//! Translated from SyncPlayTests.swift and SettingsSyncTests.swift.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::BTreeMap;

use swiftly_seerr::SeerrAccess;
use swiftly_sync::settings::SeerrStep;
use swiftly_sync::syncplay::{BufferMessage, CommandArt, Phase, QueueRecord, Reading, Step};
use swiftly_sync::*;

const T0: f64 = 1_800_000_000.0;

fn close(a: f64, b: f64, eps: f64) -> bool {
    (a - b).abs() < eps
}

#[test]
fn command_with_seven_digit_timestamps() {
    let text = r#"{"MessageType":"SyncPlayCommand","MessageId":"x","Data":{"GroupId":"g1","PlaylistItemId":"p1","When":"2026-09-24T10:00:01.5000000Z","PositionTicks":123450000,"Command":"Unpause","EmittedAt":"2026-09-24T10:00:00.9000000Z"}}"#;
    let Some(SyncPlayPostDirection::Command(b)) = SyncPlayPostDirection::read(text) else {
        panic!("no command")
    };
    assert_eq!(b.art, CommandArt::Proceed);
    assert_eq!(b.group, "g1");
    assert_eq!(b.entry_record.as_deref(), Some("p1"));
    assert!(close(b.spot.unwrap(), 12.345, 0.0001));
    assert!(close(
        b.moment,
        SyncPlay::time_read("2026-09-24T10:00:01.500Z").unwrap(),
        0.002
    ));
}

fn update(art: &str, data: &str) -> Option<SyncPlayPostDirection> {
    SyncPlayPostDirection::read(&format!(
        r#"{{"MessageType":"SyncPlayGroupUpdate","Data":{{"GroupId":"g1","Type":"{art}","Data":{data}}}}}"#
    ))
}

