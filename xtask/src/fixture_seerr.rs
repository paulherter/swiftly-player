//! The Seerr side of `cargo xtask fixture-server` (`/api/v1/...`): a small stateful Jellyseerr.
//!
//! One world behind a mutex: a normal user (`demo`, may only request and report issues; quota of
//! 3 films and 3 series seasons a week, 1 and 2 used) and an admin, anchored on the library of the
//! `--real-shapes` fixture (series "Küstenwache" Tmdb 7777, films Tmdb 1000 + n). Requests, approvals,
//! issues and deletes change the world, so the next read shows the new state.
//!
//! * Role: `SWIFTLY_FIXTURE_SEERR_ROLE=user|admin`, or `POST /__seerr/role?admin` / `?user`.
//! * Sign-in: `POST auth/jellyfin` takes any name and password except the password `falsch` (401); `POST auth/local`
//!   takes `lena@example.com` / `richtig` (else 403 "Access denied."); `POST auth/plex` takes the token `plex-ok` (else
//!   403). `POST /__seerr/signin?jellyfin=off&local=off&plex=off` switches a way off (500 "... is disabled", the
//!   answer of a Seerr in the other mode); `?jellyfin=on` etc. switches it back on; reset turns all on.
//! * `POST /__seerr/reset` rebuilds the world; `GET /__seerr/log` lists every call made (for checks);
//!   `POST /__seerr/fail?step=jellyfin[&times=N]` makes the next Jellyfin refresh fail (500);
//!   `POST /__seerr/online` ends the 503 answer of the search term `__off` and of `/__seerr/offline`;
//!   `POST /__seerr/offline` makes every search answer 503 (library results next to the offline line);
//!   `POST /__seerr/arrive[?id=N]` adds an approved request of the signed-in account for film 1001, which the library
//!   already has (the Home banner "<Titel> ist da").
//! * Delete: `DELETE media/{id}/file` marks the version gone; `POST /Library/Refresh` (the Jellyfin side)
//!   then hides it from the `--real-shapes` library when `SWIFTLY_FIXTURE_SEERR_DELETE_JELLYFIN=1`.
//! * The old routes of the Android comparisons (Tmdb 603, 1399, 77, 88, person 7) keep their answers; a
//!   search term that matches nothing of the new world still gets the old list (except `zzzz`).

use std::collections::BTreeMap;
use std::sync::Mutex;

use crate::fixture_server::Reply;

const ADMIN: i64 = 2;
/// REQUEST | REQUEST_MOVIE | REQUEST_TV | CREATE_ISSUES | VIEW_ISSUES.
const USER_PERMS: i64 = 32 + 262_144 + 524_288 + 4_194_304 + 2_097_152;

/// Paths this module answers: the Seerr API, its control routes and the Jellyfin refresh.
pub fn handles(path: &str) -> bool {
    path.starts_with("/api/v1/")
        || path.starts_with("/__seerr/")
        || path.starts_with("/t/p/")
        || path == "/Library/Refresh"
}

/// A TMDB-style picture, `/t/p/w{width}/{kind}{number}.jpg`, so a run with `SWIFTLY_TMDB_IMAGES=http://<fixture>/t/p`
/// shows pictures for what the Seerr answers name by path: `p` poster (2:3), `b` backdrop and `s` still (16:9), any
/// other kind (cast `c`) square. The picture is a generated PNG whose colours follow the name.
fn tmdb_picture(path: &str) -> Reply {
    let rest = path.trim_start_matches("/t/p/");
    let (size, name) = rest.split_once('/').unwrap_or(("w300", rest));
    let width: u32 = size
        .trim_start_matches('w')
        .parse()
        .unwrap_or(300)
        .clamp(16, 1280);
    let kind = name.chars().next().unwrap_or('x');
    let number: u32 = name
        .chars()
        .filter(char::is_ascii_digit)
        .collect::<String>()
        .parse()
        .unwrap_or(0);
    let height = match kind {
        'p' => width * 3 / 2,
        'b' | 's' => width * 9 / 16,
        _ => width,
    };
    Reply(
        200,
        "image/png",
        crate::fixture_server::png(number.wrapping_add(kind as u32), width, height),
    )
}

/// The episodes of a series season: only "Nordmeer" (3002, a Seerr-only series with three seasons) has them, so the
/// episode list of a title page can be seen with its stills, runtimes and stories; every other series answers none,
/// like a TMDB without episode data. Episode 4 has a very long name, 5 no story, 6 no still.
fn episodes_json(tmdb: i64, season: i64) -> String {
    if tmdb == 3004 && season == 22 {
        // Two episodes aired, the third comes in a week (relative to the run date, so the word stays "up to date").
        let day = |offset: i64| day_from_today(offset);
        let days = [day(-70), day(-7), day(7)];
        let rows: Vec<String> = days
            .iter()
            .enumerate()
            .map(|(i, d)| {
                format!(
                    r#"{{"id":{},"episodeNumber":{},"seasonNumber":22,"name":"Folge {}","airDate":"{d}","runtime":45}}"#,
                    3_004_000 + i,
                    i + 1,
                    i + 1
                )
            })
            .collect();
        return format!("[{}]", rows.join(","));
    }
    if tmdb != 3002 {
        return "[]".into();
    }
    const NAMES: [&str; 6] = [
        "Ankunft im Hafen",
        "Nebel über dem Deich",
        "Ebbe",
        "Die lange Nacht, in der das Meer alles zurückholte und niemand mehr wusste, wem das Boot gehörte",
        "Strandgut",
        "Sturmflut",
    ];
    let count = if season == 3 { 3 } else { 6 };
    let rows: Vec<String> = (1..=count)
        .map(|k| {
            let still = if k == 6 {
                "null".to_string()
            } else {
                format!("\"/s{tmdb}{season}{k}.jpg\"")
            };
            let story = if k == 5 {
                String::new()
            } else {
                format!(
                    "In Folge {k} der Staffel {season} geht es um das Meer, den Hafen und alles dazwischen. Ein längerer Text, damit mehrere Zeilen nötig sind und die Zeile am Ende abgeschnitten wird."
                )
            };
            format!(
                r#"{{"id":{id},"episodeNumber":{k},"seasonNumber":{season},"name":"{name}","overview":"{story}","stillPath":{still},"airDate":"2025-{month:02}-{k:02}","runtime":{runtime}}}"#,
                id = tmdb * 1000 + season * 10 + k,
                name = NAMES[(k - 1) as usize],
                month = season,
                runtime = 41 + k,
            )
        })
        .collect();
    format!("[{}]", rows.join(","))
}

// ---- world ----

#[derive(Clone, Copy, PartialEq, Eq)]
enum Role {
    User,
    Admin,
}

struct Def {
    tmdb: i64,
    art: &'static str,
    name: String,
    date: &'static str,
    seasons: &'static [(i64, &'static str)],
}

#[derive(Clone)]
struct Queue {
    season: Option<i64>,
    size: u64,
    left: u64,
    time_left: &'static str,
}

#[derive(Clone)]
struct Media {
    status: u8,
    status4k: u8,
    seasons: BTreeMap<i64, u8>,
    queue: Vec<Queue>,
}

#[derive(Clone)]
struct Req {
    id: i64,
    tmdb: i64,
    status: u8,
    is4k: bool,
    seasons: Vec<i64>,
    user: i64,
    counted: i64,
    modified_by: Option<i64>,
}

#[derive(Clone)]
struct Issue {
    id: i64,
    kind: i64,
    status: u8,
    season: i64,
    episode: i64,
    tmdb: i64,
    user: i64,
    comments: Vec<(i64, String)>,
}

struct World {
    role: Role,
    media: BTreeMap<i64, Media>,
    requests: Vec<Req>,
    issues: Vec<Issue>,
    next_request: i64,
    next_issue: i64,
    next_comment: i64,
    movie_used: i64,
    tv_used: i64,
    gone: Vec<(i64, bool)>,
    library_gone: Vec<(i64, bool)>,
    fail_jellyfin: u32,
    /// Which sign-in ways Seerr accepts: Jellyfin, e-mail and password, Plex.
    sign_in_on: [bool; 3],
    search_offline: bool,
    /// Every search answers 503 (`POST /__seerr/offline`), whatever the term.
    search_down: bool,
    log: Vec<String>,
}

static WORLD: Mutex<Option<World>> = Mutex::new(None);

const KUESTENWACHE_SEASONS: &[(i64, &str)] = &[
    (1, "2024-01-10"),
    (2, "2024-09-01"),
    (3, "2025-06-01"),
    (4, "2026-01-15"),
    (5, ""),
];
const NORDSEE_SEASONS: &[(i64, &str)] = &[(1, "2025-03-01"), (2, "2026-03-01")];
/// A series nobody asked for yet: every season can be requested.
const NORDMEER_SEASONS: &[(i64, &str)] = &[(1, "2024-02-02"), (2, "2025-02-02"), (3, "2026-02-02")];
/// "Sweet P": season 2 airs in the future (a request for it must say when, not "searching").
const SWEET_P_SEASONS: &[(i64, &str)] = &[(1, "2024-05-01"), (2, "2026-11-26")];
/// "TV Total": season 22 runs, everything aired is in the library, one more episode is still to come.
const TV_TOTAL_SEASONS: &[(i64, &str)] = &[(21, "2025-09-01"), (22, "2026-09-01")];

/// `yyyy-mm-dd` of today plus `offset` days (UTC; civil-from-days, no date crate).
fn day_from_today(offset: i64) -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let z = i64::try_from(secs / 86_400).unwrap_or(0) + offset + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

/// `SWIFTLY_FIXTURE_SEERR_SEASONS=1` adds season requests of the three kinds the status words tell apart (not yet
/// aired, up to date, searching); off by default so the counts of the other runs stay what they were.
fn season_requests() -> bool {
    std::env::var("SWIFTLY_FIXTURE_SEERR_SEASONS").is_ok_and(|v| v == "1")
}

