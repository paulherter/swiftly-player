//! Plex sign-in for the host: the plex.tv PIN, the account check, Plex Home profiles, the server
//! list and the choice of one address of a server (local, remote, relay; `plex.direct`), then
//! the account is saved. The steps and sentences are the Swift `PlexRun` in
//! `AppModel+Servers.swift`; the screen state is `swiftly_vm::PlexSignInModel` and stays on
//! the host side. Created from the accounts model (`AccountsModel::plex_sign_in`).

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use swiftly_accounts::Account;
use swiftly_net::ErrorKind;
use swiftly_plex::{
    PlexAccount, PlexAccountService, PlexAccountSession, PlexChosenConnection, PlexConnector,
    PlexError, PlexHomeUser, PlexIdentity, PlexPin, PlexServerResource, Sleep, TokenState,
};

use crate::accounts::{AccountsModel, SignedIn};
use crate::error::CoreError;
use crate::transport::ForeignTransport;

/// How long a code lives when plex.tv does not say.
const PIN_LIFETIME: Duration = Duration::from_secs(900);
/// Failures in a row that end the wait (`PlexRun.poll`).
const POLL_FAILURES: u32 = 5;

/// A fresh code and where to confirm it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlexPinInfo {
    /// The short code (shown on a TV, typed at `link_url`).
    pub code: String,
    /// The browser page that confirms the code (`plex.tv/auth#?...`).
    pub auth_url: String,
    /// The same page without `forwardUrl`: the Apple app opens it that way (with a custom scheme
    /// plex.tv landed on its Watch start page; the wait sees the token anyway).
    pub plain_auth_url: String,
    /// The page where the code is typed by hand.
    pub link_url: Option<String>,
    /// Seconds the code lives.
    pub seconds: i64,
}

/// How the wait for the confirmation ended.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PlexWaitEnd {
    /// The user confirmed; call `load_account`.
    Token,
    /// The code ran out or plex.tv forgot it.
    Expired,
    /// Five answers in a row failed; the sentence to show.
    Failed {
        /// What went wrong, readable.
        message: String,
    },
}

/// One profile of the Plex Home.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlexProfile {
    /// The id to hand back to `pick_profile` (the uuid).
    pub id: String,
    /// Name.
    pub name: String,
    /// Picture address.
    pub image: Option<String>,
    /// Asks for a PIN.
    pub protected: bool,
}

/// The account behind the token.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlexAccountInfo {
    /// The account name.
    pub name: String,
    /// Its picture.
    pub thumb: Option<String>,
    /// More than one profile: show the choice. Otherwise the only one is taken and the host
    /// goes on to `servers`.
    pub profiles: Vec<PlexProfile>,
}

/// After `load_account`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PlexAccountEnd {
    /// The token works.
    Ready {
        /// The account.
        info: PlexAccountInfo,
    },
    /// plex.tv does not know the token (the sign-in counts as expired).
    Expired,
}

/// After `pick_profile`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlexProfileEnd {
    /// The profile is in use; go on to `servers`.
    Accepted,
    /// The PIN is wrong (or a profile without one is refused).
    PinWrong,
}

/// One server of the account.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlexServerOption {
    /// The machine identifier; hand it to `connect`.
    pub id: String,
    /// Name.
    pub name: String,
    /// Who shares it; `None` when the account owns it.
    pub shared_by: Option<String>,
    /// Has an address on the home network.
    pub local: bool,
    /// plex.tv sees it online.
    pub online: bool,
}

/// One address of a server that answered.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlexRouteInfo {
    /// The address.
    pub uri: String,
    /// On the home network.
    pub is_local: bool,
    /// A relay.
    pub is_relay: bool,
    /// The token that opens the server at this address (the server's own, else the account's).
    pub token: String,
}

impl PlexRouteInfo {
    fn of(c: PlexChosenConnection, token: &str) -> Self {
        Self {
            uri: c.uri,
            is_local: c.is_local,
            is_relay: c.is_relay,
            token: token.to_owned(),
        }
    }
}

/// After `connect`.
#[allow(clippy::large_enum_variant)] // exported across uniffi as is; boxing would change the host type
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum PlexConnectEnd {
    /// An address answered; the account is saved and active.
    Connected {
        /// The account.
        signed_in: SignedIn,
        /// The address in use.
        route: PlexRouteInfo,
    },
    /// No address of the server answered.
    Unreachable,
}

