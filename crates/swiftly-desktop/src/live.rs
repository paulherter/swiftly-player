//! The real app behind the screens: accounts in the secret store, settings in the config directory, the real
//! transport, the sign-in flow, and the pieces every view model needs (`Host`, `AccountRef`, key-value stores).

use crate::login_screen::{Pending, SignInBackend};
use crate::net::AppTransport;
use crate::signin_flows::{self, EmbyFound, PlexEvent, SharedPlex};
use crate::store::{DirStore, FileKeyValue, PlatformSecrets, cache_dir, config_dir};
use futures_executor::ThreadPool;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use swiftly_accounts::{
    Account, AccountBundle, SecretStore, ServerBundles, load_bundles, save_bundles,
};
use swiftly_jellyfin::discovery::FoundServer;
use swiftly_jellyfin::{
    ClientConfig, JellyfinClient, LoginCode, OwnHeader, OwnHeaders, QuickConnectState, ServerKind,
};
use swiftly_l10n::Locale;
use swiftly_library::KeyValue;
use swiftly_net::{ErrorKind, ReqwestTransport, TlsOptions, TransportConfig};
use swiftly_seerr::Seerr;
use swiftly_settings::{JsonFileStore, KeyValueStore, Value};
use swiftly_vm::{AccountRef, Host, Shared, Sleeper, Spawner, SystemClock};

/// Runs view model effects on a small pool; the transport hops to tokio by itself.
struct Pool(ThreadPool);

impl Spawner for Pool {
    fn spawn(&self, task: Pin<Box<dyn Future<Output = ()> + Send>>) {
        use futures_util::FutureExt;
        // A panicking task must not take its worker thread down (the panic hook has already written `crash.log`).
        self.0
            .spawn_ok(std::panic::AssertUnwindSafe(task).catch_unwind().map(drop));
    }
}

/// Sleeps on the tokio runtime.
pub struct TokioSleeper(pub tokio::runtime::Handle);

impl Sleeper for TokioSleeper {
    fn sleep(&self, seconds: f64) -> Pin<Box<dyn Future<Output = ()> + Send>> {
        let h = self.0.clone();
        Box::pin(async move {
            // The timer is made inside the runtime: this future is polled on the view model pool, where tokio's
            // `sleep(..)` has no reactor and panics ("there is no reactor running"), which left the search on
            // its skeleton tiles for good.
            let d = std::time::Duration::from_secs_f64(seconds.max(0.0));
            let _ = h.spawn(async move { tokio::time::sleep(d).await }).await;
        })
    }
}

/// The Jellyfin client over the shared transport.
pub type Client = JellyfinClient<Shared<AppTransport>>;

/// Everything the real app owns for its whole run.
pub struct Core {
    /// Taken out in `Drop`, see there.
    rt: Option<tokio::runtime::Runtime>,
    /// The shared transport.
    pub net: Arc<AppTransport>,
    /// Where the accounts live.
    pub secrets: Arc<dyn SecretStore>,
    /// `settings.json` in the config directory.
    pub settings: Arc<JsonFileStore>,
    /// Sorting, filters, search history.
    pub kv: Arc<dyn KeyValue>,
    device_id: String,
    host: Host,
}

/// The TLS cases read from the settings file (`tls.ca` path to a PEM/DER file, `tls.acceptSelfSigned`, `net.proxy`)
/// or from `SWIFTLY_CA_FILE`, `SWIFTLY_ACCEPT_SELF_SIGNED=1`, `SWIFTLY_PROXY`.
pub(crate) fn tls_options(settings: &JsonFileStore) -> TlsOptions {
    let text = |key: &str, env: &str| {
        std::env::var(env).ok().or_else(|| match settings.get(key) {
            Some(Value::Str(s)) if !s.is_empty() => Some(s),
            _ => None,
        })
    };
    let flag = |key: &str, env: &str| {
        std::env::var(env)
            .map(|v| v == "1")
            .unwrap_or_else(|_| matches!(settings.get(key), Some(Value::Bool(true))))
    };
    let extra_roots = text("tls.ca", "SWIFTLY_CA_FILE")
        .and_then(|p| std::fs::read(p).ok())
        .into_iter()
        .collect();
    TlsOptions {
        extra_roots,
        accept_invalid_certs: flag("tls.acceptSelfSigned", "SWIFTLY_ACCEPT_SELF_SIGNED"),
        proxy: text("net.proxy", "SWIFTLY_PROXY"),
        ..TlsOptions::default()
    }
}

fn new_device_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut out = String::new();
    for _ in 0..2 {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u128(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_nanos()),
        );
        out.push_str(&format!("{:016x}", h.finish()));
    }
    out
}

impl Drop for Core {
    /// The core can be dropped late, from the main thread's thread-local destructors while the process exits. On
    /// Windows `ExitProcess` has already killed the runtime's workers by then, and dropping a `Runtime` waits for them
    /// forever (the app hung, unkillable, after the window's close button). `shutdown_background` never waits.
    fn drop(&mut self) {
        if let Some(rt) = self.rt.take() {
            rt.shutdown_background();
        }
    }
}

