//! Address rules: AppModelURLNormalizer (ServerURL.swift), `URL.withoutSecret` / `ImageKey`
//! (AddressSecret.swift), OwnHeaders (OwnHeaders.swift), ServerDiscovery parsing. Hostile strings:
//! IPv6, ports, paths, trailing slashes and backslashes, unicode hosts, credentials, schemes, whitespace.
use crate::Rng;
use serde_json::{Value, json};

const HOSTS: &[&str] = &[
    "tv.example.de",
    "Jellyfin.Example.COM",
    "192.168.1.5",
    "10.0.0.1",
    "127.0.0.1",
    "localhost",
    "LOCALHOST",
    "kiste.local",
    "nas.lan",
    "box.home",
    "srv.internal",
    "server",
    "nas",
    "a.b",
    "a.b.c.d",
    "1.2.3.4",
    "256.1.1.1",
    "1.2.3",
    "1.2.3.4.5",
    "01.02.03.04",
    "0x7f.0.0.1",
    "[fd00::5]",
    "[::1]",
    "fd00::5",
    "::1",
    "fe80::1%en0",
    "[fe80::1%25en0]",
    "::ffff:1.2.3.4",
    "[::ffff:1.2.3.4]",
    "2001:db8::ff00:42:8329",
    "bücher.de",
    "münchen.example",
    "日本語.jp",
    "xn--bcher-kva.de",
    "example.com.",
    ".example.com",
    "-bad.com",
    "under_score.com",
    "a..b",
    "ex ample.com",
    "exa mple",
    "jf.local.example",
    "100.110.192.87",
    "٣.٣.٣.٣",
    "１.２.３.４",
    "1.2.3.4.",
    "tv.example.de:",
    "[",
    "]",
    "[]",
    "[fd00::5",
    "fd00::5]",
    "::",
    ":::",
    "1:2",
    "abc:def",
    "Ｅxample.com",
    "example。com",
    "ex\u{00AD}ample.com",
    "ex\u{200B}ample.com",
    "\u{00A0}tv.example.de",
    "tv.example.de\u{00A0}",
    "tv.example.de%20",
    "tv%2eexample.de",
    "xn--",
    "localhost.",
    "foo.local.",
    "a.local",
    ".local",
    "local",
    "x.lan.com",
];
const PORTS: &[&str] = &[
    "",
    "",
    "",
    ":8096",
    ":80",
    ":443",
    ":8920",
    ":0",
    ":65535",
    ":65536",
    ":99999",
    ":",
    ":abc",
    ":-1",
    ":+80",
    ":080",
    ":8096:",
    ":８０９６",
    ":8096 ",
    ":1e3",
    ":0x50",
    ":１２",
];
const PATHS: &[&str] = &[
    "",
    "",
    "",
    "/",
    "//",
    "/jellyfin",
    "/jellyfin/",
    "/jellyfin//",
    "/a/b/c",
    "/a/../b",
    "/..",
    "/a/./b",
    "/a b",
    "/ä",
    "/%41",
    "/%zz",
    "/%",
    "\\",
    "\\jellyfin",
    "/jellyfin\\",
    "/a\\b",
    "/jelly fin/",
    "?x=1",
    "/?x=1",
    "#frag",
    "/#frag",
    "/p?q=a b",
    "/p?q=ä",
    "/p?q=%zz",
    "/p#a#b",
    "/p?a?b",
    "/Videos/abc/stream?static=true&api_key=GEHEIM",
    "/\u{00A0}",
    "/\u{200B}",
    "/日本",
    "/a;b",
    "/a;b=c",
    "/:",
    "/@",
    "/a@b",
];
const SCHEMES: &[&str] = &[
    "",
    "",
    "",
    "http://",
    "https://",
    "HTTP://",
    "HtTpS://",
    "ftp://",
    "file://",
    "ws://",
    "wss://",
    "//",
    "://",
    "http:/",
    "http:///",
    "https:\\\\",
    "http//",
    "javascript://",
    "data://",
    "x://",
    "h ttp://",
    "1http://",
    "+http://",
    "http+x://",
    "mailto:",
    "view-source:http://",
    "http://http://",
];
const CREDS: &[&str] = &[
    "",
    "",
    "",
    "",
    "",
    "user@",
    "user:pw@",
    "user:@",
    ":pw@",
    "@",
    "a@b@",
    "us er:pw@",
    "ü:ä@",
    "user:p%40w@",
    "u:p:w@",
    "[fd00::5]@",
];
const WS: &[&str] = &[
    "", "", "", "", "", " ", "  ", "\t", "\n", "\r\n", "\u{00A0}", "\u{3000}", "\u{200B}",
    "\u{FEFF}", "\u{2028}", "\u{0085}", "\u{000B}", "\u{001F}", "\u{0000}",
];
const TAILS: &[&str] = &["", "", "", "", "/", "//", "///", "\\", " /", "/ "];

