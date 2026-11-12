//! Track selection and mapping: Language, OriginalAudio, ColorSelection, TrackRule, TrackMapping
//! (Packages/JellyfinKit). Streams are written in the server's JSON (PascalCase) so both sides decode
//! them with their real `MediaStream` decoder.
use crate::Rng;
use serde_json::{Value, json};

const LANGS: &[&str] = &[
    "ger",
    "deu",
    "de",
    "German",
    "Deutsch",
    "eng",
    "en",
    "English",
    "ENG",
    "fre",
    "fra",
    "French",
    "jpn",
    "ja",
    "Japanese",
    "rus",
    "Russian",
    "und",
    "zxx",
    "mis",
    "unknown",
    "",
    "  ",
    "DE",
    "Eng",
    "pt-BR",
    "zh",
    "chi",
    "Chinese",
    "spa",
    "ita",
    "kor",
    "nor",
    "nob",
    "xx",
    "qaa",
    "pol",
    "tur",
    "ara",
    "heb",
    "Deutsch (Germany)",
    "deutsch",
    "German Forced",
    "\u{00A0}ger",
    "ger\u{00A0}",
    "ger\u{200B}",
    "Ger\u{0301}",
    "é",
    "日本語",
    "Русский",
    "ukr",
    "dut",
    "slo",
    "cze",
    "gre",
];
const PREFS: &[&str] = &[
    "",
    "",
    "Deutsch",
    "English",
    "Français",
    "日本語",
    "Русский",
    "Español",
    "中文",
    "ger",
    "German",
    "Norsk",
];
const TITLES: &[&str] = &[
    "Forced",
    "SDH",
    "Commentary",
    "English Forced",
    "Deutsch [SDH]",
    "",
    "Signs & Songs",
    "Erzwungen",
    "forced",
    "Full",
    "Director's cut",
    "German",
    "en.forced",
    "CC",
    "Hörgeschädigt",
    "Forced - [Russian]",
    "  ",
    "Standard",
];
const CODECS: &[&str] = &[
    "ac3",
    "eac3",
    "dts",
    "aac",
    "subrip",
    "srt",
    "ass",
    "ssa",
    "pgs",
    "dvdsub",
    "h264",
    "AC3",
    "ac-3",
    "E-AC-3",
    "dca",
    "truehd",
    "flac",
    "opus",
    "vorbis",
    "mp3",
    "mp2",
    "pcm_s16le",
    "dvd_subtitle",
    "hdmv_pgs_subtitle",
    "webvtt",
    "mov_text",
    "",
    "A52",
    "vtt",
];
const PLAYER_NAMES: &[&str] = &[
    "Track 1",
    "Forced - [Russian]",
    "German",
    "English - [English]",
    "Deutsch (erzwungen)",
    "Disable",
    "FORCED",
    "Japanese [Forced]",
    "",
    "Track 2 - [Deutsch]",
    "Spanish",
    "No subtitles",
    "This is forced",
];
const IDENTIFIERS: &[&str] = &[
    "1",
    "2",
    "3",
    "0/1",
    "abcdef0123456789abcdef0123456789",
    "ABCDEF0123456789ABCDEF0123456789/1",
    "0123456789abcdef0123456789abcdef/cc/1",
    "/0123456789abcdef0123456789abcdef",
    "0123456789abcdef0123456789abcde",
    "0123456789abcdef0123456789abcdeg",
    "123/cc/1",
    "cc/1",
    "０１２３４５６７８９ａｂｃｄｅｆ０１２３４５６７８９ａｂｃｄｅｆ",
    "0123456789abcdef0123456789abcdef0",
    "x/cc/",
    "//0123456789abcdef0123456789abcdef//a",
];

fn opt_str(rng: &mut Rng, pool: &[&str], none_percent: u64) -> Value {
    if rng.chance(none_percent) {
        Value::Null
    } else {
        json!(*rng.pick(pool))
    }
}
fn opt_bool(rng: &mut Rng) -> Value {
    match rng.below(5) {
        0 => Value::Null,
        1 | 2 => json!(false),
        _ => json!(true),
    }
}

