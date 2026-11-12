//! The sign-in screen model for the host (`LoginModel.swift`, `QuickConnectModel.swift`,
//! `ServerDiscovery.swift`): address, then user and password or Quick Connect. The state machine
//! is `swiftly_vm::LoginVm`; this object runs its effects (the address check with the https/http
//! second try, the sign-in, the Quick Connect code and wait) over the accounts model, keeps the
//! last server (`letzterServer`) and the server name cache (`serverNamenCache`) in the host's
//! settings store, and hands the screen out as one [`LoginState`]. A host draws the state and
//! calls the methods; a signed-in account comes back as [`SignedIn`].
//!
//! LAN discovery: the UDP socket is the host's (Apple needs the multicast entitlement, Android a
//! `MulticastLock`). Either the host sends [`discover_probe`] itself and feeds each answer to
//! [`discover_parse`], or it implements [`DatagramHost`] and calls [`discover`]; the found servers
//! go in with [`LoginModel::discovered`].

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use swiftly_jellyfin::discovery::{self, FoundServer};
use swiftly_jellyfin::{LoginCode, QuickConnectDeadline, ServerKind, WaitEvent};
use swiftly_l10n::Locale;
use swiftly_model::PublicSystemInfo;
use swiftly_net::ErrorKind;
use swiftly_vm::{LoginEffect, LoginIntent, LoginPart, LoginScreen, LoginVm, ServerClient};

use crate::accounts::{AccountsModel, PublicUserInfo, QuickConnectListener, SignedIn, TokioClock};
use crate::error::CoreError;
use crate::settings::{Backing, SettingsStore, TypedStore};
use crate::stores::KeyValueStore;

/// A Jellyfin server that answered on the local network.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FoundServerInfo {
    /// The server id.
    pub id: String,
    /// The server name.
    pub name: String,
    /// The full base address as the server publishes it.
    pub address: String,
    /// The address as a person says it: `192.168.1.5:8096`.
    pub short_address: String,
}

impl From<&FoundServer> for FoundServerInfo {
    fn from(s: &FoundServer) -> Self {
        Self {
            id: s.id.clone(),
            name: s.name.clone(),
            address: s.address.clone(),
            short_address: s.short_address(),
        }
    }
}

impl From<FoundServerInfo> for FoundServer {
    fn from(s: FoundServerInfo) -> Self {
        Self {
            id: s.id,
            name: s.name,
            address: s.address,
        }
    }
}

/// The last connected server (`ServerReminder`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServerReminderInfo {
    /// The address.
    pub address: String,
    /// The server name.
    pub name: String,
    /// The server version.
    pub version: String,
}

/// Where the sign-in stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LoginScreenKind {
    /// Typing the server address.
    Address,
    /// The server is confirmed; user and password.
    Credentials,
    /// Waiting for approval of a Quick Connect code.
    QuickConnect,
}

/// What the sign-in screen draws.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LoginState {
    /// Grows with every change.
    pub version: u64,
    /// The step.
    pub screen: LoginScreenKind,
    /// The address field.
    pub address: String,
    /// The user field.
    pub user: String,
    /// The password field.
    pub password: String,
    /// A call is running.
    pub working: bool,
    /// The last error, readable.
    pub error: Option<String>,
    /// Name of the confirmed server.
    pub server_name: Option<String>,
    /// The Quick Connect code to type on the other device.
    pub quick_code: Option<String>,
    /// The server offers Quick Connect.
    pub quick_offered: bool,
    /// Users to pick from, if the server lists them.
    pub public_users: Vec<PublicUserInfo>,
    /// Servers found on the network, without the one in the field and the last one.
    pub found: Vec<FoundServerInfo>,
    /// The last connected server.
    pub last: Option<ServerReminderInfo>,
    /// "Sign in" may be pressed.
    pub can_sign_in: bool,
    /// "Connect" may be pressed.
    pub can_connect: bool,
    /// Seconds left of the Quick Connect code.
    pub quick_seconds_left: i64,
    /// The countdown as `m:ss`.
    pub quick_countdown: String,
}

