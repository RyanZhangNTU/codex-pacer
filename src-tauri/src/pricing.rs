use std::collections::HashMap;

use rusqlite::{params, Connection};

use crate::database::{bool_to_i64, i64_to_bool, now_utc_string};
use crate::models::{PricingCatalogEntry, TokenUsage};

#[derive(Debug, Clone)]
pub struct ResolvedPricing {
  pub input_price_per_million: f64,
  pub cached_input_price_per_million: f64,
  pub output_price_per_million: f64,
}

fn pricing_seed() -> Vec<PricingCatalogEntry> {
  let updated_at = now_utc_string();
  vec![
    PricingCatalogEntry {
      model_id: "gpt-5.5".to_string(),
      display_name: "GPT-5.5".to_string(),
      input_price_per_million: 5.00,
      cached_input_price_per_million: 0.50,
      output_price_per_million: 30.00,
      effective_model_id: "gpt-5.5".to_string(),
      is_official: true,
      note: None,
      source_url: "https://openai.com/api/pricing/".to_string(),
      updated_at: updated_at.clone(),
    },
    PricingCatalogEntry {
      model_id: "gpt-5.4".to_string(),
      display_name: "GPT-5.4".to_string(),
      input_price_per_million: 2.50,
      cached_input_price_per_million: 0.25,
      output_price_per_million: 15.00,
      effective_model_id: "gpt-5.4".to_string(),
      is_official: true,
      note: None,
      source_url: "https://developers.openai.com/api/docs/models/gpt-5.4".to_string(),
      updated_at: updated_at.clone(),
    },
    PricingCatalogEntry {
      model_id: "gpt-5.4-mini".to_string(),
      display_name: "GPT-5.4 Mini".to_string(),
      input_price_per_million: 0.75,
      cached_input_price_per_million: 0.075,
      output_price_per_million: 4.50,
      effective_model_id: "gpt-5.4-mini".to_string(),
      is_official: true,
      note: None,
      source_url: "https://developers.openai.com/api/docs/models/gpt-5.4-mini".to_string(),
      updated_at: updated_at.clone(),
    },
    PricingCatalogEntry {
      model_id: "gpt-5.4-nano".to_string(),
      display_name: "GPT-5.4 Nano".to_string(),
      input_price_per_million: 0.20,
      cached_input_price_per_million: 0.02,
      output_price_per_million: 1.25,
      effective_model_id: "gpt-5.4-nano".to_string(),
      is_official: true,
      note: None,
      source_url: "https://openai.com/api/pricing/".to_string(),
      updated_at: updated_at.clone(),
    },
    PricingCatalogEntry {
      model_id: "gpt-5.3-codex".to_string(),
      display_name: "GPT-5.3 Codex".to_string(),
      input_price_per_million: 1.75,
      cached_input_price_per_million: 0.175,
      output_price_per_million: 14.00,
      effective_model_id: "gpt-5.3-codex".to_string(),
      is_official: true,
      note: None,
      source_url: "https://developers.openai.com/api/docs/models/gpt-5.3-codex".to_string(),
      updated_at: updated_at.clone(),
    },
    PricingCatalogEntry {
      model_id: "gpt-5.3-codex-spark".to_string(),
      display_name: "GPT-5.3 Codex Spark".to_string(),
      input_price_per_million: 1.75,
      cached_input_price_per_million: 0.175,
      output_price_per_million: 14.00,
      effective_model_id: "gpt-5.3-codex".to_string(),
      is_official: false,
      note: Some("No public Spark API price was found. Using GPT-5.3 Codex pricing.".to_string()),
      source_url: "https://developers.openai.com/api/docs/models/gpt-5.3-codex".to_string(),
      updated_at: updated_at.clone(),
    },
    PricingCatalogEntry {
      model_id: "gpt-5.2".to_string(),
      display_name: "GPT-5.2".to_string(),
      input_price_per_million: 1.75,
      cached_input_price_per_million: 0.175,
      output_price_per_million: 14.00,
      effective_model_id: "gpt-5.2".to_string(),
      is_official: true,
      note: None,
      source_url: "https://platform.openai.com/docs/models/gpt-5.2-codex".to_string(),
      updated_at: updated_at.clone(),
    },
    PricingCatalogEntry {
      model_id: "gpt-5.2-codex".to_string(),
      display_name: "GPT-5.2 Codex".to_string(),
      input_price_per_million: 1.75,
      cached_input_price_per_million: 0.175,
      output_price_per_million: 14.00,
      effective_model_id: "gpt-5.2-codex".to_string(),
      is_official: true,
      note: None,
      source_url: "https://platform.openai.com/docs/models/gpt-5.2-codex".to_string(),
      updated_at: updated_at.clone(),
    },
    PricingCatalogEntry {
      model_id: "gpt-5-codex".to_string(),
      display_name: "GPT-5 Codex".to_string(),
      input_price_per_million: 1.25,
      cached_input_price_per_million: 0.125,
      output_price_per_million: 10.00,
      effective_model_id: "gpt-5-codex".to_string(),
      is_official: true,
      note: None,
      source_url: "https://platform.openai.com/docs/models/gpt-5-codex".to_string(),
      updated_at: updated_at.clone(),
    },
    PricingCatalogEntry {
      model_id: "gpt-5.1-codex-max".to_string(),
      display_name: "GPT-5.1 Codex Max".to_string(),
      input_price_per_million: 1.25,
      cached_input_price_per_million: 0.125,
      output_price_per_million: 10.00,
      effective_model_id: "gpt-5.1-codex-max".to_string(),
      is_official: true,
      note: None,
      source_url: "https://platform.openai.com/docs/models/gpt-5.1-codex-max".to_string(),
      updated_at: updated_at.clone(),
    },
    PricingCatalogEntry {
      model_id: "gpt-5.1-codex".to_string(),
      display_name: "GPT-5.1 Codex".to_string(),
      input_price_per_million: 1.25,
      cached_input_price_per_million: 0.125,
      output_price_per_million: 10.00,
      effective_model_id: "gpt-5.1-codex".to_string(),
      is_official: true,
      note: None,
      source_url: "https://developers.openai.com/api/docs/models/gpt-5.1-codex".to_string(),
      updated_at: updated_at.clone(),
    },
    PricingCatalogEntry {
      model_id: "gpt-5.1-codex-mini".to_string(),
      display_name: "GPT-5.1 Codex Mini".to_string(),
      input_price_per_million: 0.25,
      cached_input_price_per_million: 0.025,
      output_price_per_million: 2.00,
      effective_model_id: "gpt-5.1-codex-mini".to_string(),
      is_official: true,
      note: None,
      source_url: "https://platform.openai.com/docs/models/gpt-5.1-codex-mini".to_string(),
      updated_at,
    },
  ]
}

