//! The home rails against the golden the real Swift `HomeLoader` produced from the same recorded
//! server answers (`HomeDifferentialTests.swift`).
#![allow(clippy::expect_used, clippy::unwrap_used)]

mod common;

use futures_executor::block_on;
use serde_json::{Value, json};
use swiftly_library::{HomeLoader, LoadRequest};
use swiftly_model::Item;

fn ids(v: &Option<Vec<Item>>) -> Vec<String> {
    v.iter().flatten().map(|i| i.id.clone()).collect()
}

#[test]
fn rails_equal_the_swift_golden() {
    let golden: Value = serde_json::from_slice(
        &std::fs::read(common::dir().join("golden/home_diff/swift_expected.json")).expect("golden"),
    )
    .expect("json");
    for mode in ["ok", "ids_fail", "ancestors_fail", "views_fail"] {
        let c = common::client(common::Recorded::new(mode));
        let home = block_on(HomeLoader::load(&c, &LoadRequest::new(false)));
        let got = json!({
            "continue": ids(&home.continue_watching),
            "next": ids(&home.next_episode),
            "recent": ids(&home.recent),
            "disrupted": home.disrupted,
        });
        assert_eq!(got, golden[mode], "mode {mode}");
    }
}
