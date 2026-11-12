//! Image keys and picks: `ImageAddress`, `ImageKey`, `ImageStoreKey`, `ImageSelection`.
//! Cases are described next to `Domain_Images.swift` (Tools/Oracle).
use crate::Rng;
use serde_json::{Value, json};

const BASES: &[&str] = &[
    "http://127.0.0.1:8096",
    "http://host",
    "https://jf.local.example",
    "http://host/sub/path",
    "http://host/sub/path/",
    "http://h:8920/jf",
    "http://[::1]:8096",
    "http://192.168.0.5:8096/",
    "https://h",
    "http://h/x",
    "https://h:8920",
    "http://h:1",
];
/// Addresses `Url` and Foundation's `URL` write differently (default port, host case, dot segments, empty host, bad escapes).
/// A server address is normalised by `ServerURL` first, so these only run as a pinned block at the start.
const BASES_HOSTILE: &[&str] = &[
    "http://host/",
    "https://h:443",
    "http://h:80",
    "http://user:pw@h",
    "HTTP://HOST.Example",
    "http://h//",
    "http://h/a%20b",
    "http://h/a b",
    "http://ä.de",
    "http://h?x=1",
    "http://h#f",
    "http://h/x?y#z",
    "",
    "not a url",
    "file:///tmp/x",
    "http://",
    "http://h/ü",
    "https://h/%2F",
    "http://h/./a/../b",
    "http://h:0",
    "ftp://h/x",
    "http://h/a;b",
    "http://h/a:b",
    "//h/x",
    "http://h/\u{1F600}",
];
const IDS: &[&str] = &[
    "abc",
    "0123456789abcdef0123456789abcdef",
    "",
    " ",
    "a/b",
    "a b",
    "ä",
    "a?b",
    "a#b",
    "%41",
    "a%",
    "😀",
    "a:b",
    "e\u{301}",
    "a+b",
    "a&b=c",
    "A\u{0}B",
    "a\tb",
    "a\nb",
    "[x]",
    "{x}",
    "a;b",
    "a,b",
    "a\"b",
    "a\\b",
    "a|b",
    "a^b",
    "a<b>",
    "a`b",
    "a@b",
    "a$b",
    "a(b)",
    "a*b",
    "a!b",
    "a~b",
    "a_b-c.d",
    "%2F",
    "%00",
];
/// Dot segments: `Url` collapses them, Foundation keeps them. Real ids are GUIDs or Plex numbers.
const IDS_HOSTILE: &[&str] = &[
    "a'b",
    "../x",
    "..",
    ".",
    "../../etc/passwd",
    "a/../b",
    "./x",
];
const MARKS: &[&str] = &[
    "t",
    "0123456789abcdef",
    "",
    " ",
    "a b",
    "a&b=c",
    "a=b",
    "a+b",
    "ä",
    "%41",
    "😀",
    "a#b",
    "a?b",
    "/library/metadata/1/thumb/123",
    "/library/metadata/5/art/9",
    "/a b/c",
    "http://img.example/x.jpg",
    "https://img.example/y?z=1",
    "HTTP://x",
    "a;b",
    "a/b",
    "a%",
    "TAG",
    "[x]",
    "a\u{0}b",
];
/// Plex paths that are only the scheme: Foundation accepts `http://` as an address, `Url` does not.
const MARKS_HOSTILE: &[&str] = &["http://", "https://", "http:// bad"];
const TOKENS: &[&str] = &[
    "t", "tok-1234", "", " ", "a b", "tök", "a&b=c", "+", "%41", "a/b", "a#b", "😀", "ApiKey=x",
    "a:b",
];

fn pick_opt(rng: &mut Rng, list: &[&str], none_percent: u64) -> Value {
    if rng.chance(none_percent) {
        Value::Null
    } else {
        json!(rng.pick(list))
    }
}

fn number(rng: &mut Rng) -> i64 {
    match rng.below(10) {
        0 => 0,
        1 => -1,
        2 => i64::MAX,
        3 => i64::MIN,
        4 => 4096,
        5 => rng.range(1, 100_000),
        6 => rng.range(-1000, 0),
        _ => *rng.pick(&[1, 40, 120, 240, 300, 480, 600, 1200, 1920]),
    }
}

fn mass(rng: &mut Rng) -> Value {
    match rng.below(3) {
        0 => json!(["high", number(rng)]),
        1 => json!(["wide", number(rng)]),
        _ => json!(["fill", number(rng), number(rng)]),
    }
}

fn kind(rng: &mut Rng) -> &'static str {
    ["jellyfin", "emby", "plex"][rng.below(3) as usize]
}

