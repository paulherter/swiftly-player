//! The accounts model: saved accounts, sign-in, Quick Connect (with the wait loop), an extra
//! server, switch and remove. Over the host's secret store with the same keys and JSON as the
//! Swift `ServerBundles` (`konten`, `konten.emby`, `konten.plex`, `aktiveArt`).

use std::sync::{Arc, Mutex};
use std::time::Instant;

use swiftly_accounts::{
    Account, ServerBundles, add_account, load_bundles, save_bundles, sign_out_revoked,
};
use swiftly_jellyfin::{
    LoginCode, QuickConnectDeadline, ServerKind, Session, WaitClock, WaitEvent,
};
use swiftly_l10n::error_text::readable_error;
use swiftly_l10n::{Locale, Translator};
use swiftly_model::PublicSystemInfo;
use swiftly_net::ErrorKind;
use swiftly_vm::{AccountRef, Host, ServerClient, make_client, make_signed_out_client};

use crate::error::CoreError;
use crate::plex_sign_in::PlexRouteInfo;
use crate::stores::SecretStore;
use crate::transport::ForeignTransport;

/// One saved account, without its token.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountInfo {
    /// `Session.accountKey`: server and user together.
    pub key: String,
    /// The user name.
    pub user_name: String,
    /// The user id on the server.
    pub user_id: String,
    /// The server address.
    pub server_url: String,
    /// Jellyfin, Emby or Plex.
    pub kind: ServerKind,
    /// The account in use.
    pub active: bool,
    /// Which server it belongs to (accounts on one server share it).
    pub server_identity: String,
}

/// What the server said about itself (the address check).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ServerCheck {
    /// Display name.
    pub name: Option<String>,
    /// Version.
    pub version: Option<String>,
    /// Server id.
    pub id: Option<String>,
    /// The server offers Quick Connect.
    pub quick_connect: bool,
    /// Users to pick from, if the server lists them: `(id, name)` pairs.
    pub public_users: Vec<PublicUserInfo>,
}

/// A user from the server's public list.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PublicUserInfo {
    /// User id.
    pub id: String,
    /// User name.
    pub name: String,
}

/// A Quick Connect code to show.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QuickCode {
    /// The short code to type on the other device.
    pub code: String,
    /// The secret for polling and sign-in.
    pub confidential: String,
}

/// The result of a sign-in.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SignedIn {
    /// The account now active (with its token, for the view models).
    pub account: AccountRef,
    /// There already was an account of this kind: a switch, not a first sign-in.
    pub was_switch: bool,
    /// The account lives at a server no stored account belonged to (an extra server).
    pub new_server: bool,
}

/// What the Quick Connect wait ended with.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct QuickEnd {
    /// Set when the code was approved and the sign-in worked.
    pub signed_in: Option<SignedIn>,
    /// The closing sentence when it did not (expired, failed).
    pub message: Option<String>,
}

/// What a revoked account switched to.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RevokedInfo {
    /// The user name that was dropped.
    pub dropped_name: String,
    /// The user name active now, if any is left.
    pub now_name: Option<String>,
    /// The key active now.
    pub now_key: Option<String>,
}

/// What the server says about an account (`accountDefaults`, `GET Users/{id}`). When the server
/// did not answer, `answered` is false and the other fields hold what the apps assume then:
/// downloads `unbekannt` (allowed), conversion allowed, quality choice offered.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountDefaultsInfo {
    /// The server answered.
    pub answered: bool,
    /// `Configuration.EnableNextEpisodeAutoPlay`; `None` if the server says nothing.
    pub next_episode_automatic: Option<bool>,
    /// The download permission as the Swift raw value: `unbekannt`, `erlaubt` or `verboten`.
    pub download_permission: String,
    /// Video conversion is allowed for the account.
    pub convert_allowed: bool,
    /// A smaller quality may be offered when downloading.
    pub download_quality_selectable: bool,
}

/// The host hears the seconds left once per second.
#[uniffi::export(with_foreign)]
pub trait QuickConnectListener: Send + Sync {
    /// Seconds until the code runs out.
    fn rest(&self, seconds: i64);
}

/// How long a sign-out waits for the server's answer before it gives up (the old apps fired the
/// request and did not wait at all).
const SIGN_OFF_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

/// The one edge length of every avatar (`AppModel.userImageEdge`): one address, one cache entry.
const AVATAR_EDGE: i64 = 480;

pub(crate) struct TokioClock(pub(crate) Instant);

impl WaitClock for TokioClock {
    fn now(&self) -> f64 {
        self.0.elapsed().as_secs_f64()
    }
    async fn sleep(&self, seconds: f64) {
        tokio::time::sleep(crate::support::wait_duration(seconds)).await;
    }
}

struct SecretsAdapter(Arc<dyn SecretStore>);

