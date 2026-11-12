//! The requests of `JellyfinClient.swift`, in the order of the logic map (apple-logic.md 2.1).
//! Each method names the Swift line it mirrors. Results that the Swift client post-processes
//! with list rules (one entry per work, natural sort) are returned **raw**: those rules live
//! in the library crate.

use serde::Serialize;
use swiftly_model::{
    Item, ItemsResponse, Lenient, PlaybackInfoResponse, PublicSystemInfo, UserItemData,
};
use swiftly_net::{ErrorKind, HttpTransport, Method, TransportReason, Url};

use crate::address::ADDRESS_CHECK_DEADLINE;
use crate::client::{JellyfinClient, Query};
use crate::query::build_url;
use crate::session::{ServerKind, Session};

const LIST_FIELDS: &str = "Overview,PrimaryImageAspectRatio,ProviderIds";
/// [`LIST_FIELDS`] without the description, for tiles (`ClientConfig::lean_tiles`).
const TILE_FIELDS: &str = "PrimaryImageAspectRatio,ProviderIds";
/// The page fields of `items` without the description.
const TILE_FIELDS_SORTED: &str =
    "PrimaryImageAspectRatio,ProviderIds,SortName,DateCreated,ChildCount";

fn types(list: &[String]) -> String {
    list.join(",")
}

/// The arguments of [`JellyfinClient::items`] with the Swift defaults
/// (`items(parentID:limit:…)`, JellyfinClient.swift:449-531).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItemsQuery {
    /// Folder or library id (`ParentId`).
    pub parent_id: Option<String>,
    /// Page size (`Limit`), default 100.
    pub limit: i64,
    /// Offset (`StartIndex`), default 0.
    pub start_index: i64,
    /// `SortBy`, default `SortName`.
    pub sort_by: String,
    /// `SortOrder`, default `Ascending`.
    pub sort_order: String,
    /// Jellyfin's `Filters`, e.g. `IsResumable` or `IsFavorite`.
    pub filters: Vec<String>,
    /// `Some(false)` means unwatched only (`IsPlayed`).
    pub is_watched: Option<bool>,
    /// `Recursive`.
    pub recursive: bool,
    /// `IncludeItemTypes`, e.g. `Movie`, `Series`. Without it a series library returns its
    /// virtual folders (JellyfinClient.swift:461-472).
    pub include_item_types: Vec<String>,
    /// Exactly these ids (`Ids`).
    pub ids: Vec<String>,
    /// `PersonIds`.
    pub person_ids: Vec<String>,
    /// `Genres`, joined with a pipe because a genre may contain a comma.
    pub genres: Vec<String>,
    /// Only id, name and sort name, all of them (alphabet index): `Limit`, `StartIndex` and
    /// the list fields are dropped.
    pub slim: bool,
}

impl Default for ItemsQuery {
    fn default() -> Self {
        Self {
            parent_id: None,
            limit: 100,
            start_index: 0,
            sort_by: "SortName".into(),
            sort_order: "Ascending".into(),
            filters: Vec::new(),
            is_watched: None,
            recursive: false,
            include_item_types: Vec::new(),
            ids: Vec::new(),
            person_ids: Vec::new(),
            genres: Vec::new(),
            slim: false,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
struct AuthBody<'a> {
    username: &'a str,
    pw: &'a str,
}

/// Body of `PlaybackInfo` (JellyfinClient.swift:679-689). The device profile is any
/// serialisable value: `DeviceProfile` is not in `swiftly-model` yet (see NOTES.md).
#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
struct PlaybackInfoBody<'a, P: Serialize> {
    user_id: &'a str,
    device_profile: &'a P,
    max_streaming_bitrate: i64,
    auto_open_live_stream: bool,
    enable_direct_play: bool,
    enable_direct_stream: bool,
    enable_transcoding: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    audio_stream_index: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    subtitle_stream_index: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    media_source_id: Option<&'a str>,
}

impl<T: HttpTransport> JellyfinClient<T> {
    // ---- System / session -------------------------------------------------------------

    /// `GET System/Info/Public`: reachability and version, no sign-in (:379).
    pub async fn public_system_info(&self) -> Result<PublicSystemInfo, ErrorKind> {
        self.send(self.get("System/Info/Public", &Query::new())?)
            .await
    }

