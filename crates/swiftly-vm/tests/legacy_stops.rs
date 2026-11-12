//! `Kern.stoppsProcess` on the core: a stop records position and watched state on the download, a sent one clears the
//! pending catch-up report of the same title, a finished episode with a successor marks the next one due.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use serde_json::{Value, json};
use swiftly_downloads::{Art, DownloadItem, DownloadState};
use swiftly_vm::{LegacyStop, stops_process};

fn episode(id: &str, number: i64, state: DownloadState) -> DownloadItem {
    let mut p = DownloadItem::new(id, "u1", Art::Episode, format!("E{number}"), 1_000, 10.0);
    p.state = state;
    p.series_identifier = Some("s1".into());
    p.series = Some("Show".into());
    p.season = Some(1);
    p.episode = Some(number);
    p.runtime_ticks = Some(1_000);
    p
}

fn stop(id: &str, ticks: i64, sent: bool) -> LegacyStop {
    LegacyStop {
        item_id: id.into(),
        account: "u1".into(),
        ticks,
        moment: 50.0,
        sent,
    }
}

fn list() -> String {
    serde_json::to_string(&[
        episode("e1", 1, DownloadState::Done),
        episode("e2", 2, DownloadState::Done),
        episode("x", 3, DownloadState::Done),
    ])
    .unwrap()
}

#[test]
fn records_position_and_marks_only_changed() {
    let out: Value = serde_json::from_str(&stops_process(
        "[]",
        &list(),
        false,
        &[stop("e1", 500, false)],
    ))
    .unwrap();
    let posten = out["posten"].as_array().unwrap();
    assert_eq!(posten.len(), 1);
    assert_eq!(posten[0]["id"], "e1");
    assert_eq!(out["ablage"], "[]");
}

#[test]
fn finished_episode_with_successor_is_due_only_with_the_setting() {
    let with: Value = serde_json::from_str(&stops_process(
        "[]",
        &list(),
        true,
        &[stop("e1", 950, false)],
    ))
    .unwrap();
    let a: DownloadItem = serde_json::from_value(with["posten"][0].clone()).unwrap();
    assert!(a.watched);
    assert_eq!(a.next_pending, Some(true));
    let without: Value = serde_json::from_str(&stops_process(
        "[]",
        &list(),
        false,
        &[stop("e1", 950, false)],
    ))
    .unwrap();
    let b: DownloadItem = serde_json::from_value(without["posten"][0].clone()).unwrap();
    assert_eq!(b.next_pending, None);
}

#[test]
fn a_sent_stop_clears_the_pending_report_of_that_title() {
    let store = json!([{"itemID": "e1", "konto": "u1", "ticks": 1, "wann": 1.0}, {"itemID": "e2", "konto": "u1", "ticks": 2, "wann": 1.0}]).to_string();
    let out: Value = serde_json::from_str(&stops_process(
        &store,
        "[]",
        false,
        &[stop("e1", 10, true), stop("unknown", 10, false)],
    ))
    .unwrap();
    let kept: Value = serde_json::from_str(out["ablage"].as_str().unwrap()).unwrap();
    assert_eq!(kept.as_array().unwrap().len(), 1);
    assert_eq!(kept[0]["itemID"], "e2");
    assert!(out["posten"].as_array().unwrap().is_empty());
}
