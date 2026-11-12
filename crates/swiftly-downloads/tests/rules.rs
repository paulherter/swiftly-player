//! Translation of `DownloadRulesTests` (Swift), `DownloadItemItemTests`, the item-dependent
//! tests of `DownloadQualityTests` and `DownloadAudioTests`.

#![allow(clippy::expect_used)]

mod common;

use common::*;
use swiftly_downloads::{
    Art, DownloadAudioChoice, DownloadGroup, DownloadItem, DownloadQuality, DownloadRules,
    DownloadState, FootSpace, PADDING, PathPart, ProgressEstimator,
};

fn next_id(list: &[DownloadItem], wlan: bool, only: bool) -> Option<String> {
    DownloadRules::next_one(list, wlan, only).map(|p| p.id.clone())
}

fn at(id: &str, seconds: f64) -> DownloadItem {
    DownloadItem {
        created: 1_000_000.0 + seconds,
        ..entry(id)
    }
}

// MARK: one after the other

#[test]
fn oldest_first() {
    let list = [at("b", 20.0), at("a", 10.0), at("c", 30.0)];
    assert_eq!(next_id(&list, true, true).as_deref(), Some("a"));
}

#[test]
fn only_one_at_a_time() {
    let list = [with_state("a", DownloadState::Loads), at("b", 10.0)];
    assert_eq!(next_id(&list, true, true), None);
}

#[test]
fn only_waiting() {
    let list = [
        with_state("a", DownloadState::Halted),
        with_state("b", DownloadState::Error),
        with_state("c", DownloadState::Done),
    ];
    assert_eq!(next_id(&list, true, true), None);
}

#[test]
fn without_wlan() {
    let list = [entry("a")];
    assert_eq!(next_id(&list, false, true), None);
    assert_eq!(next_id(&list, false, false).as_deref(), Some("a"));
}

#[test]
fn stable_same_state() {
    let forward = [entry("a"), entry("b")];
    let backward = [entry("b"), entry("a")];
    assert_eq!(
        next_id(&forward, true, true),
        next_id(&backward, true, true)
    );
}

// MARK: Rules

#[test]
fn cellular() {
    assert!(DownloadRules::may_load(true, true));
    assert!(DownloadRules::may_load(true, false));
    assert!(DownloadRules::may_load(false, false));
    assert!(!DownloadRules::may_load(false, true));
}

#[test]
fn network_unknown() {
    use swiftly_downloads::NetworkVerdict::*;
    assert_eq!(DownloadRules::network_verdict(None, true), WaitFor);
    assert_eq!(DownloadRules::network_verdict(None, false), Load);
}

#[test]
fn network_known() {
    use swiftly_downloads::NetworkVerdict::*;
    assert_eq!(DownloadRules::network_verdict(Some(false), true), PutBack);
    assert_eq!(DownloadRules::network_verdict(Some(true), true), Load);
    assert_eq!(DownloadRules::network_verdict(Some(false), false), Load);
}

// MARK: space

#[test]
fn space_suffices() {
    let a = DownloadRules::slot(10_000_000_000, 100_000_000_000, &[]);
    assert!(a.suffices);
    assert!(a.dispensable.is_empty());
    assert!(a.suffices_to_clean_up());
}

#[test]
fn padding_stays_free() {
    let a = DownloadRules::slot(10_000_000_000, 10_000_000_000, &[]);
    assert!(!a.suffices);
    assert_eq!(a.free_after, -PADDING);
}

#[test]
fn foot_suffices() {
    assert_eq!(
        DownloadRules::foot_space(10_000_000_000, 61_200_000_000),
        FootSpace::Free(51_200_000_000)
    );
}

#[test]
fn foot_few() {
    assert_eq!(
        DownloadRules::foot_space(91_870_000_000, 61_200_000_000),
        FootSpace::Few(30_670_000_000 + PADDING)
    );
}

#[test]
fn foot_how_sheet() {
    for free in [
        9_000_000_000_i64,
        10_000_000_000,
        10_500_000_000,
        11_073_741_824,
        12_000_000_000,
    ] {
        let bytes = 10_000_000_000;
        let suffices = DownloadRules::slot(bytes, free, &[]).suffices;
        match DownloadRules::foot_space(bytes, free) {
            FootSpace::Free(_) => assert!(suffices),
            FootSpace::Few(_) => assert!(!suffices),
        }
    }
}

