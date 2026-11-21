//! The thin line inside the Play button needs `fortschritt` in the title answer. A server that sends the resume
//! position and the runtime but no `PlayedPercentage` (the media fixture, simple proxies) must still get it.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;

use common::account;
use common::script::{Script, host};
use swiftly_vm::LegacyDetail;

fn title_answer(user_data: serde_json::Value) -> serde_json::Value {
    let item = serde_json::json!({
        "Id": "m1", "Name": "Resume film", "Type": "Movie", "RunTimeTicks": 1_500_000_000_i64,
        "UserData": user_data,
    })
    .to_string();
    let net = Script::new(move |_| Some(item.clone()));
    let detail = LegacyDetail::new(&Arc::clone(&net), &host(), &account("TOKEN-A")).unwrap();
    let answer = futures_executor::block_on(detail.title("m1")).unwrap();
    serde_json::from_str(&answer).unwrap()
}

#[test]
fn a_started_title_without_a_server_percentage_still_has_its_progress() {
    let t = title_answer(
        serde_json::json!({"PlaybackPositionTicks": 800_000_000_i64, "Played": false}),
    );
    let p = t["fortschritt"]
        .as_f64()
        .expect("progress of the resume point");
    assert!((p - 800.0 / 1500.0).abs() < 1e-9, "{p}");
}

#[test]
fn the_servers_own_percentage_wins_and_an_unstarted_title_has_none() {
    let t = title_answer(
        serde_json::json!({"PlaybackPositionTicks": 800_000_000_i64, "PlayedPercentage": 25.0}),
    );
    assert!((t["fortschritt"].as_f64().unwrap() - 0.25).abs() < 1e-9);
    let t = title_answer(serde_json::json!({"PlaybackPositionTicks": 0, "Played": false}));
    assert!(
        t.get("fortschritt").is_none_or(serde_json::Value::is_null),
        "{t}"
    );
}
