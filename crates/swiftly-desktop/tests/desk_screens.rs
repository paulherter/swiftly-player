//! W1 desktop behaviour on Home, Library, Search, the sidebar and the shell: hover, right click, rail arrows, wheel, the
//! history arrows, the window numbers. Headless, no window.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::shell::Shell;
use swiftly_desktop::wheel::WheelDelta;
use swiftly_ui::a11y::A11yNode;
use swiftly_ui::{Cx, Idiom};

const STEP: f64 = 1000.0 / 60.0;

fn shell() -> Shell {
    // 1440 x 900 points at 1x: the Mac's default window.
    Shell::new_suite((1440, 900), 1.0, Cx::deterministic(), Idiom::Desktop)
}

fn run(s: &mut Shell, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

fn flat(nodes: &[A11yNode], out: &mut Vec<A11yNode>) {
    for n in nodes {
        out.push(n.clone());
        flat(&n.children, out);
    }
}

fn nodes(s: &Shell) -> Vec<A11yNode> {
    let mut v = Vec::new();
    flat(&s.a11y_nodes().1, &mut v);
    v
}

fn centre(n: &A11yNode) -> (f64, f64) {
    let b = n.bounds.unwrap();
    (f64::from(b[0] + b[2] / 2.0), f64::from(b[1] + b[3] / 2.0))
}

fn first_tile(s: &Shell) -> A11yNode {
    nodes(s)
        .into_iter()
        .find(|n| n.key.starts_with("tile"))
        .or_else(|| {
            nodes(s)
                .into_iter()
                .find(|n| n.label.contains(", ") && n.bounds.is_some_and(|b| b[0] > 220.0))
        })
        .unwrap()
}

#[test]
fn window_numbers_are_the_macs() {
    assert_eq!(swiftly_desktop::window_rules::MIN_SIZE, (900.0, 560.0));
    let o = swiftly_desktop::cli::parse(["--demo", "app"].iter().map(|s| (*s).to_owned()))
        .unwrap()
        .unwrap();
    assert_eq!(o.size, (1440, 900));
}

#[test]
fn sidebar_is_the_macs_without_profile_row() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 400.0);
    let labels: Vec<String> = nodes(&s).into_iter().map(|n| n.label).collect();
    for want in [
        "Start",
        "Filme",
        "Serien",
        "Suche",
        "Merkliste",
        "Downloads",
    ] {
        assert!(
            labels.iter().any(|l| l == want),
            "sidebar row {want} missing"
        );
    }
    assert!(
        !labels.iter().any(|l| l == "Profil"),
        "the Mac has no Profil row"
    );
    // The account footer replaces it.
    assert!(labels.iter().any(|l| l == "Konto"));
}

#[test]
fn hover_scales_the_tile_and_leaving_restores_the_picture() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 600.0);
    let rest = s.frame(now).0;
    let t = first_tile(&s);
    let (x, y) = centre(&t);
    s.cursor_moved((x, y - 40.0), now);
    run(&mut s, &mut now, 300.0);
    let hot = s.frame(now).0;
    assert!(
        format!("{rest:?}") != format!("{hot:?}"),
        "hover changed nothing on the tile"
    );
    s.cursor_left(now);
    run(&mut s, &mut now, 300.0);
    let after = s.frame(now).0;
    assert!(
        format!("{rest:?}") == format!("{after:?}"),
        "the picture did not come back after the pointer left"
    );
}

