//! Domain `model_decode`: raw JSON text of the wire models (Item, ItemsResponse, MediaSource,
//! MediaStream, PlaybackInfoResponse, UserItemData, Person) with missing fields, nulls, wrong
//! types, huge numbers, unicode and Emby-style variants. Case: `{"kind": ..., "json": "<text>"}`.
use crate::Rng;
use serde_json::{Value, json};

#[derive(Clone, Copy)]
enum K {
    S,
    I,
    D,
    B,
    SA,
    Map,
    People,
    Studios,
    Trailers,
    UserData,
    Sources,
    Streams,
    Date,
    Rating,
    ItemType,
    PersonType,
    StreamType,
    Range,
    Num,
}

const STRINGS: &[&str] = &[
    "",
    " ",
    "a",
    "Movie",
    "The Adam Project",
    "Ünïcödé Ñame",
    "日本語のタイトル",
    "😀 emoji 🎬",
    "e\u{301}",
    "tab\\there",
    "quote \\\" and \\\\ slash",
    "line\\nbreak",
    "\\u0000nul",
    "\\u00e9\\u0301",
    "a/b?c=d&e",
    "\u{200B}zero",
    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "\\ud83d\\ude00",
    "<b>html</b>",
    "٣٤٥",
    "RTL \u{202E}text",
];
const INTS: &[&str] = &[
    "0",
    "1",
    "-1",
    "7",
    "2019",
    "36000000000",
    "9223372036854775807",
    "9223372036854775808",
    "-9223372036854775808",
    "2019.0",
    "7.2e10",
    "1e3",
    "1E3",
    "2019.5",
    "\"12\"",
    "18446744073709551615",
    "1e400",
    "-0",
    "-0.0",
    "0.0",
    "1.0e0",
    "9007199254740993",
    "4294967296",
    "2147483648",
    "-2147483649",
    "0.1e1",
    "1e-400",
    "123456789012345678901234567890",
];
const DOUBLES: &[&str] = &[
    "7.5",
    "0",
    "-1",
    "8",
    "10",
    "1e308",
    "5e-324",
    "\"7.5\"",
    "7.123456789012345",
    "1e400",
    "-1e400",
    "0.0",
    "-0.0",
    "23.976",
    "23.976023976",
    "24",
    "\"24\"",
    "\"abc\"",
    "\"\"",
    "\"NaN\"",
    "\"Infinity\"",
    "\"1e3\"",
    "\" 24 \"",
    "\"0x10\"",
    "\"23,976\"",
    "240",
    "250",
    "249.99",
    "1",
    "1.5",
    "100",
    "100.5",
    "-5",
    "1e2",
    "\"  \"",
    "\"+24\"",
    "\"24.\"",
    "\".5\"",
    "\"1_000\"",
];
const DATES: &[&str] = &[
    "2024-05-17T12:34:56.1234567Z",
    "2024-05-17T12:34:56Z",
    "2024-05-17T12:34:56.789Z",
    "2024-05-17T12:34:56+02:00",
    "2024-05-17",
    "2024-05-17 12:34:56",
    "",
    "garbage",
    "2024-13-45T99:99:99Z",
    "1970-01-01T00:00:00Z",
    "0001-01-01T00:00:00.0000000Z",
    "9999-12-31T23:59:59.9999999Z",
    "2024-05-17T12:34:56.12345678901Z",
    "2024-05-17t12:34:56z",
    "2024-05-17T12:34:56",
    "2024-05-17T12:34Z",
    "20240517T123456Z",
    "2024-05-17T12:34:56-0530",
    "2024-05-17T12:34:56.5+05:30",
    "12:34:56",
    "2024-02-30T10:00:00Z",
];
const ITEM_TYPES: &[&str] = &[
    "Movie",
    "Series",
    "Season",
    "Episode",
    "BoxSet",
    "Playlist",
    "CollectionFolder",
    "UserView",
    "Folder",
    "Person",
    "Audio",
    "MusicAlbum",
    "movie",
    "",
    "Video",
    "TvChannel",
];
const PERSON_TYPES: &[&str] = &[
    "Actor",
    "Director",
    "Writer",
    "Producer",
    "GuestStar",
    "actor",
    "",
    "Composer",
];
const STREAM_TYPES: &[&str] = &[
    "Video",
    "Audio",
    "Subtitle",
    "EmbeddedImage",
    "Data",
    "video",
    "",
];
const RANGES: &[&str] = &[
    "SDR",
    "HDR10",
    "HDR10Plus",
    "HLG",
    "DOVI",
    "DOVIWithHDR10",
    "DOVIWithHLG",
    "DOVIWithSDR",
    "DOVIWithEL",
    "DOVIInvalid",
    "Unknown",
    "sdr",
    "",
    "NewType",
    "DOVIWithELHDR10Plus",
    "DOVIWithHDR10Plus",
];
const WRONG: &[&str] = &[
    "null",
    "true",
    "false",
    "0",
    "-1",
    "1.5",
    "\"x\"",
    "\"\"",
    "[]",
    "{}",
    "[1,\"a\",null]",
    "{\"a\":\"b\"}",
    "1e400",
    "99999999999999999999",
    "[[]]",
    "{\"Id\":\"nested\"}",
    "\"7\"",
    "[\"a\",\"b\"]",
];

