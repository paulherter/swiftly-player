//! Opt-in big catalogue for the fixture server (`fixture-server --big` or `SWIFTLY_FIXTURE_BIG=1`): 300 movies, 40 series with
//! seasons and episodes, genres, eight collections, long titles, favourites and four accounts. Ids start with `bg-`, so
//! nothing of the small catalogue changes; without the switch this module answers nothing. Pictures come from the
//! normal `/Images/` route (a generated gradient per id). Deterministic and read-only.

use crate::fixture_server::{Reply, list};
use std::sync::atomic::{AtomicBool, Ordering};

static ON: AtomicBool = AtomicBool::new(false);

pub(crate) const MOVIES: usize = 300;
pub(crate) const SERIES: usize = 40;
const COLLECTIONS: usize = 8;
pub(crate) const GENRES: [&str; 12] = [
    "Drama",
    "Komödie",
    "Thriller",
    "Science-Fiction",
    "Action",
    "Abenteuer",
    "Animation",
    "Dokumentarfilm",
    "Familie",
    "Fantasy",
    "Krimi",
    "Horror",
];
/// Account names the sign-in accepts in big mode (password `demo` or empty).
pub(crate) const ACCOUNTS: [&str; 4] = ["demo", "anna", "ben", "clara"];
const WORDS: [&str; 16] = [
    "Nordlicht",
    "Sommerregen",
    "Brücke",
    "Wasser",
    "Papierschiffe",
    "Nachtzug",
    "Hafen",
    "Glas",
    "Echo",
    "Winter",
    "Kompass",
    "Leuchtturm",
    "Schatten",
    "Frühling",
    "Insel",
    "Zeitlos",
];

pub(crate) fn enable() {
    ON.store(true, Ordering::Relaxed);
}

pub(crate) fn enabled() -> bool {
    ON.load(Ordering::Relaxed) || std::env::var_os("SWIFTLY_FIXTURE_BIG").is_some()
}

pub(crate) fn movie_name(n: usize) -> String {
    let w = |k: usize| WORDS[(n * 7 + k * 5) % WORDS.len()];
    match n {
        _ if n.is_multiple_of(17) => format!(
            "{} und {} oder die lange Geschichte vom {} am Ende der {} und was danach geschah",
            w(0),
            w(1),
            w(2),
            w(3)
        ),
        _ if n.is_multiple_of(29) => "Donaudampfschifffahrtsgesellschaftskapitänsmütze".into(),
        _ if n.is_multiple_of(13) => format!("{} {} {}", w(0), w(1), w(2)),
        _ => format!("{} {}", w(0), n),
    }
}

fn series_name(n: usize) -> String {
    if n.is_multiple_of(9) {
        format!(
            "{}: Die komplette Chronik der {} in allen Staffeln",
            WORDS[n % WORDS.len()],
            WORDS[(n + 5) % WORDS.len()]
        )
    } else {
        format!("{} Serie {n}", WORDS[(n * 3) % WORDS.len()])
    }
}

fn genres(n: usize, salt: usize) -> Vec<&'static str> {
    let a = GENRES[(n + salt) % GENRES.len()];
    let b = GENRES[(n * 5 + salt + 3) % GENRES.len()];
    if a == b { vec![a] } else { vec![a, b] }
}

fn genre_json(n: usize, salt: usize) -> String {
    genres(n, salt)
        .iter()
        .map(|g| format!("\"{g}\""))
        .collect::<Vec<_>>()
        .join(",")
}

fn seasons_of(s: usize) -> usize {
    1 + s % 4
}
fn episodes_of(s: usize, season: usize) -> usize {
    3 + (s + season * 3) % 8
}

