//! Frame goldens and behaviour tests of the Downloads page after `MacDownloads.swift` (software renderer, bundled Inter).
//! PNGs live in `swiftly-ui/tests/golden`; `UPDATE_GOLDENS=1` rewrites them.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use swiftly_desktop::downloads_screen::{DownloadsScreen, LoadRequest, Scenario};
use swiftly_desktop::net_watch::{NetState, NetworkWatcher, Pump};
use swiftly_layout::Size;
use swiftly_model::{Item, MediaSource, UserItemData};
use swiftly_render::RgbaImage;
use swiftly_ui::a11y::A11yNode;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::{DownloadsIntent, RowState};

const FRAME_MS: f64 = 1000.0 / 60.0;
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 2 } else { 12 };

fn mac() -> Env {
    Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop)
}

fn check(name: &str, img: &RgbaImage) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("golden {name}: {e}"));
        println!("golden {name}: written");
        return;
    }
    let golden = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("golden {name}: {e}"));
    assert_eq!(
        (img.width, img.height),
        (golden.width, golden.height),
        "golden {name}: size"
    );
    let (max, _) = img.diff(&golden);
    assert!(max <= TOLERANCE, "golden {name} differs by {max}");
}

fn shoot(d: &mut DownloadsScreen, now: &mut f64, at: f64) -> RgbaImage {
    while *now + FRAME_MS < at {
        *now += FRAME_MS;
        let _ = d.frame(*now);
    }
    *now = at;
    let _ = d.frame(at);
    let (list, _) = d.frame(at);
    d.render_software(&list)
}

fn all(nodes: &[A11yNode], out: &mut Vec<(String, Option<String>)>) {
    for n in nodes {
        out.push((n.label.clone(), n.value.clone()));
        all(&n.children, out);
    }
}

fn labels(d: &DownloadsScreen) -> Vec<(String, Option<String>)> {
    let mut v = Vec::new();
    all(&d.a11y_nodes(), &mut v);
    v
}

#[test]
fn mac_frames() {
    let mut now = 0.0;
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::States);
    check("downloads_mac_states", &shoot(&mut d, &mut now, 400.0));
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::Mixed);
    let mut now = 0.0;
    d.press("edit");
    d.press("row:e4");
    d.press("row:f1");
    check("downloads_mac_edit", &shoot(&mut d, &mut now, 500.0));
    d.press("edit");
    let id = d
        .vm()
        .list()
        .rows
        .iter()
        .find(|r| r.items.len() > 1)
        .map(|r| r.id.clone())
        .unwrap_or_default();
    d.press(&format!("grp:{id}"));
    assert_eq!(d.series(), Some(id.as_str()));
    check("downloads_mac_series", &shoot(&mut d, &mut now, 900.0));
    d.show_menu("row:e2");
    check(
        "downloads_mac_series_menu",
        &shoot(&mut d, &mut now, 1200.0),
    );
}

#[test]
fn ring_labels_and_sublines_follow_the_mac_app() {
    let mut now = 0.0;
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::States);
    let _ = shoot(&mut d, &mut now, 300.0);
    let v = labels(&d);
    for word in [
        "Wartet",
        "L\u{00E4}dt, anhalten",
        "Angehalten, fortsetzen",
        "Auf diesem PC",
        "Fehlgeschlagen, erneut versuchen",
    ] {
        assert!(
            v.iter().any(|(l, _)| l == word),
            "ring label {word} missing in {v:?}"
        );
    }
    let sub = |title: &str| {
        v.iter()
            .find(|(l, _)| l == title)
            .and_then(|(_, s)| s.clone())
            .unwrap_or_default()
    };
    assert_eq!(sub("Der lange Weg"), "1,08 von 2,40 GB");
    assert_eq!(sub("Nachts im Zug"), "wartet");
    assert_eq!(sub("Stille Wasser"), "angehalten");
    assert_eq!(sub("Kaputte Kopie"), "Fehlgeschlagen");
    assert_eq!(sub("Das letzte Licht"), "1,2 GB");
}

