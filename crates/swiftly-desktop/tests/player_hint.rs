//! The key hint under the desktop player's centre row keeps its full text while paused ("Leertaste Abspielen", it was
//! squeezed to "Leert... Abspielen"). The golden pins the picture; `UPDATE_GOLDENS=1` rewrites it.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;
use swiftly_desktop::player_screen::{PlayerKey, PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};

mod common;

#[test]
fn paused_key_hint_is_not_truncated() {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let mut now = 0.0;
    for _ in 0..60 {
        now += 16.7;
        let _ = s.frame(now);
    }
    assert!(s.key(PlayerKey::Space, now));
    for _ in 0..30 {
        now += 16.7;
        let _ = s.frame(now);
    }
    let (list, _) = s.frame(now + 16.7);
    let img = s.render_software(&list);
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-ui/tests/golden/player_desktop_paused_hint.png");
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path).expect("golden");
        return;
    }
    let golden = RgbaImage::read_png(&path).expect("golden");
    assert_eq!(
        (img.width, img.height),
        (golden.width, golden.height),
        "size"
    );
    let (max, share) = img.diff(&golden);
    assert!(
        common::golden_ok(max, share),
        "paused hint differs by {max} ({:.4} % of the pixels)",
        share * 100.0
    );
}
