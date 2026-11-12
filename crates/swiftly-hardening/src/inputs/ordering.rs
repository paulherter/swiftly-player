//! Ordering, sorting and filtering rules: `StartRails`, `StartLibraries`, `SearchHistory`,
//! `LibraryGenre`, `Library` (sorting/filter pills), `ListRules`, `TitleFilter`, `SectionLogic`.
//! Cases are read by `Domain_Ordering.swift` (Tools/Oracle) and `tests/oracle_ordering.rs`.
use crate::Rng;
use serde_json::{Value, json};

const RAILS: &[&str] = &[
    "weiterschauen",
    "naechsteFolge",
    "neueFilme",
    "neueSerien",
    "neuzugaenge",
];
const RAILS_BAD: &[&str] = &[
    "",
    "Weiterschauen",
    "neuefilme",
    "x",
    " neueFilme",
    "neueFilme ",
    "neuzugaenge\n",
    "😀",
];

fn rail(rng: &mut Rng) -> &'static str {
    if rng.chance(10) {
        rng.pick(RAILS_BAD)
    } else {
        rng.pick(RAILS)
    }
}

fn rail_list(rng: &mut Rng, max: u64) -> Vec<&'static str> {
    (0..rng.below(max)).map(|_| rail(rng)).collect()
}

pub fn start_rails() -> Vec<Value> {
    let mut rng = Rng::new(0x5352_4149);
    let mut out = Vec::new();
    for r in RAILS.iter().chain(RAILS_BAD) {
        for disc in [false, true] {
            out.push(json!({ "op": "props", "rail": r, "disc": disc }));
        }
    }
    for _ in 0..1500 {
        let stored = rail_list(&mut rng, 9);
        let disc = rng.chance(50);
        out.push(match rng.below(3) {
            0 => json!({ "op": "applicable", "stored": stored }),
            1 => json!({ "op": "visible", "stored": stored, "hidden": rail_list(&mut rng, 4), "disc": disc }),
            _ => {
                let step = match rng.below(6) {
                    0 => 0,
                    1 => rng.range(-1_000_000_000_000, 1_000_000_000_000),
                    _ => rng.range(-3, 4),
                };
                json!({ "op": "shifted", "rail": rail(&mut rng), "step": step, "stored": stored, "disc": disc })
            }
        });
    }
    out
}

const IDS: &[&str] = &[
    "a", "b", "c", "d", "e", "A", "", " ", "é", "😀", "a b", "id-1", "ID-1", "0", "x/y", "e\u{301}",
];
const NAMES: &[&str] = &[
    "Amélie",
    "AMELIE",
    "amelie ",
    " amelie",
    "Straße",
    "STRASSE",
    "Der Pate",
    "Der  Pate",
    "",
    "İstanbul",
    "ǅ",
    "Film (2020)",
    "a\u{200B}",
    "Ａ",
    "Cæsar",
    "Ünter",
    "unter",
    "Über",
    "x\ty",
    "x y",
];
const TYPES: &[&str] = &[
    "Movie",
    "Series",
    "Episode",
    "Season",
    "BoxSet",
    "Folder",
    "CollectionFolder",
    "Video",
    "",
    "movie",
];
const COLLECTION_TYPES: &[&str] = &[
    "movies",
    "tvshows",
    "music",
    "homevideos",
    "books",
    "playlists",
    "livetv",
    "boxsets",
    "MOVIES",
    "TvShows",
    "Music",
    "LiveTV",
    "Playlists",
    "BOOKS",
    "",
    "mixed",
    "photos",
    "İ",
    "musıc",
    "musicvideos",
    "ſ",
];
const IDS_PROVIDER: &[&str] = &["", "1", "2", "tt1", "tt2", "99", " 1"];

fn item(rng: &mut Rng) -> Value {
    let mut m = serde_json::Map::new();
    m.insert("Id".into(), json!(rng.pick(IDS)));
    m.insert("Name".into(), json!(rng.pick(NAMES)));
    m.insert("Type".into(), json!(rng.pick(TYPES)));
    if rng.chance(50) {
        let mut p = serde_json::Map::new();
        for k in ["Tmdb", "Tvdb", "Imdb", "Other"] {
            if rng.chance(35) {
                p.insert(k.into(), json!(rng.pick(IDS_PROVIDER)));
            }
        }
        m.insert("ProviderIds".into(), Value::Object(p));
    }
    if rng.chance(40) {
        m.insert("SeriesName".into(), json!(rng.pick(NAMES)));
    }
    if rng.chance(40) {
        m.insert("SeriesId".into(), json!(rng.pick(IDS)));
    }
    if rng.chance(50) {
        m.insert("ProductionYear".into(), json!(rng.range(1900, 2030)));
    }
    if rng.chance(30) {
        m.insert("CollectionType".into(), json!(rng.pick(COLLECTION_TYPES)));
    }
    Value::Object(m)
}