#[test]
fn ring_click_edit_and_delete_have_no_question() {
    let mut now = 0.0;
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::Mixed);
    let _ = shoot(&mut d, &mut now, 300.0);
    let state = |d: &DownloadsScreen, id: &str| {
        d.vm()
            .list()
            .rows
            .iter()
            .flat_map(|r| r.items.iter())
            .find(|i| i.id == id)
            .map(|i| i.state)
    };
    d.press("ring:f1");
    assert_eq!(
        state(&d, "f1"),
        Some(RowState::Paused),
        "a click on a loading ring pauses"
    );
    d.press("ring:f1");
    assert_ne!(
        state(&d, "f1"),
        Some(RowState::Paused),
        "a click on a paused ring resumes"
    );
    d.press("ring:f2");
    assert_eq!(
        state(&d, "f2"),
        Some(RowState::Done),
        "a finished ring does nothing"
    );
    d.press("edit");
    assert!(d.editing());
    d.press("row:f2");
    d.press("delete");
    assert!(!d.editing(), "deleting leaves edit mode");
    assert!(
        state(&d, "f2").is_none(),
        "removed at once, no confirmation"
    );
    assert!(!d.sheet_open());
    let _ = d.vm().send(DownloadsIntent::Pause("f1".into()));
}

fn film_item(id: &str, title: &str, bytes: i64) -> swiftly_downloads::DownloadItem {
    swiftly_downloads::DownloadItem::new(id, "u1", swiftly_downloads::Art::Film, title, bytes, 50.0)
}

fn episode_item(id: &str, name: &str, season: i64, number: i64, watched: bool) -> Item {
    Item {
        id: id.into(),
        name: name.into(),
        index_number: Some(number),
        parent_index_number: Some(season),
        user_data: Some(UserItemData {
            played: Some(watched),
            ..UserItemData::default()
        }),
        media_sources: Some(vec![MediaSource {
            size: Some(900_000_000),
            container: Some("mkv".into()),
            ..MediaSource::default()
        }]),
        ..Item::default()
    }
}

fn season_request() -> LoadRequest {
    let season = |id: &str, name: &str| Item {
        id: id.into(),
        name: name.into(),
        ..Item::default()
    };
    let mut episodes = HashMap::new();
    episodes.insert(
        "se1".to_owned(),
        (1..=4)
            .map(|n| episode_item(&format!("a{n}"), &format!("Folge {n}"), 1, n, n == 1))
            .collect(),
    );
    episodes.insert(
        "se2".to_owned(),
        (1..=3)
            .map(|n| episode_item(&format!("b{n}"), &format!("Folge {n}"), 2, n, false))
            .collect(),
    );
    LoadRequest::Season {
        account: "u1".into(),
        series: Box::new(Item {
            id: "s9".into(),
            name: "Die Nachbarn".into(),
            ..Item::default()
        }),
        seasons: vec![
            season("se1", "Staffel 1"),
            season("se2", "Staffel 2"),
            season("se3", "Staffel 3"),
        ],
        episodes,
        quality_select: false,
        anchor: None,
    }
}

#[test]
fn add_sheet_follows_load_panel() {
    let mut now = 0.0;
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::Empty);
    let _ = shoot(&mut d, &mut now, 100.0);
    d.request_load(LoadRequest::Add {
        title: "Der Zug".into(),
        items: vec![film_item("n1", "Der Zug", 2_400_000_000)],
        images: HashMap::new(),
        quality_select: false,
        streams: Vec::new(),
        anchor: None,
    });
    assert!(d.load_open());
    check("downloads_mac_add", &shoot(&mut d, &mut now, 500.0));
    // Esc closes the sheet but leaves the page.
    d.back(now);
    assert!(!d.load_open() && d.is_open(), "Esc closes only the sheet");
    d.request_load(LoadRequest::Add {
        title: "Der Zug".into(),
        items: vec![film_item("n2", "Zu gro\u{00DF}", 400_000_000_000)],
        images: HashMap::new(),
        quality_select: false,
        streams: Vec::new(),
        anchor: None,
    });
    check("downloads_mac_add_full", &shoot(&mut d, &mut now, 900.0));
    d.press("load.close");
    assert!(!d.load_open());
    d.request_load(LoadRequest::Add {
        title: "Der Zug".into(),
        items: vec![film_item("n1", "Der Zug", 2_400_000_000)],
        images: HashMap::new(),
        quality_select: false,
        streams: Vec::new(),
        anchor: None,
    });
    let _ = shoot(&mut d, &mut now, 1200.0);
    d.press("load.go");
    assert!(!d.load_open(), "Laden closes the sheet");
    assert!(
        d.vm().entries().iter().any(|e| e.id == "n1"),
        "Laden queues the title"
    );
}

