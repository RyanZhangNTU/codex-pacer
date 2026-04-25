use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use chrono::{Local, LocalResult, TimeZone, Timelike};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::models::{LiveRateLimitSnapshot, RateLimitWindowSnapshot};

const APP_SERVER_TIMEOUT: Duration = Duration::from_secs(5);
const INIT_REQUEST_ID: &str = "codex-counter.init";
const READ_REQUEST_ID: &str = "codex-counter.rate-limits";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppServerRateLimitWindow {
  used_percent: i64,
  window_duration_mins: Option<i64>,
  resets_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppServerRateLimitSnapshot {
  limit_id: Option<String>,
  limit_name: Option<String>,
  plan_type: Option<String>,
  primary: Option<AppServerRateLimitWindow>,
  secondary: Option<AppServerRateLimitWindow>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppServerRateLimitReadResponse {
  rate_limits: AppServerRateLimitSnapshot,
}

enum AppServerMessage {
  Initialized(Result<(), String>),
  RateLimits(Result<LiveRateLimitSnapshot, String>),
  Closed,
}

pub fn query_live_rate_limits() -> Result<LiveRateLimitSnapshot, String> {
  let codex_binary = resolve_codex_binary();
  let mut child = Command::new("script")
    .args([
      "-q",
      "/dev/null",
      codex_binary
        .to_str()
        .ok_or_else(|| format!("Invalid Codex binary path: {}", codex_binary.display()))?,
      "app-server",
      "--listen",
      "stdio://",
    ])
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::null())
    .spawn()
    .map_err(|error| format!("Failed to launch codex app-server from {}: {error}", codex_binary.display()))?;

  let stdout = match child.stdout.take() {
    Some(stdout) => stdout,
    None => {
      stop_app_server(&mut child);
      return Err("Failed to capture codex app-server stdout.".to_string());
    }
  };
  let (sender, receiver) = mpsc::channel();

  std::thread::spawn(move || {
    let mut init_ok = false;
    for line in BufReader::new(stdout).lines().map_while(Result::ok) {
      let parsed: Value = match serde_json::from_str(&line) {
        Ok(value) => value,
        Err(_) => continue,
      };

      let Some(response_id) = response_id(&parsed) else {
        continue;
      };
      if !parsed.get("result").is_some() && !parsed.get("error").is_some() {
        continue;
      }

      if response_id == INIT_REQUEST_ID {
        if let Some(error) = parsed.get("error") {
          let _ = sender.send(AppServerMessage::Initialized(Err(format!(
            "Codex app-server initialize failed: {}",
            json_error_message(error)
          ))));
          return;
        }
        init_ok = true;
        let _ = sender.send(AppServerMessage::Initialized(Ok(())));
        continue;
      }

      if response_id != READ_REQUEST_ID {
        continue;
      }

      if !init_ok {
        let _ = sender.send(AppServerMessage::RateLimits(Err(
          "Codex app-server returned rate limits before initialization completed.".to_string(),
        )));
        return;
      }

      if let Some(error) = parsed.get("error") {
        let _ = sender.send(AppServerMessage::RateLimits(Err(format!(
          "Codex app-server rate-limit query failed: {}",
          json_error_message(error)
        ))));
        return;
      }

      let Some(result) = parsed.get("result") else {
        let _ = sender.send(AppServerMessage::RateLimits(Err(
          "Codex app-server returned an empty rate-limit response.".to_string(),
        )));
        return;
      };

      let response = serde_json::from_value::<AppServerRateLimitReadResponse>(result.clone())
        .map_err(|error| format!("Failed to decode Codex rate-limit response: {error}"));
      let _ = sender.send(AppServerMessage::RateLimits(
        response.map(|value| convert_live_rate_limits(value.rate_limits)),
      ));
      return;
    }

    let _ = sender.send(AppServerMessage::Closed);
  });

  if let Err(error) = send_app_server_request(
    &mut child,
    json!({
      "id": INIT_REQUEST_ID,
      "method": "initialize",
      "params": {
        "clientInfo": {
          "name": "codex-counter",
          "version": env!("CARGO_PKG_VERSION"),
        },
        "capabilities": {
          "experimentalApi": true,
        }
      }
    }),
    "Failed to initialize codex app-server",
    "Failed to flush codex app-server init request",
  ) {
    stop_app_server(&mut child);
    return Err(error);
  }

  let init_response = match receiver.recv_timeout(APP_SERVER_TIMEOUT) {
    Ok(message) => message,
    Err(_) => {
      stop_app_server(&mut child);
      return Err("Timed out while initializing Codex app-server.".to_string());
    }
  };

  match init_response {
    AppServerMessage::Initialized(Ok(())) => {}
    AppServerMessage::Initialized(Err(error)) => {
      stop_app_server(&mut child);
      return Err(error);
    }
    AppServerMessage::RateLimits(result) => {
      stop_app_server(&mut child);
      return result;
    }
    AppServerMessage::Closed => {
      stop_app_server(&mut child);
      return Err("Codex app-server closed before initialization completed.".to_string());
    }
  }

  if let Err(error) = send_app_server_request(
    &mut child,
    json!({
      "id": READ_REQUEST_ID,
      "method": "account/rateLimits/read",
      "params": Value::Null,
    }),
    "Failed to request live rate limits after Codex app-server initialization",
    "Failed to flush codex app-server rate-limit request",
  ) {
    stop_app_server(&mut child);
    return Err(error);
  }

  let response = loop {
    let message = match receiver.recv_timeout(APP_SERVER_TIMEOUT) {
      Ok(message) => message,
      Err(_) => {
        stop_app_server(&mut child);
        return Err("Timed out while querying live rate limits from Codex.".to_string());
      }
    };

    match message {
      AppServerMessage::Initialized(Ok(())) => continue,
      AppServerMessage::Initialized(Err(error)) => break Err(error),
      AppServerMessage::RateLimits(result) => break result,
      AppServerMessage::Closed => break Err(
        "Codex app-server closed before returning live rate limits.".to_string(),
      ),
    }
  };

  stop_app_server(&mut child);
  response
}

fn send_app_server_request(
  child: &mut Child,
  request: Value,
  write_context: &str,
  flush_context: &str,
) -> Result<(), String> {
  let stdin = child
    .stdin
    .as_mut()
    .ok_or_else(|| "Failed to open codex app-server stdin.".to_string())?;
  writeln!(stdin, "{request}").map_err(|error| format!("{write_context}: {error}"))?;
  stdin
    .flush()
    .map_err(|error| format!("{flush_context}: {error}"))
}

fn stop_app_server(child: &mut Child) {
  let _ = child.stdin.take();
  let _ = child.kill();
  let _ = child.wait();
}

fn convert_live_rate_limits(snapshot: AppServerRateLimitSnapshot) -> LiveRateLimitSnapshot {
  LiveRateLimitSnapshot {
    limit_id: snapshot.limit_id,
    limit_name: snapshot.limit_name,
    plan_type: snapshot.plan_type,
    primary: snapshot.primary.map(convert_window),
    secondary: snapshot.secondary.map(convert_window),
    fetched_at: Local::now().to_rfc3339(),
  }
}

fn convert_window(window: AppServerRateLimitWindow) -> RateLimitWindowSnapshot {
  let resets_at = window
    .resets_at
    .and_then(|value| unix_seconds_to_rfc3339(value).ok());
  let window_start = match (window.resets_at, window.window_duration_mins) {
    (Some(resets_at), Some(duration)) => unix_seconds_to_rfc3339(resets_at - duration * 60).ok(),
    _ => None,
  };

  RateLimitWindowSnapshot {
    used_percent: window.used_percent.clamp(0, 100),
    remaining_percent: (100 - window.used_percent).clamp(0, 100),
    window_duration_mins: window.window_duration_mins,
    resets_at,
    window_start,
  }
}

fn unix_seconds_to_rfc3339(value: i64) -> Result<String, String> {
  match Local.timestamp_opt(value, 0) {
    LocalResult::Single(timestamp) => Ok(normalize_local_timestamp(timestamp).to_rfc3339()),
    LocalResult::Ambiguous(timestamp, _) => Ok(normalize_local_timestamp(timestamp).to_rfc3339()),
    LocalResult::None => Err(format!("Could not localize unix timestamp {value}.")),
  }
}

fn normalize_local_timestamp(timestamp: chrono::DateTime<Local>) -> chrono::DateTime<Local> {
  timestamp
    .with_second(0)
    .and_then(|value| value.with_nanosecond(0))
    .unwrap_or(timestamp)
}

fn response_id(value: &Value) -> Option<&str> {
  value.get("id").and_then(Value::as_str)
}

fn json_error_message(value: &Value) -> String {
  value
    .get("message")
    .and_then(Value::as_str)
    .unwrap_or("unknown error")
    .to_string()
}

fn resolve_codex_binary() -> PathBuf {
  if let Ok(path) = std::env::var("CODEX_BIN") {
    let candidate = PathBuf::from(path);
    if candidate.exists() {
      return candidate;
    }
  }

  let candidates = [
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    "~/.cargo/bin/codex",
  ];

  for candidate in candidates {
    let path = expand_home(candidate);
    if path.exists() {
      return path;
    }
  }

  PathBuf::from("codex")
}

fn expand_home(value: &str) -> PathBuf {
  if value == "~/.cargo/bin/codex" {
    if let Some(home) = dirs::home_dir() {
      return home.join(".cargo/bin/codex");
    }
  }
  PathBuf::from(value)
}

#[cfg(test)]
mod tests {
  use super::convert_window;

  #[test]
  fn convert_window_calculates_remaining_and_start() {
    let converted = convert_window(super::AppServerRateLimitWindow {
      used_percent: 13,
      window_duration_mins: Some(300),
      resets_at: Some(1_774_513_656),
    });

    assert_eq!(converted.used_percent, 13);
    assert_eq!(converted.remaining_percent, 87);
    assert_eq!(converted.window_duration_mins, Some(300));
    assert!(converted.resets_at.is_some());
    assert!(converted.window_start.is_some());
  }
}