fn items(rng: &mut Rng, max: u64) -> Vec<Value> {
    (0..rng.below(max)).map(|_| item(rng)).collect()
}

const JSON_TEXTS: &[&str] = &[
    "",
    "[]",
    "{}",
    "null",
    "[null]",
    "[{}]",
    "[{\"id\":\"a\"}]",
    "[{\"id\":\"a\",\"name\":\"A\",\"sammlung\":true}]",
    "[{\"id\":\"a\",\"name\":null}]",
    "[{\"id\":\"a\",\"name\":5}]",
    "[{\"id\":5}]",
    "[{\"id\":\"a\",\"sammlung\":\"yes\"}]",
    "[{\"id\":\"a\"},{\"id\":\"a\"}]",
    "[{\"id\":\"\"}]",
    "[{\"id\":\"a\",\"extra\":[1,2]}]",
    "[ {\"id\" : \"a\" } ]",
    "[{\"id\":\"a\",\"id\":\"b\"}]",
    "[{\"id\":\"é\",\"name\":\"x/y\"}]",
    "not json",
    "[{\"id\":\"a\"},",
    "\u{FEFF}[]",
    "[{\"id\":\"a\",\"sammlung\":null,\"name\":null}]",
    "[{\"id\":\"a\",\"sammlung\":1}]",
    "[\"a\"]",
    "[1]",
    "[[]]",
    "[{\"id\":\"\\u00e9\",\"name\":\"\\ud83d\\ude00\"}]",
    "[{\"id\":\"a\",\"name\":\"\\ud800\"}]",
    "[{\"id\":\"a\"}]x",
    "[{\"id\":\"a\"}] ",
    "[{\"id\":\"a\",\"name\":\"n\",\"sammlung\":false},{\"id\":\"b\",\"sammlung\":true},{\"id\":\"c\"}]",
    "[{\"id\":\"a\",\"sammlung\":true,\"sammlung\":false}]",
];

fn choice(rng: &mut Rng) -> Vec<Value> {
    (0..rng.below(6))
        .map(|_| json!({ "id": rng.pick(IDS), "name": rng.pick(NAMES), "collection": rng.chance(40) }))
        .collect()
}

pub fn start_libraries() -> Vec<Value> {
    let mut rng = Rng::new(0x534C_4942);
    let mut out = Vec::new();
    for t in JSON_TEXTS {
        out.push(json!({ "op": "read", "text": t }));
    }
    out.push(json!({ "op": "read", "text": null }));
    for _ in 0..600 {
        out.push(json!({ "op": "data", "choice": choice(&mut rng) }));
    }
    for ct in COLLECTION_TYPES {
        out.push(
            json!({ "op": "selectable", "item": { "Id": "x", "Name": "n", "CollectionType": ct } }),
        );
    }
    out.push(json!({ "op": "selectable", "item": { "Id": "x", "Name": "n" } }));
    for _ in 0..600 {
        out.push(json!({
            "op": "pick", "libraries": items(&mut rng, 6), "collections": items(&mut rng, 5),
            "selected": (0..rng.below(4)).map(|_| json!({ "id": rng.pick(IDS) })).collect::<Vec<_>>(),
        }));
    }
    out
}