/// The host hears the seconds left once a second while the code is open.
#[uniffi::export(with_foreign)]
pub trait PlexPinListener: Send + Sync {
    /// Seconds until the code runs out.
    fn rest(&self, seconds: i64);
}

#[derive(Default)]
struct Held {
    pin: Option<PlexPin>,
    expires: Option<Instant>,
    account_token: Option<String>,
    account: Option<PlexAccount>,
    home_users: Vec<PlexHomeUser>,
    profile: Option<PlexHomeUser>,
    profile_token: Option<String>,
    servers: Vec<PlexServerResource>,
    /// The last failure that was turned into a sentence did not reach plex.tv at all (a network or
    /// certificate failure): the screen shows its own "plex.tv not reachable" page for it.
    unreachable: bool,
}

/// The Plex sign-in of one screen. One object per sign-in; `start` begins again.
#[derive(uniffi::Object)]
pub struct PlexSignIn {
    accounts: Arc<AccountsModel>,
    transport: Arc<ForeignTransport>,
    identity: PlexIdentity,
    service: PlexAccountService<ForeignTransport>,
    held: Mutex<Held>,
}

fn sleeper() -> Sleep {
    Arc::new(|d| Box::pin(tokio::time::sleep(d)))
}

impl PlexSignIn {
    pub(crate) fn build(
        accounts: Arc<AccountsModel>,
        transport: Arc<ForeignTransport>,
        identity: PlexIdentity,
        base: Option<&str>,
    ) -> Arc<Self> {
        // `base` (tests and debug builds only) stands in for plex.tv, clients.plex.tv and app.plex.tv.
        let service = match base {
            Some(b) => {
                PlexAccountService::with_bases(identity.clone(), Arc::clone(&transport), b, b, b)
            }
            None => PlexAccountService::new(identity.clone(), Arc::clone(&transport)),
        };
        Arc::new(Self {
            service,
            accounts,
            transport,
            identity,
            held: Mutex::new(Held::default()),
        })
    }

    fn held<R>(&self, f: impl FnOnce(&mut Held) -> R) -> R {
        f(&mut self
            .held
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner))
    }

    /// The readable sentence of a failure (`app.readable`).
    fn readable(&self, error: &PlexError) -> String {
        let unreachable = matches!(
            error,
            PlexError::Request(
                ErrorKind::Network { .. } | ErrorKind::Certificate(_) | ErrorKind::Transport(_)
            )
        );
        self.held(|h| h.unreachable = unreachable);
        let tr = self.accounts.translator();
        match error.text_key() {
            Some(key) => tr.t(key),
            None => match error {
                PlexError::Request(kind) => swiftly_l10n::error_text::readable_error(tr, kind),
                other => format!("{other:?}"),
            },
        }
    }

    fn failed(&self, error: &PlexError) -> CoreError {
        CoreError::Failed {
            message: self.readable(error),
        }
    }

    fn token_of(&self) -> Result<String, CoreError> {
        self.held(|h| h.account_token.clone())
            .ok_or_else(|| CoreError::Failed {
                message: "not signed in at plex.tv".to_owned(),
            })
    }

    /// The token that asks plex.tv for servers: the profile's, else the account's.
    fn servers_token(&self) -> Result<String, CoreError> {
        self.held(|h| h.profile_token.clone().or_else(|| h.account_token.clone()))
            .ok_or_else(|| CoreError::Failed {
                message: "not signed in at plex.tv".to_owned(),
            })
    }

    async fn probe_route(
        &self,
        server: &PlexServerResource,
        token: &str,
        remembered: Option<&PlexChosenConnection>,
    ) -> Result<PlexChosenConnection, PlexError> {
        let connector = PlexConnector::with_transport(
            Arc::clone(&self.transport),
            self.identity.clone(),
            token.to_owned(),
            server.machine_identifier.clone(),
            Duration::from_secs(3),
            sleeper(),
        );
        connector.choose(server, remembered).await
    }
}

