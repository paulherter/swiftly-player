//! Requests: create (with seasons, 4K, quality, folder, language, tags where the account may),
//! list with filters, count, read, withdraw, approve, decline, retry; the Radarr / Sonarr choices
//! for the advanced sheet; delete of media and media files (admin).

use serde::Deserialize;
use serde_json::{Value, json};
use swiftly_net::{ErrorKind, HttpTransport, Method};

use crate::client::{CookieJar, SeerrClient};
use crate::errors::AskError;
use crate::mapping::Seerr;
use crate::perms::Perms;
use crate::types::{RequestRow, RequestStatus, list, or_default};

/// What to ask for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestSpec {
    /// `movie` or `tv`.
    pub art: String,
    /// TMDB id.
    pub tmdb: i64,
    /// Series: the seasons; `None` or empty = all of them. Ignored for films.
    pub seasons: Option<Vec<i64>>,
    /// The 4K lane (only sent when the account may).
    pub is4k: bool,
    /// Radarr / Sonarr server (advanced).
    pub server_id: Option<i64>,
    /// Quality profile (advanced).
    pub profile_id: Option<i64>,
    /// Folder (advanced).
    pub root_folder: Option<String>,
    /// Sonarr language profile (advanced).
    pub language_profile_id: Option<i64>,
    /// Sonarr / Radarr tags (advanced).
    pub tags: Vec<i64>,
}

impl RequestSpec {
    /// A plain request: all seasons, normal quality, the default server.
    pub fn new(art: &str, tmdb: i64) -> Self {
        Self {
            art: art.to_string(),
            tmdb,
            seasons: None,
            is4k: false,
            server_id: None,
            profile_id: None,
            root_folder: None,
            language_profile_id: None,
            tags: Vec::new(),
        }
    }

    /// The same request for these seasons.
    #[must_use]
    pub fn with_seasons(mut self, seasons: &[i64]) -> Self {
        self.seasons = Some(seasons.to_vec());
        self
    }

    /// The body of `POST request`. 4K goes only with `REQUEST_4K`; server, profile, folder, language
    /// and tags only with `REQUEST_ADVANCED` / `MANAGE_REQUESTS`, so the server never gets a field the
    /// account may not set.
    pub fn body(&self, perms: Perms) -> Value {
        let mut body = Seerr::request_body(&self.art, self.tmdb, self.seasons.as_deref());
        if self.is4k && perms.can_request_4k(&self.art) {
            body["is4k"] = json!(true);
        }
        if perms.can_choose_advanced() {
            if let Some(v) = self.server_id {
                body["serverId"] = json!(v);
            }
            if let Some(v) = self.profile_id {
                body["profileId"] = json!(v);
            }
            if let Some(v) = &self.root_folder {
                body["rootFolder"] = json!(v);
            }
            if let Some(v) = self.language_profile_id {
                body["languageProfileId"] = json!(v);
            }
            if !self.tags.is_empty() {
                body["tags"] = json!(self.tags);
            }
        }
        body
    }
}

/// A request that went through.
#[derive(Debug, Clone, PartialEq)]
pub struct RequestOutcome {
    /// The new request.
    pub request: RequestRow,
    /// It needs no admin (approved on the spot).
    pub auto_approved: bool,
}

/// `filter=` of `GET request`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RequestFilter {
    /// All.
    #[default]
    All,
    /// Approved.
    Approved,
    /// Available.
    Available,
    /// Waiting for approval.
    Pending,
    /// Being processed.
    Processing,
    /// Not available.
    Unavailable,
    /// Failed.
    Failed,
    /// Deleted.
    Deleted,
    /// Completed.
    Completed,
}

impl RequestFilter {
    fn word(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Approved => "approved",
            Self::Available => "available",
            Self::Pending => "pending",
            Self::Processing => "processing",
            Self::Unavailable => "unavailable",
            Self::Failed => "failed",
            Self::Deleted => "deleted",
            Self::Completed => "completed",
        }
    }
}

/// Which requests, in which order, how many.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestQuery {
    /// Filter.
    pub filter: RequestFilter,
    /// Newest change first (`sort=modified`) instead of newest request first (`added`).
    pub by_modified: bool,
    /// Only this user's (without `MANAGE_REQUESTS` the server does that itself).
    pub requested_by: Option<i64>,
    /// `movie`, `tv`; `None` = both.
    pub media_type: Option<String>,
    /// Page size.
    pub take: u32,
    /// Entries to skip.
    pub skip: u32,
}

