//! Ports of `SettingsSyncTests.swift` and `SettingsSyncStableTextTests.swift`.

use std::collections::BTreeMap;
use swiftly_settings::sync::*;

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect()
}

#[test]
fn values_run_through_text_without_loss() {
    let samples: Vec<(SyncValue, Kind)> = vec![
        (SyncValue::Bool(true), Kind::Bool),
        (SyncValue::Bool(false), Kind::Bool),
        (SyncValue::Int(30), Kind::Int),
        (SyncValue::Text("deu".into()), Kind::Text),
        (SyncValue::Text(String::new()), Kind::Text),
        (SyncValue::List(vec!["a".into(), "b".into()]), Kind::List),
        (SyncValue::List(vec![]), Kind::List),
        (SyncValue::List(vec!["a/b".into()]), Kind::List),
        (SyncValue::Json(br#"[{"id":"1"}]"#.to_vec()), Kind::Json),
    ];
    for (value, kind) in samples {
        assert_eq!(SyncValue::decode(&value.encoded(), kind), Some(value));
    }
    // Swift's JSONEncoder escapes the slash.
    assert_eq!(SyncValue::List(vec!["a/b".into()]).encoded(), r#"["a\/b"]"#);
}

#[test]
fn unfitting_values_are_rejected() {
    assert_eq!(SyncValue::decode("ja", Kind::Bool), None);
    assert_eq!(SyncValue::decode("-5", Kind::Int), None);
    assert_eq!(SyncValue::decode("99999", Kind::Int), None);
    assert_eq!(SyncValue::decode("nicht json", Kind::List), None);
    assert_eq!(SyncValue::decode("{", Kind::Json), None);
    assert_eq!(SyncValue::decode("5", Kind::Json), None);
}

#[test]
fn subtitle_look_travels_as_one_json_value() {
    let look = br#"{"size":"large","colour":"yellow","shadow":true}"#.to_vec();
    let values = BTreeMap::from([("utAussehen".to_owned(), SyncValue::Json(look.clone()))]);
    let sent = fields_for(&values, 5);
    let back = remote_from(&sent);
    assert_eq!(back.values.get("utAussehen"), Some(&SyncValue::Json(look)));
}

#[test]
fn foreign_keys_stay_outside() {
    let r = remote_from(&map(&[
        ("swiftly.vorSek", "45"),
        ("swiftly.changed", "2000"),
        ("homesection0", "latestmedia"),
        ("swiftly.unbekannt", "x"),
    ]));
    assert_eq!(
        r.values,
        BTreeMap::from([("vorSek".to_owned(), SyncValue::Int(45))])
    );
    assert!(r.present());
    assert_eq!(r.changed, Some(2000));
}

#[test]
fn who_wins() {
    let (t, older) = (1000_i64, 500_i64);
    let none = Remote::default();
    let theirs = Remote {
        values: BTreeMap::from([("utAuto".to_owned(), SyncValue::Bool(true))]),
        changed: Some(t),
    };
    assert_eq!(decide(&none, Some(t), false), Decision::Push);
    assert_eq!(decide(&theirs, Some(older), false), Decision::Apply);
    assert_eq!(decide(&theirs, None, false), Decision::Apply);
    assert_eq!(decide(&theirs, Some(t), false), Decision::Nothing);
    assert_eq!(decide(&theirs, Some(t + 5000), false), Decision::Push);
    assert_eq!(decide(&theirs, Some(t + 5000), true), Decision::Apply);
    // Values without a time, or a time without values, are not "present".
    let timeless = Remote {
        values: theirs.values.clone(),
        changed: None,
    };
    assert_eq!(decide(&timeless, Some(t), false), Decision::Push);
    let empty = Remote {
        values: BTreeMap::new(),
        changed: Some(t),
    };
    assert_eq!(decide(&empty, Some(older), false), Decision::Push);
}

#[test]
fn change_time_never_runs_behind_the_server() {
    assert_eq!(change_time(1000, None), 1000);
    assert_eq!(change_time(1000, Some(999)), 1000);
    assert_eq!(change_time(1000, Some(61_000)), 61_001);
    assert_eq!(change_time(1000, Some(1000)), 1001);
}

#[test]
fn writing_keeps_the_rest_of_the_preferences() {
    let body =
        br#"{"Id":"x","SortBy":"DateCreated","CustomPrefs":{"homesection0":"resume","a":null}}"#;
    let copy = DisplayPreferencesCopy::from_body(body).unwrap();
    assert_eq!(copy.custom_prefs(), map(&[("homesection0", "resume")]));
    let out = copy.merged(&map(&[("swiftly.vorSek", "45")]));
    assert_eq!(out["SortBy"], "DateCreated");
    assert_eq!(out["CustomPrefs"]["homesection0"], "resume");
    assert_eq!(out["CustomPrefs"]["swiftly.vorSek"], "45");
    assert!(out["CustomPrefs"].as_object().unwrap().contains_key("a"));
    assert!(DisplayPreferencesCopy::from_body(b"[1]").is_none());
}

#[test]
fn device_name_with_server_suffix_finds_its_entry() {
    assert_eq!(
        entry_for_device_key("startBibliotheken|https://x.de").map(|e| e.name),
        Some("startBibliotheken")
    );
    assert!(entry_for_device_key("nurUeberWLAN").is_none());
    assert!(entry_for_device_key("downloadsAn").is_none());
}

#[test]
fn seerr_newer_connection_wins_and_disconnect_travels() {
    let access = SeerrAccess {
        address: "https://seerr.example".into(),
        cookie: "connect.sid=1".into(),
        headers: vec![],
    };
    let (t1, t2) = (1_000, 2_000);
    let written = seerr_fields(Some(&access), t2);
    let empty = BTreeMap::new();
    // Nothing on the server: push what is here.
    assert_eq!(seerr_step(&empty, None, true), SeerrStep::Push);
    assert_eq!(seerr_step(&empty, None, false), SeerrStep::Nothing);
    // Server newer: take it.
    let adopt = SeerrStep::Adopt {
        access: Some(access.clone()),
        changed: t2,
    };
    assert_eq!(seerr_step(&written, Some(t1), false), adopt);
    assert_eq!(seerr_step(&written, None, false), adopt);
    // Device newer: write it; same time: done.
    let old = seerr_fields(Some(&access), t1);
    assert_eq!(seerr_step(&old, Some(t2), true), SeerrStep::Push);
    assert_eq!(seerr_step(&old, Some(t1), true), SeerrStep::Nothing);
    // A newer disconnect elsewhere disconnects here.
    let gone = seerr_fields(None, t2);
    assert_eq!(
        seerr_step(&gone, Some(t1), true),
        SeerrStep::Adopt {
            access: None,
            changed: t2
        }
    );
    // A device that never synced keeps its old connection against a disconnect.
    assert_eq!(seerr_step(&gone, None, true), SeerrStep::Push);
    // Garbage on the server is no disconnect.
    let mut broken = written.clone();
    broken.insert(SEERR_KEY.to_owned(), "{".to_owned());
    assert_eq!(seerr_step(&broken, None, true), SeerrStep::Push);
}

#[test]
fn seerr_header_is_stored_as_wert_like_swift() {
    let access = SeerrAccess {
        address: "https://s".into(),
        cookie: "c".into(),
        headers: vec![OwnHeader {
            name: "CF-Access".into(),
            value: "v".into(),
        }],
    };
    let text = seerr_fields(Some(&access), 1)[SEERR_KEY].clone();
    assert!(text.contains(r#""wert":"v""#), "{text}");
    assert_eq!(serde_json::from_str::<SeerrAccess>(&text).unwrap(), access);
}

#[test]
fn fields_leave_unset_keys_out_and_carry_time_and_format() {
    let values = BTreeMap::from([
        ("vorSek".to_owned(), SyncValue::Int(45)),
        ("nichtSync".to_owned(), SyncValue::Bool(true)),
    ]);
    let f = fields_for(&values, 1234);
    assert_eq!(f.len(), 3);
    assert_eq!(f["swiftly.vorSek"], "45");
    assert_eq!(f[CHANGED_KEY], "1234");
    assert_eq!(f[FORMAT_KEY], "1");
}

#[test]
fn encoded_text_is_stable() {
    // The 1.1.0 loop: the same data must give the same text every time.
    let doc = br#"[{"id":"a","name":"Filme","collection":false}]"#.to_vec();
    let first = SyncValue::Json(doc.clone()).encoded();
    for _ in 0..500 {
        assert_eq!(SyncValue::Json(doc.clone()).encoded(), first);
    }
    let list = SyncValue::List(vec!["b".into(), "a".into()]);
    assert_eq!(list.encoded(), list.encoded());
}

#[test]
fn collect_asks_with_the_server_suffix_only_where_it_applies() {
    let seen = std::cell::RefCell::new(Vec::new());
    let out = collect("https://x.de", |key, _| {
        seen.borrow_mut().push(key.to_owned());
        (key == "startBibliotheken|https://x.de").then(|| SyncValue::Json(b"[]".to_vec()))
    });
    assert_eq!(out.len(), 1);
    let seen = seen.into_inner();
    assert_eq!(seen.len(), ENTRIES.len());
    assert!(seen.contains(&"vorSek".to_owned()));
    assert!(seen.contains(&"startBibliotheken|https://x.de".to_owned()));
}