/// One hostile address string.
fn address(rng: &mut Rng) -> String {
    let scheme = *rng.pick(SCHEMES);
    let creds = if scheme.is_empty() && rng.chance(80) {
        ""
    } else {
        *rng.pick(CREDS)
    };
    let host = *rng.pick(HOSTS);
    let port = *rng.pick(PORTS);
    let path = *rng.pick(PATHS);
    let tail = *rng.pick(TAILS);
    let lead = *rng.pick(WS);
    let trail = *rng.pick(WS);
    format!("{lead}{scheme}{creds}{host}{port}{path}{tail}{trail}")
}

fn pick_url(rng: &mut Rng) -> String {
    // A mostly well-formed absolute URL with hostile parts.
    let scheme = *rng.pick(&[
        "http://", "https://", "http://", "https://", "ws://", "wss://", "ftp://", "",
    ]);
    let creds = if rng.chance(85) { "" } else { *rng.pick(CREDS) };
    let host = *rng.pick(HOSTS);
    let port = if rng.chance(60) { "" } else { *rng.pick(PORTS) };
    let path = *rng.pick(PATHS);
    format!("{scheme}{creds}{host}{port}{path}")
}

pub fn server_url() -> Vec<Value> {
    let mut rng = Rng::new(0x5E21_0001);
    let mut cases: Vec<Value> = Vec::new();
    for raw in [
        "",
        " ",
        "tv.example.de",
        "192.168.1.5:8096",
        "kiste.local:8096",
        "[fd00::5]:8096",
        "fd00::5",
        "fe80::1%en0",
        "http://",
        "https://x",
        "HTTP://X.DE/",
    ] {
        cases.push(json!({ "raw": raw }));
    }
    while cases.len() < 4000 {
        cases.push(json!({ "raw": address(&mut rng) }));
    }
    cases
}

pub fn server_relative() -> Vec<Value> {
    let mut rng = Rng::new(0x5E21_0002);
    let details: &[&str] = &[
        "/videos/abc/master.m3u8?x=1",
        "videos/abc/master.m3u8",
        "/Videos/1/Subtitles/2/0/Stream.vtt",
        "https://other.de/sub.srt",
        "http://x.de",
        "//cdn.de/x",
        "",
        "/",
        "?q=1",
        "#f",
        "/a b/c",
        "/ä/ö",
        "/a%20b",
        "/a?b=c d",
        "/a?b=ä",
        "/a#frag",
        "/a?b#frag",
        "x:y",
        "mailto:a@b",
        "C:\\x",
        "/a\\b",
        "\\a",
        "/../x",
        "/a/../b",
        "//",
        "///x",
        "/a?",
        "/a??b",
        "/?",
        " /x",
        "/x ",
        "/\u{00A0}x",
        "ws://a/b",
        "1x:/a",
        "a+b:/c",
        "-a:/c",
        "/Videos/%zz",
        "/%",
        "/a;b",
        "/a:b",
        "a:b/c",
        "./x",
        "../x",
    ];
    let bases: &[&str] = &[
        "https://h.de",
        "https://h.de/",
        "https://h.de/jellyfin",
        "https://h.de/jellyfin/",
        "https://h.de//jellyfin//",
        "http://192.168.1.5:8096",
        "https://h.de:8920/a/b",
        "https://h.de/a b",
        "https://h.de/ä",
        "https://h.de/a%20b",
        "https://h.de/a?x=1",
        "https://h.de/a#f",
        "https://user:pw@h.de/a",
        "https://[fd00::5]:8096/jf",
        "https://h.de/a;b",
        "HTTPS://H.DE/Jf",
        "https://h.de/%zz",
        "ws://h.de/x",
    ];
    let mut cases: Vec<Value> = Vec::new();
    for d in details {
        for b in bases {
            cases.push(json!({ "detail": d, "base": b }));
        }
    }
    while cases.len() < 3000 {
        let base = pick_url(&mut rng);
        let detail = if rng.chance(50) {
            format!("{}{}", rng.pick(&["/", "", "//"]), rng.pick(PATHS))
        } else {
            pick_url(&mut rng)
        };
        cases.push(json!({ "detail": detail, "base": base }));
    }
    cases
}