impl Core {
    fn rt(&self) -> &tokio::runtime::Runtime {
        match self.rt.as_ref() {
            Some(rt) => rt,
            // Only `drop` takes the runtime out, and nothing runs after it.
            None => unreachable!("the runtime lives as long as the core"),
        }
    }

    /// Opens the stores, starts the runtime and the transport.
    ///
    /// # Errors
    /// Text when the runtime, the settings file or the TLS stack cannot start.
    pub fn open() -> Result<Core, String> {
        Core::open_with(None)
    }

    /// Like [`Core::open`], but with `mock` as the transport (tests: a scripted Jellyfin, Emby or Plex server).
    ///
    /// # Errors
    /// Text when the runtime or the settings file cannot start.
    pub fn open_with(mock: Option<swiftly_net::MockTransport>) -> Result<Core, String> {
        let dir = config_dir();
        let _ = std::fs::create_dir_all(&dir);
        let settings = Arc::new(
            JsonFileStore::open(dir.join("settings.json")).map_err(|e| format!("settings: {e}"))?,
        );
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("swiftly-net")
            .build()
            .map_err(|e| format!("runtime: {e}"))?;
        let mock_is_none = mock.is_none();
        let net = Arc::new(match (mock, crate::net::host_http()) {
            (Some(m), _) => AppTransport::Mock(m),
            (None, Some(h)) => AppTransport::Host(h, rt.handle().clone()),
            (None, None) => {
                let real =
                    ReqwestTransport::with_tls(TransportConfig::default(), &tls_options(&settings))
                        .map_err(|e| format!("network: {e:?}"))?;
                AppTransport::Real(real, rt.handle().clone())
            }
        });
        if let Some(Value::Str(table)) = settings.get("net.ownHeaders") {
            OwnHeaders::load(Some(&table));
        }
        let device_id = match settings.get("device.id") {
            Some(Value::Str(s)) if !s.is_empty() => s,
            _ => {
                let id = new_device_id();
                crate::store::set_logged(&*settings, "device.id", Value::Str(id.clone()));
                id
            }
        };
        // First start after the old Windows/Linux app: take over its sign-ins once (read only on its files).
        let secrets: Arc<PlatformSecrets> = Arc::new(PlatformSecrets::new());
        if mock_is_none {
            crate::legacy_import::run_at_start(secrets.as_ref(), &settings);
        }
        let pool = ThreadPool::builder()
            .pool_size(2)
            .create()
            .map_err(|e| format!("pool: {e}"))?;
        let host = Host {
            spawner: Arc::new(Pool(pool)),
            clock: Arc::new(SystemClock),
            store: Arc::new(DirStore(cache_dir().join("home"))),
            locale: Locale::parse("de"),
            device_name: device_name(),
            client_version: env!("CARGO_PKG_VERSION").into(),
            cache: None,
        };
        Ok(Core {
            rt: Some(rt),
            net,
            secrets,
            settings,
            kv: Arc::new(FileKeyValue::open(dir.join("library.json"))),
            device_id,
            host,
        })
    }

    /// A client for `account` with its session set.
    pub fn client_for(&self, account: &AccountRef) -> Result<Client, ErrorKind> {
        let cfg = ClientConfig::new(
            &account.device_id,
            &self.host.device_name,
            &self.host.client_version,
        )
        .kind(account.server_kind);
        let client = JellyfinClient::new(Shared(Arc::clone(&self.net)), &account.base_url, cfg)?;
        client.set_session(Some(swiftly_jellyfin::Session {
            access_token: account.token.clone(),
            user_id: account.user_id.clone(),
            user_name: String::new(),
            server_url: account.base_url.clone(),
            kind: account.server_kind,
        }));
        Ok(client)
    }

    /// A handle of the network runtime (downloads run on it).
    pub fn handle(&self) -> tokio::runtime::Handle {
        self.rt().handle().clone()
    }

    /// A handle to the network runtime, for worker threads that block on a request.
    pub fn runtime_handle(&self) -> tokio::runtime::Handle {
        self.rt().handle().clone()
    }

    /// Runs a future on the network runtime.
    pub fn spawn(&self, fut: impl Future<Output = ()> + Send + 'static) {
        self.rt().spawn(fut);
    }

    /// The host of every view model.
    pub fn host(&self) -> Host {
        self.host.clone()
    }

    /// The sleeper of the search debounce.
    pub fn sleeper(&self) -> Arc<dyn Sleeper> {
        Arc::new(TokioSleeper(self.rt().handle().clone()))
    }

    /// The scripted transport of the tests is in use: nothing here talks to a real server.
    pub fn is_scripted(&self) -> bool {
        matches!(*self.net, AppTransport::Mock(_))
    }