#[uniffi::export]
impl AccountsModel {
    /// The Plex sign-in of this installation. `client_id` is the stable id Plex knows the
    /// installation by (lower-case UUID); `platform` is `iOS`, `tvOS`, `macOS`, `Android`,
    /// `Linux` or `Windows`.
    pub fn plex_sign_in(
        self: Arc<Self>,
        client_id: String,
        app_version: String,
        platform: String,
        device: String,
        device_name: String,
    ) -> Arc<PlexSignIn> {
        let identity =
            PlexIdentity::new(&client_id, &app_version, &platform, &device, &device_name);
        let transport = self.transport();
        PlexSignIn::build(self, transport, identity, None)
    }
}

#[uniffi::export]
impl PlexSignIn {
    /// Makes a code. `strong` is the long browser code; a TV shows the short one (`false`).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn start(&self, strong: bool) -> Result<PlexPinInfo, CoreError> {
        let pin = self
            .service
            .start_pin(strong)
            .await
            .map_err(|e| self.failed(&e))?;
        let life = pin
            .expires_in
            .and_then(|s| u64::try_from(s).ok())
            .map_or(PIN_LIFETIME, Duration::from_secs);
        let auth_url = self
            .service
            .auth_url(&pin, Some("swiftly://"))
            .map(|u| u.to_string())
            .ok_or_else(|| CoreError::Failed {
                message: "no auth address".to_owned(),
            })?;
        let plain_auth_url = self
            .service
            .auth_url(&pin, None)
            .map(|u| u.to_string())
            .ok_or_else(|| CoreError::Failed {
                message: "no auth address".to_owned(),
            })?;
        let info = PlexPinInfo {
            code: pin.code.clone(),
            auth_url,
            plain_auth_url,
            link_url: self.service.link_page().map(|u| u.to_string()),
            seconds: i64::try_from(life.as_secs()).unwrap_or(i64::MAX),
        };
        self.held(|h| {
            *h = Held {
                pin: Some(pin),
                expires: Some(Instant::now() + life),
                ..Held::default()
            }
        });
        Ok(info)
    }

    /// Asks about the code once (the browser window closed: look now, not at the next beat).
    /// `true` when the token is there.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn check_now(&self) -> Result<bool, CoreError> {
        let Some(pin) = self.held(|h| h.pin.clone()) else {
            return Ok(false);
        };
        let checked = self
            .service
            .check_pin(&pin)
            .await
            .map_err(|e| self.failed(&e))?;
        Ok(self.take_token(checked))
    }

    /// About once a second until the token is there or the code is gone; the listener hears the
    /// seconds left. A hiccup does not end it, five answers in a row do; 404 and 410 mean
    /// the code is forgotten. Dropping the call (cancelling the task) stops it.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn wait_for_token(
        &self,
        listener: Arc<dyn PlexPinListener>,
    ) -> Result<PlexWaitEnd, CoreError> {
        Ok(self.wait_for_token_end(listener).await)
    }

    /// With the token: the account (`GET /api/v2/user`) and the Home profiles. With one profile
    /// or none it is taken at once and the host goes on to `servers`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_account(&self) -> Result<PlexAccountEnd, CoreError> {
        let token = self.token_of()?;
        let account = match self
            .service
            .validate(&token)
            .await
            .map_err(|e| self.failed(&e))?
        {
            TokenState::Valid(account) => account,
            TokenState::Invalid => return Ok(PlexAccountEnd::Expired),
        };
        let users = self.service.home_users(&token).await.unwrap_or_default();
        let profiles: Vec<PlexProfile> = if users.len() > 1 {
            users
                .iter()
                .map(|u| PlexProfile {
                    id: u.uuid.clone(),
                    name: u.title.clone(),
                    image: u.thumb.clone(),
                    protected: u.is_protected,
                })
                .collect()
        } else {
            Vec::new()
        };
        let info = PlexAccountInfo {
            name: account.title.clone(),
            thumb: account.thumb.clone(),
            profiles,
        };
        self.held(|h| {
            if users.len() <= 1 {
                h.profile = users.first().cloned();
                h.profile_token = Some(token.clone());
            }
            h.account = Some(account);
            h.home_users = users;
        });
        Ok(PlexAccountEnd::Ready { info })
    }

    /// Takes a profile, with its PIN when it has one. A wrong PIN is an answer, not an error.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn pick_profile(
        &self,
        id: String,
        pin: Option<String>,
    ) -> Result<PlexProfileEnd, CoreError> {
        let token = self.token_of()?;
        let Some(user) = self.held(|h| h.home_users.iter().find(|u| u.uuid == id).cloned()) else {
            return Err(CoreError::Failed {
                message: "unknown profile".to_owned(),
            });
        };
        match self
            .service
            .switch_user(&user, pin.as_deref(), &token)
            .await
        {
            Ok(profile_token) => {
                self.held(|h| {
                    h.profile = Some(user);
                    h.profile_token = Some(profile_token);
                });
                Ok(PlexProfileEnd::Accepted)
            }
            Err(PlexError::ProfilePinWrong) => Ok(PlexProfileEnd::PinWrong),
            Err(e) => Err(self.failed(&e)),
        }
    }

    /// The servers of the account. An account with none is an empty list, not an error.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn servers(&self) -> Result<Vec<PlexServerOption>, CoreError> {
        let token = self.servers_token()?;
        let found = match self.service.servers(&token).await {
            Ok(found) => found,
            Err(PlexError::NoServer) => Vec::new(),
            Err(e) => return Err(self.failed(&e)),
        };
        let other = self.accounts.translator().t("einem anderen Konto");
        let options = found
            .iter()
            .map(|s| PlexServerOption {
                id: s.machine_identifier.clone(),
                name: s.name.clone(),
                shared_by: (!s.owned)
                    .then(|| s.source_title.clone().unwrap_or_else(|| other.clone())),
                local: s.connections.iter().any(|c| c.is_local),
                online: s.presence,
            })
            .collect();
        self.held(|h| h.servers = found);
        Ok(options)
    }

    /// Picks the address that answers (the best-ranked one, not the fastest), then signs in at
    /// that server and saves the account. A failure within two seconds is tried once more after
    /// a moment (the local-network question of the system may still be on the screen).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn connect(&self, server_id: String) -> Result<PlexConnectEnd, CoreError> {
        match self.connect_account(&server_id).await? {
            Some((account, connection, key)) => {
                let signed_in = self.accounts.adopt_account(account);
                Ok(PlexConnectEnd::Connected {
                    signed_in,
                    route: PlexRouteInfo::of(connection, &key),
                })
            }
            None => Ok(PlexConnectEnd::Unreachable),
        }
    }
}