    /// The same question with the short timeout of address entry (:386, `AddressCheck.deadline`).
    pub async fn check_reachability(&self) -> Result<PublicSystemInfo, ErrorKind> {
        let mut req = self.get("System/Info/Public", &Query::new())?;
        req.timeout = Some(ADDRESS_CHECK_DEADLINE);
        self.send(req).await
    }

    /// `POST Users/AuthenticateByName {Username, Pw}` (:390). Sets the session. A 401 with a
    /// token in the body is [`ErrorKind::TwoFactor`] (:1547).
    pub async fn authenticate(&self, username: &str, password: &str) -> Result<Session, ErrorKind> {
        let body = Self::json_body(&AuthBody {
            username,
            pw: password,
        })?;
        let req = self.request(
            "Users/AuthenticateByName",
            Method::Post,
            &Query::new(),
            Some(body),
        )?;
        match self.send::<swiftly_model::AuthenticationResult>(req).await {
            Ok(result) => Ok(self.adopt(result)),
            Err(ErrorKind::Http { status, body }) => Err(ErrorKind::login_error(status, body)),
            Err(e) => Err(e),
        }
    }

    /// `POST Sessions/Logout` (:417). Errors do not matter: signing out locally must work
    /// without a network. Clears the session.
    pub async fn sign_off(&self) {
        if let Ok(req) = self.request("Sessions/Logout", Method::Post, &Query::new(), None) {
            let _ = self.execute(req).await;
        }
        self.set_session(None);
    }

    /// `GET Users/{userId}` (:430). `false` only for 401 or 403; a network error means
    /// "unknown", so `true`.
    pub async fn session_applies_still(&self) -> bool {
        let Some(s) = self.current_session() else {
            return true;
        };
        let Ok(req) = self.get(&format!("Users/{}", s.user_id), &Query::new()) else {
            return true;
        };
        match self.execute(req).await {
            Ok(r) => r.status != 401 && r.status != 403,
            Err(_) => true,
        }
    }

    // ---- Lists --------------------------------------------------------------------------

    /// `GET UserViews[?includeHidden=true]` (:441).
    pub async fn user_views(&self, hidden: bool) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let mut q = Query::new().add("userId", &s.user_id);
        if hidden {
            q.push("includeHidden", "true");
        }
        Ok(self
            .send::<ItemsResponse>(self.get("UserViews", &q)?)
            .await?
            .items)
    }

    /// `GET Items` with the generic list query (:449-531).
    pub async fn items(&self, a: &ItemsQuery) -> Result<ItemsResponse, ErrorKind> {
        let s = self.require_session()?;
        let mut q = Query::new()
            .add("userId", &s.user_id)
            .add("Limit", a.limit)
            .add("StartIndex", a.start_index)
            .add("SortBy", &a.sort_by)
            .add("SortOrder", &a.sort_order)
            .add(
                "Fields",
                if self.config.lean_tiles {
                    TILE_FIELDS_SORTED
                } else {
                    "Overview,PrimaryImageAspectRatio,ProviderIds,SortName,DateCreated,ChildCount"
                },
            )
            .add("Recursive", if a.recursive { "true" } else { "false" });
        if let Some(p) = &a.parent_id {
            q.push("ParentId", p);
        }
        if !a.include_item_types.is_empty() {
            q.push("IncludeItemTypes", types(&a.include_item_types));
        }
        if !a.filters.is_empty() {
            q.push("Filters", a.filters.join(","));
        }
        if !a.ids.is_empty() {
            q.push("Ids", a.ids.join(","));
        }
        if !a.person_ids.is_empty() {
            q.push("PersonIds", a.person_ids.join(","));
        }
        if !a.genres.is_empty() {
            q.push("Genres", a.genres.join("|"));
        }
        if let Some(w) = a.is_watched {
            q.push("IsPlayed", w);
        }
        if self.config.lean_tiles && !a.slim {
            // Grids show posters: one primary picture per item, no description.
            q.push("EnableImageTypes", "Primary");
            q.push("ImageTypeLimit", 1);
        }
        if a.slim {
            q.0.retain(|(n, _)| !matches!(n.as_str(), "Limit" | "StartIndex" | "Fields"));
            q.push("Fields", "SortName,DateCreated");
            q.push("EnableImages", "false");
            q.push("EnableUserData", "false");
        }
        self.send(self.get("Items", &q)?).await
    }