fn address_case(rng: &mut Rng, base: &str, id: &str, hostile_mark: bool) -> Value {
    let art = *rng.pick(&["poster", "background", "preview", "logo"]);
    let index = if rng.chance(25) {
        json!(number(rng))
    } else {
        Value::Null
    };
    let op = if rng.chance(15) { "user" } else { "construct" };
    json!({
        "base": base, "token": pick_opt(rng, TOKENS, 30), "kind": kind(rng), "op": op,
        "id": id, "art": art, "mark": if hostile_mark { json!(rng.pick(MARKS_HOSTILE)) } else { pick_opt(rng, MARKS, 25) },
        "mass": mass(rng), "index": index, "q": if rng.chance(70) { json!(90) } else { json!(number(rng)) }, "border": number(rng),
    })
}

/// Cases `0..HOSTILE_ADDRESS` use addresses/ids that `Url` writes differently from `URL` (pinned in `known.json`).
pub const HOSTILE_ADDRESS: usize = 400;

pub fn image_address() -> Vec<Value> {
    let mut rng = Rng::new(0x494D_4144);
    let mut out = Vec::new();
    for i in 0..HOSTILE_ADDRESS {
        let (base, id) = if i % 2 == 0 {
            (*rng.pick(BASES_HOSTILE), *rng.pick(IDS))
        } else {
            (*rng.pick(BASES), *rng.pick(IDS_HOSTILE))
        };
        out.push(address_case(&mut rng, base, id, i % 7 == 0));
    }
    for _ in 0..4000 {
        let (base, id) = (*rng.pick(BASES), *rng.pick(IDS));
        out.push(address_case(&mut rng, base, id, false));
    }
    out
}

fn url_text(rng: &mut Rng, hostile: bool) -> String {
    let (scheme, host, path): (&str, &str, &str) = if hostile {
        (
            *rng.pick(&["http", "https", "HTTP", "ftp", "file"]),
            *rng.pick(&[
                "h",
                "127.0.0.1:8096",
                "H.Example:443",
                "[::1]:80",
                "user:pw@h",
                "ä.de",
                "h:0",
                "h.",
                "",
            ]),
            *rng.pick(&[
                "/Items/a/Images/Primary",
                "/Items/ä/Images/Primary",
                "/",
                "",
                "/a/../b",
                "/a//b",
                "/a b",
                "/%",
            ]),
        )
    } else {
        (
            *rng.pick(&["http", "https"]),
            *rng.pick(&[
                "h",
                "127.0.0.1:8096",
                "jf.local.example",
                "[::1]:8096",
                "h:8920",
            ]),
            *rng.pick(&[
                "/Items/a/Images/Primary",
                "/Items/a%20b/Images/Primary",
                "/Items/%C3%A4/Images/Primary",
                "/",
                "/a//b",
                "/a%2Fb",
                "/Items/x/Images/Backdrop/3",
                "/a;b",
            ]),
        )
    };
    let query_parts = [
        "tag=t1",
        "tag=",
        "tag",
        "Tag=x",
        "TAG=x",
        "%74ag=x",
        "t%61g=x",
        "ta%67=x",
        "TA%47=y",
        "tag%3D=x",
        "maxHeight=300",
        "maxWidth=1200",
        "quality=90",
        "ApiKey=secret",
        "api_key=secret",
        "X-Plex-Token=abc",
        "apikey=low",
        "ApiKey",
        "ApiKey=",
        "&",
        "a=b",
        "a=b=c",
        "x=%zz",
        "x=%",
        "x=ä",
        "x=a+b",
        "x=a%20b",
        "tag=a%26b",
        "tag=%",
        "%",
        "=",
        "tag=t=u",
        "ApiKey=a&b",
        "api_key=a%20b",
        "tag=%E4",
    ];
    let canonical = [
        "tag=t1",
        "tag=",
        "tag",
        "Tag=x",
        "TAG=x",
        "maxHeight=300",
        "maxWidth=1200",
        "quality=90",
        "ApiKey=secret",
        "api_key=secret",
        "X-Plex-Token=abc",
        "apikey=low",
        "ApiKey",
        "ApiKey=",
        "a=b",
        "x=a+b",
        "x=a%20b",
        "tag=a%26b",
        "api_key=a%20b",
        "x=%C3%A4",
        "fillWidth=300&fillHeight=200",
    ];
    let query_parts: &[&str] = if hostile { &query_parts } else { &canonical };
    let n = rng.below(5) as usize;
    let mut query = String::new();
    for i in 0..n {
        query.push(if i == 0 { '?' } else { '&' });
        query.push_str(rng.pick(query_parts));
    }
    let frag = *rng.pick(if hostile {
        &["", "", "", "#f", "#", "#a b", "#ä"]
    } else {
        &["", "", "", "#f", "", "#x", "", ""]
    });
    format!("{scheme}://{host}{path}{query}{frag}")
}

