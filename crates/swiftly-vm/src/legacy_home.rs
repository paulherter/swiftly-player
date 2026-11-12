#![allow(missing_docs)]
//! The home page as the old Android facade (`Kern.home`) answered it: one finished JSON document
//! with German keys, rails with all their tiles, built from the same loader and the same text
//! rules as the view model. The Android adapter returns this string to the unchanged Compose
//! code; a parity test compares it with the Swift facade's answer on the fixture server.

use std::sync::Arc;

use serde::Serialize;
use swiftly_images::{ImageAddress, ImageSelection};
use swiftly_library::library_filter::SortingExt;
use swiftly_library::start_libraries::StartLibraries;
use swiftly_library::{HomeLoader, HomePageSource, LoadRequest, StartRail, StartRailsEpisode};
use swiftly_model::{Item, ItemKind};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_rules::display_rules::{TileMark, tile_mark};

use crate::account::AccountRef;
use crate::home::{Source, build_source};
use crate::host::Host;
use crate::tile::Words;
use crate::title_text::{TitleText, resume_from};

/// What `Kern.home` was given.
#[derive(Debug, Clone, Default)]
pub struct LegacyHomeArgs {
    pub disconnected: bool,
    /// The stored rail order (names).
    pub stored: Vec<String>,
    /// The hidden rails (names).
    pub from: Vec<String>,
    pub film_library: String,
    pub series_library: String,
    pub genres: Vec<String>,
    pub as_chips: bool,
    /// The stored choice of own library rows (JSON of `StartLibraries`).
    pub libraries: Vec<u8>,
}

/// `TileResponse`.
#[derive(Debug, Serialize, PartialEq)]
pub struct LegacyTile {
    pub id: String,
    pub name: String,
    #[serde(rename = "typ")]
    pub kind: String,
    #[serde(rename = "unterzeile", skip_serializing_if = "Option::is_none")]
    pub subline: Option<String>,
    #[serde(rename = "plakat", skip_serializing_if = "Option::is_none")]
    pub poster: Option<String>,
    #[serde(rename = "quer", skip_serializing_if = "Option::is_none")]
    pub landscape: Option<String>,
    #[serde(rename = "fortschritt", skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
    #[serde(rename = "marke", skip_serializing_if = "Option::is_none")]
    pub mark: Option<String>,
    #[serde(rename = "markenzahl")]
    pub mark_count: i64,
    #[serde(rename = "angabenzeile", skip_serializing_if = "Option::is_none")]
    pub details_row: Option<String>,
    #[serde(rename = "restzeit", skip_serializing_if = "Option::is_none")]
    pub remaining_time: Option<String>,
    #[serde(rename = "weiterschauenzeile", skip_serializing_if = "Option::is_none")]
    pub continue_watching_row: Option<String>,
    #[serde(rename = "gesehen")]
    pub watched: bool,
    #[serde(rename = "folgenname", skip_serializing_if = "Option::is_none")]
    pub episode_name: Option<String>,
    #[serde(rename = "laufzeitSekunden", skip_serializing_if = "Option::is_none")]
    pub runtime_seconds: Option<f64>,
    #[serde(rename = "positionSekunden", skip_serializing_if = "Option::is_none")]
    pub position_seconds: Option<f64>,
    #[serde(rename = "bewertung", skip_serializing_if = "Option::is_none")]
    pub rating: Option<f64>,
    #[serde(rename = "freigabe", skip_serializing_if = "Option::is_none")]
    pub sharing: Option<String>,
    #[serde(rename = "beschreibung", skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(rename = "kulisse", skip_serializing_if = "Option::is_none")]
    pub backdrop: Option<String>,
}

