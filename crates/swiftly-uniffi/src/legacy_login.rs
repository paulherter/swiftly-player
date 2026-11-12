//! The old Android facade's server and sign-in calls (`Kern.serverInfo/serverSearch/publicUser/quickConnect*/signIn/
//! embySignIn/onboarding*`) over the accounts model, answering the same JSON. Nothing is stored here: the session goes back
//! to Kotlin as text, like before; only the connected server, the server being added and the open Quick Connect code are held.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use serde_json::{Value, json};
use swiftly_jellyfin::{
    LoginCode, OwnHeaders, QuickConnectDeadline, ServerKind, Session, WaitEvent, discovery,
};
use swiftly_net::ErrorKind;
use swiftly_vm::ServerClient;

use crate::accounts::{AccountsModel, TokioClock};
use crate::error::CoreError;
use crate::login::{DatagramHost, DiscoverInterface, FoundServerInfo};

#[derive(Clone)]
struct Target {
    url: String,
    kind: ServerKind,
}

#[derive(Default)]
struct Held {
    connected: Option<Target>,
    /// The stored session (`Kern.sessionSet`), for the calls that need a token.
    session: Option<Session>,
    onboarding: Option<Target>,
    quick: Option<LoginCode>,
    rest: i64,
    /// The open wait: its code and the flag that ends it.
    wait: Option<(String, Arc<AtomicBool>)>,
}

/// The server and sign-in calls of one app.
#[derive(uniffi::Object)]
pub struct LegacyLogin {
    accounts: Arc<AccountsModel>,
    held: Mutex<Held>,
    /// Newest address check; an older one that finishes later sets nothing (`CheckState`).
    mark: AtomicU64,
}

#[uniffi::export]
impl AccountsModel {
    /// The old `Kern` server and sign-in calls.
    pub fn legacy_login(self: Arc<Self>) -> Arc<LegacyLogin> {
        Arc::new(LegacyLogin {
            accounts: self,
            held: Mutex::new(Held::default()),
            mark: AtomicU64::new(0),
        })
    }
}

fn no_server() -> CoreError {
    CoreError::Failed {
        message: "not connected".to_owned(),
    }
}

impl LegacyLogin {
    fn held<R>(&self, f: impl FnOnce(&mut Held) -> R) -> R {
        f(&mut self.held.lock().unwrap_or_else(PoisonError::into_inner))
    }

    fn target(&self, new_server: bool) -> Option<Target> {
        self.held(|h| {
            if new_server {
                h.onboarding.clone()
            } else {
                h.connected.clone()
            }
        })
    }

    fn client(
        &self,
        t: &Target,
    ) -> Result<ServerClient<crate::transport::ForeignTransport>, CoreError> {
        self.accounts
            .raw_client(&t.url, t.kind)
            .map_err(|e| self.accounts.failed_text(&e))
    }

    fn quick_client(
        &self,
        new_server: bool,
    ) -> Option<
        Arc<
            swiftly_jellyfin::JellyfinClient<
                swiftly_vm::Shared<crate::transport::ForeignTransport>,
            >,
        >,
    > {
        let t = self
            .target(new_server)
            .filter(|t| t.kind == ServerKind::Jellyfin)?;
        match self.accounts.raw_client(&t.url, t.kind) {
            Ok(ServerClient::Jellyfin(c)) => Some(c),
            _ => None,
        }
    }

