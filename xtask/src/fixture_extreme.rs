//! Opt-in worst-case catalogue for the fixture server (`fixture-server --extreme` or `SWIFTLY_FIXTURE_EXTREME=1`): titles the
//! demo data never has (120 characters with and without spaces, emoji, Hebrew and Arabic, one letter), a series with no
//! episodes, an empty library, four-digit episode numbers, a very long server name, huge run times and ratings. Ids start
//! with `ex-`; without the switch this module answers nothing, so every other answer stays byte-identical. Deterministic
//! and read-only. A long user name comes from the run's own account file (`LIVE_USER` of the live-run script).

use crate::fixture_server::{Reply, list};
use std::sync::atomic::{AtomicBool, Ordering};

static ON: AtomicBool = AtomicBool::new(false);

pub(crate) fn enable() {
    ON.store(true, Ordering::Relaxed);
}

pub(crate) fn enabled() -> bool {
    ON.load(Ordering::Relaxed) || std::env::var_os("SWIFTLY_FIXTURE_EXTREME").is_some()
}

const LIB_MOVIES: &str = "ex-lib-movies";
const LIB_SHOWS: &str = "ex-lib-shows";
const LIB_EMPTY: &str = "ex-lib-empty";

/// A server name as people give them ("<room> server of <family> ...").
pub(crate) const SERVER_NAME: &str =
    "Wohnzimmer-Server von Familie Wiśniewska-Kowalczyk im Dachgeschoss (Backup 2)";

/// Exactly 120 characters, words with spaces.
pub(crate) fn long_title() -> String {
    "Die unglaubliche und wahre Geschichte vom Leuchtturmwärter, der den Winter am Ende der Welt überlebte und danach alles vergaß"
        .chars()
        .take(120)
        .collect()
}

/// Exactly 120 characters without a single space (German compounds, a file name or a URL slug look like this).
pub(crate) fn unbroken_title() -> String {
    "Donaudampfschifffahrtsgesellschaftskapitänsmützenfabrikationsleiterstellvertreterinnenbesprechungsraumbeleuchtungsinspektion"
        .chars()
        .take(120)
        .collect()
}

const MOVIES: usize = 8;

fn movie_name(n: usize) -> String {
    match n {
        0 => long_title(),
        1 => unbroken_title(),
        2 => "🎬 Die große Reise 🌍✨ Teil 2: Das Finale 🍿🔥".into(),
        3 => "שובר הקופות: המסע הגדול אל קצה העולם ובחזרה".into(),
        4 => "رحلة إلى أعماق البحر: الجزء الثاني من القصة الكاملة".into(),
        5 => "X".into(),
        6 => "Ein Film mit zu vielen Stunden".into(),
        _ => "Ohne Beschreibung".into(),
    }
}

fn movie(n: usize) -> String {
    let overview = match n {
        0 => "Ein langer Beschreibungstext, der wirklich mehrere Absätze füllt. ".repeat(40),
        7 => String::new(),
        _ => format!("Beschreibung zu Film {n}."),
    };
    // Film 6 runs 99 hours (a marathon cut), film 5 two minutes.
    let runtime: u64 = match n {
        6 => 99 * 36_000_000_000,
        5 => 1_200_000_000,
        _ => 54_000_000_000 + n as u64 * 600_000_000,
    };
    let (rating, official) = if n == 6 {
        ("10.0", "TV-MA-Unrated-Mature-Audience-Only-Extended-Cut")
    } else {
        ("7.4", "FSK 12")
    };
    let resume = if n == 0 || n == 3 {
        r#""PlaybackPositionTicks":3000000000,"PlayedPercentage":25.0,"Played":false"#
    } else {
        r#""Played":false"#
    };
    format!(
        r#"{{"Id":"ex-m{n}","Name":"{name}","SortName":"{sort}","Type":"Movie","ProductionYear":{year},"PremiereDate":"{year}-03-15T00:00:00.0000000Z","DateCreated":"2026-0{month}-10T10:00:00.0000000Z","RunTimeTicks":{runtime},"Overview":"{overview}","Genres":["Wissenschaftlich-fantastische Abenteuer-Dokumentation","Drama","Komödie"],"CommunityRating":{rating},"CriticRating":100,"OfficialRating":"{official}","People":[{{"Id":"p1","Name":"Alexandra Wiśniewska-Kowalczyk-Montgomery","Type":"Actor","Role":"Die Leiterin der Nordpolarexpedition und Retterin aller","PrimaryImageTag":"pp1"}},{{"Id":"p2","Name":"Jo","Type":"Director"}}],"ImageTags":{{"Primary":"p{n}"}},"BackdropImageTags":["b{n}"],"MediaSources":[{{"Id":"src-ex-m{n}","Name":"Test","Container":"mp4","Size":{clip},"SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":{runtime},"MediaStreams":[{{"Type":"Video","Codec":"h264","Index":0,"Width":320,"Height":180}},{{"Type":"Audio","Codec":"aac","Channels":1,"Index":1,"DisplayTitle":"Ton","IsDefault":true}}]}}],"UserData":{{{resume}}}}}"#,
        name = movie_name(n),
        sort = movie_name(n).to_lowercase(),
        year = 1990 + n,
        month = 1 + n,
        clip = crate::fixture_server::CLIP.len(),
    )
}

