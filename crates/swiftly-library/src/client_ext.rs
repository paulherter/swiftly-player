//! The client-side extensions that Swift hangs on `JellyfinClient` (`Items.swift:150-246`,
//! `RailsEpisode.swift:127-159`, `NaturalOrder.swift:74-116`, `CollectionDirectory.swift:94-160`,
//! `PlaylistDirectory.swift:88-102`, `People.swift:52`, `SeriesState.swift:9-30`,
//! `SectionOffering.swift:261-278`) as free functions over [`JellyfinClient`], and the
//! [`HomePageSource`] implementation of the client (`HomePageLoader.swift:30-61`).

use std::collections::{HashMap, HashSet};
use std::future::Future;

use futures_util::StreamExt;
use futures_util::future::{join, join_all};
use futures_util::stream::FuturesUnordered;
use swiftly_jellyfin::{ItemsQuery, JellyfinClient};
use swiftly_model::{Item, Items, ItemsResponse, SeriesNumber};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_rules::natural_order::{NaturalCollator, NaturalOrder};

use crate::collection_directory::{CollectionDirectory, ItemCollection};
use crate::home::HomePageSource;
use crate::library_filter::{Sorting, SortingExt};
use crate::library_genre::{LibraryGenre, LibraryShare};
use crate::list_rules::ListRules;
use crate::playlist_directory::{PlaylistDirectory, VideoPlaylist};
use crate::shelf::{ShelfSource, TitleFilter};

/// At most this many member queries at once; a small server cannot take more
/// (`CollectionDirectory.swift:122`).
const WIDTH: usize = 6;

/// One entry per work, with what the rule needs from the server (`jeItemInTimes`,
/// `Items.swift:175-206`). Without duplicates this costs no request. If a fetch fails, entries
/// are merged anyway and the earlier one stays. `libraries` are the account's views if the
/// caller already has them.
pub async fn items_in_times<T: HttpTransport>(
    client: &JellyfinClient<T>,
    items: &[Item],
    episodes_per_series: bool,
    libraries: Option<&[Item]>,
) -> Vec<Item> {
    let suspicion = Items::series_suspicion(items);
    let mut series_list: SeriesNumber = HashMap::new();
    let mut libs: Option<Vec<Item>> = libraries.map(<[Item]>::to_vec);
    if !suspicion.is_empty() {
        let ids: Vec<String> = suspicion.into_iter().collect();
        let needs_views = libs.is_none();
        let (fetched, view_list) = join(async { client.identifiers(&ids).await.ok() }, async {
            if needs_views {
                client.user_views(false).await.ok()
            } else {
                None
            }
        })
        .await;
        for s in fetched.unwrap_or_default() {
            series_list.insert(s.id.clone(), s.provider_ids.clone().unwrap_or_default());
        }
        if needs_views {
            libs = view_list;
        }
    }
    let twice = Items::with_double(items, &series_list, episodes_per_series);
    if twice.is_empty() {
        return items.to_vec();
    }
    let view_ref = match libs {
        Some(l) => l,
        None => client.user_views(false).await.unwrap_or_default(),
    };
    let under: HashSet<String> = view_ref.iter().map(|v| v.id.clone()).collect();
    let ids: Vec<String> = twice.iter().map(|i| i.id.clone()).collect();
    let origin = origin(client, &ids, &under).await;
    Items::merge(items, &origin, &view_ref, &series_list, episodes_per_series)
}

/// Which library an entry comes from, via its ancestors (`origin(from:under:)`, `Items.swift:211-224`).
pub async fn origin<T: HttpTransport>(
    client: &JellyfinClient<T>,
    ids: &[String],
    under: &HashSet<String>,
) -> HashMap<String, String> {
    if under.is_empty() {
        return HashMap::new();
    }
    let unique: Vec<&String> = ids.iter().collect::<HashSet<_>>().into_iter().collect();
    let found = join_all(unique.into_iter().map(|id| async move {
        let ancestors = client.ancestors(id).await.unwrap_or_default();
        let from = ancestors
            .into_iter()
            .find(|a| under.contains(&a.id))
            .map(|a| a.id);
        (id.clone(), from)
    }))
    .await;
    found
        .into_iter()
        .filter_map(|(id, from)| Some((id, from?)))
        .collect()
}

