//! Pure response mapping and address rules (`enum Seerr`, Seerr.swift).

use std::collections::HashSet;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::models::{SeerrDetail, SeerrHit, SeerrPerson, SeerrSeason, SeerrState};

#[derive(Deserialize)]
struct Info {
    status: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    id: i64,
    media_type: Option<String>,
    title: Option<String>,
    name: Option<String>,
    release_date: Option<String>,
    first_air_date: Option<String>,
    poster_path: Option<String>,
    backdrop_path: Option<String>,
    media_info: Option<Info>,
}

#[derive(Deserialize)]
struct HitList {
    results: Vec<Record>,
}

#[derive(Deserialize)]
struct Filmography {
    cast: Option<Vec<Record>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CastHead {
    id: i64,
    name: Option<String>,
    character: Option<String>,
    profile_path: Option<String>,
}

#[derive(Deserialize)]
struct Credits {
    cast: Option<Vec<CastHead>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawSeason {
    season_number: i64,
    episode_count: Option<i64>,
}

#[derive(Deserialize)]
struct Genre {
    name: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SeasonState {
    season_number: i64,
    status: Option<i64>,
}

#[derive(Deserialize)]
struct MediaInfo {
    status: Option<i64>,
    seasons: Option<Vec<SeasonState>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DetailReply {
    overview: Option<String>,
    genres: Option<Vec<Genre>>,
    runtime: Option<i64>,
    episode_run_time: Option<Vec<i64>>,
    vote_average: Option<f64>,
    seasons: Option<Vec<RawSeason>>,
    credits: Option<Credits>,
    media_info: Option<MediaInfo>,
}

/// Namespace of the pure functions.
pub struct Seerr;

fn hits(entries: Vec<Record>, standard_art: Option<&str>) -> Vec<SeerrHit> {
    entries
        .into_iter()
        .filter_map(|e| {
            let art = e
                .media_type
                .clone()
                .or_else(|| standard_art.map(str::to_string))?;
            if art != "movie" && art != "tv" {
                return None;
            }
            let title = e
                .title
                .clone()
                .or(e.name.clone())
                .filter(|t| !t.is_empty())?;
            let date = e.release_date.as_ref().or(e.first_air_date.as_ref());
            Some(SeerrHit {
                id: e.id,
                art,
                title,
                year: date.and_then(|d| d.chars().take(4).collect::<String>().parse().ok()),
                poster_path: e.poster_path,
                backdrop_path: e.backdrop_path,
                state: e
                    .media_info
                    .and_then(|m| m.status)
                    .and_then(SeerrState::from_raw)
                    .unwrap_or(SeerrState::Opened),
            })
        })
        .collect()
}

impl Seerr {
    /// Hits of `GET search`; broken input gives an empty list.
    pub fn hit_from_search(data: &[u8]) -> Vec<SeerrHit> {
        serde_json::from_slice::<HitList>(data)
            .map_or_else(|_| Vec::new(), |a| hits(a.results, None))
    }

    /// Hits of `person/{id}/combined_credits`, each (art, id) once.
    pub fn hit_from_filmography(data: &[u8]) -> Vec<SeerrHit> {
        let Ok(f) = serde_json::from_slice::<Filmography>(data) else {
            return Vec::new();
        };
        let mut seen = HashSet::new();
        hits(f.cast.unwrap_or_default(), None)
            .into_iter()
            .filter(|h| seen.insert(format!("{}-{}", h.art, h.id)))
            .collect()
    }

    /// Suggestions; entries without `mediaType` inherit `art`.
    pub fn suggestions(data: &[u8], art: &str) -> Vec<SeerrHit> {
        serde_json::from_slice::<HitList>(data)
            .map_or_else(|_| Vec::new(), |a| hits(a.results, Some(art)))
    }

    /// Detail of a film or series; `None` for unreadable input.
    pub fn detail(data: &[u8]) -> Option<SeerrDetail> {
        let a: DetailReply = serde_json::from_slice(data).ok()?;
        let mut states = std::collections::HashMap::new();
        for e in a
            .media_info
            .as_ref()
            .and_then(|m| m.seasons.as_ref())
            .into_iter()
            .flatten()
        {
            if let Some(s) = e.status.and_then(SeerrState::from_raw) {
                states.insert(e.season_number, s);
            }
        }
        let seasons = a
            .seasons
            .unwrap_or_default()
            .into_iter()
            .filter(|s| s.season_number > 0)
            .map(|s| SeerrSeason {
                number: s.season_number,
                episodes: s.episode_count.unwrap_or(0),
                state: states
                    .get(&s.season_number)
                    .copied()
                    .unwrap_or(SeerrState::Opened),
            })
            .collect();
        let cast = a
            .credits
            .and_then(|c| c.cast)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|k| {
                let name = k.name.filter(|n| !n.is_empty())?;
                Some(SeerrPerson {
                    id: k.id,
                    name,
                    role: k.character.filter(|c| !c.is_empty()),
                    image_path: k.profile_path,
                })
            })
            .take(20)
            .collect();
        let text = a.overview.map(|o| o.trim().to_string());
        Some(SeerrDetail {
            description: text.filter(|t| !t.is_empty()),
            genres: a
                .genres
                .unwrap_or_default()
                .into_iter()
                .filter_map(|g| g.name)
                .take(2)
                .collect(),
            runtime: a
                .runtime
                .or_else(|| a.episode_run_time.and_then(|e| e.first().copied())),
            rating: a.vote_average,
            seasons,
            cast,
            similar_one: Vec::new(),
            state: Some(
                a.media_info
                    .and_then(|m| m.status)
                    .and_then(SeerrState::from_raw)
                    .unwrap_or(SeerrState::Opened),
            ),
        })
    }