#[test]
fn group_news() {
    use SyncPlayPostDirection as P;
    assert_eq!(
        update("UserJoined", r#""Tom""#),
        Some(P::SomeoneJoined("Tom".into()))
    );
    assert_eq!(
        update("UserLeft", r#""Tom""#),
        Some(P::SomeoneLeft("Tom".into()))
    );
    assert_eq!(update("GroupLeft", r#""g1""#), Some(P::Leave));
    assert_eq!(update("NotInGroup", r#""""#), Some(P::NotInGroup));
    assert_eq!(update("LibraryAccessDenied", r#""""#), Some(P::NoAccess));
    assert_eq!(
        update("StateUpdate", r#"{"State":"Waiting","Reason":"Buffer"}"#),
        Some(P::Condition(Phase::Waits, Some("Buffer".into())))
    );
    let Some(P::Joined(g)) = update(
        "GroupJoined",
        r#"{"GroupId":"g1","GroupName":"Filmabend","State":"Idle","Participants":["Paul"],"LastUpdatedAt":"2026-09-24T10:00:00.1234567Z"}"#,
    ) else {
        panic!("no join")
    };
    assert_eq!(
        (g.name.as_str(), g.condition, g.participant.clone()),
        ("Filmabend", Some(Phase::Empty), vec!["Paul".to_string()])
    );
    assert!(g.state.is_some());
}

#[test]
fn queue() {
    let text = r#"{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"g1","Type":"PlayQueue","Data":{"Reason":"NewPlaylist","LastUpdate":"2026-09-24T10:00:00Z","Playlist":[{"ItemId":"i1","PlaylistItemId":"p1"},{"ItemId":"i2","PlaylistItemId":"p2"}],"PlayingItemIndex":1,"StartPositionTicks":600000000,"IsPlaying":false,"ShuffleMode":"Sorted","RepeatMode":"RepeatNone"}}}"#;
    let Some(SyncPlayPostDirection::Queue(w)) = SyncPlayPostDirection::read(text) else {
        panic!("no queue")
    };
    assert_eq!(
        w.current(),
        Some(&QueueRecord {
            title: "i2".into(),
            entry_record: "p2".into()
        })
    );
    assert_eq!(w.start_point, 60.0);
    assert!(w.switches_title() && !w.running);
}

#[test]
fn foreign_stays_put_and_bad_input_does_not_panic() {
    assert!(SyncPlayPostDirection::read(r#"{"MessageType":"ForceKeepAlive","Data":60}"#).is_none());
    assert!(SyncPlayPostDirection::read("kein json").is_none());
    assert!(
        SyncPlayPostDirection::read(
            r#"{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"g","Type":"Neu","Data":1}}"#
        )
        .is_none()
    );
    for bad in [
        "",
        "null",
        "[]",
        r#"{"MessageType":"SyncPlayCommand"}"#,
        r#"{"MessageType":"SyncPlayCommand","Data":{"GroupId":"g","When":"x","Command":"Pause"}}"#,
        r#"{"MessageType":"SyncPlayGroupUpdate","Data":{"Type":"PlayQueue","Data":{"Reason":5}}}"#,
    ] {
        assert!(SyncPlayPostDirection::read(bad).is_none(), "{bad}");
    }
}

#[test]
fn groups_list_without_fields() {
    let raw = br#"[{"GroupId":"g1","GroupName":"Filmabend","State":"Playing","Participants":["Paul","Tom","Paul"]},{"GroupId":"g2"}]"#;
    let list = SyncPlayGroup::list_from_json(raw).unwrap();
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].condition, Some(Phase::Running));
    assert_eq!(list[0].other(Some("Paul")), ["Tom", "Paul"]);
    assert_eq!((list[1].name.as_str(), list[1].participant.len()), ("", 0));
}

#[test]
fn others_without_me_or_duplicates() {
    let mut g = SyncPlayGroup::new("g", "n");
    g.participant = ["Paul", "Tom", "Tom", "Lena"].map(String::from).to_vec();
    assert_eq!(g.other(Some("Paul")), ["Tom", "Lena"]);
    assert_eq!(g.other(None), ["Paul", "Tom", "Lena"]);
}

fn measurement(offset: f64, there: f64, back: f64, since: f64) -> Reading {
    let within = since + there + offset;
    let out = within + 0.005;
    Reading {
        sent: since,
        server_receive: within,
        server_sent: out,
        receive: out - offset + back,
    }
}

#[test]
fn offset_from_symmetric_measurement() {
    let m = measurement(2.5, 0.04, 0.04, T0);
    assert!(close(m.offset(), 2.5, 0.0001) && close(m.runtime(), 0.08, 0.0001));
}

#[test]
fn shortest_runtime_applies() {
    let mut a = TimeReconcile::new();
    assert!(!a.ready() && a.offset() == 0.0);
    a.record(measurement(1.0, 0.4, 0.02, T0));
    a.record(measurement(1.0, 0.01, 0.01, T0));
    assert!(close(a.offset(), 1.0, 0.001));
    assert_eq!(a.ping_milliseconds(), 10);
    let local = T0 + 10.0;
    assert!(close(a.local_only(a.server(local)), local, 0.0001));
}

#[test]
fn only_eight_measurements_remain() {
    let mut a = TimeReconcile::new();
    for i in 0..12 {
        a.record(measurement(f64::from(i), 0.01, 0.01, T0));
    }
    assert_eq!(a.measurements().len(), TimeReconcile::KEEP);
    assert_eq!(TimeReconcile::pause_to_measurements(0), 1.0);
    assert_eq!(TimeReconcile::pause_to_measurements(3), 60.0);
}

fn reconcile(offset: f64) -> TimeReconcile {
    let mut a = TimeReconcile::new();
    a.record(measurement(offset, 0.01, 0.01, T0));
    a
}

fn command(art: CommandArt, moment: f64, spot: Option<f64>) -> SyncPlayCommand {
    SyncPlayCommand {
        group: "g".into(),
        entry_record: Some("p".into()),
        art,
        moment,
        spot,
        emitted: None,
    }
}

#[test]
fn next_in_future_waits() {
    let a = reconcile(3.0);
    let b = command(CommandArt::Proceed, a.server(T0) + 1.5, Some(100.0));
    let x = SyncPlayExecution::of(&b, T0, &a, 100.1);
    assert_eq!(x.step, Step::Proceed);
    assert!(close(x.wait, 1.5, 0.001));
    assert_eq!(x.spot, None);
    assert_eq!(SyncPlayExecution::of(&b, T0, &a, 90.0).spot, Some(100.0));
}

#[test]
fn next_in_past_fetches() {
    let a = reconcile(-2.0);
    let b = command(CommandArt::Proceed, a.server(T0) - 4.0, Some(100.0));
    let x = SyncPlayExecution::of(&b, T0, &a, 100.0);
    assert_eq!(x.wait, 0.0);
    assert!(close(x.spot.unwrap(), 104.0, 0.001));
}

#[test]
fn pause_jumps_to_group_point() {
    let a = reconcile(0.0);
    let x = SyncPlayExecution::of(
        &command(CommandArt::Pause, T0 + 0.3, Some(50.0)),
        T0,
        &a,
        51.0,
    );
    assert_eq!((x.step, x.spot), (Step::Pause, Some(50.0)));
    assert!(close(x.wait, 0.3, 0.001));
}

#[test]
fn jump_always_with_point() {
    let a = reconcile(0.0);
    let x = SyncPlayExecution::of(
        &command(CommandArt::Jump, T0 - 1.0, Some(600.0)),
        T0,
        &a,
        600.0,
    );
    assert_eq!(
        x,
        SyncPlayExecution {
            step: Step::Jump,
            spot: Some(600.0),
            wait: 0.0
        }
    );
    assert_eq!(
        SyncPlayExecution::of(&command(CommandArt::Stop, T0, None), T0, &a, 1.0).step,
        Step::Stop
    );
}

#[test]
fn update_first_off_second() {
    let a = reconcile(0.0);
    let b = command(CommandArt::Proceed, T0, Some(10.0));
    let now = T0 + 20.0;
    let up = |last: Option<&SyncPlayCommand>, entry, now, point| {
        SyncPlayExecution::bring_up_to_date(last, entry, now, &a, point)
    };
    assert_eq!(up(Some(&b), Some("p"), now, 29.5), None);
    assert!(close(
        up(Some(&b), Some("p"), now, 27.0).unwrap(),
        30.0,
        0.001
    ));
    assert_eq!(up(Some(&b), Some("anders"), now, 0.0), None);
    assert_eq!(
        up(
            Some(&command(CommandArt::Pause, T0, Some(10.0))),
            Some("p"),
            now,
            0.0
        ),
        None
    );
    assert_eq!(up(Some(&b), Some("p"), T0 - 1.0, 0.0), None);
}

#[test]
fn buffer_guard() {
    let mut w = BufferGuard::new();
    let mut t = T0;
    assert_eq!(w.tick(10.0, true, t), None);
    for _ in 0..4 {
        t += 1.0;
        let spot = 11.0;
        assert_eq!(w.tick(spot, true, t), None);
    }
    t += 1.0;
    assert_eq!(w.tick(11.0, true, t), Some(BufferMessage::Buffers));
    t += 1.0;
    assert_eq!(w.tick(11.0, true, t), None, "only once");
    t += 1.0;
    assert_eq!(w.tick(11.5, true, t), Some(BufferMessage::Ready));
    for _ in 0..5 {
        t += 1.0;
        assert_eq!(w.tick(11.5, false, t), None);
    }
}

#[test]
fn ready_point_after_jump() {
    assert_eq!(SyncPlayExecution::ready_point(600.0, 600.3), 600.0);
    assert_eq!(SyncPlayExecution::ready_point(600.0, 599.2), 600.0);
    assert_eq!(SyncPlayExecution::ready_point(600.0, 604.0), 604.0);
}

#[test]
fn time_text_reads_server() {
    let text = SyncPlay::time_text(T0 + 0.25);
    assert!(text.ends_with('Z') && text.contains(".250"), "{text}");
    assert_eq!(text, "2027-01-15T08:00:00.250Z");
    assert!(close(SyncPlay::time_read(&text).unwrap() - T0, 0.25, 0.001));
    assert_eq!(SyncPlay::time_text(0.0), "1970-01-01T00:00:00.000Z");
    assert_eq!(SyncPlay::time_text(f64::NAN), "1970-01-01T00:00:00.000Z");
}

#[test]
fn tick_conversion_and_rights() {
    assert_eq!(SyncPlay::ticks(1.5), 15_000_000);
    assert_eq!(SyncPlay::seconds(600_000_000), 60.0);
    assert!(!SyncPlayRight::from_raw("JoinGroups").unwrap().may_create());
    assert!(SyncPlayRight::from_raw("JoinGroups").unwrap().may_join());
    assert!(!SyncPlayRight::No.may_join());
}

// ---- Settings sync ----

#[test]
fn roundtrip() {
    let samples = [
        (Value::Bool(true), Kind::Bool),
        (Value::Bool(false), Kind::Bool),
        (Value::Int(30), Kind::Int),
        (Value::Text("deu".into()), Kind::Text),
        (Value::Text(String::new()), Kind::Text),
        (Value::List(vec!["a".into(), "b".into()]), Kind::List),
        (Value::List(vec![]), Kind::List),
        (Value::Json(r#"[{"id":"1"}]"#.into()), Kind::Json),
    ];
    for (v, k) in samples {
        assert_eq!(Value::decode(&v.encoded(), k), Some(v));
    }
}

#[test]
fn rejects_garbage() {
    assert!(Value::decode("ja", Kind::Bool).is_none());
    assert!(Value::decode("-5", Kind::Int).is_none());
    assert!(Value::decode("99999", Kind::Int).is_none());
    assert!(Value::decode("nicht json", Kind::List).is_none());
    assert!(Value::decode("{", Kind::Json).is_none());
}

fn prefs(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).into(), (*v).into()))
        .collect()
}

#[test]
fn subtitle_look_travels_as_one_json_value() {
    let look = r#"{"size":"large","colour":"yellow","shadow":true}"#;
    let values = BTreeMap::from([("utAussehen".to_string(), Value::Json(look.into()))]);
    let sent = SettingsSync::fields(&values, 5.0);
    assert_eq!(sent["swiftly.changed"], "5000");
    assert_eq!(sent["swiftly.format"], "1");
    let back = SettingsSync::remote(&sent);
    assert_eq!(back.values["utAussehen"], Value::Json(look.into()));
}

#[test]
fn ignores_foreign_keys() {
    let r = SettingsSync::remote(&prefs(&[
        ("swiftly.vorSek", "45"),
        ("swiftly.changed", "2000"),
        ("homesection0", "latestmedia"),
        ("swiftly.unbekannt", "x"),
    ]));
    assert_eq!(
        r.values,
        BTreeMap::from([("vorSek".to_string(), Value::Int(45))])
    );
    assert!(r.present());
}

#[test]
fn who_wins() {
    let t = 1000.0;
    let none = settings::Remote {
        values: BTreeMap::new(),
        changed: None,
    };
    let theirs = settings::Remote {
        values: BTreeMap::from([("utAuto".to_string(), Value::Bool(true))]),
        changed: Some(t),
    };
    assert_eq!(SettingsSync::decide(&none, Some(t), false), Decision::Push);
    assert_eq!(
        SettingsSync::decide(&theirs, Some(500.0), false),
        Decision::Apply
    );
    assert_eq!(SettingsSync::decide(&theirs, None, false), Decision::Apply);
    assert_eq!(
        SettingsSync::decide(&theirs, Some(t), false),
        Decision::Nothing
    );
    assert_eq!(
        SettingsSync::decide(&theirs, Some(t + 5.0), false),
        Decision::Push
    );
    assert_eq!(
        SettingsSync::decide(&theirs, Some(t + 5.0), true),
        Decision::Apply
    );
}

#[test]
fn change_time_never_runs_behind_the_server() {
    assert_eq!(SettingsSync::change_time(1000.0, None), 1000.0);
    assert_eq!(SettingsSync::change_time(1000.0, Some(999.0)), 1000.0);
    assert!(SettingsSync::change_time(1000.0, Some(1060.0)) > 1060.0);
}

#[test]
fn merge_keeps_the_rest() {
    let body =
        br#"{"Id":"x","SortBy":"DateCreated","CustomPrefs":{"homesection0":"resume","a":null}}"#;
    let copy = DisplayPreferencesCopy::from_body(body).unwrap();
    assert_eq!(copy.custom_prefs(), prefs(&[("homesection0", "resume")]));
    let out: serde_json::Value =
        serde_json::from_slice(&copy.merged(&prefs(&[("swiftly.vorSek", "45")]))).unwrap();
    assert_eq!(out["SortBy"], "DateCreated");
    assert_eq!(out["CustomPrefs"]["homesection0"], "resume");
    assert_eq!(out["CustomPrefs"]["swiftly.vorSek"], "45");
    assert!(out["CustomPrefs"].as_object().unwrap().contains_key("a"));
    assert!(DisplayPreferencesCopy::from_body(b"[1]").is_none());
}

#[test]
fn device_key_suffix() {
    assert_eq!(
        SettingsSync::entry_for_device_key("startBibliotheken|https://x.de")
            .unwrap()
            .name,
        "startBibliotheken"
    );
    assert!(SettingsSync::entry_for_device_key("nurUeberWLAN").is_none());
    let got = SettingsSync::collect("|s", |k, kind| {
        (k == "startBibliotheken|s" && kind == Kind::Json).then(|| Value::Json("[]".into()))
    });
    assert_eq!(got.len(), 1);
}

#[test]
fn seerr_connection_travels() {
    let access = SeerrAccess::new("https://seerr.example", "connect.sid=1", &[]);
    let (t1, t2) = (1000.0, 2000.0);
    let written = SettingsSync::seerr_fields(Some(&access), t2);
    let step = |p: &BTreeMap<String, String>, l, has| SettingsSync::seerr_step(p, l, has);
    assert_eq!(step(&BTreeMap::new(), None, true), SeerrStep::Push);
    assert_eq!(step(&BTreeMap::new(), None, false), SeerrStep::Nothing);
    assert_eq!(
        step(&written, Some(t1), false),
        SeerrStep::Adopt(Some(access.clone()), t2)
    );
    assert_eq!(
        step(&written, None, false),
        SeerrStep::Adopt(Some(access.clone()), t2)
    );
    let old = SettingsSync::seerr_fields(Some(&access), t1);
    assert_eq!(step(&old, Some(t2), true), SeerrStep::Push);
    assert_eq!(step(&old, Some(t1), true), SeerrStep::Nothing);
    let gone = SettingsSync::seerr_fields(None, t2);
    assert_eq!(step(&gone, Some(t1), true), SeerrStep::Adopt(None, t2));
    assert_eq!(step(&gone, None, true), SeerrStep::Push);
    let mut broken = written;
    broken.insert("swiftly.seerr".into(), "{".into());
    assert_eq!(step(&broken, None, true), SeerrStep::Push);
}
