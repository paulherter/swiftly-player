//! Hostile input: deep nesting, huge numbers, giant lines, odd text. Nothing may panic, hang or overflow the stack.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::time::{Duration, Instant};

/// Runs `f` on a thread with a small stack (so a recursion bug shows) and a deadline.
fn bounded(name: &str, f: impl FnOnce() + Send + 'static) {
    let started = Instant::now();
    let handle = std::thread::Builder::new()
        .name(name.into())
        .stack_size(512 * 1024)
        .spawn(f)
        .expect("spawn");
    let deadline = started + Duration::from_secs(20);
    while !handle.is_finished() {
        assert!(Instant::now() < deadline, "{name} hangs");
        std::thread::sleep(Duration::from_millis(10));
    }
    handle.join().unwrap_or_else(|_| panic!("{name} panicked"));
}

fn nested(open: &str, close: &str, depth: usize) -> Vec<u8> {
    let mut v = open.repeat(depth).into_bytes();
    v.extend_from_slice(close.repeat(depth).as_bytes());
    v
}

#[test]
fn deeply_nested_json_is_an_error_not_a_stack_overflow() {
    for (name, doc) in [
        ("arrays", nested("[", "]", 200_000)),
        ("objects", nested("{\"a\":", "}", 200_000)),
        ("item-people", {
            let mut s = String::from("{\"Id\":\"1\",\"People\":");
            s.push_str(&String::from_utf8(nested("[", "]", 100_000)).expect("utf8"));
            s.push('}');
            s.into_bytes()
        }),
    ] {
        bounded(name, move || {
            assert!(serde_json::from_slice::<swiftly_model::Item>(&doc).is_err());
            assert!(serde_json::from_slice::<Vec<swiftly_model::Item>>(&doc).is_err());
            let _ = swiftly_plex::wire::PlexListing::from_body(&doc);
            assert!(swiftly_downloads::decode_list(&doc).is_err());
            let _ = swiftly_downloads::load_list(Some(&doc));
            let _ = swiftly_jellyfin::discovery::read(&doc);
        });
    }
}

#[test]
fn huge_numbers_and_long_strings_do_not_overflow() {
    bounded("numbers", || {
        for doc in [
            r#"{"Id":"1","RunTimeTicks":99999999999999999999999999,"ProductionYear":-99999999999,"IndexNumber":1e999}"#.to_owned(),
            format!(r#"{{"Id":"{}","Name":"{}"}}"#, "x".repeat(5_000_000), "\u{1F600}".repeat(1_000_000)),
            r#"{"Id":"1","UserData":{"PlaybackPositionTicks":-9223372036854775808,"PlayedPercentage":NaN}}"#.to_owned(),
        ] {
            if let Ok(item) = serde_json::from_str::<swiftly_model::Item>(&doc) {
                let _ = (item.episode_code(), item.watched_share(), item.runtime_seconds(), item.context_line());
            }
        }
    });
}

#[test]
fn subtitle_parser_survives_hostile_files() {
    bounded("subtitles", || {
        let cases: Vec<String> = vec![
            // One giant line with a million override tags.
            format!(
                "[Script Info]\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{}\n",
                "{\\b1}".repeat(1_000_000)
            ),
            // Unclosed tag blocks and brackets.
            format!(
                "1\n00:00:01,000 --> 00:00:02,000\n{}\n",
                "{".repeat(2_000_000)
            ),
            format!(
                "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n{}\n",
                "<c.".repeat(500_000)
            ),
            // Out-of-range timestamps and a timestamp with absurd digits.
            "1\n99999999999:99:99,999 --> 99999999999999999999:00:00,000\nhi\n".to_owned(),
            "Dialogue: 0,9999999999999999999999:00:00.00,0:00:02.00,D,,0,0,0,,x\n".repeat(10_000),
            "\u{0}\u{ffff}\u{200f}\r\r\n\n".repeat(100_000),
        ];
        for text in cases {
            let cues = swiftly_playback::subtitle_cues::SubtitleCues::parse(&text);
            for t in [-1.0, 0.0, 1.5, f64::MAX, f64::NAN, f64::INFINITY] {
                let _ = cues.text_at(t);
            }
        }
    });
}

#[test]
fn settings_and_download_lists_survive_garbage() {
    bounded("settings", || {
        for doc in [
            &b""[..],
            b"\xff\xfe\x00",
            b"{",
            b"null",
            b"[]",
            b"{\"a\":{\"b\":{\"c\":[1,2,{\"d\":null}]}}}",
            &[0u8; 100_000][..],
        ] {
            let _ = swiftly_downloads::load_list(Some(doc));
            let _ = swiftly_downloads::decode_list(doc);
        }
    });
}
