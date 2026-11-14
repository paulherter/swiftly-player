//! The live season sheet of a series: the "Laden" of the series page emits a typed request, and `SeasonRead` feeds the
//! season sheet (seasons first, then the episodes of each season in batches) from a source (a fake here).

use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_desktop::downloads_screen::{DownloadsScreen, Scenario as DlScenario};
use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::live_downloads::{SeasonRead, SeasonSource};
use swiftly_desktop::series_screen::SeriesScreen;
use swiftly_layout::Size;
use swiftly_model::Item;
use swiftly_ui::{Cx, Dir, Env, Idiom, NavKey};

fn mac() -> Env {
    Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop)
}

struct Fake {
    fail: Option<&'static str>,
}

fn item(id: &str, name: &str) -> Item {
    Item {
        id: id.into(),
        name: name.into(),
        ..Item::default()
    }
}

impl SeasonSource for Fake {
    fn seasons(&self, series: &str) -> Option<Vec<Item>> {
        assert_eq!(series, "s1");
        Some(vec![
            item("se1", "Staffel 1"),
            item("se2", "Staffel 2"),
            item("se3", "Staffel 3"),
            item("se4", "Staffel 4"),
        ])
    }
    fn episodes(&self, series: &str, season: &str) -> Option<Vec<Item>> {
        assert_eq!(series, "s1");
        if self.fail == Some(season) {
            return None;
        }
        Some(
            (1..=2)
                .map(|n| Item {
                    index_number: Some(n),
                    parent_index_number: Some(1),
                    ..item(&format!("{season}e{n}"), &format!("Folge {n}"))
                })
                .collect(),
        )
    }
}

/// What the suite does per frame with a read: poll, open, answer, finish.
fn pump(read: &mut Option<SeasonRead>, d: &mut DownloadsScreen) {
    let Some(mut r) = read.take() else { return };
    let pending: Vec<String> = d.season_pending().concat();
    let poll = r.poll(d.load_open(), &pending);
    if let Some(req) = poll.open {
        d.request_load(req);
    }
    for (id, eps) in poll.loaded {
        d.season_loaded(&id, eps);
    }
    if poll.finished {
        d.season_finished();
    }
    if !poll.gone {
        *read = Some(r);
    }
}

fn run(read: &mut Option<SeasonRead>, d: &mut DownloadsScreen) {
    let start = Instant::now();
    while read.is_some() && start.elapsed() < Duration::from_secs(5) {
        pump(read, d);
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn the_series_page_asks_for_the_season_sheet() {
    let mut s = SeriesScreen::new(mac(), Cx::deterministic(), Scenario::Ready);
    let mut now = 0.0;
    s.open(now);
    for _ in 0..80 {
        now += 1000.0 / 60.0;
        let _ = s.frame(now);
    }
    assert_eq!(s.take_download(), None, "nothing asked yet");
    let f = s.frame_of("more").expect("the more button");
    let (x, y) = (f[0] + f[2] / 2.0, f[1] + f[3] / 2.0);
    s.touch_down(x, y, now);
    s.touch_up(x, y, now + 40.0);
    let _ = s.frame(now + 60.0);
    assert!(s.menu_open(), "the more menu is open");
    // The rows are the core's entries (`more_menu`), "Laden" follows them.
    let rows = s.vm().more_menu().len() + 1;
    for i in 0..rows {
        s.nav_key(NavKey::Arrow(Dir::Down), true, now + 100.0 + i as f64);
    }
    s.nav_key(NavKey::Enter, true, now + 140.0 + rows as f64);
    let asked = s.take_download().expect("Laden emits the request");
    assert!(asked.is_some(), "with the rect of the button it came from");
    assert_eq!(s.take_download(), None, "once");
}

#[test]
fn the_live_read_feeds_the_season_sheet() {
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), DlScenario::Empty);
    let mut read = Some(SeasonRead::start(
        Arc::new(Fake { fail: None }),
        "s1",
        "Die Nachbarn",
        "u1",
        None,
    ));
    run(&mut read, &mut d);
    assert!(read.is_none(), "the read ends by itself");
    assert!(d.load_open(), "the sheet is open");
    assert!(d.season_pending().is_empty(), "every season is answered");
    // Pick the whole series: eight episodes go to the list.
    d.press("sel.all");
    d.press("sel.go");
    assert_eq!(d.vm().entries().len(), 8);
}

#[test]
fn a_failed_season_ends_the_read_and_can_be_retried() {
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), DlScenario::Empty);
    let mut read = Some(SeasonRead::start(
        Arc::new(Fake { fail: Some("se2") }),
        "s1",
        "Die Nachbarn",
        "u1",
        None,
    ));
    run(&mut read, &mut d);
    assert!(read.is_none() && d.load_open());
    d.press("sel.all");
    d.press("sel.go");
    assert_eq!(
        d.vm().entries().len(),
        6,
        "the three seasons that were read"
    );
}

#[test]
fn closing_the_sheet_drops_the_read() {
    let mut d = DownloadsScreen::new(mac(), Cx::deterministic(), DlScenario::Empty);
    let mut read = Some(SeasonRead::start(
        Arc::new(Fake { fail: None }),
        "s1",
        "Die Nachbarn",
        "u1",
        None,
    ));
    let start = Instant::now();
    while !d.load_open() && start.elapsed() < Duration::from_secs(5) {
        pump(&mut read, &mut d);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(d.load_open());
    d.press("load.close");
    pump(&mut read, &mut d);
    assert!(read.is_none(), "no sheet, no read");
}
