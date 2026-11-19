//! The subtitle search against a scripted server: language from the settings, finished rows, the states (loading,
//! results, empty, no provider, error, done), the download that waits for the track, Plex hidden.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use common::account;
use common::script::{GateSleeper, Script, host, wait_for};
use swiftly_jellyfin::ServerKind;
use swiftly_net::Method;
use swiftly_vm::{
    SubtitleSearchIntent, SubtitleSearchPhase, SubtitleSearchVm, subtitle_search_offered,
};

fn hits() -> String {
    serde_json::json!([
        {"Id": "p_low", "Name": "Movie.2020.WEB.de.srt", "ProviderName": "Open Subtitles", "Format": "srt",
         "ThreeLetterISOLanguageName": "ger", "CommunityRating": 5.5, "DownloadCount": 40},
        {"Id": "p_best", "Name": "Movie.2020.BluRay.de.srt", "ProviderName": "Open Subtitles", "Format": "srt",
         "ThreeLetterISOLanguageName": "ger", "CommunityRating": 8.25, "DownloadCount": 1204, "HearingImpaired": true},
        {"Id": "p_hash", "Name": "Movie.2020.exact.de.ass", "ProviderName": "Podnapisi", "Format": "ass",
         "ThreeLetterISOLanguageName": "ger", "IsHashMatch": true},
        "broken entry"
    ])
    .to_string()
}

fn item(subtitles: usize) -> String {
    let mut streams = vec![
        serde_json::json!({"Index": 0, "Type": "Video", "Codec": "h264"}),
        serde_json::json!({"Index": 1, "Type": "Audio", "Language": "eng", "DisplayTitle": "English"}),
    ];
    for n in 0..subtitles {
        streams.push(
            serde_json::json!({"Index": 2 + n, "Type": "Subtitle", "Language": "ger",
            "DisplayTitle": format!("Deutsch {n}"), "IsExternal": n > 0}),
        );
    }
    serde_json::json!({"Id": "m1", "Name": "Movie", "Type": "Movie",
        "MediaSources": [{"Id": "s1", "MediaStreams": streams}]})
    .to_string()
}

/// A server with a provider: the search answers `hits`, the download adds one subtitle to the title a few looks later.
struct Server {
    net: Arc<Script>,
    searched: Arc<std::sync::Mutex<Vec<String>>>,
    looks: Arc<AtomicUsize>,
}

fn server(search: String, plugins: &'static str) -> Server {
    let searched = Arc::new(std::sync::Mutex::new(Vec::new()));
    let downloaded = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let looks = Arc::new(AtomicUsize::new(0));
    let (s, d, l) = (searched.clone(), downloaded.clone(), looks.clone());
    let net = Script::new(move |r| {
        let path = r.url.path().to_owned();
        if path.contains("/RemoteSearch/Subtitles/") {
            if r.method == Method::Post {
                d.store(true, Ordering::SeqCst);
                return Some("{}".into());
            }
            s.lock()
                .unwrap()
                .push(path.rsplit('/').next().unwrap().to_owned());
            return Some(search.clone());
        }
        if path.ends_with("/Plugins") {
            return Some(plugins.into());
        }
        if path.ends_with("/Items/m1") {
            // The file shows after the second look at the title after the download.
            let after = d.load(Ordering::SeqCst);
            let n = if after {
                l.fetch_add(1, Ordering::SeqCst) + 1
            } else {
                0
            };
            return Some(item(if after && n >= 2 { 2 } else { 1 }));
        }
        Some("{}".into())
    });
    Server {
        net,
        searched,
        looks,
    }
}

fn open_gate() -> Arc<common::Gate> {
    let gate = Arc::new(common::Gate::default());
    gate.open();
    gate
}

fn vm(net: &Arc<Script>, language: &str) -> SubtitleSearchVm<Script> {
    SubtitleSearchVm::new(
        net.clone(),
        host(),
        Arc::new(GateSleeper(open_gate())),
        &account("TOKEN-A"),
        "m1",
        language,
    )
    .unwrap()
}

