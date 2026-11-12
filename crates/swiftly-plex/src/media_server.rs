//! **`PlexClient` as a `MediaServer`** (`PlexClient+MediaServer.swift`).
//!
//! The app asks the trait, never the class. Where Plex has no counterpart the method gives the
//! neutral answer (an empty list, `None`, no change) or fails with [`PlexError::Unsupported`]
//! (travelling as `ErrorKind::Transport(Other("plex:unsupported"))`, see
//! [`PlexError::into_kind`]); the capability is missing from [`PlexFeatures`] then, so the app
//! does not offer it.

use std::collections::{BTreeMap, HashMap, HashSet};

use futures_util::future::join_all;
use swiftly_jellyfin::{
    ItemsQuery, PendingReport, PostReportRules, ServerKind, Session, TrackIndices,
};
use swiftly_library::home::HomePageSource;
use swiftly_library::library_filter::SortingExt;
use swiftly_library::{
    CollectionDirectory, ItemCollection, LibraryShare, PlaylistDirectory, ShelfSource, TitleFilter,
    VideoPlaylist,
};
use swiftly_model::{Item, ItemsResponse, PublicSystemInfo, parse_timestamp};
use swiftly_net::{ErrorKind, HttpTransport, Method};
use swiftly_playback::device_profile::DeviceProfile;
use swiftly_playback::media_server::{MediaServer, ServerCapability};
use swiftly_playback::offering_layer::AccountPreGift;
use swiftly_playback::playback_plan::PlaybackPlan;
use swiftly_playback::sections::Segment;
use swiftly_playback::trickplay::Trickplay;
use swiftly_rules::alphabet_index::Sorting;
use swiftly_rules::chapter::Chapter;
use swiftly_rules::download_quality::DownloadQuality;
use swiftly_rules::natural_order::{NaturalCollator, NaturalOrder};

use crate::client::{ImageKind, PlexClient};
use crate::features::PlexFeatures;
use crate::identity::PlexError;
use crate::mapping::PlexMapper;
use crate::merge;
use crate::playback::TimelineState;
use crate::wire::{PlexMetadata, PlexSection};

enum Parent {
    Section(PlexSection),
    Collection(String),
    Children(String),
}

fn kind(e: PlexError) -> ErrorKind {
    e.into_kind()
}

