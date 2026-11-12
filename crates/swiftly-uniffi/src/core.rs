use std::sync::Arc;
use std::time::Duration;

use async_compat::Compat;
use futures_util::FutureExt;
use swiftly_images::{MemoryPressure, TrimLevel};
use swiftly_l10n::Locale;
use swiftly_vm::{AccountRef, HomePrefs, Host, SeriesSpec, SystemClock, Tile};

use crate::detail::{DetailVm, SeriesVm, item_of};
use crate::error::CoreError;
use crate::hello::HelloVm;
use crate::home::HomeVm;
use crate::library::{LibraryVm, TextKeys};
use crate::probe::{EngineProbe, PlayerProbe};
use crate::search::{SearchVm, TokioSleeper};
use crate::stores::{Blobs, KeyValueStore, SecretStore};
use crate::transport::{CoreTransport, HttpClient};

mod runtime;
use runtime::{CoreRuntime, CoreSpawner};

/// The version the app told the core (`Core::set_client_version`).
static CLIENT_VERSION: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

/// What the core needs from the host platform (paths, locale, device name, log, ...).
#[uniffi::export(with_foreign)]
pub trait Platform: Send + Sync {
    /// The name the server lists this device under.
    fn device_name(&self) -> String;
    /// One log line. Never contains a secret.
    fn log(&self, line: String);
    /// A directory the core may keep disposable files in (the entity cache database, the image
    /// plate): Apple `Caches/`, Android `cacheDir`, desktop the XDG/AppData cache directory.
    /// The OS may clear it at any time; the core rebuilds what is gone. `None`: keep everything
    /// in memory (nothing survives a launch).
    fn cache_dir(&self) -> Option<String>;
}

/// The system's names of languages, for track lists: Swift names a track language with the device's language
/// (`Locale.localizedString(forLanguageCode:)`: an English user reads "German", not "Deutsch"). Optional; install
/// it with [`Core::set_language_names`]. Without it, or when it answers `None`, the core's built-in table of the
/// ISO 639-1/639-2 names in German, English and Russian answers.
#[uniffi::export(with_foreign)]
pub trait LanguageNames: Send + Sync {
    /// The name of the language `code` (ISO 639-1/-2 code or a tag such as `pt-br`, lower case) in the interface
    /// language `language` (`de`, `en`, `ru`), `None` if the system has none. Apple: `Locale(identifier:
    /// language).localizedString(forLanguageCode: code)`; Android: `java.util.Locale.getDisplayLanguage`.
    fn language_name(&self, code: String, language: String) -> Option<String>;
    /// Whether the system knows the code at all (`Locale(identifier: "en").localizedString(forLanguageCode:) != nil`).
    fn knows_language(&self, code: String) -> bool;
}

struct HostNames(Arc<dyn LanguageNames>);

impl swiftly_vm::NameSource for HostNames {
    fn name(&self, code: &str, language: &str) -> Option<String> {
        self.0.language_name(code.to_owned(), language.to_owned())
    }
    fn knows(&self, code: &str) -> bool {
        self.0.knows_language(code.to_owned())
    }
}

/// The entry point of the core. One per app.
#[derive(uniffi::Object)]
pub struct Core {
    platform: Arc<dyn Platform>,
    secrets: Arc<dyn SecretStore>,
    blobs: Arc<Blobs>,
    store: Arc<dyn KeyValueStore>,
    /// The runtime of the view model effects: an owned multi-thread runtime, or (if it could not
    /// be built) the handle of the `async-compat` one.
    runtime: Option<Arc<CoreRuntime>>,
    fallback: Option<tokio::runtime::Handle>,
    transport: CoreTransport,
    pressure: Arc<MemoryPressure>,
    /// The entity cache every view model paints from first (SQLite in `Platform.cache_dir()`,
    /// in memory when the host gives no directory).
    cache: Option<swiftly_vm::ViewCache>,
}

impl Core {
    /// The host-backed transport, for the exports that live in their own file.
    pub(crate) fn transport_handle(&self) -> CoreTransport {
        self.transport.clone()
    }

    /// The registry the core's caches join, so one host call trims them all.
    pub fn pressure(&self) -> Arc<MemoryPressure> {
        Arc::clone(&self.pressure)
    }
}

#[uniffi::export]
impl Core {
    /// A core over the host's platform, secret store and key-value store.
    #[uniffi::constructor]
    pub fn new(
        platform: Arc<dyn Platform>,
        secrets: Arc<dyn SecretStore>,
        store: Arc<dyn KeyValueStore>,
        http: Arc<dyn HttpClient>,
    ) -> Arc<Self> {
        // A panic message can carry text from a server or a URL: it goes to the host log scrubbed, never raw.
        // Unwinding stays on, so UniFFI's catch_unwind still turns the panic into an error for the host.
        let log_sink = Arc::clone(&platform);
        swiftly_net::redact::install_panic_hook(move |line| log_sink.log(line));
        platform.log("core: created".to_owned());
        let cache = open_cache(&*platform);
        let runtime = match CoreRuntime::new(runtime::worker_count()) {
            Ok(r) => Some(Arc::new(r)),
            Err(e) => {
                platform.log(format!(
                    "core: own runtime failed ({e}), using the shared one"
                ));
                None
            }
        };
        // The handle of the async-compat runtime: entering `Compat` makes it the current one.
        let fallback = Compat::new(async { tokio::runtime::Handle::current() }).now_or_never();
        Arc::new(Self {
            platform,
            secrets,
            blobs: Arc::new(Blobs(Arc::clone(&store))),
            store,
            runtime,
            fallback,
            transport: CoreTransport::new(http),
            pressure: Arc::new(MemoryPressure::new()),
            cache,
        })
    }