#[test]
fn it_searches_in_the_settings_language_and_shows_finished_rows_best_first() {
    let s = server(hits(), "[]");
    let vm = vm(&s.net, "Deutsch");
    assert_eq!(vm.part().phase, SubtitleSearchPhase::Idle);
    vm.send(SubtitleSearchIntent::Search { language: None });
    assert_eq!(vm.part().phase, SubtitleSearchPhase::Loading);
    wait_for("results", || {
        vm.part().phase == SubtitleSearchPhase::Results
    });
    assert_eq!(*s.searched.lock().unwrap(), ["deu"]);
    let part = vm.part();
    let ids: Vec<_> = part.rows.iter().map(|r| r.id.as_str()).collect();
    // The file's own hash first, then by rating; the broken entry is dropped, not the list.
    assert_eq!(ids, ["p_hash", "p_best", "p_low"]);
    let best = &part.rows[1];
    assert_eq!(best.source_line, "SRT · Open Subtitles");
    assert_eq!(best.rating.as_deref(), Some("8,2"));
    assert_eq!(
        best.meta_line,
        "Bewertung 8,2 · 1204 Downloads · Für Hörgeschädigte"
    );
    assert!(best.hearing_impaired);
    assert!(part.rows[0].matches_file);
    let langs: Vec<_> = part
        .languages
        .iter()
        .map(|l| (l.value.as_str(), l.selected))
        .collect();
    assert_eq!(langs, [("de", true), ("en", false)]);
    assert_eq!(part.languages[0].label, "Deutsch");
}

#[test]
fn an_empty_setting_searches_in_the_interface_language_and_a_language_can_be_picked() {
    let s = server(hits(), "[]");
    let vm = vm(&s.net, "");
    vm.send(SubtitleSearchIntent::Search { language: None });
    wait_for("results", || {
        vm.part().phase == SubtitleSearchPhase::Results
    });
    vm.send(SubtitleSearchIntent::Search {
        language: Some("en".into()),
    });
    wait_for("second results", || {
        vm.part().phase == SubtitleSearchPhase::Results && s.searched.lock().unwrap().len() == 2
    });
    assert_eq!(*s.searched.lock().unwrap(), ["deu", "eng"]);
    assert!(
        vm.part()
            .languages
            .iter()
            .any(|l| l.value == "en" && l.selected)
    );
    // A language the list does not offer is ignored.
    vm.send(SubtitleSearchIntent::Search {
        language: Some("xx".into()),
    });
    wait_for("third", || s.searched.lock().unwrap().len() == 3);
    assert_eq!(s.searched.lock().unwrap()[2], "eng");
}

#[test]
fn an_empty_list_is_no_provider_unless_a_provider_plugin_is_there() {
    let none = server(
        "[]".into(),
        r#"[{"Name":"Playback Reporting","Status":"Active"}]"#,
    );
    let vm_none = vm(&none.net, "Deutsch");
    vm_none.send(SubtitleSearchIntent::Search { language: None });
    wait_for("answer", || {
        vm_none.part().phase != SubtitleSearchPhase::Loading
    });
    let part = vm_none.part();
    assert_eq!(part.phase, SubtitleSearchPhase::NoProvider);
    assert_eq!(
        part.message.as_deref(),
        Some("Auf dem Server ist kein Untertitel-Anbieter eingerichtet.")
    );

    let some = server(
        "[]".into(),
        r#"[{"Name":"Open Subtitles","Status":"Active"}]"#,
    );
    let vm_some = vm(&some.net, "Deutsch");
    vm_some.send(SubtitleSearchIntent::Search { language: None });
    wait_for("answer", || {
        vm_some.part().phase != SubtitleSearchPhase::Loading
    });
    assert_eq!(vm_some.part().phase, SubtitleSearchPhase::Empty);
    assert_eq!(
        vm_some.part().message.as_deref(),
        Some("Keine Untertitel gefunden.")
    );
}