#[test]
fn foot_without_selection() {
    assert_eq!(
        DownloadRules::foot_space(0, 500_000_000),
        FootSpace::Free(500_000_000)
    );
}

#[test]
fn progress_fixed() {
    let total = 2_310_000_000;
    let values: Vec<(String, String)> =
        [0, 850_000_000, 1_000_000_000, 1_100_000_000, 2_310_000_000]
            .iter()
            .map(|l| DownloadRules::progress(*l, total, ","))
            .collect();
    let loaded: Vec<&str> = values.iter().map(|v| v.0.as_str()).collect();
    assert_eq!(loaded, ["0,00", "0,85", "1,00", "1,10", "2,31"]);
    assert!(values.iter().all(|v| v.1 == "2,31 GB"));
    // Under one gigabyte: whole megabytes.
    let small = DownloadRules::progress(12_345_678, 734_000_000, ",");
    assert_eq!(small.0, "12");
    assert_eq!(small.1, "734 MB");
}

#[test]
fn progress_tick() {
    let g = 2_000_000_000;
    assert!(DownloadRules::progress_show(1, g, None, None));
    // Loaded enough, but too early.
    assert!(!DownloadRules::progress_show(
        500_000_000,
        g,
        Some(0),
        Some(0.3)
    ));
    // Long enough, but hardly anything added.
    assert!(!DownloadRules::progress_show(1_000, g, Some(0), Some(5.0)));
    assert!(DownloadRules::progress_show(
        500_000_000,
        g,
        Some(0),
        Some(1.0)
    ));
    // A fresh start and the end always get through.
    assert!(DownloadRules::progress_show(10, g, Some(900), Some(0.1)));
    assert!(DownloadRules::progress_show(g, g, Some(g - 5), Some(0.1)));
}

#[test]
fn estimator() {
    let mut s = ProgressEstimator::new();
    let g = 2_000_000_000;
    s.report(0, g, 0.0);
    s.report(10_000_000, g, 1.0);
    // Between two reports: continue at the same pace, so more than reported.
    let center = s.value(1.5);
    assert!(center > 10_000_000 && center < 20_000_000);
    // The next report is below what is shown: it stays put.
    s.report(12_000_000, g, 2.0);
    assert!(s.value(2.0) >= center);
    // After a while without a report the number holds.
    let a = s.value(10.0);
    assert_eq!(s.value(20.0), a);
    // Never above the total.
    s.report(g - 1, g, 21.0);
    assert!(s.value(23.0) <= g);
}

#[test]
fn estimator_pause() {
    let mut s = ProgressEstimator::new();
    let g = 2_000_000_000;
    s.report(0, g, 0.0);
    s.report(10_000_000, g, 1.0);
    let pre_pause = s.value(1.5);
    s.halt();
    assert_eq!(s.value(1.6), pre_pause);
    assert_eq!(s.value(60.0), pre_pause);
    // Resuming after a minute: no pace across the pause, the number stays until the real one
    // catches up.
    s.report(11_000_000, g, 61.0);
    assert_eq!(s.value(61.5), pre_pause);
    s.report(21_000_000, g, 62.0);
    assert!(s.value(62.5) > 21_000_000);
}

#[test]
fn estimator_new() {
    let mut s = ProgressEstimator::new();
    s.report(500, 1_000, 0.0);
    let _ = s.value(0.0);
    s.report(100, 1_000, 1.0);
    assert_eq!(s.value(1.0), 100);
}

fn ep(id: &str, state: DownloadState, watched: bool, season: i64, number: i64) -> DownloadItem {
    DownloadItem {
        state,
        watched,
        ..episode_entry(id, "S", "s1", season, number)
    }
}