/// A random server stream of the given type.
fn stream(rng: &mut Rng, ty: &str, index: i64) -> Value {
    let mut m = serde_json::Map::new();
    m.insert("Type".into(), json!(ty));
    if rng.chance(95) {
        m.insert("Index".into(), json!(index));
    }
    let language = opt_str(rng, LANGS, 20);
    if !language.is_null() {
        m.insert("Language".into(), language);
    }
    let codec = opt_str(rng, CODECS, 20);
    if !codec.is_null() {
        m.insert("Codec".into(), codec);
    }
    let title = opt_str(rng, TITLES, 60);
    if !title.is_null() {
        m.insert("Title".into(), title);
    }
    for key in ["IsForced", "IsExternal", "IsHearingImpaired", "IsDefault"] {
        let v = opt_bool(rng);
        if !v.is_null() {
            m.insert(key.into(), v);
        }
    }
    if ty == "Audio" {
        if rng.chance(70) {
            m.insert("Channels".into(), json!(*rng.pick(&[1, 2, 6, 8, 0])));
        }
        let o = opt_bool(rng);
        if !o.is_null() && rng.chance(30) {
            m.insert("IsOriginal".into(), o);
        }
    }
    Value::Object(m)
}

fn streams(rng: &mut Rng) -> Vec<Value> {
    let n = rng.range(0, 9);
    let mut out = vec![];
    for i in 0..n {
        let ty = match rng.below(10) {
            0 => "Video",
            1..=4 => "Audio",
            _ => "Subtitle",
        };
        let index = if rng.chance(10) { rng.range(0, 6) } else { i };
        out.push(stream(rng, ty, index));
    }
    if rng.chance(8) && out.len() > 1 {
        let len = out.len() as u64;
        let (a, b) = (rng.below(len) as usize, rng.below(len) as usize);
        out.swap(a, b);
    }
    out
}

fn maybe_index(rng: &mut Rng, streams: &[Value], none_percent: u64) -> Value {
    if rng.chance(none_percent) || streams.is_empty() {
        if rng.chance(30) {
            json!(rng.range(-1, 12))
        } else {
            Value::Null
        }
    } else if rng.chance(85) {
        streams[rng.below(streams.len() as u64) as usize]
            .get("Index")
            .cloned()
            .unwrap_or(Value::Null)
    } else {
        json!(rng.range(-1, 12))
    }
}

/// An imprint (stored snapshot of a track choice) in its JSON form.
fn imprint(rng: &mut Rng, streams: &[Value]) -> Value {
    let mut m = serde_json::Map::new();
    let sprache = opt_str(rng, LANGS, 25);
    if !sprache.is_null() {
        m.insert("sprache".into(), sprache);
    }
    let codec = opt_str(rng, CODECS, 40);
    if !codec.is_null() {
        m.insert("codec".into(), codec);
    }
    let titel = opt_str(rng, TITLES, 60);
    if !titel.is_null() {
        m.insert("titel".into(), titel);
    }
    m.insert("erzwungen".into(), json!(rng.chance(35)));
    if rng.chance(40) {
        m.insert("kanaele".into(), json!(*rng.pick(&[1, 2, 6, 8])));
    }
    if rng.chance(60) {
        m.insert(
            "position".into(),
            json!(rng.range(0, streams.len() as i64 + 2)),
        );
    }
    m.insert("extern".into(), json!(rng.chance(20)));
    if rng.chance(50) {
        m.insert("name".into(), json!(*rng.pick(PLAYER_NAMES)));
    }
    if rng.chance(40) {
        m.insert("hoergeschaedigt".into(), json!(rng.chance(40)));
    }
    Value::Object(m)
}

fn choice(rng: &mut Rng, streams: &[Value]) -> Value {
    match rng.below(7) {
        0 | 1 => Value::Null,
        2 => json!({ "kind": "off" }),
        3 | 4 => json!({ "kind": "track", "imprint": imprint(rng, streams) }),
        _ => json!({ "kind": "name", "name": *rng.pick(PLAYER_NAMES) }),
    }
}

