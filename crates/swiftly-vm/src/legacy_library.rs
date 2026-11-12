#![allow(missing_docs)]
//! The library calls of the old Android facade (`Kern.libraryPage`, `genre`, `genres`, `watchlist`, `labels`,
//! `savedGenres`) as the finished JSON the Compose code parses, on the same query and tile rules as the view models.

use std::sync::Arc;

use serde::Serialize;
use swiftly_images::{ImageAddress, ImageSelection};
use swiftly_jellyfin::ItemsQuery;
use swiftly_l10n::Translator;
use swiftly_library::library_filter::{LibraryFilter, RememberGenre, SortingExt};
use swiftly_library::library_genre::LibraryGenre;
use swiftly_library::{HomePageSource, ListRules};
use swiftly_model::{Item, ItemKind};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_playback::media_server::MediaServer;
use swiftly_rules::alphabet_index::{AlphabetIndex, Sorting};
use swiftly_rules::display_rules::{TileMark, tile_mark};

use crate::account::AccountRef;
use crate::home::{Source, build_source};
use crate::host::Host;
use crate::library_list::index_item;
use crate::tile::Words;

/// `GridTileResponse`.
#[derive(Debug, Serialize, PartialEq)]
pub struct LegacyGridTile {
    pub id: String,
    #[serde(rename = "titel")]
    pub title: String,
    #[serde(rename = "typ")]
    pub kind: String,
    #[serde(rename = "unterzeile", skip_serializing_if = "Option::is_none")]
    pub subline: Option<String>,
    #[serde(rename = "plakat", skip_serializing_if = "Option::is_none")]
    pub poster: Option<String>,
    #[serde(rename = "fortschritt", skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
    #[serde(rename = "marke", skip_serializing_if = "Option::is_none")]
    pub mark: Option<String>,
    #[serde(rename = "markenzahl")]
    pub mark_count: i64,
    #[serde(rename = "buchstabe", skip_serializing_if = "Option::is_none")]
    pub letter: Option<String>,
}

/// `GridPagesResponse` (without the index strip: only the section page sends it).
#[derive(Debug, Serialize, PartialEq)]
pub struct LegacyGridPage {
    #[serde(rename = "titel")]
    pub title: Vec<LegacyGridTile>,
    #[serde(rename = "gesamt")]
    pub total: i64,
}

/// `Kern.gridTile(_:_:sorting:)` with the default order (by name).
pub fn legacy_grid_tile(item: &Item, addresses: &ImageAddress, words: &Words) -> LegacyGridTile {
    grid_tile_sorted(item, addresses, words, Sorting::Name)
}

/// The same with the order that decides the tile's key for the index strip.
pub fn grid_tile_sorted(
    item: &Item,
    addresses: &ImageAddress,
    words: &Words,
    sorting: Sorting,
) -> LegacyGridTile {
    let episode = item.kind() == ItemKind::Episode;
    let (mark, count) = match tile_mark(
        item.type_.as_deref(),
        item.child_count,
        item.user_data.as_ref().and_then(|d| d.played),
        item.user_data.as_ref().and_then(|d| d.unplayed_item_count),
    ) {
        Some(TileMark::Watched) => (Some("gesehen".to_owned()), 0),
        Some(TileMark::Opened(n)) => (Some("offen".to_owned()), n),
        Some(TileMark::Seasons(n)) => (Some("staffeln".to_owned()), n),
        None => (None, 0),
    };
    LegacyGridTile {
        id: item.id.clone(),
        title: if episode {
            item.series_name
                .clone()
                .unwrap_or_else(|| item.name.clone())
        } else {
            item.name.clone()
        },
        kind: item.type_.clone().unwrap_or_default(),
        subline: if episode {
            item.episode_code_with(words)
        } else {
            item.production_year.map(|y| y.to_string())
        },
        poster: ImageSelection::portrait(item, addresses, 480).map(|u| u.to_string()),
        progress: item
            .user_data
            .as_ref()
            .and_then(|d| d.played_percentage)
            .map(|p| p / 100.0),
        mark,
        mark_count: count,
        letter: Some(AlphabetIndex::key_of(&index_item(item), sorting, false)),
    }
}