fn state_of(part: &LoginPart) -> LoginState {
    LoginState {
        version: part.version,
        screen: match part.screen {
            LoginScreen::Address => LoginScreenKind::Address,
            LoginScreen::Credentials => LoginScreenKind::Credentials,
            LoginScreen::QuickConnect => LoginScreenKind::QuickConnect,
        },
        address: part.address.clone(),
        user: part.user.clone(),
        password: part.password.clone(),
        working: part.working,
        error: part.error.clone(),
        server_name: part.server_name.clone(),
        quick_code: part.quick_code.clone(),
        quick_offered: part.quick_offered,
        public_users: part
            .public_users
            .iter()
            .map(|u| PublicUserInfo {
                id: u.id.clone(),
                name: u.name.clone(),
            })
            .collect(),
        found: part.found.iter().map(FoundServerInfo::from).collect(),
        last: part.last.as_ref().map(reminder_info),
        can_sign_in: part.can_sign_in,
        can_connect: part.can_connect,
        quick_seconds_left: part.quick_seconds_left,
        quick_countdown: swiftly_vm::quick_countdown(part.quick_seconds_left),
    }
}

fn reminder_info(r: &swiftly_vm::ServerReminder) -> ServerReminderInfo {
    ServerReminderInfo {
        address: r.address.clone(),
        name: r.name.clone(),
        version: r.version.clone(),
    }
}

// ---- LAN discovery ---------------------------------------------------------------------------

/// One network interface of the device: its address and netmask in host byte order (the
/// broadcast address is derived from them).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct DiscoverInterface {
    /// The interface address.
    pub address: u32,
    /// Its netmask.
    pub netmask: u32,
}

/// How a discovery round is timed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct DiscoverTiming {
    /// The UDP port Jellyfin listens on.
    pub port: u16,
    /// Seconds one round listens for answers.
    pub listen_seconds: u32,
    /// Seconds between rounds while the page is open.
    pub pause_seconds: u32,
}

/// The UDP half a host provides: one socket, the probe to every target, then whatever comes back.
#[uniffi::export(with_foreign)]
pub trait DatagramHost: Send + Sync {
    /// Sends `payload` to `target` (host byte order) on `port`; `true` if all bytes went out.
    fn send(&self, payload: Vec<u8>, target: u32, port: u16) -> bool;
    /// Everything received within `seconds`.
    fn receive(&self, seconds: u32) -> Vec<Vec<u8>>;
}

struct HostSocket(Arc<dyn DatagramHost>);

impl discovery::DatagramSocket for HostSocket {
    fn send(&self, payload: &[u8], target: u32, port: u16) -> bool {
        self.0.send(payload.to_vec(), target, port)
    }
    fn receive(&self, seconds: u32) -> Vec<Vec<u8>> {
        self.0.receive(seconds)
    }
}

/// The sentence a Jellyfin server answers (`ServerDiscovery.question`), as bytes to send.
#[uniffi::export]
pub fn discover_probe() -> Vec<u8> {
    discovery::QUESTION.as_bytes().to_vec()
}

/// Port and timing of a discovery round.
#[uniffi::export]
pub fn discover_timing() -> DiscoverTiming {
    DiscoverTiming {
        port: discovery::PORT,
        listen_seconds: discovery::LISTENING_SECONDS,
        pause_seconds: discovery::PAUSE_SECONDS,
    }
}

/// Where to send the probe: 255.255.255.255 first, then the broadcast address of every
/// interface, once each (host byte order).
#[uniffi::export]
pub fn discover_targets(interfaces: Vec<DiscoverInterface>) -> Vec<u32> {
    let pairs: Vec<(u32, u32)> = interfaces.iter().map(|i| (i.address, i.netmask)).collect();
    discovery::targets(&pairs)
}

/// One answer of the network. `None` for anything that is not a usable server: another program
/// on the port, a server without id or address.
#[uniffi::export]
pub fn discover_parse(data: Vec<u8>) -> Option<FoundServerInfo> {
    discovery::read(&data).map(|s| FoundServerInfo::from(&s))
}

/// One whole round over the host's socket: asks every target, listens, keeps the usable
/// answers. Blocks for the listening time: call it off the main thread. Empty when the network
/// refuses the broadcast.
#[uniffi::export]
pub fn discover(
    socket: Arc<dyn DatagramHost>,
    interfaces: Vec<DiscoverInterface>,
) -> Vec<FoundServerInfo> {
    let pairs: Vec<(u32, u32)> = interfaces.iter().map(|i| (i.address, i.netmask)).collect();
    discovery::search(&HostSocket(socket), &pairs)
        .iter()
        .map(FoundServerInfo::from)
        .collect()
}

// ---- The model ---------------------------------------------------------------------------------