impl<T: HttpTransport + 'static> PlexClient<T> {
    // MARK: items

    /// A page of titles (PlexClient+MediaServer.swift:90).
    ///
    /// `parent_id` is a library (a number from `/library/sections`) or a collection; without it,
    /// all film and series libraries one after the other. Jellyfin's words (`SortName`,
    /// `IsFavorite` ...) are turned into Plex's here, so the callers stay the same.
    pub async fn items_page(&self, q: &ItemsQuery) -> Result<ItemsResponse, PlexError> {
        if !q.ids.is_empty() {
            return self.items_by_id(&q.ids).await;
        }
        let mut query: Vec<(String, String)> = vec![(
            "sort".into(),
            Self::sort_expression(&q.sort_by, &q.sort_order),
        )];
        if q.filters.iter().any(|f| f == "IsResumable") {
            query.push(("inProgress".into(), "1".into()));
        }
        if q.filters.iter().any(|f| f == "IsFavorite") {
            query.push(("userRating>>".into(), "9".into()));
        }
        if let Some(watched) = q.is_watched {
            query.push(("unwatched".into(), if watched { "0" } else { "1" }.into()));
        }
        if !q.person_ids.is_empty() {
            query.push(("actor".into(), q.person_ids.join(",")));
        }

        if let Some(parent_id) = &q.parent_id {
            return match self.parent(parent_id, q.recursive).await? {
                Parent::Section(section) => {
                    self.page_of(
                        &[section],
                        &q.include_item_types,
                        &query,
                        &q.genres,
                        q.start_index,
                        q.limit,
                    )
                    .await
                }
                Parent::Children(id) => {
                    let all = self.children(&id).await?;
                    Ok(Self::slice(
                        &all,
                        q.start_index,
                        q.limit,
                        &q.include_item_types,
                    ))
                }
                Parent::Collection(id) => {
                    let all = self.collection_items(&id).await?;
                    Ok(Self::slice(
                        &all,
                        q.start_index,
                        q.limit,
                        &q.include_item_types,
                    ))
                }
            };
        }
        let all: Vec<PlexSection> = self
            .sections()
            .await?
            .into_iter()
            .filter(|s| s.type_ == "movie" || s.type_ == "show")
            .collect();
        self.page_of(
            &all,
            &q.include_item_types,
            &query,
            &q.genres,
            q.start_index,
            q.limit,
        )
        .await
    }

    /// What an id from the app names. Library numbers and `ratingKey`s are both small numbers,
    /// so a collection page (which never asks recursively) is checked on the server when the
    /// number is also a library's (:470).
    async fn parent(&self, id: &str, recursive: bool) -> Result<Parent, PlexError> {
        let known = self.sections().await?;
        let section = known.into_iter().find(|s| s.key == id);
        if let Some(section) = &section
            && recursive
        {
            return Ok(Parent::Section(section.clone()));
        }
        let mut kind = self.kind_cache_get(id);
        if kind.is_none() {
            // A failed look-up is not remembered; an answer is.
            if let Ok(found) = self
                .listing(&format!("/library/metadata/{id}"), &[], None, None)
                .await
                && let Some(first) = found.metadata.first()
            {
                self.kind_cache_set(id, &first.type_);
                kind = Some(first.type_.clone());
            }
        }
        Ok(match kind.as_deref() {
            Some("collection") => Parent::Collection(id.into()),
            Some("show") | Some("season") => Parent::Children(id.into()),
            _ => match section {
                Some(s) => Parent::Section(s),
                None => Parent::Collection(id.into()),
            },
        })
    }

    /// One page across the libraries, **merged by the sort field**: Kids (old) and Serien (new)
    /// are one list in the order asked for, not two lists glued together. Each library answers
    /// its own sorted run; only the part of each run that can reach `start ..< start + size` is
    /// fetched (:495).
    async fn page_of(
        &self,
        sections: &[PlexSection],
        types: &[String],
        query: &[(String, String)],
        genres: &[String],
        start: i64,
        size: i64,
    ) -> Result<ItemsResponse, PlexError> {
        let mut planned: Vec<(String, Vec<(String, String)>)> = Vec::new();
        for section in sections {
            let Some(q) = self.section_query(section, types, query, genres).await? else {
                continue;
            };
            planned.push((format!("/library/sections/{}/all", section.key), q));
        }
        if planned.is_empty() {
            return Ok(ItemsResponse::new(vec![], 0));
        }
        let as_refs = |q: &[(String, String)]| -> Vec<(String, String)> { q.to_vec() };

        if planned.len() == 1 {
            let (path, q) = &planned[0];
            let q = as_refs(q);
            let refs: Vec<(&str, &str)> = q.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
            let answer = self.listing(path, &refs, Some(start), Some(size)).await?;
            return Ok(ItemsResponse::new(
                self.items_of(&answer),
                answer.total_size.unwrap_or(answer.size),
            ));
        }
        // Count every library first (no items), then fetch only the part of each sorted run
        // that can reach the page.
        let counts = join_all(planned.iter().map(|(path, q)| async move {
            let refs: Vec<(&str, &str)> = q.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
            self.listing(path, &refs, Some(0), Some(0)).await
        }))
        .await;
        let mut totals = Vec::with_capacity(counts.len());
        for answer in counts {
            let answer = answer?;
            totals.push(answer.total_size.unwrap_or(answer.size));
        }
        let (ranges, skipped) = merge::window(&totals, start, size);
        let fetched = join_all(
            planned
                .iter()
                .zip(&ranges)
                .map(|((path, q), range)| async move {
                    if range.is_empty() {
                        return Ok(Vec::new());
                    }
                    let refs: Vec<(&str, &str)> =
                        q.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
                    self.listing(
                        path,
                        &refs,
                        Some(range.start),
                        Some(range.end - range.start),
                    )
                    .await
                    .map(|l| l.metadata)
                }),
        )
        .await;
        let mut runs: Vec<Vec<PlexMetadata>> = Vec::with_capacity(fetched.len());
        for run in fetched {
            runs.push(run?);
        }
        let order = query
            .iter()
            .find(|(k, _)| k == "sort")
            .map(|(_, v)| v.as_str());
        let page = merge::page(&runs, skipped, order, start, size);
        Ok(ItemsResponse::new(
            page.iter().map(|m| self.mapper.item(m)).collect(),
            totals.iter().sum(),
        ))
    }

    /// The query for one library, or `None` if nothing asked for can be in it (films in a
    /// series library, a genre it does not have) (:542).
    async fn section_query(
        &self,
        section: &PlexSection,
        types: &[String],
        query: &[(String, String)],
        genres: &[String],
    ) -> Result<Option<Vec<(String, String)>>, PlexError> {
        let mut q = query.to_vec();
        let own: &[&str] = if section.type_ == "movie" {
            &["Movie"]
        } else {
            &["Series", "Season", "Episode"]
        };
        if !types.is_empty() {
            let fitting: Vec<&String> =
                types.iter().filter(|t| own.contains(&t.as_str())).collect();
            if fitting.is_empty()
                && types
                    .iter()
                    .any(|t| PlexMapper::plex_type_number(t).is_some())
            {
                return Ok(None);
            }
            // One asked-for kind is a type filter; several (or none we know) mean the
            // library's own kind.
            if fitting.len() == 1
                && let Some(number) = PlexMapper::plex_type_number(fitting[0])
            {
                q.push(("type".into(), number.to_string()));
            }
        }
        if !genres.is_empty() {
            let offered = self.genres_of_section(&section.key).await?;
            let keys: Vec<String> = genres
                .iter()
                .filter_map(|name| {
                    offered
                        .iter()
                        .find(|o| o.title.to_lowercase() == name.to_lowercase())
                        .map(|o| o.key.clone())
                })
                .collect();
            if keys.is_empty() {
                return Ok(None);
            }
            q.push(("genre".into(), keys.join(",")));
        }
        Ok(Some(q))
    }

    /// Titles by id, in batches (the address holds the ids) (:569).
    async fn items_by_id(&self, ids: &[String]) -> Result<ItemsResponse, PlexError> {
        let mut all = Vec::new();
        for batch in ids.chunks(100) {
            let answer = self
                .listing(
                    &format!("/library/metadata/{}", batch.join(",")),
                    &[],
                    None,
                    None,
                )
                .await?;
            all.extend(self.items_of(&answer));
        }
        let total = all.len() as i64;
        Ok(ItemsResponse::new(all, total))
    }

    /// The newest titles of one library or of all of one kind (:579).
    async fn newest(
        &self,
        library: Option<&str>,
        shows: Option<bool>,
        size: i64,
    ) -> Option<Vec<Item>> {
        let all = self.sections().await.ok()?;
        let chosen: Vec<&PlexSection> = all
            .iter()
            .filter(|s| {
                if let Some(lib) = library {
                    return s.key == lib;
                }
                match shows {
                    None => s.type_ == "movie" || s.type_ == "show",
                    Some(true) => s.type_ == "show",
                    Some(false) => s.type_ == "movie",
                }
            })
            .collect();
        // All libraries at once; the result keeps the library order, so it does not depend on
        // which answer comes first.
        let answers = join_all(chosen.iter().map(|s| async move {
            self.listing(
                &format!("/library/sections/{}/all", s.key),
                &[("sort", "addedAt:desc")],
                Some(0),
                Some(size),
            )
            .await
            .ok()
            .map(|l| l.metadata)
        }))
        .await;
        let mut rows = Vec::new();
        for run in answers {
            rows.push(run?);
        }
        Some(
            merge::newest(&rows, usize::try_from(size).unwrap_or(0))
                .iter()
                .map(|m| self.mapper.item(m))
                .collect(),
        )
    }

    fn slice(all: &[Item], start: i64, size: i64, types: &[String]) -> ItemsResponse {
        let kept: Vec<&Item> = all
            .iter()
            .filter(|i| {
                types.is_empty()
                    || i.type_.as_ref().is_some_and(|t| types.contains(t))
                    || i.type_.as_deref() == Some("Video")
            })
            .collect();
        let page = kept
            .iter()
            .skip(usize::try_from(start).unwrap_or(0))
            .take(usize::try_from(size).unwrap_or(0))
            .map(|i| (*i).clone())
            .collect();
        ItemsResponse::new(page, kept.len() as i64)
    }

    /// Jellyfin's `SortBy`/`SortOrder` as a Plex `sort`: `year:desc,titleSort:desc` (:613).
    pub fn sort_expression(sort_by: &str, sort_order: &str) -> String {
        let direction = if sort_order.to_lowercase().starts_with("desc") {
            "desc"
        } else {
            "asc"
        };
        sort_by
            .split(',')
            .filter(|f| !f.is_empty())
            .map(|field| {
                let name = match field {
                    "DateCreated" | "DateLastContentAdded" => "addedAt",
                    "CommunityRating" => "audienceRating",
                    "PremiereDate" => "originallyAvailableAt",
                    "ProductionYear" => "year",
                    "Random" => return "random".to_string(),
                    _ => "titleSort",
                };
                format!("{name}:{direction}")
            })
            .collect::<Vec<_>>()
            .join(",")
    }

    fn milliseconds_of(plan: &PlaybackPlan) -> Option<i64> {
        plan.source
            .as_ref()
            .and_then(|s| s.run_time_ticks)
            .map(|t| t / 10_000)
    }

    /// New additions, newest first. Each kind is asked for separately and the answers are woven
    /// together: one question for "films and episodes" would bring seasons instead of episodes
    /// (:140).
    pub async fn last_added_kinds(
        &self,
        library: Option<&str>,
        fetch: i64,
        show_item: i64,
        genres: &str,
    ) -> Option<Vec<Item>> {
        let kinds: Vec<&str> = genres.split(',').filter(|k| !k.is_empty()).collect();
        // Asked per library: measured, the unscoped list ignores `type` (and the home hub
        // answers nothing for episodes), so it would bring seasons instead of episodes.
        let all = self.sections().await.ok()?;
        // Every (kind, library) question at once: a serial chain made the first home row wait one round trip per
        // library and kind. The answers keep the order of the questions (kinds, then libraries), so the merge does
        // not depend on which one arrives first; one failed answer fails the whole row, as before.
        let mut questions: Vec<(&str, i64, &PlexSection)> = Vec::new();
        for kind in kinds {
            let Some(number) = PlexMapper::plex_type_number(kind) else {
                continue;
            };
            let wanted = if kind == "Movie" { "movie" } else { "show" };
            for section in all
                .iter()
                .filter(|s| s.type_ == wanted && library.is_none_or(|l| s.key == l))
            {
                questions.push((kind, number, section));
            }
        }
        let answers = join_all(questions.iter().map(|(kind, number, section)| async move {
            let answer = self
                .listing(
                    &format!("/library/sections/{}/recentlyAdded", section.key),
                    &[("type", &number.to_string())],
                    Some(0),
                    Some(fetch.min(show_item * 2)),
                )
                .await
                .ok()?;
            Some(
                answer
                    .metadata
                    .into_iter()
                    .filter(|m| PlexMapper::item_type(&m.type_) == *kind)
                    .collect::<Vec<PlexMetadata>>(),
            )
        }))
        .await;
        let rows: Vec<Vec<PlexMetadata>> = answers.into_iter().collect::<Option<_>>()?;
        Some(
            merge::newest(&rows, usize::try_from(show_item).unwrap_or(0))
                .iter()
                .map(|m| self.mapper.item(m))
                .collect(),
        )
    }

    /// The titles of a person or genre with the total (:265-283).
    async fn titles_with_number(&self, query: ItemsQuery) -> Option<(Vec<Item>, i64)> {
        let answer = self.items_page(&query).await.ok()?;
        Some((answer.items, answer.total_record_count))
    }

    /// The natural-order list of a library (:232); the collator is the caller's.
    pub async fn natural_list(
        &self,
        query: &ItemsQuery,
        collator: &NaturalCollator,
    ) -> Result<Vec<Item>, PlexError> {
        let q = ItemsQuery {
            limit: 100_000,
            sort_by: Sorting::Name.input_field().into(),
            slim: true,
            ..query.clone()
        };
        let answer = self.items_page(&q).await?;
        Ok(NaturalOrder::sorted(answer.items, collator, |i: &Item| {
            (i.name.as_str(), i.sort_name.as_deref())
        }))
    }

    /// One page of a natural-order list, fetched by id (:242).
    pub async fn natural_page(
        &self,
        list: &[Item],
        since: i64,
        count: i64,
    ) -> Result<ItemsResponse, PlexError> {
        let slice: Vec<&Item> = list
            .iter()
            .skip(usize::try_from(since).unwrap_or(0))
            .take(usize::try_from(count).unwrap_or(0))
            .collect();
        if slice.is_empty() {
            return Ok(ItemsResponse::new(vec![], list.len() as i64));
        }
        let ids: Vec<String> = slice.iter().map(|i| i.id.clone()).collect();
        let fetched = self.items_by_id(&ids).await?.items;
        let mut by_id: HashMap<String, Item> = HashMap::new();
        for item in fetched {
            by_id.entry(item.id.clone()).or_insert(item);
        }
        Ok(ItemsResponse::new(
            slice
                .iter()
                .filter_map(|i| by_id.get(&i.id).cloned())
                .collect(),
            list.len() as i64,
        ))
    }
}

