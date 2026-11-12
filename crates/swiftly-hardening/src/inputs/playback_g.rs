//! Oracle inputs (group G, playback profile and plan): DeviceProfile, BitratesLimit, PlayTime,
//! TrailerChoice, PlaybackPlan (make / diagnose / bestSource).
use crate::Rng;
use serde_json::{Value, json};

const BITRATES: &[i64] = &[
    0,
    1,
    -1,
    999,
    1_000_000,
    8_000_000,
    120_000_000,
    999_999_999,
    1_000_000_000,
    1_000_000_001,
    2_147_483_647,
    i64::MAX,
    i64::MIN,
];

pub fn device_profile() -> Vec<Value> {
    let mut out = Vec::new();
    for &max in BITRATES {
        out.push(json!({ "kind": "vlc", "max": max }));
        for av1 in [false, true] {
            out.push(json!({ "kind": "airplay", "max": max, "av1": av1 }));
        }
    }
    out
}

pub fn download_right() -> Vec<Value> {
    let mut out = Vec::new();
    for server in [Value::Null, json!(true), json!(false)] {
        for on in [false, true] {
            out.push(json!({ "server": server, "on": on }));
        }
    }
    out
}

pub fn bitrates_limit() -> Vec<Value> {
    let mut out = Vec::new();
    for direct in [false, true] {
        for mb in [
            i64::MIN,
            -1_000_000,
            -2,
            -1,
            0,
            1,
            2,
            5,
            8,
            10,
            20,
            50,
            100,
            120,
            999,
            1_000,
            1_001,
            4_000,
            1_000_000,
            9_000_000_000_000,
        ] {
            out.push(json!({ "direct": direct, "megabit": mb }));
        }
    }
    let mut rng = Rng::new(0x4252_0001);
    for _ in 0..300 {
        out.push(json!({ "direct": rng.chance(30), "megabit": rng.range(-50, 5_000) }));
    }
    out
}

pub fn play_time() -> Vec<Value> {
    let mut out: Vec<Value> = vec![json!({"v":"nan"}), json!({"v":"inf"}), json!({"v":"-inf"})];
    for v in [
        0.0,
        -0.0,
        -1.0,
        -0.001,
        0.4,
        0.999,
        1.0,
        59.0,
        59.999,
        60.0,
        61.0,
        3599.0,
        3599.9,
        3600.0,
        3601.0,
        86_399.0,
        86_400.0,
        360_000.0,
        1e9,
        1e15,
        9.2e18,
        9.3e18,
        1e300,
        f64::MAX,
        f64::MIN_POSITIVE,
        5e-324,
    ] {
        out.push(json!({ "v": v }));
    }
    let mut rng = Rng::new(0x5054_0001);
    for _ in 0..800 {
        let scale = [60.0, 3600.0, 100_000.0, 1e7][rng.below(4) as usize];
        out.push(json!({ "v": rng.unit() * scale - scale * 0.02 }));
    }
    out
}

const LINKS: &[&str] = &[
    "https://www.youtube.com/watch?v=abc",
    "http://example.com",
    "HTTP://EXAMPLE.COM/x",
    "https://Example.com",
    "https://example.com/",
    "https://example.com",
    "ftp://example.com/x",
    "javascript:alert(1)",
    "file:///etc/passwd",
    "//example.com",
    "example.com",
    "https://",
    "http://",
    "https:///path",
    "https://[::1]/x",
    "https://exa mple.com",
    " https://example.com/a ",
    "\thttps://x.de\n",
    "",
    "   ",
    "https://example.com/ä",
    "https://example.com/%zz",
    "https://日本.jp/",
    "https://example.com:8080/x",
    "https://example.com:99999/",
    "https://user:pw@example.com/",
    "https://example.com?x=1",
    "https://example.com#f",
    "plugin://plugin.video.youtube/?action=play_video&videoid=abc-1_Z",
    "plugin://plugin.video.youtube/play/?video_id=xyz789",
    "PLUGIN://PLUGIN.VIDEO.YOUTUBE/?videoid=AbC",
    "plugin://plugin.video.youtube/?videoid=",
    "plugin://plugin.video.youtube/?videoid=a b",
    "plugin://plugin.video.youtube/?videoid=a&videoid=b",
    "plugin://plugin.video.youtube/?video_id=ä1",
    "plugin://plugin.video.youtube/?videoid=a%2Fb",
    "plugin://plugin.video.youtube/?videoid=a/b",
    "plugin://plugin.video.youtube/?action=play_video",
    "plugin://plugin.video.youtube",
    "plugin://plugin.video.youtube/?videoid=%41bc",
    "plugin://plugin.video.youtube/?videoid=a_b-c&x=1",
    "plugin://plugin.video.vimeo/?videoid=1",
    "plugin://plugin.video.youtube/?videoid=１２３",
    "plugin://plugin.video.youtube/?videoid=a\u{00A0}b",
    "plugin://plugin.video.youtube/?videoid=ab#x",
    "plugin://plugin.video.youtube/ ?videoid=ab",
    "plugin://plugin.video.youtube?videoid=ab",
    "https://youtu.be/abc",
    "mailto:a@b.de",
    "x-http://a.b",
    "https://example.com/a b",
    "https://example.com/\u{200B}",
    "https://ex\u{200B}ample.com/",
    "\u{00A0}https://example.com/",
    "https://example.com\u{3000}",
];