/// What one address check brought back besides the name.
type CheckAnswer = Result<(PublicSystemInfo, bool, Vec<swiftly_jellyfin::PublicUser>), ErrorKind>;

/// The sign-in screen, with its effects run.
#[derive(uniffi::Object)]
pub struct LoginModel {
    accounts: Arc<AccountsModel>,
    vm: Mutex<LoginVm<Backing>>,
    /// The Quick Connect code with its secret (the screen keeps only the short code).
    code: Mutex<Option<LoginCode>>,
}

impl LoginModel {
    pub(crate) fn over_packed(
        accounts: Arc<AccountsModel>,
        kv: Arc<dyn KeyValueStore>,
        locale: &str,
    ) -> Arc<Self> {
        Self::build(accounts, Backing::Packed(TypedStore::new(kv)), locale)
    }

    pub(crate) fn over_native(
        accounts: Arc<AccountsModel>,
        store: Arc<dyn SettingsStore>,
        locale: &str,
    ) -> Arc<Self> {
        Self::build(accounts, Backing::Native(store), locale)
    }

    fn build(accounts: Arc<AccountsModel>, backing: Backing, locale: &str) -> Arc<Self> {
        Arc::new(Self {
            accounts,
            vm: Mutex::new(LoginVm::new(backing, Locale::parse(locale))),
            code: Mutex::new(None),
        })
    }

    fn with_vm<R>(&self, f: impl FnOnce(&mut LoginVm<Backing>) -> R) -> R {
        f(&mut self.vm.lock().unwrap_or_else(PoisonError::into_inner))
    }

    fn step(&self, intent: LoginIntent) -> Vec<LoginEffect> {
        self.with_vm(|vm| vm.handle(intent))
    }

    fn state_now(&self) -> LoginState {
        self.with_vm(|vm| state_of(vm.part()))
    }

    async fn check(&self, url: &str) -> CheckAnswer {
        let client = self.accounts.raw_client(url, ServerKind::Jellyfin)?;
        let info = client.check_reachability().await?;
        let ServerClient::Jellyfin(c) = &client else {
            return Ok((info, false, Vec::new()));
        };
        let quick = c.quick_connect_enabled().await;
        let users = c.public_users().await.unwrap_or_default();
        Ok((info, quick, users))
    }

    /// Runs effects until none is left; the signed-in account, if one came out.
    async fn run(&self, first: Vec<LoginEffect>) -> Option<SignedIn> {
        let mut queue: VecDeque<LoginEffect> = first.into();
        let mut done = None;
        while let Some(effect) = queue.pop_front() {
            match effect {
                LoginEffect::CheckAddress { mark, url } => {
                    let answer = self.check(&url).await;
                    let (result, extra) = match answer {
                        Ok((info, quick, users)) => (Ok(info), Some((quick, users))),
                        Err(e) => (Err(e), None),
                    };
                    queue.extend(self.step(LoginIntent::AddressChecked { mark, result }));
                    if let Some((quick, users)) = extra {
                        let confirmed = self.with_vm(|vm| {
                            vm.part().screen == LoginScreen::Credentials && vm.part().address == url
                        });
                        if confirmed {
                            self.step(LoginIntent::QuickConnectOffered(quick));
                            self.step(LoginIntent::PublicUsers(users));
                        }
                    }
                }
                LoginEffect::Authenticate {
                    url,
                    user,
                    password,
                } => {
                    let result = match self.accounts.raw_client(&url, ServerKind::Jellyfin) {
                        Ok(client) => client.authenticate(&user, &password).await,
                        Err(e) => Err(e),
                    };
                    queue.extend(self.step(LoginIntent::SignedIn(result)));
                }
                LoginEffect::StartQuickConnect => {
                    let result = match self.quick_client() {
                        Ok(ServerClient::Jellyfin(c)) => c.quick_connect_start().await,
                        Ok(ServerClient::Plex(_)) => Err(ErrorKind::InvalidServerUrl),
                        Err(e) => Err(e),
                    };
                    if let Ok(code) = &result {
                        *self.code.lock().unwrap_or_else(PoisonError::into_inner) =
                            Some(code.clone());
                    }
                    queue.extend(self.step(LoginIntent::QuickConnectStarted(result)));
                }
                LoginEffect::SignInWithQuickConnect(code) => {
                    let result = match self.quick_client() {
                        Ok(ServerClient::Jellyfin(c)) => c.sign_in_with_quick_connect(&code).await,
                        Ok(ServerClient::Plex(_)) => Err(ErrorKind::InvalidServerUrl),
                        Err(e) => Err(e),
                    };
                    queue.extend(self.step(LoginIntent::SignedIn(result)));
                }
                LoginEffect::Done(session) => {
                    *self.code.lock().unwrap_or_else(PoisonError::into_inner) = None;
                    done = Some(self.accounts.adopt(session));
                }
            }
        }
        done
    }

