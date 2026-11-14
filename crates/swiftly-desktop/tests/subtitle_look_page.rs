//! The "Untertitel" settings page on the desktop: rendered once so the picture can be read (set `SWIFTLY_TEST_PNG_DIR`).

use swiftly_desktop::settings_screen::SettingsScreen;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

#[test]
fn the_subtitle_look_page_renders_with_the_preview_standing_on_its_bottom_gap() {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = SettingsScreen::new(env, Cx::deterministic(), true);
    s.open_page("subtitles");
    let mut now = 0.0;
    for _ in 0..40 {
        now += 1000.0 / 60.0;
        let _ = s.frame(now);
    }
    let (list, _) = s.frame(now + 1.0);
    let img = s.render_software(&list);
    assert_eq!((img.width, img.height), (1280, 800));
    if let Some(dir) = std::env::var_os("SWIFTLY_TEST_PNG_DIR") {
        let _ = std::fs::create_dir_all(&dir);
        img.write_png(&std::path::PathBuf::from(dir).join("subtitle-look-page.png"))
            .unwrap();
    }
    // The preview text: two white lines; its outline copies sit right around it (they once wrapped into a second line).
    let px = |x: usize, y: usize| {
        [
            img.pixels[(y * img.width + x) * 4],
            img.pixels[(y * img.width + x) * 4 + 1],
            img.pixels[(y * img.width + x) * 4 + 2],
        ]
    };
    let rows = |test: &dyn Fn([u8; 3]) -> bool| -> Option<(usize, usize)> {
        let hit: Vec<usize> = (100..img.height - 100)
            .filter(|y| (30..620).any(|x| test(px(x, *y))))
            .collect();
        Some((*hit.first()?, *hit.last()?))
    };
    let white = rows(&|p| p.iter().all(|c| *c > 235)).expect("preview text");
    let black = rows(&|p| p.iter().all(|c| *c < 6)).expect("outline");
    eprintln!("white rows {white:?}, black rows {black:?}");
    // Two short lines (the Apple sample), not a wrapped third.
    assert!(
        white.1 - white.0 < 62,
        "two lines of text, not three ({white:?})"
    );
    assert!(
        black.0 + 4 >= white.0 && black.1 <= white.1 + 4,
        "the outline hugs the text: white {white:?}, black {black:?}"
    );
}

fn open_subtitles(w: f32, h: f32, scale: f32) -> SettingsScreen {
    let env = Env::new(Size::new(w, h), scale, Idiom::Desktop);
    let mut s = SettingsScreen::new(env, Cx::deterministic(), true);
    s.open_page("subtitles");
    let mut now = 0.0;
    for _ in 0..40 {
        now += 1000.0 / 60.0;
        let _ = s.frame(now);
    }
    let _ = s.frame(now + 1.0);
    s
}

/// A 1280 px window at 125 % (the page is about 800 pt wide beside the sidebar): the segments of Größe, Rand and Position do not fit beside their titles ("Posi…"), so
/// they stack under them like the Mac's `ViewThatFits`; in a wide window they stay beside the title.
#[test]
fn the_segment_rows_stack_when_the_window_is_narrow_and_stay_inline_when_wide() {
    let narrow = open_subtitles(800.0, 640.0, 1.25);
    let wide = open_subtitles(1920.0, 1080.0, 1.0);
    let xs = |s: &SettingsScreen| -> Vec<f32> {
        ["sub.size.0", "sub.outline.0", "sub.position.0"]
            .iter()
            .map(|k| s.frame_of(k).unwrap_or_else(|| panic!("{k}"))[0])
            .collect()
    };
    // Stacked strips start at the same left edge (under the icon); inline ones are right-aligned, so their widths decide.
    let (n, w) = (xs(&narrow), xs(&wide));
    assert!(
        (n[0] - n[1]).abs() < 1.0 && n[2] > n[0] + 20.0,
        "Größe and Rand stack under their titles in a narrow window (Position still fits beside its own): {n:?}"
    );
    assert!(
        w.iter().any(|x| (x - w[0]).abs() > 20.0),
        "the strips stack in a wide window: {w:?}"
    );
}

/// The sample picture has its room from the start: a page filled with posters and icons no longer takes it away.
#[test]
fn the_preview_picture_survives_a_full_image_page() {
    let cx = swiftly_desktop::frame_surface::app_cx();
    let block = vec![40_u8; 256 * 256 * 4];
    while cx.add_image(256, 256, &block).is_some() {}
    let small = vec![40_u8; 8 * 8 * 4];
    while cx.add_image(8, 8, &small).is_some() {}
    assert!(
        swiftly_desktop::settings_pages::preview_picture(&cx).is_some(),
        "no room for the preview picture on a full page"
    );
}
