use rusqlite::{params, Connection};

use crate::models::SubscriptionProfile;

use super::now_utc_string;

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