    /// The display name of the signed-in user, as the server names it (excluded from "mit A und B").
    pub fn account_name(&self) -> Option<String> {
        let bundles = load_bundles(&*self.secrets);
        let name = bundles.active()?.active().session.user_name.clone();
        (!name.is_empty()).then_some(name)
    }

    /// The active stored account, if there is one.
    pub fn account(&self) -> Option<AccountRef> {
        let bundles = load_bundles(&*self.secrets);
        let s = &bundles.active()?.active().session;
        Some(AccountRef {
            base_url: s.server_url.clone(),
            user_id: s.user_id.clone(),
            token: s.access_token.clone(),
            server_kind: s.kind,
            device_id: self.device_id.clone(),
            plex_machine_id: None,
            plex_account_token: None,
        })
    }

    /// Forgets all accounts (sign out).
    pub fn sign_out(&self) {
        save_bundles(
            &*self.secrets,
            &ServerBundles::new(Vec::new(), ServerKind::Jellyfin),
        );
    }

    /// The backend of the sign-in screen.
    pub fn sign_in_backend(self: &Arc<Self>) -> Rc<dyn SignInBackend> {
        Rc::new(Backend {
            core: Arc::clone(self),
            state: Arc::new(Mutex::new(Flow::default())),
        })
    }

    pub(crate) fn client(
        &self,
        base: &str,
        kind: ServerKind,
    ) -> Result<JellyfinClient<Shared<AppTransport>>, ErrorKind> {
        let cfg = ClientConfig::new(
            &self.device_id,
            &self.host.device_name,
            &self.host.client_version,
        )
        .kind(kind);
        JellyfinClient::new(Shared(Arc::clone(&self.net)), base, cfg)
    }

    fn store_session(&self, session: swiftly_jellyfin::Session) {
        self.store_account(Account::new(session));
    }

    /// Records `account` in the bundle of its kind and makes it the active one.
    fn store_account(&self, account: Account) {
        let kind = account.session.kind;
        let existing = load_bundles(&*self.secrets).bundle(kind).cloned();
        let (bundle, _) = AccountBundle::record_in(account, existing);
        let mut all = load_bundles(&*self.secrets);
        all.set(Some(bundle), kind);
        all.switch_to(kind);
        save_bundles(&*self.secrets, &all);
    }
}

use std::rc::Rc;

fn device_name() -> String {
    std::env::var("SWIFTLY_DEVICE_NAME")
        .or_else(|_| std::env::var("HOSTNAME").or_else(|_| std::env::var("COMPUTERNAME")))
        .unwrap_or_else(|_| "Desktop".into())
}

#[derive(Default)]
struct Flow {
    base: Option<String>,
    code: Option<LoginCode>,
    kind: ServerKind,
    headers: Vec<OwnHeader>,
    /// The picture addresses of the Emby users the last list held (`emby_user_pictures`).
    user_pictures: Vec<Option<String>>,
    plex: SharedPlex,
}

struct Backend {
    core: Arc<Core>,
    state: Arc<Mutex<Flow>>,
}

/// The line for a failed step: the core's `readableError`, the same sentences as the Mac.
pub(crate) fn say(e: &ErrorKind) -> String {
    swiftly_l10n::error_text::readable_error(&swiftly_l10n::Translator::new(Locale::parse("de")), e)
}

/// The line for a failed address check (`AppModel.connectionError`).
fn connection_say(e: &ErrorKind, address: &str) -> String {
    swiftly_vm::connection_error_text(
        &swiftly_l10n::Translator::new(Locale::parse("de")),
        e,
        address,
    )
}

impl Backend {
    fn spawn<T: Send + 'static>(
        &self,
        fut: impl Future<Output = T> + Send + 'static,
    ) -> Pending<T> {
        let (tx, rx) = Pending::channel();
        self.core.rt().spawn(async move {
            let _ = tx.send(fut.await);
        });
        rx
    }
    fn base(&self) -> Option<String> {
        self.state.lock().ok()?.base.clone()
    }
    fn kind(&self) -> ServerKind {
        self.state.lock().map(|s| s.kind).unwrap_or_default()
    }
    fn device(&self) -> (String, String, String) {
        (
            self.core.device_id.clone(),
            self.core.host.device_name.clone(),
            self.core.host.client_version.clone(),
        )
    }
    fn identity(&self) -> swiftly_plex::PlexIdentity {
        let platform = if cfg!(target_os = "macos") {
            "macOS"
        } else if cfg!(windows) {
            "Windows"
        } else {
            "Linux"
        };
        swiftly_plex::PlexIdentity::new(
            &self.core.device_id,
            &self.core.host.client_version,
            platform,
            "PC",
            &self.core.host.device_name,
        )
    }
    fn plex_sleep(&self) -> swiftly_plex::Sleep {
        let sleeper = self.core.sleeper();
        Arc::new(move |d: std::time::Duration| sleeper.sleep(d.as_secs_f64()))
    }
}