/// The arguments of the paged calls.
#[derive(Debug, Clone, Default)]
pub struct LegacyPageArgs {
    pub library: String,
    pub art: String,
    pub sorting: String,
    pub filter: String,
    pub genre: String,
    pub since: i64,
    pub count: i64,
}

fn grid(items: &[Item], total: i64, addresses: &ImageAddress, words: &Words) -> LegacyGridPage {
    LegacyGridPage {
        title: items
            .iter()
            .map(|i| legacy_grid_tile(i, addresses, words))
            .collect(),
        total,
    }
}

/// The three server calls the legacy library functions need, for either kind of server.
struct Calls<'a, T: HttpTransport + 'static>(&'a Source<T>);

impl<T: HttpTransport + 'static> Calls<'_, T> {
    async fn items(&self, q: &ItemsQuery) -> Result<swiftly_model::ItemsResponse, ErrorKind> {
        match self.0 {
            Source::Jellyfin(c) => c.items(q).await,
            Source::Plex(c) => c.items_page(q).await.map_err(|e| e.into_kind()),
        }
    }
    async fn remembered(
        &self,
        types: &[String],
        sort: &str,
        order: &str,
        since: i64,
        count: i64,
    ) -> Result<swiftly_model::ItemsResponse, ErrorKind> {
        match self.0 {
            Source::Jellyfin(c) => {
                swiftly_library::client_ext::remembered_items(
                    &**c,
                    types,
                    sort,
                    order,
                    usize::try_from(since).unwrap_or(0),
                    usize::try_from(count).unwrap_or(0),
                    None,
                )
                .await
            }
            Source::Plex(c) => {
                MediaServer::remembered_items(&**c, types, sort, order, since, count).await
            }
        }
    }
    async fn title_genre(&self, name: &str) -> Option<Vec<Item>> {
        match self.0 {
            Source::Jellyfin(c) => HomePageSource::title(&**c, name, 200).await,
            Source::Plex(c) => HomePageSource::title(&**c, name, 200).await,
        }
    }
    async fn genres(&self) -> Result<Vec<String>, ErrorKind> {
        match self.0 {
            Source::Jellyfin(c) => c.genres().await,
            Source::Plex(c) => MediaServer::genres(&**c).await,
        }
    }
}

async fn library_page_with<T: HttpTransport + 'static>(
    c: &Calls<'_, T>,
    a: &ImageAddress,
    words: &Words,
    args: &LegacyPageArgs,
) -> Result<LegacyGridPage, ErrorKind> {
    let s = Sorting::from_raw(&args.sorting).unwrap_or(Sorting::Name);
    let f = LibraryFilter::from_raw(&args.filter).unwrap_or(LibraryFilter::All);
    let art = Some(args.art.as_str());
    let answer = c
        .items(&ItemsQuery {
            parent_id: Some(args.library.clone()),
            limit: args.count,
            start_index: args.since,
            sort_by: s.input_field().into(),
            sort_order: s.bearing().into(),
            filters: f.jellyfin_filter(),
            is_watched: f.is_watched(),
            recursive: LibraryGenre::recursive_toward(art),
            include_item_types: LibraryGenre::types_toward(art)
                .into_iter()
                .map(String::from)
                .collect(),
            ..ItemsQuery::default()
        })
        .await?;
    Ok(grid(&answer.items, answer.total_record_count, a, words))
}