impl swiftly_accounts::SecretStore for SecretsAdapter {
    fn get(&self, name: &str) -> Option<String> {
        self.0.get(name.to_owned())
    }
    fn set(&self, name: &str, value: &str) {
        self.0.set(name.to_owned(), value.to_owned());
    }
    fn remove(&self, name: &str) {
        self.0.remove(name.to_owned());
    }
}

/// Saved accounts and every way to add one.
#[derive(uniffi::Object)]
pub struct AccountsModel {
    secrets: SecretsAdapter,
    bundles: Mutex<ServerBundles>,
    transport: Arc<ForeignTransport>,
    host: Host,
    device_id: String,
    translator: Translator,
}

impl AccountsModel {
    pub(crate) fn build(
        secrets: Arc<dyn SecretStore>,
        transport: ForeignTransport,
        host: Host,
        device_id: String,
        locale: &str,
    ) -> Arc<Self> {
        let secrets = SecretsAdapter(secrets);
        let bundles = load_bundles(&secrets);
        Arc::new(Self {
            secrets,
            bundles: Mutex::new(bundles),
            transport: Arc::new(transport),
            host,
            device_id,
            translator: Translator::new(Locale::parse(locale)),
        })
    }

    pub(crate) fn failed_text(&self, error: &ErrorKind) -> CoreError {
        self.failed(error)
    }

    fn failed(&self, error: &ErrorKind) -> CoreError {
        CoreError::Failed {
            message: readable_error(&self.translator, error),
        }
    }

    pub(crate) fn translator(&self) -> &Translator {
        &self.translator
    }

    pub(crate) fn transport(&self) -> Arc<ForeignTransport> {
        Arc::clone(&self.transport)
    }

    fn with_bundles<R>(&self, f: impl FnOnce(&mut ServerBundles) -> R) -> R {
        let mut guard = self
            .bundles
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        f(&mut guard)
    }

    /// The saved account `key` with its token.
    fn account_by_key(&self, key: &str) -> Option<AccountRef> {
        self.with_bundles(|all| {
            all.kinds()
                .into_iter()
                .find_map(|kind| all.bundle(kind).and_then(|b| b.account(key)))
                .map(|a| account_ref(a, &self.device_id))
        })
    }

    /// Drops the account from the stores and wipes its cache; the active account afterwards.
    fn remove_local(&self, key: &str) -> Option<AccountRef> {
        self.with_bundles(|all| {
            if let Some(kind) = all
                .kinds()
                .into_iter()
                .find(|k| all.bundle(*k).is_some_and(|b| b.account(key).is_some()))
            {
                // Logout wipes what was cached for the account (under both spellings of its key).
                let own = all
                    .bundle(kind)
                    .and_then(|b| b.account(key))
                    .map(|a| account_ref(a, &self.device_id));
                let rest = all.bundle(kind).and_then(|b| b.removed(key));
                all.set(rest, kind);
                save_bundles(&self.secrets, all);
                if let Some(cache) = &self.host.cache {
                    let cache = cache.entity_cache();
                    cache.drop_scope(&swiftly_cache::Scope(key.to_owned()));
                    if let Some(own) = own {
                        cache.drop_scope(&swiftly_vm::ViewCache::scope(&own));
                    }
                }
            }
            all.active()
                .map(|b| account_ref(b.active(), &self.device_id))
        })
    }

    fn client(
        &self,
        address: &str,
        kind: ServerKind,
    ) -> Result<ServerClient<ForeignTransport>, CoreError> {
        self.raw_client(address, kind).map_err(|e| self.failed(&e))
    }

    /// Like `client`, with the plain error (the login model sorts it itself).
    pub(crate) fn raw_client(
        &self,
        address: &str,
        kind: ServerKind,
    ) -> Result<ServerClient<ForeignTransport>, ErrorKind> {
        make_signed_out_client(&self.transport, &self.host, kind, address, &self.device_id)
    }

    /// The client of a stored session (the login calls that need the token).
    pub(crate) fn session_client(
        &self,
        session: &Session,
    ) -> Result<ServerClient<ForeignTransport>, ErrorKind> {
        swiftly_vm::make_client_from_session(&self.transport, &self.host, session, &self.device_id)
    }

    pub(crate) fn adopt(&self, session: Session) -> SignedIn {
        self.adopt_account(Account::new(session))
    }

    /// Saves an account (with its Plex block, if any) and makes it the active one.
    pub(crate) fn adopt_account(&self, account: Account) -> SignedIn {
        let reference = account_ref(&account, &self.device_id);
        let outcome = self.with_bundles(|all| {
            let outcome = add_account(all, account);
            save_bundles(&self.secrets, all);
            outcome
        });
        SignedIn {
            account: reference,
            was_switch: outcome.was_switch,
            new_server: outcome.new_server,
        }
    }
}

fn account_ref(account: &Account, device_id: &str) -> AccountRef {
    AccountRef {
        base_url: account.session.server_url.clone(),
        user_id: account.session.user_id.clone(),
        token: account.session.access_token.clone(),
        server_kind: account.session.kind,
        device_id: device_id.to_owned(),
        plex_machine_id: account.plex.as_ref().map(|p| p.machine_identifier.clone()),
        plex_account_token: account.plex.as_ref().map(|p| p.account_token.clone()),
    }
}