/// `RailsResponse`.
#[derive(Debug, Serialize, PartialEq)]
pub struct LegacyRail {
    #[serde(rename = "titelSchluessel", skip_serializing_if = "Option::is_none")]
    pub title_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(rename = "quer")]
    pub landscape: bool,
    #[serde(rename = "kacheln")]
    pub tiles: Vec<LegacyTile>,
    #[serde(rename = "bibliothek", skip_serializing_if = "Option::is_none")]
    pub library: Option<String>,
    #[serde(rename = "sammlung")]
    pub collection: bool,
    #[serde(rename = "sprungArt", skip_serializing_if = "Option::is_none")]
    pub jump_art: Option<String>,
    #[serde(rename = "sprungSortierung", skip_serializing_if = "Option::is_none")]
    pub jump_sorting: Option<String>,
}

/// `HomeResponse`.
#[derive(Debug, Serialize, PartialEq)]
pub struct LegacyHome {
    #[serde(rename = "reihen")]
    pub rails: Vec<LegacyRail>,
    #[serde(rename = "gestoert")]
    pub disrupted: bool,
}

/// `Kern.tile(_:newAccess:withMark:_:)`.
pub fn legacy_tile(
    item: &Item,
    new_access: bool,
    with_mark: bool,
    addresses: &ImageAddress,
    words: &Words,
    text: &TitleText,
) -> LegacyTile {
    let (mark, count) = if with_mark {
        match tile_mark(
            item.type_.as_deref(),
            item.child_count,
            item.user_data.as_ref().and_then(|d| d.played),
            item.user_data.as_ref().and_then(|d| d.unplayed_item_count),
        ) {
            Some(TileMark::Watched) => (Some("gesehen".to_owned()), 0),
            Some(TileMark::Opened(n)) => (Some("offen".to_owned()), n),
            Some(TileMark::Seasons(n)) => (Some("staffeln".to_owned()), n),
            None => (None, 0),
        }
    } else {
        (None, 0)
    };
    let runtime = item.runtime_seconds();
    let mut details: Vec<String> = Vec::new();
    if item.kind() == ItemKind::Episode
        && let Some(code) = item.episode_code_with(words)
    {
        details.push(code);
    }
    if let Some(year) = item.production_year {
        details.push(year.to_string());
    }
    if let Some(seconds) = runtime.filter(|s| *s > 0.0) {
        details.push(text.runtime(seconds));
    }
    let episode = item.kind() == ItemKind::Episode;
    LegacyTile {
        id: item.id.clone(),
        name: item
            .series_name
            .clone()
            .unwrap_or_else(|| item.name.clone()),
        kind: item.type_.clone().unwrap_or_default(),
        subline: if new_access {
            item.new_arrivals_row_with(words)
        } else {
            item.episode_code_with(words)
        },
        poster: ImageSelection::portrait(item, addresses, 480).map(|u| u.to_string()),
        landscape: ImageSelection::landscape(item, addresses, 600).map(|l| l.url.to_string()),
        progress: item.watched_share(),
        mark,
        mark_count: count,
        details_row: (!details.is_empty()).then(|| details.join(" · ")),
        remaining_time: text.remaining(item),
        continue_watching_row: words.continue_row(item, context_line(item, text)),
        watched: item.is_watched(),
        episode_name: episode.then(|| item.name.clone()),
        runtime_seconds: runtime,
        position_seconds: resume_from(item),
        rating: item.community_rating,
        sharing: item.official_rating.clone(),
        description: item.overview.clone(),
        backdrop: backdrop(item, addresses),
    }
}

/// `Item.contextLine` for a movie: the year (the row builder only reads it for movies).
fn context_line(item: &Item, _text: &TitleText) -> Option<String> {
    item.production_year.map(|y| y.to_string())
}

/// `Kern.backdrop(_:episode:addresses:)` with no episode.
fn backdrop(item: &Item, addresses: &ImageAddress) -> Option<String> {
    ImageSelection::landscape(item, addresses, 1600)
        .map(|l| l.url)
        .or_else(|| ImageSelection::header_with_fallback(item, None, addresses, 1200))
        .map(|u| u.to_string())
}