/// Registers the typed headers for `address` (the transport adds them to every request to that server) and keeps the
/// table in the settings file.
fn put_headers(core: &Core, headers: &[OwnHeader], address: &str) {
    if let Ok(url) = swiftly_net::Url::parse(address) {
        OwnHeaders::set_down(headers, &url);
        let _ = core
            .settings
            .set("net.ownHeaders", Value::Str(OwnHeaders::store()));
    }
}

impl SignInBackend for Backend {
    fn connect(&self, typed: &str) -> Pending<Result<String, String>> {
        let core = Arc::clone(&self.core);
        let state = Arc::clone(&self.state);
        let typed = typed.to_owned();
        let headers = self
            .state
            .lock()
            .map(|s| s.headers.clone())
            .unwrap_or_default();
        self.spawn(async move {
            // The core's probe (`AccountsHost.linkUp`): as typed, the other scheme only for an address typed without
            // one; the reason of the FIRST attempt is the one shown; the headers of an address that did not answer
            // are taken back.
            let first = swiftly_jellyfin::normalize_server_url_string(&typed)
                .ok_or_else(|| say(&ErrorKind::InvalidServerUrl))?;
            let mut candidates = vec![first];
            if !typed.contains("://")
                && let Some(other) = swiftly_jellyfin::reversed_server_url_string(&candidates[0])
            {
                candidates.push(other);
            }
            let cleaned = OwnHeaders::cleaned(&headers);
            let mut shown: Option<String> = None;
            for address in candidates {
                let url = swiftly_net::Url::parse(&address).ok();
                let before = url.as_ref().map(OwnHeaders::registered);
                if !cleaned.is_empty() {
                    put_headers(&core, &cleaned, &address);
                }
                let answer = match core.client(&address, ServerKind::Jellyfin) {
                    Ok(c) => c.check_reachability().await,
                    Err(e) => Err(e),
                };
                match answer {
                    Ok(_) => {
                        if let Ok(mut s) = state.lock() {
                            s.base = Some(address.clone());
                            s.kind = ServerKind::Jellyfin;
                        }
                        return Ok(address);
                    }
                    Err(e) => {
                        if let (Some(u), Some(b), false) =
                            (url.as_ref(), before, cleaned.is_empty())
                        {
                            OwnHeaders::set_down(&b, u);
                            let _ = core
                                .settings
                                .set("net.ownHeaders", Value::Str(OwnHeaders::store()));
                        }
                        shown.get_or_insert_with(|| connection_say(&e, &address));
                        if !e.fallback_pays_off() {
                            break;
                        }
                    }
                }
            }
            Err(shown.unwrap_or_else(|| say(&ErrorKind::InvalidServerUrl)))
        })
    }

    fn password(&self, user: &str, password: &str) -> Pending<Result<String, String>> {
        let (core, base, kind) = (Arc::clone(&self.core), self.base(), self.kind());
        let (user, password) = (user.to_owned(), password.to_owned());
        self.spawn(async move {
            let base = base.ok_or("Erst die Serveradresse eingeben.")?;
            let client = core.client(&base, kind).map_err(|e| say(&e))?;
            let session = client
                .authenticate(&user, &password)
                .await
                .map_err(|e| say(&e))?;
            let name = session.user_name.clone();
            core.store_session(session);
            Ok(name)
        })
    }

    fn quick_start(&self) -> Pending<Result<String, String>> {
        let (core, base, state) = (Arc::clone(&self.core), self.base(), Arc::clone(&self.state));
        self.spawn(async move {
            let base = base.ok_or("Erst die Serveradresse eingeben.")?;
            let client = core
                .client(&base, ServerKind::Jellyfin)
                .map_err(|e| say(&e))?;
            let code = client.quick_connect_start().await.map_err(|e| say(&e))?;
            let shown = code.code.clone();
            if let Ok(mut s) = state.lock() {
                s.code = Some(code);
            }
            Ok(shown)
        })
    }

    fn quick_poll(&self) -> Pending<signin_flows::QuickAnswer> {
        use signin_flows::QuickAnswer;
        let (core, base, state) = (Arc::clone(&self.core), self.base(), Arc::clone(&self.state));
        self.spawn(async move {
            let Some(base) = base else {
                return QuickAnswer::Failed;
            };
            let Some(code) = state.lock().ok().and_then(|s| s.code.clone()) else {
                return QuickAnswer::Failed;
            };
            let Ok(client) = core.client(&base, ServerKind::Jellyfin) else {
                return QuickAnswer::Failed;
            };
            match client.quick_connect_ask_again(&code).await {
                QuickConnectState::Released => {
                    match client.sign_in_with_quick_connect(&code).await {
                        Ok(session) => {
                            let name = session.user_name.clone();
                            core.store_session(session);
                            QuickAnswer::SignedIn(name)
                        }
                        Err(e) => QuickAnswer::SignInFailed(say(&e)),
                    }
                }
                QuickConnectState::Expired => QuickAnswer::Expired,
                QuickConnectState::Failed => QuickAnswer::Failed,
                QuickConnectState::Opened => QuickAnswer::Waiting,
            }
        })
    }