#[uniffi::export]
impl AccountsModel {
    /// Apple shows the system's own sentence for a network code the app has no sentence for (the
    /// Swift `readableError` on `NSError`). `message` is what a failed call gave; when it is the
    /// core's neutral sentence for `code`, this returns the sentence for the host's `system_text`
    /// (`localizedDescription`), otherwise `message` as it is.
    pub fn failure_text_system(&self, message: String, code: i32, system_text: String) -> String {
        if message == swiftly_l10n::error_text::readable_url_error(&self.translator, code, "") {
            swiftly_l10n::error_text::readable_url_error_system(
                &self.translator,
                code,
                &system_text,
            )
        } else {
            message
        }
    }

    /// Reads the stored accounts again (after another process wrote them).
    pub fn reload(&self) {
        let fresh = load_bundles(&self.secrets);
        self.with_bundles(|all| *all = fresh);
    }

    /// Every saved account of every server kind; the one in use is marked.
    pub fn accounts(&self) -> Vec<AccountInfo> {
        self.with_bundles(|all| {
            let active_kind = all.active_kind();
            all.kinds()
                .into_iter()
                .filter_map(|kind| all.bundle(kind).map(|b| (kind, b)))
                .flat_map(|(kind, bundle)| {
                    let active_id = bundle.active_id().to_owned();
                    bundle
                        .accounts()
                        .iter()
                        .map(|a| AccountInfo {
                            key: a.account_key(),
                            user_name: a.session.user_name.clone(),
                            user_id: a.session.user_id.clone(),
                            server_url: a.session.server_url.clone(),
                            kind,
                            active: kind == active_kind && a.account_key() == active_id,
                            server_identity: a.server_identity(),
                        })
                        .collect::<Vec<_>>()
                })
                .collect()
        })
    }

    /// The account in use, with its token, if any is saved.
    pub fn active(&self) -> Option<AccountRef> {
        self.with_bundles(|all| {
            all.active()
                .map(|b| account_ref(b.active(), &self.device_id))
        })
    }

    /// Makes the saved account `key` the one in use. `None` when there is no such account.
    pub fn switch_to(&self, key: String) -> Option<AccountRef> {
        self.with_bundles(|all| {
            let kind = all
                .kinds()
                .into_iter()
                .find(|k| all.bundle(*k).is_some_and(|b| b.account(&key).is_some()))?;
            let mut bundle = all.bundle(kind)?.clone();
            bundle.switch_to(&key);
            all.set(Some(bundle), kind);
            all.switch_to(kind);
            save_bundles(&self.secrets, all);
            all.active()
                .map(|b| account_ref(b.active(), &self.device_id))
        })
    }

    /// Removes the saved account `key` (a sign-out), locally only. Returns the account in use
    /// afterwards. Hosts that sign out for real call [`Self::remove_and_sign_off`] instead.
    pub fn remove(&self, key: String) -> Option<AccountRef> {
        self.remove_local(&key)
    }

