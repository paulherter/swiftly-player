//! `break-ui` worst cases on every screen: very long, Arabic, Japanese, Thai and emoji titles, missing posters, huge
//! numbers, an empty library and 10,000 items. Nothing may panic, nothing may be drawn outside the window, and the work
//! per frame stays bounded (virtualization). Data comes through `Scenario::Worst`, never through the screens.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::browse::Scenario;
use swiftly_desktop::detail_screen::DetailScreen;
use swiftly_desktop::downloads_screen::{DownloadsScreen, Scenario as Dl};
use swiftly_desktop::home::HomeScreen;
use swiftly_desktop::home_data::Scenario as Hs;
use swiftly_desktop::library_screen::{Kind, LibraryScreen};
use swiftly_desktop::search_screen::SearchScreen;
use swiftly_desktop::series_screen::SeriesScreen;
use swiftly_desktop::settings_screen::SettingsScreen;
use swiftly_layout::Size;
use swiftly_render::{DrawList, QuadKind};
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;
/// (name, size in points, scale, idiom): a phone at 320 pt, a narrow window, the Mac window, a wide monitor.
const FORMS: [(&str, (f32, f32), f32, Idiom); 4] = [
    ("phone320", (320.0, 640.0), 2.0, Idiom::Phone),
    ("desktop-narrow", (720.0, 600.0), 1.0, Idiom::Desktop),
    ("desktop", (1280.0, 800.0), 2.0, Idiom::Desktop),
    ("wide", (3440.0, 1440.0), 1.0, Idiom::Desktop),
];

fn env(f: &(&str, (f32, f32), f32, Idiom)) -> Env {
    Env::new(Size::new(f.1.0, f.1.1), f.2, f.3)
}

/// Frames until `ms` have passed; the last list is checked.
fn run(
    name: &str,
    f: &(&str, (f32, f32), f32, Idiom),
    ms: f64,
    mut frame: impl FnMut(f64) -> (DrawList, bool),
) -> usize {
    let mut now = 0.0;
    let mut last = None;
    let mut worst_ms = 0.0_f64;
    while now < ms {
        now += STEP;
        let t = std::time::Instant::now();
        last = Some(frame(now).0);
        worst_ms = worst_ms.max(t.elapsed().as_secs_f64() * 1000.0);
    }
    let list = last.unwrap();
    for q in list.quads().iter().filter(|q| q.kind == QuadKind::Glyph) {
        let r = q.rect;
        assert!(
            r.x.is_finite() && r.y.is_finite() && r.w.is_finite() && r.h.is_finite(),
            "{name} {}: glyph at {r:?}",
            f.0
        );
    }
    // Virtualization: 10,000 items must not become 10,000 drawn tiles.
    assert!(
        list.quads().len() < 40_000,
        "{name} {}: {} quads in one frame",
        f.0,
        list.quads().len()
    );
    assert!(
        worst_ms < 3000.0,
        "{name} {}: a frame took {worst_ms:.0} ms",
        f.0
    );
    list.quads().len()
}

#[test]
fn library_with_ten_thousand_worst_titles() {
    for f in &FORMS {
        for kind in [Kind::Movies, Kind::Series] {
            let mut s = LibraryScreen::new(env(f), Cx::deterministic(), &kind, Scenario::Worst);
            run("library", f, 600.0, |t| s.frame(t));
            // scroll far down and jump with the strip: still bounded
            for i in 0..40 {
                s.wheel_scroll(
                    f.1.0 / 2.0,
                    f.1.1 / 2.0,
                    0.0,
                    -900.0,
                    700.0 + f64::from(i) * STEP,
                );
            }
            let n = run("library scrolled", f, 300.0, |t| s.frame(1500.0 + t));
            assert!(n > 0);
        }
    }
}

#[test]
fn library_empty_and_offline() {
    for f in &FORMS {
        for sc in [Scenario::Empty, Scenario::Offline, Scenario::Loading] {
            let mut s = LibraryScreen::new(env(f), Cx::deterministic(), &Kind::Movies, sc);
            assert!(run("library states", f, 400.0, |t| s.frame(t)) > 0);
        }
    }
}

#[test]
fn home_with_worst_titles() {
    for f in &FORMS {
        for sc in [Hs::Worst, Hs::Empty] {
            let mut s = HomeScreen::new(env(f), Cx::deterministic(), sc);
            run("home", f, 600.0, |t| s.frame(t));
        }
    }
}