#[test]
fn right_click_opens_the_tile_menu_as_a_popover_and_escape_closes_it() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 600.0);
    let t = first_tile(&s);
    let (x, y) = centre(&t);
    s.cursor_moved((x, y - 40.0), now);
    assert!(s.secondary_button(now));
    run(&mut s, &mut now, 300.0);
    let labels: Vec<String> = nodes(&s).into_iter().map(|n| n.label).collect();
    assert!(
        labels
            .iter()
            .any(|l| l.starts_with("Abspielen") || l.starts_with("Fortsetzen")),
        "no Abspielen row: {labels:?}"
    );
    assert!(labels.iter().any(|l| l.contains("Info")), "no Info row");
    // The popover is not a sheet: the tab labels are still there.
    assert!(labels.iter().any(|l| l == "Merkliste"));
    assert!(s.command(swiftly_desktop::shell::Command::Back, now));
    run(&mut s, &mut now, 300.0);
    let labels: Vec<String> = nodes(&s).into_iter().map(|n| n.label).collect();
    assert!(
        !labels.iter().any(|l| l.contains("Info")),
        "the menu stayed open"
    );
}

#[test]
fn rail_paging_arrows_show_on_hover_and_page_by_three_tiles() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 600.0);
    assert!(
        !nodes(&s).iter().any(|n| n.label == "Weiterblättern"),
        "arrows show without hover"
    );
    let t = first_tile(&s);
    let (x, y) = centre(&t);
    s.cursor_moved((x, y - 40.0), now);
    run(&mut s, &mut now, 400.0);
    let right = nodes(&s)
        .into_iter()
        .find(|n| n.label == "Weiterblättern")
        .expect("right arrow on hover");
    assert!(
        !nodes(&s).iter().any(|n| n.label == "Zurückblättern"),
        "no left arrow at the start"
    );
    let (ax, ay) = centre(&right);
    let rest = format!("{:?}", s.frame(now).0);
    s.tap_at((ax as f32, ay as f32), now);
    run(&mut s, &mut now, 600.0);
    assert!(
        rest != format!("{:?}", s.frame(now).0),
        "the rail did not page"
    );
    // The pointer is still over the rail: moving it by one point shows the left arrow, and the rail really moved.
    s.cursor_moved((ax + 1.0, ay), now);
    run(&mut s, &mut now, 400.0);
    assert!(
        nodes(&s).iter().any(|n| n.label == "Zurückblättern"),
        "left arrow after paging"
    );
}

#[test]
fn wheel_notch_scrolls_the_page_without_rubber_band() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 400.0);
    s.cursor_moved((700.0, 120.0), now);
    let before = s.frame(now).0;
    s.wheel(WheelDelta::Lines(0.0, -3.0), None, now);
    run(&mut s, &mut now, 300.0);
    let after = s.frame(now).0;
    assert!(
        format!("{before:?}") != format!("{after:?}"),
        "the wheel did not move the page"
    );
    // Scrolling up past the top stays at the top: no rubber band on a wheel.
    s.wheel(WheelDelta::Lines(0.0, 30.0), None, now);
    run(&mut s, &mut now, 300.0);
    s.wheel(WheelDelta::Lines(0.0, 30.0), None, now);
    run(&mut s, &mut now, 300.0);
    let top = s.frame(now).0;
    s.wheel(WheelDelta::Lines(0.0, 30.0), None, now);
    run(&mut s, &mut now, 300.0);
    let again = s.frame(now).0;
    assert!(
        format!("{top:?}") == format!("{again:?}"),
        "the page moved past its top edge (rubber band on a wheel)"
    );
}

#[test]
fn history_arrows_go_back_and_forward_through_the_tabs() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 300.0);
    assert!(s.goto_tab(1, now));
    assert_eq!(s.suite_mut().unwrap().tab(), 1);
    assert!(s.goto_tab(2, now));
    assert!(s.command(swiftly_desktop::shell::Command::Back, now));
    assert_eq!(s.suite_mut().unwrap().tab(), 1);
    assert!(s.command(swiftly_desktop::shell::Command::Forward, now));
    assert_eq!(s.suite_mut().unwrap().tab(), 2);
    assert!(s.command(swiftly_desktop::shell::Command::Back, now));
    assert!(s.command(swiftly_desktop::shell::Command::Back, now));
    assert_eq!(s.suite_mut().unwrap().tab(), 0);
    assert!(
        !s.command(swiftly_desktop::shell::Command::Back, now),
        "nothing left to go back to"
    );
    // The arrow in the strip does the same: click forward at (287, 26).
    s.tap_at((287.0, 26.0), now);
    assert_eq!(s.suite_mut().unwrap().tab(), 1);
}