    fn quick_share(&self, code: &str) -> Pending<Result<(), String>> {
        let (core, code) = (Arc::clone(&self.core), code.to_owned());
        self.spawn(async move {
            let account = core
                .account()
                .ok_or_else(|| say(&ErrorKind::NotAuthenticated))?;
            let client = core.client_for(&account).map_err(|e| say(&e))?;
            client.quick_connect_share(&code).await.map_err(|e| say(&e))
        })
    }

    fn quick_offered(&self) -> Pending<bool> {
        let (core, base) = (Arc::clone(&self.core), self.base());
        self.spawn(async move {
            let Some(base) = base else { return false };
            match core.client(&base, ServerKind::Jellyfin) {
                Ok(c) => c.quick_connect_enabled().await,
                Err(_) => false,
            }
        })
    }

    fn set_headers(&self, headers: &[(String, String)]) {
        if let Ok(mut s) = self.state.lock() {
            s.headers = OwnHeaders::cleaned(
                &headers
                    .iter()
                    .map(|(n, v)| OwnHeader::new(n, v))
                    .collect::<Vec<_>>(),
            );
        }
    }

    fn known_servers(&self) -> Vec<String> {
        self.core
            .accounts_list()
            .into_iter()
            .filter(|e| e.kind != ServerKind::Plex)
            .map(|e| e.server)
            .collect()
    }

    fn discover(&self) -> Option<std::sync::mpsc::Receiver<Vec<FoundServer>>> {
        Some(signin_flows::discover())
    }

    fn emby_connect(&self, typed: &str) -> Pending<Result<EmbyFound, String>> {
        let (core, state, device, typed) = (
            Arc::clone(&self.core),
            Arc::clone(&self.state),
            self.device(),
            typed.to_owned(),
        );
        let headers = self
            .state
            .lock()
            .map(|s| s.headers.clone())
            .unwrap_or_default();
        self.spawn(async move {
            for address in Seerr::addresses(&typed) {
                put_headers(&core, &headers, &address);
            }
            let found = signin_flows::emby_connect(Arc::clone(&core.net), &device, &typed).await?;
            if let Ok(mut s) = state.lock() {
                s.base = Some(found.address.clone());
                s.kind = ServerKind::Emby;
            }
            Ok(found)
        })
    }

    fn emby_users(&self) -> Pending<Vec<String>> {
        let (core, device, base, state) = (
            Arc::clone(&self.core),
            self.device(),
            self.base(),
            Arc::clone(&self.state),
        );
        self.spawn(async move {
            let users = match base {
                Some(b) => {
                    signin_flows::emby_users_with_pictures(Arc::clone(&core.net), &device, &b).await
                }
                None => Vec::new(),
            };
            if let Ok(mut s) = state.lock() {
                s.user_pictures = users.iter().map(|u| u.1.clone()).collect();
            }
            users.into_iter().map(|u| u.0).collect()
        })
    }

    fn emby_user_pictures(&self) -> Vec<Option<String>> {
        self.state
            .lock()
            .map(|s| s.user_pictures.clone())
            .unwrap_or_default()
    }

    fn plex_begin(&self) -> Option<std::sync::mpsc::Receiver<PlexEvent>> {
        let (tx, rx) = std::sync::mpsc::channel();
        let (core, identity, sleep, plex) = (
            Arc::clone(&self.core),
            self.identity(),
            self.plex_sleep(),
            Arc::clone(&self.state.lock().ok()?.plex),
        );
        *plex.lock().ok()? = Default::default();
        self.core.rt().spawn(async move {
            let svc = signin_flows::plex_service(identity, Arc::clone(&core.net));
            let pause = std::time::Duration::from_secs(1);
            signin_flows::plex_sign_in(
                &svc,
                &sleep,
                pause,
                std::time::Duration::from_secs(300),
                &plex,
                &tx,
            )
            .await;
        });
        Some(rx)
    }

    fn plex_pick(&self, index: usize, pin: &str) -> Pending<Result<Vec<(String, String)>, String>> {
        let (core, identity, pin) = (Arc::clone(&self.core), self.identity(), pin.to_owned());
        let Some(plex) = self.state.lock().ok().map(|s| Arc::clone(&s.plex)) else {
            return Pending::channel().1;
        };
        self.spawn(async move {
            let svc = signin_flows::plex_service(identity, Arc::clone(&core.net));
            signin_flows::plex_pick(&svc, &plex, index, &pin).await
        })
    }

    fn plex_finish(&self, index: usize) -> Pending<Result<String, String>> {
        let (core, identity, sleep) = (Arc::clone(&self.core), self.identity(), self.plex_sleep());
        let Some(plex) = self.state.lock().ok().map(|s| Arc::clone(&s.plex)) else {
            return Pending::channel().1;
        };
        self.spawn(async move {
            let (s, name) =
                signin_flows::plex_finish(Arc::clone(&core.net), &identity, &sleep, &plex, index)
                    .await?;
            core.store_account(Account {
                session: s.session,
                plex: s.plex,
            });
            Ok(name)
        })
    }
}