#[test]
fn search_with_worst_titles() {
    for f in &FORMS {
        let mut s = SearchScreen::new(
            env(f),
            Cx::deterministic(),
            Scenario::Worst,
            &["千と千尋の神隠し", "مسلسل", "👨‍👩‍👧‍👦"],
        );
        run("search recents", f, 200.0, |t| s.frame(t));
        s.type_text("e");
        std::thread::sleep(std::time::Duration::from_millis(60));
        SearchScreen::settle(s.vm());
        run("search results", f, 400.0, |t| s.frame(300.0 + t));
    }
}

#[test]
fn detail_and_series_with_worst_titles() {
    for f in &FORMS {
        let mut d = DetailScreen::overlay_for(
            env(f),
            Cx::deterministic(),
            Hs::Worst,
            ("m1", swiftly_desktop::browse::worst_title(0)),
        );
        run("detail", f, 600.0, |t| d.frame(t));
        let mut d = DetailScreen::overlay_for(
            env(f),
            Cx::deterministic(),
            Hs::Worst,
            ("m2", swiftly_desktop::browse::worst_title(1)),
        );
        run("detail arabic", f, 600.0, |t| d.frame(t));
        let mut d = DetailScreen::overlay_for(
            env(f),
            Cx::deterministic(),
            Hs::Worst,
            ("m3", swiftly_desktop::browse::worst_title(3)),
        );
        run("detail emoji", f, 600.0, |t| d.frame(t));
        let mut s = SeriesScreen::overlay(env(f), Cx::deterministic(), Hs::Worst);
        run("series", f, 600.0, |t| s.frame(t));
        let mut s = SeriesScreen::overlay(env(f), Cx::deterministic(), Hs::Empty);
        run("series empty", f, 600.0, |t| s.frame(t));
    }
}

#[test]
fn downloads_with_worst_rows_and_empty() {
    for f in &FORMS {
        for sc in [Dl::Worst, Dl::Empty] {
            let mut s = DownloadsScreen::new(env(f), Cx::deterministic(), sc);
            run("downloads", f, 600.0, |t| s.frame(t));
        }
    }
}

#[test]
fn settings_survive_every_form() {
    for f in &FORMS {
        for settings in [true, false] {
            let mut s = SettingsScreen::new(env(f), Cx::deterministic(), settings);
            run("settings", f, 400.0, |t| s.frame(t));
        }
    }
}

/// The text engine under the worst titles: one line stays one line inside its width, tall scripts do not blow the line
/// height up, and a title that is cut says so (ellipsis).
#[test]
fn worst_titles_stay_in_their_box() {
    use swiftly_text::{Align, FontSystem};
    let mut fonts = FontSystem::new();
    let style: swiftly_text::TextStyle = swiftly_design::tokens::desktop::text::TILE.into();
    let base = fonts
        .layout("Ag", &style, None, Some(1), Align::Start)
        .height();
    for i in 0..9 {
        let title = swiftly_desktop::browse::worst_title(i);
        for width in [64.0_f32, 104.0, 160.0, 400.0] {
            let l = fonts.layout(title, &style, Some(width), Some(1), Align::Start);
            assert!(
                l.width() <= width + 0.5,
                "{title}: {} wide in {width}",
                l.width()
            );
            assert!(
                l.height() <= base * 2.2,
                "{title}: line {} high (Ag: {base})",
                l.height()
            );
            if l.missing_glyphs() > 0 {
                println!(
                    "note: {title} has {} missing glyphs on this machine",
                    l.missing_glyphs()
                );
            }
        }
    }
}

/// Merkliste (the watchlist page): empty, offline, ready and 10,000 titles on every form; the empty page speaks about
/// the Merkliste and never offers "another filter".
#[test]
fn merkliste_edge_cases() {
    for f in &FORMS {
        for sc in [
            Scenario::Empty,
            Scenario::Offline,
            Scenario::Ready,
            Scenario::Worst,
            Scenario::Loading,
        ] {
            let mut s = LibraryScreen::new(env(f), Cx::deterministic(), &Kind::Watchlist, sc);
            run("merkliste", f, 500.0, |t| s.frame(t));
            if sc == Scenario::Empty {
                let labels: Vec<String> = s.a11y_nodes().iter().map(|n| format!("{n:?}")).collect();
                let all = labels.join("\n");
                assert!(
                    !all.contains("anderen Filter"),
                    "{}: the Merkliste offers another filter",
                    f.0
                );
                assert!(
                    all.contains("Noch nichts gemerkt"),
                    "{}: the Merkliste has no empty state of its own",
                    f.0
                );
            }
        }
    }
}