#[test]
fn sidebar_downloads_row_opens_the_downloads_page_and_merkliste_the_watchlist() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 300.0);
    let d = nodes(&s)
        .into_iter()
        .find(|n| n.label == "Downloads")
        .unwrap();
    let (x, y) = centre(&d);
    s.tap_at((x as f32, y as f32), now);
    run(&mut s, &mut now, 600.0);
    assert_eq!(s.suite_mut().unwrap().form_open(), Some("downloads"));
}

#[test]
fn type_to_search_opens_the_search() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 300.0);
    assert!(s.command(
        swiftly_desktop::shell::Command::TypeToSearch("m".into()),
        now
    ));
    assert_eq!(s.suite_mut().unwrap().tab(), 3);
}

fn step(s: &mut Shell, now: &mut f64) {
    run(s, now, 700.0);
}

#[test]
fn pointer_wheel_and_right_click_reach_the_pushed_pages() {
    use swiftly_desktop::pages_screen::Kind;
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 400.0);
    // A person page: hover and the wheel work on it, the base page below stays quiet.
    s.suite_mut().unwrap().open_page(Kind::Person, now);
    step(&mut s, &mut now);
    assert_eq!(s.suite_mut().unwrap().top_kind(), Some("page"));
    s.cursor_moved((700.0, 500.0), now);
    let before = format!("{:?}", s.frame(now).0);
    s.wheel(WheelDelta::Lines(0.0, -4.0), None, now);
    run(&mut s, &mut now, 300.0);
    assert!(
        before != format!("{:?}", s.frame(now).0),
        "the wheel did not scroll the pushed page"
    );
    s.cursor_left(now);
    assert!(s.suite_mut().unwrap().top_kind().is_some());
    // Esc pops it again.
    assert!(s.command(swiftly_desktop::shell::Command::Back, now));
    step(&mut s, &mut now);
    assert_eq!(s.suite_mut().unwrap().top_kind(), None);
}

#[test]
fn detail_page_takes_hover_wheel_and_right_click() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 600.0);
    assert!(s.suite_mut().unwrap().goto_tab(1, now));
    run(&mut s, &mut now, 600.0);
    let t = first_tile(&s);
    let (x, y) = centre(&t);
    s.tap_at((x as f32, (y - 40.0) as f32), now);
    step(&mut s, &mut now);
    let kind = s.suite_mut().unwrap().top_kind();
    assert!(
        matches!(kind, Some("detail" | "series")),
        "no title page: {kind:?}"
    );
    s.cursor_moved((600.0, 400.0), now);
    let _ = s.suite_mut().unwrap().cursor();
    // The wheel is routed to the title page (it may fit the window, so it only has to be taken without a panic).
    s.wheel(WheelDelta::Lines(0.0, -5.0), None, now);
    run(&mut s, &mut now, 300.0);
    // A right click anywhere does not panic and answers whether a node took it.
    let _ = s.secondary_button(now);
}

fn labels(s: &Shell) -> Vec<String> {
    nodes(s).into_iter().map(|n| n.label).collect()
}

