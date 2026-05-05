use chrono::{Datelike, Local, Months, NaiveDate};
use rusqlite::{params, Connection, OptionalExtension};

use crate::models::{SubscriptionProfile, SubscriptionRecord, SubscriptionRecordInput};

use super::now_utc_string;

const BILLING_MODE_ONE_TIME: &str = "one_time";
const BILLING_MODE_MONTHLY_RECURRING: &str = "monthly_recurring";

pub fn canonical_subscription_currency() -> &'static str {
    "USD"
}

pub fn get_subscription_profile(conn: &Connection) -> rusqlite::Result<SubscriptionProfile> {
    conn.query_row(
        "
    SELECT plan_type, currency, monthly_price, billing_anchor_day, updated_at
    FROM subscription_profile
    WHERE singleton_id = 1
    ",
        [],
        |row| {
            Ok(SubscriptionProfile {
                plan_type: row.get(0)?,
                currency: {
                    let _: String = row.get(1)?;
                    canonical_subscription_currency().to_string()
                },
                monthly_price: row.get(2)?,
                billing_anchor_day: row.get(3)?,
                updated_at: row.get(4)?,
            })
        },
    )
}

pub fn save_subscription_profile(
    conn: &Connection,
    profile: &SubscriptionProfile,
) -> rusqlite::Result<SubscriptionProfile> {
    let updated_at = now_utc_string();
    conn.execute(
        "
    INSERT INTO subscription_profile (
      singleton_id, plan_type, currency, monthly_price, billing_anchor_day, updated_at
    )
    VALUES (1, ?1, ?2, ?3, ?4, ?5)
    ON CONFLICT(singleton_id) DO UPDATE SET
      plan_type = excluded.plan_type,
      currency = excluded.currency,
      monthly_price = excluded.monthly_price,
      billing_anchor_day = excluded.billing_anchor_day,
      updated_at = excluded.updated_at
    ",
        params![
            profile.plan_type,
            canonical_subscription_currency(),
            profile.monthly_price.max(0.0),
            profile.billing_anchor_day.clamp(1, 28),
            updated_at,
        ],
    )?;
    get_subscription_profile(conn)
}