/// What was added most recently, one row per series (`lastAdded`, `RailsEpisode.swift:138-159`).
/// `None` if a fetch failed, an empty list if there is nothing. `genres` is the
/// `IncludeItemTypes` value (`Movie,Episode`).
pub async fn last_added<T: HttpTransport>(
    client: &JellyfinClient<T>,
    library: Option<&str>,
    fetch: i64,
    show_item: i64,
    genres: &str,
) -> Option<Vec<Item>> {
    let raw = client
        .newly_joined(library, fetch, true, genres)
        .await
        .ok()?;
    let pre_off = if library.is_none() {
        items_in_times(client, &ListRules::je_series_in_times(&raw), true, None).await
    } else {
        raw
    };
    let selected = ListRules::je_title_in_times(&pre_off, usize::try_from(show_item).unwrap_or(0));
    if selected.is_empty() {
        return Some(Vec::new());
    }
    let full = client
        .items(&ItemsQuery {
            limit: i64::try_from(selected.len()).unwrap_or(i64::MAX),
            ids: selected.iter().map(|i| i.id.clone()).collect(),
            ..ItemsQuery::default()
        })
        .await
        .ok()?;
    Some(ListRules::in_rails_episode(&full.items, &selected))
}

/// The watchlist, one entry per work, and still paged (`rememberedItems`, `Items.swift:226-246`).
pub async fn remembered_items<T: HttpTransport>(
    client: &JellyfinClient<T>,
    types: &[String],
    sort_by: &str,
    sort_order: &str,
    start_index: usize,
    limit: usize,
    libraries: Option<&[Item]>,
) -> Result<ItemsResponse, ErrorKind> {
    let all = client.remembered_ids(types, sort_by, sort_order).await?;
    let media_works = items_in_times(client, &all, false, libraries).await;
    let total = i64::try_from(media_works.len()).unwrap_or(i64::MAX);
    let page: Vec<Item> = media_works
        .into_iter()
        .skip(start_index)
        .take(limit)
        .collect();
    if page.is_empty() {
        return Ok(ItemsResponse::new(Vec::new(), total));
    }
    let full = client
        .items(&ItemsQuery {
            limit: i64::try_from(page.len()).unwrap_or(i64::MAX),
            ids: page.iter().map(|i| i.id.clone()).collect(),
            ..ItemsQuery::default()
        })
        .await?;
    Ok(ItemsResponse::new(
        ListRules::in_rails_episode(&full.items, &page),
        total,
    ))
}

/// The whole list in "By name" order: one slim request, sorted here (`naturalList`,
/// `NaturalOrder.swift:79-91`). Equal names keep the server's order.
#[allow(clippy::too_many_arguments)]
pub async fn natural_list<T: HttpTransport>(
    client: &JellyfinClient<T>,
    collator: &NaturalCollator,
    parent_id: Option<&str>,
    sort_order: &str,
    filters: &[String],
    is_watched: Option<bool>,
    recursive: bool,
    include_item_types: &[&str],
) -> Result<Vec<Item>, ErrorKind> {
    let answer = client
        .items(&ItemsQuery {
            parent_id: parent_id.map(String::from),
            sort_by: Sorting::Name.input_field().into(),
            sort_order: sort_order.into(),
            filters: filters.to_vec(),
            is_watched,
            recursive,
            include_item_types: include_item_types.iter().map(|s| (*s).into()).collect(),
            slim: true,
            ..ItemsQuery::default()
        })
        .await?;
    Ok(NaturalOrder::sorted(answer.items, collator, |i| {
        (i.name.as_str(), i.sort_name.as_deref())
    }))
}