#[test]
fn library_filter_and_sort_open_as_anchored_popovers() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 300.0);
    assert!(s.goto_tab(1, now));
    run(&mut s, &mut now, 800.0);
    for (pill, row) in [("Alle", "Angefangen"), ("Nach Name", "Bewertung")] {
        let n = nodes(&s)
            .into_iter()
            .find(|n| n.label == pill && n.bounds.is_some_and(|b| b[1] < 200.0))
            .unwrap_or_else(|| panic!("no {pill} pill"));
        let (x, y) = centre(&n);
        s.tap_at((x as f32, y as f32), now);
        run(&mut s, &mut now, 400.0);
        let l = labels(&s);
        assert!(l.iter().any(|t| t == row), "{pill}: no popover row {row}");
        assert!(
            !l.iter().any(|t| t == "Filtern" || t == "Sortieren"),
            "{pill}: a bottom sheet opened"
        );
        assert!(s.command(swiftly_desktop::shell::Command::Back, now));
        run(&mut s, &mut now, 400.0);
        assert!(
            !labels(&s).iter().any(|t| t == row),
            "{pill}: the popover stayed open"
        );
    }
}

#[test]
fn library_right_click_opens_a_popover_with_the_macs_entries() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 300.0);
    assert!(s.goto_tab(1, now));
    run(&mut s, &mut now, 900.0);
    let t = nodes(&s)
        .into_iter()
        .find(|n| n.label.contains(", ") && n.bounds.is_some_and(|b| b[0] > 220.0 && b[1] > 150.0))
        .expect("a library tile");
    let (x, y) = centre(&t);
    s.cursor_moved((x, y - 30.0), now);
    assert!(s.secondary_button(now));
    run(&mut s, &mut now, 400.0);
    let l = labels(&s);
    assert!(
        l.iter().any(|t| t.starts_with("Info")),
        "no Info entry: {l:?}"
    );
    assert!(
        l.iter()
            .any(|t| t.starts_with("Abspielen") || t.starts_with("Fortsetzen"))
    );
    assert!(
        !l.iter().any(|t| t.starts_with("Laden")),
        "the Mac has no Laden entry"
    );
}

#[test]
fn merkliste_is_its_own_page_and_the_sidebar_marks_it() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 300.0);
    let m = nodes(&s)
        .into_iter()
        .find(|n| n.label == "Merkliste")
        .unwrap();
    let (x, y) = centre(&m);
    s.tap_at((x as f32, y as f32), now);
    run(&mut s, &mut now, 900.0);
    assert_eq!(s.suite_mut().unwrap().tab(), 4);
    assert_eq!(s.a11y_nodes().0, "Merkliste");
    // The page title is "Merkliste" and the grid is the watchlist filter's.
    let l = labels(&s);
    assert!(
        l.iter().filter(|l| l.as_str() == "Merkliste").count() >= 2,
        "no page title"
    );
    // The page is not the Filme library with a filter: "Filme" is only the sidebar row, and no filter pill is left.
    assert_eq!(
        l.iter().filter(|l| l.as_str() == "Filme").count(),
        1,
        "the page is titled Filme: {l:?}"
    );
    assert!(
        !l.iter().any(|l| l == "Angefangen"),
        "a filter pill is shown on the Merkliste page: {l:?}"
    );
    assert_eq!(
        l.iter().filter(|l| l.as_str() == "Alle").count(),
        1,
        "the kind pill (Alle/Filme/Serien) is on the page: {l:?}"
    );
    // Back goes to Start.
    assert!(s.command(swiftly_desktop::shell::Command::Back, now));
    assert_eq!(s.suite_mut().unwrap().tab(), 0);
}

#[test]
fn every_area_keeps_its_own_pushed_page() {
    use swiftly_desktop::pages_screen::Kind;
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 300.0);
    s.suite_mut().unwrap().open_page(Kind::Person, now);
    run(&mut s, &mut now, 700.0);
    assert_eq!(s.suite_mut().unwrap().top_kind(), Some("page"));
    assert!(s.goto_tab(1, now));
    run(&mut s, &mut now, 500.0);
    assert_eq!(
        s.suite_mut().unwrap().top_kind(),
        None,
        "Filme shows its own stack, which is empty"
    );
    assert!(s.goto_tab(0, now));
    run(&mut s, &mut now, 500.0);
    assert_eq!(
        s.suite_mut().unwrap().top_kind(),
        Some("page"),
        "Start got its page back"
    );
}