async fn watchlist_with<T: HttpTransport + 'static>(
    c: &Calls<'_, T>,
    a: &ImageAddress,
    words: &Words,
    args: &LegacyPageArgs,
) -> Result<LegacyGridPage, ErrorKind> {
    let kind = RememberGenre::toward((!args.genre.is_empty()).then_some(args.genre.as_str()));
    let s = Sorting::from_raw(&args.sorting).unwrap_or(Sorting::Latest);
    let types: Vec<String> = kind.types().into_iter().map(String::from).collect();
    let answer = c
        .remembered(&types, s.input_field(), s.bearing(), args.since, args.count)
        .await?;
    let items = if args.since == 0 {
        ListRules::without_double(&answer.items)
    } else {
        answer.items.clone()
    };
    Ok(grid(&items, answer.total_record_count, a, words))
}

/// Which call.
pub enum LegacyLibraryCall {
    Page,
    Watchlist,
    Genre(String),
    Genres,
}

/// One library call for one account, as the JSON string the Compose code parses.
pub async fn legacy_library_json<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: &AccountRef,
    call: LegacyLibraryCall,
    args: &LegacyPageArgs,
) -> Result<String, ErrorKind> {
    let source = build_source(transport, host, account)?;
    let a = source.addresses().ok_or(ErrorKind::NotAuthenticated)?;
    let words = Words::new(host.locale.clone());
    let c = Calls(&source);
    match call {
        LegacyLibraryCall::Page => to_json(&library_page_with(&c, &a, &words, args).await?),
        LegacyLibraryCall::Watchlist => to_json(&watchlist_with(&c, &a, &words, args).await?),
        LegacyLibraryCall::Genre(name) => {
            let items = c
                .title_genre(&name)
                .await
                .ok_or(ErrorKind::Network { code: -1005 })?;
            to_json(
                &items
                    .iter()
                    .map(|i| legacy_grid_tile(i, &a, &words))
                    .collect::<Vec<_>>(),
            )
        }
        LegacyLibraryCall::Genres => to_json(&c.genres().await?),
    }
}

fn to_json<V: Serialize>(v: &V) -> Result<String, ErrorKind> {
    serde_json::to_string(v).map_err(|e| ErrorKind::Decoding(e.to_string()))
}

/// `Kern.collectionCountText`: "3 Filme" / "3 Serien" under a collection tile.
pub fn legacy_count_text(locale: swiftly_l10n::Locale, art: &str, count: i64) -> String {
    swiftly_library::collection_directory::ItemCollection::count_text(
        art,
        count,
        &Words::new(locale),
    )
}

/// `Kern.labels()`: the texts of the sort orders and filters, in the order of `allCases`.
pub fn legacy_labels_json(locale: swiftly_l10n::Locale) -> String {
    let t = Translator::new(locale);
    let sorting: Vec<_> = [
        ("name", "Nach Name"),
        ("neueste", "Zuletzt"),
        ("bewertung", "Bewertung"),
        ("erscheinung", "Jahr"),
    ]
    .into_iter()
    .map(|(v, k)| serde_json::json!({"wert": v, "text": t.t(k)}))
    .collect();
    let filter: Vec<_> = [
        ("alle", "Alle"),
        ("angefangen", "Angefangen"),
        ("merkliste", "Merkliste"),
        ("ungesehen", "Ungesehen"),
    ]
    .into_iter()
    .map(|(v, k)| serde_json::json!({"wert": v, "text": t.t(k)}))
    .collect();
    serde_json::json!({"sortierung": sorting, "filter": filter}).to_string()
}

/// `Kern.savedGenres()`: "all", "movies", "series" with the kind (`art`) as value.
pub fn legacy_saved_genres_json(locale: swiftly_l10n::Locale) -> String {
    let t = Translator::new(locale);
    let rows: Vec<_> = RememberGenre::ALL
        .into_iter()
        .map(|g| {
            let label = match g {
                RememberGenre::All => "Alle",
                RememberGenre::Movies => "Filme",
                RememberGenre::SeriesList => "Serien",
            };
            serde_json::json!({"wert": g.art().unwrap_or(""), "text": t.t(label)})
        })
        .collect();
    serde_json::Value::Array(rows).to_string()
}