const WORDS: &[&str] = &[
    "ab",
    "AB",
    "Ab",
    "a",
    "",
    " ",
    "  ab  ",
    "\tab\n",
    "ab\r\n",
    "a\r\nb",
    "straße",
    "STRASSE",
    "Strasse",
    "ß",
    "SS",
    "ǅ",
    "ǆ",
    "Ǆ",
    "İ",
    "i̇",
    "I",
    "ı",
    "é",
    "e\u{301}",
    "É",
    "E\u{301}",
    "ee",
    "😀",
    "😀😀",
    "a\u{200B}",
    "\u{200B}\u{200B}",
    "\u{00A0}ab\u{00A0}",
    "\u{2003}ab",
    "ab\u{FEFF}",
    "tatort münster",
    "Tatort Münster",
    "TATORT MÜNSTER",
    "a\nb",
    "a\u{2028}b",
    "x\u{0085}y",
    "Ｘ",
    "ｘ",
    "Σ",
    "σ",
    "ς",
    "ΑΣ",
    "ας",
    "ſ",
    "S",
    "ﬁ",
    "FI",
    "fi",
    "ǰ",
    "Ⅷ",
    "ⅷ",
    "a b",
    "A B",
    "\u{1F1E9}\u{1F1EA}",
    "🇩",
    "k",
    "K",
    "\u{212A}",
];
const ACCOUNTS: &[&str] = &["", "a", "id-1", "é", "a.b", "😀", " ", "x\ny"];

fn raw_history(rng: &mut Rng) -> String {
    let n = rng.below(11);
    let mut lines: Vec<String> = (0..n).map(|_| (*rng.pick(WORDS)).to_owned()).collect();
    if rng.chance(15) {
        lines.push(String::new());
    }
    let sep = if rng.chance(8) { "\r\n" } else { "\n" };
    let mut s = lines.join(sep);
    if rng.chance(10) {
        s.push('\n');
    }
    s
}

pub fn search_history() -> Vec<Value> {
    let mut rng = Rng::new(0x5348_4953);
    let mut out = Vec::new();
    for a in ACCOUNTS {
        out.push(json!({ "op": "key", "account": a }));
    }
    out.push(json!({ "op": "key", "account": null }));
    for _ in 0..300 {
        out.push(json!({ "op": "list", "raw": raw_history(&mut rng) }));
    }
    for w in WORDS {
        for _ in 0..12 {
            out.push(json!({ "op": "remember", "word": w, "raw": raw_history(&mut rng) }));
        }
    }
    for _ in 0..1500 {
        let raw = raw_history(&mut rng);
        // Mostly a word that is already in the history in another spelling.
        let word = match rng.below(3) {
            0 => rng.pick(WORDS).to_string(),
            1 => {
                let list: Vec<&str> = raw.split('\n').collect();
                let w = rng.pick(&list).to_string();
                if rng.chance(50) {
                    w.to_uppercase()
                } else {
                    w.to_lowercase()
                }
            }
            _ => format!("{}{}", rng.pick(WORDS), rng.pick(WORDS)),
        };
        out.push(json!({ "op": "remember", "word": word, "raw": raw }));
    }
    out
}

pub fn library_genre() -> Vec<Value> {
    let mut out: Vec<Value> = COLLECTION_TYPES
        .iter()
        .map(|c| json!({ "art": c }))
        .collect();
    out.push(json!({ "art": null }));
    for c in [
        "Movies",
        "TVSHOWS",
        "HomeVideos",
        "BOOKS",
        "tvshows ",
        " movies",
        "ſ",
        "MUSIC",
        "mUsIc",
        "K",
    ] {
        out.push(json!({ "art": c }));
    }
    out
}

const SORTINGS: &[&str] = &[
    "name",
    "neueste",
    "bewertung",
    "erscheinung",
    "",
    "Name",
    "latest",
    "rating",
    "neueste ",
];
const FILTERS: &[&str] = &[
    "alle",
    "angefangen",
    "merkliste",
    "ungesehen",
    "",
    "Alle",
    "all",
    "alle ",
];
const GENRES: &[&str] = &["alle", "filme", "serien", "", "Filme", "movies", "serien "];

pub fn library_filter() -> Vec<Value> {
    let mut rng = Rng::new(0x4C46_494C);
    let mut out = Vec::new();
    for s in SORTINGS {
        out.push(json!({ "op": "sorting", "raw": s }));
    }
    for f in FILTERS {
        out.push(json!({ "op": "filter", "raw": f }));
        out.push(json!({ "op": "kept", "raw": f, "filters": [] }));
    }
    for g in GENRES {
        out.push(json!({ "op": "remember", "raw": g }));
    }
    for c in COLLECTION_TYPES.iter().chain(&["movies", "tvshows"]) {
        out.push(json!({ "op": "toward", "art": c }));
    }
    out.push(json!({ "op": "toward", "art": null }));
    for _ in 0..800 {
        let list: Vec<&str> = (0..rng.below(6)).map(|_| *rng.pick(FILTERS)).collect();
        if rng.chance(50) {
            out.push(json!({ "op": "offered", "filters": list, "watchlist": rng.chance(50) }));
        } else {
            out.push(json!({ "op": "kept", "raw": rng.pick(FILTERS), "filters": list }));
        }
    }
    out
}

