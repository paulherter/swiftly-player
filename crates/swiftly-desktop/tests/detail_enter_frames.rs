//! Frame sequence of the detail page enter and leave against the Mac catalogue (`mac-animations.md`): the page behind
//! travels `-0.3 * width` with `PagesPush` (easeInOut 0.45 s) on the push and comes back with it on the pop. The tone
//! behind the page (`Mood`, smooth 0.55 s) and the content arrival (`Reveal`, easeInOut 0.28 s) are printed from their
//! catalogue curves next to it. Run with `--nocapture` to read the table.
#![allow(clippy::unwrap_used)]

use swiftly_desktop::a11y_bridge;
use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_motion::catalogue::Id;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;

fn tap_label(s: &mut Suite, now: &mut f64, label: &str) -> bool {
    let (title, tree) = s.a11y_nodes();
    let built = a11y_bridge::build(title, &tree, 1.0);
    let id = built
        .update
        .nodes
        .iter()
        .find(|(_, x)| x.label() == Some(label))
        .map(|(i, _)| i.0);
    let Some(&(x, y)) = id.and_then(|i| built.centres.get(&i)) else {
        return false;
    };
    s.touch_down(x, y, *now);
    s.touch_up(x, y, *now + 40.0);
    *now += 80.0;
    true
}

/// Taps the first poster found; returns the time the push began.
fn open_a_title(s: &mut Suite, now: &mut f64) -> f64 {
    let before = s.pushes();
    for yi in 0..14 {
        for xi in 0..14 {
            let (x, y) = (
                1280.0 * (0.30 + 0.05 * xi as f32),
                800.0 * (0.25 + 0.05 * yi as f32),
            );
            s.touch_down(x, y, *now);
            let at = *now + 40.0;
            s.touch_up(x, y, at);
            *now += 80.0;
            if s.pushes() > before {
                return at;
            }
        }
    }
    panic!("no poster found");
}

#[test]
fn push_and_pop_follow_pages_push_frame_by_frame() {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = Suite::new(env, Cx::deterministic());
    let mut now = 0.0;
    while now < 400.0 {
        now += STEP;
        let _ = s.frame(now);
    }
    assert!(tap_label(&mut s, &mut now, "Filme"));
    let end = now + 700.0;
    while now < end {
        now += STEP;
        let _ = s.frame(now);
    }
    let t0 = open_a_title(&mut s, &mut now);
    let (push, mood, reveal) = (Id::PagesPush.curve(), Id::Mood.curve(), Id::Reveal.curve());
    let width = 1280.0 - swiftly_design::tokens::desktop::SIDEBAR_WIDTH;
    println!(
        "push: frame  t(ms)  below_dx  expected(-0.3w*p)  | Mood p  Reveal p (tone / content arriving at t0)"
    );
    let mut worst = 0.0f32;
    let mut first_move = None;
    for i in 0..40 {
        now += STEP;
        let _ = s.frame(now);
        let t = (now - t0) / 1000.0;
        let dx = s.below_shift();
        let want = -0.3 * width * push.progress(t) as f32;
        println!(
            "{i:>3} {:>6.1} {dx:>9.2} {want:>9.2} | {:.3} {:.3}",
            t * 1000.0,
            mood.progress(t),
            reveal.progress(t)
        );
        if dx != 0.0 && first_move.is_none() {
            first_move = Some(i);
        }
        if t < 0.45 {
            worst = worst.max((dx - want).abs());
        }
    }
    println!("worst deviation of the page behind from -0.3w*PagesPush: {worst:.1} pt");
    assert!(
        worst < 6.0,
        "the push of the page behind follows PagesPush: {worst:.1} pt"
    );
    assert!(
        first_move.is_some_and(|i| i <= 3),
        "the page behind starts moving with the push: {first_move:?}"
    );
    let end = now + 800.0;
    while now < end {
        now += STEP;
        let _ = s.frame(now);
    }
    assert!(s.back(now));
    let t1 = now;
    let mut leave = Vec::new();
    let mut pop_worst = 0.0f32;
    println!("pop: frame  t(ms)  below_dx  expected");
    for i in 0..40 {
        now += STEP;
        let _ = s.frame(now);
        leave.push(s.below_shift());
        let want = -0.3 * width * (1.0 - push.progress((now - t1) / 1000.0) as f32);
        println!(
            "{i:>3} {:>6.1} {:>9.2} {want:>9.2}",
            (now - t1),
            s.below_shift()
        );
        if now - t1 < 450.0 {
            pop_worst = pop_worst.max((s.below_shift() - want).abs());
        }
    }
    println!("worst deviation on pop: {pop_worst:.1} pt");
    assert!(
        pop_worst < 6.0,
        "the pop of the page behind follows PagesPush backwards: {pop_worst:.1} pt"
    );
    assert!(
        leave.iter().any(|d| *d < -50.0),
        "the page behind travels on pop: {leave:?}"
    );
    let moving: Vec<f32> = leave.iter().copied().filter(|d| *d != 0.0).collect();
    assert!(
        moving.windows(2).all(|w| w[1] >= w[0] - 0.5),
        "left to right only: {moving:?}"
    );
}

/// Late data (the tone, the rails) fades in with `Mood` (smooth 0.55 s) and `Reveal` (easeInOut 0.28 s) once the push
/// has settled (`InTravel.waitFor()`), never during the slide. Prints value and catalogue value per frame.
#[test]
fn tone_and_rails_arrive_after_the_push_with_mood_and_reveal() {
    use swiftly_desktop::detail_screen::DetailScreen;
    use swiftly_desktop::home_data::Scenario;
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut d = DetailScreen::overlay(env, Cx::deterministic(), Scenario::Loading);
    let _ = d.frame(0.0);
    d.open(0.0);
    let (mut now, mut settled_at) = (0.0, None);
    let mut seen: Vec<(f64, f32, f32)> = Vec::new();
    println!("frame t(ms) covers | mood bottom | Mood p  Reveal p");
    for i in 0..90 {
        now += STEP;
        if i == 5 {
            // The answer comes while the page is still sliding in.
            d.vm().send(swiftly_vm::DetailIntent::Load);
        }
        let _ = d.frame(now);
        if d.covers() && settled_at.is_none() {
            settled_at = Some(now);
        }
        let (m, b) = d.arrival_alphas();
        let since = settled_at.map_or(0.0, |s| (now - s) / 1000.0);
        println!(
            "{i:>3} {now:>7.1} {} | {m:.3} {b:.3} | {:.3} {:.3}",
            d.covers(),
            Id::Mood.curve().progress(since),
            Id::Reveal.curve().progress(since)
        );
        seen.push((now, m, b));
    }
    let settled = settled_at.expect("the push settles");
    // The rails arrive after the slide with Reveal, frame by frame (1/64 steps); the demo's tone is there from the first
    // build (like a cached tone on the Mac), so it stays at 1. A live tone arrives through the same `Mood` code path.
    for (t, _, b) in seen.iter().filter(|(t, ..)| *t > settled) {
        let want = Id::Reveal.curve().progress((t - settled) / 1000.0) as f32;
        assert!(
            (b - want).abs() <= 0.04,
            "rails at {t}: {b} against Reveal {want}"
        );
    }
    assert!(
        seen.iter()
            .filter(|(t, ..)| *t < settled)
            .all(|(_, _, b)| *b == 1.0),
        "the rails are not on screen during the slide"
    );
    assert!(
        seen.iter().any(|(t, _, b)| *t > settled && *b < 0.5),
        "the rails fade in, no hard swap"
    );
}
