//! Login, Quick Connect and accounts (`Login.swift`, `QuickConnect.swift`, `QuickConnectWait.swift`,
//! `ErrorText.swift`, `AccountBundle.swift`, `ServerBundles.swift`, `AddressCheck.swift`, `Models.swift`
//! `looksLikeJellyfin`, `EmbyPaths.swift`). Cases are read by `Domain_Login.swift` (Tools/Oracle) and
//! `tests/oracle_login.rs`.
use crate::Rng;
use serde_json::{Value, json};

const CODES: [i64; 28] = [
    -999, -1000, -1001, -1002, -1003, -1004, -1005, -1006, -1007, -1008, -1009, -1011, -1012,
    -1013, -1017, -1100, -1200, -1201, -1202, -1203, -1204, -1205, -1206, -1, 0, 1, 200, 404,
];
const TLS_TEXTS: [&str; 22] = [
    "",
    "SSL certificate problem: self signed certificate",
    "SSL certificate problem: certificate has expired",
    "SSL: no alternative certificate subject name matches target hostname",
    "SSL certificate problem: self signed certificate in certificate chain",
    "SSL certificate problem: certificate is not yet valid",
    "SSL certificate problem: unable to get local issuer certificate",
    "SSL certificate problem: unable to get issuer certificate",
    "TLS handshake failed",
    "SSL peer certificate or SSH remote key was not OK",
    "certificate verify failed",
    "The certificate for this server is invalid.",
    "Recv failure: Connection reset by peer",
    "The request timed out.",
    "expired",
    "EXPIRED CERTIFICATE",
    "Hostname mismatch",
    "ssl",
    "The operation couldn't be completed. (NSURLErrorDomain error -1.)",
    "TLS: certificate NOT TRUSTED",
    "certificate has not yet valid expired",
    "İSSL Certificate Expired",
];
const TEXTS: [&str; 10] = [
    "",
    "Der Code ist zu kurz.",
    "x",
    "Keine Verbindung.",
    "ünï 👨‍👩‍👧",
    "multi\nline",
    "  ",
    "Der Server hat Quick Connect abgeschaltet.",
    "%lld",
    "100%",
];
const REASONS: [&str; 6] = [
    "NotAllowed",
    "RateLimitExceeded",
    "NoCompatibleStream",
    "",
    "notallowed",
    "other",
];

fn error_case(rng: &mut Rng) -> Value {
    match rng.below(14) {
        0 => json!({ "t": "network", "code": *rng.pick(&CODES) }),
        1 => {
            json!({ "t": "certificate", "reason": *rng.pick(&["not_trusted", "expired", "not_yet", "other_address", "otherwise"]) })
        }
        2 => json!({ "t": "transport", "text": *rng.pick(&TEXTS) }),
        3 => {
            json!({ "t": "transport_special", "which": *rng.pick(&["no_http", "login_page", "qc_disabled", "refresh", "silent"]) })
        }
        4 => json!({ "t": "not_auth" }),
        5 => json!({ "t": "two_factor" }),
        6 => json!({ "t": "invalid_url" }),
        7 => {
            json!({ "t": "http", "status": rng.range(0, 700), "body": if rng.chance(50) { Value::Null } else { json!("body") } })
        }
        8 => json!({ "t": "decoding", "text": *rng.pick(&TEXTS) }),
        9 => json!({ "t": "no_source" }),
        10 => json!({ "t": "rejected", "reason": *rng.pick(&REASONS) }),
        _ => json!({ "t": "url", "code": *rng.pick(&CODES), "desc": *rng.pick(&TLS_TEXTS) }),
    }
}

pub fn login_error() -> Vec<Value> {
    let mut rng = Rng::new(0x4c4f_4745);
    let mut out = vec![json!({ "op": "lang" })];
    // Every code against every description, every status, every special.
    for code in CODES {
        for d in TLS_TEXTS {
            out.push(json!({ "e": { "t": "url", "code": code, "desc": d } }));
        }
        out.push(json!({ "e": { "t": "network", "code": code } }));
    }
    for status in 0..=650 {
        out.push(json!({ "e": { "t": "http", "status": status, "body": null } }));
    }
    for status in [65_535, 1000, 999, 700] {
        out.push(json!({ "e": { "t": "http", "status": status, "body": "x" } }));
    }
    for _ in 0..4000 {
        out.push(json!({ "e": error_case(&mut rng) }));
    }
    out
}

