//! Frame goldens of the G1 demo (poster rails, detail push) from the software renderer, for the three form factors.
//! Bundled Inter only (`Cx::deterministic`), fixed clock, so the pixels are the same on every host. The PNGs live in
//! `swiftly-ui/tests/golden`; `UPDATE_GOLDENS=1` rewrites them. Tolerance: 2 levels per channel.

use std::path::PathBuf;
use swiftly_desktop::demo::Demo;
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;
// The goldens come from macOS; the software renderer rounds a little differently on other systems (seen: up to 10 levels).
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 2 } else { 12 };

struct Form {
    name: &'static str,
    size_pt: (f32, f32),
    scale: f32,
    idiom: Idiom,
    /// Where the first poster rail sits, when the page is too short to scroll vertically.
    rail_y: Option<f32>,
}

const TOUCH: Form = Form {
    name: "touch",
    size_pt: (390.0, 844.0),
    scale: 3.0,
    idiom: Idiom::Phone,
    rail_y: None,
};
const DESKTOP: Form = Form {
    name: "desktop",
    size_pt: (1280.0, 800.0),
    scale: 2.0,
    idiom: Idiom::Desktop,
    rail_y: None,
};
const TV: Form = Form {
    name: "tv",
    size_pt: (1920.0, 1080.0),
    scale: 1.0,
    idiom: Idiom::Tv,
    rail_y: Some(230.0),
};

fn golden_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden")
        .join(name)
}

fn check(name: &str, img: &RgbaImage) {
    let path = golden_path(&format!("{name}.png"));
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
    println!(
        "golden {name}: max diff {max}, differing {:.4} %",
        share * 100.0
    );
    assert!(max <= TOLERANCE, "golden {name} differs by {max}");
}

/// Runs frames at 60 Hz from `*now` up to `to` (inclusive of a frame at `to`).
fn run_to(demo: &mut Demo, now: &mut f64, to: f64) {
    while *now + FRAME_MS < to {
        *now += FRAME_MS;
        let _ = demo.frame(*now);
    }
    *now = to;
    let _ = demo.frame(to);
}

fn shot(demo: &mut Demo, now: &mut f64, at: f64) -> RgbaImage {
    run_to(demo, now, at);
    let (list, _) = demo.frame(*now);
    demo.render_software(&list)
}

fn scenes(form: &Form) {
    let env = Env::new(
        Size::new(form.size_pt.0, form.size_pt.1),
        form.scale,
        form.idiom,
    );
    let mut demo = Demo::new(env, Cx::deterministic());
    // The frames are pinned by one scroll table, the Mac's, so the golden is the same on every OS (Windows and Linux
    // scrolling has no end bounce, which a touch drag past the page start would otherwise show).
    demo.set_scroll_tuning(swiftly_motion::ScrollTuning::for_os(
        swiftly_motion::Os::MacOs,
    ));
    let (w, h) = form.size_pt;
    let mut now = 0.0;

    // t=0: the home page at rest.
    let rest = shot(&mut demo, &mut now, 0.0);
    check(&format!("g1_{}_home_t0", form.name), &rest);

    // Mid-scroll: a vertical drag on the page, captured while the finger is still down.
    // On the tv the page fits, so the first rail is dragged sideways instead.
    let (x0, y0) = (w * 0.5, form.rail_y.unwrap_or(h * 0.8));
    let at_step = |i: f32| match form.rail_y {
        Some(_) => (x0 - 30.0 * i, y0),
        None => (x0, y0 - 30.0 * i),
    };
    demo.touch_down(x0, y0, now);
    for i in 1..=8 {
        let t = now + f64::from(i) * FRAME_MS;
        let (x, y) = at_step(i as f32);
        demo.touch_move(x, y, t);
        let _ = demo.frame(t);
    }
    now += 8.0 * FRAME_MS;
    let at = now + 2.0 * FRAME_MS;
    let scroll = shot(&mut demo, &mut now, at);
    check(&format!("g1_{}_home_mid_scroll", form.name), &scroll);
    assert!(scroll.diff(&rest).0 > TOLERANCE, "the page did not move");
    let up_t = now + FRAME_MS;
    let (x, y) = at_step(8.0);
    demo.touch_up(x, y, up_t);
    run_to(&mut demo, &mut now, up_t + 3000.0);

    // Mid-spring: the push to a detail page, 180 ms in.
    let start = now + FRAME_MS;
    demo.open_detail(0, 2, start);
    let spring = shot(&mut demo, &mut now, start + 180.0);
    check(&format!("g1_{}_detail_mid_push", form.name), &spring);
    let settled = shot(&mut demo, &mut now, start + 2000.0);
    check(&format!("g1_{}_detail_settled", form.name), &settled);

    // Press: a finger down on the back button, 200 ms held.
    let (bx, by) = (24.0 + 40.0, 20.0 + 24.0);
    let t = now + FRAME_MS;
    demo.touch_down(bx, by, t);
    let pressed = shot(&mut demo, &mut now, t + 200.0);
    check(&format!("g1_{}_detail_press", form.name), &pressed);
    assert!(
        pressed.diff(&settled).0 > TOLERANCE,
        "the press left no mark"
    );
}

