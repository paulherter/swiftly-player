//! Dragging a window edge must not cut every picture again on every step: a tile that changes size by a few points keeps
//! the picture it has until the drag has settled (the Mac scales the one it has). The real server's Home, with many
//! pictures, lagged by seconds while the window was dragged: every step cut and uploaded each picture again.

use std::rc::Rc;
use std::sync::Arc;
use std::time::Instant;
use swiftly_desktop::browse::Scenario as BrowseScenario;
use swiftly_desktop::home::HomeScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::hub::ImageHub;
use swiftly_desktop::library_screen::{Kind, LibraryScreen};
use swiftly_images::fixture::FixtureImages;
use swiftly_images::{Device, ImageLoader};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;

fn env(w: f32) -> Env {
    Env::new(Size::new(w, 800.0), 1.5, Idiom::Desktop)
}

fn hub(cx: &Cx) -> Rc<ImageHub> {
    let loader = ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac);
    ImageHub::new(Box::new(loader), cx, 1.5, Device::Mac)
}

macro_rules! drag {
    ($name:literal, $s:ident, $hub:ident) => {{
        let mut now = 0.0;
        for _ in 0..4 {
            $s.settle_images(now);
            now += STEP;
            let _ = $s.frame(now);
        }
        $s.settle_images(now);
        now += 400.0;
        let _ = $s.frame(now);
        let before = $hub.cuts();
        assert!(
            before >= 8,
            "{}: only {before} pictures were cut before the drag",
            $name
        );
        let started = Instant::now();
        // A drag of 60 steps of 5 points, one frame each, 12 ms apart.
        let mut w = 1400.0_f32;
        for _ in 0..60 {
            w -= 5.0;
            now += 12.0;
            $s.set_env(env(w));
            $s.settle_images(now);
            let _ = $s.frame(now);
        }
        let during = $hub.cuts() - before;
        let took = started.elapsed();
        // The drag stops: after a pause the pictures are cut to the final size, once.
        for _ in 0..30 {
            now += STEP;
            $s.settle_images(now);
            let _ = $s.frame(now);
        }
        let after = $hub.cuts() - before - during;
        eprintln!(
            "{}: {} cut before, {} during the drag ({:?}), {} after it settled",
            $name, before, during, took, after
        );
        (during, after)
    }};
}

#[test]
fn a_window_drag_does_not_cut_the_home_pictures_on_every_step() {
    let cx = Cx::deterministic().with_image_page(4096);
    let h = hub(&cx);
    let mut s = HomeScreen::new(env(1400.0), cx, Scenario::Ready).with_images(Rc::clone(&h));
    let (during, after) = drag!("home", s, h);
    assert!(during <= 30, "home: {during} pictures cut during the drag");
    assert!(after <= 60, "home: {after} cuts after the drag");
}

#[test]
fn a_window_drag_does_not_cut_the_library_pictures_on_every_step() {
    let cx = Cx::deterministic().with_image_page(4096);
    let h = hub(&cx);
    let mut s = LibraryScreen::new(env(1400.0), cx, &Kind::Movies, BrowseScenario::Ready)
        .with_images(Rc::clone(&h));
    let (during, after) = drag!("library", s, h);
    assert!(
        during <= 30,
        "library: {during} pictures cut during the drag"
    );
    assert!(after <= 60, "library: {after} cuts after the drag");
}
