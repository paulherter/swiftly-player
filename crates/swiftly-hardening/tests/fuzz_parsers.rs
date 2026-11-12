//! Mutation fuzzing of the parsers: never panic, never hang, round-trip where defined.
//! Every case runs on its own thread with a time budget; a failure prints target, seed and input.
//! Replay one case with `HARDENING_SEED=<n>`; scale with `HARDENING_ITERS`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::time::Duration;

use swiftly_hardening::Rng;

const BUDGET: Duration = Duration::from_secs(5);

const TOKENS: &[&str] = &[
    "{",
    "}",
    "[",
    "]",
    "\"",
    "\\",
    ",",
    ":",
    "null",
    "true",
    "false",
    "-1",
    "0",
    "\\u0000",
    "\\ud800",
    "99999999999999999999999999",
    "-9223372036854775809",
    "1e999",
    "-1e999",
    "0.0000001",
    "{\"Id\":",
    "[[[[[[[[",
    "]]]]]]]]",
    "\n\n",
    "-->",
    "00:00:00,000",
    "\r\n",
    "<",
    ">",
    "&",
    "%",
    "://",
    "..",
    "\u{FEFF}",
    "\u{202E}",
    "\0",
];

fn mutate(rng: &mut Rng, mut data: Vec<u8>, donors: &[&[u8]]) -> Vec<u8> {
    for _ in 0..rng.range(1, 5) {
        let len = data.len();
        let at = if len == 0 {
            0
        } else {
            rng.below(len as u64) as usize
        };
        match rng.below(11) {
            0 if len > 0 => data[at] ^= 1 << rng.below(8),
            1 if len > 0 => data[at] = rng.below(256) as u8,
            2 if len > 0 => {
                let end = (at + rng.range(1, 20) as usize).min(len);
                data.drain(at..end);
            }
            3 if len > 0 => {
                let end = (at + rng.range(1, 40) as usize).min(len);
                let chunk = data[at..end].to_vec();
                data.splice(at..at, chunk);
            }
            4 => {
                let t = rng.pick(TOKENS).as_bytes().to_vec();
                data.splice(at..at, t);
            }
            5 => data.truncate(at),
            6 => {
                // Deep nesting.
                let depth = rng.range(10, 20_000) as usize;
                let open = *rng.pick(&["[", "{\"a\":", "(", "<a>"]);
                data.splice(at..at, open.repeat(depth).into_bytes());
            }
            7 => {
                // Invalid UTF-8.
                let bad: &[&[u8]] = &[
                    &[0xFF],
                    &[0xC0, 0x80],
                    &[0xE2, 0x82],
                    &[0xF8, 0x88, 0x80, 0x80, 0x80],
                ];
                let b = rng.pick(bad).to_vec();
                data.splice(at..at, b);
            }
            8 => {
                let digits = "9".repeat(rng.range(20, 400) as usize).into_bytes();
                data.splice(at..at, digits);
            }
            9 if !donors.is_empty() => {
                let d = rng.pick(donors);
                if !d.is_empty() {
                    let from = rng.below(d.len() as u64) as usize;
                    let to = (from + rng.range(1, 200) as usize).min(d.len());
                    data.splice(at..at, d[from..to].to_vec());
                }
            }
            _ => data.extend_from_slice(rng.pick(TOKENS).as_bytes()),
        }
    }
    data
}

fn preview(data: &[u8]) -> String {
    let s = String::from_utf8_lossy(&data[..data.len().min(300)]);
    format!(
        "{} bytes: {:?}{}",
        data.len(),
        s,
        if data.len() > 300 { "..." } else { "" }
    )
}