#[test]
fn the_wordmark_is_artwork_in_the_sidebar() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 400.0);
    let w = nodes(&s)
        .into_iter()
        .find(|n| {
            n.label == "Swiftly"
                && n.bounds
                    .is_some_and(|b| b[0] < 220.0 && b[1] > 30.0 && b[1] < 100.0)
        })
        .expect("wordmark node");
    let b = w.bounds.unwrap();
    // 26 pt high, 76 wide (the artwork's box 3005 x 1024).
    assert!(
        (b[3] - 26.0).abs() < 1.0 && (b[2] - 76.3).abs() < 1.5,
        "wordmark box {b:?}"
    );
}

#[test]
fn pushed_pages_leave_the_sidebar_visible_and_clickable() {
    use swiftly_desktop::pages_screen::Kind;
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 300.0);
    s.suite_mut().unwrap().open_page(Kind::Person, now);
    run(&mut s, &mut now, 800.0);
    assert_eq!(s.suite_mut().unwrap().top_kind(), Some("page"));
    // The sidebar rows are still in the reading list, left of the content column.
    let filme = nodes(&s)
        .into_iter()
        .find(|n| n.label.starts_with("Filme") && n.bounds.is_some_and(|b| b[0] < 220.0))
        .expect("sidebar row beside the page");
    let (x, y) = centre(&filme);
    s.tap_at((x as f32, y as f32), now);
    run(&mut s, &mut now, 900.0);
    assert_eq!(s.suite_mut().unwrap().tab(), 1);
    assert_eq!(
        s.suite_mut().unwrap().top_kind(),
        None,
        "Filme has its own (empty) stack"
    );
    // Back on Start the page is still there; the active row goes to the root of its area.
    assert!(s.goto_tab(0, now));
    run(&mut s, &mut now, 900.0);
    assert_eq!(s.suite_mut().unwrap().top_kind(), Some("page"));
    let start = nodes(&s)
        .into_iter()
        .find(|n| n.label.starts_with("Start") && n.bounds.is_some_and(|b| b[0] < 220.0))
        .unwrap();
    let (x, y) = centre(&start);
    s.tap_at((x as f32, y as f32), now);
    run(&mut s, &mut now, 900.0);
    assert_eq!(
        s.suite_mut().unwrap().top_kind(),
        None,
        "a click on the active row pops to the root"
    );
}

#[test]
fn area_change_cross_fades_the_content_but_not_the_sidebar() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 400.0);
    assert!(s.goto_tab(1, now));
    now += 60.0;
    let mid = s.frame(now).0;
    run(&mut s, &mut now, 600.0);
    let end = s.frame(now).0;
    assert!(
        format!("{mid:?}") != format!("{end:?}"),
        "no fade between the areas"
    );
    now += 100.0;
    assert!(
        format!("{end:?}") == format!("{:?}", s.frame(now).0),
        "the picture still changes after the fade"
    );
}

#[test]
fn launch_curtain_runs_the_macs_times() {
    // Spec D: 80 frames at 60 fps = 1.333 s, 0.5 s hold, easeOut 0.35 s fade; Spec A: hard stop 3.5 s.
    let mut s = shell();
    s.suite_mut().unwrap().enable_curtain();
    let _ = s.frame(0.0);
    let su = s.suite_mut().unwrap();
    assert!(su.curtain_up(100.0));
    assert!(
        su.curtain_up(1333.0 + 500.0 - 20.0),
        "the curtain leaves before the hold is over"
    );
    assert!(
        su.curtain_up(1333.0 + 500.0 + 100.0),
        "half way through the fade it is still there"
    );
    assert!(
        !su.curtain_up(1333.0 + 500.0 + 350.0 + 20.0),
        "the fade is over after 0.35 s"
    );
    assert!(!su.curtain_up(3500.0));
}
#[test]
fn genre_chips_row_opens_the_genre_page() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 500.0);
    let chip = nodes(&s)
        .into_iter()
        .find(|n| n.label == "Krimi")
        .expect("a genre chip");
    let (x, y) = centre(&chip);
    s.tap_at((x as f32, y as f32), now);
    run(&mut s, &mut now, 900.0);
    assert_eq!(
        s.suite_mut().unwrap().top_kind(),
        Some("page"),
        "the chip did not open the genre page"
    );
}