/// The disk cache of the pictures: `cache/images` with the Swift limit of the device (512 MB, 256 MB on tv). Old files
/// beyond the limit are cleaned up in the background, oldest use first, like the Swift `ImageStore` at launch.
pub fn image_disk_cache(device: swiftly_images::Device) -> Arc<dyn swiftly_images::DiskCache> {
    let plate = Arc::new(swiftly_images::FolderPlate::new(
        cache_dir().join("images"),
        device.disk_limit(),
    ));
    let cleaner = Arc::clone(&plate);
    std::thread::spawn(move || {
        swiftly_images::DiskCache::clean_up(&*cleaner);
    });
    plate
}

/// What the screens read when they are built for the real app. The screens are built on the UI thread; the demo
/// constructors check `current()` where they would build the scripted view model.
pub struct Wiring {
    /// The app core.
    pub core: Arc<Core>,
    /// The signed-in account.
    pub account: AccountRef,
    /// The shared image hub (created by the shell with the 4096 page).
    pub hub: Rc<crate::hub::ImageHub>,
    /// Item type of the title about to be pushed (`Movie`, `Series`, `Episode`...).
    pub next_kind: std::cell::RefCell<String>,
    /// Id and name of the title about to be pushed (series pages read it).
    pub last_title: std::cell::RefCell<(String, String)>,
    /// Where the series page about to be pushed starts (the season of the episode or season tile that was tapped).
    pub next_spec: std::cell::RefCell<swiftly_vm::SeriesSpec>,
    /// Full titles fetched ahead while the pointer rested on their tile (the Mac's `SeriesCache.prefetch`): a page that
    /// opens on one starts from the whole title, not from the tile's name.
    pub ahead: Arc<std::sync::Mutex<std::collections::HashMap<String, swiftly_model::Item>>>,
    /// What the server says about the account's right to download (the Mac's `AppModel.downloadPermission`), asked
    /// once by [`Wiring::ask_download_right`]; unknown until the answer arrives.
    pub download_right: Arc<std::sync::Mutex<swiftly_rules::download_right::DownloadPermission>>,
    asked_right: std::cell::Cell<bool>,
    together: std::cell::OnceCell<Option<Arc<crate::together::Hub>>>,
}

thread_local! {
    static CURRENT: std::cell::RefCell<Option<Rc<Wiring>>> = const { std::cell::RefCell::new(None) };
}

/// The wiring of the real app on this thread, `None` in the demo.
pub fn current() -> Option<Rc<Wiring>> {
    CURRENT.with(|c| c.borrow().clone())
}

/// Makes `w` the wiring of this thread (`None`: back to the demo).
pub fn install(w: Option<Rc<Wiring>>) {
    CURRENT.with(|c| *c.borrow_mut() = w);
}

/// Whether the account's server has the Jellyfin-only parts: SyncPlay, the remote control socket, the other devices'
/// sessions. The Mac runs them for servers that can (`can(.remoteControl)`, `.syncPlay`); a Plex server cannot, and
/// the pollers would only fill its log with routes it does not have.
fn runs_hub(kind: ServerKind) -> bool {
    kind != ServerKind::Plex
}

impl Wiring {
    /// The wiring of a signed-in account over `core`.
    pub fn new(core: Arc<Core>, account: AccountRef, hub: Rc<crate::hub::ImageHub>) -> Self {
        Self {
            core,
            account,
            hub,
            next_kind: Default::default(),
            last_title: Default::default(),
            next_spec: Default::default(),
            ahead: Default::default(),
            download_right: Arc::new(std::sync::Mutex::new(
                swiftly_rules::download_right::DownloadPermission::Unknown,
            )),
            asked_right: std::cell::Cell::new(false),
            together: std::cell::OnceCell::new(),
        }
    }

    /// Watching together, the remote control and the other devices of this account. Built and started on the first
    /// ask; `None` for the scripted transport of the tests.
    pub fn together(&self) -> Option<Arc<crate::together::Hub>> {
        self.together
            .get_or_init(|| {
                if self.core.is_scripted() || !runs_hub(self.account.server_kind) {
                    return None;
                }
                let name = self.core.account_name();
                let hub =
                    crate::together::Hub::new(&self.core, &self.account, name.as_deref()).ok()?;
                hub.start();
                Some(Arc::new(hub))
            })
            .clone()
    }

    /// A bool of the settings file, `default` when unset.
    fn flag(&self, key: &str, default: bool) -> bool {
        use swiftly_settings::KeyValueStore;
        self.core.settings.get_bool(key).unwrap_or(default)
    }

