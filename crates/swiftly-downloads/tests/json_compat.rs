//! The persisted list must stay readable by (and compatible with) the Swift app.
//!
//! The sample is what Swift's `JSONEncoder().encode([DownloadItem])` writes for an item with
//! every field set, derived from the `CodingKeys` in `Downloads.swift:41-69`: keys in
//! declaration order, optionals present because they are set, dates as seconds since 2001-01-01
//! (the default `deferredToDate` strategy), `Segment` as `Type`/`StartTicks`/`EndTicks`, quality
//! and state as raw values. Absent optionals are omitted (synthesised `encodeIfPresent`).

#![allow(clippy::expect_used)]

mod common;

use serde_json::{Value, json};
use swiftly_downloads::{
    Art, DownloadItem, DownloadQuality, DownloadState, decode_list, encode_list, load_list,
    merge_for_write,
};

/// 2025-01-01T00:00:00Z as Swift encodes it: seconds since 2001-01-01.
const CREATED_REF: f64 = 757_382_400.0;
const CREATED_UNIX: f64 = 1_735_689_600.0;

fn full_sample() -> Value {
    json!([{
        "id": "12ab",
        "konto": "u1",
        "art": "folge",
        "titel": "The End",
        "serie": "Fallout",
        "serienId": "S1",
        "staffel": 1,
        "folge": 2,
        "laufzeitTicks": 38_400_000_000_i64,
        "container": "mkv",
        "quelle": "q1",
        "bytes": 2_800_000_000_i64,
        "qualitaet": "hd720",
        "geladen": 1_400_000_000_i64,
        "stand": "angehalten",
        "grund": "Netz weg",
        "gesehen": true,
        "angelegt": 757_382_400.5,
        "nochAufDemServer": false,
        "abschnitte": [
            {"Type": "Intro", "StartTicks": 100_000_000_i64, "EndTicks": 900_000_000_i64},
            {"Type": "Outro", "StartTicks": 37_000_000_000_i64, "EndTicks": 38_400_000_000_i64}
        ],
        "stelleTicks": 1_234_567_890_i64,
        "zuletzt": 757_468_800.25,
        "bildcodec": "h264",
        "tonIndex": 3,
        "tonSprache": "de",
        "ersetzt": "11aa",
        "naechsteOffen": true
    }])
}

/// Numbers compare by value (Swift writes `757382400` where Rust writes `757382400.0`).
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

#[test]
fn full_swift_sample_decodes_every_field() {
    let list = decode_list(full_sample().to_string().as_bytes()).expect("decodes");
    assert_eq!(list.len(), 1);
    let p = &list[0];
    assert_eq!((p.id.as_str(), p.account.as_str()), ("12ab", "u1"));
    assert_eq!(p.art, Art::Episode);
    assert_eq!(p.title, "The End");
    assert_eq!(p.series.as_deref(), Some("Fallout"));
    assert_eq!(p.series_identifier.as_deref(), Some("S1"));
    assert_eq!((p.season, p.episode), (Some(1), Some(2)));
    assert_eq!(p.runtime_ticks, Some(38_400_000_000));
    assert_eq!(p.container.as_deref(), Some("mkv"));
    assert_eq!(p.source.as_deref(), Some("q1"));
    assert_eq!(p.bytes, 2_800_000_000);
    assert_eq!(p.quality, Some(DownloadQuality::Hd720));
    assert_eq!(p.loaded, 1_400_000_000);
    assert_eq!(p.state, DownloadState::Halted);
    assert_eq!(p.reason.as_deref(), Some("Netz weg"));
    assert!(p.watched && !p.still_on_the_server);
    // Reference date 2001 -> Unix 1970.
    assert_eq!(p.created, CREATED_UNIX + 0.5);
    assert_eq!(p.recent, Some(757_468_800.25 + 978_307_200.0));
    let sections = p.sections.as_ref().expect("sections");
    assert_eq!(sections.len(), 2);
    assert_eq!((sections[0].from, sections[0].until), (10.0, 90.0));
    assert_eq!(p.point_ticks, Some(1_234_567_890));
    assert_eq!(p.video_codec.as_deref(), Some("h264"));
    assert_eq!(p.audio_index, Some(3));
    assert_eq!(p.audio_language.as_deref(), Some("de"));
    assert_eq!(p.replaces.as_deref(), Some("11aa"));
    assert_eq!(p.next_pending, Some(true));
}

#[test]
fn encode_writes_exactly_the_swift_keys_and_values() {
    let list = decode_list(full_sample().to_string().as_bytes()).expect("decodes");
    let out: Value = serde_json::from_slice(&encode_list(&list).expect("encodes")).expect("json");
    assert!(same(&out, &full_sample()), "{out}");
    // The 27 CodingKeys, no more, no less.
    let keys: std::collections::BTreeSet<&str> = out[0]
        .as_object()
        .expect("object")
        .keys()
        .map(String::as_str)
        .collect();
    let expected = [
        "id",
        "konto",
        "art",
        "titel",
        "serie",
        "serienId",
        "staffel",
        "folge",
        "laufzeitTicks",
        "container",
        "quelle",
        "bytes",
        "qualitaet",
        "geladen",
        "stand",
        "grund",
        "gesehen",
        "angelegt",
        "nochAufDemServer",
        "abschnitte",
        "stelleTicks",
        "zuletzt",
        "bildcodec",
        "tonIndex",
        "tonSprache",
        "ersetzt",
        "naechsteOffen",
    ];
    assert_eq!(keys.len(), 27);
    assert_eq!(keys, expected.into_iter().collect());
}

