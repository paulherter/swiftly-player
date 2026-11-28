#![allow(missing_docs)]
//! The library section calls of the old Android facade that keep state between calls (`Kern.sectionOffering`,
//! `sectionPage`, `collections`, `playlists`, `playlistPage`, `playlistStart`, `collectionPage`, `collectionMosaic`,
//! `collectionsForTitle`): the account's views, the offering with its one-minute cache, the naturally sorted list and the
//! title filter across pages. One object per account; the answers are the JSON strings the Compose code parses.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use serde::Serialize;
use swiftly_images::{ImageAddress, ImageSelection};
use swiftly_jellyfin::ItemsQuery;
use swiftly_library::LibraryShare;
use swiftly_library::client_ext::{language_index, title_filter_narrowed, year_options};
use swiftly_library::collection_directory::{CollectionDirectory, ItemCollection};
use swiftly_library::library_filter::{LibraryFilter, SortingExt};
use swiftly_library::library_genre::LibraryGenre;
use swiftly_library::playlist_directory::{PlaylistDirectory, VideoPlaylist};
use swiftly_library::{
    Facet, FilterChoice, FilterFacets, FilterSheet, LanguageIndex, ListFilter, ListRules,
    ShelfSource, TitleFilter,
};
use swiftly_model::{Item, ItemsResponse};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_playback::media_server::MediaServer;
use swiftly_playback::section_offering::{SectionOffering, SectionSelection};
use swiftly_rules::alphabet_index::Sorting;
use swiftly_rules::natural_order::NaturalCollator;

use crate::account::AccountRef;
use crate::home::{Source, build_source};
use crate::host::{Host, age};
use crate::legacy_library::{LegacyGridTile, grid_tile_sorted};
use crate::tile::Words;

#[derive(Serialize)]
struct Letter {
    #[serde(rename = "buchstabe")]
    letter: String,
    #[serde(rename = "ab")]
    first: usize,
    #[serde(rename = "anzeige")]
    label: String,
    #[serde(rename = "luecke")]
    gap: bool,
}

#[derive(Serialize)]
struct Page {
    #[serde(rename = "titel")]
    title: Vec<LegacyGridTile>,
    #[serde(rename = "gesamt")]
    total: i64,
    #[serde(rename = "buchstaben", skip_serializing_if = "Option::is_none")]
    letters: Option<Vec<Letter>>,
}

#[derive(Serialize)]
struct SectionPage {
    #[serde(rename = "titel")]
    title: Vec<LegacyGridTile>,
    #[serde(rename = "gesamt")]
    total: i64,
    #[serde(rename = "gesiebt")]
    filtered: bool,
    #[serde(rename = "nochMehr")]
    even_more: bool,
    #[serde(rename = "buchstaben", skip_serializing_if = "Option::is_none")]
    letters: Option<Vec<Letter>>,
}

#[derive(Serialize)]
struct OfferingEntry {
    #[serde(rename = "wert")]
    value: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(rename = "rubrik")]
    category: bool,
}

#[derive(Serialize)]
struct Offering {
    #[serde(rename = "istMenue")]
    is_menu: bool,
    #[serde(rename = "hatBestand")]
    has_inventory: bool,
    #[serde(rename = "wahl")]
    choice: String,
    #[serde(rename = "kennung")]
    identifier: String,
    #[serde(rename = "eintraege")]
    entries: Vec<OfferingEntry>,
}

#[derive(Serialize)]
struct CardEntry {
    id: String,
    name: String,
    #[serde(rename = "plakat", skip_serializing_if = "Option::is_none")]
    poster: Option<String>,
    #[serde(rename = "anzahl")]
    count: usize,
}

#[derive(Serialize)]
struct CollectionRail {
    id: String,
    name: String,
    art: String,
    #[serde(rename = "titel")]
    title: Vec<LegacyGridTile>,
}

struct Offered {
    shares: HashMap<String, LibraryShare>,
    directory: CollectionDirectory,
    /// When it was asked, on the host's clock (`Instant` does not count the time the device sleeps).
    at: f64,
}

struct FilterState {
    key: String,
    filter: TitleFilter,
    offset: i64,
}

/// What the filter sheet offers for one list (years, languages), fetched once by [`LegacySection::filter_load`].
struct SheetFacets {
    key: String,
    facets: FilterFacets,
    index: Option<Arc<LanguageIndex>>,
}