    /// The "Gesehen von" setting (`AppModel.watchersShown`, key `gesehenVonAn`, on by default).
    pub fn watchers_shown(&self) -> bool {
        self.flag("gesehenVonAn", true)
    }

    /// The watchlist setting (`AppModel.watchlistShown`, key `merklisteAn`, on by default).
    pub fn watchlist_shown(&self) -> bool {
        self.flag("merklisteAn", true)
    }

    /// Whether a download button appears at all (`AppModel.downloadButtonShow`): the switch (`downloadsAn`, off by
    /// default) and the account's right, decided by `DownloadPermission.offer`.
    pub fn download_button(&self) -> bool {
        let right = *self
            .download_right
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        swiftly_rules::download_right::DownloadPermission::offer(
            right,
            self.flag("downloadsAn", false),
        )
    }

    /// Asks the server once for the account's download right (`GET Users/{id}`); a failed answer stays unknown.
    pub fn ask_download_right(&self) {
        if self.asked_right.replace(true) {
            return;
        }
        let Ok(server) = self.core.server_for(&self.account) else {
            return;
        };
        let cell = Arc::clone(&self.download_right);
        self.core.spawn(async move {
            if let Some(gift) = server.account_defaults().await {
                *cell
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) =
                    gift.download_permission();
            }
        });
    }

    /// A stand-in `Item` for a tapped tile; the view model loads the full title itself.
    pub fn stand_in(&self, id: &str, name: &str) -> swiftly_model::Item {
        if let Some(item) = self.ahead.lock().ok().and_then(|a| a.get(id).cloned()) {
            return item;
        }
        let kind = self.next_kind.borrow().clone();
        let kind = if kind.is_empty() {
            "Movie".to_owned()
        } else {
            kind
        };
        let json = serde_json::json!({ "Id": id, "Name": name, "Type": kind });
        serde_json::from_value(json).unwrap_or_else(|e| panic!("stand-in: {e}"))
    }
}

/// Signs in once and stores the account (test runs: the app then starts on Home). Returns the server address.
///
/// # Errors
/// Text of the failed step.
pub fn autologin(address: &str, user: &str, password: &str) -> Result<String, String> {
    let core = Arc::new(Core::open()?);
    if core.account().is_some() {
        return Ok("account already stored".into());
    }
    let backend = core.sign_in_backend();
    let wait = std::time::Duration::from_secs(30);
    let found = backend
        .connect(address)
        .0
        .recv_timeout(wait)
        .map_err(|_| "address check timed out".to_owned())??;
    backend
        .password(user, password)
        .0
        .recv_timeout(wait)
        .map_err(|_| "sign-in timed out".to_owned())??;
    Ok(found)
}