impl Default for RequestQuery {
    fn default() -> Self {
        Self {
            filter: RequestFilter::All,
            by_modified: false,
            requested_by: None,
            media_type: None,
            take: 20,
            skip: 0,
        }
    }
}

impl RequestQuery {
    fn pairs(&self) -> Vec<(String, String)> {
        let mut q = vec![
            ("take".to_string(), self.take.to_string()),
            ("skip".to_string(), self.skip.to_string()),
            ("filter".to_string(), self.filter.word().to_string()),
            (
                "sort".to_string(),
                if self.by_modified {
                    "modified"
                } else {
                    "added"
                }
                .to_string(),
            ),
            ("sortDirection".to_string(), "desc".to_string()),
        ];
        if let Some(u) = self.requested_by {
            q.push(("requestedBy".to_string(), u.to_string()));
        }
        if let Some(m) = &self.media_type {
            q.push(("mediaType".to_string(), m.clone()));
        }
        q
    }
}

/// `pageInfo` of a list.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PageInfo {
    /// Pages in all.
    #[serde(deserialize_with = "or_default")]
    pub pages: i64,
    /// Page size.
    #[serde(deserialize_with = "or_default")]
    pub page_size: i64,
    /// Entries in all.
    #[serde(deserialize_with = "or_default")]
    pub results: i64,
    /// This page (1...).
    #[serde(deserialize_with = "or_default")]
    pub page: i64,
}

/// A page of requests.
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RequestPage {
    /// Paging.
    pub page_info: PageInfo,
    /// The requests.
    #[serde(deserialize_with = "list")]
    pub results: Vec<RequestRow>,
}

/// `GET request/count`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(default)]
pub struct RequestCount {
    /// All.
    #[serde(deserialize_with = "or_default")]
    pub total: i64,
    /// Films.
    #[serde(deserialize_with = "or_default")]
    pub movie: i64,
    /// Series.
    #[serde(deserialize_with = "or_default")]
    pub tv: i64,
    /// Waiting for approval.
    #[serde(deserialize_with = "or_default")]
    pub pending: i64,
    /// Approved.
    #[serde(deserialize_with = "or_default")]
    pub approved: i64,
    /// Declined.
    #[serde(deserialize_with = "or_default")]
    pub declined: i64,
    /// Being processed.
    #[serde(deserialize_with = "or_default")]
    pub processing: i64,
    /// Available.
    #[serde(deserialize_with = "or_default")]
    pub available: i64,
    /// Completed.
    #[serde(deserialize_with = "or_default")]
    pub completed: i64,
}

/// A Radarr / Sonarr server the request can go to.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ServiceServer {
    /// Id.
    #[serde(deserialize_with = "or_default")]
    pub id: i64,
    /// Name.
    pub name: Option<String>,
    /// The default server.
    #[serde(deserialize_with = "or_default")]
    pub is_default: bool,
    /// A 4K server.
    #[serde(deserialize_with = "or_default")]
    pub is4k: bool,
    /// Default quality profile.
    pub active_profile_id: Option<i64>,
    /// Default folder.
    pub active_directory: Option<String>,
}

/// A quality profile.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default)]
pub struct ServiceProfile {
    /// Id.
    #[serde(deserialize_with = "or_default")]
    pub id: i64,
    /// Name.
    pub name: Option<String>,
}

/// A folder.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default)]
pub struct ServiceFolder {
    /// Path.
    pub path: Option<String>,
}

/// A tag.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default)]
pub struct ServiceTag {
    /// Id.
    #[serde(deserialize_with = "or_default")]
    pub id: i64,
    /// Label.
    pub label: Option<String>,
}

/// `GET service/{radarr|sonarr}/{id}`: what the advanced sheet offers.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ServiceDetail {
    /// The server.
    pub server: Option<ServiceServer>,
    /// Quality profiles.
    #[serde(deserialize_with = "list")]
    pub profiles: Vec<ServiceProfile>,
    /// Folders.
    #[serde(deserialize_with = "list")]
    pub root_folders: Vec<ServiceFolder>,
    /// Tags.
    #[serde(deserialize_with = "list")]
    pub tags: Vec<ServiceTag>,
}

fn row_of(body: &[u8]) -> RequestRow {
    serde_json::from_slice(body).unwrap_or_default()
}