#[test]
fn next_episode() {
    let list = [
        ep("s2f1", DownloadState::Done, false, 2, 1),
        ep("s1f2", DownloadState::Done, true, 1, 2),
        ep("s1f1", DownloadState::Done, true, 1, 1),
        ep("s1f3", DownloadState::Loads, false, 1, 3),
    ];
    assert_eq!(
        DownloadRules::next_episode(&list).map(|p| p.id.as_str()),
        Some("s2f1")
    );
    // Everything seen: from the start.
    let watched: Vec<DownloadItem> = list.iter().filter(|p| p.watched).cloned().collect();
    assert_eq!(
        DownloadRules::next_episode(&watched).map(|p| p.id.as_str()),
        Some("s1f1")
    );
    // Nothing finished: nothing to play.
    assert!(DownloadRules::next_episode(&list[3..]).is_none());
}

fn done(id: &str, bytes: i64, watched: bool) -> DownloadItem {
    DownloadItem {
        state: DownloadState::Done,
        bytes,
        watched,
        ..entry(id)
    }
}

#[test]
fn clean_up_suffices() {
    let available = [
        done("alt", 8_000_000_000, true),
        done("neu", 9_000_000_000, false),
    ];
    let a = DownloadRules::slot(10_000_000_000, 5_000_000_000, &available);
    assert!(!a.suffices);
    let ids: Vec<&str> = a.dispensable.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(ids, ["alt"]);
    assert_eq!(a.dispensable_bytes, 8_000_000_000);
    // 5 - 10 - 1 = -6 GB; 8 GB of expendable files covers that.
    assert!(a.suffices_to_clean_up());
}

#[test]
fn clean_up_suffices_not() {
    let available = [done("alt", 1_000_000_000, true)];
    let a = DownloadRules::slot(60_000_000_000, 5_000_000_000, &available);
    assert!(!a.suffices);
    assert!(!a.suffices_to_clean_up());
}

#[test]
fn started_stays() {
    let available = [
        DownloadItem {
            state: DownloadState::Loads,
            bytes: 9_000_000_000,
            watched: true,
            ..entry("halb")
        },
        DownloadItem {
            state: DownloadState::Waits,
            bytes: 9_000_000_000,
            watched: true,
            ..entry("wartet")
        },
    ];
    assert!(DownloadRules::dispensable(&available).is_empty());
}

#[test]
fn largest_first() {
    let available = [
        done("klein", 2_000_000_000, true),
        done("gross", 20_000_000_000, true),
        done("mittel", 7_000_000_000, true),
    ];
    let ids: Vec<String> = DownloadRules::dispensable(&available)
        .into_iter()
        .map(|p| p.id)
        .collect();
    assert_eq!(ids, ["gross", "mittel", "klein"]);
}

// MARK: a series is one row

fn ep_at(
    id: &str,
    series: &str,
    sid: &str,
    season: i64,
    number: i64,
    seconds: f64,
    bytes: i64,
) -> DownloadItem {
    DownloadItem {
        created: 1_000_000.0 + seconds,
        bytes,
        ..episode_entry(id, series, sid, season, number)
    }
}

#[test]
fn series_becomes_row() {
    let list = [
        ep_at("f1", "Fallout", "S1", 1, 2, 10.0, 1_000_000_000),
        ep_at("f2", "Fallout", "S1", 1, 1, 20.0, 1_000_000_000),
        at("film", 5.0),
    ];
    let groups = DownloadRules::grouped(&list);
    assert_eq!(groups.len(), 2);
    let Some(DownloadGroup::Series {
        id,
        title,
        episodes,
    }) = groups.iter().find(|g| g.id() == "serie-S1")
    else {
        panic!("Serie fehlt");
    };
    assert_eq!(id, "S1");
    assert_eq!(title, "Fallout");
    // By season and episode, not by access.
    let ids: Vec<&str> = episodes.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(ids, ["f2", "f1"]);
}

#[test]
fn group_computes() {
    let list = [
        ep_at("f1", "X", "S", 1, 1, 10.0, 2_000_000_000),
        ep_at("f2", "X", "S", 1, 2, 90.0, 3_000_000_000),
    ];
    let g = &DownloadRules::grouped(&list)[0];
    assert_eq!(g.bytes(), 5_000_000_000);
    assert_eq!(g.created(), 1_000_090.0);
}