fn movie(n: usize) -> String {
    let resume = if n < 14 && n.is_multiple_of(2) {
        r#""PlaybackPositionTicks":3000000000,"PlayedPercentage":25.0,"Played":false"#
    } else {
        r#""Played":false"#
    };
    let fav = if n.is_multiple_of(9) {
        r#","IsFavorite":true"#
    } else {
        ""
    };
    format!(
        r#"{{"Id":"bg-m{n}","Name":"{name}","SortName":"{sort}","Type":"Movie","ProductionYear":{year},"PremiereDate":"{year}-0{month}-15T00:00:00.0000000Z","DateCreated":"2026-0{month}-{day:02}T10:00:00.0000000Z","RunTimeTicks":{runtime},"Overview":"Ein Film aus dem grossen Testkatalog, Nummer {n}. Er hat einen Beschreibungstext, der ueber mehrere Zeilen laufen darf, damit die Detailseite ihre Hoehe zeigt.","Genres":[{genres}],"CommunityRating":{rating:.1},"OfficialRating":"FSK 12","People":[{{"Id":"p1","Name":"Anna Test","Type":"Actor","Role":"Hauptrolle","PrimaryImageTag":"pp1"}},{{"Id":"p2","Name":"Ben Regie","Type":"Director"}}],"ImageTags":{{"Primary":"p{n}"}},"BackdropImageTags":["b{n}"],"MediaSources":[{{"Id":"src-bg-m{n}","Name":"Test","Container":"mp4","Size":{clip},"SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":{runtime},"MediaStreams":[{{"Type":"Video","Codec":"h264","Index":0,"Width":320,"Height":180}},{{"Type":"Audio","Codec":"aac","Channels":1,"Index":1,"DisplayTitle":"Ton","IsDefault":true}}]}}],"UserData":{{{resume}}}{fav}}}"#,
        name = movie_name(n),
        sort = movie_name(n).to_lowercase(),
        year = 1980 + (n * 7) % 45,
        month = 1 + n % 9,
        day = 1 + n % 27,
        runtime = 36_000_000_000_u64 + (n as u64 % 40) * 1_800_000_000,
        genres = genre_json(n, 0),
        rating = 4.0 + (n % 55) as f64 / 10.0,
        clip = crate::fixture_server::CLIP.len(),
    )
}

fn series(s: usize) -> String {
    let fav = if s.is_multiple_of(7) {
        r#","IsFavorite":true"#
    } else {
        ""
    };
    format!(
        r#"{{"Id":"bg-s{s}","Name":"{name}","SortName":"{sort}","Type":"Series","ProductionYear":{year},"PremiereDate":"{year}-03-01T00:00:00.0000000Z","DateCreated":"2026-0{month}-{day:02}T09:00:00.0000000Z","ChildCount":{seasons},"Overview":"Eine Serie aus dem Testkatalog mit {seasons} Staffeln.","Genres":[{genres}],"CommunityRating":{rating:.1},"ImageTags":{{"Primary":"ps{s}"}},"BackdropImageTags":["bs{s}"],"UserData":{{"UnplayedItemCount":{unplayed},"Played":false}}{fav}}}"#,
        name = series_name(s),
        sort = series_name(s).to_lowercase(),
        year = 1995 + (s * 3) % 30,
        month = 1 + s % 9,
        day = 1 + s % 27,
        seasons = seasons_of(s),
        genres = genre_json(s, 4),
        rating = 5.0 + (s % 40) as f64 / 10.0,
        unplayed = 2 + s % 12,
    )
}

fn season(s: usize, k: usize) -> String {
    format!(
        r#"{{"Id":"bg-s{s}-se{k}","Name":"Staffel {k}","Type":"Season","IndexNumber":{k},"SeriesId":"bg-s{s}","SeriesName":"{}","ImageTags":{{"Primary":"pse{s}{k}"}}}}"#,
        series_name(s)
    )
}

fn episode(s: usize, k: usize, e: usize) -> String {
    format!(
        r#"{{"Id":"bg-e{s}-{k}-{e}","Name":"Folge {e}: {title}","Type":"Episode","SeriesId":"bg-s{s}","SeriesName":"{series}","SeasonId":"bg-s{s}-se{k}","ParentIndexNumber":{k},"IndexNumber":{e},"RunTimeTicks":{runtime},"Overview":"Folge {e} der Staffel {k}.","ImageTags":{{"Primary":"pe{s}{k}{e}"}},"MediaSources":[{{"Id":"src-bg-e{s}-{k}-{e}","Name":"Test","Container":"mp4","SupportsDirectPlay":true,"MediaStreams":[{{"Type":"Video","Codec":"h264","Index":0,"Width":320,"Height":180}},{{"Type":"Audio","Codec":"aac","Channels":1,"Index":1}}]}}],"UserData":{{"Played":false}}}}"#,
        title = WORDS[(s + k + e) % WORDS.len()],
        series = series_name(s),
        runtime = 24_000_000_000_u64 + (e as u64) * 600_000_000,
    )
}

