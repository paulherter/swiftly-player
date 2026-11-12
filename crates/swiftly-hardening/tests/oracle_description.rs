//! Differential oracle, `Description.readable`, `Item.description`, `Item.daysDate`, `Item.tmdbId`
//! (Tools/Oracle, Domain_Description.swift): the Rust output must equal the real Swift output.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_rules::description;

#[test]
fn description() {
    assert_equal("description", |c| {
        if c["op"] == "readable" {
            return json!({"s": description::readable(c["text"].as_str().unwrap_or(""))});
        }
        let days = description::days_date(c["premiere"].as_str())
            .map_or(Value::Null, |(y, m, d)| json!([y, m, d]));
        json!({
            "d": description::description(c["overview"].as_str()),
            "days": days,
            "tmdb": description::tmdb_id(c["tmdb"].as_str()),
        })
    });
}
