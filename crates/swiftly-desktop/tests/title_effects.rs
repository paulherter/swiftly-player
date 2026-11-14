//! The effects of the core on the title pages are carried out by the host (the Mac's `DetailView.drain`,
//! `drainSeries`): "Von vorn" plays, the trailer starts, the watched toggle tells the lists.

use swiftly_desktop::detail_screen::DetailScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

fn env() -> Env {
    Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop)
}

fn settled() -> (DetailScreen, f64) {
    let mut s = DetailScreen::new(env(), Cx::deterministic(), Scenario::Ready);
    let _ = s.frame(0.0);
    s.open(0.0);
    let mut now = 0.0;
    while now < 1500.0 {
        now += 1000.0 / 60.0;
        let _ = s.frame(now);
    }
    (s, now)
}

#[test]
fn from_start_in_the_more_menu_asks_for_the_version_and_plays_from_second_zero() {
    let (mut s, mut now) = settled();
    assert!(s.take_play().is_none());
    s.vm().send(swiftly_vm::DetailIntent::Menu(
        swiftly_vm::MenuKind::PlayFromStart,
    ));
    for _ in 0..4 {
        now += 17.0;
        let _ = s.frame(now);
    }
    // The demo title has two versions: the core's `Play` effect shows the choice, headed with the core's word.
    assert_eq!(s.sheet_kind(), 2, "the version sheet is open");
    let f = s.frame_of("version:1").expect("the second version row");
    s.touch_down(f[0] + 8.0, f[1] + 8.0, now);
    s.touch_up(f[0] + 8.0, f[1] + 8.0, now + 30.0);
    for _ in 0..4 {
        now += 17.0;
        let _ = s.frame(now);
    }
    let req = s.take_play().expect("the pick started playback");
    assert_eq!(req.since, 0.0, "from the start, not from the resume point");
    assert_eq!(req.source_id.as_deref(), Some("s1080"));
}

fn series() -> (swiftly_desktop::series_screen::SeriesScreen, f64) {
    let mut s = swiftly_desktop::series_screen::SeriesScreen::new(
        env(),
        Cx::deterministic(),
        Scenario::Ready,
    );
    let _ = s.frame(0.0);
    s.open(0.0);
    let mut now = 0.0;
    while now < 1500.0 {
        now += 1000.0 / 60.0;
        let _ = s.frame(now);
    }
    (s, now)
}

#[test]
fn the_series_menu_entry_next_episode_plays_the_next_episode() {
    let (mut s, mut now) = series();
    assert!(s.take_play().is_none());
    s.vm().send(swiftly_vm::SeriesIntent::Menu(
        swiftly_vm::MenuKind::NextEpisode,
    ));
    for _ in 0..4 {
        now += 17.0;
        let _ = s.frame(now);
    }
    let req = s.take_play().expect("the core's effect started playback");
    assert_eq!(
        req.item_id, "e4",
        "the episode after the one the main button names"
    );
}

#[test]
fn the_series_page_shows_the_proof_row_of_the_core() {
    let (s, _) = series();
    let text: String = s
        .a11y_nodes()
        .iter()
        .map(|n| format!("{n:?}"))
        .collect::<Vec<_>>()
        .join(" ");
    assert!(
        text.contains("ab 12"),
        "age rating of the proof row on the page: {text:.300}"
    );
}