impl PlexSignIn {
    /// The shared part of `connect`: the account to save, the address that answered and the key that opens it.
    /// Saves nothing (the legacy Android facade hands the account to the host as a session instead).
    pub(crate) async fn connect_account(
        &self,
        server_id: &str,
    ) -> Result<Option<(Account, PlexChosenConnection, String)>, CoreError> {
        let account_token = self.token_of()?;
        let profile_token = self
            .held(|h| h.profile_token.clone())
            .unwrap_or_else(|| account_token.clone());
        let Some(server) = self.held(|h| {
            h.servers
                .iter()
                .find(|s| s.machine_identifier == *server_id)
                .cloned()
        }) else {
            return Err(CoreError::Failed {
                message: "unknown server".to_owned(),
            });
        };
        // The server's own token opens it; the profile's token asks plex.tv.
        let key = server
            .access_token
            .clone()
            .unwrap_or_else(|| profile_token.clone());
        let started = Instant::now();
        let mut chosen = self.probe_route(&server, &key, None).await;
        if chosen.is_err() && started.elapsed() < Duration::from_secs(2) {
            tokio::time::sleep(Duration::from_millis(1500)).await;
            chosen = self.probe_route(&server, &key, None).await;
        }
        let Ok(connection) = chosen else {
            return Ok(None);
        };
        let (profile, account) = self.held(|h| (h.profile.clone(), h.account.clone()));
        let user_id = profile
            .as_ref()
            .map(|p| p.id.clone())
            .or_else(|| account.as_ref().map(|a| a.id.clone()));
        let user_name = profile
            .as_ref()
            .map(|p| p.title.clone())
            .or_else(|| account.as_ref().map(|a| a.title.clone()));
        let image = profile
            .as_ref()
            .and_then(|p| p.thumb.clone())
            .or_else(|| account.as_ref().and_then(|a| a.thumb.clone()));
        let session = PlexAccountSession::from_server(
            &server,
            &connection,
            &profile_token,
            &user_id.unwrap_or_default(),
            &user_name.unwrap_or_default(),
            profile.as_ref().map(|p| p.uuid.as_str()),
            image.as_deref(),
        );
        Ok(Some((
            Account {
                session: session.session,
                plex: session.plex,
            },
            connection,
            key,
        )))
    }
}