    /// A client for the confirmed address of the screen.
    fn quick_client(&self) -> Result<ServerClient<crate::transport::ForeignTransport>, ErrorKind> {
        let address = self.with_vm(|vm| vm.part().address.clone());
        self.accounts.raw_client(&address, ServerKind::Jellyfin)
    }
}

#[uniffi::export]
impl LoginModel {
    /// Login, connect and account switch as one state (replaces `phase`/`isWorking`/`client == nil`).
    pub fn session(&self) -> crate::state::AccountSessionPart {
        self.with_vm(|vm| crate::state::AccountSessionPart::of(vm.session()))
    }

    /// The host reports what only it knows (account switch started/done/failed, sign-out, revoked);
    /// an event that makes no sense in the state changes nothing.
    pub fn feed_session(
        &self,
        event: crate::state::AccountSessionEvent,
    ) -> crate::state::AccountSessionPart {
        self.with_vm(|vm| crate::state::AccountSessionPart::of(vm.feed_session(event.into())))
    }

    /// Sets the state at launch (a restored account is `Ready`).
    pub fn set_session(&self, state: crate::state::AccountSessionState) {
        self.with_vm(|vm| vm.set_session(state.into()));
    }

    /// The screen as it is now.
    pub fn state(&self) -> LoginState {
        self.state_now()
    }

    /// The address field changed: drops a running check and goes back to the address step.
    pub fn edit_address(&self, text: String) -> LoginState {
        self.step(LoginIntent::EditAddress(text));
        self.state_now()
    }

    /// The user field changed.
    pub fn edit_user(&self, text: String) -> LoginState {
        self.step(LoginIntent::EditUser(text));
        self.state_now()
    }

    /// The password field changed.
    pub fn edit_password(&self, text: String) -> LoginState {
        self.step(LoginIntent::EditPassword(text));
        self.state_now()
    }

    /// A user was picked from the server's list.
    pub fn pick_user(&self, name: String) -> LoginState {
        self.step(LoginIntent::PickUser(name));
        self.state_now()
    }

    /// One step back (Quick Connect to password, password to address). Drops the code.
    pub fn back(&self) -> LoginState {
        self.step(LoginIntent::Back);
        *self.code.lock().unwrap_or_else(PoisonError::into_inner) = None;
        self.state_now()
    }

    /// Servers found on the network (a round of discovery). They are merged by id and sorted by
    /// name in the app language; the screen hides the one in the field and the last one.
    pub fn discovered(&self, servers: Vec<FoundServerInfo>) -> LoginState {
        self.step(LoginIntent::Discovered(
            servers.into_iter().map(FoundServer::from).collect(),
        ));
        self.state_now()
    }

    /// The last connected server (`lastServer`).
    pub fn last_server(&self) -> Option<ServerReminderInfo> {
        self.with_vm(|vm| vm.last_server())
            .as_ref()
            .map(reminder_info)
    }

    /// Stores the last connected server (`serverRemember`).
    pub fn remember_server(
        &self,
        address: String,
        name: String,
        version: String,
    ) -> Option<ServerReminderInfo> {
        self.with_vm(|vm| vm.remember_server(&address, &name, &version))
            .as_ref()
            .map(reminder_info)
    }

    /// The cached name of the server at `url`, shown until the real one arrives.
    pub fn server_name_for(&self, url: String) -> Option<String> {
        self.with_vm(|vm| vm.server_name_for(&url))
    }

    /// Caches a server name (not an empty one, not the host name).
    pub fn cache_server_name(&self, name: String, url: String) {
        self.with_vm(|vm| vm.cache_server_name(&name, &url));
    }