fn catalogue() -> Vec<Def> {
    let film = |n: i64| Def {
        tmdb: 1000 + n,
        art: "movie",
        name: crate::fixture_server::NAMES[n as usize].to_string(),
        date: "2020-01-01",
        seasons: &[],
    };
    let movie = |tmdb, name: &str, date| Def {
        tmdb,
        art: "movie",
        name: name.to_string(),
        date,
        seasons: &[],
    };
    let mut defs = vec![
        film(0),
        film(1),
        film(2),
        film(3),
        film(4),
        Def {
            tmdb: 7777,
            art: "tv",
            name: "Küstenwache".into(),
            date: "2024-01-10",
            seasons: KUESTENWACHE_SEASONS,
        },
        movie(2001, "Nordstern", "2026-06-01"),
        movie(2002, "Nordwind", "2025-05-05"),
        movie(2003, "Nordwestpassage", "2025-08-08"),
        movie(2004, "Nordlandreise", "2026-11-28"),
        movie(2005, "Nordkap", "2024-04-04"),
        movie(2006, "Nordpol", "2023-03-03"),
        movie(2007, "Nordfeuer", "2025-12-12"),
        movie(2008, "Nordhafen", "2026-02-02"),
        Def {
            tmdb: 3001,
            art: "tv",
            name: "Nordsee-Krimi".into(),
            date: "2025-03-01",
            seasons: NORDSEE_SEASONS,
        },
        Def {
            tmdb: 3002,
            art: "tv",
            name: "Nordmeer".into(),
            date: "2024-02-02",
            seasons: NORDMEER_SEASONS,
        },
    ];
    if season_requests() {
        defs.push(Def {
            tmdb: 3003,
            art: "tv",
            name: "Sweet P".into(),
            date: "2024-05-01",
            seasons: SWEET_P_SEASONS,
        });
        defs.push(Def {
            tmdb: 3004,
            art: "tv",
            name: "TV Total".into(),
            date: "1999-03-08",
            seasons: TV_TOTAL_SEASONS,
        });
    }
    defs
}

fn media_id(tmdb: i64) -> i64 {
    match tmdb {
        7777 => 31,
        1000..=1004 => tmdb - 900,
        2001..=2008 => tmdb - 1800,
        3001 => 301,
        other => other,
    }
}

fn tmdb_of_media(id: i64) -> Option<i64> {
    catalogue()
        .iter()
        .map(|d| d.tmdb)
        .find(|t| media_id(*t) == id)
}

fn media(status: u8, seasons: &[(i64, u8)]) -> Media {
    Media {
        status,
        status4k: 1,
        seasons: seasons.iter().copied().collect(),
        queue: Vec::new(),
    }
}

impl World {
    fn new() -> Self {
        let role = if std::env::var("SWIFTLY_FIXTURE_SEERR_ROLE")
            .is_ok_and(|v| v.eq_ignore_ascii_case("admin"))
        {
            Role::Admin
        } else {
            Role::User
        };
        let mut m = BTreeMap::new();
        for n in 0..5 {
            m.insert(1000 + n, media(5, &[]));
        }
        // Küstenwache: S1 unknown, S2 in the library, S3 being fetched, S4 waiting (Lena), S5 unknown.
        let mut k = media(4, &[(2, 5), (3, 3), (4, 2)]);
        k.queue = (1..=2)
            .map(|_| Queue {
                season: Some(3),
                size: 500_000_000,
                left: 190_000_000,
                time_left: "00:20:00",
            })
            .collect();
        m.insert(7777, k);
        let mut nord = media(3, &[]);
        nord.queue.push(Queue {
            season: None,
            size: 1_000_000_000,
            left: 380_000_000,
            time_left: "00:12:03",
        });
        m.insert(2001, nord);
        m.insert(2003, media(1, &[]));
        m.insert(2004, media(3, &[]));
        m.insert(2005, media(6, &[]));
        m.insert(2006, media(7, &[]));
        m.insert(2007, media(3, &[]));
        m.insert(2008, media(2, &[]));
        m.insert(3001, media(2, &[(1, 2), (2, 2)]));
        if season_requests() {
            m.insert(3003, media(3, &[(1, 5)]));
            m.insert(3004, media(4, &[(22, 5)]));
            m.insert(3002, media(3, &[]));
        }
        let req = |id, tmdb, status, seasons: &[i64], user, counted| Req {
            id,
            tmdb,
            status,
            is4k: false,
            seasons: seasons.to_vec(),
            user,
            counted,
            modified_by: (status != 1).then_some(1),
        };
        let mut requests = vec![
            req(11, 2001, 2, &[], 2, 1),
            req(12, 3001, 1, &[1, 2], 2, 2),
            req(13, 2004, 2, &[], 2, 0),
            req(14, 2003, 3, &[], 2, 0),
            req(15, 2007, 4, &[], 2, 0),
            req(16, 7777, 1, &[4], 3, 0),
            req(17, 2008, 1, &[], 3, 0),
        ];
        if season_requests() {
            requests.push(req(18, 3003, 2, &[2], 2, 0));
            requests.push(req(19, 3004, 2, &[22], 2, 0));
            requests.push(req(20, 3002, 2, &[3], 2, 0));
        }
        let issues = vec![
            Issue {
                id: 1,
                kind: 3,
                status: 1,
                season: 2,
                episode: 3,
                tmdb: 7777,
                user: 3,
                comments: vec![(3, "Untertitel kommen zu früh · bei 23:14".into())],
            },
            Issue {
                id: 2,
                kind: 1,
                status: 2,
                season: 0,
                episode: 0,
                tmdb: 1000,
                user: 2,
                comments: vec![
                    (2, "Bild ruckelt".into()),
                    (1, "Neu eingelesen, sollte gehen.".into()),
                ],
            },
        ];
        Self {
            role,
            media: m,
            requests,
            issues,
            next_request: 100,
            next_issue: 10,
            next_comment: 500,
            movie_used: 1,
            tv_used: 2,
            gone: Vec::new(),
            library_gone: Vec::new(),
            fail_jellyfin: 0,
            sign_in_on: [true; 3],
            search_offline: true,
            search_down: false,
            log: Vec::new(),
        }
    }

    fn admin(&self) -> bool {
        self.role == Role::Admin
    }

    fn me(&self) -> i64 {
        if self.admin() { 1 } else { 2 }
    }
}

fn with_world<R>(f: impl FnOnce(&mut World) -> R) -> R {
    let mut guard = WORLD
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    f(guard.get_or_insert_with(World::new))
}

/// True when the Jellyfin library no longer shows this version (after a delete and a refresh);
/// only with `SWIFTLY_FIXTURE_SEERR_DELETE_JELLYFIN=1`.
pub fn library_hidden(tmdb: i64, is4k: bool) -> bool {
    std::env::var_os("SWIFTLY_FIXTURE_SEERR_DELETE_JELLYFIN").is_some()
        && with_world(|w| w.library_gone.contains(&(tmdb, is4k)))
}

// ---- tiny JSON helpers (the fixture has no JSON crate) ----

fn esc(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out
}

fn after_key<'a>(body: &'a str, key: &str) -> Option<&'a str> {
    let at = body.find(&format!("\"{key}\""))?;
    let rest = body[at + key.len() + 2..].trim_start();
    Some(rest.strip_prefix(':')?.trim_start())
}

fn jnum(body: &str, key: &str) -> Option<i64> {
    let rest = after_key(body, key)?;
    let end = rest
        .find(|c: char| !(c.is_ascii_digit() || c == '-'))
        .unwrap_or(rest.len());
    rest[..end].parse().ok()
}

fn jstr(body: &str, key: &str) -> Option<String> {
    let rest = after_key(body, key)?.strip_prefix('"')?;
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                other => out.push(other),
            },
            c => out.push(c),
        }
    }
    None
}

fn jbool(body: &str, key: &str) -> bool {
    after_key(body, key).is_some_and(|r| r.starts_with("true"))
}

/// `Some(list)` for `"key":[1,2]`, `None` for `"all"` or a missing key.
fn jlist(body: &str, key: &str) -> Option<Vec<i64>> {
    let rest = after_key(body, key)?.strip_prefix('[')?;
    let inner = &rest[..rest.find(']')?];
    Some(
        inner
            .split(',')
            .filter_map(|n| n.trim().parse().ok())
            .collect(),
    )
}

fn param(query: &str, key: &str) -> Option<String> {
    query.split('&').find_map(|p| {
        let (k, v) = p.split_once('=').unwrap_or((p, ""));
        (k == key).then(|| decode(v))
    })
}