impl<T: HttpTransport + 'static> HomePageSource for PlexClient<T> {
    async fn resume_items(&self, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        self.continue_watching(limit).await.map_err(kind)
    }

    async fn next_up(&self, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        self.on_deck(limit).await.map_err(kind)
    }

    async fn last_added(
        &self,
        library: Option<&str>,
        fetch: i64,
        show_item: i64,
    ) -> Option<Vec<Item>> {
        self.last_added_kinds(library, fetch, show_item, "Movie,Episode")
            .await
    }

    async fn title(&self, genre: &str, limit: i64) -> Option<Vec<Item>> {
        self.title_with_number_genre(genre, limit, 0)
            .await
            .map(|r| r.0)
    }

    async fn libraries(&self) -> Option<Vec<Item>> {
        self.views().await.ok()
    }

    async fn new_arrivals(&self, genre: &str, fetch: i64, show_item: i64) -> Option<Vec<Item>> {
        self.last_added_kinds(None, fetch, show_item, genre).await
    }

    /// The series themselves, newest first, like the series page.
    async fn new_series(&self, library: Option<&str>, show_item: i64) -> Option<Vec<Item>> {
        self.newest(library, Some(true), show_item).await
    }

    async fn latest_title(
        &self,
        library: &str,
        collection: bool,
        show_item: i64,
    ) -> Option<Vec<Item>> {
        if collection {
            return self.collection_items(library).await.ok().map(|v| {
                v.into_iter()
                    .take(usize::try_from(show_item).unwrap_or(0))
                    .collect()
            });
        }
        self.newest(Some(library), None, show_item).await
    }

    fn merges_libraries(&self) -> bool {
        true
    }

    fn log(&self, line: &str) {
        self.log_line(line);
    }
}