#[test]
fn g1_frames_touch_phone() {
    scenes(&TOUCH);
}

#[test]
fn g1_frames_desktop() {
    scenes(&DESKTOP);
}

#[test]
fn g1_frames_tv() {
    scenes(&TV);
}

/// Gate G4 frames: the `tv` focus scene with a button focused, a tile 60 ms into its lift (mid-spring) and settled.
#[test]
fn g4_focus_tv() {
    use swiftly_desktop::focus_scene;
    use swiftly_ui::{Dir, NavKey};
    let env = Env::new(Size::new(1920.0, 1080.0), 1.0, Idiom::Tv);
    let mut ui = focus_scene::ui(env, Cx::deterministic());
    let mut now = 0.0;
    let shot = |ui: &mut swiftly_ui::Ui<()>, now: &mut f64, to: f64| {
        while *now + FRAME_MS < to {
            *now += FRAME_MS;
            let _ = ui.frame(*now);
        }
        *now = to;
        let list = ui.frame(to);
        ui.render(&list, swiftly_render::Color::BLACK)
    };
    let rest = shot(&mut ui, &mut now, 1500.0);
    assert_eq!(ui.focused(), Some(focus_scene::button_id(0)));
    check("g4_tv_focus_button_settled", &rest);
    ui.nav_key(NavKey::Arrow(Dir::Down), true, 2000.0);
    assert_eq!(ui.focused(), Some(focus_scene::tile_id(0, 0)));
    let mid = shot(&mut ui, &mut now, 2060.0);
    check("g4_tv_focus_tile_mid_lift", &mid);
    let settled = shot(&mut ui, &mut now, 3500.0);
    check("g4_tv_focus_tile_settled", &settled);
    assert!(mid.diff(&settled).0 > TOLERANCE, "mid-lift equals settled");
    assert!(rest.diff(&settled).0 > TOLERANCE, "focus left no mark");
}

// ---- the Home screen, driven by HomeVm over a scripted server -------------------------------------------------------

mod home_frames {
    use super::{DESKTOP, FRAME_MS, Form, TOLERANCE, TOUCH, TV, check};
    use swiftly_desktop::home::{HomeScreen, PULL_TO_REFRESH};
    use swiftly_desktop::home_data::Scenario;
    use swiftly_layout::Size;
    use swiftly_render::RgbaImage;
    use swiftly_ui::{Cx, Dir, Env, NavKey};

    fn screen(form: &Form, scenario: Scenario) -> HomeScreen {
        let env = Env::new(
            Size::new(form.size_pt.0, form.size_pt.1),
            form.scale,
            form.idiom,
        );
        HomeScreen::new(env, Cx::deterministic(), scenario)
    }