#[test]
fn season_sheet_selects_with_the_download_rules() {
    let mut now = 0.0;
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::Empty);
    d.request_load(season_request());
    assert_eq!(
        d.season_pending(),
        vec![vec!["se3".to_owned()]],
        "the third season still has to be read"
    );
    check("downloads_mac_season", &shoot(&mut d, &mut now, 500.0));
    d.press("sel.open:se1");
    check("downloads_mac_season_open", &shoot(&mut d, &mut now, 900.0));
    d.season_loaded(
        "se3",
        Some(vec![episode_item("c1", "Folge 1", 3, 1, false)]),
    );
    d.season_finished();
    assert!(d.season_pending().is_empty());
    // "Nur ungesehene" leaves the watched episode out of "Ganze Serie".
    d.press("sel.onlyun");
    d.press("sel.all");
    d.press("sel.go");
    assert!(!d.load_open());
    let mut ids: Vec<String> = d.vm().entries().into_iter().map(|e| e.id).collect();
    ids.sort();
    assert_eq!(
        ids,
        ["a2", "a3", "a4", "b1", "b2", "b3", "c1"],
        "watched a1 stays out"
    );
    let first = d.vm().entries().into_iter().find(|e| e.id == "b2").unwrap();
    assert_eq!(
        (first.season, first.episode, first.series.as_deref()),
        (Some(2), Some(2), Some("Die Nachbarn"))
    );
}

#[test]
fn a_failed_season_does_not_stand_empty() {
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::Empty);
    d.request_load(LoadRequest::Season {
        account: "u1".into(),
        series: Box::new(Item::default()),
        seasons: vec![Item {
            id: "x".into(),
            name: "Staffel 1".into(),
            ..Item::default()
        }],
        episodes: HashMap::new(),
        quality_select: false,
        anchor: None,
    });
    d.season_loaded("x", None);
    d.season_finished();
    let mut now = 0.0;
    let _ = shoot(&mut d, &mut now, 300.0);
    assert!(
        labels(&d)
            .iter()
            .any(|(l, _)| l.contains("Erneut versuchen")),
        "the retry button is there: {:?}",
        labels(&d)
    );
    d.press("sel.retry");
    assert_eq!(d.season_pending(), vec![vec!["x".to_owned()]]);
}