#[uniffi::export]
impl PlexSignIn {
    /// The best address of a server the account already uses, for a start or a change of network:
    /// asks plex.tv for the server's addresses with `account_token`, tries the remembered one
    /// first and alone, then all of them. `None` when nothing answers; an error with the sentence "no server" when plex.tv does not list the server.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn best_route(
        &self,
        account_token: String,
        machine_identifier: String,
        remembered: Option<String>,
    ) -> Result<Option<PlexRouteInfo>, CoreError> {
        let servers = self
            .service
            .servers(&account_token)
            .await
            .map_err(|e| self.failed(&e))?;
        let Some(server) = servers
            .into_iter()
            .find(|s| s.machine_identifier == machine_identifier)
        else {
            // plex.tv lists no such server for this account: the old `PlexError.noServer`.
            let message = self
                .accounts
                .translator()
                .t("Zu diesem Plex-Konto gehört kein Server.");
            return Err(CoreError::Failed { message });
        };
        let key = server.access_token.clone().unwrap_or(account_token);
        let known = remembered.and_then(|uri| {
            server
                .connections
                .iter()
                .find(|c| c.uri == uri)
                .map(|c| PlexChosenConnection {
                    machine_identifier: machine_identifier.clone(),
                    uri: c.uri.clone(),
                    is_local: c.is_local,
                    is_relay: c.is_relay,
                })
        });
        Ok(self
            .probe_route(&server, &key, known.as_ref())
            .await
            .ok()
            .map(|c| PlexRouteInfo::of(c, &key)))
    }

    /// Whether the last failure (a thrown error or `PlexWaitEnd::Failed`) was a network or
    /// certificate failure: the host shows "plex.tv not reachable" instead of the sentence.
    pub fn last_failure_unreachable(&self) -> bool {
        self.held(|h| h.unreachable)
    }

    /// Forgets everything held (another account): the next step is `start` again.
    pub fn reset(&self) {
        self.held(|h| *h = Held::default());
    }
}

impl PlexSignIn {
    async fn wait_for_token_end(&self, listener: Arc<dyn PlexPinListener>) -> PlexWaitEnd {
        let (Some(pin), Some(expires)) = self.held(|h| (h.pin.clone(), h.expires)) else {
            return PlexWaitEnd::Expired;
        };
        let mut failures = 0;
        loop {
            let left = expires.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return PlexWaitEnd::Expired;
            }
            listener.rest(i64::try_from(left.as_secs_f64().ceil() as u64).unwrap_or(i64::MAX));
            match self.service.check_pin(&pin).await {
                Ok(checked) => {
                    if self.take_token(checked) {
                        return PlexWaitEnd::Token;
                    }
                    failures = 0;
                }
                Err(
                    PlexError::Request(ErrorKind::Http {
                        status: 404 | 410, ..
                    })
                    | PlexError::PinExpired,
                ) => {
                    return PlexWaitEnd::Expired;
                }
                Err(error) => {
                    failures += 1;
                    if failures >= POLL_FAILURES {
                        return PlexWaitEnd::Failed {
                            message: self.readable(&error),
                        };
                    }
                }
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }

    /// Keeps the token when the checked code carries one.
    fn take_token(&self, checked: PlexPin) -> bool {
        match checked.auth_token.filter(|t| !t.is_empty()) {
            Some(token) => {
                self.held(|h| h.account_token = Some(token));
                true
            }
            None => false,
        }
    }
}

mod legacy;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stores::SecretStore;
    use crate::transport::{HttpClient, HttpFailure, NetRequest, NetResponse};
    use std::collections::HashMap;
    use swiftly_jellyfin::ServerKind;
    use swiftly_l10n::Locale;
    use swiftly_vm::{Host, Spawner, SystemClock};

    const PIN_FRESH: &str = include_str!("../../swiftly-plex/tests/fixtures/pin_fresh.json");
    const PIN_DONE: &str = include_str!("../../swiftly-plex/tests/fixtures/pin_done.json");
    const HOME_USERS: &str = include_str!("../../swiftly-plex/tests/fixtures/home_users.json");
    const RESOURCES: &str = include_str!("../../swiftly-plex/tests/fixtures/resources.json");
    const IDENTITY: &str = include_str!("../../swiftly-plex/tests/fixtures/identity.json");

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
    impl SecretStore for Secrets {
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