fn string(rng: &mut Rng) -> String {
    format!("\"{}\"", rng.pick(STRINGS))
}

fn array(rng: &mut Rng, n: i64, mut each: impl FnMut(&mut Rng) -> String) -> String {
    let items: Vec<String> = (0..rng.range(0, n)).map(|_| each(rng)).collect();
    format!("[{}]", items.join(","))
}

fn object(rng: &mut Rng, fields: &[(&str, K)], keep: u64, depth: u32) -> String {
    let mut parts = vec![];
    for (key, k) in fields {
        let required = matches!(*key, "Id" | "Name");
        if required && rng.chance(88) || rng.chance(keep) {
            parts.push(format!("\"{key}\":{}", value(rng, *k, depth)));
        }
    }
    if rng.chance(8) {
        parts.push("\"Unknown\":{\"x\":[1,2,{\"y\":null}]}".to_owned());
    }
    format!("{{{}}}", parts.join(","))
}

fn value(rng: &mut Rng, k: K, depth: u32) -> String {
    let roll = rng.below(100);
    if roll < 8 {
        return "null".into();
    }
    if roll < 22 {
        return (*rng.pick(WRONG)).to_owned();
    }
    let d = depth + 1;
    match k {
        K::S => string(rng),
        K::I => (*rng.pick(INTS)).to_owned(),
        K::D | K::Num => (*rng.pick(DOUBLES)).to_owned(),
        K::B => rng
            .pick(&["true", "false", "1", "0", "\"true\"", "\"false\""])
            .to_string(),
        K::SA => array(rng, 4, string),
        K::Map => {
            let n = rng.range(0, 4);
            let keys = [
                "Tmdb", "Imdb", "Tvdb", "Primary", "Backdrop", "Logo", "", "Zap",
            ];
            let parts: Vec<String> = (0..n)
                .map(|_| {
                    format!(
                        "\"{}\":{}",
                        rng.pick(&keys),
                        if rng.chance(12) {
                            (*rng.pick(WRONG)).to_owned()
                        } else {
                            string(rng)
                        }
                    )
                })
                .collect();
            format!("{{{}}}", parts.join(","))
        }
        K::People => {
            let f = [
                ("Id", K::S),
                ("Name", K::S),
                ("Role", K::S),
                ("Type", K::PersonType),
                ("PrimaryImageTag", K::S),
            ];
            array(rng, 4, |r| object(r, &f, 60, d))
        }
        K::Studios => array(rng, 3, |r| {
            object(r, &[("Id", K::S), ("Name", K::S)], 70, d)
        }),
        K::Trailers => array(rng, 3, |r| {
            object(r, &[("Url", K::S), ("Name", K::S)], 70, d)
        }),
        K::UserData => object(
            rng,
            &[
                ("PlaybackPositionTicks", K::I),
                ("Played", K::B),
                ("IsFavorite", K::B),
                ("PlayedPercentage", K::Rating),
                ("UnplayedItemCount", K::I),
                ("LastPlayedDate", K::Date),
            ],
            60,
            d,
        ),
        K::Sources => array(rng, 3, |r| object(r, SOURCE, 55, d)),
        K::Streams => array(rng, 5, |r| object(r, STREAM, 55, d)),
        K::Date => format!("\"{}\"", rng.pick(DATES)),
        K::Rating => rng
            .pick(&[
                "0",
                "50",
                "99.5",
                "100",
                "100.0001",
                "-5",
                "1e30",
                "-1e30",
                "0.0",
                "33.333333333333336",
                "1e-9",
                "5e-324",
                "75",
            ])
            .to_string(),
        K::ItemType => format!("\"{}\"", rng.pick(ITEM_TYPES)),
        K::PersonType => format!("\"{}\"", rng.pick(PERSON_TYPES)),
        K::StreamType => format!("\"{}\"", rng.pick(STREAM_TYPES)),
        K::Range => format!("\"{}\"", rng.pick(RANGES)),
    }
}

