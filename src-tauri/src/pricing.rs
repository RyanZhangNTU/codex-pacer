use std::collections::{HashMap, HashSet};
use std::time::Duration;

use rusqlite::{params, Connection};

use crate::database::{bool_to_i64, i64_to_bool, now_utc_string};
use crate::models::{PricingCatalogEntry, TokenUsage};

pub const OPENAI_API_PRICING_URL: &str = "https://developers.openai.com/api/docs/pricing";
const FALLBACK_PRICING_NOTE: &str =
    "Bundled fallback for OpenAI Standard short-context API pricing.";
const ASTRO_ISLAND_END_TAG: &str = "</astro-island>";
const CONTENT_SWITCHER_PANE_MARKER: &str = "data-content-switcher-pane=\"true\" data-value=\"";

#[derive(Debug, Clone)]
pub struct ResolvedPricing {
    pub input_price_per_million: f64,
    pub cached_input_price_per_million: f64,
    pub output_price_per_million: f64,
}

#[derive(Debug, Clone, Copy)]
enum PricingUpsertMode {
    PreserveOfficial,
    Overwrite,
}

#[derive(Debug, Clone)]
struct OfficialPricingRow {
    model_id: String,
    input_price_per_million: f64,
    cached_input_price_per_million: f64,
    output_price_per_million: f64,
}

fn pricing_seed() -> Vec<PricingCatalogEntry> {
    let updated_at = now_utc_string();
    vec![
        fallback_entry(
            "gpt-6-astra",
            "GPT-6 Astra",
            10.00,
            1.00,
            50.00,
            &updated_at,
        ),
        PricingCatalogEntry {
            model_id: "gpt-5.6".to_string(),
            display_name: "GPT-5.6".to_string(),
            input_price_per_million: 5.00,
            cached_input_price_per_million: 0.50,
            output_price_per_million: 30.00,
            effective_model_id: "gpt-5.6-sol".to_string(),
            is_official: false,
            note: Some(FALLBACK_PRICING_NOTE.to_string()),
            source_url: OPENAI_API_PRICING_URL.to_string(),
            updated_at: updated_at.clone(),
        },
        fallback_entry("gpt-5.6-sol", "GPT-5.6 Sol", 5.00, 0.50, 30.00, &updated_at),
        fallback_entry(
            "gpt-5.6-terra",
            "GPT-5.6 Terra",
            2.50,
            0.25,
            15.00,
            &updated_at,
        ),
        fallback_entry(
            "gpt-5.6-luna",
            "GPT-5.6 Luna",
            1.00,
            0.10,
            6.00,
            &updated_at,
        ),
        fallback_entry("gpt-5.5", "GPT-5.5", 5.00, 0.50, 30.00, &updated_at),
        fallback_entry("gpt-5.4", "GPT-5.4", 2.50, 0.25, 15.00, &updated_at),
        fallback_entry(
            "gpt-5.4-mini",
            "GPT-5.4 Mini",
            0.75,
            0.075,
            4.50,
            &updated_at,
        ),
        fallback_entry(
            "gpt-5.4-nano",
            "GPT-5.4 Nano",
            0.20,
            0.02,
            1.25,
            &updated_at,
        ),
        fallback_entry(
            "gpt-5.3-codex",
            "GPT-5.3 Codex",
            1.75,
            0.175,
            14.00,
            &updated_at,
        ),
        PricingCatalogEntry {
            model_id: "gpt-5.3-codex-spark".to_string(),
            display_name: "GPT-5.3 Codex Spark".to_string(),
            input_price_per_million: 1.75,
            cached_input_price_per_million: 0.175,
            output_price_per_million: 14.00,
            effective_model_id: "gpt-5.3-codex".to_string(),
            is_official: false,
            note: Some(
                "No public Spark API price was found. Using GPT-5.3 Codex fallback pricing."
                    .to_string(),
            ),
            source_url: OPENAI_API_PRICING_URL.to_string(),
            updated_at: updated_at.clone(),
        },
        fallback_entry("gpt-5.2", "GPT-5.2", 1.75, 0.175, 14.00, &updated_at),
        fallback_entry(
            "gpt-5.2-codex",
            "GPT-5.2 Codex",
            1.75,
            0.175,
            14.00,
            &updated_at,
        ),
        fallback_entry(
            "gpt-5-codex",
            "GPT-5 Codex",
            1.25,
            0.125,
            10.00,
            &updated_at,
        ),
        fallback_entry(
            "gpt-5.1-codex-max",
            "GPT-5.1 Codex Max",
            1.25,
            0.125,
            10.00,
            &updated_at,
        ),
        fallback_entry(
            "gpt-5.1-codex",
            "GPT-5.1 Codex",
            1.25,
            0.125,
            10.00,
            &updated_at,
        ),
        fallback_entry(
            "gpt-5.1-codex-mini",
            "GPT-5.1 Codex Mini",
            0.25,
            0.025,
            2.00,
            &updated_at,
        ),
    ]
}

fn fallback_entry(
    model_id: &str,
    display_name: &str,
    input_price_per_million: f64,
    cached_input_price_per_million: f64,
    output_price_per_million: f64,
    updated_at: &str,
) -> PricingCatalogEntry {
    PricingCatalogEntry {
        model_id: model_id.to_string(),
        display_name: display_name.to_string(),
        input_price_per_million,
        cached_input_price_per_million,
        output_price_per_million,
        effective_model_id: model_id.to_string(),
        is_official: false,
        note: Some(FALLBACK_PRICING_NOTE.to_string()),
        source_url: OPENAI_API_PRICING_URL.to_string(),
        updated_at: updated_at.to_string(),
    }
}