    /// plex.tv and one server: only the home address 192.168.1.5 answers, the rest is down.
    struct World {
        confirmed: Mutex<bool>,
    }
    #[async_trait::async_trait]
    impl HttpClient for World {
        async fn send(&self, request: NetRequest) -> Result<NetResponse, HttpFailure> {
            let url = swiftly_net::Url::parse(&request.url).unwrap();
            let reply = |status: u16, body: &str| {
                Ok(NetResponse {
                    status,
                    headers: vec![],
                    body: body.as_bytes().to_vec(),
                    url: None,
                })
            };
            match (url.host_str().unwrap_or_default(), url.path()) {
                ("192.168.1.5", "/identity") => reply(200, IDENTITY),
                ("clients.plex.tv" | "plex.tv", path) => match path {
                    "/api/v2/pins" => reply(201, PIN_FRESH),
                    "/api/v2/pins/4711" => {
                        let done = std::mem::replace(&mut *self.confirmed.lock().unwrap(), true);
                        if done {
                            reply(200, PIN_DONE)
                        } else {
                            reply(200, PIN_FRESH)
                        }
                    }
                    "/api/v2/user" => reply(
                        200,
                        r#"{"id":7,"uuid":"u7","title":"paulplex","thumb":"https://t/p.png"}"#,
                    ),
                    "/api/v2/home/users" => reply(200, HOME_USERS),
                    "/api/v2/home/users/uuid-kid/switch" if url.query() == Some("pin=1234") => {
                        reply(201, r#"{"authToken":"KIDTOKEN"}"#)
                    }
                    "/api/v2/home/users/uuid-kid/switch" => reply(401, ""),
                    "/api/v2/resources" => reply(200, RESOURCES),
                    _ => reply(404, ""),
                },
                _ => Err(HttpFailure::Network { code: -1004 }),
            }
        }
    }

    struct Hears(Mutex<Vec<i64>>);
    impl PlexPinListener for Hears {
        fn rest(&self, seconds: i64) {
            self.0.lock().unwrap().push(seconds);
        }
    }

    fn sign_in(secrets: Arc<Secrets>) -> (Arc<PlexSignIn>, Arc<AccountsModel>) {
        let host = Host {
            spawner: Arc::new(Spawn),
            clock: Arc::new(SystemClock),
            store: Arc::new(NoStore),
            locale: Locale::parse("en"),
            device_name: "test".into(),
            client_version: "1".into(),
            cache: None,
        };
        let world = World {
            confirmed: Mutex::new(false),
        };
        let accounts = AccountsModel::build(
            secrets,
            ForeignTransport(Arc::new(world)),
            host,
            "dev".into(),
            "en",
        );
        let s = Arc::clone(&accounts).plex_sign_in(
            "cid".into(),
            "1.0".into(),
            "macOS".into(),
            "Mac".into(),
            "Paul's Mac".into(),
        );
        (s, accounts)
    }

