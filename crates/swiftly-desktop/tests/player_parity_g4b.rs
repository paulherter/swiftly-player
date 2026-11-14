//! Player parity with the Mac, round 2: volume and mute, the account's next-episode wish, hover growth, the stream
//! that takes over for a download that does not open.
#![allow(clippy::unwrap_used)]

use std::sync::Arc;
use swiftly_desktop::player_screen::{PlayerKey, PlayerScenario, PlayerScreen};
use swiftly_layout::Size;
use swiftly_render::RgbaImage;
use swiftly_settings::{JsonFileStore, KeyValueStore, Value};
use swiftly_ui::{Cx, Env, Idiom};

fn screen() -> PlayerScreen {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    let _ = s.frame(0.0);
    s
}

fn store(tag: &str) -> Arc<JsonFileStore> {
    let dir = std::env::temp_dir().join(format!("g4b-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    Arc::new(JsonFileStore::open(dir.join("settings.json")).unwrap())
}

fn double(st: &JsonFileStore, key: &str) -> f64 {
    match st.get(key) {
        Some(Value::Double(v)) => v,
        other => panic!("{key}: {other:?}"),
    }
}

fn run(s: &mut PlayerScreen, from: u32, to: u32) {
    for t in from..to {
        let _ = s.frame(f64::from(t) * 16.0);
    }
}

/// Mute sets the volume to 0 and remembers the value; the arrow counts up from 0 (`volumeMuted`, `volumeLevel`), the
/// second mute restores; a volume key wakes the controls.
#[test]
fn mute_is_volume_zero_and_the_arrow_counts_up_from_it() {
    let mut s = screen();
    let st = store("mute");
    st.set("playerLautstaerke", Value::Double(0.6)).unwrap();
    s.set_store(Arc::clone(&st), 0.0);
    s.key(PlayerKey::Char('m'), 10.0);
    assert!((double(&st, "playerLautstaerke") - 0.0).abs() < 1e-9);
    assert!((double(&st, "playerLautstaerkeDavor") - 0.6).abs() < 1e-9);
    s.key(PlayerKey::Up, 20.0);
    assert!(
        (double(&st, "playerLautstaerke") - 0.05).abs() < 1e-9,
        "the arrow starts at 0, not at the old value: {}",
        double(&st, "playerLautstaerke")
    );
    s.key(PlayerKey::Down, 30.0);
    s.key(PlayerKey::Char('m'), 40.0);
    assert!(
        (double(&st, "playerLautstaerke") - 0.6).abs() < 1e-9,
        "unmute restores the value before the mute"
    );
}

/// The speaker is one control named for what a press does: "Ton aus" while it plays, "Ton an" at volume 0.
#[test]
fn the_speaker_is_named_for_its_action() {
    let mut s = screen();
    run(&mut s, 0, 120);
    let find = |s: &PlayerScreen, name: &str| {
        fn walk(n: &[swiftly_ui::a11y::A11yNode], name: &str) -> bool {
            n.iter().any(|x| x.label == name || walk(&x.children, name))
        }
        walk(&s.a11y_nodes(), name)
    };
    assert!(find(&s, "Ton aus"));
    s.key(PlayerKey::Char('m'), 2000.0);
    run(&mut s, 125, 250);
    assert!(find(&s, "Ton an"));
}

/// The account's own next-episode wish counts when the player has no own choice; an own choice wins (`Advance.applies`).
#[test]
fn the_accounts_next_episode_wish_reaches_the_player() {
    let mut s = screen();
    let st = store("auto");
    s.set_title_facts(None, Some(false));
    s.set_store(Arc::clone(&st), 0.0);
    assert!(!s.prefs().next_automatic, "the account says no");
    st.set("naechsteAuto", Value::Bool(true)).unwrap();
    s.set_store(Arc::clone(&st), 0.0);
    assert!(s.prefs().next_automatic, "the own choice wins");
}

fn walk_find(n: &[swiftly_ui::a11y::A11yNode], label: &str) -> Option<[f32; 4]> {
    for x in n {
        if x.label.ends_with(label) {
            return x.bounds;
        }
        if let Some(b) = walk_find(&x.children, label) {
            return Some(b);
        }
    }
    None
}

/// Width and height of the pixels that are clearly lighter than the picture behind (the glyph's ink).
fn ink_box(img: &RgbaImage, b: [f32; 4]) -> (usize, usize) {
    let (x0, y0) = (b[0] as usize - 8, b[1] as usize - 8);
    let (x1, y1) = ((b[0] + b[2]) as usize + 8, (b[1] + b[3]) as usize + 8);
    let (mut lo_x, mut hi_x, mut lo_y, mut hi_y) = (usize::MAX, 0, usize::MAX, 0);
    for y in y0..y1 {
        for x in x0..x1 {
            if img.pixel(x, y)[0] > 150 {
                lo_x = lo_x.min(x);
                hi_x = hi_x.max(x);
                lo_y = lo_y.min(y);
                hi_y = hi_y.max(y);
            }
        }
    }
    (hi_x.saturating_sub(lo_x), hi_y.saturating_sub(lo_y))
}

/// The skip buttons grow to 1.06 under the pointer (`PlayerScreen.swift:1973`): more white pixels on the glyph.
#[test]
fn a_skip_button_grows_under_the_pointer() {
    let mut s = screen();
    run(&mut s, 0, 150);
    let b = walk_find(&s.a11y_nodes(), "Sekunden vor").expect("the forward button");
    let (list, _) = s.frame(150.0 * 16.0);
    let before = ink_box(&s.render_software(&list), b);
    // A real movement over a few frames, like a mouse.
    let (cx, cy) = (b[0] + b[2] / 2.0, b[1] + b[3] / 2.0);
    s.pointer_move(cx - 40.0, cy, 151.0 * 16.0);
    s.pointer_move(cx, cy, 152.0 * 16.0);
    run(&mut s, 153, 200);
    let (list, _) = s.frame(200.0 * 16.0);
    let after = ink_box(&s.render_software(&list), b);
    assert!(
        after.1 > before.1,
        "the glyph keeps its size under the pointer ({before:?} -> {after:?})"
    );
}

/// A downloaded file that gives no picture hands over to the stream, once, at its position.
#[test]
fn a_download_that_does_not_open_falls_back_to_the_stream() {
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Failed, 0.0);
    s.set_downloaded(true);
    let _ = s.frame(16.0);
    assert!(s.take_stream_fallback().is_some());
    let _ = s.frame(32.0);
    assert!(s.take_stream_fallback().is_none(), "only once");
}

fn luma_at(img: &RgbaImage, x: usize, y: usize) -> f32 {
    let p = img.pixel(x, y);
    0.299 * f32::from(p[0]) + 0.587 * f32::from(p[1]) + 0.114 * f32::from(p[2])
}

/// Pixels the colour bars' hard edge near `x` takes to go from 10 % to 90 % of its step, on row `y`.
fn edge_width(img: &RgbaImage, x: usize, y: usize) -> usize {
    let (lo, hi) = (luma_at(img, x - 40, y), luma_at(img, x + 40, y));
    let (a, b) = (lo.min(hi), lo.max(hi));
    let up = hi > lo;
    let at = |f: f32| {
        (x - 40..x + 40).find(|&i| {
            let l = luma_at(img, i, y);
            if up {
                l >= a + f * (b - a)
            } else {
                l <= b - f * (b - a)
            }
        })
    };
    match (at(0.1), at(0.9)) {
        (Some(p), Some(q)) => q.saturating_sub(p) + 1,
        _ => 0,
    }
}

/// A layer lies on the blurred picture (`.ultraThinMaterial` + 0.72): the hard edge of the colour bars goes soft.
#[test]
fn a_layer_blurs_the_picture_under_it() {
    let mut s = screen();
    run(&mut s, 0, 150);
    // The yellow / cyan edge of the test pattern, mid-height of the bars.
    let edge = 1280 * 2 / 7;
    let (list, _) = s.frame(150.0 * 16.0);
    let sharp = edge_width(&s.render_software(&list), edge, 300);
    s.send_intent(
        swiftly_vm::PlayerIntent::Layer(Some(swiftly_vm::PlayerLayer::Settings)),
        151.0 * 16.0,
    );
    run(&mut s, 152, 260);
    let (list, _) = s.frame(260.0 * 16.0);
    let soft = edge_width(&s.render_software(&list), edge, 300);
    assert!(
        soft >= sharp + 6,
        "the picture under the layer is not blurred ({sharp} px -> {soft} px)"
    );
}

/// The columns of a layer scroll (`PL:192`): in a window too low for them a drag moves the rows.
#[test]
fn a_layer_column_scrolls_when_it_is_too_long() {
    let env = Env::new(Size::new(1280.0, 330.0), 1.0, Idiom::Desktop);
    let mut s = PlayerScreen::new(env, Cx::deterministic(), PlayerScenario::Playing, 0.0);
    run(&mut s, 0, 150);
    s.send_intent(
        swiftly_vm::PlayerIntent::Layer(Some(swiftly_vm::PlayerLayer::Settings)),
        151.0 * 16.0,
    );
    run(&mut s, 152, 260);
    let (list, _) = s.frame(260.0 * 16.0);
    let before = s.render_software(&list);
    // The "Schlafzeit" column (second, x about 300 .. 500) has seven rows: drag it up.
    s.touch_down(330.0, 250.0, 261.0 * 16.0);
    for i in 1..=8 {
        s.touch_move(330.0, 250.0 - 12.0 * i as f32, (261.0 + i as f64) * 16.0);
    }
    s.touch_up(330.0, 154.0, 270.0 * 16.0);
    run(&mut s, 271, 330);
    let (list, _) = s.frame(330.0 * 16.0);
    let after = s.render_software(&list);
    let mut changed = 0;
    for y in 90..330 {
        for x in 270..520 {
            if before.pixel(x, y) != after.pixel(x, y) {
                changed += 1;
            }
        }
    }
    assert!(
        changed > 500,
        "the column did not move ({changed} pixels changed)"
    );
}

fn all_labels(n: &[swiftly_ui::a11y::A11yNode], out: &mut Vec<(String, Option<[f32; 4]>)>) {
    for x in n {
        out.push((x.label.clone(), x.bounds));
        all_labels(&x.children, out);
    }
}

/// The episodes layer shows what its source delivers (names, runtimes) and a card starts that episode through the core's
/// switch, like the Mac's `start(item)`; the running episode only closes the layer.
#[test]
fn the_episodes_layer_lists_the_sources_episodes_and_switches() {
    let mut s = screen();
    run(&mut s, 0, 150);
    s.send_intent(
        swiftly_vm::PlayerIntent::Layer(Some(swiftly_vm::PlayerLayer::Episodes)),
        151.0 * 16.0,
    );
    run(&mut s, 152, 300);
    let mut labels = Vec::new();
    all_labels(&s.a11y_nodes(), &mut labels);
    let card = labels
        .iter()
        .find(|(l, _)| l == "F4 · Die Rückkehr, 45 Min.")
        .unwrap_or_else(|| panic!("the fourth card is not there: {labels:?}"));
    let b = card.1.expect("bounds");
    s.touch_down(b[0] + 20.0, b[1] + 20.0, 301.0 * 16.0);
    s.touch_up(b[0] + 20.0, b[1] + 20.0, 302.0 * 16.0);
    run(&mut s, 303, 330);
    assert!(
        s.log()
            .iter()
            .any(|l| l.starts_with("effect switch demo-e4 from_card=false")),
        "no switch to the chosen episode: {:?}",
        s.log()
    );
}

/// The overlay's lines come from the file and the tracks that play, not from fixed text (`TechBadge`).
#[test]
fn the_technical_overlay_reads_the_file_and_the_playing_track() {
    use swiftly_desktop::player_host::TechFacts;
    use swiftly_model::MediaStream;
    let stream =
        |index: i64, kind: &str, codec: &str, lang: &str, channels: Option<i64>| MediaStream {
            index: Some(index),
            type_: Some(kind.to_owned()),
            codec: Some(codec.to_owned()),
            language: Some(lang.to_owned()),
            channels,
            ..MediaStream::default()
        };
    let mut video = stream(0, "Video", "hevc", "", None);
    video.width = Some(3840);
    video.height = Some(2160);
    let facts = TechFacts {
        delivery: "Direct Play".to_owned(),
        good: true,
        video: Some(video),
        audios: vec![
            stream(1, "Audio", "ac3", "ger", Some(6)),
            stream(2, "Audio", "aac", "eng", Some(2)),
        ],
        subtitles: Vec::new(),
        container: Some("matroska,webm".to_owned()),
        size: Some(9_000_000_000),
        reason: None,
    };
    let words = swiftly_vm::LabelWords::new(swiftly_l10n::Locale::parse("de"));
    let rows = facts.rows(Some(2), None, 5400.0, &words);
    let text = |name: &str| rows.iter().find(|(n, _)| n == name).map(|(_, v)| v.clone());
    let image = text("Bild").unwrap();
    assert!(image.contains("3840") && image.contains("2160"), "{image}");
    let sound = text("Ton").unwrap();
    assert!(
        sound.to_lowercase().contains("aac"),
        "the second track plays: {sound}"
    );
    let file = text("Datei").unwrap();
    assert!(
        file.contains("MATROSKA") && file.contains("GB") && file.contains("Mbit/s"),
        "{file}"
    );
}

/// The system's now-playing card carries the episode's own name, the series as album and the code as artist (`report`).
#[test]
fn the_now_playing_card_has_the_macs_fields() {
    let mut s = screen();
    run(&mut s, 0, 150);
    s.set_episode_code(Some("S1 · F3".to_owned()));
    run(&mut s, 150, 160);
    let n = s.now_playing().expect("a card while it plays");
    assert_eq!(n.meta.title, "Nordlicht");
    assert_eq!(n.meta.artist.as_deref(), Some("S1 · F3"));
    assert!(n.meta.album.is_some(), "the series is the album");
}

/// The film ends and the player stays open: the system's card stays too, paused at the end (the Mac's now-playing).
#[test]
fn an_ended_film_keeps_its_card_paused_at_the_end() {
    use swiftly_playback::engine::{EngineEvent, EngineState};
    let mut s = screen();
    run(&mut s, 0, 150);
    assert!(s.now_playing().expect("a card while it plays").playing);
    s.engine_event(EngineEvent::State(EngineState::Ended), 151.0 * 16.0);
    run(&mut s, 152, 400);
    let n = s.now_playing().expect("the card stays at the end");
    assert!(!n.playing, "paused, not playing");
    assert!(n.position_s > 0.0);
}

/// A line the app draws itself follows the stored look (`utAussehen`): a yellow look gives yellow ink, not the fixed white.
#[test]
fn the_app_drawn_subtitle_follows_the_stored_look() {
    use swiftly_playback::engine::{Cue, CueBody, EngineEvent};
    use swiftly_support::subtitle::{Colour, SubtitleLook};
    let ink = |colour: Option<Colour>| {
        let mut s = screen();
        if let Some(c) = colour {
            let st = store(&format!("sub{}", c as u8));
            let look = SubtitleLook {
                colour: c,
                ..SubtitleLook::default()
            };
            st.set("utAussehen", Value::Data(look.encoded())).unwrap();
            s.set_store(st, 0.0);
        }
        run(&mut s, 0, 150);
        s.send_intent(swiftly_vm::PlayerIntent::SelectSubtitle(3), 150.0 * 16.0);
        s.engine_event(
            EngineEvent::Cues(vec![Cue {
                id: 1,
                start: 0.0,
                end: 9999.0,
                body: CueBody::Text("Guten Abend".into()),
            }]),
            151.0 * 16.0,
        );
        run(&mut s, 152, 400);
        let (list, _) = s.frame(400.0 * 16.0);
        let img = s.render_software(&list);
        // The brightest pixel of the lower third whose blue is far below its red: yellow ink.
        let mut yellow = 0;
        let mut white = 0;
        for y in 500..760 {
            for x in 200..1080 {
                let p = img.pixel(x, y);
                if p[0] > 200 && p[1] > 200 && p[2] < 90 {
                    yellow += 1;
                }
                if p[0] > 235 && p[1] > 235 && p[2] > 235 {
                    white += 1;
                }
            }
        }
        (yellow, white)
    };
    let (plain_yellow, plain_white) = ink(None);
    assert!(
        plain_white > 300 && plain_yellow < 20,
        "the default look draws white"
    );
    let (yellow, white) = ink(Some(Colour::Yellow));
    assert!(
        yellow > 30 && white < 50,
        "the stored yellow look is not drawn ({yellow} yellow, {white} white)"
    );
}

/// Closing the window during playback closes the player the way the Close button does (stop report, engine stop).
#[test]
fn closing_the_window_stops_and_closes_the_player() {
    let mut s = screen();
    run(&mut s, 0, 150);
    assert!(!s.is_closed());
    s.window_closing(151.0 * 16.0);
    assert!(s.is_closed(), "the player is still open");
    assert!(
        s.engine_calls().iter().any(|c| c.starts_with("stop")),
        "the engine kept playing: {:?}",
        s.engine_calls()
    );
}

/// The audio track in the title's original language carries "(Original)" once the host hands the language over.
#[test]
fn the_original_language_tags_its_audio_track() {
    let mut s = screen();
    run(&mut s, 0, 150);
    let tag = |s: &PlayerScreen| {
        s.vm()
            .tracks()
            .audio
            .iter()
            .filter(|t| t.label.contains("(Original)"))
            .count()
    };
    assert_eq!(tag(&s), 0);
    s.vm().set_original_language(Some("de".to_owned()));
    run(&mut s, 150, 160);
    assert_eq!(tag(&s), 1, "{:?}", s.vm().tracks().audio);
}
