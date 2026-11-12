//! Display facts of a title about to play (`swiftly_vm::play_display`, Swift: the player screens' `titleLine`,
//! `metaText`, `fileRow`, `dolbyVision`, `defaultAudioCodec`, `cardImage`, next-episode card). Items and sources are
//! written in the server's JSON so both sides decode them with their real decoders. Text language: English (the oracle process).
use crate::Rng;
use serde_json::{Map, Value, json};

const NAMES: &[&str] = &[
    "Nordlicht",
    "Der Hafen",
    "Ein langer Tag",
    "",
    "  ",
    "Épisode 1",
    "日本語",
    "A · B",
    "Mit Punkt.",
];
const SERIES: &[&str] = &["Die Reise", "", "Nordlicht - die Serie", "Show"];
const GENRES: &[&[&str]] = &[&[], &["Drama"], &["Drama", "Krimi"], &["A", "B", "C"]];
const CONTAINERS: &[&str] = &["mkv", "mp4", "avi", "ts", ""];
const CODECS: &[&str] = &["h264", "hevc", "av1", "vp9", "mpeg4", "H265", "", "unknown"];
const AUDIO_CODECS: &[&str] = &[
    "eac3", "ac3", "aac", "truehd", "dts", "DTS", "flac", "opus", "", "mp3",
];
const LANGUAGES: &[&str] = &[
    "ger", "eng", "deu", "rus", "jpn", "fra", "und", "xx", "", "pt-BR",
];
const RANGES: &[&str] = &[
    "SDR",
    "HDR10",
    "HLG",
    "DOVI",
    "DOVIWithHDR10",
    "DOVIWithHLG",
    "DOVIWithSDR",
    "DOVIWithEL",
    "DOVIWithHDR10Plus",
    "DOVIWithELHDR10Plus",
    "DOVIInvalid",
    "HDR10Plus",
    "Unknown",
    "Bogus",
];

fn maybe(rng: &mut Rng, percent: u64, make: impl FnOnce(&mut Rng) -> Value) -> Option<Value> {
    if rng.chance(percent) {
        Some(make(rng))
    } else {
        None
    }
}

fn item(rng: &mut Rng, id: &str, episode: bool) -> Value {
    let mut m = Map::new();
    m.insert("Id".into(), json!(id));
    m.insert("Name".into(), json!(*rng.pick(NAMES)));
    m.insert(
        "Type".into(),
        json!(if episode {
            "Episode"
        } else {
            *rng.pick(&["Movie", "Movie", "Series", "Video"])
        }),
    );
    if episode {
        if let Some(v) = maybe(rng, 85, |rng| json!(*rng.pick(SERIES))) {
            m.insert("SeriesName".into(), v);
        }
        if let Some(v) = maybe(rng, 85, |rng| json!(format!("series-{}", rng.below(5)))) {
            m.insert("SeriesId".into(), v);
        }
        if let Some(v) = maybe(rng, 80, |rng| json!(format!("season-{}", rng.below(5)))) {
            m.insert("SeasonId".into(), v);
        }
        if let Some(v) = maybe(rng, 85, |rng| json!(rng.range(0, 25))) {
            m.insert("ParentIndexNumber".into(), v);
        }
        if let Some(v) = maybe(rng, 85, |rng| json!(rng.range(0, 40))) {
            m.insert("IndexNumber".into(), v);
        }
    }
    if let Some(v) = maybe(rng, 70, |rng| json!(rng.range(1950, 2026))) {
        m.insert("ProductionYear".into(), v);
    }
    if let Some(v) = maybe(rng, 70, |rng| json!(rng.range(0, 4 * 3600) * 10_000_000)) {
        m.insert("RunTimeTicks".into(), v);
    }
    if rng.chance(60) {
        m.insert("Genres".into(), json!(*rng.pick(GENRES)));
    }
    let mut tags = Map::new();
    if rng.chance(75) {
        tags.insert("Primary".into(), json!(format!("tag{}", rng.below(100))));
    }
    if rng.chance(25) {
        tags.insert("Thumb".into(), json!("thumbtag"));
    }
    if !tags.is_empty() || rng.chance(50) {
        m.insert("ImageTags".into(), Value::Object(tags));
    }
    if rng.chance(30) {
        m.insert("BackdropImageTags".into(), json!(["bd1"]));
    }
    if episode && rng.chance(35) {
        m.insert("ParentBackdropImageTags".into(), json!(["pbd1"]));
        if rng.chance(50) {
            m.insert("ParentBackdropItemId".into(), json!("series-bd"));
        }
    }
    if episode && rng.chance(20) {
        m.insert("ParentThumbImageTag".into(), json!("pthumb"));
    }
    Value::Object(m)
}