#[test]
fn two_series() {
    let list = [
        ep_at("a", "Alt", "A", 1, 1, 10.0, 1),
        ep_at("b", "Neu", "B", 1, 1, 900.0, 1),
    ];
    let titles: Vec<String> = DownloadRules::grouped(&list)
        .iter()
        .map(|g| g.title().to_owned())
        .collect();
    assert_eq!(titles, ["Neu", "Alt"]);
}

#[test]
fn episode_without_series() {
    let list = [DownloadItem {
        art: Art::Episode,
        series: Some("Irgendwas".into()),
        series_identifier: None,
        ..entry("waise")
    }];
    let g = DownloadRules::grouped(&list);
    assert_eq!(g.len(), 1);
    assert!(matches!(g[0], DownloadGroup::Single(_)));
}

// MARK: Numbers

#[test]
fn allocation() {
    let list = [
        done("a", 4_000_000_000, false),
        DownloadItem {
            state: DownloadState::Loads,
            bytes: 9_000_000_000,
            ..entry("b")
        },
        done("c", 1_000_000_000, false),
    ];
    assert_eq!(DownloadRules::allocation(&list), (2, 5_000_000_000));
}

#[test]
fn no_share_without_size() {
    let p = DownloadItem {
        bytes: 0,
        loaded: 500,
        ..entry("a")
    };
    assert_eq!(p.share(), None);
    let q = DownloadItem {
        bytes: 1000,
        loaded: 250,
        ..entry("b")
    };
    assert_eq!(q.share(), Some(0.25));
}

#[test]
fn file_name() {
    let p = DownloadItem {
        account: "u9".into(),
        ..entry("abc")
    };
    assert_eq!(p.file_name(), "u9-abc.mkv");
    // Two accounts, the same id: two files. H11.
    let a = DownloadItem {
        account: "u1".into(),
        ..entry("abc")
    };
    let b = DownloadItem {
        account: "u2".into(),
        ..entry("abc")
    };
    assert_ne!(a.file_name(), b.file_name());
}

#[test]
fn file_name_out_server_data() {
    fn with(container: Option<&str>, id: &str, account: &str) -> String {
        DownloadItem {
            container: container.map(str::to_owned),
            account: account.into(),
            ..DownloadItem::new(id, account, Art::Film, "T", 1, 0.0)
        }
        .file_name()
    }
    let w = |c: Option<&str>| with(c, "abc", "u1");
    // Real values stay as they were, so old downloads are found.
    assert_eq!(w(Some("MKV")), "u1-abc.mkv");
    assert_eq!(
        w(Some("mov,mp4,m4a,3gp,3g2,mj2")),
        "u1-abc.mov,mp4,m4a,3gp,3g2,mj2"
    );
    assert_eq!(w(None), "u1-abc");
    assert_eq!(
        with(
            Some("mkv"),
            "0f8e2c4a9b7d4e1fa3c5b6d7e8f90123",
            "a1b2c3d4-e5f6"
        ),
        "a1b2c3d4-e5f6-0f8e2c4a9b7d4e1fa3c5b6d7e8f90123.mkv"
    );
    // Everything else falls back to no extension or is neutralized.
    assert_eq!(w(Some("../../../../etc/passwd")), "u1-abc");
    assert_eq!(w(Some("mkv/x")), "u1-abc");
    assert_eq!(w(Some("mk\u{0}v")), "u1-abc");
    assert_eq!(w(Some("sehrlangeendung")), "u1-abc");
    assert_eq!(w(Some("")), "u1-abc");
    assert_eq!(with(Some("mkv"), "../../x", "u1"), "u1-______x.mkv");
    assert_eq!(with(Some("mkv"), "abc", "a/b\nc"), "a_b_c-abc.mkv");
    assert_eq!(with(None, "", "u1"), "u1-_");
    for name in [
        with(Some("mkv"), "..", "u1"),
        with(Some("../x"), "a/../b", ".."),
    ] {
        assert!(!name.contains('/') && !name.contains(".."));
    }
    assert_eq!(DownloadItem::image_name("u1", "../s"), "u1-___s.jpg");
}