impl<T: HttpTransport + 'static> MediaServer for PlexClient<T> {
    fn kind(&self) -> ServerKind {
        ServerKind::Plex
    }

    fn capabilities(&self) -> Vec<ServerCapability> {
        PlexFeatures::capabilities()
    }

    fn base_url(&self) -> String {
        PlexClient::base_url(self).to_string()
    }

    async fn current_session(&self) -> Option<Session> {
        PlexClient::current_session(self).map(|s| s.session)
    }

    async fn public_system_info(&self) -> Result<PublicSystemInfo, ErrorKind> {
        let found = self.info().await.map_err(kind)?;
        Ok(PublicSystemInfo {
            server_name: self.details().map(|d| d.server_name),
            version: found.version,
            id: Some(found.machine_identifier),
            product_name: None,
        })
    }

    async fn check_reachability(&self) -> Result<PublicSystemInfo, ErrorKind> {
        MediaServer::public_system_info(self).await
    }

    /// Plex has no sign-in with a name and password at the server; the account signs in at
    /// plex.tv ([`crate::PlexAccountService`]).
    async fn authenticate(&self, _username: &str, _password: &str) -> Result<Session, ErrorKind> {
        Err(kind(PlexError::Unsupported))
    }

    async fn sign_off(&self) {
        self.forget_account();
    }

    /// `false` only for `401`; a network error means "unknown", and signing someone out for that
    /// would be wrong.
    async fn session_applies_still(&self) -> bool {
        self.token_works().await.unwrap_or(true)
    }

    /// Plex has no transcoding for us, so no download quality to offer; downloads are the
    /// original file.
    async fn account_defaults(&self) -> Option<AccountPreGift> {
        Some(AccountPreGift::new(None, None, Some(false), Some(false)))
    }

    async fn user_views(&self, _hidden: bool) -> Result<Vec<Item>, ErrorKind> {
        self.views().await.map_err(kind)
    }

    async fn items(&self, query: &ItemsQuery) -> Result<ItemsResponse, ErrorKind> {
        self.items_page(query).await.map_err(kind)
    }

    async fn search(&self, term: &str, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        PlexClient::search(self, term, limit).await.map_err(kind)
    }

    async fn genres(&self) -> Result<Vec<String>, ErrorKind> {
        let mut names = std::collections::BTreeSet::new();
        for section in self.sections().await.map_err(kind)? {
            if section.type_ == "movie" || section.type_ == "show" {
                for g in self.genres_of_section(&section.key).await.map_err(kind)? {
                    names.insert(g.title);
                }
            }
        }
        let mut names: Vec<String> = names.into_iter().collect();
        names.sort_by_key(|n| n.to_lowercase());
        Ok(names)
    }

    async fn playlist_directory(&self) -> Result<PlaylistDirectory, ErrorKind> {
        let found: Vec<Item> = self
            .playlists()
            .await
            .map_err(kind)?
            .into_iter()
            .filter(VideoPlaylist::is_video)
            .collect();
        let members = join_all(
            found
                .iter()
                .map(|l| MediaServer::playlist_entries(self, &l.id, false)),
        )
        .await;
        let mut all = Vec::new();
        for (list, entries) in found.iter().zip(members) {
            all.push(VideoPlaylist::new(list.clone(), &entries?));
        }
        Ok(PlaylistDirectory { all })
    }

    async fn playlist_entries(&self, playlist: &str, _lean: bool) -> Result<Vec<Item>, ErrorKind> {
        Ok(self
            .playlist_items(playlist)
            .await
            .map_err(kind)?
            .into_iter()
            .filter(VideoPlaylist::is_video_entry)
            .collect())
    }

    async fn collection_directory(
        &self,
        view_list: &[Item],
    ) -> Result<CollectionDirectory, ErrorKind> {
        let known: Vec<PlexSection> = self
            .sections()
            .await
            .map_err(kind)?
            .into_iter()
            .filter(|s| s.type_ == "movie" || s.type_ == "show")
            .collect();
        let wanted: Vec<&PlexSection> = known
            .iter()
            .filter(|s| view_list.is_empty() || view_list.iter().any(|v| v.id == s.key))
            .collect();
        let mut found: Vec<Item> = Vec::new();
        for section in wanted {
            found.extend(self.collections(&section.key).await.map_err(kind)?);
        }
        let members = join_all(found.iter().map(|c| self.collection_items(&c.id))).await;
        let mut all = Vec::new();
        for (collection, entries) in found.iter().zip(members) {
            all.push(ItemCollection::new(
                collection.clone(),
                &entries.map_err(kind)?,
            ));
        }
        Ok(CollectionDirectory { all })
    }

    /// A Plex library holds one kind (films or series), never both.
    async fn library_shares(&self, _views: &[Item]) -> HashMap<String, LibraryShare> {
        HashMap::new()
    }

    /// "All" across libraries: the ids of every chosen library, in the account's order, so each
    /// work stays once (`TitleFilter`).
    async fn title_filter(
        &self,
        source: &ShelfSource,
        filters: &[String],
        is_watched: Option<bool>,
    ) -> Result<TitleFilter, ErrorKind> {
        let types: Vec<String> = source.types().iter().map(|t| (*t).to_string()).collect();
        let mut libraries: Vec<(String, Vec<Item>)> = Vec::new();
        for id in &source.only_out {
            let query = ItemsQuery {
                parent_id: Some(id.clone()),
                limit: 100_000,
                filters: filters.to_vec(),
                is_watched,
                recursive: true,
                include_item_types: types.clone(),
                slim: true,
                ..ItemsQuery::default()
            };
            libraries.push((
                id.clone(),
                self.items_page(&query).await.map_err(kind)?.items,
            ));
        }
        Ok(TitleFilter::new(&libraries))
    }

    /// The watchlist: what is rated as a favourite, once per work, paged.
    async fn remembered_items(
        &self,
        types: &[String],
        sort_by: &str,
        sort_order: &str,
        start_index: i64,
        limit: i64,
    ) -> Result<ItemsResponse, ErrorKind> {
        let query = ItemsQuery {
            limit,
            start_index,
            sort_by: sort_by.into(),
            sort_order: sort_order.into(),
            filters: vec!["IsFavorite".into()],
            recursive: true,
            include_item_types: types.to_vec(),
            ..ItemsQuery::default()
        };
        self.items_page(&query).await.map_err(kind)
    }

    async fn title_with_number_person(
        &self,
        id: &str,
        limit: i64,
        start_index: i64,
    ) -> Option<(Vec<Item>, i64)> {
        self.titles_with_number(ItemsQuery {
            limit,
            start_index,
            sort_by: "ProductionYear,SortName".into(),
            sort_order: "Descending".into(),
            recursive: true,
            include_item_types: vec!["Movie".into(), "Series".into()],
            person_ids: vec![id.into()],
            ..ItemsQuery::default()
        })
        .await
    }

    async fn title_with_number_genre(
        &self,
        genre: &str,
        limit: i64,
        start_index: i64,
    ) -> Option<(Vec<Item>, i64)> {
        self.titles_with_number(ItemsQuery {
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
    }

    async fn item(&self, id: &str) -> Result<Item, ErrorKind> {
        PlexClient::item(self, id).await.map_err(kind)
    }

    async fn similar(&self, item_id: &str, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        Ok(self
            .similar_to(item_id, limit)
            .await
            .map_err(kind)?
            .into_iter()
            .filter(|i| i.id != item_id)
            .collect())
    }

    /// Extras the server keeps as files (featurettes, scenes); trailers are kept apart.
    async fn extras(&self, item_id: &str) -> Result<Vec<Item>, ErrorKind> {
        Ok(self
            .clips(item_id)
            .await
            .map_err(kind)?
            .iter()
            .filter(|m| m.subtype.as_deref() != Some("trailer"))
            .map(|m| self.mapper.item(m))
            .collect())
    }

    /// Trailers that exist as a file on the server, like Jellyfin's local trailers.
    async fn trailer(&self, item_id: &str) -> Result<Vec<Item>, ErrorKind> {
        Ok(self
            .clips(item_id)
            .await
            .map_err(kind)?
            .iter()
            .filter(|m| m.subtype.as_deref() == Some("trailer"))
            .map(|m| self.mapper.item(m))
            .collect())
    }

    async fn seasons(&self, series_id: &str) -> Result<Vec<Item>, ErrorKind> {
        self.children(series_id).await.map_err(kind)
    }

    async fn episodes(
        &self,
        series_id: &str,
        season_id: Option<&str>,
    ) -> Result<Vec<Item>, ErrorKind> {
        self.episodes_of(series_id, season_id).await.map_err(kind)
    }

    /// The episode to watch next: the one after the last watched; `None` if nothing in the
    /// series was watched yet or it is finished (as on Jellyfin).
    async fn next_episode_series(&self, series_id: &str) -> Result<Option<Item>, ErrorKind> {
        let all = self.episodes_of(series_id, None).await.map_err(kind)?;
        let Some(last) = all
            .iter()
            .rposition(|i| i.user_data.as_ref().and_then(|u| u.played) == Some(true))
        else {
            return Ok(None);
        };
        Ok(all.get(last + 1).cloned())
    }

    async fn episode_post(
        &self,
        item_id: &str,
        series_id: &str,
    ) -> Result<Option<Item>, ErrorKind> {
        let all = self.episodes_of(series_id, None).await.map_err(kind)?;
        let Some(now) = all.iter().position(|i| i.id == item_id) else {
            return Ok(None);
        };
        Ok(all.get(now + 1).cloned())
    }

    async fn state_in_series(&self, series_id: &str) -> Option<Item> {
        MediaServer::state_in_series_checked(self, series_id)
            .await
            .ok()
            .flatten()
    }

    async fn state_in_series_checked(&self, series_id: &str) -> Result<Option<Item>, ErrorKind> {
        if let Some(next) = MediaServer::next_episode_series(self, series_id).await? {
            return Ok(Some(next));
        }
        Ok(self
            .episodes_of(series_id, None)
            .await
            .map_err(kind)?
            .into_iter()
            .next())
    }

    async fn metadata_refresh(&self, item_id: &str) -> Result<(), ErrorKind> {
        self.command(
            Method::Put,
            &format!("/library/metadata/{item_id}/refresh"),
            &[],
        )
        .await
        .map_err(kind)
    }

    async fn set_watchlist(&self, item_id: &str, on: bool) -> Result<(), ErrorKind> {
        self.set_favorite(item_id, on).await.map_err(kind)
    }

    async fn set_watched(&self, item_id: &str, on: bool) -> Result<(), ErrorKind> {
        self.set_watched_key(item_id, on).await.map_err(kind)
    }

    /// Takes the title out of "Continue watching". The watched mark stays as it was.
    async fn point_back_set(&self, item_id: &str) -> Result<(), ErrorKind> {
        self.command(
            Method::Put,
            "/actions/removeFromContinueWatching",
            &[("ratingKey".into(), item_id.into())],
        )
        .await
        .map_err(kind)
    }

    async fn image_url(&self, item: &Item, max_height: i64) -> Option<String> {
        self.image_url_for(item, ImageKind::Poster, Some(max_height), None)
            .map(|u| u.to_string())
    }

    async fn playback_plan(
        &self,
        item_id: &str,
        _profile: &DeviceProfile,
        audio_stream_index: Option<i64>,
        subtitle_stream_index: Option<i64>,
        media_source_id: Option<&str>,
    ) -> Result<Option<PlaybackPlan>, ErrorKind> {
        self.plan_for(
            item_id,
            media_source_id,
            audio_stream_index,
            subtitle_stream_index,
        )
        .await
        .map(Some)
        .map_err(kind)
    }

    /// The original file; Plex has no quality levels here.
    async fn download_url(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        _quality: DownloadQuality,
        _audio_stream_index: Option<i64>,
    ) -> Result<String, ErrorKind> {
        self.download_url_of(item_id, media_source_id)
            .await
            .map(|u| u.to_string())
            .map_err(kind)
    }

    async fn sections(&self, item_id: &str) -> Vec<Segment> {
        self.segments(item_id).await.unwrap_or_default()
    }

    async fn segments_to_store(&self, item_id: &str) -> Option<Vec<Segment>> {
        self.segments(item_id).await.ok()
    }

    /// Plex's preview pictures are single images, not tile sheets: the "grid" is 1 by 1 and a
    /// "sheet" is the picture with that number.
    async fn trickplay(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        _target: i64,
    ) -> Option<Trickplay> {
        let bif = self
            .previews(item_id, media_source_id)
            .await
            .ok()
            .flatten()?;
        let (width, height) = bif.picture_size()?;
        (bif.interval() > 0).then(|| Trickplay {
            width,
            height,
            tiles_wide: 1,
            tiles_up: 1,
            count: bif.frames.len() as i64,
            interval: bif.interval(),
        })
    }

    async fn trickplay_sheet(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        _width: i64,
        sheet: i64,
    ) -> Option<Vec<u8>> {
        self.previews(item_id, media_source_id)
            .await
            .ok()
            .flatten()?
            .image(sheet)
    }

    async fn chapter(&self, item_id: &str, _media_source_id: Option<&str>) -> Vec<Chapter> {
        self.chapters_of(item_id).await.unwrap_or_default()
    }

    async fn report_start(
        &self,
        item_id: &str,
        plan: &PlaybackPlan,
        ticks: i64,
        _tracks: TrackIndices,
    ) -> Result<(), ErrorKind> {
        self.report_timeline(
            item_id,
            TimelineState::Playing,
            ticks,
            Self::milliseconds_of(plan),
        )
        .await
        .map_err(kind)
    }

    async fn report_progress(
        &self,
        item_id: &str,
        plan: &PlaybackPlan,
        position_ticks: i64,
        paused: bool,
        _tracks: TrackIndices,
    ) -> Result<(), ErrorKind> {
        let state = if paused {
            TimelineState::Paused
        } else {
            TimelineState::Playing
        };
        self.report_timeline(item_id, state, position_ticks, Self::milliseconds_of(plan))
            .await
            .map_err(kind)
    }

    async fn report_stopped(
        &self,
        item_id: &str,
        plan: &PlaybackPlan,
        position_ticks: i64,
    ) -> Result<(), ErrorKind> {
        self.report_timeline(
            item_id,
            TimelineState::Stopped,
            position_ticks,
            Self::milliseconds_of(plan),
        )
        .await
        .map_err(kind)
    }

    /// Positions made offline. A title that is gone is settled; a position older than the
    /// server's own last play is dropped (the newer state wins). Stops at the first error.
    async fn report_later(&self, opened: &[PendingReport]) -> Vec<String> {
        let mut completed = Vec::new();
        for report in opened {
            match self.detail(&report.item_id).await {
                Ok(detail) => {
                    let last = detail
                        .item
                        .user_data
                        .as_ref()
                        .and_then(|u| u.last_played_date.as_deref())
                        .and_then(parse_timestamp);
                    let sent = if PostReportRules::dispatch(report, last) {
                        self.report_timeline(
                            &report.item_id,
                            TimelineState::Stopped,
                            report.ticks,
                            detail.metadata.duration,
                        )
                        .await
                    } else {
                        Ok(())
                    };
                    match sent {
                        Ok(()) => {
                            self.log_line(&format!(
                                "[Melden] Nachmeldung {} {} s",
                                report.item_id,
                                report.ticks / 10_000_000
                            ));
                            completed.push(report.id());
                        }
                        Err(PlexError::Request(ErrorKind::Http { status: 404, .. })) => {
                            completed.push(report.id())
                        }
                        Err(_) => {
                            self.log_line(&format!(
                                "[Melden] Nachmeldung {} gescheitert, bleibt liegen",
                                report.item_id
                            ));
                            break;
                        }
                    }
                }
                Err(PlexError::Request(ErrorKind::Http { status: 404, .. })) => {
                    completed.push(report.id())
                }
                Err(_) => {
                    self.log_line(&format!(
                        "[Melden] Nachmeldung {} gescheitert, bleibt liegen",
                        report.item_id
                    ));
                    break;
                }
            }
        }
        completed
    }
}

// Silences the unused-import lint for items used only in doc links.
#[allow(dead_code)]
type _Unused = (BTreeMap<(), ()>, HashSet<()>);