    async fn check_address(
        &self,
        address: String,
        headers: String,
        onboarding: bool,
    ) -> Result<String, CoreError> {
        let first = swiftly_jellyfin::normalize_server_url_string(&address)
            .ok_or_else(|| self.accounts.failed_text(&ErrorKind::InvalidServerUrl))?;
        let mut candidates = vec![first];
        // The other scheme only for an address typed without one (an explicit `://` is taken as meant).
        if !address.contains("://")
            && let Some(other) = swiftly_jellyfin::reversed_server_url_string(&candidates[0])
        {
            candidates.push(other);
        }
        let own: Vec<swiftly_jellyfin::OwnHeader> =
            serde_json::from_str(&headers).unwrap_or_default();
        let mark = self.mark.fetch_add(1, Ordering::SeqCst) + 1;
        let mut last: Option<CoreError> = None;
        for candidate in candidates {
            let url = swiftly_net::Url::parse(&candidate).ok();
            let cleaned = OwnHeaders::cleaned(&own);
            let before = url.as_ref().map(OwnHeaders::registered);
            if let (Some(u), false) = (url.as_ref(), cleaned.is_empty()) {
                OwnHeaders::set_down(&cleaned, u);
            }
            let answer = match self.accounts.raw_client(&candidate, ServerKind::Jellyfin) {
                Ok(c) => c.check_reachability().await,
                Err(e) => Err(e),
            };
            match answer {
                Ok(info) => {
                    if self.mark.load(Ordering::SeqCst) != mark {
                        return Err(CoreError::Closed);
                    }
                    let target = Target {
                        url: candidate.clone(),
                        kind: ServerKind::Jellyfin,
                    };
                    self.held(|h| {
                        if onboarding {
                            h.onboarding = Some(target)
                        } else {
                            h.connected = Some(target)
                        }
                    });
                    let host = url
                        .as_ref()
                        .and_then(|u| u.host_str())
                        .unwrap_or_default()
                        .to_owned();
                    return Ok(json!({ "name": info.server_name.unwrap_or(host), "version": info.version.unwrap_or_default(), "adresse": candidate }).to_string());
                }
                Err(e) => {
                    if let (Some(u), Some(b), false) = (url.as_ref(), before, cleaned.is_empty()) {
                        OwnHeaders::set_down(&b, u);
                    }
                    // The reason of the first attempt is the one that is shown.
                    last.get_or_insert_with(|| CoreError::Failed {
                        message: swiftly_vm::connection_error_text(
                            self.accounts.translator(),
                            &e,
                            &candidate,
                        ),
                    });
                    if !e.fallback_pays_off() {
                        break;
                    }
                }
            }
        }
        Err(last.unwrap_or_else(|| self.accounts.failed_text(&ErrorKind::InvalidServerUrl)))
    }

    fn session_text(s: &Session) -> Result<String, CoreError> {
        serde_json::to_string(s).map_err(|e| CoreError::Failed {
            message: e.to_string(),
        })
    }
}

#[uniffi::export]
impl LegacyLogin {
    /// `Kern.sessionSet`: the connected server is the one of this session.
    pub fn session_set(&self, json: String) {
        if let Ok(s) = serde_json::from_str::<Session>(&json) {
            self.held(|h| {
                h.connected = Some(Target {
                    url: s.server_url.clone(),
                    kind: s.kind,
                });
                h.session = Some(s);
            });
        }
    }

    /// `Kern.sessionClear`.
    pub fn session_clear(&self) {
        self.held(|h| {
            h.connected = None;
            h.session = None;
        });
    }

    /// Remembers a server checked elsewhere (the Emby check) as the one being added.
    pub fn onboarding_remember(&self, address: String, emby: bool) {
        self.held(|h| {
            h.onboarding = Some(Target {
                url: address,
                kind: if emby {
                    ServerKind::Emby
                } else {
                    ServerKind::Jellyfin
                },
            })
        });
    }