#[test]
fn id_from_outer() {
    assert!(PathPart::is_id("0f8e2c4a9b7d4e1fa3c5b6d7e8f90123"));
    assert!(PathPart::is_id("0f8e2c4a-9b7d-4e1f-a3c5-b6d7e8f90123"));
    assert!(!PathPart::is_id(""));
    assert!(!PathPart::is_id("../../Users"));
    assert!(!PathPart::is_id("abc?x=1"));
    assert!(!PathPart::is_id(&"a".repeat(65)));
}

// MARK: DownloadItemItemTests

#[test]
fn item_episode() {
    let p = DownloadItem {
        art: Art::Episode,
        series: Some("Breaking Bad".into()),
        series_identifier: Some("s1".into()),
        season: Some(1),
        episode: Some(3),
        runtime_ticks: Some(38_400_000_000),
        ..DownloadItem::new("e1", "u1", Art::Episode, "Der Einstieg", 1, 0.0)
    };
    let i = p.as_item();
    assert_eq!(i.id, "e1");
    assert_eq!(i.name, "Der Einstieg");
    assert_eq!(i.type_.as_deref(), Some("Episode"));
    assert_eq!(i.series_name.as_deref(), Some("Breaking Bad"));
    assert_eq!(i.series_id.as_deref(), Some("s1"));
    assert_eq!(i.parent_index_number, Some(1));
    assert_eq!(i.index_number, Some(3));
    assert_eq!(i.run_time_ticks, Some(38_400_000_000));
}

#[test]
fn item_film() {
    let i = DownloadItem::new("m1", "u1", Art::Film, "Arrival", 1, 0.0).as_item();
    assert_eq!(i.type_.as_deref(), Some("Movie"));
    assert!(i.series_id.is_none());
    assert!(i.series_name.is_none());
}

// MARK: DownloadQualityTests (the ones that needed DownloadItem)

const EPISODE: i64 = 36_000_000_000; // one hour in ticks

#[test]
fn entries_quality() {
    let p = DownloadItem {
        runtime_ticks: Some(EPISODE),
        container: Some("mp4".into()),
        source: Some("q".into()),
        ..DownloadItem::new("a", "u", Art::Film, "T", 10_000_000_000, 0.0)
    };
    assert!(p.quality.is_none() && !p.converted() && p.guete() == DownloadQuality::Original);
    let small = p.in_quality(DownloadQuality::Hd720);
    assert_eq!(small.container.as_deref(), Some("mkv"));
    assert!(small.file_name().ends_with(".mkv"));
    assert!(small.converted() && small.guete() == DownloadQuality::Hd720);
    assert!(small.bytes < p.bytes);
    assert_eq!(p.in_quality(DownloadQuality::Original), p);
}

#[test]
fn share_of_an_estimate_never_full() {
    let mut p = DownloadItem {
        runtime_ticks: Some(EPISODE),
        ..DownloadItem::new("a", "u", Art::Film, "T", 10_000_000_000, 0.0)
    }
    .in_quality(DownloadQuality::Sd480);
    p.state = DownloadState::Loads;
    p.loaded = p.bytes * 2;
    assert_eq!(p.share(), Some(0.99));
    p.state = DownloadState::Done;
    assert_eq!(p.share(), Some(1.0));
}

// MARK: DownloadAudioTests (the ones that needed DownloadItem / DownloadRules)

fn film_streams() -> Vec<swiftly_downloads::AudioStream> {
    swiftly_downloads::item::audio_streams(Some(&swiftly_model::MediaSource {
        media_streams: Some(vec![
            audio_stream(1, "ger", "ac3", false),
            audio_stream(2, "eng", "dts", false),
        ]),
        ..Default::default()
    }))
}