pub fn language_rules() -> Vec<Value> {
    let forms: Vec<&str> = vec![
        "deutsch",
        "german",
        "ger",
        "deu",
        "english",
        "eng",
        "en",
        "french",
        "fra",
        "japanese",
        "jpn",
        "russian",
        "rus",
        "русский",
        "norwegian",
        "nor",
        "no",
        "is",
        "chinese",
        "zh",
        "mandarin",
        "cat",
        "català",
        "tschechisch",
        "Forced",
        "forced",
        "erzwungen",
        "Track",
        "No",
        "subtitles",
        "[",
        "]",
        "-",
        " ",
        "  ",
        "_",
        ".",
        "1",
        "é",
        "e\u{0301}",
        "İ",
        "ı",
        "ß",
        "Ä",
        "ä",
        "\u{200B}",
        "\u{00A0}",
        "(",
        ")",
        "SDH",
        "Full",
        "this",
        "is",
        "plain",
        "Português",
        "PORTUGUESE",
        "日本語",
        "한국어",
        "korean",
        "ไทย",
        "thai",
    ];
    let mut rng = Rng::new(0x4C41_4E47);
    let mut out = vec![];
    let fixed = [
        "",
        "German",
        "english",
        "Forced - [Russian]",
        "No subtitles",
        "This is forced",
        "gerade",
        "english2",
        "engl",
        "Deutsch",
        "deutsch",
        "ENGLISH FORCED",
        "Japanese [Forced]",
        "ger",
        "xgerx",
        "ger.eng",
        "Chinese (Simplified)",
        "zho",
        "Norwegian Bokmål",
        "nob",
        "slo",
        "slovak",
        "Slovenčina",
        "français",
        "FRANÇAIS",
        "Fran\u{00E7}ais",
        "Franc\u{0327}ais",
        "espanol",
        "español",
        "deu\u{0301}",
        "e\u{0301}ng",
        "tha",
        "tha\u{0E48}",
    ];
    for t in fixed {
        for toward in [
            "",
            "Deutsch",
            "English",
            "Русский",
            "Español",
            "日本語",
            "Slovenčina",
            "Norsk",
        ] {
            out.push(json!({ "text": t, "toward": toward }));
        }
    }
    for _ in 0..3500 {
        let n = rng.range(1, 6) as usize;
        let sep = *rng.pick(&[" ", "-", " - ", "_", "/", "", ", "]);
        let text = (0..n)
            .map(|_| *rng.pick(&forms))
            .collect::<Vec<_>>()
            .join(sep);
        let toward = if rng.chance(50) {
            *rng.pick(&[
                "",
                "Deutsch",
                "English",
                "Français",
                "日本語",
                "Русский",
                "Norsk",
                "中文",
                "Magyar",
            ])
        } else {
            ""
        };
        out.push(json!({ "text": text, "toward": toward }));
    }
    out
}

pub fn original_audio() -> Vec<Value> {
    let langs: Vec<&str> = {
        let mut v: Vec<&str> = LANGS.to_vec();
        v.extend([
            "pt-BR",
            "zh_CN",
            "ZH-tw",
            "-de",
            "_x",
            "de-",
            "en_US",
            "  de  ",
            "\tde",
            "de\t",
            "\u{00A0}de",
            "de\u{3000}",
            "\u{200B}de",
            "\u{FEFF}en",
            "NOB",
            "No",
            "NB",
            "mul",
            "UND",
            "unk",
            "undetermined",
            "Undetermined",
            "srp",
            "tam",
            "tel",
            "est",
            "per",
            "may",
            "ice",
            "yue",
            "cmn",
            "Mandarin",
            "ESPAÑOL",
            "Français",
            "PORTUGUÊS",
            "ß",
            "İ",
            "ǅ",
            "ΑΣ",
        ]);
        v
    };
    let mut rng = Rng::new(0x4F52_4947);
    let mut out = vec![];
    for _ in 0..3000 {
        let stream = if rng.chance(60) {
            let mut m = serde_json::Map::new();
            m.insert("Type".into(), json!("Audio"));
            if rng.chance(80) {
                m.insert("Language".into(), json!(*rng.pick(&langs)));
            }
            let o = opt_bool(&mut rng);
            if !o.is_null() {
                m.insert("IsOriginal".into(), o);
            }
            Value::Object(m)
        } else {
            Value::Null
        };
        out.push(json!({
            "language": opt_str(&mut rng, &langs, 35),
            "stream": stream,
            "original": opt_str(&mut rng, &langs, 25),
        }));
    }
    out
}