/// Links whose `Url` spelling differs from Foundation's `URL` (F-oracle-G02): only the "web" cases
/// carry them, the candidate lists use the rest.
const SPELLING_ONLY: &[&str] = &[
    "http://example.com",
    "HTTP://EXAMPLE.COM/x",
    "https://Example.com",
    "https://example.com",
    "https:///path",
    "\thttps://x.de\n",
    "https://example.com/%zz",
    "https://example.com:99999/",
    "https://example.com?x=1",
    "https://example.com#f",
    "https://example.com/\u{200B}",
    "https://example.com\u{3000}",
];

fn item(id: &str) -> Value {
    json!({ "Id": id, "Name": format!("n{id}"), "Type": "Trailer" })
}

pub fn trailer_choice() -> Vec<Value> {
    let mut out = Vec::new();
    for l in LINKS {
        out.push(json!({ "op": "web", "text": l }));
    }
    out.push(json!({ "op": "web", "text": Value::Null }));
    let mut rng = Rng::new(0x5452_0001);
    let ids = ["a", "b", "c", "", "a", "d", "A", "ä"];
    let links: Vec<&str> = LINKS
        .iter()
        .copied()
        .filter(|l| !SPELLING_ONLY.contains(l))
        .collect();
    for _ in 0..1500 {
        let nl = rng.below(5);
        let local: Vec<Value> = (0..nl).map(|_| item(rng.pick(&ids))).collect();
        let remote = if rng.chance(15) {
            Value::Null
        } else {
            let nr = rng.below(5);
            Value::Array(
                (0..nr)
                    .map(|_| {
                        if rng.chance(10) {
                            json!({ "Name": "no url" })
                        } else {
                            json!({ "Url": rng.pick(&links), "Name": "t" })
                        }
                    })
                    .collect(),
            )
        };
        out.push(
            json!({ "op": "candidates", "local": local, "remote": remote, "web": rng.chance(70) }),
        );
    }
    out
}

const CONTAINERS: &[&str] = &[
    "mkv",
    "mp4",
    "MKV",
    "mkv,mp4",
    "avi,xyz",
    "xyz",
    "xyz,abc",
    "",
    ",",
    "mkv,",
    ",mkv",
    "mkv, mp4",
    " mkv",
    "ts",
    "m2ts",
    "webm",
    "flac",
    "mka",
    "wmv",
    "ogg",
    "iso",
    "bluray",
    "dvd",
    "hls",
    "m3u8",
    "mpegts,mp4",
    "mov,mp4,m4a,3gp,3g2,mj2",
];
const VCODECS: &[&str] = &[
    "h264",
    "H264",
    "hevc",
    "av1",
    "vp9",
    "mpeg2video",
    "vc1",
    "xvid",
    "msmpeg4v3",
    "wmv3",
    "theora",
    "prores",
    "dvvideo",
    "rv40",
    "",
    "İ",
    "mjpeg",
    "mpeg4",
];
const ACODECS: &[&str] = &[
    "aac",
    "AAC",
    "ac3",
    "eac3",
    "dts",
    "dca",
    "truehd",
    "mlp",
    "opus",
    "flac",
    "pcm_s16le",
    "pcm_s24be",
    "mp3",
    "wmav2",
    "cook",
    "atrac3",
    "qcelp",
    "",
    "ä",
    "vorbis",
    "dtshd",
];
const SCODECS: &[&str] = &[
    "srt",
    "subrip",
    "ass",
    "pgssub",
    "hdmv_pgs_subtitle",
    "dvdsub",
    "vtt",
    "mov_text",
    "dvb_subtitle",
    "sub",
    "idx",
    "SRT",
    "microdvd",
    "xsub",
    "arib_caption",
    "text",
    "",
    "eia_608",
];
const TRANSCODING: &[Option<&str>] = &[
    None,
    None,
    Some("/videos/1/master.m3u8?x=1"),
    Some("videos/1/master.m3u8"),
    Some("/jellyfin/videos/1/stream?a=b#f"),
    Some(""),
    Some("https://other.example/x"),
    Some("//cdn.example/x"),
    Some("?x"),
    Some("/"),
    // Spaces and non-ASCII in the path are the Foundation-parser difference of F-oracle-E02 (domain `server_relative`).
];
const BASES: &[&str] = &[
    "https://h.example.de",
    "https://h.example.de/",
    "https://h.example.de/jellyfin/",
    "http://10.0.0.5:8096",
    "https://h.example.de:8920/sub/dir",
    "https://h.example.de/x?y=1#z",
];
const IDS: &[&str] = &["s1", "s2", "s3", "abc", "x-1", ""];
const SESSIONS: &[Option<&str>] = &[None, Some("sess1"), Some("p-9"), Some("")];