pub fn list_subscription_records(conn: &Connection) -> rusqlite::Result<Vec<SubscriptionRecord>> {
    let mut stmt = conn.prepare(
        "
    SELECT id, paid_at, service_start, service_end, amount_usd, billing_mode, plan_type, note, created_at, updated_at
    FROM subscription_records
    ORDER BY service_start DESC, paid_at DESC, id DESC
    ",
    )?;

    let records = stmt
        .query_map([], subscription_record_from_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(records)
}

pub fn create_subscription_record(
    conn: &Connection,
    input: &SubscriptionRecordInput,
) -> Result<SubscriptionRecord, String> {
    let normalized = normalize_subscription_record_input(input)?;
    let now = now_utc_string();
    conn.execute(
        "
      INSERT INTO subscription_records (
        paid_at, service_start, service_end, amount_usd, billing_mode, plan_type, note, created_at, updated_at
      )
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
      ",
        params![
            normalized.paid_at,
            normalized.service_start,
            normalized.service_end,
            normalized.amount_usd,
            normalized.billing_mode,
            normalized.plan_type,
            normalized.note,
            now,
        ],
    )
    .map_err(|error| error.to_string())?;

    get_subscription_record(conn, conn.last_insert_rowid())
}

pub fn update_subscription_record(
    conn: &Connection,
    id: i64,
    input: &SubscriptionRecordInput,
) -> Result<SubscriptionRecord, String> {
    let normalized = normalize_subscription_record_input(input)?;
    let updated_at = now_utc_string();
    let changed = conn
        .execute(
            "
      UPDATE subscription_records
      SET
        paid_at = ?1,
        service_start = ?2,
        service_end = ?3,
        amount_usd = ?4,
        billing_mode = ?5,
        plan_type = ?6,
        note = ?7,
        updated_at = ?8
      WHERE id = ?9
      ",
            params![
                normalized.paid_at,
                normalized.service_start,
                normalized.service_end,
                normalized.amount_usd,
                normalized.billing_mode,
                normalized.plan_type,
                normalized.note,
                updated_at,
                id,
            ],
        )
        .map_err(|error| error.to_string())?;

    if changed == 0 {
        return Err(format!("Subscription record {id} was not found."));
    }

    get_subscription_record(conn, id)
}

pub fn delete_subscription_record(conn: &Connection, id: i64) -> Result<bool, String> {
    let changed = conn
        .execute(
            "DELETE FROM subscription_records WHERE id = ?1",
            params![id],
        )
        .map_err(|error| error.to_string())?;
    Ok(changed > 0)
}

fn get_subscription_record(conn: &Connection, id: i64) -> Result<SubscriptionRecord, String> {
    conn.query_row(
        "
      SELECT id, paid_at, service_start, service_end, amount_usd, billing_mode, plan_type, note, created_at, updated_at
      FROM subscription_records
      WHERE id = ?1
      ",
        params![id],
        subscription_record_from_row,
    )
    .map_err(|error| error.to_string())
}

fn subscription_record_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<SubscriptionRecord> {
    Ok(SubscriptionRecord {
        id: row.get(0)?,
        paid_at: row.get(1)?,
        service_start: row.get(2)?,
        service_end: row.get(3)?,
        amount_usd: row.get(4)?,
        billing_mode: row.get(5)?,
        plan_type: row.get(6)?,
        note: row.get(7)?,
        created_at: row.get(8)?,
        updated_at: row.get(9)?,
    })
}

struct NormalizedSubscriptionRecordInput {
    paid_at: String,
    service_start: String,
    service_end: String,
    amount_usd: f64,
    billing_mode: String,
    plan_type: String,
    note: Option<String>,
}

fn normalize_subscription_record_input(
    input: &SubscriptionRecordInput,
) -> Result<NormalizedSubscriptionRecordInput, String> {
    let paid_at = normalize_date_field("paidAt", &input.paid_at)?;
    let service_start = normalize_date_field("serviceStart", &input.service_start)?;
    let service_end = normalize_date_field("serviceEnd", &input.service_end)?;
    let start_date = parse_date_field("serviceStart", &service_start)?;
    let end_date = parse_date_field("serviceEnd", &service_end)?;
    if end_date <= start_date {
        return Err("serviceEnd must be later than serviceStart.".to_string());
    }
    if !input.amount_usd.is_finite() {
        return Err("amountUsd must be a finite number.".to_string());
    }
    if input.amount_usd <= 0.0 {
        return Err("amountUsd must be greater than 0.".to_string());
    }

    let plan_type = input.plan_type.trim();
    let billing_mode = normalize_billing_mode(&input.billing_mode)?;
    let note = input
        .note
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.chars().take(500).collect::<String>());

    Ok(NormalizedSubscriptionRecordInput {
        paid_at,
        service_start,
        service_end,
        amount_usd: input.amount_usd,
        billing_mode,
        plan_type: if plan_type.is_empty() {
            "unknown".to_string()
        } else {
            plan_type.chars().take(64).collect()
        },
        note,
    })
}

fn normalize_date_field(field_name: &str, value: &str) -> Result<String, String> {
    let trimmed = value.trim();
    let parsed = parse_date_field(field_name, trimmed)?;
    Ok(parsed.format("%Y-%m-%d").to_string())
}

fn parse_date_field(field_name: &str, value: &str) -> Result<NaiveDate, String> {
    let parts = value.split('-').collect::<Vec<_>>();
    if parts.len() != 3 {
        return Err(format!("{field_name} must use YYYY-MM-DD format."));
    }
    if parts[0].len() != 4 || parts[1].is_empty() || parts[2].is_empty() {
        return Err(format!("{field_name} must use YYYY-MM-DD format."));
    }
    let year = parts[0]
        .parse::<i32>()
        .map_err(|_| format!("{field_name} must use YYYY-MM-DD format."))?;
    let month = parts[1]
        .parse::<u32>()
        .map_err(|_| format!("{field_name} must use YYYY-MM-DD format."))?;
    let day = parts[2]
        .parse::<u32>()
        .map_err(|_| format!("{field_name} must use YYYY-MM-DD format."))?;
    NaiveDate::from_ymd_opt(year, month, day)
        .ok_or_else(|| format!("{field_name} must use YYYY-MM-DD format."))
}