    /// The saved accounts and every way to add one. `device_id` is the stable id of this
    /// installation that the account references carry.
    pub fn accounts_model(
        &self,
        device_id: String,
        locale: String,
    ) -> Result<Arc<crate::accounts::AccountsModel>, CoreError> {
        Ok(crate::accounts::AccountsModel::build(
            Arc::clone(&self.secrets),
            self.transport.foreign().clone(),
            self.host(&locale)?,
            device_id,
            &locale,
        ))
    }

    /// The sign-in screen over the byte store (see [`crate::login::LoginModel`]).
    pub fn login_model(
        &self,
        accounts: Arc<crate::accounts::AccountsModel>,
        locale: String,
    ) -> Arc<crate::login::LoginModel> {
        crate::login::LoginModel::over_packed(accounts, Arc::clone(&self.store), &locale)
    }

    /// The sign-in screen over the host's typed store (`UserDefaults`: `letzterServer`, `serverNamenCache`).
    pub fn login_model_native(
        &self,
        accounts: Arc<crate::accounts::AccountsModel>,
        store: Arc<dyn crate::settings::SettingsStore>,
        locale: String,
    ) -> Arc<crate::login::LoginModel> {
        crate::login::LoginModel::over_native(accounts, store, &locale)
    }

    /// The control channel of an account (remote commands, play orders, takeover hints and
    /// SyncPlay messages) over the host's WebSocket. Nothing connects before `start`.
    pub fn remote_channel(
        &self,
        account: AccountRef,
        link: Arc<dyn crate::remote::WebSocketLink>,
        listener: Arc<dyn crate::remote::RemoteListener>,
    ) -> Result<Arc<crate::remote::RemoteChannel>, CoreError> {
        Ok(crate::remote::RemoteChannel::build(
            link,
            listener,
            self.host("en")?,
            account,
            crate::remote::Timing::default(),
        ))
    }