    /// `Kern.serverInfo`: `{"name","version","adresse":""}` of the connected server.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn server_info(&self) -> Result<String, CoreError> {
        let t = self.target(false).ok_or_else(no_server)?;
        let info = self
            .client(&t)?
            .check_reachability()
            .await
            .map_err(|e| self.accounts.failed_text(&e))?;
        Ok(json!({ "name": info.server_name.unwrap_or_default(), "version": info.version.unwrap_or_default(), "adresse": "" }).to_string())
    }

    /// `Kern.serverSearchPause` in milliseconds.
    pub fn server_search_pause(&self) -> i64 {
        i64::from(discovery::PAUSE_SECONDS) * 1000
    }

    /// `Kern.serverSearch`: one round over the host's socket, merged with `known`, without the `except` addresses.
    /// `[{"id","name","adresse","kurz"}]`, sorted by name. Blocks for the listening time: call off the main thread.
    pub fn server_search(
        &self,
        socket: Arc<dyn DatagramHost>,
        interfaces: Vec<DiscoverInterface>,
        known: String,
        except: String,
    ) -> String {
        let before: Vec<discovery::FoundServer> = serde_json::from_str::<Vec<Value>>(&known)
            .unwrap_or_default()
            .iter()
            .filter_map(|v| {
                Some(discovery::FoundServer {
                    id: v.get("id")?.as_str()?.to_owned(),
                    name: v.get("name")?.as_str()?.to_owned(),
                    address: v.get("adresse")?.as_str()?.to_owned(),
                })
            })
            .collect();
        let taken: Vec<String> = serde_json::from_str(&except).unwrap_or_default();
        let taken: Vec<Option<&str>> = taken.iter().map(|a| Some(a.as_str())).collect();
        let now: Vec<discovery::FoundServer> = crate::login::discover(socket, interfaces)
            .into_iter()
            .map(Into::into)
            .collect();
        let shown = discovery::shown(&discovery::merged(&before, &now), &taken);
        Value::Array(
            shown
                .iter()
                .map(|s| {
                    let f = FoundServerInfo::from(s);
                    json!({ "id": f.id, "name": f.name, "adresse": f.address, "kurz": f.short_address })
                })
                .collect(),
        )
        .to_string()
    }

    /// `Kern.publicUser`: who is watching, from the connected or the added server; `[]` when there is none or the list is off.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn public_user(&self, new_server: bool) -> String {
        let Some(t) = self.target(new_server) else {
            return "[]".to_owned();
        };
        let Ok(ServerClient::Jellyfin(c)) = self.client(&t) else {
            return "[]".to_owned();
        };
        let Ok(list) = c.public_users().await else {
            return "[]".to_owned();
        };
        let rows: Vec<Value> = list
            .iter()
            .map(|u| {
                let mut o = json!({ "kennung": u.id, "name": u.name, "aktiv": false });
                if let Some(image) = c.user_image(u, 180) {
                    o["bild"] = Value::String(image.to_string());
                }
                o
            })
            .collect();
        Value::Array(rows).to_string()
    }

    /// Whether the connected or the added server has Quick Connect switched on (only Jellyfin has it).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn quick_connect_offered(&self, new_server: bool) -> bool {
        match self.quick_client(new_server) {
            Some(c) => c.quick_connect_enabled().await,
            None => false,
        }
    }

    /// `Kern.onboardingConnect`: checks a server without touching the session. `{"name","version","adresse"}`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn onboarding_connect(
        &self,
        address: String,
        headers: String,
    ) -> Result<String, CoreError> {
        self.check_address(address, headers, true).await
    }

    /// `Kern.linkUp`: like `onboarding_connect`, but the checked server becomes the connected one (the sign-in goes there).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn link_up(&self, address: String, headers: String) -> Result<String, CoreError> {
        self.check_address(address, headers, false).await
    }

    /// `Kern.sessionApplies`: `false` only when the server refused the token (401/403); no session or no network is "unknown" (`true`).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn session_applies(&self) -> bool {
        let Some(s) = self.held(|h| h.session.clone()) else {
            return true;
        };
        match self.accounts.session_client(&s) {
            Ok(ServerClient::Jellyfin(c)) => c.session_applies_still().await,
            Ok(ServerClient::Plex(c)) => {
                swiftly_playback::media_server::MediaServer::session_applies_still(&*c).await
            }
            Err(_) => true,
        }
    }

    /// `Kern.signOff`: tells the server, then forgets the session here (Kotlin clears the storage).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn sign_off(&self) {
        let session = self.held(|h| {
            h.connected = None;
            h.session.take()
        });
        if let Some(Ok(c)) = session.map(|s| self.accounts.session_client(&s)) {
            c.sign_off().await;
        }
    }

    /// `Kern.quickConnectShare`: approves the code of another device. `""` is done, `nichtAngemeldet` without a session, else the sentence.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn quick_connect_share(&self, code: String) -> String {
        let Some(s) = self.held(|h| h.session.clone()) else {
            return "nichtAngemeldet".to_owned();
        };
        let result = match self.accounts.session_client(&s) {
            Ok(ServerClient::Jellyfin(c)) => c.quick_connect_share(&code).await,
            Ok(ServerClient::Plex(_)) => Err(ErrorKind::NotAuthenticated),
            Err(e) => Err(e),
        };
        match result {
            Ok(()) => String::new(),
            Err(e) => match self.accounts.failed_text(&e) {
                CoreError::Failed { message } => message,
                other => other.to_string(),
            },
        }
    }

    /// `Kern.embyCheck`: `{"result","name","version","adresse","konten":[{"id","name","image"?}],"found"?,"message"?}`; an Emby found is the server being added.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn emby_check(&self, address: String, headers: String) -> String {
        let out = |v: Value| v.to_string();
        let blank = |result: &str| json!({ "result": result, "name": "", "version": "", "adresse": "", "konten": [] });
        let Some(first) = swiftly_jellyfin::normalize_server_url_string(&address) else {
            return out(blank("badAddress"));
        };
        let mut candidates = vec![first];
        if !address.contains("://")
            && let Some(other) = swiftly_jellyfin::reversed_server_url_string(&candidates[0])
        {
            candidates.push(other);
        }
        let own: Vec<swiftly_jellyfin::OwnHeader> =
            serde_json::from_str(&headers).unwrap_or_default();
        let mark = self.mark.fetch_add(1, Ordering::SeqCst) + 1;
        let mut last: Option<ErrorKind> = None;
        for candidate in candidates {
            let url = swiftly_net::Url::parse(&candidate).ok();
            let cleaned = OwnHeaders::cleaned(&own);
            let before = url.as_ref().map(OwnHeaders::registered);
            if let (Some(u), false) = (url.as_ref(), cleaned.is_empty()) {
                OwnHeaders::set_down(&cleaned, u);
            }
            let client = self.accounts.raw_client(&candidate, ServerKind::Emby);
            let answer = match &client {
                Ok(c) => c.check_reachability().await,
                Err(e) => Err(e.clone()),
            };
            let info = match answer {
                Ok(i) => i,
                Err(e) => {
                    if let (Some(u), Some(b), false) = (url.as_ref(), before, cleaned.is_empty()) {
                        OwnHeaders::set_down(&b, u);
                    }
                    let go_on = e.fallback_pays_off();
                    last = Some(e);
                    if !go_on {
                        break;
                    }
                    continue;
                }
            };
            if self.mark.load(Ordering::SeqCst) != mark {
                return out(blank("other"));
            }
            if info.looks_like_jellyfin() {
                let mut o = blank("notEmby");
                o["adresse"] = Value::String(candidate);
                o["found"] = Value::String("Jellyfin".into());
                return out(o);
            }
            self.held(|h| {
                h.onboarding = Some(Target {
                    url: candidate.clone(),
                    kind: ServerKind::Emby,
                })
            });
            let mut users = Vec::new();
            if let Ok(ServerClient::Jellyfin(c)) = &client
                && let Ok(list) = c.public_users().await
            {
                for u in &list {
                    let mut o = json!({ "id": u.id, "name": u.name });
                    if let Some(image) = c.user_image(u, 180) {
                        o["image"] = Value::String(image.to_string());
                    }
                    users.push(o);
                }
            }
            let host = url
                .as_ref()
                .and_then(|u| u.host_str())
                .unwrap_or_default()
                .to_owned();
            return out(json!({
                "result": "ok", "name": info.server_name.unwrap_or(host), "version": info.version.unwrap_or_else(|| "?".into()),
                "adresse": candidate, "konten": users,
            }));
        }
        if let Some(e @ ErrorKind::Transport(swiftly_net::TransportReason::LoginPage)) = &last {
            let message = match self.accounts.failed_text(e) {
                CoreError::Failed { message } => message,
                other => other.to_string(),
            };
            let mut o = blank("other");
            o["message"] = Value::String(message);
            return out(o);
        }
        let mut o = blank("unreachable");
        o["adresse"] = Value::String(address);
        out(o)
    }

    /// `Kern.onboardingCancel`.
    pub fn onboarding_cancel(&self) {
        self.held(|h| {
            h.onboarding = None;
            h.quick = None;
        });
    }

    /// `Kern.onboardingSignIn`: the session as JSON; it becomes active only through `sessionSet`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn onboarding_sign_in(
        &self,
        user: String,
        password: String,
    ) -> Result<String, CoreError> {
        let t = self.target(true).ok_or_else(no_server)?;
        let s = self
            .client(&t)?
            .authenticate(&user, &password)
            .await
            .map_err(|e| self.accounts.failed_text(&e))?;
        Self::session_text(&s)
    }

    /// `Kern.embySignIn`: like `onboarding_sign_in`, only for a server checked as Emby.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn emby_sign_in(&self, user: String, password: String) -> Result<String, CoreError> {
        let t = self
            .target(true)
            .filter(|t| t.kind == ServerKind::Emby)
            .ok_or_else(no_server)?;
        let s = self
            .client(&t)?
            .authenticate(&user, &password)
            .await
            .map_err(|e| self.accounts.failed_text(&e))?;
        Self::session_text(&s)
    }

    /// `Kern.signIn`: at the connected server; the new session is the connected one.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn sign_in(&self, user: String, password: String) -> Result<String, CoreError> {
        let t = self.target(false).ok_or_else(no_server)?;
        let s = self
            .client(&t)?
            .authenticate(&user, &password)
            .await
            .map_err(|e| self.accounts.failed_text(&e))?;
        self.held(|h| {
            h.connected = Some(Target {
                url: s.server_url.clone(),
                kind: s.kind,
            })
        });
        Self::session_text(&s)
    }

    /// `Kern.quickConnectStart`: the short code.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn quick_connect_start(&self, new_server: bool) -> Result<String, CoreError> {
        let c = self.quick_client(new_server).ok_or_else(no_server)?;
        let code = c
            .quick_connect_start()
            .await
            .map_err(|e| self.accounts.failed_text(&e))?;
        let short = code.code.clone();
        self.held(|h| h.quick = Some(code));
        Ok(short)
    }

    /// `Kern.quickConnectWait`: `freigegeben` when approved, empty when cancelled, else the closing sentence.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn quick_connect_wait(&self, new_server: bool) -> String {
        let code = self.held(|h| h.quick.clone());
        let (Some(c), Some(code)) = (self.quick_client(new_server), code) else {
            return swiftly_l10n::error_text::quick_connect_end_text(
                self.accounts.translator(),
                false,
            );
        };
        let stop = Arc::new(AtomicBool::new(false));
        self.held(|h| {
            if let Some((_, old)) = h.wait.take() {
                old.store(true, Ordering::SeqCst);
            }
            h.rest = QuickConnectDeadline::SECONDS as i64;
            h.wait = Some((code.code.clone(), Arc::clone(&stop)));
        });
        let ended = Mutex::new(None::<WaitEvent>);
        let clock = TokioClock(Instant::now());
        c.quick_connect_wait(&code, &clock, |event| match event {
            WaitEvent::Rest(seconds) => {
                self.held(|h| h.rest = seconds);
                !stop.load(Ordering::SeqCst)
            }
            other => {
                *ended.lock().unwrap_or_else(PoisonError::into_inner) = Some(other);
                false
            }
        })
        .await;
        let last = ended.lock().unwrap_or_else(PoisonError::into_inner).take();
        match last {
            Some(WaitEvent::Released) => "freigegeben".to_owned(),
            Some(WaitEvent::End(state)) => {
                self.held(|h| h.rest = 0);
                swiftly_l10n::error_text::quick_connect_end_text(
                    self.accounts.translator(),
                    QuickConnectDeadline::end_is_failure(state),
                )
            }
            _ => String::new(),
        }
    }

    /// `Kern.quickConnectRest`: seconds until the deadline.
    pub fn quick_connect_rest(&self) -> i64 {
        self.held(|h| h.rest)
    }

    /// `Kern.quickConnectWaitEnd`: stops the wait for `code`, if it is still the open one.
    pub fn quick_connect_wait_end(&self, code: String) {
        self.held(|h| {
            if h.wait.as_ref().is_some_and(|(c, _)| *c == code)
                && let Some((_, stop)) = h.wait.take()
            {
                stop.store(true, Ordering::SeqCst);
            }
        });
    }

    /// `Kern.quickConnectSignIn`: the approved code becomes the session (JSON).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn quick_connect_sign_in(&self, new_server: bool) -> Result<String, CoreError> {
        let code = self.held(|h| h.quick.clone());
        let (Some(c), Some(code)) = (self.quick_client(new_server), code) else {
            return Err(no_server());
        };
        let s = c
            .sign_in_with_quick_connect(&code)
            .await
            .map_err(|e| self.accounts.failed_text(&e))?;
        self.held(|h| {
            h.quick = None;
            if !new_server {
                h.connected = Some(Target {
                    url: s.server_url.clone(),
                    kind: s.kind,
                });
            }
        });
        Self::session_text(&s)
    }
}