const SECRET_NAMES: &[&str] = &[
    "api_key",
    "ApiKey",
    "X-Emby-Token",
    "X-Plex-Token",
    "token",
    "secret",
    "Secret",
    "pw",
    "Pw",
    "password",
    "apikey",
    "API_KEY",
    "Token",
    "static",
    "mediaSourceId",
    "tag",
    "",
    "a b",
    "ä",
    "%61pi_key",
];
const SECRET_VALUES: &[&str] = &[
    "GEHEIM123",
    "",
    "a b",
    "ä",
    "%41",
    "%zz",
    "1",
    "a=b",
    "a+b",
    "a%26b",
    "…",
    "x;y",
    "a?b",
    "a/b",
    "日本",
];

pub fn address_secret() -> Vec<Value> {
    let mut rng = Rng::new(0x5E21_0003);
    let mut cases: Vec<Value> = vec![
        json!({"url": "https://tv.example.de/Videos/abc/stream?static=true&api_key=GEHEIM123&mediaSourceId=xy"}),
        json!({"url": "https://tv.example.de/QuickConnect/Connect?secret=ABC"}),
        json!({"url": "https://tv.example.de/System/Info/Public"}),
    ];
    while cases.len() < 4000 {
        let mut url = pick_url(&mut rng);
        if let Some(i) = url.find(['?', '#']) {
            url.truncate(i);
        }
        let n = rng.below(5);
        let mut sep = '?';
        for _ in 0..n {
            let name = rng.pick(SECRET_NAMES);
            let item = if rng.chance(85) {
                format!("{name}={}", rng.pick(SECRET_VALUES))
            } else {
                (*name).to_string()
            };
            url.push(sep);
            url.push_str(&item);
            sep = '&';
            if rng.chance(5) {
                url.push('&');
            }
        }
        if rng.chance(10) {
            url.push('#');
            url.push_str(rng.pick(&["f", "", "a=b", "api_key=x"]));
        }
        cases.push(json!({ "url": url }));
    }
    cases
}

const HEADER_NAMES: &[&str] = &[
    "CF-Access-Client-Id",
    "cf-access-client-id",
    "CF-Access-Client-Secret",
    "X-Api-Key",
    "Authorization",
    "authorization",
    "X-Emby-Authorization",
    "X-Emby-Token",
    "X-MediaBrowser-Token",
    "Cookie",
    "COOKIE",
    "Accept",
    "Content-Type",
    "Content-Length",
    "Host",
    "Connection",
    "Transfer-Encoding",
    "Proxy-Authorization",
    "Upgrade",
    "",
    " ",
    " X-Pad ",
    "\tX-Tab\n",
    "X Space",
    "X:Colon",
    "X_Under",
    "X.Dot",
    "X~Tilde",
    "X|Pipe",
    "X`Tick",
    "X'Quote",
    "X\"DQuote",
    "X(Paren)",
    "Ünicode",
    "日本",
    "X-ﬁ",
    "X-\u{00A0}Nbsp",
    "\u{00A0}X-Lead",
    "X\u{200B}",
    "０１",
    "٣",
    "X-Ａ",
    "Ａuthorization",
    "K",
    "x-b",
    "X-B",
    "x-ß",
    "X-İ",
    "ı",
];
const HEADER_VALUES: &[&str] = &[
    "secret",
    "  padded  ",
    "",
    " ",
    "\t",
    "a\nb",
    "a\rb",
    "a\u{0000}b",
    "a\u{001F}b",
    "a\u{007F}b",
    "a\u{0080}b",
    "a\u{00A0}b",
    "\u{00A0}",
    "\u{200B}",
    "\u{3000}x\u{3000}",
    "日本",
    "a:b",
    "Bearer x",
    "\nx",
    "x\n",
    "\r\nx",
    "a b",
    "ü",
    "\u{FEFF}x",
    "\u{2028}x",
    "\u{0085}x",
    "\u{000B}x",
];

