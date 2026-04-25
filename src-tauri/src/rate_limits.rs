use std::ffi::{OsStr, OsString};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
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

struct AppServerCommandSpec {
  program: OsString,
  args: Vec<OsString>,
  hide_window: bool,
}

pub fn query_live_rate_limits() -> Result<LiveRateLimitSnapshot, String> {
  let codex_binary = resolve_codex_binary();
  let command_spec = app_server_command_spec(&codex_binary);
  let mut command = app_server_command(&command_spec);
  let mut child = command
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

fn app_server_command(spec: &AppServerCommandSpec) -> Command {
  let mut command = Command::new(&spec.program);
  command.args(&spec.args);
  apply_app_server_window_policy(&mut command, spec);
  command
}

#[cfg(windows)]
fn apply_app_server_window_policy(command: &mut Command, spec: &AppServerCommandSpec) {
  use std::os::windows::process::CommandExt;

  const CREATE_NO_WINDOW: u32 = 0x08000000;

  if spec.hide_window {
    command.creation_flags(CREATE_NO_WINDOW);
  }
}

#[cfg(not(windows))]
fn apply_app_server_window_policy(_: &mut Command, spec: &AppServerCommandSpec) {
  let _ = spec.hide_window;
}

#[cfg(windows)]
fn app_server_command_spec(codex_binary: &PathBuf) -> AppServerCommandSpec {
  if codex_binary
    .extension()
    .and_then(OsStr::to_str)
    .is_some_and(|extension| extension.eq_ignore_ascii_case("ps1"))
  {
    let mut args = vec![
      OsString::from("-NoProfile"),
      OsString::from("-ExecutionPolicy"),
      OsString::from("Bypass"),
      OsString::from("-File"),
      codex_binary.as_os_str().to_os_string(),
    ];
    args.extend(app_server_args());

    return AppServerCommandSpec {
      program: OsString::from("powershell.exe"),
      args,
      hide_window: true,
    };
  }

  AppServerCommandSpec {
    program: codex_binary.as_os_str().to_os_string(),
    args: app_server_args(),
    hide_window: true,
  }
}

#[cfg(unix)]
fn app_server_command_spec(codex_binary: &PathBuf) -> AppServerCommandSpec {
  let mut args = vec![
    OsString::from("-q"),
    OsString::from("/dev/null"),
    codex_binary.as_os_str().to_os_string(),
  ];
  args.extend(app_server_args());

  AppServerCommandSpec {
    program: OsString::from("script"),
    args,
    hide_window: false,
  }
}

fn app_server_args() -> Vec<OsString> {
  vec![
    OsString::from("app-server"),
    OsString::from("--listen"),
    OsString::from("stdio://"),
  ]
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
  let codex_bin = std::env::var_os("CODEX_BIN");
  let app_data = std::env::var_os("APPDATA");
  let home_dir = dirs::home_dir();

  resolve_codex_binary_from_env(codex_bin.as_deref(), app_data.as_deref(), home_dir.as_deref(), |path| path.exists())
}

fn resolve_codex_binary_from_env(
  codex_bin: Option<&OsStr>,
  app_data: Option<&OsStr>,
  home_dir: Option<&Path>,
  exists: impl Fn(&Path) -> bool,
) -> PathBuf {
  if let Some(path) = codex_bin {
    let candidate = PathBuf::from(path);
    if exists(&candidate) {
      return candidate;
    }
  }

  for candidate in codex_binary_candidates(app_data, home_dir) {
    if exists(&candidate) {
      return candidate;
    }
  }

  fallback_codex_binary()
}

#[cfg(windows)]
fn codex_binary_candidates(app_data: Option<&OsStr>, _home_dir: Option<&Path>) -> Vec<PathBuf> {
  let mut candidates = Vec::new();

  if let Some(app_data) = app_data {
    let npm_dir = PathBuf::from(app_data).join("npm");
    candidates.push(npm_dir.join("codex.cmd"));
    candidates.push(npm_dir.join("codex.ps1"));
    candidates.push(npm_dir.join("codex.exe"));
  }

  candidates
}

#[cfg(not(windows))]
fn codex_binary_candidates(_app_data: Option<&OsStr>, home_dir: Option<&Path>) -> Vec<PathBuf> {
  let mut candidates = vec![
    PathBuf::from("/opt/homebrew/bin/codex"),
    PathBuf::from("/usr/local/bin/codex"),
  ];

  if let Some(home_dir) = home_dir {
    candidates.push(home_dir.join(".cargo/bin/codex"));
  }

  candidates
}

#[cfg(windows)]
fn fallback_codex_binary() -> PathBuf {
  PathBuf::from("codex.cmd")
}

#[cfg(not(windows))]
fn fallback_codex_binary() -> PathBuf {
  PathBuf::from("codex")
}

#[cfg(test)]
mod tests {
  use super::convert_window;
  use std::ffi::OsString;
  use std::path::{Path, PathBuf};

  fn existing_paths(paths: &[&str]) -> impl Fn(&Path) -> bool {
    let paths: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    move |candidate| paths.iter().any(|path| path == candidate)
  }

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

  #[test]
  #[cfg(windows)]
  fn app_server_command_spec_uses_codex_directly_on_windows() {
    let spec = super::app_server_command_spec(&PathBuf::from(r"C:\Users\Ryan\AppData\Roaming\npm\codex.cmd"));

    assert_eq!(spec.program, OsString::from(r"C:\Users\Ryan\AppData\Roaming\npm\codex.cmd"));
    assert!(spec.hide_window);
    assert_eq!(
      spec.args,
      vec![
        OsString::from("app-server"),
        OsString::from("--listen"),
        OsString::from("stdio://"),
      ]
    );
  }

  #[test]
  #[cfg(windows)]
  fn app_server_command_spec_wraps_windows_ps1_shim_with_powershell() {
    let spec = super::app_server_command_spec(&PathBuf::from(r"C:\Users\Ryan\AppData\Roaming\npm\codex.ps1"));

    assert_eq!(spec.program, OsString::from("powershell.exe"));
    assert!(spec.hide_window);
    assert_eq!(
      spec.args,
      vec![
        OsString::from("-NoProfile"),
        OsString::from("-ExecutionPolicy"),
        OsString::from("Bypass"),
        OsString::from("-File"),
        OsString::from(r"C:\Users\Ryan\AppData\Roaming\npm\codex.ps1"),
        OsString::from("app-server"),
        OsString::from("--listen"),
        OsString::from("stdio://"),
      ]
    );
  }

  #[test]
  #[cfg(windows)]
  fn resolve_codex_binary_prefers_windows_cmd_shim_over_ps1() {
    let resolved = super::resolve_codex_binary_from_env(
      None,
      Some(OsString::from(r"C:\Users\Ryan\AppData\Roaming").as_os_str()),
      None,
      existing_paths(&[r"C:\Users\Ryan\AppData\Roaming\npm\codex.cmd"]),
    );

    assert_eq!(resolved, PathBuf::from(r"C:\Users\Ryan\AppData\Roaming\npm\codex.cmd"));
  }

  #[test]
  #[cfg(windows)]
  fn resolve_codex_binary_uses_windows_ps1_shim_when_cmd_missing() {
    let resolved = super::resolve_codex_binary_from_env(
      None,
      Some(OsString::from(r"C:\Users\Ryan\AppData\Roaming").as_os_str()),
      None,
      existing_paths(&[r"C:\Users\Ryan\AppData\Roaming\npm\codex.ps1"]),
    );

    assert_eq!(resolved, PathBuf::from(r"C:\Users\Ryan\AppData\Roaming\npm\codex.ps1"));
  }

  #[test]
  #[cfg(windows)]
  fn resolve_codex_binary_prefers_existing_codex_bin_override() {
    let resolved = super::resolve_codex_binary_from_env(
      Some(OsString::from(r"D:\Tools\codex.exe").as_os_str()),
      Some(OsString::from(r"C:\Users\Ryan\AppData\Roaming").as_os_str()),
      None,
      existing_paths(&[
        r"D:\Tools\codex.exe",
        r"C:\Users\Ryan\AppData\Roaming\npm\codex.cmd",
      ]),
    );

    assert_eq!(resolved, PathBuf::from(r"D:\Tools\codex.exe"));
  }

  #[test]
  #[cfg(windows)]
  fn resolve_codex_binary_falls_back_to_windows_cmd_shim_name() {
    let resolved = super::resolve_codex_binary_from_env(
      None,
      Some(OsString::from(r"C:\Users\Ryan\AppData\Roaming").as_os_str()),
      None,
      |_| false,
    );

    assert_eq!(resolved, PathBuf::from("codex.cmd"));
  }
}
