//! Stress modes of the fixture server (`cargo xtask fixture-server --mode empty|long|huge|i18n|slow|offline-flaky|auth-expire`).
//! Purely additive: with no mode every request goes to the old routing untouched. Modes can be combined with commas
//! (`--mode huge,i18n,slow`). `GET /fixture/mode` tells the tester what is on.

use crate::fixture_server::{Reply, find, list, movie};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};

pub(crate) const MOVIES: usize = 10_000;
pub(crate) const SERIES: usize = 500;

/// What a request gets in the end.
pub(crate) enum Outcome {
    Reply(Reply),
    /// Close the connection without an answer (a timeout for the client).
    Drop,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Config {
    pub empty: bool,
    pub long: bool,
    pub huge: bool,
    pub i18n: bool,
    /// Another device of the same user is playing `m1` (`GET /Sessions`), and the hand-over endpoints answer.
    pub sessions: bool,
    /// Fixed latency per request in ms (0 = off).
    pub latency_ms: u64,
    /// Every Nth countable request fails (0 = off): odd failures answer 503, even ones drop the connection.
    pub flaky_every: u64,
    /// After N countable requests since the last sign-in the token is rejected with 401 (0 = off).
    pub expire_after: u64,
}

impl Config {
    /// `modes` is a comma list; numbers come from the flags or the defaults (400 ms, every 5th, after 20).
    pub fn parse(
        modes: &str,
        latency: Option<u64>,
        flaky: Option<u64>,
        expire: Option<u64>,
    ) -> Result<Self, String> {
        let mut c = Self::default();
        for m in modes.split(',').map(str::trim).filter(|m| !m.is_empty()) {
            match m {
                "normal" => {}
                "empty" => c.empty = true,
                "long" => c.long = true,
                "huge" => c.huge = true,
                "i18n" => c.i18n = true,
                "sessions" => c.sessions = true,
                "slow" => c.latency_ms = latency.unwrap_or(400),
                "offline-flaky" => c.flaky_every = flaky.unwrap_or(5),
                "auth-expire" => c.expire_after = expire.unwrap_or(20),
                other => {
                    return Err(format!(
                        "unknown mode `{other}` (empty|long|huge|i18n|sessions|slow|offline-flaky|auth-expire)"
                    ));
                }
            }
        }
        if c.empty && c.huge {
            return Err("`empty` and `huge` exclude each other".into());
        }
        // Explicit numbers also work without the mode word.
        c.latency_ms = latency.unwrap_or(c.latency_ms);
        c.flaky_every = flaky.unwrap_or(c.flaky_every);
        c.expire_after = expire.unwrap_or(c.expire_after);
        Ok(c)
    }

    fn names(&self) -> Vec<&'static str> {
        let mut v = Vec::new();
        for (on, n) in [
            (self.empty, "empty"),
            (self.long, "long"),
            (self.huge, "huge"),
            (self.i18n, "i18n"),
            (self.sessions, "sessions"),
            (self.latency_ms > 0, "slow"),
            (self.flaky_every > 0, "offline-flaky"),
            (self.expire_after > 0, "auth-expire"),
        ] {
            if on {
                v.push(n);
            }
        }
        if v.is_empty() {
            v.push("normal");
        }
        v
    }
}

#[derive(Default)]
pub(crate) struct State {
    total: AtomicU64,
    since_login: AtomicU64,
    failures: AtomicU64,
}

impl State {
    pub const fn new() -> Self {
        Self {
            total: AtomicU64::new(0),
            since_login: AtomicU64::new(0),
            failures: AtomicU64::new(0),
        }
    }
}

static CONFIG: OnceLock<Config> = OnceLock::new();
static STATE: State = State::new();

pub(crate) fn set_global(c: Config) {
    let _ = CONFIG.set(c);
}

pub(crate) fn global() -> (&'static Config, &'static State) {
    (CONFIG.get_or_init(Config::default), &STATE)
}

fn json(body: String) -> Reply {
    Reply(200, "application/json", body.into_bytes())
}

fn is_auth(path: &str) -> bool {
    path.starts_with("/Users/Authenticate") || path.starts_with("/QuickConnect")
}

/// Requests that count for flaky/expire: everything but the tester's own endpoints and the sign-in handshake.
fn countable(path: &str) -> bool {
    !(path.starts_with("/fixture")
        || path == "/System/Info/Public"
        || path == "/Users/Public"
        || is_auth(path))
}

