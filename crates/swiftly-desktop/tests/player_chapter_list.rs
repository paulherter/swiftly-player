//! The desktop player's chapter button and list come from the shared core (`PlayerVm::chapters`): the button exists
//! only for a title with chapters, the panel draws the core's rows, and a press sends the core's `JumpToChapter`.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_desktop::player_screen::{PlayerKey, PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::{PlayerIntent, PlayerLayer};

mod common;

fn screen() -> PlayerScreen {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let _ = s.frame(0.0);
    s
}

fn settle(s: &mut PlayerScreen, from: f64) -> f64 {
    let mut now = from;
    for _ in 0..40 {
        now += 16.0;
        let _ = s.frame(now);
    }
    now
}

#[test]
fn the_chapter_button_opens_the_cores_rows_and_a_press_jumps_to_that_chapter() {
    let mut s = screen();
    let mut now = settle(&mut s, 0.0);
    let rows = s.vm().chapters().rows;
    assert_eq!(rows.len(), 4, "the made-up film has four chapters");
    // The Kapitel level of the Folgen box; the rows are the core's, walked by the arrows.
    s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Chapters)), now);
    now = settle(&mut s, now);
    assert_eq!(s.vm().controls().layer, Some(PlayerLayer::Chapters));
    assert!(
        s.frame_of("pm-box").is_some(),
        "the box hangs under the capsule"
    );
    let third = &rows[2];
    for _ in 0..3 {
        assert!(s.key(PlayerKey::Down, now));
    }
    assert!(s.key(PlayerKey::Enter, now));
    now = settle(&mut s, now);
    assert!(
        s.engine_calls()
            .contains(&format!("seek {:.0}", third.start)),
        "no seek to {} in {:?}",
        third.start,
        s.engine_calls()
    );
    assert_eq!(s.vm().controls().layer, None, "the choice closes the panel");
    assert!((s.vm().transport().position - third.start).abs() < 5.0);
    // The running chapter is the marked row now.
    let now_rows = s.vm().chapters().rows;
    assert_eq!(now_rows.iter().filter(|r| r.current).count(), 1);
    assert!(now_rows[2].current);
    let _ = now;
}

#[test]
fn a_title_without_chapters_has_no_chapter_button() {
    let mut s = screen();
    s.set_marks(Vec::new(), Vec::new());
    let now = settle(&mut s, 0.0);
    assert!(s.vm().chapters().rows.is_empty());
    // The core ignores a jump with no chapter behind it.
    s.send_intent(PlayerIntent::JumpToChapter(0), now);
}

/// The open chapter list, pinned as a picture (`UPDATE_GOLDENS=1` rewrites it).
#[test]
fn the_chapter_list_golden() {
    let mut s = screen();
    let mut now = settle(&mut s, 0.0);
    s.send_intent(PlayerIntent::Layer(Some(PlayerLayer::Chapters)), now);
    now = settle(&mut s, now);
    let (list, _) = s.frame(now + 16.7);
    let img = s.render_software(&list);
    let path =
        common::manifest_dir().join("../swiftly-ui/tests/golden/player_desktop_chapters.png");
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
        "chapter list differs by {max} ({:.4} % of the pixels)",
        share * 100.0
    );
}