/// Cases `0..HOSTILE_STORE + fixed.len()` are the pinned block (hostile spellings).
pub const HOSTILE_STORE: usize = 500;

pub fn image_store_key() -> Vec<Value> {
    let mut rng = Rng::new(0x494D_534B);
    let fixed = [
        "",
        "not a url",
        "http://h/i?tag=t",
        "http://h/i?ApiKey=k",
        "http://h/i?tag=t&ApiKey=k",
        "http://h/i?ApiKey=k&tag=t",
        "http://h/i?tag=t&ApiKey=k&quality=90",
        "http://h/i?",
        "http://h/i?#f",
        "http://h/i?tag=t#f",
        "http://h:99/i?tag=t",
        "/relative/Items?tag=t",
        "http://h/i?tag=%E4",
        "http://h/i?tag=\u{e4}",
        "http://h/\u{e4}?tag=t",
        "http://h/i?a=%zz&tag=t",
        "http://h/i?tag=t&api_key=%zz",
        "mailto:a@b",
        "http://h/i?tag=t&X-Plex-Token=",
        "http://h/i?\u{1F600}=1&tag=t",
    ];
    let mut out: Vec<Value> = fixed.iter().map(|u| json!({ "url": u })).collect();
    for _ in 0..HOSTILE_STORE {
        out.push(json!({ "url": url_text(&mut rng, true) }));
    }
    for _ in 0..4000 {
        out.push(json!({ "url": url_text(&mut rng, false) }));
    }
    out
}

fn tags(rng: &mut Rng) -> Value {
    match rng.below(5) {
        0 => Value::Null,
        1 => json!([]),
        2 => json!([rng.pick(MARKS)]),
        3 => json!([rng.pick(MARKS), "second"]),
        _ => json!(["", "x"]),
    }
}

fn maybe(rng: &mut Rng, list: &[&str]) -> Value {
    if rng.chance(50) {
        Value::Null
    } else {
        json!(rng.pick(list))
    }
}

fn item(rng: &mut Rng) -> Value {
    let mut o = serde_json::Map::new();
    o.insert("Id".into(), json!(rng.pick(IDS)));
    o.insert("Name".into(), json!("n"));
    let kinds = ["Movie", "Series", "Episode", "Season", "Folder", "Audio"];
    if rng.chance(85) {
        o.insert("Type".into(), json!(rng.pick(&kinds)));
    }
    if rng.chance(50) {
        o.insert("SeriesId".into(), json!(rng.pick(IDS)));
    }
    for name in [
        "SeriesPrimaryImageTag",
        "ParentThumbImageTag",
        "ParentLogoImageTag",
    ] {
        if rng.chance(40) {
            o.insert(name.into(), json!(rng.pick(MARKS)));
        }
    }
    for name in ["ParentBackdropItemId", "ParentThumbItemId"] {
        if rng.chance(30) {
            o.insert(name.into(), maybe(rng, IDS));
        }
    }
    for name in ["BackdropImageTags", "ParentBackdropImageTags"] {
        let t = tags(rng);
        if !t.is_null() {
            o.insert(name.into(), t);
        }
    }
    if rng.chance(70) {
        let mut m = serde_json::Map::new();
        for key in ["Primary", "Thumb", "Logo", "Backdrop"] {
            if rng.chance(45) {
                m.insert(key.into(), json!(rng.pick(MARKS)));
            }
        }
        o.insert("ImageTags".into(), Value::Object(m));
    }
    Value::Object(o)
}

pub fn image_selection() -> Vec<Value> {
    let mut rng = Rng::new(0x494D_5345);
    let mut out = Vec::new();
    for _ in 0..4000 {
        let op = *rng.pick(&["landscape", "header", "header_fb", "logo", "portrait"]);
        let episode = if op == "header_fb" && rng.chance(80) {
            item(&mut rng)
        } else {
            Value::Null
        };
        let it = if rng.chance(2) {
            json!({ "Name": "no id" })
        } else {
            item(&mut rng)
        };
        out.push(json!({
            "base": rng.pick(BASES), "token": pick_opt(&mut rng, TOKENS, 30), "kind": kind(&mut rng), "op": op,
            "item": it, "episode": episode, "width": *rng.pick(&[600, 1200, 480, 240, 0, -5, 1, 4096, 1000]),
        }));
    }
    out
}