    /// Signs the account `key` out for real, as the old apps did (`signOff`,
    /// JellyfinClient.swift:417, `AppModel.signOut`): the account is dropped locally right away
    /// (the same as [`Self::remove`]), then the server is told with `POST Sessions/Logout` so the
    /// token stops working there. The server call is best effort: when it fails or the server
    /// does not answer within [`SIGN_OFF_WAIT`], the account is gone locally all the same. Never
    /// use it to switch accounts: it withdraws the token. Returns the account in use afterwards.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn remove_and_sign_off(&self, key: String) -> Result<Option<AccountRef>, CoreError> {
        let own = self.account_by_key(&key);
        let active = self.remove_local(&key);
        if let Some(own) = own
            && let Ok(client) = make_client(&self.transport, &self.host, &own)
        {
            // A hanging server must not hold the sign-out; the result does not matter.
            let _ = tokio::time::timeout(SIGN_OFF_WAIT, client.sign_off()).await;
        }
        Ok(active)
    }

    /// Signs the account `key` out like [`Self::remove_and_sign_off`], but without waiting: the
    /// account is gone locally when this returns, and `POST Sessions/Logout` runs afterwards on
    /// the host's runtime (best effort, [`SIGN_OFF_WAIT`] at most). This is what `AppModel.signOut`
    /// needs: it drops the account synchronously and moves on to the next one.
    pub fn remove_and_sign_off_later(&self, key: String) -> Option<AccountRef> {
        let own = self.account_by_key(&key);
        let active = self.remove_local(&key);
        if let Some(own) = own
            && let Ok(client) = make_client(&self.transport, &self.host, &own)
        {
            self.host.spawner.spawn(Box::pin(async move {
                let _ = tokio::time::timeout(SIGN_OFF_WAIT, client.sign_off()).await;
            }));
        }
        active
    }

    /// What the server says about the account `key` (`accountDefaults`, `GET Users/{id}`): the
    /// next-episode setting and the download and conversion permissions. The old apps asked on
    /// every library load; the answer is not stored by the core. Never fails: without an answer
    /// `answered` is false and the fields hold the assumed values.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn account_defaults(&self, key: String) -> Result<AccountDefaultsInfo, CoreError> {
        let gift = match self.account_by_key(&key) {
            Some(own) => match make_client(&self.transport, &self.host, &own) {
                Ok(client) => client.account_defaults().await,
                Err(_) => None,
            },
            None => None,
        };
        Ok(AccountDefaultsInfo {
            answered: gift.is_some(),
            next_episode_automatic: gift.and_then(|g| g.next_episode_automatic),
            download_permission: gift
                .map_or(
                    swiftly_rules::download_right::DownloadPermission::Unknown,
                    |g| g.download_permission(),
                )
                .raw_value()
                .to_owned(),
            convert_allowed: gift.and_then(|g| g.convert_allowed).unwrap_or(true),
            download_quality_selectable: gift.is_none_or(|g| g.download_quality_selectable()),
        })
    }

    /// The profile picture address of the saved account `key` (`userImageURL(for:)`,
    /// AppModel.swift:1840): `Users/{id}/Images/Primary` of the account's own server at 480
    /// pixels, with its token. Plex keeps the plex.tv address from sign-in. `None` for an
    /// unknown account, a Plex account without a picture or an unusable address. The server
    /// answers 404 when the user has no picture; the view then shows the initial.
    pub fn avatar_address(&self, key: String) -> Option<String> {
        self.with_bundles(|all| {
            let account = all
                .kinds()
                .into_iter()
                .find_map(|kind| all.bundle(kind).and_then(|b| b.account(&key)))?;
            let session = &account.session;
            if session.kind == ServerKind::Plex {
                return account.plex.as_ref().and_then(|p| p.user_image.clone());
            }
            let base = swiftly_images::Url::parse(&session.server_url).ok()?;
            swiftly_images::ImageAddress::new(
                base,
                Some(session.access_token.clone()),
                session.kind,
            )
            .user(&session.user_id, None, AVATAR_EDGE)
            .map(|u| u.to_string())
        })
    }

    /// The server no longer accepts the token of `checked_key`: drops it, but only while it is
    /// still the account in use (a slow check must not sign out whoever switched meanwhile).
    pub fn sign_out_revoked(&self, checked_key: String) -> Option<RevokedInfo> {
        self.with_bundles(|all| {
            let outcome = sign_out_revoked(all, &checked_key)?;
            save_bundles(&self.secrets, all);
            Some(RevokedInfo {
                dropped_name: outcome.dropped_name,
                now_name: outcome.now_name,
                now_key: outcome.now_key,
            })
        })
    }

    /// A Plex server answered at another address (a change of network): keeps the new address,
    /// the token for it and the home/relay marks in the saved account `key`, which stays the
    /// account in use. `false` when there is no such Plex account.
    pub fn move_plex_route(&self, key: String, route: PlexRouteInfo) -> bool {
        self.with_bundles(|all| {
            let Some(mut bundle) = all.bundle(ServerKind::Plex).cloned() else {
                return false;
            };
            let Some(mut account) = bundle.account(&key).cloned() else {
                return false;
            };
            let Some(plex) = account.plex.clone() else {
                return false;
            };
            let before = bundle.active_id().to_owned();
            account.session.server_url = route.uri.clone();
            account.session.access_token = route.token.clone();
            account.plex = Some(swiftly_plex::PlexSessionDetails {
                is_local: route.is_local,
                is_relay: route.is_relay,
                ..plex
            });
            bundle.record(account);
            bundle.switch_to(&before);
            all.set(Some(bundle), ServerKind::Plex);
            save_bundles(&self.secrets, all);
            true
        })
    }

    /// Asks the server at `address` who it is, whether it offers Quick Connect and which users
    /// it lists. Nothing is saved.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn check_server(
        &self,
        address: String,
        kind: ServerKind,
    ) -> Result<ServerCheck, CoreError> {
        let client = self.client(&address, kind)?;
        let info: PublicSystemInfo = client
            .check_reachability()
            .await
            .map_err(|e| self.failed(&e))?;
        let (quick_connect, public_users) = match &client {
            ServerClient::Jellyfin(c) => {
                let quick = c.quick_connect_enabled().await;
                let users = c.public_users().await.unwrap_or_default();
                (quick && kind == ServerKind::Jellyfin, users)
            }
            ServerClient::Plex(_) => (false, Vec::new()),
        };
        Ok(ServerCheck {
            name: info.server_name,
            version: info.version,
            id: info.id,
            quick_connect,
            public_users: public_users
                .into_iter()
                .map(|u| PublicUserInfo {
                    id: u.id,
                    name: u.name,
                })
                .collect(),
        })
    }

    /// Signs in with name and password and saves the account. A second server is added the same
    /// way: see `SignedIn::new_server`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn sign_in(
        &self,
        address: String,
        kind: ServerKind,
        user: String,
        password: String,
    ) -> Result<SignedIn, CoreError> {
        let client = self.client(&address, kind)?;
        let session = client
            .authenticate(&user, &password)
            .await
            .map_err(|e| self.failed(&e))?;
        Ok(self.adopt(session))
    }

    /// Asks for a Quick Connect code (Jellyfin only).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn quick_connect_start(&self, address: String) -> Result<QuickCode, CoreError> {
        let ServerClient::Jellyfin(c) = self.client(&address, ServerKind::Jellyfin)? else {
            return Err(CoreError::Failed {
                message: "no quick connect".to_owned(),
            });
        };
        let code = c.quick_connect_start().await.map_err(|e| self.failed(&e))?;
        Ok(QuickCode {
            code: code.code,
            confidential: code.confidential,
        })
    }

    /// Waits for the approval of `code`: tells the listener the seconds left once a second, keeps
    /// asking when one question fails (only a 404 ends the wait), signs in when the code is
    /// approved and saves the account. Dropping the call (cancelling the task) stops it.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn quick_connect_wait(
        &self,
        address: String,
        code: QuickCode,
        listener: Arc<dyn QuickConnectListener>,
    ) -> Result<QuickEnd, CoreError> {
        let ServerClient::Jellyfin(c) = self.client(&address, ServerKind::Jellyfin)? else {
            return Err(CoreError::Failed {
                message: "no quick connect".to_owned(),
            });
        };
        let login = LoginCode {
            code: code.code,
            confidential: code.confidential,
        };
        let ended = Mutex::new(None::<WaitEvent>);
        let clock = TokioClock(Instant::now());
        c.quick_connect_wait(&login, &clock, |event| match event {
            WaitEvent::Rest(seconds) => {
                listener.rest(seconds);
                true
            }
            other => {
                *ended
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(other);
                false
            }
        })
        .await;
        let last = ended
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        match last {
            Some(WaitEvent::Released) => {
                let session = c
                    .sign_in_with_quick_connect(&login)
                    .await
                    .map_err(|e| self.failed(&e))?;
                Ok(QuickEnd {
                    signed_in: Some(self.adopt(session)),
                    message: None,
                })
            }
            Some(WaitEvent::End(state)) => Ok(QuickEnd {
                signed_in: None,
                message: Some(swiftly_l10n::error_text::quick_connect_end_text(
                    self.translator(),
                    QuickConnectDeadline::end_is_failure(state),
                )),
            }),
            _ => Ok(QuickEnd {
                signed_in: None,
                message: None,
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::{HttpClient, HttpFailure, NetRequest, NetResponse};
    use std::collections::HashMap;
    use swiftly_vm::{Spawner, SystemClock};

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

    /// Every server signs everybody in as the user named in the address.
    struct Servers;
    #[async_trait::async_trait]
    impl HttpClient for Servers {
        async fn send(&self, request: NetRequest) -> Result<NetResponse, HttpFailure> {
            let user = if request.url.contains("two.example") {
                "anna"
            } else {
                "paul"
            };
            let body = format!(
                r#"{{"AccessToken":"tok-{user}","User":{{"Id":"id-{user}","Name":"{user}"}},"ServerId":"s"}}"#
            );
            Ok(NetResponse {
                status: 200,
                headers: vec![],
                body: body.into_bytes(),
                url: None,
            })
        }
    }

    fn model(secrets: Arc<Secrets>) -> Arc<AccountsModel> {
        model_over(secrets, Arc::new(Servers))
    }

    fn model_over(
        secrets: Arc<Secrets>,
        http: Arc<impl HttpClient + 'static>,
    ) -> Arc<AccountsModel> {
        let host = Host {
            spawner: Arc::new(Spawn),
            clock: Arc::new(SystemClock),
            store: Arc::new(NoStore),
            locale: Locale::parse("en"),
            device_name: "test".into(),
            client_version: "1".into(),
            cache: None,
        };
        AccountsModel::build(secrets, ForeignTransport(http), host, "dev".into(), "en")
    }

    #[tokio::test]
    async fn sign_in_adds_an_extra_server_and_switch_and_remove_keep_the_store_in_step() {
        let secrets = Arc::new(Secrets::default());
        let m = model(Arc::clone(&secrets));
        assert!(m.active().is_none());
        let first = m
            .sign_in(
                "https://one.example".into(),
                ServerKind::Jellyfin,
                "paul".into(),
                "pw".into(),
            )
            .await
            .unwrap();
        assert!(first.new_server && !first.was_switch);
        assert_eq!(first.account.token, "tok-paul");
        let second = m
            .sign_in(
                "https://two.example".into(),
                ServerKind::Jellyfin,
                "anna".into(),
                "pw".into(),
            )
            .await
            .unwrap();
        assert!(second.new_server && second.was_switch);
        let list = m.accounts();
        assert_eq!(list.len(), 2);
        assert_eq!(list.iter().filter(|a| a.active).count(), 1);
        assert_eq!(m.active().unwrap().user_id, "id-anna");
        // The stored bundle is what the Swift app reads: `konten` with the German keys.
        let stored = secrets.get("konten".into()).unwrap();
        assert!(
            stored.contains("aktiveKennung") && stored.contains("konten"),
            "{stored}"
        );
        // A new core over the same store sees the same accounts.
        assert_eq!(model(Arc::clone(&secrets)).accounts().len(), 2);
        let back = m
            .switch_to(first.account.user_id.clone().replace("id-", ""))
            .is_none();
        assert!(back, "switching needs the account key, not the user name");
        let key = list
            .iter()
            .find(|a| a.user_name == "paul")
            .unwrap()
            .key
            .clone();
        assert_eq!(m.switch_to(key.clone()).unwrap().user_id, "id-paul");
        let left = m.remove(key);
        assert_eq!(left.unwrap().user_id, "id-anna");
        assert_eq!(m.accounts().len(), 1);
    }

    #[tokio::test]
    async fn a_revoked_account_is_only_dropped_while_it_is_the_active_one() {
        let m = model(Arc::new(Secrets::default()));
        m.sign_in(
            "https://one.example".into(),
            ServerKind::Jellyfin,
            "paul".into(),
            "pw".into(),
        )
        .await
        .unwrap();
        m.sign_in(
            "https://two.example".into(),
            ServerKind::Jellyfin,
            "anna".into(),
            "pw".into(),
        )
        .await
        .unwrap();
        let other = m
            .accounts()
            .into_iter()
            .find(|a| a.user_name == "paul")
            .unwrap()
            .key;
        assert!(
            m.sign_out_revoked(other).is_none(),
            "the account is not the active one"
        );
        let anna = m
            .active()
            .map(|a| format!("{}|{}", a.base_url.to_lowercase(), a.user_id))
            .unwrap();
        let out = m.sign_out_revoked(anna).unwrap();
        assert_eq!(out.dropped_name, "anna");
        assert_eq!(out.now_name.as_deref(), Some("paul"));
    }

    /// Answers sign-in like `Servers`, records every other request and answers it with `reply`.
    type Seen = (String, String, Option<String>);
    type Reply = Box<dyn Fn(&str) -> Result<NetResponse, HttpFailure> + Send + Sync>;
    struct Recording {
        seen: Mutex<Vec<Seen>>,
        reply: Reply,
    }
    impl Recording {
        fn new(
            reply: impl Fn(&str) -> Result<NetResponse, HttpFailure> + Send + Sync + 'static,
        ) -> Arc<Self> {
            Arc::new(Self {
                seen: Mutex::new(Vec::new()),
                reply: Box::new(reply),
            })
        }
        fn seen(&self) -> Vec<Seen> {
            self.seen.lock().unwrap().clone()
        }
    }
    #[async_trait::async_trait]
    impl HttpClient for Recording {
        async fn send(&self, request: NetRequest) -> Result<NetResponse, HttpFailure> {
            if request.url.contains("AuthenticateByName") {
                return Servers.send(request).await;
            }
            let auth = request
                .headers
                .iter()
                .find(|h| h.name.eq_ignore_ascii_case("authorization"))
                .map(|h| h.value.clone());
            self.seen.lock().unwrap().push((
                format!("{:?}", request.method),
                request.url.clone(),
                auth,
            ));
            (self.reply)(&request.url)
        }
    }

    fn ok(body: &str) -> Result<NetResponse, HttpFailure> {
        Ok(NetResponse {
            status: 200,
            headers: vec![],
            body: body.as_bytes().to_vec(),
            url: None,
        })
    }

    fn down() -> Result<NetResponse, HttpFailure> {
        Err(HttpFailure::Network { code: -1003 })
    }

    async fn signed_in_pair(m: &AccountsModel) -> (String, String) {
        m.sign_in(
            "https://one.example".into(),
            ServerKind::Jellyfin,
            "paul".into(),
            "pw".into(),
        )
        .await
        .unwrap();
        m.sign_in(
            "https://two.example".into(),
            ServerKind::Jellyfin,
            "anna".into(),
            "pw".into(),
        )
        .await
        .unwrap();
        let list = m.accounts();
        let key = |n: &str| list.iter().find(|a| a.user_name == n).unwrap().key.clone();
        (key("paul"), key("anna"))
    }

    fn plex_session() -> Session {
        Session {
            access_token: "plex-tok".into(),
            user_id: "7".into(),
            user_name: "pia".into(),
            server_url: "https://plex.example".into(),
            kind: ServerKind::Plex,
        }
    }

    #[tokio::test]
    async fn link_up_probes_the_other_scheme_only_for_an_address_without_one() {
        let refused = || Err(HttpFailure::Network { code: -1004 });
        let http = Recording::new(move |url| {
            if url.starts_with("http://") {
                ok(r#"{"ServerName":"Home","Version":"10.9"}"#)
            } else {
                refused()
            }
        });
        let m = model_over(Arc::new(Secrets::default()), Arc::clone(&http));
        let login = m.legacy_login();
        let found = login
            .link_up("box.example".into(), "[]".into())
            .await
            .unwrap();
        assert!(found.contains("http://box.example"), "{found}");
        let tried: Vec<String> = http.seen().into_iter().map(|s| s.1).collect();
        assert!(
            tried.iter().any(|u| u.starts_with("https://"))
                && tried.iter().any(|u| u.starts_with("http://")),
            "{tried:?}"
        );
        let before = http.seen().len();
        assert!(
            login
                .link_up("https://box.example".into(), "[]".into())
                .await
                .is_err()
        );
        assert!(
            http.seen()[before..]
                .iter()
                .all(|s| s.1.starts_with("https://")),
            "an explicit scheme is not retried"
        );
    }

    #[tokio::test]
    async fn remove_and_sign_off_tells_the_server_with_the_accounts_own_token_and_drops_it() {
        let http = Recording::new(|_| ok(""));
        let m = model_over(Arc::new(Secrets::default()), Arc::clone(&http));
        let (paul, _anna) = signed_in_pair(&m).await;
        let left = m.remove_and_sign_off(paul).await.unwrap();
        assert_eq!(left.unwrap().user_id, "id-anna");
        assert_eq!(m.accounts().len(), 1);
        let seen = http.seen();
        assert_eq!(seen.len(), 1, "{seen:?}");
        assert_eq!(seen[0].0, "Post");
        assert_eq!(seen[0].1, "https://one.example/Sessions/Logout");
        assert!(
            seen[0]
                .2
                .as_deref()
                .unwrap()
                .contains(r#"Token="tok-paul""#),
            "{:?}",
            seen[0].2
        );
    }

    #[tokio::test]
    async fn a_failing_or_unreachable_server_never_keeps_the_account() {
        let secrets = Arc::new(Secrets::default());
        let http = Recording::new(|_| down());
        let m = model_over(Arc::clone(&secrets), Arc::clone(&http));
        let (paul, _) = signed_in_pair(&m).await;
        assert_eq!(
            m.remove_and_sign_off(paul).await.unwrap().unwrap().user_id,
            "id-anna"
        );
        assert_eq!(m.accounts().len(), 1);
        assert_eq!(http.seen().len(), 1, "the call was tried");
        assert_eq!(
            model(secrets).accounts().len(),
            1,
            "the store has it gone too"
        );
        // A 500 answer is no different.
        let http = Recording::new(|_| {
            Ok(NetResponse {
                status: 500,
                headers: vec![],
                body: vec![],
                url: None,
            })
        });
        let m = model_over(Arc::new(Secrets::default()), http);
        let (_, anna) = signed_in_pair(&m).await;
        assert!(m.remove_and_sign_off(anna).await.unwrap().is_some());
        assert_eq!(m.accounts().len(), 1);
    }

    struct Hangs;
    #[async_trait::async_trait]
    impl HttpClient for Hangs {
        async fn send(&self, request: NetRequest) -> Result<NetResponse, HttpFailure> {
            if request.url.contains("AuthenticateByName") {
                return Servers.send(request).await;
            }
            std::future::pending().await
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_server_that_never_answers_does_not_hold_the_sign_out() {
        let m = model_over(Arc::new(Secrets::default()), Arc::new(Hangs));
        let (paul, _) = signed_in_pair(&m).await;
        let started = tokio::time::Instant::now();
        assert!(m.remove_and_sign_off(paul).await.unwrap().is_some());
        assert_eq!(m.accounts().len(), 1);
        assert_eq!(started.elapsed(), SIGN_OFF_WAIT);
    }

    #[tokio::test]
    async fn the_later_variant_drops_at_once_and_tells_the_server_afterwards() {
        let http = Recording::new(|_| ok(""));
        let m = model_over(Arc::new(Secrets::default()), Arc::clone(&http));
        let (paul, _) = signed_in_pair(&m).await;
        let left = m.remove_and_sign_off_later(paul);
        assert_eq!(left.unwrap().user_id, "id-anna");
        assert_eq!(m.accounts().len(), 1, "gone locally before any await");
        for _ in 0..50 {
            tokio::task::yield_now().await;
        }
        let seen = http.seen();
        assert_eq!(seen.len(), 1, "{seen:?}");
        assert_eq!(seen[0].1, "https://one.example/Sessions/Logout");
        assert!(
            seen[0]
                .2
                .as_deref()
                .unwrap()
                .contains(r#"Token="tok-paul""#)
        );
    }

    #[tokio::test]
    async fn an_unknown_key_signs_nothing_off() {
        let http = Recording::new(|_| ok(""));
        let m = model_over(Arc::new(Secrets::default()), Arc::clone(&http));
        signed_in_pair(&m).await;
        assert!(
            m.remove_and_sign_off("nobody|x".into())
                .await
                .unwrap()
                .is_some()
        );
        assert_eq!(m.accounts().len(), 2);
        assert!(http.seen().is_empty());
    }

    #[tokio::test]
    async fn plex_signs_out_without_a_server_call() {
        let http = Recording::new(|_| ok(""));
        let m = model_over(Arc::new(Secrets::default()), Arc::clone(&http));
        m.adopt_account(Account::new(plex_session()));
        let key = m.accounts()[0].key.clone();
        assert!(m.remove_and_sign_off(key).await.unwrap().is_none());
        assert!(m.accounts().is_empty());
        assert!(
            http.seen().is_empty(),
            "Plex has no Sessions/Logout: {:?}",
            http.seen()
        );
    }

    #[tokio::test]
    async fn account_defaults_read_users_id_and_map_the_permissions() {
        let body = r#"{"Configuration":{"EnableNextEpisodeAutoPlay":false},
            "Policy":{"EnableContentDownloading":false,"EnableVideoPlaybackTranscoding":false,"EnableAudioPlaybackTranscoding":true}}"#;
        let http = Recording::new(move |_| ok(body));
        let m = model_over(Arc::new(Secrets::default()), Arc::clone(&http));
        let (paul, _) = signed_in_pair(&m).await;
        let got = m.account_defaults(paul).await.unwrap();
        assert_eq!(
            got,
            AccountDefaultsInfo {
                answered: true,
                next_episode_automatic: Some(false),
                download_permission: "verboten".into(),
                convert_allowed: false,
                // Video conversion is off, so there is no smaller quality to pick (the rule).
                download_quality_selectable: false,
            }
        );
        let seen = http.seen();
        assert_eq!(
            (seen[0].0.as_str(), seen[0].1.as_str()),
            ("Get", "https://one.example/Users/id-paul")
        );
        assert!(
            seen[0]
                .2
                .as_deref()
                .unwrap()
                .contains(r#"Token="tok-paul""#)
        );
    }

    #[tokio::test]
    async fn account_defaults_without_an_answer_hold_the_assumed_values() {
        let http = Recording::new(|_| down());
        let m = model_over(Arc::new(Secrets::default()), http);
        let (paul, _) = signed_in_pair(&m).await;
        let got = m.account_defaults(paul).await.unwrap();
        assert_eq!(
            got,
            AccountDefaultsInfo {
                answered: false,
                next_episode_automatic: None,
                download_permission: "unbekannt".into(),
                convert_allowed: true,
                download_quality_selectable: true,
            }
        );
        assert!(
            !m.account_defaults("nobody|x".into())
                .await
                .unwrap()
                .answered
        );
    }

    #[tokio::test]
    async fn the_avatar_address_is_the_primary_image_at_480_with_the_token() {
        let m = model(Arc::new(Secrets::default()));
        let (paul, _) = signed_in_pair(&m).await;
        assert_eq!(
            m.avatar_address(paul).unwrap(),
            "https://one.example/Users/id-paul/Images/Primary?fillWidth=480&fillHeight=480&quality=90&ApiKey=tok-paul"
        );
        assert!(m.avatar_address("nobody|x".into()).is_none());
    }

    #[test]
    fn the_avatar_of_a_plex_account_is_the_address_from_plex_tv() {
        let m = model(Arc::new(Secrets::default()));
        let mut account = Account::new(plex_session());
        assert!(m.adopt_account(account.clone()).new_server);
        let key = m.accounts()[0].key.clone();
        assert_eq!(m.avatar_address(key), None, "no picture known");
        let m = model(Arc::new(Secrets::default()));
        account.plex = Some(swiftly_plex::PlexSessionDetails {
            machine_identifier: "m".into(),
            server_name: "s".into(),
            account_token: "a".into(),
            is_local: false,
            is_relay: false,
            home_user_uuid: None,
            user_image: Some("https://plex.tv/users/1.png".into()),
        });
        m.adopt_account(account);
        let key = m.accounts()[0].key.clone();
        assert_eq!(
            m.avatar_address(key).as_deref(),
            Some("https://plex.tv/users/1.png")
        );
    }

    #[test]
    fn an_unknown_network_code_gets_the_system_sentence_the_known_ones_keep_theirs() {
        let m = model(Arc::new(Secrets::default()));
        let neutral = |code| swiftly_l10n::error_text::readable_url_error(&m.translator, code, "");
        assert_eq!(
            m.failure_text_system(neutral(-1100), -1100, "The file does not exist.".into()),
            "The file does not exist."
        );
        assert_eq!(
            m.failure_text_system(neutral(-1001), -1001, "The request timed out.".into()),
            neutral(-1001)
        );
        assert_eq!(
            m.failure_text_system("Other sentence.".into(), -1100, "System.".into()),
            "Other sentence."
        );
    }
}