fn official_entry(row: OfficialPricingRow, updated_at: &str) -> PricingCatalogEntry {
    PricingCatalogEntry {
        display_name: display_name_for_model(&row.model_id),
        effective_model_id: row.model_id.clone(),
        model_id: row.model_id,
        input_price_per_million: row.input_price_per_million,
        cached_input_price_per_million: row.cached_input_price_per_million,
        output_price_per_million: row.output_price_per_million,
        is_official: true,
        note: Some("OpenAI API Standard short-context pricing.".to_string()),
        source_url: OPENAI_API_PRICING_URL.to_string(),
        updated_at: updated_at.to_string(),
    }
}

pub fn seed_pricing_catalog(conn: &Connection) -> rusqlite::Result<Vec<PricingCatalogEntry>> {
    let entries = pricing_seed();
    repair_misparsed_gpt_56_output_prices(conn)?;
    upsert_pricing_entries(conn, &entries, PricingUpsertMode::PreserveOfficial)?;
    load_catalog(conn)
}

fn repair_misparsed_gpt_56_output_prices(conn: &Connection) -> rusqlite::Result<()> {
    for (model_id, input, cached_input, bad_output) in [
        ("gpt-5.6-sol", 5.0, 0.5, 6.25),
        ("gpt-5.6-terra", 2.5, 0.25, 3.125),
        ("gpt-5.6-luna", 1.0, 0.1, 1.25),
    ] {
        conn.execute(
            "
            UPDATE pricing_catalog
            SET is_official = 0
            WHERE model_id = ?1
              AND is_official = 1
              AND ABS(input_price_per_million - ?2) <= 1e-9
              AND ABS(cached_input_price_per_million - ?3) <= 1e-9
              AND ABS(output_price_per_million - ?4) <= 1e-9
            ",
            params![model_id, input, cached_input, bad_output],
        )?;
    }

    Ok(())
}

pub fn apply_pricing_catalog_refresh(
    conn: &Connection,
    official_entries: Option<&[PricingCatalogEntry]>,
) -> Result<(), String> {
    if let Some(entries) = official_entries {
        upsert_pricing_entries(conn, entries, PricingUpsertMode::Overwrite)
            .map_err(|error| error.to_string())?;
    }

    seed_pricing_catalog(conn).map_err(|error| error.to_string())?;
    Ok(())
}

pub fn fetch_official_pricing_catalog() -> Result<Vec<PricingCatalogEntry>, String> {
    let response = ureq::get(OPENAI_API_PRICING_URL)
        .timeout(Duration::from_secs(20))
        .call()
        .map_err(|error| error.to_string())?;
    let status = response.status();
    if !(200..300).contains(&status) {
        return Err(format!("OpenAI pricing page returned HTTP {status}."));
    }
    let body = response.into_string().map_err(|error| error.to_string())?;
    parse_official_pricing_catalog(&body)
}

pub fn parse_official_pricing_catalog(document: &str) -> Result<Vec<PricingCatalogEntry>, String> {
    let updated_at = now_utc_string();
    let mut entries = Vec::new();
    let mut seen = HashSet::new();

    for block in pricing_component_blocks(document) {
        for row in extract_pricing_rows(block) {
            if seen.insert(row.model_id.clone()) {
                entries.push(official_entry(row, &updated_at));
            }
        }
    }

    let required_models = [
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5.3-codex",
    ];
    let missing = required_models
        .iter()
        .filter(|model_id| !seen.contains(**model_id))
        .copied()
        .collect::<Vec<_>>();
    if !missing.is_empty() {
        return Err(format!(
            "OpenAI pricing page did not include required Standard short-context rows: {}.",
            missing.join(", ")
        ));
    }

    Ok(entries)
}

fn pricing_component_blocks(document: &str) -> Vec<&str> {
    let mut blocks = Vec::new();
    let mut cursor = 0usize;
    while let Some(relative_start) = document[cursor..].find("<astro-island") {
        let start = cursor + relative_start;
        let Some(relative_end) = document[start..].find(ASTRO_ISLAND_END_TAG) else {
            break;
        };
        let end = start + relative_end;
        let block = &document[start..end];
        let is_standard_text_table = block.contains("TextTokenPricingTables")
            && block.contains("&quot;tier&quot;:[0,&quot;standard&quot;]");
        let is_standard_grouped_pricing_table = block.contains("GroupedPricingTable")
            && is_standard_grouped_pricing_pane(document, start);
        if is_standard_text_table || is_standard_grouped_pricing_table {
            blocks.push(block);
        }
        cursor = end + ASTRO_ISLAND_END_TAG.len();
    }
    blocks
}

fn is_standard_grouped_pricing_pane(document: &str, block_start: usize) -> bool {
    nearest_content_switcher_pane_value(document, block_start)
        .map(|value| value == "standard")
        .unwrap_or(true)
}

fn nearest_content_switcher_pane_value(document: &str, block_start: usize) -> Option<&str> {
    let prefix = document.get(..block_start)?;
    let marker_start = prefix.rfind(CONTENT_SWITCHER_PANE_MARKER)?;
    let value_start = marker_start + CONTENT_SWITCHER_PANE_MARKER.len();
    let value_end = value_start + document.get(value_start..)?.find('"')?;
    document.get(value_start..value_end)
}