const SERIES: usize = 4;

fn series_name(s: usize) -> String {
    match s {
        0 => long_title(),
        1 => "Leere Serie ohne eine einzige Folge".into(),
        2 => "הסדרה הארוכה: עונה אחת עם אלפי פרקים".into(),
        _ => "📺 مسلسل الأحلام 🌙 الموسم الأول".into(),
    }
}

/// The season numbers of series `s`: none for the empty series, 12 only for the one with four-digit episodes.
fn seasons_of(s: usize) -> Vec<usize> {
    match s {
        0 => vec![1, 2],
        1 => vec![],
        2 => vec![12],
        _ => vec![1],
    }
}

/// The episode numbers of season `k` of series `s`.
fn episodes_of(s: usize, _k: usize) -> Vec<usize> {
    match s {
        0 => vec![1, 2, 3],
        2 => vec![1000, 1001, 1002, 1003],
        _ => vec![1, 2],
    }
}

fn series(s: usize) -> String {
    let seasons = seasons_of(s).len();
    format!(
        r#"{{"Id":"ex-s{s}","Name":"{name}","SortName":"{sort}","Type":"Series","ProductionYear":{year},"PremiereDate":"{year}-03-01T00:00:00.0000000Z","DateCreated":"2026-02-0{d}T09:00:00.0000000Z","ChildCount":{seasons},"Overview":"Eine Serie mit {seasons} Staffeln.","Genres":["Drama"],"CommunityRating":8.1,"ImageTags":{{"Primary":"ps{s}"}},"BackdropImageTags":["bs{s}"],"UserData":{{"UnplayedItemCount":{unplayed},"Played":false}}}}"#,
        name = series_name(s),
        sort = series_name(s).to_lowercase(),
        year = 2000 + s,
        d = 1 + s,
        unplayed = if s == 2 { 4000 } else { 3 },
    )
}

fn season_name(s: usize, k: usize) -> String {
    if s == 0 {
        format!("Staffel {k}: Der lange Winter am Ende der Welt und was danach kam")
    } else {
        format!("Staffel {k}")
    }
}

fn season(s: usize, k: usize) -> String {
    format!(
        r#"{{"Id":"ex-s{s}-se{k}","Name":"{}","Type":"Season","IndexNumber":{k},"SeriesId":"ex-s{s}","SeriesName":"{}","ImageTags":{{"Primary":"pse{s}{k}"}}}}"#,
        season_name(s, k),
        series_name(s)
    )
}

fn episode(s: usize, k: usize, e: usize) -> String {
    format!(
        r#"{{"Id":"ex-e{s}-{k}-{e}","Name":"Folge {e}: Der Abend, an dem der Leuchtturm zum ersten Mal ausging und niemand wusste, warum","Type":"Episode","SeriesId":"ex-s{s}","SeriesName":"{series}","SeasonId":"ex-s{s}-se{k}","SeasonName":"{season}","ParentIndexNumber":{k},"IndexNumber":{e},"RunTimeTicks":{runtime},"Overview":"Folge {e} der Staffel {k}.","ImageTags":{{"Primary":"pe{s}{k}{e}"}},"MediaSources":[{{"Id":"src-ex-e{s}-{k}-{e}","Name":"Test","Container":"mp4","SupportsDirectPlay":true,"MediaStreams":[{{"Type":"Video","Codec":"h264","Index":0,"Width":320,"Height":180}},{{"Type":"Audio","Codec":"aac","Channels":1,"Index":1}}]}}],"UserData":{{"Played":false}}}}"#,
        series = series_name(s),
        season = season_name(s, k),
        runtime = 24_000_000_000_u64 + e as u64 * 600_000_000,
    )
}

fn find(id: &str) -> Option<String> {
    let rest = id.strip_prefix("ex-")?;
    let num = |t: &str| t.parse::<usize>().ok();
    if let Some(n) = rest.strip_prefix('m') {
        return num(n).filter(|n| *n < MOVIES).map(movie);
    }
    if let Some(r) = rest.strip_prefix('e') {
        let p: Vec<usize> = r.split('-').filter_map(num).collect();
        return (p.len() == 3
            && p[0] < SERIES
            && seasons_of(p[0]).contains(&p[1])
            && episodes_of(p[0], p[1]).contains(&p[2]))
        .then(|| episode(p[0], p[1], p[2]));
    }
    let r = rest.strip_prefix('s')?;
    match r.split_once("-se") {
        Some((s, k)) => {
            let (s, k) = (num(s)?, num(k)?);
            (s < SERIES && seasons_of(s).contains(&k)).then(|| season(s, k))
        }
        None => num(r).filter(|s| *s < SERIES).map(series),
    }
}