pub fn seed_pricing_catalog(conn: &Connection) -> rusqlite::Result<Vec<PricingCatalogEntry>> {
  let entries = pricing_seed();
  for entry in &entries {
    conn.execute(
      "
      INSERT INTO pricing_catalog (
        model_id, display_name, input_price_per_million, cached_input_price_per_million,
        output_price_per_million, effective_model_id, is_official, note, source_url, updated_at
      )
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      ON CONFLICT(model_id) DO UPDATE SET
        display_name = excluded.display_name,
        input_price_per_million = excluded.input_price_per_million,
        cached_input_price_per_million = excluded.cached_input_price_per_million,
        output_price_per_million = excluded.output_price_per_million,
        effective_model_id = excluded.effective_model_id,
        is_official = excluded.is_official,
        note = excluded.note,
        source_url = excluded.source_url,
        updated_at = excluded.updated_at
      ",
      params![
        entry.model_id,
        entry.display_name,
        entry.input_price_per_million,
        entry.cached_input_price_per_million,
        entry.output_price_per_million,
        entry.effective_model_id,
        bool_to_i64(entry.is_official),
        entry.note,
        entry.source_url,
        entry.updated_at,
      ],
    )?;
  }

  load_catalog(conn)
}

pub fn load_catalog(conn: &Connection) -> rusqlite::Result<Vec<PricingCatalogEntry>> {
  let mut stmt = conn.prepare(
    "
    SELECT model_id, display_name, input_price_per_million, cached_input_price_per_million,
           output_price_per_million, effective_model_id, is_official, note, source_url, updated_at
    FROM pricing_catalog
    ORDER BY model_id
    ",
  )?;

  let rows = stmt.query_map([], |row| {
    Ok(PricingCatalogEntry {
      model_id: row.get(0)?,
      display_name: row.get(1)?,
      input_price_per_million: row.get(2)?,
      cached_input_price_per_million: row.get(3)?,
      output_price_per_million: row.get(4)?,
      effective_model_id: row.get(5)?,
      is_official: i64_to_bool(row.get::<_, i64>(6)?),
      note: row.get(7)?,
      source_url: row.get(8)?,
      updated_at: row.get(9)?,
    })
  })?;

  rows.collect()
}