fn collection(c: usize) -> String {
    format!(
        r#"{{"Id":"bg-c{c}","Name":"Sammlung {c}: {}","SortName":"sammlung {c}","Type":"BoxSet","ImageTags":{{"Primary":"pc{c}"}}}}"#,
        WORDS[c % WORDS.len()]
    )
}

fn members(c: usize) -> Vec<String> {
    (0..6)
        .map(|i| movie((c * 11 + i * 3) % MOVIES))
        .chain(std::iter::once(series(c % SERIES)))
        .collect()
}

/// One item by id (`bg-m12`, `bg-s3`, `bg-s3-se2`, `bg-e3-2-4`, `bg-c1`).
pub(crate) fn find(id: &str) -> Option<String> {
    let rest = id.strip_prefix("bg-")?;
    let num = |t: &str| t.parse::<usize>().ok();
    if let Some(n) = rest.strip_prefix('m') {
        return num(n).filter(|n| *n < MOVIES).map(movie);
    }
    if let Some(r) = rest.strip_prefix('c') {
        return num(r).filter(|c| *c < COLLECTIONS).map(collection);
    }
    if let Some(r) = rest.strip_prefix('e') {
        let p: Vec<usize> = r.split('-').filter_map(num).collect();
        return (p.len() == 3
            && p[0] < SERIES
            && (1..=seasons_of(p[0])).contains(&p[1])
            && (1..=episodes_of(p[0], p[1])).contains(&p[2]))
        .then(|| episode(p[0], p[1], p[2]));
    }
    if let Some(r) = rest.strip_prefix('s') {
        return match r.split_once("-se") {
            Some((s, k)) => {
                let (s, k) = (num(s)?, num(k)?);
                (s < SERIES && (1..=seasons_of(s)).contains(&k)).then(|| season(s, k))
            }
            None => num(r).filter(|s| *s < SERIES).map(series),
        };
    }
    None
}

fn all_movies() -> Vec<(usize, String)> {
    (0..MOVIES).map(|n| (n, movie(n))).collect()
}

fn decode(v: &str) -> String {
    let mut out = Vec::new();
    let b = v.as_bytes();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' if i + 2 < b.len() => {
                if let Ok(x) = u8::from_str_radix(&v[i + 1..i + 3], 16) {
                    out.push(x);
                    i += 3;
                    continue;
                }
                out.push(b'%');
            }
            b'+' => out.push(b' '),
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn field(item: &str, key: &str) -> String {
    let pat = format!("\"{key}\":\"");
    item.split_once(&pat)
        .and_then(|(_, r)| r.split('"').next())
        .unwrap_or("")
        .to_owned()
}

fn number(item: &str, key: &str) -> f64 {
    let pat = format!("\"{key}\":");
    item.split_once(&pat)
        .map(|(_, r)| r.split([',', '}']).next().unwrap_or("0"))
        .and_then(|t| t.parse().ok())
        .unwrap_or(0.0)
}