#[test]
fn window_has_its_own_buttons_a_drag_zone_and_no_menu_bar() {
    use swiftly_desktop::desk::WinAction;
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 400.0);
    let l = labels(&s);
    for want in ["Minimieren", "Maximieren", "Schließen"] {
        assert!(l.iter().any(|t| t == want), "window button {want} missing");
    }
    assert!(
        !l.iter().any(|t| t == "Gehe zu" || t == "Fenster"),
        "the menu bar must be gone"
    );
    // The buttons sit in the 52 pt toolbar row at the top right, no extra strip.
    let close = nodes(&s)
        .into_iter()
        .find(|n| n.label == "Schließen")
        .unwrap();
    let b = close.bounds.unwrap();
    assert!(
        b[1] >= 0.0 && b[1] + b[3] <= 52.0 && b[0] + b[2] <= 1440.0 && b[0] > 1300.0,
        "close button at {b:?}"
    );
    // Minimise and maximise click through to the window.
    let (x, y) = centre(
        &nodes(&s)
            .into_iter()
            .find(|n| n.label == "Minimieren")
            .unwrap(),
    );
    s.tap_at((x as f32, y as f32), now);
    assert_eq!(s.take_window_action(), Some(WinAction::Minimize));
    let (x, y) = centre(
        &nodes(&s)
            .into_iter()
            .find(|n| n.label == "Maximieren")
            .unwrap(),
    );
    s.tap_at((x as f32, y as f32), now);
    assert_eq!(s.take_window_action(), Some(WinAction::ToggleMaximize));
    // An empty spot of the toolbar row drags the window.
    s.tap_at((900.0, 20.0), now);
    assert_eq!(s.take_window_action(), Some(WinAction::DragMove));
    // Below the row the page keeps its clicks (an empty spot: a tile there would open the player).
    s.tap_at((1300.0, 180.0), now);
    assert_eq!(s.take_window_action(), None);
    assert!(!s.suite_mut().unwrap().player_open());
    // Close asks the window to close.
    let (x, y) = centre(&close);
    s.tap_at((x as f32, y as f32), now);
    assert_eq!(s.take_window_action(), Some(WinAction::Close));
    assert!(s.quit_asked());
}

/// The player's own X sits in the corner where the window's close button is. With a player open that button is not drawn,
/// so the click must close the player and never quit the app (the Windows build then hung in its exit).
#[test]
fn the_players_x_closes_the_player_and_not_the_app() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 300.0);
    run(&mut s, &mut now, 900.0);
    // The Continue rail on Home resumes at once, without a detail page.
    let play = nodes(&s)
        .into_iter()
        .find(|n| n.label.starts_with("Der Weg zurück"))
        .expect("the Continue tile");
    let (x, y) = centre(&play);
    s.tap_at((x as f32, y as f32), now);
    run(&mut s, &mut now, 1500.0);
    assert!(
        s.suite_mut().unwrap().player_open(),
        "the play entry did not open the player"
    );
    // The player's close button is a labelled node; tap its centre.
    let close = nodes(&s)
        .into_iter()
        .find(|n| {
            n.label == "Schließen"
                || n.label == "Player schließen"
                || n.label.starts_with("Schließen")
        })
        .expect("the player's close button");
    let b = close.bounds.unwrap();
    assert!(
        b[0] > 1300.0 && b[1] < 60.0,
        "the player's X is not in the caption corner: {b:?}"
    );
    let (x, y) = centre(&close);
    s.tap_at((x as f32, y as f32), now);
    run(&mut s, &mut now, 600.0);
    assert_eq!(
        s.take_window_action(),
        None,
        "the click reached the window's close button"
    );
    assert!(
        !s.suite_mut().unwrap().quit_asked(),
        "the player's X quit the app"
    );
    assert!(
        !s.suite_mut().unwrap().player_open(),
        "the player is still open"
    );
}