    #[tokio::test]
    async fn pin_profiles_server_and_the_saved_plex_account() {
        let secrets = Arc::new(Secrets::default());
        let (s, accounts) = sign_in(Arc::clone(&secrets));
        let pin = s.start(true).await.unwrap();
        assert_eq!(pin.code, "ABCD1234");
        assert!(
            pin.auth_url
                .starts_with("https://app.plex.tv/auth#?clientID=cid&code=ABCD1234"),
            "{}",
            pin.auth_url
        );
        assert_eq!(pin.seconds, 1800);
        assert!(
            !pin.plain_auth_url.contains("forwardUrl")
                && pin.plain_auth_url.contains("code=ABCD1234")
        );

        let hears = Arc::new(Hears(Mutex::new(Vec::new())));
        // The first beat is "not yet", the second brings the token; the wait sleeps one second.
        assert_eq!(
            s.wait_for_token(Arc::clone(&hears) as Arc<dyn PlexPinListener>)
                .await
                .unwrap(),
            PlexWaitEnd::Token
        );
        assert_eq!(hears.0.lock().unwrap().len(), 2);

        let PlexAccountEnd::Ready { info } = s.load_account().await.unwrap() else {
            panic!("expired")
        };
        assert_eq!(info.name, "paulplex");
        assert_eq!(info.profiles.len(), 2, "two profiles: the user picks");
        assert_eq!(
            s.pick_profile("uuid-kid".into(), None).await.unwrap(),
            PlexProfileEnd::PinWrong
        );
        assert_eq!(
            s.pick_profile("uuid-kid".into(), Some("0000".into()))
                .await
                .unwrap(),
            PlexProfileEnd::PinWrong
        );
        assert_eq!(
            s.pick_profile("uuid-kid".into(), Some("1234".into()))
                .await
                .unwrap(),
            PlexProfileEnd::Accepted
        );

        let servers = s.servers().await.unwrap();
        assert_eq!(
            servers.iter().map(|x| x.name.as_str()).collect::<Vec<_>>(),
            ["Home", "Friend"]
        );
        assert!(servers[0].local && servers[0].shared_by.is_none());
        assert!(servers[1].shared_by.is_some());

        let PlexConnectEnd::Connected { signed_in, route } =
            s.connect("MACHINE1".into()).await.unwrap()
        else {
            panic!("unreachable")
        };
        assert_eq!(route.uri, "http://192.168.1.5:32400");
        assert!(route.is_local && !route.is_relay);
        assert_eq!(signed_in.account.token, "SERVERTOKEN");
        assert_eq!(signed_in.account.server_kind, ServerKind::Plex);
        assert_eq!(signed_in.account.user_id, "2");
        let stored = secrets.get("konten.plex".into()).expect("plex bundle");
        assert!(
            stored.contains("MACHINE1") && stored.contains("KIDTOKEN"),
            "{stored}"
        );
        assert_eq!(accounts.accounts().len(), 1);

        // Failing over later: the remembered address goes first and alone.
        let best = s
            .best_route(
                "ACCOUNTTOKEN".into(),
                "MACHINE1".into(),
                Some(route.uri.clone()),
            )
            .await
            .unwrap();
        let best = best.unwrap();
        assert_eq!(best.uri, route.uri);
        assert_eq!(
            best.token, "SERVERTOKEN",
            "the token that opens the server goes with the address"
        );
        // The server moved: the remembered address is gone from plex.tv's list, the live one is found anyway.
        let healed = s
            .best_route(
                "ACCOUNTTOKEN".into(),
                "MACHINE1".into(),
                Some("http://10.9.9.9:32400".into()),
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            (healed.uri.as_str(), healed.token.as_str()),
            (route.uri.as_str(), "SERVERTOKEN")
        );
        match s
            .best_route("ACCOUNTTOKEN".into(), "NOPE".into(), None)
            .await
        {
            Err(CoreError::Failed { message }) => {
                assert_eq!(message, "This Plex account has no server.")
            }
            other => panic!("{other:?}"),
        }

        // A change of network keeps the new address and token in the saved account; it stays active.
        let key = accounts.accounts()[0].key.clone();
        let moved = PlexRouteInfo {
            uri: "https://relay.plex.direct:443".into(),
            is_local: false,
            is_relay: true,
            token: "OTHERTOKEN".into(),
        };
        assert!(accounts.move_plex_route(key.clone(), moved));
        assert!(!accounts.move_plex_route(
            "plex:NOPE|9".into(),
            PlexRouteInfo {
                uri: String::new(),
                is_local: false,
                is_relay: false,
                token: String::new()
            }
        ));
        let stored = secrets.get("konten.plex".into()).expect("plex bundle");
        assert!(
            stored.contains("relay.plex.direct")
                && stored.contains("OTHERTOKEN")
                && stored.contains("MACHINE1"),
            "{stored}"
        );
        assert_eq!(accounts.accounts().len(), 1);
        assert_eq!(
            accounts.accounts()[0].key,
            key,
            "the machine, not the address, names the account"
        );
        assert!(accounts.accounts()[0].active);
        assert_eq!(accounts.active().unwrap().token, "OTHERTOKEN");
    }

    #[tokio::test]
    async fn a_network_failure_is_flagged_as_unreachable() {
        let (s, _) = sign_in(Arc::new(Secrets::default()));
        assert!(!s.last_failure_unreachable());
        // `check_now` before `start` has nothing to ask; the world answers `-1004` for unknown hosts.
        s.start(true).await.unwrap();
        s.reset();
        assert!(s.load_account().await.is_err());
        assert!(
            !s.last_failure_unreachable(),
            "no token yet is not a network failure"
        );
    }