pub fn color_selection() -> Vec<Value> {
    let mut rng = Rng::new(0x434F_4C52);
    let mut out = vec![];
    for r in [0.0, 1.0, 10.0, 128.0, 255.0] {
        for g in [0.0, 50.0, 255.0] {
            for b in [0.0, 200.0, 255.0] {
                out.push(json!({ "op": "oklab", "a": r / 255.0, "b": g / 255.0, "c": b / 255.0 }));
            }
        }
    }
    for _ in 0..1000 {
        out.push(json!({ "op": "oklab", "a": rng.unit(), "b": rng.unit(), "c": rng.unit() }));
    }
    for _ in 0..1000 {
        let l = rng.unit();
        let c = rng.unit() * 0.45;
        let h = rng.unit() * 360.0;
        let rad = h.to_radians();
        out.push(json!({ "op": "lab_to_srgb", "a": l, "b": c * rad.cos(), "c": c * rad.sin() }));
        out.push(json!({ "op": "lch_to_srgb", "a": l, "b": c, "c": h }));
    }
    for _ in 0..300 {
        let l = rng.unit() * 1.6 - 0.3;
        let c = rng.unit() * 1.2;
        let h = rng.unit() * 900.0 - 270.0;
        out.push(json!({ "op": "lch_to_srgb", "a": l, "b": c, "c": h }));
        out.push(json!({ "op": "lab_to_srgb", "a": l, "b": c - 0.5, "c": rng.unit() - 0.5 }));
    }
    for (l, c, h) in [
        (0.0, 0.0, 0.0),
        (1.0, 0.0, 0.0),
        (0.5, 0.0, 120.0),
        (0.7, 0.4, 30.0),
        (0.7, 0.4, -30.0),
        (0.5, 0.5, 360.0),
        (-0.1, 0.1, 10.0),
        (1.2, 0.1, 10.0),
    ] {
        out.push(json!({ "op": "lch_to_srgb", "a": l, "b": c, "c": h }));
    }
    out
}

pub fn track_rule() -> Vec<Value> {
    let mut rng = Rng::new(0x5452_554C);
    let mut out = vec![];
    for _ in 0..5000 {
        let s = streams(&mut rng);
        let audio_index = maybe_index(&mut rng, &s, 25);
        let remembered_audio = if rng.chance(45) {
            imprint(&mut rng, &s)
        } else {
            Value::Null
        };
        let ordered_a = if rng.chance(15) {
            maybe_index(&mut rng, &s, 10)
        } else {
            Value::Null
        };
        let ordered_s = if rng.chance(15) {
            maybe_index(&mut rng, &s, 10)
        } else {
            Value::Null
        };
        let imprint_of = if s.is_empty() || rng.chance(30) {
            Value::Null
        } else {
            json!(rng.below(s.len() as u64))
        };
        let remembered_sub = choice(&mut rng, &s);
        let pref_audio = *rng.pick(PREFS);
        let pref_sub = *rng.pick(PREFS);
        let server_audio = maybe_index(&mut rng, &s, 30);
        let server_sub = maybe_index(&mut rng, &s, 30);
        let automatic = rng.chance(60);
        let tonwunsch = *rng.pick(PREFS);
        let imprint_name = opt_str(&mut rng, PLAYER_NAMES, 50);
        out.push(json!({
            "streams": s,
            "remembered_audio": remembered_audio,
            "remembered_sub": remembered_sub,
            "pref_audio": pref_audio,
            "pref_sub": pref_sub,
            "server_audio": server_audio,
            "server_sub": server_sub,
            "automatic": automatic,
            "audio_index": audio_index,
            "tonwunsch": tonwunsch,
            "ordered_audio": ordered_a,
            "ordered_sub": ordered_s,
            "imprint_of": imprint_of,
            "imprint_name": imprint_name,
        }));
    }
    out
}

fn player_track(rng: &mut Rng) -> Value {
    let id = if rng.chance(60) {
        json!(rng.range(0, 9).to_string())
    } else {
        json!(*rng.pick(IDENTIFIERS))
    };
    let name = *rng.pick(PLAYER_NAMES);
    let language = opt_str(rng, LANGS, 30);
    let codec = opt_str(rng, CODECS, 40);
    let channels = if rng.chance(40) {
        json!(*rng.pick(&[1, 2, 6, 8]))
    } else {
        Value::Null
    };
    json!({ "identifier": id, "name": name, "language": language, "codec": codec, "channels": channels })
}

fn tracks_like(rng: &mut Rng, base: i64, deviation: bool) -> Vec<Value> {
    let n = if deviation {
        rng.range(0, base + 3)
    } else {
        base
    };
    (0..n).map(|_| player_track(rng)).collect()
}

const ATTRS: &[&str] = &[
    "abcdef0123456789abcdef0123456789",
    "ABCDEF0123456789ABCDEF0123456789",
    "0123456789abcdef0123456789abcdef",
];