struct FakeNet(Mutex<NetState>);
impl NetworkWatcher for FakeNet {
    fn state(&self) -> NetState {
        *self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[test]
fn the_network_watcher_drives_wartet_auf_netz() {
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::Mixed);
    let fake = FakeNet(Mutex::new(NetState::ONLINE));
    let mut pump = Pump::new();
    assert!(pump.poll(&fake, d.vm()), "the first answer is reported");
    assert!(!pump.poll(&fake, d.vm()), "the same answer is not");
    assert!(!d.vm().storage().offline);
    *fake
        .0
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = NetState::OFFLINE;
    assert!(pump.poll(&fake, d.vm()));
    assert!(
        d.vm().storage().offline,
        "the page shows \"Wartet auf Netz\""
    );
    let mut now = 0.0;
    let _ = shoot(&mut d, &mut now, 300.0);
    *fake
        .0
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = NetState::ONLINE;
    assert!(pump.poll(&fake, d.vm()));
    assert!(
        !d.vm().storage().offline,
        "the wait is over when the network returns"
    );
    let f1 = d
        .vm()
        .list()
        .rows
        .iter()
        .flat_map(|r| r.items.iter())
        .find(|i| i.id == "f1")
        .map(|i| i.state);
    assert_ne!(f1, Some(RowState::Failed), "waiting titles do not fail");
    // Unknown metering counts as allowed: the Wi-Fi rule never blocks a connected desktop.
    let _ = d.vm().send(DownloadsIntent::OnlyOverWlan(true));
    assert!(!pump.poll(&fake, d.vm()));
    assert!(!d.vm().storage().waiting_for_wlan);
}

#[test]
fn delete_key_removes_the_selection() {
    let mut now = 0.0;
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::Mixed);
    let _ = shoot(&mut d, &mut now, 300.0);
    assert!(!d.delete_key(), "outside edit mode the key does nothing");
    d.press("edit");
    assert!(!d.delete_key(), "and without a selection");
    d.press("row:f2");
    assert_eq!(d.selected(), ["f2"]);
    assert!(d.delete_key());
    assert!(!d.editing());
    assert!(d.vm().entries().iter().all(|e| e.id != "f2"));
    // The same on the series page.
    let id = d
        .vm()
        .list()
        .rows
        .iter()
        .find(|r| r.items.len() > 1)
        .map(|r| r.id.clone())
        .unwrap_or_default();
    d.press(&format!("grp:{id}"));
    d.press("edit");
    d.press("row:e2");
    assert!(d.delete_key());
    assert!(d.vm().entries().iter().all(|e| e.id != "e2"));
    d.pointer_move(10.0, 10.0, now);
    d.pointer_leave(now);
}

#[test]
fn check_circle_and_ring_state_animate() {
    let mut now = 0.0;
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::States);
    let _ = shoot(&mut d, &mut now, 400.0);
    // The ring of the loading title pauses: the new face is revealed over 0.28 s, then it rests.
    d.press("ring:a1");
    let early = shoot(&mut d, &mut now, 440.0);
    let mid = shoot(&mut d, &mut now, 520.0);
    let late = shoot(&mut d, &mut now, 1000.0);
    let rest = shoot(&mut d, &mut now, 1100.0);
    assert!(early.diff(&mid).0 > 0, "the ring face is still arriving");
    assert!(mid.diff(&late).0 > 0, "and arrives");
    assert_eq!(late.diff(&rest).0, 0, "then rests");
    // The check circles slide in with edit mode.
    d.press("edit");
    let a = shoot(&mut d, &mut now, 1140.0);
    let b = shoot(&mut d, &mut now, 1180.0);
    let c = shoot(&mut d, &mut now, 1700.0);
    assert!(
        a.diff(&b).0 > 0 && b.diff(&c).0 > 0,
        "the check circle comes in over several frames: {} {}",
        a.diff(&b).0,
        b.diff(&c).0
    );
}

#[test]
fn loading_rows_keep_frames_coming() {
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::Mixed);
    let _ = d.frame(0.0);
    assert!(d.wants_frame(), "a loading row counts at 10 Hz");
}

fn film_streams() -> Vec<swiftly_downloads::AudioStream> {
    let track = |i: i64, lang: &str| swiftly_downloads::AudioStream {
        codec: Some("ac3".into()),
        kind: "Audio".into(),
        language: Some(lang.into()),
        display_title: None,
        channels: Some(6),
        is_default: None,
        index: Some(i),
    };
    vec![track(1, "ger"), track(2, "eng")]
}