// ---- i18n and long text ----

const I18N_NAMES: [&str; 6] = [
    "الشمس المشرقة",
    "千と千尋の神隠し",
    "ลุงบุญมีระลึกชาติ",
    "🎬🍿 Kino-Nacht 🌙✨",
    "הים התיכון",
    "Nordlicht العربية 日本語 🌌",
];
const I18N_SERIES: &str = "港の灯り – أضواء الميناء 🚢";
const NORMAL_NAMES: [&str; 6] = [
    "Nordlicht",
    "Sommerregen",
    "Die Brücke",
    "Stilles Wasser",
    "Papierschiffe",
    "Nachtzug",
];
const OVERVIEW: &str = "Ein ruhiger Testfilm vom Fixture-Server.";
const I18N_OVERVIEW: &str = "في ليلة هادئة على الميناء، يبحث رجل عن صوت البحر الذي فقده منذ سنوات، ويجد أكثر مما كان يتوقع. 港の小さな町で、一人の男が失われた音を探す。ท่าเรือเงียบสงบในคืนหนึ่ง 🌊 שקט בנמל, והים שר מחדש. ";
const LONG_TITLE: &str = " – Eine außergewöhnlich lange Titelfortsetzung, die über mehrere Zeilen läuft, weil sie niemals in eine einzelne Kachel passt, und trotzdem lesbar bleiben muss (Director's Cut, Extended Edition, Remastered 4K)";
const LONG_OVERVIEW_UNIT: &str = "Dies ist ein sehr langer Beschreibungstext, der prüft, ob Zeilenumbruch, Kürzung und Scrollen auf der Detailseite sauber arbeiten, auch ohne Leerzeichen: Donaudampfschifffahrtsgesellschaftskapitänsmützenabzeichenhersteller. ";

fn replace_values(text: &str, key: &str, f: &dyn Fn(&str) -> String) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(key) {
        let (head, tail) = rest.split_at(at + key.len());
        out.push_str(head);
        let end = tail.find('"').unwrap_or(tail.len());
        out.push_str(&f(&tail[..end]));
        rest = &tail[end..];
    }
    out.push_str(rest);
    out
}