#[test]
fn item_with_audio() {
    let base = DownloadItem {
        container: Some("mp4".into()),
        ..DownloadItem::new("f", "u1", Art::Film, "F", 5_000, 0.0)
    };
    assert!(!base.streamed());
    let all = base.with_audio(&Fake, &DownloadAudioChoice::All, &film_streams());
    assert_eq!(all, base);
    let one = base.with_audio(&Fake, &DownloadAudioChoice::Track(2), &film_streams());
    assert_eq!(one.audio_index, Some(2));
    assert!(one.streamed() && !one.converted());
    assert_eq!(one.container.as_deref(), Some("mkv"));
    // The sheet always starts from the catalog's item, so the quality comes first.
    let small = base.in_quality(DownloadQuality::Hd720).with_audio(
        &Fake,
        &DownloadAudioChoice::Track(2),
        &film_streams(),
    );
    assert!(small.audio_index == Some(2) && small.converted());
    assert_eq!(
        small.in_quality(DownloadQuality::Original).audio_index,
        Some(2)
    );
    assert_eq!(
        small
            .in_quality(DownloadQuality::Original)
            .container
            .as_deref(),
        Some("mkv")
    );
}

#[test]
fn old_list_still_reads() {
    let json = r#"{"id":"a","konto":"u1","art":"film","titel":"T","bytes":1,"geladen":0,"stand":"fertig","gesehen":false,"angelegt":0,"nochAufDemServer":true}"#;
    let item: DownloadItem = serde_json::from_str(json).expect("old list reads");
    assert!(item.audio_index.is_none() && item.replaces.is_none() && item.next_pending.is_none());
    let again: DownloadItem = serde_json::from_slice(
        &serde_json::to_vec(&item.with_audio_index(3, Some("de".into()))).expect("encode"),
    )
    .expect("decode");
    assert!(again.audio_index == Some(3) && again.audio_language.as_deref() == Some("de"));
}

#[test]
fn the_end_is_ninety_percent() {
    assert!(DownloadRules::reached_end(900, Some(1_000)));
    assert!(!DownloadRules::reached_end(899, Some(1_000)));
    assert!(!DownloadRules::reached_end(900, None));
}

fn watched_ep(id: &str, season: i64, number: i64) -> DownloadItem {
    DownloadItem {
        art: Art::Episode,
        title: "x".into(),
        series: Some("S".into()),
        series_identifier: Some("s1".into()),
        season: Some(season),
        episode: Some(number),
        container: Some("mkv".into()),
        bytes: 1_000,
        state: DownloadState::Done,
        watched: true,
        ..DownloadItem::new(id, "u1", Art::Episode, "x", 1_000, 0.0)
    }
}

#[test]
fn following_episode() {
    let list = [
        episode_item("a", 0, 1, vec![]),
        episode_item("b", 1, 2, vec![]),
        episode_item("c", 1, 3, vec![]),
        episode_item("d", 2, 1, vec![]),
    ];
    let id = |p: DownloadItem| DownloadRules::following_episode(&p, &list).map(|i| i.id.clone());
    assert_eq!(id(watched_ep("e1", 1, 2)).as_deref(), Some("c"));
    assert_eq!(id(watched_ep("e1", 1, 3)).as_deref(), Some("d"));
    assert_eq!(id(watched_ep("e1", 2, 1)), None);
}

#[test]
fn follow_up_keeps_quality_and_audio() {
    let old = watched_ep("e1", 1, 1)
        .in_quality(DownloadQuality::Hd720)
        .with_audio_index(2, Some("en".into()));
    let next = episode_item(
        "e2",
        1,
        2,
        vec![
            audio_stream(1, "eng", "ac3", false),
            audio_stream(2, "ger", "ac3", false),
        ],
    );
    let follower = DownloadRules::follow_up(&Fake, &old, &next, 42.0);
    assert!(follower.id == "e2" && follower.replaces.as_deref() == Some("e1"));
    assert_eq!(follower.quality, Some(DownloadQuality::Hd720));
    assert!(follower.audio_index == Some(1) && follower.audio_language.as_deref() == Some("en"));
    assert!(follower.state == DownloadState::Waits && !follower.watched);
    assert_eq!(follower.created, 42.0);
    // A file without the language is loaded whole, the language is carried on.
    let other = episode_item(
        "e3",
        1,
        3,
        vec![
            audio_stream(1, "fra", "ac3", false),
            audio_stream(2, "ger", "ac3", false),
        ],
    );
    let whole = DownloadRules::follow_up(&Fake, &old, &other, 42.0);
    assert!(whole.audio_index.is_none() && whole.audio_language.as_deref() == Some("en"));
}

