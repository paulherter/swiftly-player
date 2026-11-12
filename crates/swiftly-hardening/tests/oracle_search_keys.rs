//! Differential oracle, `SearchKeys`, `SearchGroups`, `SearchScreen` (Tools/Oracle, Domain_Description.swift):
//! the Rust output (`swiftly_vm::legacy_search` over `swiftly_rules::search_keys`) must equal the real Swift.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_vm::{
    search_key_delete, search_key_hardware, search_key_rows, search_key_space,
    search_key_space_fits, search_key_typed, search_screen_state, search_titles_shown,
};

#[test]
fn search_keys() {
    assert_equal("search_keys", |c| {
        let term = c["term"].as_str().unwrap_or("");
        let n = |k: &str| c[k].as_i64().unwrap_or(0);
        match c["op"].as_str().unwrap() {
            "rows" => {
                serde_json::from_str(&search_key_rows(c["speech"].as_bool().unwrap_or(false)))
                    .unwrap()
            }
            "typed" => json!(search_key_typed(c["c"].as_str().unwrap_or(""), term)),
            "space_fits" => json!(search_key_space_fits(term)),
            "with_space" => json!(search_key_space(term)),
            "delete" => json!(search_key_delete(term)),
            "hardware" => json!(search_key_hardware(c["text"].as_str().unwrap_or(""), term)),
            "titles" => json!(search_titles_shown(n("s"), n("f"), n("r"))),
            _ => {
                let b = |k: &str| c[k].as_bool().unwrap_or(false);
                Value::String(
                    search_screen_state(
                        term,
                        n("history"),
                        b("hits"),
                        b("answered"),
                        b("disrupted"),
                        b("waited"),
                    )
                    .to_owned(),
                )
            }
        }
    });
}