pub fn login_quick() -> Vec<Value> {
    let mut rng = Rng::new(0x5155_4943);
    let states = ["opened", "released", "expired", "failed"];
    let mut out = vec![json!({ "op": "consts" }), json!({ "op": "expired_text" })];
    for expired in [true, false] {
        out.push(json!({ "op": "from_error", "expired": expired }));
    }
    for s in states {
        out.push(json!({ "op": "ended", "state": s }));
        out.push(json!({ "op": "end_text", "state": s }));
    }
    for ms in -3000..=3000 {
        out.push(json!({ "op": "remaining", "ms": ms }));
    }
    for _ in 0..3000 {
        let ms = match rng.below(4) {
            0 => rng.range(-1_000_000, 1_000_000),
            1 => rng.range(0, 400_000) / 1000 * 1000 + rng.range(-1, 2),
            2 => rng.range(299_000, 301_000),
            _ => rng.range(-10_000_000_000, 10_000_000_000),
        };
        out.push(json!({ "op": "remaining", "ms": ms }));
    }
    // Wait outcomes: the real flow runs on the clock (0.5 s deadline, ask every 0.1 s), so only scripts whose
    // tail repeats are used: the final event does not depend on the exact number of asks.
    let scripts: [&[&str]; 17] = [
        &["opened"],
        &["failed"],
        &["released"],
        &["expired"],
        &["opened", "released"],
        &["opened", "expired"],
        &["failed", "released"],
        &["failed", "expired"],
        &["failed", "opened"],
        &["opened", "failed"],
        &["failed", "failed", "released"],
        &["opened", "opened", "failed"],
        &["opened", "opened", "opened", "expired"],
        &["failed", "opened", "failed"],
        &["released", "failed"],
        &["expired", "released"],
        &["failed", "failed", "opened"],
    ];
    for s in scripts {
        out.push(json!({ "op": "outcome", "script": s, "deadline_ms": 500, "tick_ms": 50, "poll_ms": 100 }));
    }
    // A deadline so short that nothing is asked, and one that is already over.
    out.push(json!({ "op": "outcome", "script": ["released"], "deadline_ms": 60, "tick_ms": 50, "poll_ms": 200 }));
    out.push(json!({ "op": "outcome", "script": ["released"], "deadline_ms": 0, "tick_ms": 50, "poll_ms": 100 }));
    out
}

const BASES: [&str; 5] = [
    "http://example.test:8096",
    "https://tv.example.de",
    "https://tv.example.de/jf/",
    "http://[::1]:8096",
    "http://192.168.1.2/",
];
const BODIES: [&str; 22] = [
    "",
    "true",
    "True",
    "false",
    "FALSE",
    "{}",
    "{\"Authenticated\":true}",
    "{\"Authenticated\":false}",
    "{\"Authenticated\":\"yes\"}",
    "{\"authenticated\":true}",
    "{\"Secret\":\"s3\",\"Code\":\"123456\"}",
    "{\"Secret\":\"s3\"}",
    "{\"Code\":123456,\"Secret\":\"s\"}",
    "[{\"Id\":\"u1\",\"Name\":\"Anna\",\"PrimaryImageTag\":\"tag\"},{\"Id\":\"u2\",\"Name\":\"Bo\"}]",
    "[{\"Id\":\"u1\"}]",
    "[]",
    "<html>login</html>",
    "nope",
    "{\"AccessToken\":\"tok\",\"User\":{\"Id\":\"uid\",\"Name\":\"nm\"}}",
    "{\"AccessToken\":\"tok\",\"ServerId\":\"sid\",\"User\":{\"Id\":\"uid\",\"Name\":\"nm\",\"ServerId\":\"sid\"}}",
    "{\"AccessToken\":\"tok\"}",
    "truefalse",
];
const CODES_IN: [&str; 14] = [
    "123456",
    "12345",
    "1234",
    "123",
    "",
    "  1234  ",
    "\n12 34\t",
    "ab",
    "äöü1",
    "👨‍👩‍👧x",
    "e\u{301}e\u{301}e\u{301}",
    "\u{a0}1234\u{a0}",
    "\u{85}1234\u{2028}",
    "a&b=c d",
];