pub fn track_mapping() -> Vec<Value> {
    let mut rng = Rng::new(0x5452_4D41);
    let mut out = vec![];
    for _ in 0..5000 {
        let s = streams(&mut rng);
        let audio_streams: Vec<&Value> = s
            .iter()
            .filter(|x| x["Type"] == "Audio" && x["IsExternal"] != true)
            .collect();
        let sub_streams: Vec<&Value> = s
            .iter()
            .filter(|x| x["Type"] == "Subtitle" && x["IsExternal"] != true)
            .collect();
        let dev = rng.chance(40);
        let mut audio = tracks_like(&mut rng, audio_streams.len() as i64, dev);
        let mut subtitle = tracks_like(&mut rng, sub_streams.len() as i64, dev);
        if rng.chance(50) {
            // make the player tracks agree with the streams: copy language and codec
            for (t, st) in audio.iter_mut().zip(&audio_streams) {
                t["language"] = st.get("Language").cloned().unwrap_or(Value::Null);
                t["codec"] = st.get("Codec").cloned().unwrap_or(Value::Null);
            }
            for (t, st) in subtitle.iter_mut().zip(&sub_streams) {
                t["language"] = st.get("Language").cloned().unwrap_or(Value::Null);
                t["codec"] = st.get("Codec").cloned().unwrap_or(Value::Null);
            }
        }
        let n_files = rng.range(0, 2);
        let files: Vec<Value> = (0..n_files)
            .map(|_| {
                let attr = *rng.pick(ATTRS);
                let attribute = if rng.chance(40) {
                    Value::Null
                } else {
                    json!(attr)
                };
                json!({ "index": rng.range(0, 8), "attribute": attribute })
            })
            .collect();
        if rng.chance(35) {
            for t in subtitle.iter_mut() {
                if rng.chance(50) {
                    let attr = *rng.pick(ATTRS);
                    t["identifier"] = json!(format!("{attr}/{}", rng.range(0, 3)));
                }
            }
        }
        let start_audio = maybe_index(&mut rng, &s, 30);
        let start_sub = maybe_index(&mut rng, &s, 40);
        out.push(json!({
            "audio": audio,
            "subtitle": subtitle,
            "streams": s,
            "files": files,
            "start_audio": start_audio,
            "start_sub": start_sub,
        }));
    }
    out
}

/// Language names in the interface language (`TrackLabel.language(_:locale:)`): every ISO 639-1/639-2 code of the
/// list Foundation names (`iso639_codes.txt`, written by `Tools/LanguageData/generate.swift`) in lower case, upper
/// case and with a region, every written-out name and spelling of the app's language table, and odd input, each in
/// de, en and ru. Codes meaning "no language" are left out: their word ("unbekannt") comes from the package
/// bundle, i.e. the language of the process, not from the locale of the call.
pub fn track_language() -> Vec<Value> {
    const CODES: &str = include_str!("iso639_codes.txt");
    const UNDETERMINED: [&str; 3] = ["und", "mis", "zxx"];
    let mut raws: Vec<String> = Vec::new();
    for code in CODES
        .lines()
        .filter(|c| !c.is_empty() && !UNDETERMINED.contains(c))
    {
        raws.push(code.to_owned());
        raws.push(code.to_uppercase());
        raws.push(format!("{code}-US"));
    }
    for entry in swiftly_rules::language::ALL {
        raws.push(entry.name.to_owned());
        raws.extend(entry.shape.iter().map(|s| (*s).to_owned()));
        raws.extend(entry.shape.iter().map(|s| s.to_uppercase()));
    }
    for odd in [
        "",
        "  ",
        " ger ",
        "pt-BR",
        "pt_br",
        "zh-Hans",
        "zh-Hant-TW",
        "sr-Latn",
        "es-419",
        "en-",
        "-en",
        "xx-yy",
        "qaa",
        "qaz",
        "zzz",
        "Deutsch (Germany)",
        "German Forced",
        "\u{00A0}ger",
        "ger\u{00A0}",
        "ger\u{200B}",
        "Ger\u{0301}",
        "é",
        "日本語",
        "Русский",
        "русский",
        "deu-",
        "ENG",
        "Eng",
        "eNg",
        "fil",
        "tl",
        "mul",
        "nob",
        "nno",
        "nor",
        "hbs",
        "scr",
        "srp",
        "sh",
        "iw",
        "in",
        "ji",
        "jw",
    ] {
        raws.push(odd.to_owned());
    }
    let mut out = Vec::new();
    for locale in ["de", "en", "ru"] {
        for raw in &raws {
            out.push(json!({ "raw": raw, "locale": locale }));
        }
    }
    out
}