fn header(rng: &mut Rng) -> Value {
    json!({ "name": *rng.pick(HEADER_NAMES), "value": *rng.pick(HEADER_VALUES) })
}

pub fn own_headers_clean() -> Vec<Value> {
    let mut rng = Rng::new(0x5E21_0004);
    let mut cases: Vec<Value> = Vec::new();
    for n in HEADER_NAMES {
        cases.push(json!({ "headers": [{ "name": n, "value": "v" }] }));
    }
    while cases.len() < 3000 {
        let n = rng.below(6);
        let headers: Vec<Value> = (0..n).map(|_| header(&mut rng)).collect();
        cases.push(json!({ "headers": headers }));
    }
    cases
}

pub fn own_headers_table() -> Vec<Value> {
    let mut rng = Rng::new(0x5E21_0005);
    let bases: &[&str] = &[
        "https://h.de",
        "https://h.de/",
        "https://h.de/jellyfin",
        "https://h.de/jellyfin/",
        "https://h.de/seerr",
        "http://h.de",
        "https://h.de:443",
        "https://h.de:8920",
        "http://192.168.1.5:8096",
        "https://H.DE/Jellyfin",
        "wss://h.de/jellyfin",
        "ws://h.de",
        "https://h.de/a/b",
        "https://h.de/a",
        "https://h.de//a",
        "https://h.de/a%20b",
        "https://h.de/a b",
        "https://h.de/..",
        "https://h.de/a/../b",
        "https://[fd00::5]:8096",
        "ftp://h.de",
        "file:///x",
        "https://user:pw@h.de/u",
        "https://h.de/ä",
        "https://日本.jp",
        "https://h.de/a?x=1",
        "https://h.de/a#f",
    ];
    let queries: &[&str] = &[
        "https://h.de/Items/1/Images/Primary",
        "https://h.de/jellyfin/System/Info",
        "https://h.de/jellyfin",
        "https://h.de/jellyfin/",
        "https://h.de/jellyfinx",
        "https://h.de/jellyfin2/a",
        "https://h.de/seerr/api/v1",
        "wss://h.de/jellyfin/socket",
        "http://h.de/jellyfin/a",
        "https://h.de:443/jellyfin/a",
        "https://h.de:8920/x",
        "https://other.de/x",
        "http://192.168.1.5:8096/Videos/1",
        "https://h.de/a/b/c",
        "https://h.de/a/x",
        "https://h.de/a/../b",
        "https://h.de/a/b/../c",
        "https://h.de//a/b",
        "https://h.de/a%20b/c",
        "https://h.de/a b/c",
        "https://[fd00::5]:8096/x",
        "ftp://h.de/x",
        "https://h.de/ä/x",
        "https://H.DE/JELLYFIN/x",
        "https://h.de/jellyfin/?x=1",
        "https://h.de/a#f",
        "https://h.de/a/%2e%2e/b",
        "https://h.de/a/./b",
        "https://xn--n3h.de/",
        "https://日本.jp/x",
        "https://user:pw@h.de/u/x",
    ];
    let mut cases: Vec<Value> = Vec::new();
    while cases.len() < 3000 {
        let ne = rng.below(5);
        let entries: Vec<Value> = (0..ne)
            .map(|_| {
                let nh = rng.below(3);
                let headers: Vec<Value> = (0..nh)
                    .map(|_| json!({ "name": *rng.pick(&["X-A", "X-B", "CF-Access-Client-Id", "Cookie", "x-a", "X C", ""]), "value": *rng.pick(&["1", "2", " 3 ", "", "a\nb"]) }))
                    .collect();
                json!({ "base": *rng.pick(bases), "headers": headers })
            })
            .collect();
        let nq = 1 + rng.below(6);
        let asked: Vec<Value> = (0..nq).map(|_| json!(*rng.pick(queries))).collect();
        cases.push(json!({ "entries": entries, "queries": asked }));
    }
    cases
}

