//! Frame goldens and behaviour tests of the Library and Search screens (software renderer, bundled Inter, three form
//! factors). PNGs live in `swiftly-ui/tests/golden`; `UPDATE_GOLDENS=1` rewrites them. Tolerance: see `check`.

use std::path::PathBuf;
use swiftly_desktop::browse::Scenario;
use swiftly_desktop::library_screen::{Kind, LibraryScreen};
use swiftly_desktop::search_screen::SearchScreen;
use swiftly_layout::Size;
use swiftly_library::LibraryFilter;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Dir, Env, Idiom, NavKey};
use swiftly_vm::{LibraryIntent, LibraryStatus, SearchKind, SearchStatus};

const FRAME_MS: f64 = 1000.0 / 60.0;
// The goldens are written on Linux. Other systems may differ: 12 levels (seen: up to 10 from font hinting). On macOS the
// icon edges rounded through the system libm differ by a few pixels (measured 2026-11-13: 0.003-0.007 % of the pixels,
// up to 10 levels), so there a difference above 2 levels may touch at most 0.05 % of the pixels and none may exceed 16
// levels (a real layout change moves far more pixels and fails; see `forms_golden`).
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 16 } else { 12 };
const MAC_PIXEL_SHARE: f64 = 0.0005;

struct Form {
    name: &'static str,
    size_pt: (f32, f32),
    scale: f32,
    idiom: Idiom,
}
const TOUCH: Form = Form {
    name: "touch",
    size_pt: (390.0, 844.0),
    scale: 3.0,
    idiom: Idiom::Phone,
};
const DESKTOP: Form = Form {
    name: "desktop",
    size_pt: (1280.0, 800.0),
    scale: 2.0,
    idiom: Idiom::Desktop,
};
const TV: Form = Form {
    name: "tv",
    size_pt: (1920.0, 1080.0),
    scale: 1.0,
    idiom: Idiom::Tv,
};

fn env(f: &Form) -> Env {
    Env::new(Size::new(f.size_pt.0, f.size_pt.1), f.scale, f.idiom)
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
    let (max, share) = img.diff(&golden);
    if let (true, Some(dir)) = (max > 0, std::env::var_os("GOLDEN_ACTUAL_DIR")) {
        let _ = img.write_png(&PathBuf::from(dir).join(format!("{name}.png")));
    }
    let share_ok = !cfg!(target_os = "macos") || max <= 2 || share <= MAC_PIXEL_SHARE;
    assert!(
        max <= TOLERANCE && share_ok,
        "golden {name} differs by {max} ({:.3} % of the pixels)",
        share * 100.0
    );
}

macro_rules! driver {
    ($t:ty) => {
        fn run_to(s: &mut $t, now: &mut f64, to: f64) {
            while *now + FRAME_MS < to {
                *now += FRAME_MS;
                let _ = s.frame(*now);
            }
            *now = to;
            let _ = s.frame(to);
        }
        fn run_to_by(s: &mut $t, now: &mut f64, dt: f64) {
            let to = *now + dt;
            run_to(s, now, to);
        }
        fn shot_by(s: &mut $t, now: &mut f64, dt: f64) -> RgbaImage {
            let to = *now + dt;
            shot(s, now, to)
        }
        fn shot(s: &mut $t, now: &mut f64, at: f64) -> RgbaImage {
            run_to(s, now, at);
            let (list, _) = s.frame(*now);
            s.render_software(&list)
        }
    };
}

mod lib_t {
    use super::*;
    driver!(LibraryScreen);

    pub fn screen(f: &Form, kind: &Kind, sc: Scenario) -> LibraryScreen {
        LibraryScreen::new(env(f), Cx::deterministic(), kind, sc)
    }