    /// Only the number of titles of these kinds under a folder (:537). One title is requested
    /// because `Limit=0` does not mean "none" on every server.
    pub async fn count(&self, parent_id: &str, kinds: &[String]) -> Result<i64, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("ParentId", parent_id)
            .add("IncludeItemTypes", types(kinds))
            .add("Recursive", "true")
            .add("Limit", 1)
            .add("EnableImages", "false")
            .add("EnableUserData", "false");
        Ok(self
            .send::<ItemsResponse>(self.get("Items", &q)?)
            .await?
            .total_record_count)
    }

    /// Everything of one kind from a library, slim: id, name, year, provider ids (:553).
    pub async fn title_ids(
        &self,
        parent_id: &str,
        kinds: &[String],
        filters: &[String],
        is_watched: Option<bool>,
    ) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let mut q = Query::new()
            .add("userId", &s.user_id)
            .add("ParentId", parent_id)
            .add("IncludeItemTypes", types(kinds))
            .add("Recursive", "true")
            .add("Fields", "ProviderIds")
            .add("EnableImages", "false")
            .add("EnableUserData", "false");
        if !filters.is_empty() {
            q.push("Filters", filters.join(","));
        }
        if let Some(w) = is_watched {
            q.push("IsPlayed", w);
        }
        Ok(self
            .send::<ItemsResponse>(self.get("Items", &q)?)
            .await?
            .items)
    }

    /// Exactly these entries: id, name, kind, provider ids (:572). Empty input, no request.
    pub async fn identifiers(&self, ids: &[String]) -> Result<Vec<Item>, ErrorKind> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let s = self.require_session()?;
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("Ids", ids.join(","))
            .add("Fields", "ProviderIds")
            .add("EnableImages", "false")
            .add("EnableUserData", "false");
        Ok(self
            .send::<ItemsResponse>(self.get("Items", &q)?)
            .await?
            .items)
    }

    /// `GET Items/{id}/Ancestors`: the folders above an entry (:587).
    pub async fn ancestors(&self, id: &str) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new().add("userId", &s.user_id);
        self.send(self.get(&format!("Items/{id}/Ancestors"), &q)?)
            .await
    }

    /// The whole watchlist slim, in the page's sort order (:597).
    pub async fn remembered_ids(
        &self,
        kinds: &[String],
        sort_by: &str,
        sort_order: &str,
    ) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("Recursive", "true")
            .add("Filters", "IsFavorite")
            .add("IncludeItemTypes", types(kinds))
            .add("SortBy", sort_by)
            .add("SortOrder", sort_order)
            .add("Fields", "ProviderIds")
            .add("EnableImages", "false")
            .add("EnableUserData", "false");
        Ok(self
            .send::<ItemsResponse>(self.get("Items", &q)?)
            .await?
            .items)
    }

    /// Members of a collection, not recursive (:619).
    pub async fn collection_members(&self, collection: &str) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("ParentId", collection)
            .add("IncludeItemTypes", "Movie,Series")
            .add("Limit", 2000)
            .add("EnableImages", "false")
            .add("EnableUserData", "false");
        Ok(self
            .send::<ItemsResponse>(self.get("Items", &q)?)
            .await?
            .items)
    }

    /// `GET Playlists/{id}/Items`, in the playlist's order (:637). The Swift client then keeps
    /// only video entries (`VideoPlaylist.isVideoEntry`); that filter is left to the caller.
    pub async fn playlist_entries(
        &self,
        playlist: &str,
        lean: bool,
    ) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let mut q = Query::new()
            .add("userId", &s.user_id)
            .add("Limit", 2000)
            .add("Fields", LIST_FIELDS);
        if lean {
            q.push("EnableImages", "false");
            q.push("EnableUserData", "false");
        }
        Ok(self
            .send::<ItemsResponse>(self.get(&format!("Playlists/{playlist}/Items"), &q)?)
            .await?
            .items)
    }

    // ---- One title ------------------------------------------------------------------------

    /// `POST Items/{id}/PlaybackInfo` with the device profile (:669-702). Always Direct Play,
    /// Direct Stream and transcoding allowed, from second zero. `max_streaming_bitrate` is the
    /// profile's unless the caller overrides it.
    #[allow(clippy::too_many_arguments)]
    pub async fn playback_info<P: Serialize>(
        &self,
        item_id: &str,
        profile: &P,
        max_streaming_bitrate: i64,
        audio_stream_index: Option<i64>,
        subtitle_stream_index: Option<i64>,
        media_source_id: Option<&str>,
    ) -> Result<PlaybackInfoResponse, ErrorKind> {
        self.playback_info_with(
            item_id,
            profile,
            max_streaming_bitrate,
            audio_stream_index,
            subtitle_stream_index,
            media_source_id,
            true,
        )
        .await
    }

    /// [`Self::playback_info`] with `allow_direct` off: the server may neither play the file
    /// as it is nor copy its video, so it transcodes if it can (AV1 Dolby Vision 10.0 on a
    /// device that cannot show it).
    #[allow(clippy::too_many_arguments)]
    pub async fn playback_info_with<P: Serialize>(
        &self,
        item_id: &str,
        profile: &P,
        max_streaming_bitrate: i64,
        audio_stream_index: Option<i64>,
        subtitle_stream_index: Option<i64>,
        media_source_id: Option<&str>,
        allow_direct: bool,
    ) -> Result<PlaybackInfoResponse, ErrorKind> {
        let s = self.require_session()?;
        let body = Self::json_body(&PlaybackInfoBody {
            user_id: &s.user_id,
            device_profile: profile,
            max_streaming_bitrate,
            auto_open_live_stream: true,
            enable_direct_play: allow_direct,
            enable_direct_stream: allow_direct,
            enable_transcoding: true,
            audio_stream_index,
            subtitle_stream_index,
            media_source_id,
        })?;
        let req = self.request(
            &format!("Items/{item_id}/PlaybackInfo"),
            Method::Post,
            &Query::new(),
            Some(body),
        )?;
        self.send(req).await
    }

    /// `GET Items/{id}`: one title, fresh (:711). `UserData` comes once `userId` is sent.
    pub async fn item(&self, id: &str) -> Result<Item, ErrorKind> {
        let s = self.require_session()?;
        self.send(self.get(
            &format!("Items/{id}"),
            &Query::new().add("userId", &s.user_id),
        )?)
        .await
    }

    /// `GET {path}?{pairs}` as raw JSON, for the answers the player reads leniently
    /// (`MediaSegments`, an item with `Fields=Trickplay` or `Fields=Chapters`).
    pub async fn raw_json(
        &self,
        path: &str,
        pairs: &[(&str, &str)],
    ) -> Result<serde_json::Value, ErrorKind> {
        let mut q = Query::new();
        for (k, v) in pairs {
            q.push(k, v);
        }
        self.send(self.get(path, &q)?).await
    }

    /// `GET Genres`: the names of genres that have movies or series (:723).
    pub async fn genres(&self) -> Result<Vec<String>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("IncludeItemTypes", "Movie,Series")
            .add("Recursive", "true")
            .add("SortBy", "SortName");
        Ok(self
            .send::<ItemsResponse>(self.get("Genres", &q)?)
            .await?
            .items
            .into_iter()
            .map(|i| i.name)
            .collect())
    }

    /// `GET Items/{id}/Similar` (:739). Asks for twice `limit` and returns the raw answer; the
    /// Swift client drops the title itself and merges duplicates (`ListRules`), which is the
    /// library crate's job.
    pub async fn similar(&self, item_id: &str, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("limit", limit * 2)
            .add("Fields", "ProviderIds");
        Ok(self
            .send::<ItemsResponse>(self.get(&format!("Items/{item_id}/Similar"), &q)?)
            .await?
            .items)
    }

    /// `GET Items/{id}/SpecialFeatures`: extras (:753). Lenient list.
    pub async fn extras(&self, item_id: &str) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new().add("userId", &s.user_id);
        let list: Lenient<Item> = self
            .send(self.get(&format!("Items/{item_id}/SpecialFeatures"), &q)?)
            .await?;
        Ok(list.0)
    }

    /// `GET Items/{id}/LocalTrailers` (:941). Lenient list.
    pub async fn trailers(&self, item_id: &str) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new().add("userId", &s.user_id);
        let list: Lenient<Item> = self
            .send(self.get(&format!("Items/{item_id}/LocalTrailers"), &q)?)
            .await?;
        Ok(list.0)
    }

    /// Full-text search over movies and series (:773). Raw: the Swift client merges to one hit
    /// per work and sorts by natural order afterwards.
    pub async fn search(&self, term: &str, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("searchTerm", term)
            .add("Recursive", "true")
            .add("IncludeItemTypes", "Movie,Series")
            .add("Limit", limit)
            .add(
                "Fields",
                "Overview,PrimaryImageAspectRatio,ProviderIds,SortName,DateCreated,ChildCount",
            );
        Ok(self
            .send::<ItemsResponse>(self.get("Items", &q)?)
            .await?
            .items)
    }

    // ---- User data ------------------------------------------------------------------------

    /// A title's playback state for this account (:794). Emby has no read-only path, so the
    /// title itself carries the record.
    pub async fn user_record(&self, item_id: &str) -> Result<UserItemData, ErrorKind> {
        let s = self.require_session()?;
        if self.config.kind == ServerKind::Emby {
            return self
                .item(item_id)
                .await?
                .user_data
                .ok_or_else(|| ErrorKind::Decoding("UserData fehlt".into()));
        }
        let q = Query::new().add("userId", &s.user_id);
        self.send(self.get(&format!("UserItems/{item_id}/UserData"), &q)?)
            .await
    }

    /// `POST UserItems/{id}/UserData {LastPlayedDate}`: sets only the date (:811).
    /// `moment` is seconds since 1970; the text has milliseconds and `Z`.
    pub async fn last_play_set(&self, item_id: &str, moment: f64) -> Result<(), ErrorKind> {
        let s = self.require_session()?;
        let body = Self::json_body(
            &serde_json::json!({ "LastPlayedDate": crate::pending::iso8601_millis(moment) }),
        )?;
        let q = Query::new().add("userId", &s.user_id);
        let req = self.request(
            &format!("UserItems/{item_id}/UserData"),
            Method::Post,
            &q,
            Some(body),
        )?;
        self.send_ignoring_body(req).await
    }

    /// `POST UserItems/{id}/UserData {PlaybackPositionTicks: 0}`: remove from "Continue
    /// Watching", watched stays as it was (:827).
    pub async fn point_back_set(&self, item_id: &str) -> Result<(), ErrorKind> {
        let s = self.require_session()?;
        let body = Self::json_body(&serde_json::json!({ "PlaybackPositionTicks": 0 }))?;
        let q = Query::new().add("userId", &s.user_id);
        let req = self.request(
            &format!("UserItems/{item_id}/UserData"),
            Method::Post,
            &q,
            Some(body),
        )?;
        self.send_ignoring_body(req).await
    }

    /// `POST|DELETE UserFavoriteItems/{id}`: the watchlist (:859).
    pub async fn set_watchlist(&self, item_id: &str, on: bool) -> Result<(), ErrorKind> {
        let s = self.require_session()?;
        let method = if on { Method::Post } else { Method::Delete };
        let q = Query::new().add("userId", &s.user_id);
        self.send_ignoring_body(self.request(
            &format!("UserFavoriteItems/{item_id}"),
            method,
            &q,
            None,
        )?)
        .await
    }

    /// `POST|DELETE UserPlayedItems/{id}`: watched (:867).
    pub async fn set_watched(&self, item_id: &str, on: bool) -> Result<(), ErrorKind> {
        let s = self.require_session()?;
        let method = if on { Method::Post } else { Method::Delete };
        let q = Query::new().add("userId", &s.user_id);
        self.send_ignoring_body(self.request(
            &format!("UserPlayedItems/{item_id}"),
            method,
            &q,
            None,
        )?)
        .await
    }

    // ---- Series ---------------------------------------------------------------------------

    /// `GET Shows/{id}/Seasons` (:898).
    pub async fn seasons(&self, series_id: &str) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("isMissing", "false")
            .add("Fields", "Overview");
        Ok(self
            .send::<ItemsResponse>(self.get(&format!("Shows/{series_id}/Seasons"), &q)?)
            .await?
            .items)
    }

    /// `GET Shows/{id}/Episodes[?seasonId]` (:909). Without a season, all episodes.
    pub async fn episodes(
        &self,
        series_id: &str,
        season_id: Option<&str>,
    ) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let mut q = Query::new()
            .add("userId", &s.user_id)
            .add("isMissing", "false")
            .add("Fields", "Overview,MediaSources");
        if let Some(season) = season_id {
            q.push("seasonId", season);
        }
        Ok(self
            .send::<ItemsResponse>(self.get(&format!("Shows/{series_id}/Episodes"), &q)?)
            .await?
            .items)
    }

    /// Only the series' first episode (:926).
    pub async fn first_episode(&self, series_id: &str) -> Result<Option<Item>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("isMissing", "false")
            .add("Limit", 1)
            .add("Fields", "Overview,MediaSources");
        let r: ItemsResponse = self
            .send(self.get(&format!("Shows/{series_id}/Episodes"), &q)?)
            .await?;
        Ok(r.items.into_iter().next())
    }

    /// `POST Items/{id}/Refresh`: re-read the metadata (:949). Any non-2xx is
    /// [`TransportReason::RefreshRejected`].
    pub async fn metadata_refresh(&self, item_id: &str) -> Result<(), ErrorKind> {
        let q = Query::new()
            .add("metadataRefreshMode", "FullRefresh")
            .add("imageRefreshMode", "FullRefresh")
            .add("replaceAllMetadata", "false");
        let response = self
            .execute(self.request(&format!("Items/{item_id}/Refresh"), Method::Post, &q, None)?)
            .await?;
        if response.is_success() {
            Ok(())
        } else {
            Err(ErrorKind::Transport(TransportReason::RefreshRejected))
        }
    }

    /// `GET Shows/NextUp?seriesId&Limit=1`: where one is in this series (:964). On Emby, which
    /// answers nothing for an unstarted series, falls back to the first unwatched episode.
    pub async fn next_episode_series(&self, series_id: &str) -> Result<Option<Item>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("seriesId", series_id)
            .add("Limit", 1)
            .add("Fields", "Overview");
        let r: ItemsResponse = self.send(self.get("Shows/NextUp", &q)?).await?;
        if let Some(found) = r.items.into_iter().next() {
            return Ok(Some(found));
        }
        if self.config.kind != ServerKind::Emby {
            return Ok(None);
        }
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("isMissing", "false")
            .add("Filters", "IsUnplayed")
            .add("Limit", 1)
            .add("Fields", "Overview");
        let r: ItemsResponse = self
            .send(self.get(&format!("Shows/{series_id}/Episodes"), &q)?)
            .await?;
        Ok(r.items.into_iter().next())
    }

    /// The episode after this one, via `adjacentTo` (:996); `None` for the last of a season.
    pub async fn episode_post(
        &self,
        item_id: &str,
        series_id: &str,
    ) -> Result<Option<Item>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new()
            .add("userId", &s.user_id)
            .add("isMissing", "false")
            .add("adjacentTo", item_id)
            .add("Fields", "Overview");
        let r: ItemsResponse = self
            .send(self.get(&format!("Shows/{series_id}/Episodes"), &q)?)
            .await?;
        let now = r.items.iter().position(|i| i.id == item_id);
        Ok(now.and_then(|n| r.items.into_iter().nth(n + 1)))
    }

    // ---- Home rows ------------------------------------------------------------------------

    fn row_fields(&self) -> &'static str {
        if self.config.lean_tiles {
            TILE_FIELDS
        } else {
            LIST_FIELDS
        }
    }

    /// The extra parameters of a home row under `lean_tiles`: the count is never read, one
    /// picture per type, and poster rows ask for the primary picture only.
    fn lean_row(&self, q: &mut Query, posters_only: bool) {
        if !self.config.lean_tiles {
            return;
        }
        if posters_only {
            q.push("EnableImageTypes", "Primary");
        }
        q.push("ImageTypeLimit", 1);
        q.push("EnableTotalRecordCount", "false");
    }

    /// `GET UserItems/Resume`: "Continue Watching" (:1009). Raw (the Swift client merges to one
    /// entry per work afterwards).
    pub async fn resume_items(&self, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let mut q = Query::new()
            .add("userId", &s.user_id)
            .add("Limit", limit)
            .add("Fields", self.row_fields())
            .add("MediaTypes", "Video");
        // The landscape row walks several picture types: keep them, one of each.
        self.lean_row(&mut q, false);
        Ok(self
            .send::<ItemsResponse>(self.get("UserItems/Resume", &q)?)
            .await?
            .items)
    }

    /// `GET Shows/NextUp` (:1024). Raw, like [`resume_items`](Self::resume_items).
    pub async fn next_up(&self, limit: i64) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let mut q = Query::new()
            .add("userId", &s.user_id)
            .add("Limit", limit)
            .add("Fields", self.row_fields());
        self.lean_row(&mut q, true);
        Ok(self
            .send::<ItemsResponse>(self.get("Shows/NextUp", &q)?)
            .await?
            .items)
    }

    /// What was added most recently, through the ordinary `Items` endpoint (:1073-1096).
    /// `item_types` is `Movie,Episode` for the home row. `slim` drops description, images and
    /// user data.
    pub async fn newly_joined(
        &self,
        parent_id: Option<&str>,
        limit: i64,
        slim: bool,
        item_types: &str,
    ) -> Result<Vec<Item>, ErrorKind> {
        let s = self.require_session()?;
        let mut q = Query::new()
            .add("userId", &s.user_id)
            .add("Limit", limit)
            .add("Recursive", "true")
            .add("SortBy", "DateCreated")
            .add("SortOrder", "Descending")
            .add("IncludeItemTypes", item_types)
            .add("IsVirtualItem", "false");
        if slim {
            q.push("Fields", "ProviderIds");
            q.push("EnableImages", "false");
            q.push("EnableUserData", "false");
        } else {
            q.push("Fields", self.row_fields());
            self.lean_row(&mut q, true);
        }
        if let Some(p) = parent_id {
            q.push("ParentId", p);
        }
        Ok(self
            .send::<ItemsResponse>(self.get("Items", &q)?)
            .await?
            .items)
    }

    // ---- Addresses for player and image loader (no request) --------------------------------

    fn url_with(&self, path: &str, query: &Query) -> Result<Url, ErrorKind> {
        build_url(&self.base_url, path, &query.0).ok_or(ErrorKind::InvalidServerUrl)
    }

    /// `Videos/{id}/stream?static=true&<token>&mediaSourceId&playSessionId` (:1368).
    pub fn stream_url(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        play_session_id: Option<&str>,
    ) -> Result<Url, ErrorKind> {
        let s = self.require_session()?;
        let mut q = Query::new()
            .add("static", "true")
            .add(self.token_name(), &s.access_token);
        if let Some(m) = media_source_id {
            q.push("mediaSourceId", m);
        }
        if let Some(p) = play_session_id {
            q.push("playSessionId", p);
        }
        self.url_with(&format!("Videos/{item_id}/stream"), &q)
    }

    /// `Items/{id}/Images/Primary?tag&maxHeight&quality=90&<token>` (:1518). `None` without an
    /// image tag or a session.
    pub fn image_url(&self, item: &Item, max_height: i64) -> Option<Url> {
        let tag = item.image_tags.as_ref()?.get("Primary")?.clone();
        let token = self.current_session()?.access_token;
        let q = Query::new()
            .add("tag", tag)
            .add("maxHeight", max_height)
            .add("quality", 90)
            .add(self.token_name(), token);
        self.url_with(&format!("Items/{}/Images/Primary", item.id), &q)
            .ok()
    }

    /// `Items/{id}/Images/Primary?maxHeight&quality=90&<token>` for an item known only by its id (the next-episode card of
    /// the player; the server answers without a tag, only the cache hint is missing). `None` without a session.
    pub fn image_url_by_id(&self, item_id: &str, max_height: i64) -> Option<Url> {
        let token = self.current_session()?.access_token;
        let q = Query::new()
            .add("maxHeight", max_height)
            .add("quality", 90)
            .add(self.token_name(), token);
        self.url_with(&format!("Items/{item_id}/Images/Primary"), &q)
            .ok()
    }

    /// `Items/{id}/Images/Backdrop?tag&maxWidth&quality=85&<token>` (:1502).
    pub fn backdrop_url(&self, item: &Item, max_width: i64) -> Option<Url> {
        let tag = item.backdrop_image_tags.as_ref()?.first()?.clone();
        let token = self.current_session()?.access_token;
        let q = Query::new()
            .add("tag", tag)
            .add("maxWidth", max_width)
            .add("quality", 85)
            .add(self.token_name(), token);
        self.url_with(&format!("Items/{}/Images/Backdrop", item.id), &q)
            .ok()
    }

    /// `Videos/{id}/Trickplay/{width}/{sheet}.jpg?[MediaSourceId&]<token>` (:1281-1296).
    pub fn trickplay_url(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        width: i64,
        sheet: i64,
    ) -> Option<Url> {
        let token = self.current_session()?.access_token;
        let mut q = Query::new();
        if let Some(m) = media_source_id {
            q.push("MediaSourceId", m);
        }
        q.push(self.token_name(), token);
        self.url_with(
            &format!("Videos/{item_id}/Trickplay/{width}/{sheet}.jpg"),
            &q,
        )
        .ok()
    }
}