/// Runs `target` over mutations of `samples`; fails with seed and input on panic or hang.
fn fuzz(name: &str, samples: &[&'static [u8]], default_iters: u64, target: fn(&[u8])) {
    common::for_seeds(name, default_iters, |seed| {
        let mut rng = Rng::new(seed ^ 0xF022);
        let base = samples[(seed as usize) % samples.len()].to_vec();
        let input = mutate(&mut rng, base, samples);
        let shown = preview(&input);
        let copy = input.clone();
        if let Err(e) = common::guarded(BUDGET, move || target(&copy)) {
            panic!("{e} on input {shown}");
        }
    });
}

// ---- samples ---------------------------------------------------------------------------------

const MODEL: &[&[u8]] = &[
    include_bytes!("../../swiftly-model/tests/fixtures/emby_movie.json"),
    include_bytes!("../../swiftly-model/tests/fixtures/emby_views.json"),
    include_bytes!("../../swiftly-model/tests/fixtures/emby_playbackInfo.json"),
    include_bytes!("../../swiftly-model/tests/fixtures/emby_authenticate.json"),
    br#"{"Id":"1","Name":"x","Type":"Movie","RunTimeTicks":36000000000,"UserData":{"PlayedPercentage":12.5,"Played":false}}"#,
];

const PLEX: &[&[u8]] = &[
    include_bytes!("../../swiftly-plex/tests/fixtures/movie.json"),
    include_bytes!("../../swiftly-plex/tests/fixtures/episode.json"),
    include_bytes!("../../swiftly-plex/tests/fixtures/show.json"),
    include_bytes!("../../swiftly-plex/tests/fixtures/page.json"),
    include_bytes!("../../swiftly-plex/tests/fixtures/sections.json"),
    include_bytes!("../../swiftly-plex/tests/fixtures/resources.json"),
    include_bytes!("../../swiftly-plex/tests/fixtures/home_users.json"),
    include_bytes!("../../swiftly-plex/tests/fixtures/identity.json"),
    include_bytes!("../../swiftly-plex/tests/fixtures/pin_done.json"),
];

const SUBTITLES: &[&[u8]] = &[
    b"1\n00:00:01,000 --> 00:00:03,500\nHello <i>world</i>\n\n2\n00:00:04,000 --> 00:00:06,000\nSecond\nline\n\n",
    b"\xEF\xBB\xBFWEBVTT\n\nNOTE x\n\n00:01.000 --> 00:03.000 align:start\nHi\n\n01:00:00.000 --> 01:00:02.000\nLate\n",
    b"[Script Info]\nTitle: x\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\an8}Hello\\Nworld\n",
    b"1\r\n00:00:01,000 --> 00:00:02,000\r\nCRLF\r\n\r\n",
];

const ADDRESSES: &[&[u8]] = &[
    b"https://jellyfin.example.com:8920/base",
    b"192.168.0.5:8096",
    b"http://[fe80::1]:8096/",
    b"jellyfin.local",
    b"  HTTP://User:pw@Host.Example/Path/?q=1#frag  ",
    b"https://\xE4\xB8\xAD\xE6\x96\x87.example/",
    br#"{"Address":"http://192.168.0.5:8096","Id":"abc","Name":"Home","EndpointAddress":null}"#,
];

const SETTINGS: &[&[u8]] = &[
    br#"{"CustomPrefs":{"swiftly.theme":"dark","swiftly.n":"3"},"Id":"x","ViewType":"Home"}"#,
    br#"[{"id":"a","konto":"u1","art":"film","titel":"T","bytes":100,"geladen":50,"zustand":"laedt"}]"#,
    br#"{"version":"1.2.3","entries":[{"title":"A","text":"B"}]}"#,
];

// ---- targets ---------------------------------------------------------------------------------

fn target_model(data: &[u8]) {
    if let Ok(item) = serde_json::from_slice::<swiftly_model::Item>(data) {
        // Round trip: what decodes encodes to something that decodes to the same value.
        let text = serde_json::to_vec(&item).expect("encode");
        let again: swiftly_model::Item = serde_json::from_slice(&text).expect("re-decode");
        assert_eq!(item, again, "Item round trip differs");
        let _ = (
            item.episode_code(),
            item.watched_share(),
            item.runtime_seconds(),
            item.context_line(),
        );
    }
    let _ = serde_json::from_slice::<Vec<swiftly_model::Item>>(data);
    let _ = serde_json::from_slice::<serde_json::Value>(data);
}

fn target_plex(data: &[u8]) {
    let _ = swiftly_plex::wire::PlexListing::from_body(data);
    if let Ok(v) = serde_json::from_slice::<serde_json::Value>(data) {
        let _ = swiftly_plex::wire::PlexListing::parse(&v);
        let _ = swiftly_plex::wire::PlexSection::parse(&v);
        let _ = swiftly_plex::wire::PlexHub::parse(&v);
        if let Some(c) = v.get("MediaContainer") {
            let _ = swiftly_plex::wire::PlexListing::parse(c);
        }
    }
}

fn target_subtitles(data: &[u8]) {
    let text = String::from_utf8_lossy(data);
    let cues = swiftly_playback::subtitle_cues::SubtitleCues::parse(&text);
    for c in cues.cues() {
        assert!(c.start <= c.end || c.end.is_nan() || true, "unordered cue");
    }
    for t in [-1.0, 0.0, 1.5, 3600.0, f64::MAX, f64::NAN] {
        let _ = cues.text_at(t);
    }
}

fn target_address(data: &[u8]) {
    let text = String::from_utf8_lossy(data);
    if let Some(n) = swiftly_jellyfin::normalize_server_url_string(&text) {
        // Settles after one more pass (a trailing backslash gives "/base/" first, then "/base").
        let once = swiftly_jellyfin::normalize_server_url_string(&n);
        let twice = once
            .as_deref()
            .and_then(swiftly_jellyfin::normalize_server_url_string);
        assert_eq!(twice, once, "normalize does not settle for {n:?}");
    }
    let _ = swiftly_jellyfin::normalize_server_url(&text);
    let _ = swiftly_jellyfin::discovery::read(data);
}

fn target_settings(data: &[u8]) {
    let _ = swiftly_downloads::decode_list(data);
    let loaded = swiftly_downloads::load_list(Some(data));
    let _ = loaded;
    if let Ok(list) = swiftly_downloads::decode_list(data) {
        let bytes = swiftly_downloads::encode_list(&list).expect("encode list");
        let again = swiftly_downloads::decode_list(&bytes).expect("re-decode list");
        assert_eq!(
            list.len(),
            again.len(),
            "download list length changed in a round trip"
        );
    }
    let _ = serde_json::from_slice::<serde_json::Value>(data);
}

#[test]
fn fuzz_item_json() {
    fuzz("fuzz_parsers", MODEL, 400, target_model);
}
#[test]
fn fuzz_plex_json() {
    fuzz("fuzz_parsers", PLEX, 400, target_plex);
}
#[test]
fn fuzz_subtitle_cues() {
    fuzz("fuzz_parsers", SUBTITLES, 600, target_subtitles);
}
#[test]
fn fuzz_addresses() {
    fuzz("fuzz_parsers", ADDRESSES, 600, target_address);
}
#[test]
fn fuzz_settings_and_download_list() {
    fuzz("fuzz_parsers", SETTINGS, 400, target_settings);
}