#[derive(Default)]
struct State {
    facets: Option<SheetFacets>,
    views: Option<Vec<Item>>,
    offered: Option<Offered>,
    playlists: Option<PlaylistDirectory>,
    filter: Option<FilterState>,
    natural: Option<(String, Vec<Item>)>,
    /// The entries of the playlist started last (`playlistStart`), for the player's "next episode" run.
    run: Vec<Item>,
}

/// The library section state of one account.
pub struct LegacySection<T: HttpTransport + 'static> {
    source: Source<T>,
    addresses: ImageAddress,
    words: Words,
    collator: Option<NaturalCollator>,
    /// The host the account's short-term memory ([`crate::offered`]) belongs to.
    host: Host,
    /// The key of the account ([`AccountRef::key`]), the key of that memory.
    key: String,
    state: Mutex<State>,
}

fn json<V: Serialize>(v: &V) -> Result<String, ErrorKind> {
    serde_json::to_string(v).map_err(|e| ErrorKind::Decoding(e.to_string()))
}

impl<T: HttpTransport + 'static> LegacySection<T> {
    pub fn new(transport: &Arc<T>, host: &Host, account: &AccountRef) -> Result<Self, ErrorKind> {
        let source = build_source(transport, host, account)?;
        let addresses = source.addresses().ok_or(ErrorKind::NotAuthenticated)?;
        Ok(Self {
            source,
            addresses,
            words: Words::new(host.locale.clone()),
            collator: NaturalCollator::new(host.locale.language()).ok(),
            host: host.clone(),
            key: account.key(),
            state: Mutex::new(State::default()),
        })
    }

    fn locked<R>(&self, f: impl FnOnce(&mut State) -> R) -> R {
        f(&mut self.state.lock().unwrap_or_else(PoisonError::into_inner))
    }

    // ---- the server, either kind ----------------------------------------------------------------------------------

    async fn user_views(&self, hidden: bool) -> Result<Vec<Item>, ErrorKind> {
        match &self.source {
            Source::Jellyfin(c) => c.user_views(hidden).await,
            Source::Plex(c) => MediaServer::user_views(&**c, hidden).await,
        }
    }
    async fn items(&self, q: &ItemsQuery) -> Result<ItemsResponse, ErrorKind> {
        match &self.source {
            Source::Jellyfin(c) => c.items(q).await,
            Source::Plex(c) => c.items_page(q).await.map_err(|e| e.into_kind()),
        }
    }
    async fn item(&self, id: &str) -> Result<Item, ErrorKind> {
        match &self.source {
            Source::Jellyfin(c) => c.item(id).await,
            Source::Plex(c) => c.item(id).await.map_err(|e| e.into_kind()),
        }
    }
    async fn library_shares(&self, views: &[Item]) -> HashMap<String, LibraryShare> {
        match &self.source {
            Source::Jellyfin(c) => swiftly_library::client_ext::library_shares(&**c, views).await,
            Source::Plex(c) => MediaServer::library_shares(&**c, views).await,
        }
    }
    async fn collection_directory(&self, views: &[Item]) -> Result<CollectionDirectory, ErrorKind> {
        match &self.source {
            Source::Jellyfin(c) => {
                swiftly_library::client_ext::collection_directory(&**c, views).await
            }
            Source::Plex(c) => MediaServer::collection_directory(&**c, views).await,
        }
    }
    async fn playlist_directory(&self) -> Result<PlaylistDirectory, ErrorKind> {
        match &self.source {
            Source::Jellyfin(c) => swiftly_library::client_ext::playlist_directory(&**c).await,
            Source::Plex(c) => MediaServer::playlist_directory(&**c).await,
        }
    }
    async fn playlist_entries(&self, id: &str) -> Result<Vec<Item>, ErrorKind> {
        match &self.source {
            Source::Jellyfin(c) => Ok(c
                .playlist_entries(id, false)
                .await?
                .into_iter()
                .filter(VideoPlaylist::is_video_entry)
                .collect()),
            Source::Plex(c) => MediaServer::playlist_entries(&**c, id, false).await,
        }
    }
    async fn title_filter(
        &self,
        source: &ShelfSource,
        filters: &[String],
        watched: Option<bool>,
    ) -> Result<TitleFilter, ErrorKind> {
        match &self.source {
            Source::Jellyfin(c) => {
                swiftly_library::client_ext::title_filter(&**c, source, filters, watched).await
            }
            Source::Plex(c) => MediaServer::title_filter(&**c, source, filters, watched).await,
        }
    }
    async fn natural_list(
        &self,
        source: &ShelfSource,
        filter: LibraryFilter,
    ) -> Result<Vec<Item>, ErrorKind> {
        let Some(collator) = &self.collator else {
            return Err(ErrorKind::Decoding("no collator".into()));
        };
        let types = source.types();
        match &self.source {
            Source::Jellyfin(c) => {
                swiftly_library::client_ext::natural_list(
                    &**c,
                    collator,
                    source.parent.as_deref(),
                    source.bearing(Sorting::Name),
                    &filter.jellyfin_filter(),
                    filter.is_watched(),
                    source.recursive(),
                    &types,
                )
                .await
            }
            Source::Plex(c) => c
                .natural_list(
                    &ItemsQuery {
                        parent_id: source.parent.clone(),
                        sort_order: source.bearing(Sorting::Name).into(),
                        filters: filter.jellyfin_filter(),
                        is_watched: filter.is_watched(),
                        recursive: source.recursive(),
                        include_item_types: types.iter().map(|s| (*s).into()).collect(),
                        ..ItemsQuery::default()
                    },
                    collator,
                )
                .await
                .map_err(|e| e.into_kind()),
        }
    }
    async fn natural_page(
        &self,
        list: &[Item],
        since: usize,
        count: usize,
    ) -> Result<ItemsResponse, ErrorKind> {
        match &self.source {
            Source::Jellyfin(c) => {
                swiftly_library::client_ext::natural_page(&**c, list, since, count).await
            }
            Source::Plex(c) => c
                .natural_page(
                    list,
                    i64::try_from(since).unwrap_or(i64::MAX),
                    i64::try_from(count).unwrap_or(i64::MAX),
                )
                .await
                .map_err(|e| e.into_kind()),
        }
    }

    // ---- state ----------------------------------------------------------------------------------------------------

    async fn view_list(&self) -> Result<Vec<Item>, ErrorKind> {
        if let Some(v) = self.locked(|s| s.views.clone()) {
            return Ok(v);
        }
        let list = self.user_views(false).await?;
        self.locked(|s| s.views = Some(list.clone()));
        Ok(list)
    }

    /// The account's short-term memory of what it offers ([`crate::offered`]).
    fn whose(&self) -> crate::offered::Whose {
        crate::offered::Whose::new(&self.key, &self.host)
    }

    /// `AppModel.offeringLoad()`: on demand, valid for one minute; a failed look-up leaves the state as it was.
    pub async fn offering_load(&self) {
        if self.locked(|s| {
            s.offered
                .as_ref()
                .is_some_and(|o| age(self.host.clock.now(), o.at) < Duration::from_secs(60))
        }) {
            return;
        }
        let views = if let Ok(new) = self.user_views(false).await {
            self.locked(|s| s.views = Some(new.clone()));
            new
        } else if let Some(old) = self.locked(|s| s.views.clone()) {
            old
        } else {
            return;
        };
        let shares = self.library_shares(&views);
        let directory = async {
            // The home page and the detail pages keep the account's collections for a minute ([`crate::offered`]):
            // what they asked a moment ago is not asked again, and what is asked here is theirs to use.
            let who = self.whose();
            if let Some(kept) = crate::offered::current(&who) {
                return Some(kept);
            }
            let began = crate::offered::stamp(&who);
            let with_hidden = self
                .user_views(true)
                .await
                .unwrap_or_else(|_| views.clone());
            let found = if CollectionDirectory::hidden(&views, &with_hidden) {
                Some(CollectionDirectory::default())
            } else {
                self.collection_directory(&with_hidden).await.ok()
            };
            if let Some(found) = &found {
                crate::offered::remember(&who, began, found);
            }
            found
        };
        let playlists = async { self.playlist_directory().await.ok() };
        let (shares, directory, playlists) =
            futures_util::future::join3(shares, directory, playlists).await;
        self.locked(|s| {
            s.playlists = playlists.or_else(|| s.playlists.take());
            if let Some(directory) = directory {
                s.offered = Some(Offered {
                    shares,
                    directory,
                    at: self.host.clock.now(),
                });
            }
        });
    }

    fn offering(&self, art: &str, views: &[Item]) -> SectionOffering {
        self.locked(|s| {
            let empty = HashMap::new();
            SectionOffering::compose(
                art,
                views,
                s.offered.as_ref().map_or(&empty, |o| &o.shares),
                s.offered.as_ref().map(|o| &o.directory),
                s.playlists.as_ref(),
            )
        })
    }

    fn directory(&self) -> Option<CollectionDirectory> {
        self.locked(|s| s.offered.as_ref().map(|o| o.directory.clone()))
    }

    fn tile(&self, item: &Item, sorting: Sorting) -> LegacyGridTile {
        grid_tile_sorted(item, &self.addresses, &self.words, sorting)
    }

    fn letters(list: &[Item], sorting: Sorting) -> Vec<Letter> {
        crate::library_list::alphabet(list, sorting_of(sorting))
            .entries
            .into_iter()
            .map(|e| Letter {
                letter: e.letter,
                first: e.first,
                label: e.label,
                gap: e.gap,
            })
            .collect()
    }

    async fn other_letters(
        &self,
        source: &ShelfSource,
        s: Sorting,
        f: LibraryFilter,
    ) -> Option<Vec<Letter>> {
        // Only "By name" has a strip: no whole-list fetch for the other orders.
        if s != Sorting::Name {
            return Some(Vec::new());
        }
        let list = self
            .items(&ItemsQuery {
                parent_id: source.parent.clone(),
                sort_by: s.input_field().into(),
                sort_order: source.bearing(s).into(),
                filters: f.jellyfin_filter(),
                is_watched: f.is_watched(),
                recursive: source.recursive(),
                include_item_types: source.types().iter().map(|t| (*t).to_owned()).collect(),
                slim: true,
                ..ItemsQuery::default()
            })
            .await
            .ok()?
            .items;
        Some(Self::letters(&list, s))
    }

    async fn natural_cached(
        &self,
        key: &str,
        since: i64,
        source: &ShelfSource,
        f: LibraryFilter,
    ) -> Result<Vec<Item>, ErrorKind> {
        if since > 0
            && let Some(list) = self.locked(|s| {
                s.natural
                    .as_ref()
                    .filter(|n| n.0 == key)
                    .map(|n| n.1.clone())
            })
        {
            return Ok(list);
        }
        let list = self.natural_list(source, f).await?;
        self.locked(|s| s.natural = Some((key.to_owned(), list.clone())));
        Ok(list)
    }

    // ---- the calls ------------------------------------------------------------------------------------------------

    /// `Kern.startSelection`: the libraries and collections still offered as own home rows (`[{id,name,sammlung}]`).
    pub async fn start_selection(&self, selected: &str) -> Result<String, ErrorKind> {
        use swiftly_library::start_libraries::{StartLibraries, StartLibrary};
        let views = self.view_list().await?;
        self.offering_load().await;
        let collections: Vec<Item> = self
            .directory()
            .map(|d| d.all.iter().map(|c| c.item.clone()).collect())
            .unwrap_or_default();
        let libraries: Vec<Item> = views
            .into_iter()
            .filter(StartLibraries::selectable)
            .collect();
        let free = StartLibraries::pick(
            &libraries,
            &collections,
            &StartLibraries::read(Some(selected.as_bytes())),
        );
        let offered: Vec<serde_json::Value> = free
            .iter()
            .map(|item| {
                let library = StartLibrary::from_item(item);
                serde_json::json!({
                    "id": library.id,
                    "name": library.name,
                    "sammlung": library.collection,
                })
            })
            .collect();
        json(&offered)
    }

    pub async fn section_offering(&self, art: &str, remembered: &str) -> Result<String, ErrorKind> {
        let views = self.view_list().await?;
        let a = self.offering(art, &views);
        let first = a.first_library();
        let entries = a
            .entries()
            .into_iter()
            .map(|e| match &e {
                SectionSelection::Library(id) => OfferingEntry {
                    value: e.remember_value(),
                    name: Some(a.library(id).map(|l| l.name.clone()).unwrap_or_default()),
                    category: Some(&e) == first.as_ref(),
                },
                _ => OfferingEntry {
                    value: e.remember_value(),
                    name: None,
                    category: false,
                },
            })
            .collect();
        let values: Vec<String> = a
            .entries()
            .iter()
            .map(SectionSelection::remember_value)
            .collect();
        json(&Offering {
            is_menu: a.is_menu(),
            has_inventory: a.has_inventory(),
            choice: a.choice(Some(remembered)).remember_value(),
            identifier: format!("{}|{}", values.join(","), a.all_sources().join("+")),
            entries,
        })
    }

    /// The list a section page reads: all libraries, one library, or none (collections, playlists).
    async fn section_source(
        &self,
        art: &str,
        choice: &str,
    ) -> Result<Option<ShelfSource>, ErrorKind> {
        let views = self.view_list().await?;
        let offering = self.offering(art, &views);
        let art_opt = Some(art);
        let source: Option<ShelfSource> = match SectionSelection::from_remember_value(Some(choice))
        {
            SectionSelection::All => offering.has_inventory().then(|| {
                let out = offering.all_out();
                let all = offering.all_sources();
                let only: Vec<&str> = if out.is_none() {
                    all.iter().map(String::as_str).collect()
                } else {
                    Vec::new()
                };
                ShelfSource::new(out.as_deref(), art_opt, false, &only)
            }),
            SectionSelection::Library(id) => Some(ShelfSource::new(Some(&id), art_opt, false, &[])),
            SectionSelection::Collections | SectionSelection::Playlists => None,
        };
        Ok(source)
    }

    async fn title_filter_listed(
        &self,
        source: &ShelfSource,
        filter: &ListFilter,
        languages: Option<&LanguageIndex>,
    ) -> Result<TitleFilter, ErrorKind> {
        match &self.source {
            Source::Jellyfin(c) => title_filter_narrowed(&**c, source, filter, languages).await,
            Source::Plex(c) => {
                MediaServer::title_filter(
                    &**c,
                    source,
                    &filter.jellyfin_filter(),
                    filter.is_watched(),
                )
                .await
            }
        }
    }

    /// Years and languages are offered for a Jellyfin or Emby library list, not for Plex, a collection or a playlist.
    fn supports_facets(&self, source: &ShelfSource) -> bool {
        matches!(self.source, Source::Jellyfin(_)) && !source.collection
    }

    /// The language index of this list: the one the sheet fetched, else one scan now.
    async fn language_index_for(&self, source: &ShelfSource) -> Option<Arc<LanguageIndex>> {
        let key = source.key();
        if let Some(index) = self.locked(|s| {
            s.facets
                .as_ref()
                .filter(|f| f.key == key)
                .and_then(|f| f.index.clone())
        }) {
            return Some(index);
        }
        match &self.source {
            Source::Jellyfin(c) => language_index(&**c, source).await.ok().map(Arc::new),
            Source::Plex(_) => None,
        }
    }

    /// The filter sheet is about to open: fetch the years and languages of this list, once per list.
    pub async fn filter_load(&self, art: &str, choice: &str) {
        let Ok(Some(source)) = self.section_source(art, choice).await else {
            return;
        };
        let key = source.key();
        let Source::Jellyfin(c) = &self.source else {
            return;
        };
        if !self.supports_facets(&source)
            || self.locked(|s| {
                s.facets
                    .as_ref()
                    .is_some_and(|f| f.key == key && !matches!(f.facets.languages, Facet::Failed))
            })
        {
            return;
        }
        let years = year_options(&**c, &source).await;
        let index = language_index(&**c, &source).await;
        let (languages, index) = match index {
            Ok(index) => (Facet::Ready(index.languages()), Some(Arc::new(index))),
            Err(_) => (Facet::Failed, None),
        };
        let facets = FilterFacets {
            years: years.map_or(Facet::Failed, Facet::Ready),
            languages,
        };
        self.locked(|s| s.facets = Some(SheetFacets { key, facets, index }));
    }

    /// The filter sheet every platform draws, for the list `art` / `choice` and the filter value `filter`
    /// (a status, plus the narrowing: [`ListFilter::raw_value`]). `offered` are the status filters the page offers.
    pub async fn filter_sheet(
        &self,
        art: &str,
        choice: &str,
        filter: &str,
        offered: &[LibraryFilter],
    ) -> FilterSheet {
        let lf = ListFilter::from_raw(filter);
        let facets = match self.section_source(art, choice).await {
            Ok(Some(source)) if self.supports_facets(&source) => {
                let key = source.key();
                self.locked(|s| {
                    s.facets
                        .as_ref()
                        .filter(|f| f.key == key)
                        .map(|f| f.facets.clone())
                })
                .unwrap_or(FilterFacets {
                    years: Facet::Loading,
                    languages: Facet::Loading,
                })
            }
            _ => FilterFacets::default(),
        };
        let lang = self.host.locale.language().to_owned();
        FilterSheet::build(
            offered,
            lf.status,
            &lf.narrowing,
            &facets,
            &|key| self.words.title(key),
            &|code| crate::language_names::language_name(code, &lang),
        )
    }

    /// The filter value after a row of the sheet was picked.
    pub fn filter_pick(filter: &str, choice: &FilterChoice) -> String {
        ListFilter::from_raw(filter).picked(choice).raw_value()
    }

    /// What the filter pill shows for the filter value.
    pub fn filter_pill(&self, filter: &str) -> String {
        let lf = ListFilter::from_raw(filter);
        let lang = self.host.locale.language().to_owned();
        swiftly_library::pill_text(
            lf.status,
            &lf.narrowing,
            &|key| self.words.title(key),
            &|code| crate::language_names::language_name(code, &lang),
        )
    }

    /// The status part of a filter value (`LibraryFilter::raw_value`), for the page's own "offered" check.
    pub fn filter_status(filter: &str) -> String {
        ListFilter::from_raw(filter).status.raw_value().to_owned()
    }

    pub async fn section_page(
        &self,
        art: &str,
        choice: &str,
        sorting: &str,
        filter: &str,
        since: i64,
        count: i64,
    ) -> Result<String, ErrorKind> {
        let s = Sorting::from_raw(sorting).unwrap_or(Sorting::Name);
        let lf = ListFilter::from_raw(filter);
        let f = lf.status;
        let narrowed = !lf.narrowing.is_none();
        let source = self.section_source(art, choice).await?;
        let Some(source) = source else {
            return json(&SectionPage {
                title: vec![],
                total: 0,
                filtered: false,
                even_more: false,
                letters: None,
            });
        };
        let index = if lf.narrowing.language.is_some() {
            self.language_index_for(&source).await
        } else {
            None
        };
        let natural: Option<Vec<Item>> = if s == Sorting::Name && self.collator.is_some() {
            let list = self
                .natural_cached(
                    &format!("{}|{}", source.key(), f.raw_value()),
                    since,
                    &source,
                    f,
                )
                .await?;
            Some(if narrowed {
                list.into_iter()
                    .filter(|i| lf.narrowing.keeps(i, index.as_deref()))
                    .collect()
            } else {
                list
            })
        } else {
            None
        };
        let letters = if since > 0 {
            None
        } else if let Some(list) = &natural {
            Some(Self::letters(list, Sorting::Name))
        } else if narrowed {
            None
        } else {
            self.other_letters(&source, s, f).await
        };
        let years_wanted = lf.years();
        let page = |start: i64, amount: i64| {
            let (source, natural, years) = (&source, &natural, &years_wanted);
            async move {
                if let Some(list) = natural {
                    return self
                        .natural_page(
                            list,
                            usize::try_from(start).unwrap_or(0),
                            usize::try_from(amount).unwrap_or(0),
                        )
                        .await;
                }
                self.items(&ItemsQuery {
                    parent_id: source.parent.clone(),
                    limit: amount,
                    start_index: start,
                    sort_by: s.input_field().into(),
                    sort_order: source.bearing(s).into(),
                    filters: f.jellyfin_filter(),
                    is_watched: f.is_watched(),
                    years: years.clone(),
                    recursive: source.recursive(),
                    include_item_types: source.types().iter().map(|t| (*t).to_owned()).collect(),
                    ..ItemsQuery::default()
                })
                .await
            }
        };
        if !source.is_filtering() && !narrowed {
            let answer = page(since, count).await?;
            return json(&SectionPage {
                title: answer.items.iter().map(|i| self.tile(i, s)).collect(),
                total: answer.total_record_count,
                filtered: false,
                even_more: false,
                letters,
            });
        }
        let key = format!("{}|{}|{}", source.key(), s.raw_value(), lf.raw_value());
        let before = self.locked(|st| {
            st.filter
                .as_ref()
                .map(|b| (b.key.clone(), b.filter.clone(), b.offset))
        });
        let (mut filter_ref, mut offset, mut first);
        first = count;
        if since == 0 {
            filter_ref = if narrowed {
                self.title_filter_listed(&source, &lf, index.as_deref())
                    .await?
            } else {
                self.title_filter(&source, &f.jellyfin_filter(), f.is_watched())
                    .await?
            };
            offset = 0;
            if let Some((k, _, o)) = &before
                && *k == key
            {
                first = count.max(*o);
            }
        } else {
            match before {
                Some((k, fr, o)) if k == key => {
                    filter_ref = fr;
                    offset = o;
                }
                _ => {
                    return json(&SectionPage {
                        title: vec![],
                        total: 0,
                        filtered: true,
                        even_more: false,
                        letters: None,
                    });
                }
            }
        }
        let mut new: Vec<Item> = Vec::new();
        let mut raw;
        let mut amount = first;
        loop {
            let answer = page(offset, amount).await?;
            new.extend(filter_ref.sift(&answer.items));
            offset += i64::try_from(answer.items.len()).unwrap_or(0);
            raw = answer.total_record_count;
            amount = count;
            if answer.items.is_empty()
                || !(i64::try_from(new.len()).unwrap_or(0) < count / 2 && offset < raw)
            {
                break;
            }
        }
        let total = filter_ref.total;
        self.locked(|st| {
            st.filter = Some(FilterState {
                key,
                filter: filter_ref,
                offset,
            })
        });
        json(&SectionPage {
            title: new.iter().map(|i| self.tile(i, s)).collect(),
            total,
            filtered: true,
            even_more: ListRules::still_more_present(offset, raw),
            letters,
        })
    }

    fn cards(&self, entries: Vec<(&Item, usize)>) -> Vec<CardEntry> {
        entries
            .into_iter()
            .map(|(item, count)| CardEntry {
                id: item.id.clone(),
                name: item.name.clone(),
                poster: ImageSelection::portrait(item, &self.addresses, 480).map(|u| u.to_string()),
                count,
            })
            .collect()
    }

    pub async fn collections(&self, art: &str) -> Result<String, ErrorKind> {
        self.offering_load().await;
        let directory = self.directory();
        let list: Vec<&ItemCollection> = directory
            .as_ref()
            .map(|d| d.collections(art))
            .unwrap_or_default();
        json(&self.cards(list.into_iter().map(|c| (&c.item, c.count(art))).collect()))
    }

    pub async fn playlists(&self, art: &str) -> Result<String, ErrorKind> {
        self.offering_load().await;
        let directory = self.locked(|s| s.playlists.clone());
        let list: Vec<&VideoPlaylist> = directory
            .as_ref()
            .map(|d| d.playlists(art))
            .unwrap_or_default();
        json(&self.cards(list.into_iter().map(|p| (&p.item, p.count(art))).collect()))
    }

    fn playlist_shown(entries: &[Item], art: &str) -> Vec<Item> {
        match art {
            "movies" | "tvshows" => VideoPlaylist::shown(entries, Some(art)),
            _ => entries.to_vec(),
        }
    }

    pub async fn playlist_page(&self, id: &str, art: &str) -> Result<String, ErrorKind> {
        let shown = Self::playlist_shown(&self.playlist_entries(id).await?, art);
        json(&Page {
            title: shown.iter().map(|i| self.tile(i, Sorting::Name)).collect(),
            total: i64::try_from(shown.len()).unwrap_or(0),
            letters: None,
        })
    }

    /// The first entry's id, empty for an empty list or no answer; the entries are kept as the player's run.
    pub async fn playlist_start(&self, id: &str, art: &str) -> String {
        let Ok(all) = self.playlist_entries(id).await else {
            return String::new();
        };
        let shown = Self::playlist_shown(&all, art);
        let Some(first) = shown.first() else {
            return String::new();
        };
        let first = first.id.clone();
        self.locked(|s| s.run = shown);
        first
    }

    /// The entries of the playlist started last, in order.
    pub fn playlist_run(&self) -> Vec<Item> {
        self.locked(|s| s.run.clone())
    }

    async fn collection_title(&self, id: &str, art: Option<&str>) -> Result<Vec<Item>, ErrorKind> {
        let source = ShelfSource::new(Some(id), art, true, &[]);
        Ok(self
            .items(&ItemsQuery {
                parent_id: source.parent.clone(),
                limit: 100,
                sort_by: Sorting::Erscheinung.input_field().into(),
                sort_order: source.bearing(Sorting::Erscheinung).into(),
                recursive: source.recursive(),
                include_item_types: source.types().iter().map(|t| (*t).to_owned()).collect(),
                ..ItemsQuery::default()
            })
            .await?
            .items)
    }

    pub async fn collection_mosaic(&self, id: &str, art: &str, height: i64) -> String {
        let Ok(list) = self
            .collection_title(id, (!art.is_empty()).then_some(art))
            .await
        else {
            return "[]".into();
        };
        let posters: Vec<Option<String>> = list
            .iter()
            .take(4)
            .map(|i| ImageSelection::portrait(i, &self.addresses, height).map(|u| u.to_string()))
            .collect();
        serde_json::to_string(&posters).unwrap_or_else(|_| "[]".into())
    }

    pub async fn collection_page(
        &self,
        id: &str,
        art: &str,
        sorting: &str,
        filter: &str,
        since: i64,
        count: i64,
    ) -> Result<String, ErrorKind> {
        let s = Sorting::from_raw(sorting).unwrap_or(Sorting::Erscheinung);
        let f = LibraryFilter::from_raw(filter).unwrap_or(LibraryFilter::All);
        let source = ShelfSource::new(Some(id), (!art.is_empty()).then_some(art), true, &[]);
        if s == Sorting::Name && self.collator.is_some() {
            let list = self
                .natural_cached(
                    &format!("{}|{}", source.key(), f.raw_value()),
                    since,
                    &source,
                    f,
                )
                .await?;
            let answer = self
                .natural_page(
                    &list,
                    usize::try_from(since).unwrap_or(0),
                    usize::try_from(count).unwrap_or(0),
                )
                .await?;
            return json(&Page {
                title: answer
                    .items
                    .iter()
                    .map(|i| self.tile(i, Sorting::Name))
                    .collect(),
                total: answer.total_record_count,
                letters: (since == 0).then(|| Self::letters(&list, Sorting::Name)),
            });
        }
        let answer = self
            .items(&ItemsQuery {
                parent_id: source.parent.clone(),
                limit: count,
                start_index: since,
                sort_by: s.input_field().into(),
                sort_order: source.bearing(s).into(),
                filters: f.jellyfin_filter(),
                is_watched: f.is_watched(),
                recursive: source.recursive(),
                include_item_types: source.types().iter().map(|t| (*t).to_owned()).collect(),
                ..ItemsQuery::default()
            })
            .await?;
        let letters = if since == 0 {
            self.other_letters(&source, s, f).await
        } else {
            None
        };
        json(&Page {
            title: answer.items.iter().map(|i| self.tile(i, s)).collect(),
            total: answer.total_record_count,
            letters,
        })
    }

    pub async fn collections_for_title(&self, id: &str) -> String {
        let Ok(title) = self.item(id).await else {
            return "[]".into();
        };
        let Some(art) = LibraryGenre::art_to_type(title.type_.as_deref()) else {
            return "[]".into();
        };
        self.offering_load().await;
        let Some(directory) = self.directory() else {
            return "[]".into();
        };
        let mut rails = Vec::new();
        for collection in directory.collections_with(&title).into_iter().take(2) {
            let Ok(list) = self.collection_title(collection.id(), Some(art)).await else {
                continue;
            };
            let other: Vec<Item> = ListRules::without_double(&list)
                .into_iter()
                .filter(|i| i.id != title.id)
                .collect();
            if !other.is_empty() {
                rails.push(CollectionRail {
                    id: collection.id().to_owned(),
                    name: collection.item.name.clone(),
                    art: art.to_owned(),
                    title: other.iter().map(|i| self.tile(i, Sorting::Name)).collect(),
                });
            }
        }
        serde_json::to_string(&rails).unwrap_or_else(|_| "[]".into())
    }
}

fn sorting_of(s: Sorting) -> swiftly_library::library_filter::Sorting {
    s
}