fn source(rng: &mut Rng) -> Value {
    let mut m = Map::new();
    m.insert("Id".into(), json!("src"));
    if let Some(v) = maybe(rng, 85, |rng| json!(*rng.pick(CONTAINERS))) {
        m.insert("Container".into(), v);
    }
    let mut streams: Vec<Value> = Vec::new();
    let videos = if rng.chance(90) {
        1
    } else if rng.chance(50) {
        0
    } else {
        2
    };
    for i in 0..videos {
        let mut s = Map::new();
        s.insert("Type".into(), json!("Video"));
        s.insert("Index".into(), json!(i));
        if let Some(v) = maybe(rng, 90, |rng| json!(*rng.pick(CODECS))) {
            s.insert("Codec".into(), v);
        }
        if let Some(v) = maybe(rng, 90, |rng| {
            json!(*rng.pick(&[480, 720, 1080, 2160, 0, 1088]))
        }) {
            s.insert("Height".into(), v);
        }
        if let Some(v) = maybe(rng, 70, |rng| json!(*rng.pick(RANGES))) {
            s.insert("VideoRangeType".into(), v);
        }
        if let Some(v) = maybe(rng, 50, |rng| json!(*rng.pick(&[5, 7, 8, 10, 0]))) {
            s.insert("DvProfile".into(), v);
        }
        if rng.chance(15) {
            s.insert("DisplayTitle".into(), json!("1080p H264"));
        }
        streams.push(Value::Object(s));
    }
    for i in 0..rng.below(4) {
        let mut s = Map::new();
        s.insert("Type".into(), json!("Audio"));
        s.insert("Index".into(), json!(10 + i));
        if let Some(v) = maybe(rng, 85, |rng| json!(*rng.pick(AUDIO_CODECS))) {
            s.insert("Codec".into(), v);
        }
        if let Some(v) = maybe(rng, 85, |rng| json!(*rng.pick(LANGUAGES))) {
            s.insert("Language".into(), v);
        }
        if let Some(v) = maybe(rng, 85, |rng| json!(*rng.pick(&[1, 2, 6, 8, 0, -1]))) {
            s.insert("Channels".into(), v);
        }
        if let Some(v) = maybe(rng, 40, |rng| json!(rng.chance(40))) {
            s.insert("IsDefault".into(), v);
        }
        if rng.chance(15) {
            s.insert("DisplayTitle".into(), json!("Deutsch - EAC3 - 5.1"));
        }
        streams.push(Value::Object(s));
    }
    if rng.chance(50) {
        streams
            .push(json!({"Type": "Subtitle", "Index": 30, "Language": "eng", "Codec": "subrip"}));
    }
    if rng.chance(95) {
        m.insert("MediaStreams".into(), Value::Array(streams));
    }
    Value::Object(m)
}

pub fn play_display() -> Vec<Value> {
    let mut rng = Rng::new(0x504C_4159);
    let mut out = Vec::new();
    for n in 0..2500 {
        let episode = rng.chance(55);
        let it = item(&mut rng, &format!("item{n}"), episode);
        let next = (episode && rng.chance(60)).then(|| item(&mut rng, &format!("next{n}"), true));
        let (base, token) = if rng.chance(90) {
            (
                json!("http://server.example:8096"),
                json!(*rng.pick(&["tok", "a b", ""])),
            )
        } else {
            (Value::Null, Value::Null)
        };
        let mut case = json!({
            "item": it,
            "method": *rng.pick(&["Direct Play", "Direct Stream", "Transcode"]),
            "base": base,
            "token": token,
        });
        if rng.chance(92) {
            case["source"] = source(&mut rng);
        }
        if let Some(next) = next {
            case["next"] = next;
        }
        out.push(case);
    }
    out
}
