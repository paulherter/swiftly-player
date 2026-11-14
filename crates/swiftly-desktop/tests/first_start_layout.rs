//! The first-start sign-in on a large window: pages sit in the middle, the back chevron is a button and not a drag
//! strip, and pictures follow the window's scale when it changes after the screens exist.

use swiftly_desktop::login_screen::{LoginScreen, Start, Step};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

fn env(w: f32, h: f32, scale: f32) -> Env {
    Env::new(Size::new(w, h), scale, Idiom::Desktop)
}

fn centre_x(f: [f32; 4]) -> f32 {
    f[0] + f[2] / 2.0
}

#[test]
fn jellyfin_address_page_is_centred_in_a_large_window() {
    for (w, h) in [(1440.0, 900.0), (2560.0, 1440.0)] {
        let mut l = LoginScreen::new(env(w, h, 1.5), Cx::deterministic(), Start::Kind);
        l.press("kind:0");
        assert_eq!(l.step(), Step::Address);
        let f = l.frame_of("field:addr").expect("address field");
        assert!(
            (centre_x(f) - w / 2.0).abs() < 2.0,
            "field centred at {w}: {f:?}"
        );
        assert!(
            f[1] > h * 0.25 && f[1] < h * 0.75,
            "field in the middle band at {h}: {f:?}"
        );
    }
}

#[test]
fn quick_connect_page_is_centred_in_a_large_window() {
    let (w, h) = (2560.0, 1440.0);
    let mut l = LoginScreen::new(env(w, h, 1.5), Cx::deterministic(), Start::Kind);
    l.press("kind:0");
    l.type_text("jellyfin.example.org");
    l.submit();
    l.press("quick");
    assert_eq!(l.step(), Step::Quick);
    let f = l.frame_of("password").expect("way back to the password");
    assert!((centre_x(f) - w / 2.0).abs() < 2.0, "button centred: {f:?}");
    assert!(f[1] > h * 0.25, "not stuck to the top: {f:?}");
}

#[test]
fn back_chevron_is_not_part_of_the_window_drag_strip() {
    let mut l = LoginScreen::new(env(1440.0, 900.0, 1.5), Cx::deterministic(), Start::Kind);
    l.press("kind:0");
    let f = l.frame_of("back").expect("back chevron");
    let (x, y) = (f[0] + f[2] / 2.0, f[1] + f[3] / 2.0);
    assert!(
        swiftly_desktop::forms::on_back_arrow(x, y),
        "the drag strip leaves the chevron alone: {f:?}"
    );
    assert!(
        !swiftly_desktop::desk::NavArrows::hits(x, y),
        "this is the spot the arrows rule never covered"
    );
    l.press("back");
    assert_eq!(l.step(), Step::Kind);
}

#[test]
fn wordmark_is_rasterised_again_when_the_scale_changes() {
    let cx = Cx::deterministic();
    let mut l = LoginScreen::new(env(1440.0, 900.0, 1.0), cx.clone(), Start::Kind);
    let _ = l.frame(0.0);
    let (_, _, row_1x) = cx.images.borrow().cursor();
    l.set_env(env(1440.0, 900.0, 1.5));
    let _ = l.frame(16.0);
    // 44 pt at 1.5 = 66 px plus the margin: a tile at least 68 px high exists now, none did at 1x.
    let (_, _, row_15) = cx.images.borrow().cursor();
    assert!(row_1x < 66, "1x tile is {row_1x} px high");
    assert!(row_15 >= 68, "1.5x tile is {row_15} px high");
}

#[test]
fn neighbouring_pictures_never_bleed_into_each_others_edges() {
    use swiftly_render::Atlas;
    let cx = Cx::deterministic();
    let white = [255_u8; 4 * 4 * 4];
    let red = [255, 0, 0, 255].repeat(16);
    let a = cx.add_image(4, 4, &white).unwrap();
    let b = cx.add_image(4, 4, &red).unwrap();
    let store = cx.images.borrow();
    let (pw, _) = store.page.size();
    let x0 = (b.uv[0] * pw as f32).round() as usize;
    let y0 = (b.uv[1] * pw as f32).round() as usize;
    let at = |x: usize, y: usize| {
        let i = (y * pw as usize + x) * 4;
        store.page.pixels()[i..i + 4].to_vec()
    };
    // The texel just left of, above and below the second picture repeats its own edge, not the white neighbour.
    assert_eq!(
        at(x0 - 1, y0),
        vec![255, 0, 0, 255],
        "left of {a:?} / {b:?}"
    );
    assert_eq!(at(x0, y0 - 1), vec![255, 0, 0, 255], "above");
    assert_eq!(at(x0, y0 + 4), vec![255, 0, 0, 255], "below");
}

/// Every icon and the wordmark of the first-start pages is drawn one texel to one device pixel on whole pixels at the
/// scale the user has (1.5): a quad of 19.5 pixels showing 20 texels, or one starting between two pixels, is resampled
/// and looks like a blurry PNG.
#[test]
fn icons_and_wordmark_sit_on_whole_pixels_at_scale_1_5() {
    use swiftly_render::{Atlas, QuadKind};
    let cx = Cx::deterministic();
    let mut l = LoginScreen::new(env(2560.0, 1440.0, 1.5), cx.clone(), Start::Kind);
    for step in 0..2 {
        let mut list = l.frame(0.0).0;
        for i in 1..30 {
            list = l.frame(f64::from(i) * 16.0).0;
        }
        let (iw, ih) = cx.images.borrow().page.size();
        let scale = list.scale();
        let mut seen = 0;
        for q in list.quads().iter().filter(|q| q.kind == QuadKind::Image) {
            seen += 1;
            let (tw, th) = (
                (q.uv[2] - q.uv[0]) * iw as f32,
                (q.uv[3] - q.uv[1]) * ih as f32,
            );
            let (x, y, w, h) = (
                q.rect.x * scale,
                q.rect.y * scale,
                q.rect.w * scale,
                q.rect.h * scale,
            );
            let whole = |v: f32| (v - v.round()).abs() < 0.01;
            assert!(
                whole(x) && whole(y),
                "page {step}: picture at {x},{y} px is between two pixels"
            );
            assert!(
                (w - tw).abs() < 0.01 && (h - th).abs() < 0.01,
                "page {step}: picture drawn {w}x{h} px from {tw}x{th} texels"
            );
        }
        assert!(seen >= 2, "page {step}: icons are drawn");
        l.press("kind:0");
    }
}

#[test]
fn a_picture_as_wide_as_the_page_still_fits() {
    // The image hub reserves a region as wide as the page for the covers; the frame around small pictures must not
    // make that request fail (no cover was drawn at all when it did).
    use swiftly_render::Atlas;
    let cx = Cx::deterministic();
    let (pw, _) = cx.images.borrow().page.size();
    let id = cx.add_image(pw, 128, &vec![0_u8; pw as usize * 128 * 4]);
    assert!(id.is_some(), "a {pw} px wide region is placed");
}

#[test]
fn address_field_look_follows_first_start_and_add_server() {
    use swiftly_desktop::login_mac::address_look;
    // First start is the Mac's `ServerView`: globe and "tv.beispiel.de".
    assert_eq!(address_look(false), ("globe", "tv.beispiel.de"));
    // "Server hinzufügen" is `ServerOnboardingView`: the server symbol and "jellyfin.beispiel.de".
    assert_eq!(address_look(true), ("hard-drives", "jellyfin.beispiel.de"));
}
