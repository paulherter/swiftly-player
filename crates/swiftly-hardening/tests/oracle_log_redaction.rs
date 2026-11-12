//! Differential oracle, `LogRedaction.text` (Tools/Oracle, Domain_LogRedaction.swift): credentials in free text
//! blacked out by the real Swift regular expressions and by `swiftly_support::log_ring::redact`.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::json;
use swiftly_hardening::oracle::assert_equal;

#[test]
fn log_redaction() {
    assert_equal(
        "log_redaction",
        |c| json!({"s": swiftly_uniffi::log_redact(c["text"].as_str().unwrap_or("").to_owned())}),
    );
}