fn decode(v: &str) -> String {
    let bytes = v.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
                if let Ok(b) = u8::from_str_radix(hex, 16) {
                    out.push(b);
                    i += 3;
                    continue;
                }
                out.push(b'%');
                i += 1;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ---- JSON of the world ----

fn user_json(id: i64) -> String {
    let (name, perms) = match id {
        1 => ("Admin", ADMIN),
        3 => ("Lena", USER_PERMS),
        _ => ("demo", USER_PERMS),
    };
    format!(
        r#"{{"id":{id},"displayName":"{name}","jellyfinUsername":"{}","email":"{}@example.test","permissions":{perms},"requestCount":3,"avatar":"/avatar{id}.png"}}"#,
        name.to_lowercase(),
        name.to_lowercase()
    )
}

fn queue_json(q: &Queue) -> String {
    let episode = q.season.map_or(String::new(), |s| {
        format!(r#","episode":{{"seasonNumber":{s},"episodeNumber":1}}"#)
    });
    format!(
        r#"{{"mediaType":"x","size":{},"sizeLeft":{},"status":"downloading","timeLeft":"{}","estimatedCompletionTime":"2026-11-14T12:00:00.000Z","title":"Release"{episode}}}"#,
        q.size, q.left, q.time_left
    )
}

fn media_json(w: &World, def: &Def, with_requests: bool) -> Option<String> {
    let m = w.media.get(&def.tmdb)?;
    let requests = if with_requests {
        w.requests
            .iter()
            .filter(|r| r.tmdb == def.tmdb)
            .map(|r| request_json(w, r, false))
            .collect::<Vec<_>>()
            .join(",")
    } else {
        String::new()
    };
    let seasons = m
        .seasons
        .iter()
        .map(|(n, s)| format!(r#"{{"seasonNumber":{n},"status":{s},"status4k":1}}"#))
        .collect::<Vec<_>>()
        .join(",");
    let queue = m.queue.iter().map(queue_json).collect::<Vec<_>>().join(",");
    Some(format!(
        r#"{{"id":{},"tmdbId":{},"mediaType":"{}","status":{},"status4k":{},"requests":[{requests}],"seasons":[{seasons}],"downloadStatus":[{queue}],"downloadStatus4k":[]}}"#,
        media_id(def.tmdb),
        def.tmdb,
        def.art,
        m.status,
        m.status4k
    ))
}

fn def_of(tmdb: i64) -> Option<Def> {
    catalogue().into_iter().find(|d| d.tmdb == tmdb)
}

fn request_json(w: &World, r: &Req, with_media: bool) -> String {
    let def = def_of(r.tmdb);
    let art = def.as_ref().map_or("movie", |d| d.art);
    let seasons = r
        .seasons
        .iter()
        .map(|n| {
            format!(
                r#"{{"id":{},"seasonNumber":{n},"status":{}}}"#,
                r.id * 10 + n,
                r.status
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    let media = if with_media {
        def.as_ref()
            .and_then(|d| media_json(w, d, false))
            .map_or(String::new(), |m| format!(r#","media":{m}"#))
    } else {
        String::new()
    };
    let modified = r.modified_by.map_or("null".to_string(), user_json);
    format!(
        r#"{{"id":{},"status":{},"type":"{art}","is4k":{},"createdAt":"2026-11-{:02}T10:00:00.000Z","updatedAt":"2026-11-{:02}T11:00:00.000Z","requestedBy":{},"modifiedBy":{modified},"seasons":[{seasons}]{media}}}"#,
        r.id,
        r.status,
        r.is4k,
        (r.id % 13) + 1,
        (r.id % 13) + 1,
        user_json(r.user)
    )
}

fn card(w: &World, d: &Def) -> String {
    let (name, when) = if d.art == "tv" {
        ("name", "firstAirDate")
    } else {
        ("title", "releaseDate")
    };
    let info = media_json(w, d, true).map_or(String::new(), |m| format!(r#","mediaInfo":{m}"#));
    format!(
        r#"{{"id":{id},"mediaType":"{art}","{name}":"{title}","{when}":"{date}","overview":"Ein Fixture-Titel.","voteAverage":7.2,"posterPath":"/p{id}.jpg","backdropPath":"/b{id}.jpg"{info}}}"#,
        id = d.tmdb,
        art = d.art,
        title = esc(&d.name),
        date = d.date
    )
}

fn page(cards: Vec<String>) -> String {
    format!(
        r#"{{"page":1,"totalPages":1,"totalResults":{},"results":[{}]}}"#,
        cards.len(),
        cards.join(",")
    )
}

fn cards_of(w: &World, tmdbs: &[i64]) -> Vec<String> {
    tmdbs
        .iter()
        .filter_map(|t| def_of(*t))
        .map(|d| card(w, &d))
        .collect()
}

fn detail(w: &World, d: &Def) -> String {
    let media = media_json(w, d, true).unwrap_or_else(|| "null".to_string());
    let credits = r#""credits":{"cast":[{"id":1234,"name":"Anna Test","character":"Hauptrolle","profilePath":"/anna.jpg"},{"id":5678,"name":"Carl Beispiel","character":"Nebenrolle","profilePath":"/carl.jpg"}]}"#;
    if d.art == "tv" {
        let seasons = d
            .seasons
            .iter()
            .map(|(n, date)| {
                let air = if date.is_empty() {
                    String::new()
                } else {
                    format!(r#","airDate":"{date}""#)
                };
                format!(r#"{{"seasonNumber":{n},"episodeCount":8,"name":"Staffel {n}"{air}}}"#)
            })
            .collect::<Vec<_>>()
            .join(",");
        format!(
            r#"{{"id":{},"name":"{}","overview":"Ein Fixture-Titel.","firstAirDate":"{}","genres":[{{"name":"Krimi"}},{{"name":"Drama"}}],"episodeRunTime":[45],"voteAverage":8.1,"status":"Returning Series","posterPath":"/p{0}.jpg","backdropPath":"/b{0}.jpg","seasons":[{{"seasonNumber":0,"episodeCount":2}},{seasons}],{credits},"mediaInfo":{media}}}"#,
            d.tmdb,
            esc(&d.name),
            d.date
        )
    } else {
        let collection = if d.tmdb == 2001 || d.tmdb == 1001 {
            r#","belongsToCollection":{"id":55,"name":"Nordstern-Reihe","posterPath":"/c55.jpg"}"#
        } else {
            ""
        };
        format!(
            r#"{{"id":{},"title":"{}","overview":"Ein Fixture-Titel.","releaseDate":"{}","genres":[{{"name":"Drama"}}],"runtime":101,"voteAverage":7.2,"status":"Released","posterPath":"/p{0}.jpg","backdropPath":"/b{0}.jpg",{credits}{collection},"mediaInfo":{media}}}"#,
            d.tmdb,
            esc(&d.name),
            d.date
        )
    }
}

fn issue_json(w: &World, i: &Issue) -> String {
    let media = def_of(i.tmdb)
        .and_then(|d| media_json(w, &d, false))
        .unwrap_or_else(|| "null".into());
    let comments = i
        .comments
        .iter()
        .enumerate()
        .map(|(n, (u, m))| {
            format!(
                r#"{{"id":{},"message":"{}","user":{},"createdAt":"2026-11-1{}T10:00:00.000Z"}}"#,
                i.id * 100 + n as i64,
                esc(m),
                user_json(*u),
                n % 10
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    format!(
        r#"{{"id":{},"issueType":{},"status":{},"problemSeason":{},"problemEpisode":{},"createdAt":"2026-11-10T10:00:00.000Z","media":{media},"createdBy":{},"comments":[{comments}]}}"#,
        i.id,
        i.kind,
        i.status,
        i.season,
        i.episode,
        user_json(i.user)
    )
}

fn quota_json(w: &World) -> String {
    if w.admin() {
        return r#"{"movie":{"used":0,"restricted":false},"tv":{"used":0,"restricted":false}}"#
            .into();
    }
    let part = |used: i64| {
        let left = (3 - used).max(0);
        format!(
            r#"{{"days":7,"limit":3,"used":{used},"remaining":{left},"restricted":{}}}"#,
            left == 0
        )
    };
    format!(
        r#"{{"movie":{},"tv":{}}}"#,
        part(w.movie_used),
        part(w.tv_used)
    )
}

// ---- answers ----

type Out = Option<(u16, String)>;

fn ok(body: String) -> Out {
    Some((200, body))
}

fn message(status: u16, text: &str) -> Out {
    Some((status, format!(r#"{{"message":"{}"}}"#, esc(text))))
}

fn no_permission() -> Out {
    message(403, "You do not have permission to make this request.")
}

/// The answer of one call. `None` = this module does not know the path (404).
fn handle(w: &mut World, method: &str, path: &str, query: &str, body: &str) -> Out {
    if let Some(rest) = path.strip_prefix("/__seerr/") {
        return control(w, method, rest, query);
    }
    w.log.push(format!(
        r#"{{"method":"{method}","path":"{}","query":"{}","body":{}}}"#,
        esc(path),
        esc(query),
        if body.trim_start().starts_with(['{', '[']) {
            body.trim().to_string()
        } else {
            format!("\"{}\"", esc(body))
        }
    ));
    if path == "/Library/Refresh" {
        if w.fail_jellyfin > 0 {
            w.fail_jellyfin -= 1;
            return message(500, "Jellyfin antwortet nicht");
        }
        w.library_gone = w.gone.clone();
        return Some((204, String::new()));
    }
    let rest = path.strip_prefix("/api/v1/")?;
    let segs: Vec<&str> = rest.split('/').filter(|s| !s.is_empty()).collect();
    api(w, method, &segs, query, body)
}

fn control(w: &mut World, method: &str, rest: &str, query: &str) -> Out {
    match (method, rest) {
        (_, "reset") => {
            *w = World::new();
            ok(r#"{"ok":true}"#.into())
        }
        (_, "role") => {
            w.role = if query.contains("admin") {
                Role::Admin
            } else {
                Role::User
            };
            ok(format!(
                r#"{{"role":"{}"}}"#,
                if w.admin() { "admin" } else { "user" }
            ))
        }
        (_, "log") => ok(format!(r#"{{"calls":[{}]}}"#, w.log.join(","))),
        (_, "fail") => {
            let times = param(query, "times")
                .and_then(|t| t.parse().ok())
                .unwrap_or(1);
            w.fail_jellyfin = if param(query, "step").as_deref() == Some("jellyfin") {
                times
            } else {
                0
            };
            ok(format!(r#"{{"failJellyfin":{}}}"#, w.fail_jellyfin))
        }
        // `POST /__seerr/arrive[?id=N]`: a request of the signed-in account for film 1001 (in both movie libraries)
        // that is approved and available now, i.e. something that "is here". The id lets a test use a fresh one,
        // because the app keeps closed banners per request id on the device.
        (_, "arrive") => {
            let id = param(query, "id")
                .and_then(|v| v.parse().ok())
                .unwrap_or(18);
            // `&tmdb=7777&season=2`: a finished request for one season of a series (the banner names the season).
            let tmdb = param(query, "tmdb")
                .and_then(|v| v.parse().ok())
                .unwrap_or(1001);
            let season: Option<i64> = param(query, "season").and_then(|v| v.parse().ok());
            let user = w.me();
            w.requests.retain(|r| r.id != id);
            w.requests.push(Req {
                id,
                tmdb,
                status: if season.is_some() { 5 } else { 2 },
                is4k: false,
                seasons: season.into_iter().collect(),
                user,
                counted: 0,
                modified_by: Some(1),
            });
            ok(format!(r#"{{"arrival":{id}}}"#))
        }
        // `POST /__seerr/clear`: the account has asked for nothing (the empty states).
        (_, "clear") => {
            w.requests.clear();
            ok(r#"{"ok":true}"#.into())
        }
        (_, "signin") => {
            for (i, name) in ["jellyfin", "local", "plex"].iter().enumerate() {
                match param(query, name).as_deref() {
                    Some("off") => w.sign_in_on[i] = false,
                    Some("on") => w.sign_in_on[i] = true,
                    _ => {}
                }
            }
            ok(format!(
                r#"{{"jellyfin":{},"local":{},"plex":{}}}"#,
                w.sign_in_on[0], w.sign_in_on[1], w.sign_in_on[2]
            ))
        }
        (_, "offline") => {
            w.search_down = true;
            ok(r#"{"ok":true}"#.into())
        }
        (_, "online") => {
            w.search_offline = false;
            w.search_down = false;
            ok(r#"{"ok":true}"#.into())
        }
        _ => None,
    }
}

/// `POST auth/jellyfin|local|plex`: the answers of a Seerr that takes the accounts named in the module doc.
fn sign_in(w: &World, way: &str, body: &str) -> Out {
    let (index, disabled) = match way {
        "jellyfin" => (0, "Jellyfin login is disabled"),
        "local" => (1, "Password sign-in is disabled."),
        _ => (2, "Plex login is disabled"),
    };
    if !w.sign_in_on[index] {
        return Some((500, format!(r#"{{"error":"{disabled}"}}"#)));
    }
    let right = match way {
        "jellyfin" => jstr(body, "password").as_deref() != Some("falsch"),
        "local" => {
            jstr(body, "email").as_deref() == Some("lena@example.com")
                && jstr(body, "password").as_deref() == Some("richtig")
        }
        _ => jstr(body, "authToken").as_deref() == Some("plex-ok"),
    };
    if right {
        ok(user_json(w.me()))
    } else if way == "jellyfin" {
        message(401, "Unauthorized")
    } else {
        message(403, "Access denied.")
    }
}

fn api(w: &mut World, method: &str, segs: &[&str], query: &str, body: &str) -> Out {
    let num = |i: usize| segs.get(i).and_then(|s| s.parse::<i64>().ok());
    match (method, segs) {
        ("POST", ["auth", way @ ("jellyfin" | "local" | "plex")]) => sign_in(w, way, body),
        ("GET", ["auth", "me"]) => ok(user_json(w.me())),
        ("GET", ["user", _, "quota"]) => ok(quota_json(w)),
        ("GET", ["settings", "public"]) => ok(r#"{"applicationTitle":"Fixture Seerr","movie4kEnabled":true,"series4kEnabled":true,"partialRequestsEnabled":true,"enableSpecialEpisodes":false,"hideAvailable":false,"hideBlocklisted":false,"mediaServerType":2}"#.into()),
        ("GET", ["settings", "discover"]) => ok(r#"[{"id":1,"type":2,"enabled":true},{"id":2,"type":4,"enabled":true},{"id":3,"type":5,"enabled":true},{"id":4,"type":9,"enabled":true},{"id":5,"type":7,"enabled":true},{"id":6,"type":3,"enabled":true},{"id":7,"type":6,"enabled":true}]"#.into()),
        ("GET", ["search"]) => search(w, &param(query, "query").unwrap_or_default()),
        ("GET", ["discover", rest @ ..]) => discover(w, rest),
        ("GET", [art @ ("movie" | "tv"), id, tail @ ..]) => {
            let id: i64 = id.parse().ok()?;
            title(w, art, id, tail)
        }
        ("GET", ["collection", "55"]) => ok(format!(
            r#"{{"id":55,"name":"Nordstern-Reihe","overview":"Zwei Filme.","posterPath":"/c55.jpg","backdropPath":"/c55b.jpg","parts":[{}]}}"#,
            cards_of(w, &[1001, 2001]).join(",")
        )),
        ("GET", ["person", id]) => {
            let (name, tmdb) = match *id {
                "1234" => ("Anna Test", 1234),
                "5678" => ("Carl Beispiel", 5678),
                "7" => ("Someone", 7),
                _ => return None,
            };
            ok(format!(
                r#"{{"id":{tmdb},"name":"{name}","biography":"Eine Person im Fixture.","birthday":"1980-05-01","knownForDepartment":"Acting","profilePath":"/person{tmdb}.jpg"}}"#
            ))
        }
        ("GET", ["person", id, "combined_credits"]) => {
            let ids: &[i64] = match *id {
                "1234" => &[1000, 1001, 2001, 2002, 7777],
                "5678" => &[1002, 2003],
                "7" => return legacy(method, "person/7/combined_credits"),
                _ => return None,
            };
            ok(format!(r#"{{"cast":[{}],"crew":[]}}"#, cards_of(w, ids).join(",")))
        }
        ("GET", ["service", kind]) if *kind == "radarr" || *kind == "sonarr" => ok(format!(
            r#"[{{"id":0,"name":"{kind}","isDefault":true,"is4k":false,"activeProfileId":4,"activeDirectory":"/media"}}]"#
        )),
        ("GET", ["service", kind, "0"]) if *kind == "radarr" || *kind == "sonarr" => ok(format!(
            r#"{{"server":{{"id":0,"name":"{kind}","isDefault":true,"activeProfileId":4,"activeDirectory":"/media"}},"profiles":[{{"id":4,"name":"HD-1080p"}},{{"id":5,"name":"Ultra-HD"}}],"rootFolders":[{{"path":"/media"}},{{"path":"/media2"}}],"tags":[{{"id":1,"label":"kinder"}}]}}"#
        )),
        ("GET", ["request"]) => request_list(w, query),
        ("GET", ["request", "count"]) => request_count(w),
        ("GET", ["request", _]) => {
            let r = w.requests.iter().find(|r| Some(r.id) == num(1))?;
            ok(request_json(w, r, true))
        }
        ("POST", ["request"]) => create_request(w, body),
        ("POST", ["request", _, verb @ ("approve" | "decline" | "retry")]) => {
            judge(w, num(1)?, verb)
        }
        ("DELETE", ["request", _]) => cancel_request(w, num(1)?),
        ("GET", ["issue"]) => issue_list(w, query),
        ("GET", ["issue", "count"]) => issue_count(w),
        ("GET", ["issue", _]) => {
            let i = visible_issues(w).into_iter().find(|i| Some(i.id) == num(1))?;
            ok(issue_json(w, &i))
        }
        ("POST", ["issue"]) => create_issue(w, body),
        ("POST", ["issue", _, verb @ ("comment" | "resolved" | "open")]) => {
            issue_verb(w, num(1)?, verb, body)
        }
        ("DELETE", ["media", _, "file"]) => delete_file(w, num(1)?, query),
        ("DELETE", ["media", _]) => delete_media(w, num(1)?),
        _ => legacy_post(method, segs),
    }
}

fn legacy(method: &str, key: &str) -> Out {
    let hit = |id: u32, art: &str, title: &str, date: &str, status: Option<u8>| {
        let name = if art == "tv" { "name" } else { "title" };
        let when = if art == "tv" {
            "firstAirDate"
        } else {
            "releaseDate"
        };
        let info = status.map_or(String::new(), |s| {
            format!(r#","mediaInfo":{{"status":{s}}}"#)
        });
        format!(
            r#"{{"id":{id},"mediaType":"{art}","{name}":"{title}","{when}":"{date}","posterPath":"/p{id}.jpg","backdropPath":"/b{id}.jpg"{info}}}"#
        )
    };
    let matrix = hit(603, "movie", "Matrix Fixture", "1999-03-30", None);
    let here = hit(77, "movie", "Already Here", "2001-01-01", Some(5));
    let deleted = hit(88, "movie", "Deleted One", "2002-02-02", Some(6));
    Some((200, match (method, key) {
        ("GET", "search") => format!(
            r#"{{"page":1,"results":[{matrix},{},{here},{deleted},{{"id":7,"mediaType":"person","name":"Someone"}}]}}"#,
            hit(1399, "tv", "Seerr Serie", "2011-04-17", Some(4))
        ),
        ("GET", "person/7/combined_credits") => format!(r#"{{"cast":[{matrix},{here}]}}"#),
        ("GET", "movie/603") => r#"{"overview":"A film.","genres":[{"name":"Action"},{"name":"Sci-Fi"}],"runtime":136,"voteAverage":8.2,"credits":{"cast":[{"id":6384,"name":"Keanu","character":"Neo","profilePath":"/k.jpg"},{"id":9,"name":"No Face"}]},"mediaInfo":{"status":3}}"#.into(),
        ("GET", "tv/1399") => r#"{"overview":"A series.","genres":[{"name":"Drama"}],"episodeRunTime":[55],"voteAverage":9.1,"seasons":[{"seasonNumber":0,"episodeCount":2},{"seasonNumber":1,"episodeCount":10},{"seasonNumber":2,"episodeCount":8}],"credits":{"cast":[{"id":1,"name":"Lead","character":"Hero"}]},"mediaInfo":{"status":4,"seasons":[{"seasonNumber":1,"status":5},{"seasonNumber":2,"status":1}]}}"#.into(),
        ("GET", "movie/603/recommendations" | "tv/1399/recommendations") => {
            format!(r#"{{"results":[{deleted},{here}]}}"#)
        }
        _ => return None,
    }))
}

/// The old stateless answers: a POST to `request` for a title the world does not know.
fn legacy_post(method: &str, segs: &[&str]) -> Out {
    legacy(method, &segs.join("/"))
}

fn search(w: &World, term: &str) -> Out {
    let t = term.trim().to_lowercase();
    if t == "zzzz" {
        return ok(page(Vec::new()));
    }
    if w.search_down || (t == "__off" && w.search_offline) {
        return message(503, "Seerr antwortet gerade nicht");
    }
    let key = if t == "__off" { "nord".to_string() } else { t };
    let mut results: Vec<String> = catalogue()
        .iter()
        .filter(|d| d.name.to_lowercase().contains(&key))
        .map(|d| card(w, d))
        .collect();
    if "nordstern-reihe".contains(&key) || "nordstern-reihe".starts_with(&key) && !key.is_empty() {
        results.push(r#"{"id":55,"mediaType":"collection","name":"Nordstern-Reihe","posterPath":"/c55.jpg","backdropPath":"/c55b.jpg"}"#.into());
    }
    for (id, name) in [
        (1234, "Anna Test"),
        (5678, "Carl Beispiel"),
        (9100, "Nordin Beispiel"),
    ] {
        if name.to_lowercase().contains(&key) {
            results.push(format!(
                r#"{{"id":{id},"mediaType":"person","name":"{name}","profilePath":"/person{id}.jpg","knownForDepartment":"Acting"}}"#
            ));
        }
    }
    if results.is_empty() {
        return legacy("GET", "search");
    }
    ok(page(results))
}

fn discover(w: &World, rest: &[&str]) -> Out {
    let movies = [1000, 1001, 1002, 2001, 2002, 2003, 2004, 2008];
    let tv = [7777, 3001];
    match rest {
        ["trending"] => ok(page(cards_of(w, &[7777, 2001, 1000, 2002, 3001, 2004]))),
        ["movies"] => ok(page(cards_of(w, &movies))),
        ["tv"] => ok(page(cards_of(w, &tv))),
        ["movies", "upcoming"] => ok(page(cards_of(w, &[2004, 2008]))),
        ["tv", "upcoming"] => ok(page(cards_of(w, &[3001]))),
        ["genreslider", _] => ok(r#"[{"id":18,"name":"Drama","backdrops":["/b7777.jpg","/b2001.jpg"]},{"id":80,"name":"Krimi","backdrops":["/b3001.jpg"]}]"#.into()),
        ["movies", ..] | ["keyword", ..] => ok(page(cards_of(w, &movies))),
        ["tv", ..] => ok(page(cards_of(w, &tv))),
        _ => None,
    }
}

fn title(w: &World, art: &str, id: i64, tail: &[&str]) -> Out {
    let Some(d) = def_of(id).filter(|d| d.art == art) else {
        return legacy(
            "GET",
            &format!(
                "{art}/{id}{}",
                tail.iter().map(|t| format!("/{t}")).collect::<String>()
            ),
        );
    };
    match tail {
        [] => ok(detail(w, &d)),
        ["season", n] => {
            let n: i64 = n.parse().ok()?;
            let date = d.seasons.iter().find(|s| s.0 == n)?.1;
            let date = if date.is_empty() { "2026-09-01" } else { date };
            ok(format!(
                r#"{{"seasonNumber":{n},"name":"Staffel {n}","airDate":"{date}","episodes":{}}}"#,
                episodes_json(id, n)
            ))
        }
        ["recommendations"] => {
            let ids: &[i64] = if art == "tv" {
                &[3001, 7777]
            } else {
                &[2001, 2002, 2004, 1000]
            };
            ok(page(cards_of(
                w,
                &ids.iter().copied().filter(|t| *t != id).collect::<Vec<_>>(),
            )))
        }
        ["similar"] => {
            let ids: &[i64] = if art == "tv" {
                &[7777, 3001]
            } else {
                &[2003, 2008, 1001]
            };
            ok(page(cards_of(
                w,
                &ids.iter().copied().filter(|t| *t != id).collect::<Vec<_>>(),
            )))
        }
        _ => None,
    }
}

// ---- requests ----

fn visible_requests(w: &World) -> Vec<Req> {
    w.requests
        .iter()
        .filter(|r| w.admin() || r.user == w.me())
        .cloned()
        .collect()
}

fn request_list(w: &World, query: &str) -> Out {
    let take: usize = param(query, "take")
        .and_then(|v| v.parse().ok())
        .unwrap_or(20);
    let skip: usize = param(query, "skip")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let filter = param(query, "filter").unwrap_or_else(|| "all".into());
    let by: Option<i64> = param(query, "requestedBy").and_then(|v| v.parse().ok());
    let kind = param(query, "mediaType").filter(|k| k == "movie" || k == "tv");
    let mut list: Vec<Req> = visible_requests(w)
        .into_iter()
        .filter(|r| by.is_none_or(|u| r.user == u))
        .filter(|r| {
            kind.as_deref()
                .is_none_or(|k| def_of(r.tmdb).is_some_and(|d| d.art == k))
        })
        .filter(|r| match filter.as_str() {
            "pending" => r.status == 1,
            "approved" | "processing" => r.status == 2,
            "declined" => r.status == 3,
            "failed" => r.status == 4,
            "available" | "completed" => r.status == 5,
            "unavailable" => r.status == 1 || r.status == 2,
            "deleted" => w.media.get(&r.tmdb).is_some_and(|m| m.status == 7),
            _ => true,
        })
        .collect();
    list.sort_by_key(|r| std::cmp::Reverse(r.id));
    let total = list.len();
    let pages = total.div_ceil(take.max(1)).max(1);
    let rows = list
        .iter()
        .skip(skip)
        .take(take)
        .map(|r| request_json(w, r, true))
        .collect::<Vec<_>>()
        .join(",");
    ok(format!(
        r#"{{"pageInfo":{{"pages":{pages},"pageSize":{take},"results":{total},"page":{}}},"results":[{rows}]}}"#,
        skip / take.max(1) + 1
    ))
}

fn request_count(w: &World) -> Out {
    let list = visible_requests(w);
    let n = |f: &dyn Fn(&Req) -> bool| list.iter().filter(|r| f(r)).count();
    let kind = |k: &str| n(&|r| def_of(r.tmdb).is_some_and(|d| d.art == k));
    ok(format!(
        r#"{{"total":{},"movie":{},"tv":{},"pending":{},"approved":{},"declined":{},"processing":{},"available":{},"completed":{}}}"#,
        list.len(),
        kind("movie"),
        kind("tv"),
        n(&|r| r.status == 1),
        n(&|r| r.status == 2),
        n(&|r| r.status == 3),
        n(&|r| r.status == 2),
        n(&|r| r.status == 5),
        n(&|r| r.status == 5)
    ))
}

fn live(r: &Req) -> bool {
    r.status == 1 || r.status == 2
}

fn create_request(w: &mut World, body: &str) -> Out {
    let (Some(tmdb), Some(art)) = (jnum(body, "mediaId"), jstr(body, "mediaType")) else {
        return message(400, "mediaType and mediaId are required.");
    };
    let Some(def) = def_of(tmdb).filter(|d| d.art == art) else {
        return Some((200, r#"{"id":1,"status":1}"#.into()));
    };
    let is4k = jbool(body, "is4k");
    if !w.admin() && is4k {
        return no_permission();
    }
    let lane_status = w
        .media
        .get(&tmdb)
        .map_or(1, |m| if is4k { m.status4k } else { m.status });
    if lane_status == 6 {
        return message(403, "This title is blocklisted and cannot be requested.");
    }
    let wanted: Vec<i64> = if art == "tv" {
        jlist(body, "seasons").unwrap_or_else(|| def.seasons.iter().map(|s| s.0).collect())
    } else {
        Vec::new()
    };
    let me = w.me();
    let mut seasons = Vec::new();
    if art == "tv" {
        let taken = |n: i64, w: &World| {
            w.requests
                .iter()
                .any(|r| r.tmdb == tmdb && r.is4k == is4k && live(r) && r.seasons.contains(&n))
        };
        let available = |n: i64, w: &World| {
            w.media
                .get(&tmdb)
                .and_then(|m| m.seasons.get(&n))
                .is_some_and(|s| *s == 5)
        };
        if wanted.iter().any(|n| taken(*n, w))
            && !jlist(body, "seasons").is_none_or(|l| l.is_empty())
        {
            return message(409, "Request for this media already exists.");
        }
        seasons = wanted
            .into_iter()
            .filter(|n| !taken(*n, w) && !available(*n, w))
            .collect();
        if seasons.is_empty() {
            return message(202, "No seasons available to request");
        }
    } else if w
        .requests
        .iter()
        .any(|r| r.tmdb == tmdb && r.is4k == is4k && live(r))
        || lane_status == 5
    {
        return message(409, "Request for this media already exists.");
    }
    let need = if art == "tv" { seasons.len() as i64 } else { 1 };
    if !w.admin() {
        let used = if art == "tv" { w.tv_used } else { w.movie_used };
        if 3 - used < need {
            return message(
                403,
                if art == "tv" {
                    "Series Quota exceeded."
                } else {
                    "Movie Quota exceeded."
                },
            );
        }
        if art == "tv" {
            w.tv_used += need;
        } else {
            w.movie_used += need;
        }
    }
    let status = if w.admin() { 2 } else { 1 };
    let id = w.next_request;
    w.next_request += 1;
    w.requests.push(Req {
        id,
        tmdb,
        status,
        is4k,
        seasons: seasons.clone(),
        user: me,
        counted: if w.admin() { 0 } else { need },
        modified_by: (status == 2).then_some(1),
    });
    let m = w.media.entry(tmdb).or_insert_with(|| media(1, &[]));
    let lane = if is4k { &mut m.status4k } else { &mut m.status };
    if *lane == 1 || *lane == 7 {
        *lane = if status == 2 { 3 } else { 2 };
    }
    for n in seasons {
        let s = m.seasons.entry(n).or_insert(1);
        if *s == 1 || *s == 7 {
            *s = if status == 2 { 3 } else { 2 };
        }
    }
    let r = w.requests.last()?;
    Some((201, request_json(w, r, true)))
}

fn restore_media(w: &mut World, tmdb: i64, is4k: bool, seasons: &[i64]) {
    let others = w
        .requests
        .iter()
        .any(|r| r.tmdb == tmdb && r.is4k == is4k && live(r));
    if let Some(m) = w.media.get_mut(&tmdb) {
        for n in seasons {
            let still = w
                .requests
                .iter()
                .any(|r| r.tmdb == tmdb && live(r) && r.seasons.contains(n));
            if !still && m.seasons.get(n).is_some_and(|s| *s == 2 || *s == 3) {
                m.seasons.insert(*n, 1);
            }
        }
        let lane = if is4k { &mut m.status4k } else { &mut m.status };
        if !others && (*lane == 2 || *lane == 3) {
            *lane = 1;
        }
    }
}

fn judge(w: &mut World, id: i64, verb: &str) -> Out {
    if !w.admin() {
        return message(403, "You do not have permission to manage requests.");
    }
    let r = w.requests.iter().find(|r| r.id == id)?.clone();
    let wanted = if verb == "retry" { 4 } else { 1 };
    if r.status != wanted {
        return message(
            409,
            if verb == "retry" {
                "This request has not failed."
            } else {
                "This request is not pending."
            },
        );
    }
    let new = if verb == "decline" { 3 } else { 2 };
    if let Some(x) = w.requests.iter_mut().find(|x| x.id == id) {
        x.status = new;
        x.modified_by = Some(1);
    }
    if new == 2 {
        if let Some(m) = w.media.get_mut(&r.tmdb) {
            let lane = if r.is4k {
                &mut m.status4k
            } else {
                &mut m.status
            };
            if *lane != 5 && *lane != 4 {
                *lane = 3;
            }
            for n in &r.seasons {
                m.seasons.insert(*n, 3);
            }
        }
    } else {
        restore_media(w, r.tmdb, r.is4k, &r.seasons);
    }
    let r = w.requests.iter().find(|r| r.id == id)?;
    ok(request_json(w, r, true))
}

fn cancel_request(w: &mut World, id: i64) -> Out {
    let r = w.requests.iter().find(|r| r.id == id)?.clone();
    if !w.admin() && (r.user != w.me() || r.status != 1) {
        return no_permission();
    }
    w.requests.retain(|x| x.id != id);
    if def_of(r.tmdb).is_some_and(|d| d.art == "tv") {
        w.tv_used = (w.tv_used - r.counted).max(0);
    } else {
        w.movie_used = (w.movie_used - r.counted).max(0);
    }
    restore_media(w, r.tmdb, r.is4k, &r.seasons);
    Some((204, String::new()))
}

// ---- issues ----

fn visible_issues(w: &World) -> Vec<Issue> {
    w.issues
        .iter()
        .filter(|i| w.admin() || i.user == w.me())
        .cloned()
        .collect()
}

fn issue_list(w: &World, query: &str) -> Out {
    let take: usize = param(query, "take")
        .and_then(|v| v.parse().ok())
        .unwrap_or(20);
    let skip: usize = param(query, "skip")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let filter = param(query, "filter").unwrap_or_else(|| "all".into());
    let by: Option<i64> = param(query, "requestedBy").and_then(|v| v.parse().ok());
    let mut list: Vec<Issue> = visible_issues(w)
        .into_iter()
        .filter(|i| by.is_none_or(|u| i.user == u))
        .filter(|i| match filter.as_str() {
            "open" => i.status == 1,
            "resolved" => i.status == 2,
            _ => true,
        })
        .collect();
    list.sort_by_key(|i| std::cmp::Reverse(i.id));
    let total = list.len();
    let rows = list
        .iter()
        .skip(skip)
        .take(take)
        .map(|i| issue_json(w, i))
        .collect::<Vec<_>>()
        .join(",");
    ok(format!(
        r#"{{"pageInfo":{{"pages":{},"pageSize":{take},"results":{total},"page":{}}},"results":[{rows}]}}"#,
        total.div_ceil(take.max(1)).max(1),
        skip / take.max(1) + 1
    ))
}

fn issue_count(w: &World) -> Out {
    let list = visible_issues(w);
    let n = |f: &dyn Fn(&Issue) -> bool| list.iter().filter(|i| f(i)).count();
    ok(format!(
        r#"{{"total":{},"video":{},"audio":{},"subtitles":{},"others":{},"open":{},"closed":{}}}"#,
        list.len(),
        n(&|i| i.kind == 1),
        n(&|i| i.kind == 2),
        n(&|i| i.kind == 3),
        n(&|i| i.kind == 4),
        n(&|i| i.status == 1),
        n(&|i| i.status == 2)
    ))
}

fn create_issue(w: &mut World, body: &str) -> Out {
    let (Some(kind), Some(mid), Some(text)) = (
        jnum(body, "issueType"),
        jnum(body, "mediaId"),
        jstr(body, "message"),
    ) else {
        return message(400, "issueType, mediaId and message are required.");
    };
    let Some(tmdb) = tmdb_of_media(mid) else {
        return message(404, "Media not found.");
    };
    let id = w.next_issue;
    w.next_issue += 1;
    let me = w.me();
    w.issues.push(Issue {
        id,
        kind,
        status: 1,
        season: jnum(body, "problemSeason").unwrap_or(0),
        episode: jnum(body, "problemEpisode").unwrap_or(0),
        tmdb,
        user: me,
        comments: vec![(me, text)],
    });
    let i = w.issues.last()?;
    Some((201, issue_json(w, i)))
}

fn issue_verb(w: &mut World, id: i64, verb: &str, body: &str) -> Out {
    if verb != "comment" && !w.admin() {
        return message(403, "You do not have permission to manage issues.");
    }
    let me = w.me();
    let visible = visible_issues(w).iter().any(|i| i.id == id);
    if !visible {
        return None;
    }
    w.next_comment += 1;
    let text = jstr(body, "message");
    let issue = w.issues.iter_mut().find(|i| i.id == id)?;
    match verb {
        "comment" => issue.comments.push((me, text.unwrap_or_default())),
        "resolved" => issue.status = 2,
        _ => issue.status = 1,
    }
    let i = w.issues.iter().find(|i| i.id == id)?;
    ok(issue_json(w, i))
}

// ---- delete ----

fn delete_file(w: &mut World, mid: i64, query: &str) -> Out {
    if !w.admin() {
        return message(403, "You do not have permission to manage media.");
    }
    let is4k = param(query, "is4k").is_some_and(|v| v == "true");
    let tmdb = tmdb_of_media(mid)?;
    if let Some(m) = w.media.get_mut(&tmdb) {
        if is4k {
            m.status4k = 7;
        } else {
            m.status = 7;
            m.seasons.values_mut().for_each(|s| *s = 7);
            m.queue.clear();
        }
    }
    w.gone.push((tmdb, is4k));
    Some((204, String::new()))
}

fn delete_media(w: &mut World, mid: i64) -> Out {
    if !w.admin() {
        return message(403, "You do not have permission to manage media.");
    }
    if let Some(tmdb) = tmdb_of_media(mid) {
        w.media.remove(&tmdb);
        w.requests.retain(|r| r.tmdb != tmdb);
    }
    Some((204, String::new()))
}

/// The Seerr (and Jellyfin refresh) answer for one call, or `None` for a path it does not know.
pub fn answer(method: &str, path: &str, query: &str, body: &str) -> Option<Reply> {
    if path.starts_with("/t/p/") {
        return Some(tmdb_picture(path));
    }
    let (status, text) = with_world(|w| handle(w, method, path, query, body))?;
    Some(if status == 204 {
        Reply(204, "text/plain", Vec::new())
    } else {
        Reply(status, "application/json", text.into_bytes())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nordmeer_lists_episodes_with_pictures_and_other_series_none() {
        let mut w = World::new();
        let (status, body) =
            handle(&mut w, "GET", "/api/v1/tv/3002/season/1", "", "").expect("season answer");
        assert_eq!(status, 200);
        assert_eq!(body.matches(r#""episodeNumber":"#).count(), 6);
        assert!(body.contains(r#""stillPath":"/s300211.jpg""#));
        assert!(
            body.contains(r#""stillPath":null"#),
            "one episode has no still"
        );
        assert!(
            body.contains(r#""overview":"""#),
            "one episode has no story"
        );
        assert!(body.contains("Die lange Nacht"));
        let (_, third) =
            handle(&mut w, "GET", "/api/v1/tv/3002/season/3", "", "").expect("season 3");
        assert_eq!(third.matches(r#""episodeNumber":"#).count(), 3);
        let (_, other) = handle(&mut w, "GET", "/api/v1/tv/3001/season/1", "", "").expect("other");
        assert!(other.contains(r#""episodes":[]"#));
        // The pictures the page's finished URLs point at: a 16:9 still, a 2:3 poster, a square cast head.
        for (path, (w, h)) in [
            ("/t/p/w300/s300211.jpg", (300, 168)),
            ("/t/p/w342/p3002.jpg", (342, 513)),
            ("/t/p/w185/c7.jpg", (185, 185)),
        ] {
            assert!(handles(path));
            let Reply(code, kind, data) = answer("GET", path, "", "").expect("picture");
            assert_eq!((code, kind), (200, "image/png"));
            let reader = png::Decoder::new(std::io::Cursor::new(data))
                .read_info()
                .expect("png");
            assert_eq!(
                (reader.info().width, reader.info().height),
                (w, h),
                "{path}"
            );
        }
    }

    /// One call against a private world (the global one is shared by the running server).
    fn call(w: &mut World, method: &str, target: &str, body: &str) -> (u16, String) {
        let (path, query) = target.split_once('?').unwrap_or((target, ""));
        handle(w, method, path, query, body).unwrap_or((404, String::new()))
    }

    fn fresh(role: Role) -> World {
        let mut w = World::new();
        w.role = role;
        w
    }

    #[test]
    fn sign_in_ways_answer_like_seerr() {
        let mut w = fresh(Role::User);
        let post = |w: &mut World, way: &str, body: &str| {
            call(w, "POST", &format!("/api/v1/auth/{way}"), body)
        };
        assert_eq!(
            post(&mut w, "jellyfin", r#"{"username":"lena","password":"x"}"#).0,
            200
        );
        assert_eq!(
            post(
                &mut w,
                "jellyfin",
                r#"{"username":"lena","password":"falsch"}"#
            )
            .0,
            401
        );
        assert_eq!(
            post(
                &mut w,
                "local",
                r#"{"email":"lena@example.com","password":"richtig"}"#
            )
            .0,
            200
        );
        let (s, body) = post(
            &mut w,
            "local",
            r#"{"email":"lena@example.com","password":"falsch"}"#,
        );
        assert_eq!((s, body.contains("Access denied")), (403, true));
        assert_eq!(post(&mut w, "plex", r#"{"authToken":"plex-ok"}"#).0, 200);
        assert_eq!(post(&mut w, "plex", r#"{"authToken":"alt"}"#).0, 403);
        call(&mut w, "POST", "/__seerr/signin?jellyfin=off&local=off", "");
        let (s, body) = post(&mut w, "jellyfin", r#"{"username":"lena","password":"x"}"#);
        assert_eq!((s, body.contains("disabled")), (500, true));
        assert_eq!(
            post(
                &mut w,
                "local",
                r#"{"email":"lena@example.com","password":"richtig"}"#
            )
            .0,
            500
        );
        assert_eq!(post(&mut w, "plex", r#"{"authToken":"plex-ok"}"#).0, 200);
        call(&mut w, "POST", "/__seerr/signin?jellyfin=on", "");
        assert_eq!(
            post(&mut w, "jellyfin", r#"{"username":"lena","password":"x"}"#).0,
            200
        );
    }

    #[test]
    fn me_and_quota_by_role() {
        let mut w = fresh(Role::User);
        let (s, me) = call(&mut w, "GET", "/api/v1/auth/me", "");
        assert_eq!(s, 200);
        assert!(me.contains(r#""id":2"#) && me.contains(&format!(r#""permissions":{USER_PERMS}"#)));
        let (_, q) = call(&mut w, "GET", "/api/v1/user/2/quota", "");
        assert!(
            q.contains(r#""tv":{"days":7,"limit":3,"used":2,"remaining":1,"restricted":false}"#),
            "{q}"
        );
        assert!(
            q.contains(r#""movie":{"days":7,"limit":3,"used":1,"remaining":2"#),
            "{q}"
        );
        w.role = Role::Admin;
        let (_, me) = call(&mut w, "GET", "/api/v1/auth/me", "");
        assert!(me.contains(r#""permissions":2"#));
        let (_, q) = call(&mut w, "GET", "/api/v1/user/1/quota", "");
        assert!(!q.contains("limit"), "{q}");
    }

    #[test]
    fn request_uses_up_the_quota_then_refuses_with_403() {
        let mut w = fresh(Role::User);
        let (s, r) = call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"tv","mediaId":7777,"seasons":[5]}"#,
        );
        assert_eq!(s, 201, "{r}");
        assert!(r.contains(r#""status":1"#) && r.contains(r#""seasonNumber":5"#));
        // The next read shows the new state: S5 waits and the quota is spent.
        let (_, t) = call(&mut w, "GET", "/api/v1/tv/7777", "");
        assert!(
            t.contains(r#"{"seasonNumber":5,"status":2,"status4k":1}"#),
            "{t}"
        );
        let (_, q) = call(&mut w, "GET", "/api/v1/user/2/quota", "");
        assert!(
            q.contains(r#""tv":{"days":7,"limit":3,"used":3,"remaining":0,"restricted":true}"#),
            "{q}"
        );
        // S1 now: quota exceeded, with the server's text.
        let (s, e) = call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"tv","mediaId":7777,"seasons":[1]}"#,
        );
        assert_eq!(
            (s, e.as_str()),
            (403, r#"{"message":"Series Quota exceeded."}"#)
        );
        // Withdrawing the pending request gives the quota back.
        let id = r
            .split(r#""id":"#)
            .nth(1)
            .and_then(|r| r.split(',').next())
            .unwrap_or("0")
            .to_string();
        let (s, _) = call(&mut w, "DELETE", &format!("/api/v1/request/{id}"), "");
        assert_eq!(s, 204);
        let (_, q) = call(&mut w, "GET", "/api/v1/user/2/quota", "");
        assert!(q.contains(r#""used":2,"remaining":1"#), "{q}");
    }

    #[test]
    fn duplicate_blocked_and_four_k() {
        let mut w = fresh(Role::User);
        let (s, _) = call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"movie","mediaId":2008}"#,
        );
        assert_eq!(s, 409);
        let (s, e) = call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"movie","mediaId":2005}"#,
        );
        assert_eq!(s, 403);
        assert!(e.contains("blocklisted"), "{e}");
        let (s, _) = call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"movie","mediaId":2002,"is4k":true}"#,
        );
        assert_eq!(s, 403);
        let (s, _) = call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"movie","mediaId":2002}"#,
        );
        assert_eq!(s, 201);
        let (s, _) = call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"movie","mediaId":2006}"#,
        );
        assert_eq!(s, 201, "a deleted title can be asked for again");
        let (s, e) = call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"movie","mediaId":2003}"#,
        );
        assert_eq!(s, 403, "movie quota 3 of 3 is used now: {e}");
        assert!(e.contains("Movie Quota exceeded"), "{e}");
    }

    #[test]
    fn admin_requests_are_approved_at_once() {
        let mut w = fresh(Role::Admin);
        let (s, r) = call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"movie","mediaId":2002,"is4k":false}"#,
        );
        assert_eq!(s, 201);
        assert!(r.contains(r#""status":2"#));
        let (_, m) = call(&mut w, "GET", "/api/v1/movie/2002", "");
        assert!(m.contains(r#""status":3,"status4k":1"#), "{m}");
        let (s, _) = call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"tv","mediaId":7777,"seasons":[4]}"#,
        );
        assert_eq!(s, 409, "S4 already waits");
        let (s, _) = call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"tv","mediaId":7777,"seasons":[2]}"#,
        );
        assert_eq!(s, 202, "S2 is in the library");
    }

    #[test]
    fn lists_by_role_and_filter() {
        let mut w = fresh(Role::User);
        let (_, mine) = call(
            &mut w,
            "GET",
            "/api/v1/request?take=20&skip=0&filter=all",
            "",
        );
        assert_eq!(mine.matches(r#""requestedBy""#).count(), 5, "{mine}");
        let (_, c) = call(&mut w, "GET", "/api/v1/request/count", "");
        assert!(
            c.contains(r#""total":5"#) && c.contains(r#""pending":1"#),
            "{c}"
        );
        w.role = Role::Admin;
        let (_, all) = call(&mut w, "GET", "/api/v1/request?filter=all", "");
        assert_eq!(all.matches(r#""requestedBy""#).count(), 7);
        let (_, pend) = call(
            &mut w,
            "GET",
            "/api/v1/request?filter=pending&take=2&skip=0",
            "",
        );
        assert_eq!(pend.matches(r#""requestedBy""#).count(), 2);
        assert!(
            pend.contains(r#""results":3"#) && pend.contains(r#""pages":2"#),
            "{pend}"
        );
        let (_, c) = call(&mut w, "GET", "/api/v1/request/count", "");
        assert!(c.contains(r#""pending":3"#), "{c}");
    }

    #[test]
    fn approve_decline_retry_and_rights() {
        let mut w = fresh(Role::User);
        let (s, e) = call(&mut w, "POST", "/api/v1/request/12/approve", "");
        assert_eq!(s, 403, "{e}");
        w.role = Role::Admin;
        let (s, r) = call(&mut w, "POST", "/api/v1/request/12/approve", "");
        assert_eq!(s, 200);
        assert!(r.contains(r#""status":2"#));
        let (s, _) = call(&mut w, "POST", "/api/v1/request/12/approve", "");
        assert_eq!(s, 409, "not pending any more");
        let (s, r) = call(&mut w, "POST", "/api/v1/request/17/decline", "");
        assert_eq!((s, r.contains(r#""status":3"#)), (200, true));
        let (_, m) = call(&mut w, "GET", "/api/v1/movie/2008", "");
        assert!(
            m.contains(r#""mediaInfo":{"id":208,"tmdbId":2008,"mediaType":"movie","status":1"#),
            "{m}"
        );
        let (s, r) = call(&mut w, "POST", "/api/v1/request/15/retry", "");
        assert_eq!((s, r.contains(r#""status":2"#)), (200, true));
        assert_eq!(call(&mut w, "POST", "/api/v1/request/15/retry", "").0, 409);
    }

    #[test]
    fn issues_create_comment_resolve() {
        let mut w = fresh(Role::User);
        let (_, c) = call(&mut w, "GET", "/api/v1/issue/count", "");
        assert!(
            c.contains(r#""total":1"#) && c.contains(r#""open":0"#),
            "own issues only: {c}"
        );
        let (s, i) = call(
            &mut w,
            "POST",
            "/api/v1/issue",
            r#"{"issueType":3,"message":"Ton fehlt · bei 12:30","mediaId":31,"problemSeason":2,"problemEpisode":3}"#,
        );
        assert_eq!(s, 201, "{i}");
        assert!(i.contains(r#""problemSeason":2"#) && i.contains("bei 12:30"));
        assert_eq!(call(&mut w, "POST", "/api/v1/issue/10/resolved", "").0, 403);
        let (s, i) = call(
            &mut w,
            "POST",
            "/api/v1/issue/10/comment",
            r#"{"message":"Danke"}"#,
        );
        assert_eq!(s, 200);
        assert!(i.contains("Danke"));
        w.role = Role::Admin;
        let (_, c) = call(&mut w, "GET", "/api/v1/issue/count", "");
        assert!(
            c.contains(r#""total":3"#) && c.contains(r#""open":2"#),
            "{c}"
        );
        let (s, i) = call(&mut w, "POST", "/api/v1/issue/10/resolved", "");
        assert_eq!((s, i.contains(r#""status":2"#)), (200, true));
        let (_, c) = call(&mut w, "GET", "/api/v1/issue/count", "");
        assert!(c.contains(r#""open":1"#), "{c}");
        let (_, open) = call(&mut w, "GET", "/api/v1/issue?filter=open", "");
        assert_eq!(open.matches(r#""createdBy""#).count(), 1);
        let (_, one) = call(&mut w, "GET", "/api/v1/issue/1", "");
        assert!(one.contains("bei 23:14") && one.contains(r#""problemEpisode":3"#));
    }

    #[test]
    fn delete_flow_and_failing_refresh() {
        let mut w = fresh(Role::User);
        assert_eq!(
            call(&mut w, "DELETE", "/api/v1/media/100/file?is4k=false", "").0,
            403
        );
        w.role = Role::Admin;
        assert_eq!(
            call(&mut w, "DELETE", "/api/v1/media/100/file?is4k=false", "").0,
            204
        );
        let (_, m) = call(&mut w, "GET", "/api/v1/movie/1000", "");
        assert!(m.contains(r#""status":7,"status4k":1"#), "{m}");
        assert!(
            w.library_gone.is_empty(),
            "the library only changes on a refresh"
        );
        call(&mut w, "POST", "/__seerr/fail?step=jellyfin", "");
        assert_eq!(call(&mut w, "POST", "/Library/Refresh", "").0, 500);
        assert_eq!(call(&mut w, "POST", "/Library/Refresh", "").0, 204);
        assert_eq!(w.library_gone, vec![(1000, false)]);
        assert_eq!(call(&mut w, "DELETE", "/api/v1/media/100", "").0, 204);
        let (_, m) = call(&mut w, "GET", "/api/v1/movie/1000", "");
        assert!(m.contains(r#""mediaInfo":null"#), "{m}");
        // The log names every call, in order, for the checks.
        let (_, log) = call(&mut w, "GET", "/__seerr/log", "");
        assert_eq!(log.matches(r#""method":"DELETE""#).count(), 3, "{log}");
        assert_eq!(log.matches("/Library/Refresh").count(), 2);
    }

    #[test]
    fn search_words_and_states() {
        let mut w = fresh(Role::User);
        let (_, r) = call(&mut w, "GET", "/api/v1/search?query=nord&page=1", "");
        for id in [
            "2001", "2002", "2003", "2004", "2005", "2006", "2007", "2008", "3001", "1000",
        ] {
            assert!(
                r.contains(&format!(r#""id":{id},"mediaType""#)),
                "{id} in {r}"
            );
        }
        assert!(r.contains(r#""mediaType":"person""#) && r.contains(r#""mediaType":"collection""#));
        assert!(r.contains(r#""status":6"#) && r.contains(r#""releaseDate":"2026-11-28""#));
        assert!(r.contains(r#""sizeLeft":380000000"#));
        let (_, none) = call(&mut w, "GET", "/api/v1/search?query=zzzz", "");
        assert!(none.contains(r#""results":[]"#), "{none}");
        let (s, _) = call(&mut w, "GET", "/api/v1/search?query=__off", "");
        assert_eq!(s, 503);
        call(&mut w, "POST", "/__seerr/online", "");
        let (s, back) = call(&mut w, "GET", "/api/v1/search?query=__off", "");
        assert_eq!(s, 200);
        assert!(back.contains(r#""id":2001"#));
        // A term of the old Android comparisons still gets the old list.
        let (_, old) = call(&mut w, "GET", "/api/v1/search?query=whatever", "");
        assert!(old.contains("Matrix Fixture") && old.contains("Deleted One"));
    }

    #[test]
    fn old_routes_keep_their_answers() {
        let mut w = fresh(Role::User);
        let (s, a) = call(&mut w, "GET", "/api/v1/movie/603", "");
        assert_eq!(s, 200);
        assert!(a.starts_with(r#"{"overview":"A film.""#));
        assert!(
            call(&mut w, "GET", "/api/v1/tv/1399", "")
                .1
                .contains(r#""seasonNumber":2,"status":1"#)
        );
        assert!(
            call(&mut w, "GET", "/api/v1/movie/603/recommendations", "")
                .1
                .contains("Already Here")
        );
        assert!(
            call(&mut w, "GET", "/api/v1/person/7/combined_credits", "")
                .1
                .contains("Matrix Fixture")
        );
        assert_eq!(
            call(
                &mut w,
                "POST",
                "/api/v1/request",
                r#"{"mediaType":"movie","mediaId":603}"#
            ),
            (200, r#"{"id":1,"status":1}"#.into())
        );
        assert_eq!(call(&mut w, "GET", "/api/v1/nope", "").0, 404);
    }

    #[test]
    fn titles_and_people_anchor_on_the_library() {
        let mut w = fresh(Role::User);
        let (_, k) = call(&mut w, "GET", "/api/v1/tv/7777", "");
        assert!(k.contains(r#""status":4,"status4k":1"#) && k.contains(r#""sizeLeft":190000000"#));
        assert!(
            k.contains(r#"{"seasonNumber":5,"episodeCount":8,"name":"Staffel 5"}"#),
            "no air date: {k}"
        );
        assert!(
            call(&mut w, "GET", "/api/v1/tv/7777/season/5", "")
                .1
                .contains(r#""airDate":"2026-09-01""#)
        );
        let (_, p) = call(&mut w, "GET", "/api/v1/person/1234/combined_credits", "");
        assert!(
            p.contains(r#""id":1000,"#)
                && p.contains(r#""id":2001,"#)
                && p.contains(r#""id":7777,"#)
        );
        let (_, c) = call(&mut w, "GET", "/api/v1/collection/55", "");
        assert!(c.contains(r#""id":1001,"#) && c.contains(r#""id":2001,"#));
        let (_, r) = call(&mut w, "GET", "/api/v1/tv/7777/recommendations", "");
        assert!(r.contains(r#""id":3001,"#) && !r.contains(r#""id":7777,"#));
        let (_, d) = call(&mut w, "GET", "/api/v1/settings/discover", "");
        assert!(d.contains(r#""type":2"#));
    }

    #[test]
    fn arrive_adds_a_finished_request_of_the_account() {
        let mut w = fresh(Role::User);
        call(&mut w, "POST", "/__seerr/arrive?id=77", "");
        let (_, list) = call(&mut w, "GET", "/api/v1/request?take=20&requestedBy=2", "");
        assert!(list.contains(r#""id":77,"status":2"#), "{list}");
        assert!(
            list.contains(r#""media":{"id":101,"#) || list.contains(r#""tmdbId":1001"#),
            "{list}"
        );
        // the same id twice is one request
        call(&mut w, "POST", "/__seerr/arrive?id=77", "");
        assert_eq!(w.requests.iter().filter(|r| r.id == 77).count(), 1);
    }

    #[test]
    fn arrive_can_name_a_season_of_a_series() {
        let mut w = fresh(Role::User);
        call(
            &mut w,
            "POST",
            "/__seerr/arrive?id=78&tmdb=7777&season=2",
            "",
        );
        let (_, list) = call(&mut w, "GET", "/api/v1/request?take=20&requestedBy=2", "");
        assert!(
            list.contains(r#""seasonNumber":2"#) && list.contains(r#""tmdbId":7777"#),
            "{list}"
        );
    }

    #[test]
    fn season_requests_are_added_only_on_demand() {
        assert_eq!(day_from_today(0).len(), 10);
        assert!(day_from_today(7) > day_from_today(0));
        let w = fresh(Role::User);
        assert_eq!(w.requests.len(), 7, "off by default");
    }

    #[test]
    fn reset_and_role_control() {
        let mut w = fresh(Role::User);
        call(&mut w, "POST", "/__seerr/role?admin", "");
        assert!(w.admin());
        call(
            &mut w,
            "POST",
            "/api/v1/request",
            r#"{"mediaType":"movie","mediaId":2002}"#,
        );
        assert!(w.requests.len() > 7);
        call(&mut w, "POST", "/__seerr/reset", "");
        assert_eq!(w.requests.len(), 7);
        assert!(w.log.is_empty());
    }

    #[test]
    fn json_helpers() {
        let b =
            r#"{"mediaType":"tv","mediaId":7777,"seasons":[1, 3],"is4k":true,"message":"a \"b\""}"#;
        assert_eq!(jnum(b, "mediaId"), Some(7777));
        assert_eq!(jstr(b, "mediaType").as_deref(), Some("tv"));
        assert_eq!(jlist(b, "seasons"), Some(vec![1, 3]));
        assert!(jbool(b, "is4k") && !jbool(b, "other"));
        assert_eq!(jstr(b, "message").as_deref(), Some(r#"a "b""#));
        assert_eq!(jlist(r#"{"seasons":"all"}"#, "seasons"), None);
        assert_eq!(decode("nord%20s%C3%BCd+x"), "nord süd x");
    }
}
