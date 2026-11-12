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
    // The preview text: one white line; its outline copies sit right around it (they once wrapped into a second line).
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
    assert!(
        white.1 - white.0 < 30,
        "one line of text, not two ({white:?})"
    );
    assert!(
        black.0 + 4 >= white.0 && black.1 <= white.1 + 4,
        "the outline hugs the text: white {white:?}, black {black:?}"
    );
    // The dark card ends below the text with the 16 px bottom gap plus the line's own descent.
    let card_end = (white.1..img.height).find(|y| {
        px(300, *y)[2] > 20 && px(300, *y)[2] < 40 && px(300, *y + 1)[2] >= 40
            || px(300, *y) == [15, 18, 23] && px(300, *y + 1) != [15, 18, 23]
    });
    eprintln!(
        "card ends {card_end:?}, gap {:?}",
        card_end.map(|e| e - white.1)
    );
    assert!(
        card_end.is_some_and(|e| e - white.1 >= 18),
        "the preview text stands 16 px above the card's bottom edge (plus the line's descent): {card_end:?}"
    );
}