pub fn load_catalog_map(conn: &Connection) -> rusqlite::Result<HashMap<String, PricingCatalogEntry>> {
  Ok(load_catalog(conn)?
    .into_iter()
    .map(|entry| (entry.model_id.clone(), entry))
    .collect())
}

pub fn resolve_pricing(
  catalog: &HashMap<String, PricingCatalogEntry>,
  model_id: &str,
) -> Option<ResolvedPricing> {
  let normalized = normalize_model_id(model_id);
  let entry = if let Some(entry) = catalog.get(&normalized) {
    entry.clone()
  } else if normalized.starts_with("gpt-5.5") {
    catalog.get("gpt-5.5")?.clone()
  } else if normalized.starts_with("gpt-5.4-mini") {
    catalog.get("gpt-5.4-mini")?.clone()
  } else if normalized.starts_with("gpt-5.4-nano") {
    catalog.get("gpt-5.4-nano")?.clone()
  } else if normalized.starts_with("gpt-5.4") {
    catalog.get("gpt-5.4")?.clone()
  } else if normalized.starts_with("gpt-5.3-codex-spark") {
    catalog.get("gpt-5.3-codex-spark")?.clone()
  } else if normalized.starts_with("gpt-5.3-codex") {
    catalog.get("gpt-5.3-codex")?.clone()
  } else if normalized.starts_with("gpt-5.2-codex") {
    catalog.get("gpt-5.2-codex")?.clone()
  } else if normalized.starts_with("gpt-5.2") {
    catalog.get("gpt-5.2")?.clone()
  } else if normalized.starts_with("gpt-5-codex") {
    catalog.get("gpt-5-codex")?.clone()
  } else if normalized.starts_with("gpt-5.1-codex-max") {
    catalog.get("gpt-5.1-codex-max")?.clone()
  } else if normalized.starts_with("gpt-5.1-codex-mini") {
    catalog.get("gpt-5.1-codex-mini")?.clone()
  } else if normalized.starts_with("gpt-5.1-codex") {
    catalog.get("gpt-5.1-codex")?.clone()
  } else {
    return None;
  };

  Some(ResolvedPricing {
    input_price_per_million: entry.input_price_per_million,
    cached_input_price_per_million: entry.cached_input_price_per_million,
    output_price_per_million: entry.output_price_per_million,
  })
}

pub fn normalize_model_id(model_id: &str) -> String {
  let trimmed = model_id.trim();
  if trimmed.is_empty() {
    "unknown".to_string()
  } else {
    trimmed.to_ascii_lowercase()
  }
}