fn seasons(s: usize) -> Vec<String> {
    seasons_of(s).into_iter().map(|k| season(s, k)).collect()
}

fn episodes(s: usize, only: Option<usize>) -> Vec<String> {
    seasons_of(s)
        .into_iter()
        .filter(|k| only.is_none_or(|w| w == *k))
        .flat_map(|k| episodes_of(s, k).into_iter().map(move |e| episode(s, k, e)))
        .collect()
}

fn all_movies() -> Vec<String> {
    (0..MOVIES).map(movie).collect()
}

fn all_series() -> Vec<String> {
    (0..SERIES).map(series).collect()
}

fn json(body: String) -> Option<Reply> {
    Some(Reply(200, "application/json", body.into_bytes()))
}

/// Keeps the items whose `Type` is one of the comma separated `types`; empty keeps everything.
fn of_types(items: Vec<String>, types: &str) -> Vec<String> {
    if types.is_empty() {
        return items;
    }
    let wanted: Vec<String> = types
        .split(',')
        .map(|t| format!(r#""Type":"{t}""#))
        .collect();
    items
        .into_iter()
        .filter(|i| wanted.iter().any(|t| i.contains(t.as_str())))
        .collect()
}

fn name_of(item: &str) -> String {
    item.split_once(r#""Name":""#)
        .and_then(|(_, r)| r.split('"').next())
        .unwrap_or("")
        .to_owned()
}

fn page(items: Vec<String>, param: &dyn Fn(&str) -> Option<String>) -> String {
    let total = items.len();
    let start = param("StartIndex")
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0)
        .min(total);
    let limit = param("Limit")
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(total);
    let slice: Vec<String> = items.into_iter().skip(start).take(limit).collect();
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{total},"StartIndex":{start}}}"#,
        slice.join(",")
    )
}

/// Answers the catalogue routes in extreme mode; `None` leaves the request to the normal routes.
pub(crate) fn answer(method: &str, path: &str, query: &str) -> Option<Reply> {
    if !enabled() {
        return None;
    }
    answer_on(method, path, query)
}