/// One page of such a list, fetched by id in batches of [`NaturalOrder::NATURAL_BATCH`] and put
/// back into the list's order; `total_record_count` is the list's length (`naturalPage`,
/// `NaturalOrder.swift:96-113`).
pub async fn natural_page<T: HttpTransport>(
    client: &JellyfinClient<T>,
    list: &[Item],
    since: usize,
    count: usize,
) -> Result<ItemsResponse, ErrorKind> {
    let total = i64::try_from(list.len()).unwrap_or(i64::MAX);
    let slice: Vec<&Item> = list.iter().skip(since).take(count).collect();
    if slice.is_empty() {
        return Ok(ItemsResponse::new(Vec::new(), total));
    }
    let batches: Vec<Vec<String>> = slice
        .chunks(NaturalOrder::NATURAL_BATCH)
        .map(|c| c.iter().map(|i| i.id.clone()).collect())
        .collect();
    let parts = join_all(batches.iter().map(|ids| async move {
        let query = ItemsQuery {
            limit: i64::try_from(ids.len()).unwrap_or(i64::MAX),
            ids: ids.clone(),
            ..ItemsQuery::default()
        };
        client.items(&query).await
    }))
    .await;
    let mut by_id: HashMap<String, Item> = HashMap::new();
    for part in parts {
        for item in part?.items {
            by_id.entry(item.id.clone()).or_insert(item);
        }
    }
    let items = slice
        .iter()
        .filter_map(|s| by_id.get(&s.id).cloned())
        .collect();
    Ok(ItemsResponse::new(items, total))
}

/// New titles of a genre, `None` if the server did not answer (`title(genre:limit:)`,
/// `People.swift:52-61`).
pub async fn title_genre<T: HttpTransport>(
    client: &JellyfinClient<T>,
    genre: &str,
    limit: i64,
) -> Option<Vec<Item>> {
    let answer = client
        .items(&ItemsQuery {
            limit,
            sort_by: "DateCreated".into(),
            sort_order: "Descending".into(),
            recursive: true,
            include_item_types: vec!["Movie".into(), "Series".into()],
            genres: vec![genre.into()],
            ..ItemsQuery::default()
        })
        .await
        .ok()?;
    Some(ListRules::without_double(&answer.items))
}

/// A page of the filmography with the server's total: each work once within the page, copies in
/// a second library merged (`titleWithNumber(person:limit:startIndex:)`, `People.swift:68-79`).
/// `None` if the server did not answer.
pub async fn title_person_page<T: HttpTransport>(
    client: &JellyfinClient<T>,
    person: &str,
    limit: i64,
    start_index: i64,
) -> Option<(Vec<Item>, i64)> {
    let answer = client
        .items(&ItemsQuery {
            limit,
            start_index,
            sort_by: "ProductionYear,SortName".into(),
            sort_order: "Descending".into(),
            recursive: true,
            include_item_types: vec!["Movie".into(), "Series".into()],
            person_ids: vec![person.into()],
            ..ItemsQuery::default()
        })
        .await
        .ok()?;
    let total = answer
        .total_record_count
        .max(i64::try_from(answer.items.len()).unwrap_or(i64::MAX));
    let without = ListRules::without_double(&answer.items);
    Some((items_in_times(client, &without, false, None).await, total))
}

/// A page of a genre, newest first, with the server's total; otherwise like
/// [`title_person_page`] (`titleWithNumber(genre:limit:startIndex:)`, `People.swift:83-94`).
pub async fn title_genre_page<T: HttpTransport>(
    client: &JellyfinClient<T>,
    genre: &str,
    limit: i64,
    start_index: i64,
) -> Option<(Vec<Item>, i64)> {
    let answer = client
        .items(&ItemsQuery {
            limit,
            start_index,
            sort_by: "DateCreated".into(),
            sort_order: "Descending".into(),
            recursive: true,
            include_item_types: vec!["Movie".into(), "Series".into()],
            genres: vec![genre.into()],
            ..ItemsQuery::default()
        })
        .await
        .ok()?;
    let total = answer
        .total_record_count
        .max(i64::try_from(answer.items.len()).unwrap_or(i64::MAX));
    let without = ListRules::without_double(&answer.items);
    Some((items_in_times(client, &without, false, None).await, total))
}

/// Runs `fetch` for every id, at most [`WIDTH`] at once. If one fails, everything fails: a
/// partial directory would look complete.
async fn windowed<F, Fut>(ids: &[String], fetch: F) -> Result<HashMap<String, Vec<Item>>, ErrorKind>
where
    F: Fn(String) -> Fut,
    Fut: Future<Output = Result<(String, Vec<Item>), ErrorKind>>,
{
    let mut rest = ids.iter();
    let mut running = FuturesUnordered::new();
    let mut members = HashMap::new();
    for _ in 0..WIDTH {
        if let Some(id) = rest.next() {
            running.push(fetch(id.clone()));
        }
    }
    while let Some(done) = running.next().await {
        let (id, list) = done?;
        members.insert(id, list);
        if let Some(id) = rest.next() {
            running.push(fetch(id.clone()));
        }
    }
    Ok(members)
}