async fn home_with(
    client: &impl HomePageSource,
    addresses: &ImageAddress,
    args: &LegacyHomeArgs,
    host: &Host,
) -> LegacyHome {
    let words = Words::new(host.locale.clone());
    let text = TitleText::new(host.locale.clone());
    let choice = StartLibraries::read(Some(&args.libraries));
    let library_rails = async {
        if choice.is_empty() {
            Vec::new()
        } else {
            HomeLoader::library_rails(client, &choice).await
        }
    };
    let none_if_empty = |s: &str| (!s.is_empty()).then(|| s.to_owned());
    let mut wish = LoadRequest::new(args.disconnected)
        .film_library(none_if_empty(&args.film_library).as_deref())
        .series_library(none_if_empty(&args.series_library).as_deref());
    wish.genres = (!args.as_chips).then(|| args.genres.clone());
    let (library_state, state) =
        futures_util::future::join(library_rails, HomeLoader::load(client, &wish)).await;

    let hidden: std::collections::HashSet<String> = args.from.iter().cloned().collect();
    let mut rails: Vec<LegacyRail> = Vec::new();
    for rail in StartRailsEpisode::visible(&args.stored, &hidden, args.disconnected) {
        let (landscape, new, mark, items) = match rail {
            StartRail::ContinueWatching => (true, false, false, &state.continue_watching),
            StartRail::NextEpisode => (false, false, false, &state.next_episode),
            StartRail::NewArrivals => (false, true, true, &state.recent),
            StartRail::NewMovies => (false, true, true, &state.new_movies),
            StartRail::NewSeries => (false, true, true, &state.new_series),
        };
        let Some(items) = items.as_ref().filter(|i| !i.is_empty()) else {
            continue;
        };
        let jump = rail.library_jump();
        rails.push(LegacyRail {
            title_key: Some(rail.rails_title().to_owned()),
            name: None,
            landscape,
            tiles: items
                .iter()
                .map(|i| legacy_tile(i, new, mark, addresses, &words, &text))
                .collect(),
            library: None,
            collection: false,
            jump_art: jump.map(|j| j.art.to_owned()),
            jump_sorting: jump.map(|j| j.sorting.raw_value().to_owned()),
        });
    }
    for w in &choice {
        let Some(r) = library_state.iter().find(|r| r.id == w.id) else {
            continue;
        };
        rails.push(LegacyRail {
            title_key: None,
            name: Some(w.name.clone()),
            landscape: false,
            tiles: r
                .items
                .iter()
                .map(|i| legacy_tile(i, false, true, addresses, &words, &text))
                .collect(),
            library: Some(w.id.clone()),
            collection: w.collection,
            jump_art: None,
            jump_sorting: None,
        });
    }
    for g in &state.genre_rails {
        rails.push(LegacyRail {
            title_key: None,
            name: Some(g.name.clone()),
            landscape: false,
            tiles: g
                .items
                .iter()
                .map(|i| legacy_tile(i, false, true, addresses, &words, &text))
                .collect(),
            library: None,
            collection: false,
            jump_art: None,
            jump_sorting: None,
        });
    }
    LegacyHome {
        rails,
        disrupted: state.disrupted,
    }
}

/// `Kern.home` for one account, as the JSON string the Compose code parses.
pub async fn legacy_home_json<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: &AccountRef,
    args: &LegacyHomeArgs,
) -> Result<String, ErrorKind> {
    let source = build_source(transport, host, account)?;
    let home = match &source {
        Source::Jellyfin(c) => {
            let a = source.addresses().ok_or(ErrorKind::NotAuthenticated)?;
            home_with(&**c, &a, args, host).await
        }
        Source::Plex(c) => {
            let a = source.addresses().ok_or(ErrorKind::NotAuthenticated)?;
            home_with(&**c, &a, args, host).await
        }
    };
    serde_json::to_string(&home).map_err(|e| ErrorKind::Decoding(e.to_string()))
}
