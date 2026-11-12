//! Differential oracle tests: Rust output must equal the recorded output of the real Swift code.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_rules::natural_order::{NaturalCollator, NaturalOrder};

fn s(v: &Value) -> &str {
    v.as_str().unwrap_or("")
}

#[test]
fn natural_order() {
    assert_equal("natural_order", |case| {
        let collator = NaturalCollator::new(s(&case["locale"])).expect("collator");
        let titles: Vec<(String, Option<String>)> = case["titles"]
            .as_array()
            .expect("titles")
            .iter()
            .map(|t| {
                (
                    s(&t["name"]).to_owned(),
                    t["sort"].as_str().map(str::to_owned),
                )
            })
            .collect();
        let group: Vec<i32> = titles
            .iter()
            .map(|t| NaturalOrder::group(&t.0, t.1.as_deref()))
            .collect();
        let key: Vec<String> = titles
            .iter()
            .map(|t| NaturalOrder::key(&t.0, t.1.as_deref()))
            .collect();
        let idx: Vec<(usize, String, Option<String>)> = titles
            .iter()
            .enumerate()
            .map(|(i, t)| (i, t.0.clone(), t.1.clone()))
            .collect();
        let sorted: Vec<usize> =
            NaturalOrder::sorted(idx, &collator, |t| (t.1.as_str(), t.2.as_deref()))
                .into_iter()
                .map(|t| t.0)
                .collect();
        json!({ "group": group, "key": key, "sorted": sorted })
    });
}
