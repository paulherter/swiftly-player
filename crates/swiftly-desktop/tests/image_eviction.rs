//! No tile ever shows another tile's picture, even while a tiny image region forces constant eviction: every drawn
//! picture rectangle belongs to a live entry, its pixels are those of the entry's own fixture, and no stale rectangle
//! ever had to be blanked.

use std::sync::Arc;
use swiftly_desktop::home::HomeScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::hub::ImageHub;
use swiftly_images::fixture::{self, FixtureImages};
use swiftly_images::{Device, ImageLoader};
use swiftly_layout::Size;
use swiftly_render::{QuadKind, RgbaImage};
use swiftly_ui::{Cx, Env, Idiom};

const FRAME_MS: f64 = 1000.0 / 60.0;

fn patch_avg(get: impl Fn(usize, usize) -> [u8; 4], cx: usize, cy: usize, half: usize) -> [f64; 3] {
    let mut sum = [0.0; 3];
    let n = (2 * half * 2 * half) as f64;
    for dy in 0..2 * half {
        for dx in 0..2 * half {
            let p = get(cx + dx - half, cy + dy - half);
            for c in 0..3 {
                sum[c] += f64::from(p[c]) / n;
            }
        }
    }
    sum
}

fn dist(a: [f64; 3], b: [f64; 3]) -> f64 {
    (0..3).map(|c| (a[c] - b[c]).abs()).sum()
}

/// The fixture id and size an entry key stands for.
fn fixture_of(entry: &str) -> (String, u32, u32) {
    let after = entry.split("/Items/").nth(1).unwrap_or("");
    let mut parts = after.split('/');
    let id = parts.next().unwrap_or("").to_owned();
    let kind = parts.nth(1).unwrap_or("").split('?').next().unwrap_or("");
    let (w, h) = if kind == "Primary" {
        fixture::POSTER
    } else {
        fixture::LANDSCAPE
    };
    (id, w, h)
}

fn check_frame(
    hub: &ImageHub,
    s: &HomeScreen,
    list: &swiftly_render::DrawList,
    scale: f32,
    ids: &[String],
    pixels: bool,
) -> usize {
    let shot: Option<RgbaImage> = pixels.then(|| s.render_software(list));
    let mut checked = 0;
    for q in list.quads() {
        if q.kind != QuadKind::Image || q.color.a < 0.999 || !hub.in_region(q.uv) {
            continue;
        }
        let owner = hub
            .owner_of(q.uv)
            .unwrap_or_else(|| panic!("a drawn picture has no live rectangle: {:?}", q.uv));
        let Some(shot) = shot.as_ref() else {
            checked += 1;
            continue;
        };
        let (id, w, h) = fixture_of(&owner);
        let (cx, cy) = (
            ((q.rect.x + q.rect.w / 2.0) * scale) as usize,
            ((q.rect.y + q.rect.h / 2.0) * scale) as usize,
        );
        if cy < 130
            || cy + 120 >= shot.height
            || cx < 4
            || cx + 4 >= shot.width
            || q.clip[2] < q.rect.w * 0.9
        {
            continue; // cut by the screen edge or a clip: the centre is not the picture's centre
        }
        let ratio = ((w as f32 / (q.rect.w * scale)).round() as usize).max(1);
        let drawn = patch_avg(|x, y| shot.pixel(x, y), cx, cy, 4);
        let expected = |id: &str| {
            let px = fixture::pixels(id, w, h);
            patch_avg(
                |x, y| {
                    [
                        px[(y * w as usize + x) * 4],
                        px[(y * w as usize + x) * 4 + 1],
                        px[(y * w as usize + x) * 4 + 2],
                        255,
                    ]
                },
                w as usize / 2,
                h as usize / 2,
                4 * ratio,
            )
        };
        let own = dist(drawn, expected(&id));
        for other in ids.iter().filter(|o| **o != id) {
            let od = dist(drawn, expected(other));
            assert!(
                own < od + 1.0,
                "tile of {id} shows the picture of {other}: own {own} other {od} drawn {drawn:?} owner {owner} rect {:?} ratio {ratio}",
                q.rect
            );
        }
        checked += 1;
    }
    checked
}

#[test]
fn eviction_never_shows_another_tiles_picture() {
    let cx = Cx::deterministic().with_image_page(2048);
    let env = Env::new(Size::new(390.0, 844.0), 1.0, Idiom::Phone);
    let s0 = HomeScreen::new(env, cx.clone(), Scenario::Ready);
    let loader = ImageLoader::new(Arc::new(FixtureImages), None, Device::Phone);
    // One band's worth of rows: poster and landscape tiles fight for the same space.
    let hub = ImageHub::with_region_height(Box::new(loader), &cx, 1.0, Device::Phone, 200);
    let mut s = s0.with_images(std::rc::Rc::clone(&hub));
    let ids: Vec<String> = [
        "m0", "m1", "m2", "m3", "m4", "m5", "e0", "e1", "e2", "e3", "e4", "e5", "s0", "s1", "s2",
    ]
    .map(String::from)
    .to_vec();
    let mut now = 0.0;
    let mut checked = 0;
    let mut n = 0;
    let mut frame = |s: &mut HomeScreen, now: &mut f64, hub: &ImageHub| {
        *now += FRAME_MS;
        s.settle_images(*now);
        let (list, _) = s.frame(*now);
        n += 1;
        checked += check_frame(hub, s, &list, 1.0, &ids, n % 10 == 0);
    };
    for _ in 0..30 {
        frame(&mut s, &mut now, &hub);
    }
    // Drag the page up and down, and the first rail sideways, many times.
    for round in 0..6 {
        let dir = if round % 2 == 0 { -1.0 } else { 1.0 };
        let (x0, y0) = (300.0, if dir < 0.0 { 700.0 } else { 150.0 });
        s.touch_down(x0, y0, now);
        for i in 1..=12 {
            now += FRAME_MS;
            s.touch_move(x0, y0 + dir * 30.0 * i as f32, now);
            frame(&mut s, &mut now, &hub);
        }
        s.touch_up(x0, y0 + dir * 360.0, now + FRAME_MS);
        for _ in 0..40 {
            frame(&mut s, &mut now, &hub);
        }
        let (x1, y1) = (320.0, 300.0);
        s.touch_down(x1, y1, now);
        for i in 1..=10 {
            now += FRAME_MS;
            s.touch_move(x1 - 40.0 * i as f32, y1, now);
            frame(&mut s, &mut now, &hub);
        }
        s.touch_up(x1 - 400.0, y1, now + FRAME_MS);
        for _ in 0..40 {
            frame(&mut s, &mut now, &hub);
        }
    }
    assert!(checked > 50, "too few pictures were checked: {checked}");
    assert_eq!(hub.stale_total(), 0, "a stale rectangle had to be blanked");
    assert!(hub.placed() > 0);
}