impl<T: HttpTransport, J: CookieJar> SeerrClient<T, J> {
    /// `POST request`. Refusals are typed: a used-up quota (with the server's text), a missing
    /// permission, a blocklisted title, a duplicate (`Exists`, not a success), nothing left to ask for.
    pub async fn request(
        &self,
        spec: &RequestSpec,
        perms: Perms,
    ) -> Result<RequestOutcome, AskError> {
        let answer = self
            .send(Method::Post, "request", &[], Some(spec.body(perms)), true)
            .await?;
        let request = row_of(&answer.body);
        let auto_approved = matches!(
            request.status,
            RequestStatus::Approved | RequestStatus::Completed
        );
        Ok(RequestOutcome {
            request,
            auto_approved,
        })
    }

    /// `GET request` with filters.
    pub async fn request_list(&self, query: &RequestQuery) -> Result<RequestPage, AskError> {
        let pairs = query.pairs();
        let q: Vec<(&str, &str)> = pairs
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        self.get_json("request", &q).await
    }

    /// The stored answer of `query` (a request list) forgets the request `id` (see
    /// [`SeerrClient::drop_from_stored_list`]); called after the request was withdrawn.
    pub fn drop_request_from_stash(&self, query: &RequestQuery, id: i64) {
        let pairs = query.pairs();
        let q: Vec<(&str, &str)> = pairs
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        self.drop_from_stored_list("request", &q, id);
    }

    /// `GET request/count`.
    pub async fn request_count(&self) -> Result<RequestCount, AskError> {
        self.get_json("request/count", &[]).await
    }

    /// `GET request/{id}`.
    pub async fn request_by_id(&self, id: i64) -> Result<RequestRow, AskError> {
        self.get_json(&format!("request/{id}"), &[]).await
    }

    /// `DELETE request/{id}`: withdraws an own waiting request (or any with `MANAGE_REQUESTS`).
    pub async fn cancel_request(&self, id: i64) -> Result<(), AskError> {
        self.send(Method::Delete, &format!("request/{id}"), &[], None, false)
            .await
            .map(|_| ())
    }

    /// `POST request/{id}/approve` (`MANAGE_REQUESTS`).
    pub async fn approve_request(&self, id: i64) -> Result<RequestRow, AskError> {
        self.verdict(id, "approve").await
    }

    /// `POST request/{id}/decline` (`MANAGE_REQUESTS`). Seerr takes no reason.
    pub async fn decline_request(&self, id: i64) -> Result<RequestRow, AskError> {
        self.verdict(id, "decline").await
    }

    /// `POST request/{id}/retry` (a failed request).
    pub async fn retry_request(&self, id: i64) -> Result<RequestRow, AskError> {
        self.verdict(id, "retry").await
    }

    async fn verdict(&self, id: i64, what: &str) -> Result<RequestRow, AskError> {
        let a = self
            .send(
                Method::Post,
                &format!("request/{id}/{what}"),
                &[],
                None,
                false,
            )
            .await?;
        Ok(row_of(&a.body))
    }

    /// `GET service/radarr` or `service/sonarr` (`art` = `movie` / `tv`).
    pub async fn service_servers(&self, art: &str) -> Result<Vec<ServiceServer>, AskError> {
        self.get_json(&format!("service/{}", service_name(art)), &[])
            .await
    }

    /// `GET service/{radarr|sonarr}/{id}`: profiles, folders, tags.
    pub async fn service_detail(&self, art: &str, id: i64) -> Result<ServiceDetail, AskError> {
        self.get_json(&format!("service/{}/{id}", service_name(art)), &[])
            .await
    }

    /// `DELETE media/{id}`: Seerr forgets the title (no file is touched). Admin.
    pub async fn delete_media(&self, media_id: i64) -> Result<(), AskError> {
        self.send(
            Method::Delete,
            &format!("media/{media_id}"),
            &[],
            None,
            false,
        )
        .await
        .map(|_| ())
    }

    /// `DELETE media/{id}/file?is4k=`: Radarr / Sonarr delete the whole film or series with its
    /// files. Admin.
    pub async fn delete_media_file(&self, media_id: i64, is4k: bool) -> Result<(), AskError> {
        self.send(
            Method::Delete,
            &format!("media/{media_id}/file"),
            &[("is4k", if is4k { "true" } else { "false" })],
            None,
            false,
        )
        .await
        .map(|_| ())
    }
}

fn service_name(art: &str) -> &'static str {
    if art == "tv" { "sonarr" } else { "radarr" }
}

impl From<ErrorKind> for AskError {
    fn from(k: ErrorKind) -> Self {
        Self::Network(k)
    }
}