    /// `POST Sessions/Capabilities/Full`: the host calls it when the control channel reports `connected`, so the
    /// session can be controlled and other devices offer "continue here" (`reportCapabilities` of the old core).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn report_capabilities(&self, account: AccountRef) -> Result<(), CoreError> {
        let client = swiftly_vm::account_client(
            &Arc::new(self.transport.clone()),
            &self.host("en")?,
            &account,
        )?;
        client.report_capabilities().await.map_err(CoreError::from)
    }

    /// The Plex play check of an account (state machine over the decision call); an error when the
    /// account is not a Plex account.
    pub fn plex_play_check(
        &self,
        account: AccountRef,
    ) -> Result<Arc<crate::plex_live::PlexPlayCheckModel>, CoreError> {
        let client = swiftly_vm::plex_client_for(
            &Arc::new(self.transport.clone()),
            &self.host("en")?,
            &account,
        )?
        .ok_or_else(|| CoreError::Failed {
            message: "not a Plex account".to_owned(),
        })?;
        Ok(crate::plex_live::PlexPlayCheckModel::new(Arc::new(
            crate::plex_live::ClientAsker(client),
        )))
    }

    /// The Plex notifications socket address (`ws`/`wss`, token in the query) of a Plex account;
    /// `None` when it is not one. The host owns the socket and feeds frames to a `PlexChangeFeed`.
    pub fn plex_notifications_url(&self, account: AccountRef) -> Result<Option<String>, CoreError> {
        let client = swiftly_vm::plex_client_for(
            &Arc::new(self.transport.clone()),
            &self.host("en")?,
            &account,
        )?;
        Ok(client
            .and_then(|c| c.notifications_url())
            .map(|u| u.to_string()))
    }

    /// The SyncPlay session of an account over the server calls of the core. Feed it the
    /// `SyncPlay` messages of the `RemoteChannel`; `host` moves the player.
    pub fn sync_play_model(
        &self,
        account: AccountRef,
        locale: String,
        self_name: Option<String>,
        host: Arc<dyn crate::sync_play::SyncPlayHost>,
    ) -> Result<Arc<crate::sync_play::SyncPlayModel>, CoreError> {
        crate::sync_play::SyncPlayModel::build(
            self.transport.clone(),
            self.host(&locale)?,
            &account,
            self_name,
            host,
        )
    }

    /// Settings that follow the account: one run reads the server copy and either hands its
    /// values to the host or writes the local ones.
    pub fn settings_sync_model(
        &self,
        account: AccountRef,
        locale: String,
    ) -> Result<Arc<crate::settings_sync::SettingsSyncModel>, CoreError> {
        crate::settings_sync::SettingsSyncModel::build(
            self.transport.clone(),
            &self.host(&locale)?,
            &account,
        )
    }

    /// A Seerr connection (address, session cookie, own headers) to search and request through.
    pub fn seerr_model(
        &self,
        connection: crate::seerr::SeerrConnection,
        jar: Option<Arc<dyn crate::seerr::SeerrCookieJar>>,
    ) -> Arc<crate::seerr::SeerrModel> {
        crate::seerr::SeerrModel::build(self.transport.clone(), connection, jar)
    }

    /// Signs in to a Seerr with the Jellyfin user and returns the connection to store
    /// (`seerr|<account>`). `typed` is what the user typed; schemes and ports are tried.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn seerr_sign_in(
        &self,
        typed: String,
        user: String,
        password: String,
        headers: Vec<swiftly_jellyfin::OwnHeader>,
        jar: Option<Arc<dyn crate::seerr::SeerrCookieJar>>,
    ) -> Result<crate::seerr::SeerrConnection, CoreError> {
        crate::seerr::SeerrModel::sign_in(
            self.transport.clone(),
            jar,
            &typed,
            &user,
            &password,
            &headers,
        )
        .await
    }

    /// The old facade's Seerr calls over a stored access (`{"adresse","keks","koepfe"}`); `None` when it does not read.
    pub fn legacy_seerr(&self, access: String) -> Option<Arc<crate::legacy_seerr::LegacySeerr>> {
        let c = crate::legacy_seerr::connection_of(&access)?;
        Some(crate::legacy_seerr::LegacySeerr::new(
            crate::seerr::SeerrModel::build(self.transport.clone(), c, None),
        ))
    }

    /// `Kern.seerrConnect`: signs in with the Jellyfin name and password and returns the access JSON to store.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn legacy_seerr_connect(
        &self,
        address: String,
        user: String,
        password: String,
        headers: String,
    ) -> Result<String, CoreError> {
        let headers: Vec<swiftly_jellyfin::OwnHeader> =
            serde_json::from_str(&headers).unwrap_or_default();
        let c = crate::seerr::SeerrModel::sign_in(
            self.transport.clone(),
            None,
            &address,
            &user,
            &password,
            &headers,
        )
        .await?;
        Ok(crate::legacy_seerr::access_json(&c))
    }

    /// Automatic Seerr sign-in with the Jellyfin account's own credentials: keeps a valid stored
    /// session, else signs in with `user` and the password from `secret` (the host's Keychain).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn seerr_auto_sign_in(
        &self,
        typed: String,
        user: String,
        stored: Option<crate::seerr::SeerrConnection>,
        secret: Arc<dyn crate::seerr::SeerrPasswordSource>,
        headers: Vec<swiftly_jellyfin::OwnHeader>,
        jar: Option<Arc<dyn crate::seerr::SeerrCookieJar>>,
    ) -> Result<crate::seerr::SeerrAutoState, CoreError> {
        Ok(crate::seerr::SeerrModel::auto_sign_in(
            self.transport.clone(),
            jar,
            &typed,
            &user,
            stored,
            secret,
            &headers,
        )
        .await)
    }

    /// The page of a person (cast entry); `origin` is the title the tap came from.
    pub fn person_model(
        &self,
        account: AccountRef,
        locale: String,
        person: crate::pages::PersonInfo,
        origin: Option<String>,
    ) -> Result<Arc<crate::pages::PersonModel>, CoreError> {
        crate::pages::PersonModel::build(
            self.transport.clone(),
            &self.host(&locale)?,
            &account,
            person,
            origin,
        )
    }

    /// The page of a video playlist; `art` is the section it was opened from.
    pub fn playlist_model(
        &self,
        account: AccountRef,
        locale: String,
        playlist: Tile,
        art: Option<String>,
    ) -> Result<Arc<crate::pages::PlaylistModel>, CoreError> {
        crate::pages::PlaylistModel::build(
            self.transport.clone(),
            &self.host(&locale)?,
            &account,
            &playlist,
            art,
        )
    }

    /// Awaits a short sleep on the async runtime, then answers with the device name.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn ping(&self, n: u32) -> Result<String, CoreError> {
        tokio::time::sleep(Duration::from_millis(2)).await;
        let device = self.platform.device_name();
        self.platform.log(format!("core: ping {n}"));
        Ok(format!("pong {n} from {device}"))
    }

    /// The picture sizes (points) tiles ask the server for: poster height and backdrop width. A host whose
    /// tiles are larger than a phone's (Apple TV: 600 and 900) calls this once after creating the core; `0`
    /// keeps the default (360 and 640).
    pub fn set_tile_image_sizes(&self, poster_height: u32, backdrop_width: u32) {
        swiftly_vm::set_tile_image_sizes(poster_height, backdrop_width);
    }

    /// The app's own version for the `Version=` of the `Authorization` header (the server's device list
    /// shows it); process-wide. Call once after creating the core. Without it the core's crate version is sent.
    pub fn set_client_version(&self, version: String) {
        *CLIENT_VERSION
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(version);
    }

    /// The system's language names for track lists and file lines (process-wide; `None` removes it again and
    /// leaves the built-in table). Call once after creating the core, before the first player opens.
    pub fn set_language_names(&self, names: Option<Arc<dyn LanguageNames>>) {
        swiftly_vm::set_name_source(
            names.map(|n| Arc::new(HostNames(n)) as Arc<dyn swiftly_vm::NameSource>),
        );
    }

    /// The name of a language code in the interface language as the track lists show it (`TrackLabel.language`,
    /// capitalised, "Unbekannt" for undetermined, an unknown code in capitals), through the installed names or
    /// the built-in table. For hosts that draw their own track rows.
    pub fn track_language(&self, raw: Option<String>, locale: String) -> Option<String> {
        swiftly_playback::track_label::language(
            raw.as_deref(),
            &swiftly_vm::LabelWords::new(swiftly_l10n::Locale::parse(&locale)),
        )
    }

    /// The host reports memory pressure (iOS memory warning, Android `onTrimMemory`): `0` keeps a quarter of the
    /// image memory, anything else drops all rebuildable memory. Disk caches stay. Answers how many caches reacted.
    /// Safe to call from any thread at any time; no lock is held while a cache trims.
    pub fn memory_warning(&self, level: u8) -> u32 {
        let reached = self.pressure.warn(TrimLevel::from_code(level));
        self.platform.log(format!(
            "core: memory warning level {level}, {reached} caches trimmed"
        ));
        u32::try_from(reached).unwrap_or(u32::MAX)
    }

    /// Whether the host's secret store has a secret under `name` (the value never crosses).
    pub fn has_secret(&self, name: String) -> bool {
        self.secrets.get(name).is_some()
    }

    pub fn hello_vm(&self) -> Arc<HelloVm> {
        HelloVm::new(Arc::clone(&self.platform))
    }

    /// Starts a player session over a Swift-implemented engine.
    pub fn player_probe(&self, engine: Arc<dyn EngineProbe>) -> Arc<PlayerProbe> {
        PlayerProbe::new(engine, Arc::clone(&self.platform))
    }

    /// The home page of an account (signed in; use `AccountSwitched` for the next one). HTTP is
    /// the host's (URLSession on Apple); the page snapshot goes to the host's
    /// key-value store. Nothing loads before `HomeIntent::Load`.
    pub fn home_vm(&self, account: AccountRef, locale: String) -> Result<Arc<HomeVm>, CoreError> {
        self.home_vm_with(account, locale, HomePrefs::default())
    }

    /// As `home_vm` with the home page settings (separate new rows, genre rows).
    pub fn home_vm_with(
        &self,
        account: AccountRef,
        locale: String,
        prefs: HomePrefs,
    ) -> Result<Arc<HomeVm>, CoreError> {
        let host = self.host(&locale)?;
        let vm =
            swiftly_vm::HomeVm::new(Arc::new(self.transport.clone()), host, prefs, Some(account))?;
        Ok(HomeVm::wrap(vm))
    }

    /// The grid of a library, collection or genre. Nothing loads before `LibraryIntent::Load`.
    pub fn library_vm(
        &self,
        account: AccountRef,
        locale: String,
        spec: crate::library::LibrarySpec,
    ) -> Result<Arc<LibraryVm>, CoreError> {
        let kv = Arc::new(TextKeys(Arc::clone(&self.blobs.0)));
        let vm = swiftly_vm::LibraryVm::new(
            Arc::new(self.transport.clone()),
            self.host(&locale)?,
            kv,
            spec.into(),
            Some(account),
        )?;
        Ok(LibraryVm::wrap(vm))
    }

    /// Search with recent terms per account.
    pub fn search_vm(
        &self,
        account: AccountRef,
        locale: String,
    ) -> Result<Arc<SearchVm>, CoreError> {
        let kv = Arc::new(TextKeys(Arc::clone(&self.blobs.0)));
        let vm = swiftly_vm::SearchVm::new(
            Arc::new(self.transport.clone()),
            self.host(&locale)?,
            Arc::new(TokioSleeper),
            kv,
            Some(account),
        )?;
        Ok(SearchVm::wrap(vm))
    }

    /// A movie or episode page, started from the tile that was tapped.
    pub fn detail_vm(
        &self,
        account: AccountRef,
        locale: String,
        tile: Tile,
    ) -> Result<Arc<DetailVm>, CoreError> {
        let vm = swiftly_vm::DetailVm::new(
            Arc::new(self.transport.clone()),
            self.host(&locale)?,
            item_of(&tile),
            Some(account),
        )?;
        Ok(DetailVm::wrap(vm))
    }

    /// The report queue of the player screens for one account (`account_key`: how the app files
    /// stops that did not get through, `ServerSession.storageAccount`). Keep it as long as the
    /// account is signed in.
    pub fn play_reporter(
        &self,
        account: AccountRef,
        locale: String,
        account_key: String,
    ) -> Result<Arc<crate::player::PlayReporter>, CoreError> {
        crate::player::PlayReporter::build(
            self.transport.foreign(),
            &self.host(&locale)?,
            &self.store,
            &account,
            &account_key,
        )
    }

    /// The player of one title over a host engine (AetherDriver, AVPlayer, VLC). Reports go to
    /// the server through the host's HTTP; nothing loads before `PlayerVm::start`.
    pub fn player_vm(
        &self,
        account: AccountRef,
        locale: String,
        start: crate::player::PlayerStart,
        prefs: swiftly_vm::PlayerPrefs,
        engine: Arc<dyn crate::player::PlayerEngine>,
    ) -> Result<Arc<crate::player::PlayerVm>, CoreError> {
        let key = account.user_id.clone();
        self.player_vm_keyed(account, key, locale, start, prefs, engine)
    }

    /// `player_vm` with the key the app files this account's unsent stops under
    /// (`ServerSession.storageAccount`; `player_vm` takes the user id, which is only the same for
    /// Jellyfin and Emby). The screens use this one.
    pub fn player_vm_keyed(
        &self,
        account: AccountRef,
        account_key: String,
        locale: String,
        start: crate::player::PlayerStart,
        prefs: swiftly_vm::PlayerPrefs,
        engine: Arc<dyn crate::player::PlayerEngine>,
    ) -> Result<Arc<crate::player::PlayerVm>, CoreError> {
        crate::player::PlayerVm::build(
            self.transport.foreign(),
            &self.host(&locale)?,
            &self.store,
            &self.platform,
            &account,
            &account_key,
            start,
            prefs,
            engine,
            None,
        )
    }

    /// `player_vm_keyed` whose reports go through the queue of the app's own `PlayReporter`: one stop lock and
    /// one order for the core's start/progress reports and the app's stop, so a stop is never sent twice and a
    /// late progress after it is dropped.
    #[allow(clippy::too_many_arguments)]
    pub fn player_vm_shared(
        &self,
        account: AccountRef,
        account_key: String,
        locale: String,
        start: crate::player::PlayerStart,
        prefs: swiftly_vm::PlayerPrefs,
        engine: Arc<dyn crate::player::PlayerEngine>,
        reporter: Arc<crate::player::PlayReporter>,
    ) -> Result<Arc<crate::player::PlayerVm>, CoreError> {
        crate::player::PlayerVm::build(
            self.transport.foreign(),
            &self.host(&locale)?,
            &self.store,
            &self.platform,
            &account,
            &account_key,
            start,
            prefs,
            engine,
            Some(reporter.shared_desk()),
        )
    }

    /// The play plan of a title for the player screens: the start (profile of the engine,
    /// version, resume, starting tracks, sections, chapters, trickplay), the versions to choose
    /// from, or the reason there is nothing to play.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn play_plan(
        &self,
        account: AccountRef,
        locale: String,
        request: crate::play_start::PlayPlanRequest,
    ) -> Result<crate::play_start::PlayPlanAnswer, CoreError> {
        crate::play_start::play_plan(
            self.transport.foreign(),
            &self.host(&locale)?,
            &self.store,
            &account,
            request,
        )
        .await
    }

    /// The whole home page as one JSON document with German keys, in the shape the Android
    /// Compose code has always parsed (`Kern.home`): all rails with all their tiles. Same loader
    /// and text rules as `HomeVm`; the Android adapter returns this string unchanged.
    #[uniffi::method(async_runtime = "tokio")]
    #[allow(clippy::too_many_arguments)]
    pub async fn legacy_home(
        &self,
        account: AccountRef,
        locale: String,
        disconnected: bool,
        stored: Vec<String>,
        hidden: Vec<String>,
        film_library: String,
        series_library: String,
        genres: Vec<String>,
        as_chips: bool,
        libraries: String,
    ) -> Result<String, CoreError> {
        let args = swiftly_vm::LegacyHomeArgs {
            disconnected,
            stored,
            from: hidden,
            film_library,
            series_library,
            genres,
            as_chips,
            libraries: libraries.into_bytes(),
        };
        let transport = Arc::new(self.transport.clone());
        Ok(swiftly_vm::legacy_home_json(&transport, &self.host(&locale)?, &account, &args).await?)
    }

    /// One page of a library as the old `Kern.libraryPage` answered it (`titel`, `gesamt`).
    #[uniffi::method(async_runtime = "tokio")]
    #[allow(clippy::too_many_arguments)]
    pub async fn legacy_library_page(
        &self,
        account: AccountRef,
        locale: String,
        library: String,
        art: String,
        sorting: String,
        filter: String,
        since: i64,
        count: i64,
    ) -> Result<String, CoreError> {
        let args = swiftly_vm::LegacyPageArgs {
            library,
            art,
            sorting,
            filter,
            genre: String::new(),
            since,
            count,
        };
        self.run_legacy_library(account, &locale, swiftly_vm::LegacyLibraryCall::Page, &args)
            .await
    }

    /// The watchlist page as the old `Kern.watchlist` answered it.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn legacy_watchlist(
        &self,
        account: AccountRef,
        locale: String,
        genre: String,
        sorting: String,
        since: i64,
        count: i64,
    ) -> Result<String, CoreError> {
        let args = swiftly_vm::LegacyPageArgs {
            sorting,
            genre,
            since,
            count,
            ..Default::default()
        };
        self.run_legacy_library(
            account,
            &locale,
            swiftly_vm::LegacyLibraryCall::Watchlist,
            &args,
        )
        .await
    }

    /// The titles of a genre as the old `Kern.genre` answered it.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn legacy_genre(
        &self,
        account: AccountRef,
        locale: String,
        name: String,
    ) -> Result<String, CoreError> {
        self.run_legacy_library(
            account,
            &locale,
            swiftly_vm::LegacyLibraryCall::Genre(name),
            &swiftly_vm::LegacyPageArgs::default(),
        )
        .await
    }

    /// `Kern.can`: whether the account's kind has the capability (`ServerCapability` raw value, e.g. `syncPlay`).
    pub fn legacy_can(&self, kind: swiftly_jellyfin::ServerKind, capability: String) -> bool {
        swiftly_vm::capabilities_for(kind).iter().any(|c| {
            let name = format!("{c:?}");
            let mut chars = name.chars();
            chars
                .next()
                .is_some_and(|f| format!("{}{}", f.to_lowercase(), chars.as_str()) == capability)
        })
    }

    /// `Kern.serverName`: the server's public name.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn legacy_server_name(&self, account: AccountRef) -> Result<String, CoreError> {
        let client = swiftly_vm::make_client(
            &Arc::new(self.transport.clone()),
            &self.host("en")?,
            &account,
        )?;
        Ok(client
            .public_system_info()
            .await?
            .server_name
            .unwrap_or_default())
    }

    /// `Kern.accountDefaults`: `nextAutomatic|downloadRight|convertAllowed|qualitySelectable` (`1`, `0` or empty; `|||1` without
    /// an answer).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn legacy_account_defaults(&self, account: AccountRef) -> Result<String, CoreError> {
        let text = |v: Option<bool>| v.map_or("", |b| if b { "1" } else { "0" });
        let Ok(client) = swiftly_vm::make_client(
            &Arc::new(self.transport.clone()),
            &self.host("en")?,
            &account,
        ) else {
            return Ok("|||1".into());
        };
        let Some(g) = client.account_defaults().await else {
            return Ok("|||1".into());
        };
        Ok(format!(
            "{}|{}|{}|{}",
            text(g.next_episode_automatic),
            text(g.downloads_allowed),
            text(g.convert_allowed),
            if g.download_quality_selectable() {
                "1"
            } else {
                "0"
            }
        ))
    }

    /// The genre names as the old `Kern.genres` answered it.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn legacy_genres(
        &self,
        account: AccountRef,
        locale: String,
    ) -> Result<String, CoreError> {
        self.run_legacy_library(
            account,
            &locale,
            swiftly_vm::LegacyLibraryCall::Genres,
            &swiftly_vm::LegacyPageArgs::default(),
        )
        .await
    }

    /// The flat result list of the old `Kern.search` (movies and series, each work once, the hit line under the poster).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn legacy_search(
        &self,
        account: AccountRef,
        locale: String,
        term: String,
    ) -> Result<String, CoreError> {
        let transport = Arc::new(self.transport.clone());
        Ok(
            swiftly_vm::legacy_search_json(&transport, &self.host(&locale)?, &account, &term)
                .await?,
        )
    }

    /// Title, series and person pages of an account as the old `Kern` answered them. Make a new one after an
    /// account switch.
    pub fn legacy_detail(
        &self,
        account: AccountRef,
        locale: String,
    ) -> Result<Arc<crate::legacy_detail::LegacyDetail>, CoreError> {
        let transport = Arc::new(self.transport.clone());
        let inner = swiftly_vm::LegacyDetail::new(&transport, &self.host(&locale)?, &account)?;
        Ok(crate::legacy_detail::LegacyDetail::new(inner))
    }

    /// Title, series and person pages of a Plex account (same answers as [`Self::legacy_detail`]).
    pub fn legacy_plex_detail(
        &self,
        account: AccountRef,
        locale: String,
    ) -> Result<Arc<crate::legacy_plex_detail::LegacyPlexDetail>, CoreError> {
        let transport = Arc::new(self.transport.clone());
        let inner = swiftly_vm::LegacyPlexDetail::new(&transport, &self.host(&locale)?, &account)?;
        Ok(crate::legacy_plex_detail::LegacyPlexDetail::new(inner))
    }

    /// The open title of an account as the old `Kern` kept it (plan, tracks, chapters, trickplay). Make a new one after
    /// an account switch.
    pub fn legacy_playback(
        &self,
        account: AccountRef,
        locale: String,
    ) -> Result<Arc<crate::legacy_playback::LegacyPlayback>, CoreError> {
        let transport = Arc::new(self.transport.clone());
        let host = self.host(&locale)?;
        // Stops that did not get through go back to the app in the answer (it stores them), not into the core's store.
        let desk = crate::player::report_desk_with(
            self.transport.foreign(),
            &host,
            &account,
            &account.user_id,
            0.0,
            Arc::new(crate::legacy_playback::NoPending),
        )?;
        let inner = swiftly_vm::LegacyPlayback::new(&transport, &host, &account, Arc::new(desk))?;
        Ok(crate::legacy_playback::LegacyPlayback::new(inner))
    }

    /// The library section state of an account (`sectionOffering`, `sectionPage`, collections, playlists), as the old
    /// `Kern` kept it. Make a new one after an account switch.
    pub fn legacy_library(
        &self,
        account: AccountRef,
        locale: String,
    ) -> Result<Arc<crate::legacy_library::LegacyLibrary>, CoreError> {
        let transport = Arc::new(self.transport.clone());
        let inner = swiftly_vm::LegacySection::new(&transport, &self.host(&locale)?, &account)?;
        Ok(crate::legacy_library::LegacyLibrary::new(inner))
    }

    /// The plan of a title alone: one `PlaybackInfo` request with the Aether profile for `max_bitrate`
    /// (`hardware_av1`: the device decodes AV1 in hardware)
    /// (`JellyfinClient.playbackPlan`), without resume, tracks, next episode or extras. `subtitle`: the track a running
    /// transcode must now show or drop (the `reloadForSubtitle` effect): the plan comes with it burned in or out.
    #[allow(clippy::too_many_arguments)] // the foreign-language call carries every input separately
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn play_plan_only(
        &self,
        account: AccountRef,
        locale: String,
        item_id: String,
        source_id: Option<String>,
        hardware_av1: bool,
        max_bitrate: i64,
        subtitle: Option<i64>,
    ) -> Result<crate::play_start::PlanOnly, CoreError> {
        crate::play_start::play_plan_only(
            self.transport.foreign(),
            &self.host(&locale)?,
            &account,
            &item_id,
            source_id.as_deref(),
            hardware_av1,
            max_bitrate,
            subtitle,
        )
        .await
    }

    /// The skip sections (intro, recap, outro ...) of a title; empty when the server knows none.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn play_sections(
        &self,
        account: AccountRef,
        locale: String,
        item_id: String,
    ) -> Result<Vec<crate::player::PlayerSection>, CoreError> {
        crate::play_start::play_sections(
            self.transport.foreign(),
            &self.host(&locale)?,
            &account,
            &item_id,
        )
        .await
    }

    /// The preview sheets (trickplay) of a version; `None` when the server has none.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn play_trickplay(
        &self,
        account: AccountRef,
        locale: String,
        item_id: String,
        source: Option<String>,
    ) -> Result<Option<crate::player::PlayerTrickplay>, CoreError> {
        crate::play_start::play_trickplay(
            self.transport.foreign(),
            &self.host(&locale)?,
            &account,
            &item_id,
            source.as_deref(),
        )
        .await
    }

    /// The chapters of a title, cleaned for the bar.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn play_chapters(
        &self,
        account: AccountRef,
        locale: String,
        item_id: String,
        source: Option<String>,
    ) -> Result<Vec<crate::player::PlayerChapter>, CoreError> {
        crate::play_start::play_chapters(
            self.transport.foreign(),
            &self.host(&locale)?,
            &account,
            &item_id,
            source.as_deref(),
        )
        .await
    }

    /// The settings screens; values live in the host's key-value store.
    pub fn settings_vm(
        &self,
        locale: String,
        facts: crate::settings::SettingsFacts,
    ) -> Arc<crate::settings::SettingsVm> {
        crate::settings::SettingsVm::new(Arc::clone(&self.store), &locale, facts)
    }

    /// The settings screens over the host's typed store (`UserDefaults`): the core and the
    /// `@AppStorage` screens read and write the same keys.
    pub fn settings_vm_native(
        &self,
        store: Arc<dyn crate::settings::SettingsStore>,
        locale: String,
        facts: crate::settings::SettingsFacts,
    ) -> Arc<crate::settings::SettingsVm> {
        crate::settings::SettingsVm::native(store, &locale, facts)
    }

    /// The address a title is downloaded from (`quality`: `original`, `hd1080`, `hd720`, `sd480`;
    /// `audio_index` cuts the file to one audio track). Same rules as the desktop shell: the plain
    /// stream address for the original, a converting stream otherwise, and an explicit "downloads
    /// not allowed" gives the 403 the server would. Pure: no request is made. A host answers
    /// `DownloadHost::request_address` with it.
    pub fn download_address(
        &self,
        account: AccountRef,
        locale: String,
        id: String,
        source: Option<String>,
        quality: String,
        audio_index: Option<i64>,
    ) -> Result<String, CoreError> {
        use swiftly_jellyfin::{ClientConfig, DownloadConversion, JellyfinClient, Session};
        use swiftly_rules::download_quality::DownloadQuality;
        let host = self.host(&locale)?;
        let config = ClientConfig::new(&account.device_id, &host.device_name, &host.client_version)
            .kind(account.server_kind);
        let client = JellyfinClient::new(
            swiftly_vm::Shared(Arc::new(self.transport.foreign().clone())),
            &account.base_url,
            config,
        )?;
        client.set_session(Some(Session {
            access_token: account.token.clone(),
            user_id: account.user_id.clone(),
            user_name: String::new(),
            server_url: account.base_url.clone(),
            kind: account.server_kind,
        }));
        let level = DownloadQuality::from_raw_value(&quality).unwrap_or(DownloadQuality::Original);
        let conversion = (|| {
            Some(DownloadConversion {
                video_bitrate: level.image_bitrate()?,
                audio_bitrate: level.audio_bitrate()?,
                height: level.height()?,
                width: level.width()?,
                channels: level.audio_channels()?,
            })
        })();
        let url = client.download_url(&id, source.as_deref(), conversion, audio_index)?;
        Ok(url.to_string())
    }

    /// The downloads list over the host's transfer layer. Send `SignIn` to load the list.
    pub fn downloads_vm(
        &self,
        host: Arc<dyn crate::downloads::DownloadHost>,
        locale: String,
        only_over_wlan: bool,
        next_auto: bool,
    ) -> Arc<crate::downloads::DownloadsVm> {
        crate::downloads::DownloadsVm::new(
            host,
            Arc::clone(&self.store),
            Arc::clone(&self.platform),
            &locale,
            only_over_wlan,
            next_auto,
        )
    }

    /// A series page, started from the tile that was tapped.
    pub fn series_vm(
        &self,
        account: AccountRef,
        locale: String,
        tile: Tile,
        spec: SeriesSpec,
    ) -> Result<Arc<SeriesVm>, CoreError> {
        let vm = swiftly_vm::SeriesVm::new(
            Arc::new(self.transport.clone()),
            self.host(&locale)?,
            item_of(&tile),
            spec,
            Some(account),
        )?;
        Ok(SeriesVm::wrap(vm))
    }

    /// A message from the account's WebSocket (`RemoteEvent::Unreadable` carries texts the channel
    /// does not use; the host may also pass every raw message): `LibraryChanged` and
    /// `UserDataChanged` mark the cached lists and titles stale and the open screens refresh.
    /// Anything else is ignored.
    pub fn cache_event(&self, account: AccountRef, message: String) {
        if let (Some(cache), Some(event)) = (&self.cache, swiftly_cache::parse_ws(&message)) {
            cache
                .entity_cache()
                .apply_event(&swiftly_vm::ViewCache::scope(&account), &event);
        }
    }

    /// The polling fallback: the host calls this on a timer while its WebSocket is down (or when
    /// the app returns to the front); every cached list of the account is marked stale and the
    /// open screens refresh.
    pub fn cache_lists_changed(&self, account: AccountRef) {
        if let Some(cache) = &self.cache {
            cache
                .entity_cache()
                .lists_changed(&swiftly_vm::ViewCache::scope(&account));
        }
    }

    /// Deletes everything cached for the account (sign-out, removed account) and voids the
    /// answers that were still on their way.
    pub fn cache_forget(&self, account: AccountRef) {
        if let Some(cache) = &self.cache {
            cache
                .entity_cache()
                .drop_scope(&swiftly_vm::ViewCache::scope(&account));
        }
    }

    /// Bytes the cache database holds (settings screen, tests).
    pub fn cache_disk_bytes(&self) -> u64 {
        self.cache
            .as_ref()
            .map_or(0, |c| c.entity_cache().disk_bytes())
    }

    /// Everything the core keeps in `Platform.cache_dir()` for the settings line "Cache": the
    /// cache database plus the picture plate (`images/`). Plain (blocking) file sizes, 0 when
    /// there is no cache directory.
    pub fn cache_size_bytes(&self) -> u64 {
        let plate = self.platform.cache_dir().map_or(0, |dir| {
            dir_size(&std::path::Path::new(&dir).join("images"))
        });
        self.cache_disk_bytes() + plate
    }

    /// The picture loader: memory cache, disk plate in `cache_dir` (the host's `Platform.cache_dir()`,
    /// `None` keeps everything in memory), fetch through the host's HTTP. One per app; a memory warning
    /// reaches it through `memory_warning`.
    pub fn image_loader(
        &self,
        cache_dir: Option<String>,
        device: crate::images::ImageDevice,
    ) -> Arc<crate::images::ImageLoader> {
        let loader =
            crate::images::ImageLoader::build(self.transport.foreign().clone(), cache_dir, device);
        self.pressure.register(&loader.trim_sink());
        loader
    }

    /// The look state (selection, gifts, try-on, effects switch) over the host's key-value store.
    pub fn look_model(&self) -> Arc<crate::looks::LookModel> {
        crate::looks::LookModel::build(Arc::clone(&self.store))
    }

    /// The takeover card of a signed-in user on this device.
    pub fn takeover_model(
        &self,
        account: AccountRef,
        locale: String,
    ) -> Arc<crate::takeover::TakeoverModel> {
        crate::takeover::TakeoverModel::build(&locale, &account.device_id, &account.user_id)
    }

    /// The server calls of "continue here" and "play on" (Jellyfin accounts).
    pub fn takeover_calls(
        &self,
        account: AccountRef,
    ) -> Result<Arc<crate::takeover_calls::TakeoverCalls>, CoreError> {
        Ok(crate::takeover_calls::TakeoverCalls::build(
            self.transport.clone(),
            self.host("en")?,
            account,
        ))
    }

    /// The polling and hand-over flow of a signed-in user on this device.
    pub fn handoff_flow(&self, account: AccountRef) -> Arc<crate::takeover::HandoffFlowModel> {
        crate::takeover::HandoffFlowModel::build(&account.device_id, &account.user_id)
    }

    /// The support state (status, watch time, prompt history) over the host's key-value store.
    pub fn support_model(&self) -> Arc<crate::looks::SupportModel> {
        crate::looks::SupportModel::build(Arc::clone(&self.store))
    }
}