    /// Checks the address in the field: https first, then http once when that can pay off. On
    /// success the screen moves to the credentials step with the server's name, the Quick
    /// Connect offer and the public users; the server is remembered as the last one.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn connect(&self) -> Result<LoginState, CoreError> {
        let effects = self.step(LoginIntent::Connect);
        self.run(effects).await;
        Ok(self.state_now())
    }

    /// A server found on the network was tapped (its id): fills the field and connects.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn pick_server(&self, id: String) -> Result<LoginState, CoreError> {
        let effects = self.step(LoginIntent::PickServer(id));
        self.run(effects).await;
        Ok(self.state_now())
    }

    /// "Zuletzt verbunden" was tapped: fills the field and connects.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn use_last(&self) -> Result<LoginState, CoreError> {
        let effects = self.step(LoginIntent::UseLast);
        self.run(effects).await;
        Ok(self.state_now())
    }

    /// Signs in with the user and password of the screen and saves the account. `None` when it
    /// did not work (the state has the sentence) or nothing was to do.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn sign_in(&self) -> Result<Option<SignedIn>, CoreError> {
        let effects = self.step(LoginIntent::SignIn);
        Ok(self.run(effects).await)
    }

    /// Opens the Quick Connect page and asks for a code.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn use_quick_connect(&self) -> Result<LoginState, CoreError> {
        let effects = self.step(LoginIntent::UseQuickConnect);
        self.run(effects).await;
        Ok(self.state_now())
    }

    /// "Neuen Code holen": the host stops the old wait first, then calls this.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn new_code(&self) -> Result<LoginState, CoreError> {
        let effects = self.step(LoginIntent::NewCode);
        self.run(effects).await;
        Ok(self.state_now())
    }

    /// Waits for the approval of the code on screen: the countdown goes into the state and to the
    /// listener once a second; when the code is approved the sign-in runs and the account is
    /// saved. Returns it, or `None` when the code ran out or failed (the state has the sentence)
    /// or there was no code. Dropping the call stops the wait.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn quick_connect_wait(
        &self,
        listener: Arc<dyn QuickConnectListener>,
    ) -> Result<Option<SignedIn>, CoreError> {
        Ok(self.wait_for_approval(listener).await)
    }
}