pub fn display_name_for_model(model_id: &str) -> String {
  match normalize_model_id(model_id).as_str() {
    "gpt-5.5" => "GPT-5.5".to_string(),
    "gpt-5.4" => "GPT-5.4".to_string(),
    "gpt-5.4-mini" => "GPT-5.4 Mini".to_string(),
    "gpt-5.4-nano" => "GPT-5.4 Nano".to_string(),
    "gpt-5.3-codex" => "GPT-5.3 Codex".to_string(),
    "gpt-5.3-codex-spark" => "GPT-5.3 Codex Spark".to_string(),
    "gpt-5.2" => "GPT-5.2".to_string(),
    "gpt-5.2-codex" => "GPT-5.2 Codex".to_string(),
    "gpt-5-codex" => "GPT-5 Codex".to_string(),
    "gpt-5.1-codex" => "GPT-5.1 Codex".to_string(),
    "gpt-5.1-codex-max" => "GPT-5.1 Codex Max".to_string(),
    "gpt-5.1-codex-mini" => "GPT-5.1 Codex Mini".to_string(),
    "unknown" => "Unknown".to_string(),
    other => other.to_ascii_uppercase(),
  }
}

pub fn model_color(model_id: &str) -> &'static str {
  match normalize_model_id(model_id).as_str() {
    "gpt-5.5" => "#d946ef",
    "gpt-5.4" => "#ff6b35",
    "gpt-5.4-mini" => "#ff915c",
    "gpt-5.4-nano" => "#ffb67d",
    "gpt-5.3-codex" => "#ff9f1c",
    "gpt-5.3-codex-spark" => "#ffd166",
    "gpt-5.2" => "#1f9d8f",
    "gpt-5.2-codex" => "#2ec4b6",
    "gpt-5-codex" => "#3a86ff",
    "gpt-5.1-codex-max" => "#8338ec",
    "gpt-5.1-codex" => "#8d99ae",
    "gpt-5.1-codex-mini" => "#457b9d",
    _ => "#7c7f86",
  }
}

pub fn is_codex_fast_mode_model(model_id: &str) -> bool {
  let normalized = normalize_model_id(model_id);
  normalized.starts_with("gpt-5.5") || normalized.starts_with("gpt-5.4")
}

pub fn fast_mode_multiplier_for_model(model_id: &str) -> f64 {
  let normalized = normalize_model_id(model_id);
  if normalized.starts_with("gpt-5.5") {
    2.5
  } else if normalized.starts_with("gpt-5.4") {
    2.0
  } else {
    1.0
  }
}