fn extract_pricing_rows(block: &str) -> Vec<OfficialPricingRow> {
    let marker = "[[0,&quot;";
    let mut rows = Vec::new();
    let mut cursor = 0usize;

    while let Some(relative_start) = block[cursor..].find(marker) {
        let name_start = cursor + relative_start + marker.len();
        let Some(relative_name_end) = block[name_start..].find("&quot;]") else {
            break;
        };
        let name_end = name_start + relative_name_end;
        let raw_name = html_unescape(&block[name_start..name_end]);
        let next_row = block[name_end..]
            .find(marker)
            .map(|offset| name_end + offset)
            .unwrap_or(block.len());
        if !is_standard_short_context_pricing_row(&raw_name) {
            cursor = next_row;
            continue;
        }
        let row_source = &block[name_end..next_row];
        let mut value_cursor = 0usize;
        let mut values = Vec::new();
        while let Some(value) = parse_next_pricing_value(row_source, &mut value_cursor) {
            values.push(value);
        }

        let input = values.first().copied().flatten();
        let cached_input = values.get(1).copied().flatten();
        let output = values.last().copied().flatten();

        if let (Some(input), Some(output)) = (input, output) {
            let model_id = normalize_official_model_id(&raw_name);
            if should_include_official_pricing_model(&model_id) {
                rows.push(OfficialPricingRow {
                    model_id,
                    input_price_per_million: input,
                    cached_input_price_per_million: cached_input.unwrap_or(input),
                    output_price_per_million: output,
                });
            }
        }

        cursor = next_row;
    }

    rows
}

fn is_standard_short_context_pricing_row(raw_name: &str) -> bool {
    let normalized = raw_name.to_ascii_lowercase().replace(' ', "");
    !normalized.contains(">=272k") && !normalized.contains(">272k")
}

fn parse_next_pricing_value(source: &str, cursor: &mut usize) -> Option<Option<f64>> {
    let marker = ",[0,";
    let value_start = *cursor + source[*cursor..].find(marker)? + marker.len();
    if source[value_start..].starts_with("&quot;") {
        let inner_start = value_start + "&quot;".len();
        let inner_end = inner_start + source[inner_start..].find("&quot;")?;
        *cursor = inner_end + "&quot;".len();
        Some(parse_price_literal(&html_unescape(
            &source[inner_start..inner_end],
        )))
    } else {
        let value_end = value_start + source[value_start..].find(']')?;
        *cursor = value_end;
        Some(parse_price_literal(&source[value_start..value_end]))
    }
}

fn parse_price_literal(value: &str) -> Option<f64> {
    let cleaned = value.trim().trim_start_matches('$').replace(',', "");
    if cleaned.is_empty()
        || cleaned == "-"
        || cleaned.eq_ignore_ascii_case("null")
        || cleaned.starts_with('{')
    {
        return None;
    }
    cleaned.parse::<f64>().ok()
}

fn normalize_official_model_id(raw_name: &str) -> String {
    let base = raw_name
        .split(" (")
        .next()
        .unwrap_or(raw_name)
        .trim()
        .split_whitespace()
        .next()
        .unwrap_or(raw_name)
        .trim();
    normalize_model_id(base)
}

fn should_include_official_pricing_model(model_id: &str) -> bool {
    if model_id.is_empty() {
        return false;
    }
    let excluded_fragments = [
        "image",
        "realtime",
        "transcribe",
        "tts",
        "sora",
        "embedding",
        "moderation",
        "computer-use",
        "deep-research",
    ];
    if excluded_fragments
        .iter()
        .any(|fragment| model_id.contains(fragment))
    {
        return false;
    }
    model_id.starts_with("gpt-")
        || model_id.starts_with('o')
        || model_id.starts_with("chatgpt-")
        || model_id.starts_with("codex-")
        || model_id.contains("codex")
}

