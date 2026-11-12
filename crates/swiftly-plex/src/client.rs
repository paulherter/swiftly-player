//! **A Plex Media Server, as the app talks to it** (`PlexClient.swift`).
//!
//! Everything that comes out is already an `Item`, `PlaybackPlan`, `Segment` or `Chapter`.
//!
//! **The address can change under the client.** A Plex server is reachable by several
//! addresses and which one works depends on where the device is. When a request does not get
//! through (no route, timeout, certificate, gateway error) and the client knows the account
//! ([`PlexSessionDetails`]), it asks plex.tv for the addresses again, takes the best one that
//! answers ([`crate::PlexConnector`]), and repeats the request once. Calls that run at the same
//! time share one such search. The app is told through [`PlexClient::on_session_change`] so it
//! can keep the new address.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use futures_util::future::{BoxFuture, Either, FutureExt, Shared, select};
use swiftly_jellyfin::{ServerKind, Session};
use swiftly_library::library_filter::{LibraryFilter, Sorting};
use swiftly_model::Item;
use swiftly_net::{ErrorKind, HttpRequest, HttpTransport, Method};
use swiftly_playback::playback_plan::PlaybackPlan;
use swiftly_playback::sections::Segment;
use swiftly_rules::chapter::Chapter;
use url::Url;

use crate::bif::PlexBif;
use crate::connections::{PlexChosenConnection, Sleep};
use crate::identity::{PlexError, PlexIdentity, random_uuid};
use crate::mapping::PlexMapper;
use crate::playback::{PlexPlayback, TimelineState};
use crate::session::{PlexAccountSession, PlexSessionDetails};
use crate::wire::{PlexHub, PlexListing, PlexMetadata, PlexSection};

/// What `/identity` says about a server. Needs no sign-in, so it also answers "is this the
/// server I mean" before a token is spent (PlexClient.swift:9).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexServerInfo {
    /// The machine.
    pub machine_identifier: String,
    /// Server version.
    pub version: Option<String>,
    /// Whether an account owns the server yet (`claimed`).
    pub claimed: bool,
}

/// A page of a list, already mapped (PlexClient.swift:18).
#[derive(Debug, Clone, PartialEq)]
pub struct PlexPage {
    /// The titles.
    pub items: Vec<Item>,
    /// How many entries the whole list has (`totalSize`).
    pub total: i64,
    /// Offset of the page.
    pub start: i64,
}

/// A title with everything the detail page and the player need (PlexClient.swift:26).
#[derive(Debug, Clone, PartialEq)]
pub struct PlexDetail {
    /// The mapped title.
    pub item: Item,
    /// The wire form.
    pub metadata: PlexMetadata,
    /// Skip sections.
    pub segments: Vec<Segment>,
    /// Chapters.
    pub chapters: Vec<Chapter>,
}

/// What asking plex.tv again found: the address to use and the token for it
/// (PlexClient.swift:~58).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexResolvedRoute {
    /// The chosen address.
    pub connection: PlexChosenConnection,
    /// The token for it.
    pub token: String,
}

/// Which picture of a title (`ImageKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageKind {
    /// The poster.
    Poster,
    /// The background.
    Background,
    /// The logo.
    Logo,
    /// The landscape preview.
    Preview,
}

/// Asks plex.tv for the addresses of the server again.
pub type Resolver = Arc<
    dyn Fn(PlexSessionDetails) -> BoxFuture<'static, Result<PlexResolvedRoute, PlexError>>
        + Send
        + Sync,
>;

type Switching = Shared<BoxFuture<'static, Result<PlexResolvedRoute, PlexError>>>;
/// Where the client writes its log lines.
pub type LogSink = Arc<dyn Fn(&str) + Send + Sync>;
type SessionObserver = Arc<dyn Fn(PlexAccountSession) + Send + Sync>;

struct Route {
    base: Url,
    token: String,
}

#[derive(Default)]
struct State {
    user: Option<(String, String)>,
    details: Option<PlexSessionDetails>,
    /// Whether the address in use has answered since the client was built (or was just chosen
    /// by a probe). A stored address is not trusted until then.
    route_confirmed: bool,
    route_observer: Option<SessionObserver>,
    unauthorized_observer: Option<Arc<dyn Fn() + Send + Sync>>,
    /// Set once the observer has been told, so a check that itself gets a `401` does not call it
    /// again.
    unauthorized_told: bool,
    /// The last preview file, so scrubbing does not fetch it for every picture.
    preview_cache: Option<(String, Option<Arc<PlexBif>>)>,
    /// The kind (`collection`, `show`, ...) the server named for an id.
    parent_kinds: HashMap<String, String>,
    switching: Option<Switching>,
}

/// A Plex Media Server client over any [`HttpTransport`].
pub struct PlexClient<T: HttpTransport> {
    transport: Arc<T>,
    /// Who is asking.
    pub identity: PlexIdentity,
    /// One value per client, so the server can tell this play session from another one of the
    /// same account.
    pub session_id: String,
    route: Mutex<Route>,
    state: Mutex<State>,
    resolver: Option<Resolver>,
    sleep: Option<Sleep>,
    log: Option<LogSink>,
    pub(crate) mapper: PlexMapper,
}