impl Core {
    async fn run_legacy_library(
        &self,
        account: AccountRef,
        locale: &str,
        call: swiftly_vm::LegacyLibraryCall,
        args: &swiftly_vm::LegacyPageArgs,
    ) -> Result<String, CoreError> {
        let transport = Arc::new(self.transport.clone());
        Ok(
            swiftly_vm::legacy_library_json(&transport, &self.host(locale)?, &account, call, args)
                .await?,
        )
    }

    fn host(&self, locale: &str) -> Result<Host, CoreError> {
        let spawner = match (&self.runtime, &self.fallback) {
            (Some(owned), _) => CoreSpawner {
                handle: owned.handle().clone(),
                _owner: Some(Arc::clone(owned)),
            },
            (None, Some(handle)) => CoreSpawner {
                handle: handle.clone(),
                _owner: None,
            },
            (None, None) => {
                return Err(CoreError::Failed {
                    message: "the async runtime is not available".to_owned(),
                });
            }
        };
        Ok(Host {
            spawner: Arc::new(spawner),
            clock: Arc::new(SystemClock),
            store: Arc::clone(&self.blobs) as _,
            locale: Locale::parse(locale),
            device_name: self.platform.device_name(),
            client_version: CLIENT_VERSION
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone()
                .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_owned()),
            cache: self.cache.clone(),
        })
    }
}