/// All collections with their members (`collectionDirectory(viewList:)`,
/// `CollectionDirectory.swift:121-146`). `view_list` are the views including hidden ones: if the
/// recursive search returns nothing, the `boxsets` folder is searched.
pub async fn collection_directory<T: HttpTransport>(
    client: &JellyfinClient<T>,
    view_list: &[Item],
) -> Result<CollectionDirectory, ErrorKind> {
    let mut crates = client
        .items(&ItemsQuery {
            limit: 2000,
            recursive: true,
            include_item_types: vec!["BoxSet".into()],
            ..ItemsQuery::default()
        })
        .await?
        .items;
    if crates.is_empty() {
        let folder = view_list.iter().find(|v| {
            v.collection_type
                .as_deref()
                .map(str::to_lowercase)
                .as_deref()
                == Some("boxsets")
        });
        if let Some(folder) = folder {
            crates = client
                .items(&ItemsQuery {
                    parent_id: Some(folder.id.clone()),
                    limit: 2000,
                    include_item_types: vec!["BoxSet".into()],
                    ..ItemsQuery::default()
                })
                .await?
                .items;
        }
    }
    let ids: Vec<String> = crates.iter().map(|c| c.id.clone()).collect();
    let members = windowed(&ids, |id| async move {
        let list = client.collection_members(&id).await?;
        Ok((id, list))
    })
    .await?;
    Ok(CollectionDirectory {
        all: crates
            .into_iter()
            .map(|c| {
                let m = members.get(&c.id).cloned().unwrap_or_default();
                ItemCollection::new(c, &m)
            })
            .collect(),
    })
}

/// Movies and series per library that can contain both (`libraryShares`,
/// `CollectionDirectory.swift:148-170`). A library that does not answer is missing.
pub async fn library_shares<T: HttpTransport>(
    client: &JellyfinClient<T>,
    views: &[Item],
) -> HashMap<String, LibraryShare> {
    let mixed = views
        .iter()
        .filter(|v| LibraryGenre::can_be_mixed(v.collection_type.as_deref()));
    let found = join_all(mixed.map(|view| async move {
        let (m, s) = join(
            client.count(&view.id, &["Movie".to_string()]),
            client.count(&view.id, &["Series".to_string()]),
        )
        .await;
        match (m, s) {
            (Ok(movies), Ok(series_list)) => Some((
                view.id.clone(),
                LibraryShare {
                    movies,
                    series_list,
                },
            )),
            _ => None,
        }
    }))
    .await;
    found.into_iter().flatten().collect()
}

/// The entries of a playlist, only video (`playlistEntries`, JellyfinClient.swift:637).
pub async fn playlist_entries_video<T: HttpTransport>(
    client: &JellyfinClient<T>,
    playlist: &str,
    lean: bool,
) -> Result<Vec<Item>, ErrorKind> {
    Ok(client
        .playlist_entries(playlist, lean)
        .await?
        .into_iter()
        .filter(VideoPlaylist::is_video_entry)
        .collect())
}

/// The video playlists of the account, each with its entry types (`playlistDirectory`,
/// `PlaylistDirectory.swift:88-102`).
pub async fn playlist_directory<T: HttpTransport>(
    client: &JellyfinClient<T>,
) -> Result<PlaylistDirectory, ErrorKind> {
    let found: Vec<Item> = client
        .items(&ItemsQuery {
            limit: 500,
            recursive: true,
            include_item_types: vec!["Playlist".into()],
            ..ItemsQuery::default()
        })
        .await?
        .items
        .into_iter()
        .filter(VideoPlaylist::is_video)
        .collect();
    let ids: Vec<String> = found.iter().map(|p| p.id.clone()).collect();
    let members = windowed(&ids, |id| async move {
        let list = playlist_entries_video(client, &id, true).await?;
        Ok((id, list))
    })
    .await?;
    Ok(PlaylistDirectory {
        all: found
            .into_iter()
            .map(|p| {
                let m = members.get(&p.id).cloned().unwrap_or_default();
                VideoPlaylist::new(p, &m)
            })
            .collect(),
    })
}