#[test]
fn replaced() {
    let mut follower = watched_ep("e2", 1, 2);
    follower.replaces = Some("e1".into());
    follower.watched = false;
    let r = |item: &DownloadItem, list: &[DownloadItem]| DownloadRules::replaced_one(item, list);
    assert_eq!(
        r(&follower, &[watched_ep("e1", 1, 1), follower.clone()]).as_deref(),
        Some("e1")
    );
    let running = DownloadItem {
        state: DownloadState::Loads,
        ..follower.clone()
    };
    assert_eq!(
        r(&running, &[watched_ep("e1", 1, 1), running.clone()]),
        None
    );
    let unwatched = DownloadItem {
        watched: false,
        ..watched_ep("e1", 1, 1)
    };
    assert_eq!(r(&follower, &[unwatched, follower.clone()]), None);
    assert_eq!(r(&follower, std::slice::from_ref(&follower)), None);
}

// Offline helpers without a Swift test of their own.

#[test]
fn post_playback_thresholds() {
    let p = DownloadItem {
        runtime_ticks: Some(1_000),
        ..entry("a")
    };
    let low = p.post_playback(40, 5.0); // 4 %: no position
    assert!(low.point_ticks.is_none() && !low.watched && low.recent == Some(5.0));
    let mid = p.post_playback(500, 5.0);
    assert_eq!(mid.point_ticks, Some(500));
    let end = p.post_playback(900, 5.0);
    assert!(end.watched && end.point_ticks.is_none());
    // Watched stays watched in between, like the server.
    let again = DownloadItem { watched: true, ..p }.post_playback(500, 6.0);
    assert!(again.watched && again.point_ticks == Some(500));
    assert_eq!(again.resume_from(), 0.0);
}

#[test]
fn episode_post_skips_gaps_and_specials() {
    let list = [
        DownloadItem {
            season: Some(0),
            ..watched_ep("sp", 0, 1)
        },
        watched_ep("e1", 1, 1),
        watched_ep("e5", 1, 5),
        DownloadItem {
            state: DownloadState::Loads,
            ..watched_ep("e6", 1, 6)
        },
    ];
    assert_eq!(
        DownloadRules::episode_post("e1", &list).map(|p| p.id.as_str()),
        Some("e5")
    );
    assert!(DownloadRules::episode_post("e5", &list).is_none());
    assert_eq!(
        DownloadRules::episode_post("sp", &list).map(|p| p.id.as_str()),
        Some("e1")
    );
}

#[test]
fn follow_keeps_newer_local_state() {
    use swiftly_model::UserItemData;
    let p = DownloadItem {
        recent: Some(2_000.0),
        watched: true,
        ..entry("a")
    };
    let server = UserItemData {
        played: Some(false),
        last_played_date: Some("1970-01-01T00:16:40Z".into()), // 1000 s
        ..Default::default()
    };
    assert_eq!(DownloadRules::follow(&p, Some(&server)), p);
    let newer = UserItemData {
        played: Some(false),
        playback_position_ticks: Some(7),
        last_played_date: Some("1970-01-01T00:50:00Z".into()), // 3000 s
        ..Default::default()
    };
    let q = DownloadRules::follow(&p, Some(&newer));
    assert!(!q.watched && q.point_ticks == Some(7) && q.recent == Some(3_000.0));
    assert_eq!(DownloadRules::follow(&p, None), p);
}

// MARK: bidirectional progress sync (fake clock: the moments are plain numbers)

fn server_state(last: &str, ticks: Option<i64>, played: bool) -> swiftly_model::UserItemData {
    swiftly_model::UserItemData {
        playback_position_ticks: ticks,
        played: Some(played),
        last_played_date: Some(last.into()),
        ..Default::default()
    }
}