    /// The session cookie (`name=value`) out of a `Set-Cookie` header value (several cookies
    /// joined with `, `). Only names containing `sid` count; an empty value does not.
    pub fn cookie_from_header(set_cookie: &str) -> Option<String> {
        for part in set_cookie.split(',') {
            let piece = part.trim_matches(|c: char| c == ' ' || c == '\t');
            let Some(same) = piece.find('=') else {
                continue;
            };
            if !piece[..same].contains("sid") {
                continue;
            }
            let until = piece.find(';').unwrap_or(piece.len());
            let cookie = &piece[..until];
            if !cookie.ends_with('=') {
                return Some(cookie.to_string());
            }
        }
        None
    }

    /// Body of `POST request`. A series without a season choice asks for `"all"`.
    pub fn request_body(art: &str, id: i64, seasons: Option<&[i64]>) -> Value {
        let mut shell = json!({ "mediaType": art, "mediaId": id });
        if art == "tv" {
            shell["seasons"] = match seasons {
                Some(s) if !s.is_empty() => json!(s),
                _ => json!("all"),
            };
        }
        shell
    }

    /// Cleans a typed address: scheme guessed (`http` in the home network), trailing slashes and
    /// `/api/v1`, `/api` removed. `None` for empty or unusable input.
    pub fn address(typed: &str) -> Option<String> {
        let mut text = typed.trim().to_string();
        if text.is_empty() {
            return None;
        }
        if !text.to_lowercase().starts_with("http") {
            let scheme = if is_home_network(&text) {
                "http://"
            } else {
                "https://"
            };
            text = format!("{scheme}{text}");
        }
        text.truncate(text.trim_end_matches('/').len());
        for attachment in ["/api/v1", "/api"] {
            if text.to_lowercase().ends_with(attachment) {
                text.truncate(text.len() - attachment.len());
            }
        }
        text.truncate(text.trim_end_matches('/').len());
        swiftly_net::Url::parse(&text).ok()?;
        Some(text)
    }

    /// The address and, when the user typed no scheme, the other scheme as a second try.
    pub fn addresses(typed: &str) -> Vec<String> {
        let Some(first) = Self::address(typed) else {
            return Vec::new();
        };
        if typed.trim().to_lowercase().starts_with("http") {
            return vec![first];
        }
        let second = if let Some(rest) = first.strip_prefix("https://") {
            format!("http://{rest}")
        } else if let Some(rest) = first.strip_prefix("http://") {
            format!("https://{rest}")
        } else {
            return vec![first];
        };
        vec![first, second]
    }
}

/// `AppModelURLNormalizer.isHomeNetwork` (ServerURL.swift:69): IP literals, `.local`, `.lan`,
/// `.home`, `.internal`, `localhost` and bare host names. (Copy: the jellyfin crate has no
/// public version yet.)
pub(crate) fn is_home_network(text: &str) -> bool {
    let name = text.split('/').find(|s| !s.is_empty()).unwrap_or(text);
    if let Some(rest) = name.strip_prefix('[') {
        return rest.find(']').is_some_and(|i| is_ipv6(&rest[..i]));
    }
    if is_ipv6(name) {
        return true;
    }
    let without_port = name.split(':').find(|s| !s.is_empty()).unwrap_or(name);
    let small = without_port.to_lowercase();
    if [".local", ".lan", ".home", ".internal"]
        .iter()
        .any(|s| small.ends_with(s))
        || small == "localhost"
    {
        return true;
    }
    if !small.contains('.') {
        return true;
    }
    let parts: Vec<&str> = small.split('.').collect();
    parts.len() == 4
        && parts.iter().all(|p| {
            !p.is_empty()
                && p.chars().all(|c| c.is_ascii_digit())
                && p.parse::<u32>().is_ok_and(|n| n < 256)
        })
}

fn is_ipv6(text: &str) -> bool {
    let without_zone = text.split('%').next().unwrap_or(text);
    without_zone.matches(':').count() >= 2
        && without_zone
            .chars()
            .all(|c| c == ':' || c == '.' || c.is_ascii_hexdigit())
}