#[test]
fn absent_optionals_are_omitted_like_swift() {
    let p = DownloadItem::new("a", "u1", Art::Film, "T", 1, CREATED_UNIX);
    let out: Value = serde_json::from_slice(&encode_list(&[p]).expect("encodes")).expect("json");
    let keys: std::collections::BTreeSet<&str> = out[0]
        .as_object()
        .expect("object")
        .keys()
        .map(String::as_str)
        .collect();
    let expected = [
        "id",
        "konto",
        "art",
        "titel",
        "bytes",
        "geladen",
        "stand",
        "gesehen",
        "angelegt",
        "nochAufDemServer",
    ];
    assert_eq!(keys, expected.into_iter().collect());
    assert_eq!(out[0]["angelegt"].as_f64(), Some(CREATED_REF));
    assert_eq!(out[0]["stand"], "wartet");
    assert_eq!(out[0]["art"], "film");
}

#[test]
fn old_entries_without_the_later_fields_read() {
    // From DownloadRulesTests.formatStays / olderStore / DownloadAudioTests.oldList.
    let raw = r#"[
      {"id":"12ab","konto":"u1","art":"folge","titel":"The End","serie":"Fallout","serienId":"S1",
       "staffel":1,"folge":1,"laufzeitTicks":38400000000,"container":"mkv","quelle":"q1",
       "bytes":2800000000,"geladen":1400000000,"stand":"laedt","gesehen":false,
       "angelegt":757382400,"nochAufDemServer":true},
      {"id":"a","konto":"u1","art":"film","titel":"T","bytes":1,"geladen":0,"stand":"wartet",
       "gesehen":false,"angelegt":757382400,"nochAufDemServer":true},
      {"id":"b","konto":"u1","art":"film","titel":"T","bytes":1,"qualitaet":null,"geladen":0,
       "stand":"fertig","gesehen":false,"angelegt":0,"nochAufDemServer":true}
    ]"#;
    let list = decode_list(raw.as_bytes()).expect("decodes");
    assert_eq!(list.len(), 3);
    assert_eq!(list[0].state, DownloadState::Loads);
    assert_eq!(list[0].share(), Some(0.5));
    assert_eq!(list[0].file_name(), "u1-12ab.mkv");
    assert!(list[1].reason.is_none() && list[1].series.is_none());
    assert_eq!(list[1].file_name(), "u1-a");
    assert_eq!(list[1].created, CREATED_UNIX);
    assert_eq!(list[2].guete(), DownloadQuality::Original);
    // `angelegt: 0` is the reference date itself.
    assert_eq!(list[2].created, 978_307_200.0);
}

#[test]
fn unknown_state_or_quality_is_an_error_like_in_swift() {
    let bad_state = r#"[{"id":"a","konto":"u","art":"film","titel":"T","bytes":1,"geladen":0,"stand":"kaputt","gesehen":false,"angelegt":0,"nochAufDemServer":true}]"#;
    assert!(decode_list(bad_state.as_bytes()).is_err());
    let bad_quality = r#"[{"id":"a","konto":"u","art":"film","titel":"T","bytes":1,"qualitaet":"4k","geladen":0,"stand":"wartet","gesehen":false,"angelegt":0,"nochAufDemServer":true}]"#;
    assert!(decode_list(bad_quality.as_bytes()).is_err());
}

#[test]
fn all_states_and_qualities_round_trip() {
    for state in DownloadState::ALL {
        for q in DownloadQuality::ALL {
            let p = DownloadItem {
                state,
                quality: Some(q),
                ..DownloadItem::new("a", "u", Art::Film, "T", 1, 12.5)
            };
            let back = decode_list(&encode_list(std::slice::from_ref(&p)).expect("e")).expect("d");
            assert_eq!(back, vec![p]);
        }
    }
}

#[test]
fn broken_list_is_reported_not_swallowed() {
    let loaded = load_list(Some(b"{not json"));
    assert!(loaded.items.is_empty());
    let (count, _message) = loaded.broken.expect("broken");
    assert_eq!(count, 9);
    assert!(load_list(None).broken.is_none() && load_list(None).items.is_empty());
}

#[test]
fn write_replaces_only_the_own_account() {
    let other = DownloadItem::new("x", "u2", Art::Film, "X", 1, 0.0);
    let old_own = DownloadItem::new("a", "u1", Art::Film, "A", 1, 0.0);
    let new_own = DownloadItem::new("b", "u1", Art::Film, "B", 1, 0.0);
    let all = merge_for_write(vec![other.clone(), old_own], "u1", vec![new_own.clone()]);
    assert_eq!(all, vec![other, new_own]);
}