pub fn login_http() -> Vec<Value> {
    let mut rng = Rng::new(0x4854_5450);
    let mut out = vec![];
    let ops = [
        "start", "released", "ask", "enabled", "share", "public", "signin",
    ];
    for n in 0..4000 {
        let op = ops[n % ops.len()];
        let reply = match rng.below(10) {
            0 => {
                json!({ "net": *rng.pick(&[-1001, -1003, -1004, -1005, -1009, -1200, -1202, -1, -999, -1100]) })
            }
            1..=3 => json!({ "status": 200, "body": *rng.pick(&BODIES) }),
            _ => {
                json!({ "status": *rng.pick(&[200, 200, 201, 204, 301, 400, 401, 403, 404, 408, 429, 500, 503, 502, 599]), "body": *rng.pick(&BODIES) })
            }
        };
        out.push(json!({
            "op": op, "reply": reply, "base": *rng.pick(&BASES), "code": *rng.pick(&CODES_IN), "secret": *rng.pick(&["sec", "", "a b&c=d", "ünï"]),
            "no_session": rng.chance(10),
        }));
    }
    for id in [
        "u1", "", "a/b", "a b", "ünï", "../x", "u?1", "a#b", "%41", "x\u{0}y",
    ] {
        for mark in [
            Value::Null,
            json!("tag"),
            json!(""),
            json!("a b&c"),
            json!("ü"),
        ] {
            for border in [180, 0, -5, 1_000_000] {
                for base in BASES {
                    out.push(json!({ "op": "image", "id": id, "mark": mark, "border": border, "base": base }));
                }
            }
        }
    }
    out
}

const URLS: [&str; 11] = [
    "https://tv.example.de",
    "https://tv.example.de/",
    "HTTPS://TV.Example.DE//",
    "http://192.168.1.5:8096",
    "http://192.168.1.5:8096/",
    "https://a.b/jf/",
    "http://[::1]:8096/",
    "https://tv.example.de:443",
    "http://nas.local",
    "https://xn--n-nga1b.example/",
    "http://x/y%20z/",
];
const USERS: [&str; 5] = ["u1", "U1", "u2", "", "ünï"];
const MACHINES: [&str; 3] = ["m1", "m2", "M1"];

fn session(rng: &mut Rng, kind: Option<&str>) -> String {
    let kind = kind.map_or_else(
        || *rng.pick(&["jellyfin", "jellyfin", "emby", "plex"]),
        |k| k,
    );
    let mut o = serde_json::Map::new();
    o.insert(
        "accessToken".into(),
        json!(format!("tok{}", rng.below(1000))),
    );
    o.insert("userID".into(), json!(*rng.pick(&USERS)));
    o.insert("userName".into(), json!("n"));
    o.insert("serverURL".into(), json!(*rng.pick(&URLS)));
    if kind != "jellyfin" || rng.chance(5) {
        o.insert("kind".into(), json!(kind));
    }
    if kind == "plex" || rng.chance(5) {
        o.insert("plex".into(), json!({ "machineIdentifier": *rng.pick(&MACHINES), "serverName": "S", "accountToken": "pt", "isLocal": rng.chance(50), "isRelay": false }));
    }
    Value::Object(o).to_string()
}

fn steps(rng: &mut Rng, kind: Option<&str>, n: u64) -> Vec<Value> {
    (0..n)
        .map(|_| match rng.below(7) {
            0 => json!({ "op": "record", "session": session(rng, kind) }),
            1 => json!({ "op": "record_in", "session": session(rng, kind) }),
            2 => json!({ "op": "switch", "id": id_pick(rng) }),
            3 => json!({ "op": "remove", "id": id_pick(rng) }),
            4 => json!({ "op": "on", "server": *rng.pick(&URLS) }),
            5 => json!({ "op": "account", "id": id_pick(rng) }),
            _ => json!({ "op": "fits", "session": session(rng, kind) }),
        })
        .collect()
}

fn id_pick(rng: &mut Rng) -> String {
    match rng.below(4) {
        0 => (*rng.pick(&USERS)).to_string(),
        1 => format!(
            "{}|{}",
            (*rng.pick(&URLS)).to_lowercase().trim_end_matches('/'),
            rng.pick(&USERS)
        ),
        2 => format!(
            "{}{}|{}",
            rng.pick(&["emby:", "plex:", ""]),
            rng.pick(&MACHINES),
            rng.pick(&USERS)
        ),
        _ => "zz".to_string(),
    }
}