#[test]
fn a_failed_request_is_an_error_with_a_sentence_not_an_empty_page() {
    let s = server(hits(), "[]");
    *s.net.force.lock().unwrap() = Some((500, "boom".into()));
    let vm = vm(&s.net, "Deutsch");
    vm.send(SubtitleSearchIntent::Search { language: None });
    wait_for("failure", || vm.part().phase == SubtitleSearchPhase::Failed);
    assert!(vm.part().message.as_deref().is_some_and(|m| !m.is_empty()));
    // A new search after the server is back works.
    *s.net.force.lock().unwrap() = None;
    vm.send(SubtitleSearchIntent::Search { language: None });
    wait_for("results", || {
        vm.part().phase == SubtitleSearchPhase::Results
    });
}

#[test]
fn a_download_waits_for_the_track_and_lists_the_titles_subtitles() {
    let s = server(hits(), "[]");
    let vm = vm(&s.net, "Deutsch");
    vm.send(SubtitleSearchIntent::Search { language: None });
    wait_for("results", || {
        vm.part().phase == SubtitleSearchPhase::Results
    });
    vm.send(SubtitleSearchIntent::Download {
        id: "p_best".into(),
    });
    let busy = vm.part();
    assert_eq!(busy.phase, SubtitleSearchPhase::Downloading);
    assert_eq!(
        busy.rows
            .iter()
            .filter(|r| r.busy)
            .map(|r| r.id.as_str())
            .collect::<Vec<_>>(),
        ["p_best"]
    );
    wait_for("done", || vm.part().phase == SubtitleSearchPhase::Done);
    let part = vm.part();
    assert_eq!(part.added, 1);
    // The track the download added is the one the host switches on at the reload (the one that was not listed before).
    assert_eq!(part.selected_track, Some(part.tracks[1].index));
    assert_ne!(part.selected_track, Some(part.tracks[0].index));
    assert_eq!(part.tracks.len(), 2);
    assert!(part.tracks[1].external && part.tracks[1].label == "Deutsch 1");
    assert_eq!(part.message.as_deref(), Some("Untertitel hinzugefügt."));
    assert!(s.net.seen.lock().unwrap().iter().any(|r| {
        r.method == Method::Post
            && r.url
                .path()
                .ends_with("/Items/m1/RemoteSearch/Subtitles/p_best")
    }));
    // The model stopped looking once the track was there (two looks after the download, not all of them).
    assert_eq!(s.looks.load(Ordering::SeqCst), 2);
}

#[test]
fn a_download_that_the_server_refuses_is_an_error_and_keeps_the_rows() {
    let s = server(hits(), "[]");
    let vm = vm(&s.net, "Deutsch");
    vm.send(SubtitleSearchIntent::Search { language: None });
    wait_for("results", || {
        vm.part().phase == SubtitleSearchPhase::Results
    });
    *s.net.force.lock().unwrap() = Some((500, "no".into()));
    vm.send(SubtitleSearchIntent::Download { id: "p_low".into() });
    wait_for("failure", || vm.part().phase == SubtitleSearchPhase::Failed);
    assert_eq!(vm.part().rows.len(), 3);
    // Pressing a row while nothing is on offer does nothing.
    vm.send(SubtitleSearchIntent::Download { id: "p_low".into() });
    assert_eq!(vm.part().phase, SubtitleSearchPhase::Failed);
}

#[test]
fn plex_is_not_offered() {
    let mut plex = account("TOKEN-A");
    plex.server_kind = ServerKind::Plex;
    assert!(subtitle_search_offered(&account("TOKEN-A")));
    assert!(!subtitle_search_offered(&plex));
    let s = server(hits(), "[]");
    let made = SubtitleSearchVm::new(
        s.net.clone(),
        host(),
        Arc::new(GateSleeper(open_gate())),
        &plex,
        "m1",
        "Deutsch",
    );
    assert!(made.is_err());
    assert_eq!(s.net.urls().len(), 0);
}