fn normalize_billing_mode(value: &str) -> Result<String, String> {
    match value.trim() {
        BILLING_MODE_ONE_TIME => Ok(BILLING_MODE_ONE_TIME.to_string()),
        BILLING_MODE_MONTHLY_RECURRING => Ok(BILLING_MODE_MONTHLY_RECURRING.to_string()),
        _ => Err("billingMode must be one_time or monthly_recurring.".to_string()),
    }
}

pub(super) fn ensure_subscription_records_schema(conn: &Connection) -> rusqlite::Result<()> {
    let mut stmt = conn.prepare("PRAGMA table_info(subscription_records)")?;
    let column_names = stmt
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    if !column_names.iter().any(|name| name == "billing_mode") {
        conn.execute(
            "
            ALTER TABLE subscription_records
            ADD COLUMN billing_mode TEXT NOT NULL DEFAULT 'one_time'
            ",
            [],
        )?;
    }

    Ok(())
}

pub(super) fn migrate_subscription_profile_to_subscription_record(
    conn: &Connection,
    had_subscription_records_table: bool,
) -> rusqlite::Result<()> {
    if had_subscription_records_table {
        return Ok(());
    }

    let existing_count = conn.query_row(
        "SELECT COUNT(*) FROM subscription_records",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    if existing_count > 0 {
        return Ok(());
    }

    let profile = conn
        .query_row(
            "
            SELECT plan_type, monthly_price, billing_anchor_day
            FROM subscription_profile
            WHERE singleton_id = 1
            ",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, f64>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        )
        .optional()?;
    let Some((plan_type, monthly_price, billing_anchor_day)) = profile else {
        return Ok(());
    };
    if monthly_price <= 0.0 || !monthly_price.is_finite() {
        return Ok(());
    }

    let today = Local::now().date_naive();
    let service_start = billing_cycle_start(today, billing_anchor_day as u32);
    let service_end = add_months_clamped(service_start, 1);
    let service_start = service_start.format("%Y-%m-%d").to_string();
    let service_end = service_end.format("%Y-%m-%d").to_string();
    let now = now_utc_string();

    conn.execute(
        "
        INSERT INTO subscription_records (
          paid_at, service_start, service_end, amount_usd, billing_mode, plan_type, note, created_at, updated_at
        )
        VALUES (?1, ?1, ?2, ?3, ?4, ?5, NULL, ?6, ?6)
        ",
        params![
            service_start,
            service_end,
            monthly_price,
            BILLING_MODE_MONTHLY_RECURRING,
            if plan_type.trim().is_empty() {
                "plus"
            } else {
                plan_type.trim()
            },
            now,
        ],
    )?;

    Ok(())
}

fn billing_cycle_start(anchor_date: NaiveDate, billing_anchor_day: u32) -> NaiveDate {
    let this_month_anchor = anchored_date(anchor_date.year(), anchor_date.month(), billing_anchor_day);
    if anchor_date >= this_month_anchor {
        this_month_anchor
    } else {
        add_months_clamped(this_month_anchor, -1)
    }
}

fn add_months_clamped(date: NaiveDate, months: i32) -> NaiveDate {
    if months >= 0 {
        date.checked_add_months(Months::new(months as u32))
            .expect("valid positive month offset")
    } else {
        date.checked_sub_months(Months::new(months.unsigned_abs()))
            .expect("valid negative month offset")
    }
}

fn anchored_date(year: i32, month: u32, billing_anchor_day: u32) -> NaiveDate {
    let day = billing_anchor_day
        .clamp(1, 31)
        .min(days_in_month(year, month));
    NaiveDate::from_ymd_opt(year, month, day).expect("valid anchored date")
}

fn days_in_month(year: i32, month: u32) -> u32 {
    let (next_year, next_month) = if month == 12 {
        (year + 1, 1)
    } else {
        (year, month + 1)
    };
    let first_next_month =
        NaiveDate::from_ymd_opt(next_year, next_month, 1).expect("valid first day of next month");
    first_next_month.pred_opt().expect("valid previous day").day()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::init_db;

    #[test]
    fn subscription_records_round_trip() {
        let conn = Connection::open_in_memory().expect("open in-memory database");

        init_db(&conn).expect("init database");
        let created = create_subscription_record(
            &conn,
            &SubscriptionRecordInput {
                paid_at: "2026-04-16".to_string(),
                service_start: "2026-04-16".to_string(),
                service_end: "2026-05-16".to_string(),
                amount_usd: 19.99,
                billing_mode: "monthly_recurring".to_string(),
                plan_type: "plus".to_string(),
                note: Some("user@example.com".to_string()),
            },
        )
        .expect("create record");

        assert_eq!(created.plan_type, "plus");
        assert_eq!(created.note.as_deref(), Some("user@example.com"));

        let updated = update_subscription_record(
            &conn,
            created.id,
            &SubscriptionRecordInput {
                paid_at: "2026-04-17".to_string(),
                service_start: "2026-04-17".to_string(),
                service_end: "2026-05-17".to_string(),
                amount_usd: 100.0,
                billing_mode: "one_time".to_string(),
                plan_type: "pro_x5".to_string(),
                note: Some("updated@example.com".to_string()),
            },
        )
        .expect("update record");

        assert_eq!(updated.amount_usd, 100.0);
        assert_eq!(updated.plan_type, "pro_x5");
        assert_eq!(list_subscription_records(&conn).expect("list records").len(), 2);
        assert!(delete_subscription_record(&conn, created.id).expect("delete record"));
        assert_eq!(
            list_subscription_records(&conn)
                .expect("list after delete")
                .len(),
            1
        );
    }

    #[test]
    fn subscription_record_rejects_invalid_dates() {
        let conn = Connection::open_in_memory().expect("open in-memory database");

        init_db(&conn).expect("init database");
        let error = create_subscription_record(
            &conn,
            &SubscriptionRecordInput {
                paid_at: "2026-04-16".to_string(),
                service_start: "2026-05-16".to_string(),
                service_end: "2026-04-16".to_string(),
                amount_usd: 19.99,
                billing_mode: "one_time".to_string(),
                plan_type: "plus".to_string(),
                note: None,
            },
        )
        .expect_err("reject invalid date range");

        assert!(error.contains("serviceEnd"));
    }

    #[test]
    fn subscription_record_canonicalizes_dates_and_rejects_invalid_amounts() {
        let conn = Connection::open_in_memory().expect("open in-memory database");

        init_db(&conn).expect("init database");
        let created = create_subscription_record(
            &conn,
            &SubscriptionRecordInput {
                paid_at: "2026-4-6".to_string(),
                service_start: "2026-4-6".to_string(),
                service_end: "2026-5-6".to_string(),
                amount_usd: 19.99,
                billing_mode: "monthly_recurring".to_string(),
                plan_type: "plus".to_string(),
                note: None,
            },
        )
        .expect("create record");

        assert_eq!(created.paid_at, "2026-04-06");
        assert_eq!(created.service_start, "2026-04-06");
        assert_eq!(created.service_end, "2026-05-06");
        assert_eq!(created.billing_mode, "monthly_recurring");

        let error = create_subscription_record(
            &conn,
            &SubscriptionRecordInput {
                paid_at: "2026-04-06".to_string(),
                service_start: "2026-04-06".to_string(),
                service_end: "2026-05-06".to_string(),
                amount_usd: -1.0,
                billing_mode: "one_time".to_string(),
                plan_type: "plus".to_string(),
                note: None,
            },
        )
        .expect_err("reject negative amount");

        assert!(error.contains("amountUsd"));
    }

    #[test]
    fn init_db_migrates_profile_to_monthly_recurring_record() {
        let conn = Connection::open_in_memory().expect("open in-memory database");

        init_db(&conn).expect("init database");
        let records = list_subscription_records(&conn).expect("list records");

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].billing_mode, "monthly_recurring");
        assert_eq!(records[0].amount_usd, 20.0);
        assert_eq!(records[0].plan_type, "plus");
    }
}