const ITEM: &[(&str, K)] = &[
    ("Id", K::S),
    ("Name", K::S),
    ("Type", K::ItemType),
    ("CollectionType", K::S),
    ("ProductionYear", K::I),
    ("Overview", K::S),
    ("RunTimeTicks", K::I),
    ("SeriesName", K::S),
    ("IndexNumber", K::I),
    ("ParentIndexNumber", K::I),
    ("SeriesId", K::S),
    ("SeasonId", K::S),
    ("Genres", K::SA),
    ("OfficialRating", K::S),
    ("CommunityRating", K::D),
    ("ChildCount", K::I),
    ("LocalTrailerCount", K::I),
    ("BackdropImageTags", K::SA),
    ("SeriesPrimaryImageTag", K::S),
    ("People", K::People),
    ("Studios", K::Studios),
    ("Taglines", K::SA),
    ("CriticRating", K::D),
    ("RemoteTrailers", K::Trailers),
    ("ImageTags", K::Map),
    ("UserData", K::UserData),
    ("MediaSources", K::Sources),
    ("ParentBackdropImageTags", K::SA),
    ("ParentBackdropItemId", K::S),
    ("ParentThumbImageTag", K::S),
    ("ParentLogoImageTag", K::S),
    ("ParentThumbItemId", K::S),
    ("PremiereDate", K::Date),
    ("ProductionLocations", K::SA),
    ("ProviderIds", K::Map),
    ("OriginalLanguage", K::S),
    ("ExtraType", K::S),
    ("MediaType", K::S),
    ("SortName", K::S),
    ("DateCreated", K::Date),
];
const STREAM: &[(&str, K)] = &[
    ("Codec", K::S),
    ("Type", K::StreamType),
    ("Language", K::S),
    ("DisplayTitle", K::S),
    ("Channels", K::I),
    ("IsDefault", K::B),
    ("IsForced", K::B),
    ("IsExternal", K::B),
    ("IsHearingImpaired", K::B),
    ("IsOriginal", K::B),
    ("AspectRatio", K::S),
    ("Title", K::S),
    ("DeliveryUrl", K::S),
    ("Index", K::I),
    ("Height", K::I),
    ("Width", K::I),
    ("VideoRangeType", K::Range),
    ("ColorTransfer", K::S),
    ("ColorPrimaries", K::S),
    ("DvProfile", K::Num),
    ("DvBlSignalCompatibilityId", K::Num),
    ("RealFrameRate", K::Num),
    ("AverageFrameRate", K::Num),
];
const SOURCE: &[(&str, K)] = &[
    ("Id", K::S),
    ("Name", K::S),
    ("Container", K::S),
    ("Size", K::I),
    ("SupportsDirectPlay", K::B),
    ("SupportsDirectStream", K::B),
    ("SupportsTranscoding", K::B),
    ("TranscodingUrl", K::S),
    ("MediaStreams", K::Streams),
    ("DefaultAudioStreamIndex", K::I),
    ("DefaultSubtitleStreamIndex", K::I),
    ("RunTimeTicks", K::I),
];
const PERSON: &[(&str, K)] = &[
    ("Id", K::S),
    ("Name", K::S),
    ("Role", K::S),
    ("Type", K::PersonType),
    ("PrimaryImageTag", K::S),
];
const USER_DATA: &[(&str, K)] = &[
    ("PlaybackPositionTicks", K::I),
    ("Played", K::B),
    ("IsFavorite", K::B),
    ("PlayedPercentage", K::Rating),
    ("UnplayedItemCount", K::I),
    ("LastPlayedDate", K::Date),
];