    fn run_to(s: &mut HomeScreen, now: &mut f64, to: f64) {
        while *now + FRAME_MS < to {
            *now += FRAME_MS;
            let _ = s.frame(*now);
        }
        *now = to;
        let _ = s.frame(to);
    }

    fn shot(s: &mut HomeScreen, now: &mut f64, at: f64) -> RgbaImage {
        run_to(s, now, at);
        let (list, _) = s.frame(*now);
        s.render_software(&list)
    }

    fn scenes(form: &Form) {
        let (w, h) = form.size_pt;
        // Loading: the vm has not been asked; two placeholder rails.
        let mut s = screen(form, Scenario::Loading);
        let mut now = 0.0;
        let loading = shot(&mut s, &mut now, 0.0);
        check(&format!("home_{}_loading", form.name), &loading);

        // Offline: no rails, "Server ist abgetaucht".
        let mut s = screen(form, Scenario::Offline);
        let mut now = 0.0;
        let offline = shot(&mut s, &mut now, 0.0);
        check(&format!("home_{}_offline", form.name), &offline);
        assert!(
            offline.diff(&loading).0 > TOLERANCE,
            "offline equals loading"
        );

        // Ready: initial, then scrolled.
        let mut s = screen(form, Scenario::Ready);
        let mut now = 0.0;
        let rest = shot(&mut s, &mut now, 1200.0);
        check(&format!("home_{}_initial", form.name), &rest);
        if form.name == "tv" {
            for _ in 0..2 {
                let t = now + FRAME_MS;
                s.nav_key(NavKey::Arrow(Dir::Down), true, t);
                s.nav_key(NavKey::Arrow(Dir::Down), false, t);
                run_to(&mut s, &mut now, t + 1500.0);
            }
        } else {
            let (x0, y0) = (w * 0.6, h * 0.8);
            s.touch_down(x0, y0, now);
            for i in 1..=10 {
                let t = now + f64::from(i) * FRAME_MS;
                s.touch_move(x0, y0 - 40.0 * i as f32, t);
                let _ = s.frame(t);
            }
            now += 10.0 * FRAME_MS;
            s.touch_up(x0, y0 - 400.0, now + FRAME_MS);
            let to = now + 3000.0;
            run_to(&mut s, &mut now, to);
        }
        let at = now + 100.0;
        let scrolled = shot(&mut s, &mut now, at);
        check(&format!("home_{}_scrolled", form.name), &scrolled);
        assert!(
            scrolled.diff(&rest).0 > TOLERANCE,
            "the page did not scroll"
        );
    }

    #[test]
    fn home_frames_touch_phone() {
        scenes(&TOUCH);
    }

    #[test]
    fn home_frames_desktop() {
        swiftly_desktop::desk::force_hint_os(swiftly_motion::Os::MacOs); // the goldens are Mac-made
        scenes(&DESKTOP);
    }

    #[test]
    fn home_frames_tv() {
        scenes(&TV);
    }

    /// The fixture image server, held closed until the test opens it, so "loading" is a stable frame.
    struct Held(std::sync::Arc<(std::sync::Mutex<bool>, std::sync::Condvar)>);
    impl swiftly_net::HttpTransport for Held {
        async fn send(
            &self,
            request: swiftly_net::HttpRequest,
        ) -> Result<swiftly_net::HttpResponse, swiftly_net::ErrorKind> {
            {
                let (lock, cv) = &*self.0;
                let mut open = lock
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                while !*open {
                    open = cv
                        .wait(open)
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                }
            }
            swiftly_images::fixture::FixtureImages.send(request).await
        }
    }