pub fn login_accounts() -> Vec<Value> {
    let mut rng = Rng::new(0x4143_434f);
    let mut out = vec![];
    for _ in 0..1500 {
        out.push(json!({ "op": "key", "session": session(&mut rng, None) }));
    }
    for s in [
        "{}",
        "{\"accessToken\":\"t\",\"userID\":\"u\",\"userName\":\"n\",\"serverURL\":\"not a url\"}",
        "{\"accessToken\":\"t\",\"userID\":\"u\",\"userName\":\"n\",\"serverURL\":\"https://x/\",\"kind\":\"bogus\"}",
        "{\"accessToken\":\"t\",\"userID\":\"u\",\"userName\":\"n\",\"serverURL\":\"https://x/\",\"kind\":\"plex\"}",
        "{\"accessToken\":\"t\",\"userID\":\"u\",\"userName\":\"n\",\"serverURL\":\"https://x/\",\"kind\":\"plex\",\"plex\":{\"machineIdentifier\":\"m\",\"accountToken\":\"a\",\"serverName\":\"s\",\"isLocal\":false,\"isRelay\":false}}",
        "[]",
        "",
    ] {
        out.push(json!({ "op": "key", "session": s }));
    }
    for _ in 0..2500 {
        let kind = if rng.chance(70) {
            Some(*rng.pick(&["jellyfin", "emby", "plex"]))
        } else {
            None
        };
        let n = rng.below(5) + 1;
        let sessions: Vec<String> = (0..n).map(|_| session(&mut rng, kind)).collect();
        let active = if rng.chance(30) {
            Value::Null
        } else {
            json!(id_pick(&mut rng))
        };
        let count = rng.below(8);
        let st = steps(&mut rng, kind, count);
        out.push(json!({ "op": "bundle", "sessions": sessions, "active": active, "steps": st }));
    }
    for _ in 0..300 {
        out.push(json!({ "op": "single", "session": session(&mut rng, None) }));
    }
    // Stores: a bundle (good, with a stale pointer, junk), the single session before bundles, nothing.
    for _ in 0..800 {
        let n = rng.below(4) + 1;
        let accounts: Vec<Value> = (0..n)
            .map(|_| serde_json::from_str(&session(&mut rng, None)).unwrap())
            .collect();
        let bundle = match rng.below(6) {
            0 => Value::Null,
            1 => json!("garbage"),
            2 => json!("{\"konten\":[]}"),
            3 => {
                json!(json!({ "konten": accounts, "aktiveKennung": id_pick(&mut rng) }).to_string())
            }
            _ => json!(
                json!({ "konten": accounts, "aktiveKennung": accounts[0]["userID"] }).to_string()
            ),
        };
        let individual = match rng.below(4) {
            0 => Value::Null,
            1 => json!("{}"),
            _ => json!(session(&mut rng, None)),
        };
        out.push(json!({ "op": "from_store", "bundle": bundle, "individual": individual }));
    }
    for d in [
        "{\"serverURL\":\"https://x/\",\"token\":\"t\",\"benutzerID\":\"u\",\"benutzername\":\"n\",\"serverName\":\"S\"}",
        "{\"serverURL\":\"https://x/\",\"token\":\"t\",\"benutzerID\":\"u\",\"benutzername\":\"n\"}",
        "{\"serverURL\":\"https://x/\",\"token\":\"t\",\"benutzerID\":\"u\"}",
        "{\"serverURL\":\"https://x/\",\"accessToken\":\"t\",\"userID\":\"u\",\"userName\":\"n\"}",
        "{\"serverURL\":5,\"token\":\"t\",\"benutzerID\":\"u\",\"benutzername\":\"n\"}",
        "nope",
        "",
    ] {
        out.push(json!({ "op": "old_gtk", "data": d }));
    }
    for _ in 0..400 {
        let mut store = serde_json::Map::new();
        for key in ["konten", "konten.emby", "konten.plex"] {
            if rng.chance(60) {
                let kind = match key {
                    "konten" => "jellyfin",
                    "konten.emby" => "emby",
                    _ => "plex",
                };
                let accounts: Vec<Value> = (0..rng.below(3) + 1)
                    .map(|_| serde_json::from_str(&session(&mut rng, Some(kind))).unwrap())
                    .collect();
                let text = if rng.chance(15) {
                    "junk".to_string()
                } else {
                    json!({ "konten": accounts, "aktiveKennung": id_pick(&mut rng) }).to_string()
                };
                store.insert(key.into(), json!(text));
            }
        }
        if rng.chance(80) {
            store.insert(
                "aktiveArt".into(),
                json!(*rng.pick(&["jellyfin", "emby", "plex", "bogus", "", "Emby"])),
            );
        }
        out.push(json!({ "op": "bundles_load", "store": store }));
    }
    for _ in 0..500 {
        let n = rng.below(6);
        let sessions: Vec<String> = (0..n).map(|_| session(&mut rng, None)).collect();
        let st: Vec<Value> = (0..rng.below(6))
            .map(|_| json!({ "op": *rng.pick(&["switch", "clear"]), "kind": *rng.pick(&["jellyfin", "emby", "plex"]) }))
            .collect();
        out.push(json!({ "op": "bundles_ops", "sessions": sessions, "steps": st }));
    }
    out
}