/// Bytes of all files below `dir` (0 when it does not exist); links are not followed.
fn dir_size(dir: &std::path::Path) -> u64 {
    let Ok(read) = std::fs::read_dir(dir) else {
        return 0;
    };
    read.flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => dir_size(&e.path()),
            Ok(t) if t.is_file() => e.metadata().map_or(0, |m| m.len()),
            _ => 0,
        })
        .sum()
}

/// Opens `core-cache.sqlite` in the platform's cache directory. A file that cannot be opened is
/// replaced by the cache itself; if even that fails (read-only disk) the cache lives in memory.
fn open_cache(platform: &dyn Platform) -> Option<swiftly_vm::ViewCache> {
    use swiftly_cache::{CacheConfig, EntityCache};
    let on_disk = platform.cache_dir().and_then(|dir| {
        let dir = std::path::PathBuf::from(dir);
        std::fs::create_dir_all(&dir).ok()?;
        match EntityCache::open(&dir.join("core-cache.sqlite"), CacheConfig::default()) {
            Ok(c) => Some(c),
            Err(e) => {
                platform.log(format!(
                    "core: cache file unusable ({e:?}), keeping it in memory"
                ));
                None
            }
        }
    });
    on_disk
        .or_else(|| EntityCache::in_memory(CacheConfig::default()).ok())
        .map(swiftly_vm::ViewCache::new)
}

#[cfg(test)]
mod size_tests {
    #[test]
    fn dir_size_sums_nested_files() {
        let d = std::env::temp_dir().join(format!("swiftly-size-{}", std::process::id()));
        std::fs::create_dir_all(d.join("a/b")).unwrap();
        std::fs::write(d.join("x"), [0u8; 10]).unwrap();
        std::fs::write(d.join("a/b/y"), [0u8; 5]).unwrap();
        assert_eq!(super::dir_size(&d), 15);
        assert_eq!(super::dir_size(&d.join("none")), 0);
        std::fs::remove_dir_all(&d).unwrap();
    }
}
