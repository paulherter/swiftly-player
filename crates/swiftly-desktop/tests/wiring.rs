//! The loose ends of the round-2 pages in the suite: the Delete key reaches the Downloads page, a load request opens
//! the add popover (and the Downloads page first), and the account switch stage runs and ends, with Reduce Motion fading.

use std::collections::HashMap;
use swiftly_desktop::downloads_screen::LoadRequest;
use swiftly_desktop::shell::{Command, Shell};
use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;

fn env(reduce_motion: bool) -> Env {
    let mut e = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    e.reduce_motion = reduce_motion;
    e
}

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
    }
}

fn downloads_open(s: &mut Suite, now: &mut f64) {
    assert!(s.run_command("cmd.downloads", *now));
    run_for(s, now, 600.0);
    assert_eq!(s.form_open(), Some("downloads"));
}

#[test]
fn the_delete_key_reaches_the_downloads_page() {
    let mut shell = Shell::new_suite((1280, 800), 1.0, Cx::deterministic(), Idiom::Desktop);
    let mut now = 0.0;
    for _ in 0..20 {
        now += STEP;
        let _ = shell.frame(now);
    }
    assert!(
        !shell.command(Command::Delete, now),
        "nothing to delete on the start page"
    );
    let s = shell.suite_mut().expect("suite");
    downloads_open(s, &mut now);
    assert!(
        !shell.command(Command::Delete, now),
        "outside edit mode the key does nothing"
    );
    let d = shell
        .suite_mut()
        .unwrap()
        .downloads()
        .expect("downloads in front");
    d.press("edit");
    d.press("row:f2");
    assert_eq!(d.selected(), ["f2"]);
    assert!(shell.command(Command::Delete, now));
    let d = shell.suite_mut().unwrap().downloads().unwrap();
    assert!(!d.editing(), "deleting leaves edit mode");
    assert!(d.vm().entries().iter().all(|e| e.id != "f2"));
}

#[test]
fn a_load_request_opens_the_downloads_page_with_the_add_popover() {
    let mut s = Suite::new(env(false), Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 300.0);
    assert!(s.downloads().is_none());
    s.request_load(
        LoadRequest::Add {
            title: "Der Zug laden".into(),
            items: Vec::new(),
            images: HashMap::new(),
            quality_select: false,
            streams: Vec::new(),
            anchor: None,
        },
        now,
    );
    run_for(&mut s, &mut now, 600.0);
    assert_eq!(s.form_open(), Some("downloads"));
    assert!(s.load_open(), "the add popover is open");
    assert!(
        s.season_pending().is_empty(),
        "an add popover reads no seasons"
    );
    s.season_finished();
}

/// A sheet is modal, as on the Mac: the sidebar (clicks and the tab shortcuts) does nothing under the open add popover.
#[test]
fn the_sidebar_does_nothing_while_the_add_popover_is_open() {
    let mut s = Suite::new(env(false), Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 300.0);
    s.request_load(
        LoadRequest::Add {
            title: "Der Zug laden".into(),
            items: Vec::new(),
            images: HashMap::new(),
            quality_select: false,
            streams: Vec::new(),
            anchor: None,
        },
        now,
    );
    run_for(&mut s, &mut now, 600.0);
    assert!(s.load_open());
    let rows = (60..420).step_by(30);
    for y in rows {
        s.touch_down(40.0, y as f32, now);
        now += 40.0;
        s.touch_up(40.0, y as f32, now);
        run_for(&mut s, &mut now, 400.0);
        assert!(
            s.load_open() && s.form_open() == Some("downloads"),
            "a sidebar click at y={y} changed the page under the sheet"
        );
    }
    assert!(!s.goto_tab(2, now), "the tab shortcuts wait for the sheet");
    assert!(s.load_open() && s.form_open() == Some("downloads"));
    // Esc closes the sheet; afterwards the sidebar works again.
    s.back(now);
    run_for(&mut s, &mut now, 400.0);
    assert!(!s.load_open());
    assert!(s.goto_tab(2, now));
}

fn play(s: &mut Suite, now: &mut f64) -> (f64, f64) {
    s.begin_switch_stage("Paula", None, *now);
    assert!(s.switch_stage_running());
    assert!(s.wants_frame());
    let start = *now;
    let mut moved_after = 0.0;
    let first = s.frame(*now + STEP).0.quads().len();
    while s.switch_stage_running() && *now - start < 5000.0 {
        *now += STEP;
        let (list, _) = s.frame(*now);
        if moved_after == 0.0 && list.quads().len() != first {
            moved_after = *now - start;
        }
    }
    (*now - start, moved_after)
}

#[test]
fn the_switch_stage_runs_and_ends() {
    let mut s = Suite::new(env(false), Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 300.0);
    let (took, _) = play(&mut s, &mut now);
    assert!(
        (700.0..3000.0).contains(&took),
        "the flight takes about a second, took {took} ms"
    );
    assert!(!s.switch_stage_running());
    let after = s.frame(now + STEP).0.quads().len();
    s.begin_switch_stage("Paula", None, now);
    let during = s.frame(now + 2.0 * STEP).0.quads().len();
    assert!(
        during > after,
        "the stage draws the picture over the page ({during} vs {after} quads)"
    );
}

#[test]
fn reduce_motion_only_fades_the_switch_stage() {
    let mut s = Suite::new(env(true), Cx::deterministic());
    let mut now = 0.0;
    run_for(&mut s, &mut now, 300.0);
    let (took, _) = play(&mut s, &mut now);
    assert!(
        (450.0..700.0).contains(&took),
        "the fade lasts half a second, took {took} ms"
    );
    assert!(!s.switch_stage_running());
}