fn html_unescape(value: &str) -> String {
    value
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

fn upsert_pricing_entries(
    conn: &Connection,
    entries: &[PricingCatalogEntry],
    mode: PricingUpsertMode,
) -> rusqlite::Result<()> {
    let sql = match mode {
        PricingUpsertMode::Overwrite => {
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
      "
        }
        PricingUpsertMode::PreserveOfficial => {
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
      WHERE pricing_catalog.is_official = 0
      "
        }
    };

    for entry in entries {
        conn.execute(
            sql,
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

    Ok(())
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

pub fn load_catalog_map(
    conn: &Connection,
) -> rusqlite::Result<HashMap<String, PricingCatalogEntry>> {
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
    let entry = if matches_canonical_or_dated_model_id(&normalized, "gpt-5.6") {
        catalog.get("gpt-5.6-sol")?.clone()
    } else if let Some(entry) = catalog.get(&normalized) {
        entry.clone()
    } else if matches_canonical_or_dated_model_id(&normalized, "gpt-6-astra") {
        catalog.get("gpt-6-astra")?.clone()
    } else if matches_canonical_or_dated_model_id(&normalized, "gpt-5.6-sol") {
        catalog.get("gpt-5.6-sol")?.clone()
    } else if matches_canonical_or_dated_model_id(&normalized, "gpt-5.6-terra") {
        catalog.get("gpt-5.6-terra")?.clone()
    } else if matches_canonical_or_dated_model_id(&normalized, "gpt-5.6-luna") {
        catalog.get("gpt-5.6-luna")?.clone()
    } else if normalized.starts_with("gpt-5.5-pro") {
        catalog.get("gpt-5.5-pro")?.clone()
    } else if normalized.starts_with("gpt-5.5") {
        catalog.get("gpt-5.5")?.clone()
    } else if normalized.starts_with("gpt-5.4-mini") {
        catalog.get("gpt-5.4-mini")?.clone()
    } else if normalized.starts_with("gpt-5.4-nano") {
        catalog.get("gpt-5.4-nano")?.clone()
    } else if normalized.starts_with("gpt-5.4-pro") {
        catalog.get("gpt-5.4-pro")?.clone()
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

fn matches_canonical_or_dated_model_id(model_id: &str, canonical_model_id: &str) -> bool {
    if model_id == canonical_model_id {
        return true;
    }

    let Some(date_suffix) = model_id
        .strip_prefix(canonical_model_id)
        .and_then(|suffix| suffix.strip_prefix('-'))
    else {
        return false;
    };
    let bytes = date_suffix.as_bytes();
    let has_iso_date_shape = bytes.len() == 10
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes[..4].iter().all(u8::is_ascii_digit)
        && bytes[5..7].iter().all(u8::is_ascii_digit)
        && bytes[8..].iter().all(u8::is_ascii_digit);

    has_iso_date_shape && chrono::NaiveDate::parse_from_str(date_suffix, "%Y-%m-%d").is_ok()
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
        "codex-auto-review" => "Codex Auto Review".to_string(),
        "codex-mini-latest" => "Codex Mini Latest".to_string(),
        model if matches_canonical_or_dated_model_id(model, "gpt-6-astra") => {
            "GPT-6 Astra".to_string()
        }
        "gpt-5.6" => "GPT-5.6".to_string(),
        "gpt-5.6-sol" => "GPT-5.6 Sol".to_string(),
        "gpt-5.6-terra" => "GPT-5.6 Terra".to_string(),
        "gpt-5.6-luna" => "GPT-5.6 Luna".to_string(),
        "gpt-5.5" => "GPT-5.5".to_string(),
        "gpt-5.5-pro" => "GPT-5.5 Pro".to_string(),
        "gpt-5.4" => "GPT-5.4".to_string(),
        "gpt-5.4-mini" => "GPT-5.4 Mini".to_string(),
        "gpt-5.4-nano" => "GPT-5.4 Nano".to_string(),
        "gpt-5.4-pro" => "GPT-5.4 Pro".to_string(),
        "gpt-5.3-codex" => "GPT-5.3 Codex".to_string(),
        "gpt-5.3-codex-spark" => "GPT-5.3 Codex Spark".to_string(),
        "gpt-5.3-chat-latest" => "GPT-5.3 Chat Latest".to_string(),
        "gpt-5.2" => "GPT-5.2".to_string(),
        "gpt-5.2-codex" => "GPT-5.2 Codex".to_string(),
        "gpt-5.2-chat-latest" => "GPT-5.2 Chat Latest".to_string(),
        "gpt-5.1" => "GPT-5.1".to_string(),
        "gpt-5.1-codex" => "GPT-5.1 Codex".to_string(),
        "gpt-5.1-codex-max" => "GPT-5.1 Codex Max".to_string(),
        "gpt-5.1-codex-mini" => "GPT-5.1 Codex Mini".to_string(),
        "gpt-5.1-chat-latest" => "GPT-5.1 Chat Latest".to_string(),
        "gpt-5" => "GPT-5".to_string(),
        "gpt-5-codex" => "GPT-5 Codex".to_string(),
        "gpt-5-chat-latest" => "GPT-5 Chat Latest".to_string(),
        "unknown" => "Unknown".to_string(),
        other => other.to_ascii_uppercase(),
    }
}

pub fn model_color(model_id: &str) -> &'static str {
    match normalize_model_id(model_id).as_str() {
        "codex-auto-review" => "#60a5fa",
        model if matches_canonical_or_dated_model_id(model, "gpt-6-astra") => "#06b6d4",
        "gpt-5.6" => "#f59e0b",
        "gpt-5.6-sol" => "#ffd166",
        "gpt-5.6-terra" => "#2ec4b6",
        "gpt-5.6-luna" => "#8338ec",
        "gpt-5.5" => "#d946ef",
        "gpt-5.5-pro" => "#c026d3",
        "gpt-5.4" => "#ff6b35",
        "gpt-5.4-mini" => "#ff915c",
        "gpt-5.4-nano" => "#ffb67d",
        "gpt-5.4-pro" => "#e85d04",
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

pub fn calculate_value_usd(usage: &TokenUsage, resolved_pricing: Option<&ResolvedPricing>) -> f64 {
    let Some(pricing) = resolved_pricing else {
        return 0.0;
    };

    let input_tokens = usage.input_tokens as f64;
    let cached_input_tokens = usage.cached_input_tokens as f64;
    let output_tokens = usage.output_tokens as f64;
    let uncached_input_tokens = (input_tokens - cached_input_tokens).max(0.0);

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

        let value = calculate_value_usd(&usage, Some(&pricing));
        let expected = (600_000.0 / 1_000_000.0) * 2.0
            + (400_000.0 / 1_000_000.0) * 0.5
            + (100_000.0 / 1_000_000.0) * 10.0;

        assert!((value - expected).abs() < 1e-9);
    }

    #[test]
    fn large_inputs_still_use_the_same_short_context_rate() {
        let usage = TokenUsage {
            input_tokens: 300_000,
            cached_input_tokens: 50_000,
            output_tokens: 10_000,
            reasoning_output_tokens: 0,
            total_tokens: 310_000,
        };
        let pricing = ResolvedPricing {
            input_price_per_million: 5.0,
            cached_input_price_per_million: 0.5,
            output_price_per_million: 30.0,
        };

        let value = calculate_value_usd(&usage, Some(&pricing));
        let expected = (250_000.0 / 1_000_000.0) * 5.0
            + (50_000.0 / 1_000_000.0) * 0.5
            + (10_000.0 / 1_000_000.0) * 30.0;

        assert!((value - expected).abs() < 1e-9);
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
    fn gpt_6_astra_pricing_and_presentation() {
        let catalog = pricing_seed()
            .into_iter()
            .map(|entry| (entry.model_id.clone(), entry))
            .collect::<HashMap<_, _>>();
        for model in ["gpt-6-astra", " GPT-6-ASTRA ", "gpt-6-astra-2026-09-05"] {
            assert_eq!(display_name_for_model(model), "GPT-6 Astra");
            assert_eq!(model_color(model), "#06b6d4");
            let pricing = resolve_pricing(&catalog, model).expect("Astra pricing");
            assert_eq!(pricing.input_price_per_million, 10.0);
            assert_eq!(pricing.cached_input_price_per_million, 1.0);
            assert_eq!(pricing.output_price_per_million, 50.0);
            let usage = TokenUsage {
                input_tokens: 100_000,
                cached_input_tokens: 40_000,
                output_tokens: 10_000,
                reasoning_output_tokens: 0,
                total_tokens: 110_000,
            };
            assert!((calculate_value_usd(&usage, Some(&pricing)) - 1.14).abs() < 1e-9);
        }
        for model in [
            "gpt-6",
            "gpt-6-astra-preview",
            "gpt-6-astra-2026-02-30",
            "gpt-6-astra-2026-09-05-preview",
        ] {
            assert!(resolve_pricing(&catalog, model).is_none(), "{model}");
            assert_eq!(display_name_for_model(model), model.to_ascii_uppercase());
            assert_eq!(model_color(model), "#7c7f86");
        }
        assert_eq!(display_name_for_model("gpt-6-astra"), "GPT-6 Astra");
        assert_eq!(model_color("gpt-6-astra"), "#06b6d4");
    }

    #[test]
    fn gpt_6_astra_official_row_uses_output_not_cache_write_price() {
        let rows =
            extract_pricing_rows("[[0,&quot;gpt-6-astra&quot;],[0,10],[0,1],[0,12.5],[0,50]]");
        assert_eq!(rows.len(), 1);
        let entry = official_entry(rows[0].clone(), "2026-09-05");
        assert_eq!(entry.model_id, "gpt-6-astra");
        assert_eq!(entry.display_name, "GPT-6 Astra");
        assert_eq!(entry.output_price_per_million, 50.0);
        assert!(entry.is_official);
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
    fn resolve_pricing_includes_gpt_56_family_and_alias() {
        let catalog = pricing_seed()
            .into_iter()
            .map(|entry| (entry.model_id.clone(), entry))
            .collect::<HashMap<_, _>>();

        for (model, input, cached, output) in [
            ("gpt-5.6", 5.0, 0.5, 30.0),
            ("gpt-5.6-2026-07-09", 5.0, 0.5, 30.0),
            ("gpt-5.6-sol", 5.0, 0.5, 30.0),
            ("gpt-5.6-sol-2026-07-09", 5.0, 0.5, 30.0),
            ("gpt-5.6-terra", 2.5, 0.25, 15.0),
            ("gpt-5.6-terra-2026-07-09", 2.5, 0.25, 15.0),
            ("gpt-5.6-luna", 1.0, 0.1, 6.0),
            ("gpt-5.6-luna-2026-07-09", 1.0, 0.1, 6.0),
        ] {
            let pricing = resolve_pricing(&catalog, model).expect(model);
            assert_eq!(pricing.input_price_per_million, input);
            assert_eq!(pricing.cached_input_price_per_million, cached);
            assert_eq!(pricing.output_price_per_million, output);
        }

        assert_eq!(catalog["gpt-5.6"].effective_model_id, "gpt-5.6-sol");
        assert_eq!(catalog["gpt-5.6"].display_name, "GPT-5.6");
        assert_eq!(catalog["gpt-5.6-sol"].display_name, "GPT-5.6 Sol");
        assert_eq!(catalog["gpt-5.6-terra"].display_name, "GPT-5.6 Terra");
        assert_eq!(catalog["gpt-5.6-luna"].display_name, "GPT-5.6 Luna");
        for (model_id, display_name, color) in [
            ("gpt-5.6", "GPT-5.6", "#f59e0b"),
            ("gpt-5.6-sol", "GPT-5.6 Sol", "#ffd166"),
            ("gpt-5.6-terra", "GPT-5.6 Terra", "#2ec4b6"),
            ("gpt-5.6-luna", "GPT-5.6 Luna", "#8338ec"),
        ] {
            assert_eq!(display_name_for_model(model_id), display_name);
            assert_eq!(model_color(model_id), color);
        }
    }

    #[test]
    fn resolve_pricing_routes_gpt_56_aliases_to_current_sol_row() {
        let mut catalog = pricing_seed()
            .into_iter()
            .map(|entry| (entry.model_id.clone(), entry))
            .collect::<HashMap<_, _>>();
        let alias = catalog.get_mut("gpt-5.6").expect("GPT-5.6 alias");
        alias.input_price_per_million = 4.0;
        alias.cached_input_price_per_million = 0.4;
        alias.output_price_per_million = 24.0;
        let sol = catalog.get_mut("gpt-5.6-sol").expect("GPT-5.6 Sol");
        sol.input_price_per_million = 7.0;
        sol.cached_input_price_per_million = 0.7;
        sol.output_price_per_million = 42.0;

        for model_id in ["gpt-5.6", "gpt-5.6-2026-07-09"] {
            let pricing = resolve_pricing(&catalog, model_id).expect(model_id);
            assert_eq!(pricing.input_price_per_million, 7.0);
            assert_eq!(pricing.cached_input_price_per_million, 0.7);
            assert_eq!(pricing.output_price_per_million, 42.0);
        }
    }

    #[test]
    fn resolve_pricing_does_not_guess_unknown_gpt_56_ids() {
        let catalog = pricing_seed()
            .into_iter()
            .map(|entry| (entry.model_id.clone(), entry))
            .collect::<HashMap<_, _>>();

        for model_id in [
            "gpt-5.6-solaris",
            "gpt-5.6-neptune",
            "gpt-5.60",
            "gpt-5.6-2026-02-30",
            "gpt-5.6-2026-7-09",
            "gpt-5.6-2026-07-09-preview",
            "gpt-5.6-sol-2026-02-30",
            "gpt-5.6-sol-2026-7-09",
            "gpt-5.6-sol-2026-07-09-preview",
        ] {
            assert!(
                resolve_pricing(&catalog, model_id).is_none(),
                "unexpected guessed pricing for {model_id}"
            );
        }
    }

    #[test]
    fn parses_gpt_56_cache_write_price_without_treating_it_as_output() {
        let html = complete_standard_fixture_with_gpt56_rows();
        let catalog = parse_official_pricing_catalog(&html)
            .expect("parse pricing")
            .into_iter()
            .map(|entry| (entry.model_id.clone(), entry))
            .collect::<HashMap<_, _>>();

        assert_eq!(catalog["gpt-5.6-sol"].output_price_per_million, 30.0);
        assert_eq!(catalog["gpt-5.6-terra"].output_price_per_million, 15.0);
        assert_eq!(catalog["gpt-5.6-luna"].output_price_per_million, 6.0);
    }

    #[test]
    fn seed_repairs_misparsed_gpt_56_output_prices() {
        let conn = Connection::open_in_memory().expect("open database");
        crate::database::init_db(&conn).expect("init database");
        conn.execute(
            "
            INSERT INTO pricing_catalog (
                model_id, display_name, input_price_per_million, cached_input_price_per_million,
                output_price_per_million, effective_model_id, is_official, note, source_url, updated_at
            )
            VALUES
              ('gpt-5.6-sol', 'Official Sol', 5.0, 0.5, 6.25,
               'gpt-5.6-sol', 1, 'official-sol', 'https://example.com/sol', 'official-sol'),
              ('gpt-5.6-terra', 'Official Terra', 2.5, 0.25, 3.125,
               'gpt-5.6-terra', 1, 'official-terra', 'https://example.com/terra', 'official-terra'),
              ('gpt-5.6-luna', 'Official Luna', 1.0, 0.1, 1.25,
               'gpt-5.6-luna', 1, 'official-luna', 'https://example.com/luna', 'official-luna')
            ",
            [],
        )
        .expect("insert malformed GPT-5.6 pricing");

        let catalog = seed_pricing_catalog(&conn)
            .expect("seed pricing")
            .into_iter()
            .map(|entry| (entry.model_id.clone(), entry))
            .collect::<HashMap<_, _>>();

        for (model_id, display_name, output, provenance) in [
            ("gpt-5.6-sol", "GPT-5.6 Sol", 30.0, "official-sol"),
            ("gpt-5.6-terra", "GPT-5.6 Terra", 15.0, "official-terra"),
            ("gpt-5.6-luna", "GPT-5.6 Luna", 6.0, "official-luna"),
        ] {
            let entry = &catalog[model_id];
            assert_eq!(entry.output_price_per_million, output);
            assert_eq!(entry.display_name, display_name);
            assert!(!entry.is_official);
            assert_eq!(entry.note.as_deref(), Some(FALLBACK_PRICING_NOTE));
            assert_eq!(entry.source_url, OPENAI_API_PRICING_URL);
            assert_ne!(entry.updated_at, provenance);
        }
    }

    #[test]
    fn seed_preserves_future_official_gpt_56_price_at_one_point_two_five_ratio() {
        let conn = Connection::open_in_memory().expect("open database");
        crate::database::init_db(&conn).expect("init database");
        conn.execute(
            "
            INSERT INTO pricing_catalog (
                model_id, display_name, input_price_per_million, cached_input_price_per_million,
                output_price_per_million, effective_model_id, is_official, note, source_url, updated_at
            )
            VALUES ('gpt-5.6-sol', 'Future Official Sol', 8.0, 0.8, 10.0,
                    'gpt-5.6-sol', 1, 'future-official', 'https://example.com/future',
                    'future-official-sol')
            ",
            [],
        )
        .expect("insert future official Sol pricing");

        let catalog = seed_pricing_catalog(&conn)
            .expect("seed pricing")
            .into_iter()
            .map(|entry| (entry.model_id.clone(), entry))
            .collect::<HashMap<_, _>>();
        let sol = &catalog["gpt-5.6-sol"];

        assert_eq!(sol.input_price_per_million, 8.0);
        assert_eq!(sol.cached_input_price_per_million, 0.8);
        assert_eq!(sol.output_price_per_million, 10.0);
        assert_eq!(sol.display_name, "Future Official Sol");
        assert!(sol.is_official);
        assert_eq!(sol.note.as_deref(), Some("future-official"));
        assert_eq!(sol.source_url, "https://example.com/future");
        assert_eq!(sol.updated_at, "future-official-sol");
    }

    #[test]
    fn official_refresh_restores_repaired_gpt_56_provenance() {
        let conn = Connection::open_in_memory().expect("open database");
        crate::database::init_db(&conn).expect("init database");
        conn.execute(
            "
            INSERT INTO pricing_catalog (
                model_id, display_name, input_price_per_million, cached_input_price_per_million,
                output_price_per_million, effective_model_id, is_official, note, source_url, updated_at
            )
            VALUES ('gpt-5.6-sol', 'Old Official Sol', 5.0, 0.5, 6.25,
                    'gpt-5.6-sol', 1, 'old-official', 'https://example.com/old', 'old-official')
            ",
            [],
        )
        .expect("insert malformed official Sol pricing");

        let repaired = seed_pricing_catalog(&conn).expect("repair malformed pricing");
        assert!(repaired
            .iter()
            .find(|entry| entry.model_id == "gpt-5.6-sol")
            .is_some_and(|entry| !entry.is_official));

        let official_entries =
            parse_official_pricing_catalog(&complete_standard_fixture_with_gpt56_rows())
                .expect("parse official pricing");
        upsert_pricing_entries(&conn, &official_entries, PricingUpsertMode::Overwrite)
            .expect("write refreshed official pricing");
        let catalog = seed_pricing_catalog(&conn)
            .expect("seed refreshed pricing")
            .into_iter()
            .map(|entry| (entry.model_id.clone(), entry))
            .collect::<HashMap<_, _>>();
        let sol = &catalog["gpt-5.6-sol"];

        assert!(sol.is_official);
        assert_eq!(sol.output_price_per_million, 30.0);
        assert_eq!(sol.source_url, OPENAI_API_PRICING_URL);
        assert_eq!(
            sol.note.as_deref(),
            Some("OpenAI API Standard short-context pricing.")
        );
    }

    #[test]
    fn seed_preserves_correct_official_gpt_56_prices() {
        let conn = Connection::open_in_memory().expect("open database");
        crate::database::init_db(&conn).expect("init database");
        conn.execute(
            "
            INSERT INTO pricing_catalog (
                model_id, display_name, input_price_per_million, cached_input_price_per_million,
                output_price_per_million, effective_model_id, is_official, note, source_url, updated_at
            )
            VALUES ('gpt-5.6-terra', 'Official Terra', 2.5, 0.25, 15.0,
                    'gpt-5.6-terra', 1, 'official', 'https://example.com', 'official-terra')
            ",
            [],
        )
        .expect("insert correct Terra pricing");

        let catalog = seed_pricing_catalog(&conn)
            .expect("seed pricing")
            .into_iter()
            .map(|entry| (entry.model_id.clone(), entry))
            .collect::<HashMap<_, _>>();

        assert_eq!(catalog["gpt-5.6-terra"].output_price_per_million, 15.0);
        assert_eq!(catalog["gpt-5.6-terra"].display_name, "Official Terra");
        assert_eq!(catalog["gpt-5.6-terra"].updated_at, "official-terra");
        assert!(catalog["gpt-5.6-terra"].is_official);
    }

    fn complete_standard_fixture_with_gpt56_rows() -> String {
        concat!(
            "<astro-island component-export=\"TextTokenPricingTables\" props=\"{&quot;tier&quot;:[0,&quot;standard&quot;],&quot;rows&quot;:[1,[[1,[[0,&quot;gpt-5.6-sol&quot;],[0,5],[0,0.5],[0,6.25],[0,30]]],[1,[[0,&quot;gpt-5.6-terra&quot;],[0,2.5],[0,0.25],[0,3.125],[0,15]]],[1,[[0,&quot;gpt-5.6-luna&quot;],[0,1],[0,0.1],[0,1.25],[0,6]]],[1,[[0,&quot;gpt-5.5 (&lt;272K context length)&quot;],[0,5],[0,0.5],[0,30]]],[1,[[0,&quot;gpt-5.4 (&lt;272K context length)&quot;],[0,2.5],[0,0.25],[0,15]]],[1,[[0,&quot;gpt-5.4-mini&quot;],[0,0.75],[0,0.075],[0,4.5]]],[1,[[0,&quot;gpt-5.4-nano&quot;],[0,0.2],[0,0.02],[0,1.25]]]]]}\"></astro-island>",
            "<astro-island component-export=\"GroupedPricingTable\" props=\"{&quot;groups&quot;:[1,[[0,{&quot;model&quot;:[0,&quot;Codex&quot;],&quot;rows&quot;:[1,[[1,[[0,&quot;gpt-5.3-codex&quot;],[0,1.75],[0,0.175],[0,14]]]]]}]]]}\"></astro-island>"
        ).to_string()
    }

    #[test]
    fn parses_official_standard_short_context_pricing_rows() {
        let html = concat!(
            "<astro-island component-export=\"TextTokenPricingTables\" props=\"{&quot;tier&quot;:[0,&quot;standard&quot;],&quot;rows&quot;:[1,[[1,[[0,&quot;gpt-5.6-sol&quot;],[0,5],[0,0.5],[0,6.25],[0,30]]],[1,[[0,&quot;gpt-5.6-terra&quot;],[0,2.5],[0,0.25],[0,3.125],[0,15]]],[1,[[0,&quot;gpt-5.6-luna&quot;],[0,1],[0,0.1],[0,1.25],[0,6]]],[1,[[0,&quot;gpt-5.5 (&lt;272K context length)&quot;],[0,5],[0,0.5],[0,30]]],[1,[[0,&quot;gpt-5.5 (&gt;=272K context length)&quot;],[0,10],[0,1],[0,45]]],[1,[[0,&quot;gpt-5.4 (&lt;272K context length)&quot;],[0,2.5],[0,0.25],[0,15]]],[1,[[0,&quot;gpt-5.4-mini&quot;],[0,0.75],[0,0.075],[0,4.5]]],[1,[[0,&quot;gpt-5.4-nano&quot;],[0,0.2],[0,0.02],[0,1.25]]]]]}\"></astro-island>",
            "<astro-island component-export=\"GroupedPricingTable\" props=\"{&quot;groups&quot;:[1,[[0,{&quot;model&quot;:[0,&quot;Codex&quot;],&quot;rows&quot;:[1,[[1,[[0,&quot;gpt-5.3-codex&quot;],[0,1.75],[0,0.175],[0,14]]]]]}]]]}\"></astro-island>"
        );

        let entries = parse_official_pricing_catalog(html).expect("parse official pricing");
        let catalog = entries
            .into_iter()
            .map(|entry| (entry.model_id.clone(), entry))
            .collect::<HashMap<_, _>>();

        let gpt55 = catalog.get("gpt-5.5").expect("gpt-5.5");
        assert_eq!(gpt55.input_price_per_million, 5.0);
        assert_eq!(gpt55.cached_input_price_per_million, 0.5);
        assert_eq!(gpt55.output_price_per_million, 30.0);
        assert!(gpt55.is_official);

        let codex = catalog.get("gpt-5.3-codex").expect("gpt-5.3-codex");
        assert_eq!(codex.input_price_per_million, 1.75);
        assert_eq!(codex.cached_input_price_per_million, 0.175);
        assert_eq!(codex.output_price_per_million, 14.0);
    }

    #[test]
    fn prefers_standard_short_context_when_pricing_blocks_are_reordered() {
        let html = concat!(
            "<astro-island component-export=\"TextTokenPricingTables\" props=\"{&quot;tier&quot;:[0,&quot;standard&quot;],&quot;rows&quot;:[1,[[1,[[0,&quot;gpt-5.6-sol&quot;],[0,5],[0,0.5],[0,6.25],[0,30]]],[1,[[0,&quot;gpt-5.6-terra&quot;],[0,2.5],[0,0.25],[0,3.125],[0,15]]],[1,[[0,&quot;gpt-5.6-luna&quot;],[0,1],[0,0.1],[0,1.25],[0,6]]],[1,[[0,&quot;gpt-5.5 (&gt;=272K context length)&quot;],[0,10],[0,1],[0,45]]],[1,[[0,&quot;gpt-5.5 (&lt;272K context length)&quot;],[0,5],[0,0.5],[0,30]]],[1,[[0,&quot;gpt-5.4 (&lt;272K context length)&quot;],[0,2.5],[0,0.25],[0,15]]],[1,[[0,&quot;gpt-5.4-mini&quot;],[0,0.75],[0,0.075],[0,4.5]]],[1,[[0,&quot;gpt-5.4-nano&quot;],[0,0.2],[0,0.02],[0,1.25]]]]]}\"></astro-island>",
            "<div data-content-switcher-pane=\"true\" data-value=\"priority\" hidden><div class=\"hidden\">Priority</div><astro-island component-export=\"GroupedPricingTable\" props=\"{&quot;groups&quot;:[1,[[0,{&quot;model&quot;:[0,&quot;Codex&quot;],&quot;rows&quot;:[1,[[1,[[0,&quot;gpt-5.3-codex&quot;],[0,3.5],[0,0.35],[0,28]]]]]}]]]}\"></astro-island></div>",
            "<div data-content-switcher-pane=\"true\" data-value=\"standard\"><div class=\"hidden\">Standard</div><astro-island component-export=\"GroupedPricingTable\" props=\"{&quot;groups&quot;:[1,[[0,{&quot;model&quot;:[0,&quot;Codex&quot;],&quot;rows&quot;:[1,[[1,[[0,&quot;gpt-5.3-codex&quot;],[0,1.75],[0,0.175],[0,14]]]]]}]]]}\"></astro-island></div>"
        );

        let entries = parse_official_pricing_catalog(html).expect("parse official pricing");
        let catalog = entries
            .into_iter()
            .map(|entry| (entry.model_id.clone(), entry))
            .collect::<HashMap<_, _>>();

        let gpt55 = catalog.get("gpt-5.5").expect("gpt-5.5");
        assert_eq!(gpt55.input_price_per_million, 5.0);
        assert_eq!(gpt55.cached_input_price_per_million, 0.5);
        assert_eq!(gpt55.output_price_per_million, 30.0);

        let codex = catalog.get("gpt-5.3-codex").expect("gpt-5.3-codex");
        assert_eq!(codex.input_price_per_million, 1.75);
        assert_eq!(codex.cached_input_price_per_million, 0.175);
        assert_eq!(codex.output_price_per_million, 14.0);
    }
}