fn case(kind: &str, text: impl Into<String>) -> Value {
    json!({ "kind": kind, "json": text.into() })
}

pub fn cases() -> Vec<Value> {
    let mut rng = Rng::new(0x4D4F_4445);
    let mut out = vec![];

    // Recorded shapes and hostile documents (every kind sees the same raw texts).
    let hostile: Vec<String> = vec![
        "{}".into(), "[]".into(), "null".into(), "\"\"".into(), "".into(), " ".into(), "{".into(), "{\"Id\":\"a\"".into(), "{\"Id\":\"a\",\"Name\":\"b\"}x".into(),
        "{\"Id\":\"a\",\"Id\":\"b\",\"Name\":\"n\"}".into(), "{\"id\":\"a\",\"name\":\"n\"}".into(), "{\"ID\":\"a\",\"NAME\":\"n\"}".into(),
        "\u{FEFF}{\"Id\":\"a\",\"Name\":\"n\"}".into(), "{\"Id\":\"a\",\"Name\":\"n\",}".into(), "{\"Id\":\"a\",\"Name\":\"n\"} ".into(),
        "{\"Id\":\"a\",\"Name\":\"n\"} // c".into(), "/* c */{\"Id\":\"a\",\"Name\":\"n\"}".into(), "{'Id':'a','Name':'n'}".into(),
        "{\"Id\":12,\"Name\":\"n\"}".into(), "{\"Id\":\"a\",\"Name\":12}".into(), "{\"Id\":null,\"Name\":\"n\"}".into(), "{\"Id\":\"a\"}".into(), "{\"Name\":\"n\"}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"X\":NaN}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"CommunityRating\":NaN}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"CommunityRating\":Infinity}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"CommunityRating\":-Infinity}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"RunTimeTicks\":01}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"RunTimeTicks\":+1}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"RunTimeTicks\":.5}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"RunTimeTicks\":1.}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"RunTimeTicks\":0x10}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"RunTimeTicks\":1e+2}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"RunTimeTicks\":-}".into(),
        "{\"Id\":\"\\ud800\",\"Name\":\"n\"}".into(), "{\"Id\":\"\\udc00x\",\"Name\":\"n\"}".into(), "{\"Id\":\"a\\u0000b\",\"Name\":\"n\"}".into(), "{\"Id\":\"a\nb\",\"Name\":\"n\"}".into(),
        "{\"Id\":\"a\tb\",\"Name\":\"n\"}".into(), "{\"Id\":\"\\x\",\"Name\":\"n\"}".into(), "{\"Id\":\"\\/\",\"Name\":\"n\"}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"Genres\":[\"a\",1,\"b\"]}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"People\":[{\"Id\":\"p\",\"Name\":\"q\"},{\"Name\":\"x\"}]}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"ImageTags\":{\"Primary\":1}}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"ProviderIds\":{\"Tmdb\":123}}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"ProviderIds\":{\"Tmdb\":\"1\",\"Tmdb\":\"2\"}}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"UserData\":[]}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"UserData\":{\"PlayedPercentage\":1e30}}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"UserData\":{\"PlayedPercentage\":-1e30}}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"UserData\":{\"PlayedPercentage\":\"50\"}}".into(), "{\"Id\":\"a\",\"Name\":\"n\",\"UserData\":{\"Played\":\"true\"}}".into(),
        // Emby: ids can be numbers, ticks floats, UserData missing, MediaSources with other casing.
        "{\"Id\":\"1234\",\"Name\":\"Emby\",\"Type\":\"Movie\",\"RunTimeTicks\":72000000000.0,\"ProductionYear\":2020.0,\"UserData\":{\"PlaybackPositionTicks\":0.0,\"PlayCount\":0,\"IsFavorite\":false,\"Played\":false}}".into(),
        "{\"Id\":\"1234\",\"Name\":\"Emby\",\"ServerId\":\"x\",\"IsFolder\":false,\"MediaSources\":[{\"Id\":\"s\",\"Protocol\":\"File\",\"Size\":1,\"MediaStreams\":[{\"Type\":\"Video\",\"Codec\":\"h264\",\"RealFrameRate\":23.976,\"Index\":0,\"Height\":1080}]}]}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"MediaSources\":[{\"Id\":\"s\",\"MediaStreams\":[{\"Type\":\"Video\",\"Height\":\"1080\"}]}]}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"MediaSources\":[{\"Id\":\"s\",\"MediaStreams\":[{\"Type\":\"Video\",\"Height\":1080.0},{\"Type\":\"Audio\",\"Channels\":6.0}]}]}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"MediaSources\":[{\"Size\":\"5\"}]}".into(),
        "{\"Id\":\"a\",\"Name\":\"n\",\"MediaSources\":null}".into(),
        format!("{{\"Id\":\"a\",\"Name\":\"n\",\"Deep\":{}}}", "[".repeat(100) + &"]".repeat(100)),
        format!("{{\"Id\":\"a\",\"Name\":\"n\",\"Deep\":{}}}", "[".repeat(200) + &"]".repeat(200)),
        format!("{{\"Id\":\"a\",\"Name\":\"n\",\"Deep\":{}}}", "[".repeat(600) + &"]".repeat(600)),
        format!("{{\"Id\":\"{}\",\"Name\":\"n\"}}", "x".repeat(100_000)),
        format!("{{\"Id\":\"a\",\"Name\":\"n\",\"Genres\":[{}]}}", vec!["\"g\""; 5000].join(",")),
    ];
    // Swift scans leniently (BOM, trailing comma, `01`, duplicate keys, nesting up to 512), Rust
    // is strict JSON: those quirks are compared on `item` only (and pinned in known.json); the
    // other kinds get the documents both sides read as proper JSON.
    for kind in [
        "item",
        "items",
        "source",
        "stream",
        "playback",
        "user_data",
        "person",
    ] {
        for h in &hostile {
            let proper = serde_json::from_str::<Value>(h).is_ok()
                && !h.contains("\"Id\":\"a\",\"Id\"")
                && !h.contains("[[[[");
            if kind == "item" || proper {
                out.push(case(kind, h.clone()));
            }
        }
    }
    out.push(case(
        "item",
        "{\"Id\":\"\u{FEFF}a\",\"Name\":\"\u{FEFF}\",\"Overview\":\"\u{FEFF}\u{FEFF}x\"}",
    ));
    out.push(case(
        "item",
        "{\"Id\":\"a\",\"Name\":\"n\",\"RunTimeTicks\":-9223372036854775809}",
    ));
    out.push(case(
        "item",
        "{\"Id\":\"a\",\"Name\":\"n\",\"RunTimeTicks\":-9223372036854775808}",
    ));
    out.push(case(
        "item",
        "{\"Id\":\"a\",\"Name\":\"n\",\"RunTimeTicks\":-9223372036854775808.0}",
    ));
    out.push(case(
        "item",
        "{\"Id\":\"a\",\"Name\":\"n\",\"CommunityRating\":1e400}",
    ));
    out.push(case("items", "{\"Items\":[{\"Id\":\"a\",\"Name\":\"n\",\"CommunityRating\":1e400},{\"Id\":\"b\",\"Name\":\"m\"}]}"));
    out.push(case("items", "{\"Items\":[{\"Id\":\"a\",\"Name\":\"n\",\"RunTimeTicks\":1e400},{\"Id\":\"b\",\"Name\":\"m\"}],\"TotalRecordCount\":2}"));
    out.push(case(
        "items",
        "{\"Items\":[{\"Id\":\"a\",\"Name\":\"n\",\"X\":1e400},{\"Id\":\"b\",\"Name\":\"m\"}]}",
    ));

    // Items responses with broken entries mixed in.
    let items_docs = [
        "{\"Items\":null}",
        "{\"Items\":5}",
        "{\"Items\":{}}",
        "{\"Items\":[]}",
        "{\"Items\":[null,1,\"x\",[],{}]}",
        "{\"TotalRecordCount\":\"7\"}",
        "{\"TotalRecordCount\":7.0,\"Items\":[]}",
        "{\"TotalRecordCount\":7.5,\"Items\":[]}",
        "{\"TotalRecordCount\":-1}",
        "{\"TotalRecordCount\":null,\"Items\":[{\"Id\":\"a\",\"Name\":\"b\"}]}",
        "{\"TotalRecordCount\":99999999999999999999}",
        "{\"Items\":[{\"Id\":\"a\",\"Name\":\"b\"},{\"Id\":5,\"Name\":[]},{\"Id\":\"c\",\"Name\":\"C\"}],\"TotalRecordCount\":3}",
        "{\"items\":[{\"Id\":\"a\",\"Name\":\"b\"}]}",
        "{\"Items\":[{\"Id\":\"a\",\"Name\":\"b\"}],\"Items\":[]}",
        "[]",
        "[{\"Id\":\"a\",\"Name\":\"b\"}]",
    ];
    for d in items_docs {
        out.push(case("items", d));
    }

    // Generated.
    for _ in 0..1500 {
        out.push(case("item", object(&mut rng, ITEM, 55, 0)));
    }
    for _ in 0..400 {
        let entries: Vec<String> = (0..rng.range(0, 6))
            .map(|_| {
                if rng.chance(15) {
                    (*rng.pick(WRONG)).to_owned()
                } else {
                    object(&mut rng, ITEM, 45, 0)
                }
            })
            .collect();
        let total = if rng.chance(30) {
            String::new()
        } else {
            format!(",\"TotalRecordCount\":{}", value(&mut rng, K::I, 0))
        };
        let items = if rng.chance(8) {
            format!(",\"Items\":{}", rng.pick(WRONG))
        } else {
            format!(",\"Items\":[{}]", entries.join(","))
        };
        out.push(case("items", format!("{{{}{}}}", &items[1..], total)));
    }
    for _ in 0..900 {
        out.push(case("stream", object(&mut rng, STREAM, 70, 0)));
    }
    for _ in 0..500 {
        out.push(case("source", object(&mut rng, SOURCE, 60, 0)));
    }
    for _ in 0..250 {
        let sources = array(&mut rng, 3, |r| object(r, SOURCE, 60, 0));
        let doc = match rng.below(6) {
            0 => format!("{{\"MediaSources\":{}}}", rng.pick(WRONG)),
            1 => "{}".to_owned(),
            _ => format!(
                "{{\"MediaSources\":{sources},\"PlaySessionId\":{},\"ErrorCode\":{}}}",
                value(&mut rng, K::S, 0),
                value(&mut rng, K::S, 0)
            ),
        };
        out.push(case("playback", doc));
    }
    for _ in 0..500 {
        out.push(case("user_data", object(&mut rng, USER_DATA, 75, 0)));
    }
    for _ in 0..150 {
        out.push(case("person", object(&mut rng, PERSON, 70, 0)));
    }
    out
}