#[test]
fn offline_playback_is_reported_when_newer_than_the_server() {
    let mut p = entry("a");
    p.runtime_ticks = Some(1_000_000_000);
    let p = p.post_playback(400_000_000, 5_000.0);
    // Server saw it at 1000 s (1970-01-01T00:16:40Z): the local position is newer.
    let s = server_state("1970-01-01T00:16:40Z", Some(100_000_000), false);
    assert_eq!(
        DownloadRules::unreported_progress(&p, Some(&s)),
        Some((400_000_000, 5_000.0))
    );
    // Never played on the server: reported too.
    assert_eq!(
        DownloadRules::unreported_progress(&p, None),
        Some((400_000_000, 5_000.0))
    );
}

#[test]
fn an_older_or_equal_local_state_is_not_reported_and_never_moves_the_server_back() {
    let mut p = entry("a");
    p.runtime_ticks = Some(1_000_000_000);
    let p = p.post_playback(400_000_000, 1_000.5);
    // Equal within the one second of slack.
    let same = server_state("1970-01-01T00:16:40Z", Some(900_000_000), false);
    assert_eq!(DownloadRules::unreported_progress(&p, Some(&same)), None);
    // Server is newer.
    let newer = server_state("1970-01-01T01:00:00Z", Some(900_000_000), false);
    assert_eq!(DownloadRules::unreported_progress(&p, Some(&newer)), None);
}

#[test]
fn nothing_to_report_without_a_position_and_a_finished_title_reports_its_length() {
    let mut p = entry("a");
    p.runtime_ticks = Some(1_000_000_000);
    // Below 5 %: no position, must not send 0 over the server's.
    let early = p.post_playback(10_000_000, 5_000.0);
    assert_eq!(DownloadRules::unreported_progress(&early, None), None);
    // Never played: no moment.
    assert_eq!(DownloadRules::unreported_progress(&p, None), None);
    // Watched to the end offline: the full length goes out.
    let end = p.post_playback(980_000_000, 5_000.0);
    assert!(end.watched);
    assert_eq!(
        DownloadRules::unreported_progress(&end, None),
        Some((1_000_000_000, 5_000.0))
    );
}

#[test]
fn a_newer_server_state_updates_the_download_and_a_newer_local_one_is_kept() {
    let mut p = entry("a");
    p.runtime_ticks = Some(1_000_000_000);
    let local = p.post_playback(200_000_000, 2_000.0);
    // Watched on another device later: the download follows.
    let later = server_state("1970-01-01T01:00:00Z", Some(700_000_000), false);
    let pulled = DownloadRules::follow(&local, Some(&later));
    assert_eq!(pulled.point_ticks, Some(700_000_000));
    assert_eq!(pulled.recent, Some(3_600.0));
    // An older server state does not take the local position back.
    let older = server_state("1970-01-01T00:10:00Z", Some(50_000_000), false);
    assert_eq!(
        DownloadRules::follow(&local, Some(&older)).point_ticks,
        Some(200_000_000)
    );
}

#[test]
fn progress_sync_transition_table() {
    use swiftly_downloads::{ProgressSync as S, SyncEvent as E, SyncRefused};
    let mut base = entry("a");
    base.runtime_ticks = Some(1_000_000_000);
    let ahead = base.post_playback(400_000_000, 5_000.0);
    let la = S::LocalAhead {
        ticks: 400_000_000,
        moment: 5_000.0,
    };
    let newer = server_state("1970-01-01T05:00:00Z", Some(1), false);
    // Answer re-judges from every state.
    for from in [S::Unknown, S::Offline, S::Synced, la, S::ServerAhead] {
        assert_eq!(from.transition(&ahead, E::Answer(None)), Ok(la));
        assert_eq!(
            from.transition(&ahead, E::Answer(Some(&newer))),
            Ok(S::ServerAhead)
        );
    }
    // No network: a due report stays due, everything else is offline.
    assert_eq!(la.transition(&ahead, E::NoNetwork), Ok(la));
    for from in [S::Unknown, S::Offline, S::Synced, S::ServerAhead] {
        assert_eq!(from.transition(&ahead, E::NoNetwork), Ok(S::Offline));
    }
    // Reported only fits LocalAhead.
    assert_eq!(la.transition(&ahead, E::Reported), Ok(S::Synced));
    for from in [S::Unknown, S::Offline, S::Synced, S::ServerAhead] {
        assert_eq!(from.transition(&ahead, E::Reported), Err(SyncRefused));
    }
}