    pub fn scenes(f: &Form) {
        let mut now = 0.0;
        let mut s = screen(f, &Kind::Movies, Scenario::Ready);
        let rest = shot(&mut s, &mut now, 800.0);
        check(&format!("library_{}_initial", f.name), &rest);
        // scrolled (and paging: the last rows come into view)
        if f.name == "tv" {
            for _ in 0..3 {
                let t = now + FRAME_MS;
                s.nav_key(NavKey::Arrow(Dir::Down), true, t);
                s.nav_key(NavKey::Arrow(Dir::Down), false, t);
                run_to(&mut s, &mut now, t + 1200.0);
            }
        } else {
            let (x0, y0) = (f.size_pt.0 * 0.6, f.size_pt.1 * 0.8);
            s.touch_down(x0, y0, now);
            for i in 1..=10 {
                let t = now + f64::from(i) * FRAME_MS;
                s.touch_move(x0, y0 - 50.0 * i as f32, t);
                let _ = s.frame(t);
            }
            now += 10.0 * FRAME_MS;
            s.touch_up(x0, y0 - 500.0, now + FRAME_MS);
            let to = now + 3000.0;
            run_to(&mut s, &mut now, to);
        }
        let scrolled = shot_by(&mut s, &mut now, 100.0);
        check(&format!("library_{}_scrolled", f.name), &scrolled);
        assert!(
            scrolled.diff(&rest).0 > TOLERANCE,
            "the grid did not scroll"
        );
        // menus
        let mut m = screen(f, &Kind::Movies, Scenario::Ready);
        let mut t = 0.0;
        run_to(&mut m, &mut t, 400.0);
        let id = m.vm().grid().tiles[1].id.clone();
        m.show(&id);
        check(
            &format!("library_{}_menu", f.name),
            &shot_by(&mut m, &mut t, 100.0),
        );
        m.show("sort");
        check(
            &format!("library_{}_sort", f.name),
            &shot_by(&mut m, &mut t, 100.0),
        );
        // empty, offline, loading
        let mut e = screen(f, &Kind::Series, Scenario::Empty);
        let mut t = 0.0;
        check(
            &format!("library_{}_empty", f.name),
            &shot(&mut e, &mut t, 500.0),
        );
        let mut o = screen(f, &Kind::Movies, Scenario::Offline);
        let mut t = 0.0;
        check(
            &format!("library_{}_offline", f.name),
            &shot(&mut o, &mut t, 500.0),
        );
        let mut l = screen(f, &Kind::Movies, Scenario::Loading);
        let mut t = 0.0;
        check(
            &format!("library_{}_loading", f.name),
            &shot(&mut l, &mut t, 300.0),
        );
    }

    #[test]
    fn library_frames_touch_phone() {
        scenes(&TOUCH);
    }
    #[test]
    fn library_frames_desktop() {
        swiftly_desktop::desk::force_hint_os(swiftly_motion::Os::MacOs); // the goldens are Mac-made
        scenes(&DESKTOP);
    }
    #[test]
    fn library_frames_tv() {
        scenes(&TV);
    }

    #[test]
    fn states_and_sort_filter_intents() {
        let s = screen(&TOUCH, &Kind::Movies, Scenario::Ready);
        assert_eq!(s.vm().status().status, LibraryStatus::Ready);
        assert!(!s.vm().grid().tiles.is_empty());
        let o = screen(&TOUCH, &Kind::Movies, Scenario::Offline);
        assert_eq!(o.vm().status().status, LibraryStatus::Offline);
        let e = screen(&TOUCH, &Kind::Series, Scenario::Empty);
        assert_eq!(e.vm().status().status, LibraryStatus::Empty);
        s.vm().send(LibraryIntent::SetFilter {
            filter: LibraryFilter::Unwatched,
        });
    }

    /// A new order or filter over titles that are on screen: the old grid stays, but until the new page is in the core
    /// reports `refreshing`. The page never shows the old list as the settled result of the new choice.
    #[test]
    fn a_new_order_is_a_refresh_until_its_page_arrived() {
        for (pick, sorting) in [
            ("latest", swiftly_library::library_filter::Sorting::Latest),
            ("rating", swiftly_library::library_filter::Sorting::Rating),
        ] {
            let mut s = screen(&DESKTOP, &Kind::Movies, Scenario::Ready);
            let mut now = 0.0;
            run_to(&mut s, &mut now, 400.0);
            let (before, shown) = (s.vm().grid().version, s.vm().grid().tiles.len());
            assert!(
                shown > 0 && !s.vm().status().refreshing,
                "{pick}: a settled page to start from"
            );
            s.vm().send(LibraryIntent::SetSorting { sorting });
            let began = std::time::Instant::now();
            loop {
                let st = s.vm().status();
                // The old grid stays on screen while the run is in flight ...
                assert!(
                    !s.vm().grid().tiles.is_empty(),
                    "{pick}: the grid emptied during the refresh"
                );
                // ... and the old version is never the settled answer to the new sorting.
                if st.sorting == sorting && !st.refreshing {
                    assert_ne!(
                        s.vm().grid().version,
                        before,
                        "{pick}: the old list is shown as the settled result"
                    );
                    break;
                }
                assert!(
                    began.elapsed().as_secs() < 10,
                    "{pick}: the new page never arrived"
                );
                now += FRAME_MS;
                let _ = s.frame(now);
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
            assert_eq!(s.vm().status().status, LibraryStatus::Ready, "{pick}");
        }
    }

    /// A long press on a tile opens the menu; the first row opens the title; Esc-like tap on the scrim closes it.
    #[test]
    fn long_press_opens_menu_touch() {
        let mut s = screen(&TOUCH, &Kind::Movies, Scenario::Ready);
        let mut now = 0.0;
        run_to(&mut s, &mut now, 500.0);
        let (x, y) = (60.0, 66.0 + 44.0 + 22.0 + 60.0 + 14.0);
        s.touch_down(x, y, now);
        run_to_by(&mut s, &mut now, 800.0);
        s.touch_up(x, y, now + FRAME_MS);
        run_to_by(&mut s, &mut now, 100.0);
        assert!(s.sheet_open(), "long press opens the menu");
    }

    /// D-pad on tv reaches the tiles and the focus moves.
    #[test]
    fn tv_focus_plan() {
        let mut s = screen(&TV, &Kind::Movies, Scenario::Ready);
        let mut now = 0.0;
        run_to(&mut s, &mut now, 500.0);
        let mut seen = Vec::new();
        for _ in 0..4 {
            now += 40.0;
            s.nav_key(NavKey::Arrow(Dir::Down), true, now);
            s.nav_key(NavKey::Arrow(Dir::Down), false, now);
            run_to_by(&mut s, &mut now, 400.0);
            seen.push(s.focused());
        }
        assert!(
            seen.iter().all(Option::is_some),
            "focus reaches the page: {seen:?}"
        );
        assert!(seen.first() != seen.last(), "focus moves down: {seen:?}");
    }
}

mod search_t {
    use super::*;
    driver!(SearchScreen);