pub fn server_discovery() -> Vec<Value> {
    let mut rng = Rng::new(0x5E21_0006);
    let ids: &[&str] = &[
        "a1",
        "b2",
        "c3",
        "",
        "A1",
        "ä",
        "id with space",
        "1",
        "10",
        "2",
    ];
    let names: &[&str] = &[
        "Wohnzimmer",
        "kiste",
        "Kiste",
        "KISTE",
        "ärger",
        "Zebra",
        "alpha",
        "Alpha",
        "",
        "a1",
        "a 1",
        "a10",
        "a2",
        "Ä",
        "ae",
        "日本",
        "\u{00A0}x",
        "e\u{0301}",
        "é",
        "File 2",
        "file 10",
    ];
    let addrs: &[&str] = &[
        "http://192.168.1.5:8096",
        "http://192.168.1.5:8096/",
        "192.168.1.5:8096",
        "HTTP://192.168.1.5:8096//",
        "https://tv.example.de",
        "https://TV.example.de:443/",
        "https://tv.example.de:8920",
        "http://tv.example.de:80",
        "http://tv.example.de",
        "",
        "   ",
        "http://",
        "not a url",
        "http://[fd00::5]:8096/",
        "ftp://x.de",
        "HtTp://X.de/",
        "https://x.de//",
        "\u{00A0}http://x.de",
        "http://user:pw@x.de/",
        "http://x.de/jellyfin/",
        "https://xn--n3h.de",
    ];
    let server = |rng: &mut Rng| json!({ "id": *rng.pick(ids), "name": *rng.pick(names), "address": *rng.pick(addrs) });
    let mut cases: Vec<Value> = Vec::new();
    while cases.len() < 4000 {
        match rng.below(4) {
            0 => {
                // read: the raw bytes of one answer (JSON text, sometimes damaged).
                let text = match rng.below(8) {
                    0 => "not json".to_string(),
                    1 => "{}".to_string(),
                    2 => format!("{{\"Id\":\"{}\",\"Name\":\"n\"}}", rng.pick(ids)),
                    3 => format!(
                        "{{\"Id\":1,\"Name\":\"n\",\"Address\":\"{}\"}}",
                        rng.pick(addrs)
                    ),
                    4 => format!(
                        "{{\"Id\":\"{}\",\"Name\":null,\"Address\":\"{}\"}}",
                        rng.pick(ids),
                        rng.pick(addrs)
                    ),
                    _ => format!(
                        "{{\"Id\":\"{}\",\"Name\":\"{}\",\"Address\":\"{}\",\"EndpointAddress\":null}}",
                        rng.pick(ids),
                        rng.pick(names),
                        rng.pick(addrs)
                    ),
                };
                cases.push(json!({ "kind": "read", "text": text }));
            }
            1 => cases.push(json!({ "kind": "short", "server": server(&mut rng) })),
            2 => {
                let k = rng.below(5);
                let known: Vec<Value> = (0..k).map(|_| server(&mut rng)).collect();
                let n = rng.below(5);
                let new: Vec<Value> = (0..n).map(|_| server(&mut rng)).collect();
                // The language of the device decides the order; no random draw, so the other cases keep their numbers.
                let locale = ["de", "en", "ru"][cases.len() % 3];
                cases.push(
                    json!({ "kind": "merged", "locale": locale, "known": known, "new": new }),
                );
            }
            _ => {
                let k = rng.below(6);
                let found: Vec<Value> = (0..k).map(|_| server(&mut rng)).collect();
                let m = rng.below(4);
                let except: Vec<Value> = (0..m)
                    .map(|_| {
                        if rng.chance(25) {
                            Value::Null
                        } else {
                            json!(*rng.pick(addrs))
                        }
                    })
                    .collect();
                cases.push(json!({ "kind": "shown", "found": found, "except": except }));
            }
        }
    }
    cases
}