#[test]
fn the_add_sheet_has_a_sound_row_and_menus_under_its_buttons() {
    let mut now = 0.0;
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::Empty);
    let anchor = Some(swiftly_layout::Rect::new(420.0, 260.0, 120.0, 36.0));
    d.request_load(LoadRequest::Add {
        title: "Der Zug".into(),
        items: vec![film_item("n1", "Der Zug", 2_400_000_000)],
        images: HashMap::new(),
        quality_select: true,
        streams: vec![film_streams()],
        anchor,
    });
    let _ = shoot(&mut d, &mut now, 600.0);
    assert!(
        labels(&d).iter().any(|(l, _)| l == "Ton"),
        "the sound row is there: {:?}",
        labels(&d)
    );
    // The sound button opens a menu with its own keys; Esc closes the menu and leaves the sheet.
    d.press("load.sound");
    assert!(d.sheet_open(), "the sound menu is open");
    let _ = shoot(&mut d, &mut now, 900.0);
    d.back(now);
    assert!(!d.sheet_open() && d.load_open(), "Esc closes only the menu");
    d.press("load.quality");
    assert!(d.sheet_open(), "the quality menu is open");
    check("downloads_mac_add_menu", &shoot(&mut d, &mut now, 1200.0));
    d.press("load.q:1");
    assert!(!d.sheet_open() && d.load_open(), "a choice closes the menu");
    d.press("load.sound");
    d.press("load.a:2");
    d.press("load.go");
    assert!(!d.load_open());
    let n1 = d
        .vm()
        .entries()
        .into_iter()
        .find(|e| e.id == "n1")
        .expect("queued");
    assert_eq!(
        n1.audio_index,
        Some(2),
        "the chosen track goes with the title"
    );
}

#[test]
fn the_season_sheet_grows_out_of_its_button() {
    let mut now = 0.0;
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::Empty);
    let LoadRequest::Season {
        account,
        series,
        seasons,
        episodes,
        quality_select,
        ..
    } = season_request()
    else {
        unreachable!()
    };
    d.request_load(LoadRequest::Season {
        account,
        series,
        seasons,
        episodes,
        quality_select,
        anchor: Some(swiftly_layout::Rect::new(60.0, 120.0, 150.0, 40.0)),
    });
    // It starts small and see-through and settles (the leap curve), the card is at its place then.
    let early = shoot(&mut d, &mut now, 40.0);
    let settled = shoot(&mut d, &mut now, 700.0);
    assert_ne!(early.pixels, settled.pixels, "the card moves in");
    check("downloads_mac_season_anchor", &settled);
    d.press("sel.open:se1");
    let mid = shoot(&mut d, &mut now, 760.0);
    let end = shoot(&mut d, &mut now, 1300.0);
    assert_ne!(mid.pixels, end.pixels, "the card height follows the rows");
}

/// The row is a button on the desktop (`Dim` style): Tab reaches it, Return opens the series, and the series page goes back
/// by itself when its last episode is removed (`onChange(of: episodes.isEmpty)`).
#[test]
fn rows_take_tab_and_return_and_the_series_page_goes_back_when_empty() {
    use swiftly_ui::NavKey;
    let mut now = 0.0;
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), Scenario::Mixed);
    let _ = shoot(&mut d, &mut now, 300.0);
    let id = d
        .vm()
        .list()
        .rows
        .iter()
        .find(|r| r.items.len() > 1)
        .map(|r| r.id.clone())
        .unwrap_or_default();
    let want = swiftly_ui::components::focus_id(format!("grp:{id}").as_str());
    for _ in 0..30 {
        if d.focused() == Some(want) {
            break;
        }
        d.nav_key(NavKey::Tab, true, now);
        d.nav_key(NavKey::Tab, false, now);
        now += 20.0;
        let _ = d.frame(now);
    }
    assert_eq!(d.focused(), Some(want), "Tab reaches the series row");
    d.nav_key(NavKey::Enter, true, now);
    d.nav_key(NavKey::Enter, false, now);
    assert_eq!(d.series(), Some(id.as_str()), "Return opens it");
    let all: Vec<String> = d
        .vm()
        .entries()
        .iter()
        .filter(|e| e.series.is_some())
        .map(|e| e.id.clone())
        .collect();
    d.press("edit");
    for e in &all {
        d.press(&format!("row:{e}"));
    }
    assert!(d.delete_key());
    now += 20.0;
    let _ = d.frame(now);
    assert_eq!(d.series(), None, "the page went back");
}