/// Pages a filtered, sorted list by `StartIndex` / `Limit`; `TotalRecordCount` is the full match count.
fn page(mut items: Vec<String>, param: &dyn Fn(&str) -> Option<String>) -> String {
    let sort = param("SortBy").unwrap_or_default();
    let key = |it: &String| -> (String, i64) {
        match sort.split(',').next().unwrap_or("") {
            "DateCreated" => (field(it, "DateCreated"), 0),
            "PremiereDate" => (field(it, "PremiereDate"), 0),
            "CommunityRating" => (String::new(), (number(it, "CommunityRating") * 10.0) as i64),
            "ProductionYear" => (String::new(), number(it, "ProductionYear") as i64),
            _ => (field(it, "SortName"), 0),
        }
    };
    items.sort_by_key(key);
    if param("SortOrder").is_some_and(|o| o.starts_with("Descending")) {
        items.reverse();
    }
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

fn json(body: String) -> Option<Reply> {
    Some(Reply(200, "application/json", body.into_bytes()))
}

/// Answers the catalogue routes in big mode; `None` leaves the request to the normal routes.
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
                .map(|(_, v)| decode(v))
        })
    };
    if method == "POST" && path == "/Users/AuthenticateByName" {
        return None; // handled by `fixture_server::route` (it asks `accepts_user`)
    }
    if path == "/Users/Public" {
        return json(format!(
            "[{}]",
            ACCOUNTS
                .iter()
                .map(|n| format!(r#"{{"Id":"u-{n}","Name":"{n}"}}"#))
                .collect::<Vec<_>>()
                .join(",")
        ));
    }
    if path.ends_with("/UserViews") || path.ends_with("/Views") {
        return json(list(&[
            r#"{"Id":"lib-movies","Name":"Filme","Type":"CollectionFolder","CollectionType":"movies"}"#.into(),
            r#"{"Id":"lib-shows","Name":"Serien","Type":"CollectionFolder","CollectionType":"tvshows"}"#.into(),
            r#"{"Id":"lib-collections","Name":"Sammlungen","Type":"CollectionFolder","CollectionType":"boxsets"}"#.into(),
        ]));
    }
    if path == "/Genres" {
        return json(list(
            &GENRES
                .iter()
                .map(|g| format!(r#"{{"Id":"genre-{g}","Name":"{g}","Type":"Genre"}}"#))
                .collect::<Vec<_>>(),
        ));
    }
    if path.ends_with("/UserItems/Resume") || path.ends_with("/Items/Resume") {
        return json(list(&(0..14).step_by(2).map(movie).collect::<Vec<_>>()));
    }
    if path == "/Shows/NextUp" {
        return json(list(&[
            episode(1, 1, 2),
            episode(2, 1, 3),
            episode(5, 2, 1),
        ]));
    }
    if let Some(s) = path
        .strip_prefix("/Shows/")
        .and_then(|r| r.strip_suffix("/Seasons"))
        .and_then(|id| id.strip_prefix("bg-s"))
        .and_then(|n| n.parse::<usize>().ok())
        .filter(|s| *s < SERIES)
    {
        return json(list(
            &(1..=seasons_of(s))
                .map(|k| season(s, k))
                .collect::<Vec<String>>(),
        ));
    }
    if let Some(s) = path
        .strip_prefix("/Shows/")
        .and_then(|r| r.strip_suffix("/Episodes"))
        .and_then(|id| id.strip_prefix("bg-s"))
        .and_then(|n| n.parse::<usize>().ok())
        .filter(|s| *s < SERIES)
    {
        let wanted = param("seasonId").and_then(|id| {
            id.rsplit_once("-se")
                .and_then(|(_, k)| k.parse::<usize>().ok())
        });
        let eps: Vec<String> = (1..=seasons_of(s))
            .filter(|k| wanted.is_none_or(|w| w == *k))
            .flat_map(|k| (1..=episodes_of(s, k)).map(move |e| episode(s, k, e)))
            .collect();
        return json(list(&eps));
    }
    if path.ends_with("/Items/Latest") {
        let mut v: Vec<String> = (0..16).map(movie).collect();
        v.extend((0..8).map(series));
        return json(format!("[{}]", v.join(",")));
    }
    if path.ends_with("/Similar") {
        return json(list(&(1..7).map(movie).collect::<Vec<_>>()));
    }
    if path.ends_with("/Items") {
        // By ids: the big ones from here, the small catalogue's from the normal `find`.
        if let Some(ids) = param("Ids").or_else(|| param("ids")) {
            let items: Vec<String> = ids
                .split(',')
                .filter_map(|id| find(id).or_else(|| crate::fixture_server::find(id)))
                .collect();
            return json(list(&items));
        }
        let kinds = param("IncludeItemTypes").unwrap_or_default();
        let parent = param("ParentId").unwrap_or_default();
        if let Some(c) = parent
            .strip_prefix("bg-c")
            .and_then(|c| c.parse::<usize>().ok())
        {
            return json(page(members(c), &param));
        }
        if kinds.contains("BoxSet") || parent == "lib-collections" {
            return json(page((0..COLLECTIONS).map(collection).collect(), &param));
        }
        if kinds.contains("Playlist") {
            return json(list(&[]));
        }
        let want_movies = kinds.is_empty() && parent != "lib-shows" || kinds.contains("Movie");
        let want_series = kinds.is_empty() && parent != "lib-movies" || kinds.contains("Series");
        let mut items: Vec<String> = Vec::new();
        if want_movies {
            items.extend(all_movies().into_iter().map(|(_, m)| m));
        }
        if want_series {
            items.extend((0..SERIES).map(series));
        }
        if let Some(g) = param("Genres") {
            let wanted: Vec<String> = g.split('|').map(str::to_owned).collect();
            items.retain(|it| wanted.iter().any(|w| it.contains(&format!("\"{w}\""))));
        }
        if param("Filters").is_some_and(|f| f.contains("IsFavorite")) {
            items.retain(|it| it.contains(r#""IsFavorite":true"#));
        }
        if param("Filters").is_some_and(|f| f.contains("IsResumable")) {
            items.retain(|it| it.contains("PlaybackPositionTicks"));
        }
        if let Some(t) = param("SearchTerm") {
            let t = t.to_lowercase();
            items.retain(|it| field(it, "Name").to_lowercase().contains(&t));
        }
        return json(page(items, &param));
    }
    if path.rsplit('/').nth(1) == Some("Items") {
        let id = path.rsplit('/').next().unwrap_or("");
        if id.starts_with("bg-") {
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
    fn the_big_catalogue_has_300_movies_and_40_series() {
        assert_eq!(
            total(&get("/Users/u/Items?IncludeItemTypes=Movie&Recursive=true")),
            MOVIES
        );
        assert_eq!(
            total(&get(
                "/Users/u/Items?IncludeItemTypes=Series&Recursive=true"
            )),
            SERIES
        );
    }

    #[test]
    fn paging_genres_and_search_work() {
        let first =
            get("/Users/u/Items?IncludeItemTypes=Movie&Limit=100&StartIndex=0&SortBy=SortName");
        assert_eq!(first.matches("\"Type\":\"Movie\"").count(), 100);
        assert_eq!(total(&first), MOVIES);
        let tail = get("/Users/u/Items?IncludeItemTypes=Movie&Limit=100&StartIndex=250");
        assert_eq!(tail.matches("\"Type\":\"Movie\"").count(), 50);
        let drama = get("/Users/u/Items?IncludeItemTypes=Movie&Genres=Drama");
        assert!(total(&drama) > 20 && total(&drama) < MOVIES);
        assert!(get("/Genres").contains("Science-Fiction"));
        assert_eq!(
            total(&get(
                "/Users/u/Items?IncludeItemTypes=Movie&SearchTerm=Donaudampf"
            )),
            10
        ); // 29, 58 .. 290; 0 is a 17-title
    }

    #[test]
    fn seasons_episodes_and_collections_resolve() {
        assert_eq!(total(&get("/Shows/bg-s3/Seasons")), seasons_of(3));
        let eps = get("/Shows/bg-s3/Episodes?seasonId=bg-s3-se2");
        assert_eq!(total(&eps), episodes_of(3, 2));
        assert!(find("bg-e3-2-1").is_some() && find("bg-e3-2-99").is_none());
        assert_eq!(
            total(&get("/Users/u/Items?IncludeItemTypes=BoxSet")),
            COLLECTIONS
        );
        assert_eq!(total(&get("/Users/u/Items?ParentId=bg-c1")), 7);
    }

    #[test]
    fn long_titles_and_favourites_exist() {
        assert!(movie_name(17).chars().count() > 60);
        assert!(
            total(&get(
                "/Users/u/Items?IncludeItemTypes=Movie&Filters=IsFavorite"
            )) >= 30
        );
    }
}