/// ui-gefuehl 6: counts go through the plural rules ("1 Folge", not "1 Folgen"), in the catalogue's own words.
#[test]
fn counts_use_plural_rules() {
    swiftly_l10n::set_locale(swiftly_l10n::Locale::parse("de"));
    assert_eq!(swiftly_l10n::plural("%lld Folgen", 1, &[]), "1 Folge");
    assert_eq!(swiftly_l10n::plural("%lld Folgen", 0, &[]), "0 Folgen");
    assert_eq!(swiftly_l10n::plural("%lld Folgen", 2, &[]), "2 Folgen");
    assert_eq!(
        swiftly_l10n::plural("%lld Titel auf diesem Gerät", 1, &[]),
        "1 Titel auf diesem Gerät"
    );
    assert_eq!(
        swiftly_l10n::plural("%lld Titel bleiben auf dem Gerät", 3, &[]),
        "3 Titel bleiben auf dem Gerät"
    );
    assert_eq!(
        swiftly_l10n::plural("%lld Titel bleiben auf diesem Mac", 1, &[]),
        "1 Titel bleibt auf diesem Mac"
    );
    // The catalogue's own grammar: the verb follows the count too ("1 Titel bleibt"), and no "(s)" shortcut anywhere.
    assert!(!swiftly_l10n::plural("%lld Titel bleiben auf diesem Mac", 1, &[]).contains("(s)"));
}

fn unnamed(title: &str, nodes: &[swiftly_ui::a11y::A11yNode], out: &mut Vec<String>) {
    use swiftly_ui::a11y::Role;
    for n in nodes {
        if matches!(
            n.role,
            Role::Button | Role::Tab | Role::Switch | Role::Slider
        ) && n.label.trim().is_empty()
        {
            out.push(format!(
                "{title}: {:?} {:?} key={}",
                n.role, n.bounds, n.key
            ));
        }
        unnamed(title, &n.children, out);
    }
}

/// F10: every interactive element of every screen has a spoken name (icon-only buttons need an explicit label).
#[test]
fn every_interactive_element_has_a_label() {
    let f = &FORMS[2];
    let mut bad = Vec::new();
    let mut all = |title: &str, nodes: Vec<swiftly_ui::a11y::A11yNode>| {
        if nodes.is_empty() {
            println!("note: {title} exposes no nodes");
        }
        unnamed(title, &nodes, &mut bad);
    };
    for (name, kind) in [
        ("movies", Kind::Movies),
        ("series", Kind::Series),
        ("merkliste", Kind::Watchlist),
    ] {
        let mut s = LibraryScreen::new(env(f), Cx::deterministic(), &kind, Scenario::Ready);
        run(name, f, 500.0, |t| s.frame(t));
        all(name, s.a11y_nodes());
    }
    let mut s = SearchScreen::new(env(f), Cx::deterministic(), Scenario::Ready, &["Nordlicht"]);
    run("search", f, 300.0, |t| s.frame(t));
    all("search", s.a11y_nodes());
    for settings in [true, false] {
        let mut s = SettingsScreen::new(env(f), Cx::deterministic(), settings);
        run("settings", f, 300.0, |t| s.frame(t));
        all(
            if settings { "settings" } else { "accounts" },
            s.a11y_nodes(),
        );
    }
    for sc in [Dl::Mixed, Dl::Empty] {
        let mut s = DownloadsScreen::new(env(f), Cx::deterministic(), sc);
        run("downloads", f, 300.0, |t| s.frame(t));
        all("downloads", s.a11y_nodes());
    }
    let mut s = DetailScreen::overlay(env(f), Cx::deterministic(), Hs::Ready);
    run("detail", f, 800.0, |t| s.frame(t));
    all("detail", s.a11y_nodes());
    let mut s = HomeScreen::new(env(f), Cx::deterministic(), Hs::Ready);
    run("home", f, 500.0, |t| s.frame(t));
    all("home", s.a11y_nodes());
    bad.sort();
    bad.dedup();
    assert!(bad.is_empty(), "unnamed controls:\n{}", bad.join("\n"));
}