fn bool_opt(rng: &mut Rng) -> Value {
    match rng.below(4) {
        0 => Value::Null,
        1 | 2 => json!(rng.chance(50)),
        _ => json!(rng.chance(50)),
    }
}

fn stream(rng: &mut Rng) -> Value {
    let (ty, codec) = match rng.below(9) {
        0..=2 => ("Video", *rng.pick(VCODECS)),
        3..=5 => ("Audio", *rng.pick(ACODECS)),
        6 | 7 => ("Subtitle", *rng.pick(SCODECS)),
        _ => (
            *rng.pick(&["Data", "EmbeddedImage", "video", ""]),
            *rng.pick(VCODECS),
        ),
    };
    let mut s = json!({ "Type": ty, "Codec": codec });
    if rng.chance(8) {
        s.as_object_mut().map(|o| o.remove("Codec"));
    }
    if ty == "Audio" && rng.chance(70) {
        s["Channels"] = json!(rng.range(0, 12));
    }
    s
}

fn source(rng: &mut Rng) -> Value {
    let mut s = json!({});
    let o = s.as_object_mut().expect("object");
    if rng.chance(92) {
        o.insert("Id".into(), json!(*rng.pick(IDS)));
    }
    if rng.chance(90) {
        o.insert("Container".into(), json!(*rng.pick(CONTAINERS)));
    }
    for (k, v) in [
        ("SupportsDirectPlay", bool_opt(rng)),
        ("SupportsDirectStream", bool_opt(rng)),
        ("SupportsTranscoding", bool_opt(rng)),
    ] {
        if !v.is_null() {
            o.insert(k.into(), v);
        }
    }
    if let Some(t) = *rng.pick(TRANSCODING) {
        o.insert("TranscodingUrl".into(), json!(t));
    }
    if rng.chance(90) {
        let n = rng.below(6);
        o.insert(
            "MediaStreams".into(),
            Value::Array((0..n).map(|_| stream(rng)).collect()),
        );
    }
    s
}

fn response(rng: &mut Rng) -> Value {
    let n = match rng.below(10) {
        0 => 0,
        1..=5 => 1,
        6..=8 => 2,
        _ => 4,
    };
    let mut r = json!({ "MediaSources": (0..n).map(|_| source(rng)).collect::<Vec<_>>() });
    if let Some(s) = *rng.pick(SESSIONS) {
        r["PlaySessionId"] = json!(s);
    }
    if rng.chance(25) {
        r["ErrorCode"] = json!(*rng.pick(&[
            "NotAllowed",
            "NoCompatibleStream",
            "RateLimitExceeded",
            "",
            "Other"
        ]));
    }
    r
}

fn profile(rng: &mut Rng) -> (&'static str, bool) {
    match rng.below(3) {
        0 => ("vlc", false),
        1 => ("airplay", false),
        _ => ("airplay", true),
    }
}

pub fn playback_plan() -> Vec<Value> {
    let mut rng = Rng::new(0x504C_4E01);
    let mut out = Vec::new();
    for i in 0..4000 {
        let (kind, av1) = profile(&mut rng);
        let r = response(&mut rng);
        let preferred = if rng.chance(30) {
            json!(*rng.pick(IDS))
        } else {
            Value::Null
        };
        let op = if i % 3 == 2 { "diagnose" } else { "make" };
        out.push(json!({
            "op": op, "response": r, "kind": kind, "av1": av1, "max": 1_000_000_000,
            "item": *rng.pick(&["item1", "i-2", "abc123", ""]),
            "base": *rng.pick(BASES), "preferred": preferred,
        }));
    }
    out
}