    /// Loading (tile ground only), half faded in, fully loaded: real pictures from the fixture server.
    fn image_scenes(form: &Form) {
        use std::sync::{Arc, Condvar, Mutex};
        use swiftly_desktop::hub::ImageHub;
        use swiftly_images::{Device, ImageLoader};
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let cx = Cx::deterministic().with_image_page(4096);
        let env = Env::new(
            Size::new(form.size_pt.0, form.size_pt.1),
            form.scale,
            form.idiom,
        );
        let s0 = HomeScreen::new(env, cx.clone(), Scenario::Ready);
        let loader = ImageLoader::new(Arc::new(Held(Arc::clone(&gate))), None, Device::Mac);
        let hub = ImageHub::new(Box::new(loader), &cx, form.scale, Device::Mac);
        let mut s = s0.with_images(hub);
        let mut now = 0.0;
        let loading = shot(&mut s, &mut now, 1200.0);
        check(&format!("home_{}_images_loading", form.name), &loading);

        *gate
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = true;
        gate.1.notify_all();
        s.settle_images(now);
        let t = now + FRAME_MS;
        let _ = s.frame(t);
        s.settle_images(t);
        now = t;
        let at = now + 140.0;
        let half = shot(&mut s, &mut now, at);
        check(&format!("home_{}_images_fade", form.name), &half);
        let at = now + 600.0;
        s.settle_images(now);
        let loaded = shot(&mut s, &mut now, at);
        check(&format!("home_{}_images_loaded", form.name), &loaded);
        assert!(half.diff(&loading).0 > TOLERANCE, "nothing faded in");
        assert!(loaded.diff(&half).0 > TOLERANCE, "the fade did not finish");
    }

    #[test]
    fn home_frames_touch_phone_images() {
        image_scenes(&TOUCH);
    }

    #[test]
    fn home_frames_desktop_images() {
        swiftly_desktop::desk::force_hint_os(swiftly_motion::Os::MacOs); // the goldens are Mac-made
        image_scenes(&DESKTOP);
    }

    #[test]
    fn home_frames_tv_images() {
        image_scenes(&TV);
    }

    /// Pulling the page down past the threshold and letting go reloads (touch only).
    #[test]
    fn home_pull_to_refresh_touch() {
        let mut s = screen(&TOUCH, Scenario::Ready);
        let mut now = 0.0;
        run_to(&mut s, &mut now, 500.0);
        assert_eq!(s.refreshes(), 0);
        let (x, y0) = (200.0, 300.0);
        s.touch_down(x, y0, now);
        for i in 1..=20 {
            let t = now + f64::from(i) * FRAME_MS;
            s.touch_move(x, y0 + 12.0 * i as f32, t);
            let _ = s.frame(t);
        }
        now += 20.0 * FRAME_MS;
        // Mid-pull: the spinner spokes are showing (all 12 past the threshold).
        let (list, _) = s.frame(now);
        check("home_touch_pull", &s.render_software(&list));
        assert!(
            -s.page_offset() as f32 >= PULL_TO_REFRESH,
            "pulled {}",
            s.page_offset()
        );
        s.touch_up(x, y0 + 240.0, now + FRAME_MS);
        assert_eq!(s.refreshes(), 1);
        let to = now + 2000.0;
        run_to(&mut s, &mut now, to);
        assert!(s.page_offset().abs() < 1.0, "the page springs back");
    }

    /// A tap on a Continue-rail tile resumes the title at once (no detail page first); on tv the focus engine
    /// reaches the first tile.
    #[test]
    fn home_tap_and_focus() {
        let mut s = screen(&DESKTOP, Scenario::Ready);
        let mut now = 0.0;
        run_to(&mut s, &mut now, 500.0);
        // First landscape tile of the first rail on the desktop layout.
        let (x, y) = (220.0 + 36.0 + 60.0, 200.0);
        s.touch_down(x, y, now + 20.0);
        s.touch_up(x, y, now + 60.0);
        let _ = s.frame(now + 80.0);
        assert_eq!(s.take_resumed().len(), 1, "a Continue tile plays at once");
        assert!(s.opened().is_empty(), "the detail page is not opened first");
        let mut tv = screen(&TV, Scenario::Ready);
        let mut t = 0.0;
        run_to(&mut tv, &mut t, 500.0);
        tv.nav_key(NavKey::Arrow(Dir::Down), true, t + 20.0);
        assert!(tv.focused().is_some(), "focus reaches a tile");
    }
}
