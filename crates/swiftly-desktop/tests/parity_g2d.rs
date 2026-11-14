//! Round 4 of the shell parity (g2): the look glow behind Start, toasts, the version dialog, the account-switch fade of the
//! library and the pushed pages in the accessibility tree.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::home::HomeScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::look_glow::{self, Glow};
use swiftly_layout::Size;
use swiftly_render::QuadKind;
use swiftly_ui::{Cx, Env, Idiom};

fn home() -> HomeScreen {
    let mut s = HomeScreen::new(
        Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop),
        Cx::deterministic(),
        Scenario::Ready,
    );
    let mut t = 0.0;
    for _ in 0..40 {
        t += 16.0;
        let _ = s.frame(t);
    }
    s
}

#[test]
fn start_draws_the_look_glow_only_while_a_look_has_one() {
    look_glow::set(Glow::default());
    let mut s = home();
    let (list, _) = s.frame(1000.0);
    assert!(
        list.quads().iter().all(|q| q.kind != QuadKind::Radial),
        "the original look leaves Start as it is"
    );
    look_glow::set(Glow {
        tone: 0x00D4FF,
        tint: Some(0xFF00AA),
        strength: 200,
    });
    let mut s = home();
    let (list, _) = s.frame(1000.0);
    let glow: Vec<_> = list
        .quads()
        .iter()
        .filter(|q| q.kind == QuadKind::Radial)
        .collect();
    assert!(glow.len() >= 4, "main tone and tint: {}", glow.len());
    assert!(
        glow.iter()
            .all(|q| q.rect.x >= 219.5 && q.rect.y.abs() < 0.5),
        "behind the content column, from the top of the window"
    );
    look_glow::set(Glow::default());
}

#[test]
fn pushed_pages_are_in_the_accessibility_tree() {
    use swiftly_desktop::pages_screen::Kind;
    use swiftly_desktop::suite::Suite;
    for (kind, name, window) in [
        (Kind::Collection, "collection", "Sammlung"),
        (Kind::Person, "person", "Person"),
        (Kind::Genre, "genre", "Genre"),
        (Kind::Playlist, "playlist", "Playlist"),
    ] {
        let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
        let mut s = Suite::new(env, Cx::deterministic());
        let mut now = 0.0;
        for _ in 0..30 {
            now += 16.0;
            let _ = s.frame(now);
        }
        s.open_page(kind, now);
        for _ in 0..60 {
            now += 16.0;
            let _ = s.frame(now);
        }
        let (title, nodes) = s.a11y_nodes();
        assert_eq!(title, window, "{name}");
        let mut labels = Vec::new();
        fn walk(n: &[swiftly_ui::a11y::A11yNode], out: &mut Vec<String>) {
            for x in n {
                out.push(x.label.clone());
                walk(&x.children, out);
            }
        }
        walk(&nodes, &mut labels);
        // The sidebar and the window controls are always there; the page must add its own nodes on top of them.
        let mut t = Suite::new(env, Cx::deterministic());
        let _ = t.frame(16.0);
        let (_, n) = t.a11y_nodes();
        let mut base = Vec::new();
        walk(&n, &mut base);
        let own: Vec<&String> = labels
            .iter()
            .filter(|l| !l.is_empty() && !base.contains(l))
            .collect();
        assert!(
            own.len() >= 2,
            "{name}: the pushed page exposes no nodes of its own: {labels:?}"
        );
    }
}

/// Quads that look like the keyboard focus ring: an accent coloured inside border.
fn ring_quads(list: &swiftly_render::DrawList) -> usize {
    list.quads()
        .iter()
        .filter(|q| {
            q.border_width > 0.0
                && (q.border_color.g - 0.835).abs() < 0.02
                && q.border_color.a > 0.3
        })
        .count()
}

#[test]
fn the_keyboard_focus_mark_shows_after_a_key_and_goes_with_a_click() {
    use swiftly_desktop::suite::Suite;
    use swiftly_ui::{Dir, NavKey};
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    let frame = |s: &mut Suite, now: &mut f64| {
        let mut l = s.frame(*now + 16.0).0;
        for _ in 0..30 {
            *now += 16.0;
            l = s.frame(*now).0;
        }
        l
    };
    let quiet = ring_quads(&frame(&mut s, &mut now));
    s.nav_key(NavKey::Arrow(Dir::Right), true, now);
    s.nav_key(NavKey::Arrow(Dir::Right), false, now + 5.0);
    now += 10.0;
    let shown = ring_quads(&frame(&mut s, &mut now));
    assert!(shown > quiet, "a key shows the mark: {quiet} -> {shown}");
    s.touch_down(700.0, 400.0, now);
    s.touch_up(700.0, 400.0, now + 40.0);
    now += 80.0;
    let after_click = ring_quads(&frame(&mut s, &mut now));
    assert!(
        after_click <= quiet,
        "a click hides the mark: {quiet} -> {shown} -> {after_click}"
    );
}

fn two_versions() -> swiftly_desktop::live_play::VersionAsk {
    let v = |id: &str, label: &str| swiftly_vm::VersionOption {
        id: id.to_owned(),
        name: label.to_owned(),
        label: label.to_owned(),
    };
    swiftly_desktop::live_play::VersionAsk {
        item_id: "m1".into(),
        since: 0.0,
        versions: vec![
            v("a", "Kinofassung \u{b7} 2160p"),
            v("b", "Extended \u{b7} 1080p"),
        ],
    }
}

#[test]
fn the_shell_asks_which_version_over_the_whole_window_and_a_click_beside_closes_it() {
    use swiftly_desktop::suite::Suite;
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    for _ in 0..20 {
        now += 16.0;
        let _ = s.frame(now);
    }
    let plain = s.frame(now + 16.0).0.quads().len();
    assert!(!s.version_dialog_open());
    s.ask_versions(two_versions());
    assert!(s.version_dialog_open());
    now += 16.0;
    for _ in 0..30 {
        now += 16.0;
        let _ = s.frame(now);
    }
    let shown = s.frame(now + 16.0).0;
    assert!(
        shown.quads().len() > plain + 3,
        "the card and its rows are drawn"
    );
    // The dim ground covers the whole window, sidebar included.
    assert!(
        shown
            .quads()
            .iter()
            .rev()
            .take(60)
            .any(|q| q.rect.w >= 1279.0
                && q.rect.h >= 799.0
                && q.color.a > 0.2
                && q.color.r < 0.01)
    );
    // A click beside the card cancels; nothing starts (no live account here).
    s.touch_down(30.0, 30.0, now + 100.0);
    s.touch_up(30.0, 30.0, now + 140.0);
    assert!(!s.version_dialog_open());
}

#[test]
fn escape_closes_the_version_dialog_before_anything_else() {
    use swiftly_desktop::suite::Suite;
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let _ = s.frame(16.0);
    s.ask_versions(two_versions());
    assert!(s.back(32.0));
    assert!(!s.version_dialog_open());
}