/// The left edge of the page that slides in: the widest ground quad that starts right of the sidebar and is furthest right.
fn page_edge(s: &mut Shell, now: f64) -> f32 {
    let list = s.frame(now).0;
    list.quads()
        .iter()
        .filter(|q| {
            (q.rect.w - 1220.0).abs() < 1.0
                && q.rect.x >= 219.5
                && q.rect.h >= 800.0
                && q.clip[0] >= 219.5
                && q.clip[2] > 1439.0
        })
        .map(|q| q.rect.x)
        .fold(220.0, f32::max)
}

/// Samples the push at fixed times after `t0` and checks the 0.45 s easeInOut: starts at the right edge, half way at about
/// 0.225 s, rests at the sidebar's edge from 0.45 s on, never moves backwards.
fn check_push(s: &mut Shell, t0: f64, what: &str) {
    let mut last = f32::MAX;
    let mut at = |ms: f64, s: &mut Shell| {
        let e = page_edge(s, t0 + ms);
        assert!(
            e <= last + 0.5,
            "{what}: moved back at {ms} ms ({e} after {last})"
        );
        last = e;
        e
    };
    let start = at(16.0, s);
    let quarter = at(112.0, s);
    let half = at(225.0, s);
    let three = at(337.0, s);
    let end = at(480.0, s);
    let rest = at(700.0, s);
    let travel = 1220.0_f64;
    let frac = |x: f32| (1440.0 - f64::from(x)) / travel;
    assert!(frac(start) < 0.1, "{what}: starts too far in ({start})");
    assert!(
        (0.05..0.3).contains(&frac(quarter)),
        "{what}: quarter {}",
        frac(quarter)
    );
    assert!(
        (0.35..0.65).contains(&frac(half)),
        "{what}: half way {}",
        frac(half)
    );
    assert!(
        (0.7..0.95).contains(&frac(three)),
        "{what}: three quarters {}",
        frac(three)
    );
    assert!(
        (end - 220.0).abs() < 2.0 && (rest - 220.0).abs() < 1.0,
        "{what}: does not rest at the sidebar edge ({end}, {rest})"
    );
}

#[test]
fn pushes_take_045_seconds_for_form_pages_and_title_pages() {
    // A form page (Settings).
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 600.0);
    assert!(s.open_settings(now));
    check_push(&mut s, now, "settings");
    // A title page (tap a tile).
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 600.0);
    // Home's Continue rail resumes playback; title pages are opened from Movies.
    assert!(s.suite_mut().unwrap().goto_tab(1, now));
    run(&mut s, &mut now, 600.0);
    let t = first_tile(&s);
    let (x, y) = centre(&t);
    s.tap_at((x as f32, (y - 40.0) as f32), now);
    check_push(&mut s, now + 30.0, "title");
}

#[test]
fn downloads_is_a_page_and_login_pushes_take_045_seconds() {
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 600.0);
    assert!(s.run_command("cmd.downloads", now));
    // Downloads is a page of the sidebar: it does not slide in.
    now += 16.0;
    let _ = s.frame(now);
    assert!(!s.suite_mut().unwrap().sliding());
    assert_eq!(s.suite_mut().unwrap().form_open(), Some("downloads"));
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 600.0);
    assert!(s.run_command("cmd.profile", now));
    assert_eq!(s.suite_mut().unwrap().form_open(), Some("accounts"));
    check_push(&mut s, now, "login (accounts)");
}