pub fn list_rules() -> Vec<Value> {
    let mut rng = Rng::new(0x4C52_554C);
    let mut out = Vec::new();
    for _ in 0..2500 {
        let list = items(&mut rng, 10);
        let more = items(&mut rng, 8);
        out.push(match rng.below(8) {
            0 => json!({ "op": "double", "items": list }),
            1 | 2 => json!({ "op": "title", "items": list, "show": rng.range(0, 12) }),
            3 => json!({ "op": "append", "items": list, "more": more }),
            4 => json!({
                "op": "refresh", "items": list, "more": more,
                "before": rng.range(0, 5), "now": if rng.chance(70) { rng.range(0, 5) } else { rng.range(-2, 300) },
            }),
            5 => json!({ "op": "rails", "items": list, "more": more }),
            6 => json!({
                "op": "post", "id": rng.pick(IDS), "items": list,
                "columns": match rng.below(5) { 0 => rng.range(-5, 1), 1 => rng.range(1, 60), _ => rng.range(1, 8) },
            }),
            _ => json!({ "op": "more", "loaded": rng.range(-3, 100), "total": rng.range(-3, 100) }),
        });
    }
    out
}

pub fn title_filter() -> Vec<Value> {
    let mut rng = Rng::new(0x5446_494C);
    let mut out = Vec::new();
    for _ in 0..2500 {
        let libs: Vec<Value> = (0..rng.below(4))
            .map(|n| json!({ "id": format!("lib{n}"), "items": items(&mut rng, 8) }))
            .collect();
        let pages: Vec<Vec<Value>> = (0..rng.below(4)).map(|_| items(&mut rng, 8)).collect();
        let front = if rng.chance(30) {
            json!(rng.range(0, 3))
        } else {
            Value::Null
        };
        out.push(json!({ "libs": libs, "pages": pages, "front_after": front }));
    }
    out
}

const ARTS: &[&str] = &[
    "Unknown",
    "Commercial",
    "Preview",
    "Recap",
    "Outro",
    "Intro",
];

fn spot(rng: &mut Rng, duration: f64) -> f64 {
    match rng.below(8) {
        0 => 0.0,
        1 => duration,
        2 => (rng.range(0, 4000) as f64) / 2.0,
        3 => rng.range(0, 400) as f64 / 10.0,
        4 => duration - rng.range(0, 40) as f64 / 4.0,
        5 => rng.range(-5, 6) as f64 * 1.5,
        _ => rng.unit() * duration.max(1.0),
    }
}

pub fn section_logic() -> Vec<Value> {
    let mut rng = Rng::new(0x5345_434C);
    let mut out = Vec::new();
    for _ in 0..5000 {
        let duration = match rng.below(6) {
            0 => 0.0,
            1 => -1.0,
            2 => 1e9,
            _ => rng.range(30, 7200) as f64 + if rng.chance(30) { 0.5 } else { 0.0 },
        };
        let sections: Vec<Value> = (0..rng.below(5))
            .map(|_| {
                let from = spot(&mut rng, duration);
                let until = match rng.below(4) {
                    0 => from + rng.range(0, 12) as f64 / 2.0,
                    1 => duration - rng.range(0, 6) as f64 / 2.0,
                    2 => from + rng.range(1, 600) as f64,
                    _ => spot(&mut rng, duration),
                };
                json!({ "art": rng.pick(ARTS), "from": from, "until": until })
            })
            .collect();
        let op = *rng.pick(&[
            "offering",
            "offering",
            "automatic",
            "card",
            "countdown",
            "countdown2",
        ]);
        let window = if rng.chance(50) {
            json!(rng.range(0, 90) as f64 / 2.0)
        } else {
            Value::Null
        };
        out.push(json!({
            "op": op, "position": spot(&mut rng, duration), "duration": duration, "sections": sections,
            "next": rng.chance(70), "window": window,
        }));
    }
    out
}