pub fn calculate_value_usd(
  usage: &TokenUsage,
  resolved_pricing: Option<&ResolvedPricing>,
  model_id: &str,
  fast_mode_enabled: bool,
) -> f64 {
  let Some(pricing) = resolved_pricing else {
    return 0.0;
  };

  let mut input_tokens = usage.input_tokens as f64;
  let mut cached_input_tokens = usage.cached_input_tokens as f64;
  let mut output_tokens = usage.output_tokens as f64;
  let mut uncached_input_tokens = (input_tokens - cached_input_tokens).max(0.0);

  if fast_mode_enabled {
    let multiplier = fast_mode_multiplier_for_model(model_id);
    input_tokens *= multiplier;
    cached_input_tokens *= multiplier;
    output_tokens *= multiplier;
    uncached_input_tokens = (input_tokens - cached_input_tokens).max(0.0);
  }

  (uncached_input_tokens / 1_000_000.0) * pricing.input_price_per_million
    + (cached_input_tokens / 1_000_000.0) * pricing.cached_input_price_per_million
    + (output_tokens / 1_000_000.0) * pricing.output_price_per_million
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn cached_input_is_not_billed_twice() {
    let usage = TokenUsage {
      input_tokens: 1_000_000,
      cached_input_tokens: 400_000,
      output_tokens: 100_000,
      reasoning_output_tokens: 0,
      total_tokens: 1_100_000,
    };
    let pricing = ResolvedPricing {
      input_price_per_million: 2.0,
      cached_input_price_per_million: 0.5,
      output_price_per_million: 10.0,
    };

    let value = calculate_value_usd(&usage, Some(&pricing), "gpt-5.4", false);
    let expected = (600_000.0 / 1_000_000.0) * 2.0
      + (400_000.0 / 1_000_000.0) * 0.5
      + (100_000.0 / 1_000_000.0) * 10.0;

    assert!((value - expected).abs() < 1e-9);
  }

  #[test]
  fn fast_mode_doubles_each_billable_bucket() {
    let usage = TokenUsage {
      input_tokens: 1_000_000,
      cached_input_tokens: 250_000,
      output_tokens: 250_000,
      reasoning_output_tokens: 0,
      total_tokens: 1_250_000,
    };
    let pricing = ResolvedPricing {
      input_price_per_million: 2.0,
      cached_input_price_per_million: 0.5,
      output_price_per_million: 10.0,
    };

    let standard = calculate_value_usd(&usage, Some(&pricing), "gpt-5.4", false);
    let fast = calculate_value_usd(&usage, Some(&pricing), "gpt-5.4", true);

    assert!((fast - standard * 2.0).abs() < 1e-9);
  }

  #[test]
  fn resolve_pricing_distinguishes_gpt_54_variants() {
    let entries = pricing_seed();
    let catalog = entries
      .into_iter()
      .map(|entry| (entry.model_id.clone(), entry))
      .collect::<HashMap<_, _>>();

    let flagship = resolve_pricing(&catalog, "gpt-5.4").expect("gpt-5.4 pricing");
    let mini = resolve_pricing(&catalog, "gpt-5.4-mini").expect("gpt-5.4-mini pricing");
    let nano = resolve_pricing(&catalog, "gpt-5.4-nano").expect("gpt-5.4-nano pricing");

    assert_eq!(flagship.input_price_per_million, 2.50);
    assert_eq!(mini.input_price_per_million, 0.75);
    assert_eq!(nano.input_price_per_million, 0.20);
    assert!(flagship.input_price_per_million > mini.input_price_per_million);
    assert!(mini.input_price_per_million > nano.input_price_per_million);
  }

  #[test]
  fn resolve_pricing_includes_gpt_55() {
    let entries = pricing_seed();
    let catalog = entries
      .into_iter()
      .map(|entry| (entry.model_id.clone(), entry))
      .collect::<HashMap<_, _>>();

    let pricing = resolve_pricing(&catalog, "gpt-5.5").expect("gpt-5.5 pricing");

    assert_eq!(pricing.input_price_per_million, 5.00);
    assert_eq!(pricing.cached_input_price_per_million, 0.50);
    assert_eq!(pricing.output_price_per_million, 30.00);
  }

  #[test]
  fn gpt_55_fast_mode_uses_two_point_five_multiplier() {
    let usage = TokenUsage {
      input_tokens: 1_000_000,
      cached_input_tokens: 250_000,
      output_tokens: 250_000,
      reasoning_output_tokens: 0,
      total_tokens: 1_250_000,
    };
    let pricing = ResolvedPricing {
      input_price_per_million: 5.0,
      cached_input_price_per_million: 0.5,
      output_price_per_million: 30.0,
    };

    let standard = calculate_value_usd(&usage, Some(&pricing), "gpt-5.5", false);
    let fast = calculate_value_usd(&usage, Some(&pricing), "gpt-5.5", true);

    assert!((fast - standard * 2.5).abs() < 1e-9);
  }

  #[test]
  fn gpt_55_models_are_fast_mode_eligible() {
    assert!(is_codex_fast_mode_model("gpt-5.5"));
    assert!(is_codex_fast_mode_model("gpt-5.5-2026-04-23"));
    assert!(is_codex_fast_mode_model("gpt-5.4"));
    assert!(!is_codex_fast_mode_model("gpt-5.3-codex"));
  }
}