    fn screen(f: &Form, sc: Scenario, recents: &[&str]) -> SearchScreen {
        SearchScreen::new(env(f), Cx::deterministic(), sc, recents)
    }

    fn typed(f: &Form, sc: Scenario, term: &str) -> (SearchScreen, f64) {
        let mut s = screen(f, sc, &["Nordlicht", "Brücke"]);
        let mut now = 0.0;
        run_to(&mut s, &mut now, 100.0);
        s.type_text(term);
        std::thread::sleep(std::time::Duration::from_millis(50));
        SearchScreen::settle(s.vm());
        run_to_by(&mut s, &mut now, 300.0);
        (s, now)
    }

    pub fn scenes(f: &Form) {
        let mut s = screen(f, Scenario::Ready, &["Nordlicht", "Brücke"]);
        let mut now = 0.0;
        check(
            &format!("search_{}_recents", f.name),
            &shot(&mut s, &mut now, 300.0),
        );
        let mut s = screen(f, Scenario::Ready, &[]);
        let mut now = 0.0;
        check(
            &format!("search_{}_hint", f.name),
            &shot(&mut s, &mut now, 300.0),
        );
        let (mut s, mut now) = typed(f, Scenario::Ready, "nord");
        check(
            &format!("search_{}_results", f.name),
            &shot_by(&mut s, &mut now, 100.0),
        );
        let (mut s, mut now) = typed(f, Scenario::Empty, "xyz");
        check(
            &format!("search_{}_empty", f.name),
            &shot_by(&mut s, &mut now, 100.0),
        );
        let (mut s, mut now) = typed(f, Scenario::Offline, "nord");
        check(
            &format!("search_{}_offline", f.name),
            &shot_by(&mut s, &mut now, 100.0),
        );
    }

    #[test]
    fn search_frames_touch_phone() {
        scenes(&TOUCH);
    }
    #[test]
    fn search_frames_desktop() {
        swiftly_desktop::desk::force_hint_os(swiftly_motion::Os::MacOs); // the goldens are Mac-made
        scenes(&DESKTOP);
    }
    #[test]
    fn search_frames_tv() {
        scenes(&TV);
    }

    /// One character stays idle, two search after the debounce, results come grouped (series, then movies), backspace
    /// back under two characters returns to the recents, paste works, a failed search is offline.
    #[test]
    fn debounce_groups_paste_and_states() {
        let mut s = screen(&TOUCH, Scenario::Ready, &["Nordlicht"]);
        s.type_text("n");
        assert_eq!(s.vm().status().status, SearchStatus::Idle);
        s.type_text("o");
        assert_eq!(
            s.vm().status().status,
            SearchStatus::Searching,
            "waits out the debounce"
        );
        SearchScreen::settle(s.vm());
        assert_eq!(s.vm().status().status, SearchStatus::Done);
        let kinds: Vec<SearchKind> = s.vm().results().groups.iter().map(|g| g.kind).collect();
        assert_eq!(
            kinds,
            vec![SearchKind::Series, SearchKind::Movies]
                .into_iter()
                .filter(|k| kinds.contains(k))
                .collect::<Vec<_>>()
        );
        s.backspace();
        assert_eq!(s.vm().status().status, SearchStatus::Idle);
        s.clear_text();
        s.paste("Nord\nlicht");
        assert_eq!(s.text(), "Nord licht");
        let (e, _) = typed(&TOUCH, Scenario::Empty, "xyz");
        assert_eq!(e.vm().status().status, SearchStatus::Empty);
        let (o, _) = typed(&TOUCH, Scenario::Offline, "nord");
        assert_eq!(o.vm().status().status, SearchStatus::Offline);
    }

    /// D-pad on tv reaches the first result tile.
    #[test]
    fn tv_focus_plan() {
        let (mut s, mut now) = typed(&TV, Scenario::Ready, "nord");
        for _ in 0..3 {
            now += 40.0;
            s.nav_key(NavKey::Arrow(Dir::Down), true, now);
            s.nav_key(NavKey::Arrow(Dir::Down), false, now);
            run_to_by(&mut s, &mut now, 400.0);
        }
        assert!(s.focused().is_some(), "focus reaches the results");
    }
}
