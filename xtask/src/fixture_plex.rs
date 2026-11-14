//! The Plex side of `cargo xtask fixture-server`: just enough of a Plex Media Server (JSON) for the old-against-new
//! comparisons of the Android facade (Home, Library, Search, Detail, Series). Every answer is deterministic. Paths that
//! no Jellyfin route uses (`/library/...`, `/hubs/...`, `/identity`, `/playlists`) belong here.

use crate::fixture_server::Reply;
use std::path::PathBuf;

/// The bench media folder (`SWIFTLY_FIXTURE_MEDIA_DIR`, made by `Werkzeuge/pruefstand-medien.py` + `pruefstand-plex.py`).
fn media_dir() -> Option<PathBuf> {
    std::env::var_os("SWIFTLY_FIXTURE_MEDIA_DIR")
        .map(PathBuf::from)
        .filter(|d| d.is_dir())
}

fn read(dir: &std::path::Path, name: &str) -> Option<Vec<u8>> {
    if name.contains('/') || name.contains("..") {
        return None;
    }
    std::fs::read(dir.join(name)).ok()
}

/// The bench titles in the Plex shape (rating keys 9001..): the metadata, the part files and the external subtitle files
/// of real media. Like a Plex server, a file is only served with an `X-Plex-Token` in the query (a player cannot set
/// headers). `None` for everything else (the caller goes on with the older routes); without the media folder always `None`.
pub(crate) fn bench(path: &str, query: &str) -> Option<Reply> {
    let dir = media_dir()?;
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    let token = query.split('&').any(|p| {
        p.split_once('=')
            .is_some_and(|(k, v)| k == "X-Plex-Token" && !v.is_empty())
    });
    let missing = || Reply(404, "text/plain", Vec::new());
    let denied = || Reply(401, "text/plain", b"token missing".to_vec());
    match parts.as_slice() {
        ["library", "metadata", key] if key.starts_with("90") => {
            let body = read(&dir, &format!("plex-{key}.json"))?;
            let inner = String::from_utf8(body).ok()?;
            Some(Reply(200, "application/json", meta(&[inner]).into_bytes()))
        }
        ["library", "metadata", "80", "allLeaves"] => {
            // The file is a JSON array of the episodes' metadata objects.
            let text = String::from_utf8(read(&dir, "plex-leaves-80.json")?).ok()?;
            let inner = text
                .trim()
                .trim_start_matches('[')
                .trim_end_matches(']')
                .to_owned();
            Some(Reply(200, "application/json", meta(&[inner]).into_bytes()))
        }
        ["library", "parts", key, _, _file] if key.starts_with("90") => {
            if !token {
                return Some(denied());
            }
            let media = String::from_utf8(read(&dir, &format!("plex-{key}.media"))?).ok()?;
            let kind = match media.rsplit('.').next().unwrap_or("") {
                "mp4" => "video/mp4",
                "mkv" => "video/x-matroska",
                _ => "application/octet-stream",
            };
            Some(read(&dir, &media).map_or_else(missing, |b| Reply(200, kind, b)))
        }
        ["library", "streams", id] => {
            let prefix = format!("plex-stream-{id}.");
            let name = std::fs::read_dir(&dir)
                .ok()?
                .flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .find(|n| n.starts_with(&prefix))?;
            if !token {
                return Some(denied());
            }
            Some(read(&dir, &name).map_or_else(missing, |b| Reply(200, "text/plain", b)))
        }
        _ => None,
    }
}

pub fn handles(path: &str) -> bool {
    path.starts_with("/library/")
        || path.starts_with("/hubs/")
        || path == "/identity"
        || path.starts_with("/playlists")
        || path.starts_with("/:/")
}