fn lock<V>(m: &Mutex<V>) -> MutexGuard<'_, V> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl<T: HttpTransport> PlexClient<T> {
    /// **How long a stored address may stay silent before the others are tried** (:~185). The
    /// address a stored account comes back with is the one from the last launch; on another
    /// network it hangs until the request gives up. After this the addresses are looked up
    /// alongside, and the first request moves over if that finds another one.
    pub const SILENCE_LIMIT: Duration = Duration::from_secs(4);

    /// A client for an address and a token, without an account to fall back on (:99).
    pub fn new(base: Url, token: &str, identity: PlexIdentity, transport: Arc<T>) -> Self {
        Self {
            transport,
            identity,
            session_id: random_uuid().to_uppercase(),
            route: Mutex::new(Route {
                base,
                token: token.into(),
            }),
            state: Mutex::new(State::default()),
            resolver: None,
            sleep: None,
            log: None,
            mapper: PlexMapper::new(),
        }
    }

    /// A client for a stored account. `resolver` asks plex.tv for the addresses of the server
    /// again (:108). Without a Plex block there is nothing to look up and no resolver.
    pub fn from_session(
        stored: &PlexAccountSession,
        identity: PlexIdentity,
        transport: Arc<T>,
        resolver: Option<Resolver>,
    ) -> Result<Self, PlexError> {
        let base =
            Url::parse(&stored.session.server_url).map_err(|_| ErrorKind::InvalidServerUrl)?;
        let mut client = Self::new(base, &stored.session.access_token, identity, transport);
        {
            let mut state = lock(&client.state);
            state.user = Some((
                stored.session.user_id.clone(),
                stored.session.user_name.clone(),
            ));
            state.details = stored.plex.clone();
        }
        client.resolver = if stored.plex.is_some() {
            resolver
        } else {
            None
        };
        Ok(client)
    }

    /// Gives the client a timer, which turns on the silence rule for a stored address that has
    /// not answered yet ([`Self::SILENCE_LIMIT`]).
    #[must_use]
    pub fn with_sleep(mut self, sleep: Sleep) -> Self {
        self.sleep = Some(sleep);
        self
    }

    /// Where the client writes its log lines (`LogRing`).
    #[must_use]
    pub fn with_log(mut self, log: LogSink) -> Self {
        self.log = Some(log);
        self
    }

    /// A text source for "Kapitel n" / "Teil n".
    #[must_use]
    pub fn with_mapper(mut self, mapper: PlexMapper) -> Self {
        self.mapper = mapper;
        self
    }

    pub(crate) fn log_line(&self, line: &str) {
        if let Some(log) = &self.log {
            log(line);
        }
    }

    /// The transport (shared with a signed-out copy).
    pub fn transport(&self) -> Arc<T> {
        Arc::clone(&self.transport)
    }

    /// The address in use. Changes when the client switches.
    pub fn base_url(&self) -> Url {
        lock(&self.route).base.clone()
    }

    /// The token in use.
    pub fn access_token(&self) -> String {
        lock(&self.route).token.clone()
    }

    fn playback(&self) -> PlexPlayback {
        let r = lock(&self.route);
        PlexPlayback::new(r.base.clone(), &r.token)
    }

    pub(crate) fn details(&self) -> Option<PlexSessionDetails> {
        lock(&self.state).details.clone()
    }

    fn machine_key(&self) -> String {
        self.details()
            .map(|d| d.machine_identifier)
            .unwrap_or_else(|| self.base_url().to_string())
    }

    // MARK: Account

    /// The account as a session, with the address in use now. `None` for a client built from an
    /// address alone (:129).
    pub fn current_session(&self) -> Option<PlexAccountSession> {
        let (user, details) = {
            let s = lock(&self.state);
            (s.user.clone()?, s.details.clone())
        };
        let r = lock(&self.route);
        Some(PlexAccountSession {
            session: Session {
                access_token: r.token.clone(),
                user_id: user.0,
                user_name: user.1,
                server_url: r.base.to_string(),
                kind: ServerKind::Plex,
            },
            plex: details,
        })
    }

    /// Called with the new session whenever the client moves to another address.
    pub fn on_session_change(&self, handler: Option<SessionObserver>) {
        lock(&self.state).route_observer = handler;
    }

    /// Called when the server answers `401` to a request: the token may have run out in the
    /// middle of the session. Once, until [`Self::unauthorized_handled`].
    pub fn on_unauthorized(&self, handler: Option<Arc<dyn Fn() + Send + Sync>>) {
        lock(&self.state).unauthorized_observer = handler;
    }

    /// The `401` was looked into and the token still works (it was about one title): the next
    /// one may be reported again.
    pub fn unauthorized_handled(&self) {
        lock(&self.state).unauthorized_told = false;
    }

    /// Forgets the account on this client. The plex.tv token stays valid (it belongs to the
    /// user's other devices too); the app deletes its copy.
    pub fn forget_account(&self) {
        {
            let mut s = lock(&self.state);
            s.user = None;
            s.details = None;
        }
        lock(&self.route).token.clear();
    }

    /// Asks plex.tv for the server's addresses and uses the best one that answers. For a change
    /// of network, where the old address still answers but a better one now exists. Returns
    /// whether the address changed.
    pub async fn choose_best_connection(&self) -> Result<bool, PlexError> {
        let before = self.base_url();
        self.move_to_best_connection(None).await?;
        Ok(self.base_url() != before)
    }

    /// Only a request that did not arrive justifies another address. `401`, `404` and the like
    /// say something about the account or the title, not about the way (:~178).
    pub fn is_route_problem(error: &PlexError) -> bool {
        match error {
            PlexError::Request(ErrorKind::Network { .. })
            | PlexError::Request(ErrorKind::Certificate(_))
            | PlexError::Request(ErrorKind::Transport(_)) => true,
            PlexError::Request(ErrorKind::Http { status, .. }) => {
                [502, 503, 504, 521, 522, 523, 524].contains(status)
            }
            _ => false,
        }
    }

    async fn move_to_best_connection(&self, failed: Option<&Url>) -> Result<(), PlexError> {
        // Someone else already moved: nothing to search, the caller just repeats.
        if let Some(f) = failed
            && self.base_url() != *f
        {
            return Ok(());
        }
        let shared = {
            let mut s = lock(&self.state);
            if let Some(running) = s.switching.clone() {
                running
            } else {
                let (Some(details), Some(resolver)) = (s.details.clone(), self.resolver.clone())
                else {
                    return Err(PlexError::ServerUnreachable);
                };
                let task: Switching = resolver(details).shared();
                s.switching = Some(task.clone());
                task
            }
        };
        let result = shared.await;
        lock(&self.state).switching = None;
        self.adopt(&result?);
        Ok(())
    }

    /// Takes a resolved route into use. Idempotent: callers that shared one search all end
    /// here, the first changes the route and tells the observer.
    fn adopt(&self, resolved: &PlexResolvedRoute) {
        let Ok(base) = Url::parse(&resolved.connection.uri) else {
            return;
        };
        let changed = {
            let mut r = lock(&self.route);
            let changed = r.base != base || r.token != resolved.token;
            r.base = base;
            r.token = resolved.token.clone();
            changed
        };
        let observer = {
            let mut s = lock(&self.state);
            s.route_confirmed = true;
            if changed {
                s.details = s.details.as_ref().map(|d| d.moved(&resolved.connection));
                s.preview_cache = None;
                s.parent_kinds.clear();
            }
            if changed {
                s.route_observer.clone()
            } else {
                None
            }
        };
        if let (Some(observer), Some(session)) = (observer, self.current_session()) {
            observer(session);
        }
    }

    // MARK: Transport

    /// A request to the server with the identity headers, the token and the paging headers
    /// (`request(_:_:_:start:size:)`, PlexClient.swift:~240).
    pub(crate) fn request(
        &self,
        method: Method,
        path: &str,
        query: &[(String, String)],
        start: Option<i64>,
        size: Option<i64>,
    ) -> Result<HttpRequest, PlexError> {
        let playback = self.playback();
        let url = playback
            .url(path, query, false)
            .ok_or(ErrorKind::InvalidServerUrl)?;
        let mut req = HttpRequest::new(method, url);
        req.timeout = Some(Duration::from_secs(20));
        let token = (!playback.token.is_empty()).then_some(playback.token.as_str());
        for (name, value) in self.identity.headers(token, Some(&self.session_id)) {
            req.set_header(&name, &value);
        }
        if let Some(start) = start {
            req.set_header("X-Plex-Container-Start", &start.to_string());
        }
        if let Some(size) = size {
            req.set_header("X-Plex-Container-Size", &size.to_string());
        }
        Ok(req)
    }

    /// Sends what `build` makes. If it does not get through, looks for another address and
    /// builds the request again (the address is part of it) (:~262).
    pub(crate) async fn fetch(
        &self,
        build: impl Fn() -> Result<HttpRequest, PlexError>,
    ) -> Result<Vec<u8>, PlexError> {
        let used = self.base_url();
        let (has_details, unconfirmed) = {
            let s = lock(&self.state);
            (
                s.details.is_some(),
                !s.route_confirmed && s.details.is_some() && self.resolver.is_some(),
            )
        };
        let first = if unconfirmed {
            self.fetch_unconfirmed(&build, &used).await
        } else {
            self.fetch_once(build()?).await
        };
        match first {
            Err(error) if has_details && Self::is_route_problem(&error) => {
                self.move_to_best_connection(Some(&used)).await?;
                self.fetch_once(build()?).await
            }
            other => other,
        }
    }

    /// The first request on a stored address nobody has proven yet: if it stays silent for
    /// [`Self::SILENCE_LIMIT`], the addresses are looked up alongside and the request moves over
    /// when that finds another one. Without a timer ([`Self::with_sleep`]) it is a plain request.
    async fn fetch_unconfirmed(
        &self,
        build: &impl Fn() -> Result<HttpRequest, PlexError>,
        used: &Url,
    ) -> Result<Vec<u8>, PlexError> {
        let request = build()?;
        let Some(sleep) = self.sleep.clone() else {
            let data = self.fetch_once(request).await?;
            lock(&self.state).route_confirmed = true;
            return Ok(data);
        };
        let request_future = self.fetch_once(request).boxed();
        let moved_future = async {
            sleep(Self::SILENCE_LIMIT).await;
            let _ = self.move_to_best_connection(Some(used)).await;
            self.base_url() != *used
        }
        .boxed();
        match select(request_future, moved_future).await {
            Either::Left((result, _)) => {
                let data = result?;
                lock(&self.state).route_confirmed = true;
                Ok(data)
            }
            Either::Right((true, _)) => self.fetch_once(build()?).await,
            Either::Right((false, request_rest)) => {
                let data = request_rest.await?;
                lock(&self.state).route_confirmed = true;
                Ok(data)
            }
        }
    }

    /// One request, no second try. A non-2xx answer is an error; `401` also tells the
    /// unauthorized observer once and becomes "not authenticated" (:~285).
    pub(crate) async fn fetch_once(&self, request: HttpRequest) -> Result<Vec<u8>, PlexError> {
        let response = self.transport.send(request).await?;
        if response.is_success() {
            return Ok(response.body);
        }
        if response.status == 401 {
            let observer = {
                let mut s = lock(&self.state);
                if s.unauthorized_told {
                    None
                } else {
                    s.unauthorized_told = s.unauthorized_observer.is_some();
                    s.unauthorized_observer.clone()
                }
            };
            if let Some(observer) = observer {
                observer();
            }
            return Err(ErrorKind::NotAuthenticated.into());
        }
        Err(ErrorKind::Http {
            status: response.status,
            body: response.text_prefix(300),
        }
        .into())
    }

    /// `GET path` as a list answer (`listing`).
    pub(crate) async fn listing(
        &self,
        path: &str,
        query: &[(&str, &str)],
        start: Option<i64>,
        size: Option<i64>,
    ) -> Result<PlexListing, PlexError> {
        let query: Vec<(String, String)> = query
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        let body = self
            .fetch(|| self.request(Method::Get, path, &query, start, size))
            .await?;
        Ok(PlexListing::from_body(&body)?)
    }

    /// A call without an answer worth reading (`command`).
    pub(crate) async fn command(
        &self,
        method: Method,
        path: &str,
        query: &[(String, String)],
    ) -> Result<(), PlexError> {
        self.fetch(|| self.request(method, path, query, None, None))
            .await
            .map(|_| ())
    }

    pub(crate) fn items_of(&self, listing: &PlexListing) -> Vec<Item> {
        listing
            .metadata
            .iter()
            .map(|m| self.mapper.item(m))
            .collect()
    }

    // MARK: Server

    /// `GET /identity` (:340). Also `publicSystemInfo` and `checkReachability`.
    pub async fn info(&self) -> Result<PlexServerInfo, PlexError> {
        let answer = self.listing("/identity", &[], None, None).await?;
        let machine = answer
            .machine_identifier
            .ok_or_else(|| ErrorKind::Decoding("identity".into()))?;
        Ok(PlexServerInfo {
            machine_identifier: machine,
            version: answer.version,
            claimed: answer.claimed.unwrap_or(false),
        })
    }

    /// Whether the token still works: `401` means no; anything else that fails is an error, not
    /// a sign-out (:354).
    pub async fn token_works(&self) -> Result<bool, PlexError> {
        match self.listing("/library/sections", &[], None, None).await {
            Ok(_) => Ok(true),
            Err(PlexError::Request(ErrorKind::NotAuthenticated)) => Ok(false),
            Err(e) => Err(e),
        }
    }

    // MARK: Libraries and lists

    /// `GET /library/sections` (:365).
    pub async fn sections(&self) -> Result<Vec<PlexSection>, PlexError> {
        Ok(self
            .listing("/library/sections", &[], None, None)
            .await?
            .directories)
    }

    /// The libraries the app can show (films and series), as home-page views (:370).
    pub async fn views(&self) -> Result<Vec<Item>, PlexError> {
        Ok(self
            .sections()
            .await?
            .iter()
            .filter(|s| s.type_ == "movie" || s.type_ == "show")
            .map(|s| self.mapper.view(s))
            .collect())
    }

    /// A page of a library (:395). `type_` is an `Item` type (`Movie`, `Series`, `Season`,
    /// `Episode`); `None` is the library's own kind. `genre_id` is the `key` of a genre entry,
    /// see [`Self::genres_of_section`].
    #[allow(clippy::too_many_arguments)] // the Swift signature, kept 1:1
    pub async fn list(
        &self,
        section: &str,
        type_: Option<&str>,
        sort: Sorting,
        filter: LibraryFilter,
        genre_id: Option<&str>,
        start: i64,
        size: i64,
    ) -> Result<PlexPage, PlexError> {
        let sort_value = Self::sort_value(sort);
        let mut query: Vec<(&str, String)> = vec![("sort", sort_value.to_string())];
        if let Some(number) = type_.and_then(PlexMapper::plex_type_number) {
            query.push(("type", number.to_string()));
        }
        match filter {
            LibraryFilter::Begun => query.push(("inProgress", "1".into())),
            LibraryFilter::Unwatched => query.push(("unwatched", "1".into())),
            // A favourite is a rating of 9 or more (hearts are written as 10).
            LibraryFilter::Watchlist => query.push(("userRating>>", "9".into())),
            LibraryFilter::All => {}
        }
        if let Some(g) = genre_id {
            query.push(("genre", g.to_string()));
        }
        let query: Vec<(&str, &str)> = query.iter().map(|(k, v)| (*k, v.as_str())).collect();
        let answer = self
            .listing(
                &format!("/library/sections/{section}/all"),
                &query,
                Some(start),
                Some(size),
            )
            .await?;
        Ok(PlexPage {
            items: self.items_of(&answer),
            total: answer.total_size.unwrap_or(answer.size),
            start: answer.offset.unwrap_or(start),
        })
    }

    /// Plex's sort expression for one of the app's sortings (:~405).
    pub fn sort_value(sorting: Sorting) -> &'static str {
        match sorting {
            Sorting::Name => "titleSort:asc",
            Sorting::Latest => "addedAt:desc",
            Sorting::Rating => "audienceRating:desc",
            Sorting::Erscheinung => "originallyAvailableAt:desc",
        }
    }

    /// `GET /library/sections/{id}/genre` (:413).
    pub async fn genres_of_section(&self, section: &str) -> Result<Vec<PlexSection>, PlexError> {
        Ok(self
            .listing(
                &format!("/library/sections/{section}/genre"),
                &[],
                None,
                None,
            )
            .await?
            .directories)
    }

    // MARK: Shelves

    /// "Continue watching": started films and episodes, newest first (:421).
    pub async fn continue_watching(&self, limit: i64) -> Result<Vec<Item>, PlexError> {
        let answer = self
            .listing("/hubs/continueWatching/items", &[], Some(0), Some(limit))
            .await?;
        Ok(self.items_of(&answer))
    }

    /// The next unwatched episode of every series being watched (:427).
    pub async fn on_deck(&self, limit: i64) -> Result<Vec<Item>, PlexError> {
        let answer = self
            .listing("/library/onDeck", &[], Some(0), Some(limit))
            .await?;
        Ok(self.items_of(&answer))
    }

    /// Newly added films and episodes, optionally of one library (:432).
    pub async fn recently_added(
        &self,
        section: Option<&str>,
        limit: i64,
    ) -> Result<Vec<Item>, PlexError> {
        let path = section
            .map(|s| format!("/library/sections/{s}/recentlyAdded"))
            .unwrap_or_else(|| "/library/recentlyAdded".into());
        let answer = self.listing(&path, &[], Some(0), Some(limit)).await?;
        Ok(self.items_of(&answer))
    }

    /// All shelves the server composes for a library (or the home page), unmapped (:438).
    pub async fn hubs(&self, section: Option<&str>) -> Result<Vec<PlexHub>, PlexError> {
        let path = section
            .map(|s| format!("/hubs/sections/{s}"))
            .unwrap_or_else(|| "/hubs".into());
        Ok(self.listing(&path, &[], None, None).await?.hubs)
    }

    /// `GET /hubs/search`: films, series and episodes whose name matches (:445).
    pub async fn search(&self, term: &str, limit: i64) -> Result<Vec<Item>, PlexError> {
        let clean = term.trim();
        if clean.is_empty() {
            return Ok(vec![]);
        }
        let limit = limit.to_string();
        let answer = self
            .listing(
                "/hubs/search",
                &[("query", clean), ("limit", &limit)],
                None,
                None,
            )
            .await?;
        let mut seen = std::collections::HashSet::new();
        Ok(answer
            .hubs
            .iter()
            .flat_map(|h| h.items.iter())
            .filter(|m| {
                ["movie", "show", "episode"].contains(&m.type_.as_str())
                    && seen.insert(m.rating_key.clone())
            })
            .map(|m| self.mapper.item(m))
            .collect())
    }

    // MARK: Details

    /// `GET /library/metadata/{id}` with markers and chapters (:457).
    pub async fn detail(&self, rating_key: &str) -> Result<PlexDetail, PlexError> {
        let answer = self
            .listing(
                &format!("/library/metadata/{rating_key}"),
                &[("includeChapters", "1"), ("includeMarkers", "1")],
                None,
                None,
            )
            .await?;
        let metadata = answer
            .metadata
            .into_iter()
            .next()
            .ok_or(ErrorKind::NoPlayableSource)?;
        Ok(PlexDetail {
            item: self.mapper.item(&metadata),
            segments: self.mapper.segments(&metadata.markers, metadata.duration),
            chapters: self.mapper.chapters(&metadata.chapters),
            metadata,
        })
    }

    /// One title.
    pub async fn item(&self, rating_key: &str) -> Result<Item, PlexError> {
        Ok(self.detail(rating_key).await?.item)
    }

    /// Children: a series' seasons, a season's episodes (:469).
    pub async fn children(&self, rating_key: &str) -> Result<Vec<Item>, PlexError> {
        let answer = self
            .listing(
                &format!("/library/metadata/{rating_key}/children"),
                &[],
                None,
                None,
            )
            .await?;
        Ok(self.items_of(&answer))
    }

    /// One season's episodes, or all of the series (:478).
    pub async fn episodes_of(
        &self,
        series_id: &str,
        season_id: Option<&str>,
    ) -> Result<Vec<Item>, PlexError> {
        if let Some(season) = season_id {
            return self.children(season).await;
        }
        let answer = self
            .listing(
                &format!("/library/metadata/{series_id}/allLeaves"),
                &[],
                None,
                None,
            )
            .await?;
        Ok(self.items_of(&answer))
    }

    /// Titles like this one (:483).
    pub async fn similar_to(&self, rating_key: &str, limit: i64) -> Result<Vec<Item>, PlexError> {
        let count = limit.to_string();
        let answer = self
            .listing(
                &format!("/library/metadata/{rating_key}/similar"),
                &[("count", &count)],
                Some(0),
                Some(limit),
            )
            .await?;
        Ok(self.items_of(&answer))
    }

    /// `GET /library/metadata/{id}/extras`: trailers and extras. Only those with a file of
    /// their own count: an online extra has nothing to play from this server (:491). A `404`
    /// (a title the server does not know) is an empty list.
    pub async fn clips(&self, rating_key: &str) -> Result<Vec<PlexMetadata>, PlexError> {
        let answer = match self
            .listing(
                &format!("/library/metadata/{rating_key}/extras"),
                &[],
                None,
                None,
            )
            .await
        {
            Ok(a) => a,
            Err(PlexError::Request(ErrorKind::Http { status: 404, .. })) => return Ok(vec![]),
            Err(e) => return Err(e),
        };
        Ok(answer
            .metadata
            .into_iter()
            .filter(|m| m.media.iter().any(|x| !x.parts.is_empty()))
            .collect())
    }

    /// The collections of a library (:498).
    pub async fn collections(&self, section: &str) -> Result<Vec<Item>, PlexError> {
        let answer = self
            .listing(
                &format!("/library/sections/{section}/collections"),
                &[],
                None,
                None,
            )
            .await?;
        Ok(self.items_of(&answer))
    }

    /// The members of a collection (:502).
    pub async fn collection_items(&self, rating_key: &str) -> Result<Vec<Item>, PlexError> {
        let answer = self
            .listing(
                &format!("/library/collections/{rating_key}/children"),
                &[],
                None,
                None,
            )
            .await?;
        Ok(self.items_of(&answer))
    }

    /// Video playlists (:507).
    pub async fn playlists(&self) -> Result<Vec<Item>, PlexError> {
        let answer = self
            .listing("/playlists", &[("playlistType", "video")], None, None)
            .await?;
        Ok(self.items_of(&answer))
    }

    /// The entries of a playlist (:512).
    pub async fn playlist_items(&self, rating_key: &str) -> Result<Vec<Item>, PlexError> {
        let answer = self
            .listing(&format!("/playlists/{rating_key}/items"), &[], None, None)
            .await?;
        Ok(self.items_of(&answer))
    }

    /// Everything a person or genre filter finds in one library (:518).
    pub async fn titles(
        &self,
        section: &str,
        filter: &str,
        value: &str,
        start: i64,
        size: i64,
    ) -> Result<PlexPage, PlexError> {
        let answer = self
            .listing(
                &format!("/library/sections/{section}/all"),
                &[(filter, value)],
                Some(start),
                Some(size),
            )
            .await?;
        Ok(PlexPage {
            items: self.items_of(&answer),
            total: answer.total_size.unwrap_or(answer.size),
            start,
        })
    }

    // MARK: State

    /// `PUT /:/scrobble` or `/:/unscrobble` (:528).
    pub async fn set_watched_key(&self, rating_key: &str, watched: bool) -> Result<(), PlexError> {
        self.command(
            Method::Put,
            if watched {
                "/:/scrobble"
            } else {
                "/:/unscrobble"
            },
            &[
                ("key".into(), rating_key.into()),
                ("identifier".into(), "com.plexapp.plugins.library".into()),
            ],
        )
        .await
    }

    /// A favourite is a rating of 10; taking it away removes the rating (`-1`) (:534).
    pub async fn set_favorite(&self, rating_key: &str, favorite: bool) -> Result<(), PlexError> {
        self.command(
            Method::Put,
            "/:/rate",
            &[
                ("key".into(), rating_key.into()),
                ("identifier".into(), "com.plexapp.plugins.library".into()),
                ("rating".into(), if favorite { "10" } else { "-1" }.into()),
            ],
        )
        .await
    }

    /// Tells the server which tracks the user chose, so they are the default next time (:545).
    pub async fn choose_tracks(
        &self,
        part_id: i64,
        audio_stream_id: Option<i64>,
        subtitle_stream_id: Option<i64>,
    ) -> Result<(), PlexError> {
        let mut query = vec![("allParts".to_string(), "1".to_string())];
        if let Some(a) = audio_stream_id {
            query.push(("audioStreamID".into(), a.to_string()));
        }
        // 0 switches subtitles off.
        query.push((
            "subtitleStreamID".into(),
            subtitle_stream_id.unwrap_or(0).to_string(),
        ));
        self.command(Method::Put, &format!("/library/parts/{part_id}"), &query)
            .await
    }

    // MARK: Images

    /// A picture address from a path the server wrote (:~560).
    pub fn image_url_path(
        &self,
        path: &str,
        max_height: Option<i64>,
        max_width: Option<i64>,
    ) -> Option<Url> {
        self.playback().image_url(path, max_height, max_width)
    }

    /// The picture of a title for a purpose.
    pub fn image_url_for(
        &self,
        item: &Item,
        kind: ImageKind,
        max_height: Option<i64>,
        max_width: Option<i64>,
    ) -> Option<Url> {
        let tags = item.image_tags.as_ref();
        let path = match kind {
            ImageKind::Poster => tags.and_then(|t| t.get("Primary")),
            ImageKind::Background => item
                .backdrop_image_tags
                .as_ref()
                .and_then(|b| b.first())
                .or_else(|| {
                    item.parent_backdrop_image_tags
                        .as_ref()
                        .and_then(|b| b.first())
                }),
            ImageKind::Logo => tags.and_then(|t| t.get("Logo")),
            ImageKind::Preview => tags.and_then(|t| t.get("Thumb").or_else(|| t.get("Primary"))),
        }?;
        self.image_url_path(path, max_height, max_width)
    }

    // MARK: Playback

    /// Direct play, always. No server call besides the detail (:~585).
    pub async fn plan_for(
        &self,
        rating_key: &str,
        media_source_id: Option<&str>,
        audio_stream_id: Option<i64>,
        subtitle_stream_id: Option<i64>,
    ) -> Result<PlaybackPlan, PlexError> {
        let detail = self.detail(rating_key).await?;
        self.playback().plan(
            &detail.metadata,
            media_source_id,
            audio_stream_id,
            subtitle_stream_id,
            &self.session_id,
        )
    }

    /// [`Self::plan_for`] for a device that may not be able to show the file: AV1 Dolby Vision
    /// 10.0 (no HDR10 base layer) on a device that cannot render it gets the universal
    /// transcoder's address when the server says it will transcode (decision with direct play
    /// and direct stream off). Every other title, and a server that refuses or does not answer,
    /// keeps the direct plan (the engine then shows its message). `flavour`/hardware AV1 as in
    /// [`swiftly_playback::dolby_vision::needs_server_transcode`].
    pub async fn plan_for_device(
        &self,
        rating_key: &str,
        media_source_id: Option<&str>,
        audio_stream_id: Option<i64>,
        subtitle_stream_id: Option<i64>,
        device: (
            swiftly_playback::device_profile::Flavour,
            swiftly_playback::dolby_vision::HostDecoders,
        ),
    ) -> Result<PlaybackPlan, PlexError> {
        let detail = self.detail(rating_key).await?;
        let playback = self.playback();
        let direct = playback.plan(
            &detail.metadata,
            media_source_id,
            audio_stream_id,
            subtitle_stream_id,
            &self.session_id,
        )?;
        let Some(source) = direct.source.as_ref() else {
            return Ok(direct);
        };
        if !swiftly_playback::dolby_vision::needs_server_transcode(source, device.0, device.1) {
            return Ok(direct);
        }
        let Some(file) = PlexPlayback::file(&detail.metadata, media_source_id) else {
            return Ok(direct);
        };
        let identity: Vec<(String, String)> = self
            .identity
            .headers(None, None)
            .into_iter()
            .filter(|(k, _)| k.starts_with("X-Plex-"))
            .collect();
        let Some(plan) = playback.transcode_plan(
            &direct,
            &detail.metadata,
            &file,
            &self.session_id,
            &identity,
        ) else {
            return Ok(direct);
        };
        // Ask first: a refusing server (transcoding off, no transcoder) must keep the original plan.
        let media_index = detail
            .metadata
            .media
            .iter()
            .position(|m| m.id == file.media.id)
            .unwrap_or(0);
        let query = crate::PlexDecision::transcode_query(
            rating_key,
            media_index,
            usize::try_from(file.number - 1).unwrap_or(0),
            &self.session_id,
        );
        let answer = self
            .fetch(|| self.request(Method::Get, crate::PlexDecision::PATH, &query, None, None))
            .await
            .ok()
            .and_then(|body| crate::PlexDecision::from_body(&body).ok());
        Ok(if answer.is_some_and(|d| d.allows_transcode()) {
            plan
        } else {
            direct
        })
    }

    /// The original file for a download (:~595).
    pub async fn download_url_of(
        &self,
        rating_key: &str,
        media_source_id: Option<&str>,
    ) -> Result<Url, PlexError> {
        let metadata = self.detail(rating_key).await?.metadata;
        let part = PlexPlayback::part(&metadata, media_source_id).ok_or(PlexError::NoFile)?;
        self.playback()
            .file_url(&part.key, true)
            .ok_or(PlexError::NoFile)
    }

    /// An external subtitle with the token attached. Embedded tracks have none.
    pub fn subtitle_url(&self, stream: &crate::wire::PlexStream) -> Option<Url> {
        self.playback().subtitle_url(stream)
    }

    /// The address of a subtitle of a mapped stream (`MediaStream.deliveryUrl` holds the bare
    /// path).
    pub fn subtitle_url_path(&self, path: &str) -> Option<Url> {
        self.playback().url(path, &[], true)
    }

    /// Skip buttons.
    pub async fn segments(&self, rating_key: &str) -> Result<Vec<Segment>, PlexError> {
        Ok(self.detail(rating_key).await?.segments)
    }

    /// Chapters.
    pub async fn chapters_of(&self, rating_key: &str) -> Result<Vec<Chapter>, PlexError> {
        Ok(self.detail(rating_key).await?.chapters)
    }

    /// The preview pictures of a title, or `None` if the server made none (`404`) (:~615).
    pub async fn previews(
        &self,
        rating_key: &str,
        media_source_id: Option<&str>,
    ) -> Result<Option<Arc<PlexBif>>, PlexError> {
        let metadata = self.detail(rating_key).await?.metadata;
        let playback = self.playback();
        let Some(part) = PlexPlayback::part(&metadata, media_source_id) else {
            return Ok(None);
        };
        if part.indexes.is_none() {
            return Ok(None);
        }
        let Some(address) = playback.preview_index_url(part.id) else {
            return Ok(None);
        };
        let key = format!("{}/{}", self.machine_key(), part.id);
        if let Some((cached_key, bif)) = &lock(&self.state).preview_cache
            && *cached_key == key
        {
            return Ok(bif.clone());
        }
        let token = self.access_token();
        let mut request = HttpRequest::new(Method::Get, address);
        for (name, value) in self
            .identity
            .headers((!token.is_empty()).then_some(token.as_str()), None)
        {
            request.set_header(&name, &value);
        }
        request.set_header("Accept", "*/*");
        match self.fetch_once(request).await {
            Ok(data) => {
                let bif = PlexBif::parse(&data).map(Arc::new);
                lock(&self.state).preview_cache = Some((key, bif.clone()));
                Ok(bif)
            }
            Err(PlexError::Request(ErrorKind::Http { status: 404, .. })) => {
                lock(&self.state).preview_cache = Some((key, None));
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }

    // MARK: Reports

    /// `POST /:/timeline`. Send on every change of state and about every ten seconds in
    /// between; the server marks a title watched itself when it is played to the end (:641).
    pub async fn report_timeline(
        &self,
        rating_key: &str,
        state: TimelineState,
        position_ticks: i64,
        duration_milliseconds: Option<i64>,
    ) -> Result<(), PlexError> {
        self.command(
            Method::Post,
            "/:/timeline",
            &PlexPlayback::timeline_query(rating_key, state, position_ticks, duration_milliseconds),
        )
        .await
    }

    /// `GET /video/:/transcode/universal/decision` for the first file of a title: may it be
    /// played as it is? Starts no transcode session; additive (Swift never asks).
    pub async fn direct_play_decision(
        &self,
        rating_key: &str,
        media_index: usize,
        part_index: usize,
    ) -> Result<crate::PlexDecision, PlexError> {
        let query = crate::PlexDecision::query(rating_key, media_index, part_index);
        let body = self
            .fetch(|| self.request(Method::Get, crate::PlexDecision::PATH, &query, None, None))
            .await?;
        Ok(crate::PlexDecision::from_body(&body)?)
    }

    /// The address of the notifications socket for the current server address and token.
    pub fn notifications_url(&self) -> Option<Url> {
        crate::notifications::socket_url(&self.base_url(), &self.access_token())
    }

    pub(crate) fn kind_cache_get(&self, id: &str) -> Option<String> {
        lock(&self.state).parent_kinds.get(id).cloned()
    }

    pub(crate) fn kind_cache_set(&self, id: &str, kind: &str) {
        lock(&self.state)
            .parent_kinds
            .insert(id.into(), kind.into());
    }
}