/// The filter for "All": the ids of every chosen library, fetched side by side, in the order of
/// `source.only_out` (`titleFilter`, `SectionOffering.swift:261-278`).
pub async fn title_filter<T: HttpTransport>(
    client: &JellyfinClient<T>,
    source: &ShelfSource,
    filters: &[String],
    is_watched: Option<bool>,
) -> Result<TitleFilter, ErrorKind> {
    let types: Vec<String> = source.types().iter().map(|t| (*t).to_string()).collect();
    let parts = join_all(
        source
            .only_out
            .iter()
            .map(|id| client.title_ids(id, &types, filters, is_watched)),
    )
    .await;
    let mut libraries = Vec::new();
    for (id, part) in source.only_out.iter().zip(parts) {
        libraries.push((id.clone(), part?));
    }
    Ok(TitleFilter::new(&libraries))
}

/// The episode one is at in this series; the first episode if finished (`stateInSeries`,
/// `SeriesState.swift:12-18`). `None` if nothing came back.
pub async fn state_in_series<T: HttpTransport>(
    client: &JellyfinClient<T>,
    series_id: &str,
) -> Option<Item> {
    if let Ok(Some(opened)) = client.next_episode_series(series_id).await {
        return Some(opened);
    }
    client.first_episode(series_id).await.ok().flatten()
}

/// The same, but a failed request fails; `Ok(None)` only means: the series has no episodes
/// (`stateInSeriesChecked`, `SeriesState.swift:24-29`).
pub async fn state_in_series_checked<T: HttpTransport>(
    client: &JellyfinClient<T>,
    series_id: &str,
) -> Result<Option<Item>, ErrorKind> {
    if let Some(opened) = client.next_episode_series(series_id).await? {
        return Ok(Some(opened));
    }
    client.first_episode(series_id).await
}

impl<T: HttpTransport> HomePageSource for JellyfinClient<T> {
    async fn resume_items(&self, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        let raw = JellyfinClient::resume_items(self, limit).await?;
        Ok(items_in_times(self, &raw, false, None).await)
    }
    async fn next_up(&self, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        let raw = JellyfinClient::next_up(self, limit).await?;
        Ok(items_in_times(self, &raw, false, None).await)
    }
    async fn last_added(
        &self,
        library: Option<&str>,
        fetch: i64,
        show_item: i64,
    ) -> Option<Vec<Item>> {
        last_added(self, library, fetch, show_item, "Movie,Episode").await
    }
    async fn title(&self, genre: &str, limit: i64) -> Option<Vec<Item>> {
        title_genre(self, genre, limit).await
    }
    async fn libraries(&self) -> Option<Vec<Item>> {
        self.user_views(false).await.ok()
    }
    async fn new_arrivals(&self, genre: &str, fetch: i64, show_item: i64) -> Option<Vec<Item>> {
        last_added(self, None, fetch, show_item, genre).await
    }
    /// Like the series page: `/Items`, `Series` only, recursive, by the time of the latest new
    /// episode (`HomePageLoader.swift:54-60`).
    async fn new_series(&self, library: Option<&str>, show_item: i64) -> Option<Vec<Item>> {
        self.items(&ItemsQuery {
            parent_id: library.map(String::from),
            limit: show_item,
            sort_by: "DateLastContentAdded".into(),
            sort_order: "Descending".into(),
            recursive: true,
            include_item_types: vec!["Series".into()],
            ..ItemsQuery::default()
        })
        .await
        .ok()
        .map(|r| r.items)
    }
    /// The most recently added movies and series of the library; for a collection, its members
    /// (`HomePageLoader.swift:32-38`).
    async fn latest_title(
        &self,
        library: &str,
        collection: bool,
        show_item: i64,
    ) -> Option<Vec<Item>> {
        self.items(&ItemsQuery {
            parent_id: Some(library.into()),
            limit: show_item,
            sort_by: "DateCreated".into(),
            sort_order: "Descending".into(),
            recursive: !collection,
            include_item_types: vec!["Movie".into(), "Series".into(), "Video".into()],
            ..ItemsQuery::default()
        })
        .await
        .ok()
        .map(|r| r.items)
    }
}