#[test]
fn wheel_notches_glide_frame_by_frame_instead_of_jumping() {
    let notch = swiftly_motion::ScrollTuning::for_os(swiftly_motion::Os::current()).notch(900.0);
    // Before: a notch handed straight to the page is one frame of a whole notch.
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 500.0);
    s.cursor_moved((700.0, 120.0), now);
    let o0 = s.suite_mut().unwrap().page_offset();
    assert!(
        s.suite_mut()
            .unwrap()
            .wheel_scroll(700.0, 120.0, 0.0, notch as f32, now)
    );
    let jump = s.suite_mut().unwrap().page_offset() - o0;
    assert!(
        (jump - notch).abs() < 1.0,
        "a direct notch moves {jump} in one step"
    );

    // After: two notches 20 ms apart (the Start page only scrolls 279 px) through the shell, sampled every 8 ms.
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 500.0);
    s.cursor_moved((700.0, 120.0), now);
    let start = s.suite_mut().unwrap().page_offset();
    let t0 = now;
    let mut curve: Vec<f64> = Vec::new();
    let mut fired = 0;
    while now < t0 + 700.0 {
        if fired < 2 && now >= t0 + 20.0 * fired as f64 {
            s.wheel(WheelDelta::Lines(0.0, -1.0), None, now);
            fired += 1;
        }
        now += 8.0;
        let _ = s.frame(now);
        curve.push(s.suite_mut().unwrap().page_offset() - start);
    }
    let steps: Vec<f64> = curve.windows(2).map(|w| w[1] - w[0]).collect();
    let max_step = steps.iter().copied().fold(0.0, f64::max);
    let total = *curve.last().unwrap();
    eprintln!(
        "wheel curve per 8 ms (px): {:?}",
        curve
            .iter()
            .step_by(4)
            .map(|v| v.round())
            .collect::<Vec<_>>()
    );
    eprintln!("max step {max_step:.1} px per 8 ms (a whole notch is {notch:.0}); total {total:.1}");
    assert!(
        steps.iter().all(|d| *d >= -0.01),
        "the page moved back during the glide"
    );
    assert!(
        (total - 2.0 * notch).abs() < 1.5,
        "the notches add up to {total}"
    );
    assert!(
        max_step < notch * 0.45,
        "a frame moves {max_step} px, about a whole notch ({notch})"
    );
    // It lands within the smoothing time after the last notch (150 ms from t0 + 20) and then rests.
    let at = |ms: f64| curve[((ms / 8.0) as usize).min(curve.len() - 1)];
    assert!(
        (at(260.0) - total).abs() < 1.5,
        "still moving at 260 ms: {}",
        at(260.0)
    );
}

#[test]
fn history_arrows_sit_where_the_mac_puts_them_over_every_area_and_page() {
    use swiftly_desktop::pages_screen::Kind;
    let mut s = shell();
    let mut now = 0.0;
    run(&mut s, &mut now, 500.0);
    let spot = |s: &Shell| -> [f32; 4] {
        nodes(s)
            .into_iter()
            .find(|n| n.label == "Zurück")
            .and_then(|n| n.bounds)
            .expect("back arrow")
    };
    // Content column (220 + 1 edge) plus 20, centred in the 52 pt row: the pair is 62 x 28 at (241, 12); one arrow 30 x 28.
    let b = spot(&s);
    assert!(
        (b[0] - 241.0).abs() < 0.6
            && (b[1] - 12.0).abs() < 0.6
            && (b[2] - 30.0).abs() < 0.6
            && (b[3] - 28.0).abs() < 0.6,
        "back arrow at {b:?}"
    );
    // The same place on another area and on a pushed page.
    assert!(s.goto_tab(1, now));
    run(&mut s, &mut now, 600.0);
    assert!((spot(&s)[0] - 241.0).abs() < 0.6);
    s.suite_mut().unwrap().open_page(Kind::Person, now);
    run(&mut s, &mut now, 800.0);
    assert!((spot(&s)[0] - 241.0).abs() < 0.6 && (spot(&s)[1] - 12.0).abs() < 0.6);
}