fn i18n(text: &str) -> String {
    let mut t = text.to_owned();
    for (n, i) in NORMAL_NAMES.iter().zip(I18N_NAMES) {
        t = t.replace(&format!(r#""Name":"{n}""#), &format!(r#""Name":"{i}""#));
    }
    t.replace(r#""Hafenlichter""#, &format!("\"{I18N_SERIES}\""))
        .replace(OVERVIEW, I18N_OVERVIEW.trim_end())
}

fn long(text: &str) -> String {
    let t = replace_values(text, r#""Name":""#, &|v| format!("{v}{LONG_TITLE}"));
    replace_values(&t, r#""Overview":""#, &|v| {
        format!("{v} {}", LONG_OVERVIEW_UNIT.repeat(12))
    })
}

/// Text modes only touch item answers, never sign-in, user names or the tester's endpoints.
fn text_mode_applies(path: &str) -> bool {
    !(path.starts_with("/fixture")
        || path.starts_with("/System")
        || path.starts_with("/Users/Public")
        || is_auth(path)
        || path.contains("/Images/")
        || path.contains("/Videos/")
        || path.starts_with("/:/")
        || path.starts_with("/Sessions"))
}

// ---- huge catalogue ----

fn base_name(cfg: &Config, n: usize) -> &'static str {
    if cfg.i18n {
        I18N_NAMES[n % 6]
    } else {
        NORMAL_NAMES[n % 6]
    }
}

/// A sort name whose first letter climbs A..Z with the index, so the list is in `SortName` order and the letter rail has
/// 26 letters to show (the display names start with digits and would all fall under "#").
fn huge_sort_name(n: usize, total: usize, name: &str) -> String {
    format!(
        "{}{n:05} {name}",
        (b'A' + (n * 26 / total).min(25) as u8) as char
    )
}

fn huge_movie_list(cfg: &Config, n: usize) -> String {
    format!(
        r#"{{"Id":"hm{n}","Name":"{n:05} {}","SortName":"{}","Type":"Movie","ProductionYear":{},"RunTimeTicks":{},"Overview":"{OVERVIEW}","ImageTags":{{"Primary":"phm{n}"}},"UserData":{{"Played":false}}}}"#,
        base_name(cfg, n),
        huge_sort_name(n, 10_000, base_name(cfg, n)),
        1950 + n % 75,
        (n as u64 % 90 + 60) * 600_000_000
    )
}

fn huge_series(cfg: &Config, n: usize) -> String {
    format!(
        r#"{{"Id":"hs{n}","Name":"S{n:03} {}","SortName":"{}","Type":"Series","ProductionYear":{},"ChildCount":{},"ImageTags":{{"Primary":"phs{n}"}},"UserData":{{"UnplayedItemCount":{},"Played":false}}}}"#,
        base_name(cfg, n),
        huge_sort_name(n, 500, base_name(cfg, n)),
        1980 + n % 45,
        1 + n % 8,
        n % 30
    )
}

/// Detail of a generated title: a full fixture movie (versions, streams) carrying the generated id and name.
fn huge_detail(cfg: &Config, id: &str) -> Option<String> {
    let n: usize = id.get(2..)?.parse().ok()?;
    match id.get(..2)? {
        "hm" if n < MOVIES => {
            let k = n % 6;
            let old = format!(r#"{{"Id":"m{k}","Name":"{}","#, NORMAL_NAMES[k]);
            let new = format!(r#"{{"Id":"hm{n}","Name":"{n:05} {}","#, base_name(cfg, n));
            Some(movie(k).replacen(&old, &new, 1))
        }
        "hs" if n < SERIES => Some(huge_series(cfg, n)),
        _ => None,
    }
}

fn find_any(cfg: &Config, id: &str) -> Option<String> {
    if cfg.huge && id.starts_with('h') {
        huge_detail(cfg, id)
    } else {
        find(id)
    }
}

/// One page of the generated catalogue. Types: Series only, Movie only, or movies then series.
fn huge_page(cfg: &Config, query_types: &str, parent: &str, start: usize, limit: usize) -> String {
    let want_series = query_types.contains("Series") || parent == "lib-shows";
    let want_movies = query_types.contains("Movie") || parent == "lib-movies";
    let (movies, shows) = match (want_movies, want_series) {
        (true, false) => (MOVIES, 0),
        (false, true) => (0, SERIES),
        _ => (MOVIES, SERIES),
    };
    let total = movies + shows;
    let end = start.saturating_add(limit).min(total);
    let items: Vec<String> = (start.min(total)..end)
        .map(|i| {
            if i < movies {
                huge_movie_list(cfg, i)
            } else {
                huge_series(cfg, i - movies)
            }
        })
        .collect();
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{total},"StartIndex":{start}}}"#,
        items.join(",")
    )
}

// ---- the gate ----

/// Answers one request. `fallback` is the normal routing (sync play, then the old routes).
pub(crate) fn handle(
    cfg: &Config,
    state: &State,
    method: &str,
    target: &str,
    fallback: &dyn Fn() -> Reply,
) -> Outcome {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let path = path.trim_end_matches('/');
    if path == "/fixture/mode" {
        return Outcome::Reply(mode_reply(cfg, state));
    }
    if cfg == &Config::default() {
        return Outcome::Reply(fallback());
    }
    let param = |k: &str| {
        query.split('&').find_map(|p| {
            p.split_once('=')
                .filter(|(n, _)| n.eq_ignore_ascii_case(k))
                .map(|(_, v)| v.replace("%2C", ",").replace("%2c", ","))
        })
    };
    if cfg.latency_ms > 0 && !path.starts_with("/fixture") {
        std::thread::sleep(std::time::Duration::from_millis(cfg.latency_ms));
    }
    if countable(path) {
        let total = state.total.fetch_add(1, Ordering::SeqCst) + 1;
        let since = state.since_login.fetch_add(1, Ordering::SeqCst) + 1;
        if cfg.expire_after > 0 && since > cfg.expire_after {
            return Outcome::Reply(Reply(401, "text/plain", b"token expired".to_vec()));
        }
        if cfg.flaky_every > 0 && total.is_multiple_of(cfg.flaky_every) {
            return if state
                .failures
                .fetch_add(1, Ordering::SeqCst)
                .is_multiple_of(2)
            {
                Outcome::Reply(Reply(503, "text/plain", b"flaky".to_vec()))
            } else {
                Outcome::Drop
            };
        }
    }
    let reply = content(cfg, path, &param).unwrap_or_else(fallback);
    if is_auth(path) && reply.0 == 200 {
        state.since_login.store(0, Ordering::SeqCst);
    }
    let _ = method;
    let Reply(status, kind, mut data) = reply;
    if kind == "application/json"
        && status == 200
        && text_mode_applies(path)
        && (cfg.i18n || cfg.long)
        && let Ok(mut t) = String::from_utf8(data.clone())
    {
        if cfg.i18n {
            t = i18n(&t);
        }
        if cfg.long {
            t = long(&t);
        }
        data = t.into_bytes();
    }
    Outcome::Reply(Reply(status, kind, data))
}

/// Content modes (`empty`, `huge`). `None` = let the normal routing answer.
fn content(cfg: &Config, path: &str, param: &dyn Fn(&str) -> Option<String>) -> Option<Reply> {
    if !(cfg.empty || cfg.huge) {
        return None;
    }
    let types = param("IncludeItemTypes").unwrap_or_default();
    let parent = param("ParentId").unwrap_or_default();
    let ids = param("Ids");
    if cfg.empty {
        let collection = parent == "c1" || parent == "c2" || parent == "pl1";
        if path.ends_with("/Items/Latest") {
            return Some(json("[]".into()));
        }
        if path.ends_with("/Items/Resume")
            || path.ends_with("/UserItems/Resume")
            || path == "/Shows/NextUp"
            || (path.ends_with("/Items") && ids.is_none() && !collection)
        {
            return Some(json(list(&[])));
        }
        return None;
    }
    // huge
    if path.ends_with("/Items/Latest") {
        let limit = param("Limit")
            .and_then(|l| l.parse().ok())
            .unwrap_or(16_usize);
        return Some(json(format!(
            "[{}]",
            (0..limit.min(MOVIES))
                .map(|n| huge_movie_list(cfg, n))
                .collect::<Vec<_>>()
                .join(",")
        )));
    }
    if path.ends_with("/Items") {
        if let Some(ids) = ids {
            if ids.split(',').any(|i| i.starts_with('h')) {
                return Some(json(list(
                    &ids.split(',')
                        .filter_map(|i| find_any(cfg, i))
                        .collect::<Vec<_>>(),
                )));
            }
            return None;
        }
        if types.contains("BoxSet")
            || types.contains("Playlist")
            || parent == "c1"
            || parent == "c2"
            || parent == "pl1"
        {
            return None;
        }
        let start = param("StartIndex")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let limit = param("Limit")
            .and_then(|v| v.parse().ok())
            .unwrap_or(usize::MAX);
        return Some(json(huge_page(cfg, &types, &parent, start, limit)));
    }
    if path.rsplit('/').nth(1) == Some("Items") {
        let id = path.rsplit('/').next().unwrap_or("");
        if id.starts_with('h') {
            return Some(match huge_detail(cfg, id) {
                Some(item) => json(item),
                None => Reply(404, "text/plain", b"no such item".to_vec()),
            });
        }
    }
    None
}

fn mode_reply(cfg: &Config, state: &State) -> Reply {
    let (movies, shows) = if cfg.empty {
        (0, 0)
    } else if cfg.huge {
        (MOVIES, SERIES)
    } else {
        (6, 1)
    };
    let names = cfg
        .names()
        .iter()
        .map(|n| format!("\"{n}\""))
        .collect::<Vec<_>>()
        .join(",");
    json(format!(
        r#"{{"modes":[{names}],"latencyMs":{},"flakyEvery":{},"expireAfter":{},"movies":{movies},"series":{shows},"requests":{},"sinceLogin":{}}}"#,
        cfg.latency_ms,
        cfg.flaky_every,
        cfg.expire_after,
        state.total.load(Ordering::SeqCst),
        state.since_login.load(Ordering::SeqCst)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixture_server::route;

    fn cfg(modes: &str) -> Config {
        Config::parse(
            modes,
            modes.contains("slow").then_some(30),
            None,
            modes.contains("auth-expire").then_some(3),
        )
        .expect("modes")
    }

    fn ask(c: &Config, s: &State, method: &str, target: &str, body: &str) -> Outcome {
        handle(c, s, method, target, &|| route(method, target, body))
    }

    fn reply(c: &Config, s: &State, target: &str) -> Reply {
        match ask(c, s, "GET", target, "") {
            Outcome::Reply(r) => r,
            Outcome::Drop => Reply(0, "", Vec::new()),
        }
    }

    fn body(r: &Reply) -> String {
        String::from_utf8(r.2.clone()).expect("utf-8")
    }

    #[test]
    fn parse_rejects_unknown_and_conflicting_modes() {
        assert!(Config::parse("bogus", None, None, None).is_err());
        assert!(Config::parse("empty,huge", None, None, None).is_err());
        let c = Config::parse("huge,i18n,slow", None, None, None).expect("ok");
        assert!(c.huge && c.i18n && c.latency_ms == 400);
        assert_eq!(
            Config::parse("normal", None, None, None).expect("ok"),
            Config::default()
        );
    }

    #[test]
    fn normal_mode_is_the_old_routing() {
        let (c, s) = (Config::default(), State::new());
        for t in ["/Users/u1/Items", "/Users/u1/Items/m1", "/Users/u1/Views"] {
            assert_eq!(reply(&c, &s, t).2, route("GET", t, "").2);
        }
        assert!(body(&reply(&c, &s, "/fixture/mode")).contains(r#""modes":["normal"]"#));
    }

    #[test]
    fn empty_mode_has_libraries_but_no_content() {
        let (c, s) = (cfg("empty"), State::new());
        assert!(body(&reply(&c, &s, "/Users/u1/Views")).contains("lib-movies"));
        for t in [
            "/Users/u1/Items?ParentId=lib-movies",
            "/Users/u1/Items/Resume",
            "/Shows/NextUp",
            "/Users/u1/Items?IncludeItemTypes=BoxSet",
        ] {
            assert_eq!(
                body(&reply(&c, &s, t)),
                r#"{"Items":[],"TotalRecordCount":0}"#,
                "{t}"
            );
        }
        assert_eq!(body(&reply(&c, &s, "/Users/u1/Items/Latest")), "[]");
        assert!(
            body(&reply(&c, &s, "/Users/u1/Items/m1")).contains(r#""Id":"m1""#),
            "detail by id still works"
        );
        assert!(body(&reply(&c, &s, "/fixture/mode")).contains(r#""movies":0"#));
    }

    #[test]
    fn long_mode_stretches_titles_and_overviews_but_not_sign_in() {
        let (c, s) = (cfg("long"), State::new());
        let b = body(&reply(&c, &s, "/Users/u1/Items/m1"));
        assert!(
            b.contains("Director's Cut") && b.len() > 3000,
            "{}",
            b.len()
        );
        assert!(body(&reply(&c, &s, "/Users/Public")).contains(r#""Name":"demo""#));
        let Outcome::Reply(auth) = ask(
            &c,
            &s,
            "POST",
            "/Users/AuthenticateByName",
            r#"{"Username":"demo","Pw":"demo"}"#,
        ) else {
            panic!("dropped")
        };
        assert_eq!(
            body(&auth),
            body(&route(
                "POST",
                "/Users/AuthenticateByName",
                r#"{"Username":"demo","Pw":"demo"}"#
            ))
        );
    }

    #[test]
    fn i18n_mode_serves_arabic_japanese_thai_emoji_and_rtl_text() {
        let (c, s) = (cfg("i18n"), State::new());
        let b = body(&reply(&c, &s, "/Users/u1/Items"));
        for want in [
            "الشمس المشرقة",
            "千と千尋の神隠し",
            "ลุงบุญมีระลึกชาติ",
            "🎬",
            "הים התיכון",
            "港の灯り",
            "في ليلة هادئة",
        ] {
            assert!(b.contains(want), "{want}");
        }
        assert!(!b.contains("Nordlicht\"") && !b.contains("Hafenlichter"));
        assert!(b.starts_with(r#"{"Items":["#) && b.contains(r#""TotalRecordCount":7"#));
    }

    #[test]
    fn huge_mode_pages_10000_movies_and_500_series() {
        let (c, s) = (cfg("huge"), State::new());
        let started = std::time::Instant::now();
        let all = body(&reply(&c, &s, "/Users/u1/Items?IncludeItemTypes=Movie"));
        assert!(
            all.contains(r#""TotalRecordCount":10000"#)
                && all.matches(r#""Type":"Movie""#).count() == 10_000
        );
        assert!(started.elapsed().as_secs() < 2, "{:?}", started.elapsed());
        let page = body(&reply(
            &c,
            &s,
            "/Users/u1/Items?IncludeItemTypes=Movie&StartIndex=9990&Limit=50",
        ));
        assert_eq!(
            page.matches(r#""Type":"Movie""#).count(),
            10,
            "last page is short"
        );
        assert!(page.contains(r#""Id":"hm9999""#) && page.contains(r#""StartIndex":9990"#));
        let shows = body(&reply(
            &c,
            &s,
            "/Users/u1/Items?IncludeItemTypes=Series&Limit=5",
        ));
        assert!(
            shows.contains(r#""TotalRecordCount":500"#)
                && shows.matches(r#""Type":"Series""#).count() == 5
        );
        let mixed = body(&reply(&c, &s, "/Users/u1/Items?StartIndex=10000&Limit=2"));
        assert!(mixed.contains(r#""TotalRecordCount":10500"#) && mixed.contains(r#""Id":"hs0""#));
        assert!(
            body(&reply(&c, &s, "/Users/u1/Items?ParentId=lib-shows&Limit=1"))
                .contains(r#""TotalRecordCount":500"#)
        );
        let detail = body(&reply(&c, &s, "/Users/u1/Items/hm42"));
        assert!(detail.contains(r#""Id":"hm42""#) && detail.contains("MediaSources"));
        assert_eq!(reply(&c, &s, "/Users/u1/Items/hm10000").0, 404);
        assert!(
            body(&reply(&c, &s, "/Users/u1/Items?ids=hm7,hs3")).contains(r#""TotalRecordCount":2"#)
        );
        let poster = reply(&c, &s, "/Items/hm5/Images/Primary");
        assert!(poster.0 == 200 && poster.1 == "image/png");
    }

    #[test]
    fn slow_mode_waits_the_configured_latency_but_not_for_the_tester_endpoint() {
        let (c, s) = (cfg("slow"), State::new());
        let t = std::time::Instant::now();
        let _ = reply(&c, &s, "/Users/u1/Views");
        assert!(t.elapsed().as_millis() >= 30);
        let t = std::time::Instant::now();
        let _ = reply(&c, &s, "/fixture/mode");
        assert!(t.elapsed().as_millis() < 30);
        assert!(body(&reply(&c, &s, "/fixture/mode")).contains(r#""latencyMs":30"#));
    }

    #[test]
    fn offline_flaky_fails_every_nth_request_alternating_503_and_drop() {
        let c = Config::parse("offline-flaky", None, Some(3), None).expect("ok");
        let s = State::new();
        let results: Vec<u16> = (0..9).map(|_| reply(&c, &s, "/Users/u1/Views").0).collect();
        assert_eq!(results, [200, 200, 503, 200, 200, 0, 200, 200, 503]);
        assert_eq!(
            reply(&c, &s, "/System/Info/Public").0,
            200,
            "handshake and tester endpoints never fail"
        );
    }

    #[test]
    fn auth_expire_rejects_with_401_until_the_next_sign_in() {
        let (c, s) = (cfg("auth-expire"), State::new());
        let codes: Vec<u16> = (0..5).map(|_| reply(&c, &s, "/Users/u1/Views").0).collect();
        assert_eq!(codes, [200, 200, 200, 401, 401]);
        assert_eq!(reply(&c, &s, "/System/Info/Public").0, 200);
        let Outcome::Reply(bad) = ask(
            &c,
            &s,
            "POST",
            "/Users/AuthenticateByName",
            r#"{"Username":"x","Pw":"y"}"#,
        ) else {
            panic!()
        };
        assert_eq!(bad.0, 401);
        assert_eq!(
            reply(&c, &s, "/Users/u1/Views").0,
            401,
            "a failed sign-in does not renew the token"
        );
        let Outcome::Reply(ok) = ask(
            &c,
            &s,
            "POST",
            "/Users/AuthenticateByName",
            r#"{"Username":"demo","Pw":"demo"}"#,
        ) else {
            panic!()
        };
        assert_eq!(ok.0, 200);
        assert_eq!(reply(&c, &s, "/Users/u1/Views").0, 200);
        assert!(body(&reply(&c, &s, "/fixture/mode")).contains(r#""expireAfter":3"#));
    }
}