    #[tokio::test]
    async fn a_server_nobody_answers_for_is_unreachable_not_an_error() {
        let (s, _) = sign_in(Arc::new(Secrets::default()));
        s.start(true).await.unwrap();
        assert!(!s.check_now().await.unwrap());
        assert!(s.check_now().await.unwrap());
        s.load_account().await.unwrap();
        // Two profiles but none picked: servers come from the account token.
        let servers = s.servers().await.unwrap();
        assert_eq!(servers.len(), 2);
        // MACHINE2 has no address at all.
        assert_eq!(
            s.connect("MACHINE2".into()).await.unwrap(),
            PlexConnectEnd::Unreachable
        );
        assert!(s.connect("UNKNOWN".into()).await.is_err());
    }

    #[tokio::test]
    async fn the_old_json_steps() {
        use serde_json::Value;
        let (s, _) = sign_in(Arc::new(Secrets::default()));
        let l = legacy::LegacyPlexSignIn::over(Arc::clone(&s));
        let j = |t: String| serde_json::from_str::<Value>(&t).unwrap();
        // Before a start there is nothing to look at.
        assert_eq!(
            j(l.poll().await),
            serde_json::json!({"step":"waiting","secondsLeft":0})
        );
        let w = j(l.start_tv().await);
        assert_eq!(w["step"], "waiting");
        assert_eq!(w["secondsLeft"], 1800);
        assert_eq!(w["code"], "ABCD1234");
        assert_eq!(w["url"], "https://plex.tv/link");
        let w = j(l.start().await);
        assert!(
            w["url"]
                .as_str()
                .unwrap()
                .starts_with("https://app.plex.tv/auth#?clientID=cid&code=ABCD1234")
        );
        assert!(!w["url"].as_str().unwrap().contains("forwardUrl") && w.get("code").is_none());
        // First look: not confirmed yet. Second: the token, then the two profiles in the same answer.
        let p = j(l.poll().await);
        assert_eq!(p["step"], "waiting");
        assert!(p["secondsLeft"].as_i64().unwrap() > 1700);
        let p = j(l.poll().await);
        assert_eq!(p["step"], "profiles");
        assert_eq!(p["account"], "paulplex");
        assert_eq!(p["profiles"].as_array().unwrap().len(), 2);
        assert_eq!(
            j(l.poll().await)["secondsLeft"],
            0,
            "handled: nothing to add"
        );
        assert_eq!(
            j(l.pick_profile("nobody".into(), String::new()).await),
            serde_json::json!({"step":"failed"})
        );
        assert_eq!(
            j(l.pick_profile("uuid-kid".into(), "0000".into()).await),
            serde_json::json!({"step":"pinWrong"})
        );
        assert_eq!(
            j(l.pick_profile("uuid-kid".into(), String::new()).await)["step"],
            "failed",
            "refused without a PIN: back to the list"
        );
        let v = j(l.pick_profile("uuid-kid".into(), "1234".into()).await);
        assert_eq!(v["step"], "servers");
        assert_eq!(v["account"], "paulplex");
        assert!(v["profile"].is_string());
        let list = v["servers"].as_array().unwrap();
        assert_eq!(
            list[0],
            serde_json::json!({"id":"MACHINE1","name":"Home","local":true,"online":true})
        );
        assert!(list[1]["sharedBy"].is_string());
        assert_eq!(j(l.servers().await)["servers"].as_array().unwrap().len(), 2);
        assert_eq!(
            j(l.pick_server("MACHINE2".into()).await),
            serde_json::json!({"step":"unreachable"})
        );
        assert_eq!(
            j(l.pick_server("NOPE".into()).await),
            serde_json::json!({"step":"failed"})
        );
        let done = j(l.pick_server("MACHINE1".into()).await);
        assert_eq!(done["step"], "done");
        let session = j(done["session"].as_str().unwrap().to_owned());
        assert_eq!(session["accessToken"], "SERVERTOKEN");
        assert_eq!(session["plex"]["machineIdentifier"], "MACHINE1");
        assert_eq!(session["plex"]["accountToken"], "KIDTOKEN");
        assert!(
            session["serverURL"]
                .as_str()
                .unwrap()
                .contains("192.168.1.5"),
            "{session}"
        );
        l.reset();
        assert_eq!(j(l.servers().await), serde_json::json!({"step":"failed"}));
    }
}