fn container(inner: &str) -> String {
    format!(r#"{{"MediaContainer":{{{inner}}}}}"#)
}

fn meta(rows: &[String]) -> String {
    container(&format!(
        r#""size":{n},"totalSize":{n},"offset":0,"Metadata":[{r}]"#,
        n = rows.len(),
        r = rows.join(",")
    ))
}

const NAMES: [&str; 3] = ["Plex Eins", "Plex Zwei", "Plex Drei"];

fn movie_row(k: usize) -> String {
    let n = k - 10;
    let offset = if n == 1 {
        r#","viewOffset":600000,"lastViewedAt":1700000000"#
    } else {
        ""
    };
    format!(
        r#"{{"ratingKey":"{k}","type":"movie","title":"{}","year":{},"duration":5400000,"thumb":"/library/metadata/{k}/thumb/1","art":"/library/metadata/{k}/art/1","addedAt":{}{offset}}}"#,
        NAMES[n],
        2018 + n,
        1700000000 + n * 1000
    )
}

fn show_row() -> String {
    r#"{"ratingKey":"20","type":"show","title":"Plex Serie","year":2019,"leafCount":3,"viewedLeafCount":1,"childCount":1,"thumb":"/library/metadata/20/thumb/1","art":"/library/metadata/20/art/1","addedAt":1700004000}"#.into()
}

fn season_row() -> String {
    r#"{"ratingKey":"21","type":"season","title":"Staffel 1","index":1,"parentRatingKey":"20","parentTitle":"Plex Serie","leafCount":3,"viewedLeafCount":1,"thumb":"/library/metadata/21/thumb/1"}"#.into()
}

fn episode_row(n: usize) -> String {
    let viewed = if n == 1 {
        r#","viewCount":1,"lastViewedAt":1700000500"#
    } else {
        ""
    };
    format!(
        r#"{{"ratingKey":"3{n}","type":"episode","title":"Plex Folge {n}","index":{n},"parentIndex":1,"parentRatingKey":"21","grandparentRatingKey":"20","grandparentTitle":"Plex Serie","parentTitle":"Staffel 1","duration":1800000,"thumb":"/library/metadata/3{n}/thumb/1","grandparentThumb":"/library/metadata/20/thumb/1","Media":[{{"id":{n},"duration":1800000,"container":"mkv","Part":[{{"id":{n},"key":"/library/parts/3{n}/1/file.mkv","container":"mkv","size":900000,"Stream":[{{"id":{n}1,"streamType":1,"codec":"h264","index":0,"height":720,"width":1280}},{{"id":{n}2,"streamType":2,"selected":true,"codec":"aac","index":1,"channels":2,"languageCode":"eng","displayTitle":"English (AAC Stereo)"}}]}}]}}]{viewed}}}"#
    )
}

/// The full movie from the Plex tests (one Metadata object with media, streams, people, markers), under another key.
fn movie_full(k: usize) -> String {
    let n = k - 10;
    let obj = include_str!("../../crates/swiftly-plex/tests/fixtures/movie.json");
    let inner = obj
        .split_once(r#""Metadata":["#)
        .map_or("", |(_, r)| r)
        .trim_end()
        .trim_end_matches('}')
        .trim_end_matches('}')
        .trim_end_matches(']')
        .to_owned();
    let inner = inner
        .replacen(r#""ratingKey":"1""#, &format!(r#""ratingKey":"{k}""#), 1)
        .replace("/library/metadata/1/", &format!("/library/metadata/{k}/"))
        .replacen(
            r#""title":"Testfilm""#,
            &format!(r#""title":"{}""#, NAMES[n]),
            1,
        )
        .replacen(
            r#""titleSort":"Testfilm""#,
            &format!(r#""titleSort":"{}""#, NAMES[n]),
            1,
        );
    meta(&[inner])
}

fn show_full() -> String {
    meta(&[r#"{"ratingKey":"20","type":"show","title":"Plex Serie","year":2019,"summary":"Eine Serie.","leafCount":3,"viewedLeafCount":1,"childCount":1,"thumb":"/library/metadata/20/thumb/1","art":"/library/metadata/20/art/1","Genre":[{"id":"5","tag":"Drama"}]}"#.into()])
}

fn collection_row() -> String {
    r#"{"ratingKey":"40","type":"collection","title":"Plex Sammlung","subtype":"movie","childCount":3,"thumb":"/library/collections/40/thumb/1","addedAt":1700005000}"#.into()
}

fn playlist_row() -> String {
    r#"{"ratingKey":"41","type":"playlist","title":"Plex Liste","playlistType":"video","leafCount":3,"composite":"/playlists/41/composite/1","addedAt":1700006000}"#.into()
}

fn search() -> String {
    container(&format!(
        r#""size":2,"Hub":[{{"type":"movie","title":"Movies","size":3,"Metadata":[{}]}},{{"type":"show","title":"Shows","size":1,"Metadata":[{}]}}]"#,
        (10..13).map(movie_row).collect::<Vec<_>>().join(","),
        show_row()
    ))
}

/// A Plex answer for `path`, or `None` for a path this fixture does not know (the caller answers 404).
pub fn answer(path: &str) -> Option<String> {
    let key = |p: &str| {
        path.strip_prefix(p)
            .and_then(|r| r.split('/').next())
            .map(str::to_owned)
    };
    Some(match path {
        "/identity" => container(
            r#""size":0,"claimed":false,"machineIdentifier":"plexfx","version":"1.43.0.0""#,
        ),
        "/library/sections" => container(
            r#""size":2,"Directory":[{"key":"1","type":"movie","title":"Filme","uuid":"u1"},{"key":"2","type":"show","title":"Serien","uuid":"u2"}]"#,
        ),
        "/library/sections/1/all" | "/library/sections/1/recentlyAdded" => {
            meta(&(10..13).map(movie_row).collect::<Vec<_>>())
        }
        "/library/sections/2/all" | "/library/sections/2/recentlyAdded" => meta(&[show_row()]),
        "/library/sections/1/genre" | "/library/sections/2/genre" => {
            container(r#""size":1,"Directory":[{"key":"5","title":"Drama"}]"#)
        }
        "/library/sections/1/collections" => meta(&[collection_row()]),
        "/library/sections/2/collections" => container(r#""size":0"#),
        "/playlists" => meta(&[playlist_row()]),
        "/library/collections/40/children" | "/playlists/41/items" => {
            meta(&(10..13).map(movie_row).collect::<Vec<_>>())
        }
        "/hubs/continueWatching/items" => meta(&[movie_row(11), episode_row(1)]),
        "/library/onDeck" => meta(&[episode_row(2)]),
        "/hubs/search" => search(),
        "/library/metadata/20" => show_full(),
        "/library/metadata/20/children" => meta(&[season_row()]),
        "/library/metadata/21/children" | "/library/metadata/20/allLeaves" => {
            meta(&(1..4).map(episode_row).collect::<Vec<_>>())
        }
        p if p.ends_with("/similar") || p.ends_with("/extras") => container(r#""size":0"#),
        p if p.starts_with("/library/metadata/") && p.matches('/').count() == 3 => {
            let k = key("/library/metadata/")?;
            match k.parse::<usize>().ok()? {
                n @ 10..=12 => movie_full(n),
                n @ 31..=33 => meta(&[episode_row(n - 30)]),
                21 => meta(&[season_row()]),
                _ => return None,
            }
        }
        _ => return None,
    })
}

// ---- plex.tv (live sign-in runs) ---------------------------------------------------------------------------------

/// When the code was made; the account "confirms" it six seconds later, so a run can look at the waiting page first.
static PIN_MADE: std::sync::Mutex<Option<std::time::Instant>> = std::sync::Mutex::new(None);

/// The two servers of the account; both address this fixture itself (`base`), so the sign-in ends on a server that answers.
fn resources(base: &str) -> String {
    let base = if base.is_empty() {
        "http://127.0.0.1:9"
    } else {
        base
    };
    format!(
        r#"[{{"clientIdentifier":"plexfx","name":"Wohnzimmer","provides":"server","owned":true,"presence":true,"connections":[{{"uri":"{base}","local":true}}]}},{{"clientIdentifier":"m2","name":"Kino","provides":"server","owned":false,"sourceTitle":"Oma","presence":true,"connections":[{{"uri":"{base}","local":false}}]}}]"#
    )
}

/// The plex.tv routes the desktop sign-in asks (`SWIFTLY_PLEX_FIXTURE` points every Plex host at this server): the code
/// (`expiresIn` 900), the confirmation, the Home profiles (Mama has a PIN, "1234"), the profile switch and two servers.
pub(crate) fn account(method: &str, path: &str) -> Option<Reply> {
    let json = |s: &str| Some(Reply(200, "application/json", s.as_bytes().to_vec()));
    match (method, path) {
        ("POST", "/api/v2/pins") => {
            *PIN_MADE.lock().ok()? = Some(std::time::Instant::now());
            json(r#"{"id":7,"code":"K7QMXXXX","expiresIn":900}"#)
        }
        ("GET", "/api/v2/pins/7") => {
            let ready = PIN_MADE
                .lock()
                .ok()?
                .is_some_and(|t| t.elapsed() >= std::time::Duration::from_secs(6));
            json(if ready {
                r#"{"id":7,"code":"K7QMXXXX","expiresIn":900,"authToken":"acct-token"}"#
            } else {
                r#"{"id":7,"code":"K7QMXXXX","expiresIn":900}"#
            })
        }
        ("GET", "/api/v2/user") => {
            json(r#"{"id":1,"uuid":"u1","title":"paul@plex.test","username":"paul"}"#)
        }
        ("GET", "/api/v2/home/users") => {
            let base = std::env::var("SWIFTLY_PLEX_FIXTURE").unwrap_or_default();
            json(&format!(
                r#"{{"users":[{{"id":"1","uuid":"u1","title":"Paul","protected":false,"admin":true,"thumb":"{base}/Users/u1/Images/Primary"}},{{"id":"2","uuid":"u2","title":"Mama","protected":true}}]}}"#
            ))
        }
        ("POST", p) if p.starts_with("/api/v2/home/users/") && p.ends_with("/switch") => {
            json(r#"{"authToken":"mama-token"}"#)
        }
        ("GET", "/api/v2/resources") => {
            let base = std::env::var("SWIFTLY_PLEX_FIXTURE").unwrap_or_default();
            json(&resources(&base))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_sign_in_servers_point_at_the_fixture_itself() {
        let list = super::resources("http://127.0.0.1:4242");
        assert_eq!(list.matches("http://127.0.0.1:4242").count(), 2, "{list}");
        assert!(!list.contains("127.0.0.1:9\""), "{list}");
    }
}
