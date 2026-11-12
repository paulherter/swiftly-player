//! Differential oracle, group C text: PluralCategory, VersionComparison, TimestampFormat.
//! Swift side: Tools/Oracle/Sources/oracle/Domain_TextC.swift.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;

#[test]
fn plural_category() {
    assert_equal("plural_category", |c| {
        let n = c["n"].as_i64().unwrap();
        json!(swiftly_l10n::plural::category(c["lang"].as_str().unwrap(), n).as_str())
    });
}

#[test]
fn version_compare() {
    assert_equal("version_compare", |c: &Value| {
        let s = |k: &str| c[k].as_str().unwrap().to_owned();
        json!({
            "newer": swiftly_l10n::version_number::newer(
                &s("there"), &s("here"), c["build_there"].as_i64(), c["build_here"].as_i64().unwrap()),
            "build": swiftly_l10n::version_number::build_number_from_text(&s("text")),
        })
    });
}

#[test]
fn timestamp() {
    assert_equal("timestamp", |c| {
        json!(swiftly_model::parse_timestamp(c["text"].as_str().unwrap()))
    });
}