const PATHS: [&str; 30] = [
    "UserViews",
    "UserViews/",
    "/UserViews",
    "Items",
    "Items/42",
    "Items/42/SpecialFeatures",
    "Items/42/LocalTrailers",
    "Items/42/Similar",
    "Items/42/Ancestors/x",
    "UserItems/Resume",
    "UserItems/42/UserData",
    "UserItems/42/Other",
    "UserItems",
    "UserFavoriteItems/42",
    "UserPlayedItems/42",
    "UserPlayedItems",
    "Shows/1/Episodes",
    "System/Info/Public",
    "",
    "/",
    "//Items//42",
    "Items/ü",
    "Items/42/",
    "useritems/resume",
    "Users/u1/Items",
    "UserViews/x",
    "Items/42/SpecialFeatures/x",
    "Items/a b",
    "Genres",
    "UserFavoriteItems/42/extra",
];
const PRODUCTS: [&str; 12] = [
    "Jellyfin Server",
    "jellyfin",
    "JELLYFIN",
    "Emby Server",
    "",
    "Jelly fin",
    "Jellyfın",
    "JellyfİN",
    "Jelly\u{200b}fin",
    "Plex Media Server",
    "ＪＥＬＬＹＦＩＮ",
    "my-jellyfin-fork",
];
const VERSIONS: [&str; 24] = [
    "10.11.0",
    "4.10.0.2",
    "12.0.0",
    "10",
    "9.9",
    "",
    ".10",
    "..10.1",
    "+10",
    "-10",
    "10a",
    "1e1",
    "٣",
    "10.",
    "0.10",
    "010.1",
    "99999999999999999999",
    "x.10",
    "10 .1",
    " 10",
    "10\n",
    "９",
    "9.99",
    "10.x",
];

pub fn login_kind() -> Vec<Value> {
    let mut rng = Rng::new(0x4b49_4e44);
    let mut out = vec![];
    for p in PRODUCTS {
        for v in VERSIONS {
            out.push(json!({ "op": "looks_jellyfin", "product": p, "version": v }));
        }
        out.push(json!({ "op": "looks_jellyfin", "product": p }));
    }
    for v in VERSIONS {
        out.push(json!({ "op": "looks_jellyfin", "version": v }));
    }
    out.push(json!({ "op": "looks_jellyfin" }));
    for p in PATHS {
        for u in [
            Value::Null,
            json!(""),
            json!("u1"),
            json!("ü/x"),
            json!("a b"),
        ] {
            out.push(json!({ "op": "rewrite", "path": p, "user": u }));
        }
    }
    for k in ["jellyfin", "emby", "plex"] {
        out.push(json!({ "op": "token_name", "kind": k }));
    }
    out.push(json!({ "op": "deadline" }));
    out.push(json!({ "op": "fallback", "e": { "t": "cancel" } }));
    for code in CODES {
        out.push(json!({ "op": "fallback", "e": { "t": "ns", "code": code } }));
        out.push(json!({ "op": "fallback", "e": { "t": "ns_other", "code": code } }));
        out.push(json!({ "op": "fallback", "e": { "t": "network", "code": code } }));
    }
    for _ in 0..800 {
        out.push(json!({ "op": "fallback", "e": error_case(&mut rng) }));
    }
    for _ in 0..1500 {
        let st: Vec<Value> = (0..rng.below(14) + 1)
            .map(|_| match rng.below(5) {
                0 | 1 => json!({ "op": "begin", "address": *rng.pick(&URLS) }),
                2 => json!({ "op": "applies", "i": rng.below(5) }),
                3 => json!({ "op": "complete", "i": rng.below(5) }),
                _ => json!({ "op": "discard" }),
            })
            .collect();
        out.push(json!({ "op": "check", "steps": st }));
    }
    out
}