fn answer_on(method: &str, path: &str, query: &str) -> Option<Reply> {
    let param = |k: &str| {
        query.split('&').find_map(|p| {
            p.split_once('=')
                .filter(|(n, _)| n.eq_ignore_ascii_case(k))
                .map(|(_, v)| crate::fixture_big::decode(v))
        })
    };
    if method != "GET" {
        return None;
    }
    if path == "/System/Info/Public" {
        return json(format!(
            r#"{{"ServerName":"{SERVER_NAME}","Version":"10.10.0","Id":"{}","ProductName":"Jellyfin Server"}}"#,
            crate::fixture_server::server_id()
        ));
    }
    if path.ends_with("/UserViews") || path.ends_with("/Views") {
        return json(list(&[
            format!(
                r#"{{"Id":"{LIB_MOVIES}","Name":"Filme","Type":"CollectionFolder","CollectionType":"movies"}}"#
            ),
            format!(
                r#"{{"Id":"{LIB_SHOWS}","Name":"Serien","Type":"CollectionFolder","CollectionType":"tvshows"}}"#
            ),
            format!(
                r#"{{"Id":"{LIB_EMPTY}","Name":"Leere Bibliothek","Type":"CollectionFolder","CollectionType":"movies"}}"#
            ),
        ]));
    }
    if path.ends_with("/UserItems/Resume") || path.ends_with("/Items/Resume") {
        return json(list(&[movie(0), movie(3), episode(2, 12, 1000)]));
    }
    if path == "/Shows/NextUp" {
        return json(list(&[episode(0, 1, 2), episode(2, 12, 1001)]));
    }
    let show = path.strip_prefix("/Shows/").and_then(|r| {
        let (id, tail) = r.split_once('/')?;
        let s = id.strip_prefix("ex-s")?.parse::<usize>().ok()?;
        (s < SERIES).then_some((s, tail))
    });
    if let Some((s, tail)) = show {
        match tail {
            "Seasons" => return json(list(&seasons(s))),
            "Episodes" => {
                let only = param("seasonId").and_then(|id| {
                    id.rsplit_once("-se")
                        .and_then(|(_, k)| k.parse::<usize>().ok())
                });
                return json(list(&episodes(s, only)));
            }
            _ => {}
        }
    }
    if path.ends_with("/Items/Latest") {
        let mut v = all_movies();
        v.extend(all_series());
        return json(format!("[{}]", v.join(",")));
    }
    if path.ends_with("/Similar") && path.contains("/ex-") {
        return json(list(&[movie(1), movie(2), movie(5)]));
    }
    if path.ends_with("/Items") {
        let ids = param("Ids").or_else(|| param("ids"));
        if let Some(ids) = ids {
            let found: Vec<String> = ids.split(',').filter_map(find).collect();
            return json(list(&found));
        }
        let types = param("IncludeItemTypes").unwrap_or_default();
        let recursive = param("Recursive").is_some_and(|r| r.eq_ignore_ascii_case("true"));
        let parent = param("ParentId").unwrap_or_default();
        let mut items = match parent.as_str() {
            LIB_MOVIES => all_movies(),
            LIB_EMPTY => Vec::new(),
            LIB_SHOWS => {
                let mut v = all_series();
                if recursive {
                    for s in 0..SERIES {
                        v.extend(seasons(s));
                        v.extend(episodes(s, None));
                    }
                }
                v
            }
            p if p.starts_with("ex-s") => {
                let s = p
                    .strip_prefix("ex-s")?
                    .split("-se")
                    .next()?
                    .parse::<usize>()
                    .ok()?;
                if p.contains("-se") {
                    find(p)?;
                    let k = p.rsplit_once("-se")?.1.parse::<usize>().ok()?;
                    episodes(s, Some(k))
                } else {
                    let mut v = seasons(s);
                    if recursive {
                        v.extend(episodes(s, None));
                    }
                    v
                }
            }
            "" => {
                let mut v = all_movies();
                v.extend(all_series());
                if !types.is_empty() {
                    for s in 0..SERIES {
                        v.extend(seasons(s));
                        v.extend(episodes(s, None));
                    }
                }
                v
            }
            _ => return None,
        };
        if let Some(term) = param("searchTerm") {
            let term = term.to_lowercase();
            items.retain(|i| name_of(i).to_lowercase().contains(&term));
        }
        let items = of_types(items, &types);
        return json(page(items, &param));
    }
    if path.rsplit('/').nth(1) == Some("Items") {
        let id = path.rsplit('/').next().unwrap_or("");
        if id.starts_with("ex-") {
            return Some(match find(id) {
                Some(item) => Reply(200, "application/json", item.into_bytes()),
                None => Reply(404, "text/plain", b"no such item".to_vec()),
            });
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn get(target: &str) -> String {
        let (path, query) = target.split_once('?').unwrap_or((target, ""));
        let reply = answer_on("GET", path, query).expect("answered");
        String::from_utf8(reply.2).unwrap()
    }

    fn total(body: &str) -> usize {
        body.split_once("\"TotalRecordCount\":")
            .and_then(|(_, r)| r.split([',', '}']).next())
            .and_then(|t| t.parse().ok())
            .unwrap()
    }

    #[test]
    fn the_long_titles_are_exactly_120_characters() {
        assert_eq!(long_title().chars().count(), 120);
        assert!(long_title().contains(' '));
        assert_eq!(unbroken_title().chars().count(), 120);
        assert!(!unbroken_title().contains(' '));
    }

    #[test]
    fn every_item_is_valid_json() {
        for item in all_movies().into_iter().chain(all_series()) {
            assert!(item.starts_with('{') && item.ends_with('}'), "{item}");
        }
        assert!(find("ex-e2-12-1003").is_some());
        assert!(find("ex-e2-12-4").is_none());
    }

    #[test]
    fn one_library_is_empty_and_one_series_has_no_episodes() {
        assert_eq!(total(&get("/Users/u1/Items?ParentId=ex-lib-empty")), 0);
        assert_eq!(total(&get("/Shows/ex-s1/Episodes")), 0);
        assert_eq!(total(&get("/Shows/ex-s1/Seasons")), 0);
        assert_eq!(total(&get("/Shows/ex-s2/Episodes")), 4);
        assert_eq!(total(&get("/Users/u1/Views")), 3);
    }

    #[test]
    fn search_and_paging_work() {
        assert_eq!(
            total(&get("/Users/u1/Items?Recursive=true&searchTerm=reise")),
            1
        );
        let page = get("/Users/u1/Items?ParentId=ex-lib-movies&StartIndex=6&Limit=5");
        assert_eq!(total(&page), MOVIES);
        assert_eq!(page.matches(r#""Type":"Movie""#).count(), 2);
    }

    #[test]
    fn the_server_name_is_long() {
        assert!(get("/System/Info/Public").contains(SERVER_NAME));
        assert!(SERVER_NAME.chars().count() > 60);
    }

    #[test]
    fn off_by_default() {
        if !enabled() {
            assert!(answer("GET", "/System/Info/Public", "").is_none());
            assert!(answer("GET", "/Users/u1/Views", "").is_none());
        }
    }
}