impl LoginModel {
    /// The wait of [`Self::quick_connect_wait`]; `None` when the code ran out, failed or was missing.
    async fn wait_for_approval(&self, listener: Arc<dyn QuickConnectListener>) -> Option<SignedIn> {
        let login = self
            .code
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()?;
        let ServerClient::Jellyfin(client) = self.quick_client().ok()? else {
            return None;
        };
        let ended = Mutex::new(None::<WaitEvent>);
        let clock = TokioClock(Instant::now());
        client
            .quick_connect_wait(&login, &clock, |event| match event {
                WaitEvent::Rest(seconds) => {
                    self.step(LoginIntent::QuickConnectRest(seconds));
                    listener.rest(seconds);
                    true
                }
                other => {
                    *ended.lock().unwrap_or_else(PoisonError::into_inner) = Some(other);
                    false
                }
            })
            .await;
        let last = ended.lock().unwrap_or_else(PoisonError::into_inner).take();
        let intent = match last? {
            WaitEvent::Released => {
                LoginIntent::QuickConnectState(swiftly_jellyfin::QuickConnectState::Released)
            }
            WaitEvent::End(state) => {
                LoginIntent::QuickConnectState(if QuickConnectDeadline::end_is_failure(state) {
                    swiftly_jellyfin::QuickConnectState::Failed
                } else {
                    swiftly_jellyfin::QuickConnectState::Expired
                })
            }
            WaitEvent::Rest(_) => return None,
        };
        let effects = self.step(intent);
        self.run(effects).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::{ForeignTransport, HttpClient, HttpFailure, NetRequest, NetResponse};
    use std::collections::HashMap;
    use swiftly_vm::{Host, Spawner, SystemClock};

    struct Spawn;
    impl Spawner for Spawn {
        fn spawn(&self, task: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>) {
            drop(tokio::spawn(task));
        }
    }

    struct NoStore;
    impl swiftly_library::Store for NoStore {
        fn read(&self, _: &str) -> Option<Vec<u8>> {
            None
        }
        fn write(&self, _: &str, _: &[u8]) {}
        fn remove(&self, _: &str) {}
    }

    #[derive(Default)]
    struct Secrets(Mutex<HashMap<String, String>>);
    impl crate::stores::SecretStore for Secrets {
        fn get(&self, name: String) -> Option<String> {
            self.0.lock().unwrap().get(&name).cloned()
        }
        fn set(&self, name: String, value: String) {
            self.0.lock().unwrap().insert(name, value);
        }
        fn remove(&self, name: String) {
            self.0.lock().unwrap().remove(&name);
        }
    }

    #[derive(Default)]
    struct Bytes(Mutex<HashMap<String, Vec<u8>>>);
    impl KeyValueStore for Bytes {
        fn get(&self, key: String) -> Option<Vec<u8>> {
            self.0.lock().unwrap().get(&key).cloned()
        }
        fn set(&self, key: String, value: Vec<u8>) {
            self.0.lock().unwrap().insert(key, value);
        }
        fn remove(&self, key: String) {
            self.0.lock().unwrap().remove(&key);
        }
    }

    /// A home server that only speaks http, with Quick Connect and one public user. The first
    /// Quick Connect poll says "waiting", the second "approved".
    struct Home {
        polls: Mutex<u32>,
        seen: Mutex<Vec<String>>,
    }

    fn reply(status: u16, body: &str) -> Result<NetResponse, HttpFailure> {
        Ok(NetResponse {
            status,
            headers: vec![],
            body: body.as_bytes().to_vec(),
            url: None,
        })
    }

    #[async_trait::async_trait]
    impl HttpClient for Home {
        async fn send(&self, request: NetRequest) -> Result<NetResponse, HttpFailure> {
            let url = request.url.clone();
            self.seen.lock().unwrap().push(url.clone());
            if url.starts_with("https://") {
                return Err(HttpFailure::Network { code: -1004 });
            }
            if url.contains("System/Info/Public") {
                reply(
                    200,
                    r#"{"ServerName":"Home","Version":"10.9.1","Id":"sid"}"#,
                )
            } else if url.contains("QuickConnect/Enabled") {
                reply(200, "true")
            } else if url.contains("Users/Public") {
                reply(200, r#"[{"Id":"u1","Name":"paul"}]"#)
            } else if url.contains("QuickConnect/Initiate") {
                reply(200, r#"{"Code":"123456","Secret":"sec"}"#)
            } else if url.contains("QuickConnect/Connect") {
                let mut n = self.polls.lock().unwrap();
                *n += 1;
                reply(
                    200,
                    if *n >= 2 {
                        r#"{"Authenticated":true}"#
                    } else {
                        r#"{"Authenticated":false}"#
                    },
                )
            } else if url.contains("AuthenticateByName")
                || url.contains("AuthenticateWithQuickConnect")
            {
                let body = String::from_utf8_lossy(request.body.as_deref().unwrap_or_default())
                    .into_owned();
                if url.contains("AuthenticateByName") && body.contains("wrong") {
                    return reply(401, "Unauthorized");
                }
                reply(
                    200,
                    r#"{"AccessToken":"tok","User":{"Id":"id-paul","Name":"paul"},"ServerId":"sid"}"#,
                )
            } else {
                reply(404, "")
            }
        }
    }

    struct Fixture {
        model: Arc<LoginModel>,
        accounts: Arc<AccountsModel>,
        bytes: Arc<Bytes>,
        home: Arc<Home>,
    }

    fn fixture() -> Fixture {
        let home = Arc::new(Home {
            polls: Mutex::new(0),
            seen: Mutex::new(Vec::new()),
        });
        let host = Host {
            spawner: Arc::new(Spawn),
            clock: Arc::new(SystemClock),
            store: Arc::new(NoStore),
            locale: Locale::parse("en"),
            device_name: "test".into(),
            client_version: "1".into(),
            cache: None,
        };
        let accounts = AccountsModel::build(
            Arc::new(Secrets::default()),
            ForeignTransport(Arc::<Home>::clone(&home)),
            host,
            "dev".into(),
            "en",
        );
        let bytes = Arc::new(Bytes::default());
        let model =
            LoginModel::over_packed(Arc::clone(&accounts), Arc::<Bytes>::clone(&bytes), "en");
        Fixture {
            model,
            accounts,
            bytes,
            home,
        }
    }

    struct Beats(Mutex<Vec<i64>>);
    impl QuickConnectListener for Beats {
        fn rest(&self, seconds: i64) {
            self.0.lock().unwrap().push(seconds);
        }
    }

    #[tokio::test]
    async fn connect_tries_http_after_https_then_shows_the_credentials_step_and_remembers_the_server()
     {
        let f = fixture();
        assert!(!f.model.state().can_connect);
        f.model.edit_address("home.example:8096".into());
        assert!(f.model.state().can_connect);
        let state = f.model.connect().await.unwrap();
        assert_eq!(state.screen, LoginScreenKind::Credentials);
        assert_eq!(state.server_name.as_deref(), Some("Home"));
        assert_eq!(state.address, "http://home.example:8096");
        assert!(state.quick_offered);
        assert_eq!(
            state.public_users,
            vec![PublicUserInfo {
                id: "u1".into(),
                name: "paul".into()
            }]
        );
        assert!(!state.working && state.error.is_none());
        let seen = f.home.seen.lock().unwrap().clone();
        assert!(
            seen[0].starts_with("https://home.example:8096/System/Info/Public"),
            "{seen:?}"
        );
        assert!(
            seen[1].starts_with("http://home.example:8096/System/Info/Public"),
            "{seen:?}"
        );
        // The last server is in the store under the German key, as the Swift app wrote it.
        let raw: Vec<String> = f
            .bytes
            .0
            .lock()
            .unwrap()
            .values()
            .map(|v| String::from_utf8_lossy(v).into_owned())
            .collect();
        let last = f.model.last_server().unwrap();
        assert_eq!(
            last,
            ServerReminderInfo {
                address: "http://home.example:8096".into(),
                name: "Home".into(),
                version: "10.9.1".into()
            }
        );
        assert!(raw.iter().any(|v| v.contains("adresse")), "{raw:?}");
        // A new model over the same store knows it, and the server name cache answers.
        let again =
            LoginModel::over_packed(Arc::clone(&f.accounts), Arc::<Bytes>::clone(&f.bytes), "en");
        assert_eq!(again.state().last, Some(last));
        assert_eq!(
            again
                .server_name_for("HTTP://home.example:8096".into())
                .as_deref(),
            Some("Home")
        );
    }

    #[tokio::test]
    async fn the_password_step_signs_in_and_saves_the_account_and_a_wrong_password_keeps_the_fields()
     {
        let f = fixture();
        f.model.edit_address("http://home.example:8096".into());
        f.model.connect().await.unwrap();
        assert!(
            f.model.sign_in().await.unwrap().is_none(),
            "no user typed: nothing happens"
        );
        f.model.pick_user("paul".into());
        f.model.edit_password("wrong".into());
        assert!(f.model.state().can_sign_in);
        assert!(f.model.sign_in().await.unwrap().is_none());
        let failed = f.model.state();
        assert!(failed.error.is_some() && !failed.working);
        assert_eq!(
            (failed.user.as_str(), failed.password.as_str()),
            ("paul", "wrong")
        );
        f.model.edit_password("right".into());
        let signed = f.model.sign_in().await.unwrap().unwrap();
        assert_eq!(signed.account.token, "tok");
        assert!(signed.new_server);
        assert_eq!(f.accounts.accounts().len(), 1);
        assert!(f.model.state().password.is_empty());
    }

    #[tokio::test]
    async fn back_goes_from_credentials_to_the_address_and_a_tap_on_last_connects_again() {
        let f = fixture();
        f.model.edit_address("http://home.example:8096".into());
        f.model.connect().await.unwrap();
        let back = f.model.back();
        assert_eq!(back.screen, LoginScreenKind::Address);
        assert!(back.server_name.is_none());
        f.model.edit_address(String::new());
        let again = f.model.use_last().await.unwrap();
        assert_eq!(again.screen, LoginScreenKind::Credentials);
        assert_eq!(again.address, "http://home.example:8096");
    }

    #[tokio::test]
    async fn found_servers_are_merged_sorted_and_hide_the_one_in_the_field_or_last() {
        let f = fixture();
        let server = |id: &str, name: &str, addr: &str| FoundServerInfo {
            id: id.into(),
            name: name.into(),
            address: addr.into(),
            short_address: String::new(),
        };
        let state = f.model.discovered(vec![
            server("2", "Zoo", "http://192.168.1.9:8096"),
            server("1", "attic", "http://192.168.1.5:8096"),
        ]);
        assert_eq!(
            state
                .found
                .iter()
                .map(|s| s.name.as_str())
                .collect::<Vec<_>>(),
            ["attic", "Zoo"]
        );
        assert_eq!(state.found[0].short_address, "192.168.1.5:8096");
        // The address in the field hides its server.
        let state = f.model.edit_address("192.168.1.5:8096".into());
        assert_eq!(state.found.len(), 1);
        assert_eq!(state.found[0].id, "2");
        // Tapping the other fills the field and checks it (the http-only fixture answers).
        let tapped = f.model.pick_server("2".into()).await.unwrap();
        assert_eq!(tapped.address, "http://192.168.1.9:8096");
        assert_eq!(tapped.screen, LoginScreenKind::Credentials);
    }

    #[tokio::test]
    async fn quick_connect_starts_counts_down_and_signs_in_when_approved() {
        let f = fixture();
        f.model.edit_address("http://home.example:8096".into());
        f.model.connect().await.unwrap();
        let started = f.model.use_quick_connect().await.unwrap();
        assert_eq!(started.screen, LoginScreenKind::QuickConnect);
        assert_eq!(started.quick_code.as_deref(), Some("123456"));
        assert_eq!(started.quick_countdown, "5:00");
        let beats = Arc::new(Beats(Mutex::new(Vec::new())));
        let signed = f
            .model
            .quick_connect_wait(Arc::<Beats>::clone(&beats))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(signed.account.user_id, "id-paul");
        assert!(!beats.0.lock().unwrap().is_empty());
        assert_eq!(f.accounts.accounts().len(), 1);
    }

    #[tokio::test]
    async fn quick_connect_is_refused_before_the_server_is_confirmed_and_back_drops_the_code() {
        let f = fixture();
        // Not confirmed yet: nothing to open.
        let state = f.model.use_quick_connect().await.unwrap();
        assert_eq!(state.screen, LoginScreenKind::Address);
        f.model.edit_address("http://home.example:8096".into());
        f.model.connect().await.unwrap();
        f.model.use_quick_connect().await.unwrap();
        let back = f.model.back();
        assert_eq!(back.screen, LoginScreenKind::Credentials);
        assert!(back.quick_code.is_none());
        let beats = Arc::new(Beats(Mutex::new(Vec::new())));
        assert!(
            f.model.quick_connect_wait(beats).await.unwrap().is_none(),
            "the code is gone"
        );
    }

    #[test]
    fn the_discovery_packets_are_the_ones_jellyfin_answers() {
        assert_eq!(discover_probe(), b"who is JellyfinServer?".to_vec());
        let timing = discover_timing();
        assert_eq!(
            (timing.port, timing.listen_seconds, timing.pause_seconds),
            (7359, 2, 8)
        );
        let found = discover_parse(
            br#"{"Id":"x","Name":"Home","Address":"http://192.168.1.5:8096"}"#.to_vec(),
        )
        .unwrap();
        assert_eq!(found.short_address, "192.168.1.5:8096");
        assert!(discover_parse(b"hello".to_vec()).is_none());
        assert!(discover_parse(br#"{"Id":"","Name":"n","Address":"http://h"}"#.to_vec()).is_none());
        // 255.255.255.255 first, then the broadcast of 192.168.1.20/24, once.
        let targets = discover_targets(vec![
            DiscoverInterface {
                address: 0xC0A8_0114,
                netmask: 0xFFFF_FF00,
            },
            DiscoverInterface {
                address: 0xC0A8_0115,
                netmask: 0xFFFF_FF00,
            },
        ]);
        assert_eq!(targets, vec![u32::MAX, 0xC0A8_01FF]);
    }

    struct Wire {
        sent: Mutex<Vec<(Vec<u8>, u32, u16)>>,
    }
    impl DatagramHost for Wire {
        fn send(&self, payload: Vec<u8>, target: u32, port: u16) -> bool {
            self.sent.lock().unwrap().push((payload, target, port));
            true
        }
        fn receive(&self, _seconds: u32) -> Vec<Vec<u8>> {
            vec![
                br#"{"Id":"x","Name":"Home","Address":"http://192.168.1.5:8096"}"#.to_vec(),
                b"junk".to_vec(),
            ]
        }
    }

    #[test]
    fn a_round_over_the_host_socket_asks_every_target_and_keeps_the_usable_answers() {
        let wire = Arc::new(Wire {
            sent: Mutex::new(Vec::new()),
        });
        let found = discover(
            Arc::<Wire>::clone(&wire),
            vec![DiscoverInterface {
                address: 0xC0A8_0114,
                netmask: 0xFFFF_FF00,
            }],
        );
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].name, "Home");
        let sent = wire.sent.lock().unwrap().clone();
        assert_eq!(
            sent.iter().map(|s| (s.1, s.2)).collect::<Vec<_>>(),
            vec![(u32::MAX, 7359), (0xC0A8_01FF, 7359)]
        );
        assert!(sent.iter().all(|s| s.0 == discover_probe()));
    }
}