/// The headless smoke run: sign in, load Home, open the first title, load one picture. One line per step. Uses the
/// config directory of `SWIFTLY_CONFIG_DIR` (a temporary one in the tests) and stores the account like the app.
///
/// # Errors
/// The step that failed, as text.
pub fn smoke(address: &str, user: &str, password: &str) -> Result<String, String> {
    use std::time::{Duration, Instant};
    use swiftly_vm::{DetailIntent, HomeIntent, Status};
    let core = Arc::new(Core::open()?);
    let backend = core.sign_in_backend();
    let wait = |what: &str| Duration::from_secs(if what == "pic" { 20 } else { 30 });
    let mut out = Vec::new();
    let t = Instant::now();
    let found = backend
        .connect(address)
        .0
        .recv_timeout(wait("net"))
        .map_err(|_| "address check timed out".to_owned())??;
    out.push(format!(
        "address ok: {found} ({} ms)",
        t.elapsed().as_millis()
    ));
    let name = backend
        .password(user, password)
        .0
        .recv_timeout(wait("net"))
        .map_err(|_| "sign-in timed out".to_owned())??;
    out.push(format!(
        "signed in as {name}, account stored: {}",
        core.account().is_some()
    ));
    let account = core.account().ok_or("account not stored")?;
    let cx = swiftly_ui::Cx::deterministic();
    let device = swiftly_images::Device::Mac;
    let loader = swiftly_images::ImageLoader::new(
        Arc::clone(&core.net),
        Some(image_disk_cache(device)),
        device,
    );
    let hub = crate::hub::ImageHub::new(Box::new(loader), &cx, 1.0, device);
    let w = Rc::new(Wiring::new(Arc::clone(&core), account, Rc::clone(&hub)));
    install(Some(Rc::clone(&w)));
    let vm = crate::home_data::home_vm(crate::home_data::Scenario::Ready);
    vm.send(HomeIntent::Load);
    let t = Instant::now();
    loop {
        let s = vm.status();
        if matches!(s.status, Status::Ready | Status::Offline) && !s.preview && !s.refreshing {
            break;
        }
        if t.elapsed() > wait("net") {
            return Err("home did not settle".into());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let rails = vm.rails();
    let tiles: usize = rails.rails.iter().map(|r| r.tiles.len()).sum();
    out.push(format!(
        "home {:?}: {} rails, {tiles} tiles ({} ms)",
        vm.status().status,
        rails.rails.len(),
        t.elapsed().as_millis()
    ));
    let tile = rails
        .rails
        .iter()
        .flat_map(|r| r.tiles.iter())
        .find(|t| t.facts.kind.as_deref() != Some("Series"))
        .or_else(|| rails.rails.iter().flat_map(|r| r.tiles.iter()).next())
        .cloned()
        .ok_or("home has no titles")?;
    *w.next_kind.borrow_mut() = tile.facts.kind.clone().unwrap_or_default();
    let detail =
        crate::title_data::detail_vm_for(crate::home_data::Scenario::Ready, &tile.id, &tile.title);
    detail.send(DetailIntent::Load);
    let t = Instant::now();
    while !detail.bottom().ready {
        if t.elapsed() > wait("net") {
            return Err("detail did not settle".into());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    out.push(format!(
        "detail \"{}\": {} ({} ms)",
        detail.hero().title,
        detail.hero().secondary_line,
        t.elapsed().as_millis()
    ));
    let image = tile
        .image
        .clone()
        .or_else(|| detail.hero().image.clone())
        .ok_or("no picture address")?;
    let t = Instant::now();
    let owner = std::rc::Rc::new(std::cell::RefCell::new(None));
    loop {
        hub.begin_build();
        let slot = hub.slot(
            Some(&image),
            116.0,
            174.0,
            swiftly_images::Priority::Visible,
        );
        hub.after_build(&std::rc::Rc::downgrade(&owner));
        hub.frame(t.elapsed().as_secs_f64() * 1000.0);
        match slot {
            crate::hub::RemoteSlot::Ready { .. } => {
                out.push(format!(
                    "picture decoded and placed ({} ms)",
                    t.elapsed().as_millis()
                ));
                break;
            }
            crate::hub::RemoteSlot::Failed => return Err("picture failed to load".into()),
            crate::hub::RemoteSlot::Loading => {}
        }
        if t.elapsed() > wait("pic") {
            return Err("picture timed out".into());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    Ok(out.join("\n"))
}

/// Asks the server for the genre names that have movies or series (`GET Genres`), for the chips row of Start.
pub fn fetch_genres(w: &Wiring) -> crate::login_screen::Pending<Vec<String>> {
    let (tx, rx) = crate::login_screen::Pending::channel();
    if let Ok(server) = w.core.server_for(&w.account) {
        w.core.spawn(async move {
            if let Ok(names) = crate::live_server::genres(&server).await {
                let _ = tx.send(names);
            }
        });
    }
    rx
}

#[cfg(test)]
mod say_tests {
    use super::*;

    #[test]
    fn failed_steps_read_like_the_cores_readable_error() {
        let http = |status| ErrorKind::Http { status, body: None };
        assert_eq!(say(&http(401)), "Benutzername oder Passwort stimmt nicht.");
        assert_eq!(say(&http(403)), "Dieses Konto darf das nicht.");
        assert_eq!(say(&http(500)), "Der Server hat einen Fehler gemeldet.");
        assert!(
            say(&ErrorKind::TwoFactor)
                .starts_with("Dein Server will eine Zwei-Faktor-Bestätigung.")
        );
        assert_eq!(
            say(&ErrorKind::InvalidServerUrl),
            "Die Adresse konnte nicht gelesen werden."
        );
        // A timeout is not "kein Jellyfin": it names the connection.
        assert!(!say(&ErrorKind::Network { code: -1001 }).contains("kein Jellyfin"));
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_plex_account_runs_no_jellyfin_pollers() {
        assert!(!super::runs_hub(super::ServerKind::Plex));
        assert!(super::runs_hub(super::ServerKind::Jellyfin));
        assert!(super::runs_hub(super::ServerKind::Emby));
    }

    use super::*;

    /// The view model pool is no tokio thread; the search debounce is polled there (it panicked: no reactor).
    #[test]
    fn the_sleeper_works_when_polled_outside_the_runtime() {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .unwrap_or_else(|e| panic!("runtime: {e}"));
        let sleeper = TokioSleeper(rt.handle().clone());
        let started = std::time::Instant::now();
        futures_executor::block_on(sleeper.sleep(0.05));
        assert!(started.elapsed() >= std::time::Duration::from_millis(45));
    }

    /// A panicking task must not kill the pool: the next task still runs.
    #[test]
    fn a_panicking_task_does_not_take_the_pool_down() {
        let pool = Pool(
            ThreadPool::builder()
                .pool_size(1)
                .create()
                .unwrap_or_else(|e| panic!("{e}")),
        );
        pool.spawn(Box::pin(async { panic!("boom") }));
        let (tx, rx) = std::sync::mpsc::channel();
        pool.spawn(Box::pin(async move {
            let _ = tx.send(());
        }));
        assert!(rx.recv_timeout(std::time::Duration::from_secs(5)).is_ok());
    }
}
