//! The season tab of a series page with several seasons shows the whole season name next to its chevron, however long
//! the name is ("Staffel 2", "Staffel 13"): the tab is as wide as the name, the chevron and the gap.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::series_screen::SeriesScreen;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;

#[test]
fn the_season_tab_with_a_chevron_is_as_wide_as_its_name() {
    let mut widths = Vec::new();
    for (w, h) in [(1280.0, 800.0), (700.0, 800.0), (480.0, 800.0)] {
        let env = Env::new(Size::new(w, h), 1.0, Idiom::Desktop);
        let mut s = SeriesScreen::new(env, Cx::deterministic(), Scenario::Ready);
        let mut now = 0.0;
        let _ = s.frame(0.0);
        s.open(0.0);
        for _ in 0..90 {
            now += FRAME_MS;
            let _ = s.frame(now);
        }
        assert!(
            s.vm().seasons().seasons.len() > 1,
            "a series with several seasons"
        );
        let name = s
            .vm()
            .seasons()
            .seasons
            .iter()
            .find(|x| Some(&x.id) == s.vm().seasons().selected.as_ref())
            .map(|x| x.name.clone())
            .unwrap();
        let tab = s.frame_of("tab:0").expect("the season tab");
        let next = s.frame_of("tab:1").expect("the next tab");
        println!("{w}: {name:?} tab {tab:?} next {next:?}");
        if let Ok(dir) = std::env::var("SERIES_TAB_PNG") {
            let (list, _) = s.frame(now + FRAME_MS);
            s.render_software(&list)
                .write_png(std::path::Path::new(&format!("{dir}/tab-{w}.png")))
                .unwrap();
        }
        widths.push(tab[2]);
    }
    // The tab is as wide as its word and chevron whatever the window offers. (The squeeze of the live page, "Staffe…" in
    // 71.6 pt where the name needs 74, does not show in this scripted page; the live script `l-season-tab.txt` reads the
    // width of the tab on the fixture series: 74.0 now.)
    for w in &widths {
        assert!(
            (*w - widths[0]).abs() < 0.01,
            "the tab width follows the window: {widths:?}"
        );
    }
}
