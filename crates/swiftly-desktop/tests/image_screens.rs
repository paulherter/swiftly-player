//! Every screen that shows server pictures draws real (fixture) pictures when a hub is attached: image quads from the
//! hub's region with a live owner, none stale, and the frame differs from the demo art.

use std::rc::Rc;
use std::sync::Arc;
use swiftly_desktop::browse::Scenario as BrowseScenario;
use swiftly_desktop::detail_screen::DetailScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::hub::ImageHub;
use swiftly_desktop::library_screen::{Kind, LibraryScreen};
use swiftly_desktop::search_screen::SearchScreen;
use swiftly_desktop::series_screen::SeriesScreen;
use swiftly_images::fixture::FixtureImages;
use swiftly_images::{Device, ImageLoader};
use swiftly_layout::Size;
use swiftly_render::{DrawList, QuadKind};
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;

fn env() -> Env {
    Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop)
}

fn hub(cx: &Cx) -> Rc<ImageHub> {
    let loader = ImageLoader::new(Arc::new(FixtureImages), None, Device::Mac);
    ImageHub::new(Box::new(loader), cx, 1.0, Device::Mac)
}

fn real_pictures(hub: &ImageHub, list: &DrawList) -> usize {
    list.quads()
        .iter()
        .filter(|q| q.kind == QuadKind::Image && hub.in_region(q.uv) && q.color.a > 0.99)
        .inspect(|q| {
            assert!(
                hub.owner_of(q.uv).is_some(),
                "a drawn picture has no live rectangle"
            )
        })
        .count()
}

macro_rules! run {
    ($s:ident, $hub:ident) => {{
        let mut now = 0.0;
        for _ in 0..3 {
            $s.settle_images(now);
            now += STEP;
            let _ = $s.frame(now);
        }
        $s.settle_images(now);
        // Past the fade.
        let (list, _) = $s.frame(now + 400.0);
        (real_pictures(&$hub, &list), $hub.stale_total())
    }};
}

#[test]
fn library_shows_real_pictures() {
    let cx = Cx::deterministic().with_image_page(4096);
    let h = hub(&cx);
    let mut s = LibraryScreen::new(env(), cx, &Kind::Movies, BrowseScenario::Ready)
        .with_images(Rc::clone(&h));
    let (n, stale) = run!(s, h);
    assert!(n >= 4, "library pictures: {n}");
    assert_eq!(stale, 0);
}

#[test]
fn search_shows_real_pictures() {
    let cx = Cx::deterministic().with_image_page(4096);
    let h = hub(&cx);
    let mut s = SearchScreen::new(env(), cx, BrowseScenario::Ready, &["Nordlicht", "Brücke"])
        .with_images(Rc::clone(&h));
    let _ = s.frame(100.0);
    s.type_text("Nord");
    let started = std::time::Instant::now();
    while s.vm().results().groups.is_empty() && started.elapsed().as_secs() < 5 {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    SearchScreen::settle(s.vm());
    let (n, stale) = run!(s, h);
    assert!(n >= 1, "search pictures: {n}");
    assert_eq!(stale, 0);
}

#[test]
fn detail_shows_real_pictures_and_mood_tones() {
    let cx = Cx::deterministic().with_image_page(4096);
    let h = hub(&cx);
    let mut s = DetailScreen::new(env(), cx, Scenario::Ready).with_images(Rc::clone(&h));
    s.open(0.0);
    let (n, stale) = run!(s, h);
    assert!(n >= 1, "detail pictures: {n}");
    assert_eq!(stale, 0);
}

#[test]
fn series_shows_real_pictures() {
    let cx = Cx::deterministic().with_image_page(4096);
    let h = hub(&cx);
    let mut s = SeriesScreen::new(env(), cx, Scenario::Ready).with_images(Rc::clone(&h));
    s.open(0.0);
    let (n, stale) = run!(s, h);
    assert!(n >= 1, "series pictures: {n}");
    assert_eq!(stale, 0);
}

/// The mood backdrop of a series page is built from the hero picture's hues. They arrive after the page was built; the
/// page must pick them up then (it did only when something else changed the page, so at a small window the backdrop was
/// missing in most runs). Counts tinted pixels of the page ground beside the content.
#[test]
fn series_mood_backdrop_appears_when_the_hues_arrive_late() {
    let cx = Cx::deterministic().with_image_page(4096);
    let h = hub(&cx);
    let env = Env::new(Size::new(1280.0, 600.0), 1.0, Idiom::Desktop);
    let mut s = SeriesScreen::new(env, cx, Scenario::Ready).with_images(Rc::clone(&h));
    s.open(0.0);
    let mut now = 0.0;
    // The page is built and has been quiet for a while before the picture arrives.
    for _ in 0..30 {
        now += STEP;
        let _ = s.frame(now);
    }
    s.settle_images(now);
    now += 600.0;
    let (list, _) = s.frame(now);
    let img = s.render_software(&list);
    let mut tinted = 0;
    for y in (330..590).step_by(4) {
        for x in (700..1270).step_by(4) {
            let p = img.pixel(x, y);
            tinted += usize::from(p[0].abs_diff(p[2]) >= 4 || p[1].abs_diff(p[2]) >= 4);
        }
    }
    assert!(
        tinted > 100,
        "no mood colour on the page ({tinted} tinted samples)"
    );
}
