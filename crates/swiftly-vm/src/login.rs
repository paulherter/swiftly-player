//! The sign-in screen (`LoginModel.swift`, `QuickConnectModel.swift`): address, then user and
//! password or Quick Connect. A state machine: intents go in, effects (network calls the host
//! runs) come out, [`LoginPart`] is what the view draws. The last server (`letzterServer`) and
//! the server name cache (`serverNamenCache`) are read and written through the settings store.

use serde::{Deserialize, Serialize};
use swiftly_accounts::{RevokedOutcome, Session as AccountSession, SessionEvent, SignInMethod};
use swiftly_jellyfin::discovery::{self, FoundServer};
use swiftly_jellyfin::{
    CheckMark, CheckState, LoginCode, PublicUser, QuickConnectDeadline, QuickConnectState, Session,
    is_home_network, normalize_server_url_string, reversed_server_url_string,
};
use swiftly_l10n::{
    Arg, Locale, Translator,
    error_text::{quick_connect_end_text, readable_error},
};
use swiftly_model::PublicSystemInfo;
use swiftly_net::{ErrorKind, Url};
use swiftly_rules::natural_order::StandardCollator;
use swiftly_settings::{KeyValueStore, Settings, keys};

/// What the sign-in screen knows about the last server (`ServerReminder`; the keys are the
/// German ones the app already stores).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerReminder {
    /// The address.
    #[serde(rename = "adresse")]
    pub address: String,
    /// The server name.
    pub name: String,
    /// The server version.
    pub version: String,
}

/// Where the sign-in stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoginScreen {
    /// Typing the server address.
    Address,
    /// The server is confirmed; user and password.
    Credentials,
    /// Waiting for approval of a Quick Connect code.
    QuickConnect,
}

/// What the view draws.
#[derive(Debug, Clone, PartialEq)]
pub struct LoginPart {
    /// Grows with every change.
    pub version: u64,
    /// The step.
    pub screen: LoginScreen,
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
    pub public_users: Vec<PublicUser>,
    /// Servers found on the network, without the one in the field and the last one.
    pub found: Vec<FoundServer>,
    /// The last connected server.
    pub last: Option<ServerReminder>,
    /// "Sign in" may be pressed.
    pub can_sign_in: bool,
    /// "Connect" may be pressed: an address is typed and no check runs (`.disabled(address.isEmpty ||
    /// model.phase == .connecting)`).
    pub can_connect: bool,
    /// Seconds left of the Quick Connect code (`QuickConnectModel.secondsLeft`): 300 until the wait
    /// reports, 0 after the end.
    pub quick_seconds_left: i64,
}

/// The countdown the way the Quick Connect page writes it: `m:ss` (`\(secondsLeft / 60):%02d`).
pub fn quick_countdown(seconds: i64) -> String {
    format!("{}:{:02}", seconds / 60, seconds % 60)
}

/// What the view asks for.
#[derive(Debug, Clone)]
pub enum LoginIntent {
    /// The address field changed.
    EditAddress(String),
    /// Check the address.
    Connect,
    /// The answer of [`LoginEffect::CheckAddress`].
    AddressChecked {
        /// The check this answers.
        mark: CheckMark,
        /// What the server said.
        result: Result<PublicSystemInfo, ErrorKind>,
    },
    /// The user field changed.
    EditUser(String),
    /// The password field changed.
    EditPassword(String),
    /// Sign in with user and password.
    SignIn,
    /// The answer of [`LoginEffect::Authenticate`] or of the Quick Connect sign-in.
    SignedIn(Result<Session, ErrorKind>),
    /// Whether the server has Quick Connect switched on.
    QuickConnectOffered(bool),
    /// The server's list of public users.
    PublicUsers(Vec<PublicUser>),
    /// A user was picked from the list.
    PickUser(String),
    /// Start Quick Connect.
    UseQuickConnect,
    /// "Neuen Code holen" on the Quick Connect page (`QuickConnectModel.newStart`): drops the code
    /// and its wait and asks for a new one. The host stops the old wait loop first.
    NewCode,
    /// The wait's once-a-second `rest` event: seconds until the deadline.
    QuickConnectRest(i64),
    /// The answer of [`LoginEffect::StartQuickConnect`].
    QuickConnectStarted(Result<LoginCode, ErrorKind>),
    /// One answer of the Quick Connect wait.
    QuickConnectState(QuickConnectState),
    /// One step back.
    Back,
    /// Another round of discovery found these.
    Discovered(Vec<FoundServer>),
    /// A found server was tapped (its id).
    PickServer(String),
    /// "Zuletzt verbunden" was tapped.
    UseLast,
}

/// What the host runs for the screen.
#[derive(Debug, Clone, PartialEq)]
pub enum LoginEffect {
    /// Ask the server who it is, then answer with [`LoginIntent::AddressChecked`].
    CheckAddress {
        /// The check.
        mark: CheckMark,
        /// The address to ask.
        url: String,
    },
    /// Sign in with name and password.
    Authenticate {
        /// The checked address.
        url: String,
        /// The user.
        user: String,
        /// The password.
        password: String,
    },
    /// Ask for a Quick Connect code.
    StartQuickConnect,
    /// Sign in with an approved code.
    SignInWithQuickConnect(LoginCode),
    /// Signed in; the host adopts the session (`sessionAdopt`).
    Done(Session),
}

/// The sign-in screen model.
pub struct LoginVm<S: KeyValueStore> {
    settings: Settings<S>,
    translator: Translator,
    checks: CheckState,
    tried_reverse: bool,
    /// The reason of the first attempt: it is what the user reads if the second fails too.
    first_error: Option<ErrorKind>,
    /// The typed address carried a scheme: then the other scheme is never tried.
    explicit_scheme: bool,
    code: Option<LoginCode>,
    discovered: Vec<FoundServer>,
    /// The order of the found servers in the app language (`localizedStandardCompare`).
    collator: Option<StandardCollator>,
    part: LoginPart,
    /// Login, connect and account switch as one machine; fed by [`Self::handle`] and by hosts.
    session: AccountSession,
}

impl<S: KeyValueStore> LoginVm<S> {
    /// A fresh screen; the last server is read from the store.
    pub fn new(store: S, locale: Locale) -> Self {
        let settings = Settings::new(store);
        let last = Self::read_last(&settings);
        let address = String::new();
        let collator = StandardCollator::new(locale.language()).ok();
        Self {
            settings,
            translator: Translator::new(locale),
            checks: CheckState::new(),
            tried_reverse: false,
            first_error: None,
            explicit_scheme: false,
            code: None,
            discovered: Vec::new(),
            collator,
            part: LoginPart {
                version: 0,
                screen: LoginScreen::Address,
                address,
                user: String::new(),
                password: String::new(),
                working: false,
                error: None,
                server_name: None,
                quick_code: None,
                quick_offered: false,
                public_users: Vec::new(),
                found: Vec::new(),
                last,
                can_sign_in: false,
                can_connect: false,
                quick_seconds_left: QuickConnectDeadline::SECONDS as i64,
            },
            session: AccountSession::SignedOut,
        }
    }

    /// The current state of the screen.
    pub fn part(&self) -> &LoginPart {
        &self.part
    }

    fn read_last(settings: &Settings<S>) -> Option<ServerReminder> {
        serde_json::from_slice(&settings.get(&keys::LETZTER_SERVER)?).ok()
    }

    /// The last connected server (`lastServer`).
    pub fn last_server(&self) -> Option<ServerReminder> {
        Self::read_last(&self.settings)
    }

    /// Stores the last server (`serverRemember`) and returns it.
    pub fn remember_server(
        &mut self,
        address: &str,
        name: &str,
        version: &str,
    ) -> Option<ServerReminder> {
        let entry = ServerReminder {
            address: address.into(),
            name: name.into(),
            version: version.into(),
        };
        let raw = serde_json::to_vec(&entry).ok()?;
        self.settings.set(&keys::LETZTER_SERVER, Some(raw)).ok()?;
        self.part.last = Some(entry.clone());
        Some(entry)
    }

    /// The cached name of a server (`ServerNameCache.name(for:)`).
    pub fn server_name_for(&self, url: &str) -> Option<String> {
        self.settings
            .get(&keys::SERVER_NAMEN_CACHE)?
            .get(&cache_id(url))
            .cloned()
    }

    /// Caches a server name (`ServerNameCache.store`). The host name is what the app shows until
    /// the real name arrives: not worth keeping, nor is an empty name.
    pub fn cache_server_name(&self, name: &str, url: &str) {
        let host = Url::parse(url)
            .ok()
            .and_then(|u| u.host_str().map(String::from))
            .unwrap_or_else(|| url.into());
        if name.is_empty() || name == host {
            return;
        }
        let mut all = self
            .settings
            .get(&keys::SERVER_NAMEN_CACHE)
            .unwrap_or_default();
        let id = cache_id(url);
        if all.get(&id).is_some_and(|n| n == name) {
            return;
        }
        all.insert(id, name.into());
        let _ = self.settings.set(&keys::SERVER_NAMEN_CACHE, Some(all));
    }

    fn readable(&self, error: &ErrorKind) -> String {
        readable_error(&self.translator, error)
    }

    /// The sentence for a failed address check (`connectionError`).
    fn connection_text(&self, error: &ErrorKind, address: &str) -> String {
        connection_error_text(&self.translator, error, address)
    }

    fn touch(&mut self) {
        self.part.version += 1;
        self.part.can_sign_in = self.part.screen == LoginScreen::Credentials
            && !self.part.working
            && !self.part.user.trim().is_empty();
        self.part.can_connect = !self.part.address.is_empty()
            && !self.part.working
            && self.part.screen == LoginScreen::Address;
        let taken = [
            Some(self.part.address.as_str()),
            self.part.last.as_ref().map(|l| l.address.as_str()),
        ];
        self.part.found = discovery::shown(&self.discovered, &taken);
    }

    fn fail(&mut self, error: &ErrorKind) {
        self.part.working = false;
        self.part.error = Some(self.readable(error));
    }

    /// Applies an intent; returns what the host has to run.
    pub fn handle(&mut self, intent: LoginIntent) -> Vec<LoginEffect> {
        let seen = intent.clone();
        let effects = self.apply(intent);
        self.drive_session(&seen, &effects);
        self.touch();
        effects
    }

    /// The login/account state (`AppModel.phase` + `isWorking` + `errorMessage` as one enum).
    pub fn session(&self) -> &AccountSession {
        &self.session
    }

    /// Hosts feed what only they know: account switches (`SwitchTo`, `SwitchDone`, `SwitchFailed`),
    /// `SignOut`, `Revoked`. Returns the state afterwards; an event that makes no sense changes nothing.
    pub fn feed_session(&mut self, event: SessionEvent) -> &AccountSession {
        self.session =
            std::mem::replace(&mut self.session, AccountSession::SignedOut).reduce(event);
        &self.session
    }

    /// Sets the state at launch (a restored account is `Ready`) or after the host adopted a session.
    pub fn set_session(&mut self, session: AccountSession) {
        self.session = session;
    }

    /// The only mapping from screen intents to session events.
    fn drive_session(&mut self, intent: &LoginIntent, effects: &[LoginEffect]) {
        let mut events = Vec::new();
        match intent {
            LoginIntent::Connect => {
                if let Some(LoginEffect::CheckAddress { url, .. }) = effects.first() {
                    events.push(SessionEvent::Connect {
                        server: url.clone(),
                    });
                }
            }
            LoginIntent::AddressChecked { result, .. }
                if effects.is_empty() && !self.part.working =>
            {
                match result {
                    Ok(_) if self.part.screen == LoginScreen::Credentials => {
                        events.push(SessionEvent::Reachable)
                    }
                    Err(_) => {
                        events.push(SessionEvent::Unreachable {
                            reason: self.part.error.clone().unwrap_or_default(),
                        });
                    }
                    Ok(_) => {}
                }
            }
            LoginIntent::EditAddress(_) => events.push(SessionEvent::Cancelled),
            LoginIntent::Back if self.part.screen == LoginScreen::Address => {
                events.push(SessionEvent::Cancelled)
            }
            LoginIntent::SignedIn(Ok(session)) => {
                events.push(SessionEvent::SignedIn {
                    account: session.user_id.clone(),
                });
            }
            _ => {}
        }
        for effect in effects {
            match effect {
                LoginEffect::Authenticate { .. } => {
                    events.push(SessionEvent::BeginSignIn {
                        method: SignInMethod::Password,
                    });
                }
                LoginEffect::SignInWithQuickConnect(_) => {
                    events.push(SessionEvent::BeginSignIn {
                        method: SignInMethod::QuickConnect,
                    });
                }
                _ => {}
            }
        }
        for event in events {
            self.feed_session(event);
        }
        // A sign-in that ended without an account (wrong password, Quick Connect left or expired)
        // is back at the form, never stuck.
        if matches!(self.session, AccountSession::SigningIn { .. }) && !self.part.working {
            self.feed_session(SessionEvent::SignInRefused);
        }
    }

    fn apply(&mut self, intent: LoginIntent) -> Vec<LoginEffect> {
        match intent {
            LoginIntent::EditAddress(text) => {
                self.part.address = text;
                self.part.error = None;
                self.part.working = false;
                self.part.screen = LoginScreen::Address;
                self.part.server_name = None;
                self.checks.discard();
            }
            LoginIntent::Connect => return self.connect(),
            LoginIntent::AddressChecked { mark, result } => {
                return self.address_checked(&mark, result);
            }
            LoginIntent::EditUser(text) => {
                self.part.user = text;
                self.part.error = None;
            }
            LoginIntent::EditPassword(text) => {
                self.part.password = text;
                self.part.error = None;
            }
            LoginIntent::SignIn => {
                let user = self.part.user.trim().to_string();
                if self.part.screen != LoginScreen::Credentials
                    || self.part.working
                    || user.is_empty()
                {
                    return Vec::new();
                }
                let Some(url) = normalize_server_url_string(&self.part.address) else {
                    return Vec::new();
                };
                self.part.working = true;
                self.part.error = None;
                return vec![LoginEffect::Authenticate {
                    url,
                    user,
                    password: self.part.password.clone(),
                }];
            }
            LoginIntent::SignedIn(result) => match result {
                Ok(session) => {
                    self.part.working = false;
                    self.part.password.clear();
                    return vec![LoginEffect::Done(session)];
                }
                Err(e) => {
                    self.fail(&e);
                    if self.part.screen == LoginScreen::QuickConnect {
                        self.leave_quick_connect();
                    }
                }
            },
            LoginIntent::QuickConnectOffered(offered) => self.part.quick_offered = offered,
            LoginIntent::PublicUsers(users) => self.part.public_users = users,
            LoginIntent::PickUser(name) => self.part.user = name,
            LoginIntent::UseQuickConnect => {
                if !self.part.quick_offered
                    || self.part.working
                    || self.part.screen != LoginScreen::Credentials
                {
                    return Vec::new();
                }
                self.part.screen = LoginScreen::QuickConnect;
                self.part.working = true;
                self.part.error = None;
                self.part.quick_seconds_left = QuickConnectDeadline::SECONDS as i64;
                return vec![LoginEffect::StartQuickConnect];
            }
            LoginIntent::NewCode => {
                // Only on the Quick Connect page, and not while the approved code is being signed in.
                if self.part.screen != LoginScreen::QuickConnect
                    || (self.part.working && self.code.is_some())
                {
                    return Vec::new();
                }
                self.code = None;
                self.part.quick_code = None;
                self.part.working = true;
                self.part.error = None;
                self.part.quick_seconds_left = QuickConnectDeadline::SECONDS as i64;
                return vec![LoginEffect::StartQuickConnect];
            }
            LoginIntent::QuickConnectRest(seconds) => {
                if self.part.screen == LoginScreen::QuickConnect && self.code.is_some() {
                    self.part.quick_seconds_left = seconds;
                }
            }
            LoginIntent::QuickConnectStarted(result) => {
                if self.part.screen != LoginScreen::QuickConnect {
                    return Vec::new();
                }
                match result {
                    Ok(code) => {
                        self.part.working = false;
                        self.part.quick_code = Some(code.code.clone());
                        self.code = Some(code);
                    }
                    Err(e) => {
                        self.fail(&e);
                        self.leave_quick_connect();
                    }
                }
            }
            LoginIntent::QuickConnectState(state) => return self.quick_state(state),
            LoginIntent::Back => match self.part.screen {
                LoginScreen::QuickConnect => {
                    self.leave_quick_connect();
                    self.part.working = false;
                }
                LoginScreen::Credentials => {
                    self.part.screen = LoginScreen::Address;
                    self.part.server_name = None;
                    self.part.error = None;
                }
                LoginScreen::Address => {}
            },
            LoginIntent::Discovered(list) => {
                self.discovered = match &self.collator {
                    Some(collator) => {
                        discovery::merged_localized(&self.discovered, &list, collator)
                    }
                    None => discovery::merged(&self.discovered, &list),
                }
            }
            LoginIntent::PickServer(id) => {
                if let Some(s) = self.discovered.iter().find(|s| s.id == id) {
                    self.part.address = s.address.clone();
                    self.part.error = None;
                    self.part.screen = LoginScreen::Address;
                    self.part.working = false;
                    self.checks.discard();
                    // The Swift row fills the field and connects (`address = server.address; linkUp()`).
                    return self.connect();
                }
            }
            LoginIntent::UseLast => {
                if let Some(last) = &self.part.last {
                    self.part.address = last.address.clone();
                    self.part.error = None;
                    self.part.screen = LoginScreen::Address;
                    self.part.working = false;
                    self.checks.discard();
                    // "Zuletzt verbunden" fills the field and connects, too.
                    return self.connect();
                }
            }
        }
        Vec::new()
    }

    fn leave_quick_connect(&mut self) {
        self.part.screen = LoginScreen::Credentials;
        self.part.quick_code = None;
        self.code = None;
    }

    fn connect(&mut self) -> Vec<LoginEffect> {
        // An empty field does nothing and says nothing (`guard !address.isEmpty`).
        if self.part.working || self.part.address.is_empty() {
            return Vec::new();
        }
        let Some(url) = normalize_server_url_string(&self.part.address) else {
            self.part.error = Some(self.readable(&ErrorKind::InvalidServerUrl));
            return Vec::new();
        };
        self.tried_reverse = false;
        self.first_error = None;
        self.explicit_scheme = self.part.address.contains("://");
        self.part.working = true;
        self.part.error = None;
        let mark = self.checks.begin(&url);
        vec![LoginEffect::CheckAddress { mark, url }]
    }

    fn address_checked(
        &mut self,
        mark: &CheckMark,
        result: Result<PublicSystemInfo, ErrorKind>,
    ) -> Vec<LoginEffect> {
        if !self.checks.applies(mark) {
            return Vec::new();
        }
        match result {
            Ok(info) => {
                self.checks.complete(mark);
                self.part.working = false;
                let url = mark.address.clone();
                let host = Url::parse(&url)
                    .ok()
                    .and_then(|u| u.host_str().map(String::from))
                    .unwrap_or_default();
                let name = info
                    .server_name
                    .clone()
                    .filter(|n| !n.is_empty())
                    .unwrap_or(host);
                // `name ?? host ?? "Server"`, `version ?? "?"`.
                let name = if name.is_empty() {
                    "Server".to_string()
                } else {
                    name
                };
                self.remember_server(&url, &name, info.version.as_deref().unwrap_or("?"));
                self.cache_server_name(&name, &url);
                self.part.address = url;
                self.part.server_name = Some(name);
                self.part.screen = LoginScreen::Credentials;
                Vec::new()
            }
            Err(e) => {
                // The other scheme is tried once, only for an address typed without one and only
                // when it can pay off (`raw.contains("://") == false`, `fallbackPaysOff`).
                let alternate =
                    (!self.explicit_scheme && !self.tried_reverse && e.fallback_pays_off())
                        .then(|| reversed_server_url_string(&mark.address))
                        .flatten();
                if let Some(text) = alternate {
                    self.tried_reverse = true;
                    // Keep the reason of the **first** attempt (`realReason`).
                    self.first_error = Some(e);
                    let next = self.checks.begin(&text);
                    return vec![LoginEffect::CheckAddress {
                        mark: next,
                        url: text,
                    }];
                }
                self.checks.complete(mark);
                let shown = self.first_error.take().unwrap_or(e);
                self.part.working = false;
                self.part.error = Some(self.connection_text(&shown, &mark.address));
                Vec::new()
            }
        }
    }

    fn quick_state(&mut self, state: QuickConnectState) -> Vec<LoginEffect> {
        if self.part.screen != LoginScreen::QuickConnect {
            return Vec::new();
        }
        match state {
            QuickConnectState::Opened => Vec::new(),
            // After the first approval the wait is over (`run += 1`): a second one signs nobody in.
            QuickConnectState::Released if self.part.working => Vec::new(),
            QuickConnectState::Released => match self.code.clone() {
                Some(code) => {
                    self.part.working = true;
                    vec![LoginEffect::SignInWithQuickConnect(code)]
                }
                None => Vec::new(),
            },
            QuickConnectState::Expired => {
                self.part.quick_seconds_left = 0;
                self.part.working = false;
                self.part.error = Some(quick_connect_end_text(&self.translator, false));
                self.leave_quick_connect();
                Vec::new()
            }
            QuickConnectState::Failed => {
                self.part.quick_seconds_left = 0;
                self.part.working = false;
                self.part.error = Some(quick_connect_end_text(&self.translator, true));
                self.leave_quick_connect();
                Vec::new()
            }
        }
    }
}

/// The key of the server name cache: the address, lower case (`ServerNameCache.id`).
fn cache_id(url: &str) -> String {
    url.to_lowercase()
}

/// The sentence after a revoked account was dropped (`signOutRevoked`, AppModel.swift:2709):
/// either the next account took over, or the user has to sign in again.
pub fn revoked_message(translator: &Translator, outcome: &RevokedOutcome) -> String {
    match &outcome.now_name {
        Some(next) => translator.t_args(
            "Die Anmeldung von %@ gilt nicht mehr. Jetzt angemeldet als %@.",
            &[
                Arg::Str(outcome.dropped_name.clone()),
                Arg::Str(next.clone()),
            ],
        ),
        None => translator.t("Die Anmeldung gilt nicht mehr. Bitte neu anmelden."),
    }
}

/// The plex.tv/link page of a Plex sign-in (`PlexSignIn`): the page where the code is typed, and
/// the payload of its QR code. Rendering the code is the view's job.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexLink {
    /// The page to open or show.
    pub page: String,
    /// The PIN code to type there.
    pub code: String,
    /// What the QR code encodes: the page address.
    pub qr_payload: String,
}

/// Builds the link data from the page address (`PlexAccountService::link_page`) and the PIN code.
pub fn plex_link(link_page: Option<&Url>, code: &str) -> Option<PlexLink> {
    let page = link_page?.to_string();
    (!code.is_empty()).then(|| PlexLink {
        qr_payload: page.clone(),
        page,
        code: code.into(),
    })
}

/// The sentence for a failed address check (`AppModel.connectionError`): the offline error on the home
/// network points at the local-network permission; everything else reads like any other error.
pub fn connection_error_text(translator: &Translator, error: &ErrorKind, address: &str) -> String {
    let host = Url::parse(address)
        .ok()
        .and_then(|u| u.host_str().map(String::from))
        .unwrap_or_default();
    if is_home_network(&host)
        && matches!(error, ErrorKind::Network { code } if *code == swiftly_net::url_error::NOT_CONNECTED_TO_INTERNET)
    {
        return translator.t("Der Server war nicht erreichbar. Hat Swiftly die Erlaubnis, Geräte im heimischen Netz zu suchen? Sie steht in den Systemeinstellungen unter „Swiftly · Lokales Netzwerk\".");
    }
    readable_error(translator, error)
}

#[cfg(test)]
mod tests {
    #[test]
    fn connection_hint_only_offline_on_the_home_network() {
        let t = Translator::new(Locale::parse("de"));
        let offline = ErrorKind::Network {
            code: swiftly_net::url_error::NOT_CONNECTED_TO_INTERNET,
        };
        assert!(
            connection_error_text(&t, &offline, "http://192.168.1.5:8096")
                .contains("Lokales Netzwerk")
        );
        assert!(
            !connection_error_text(&t, &offline, "https://example.org")
                .contains("Lokales Netzwerk")
        );
        let other = ErrorKind::Network { code: -1001 };
        assert!(
            !connection_error_text(&t, &other, "http://192.168.1.5:8096")
                .contains("Lokales Netzwerk")
        );
    }

    use super::*;
    use swiftly_settings::MemoryStore;

    fn vm() -> LoginVm<MemoryStore> {
        LoginVm::new(MemoryStore::new(), Locale::parse("de"))
    }

    fn info(name: &str) -> PublicSystemInfo {
        PublicSystemInfo {
            server_name: Some(name.into()),
            version: Some("10.9.0".into()),
            id: None,
            product_name: None,
        }
    }

    fn session() -> Session {
        Session {
            access_token: "t".into(),
            user_id: "u".into(),
            user_name: "Anna".into(),
            server_url: "http://192.168.1.5:8096".into(),
            kind: swiftly_jellyfin::ServerKind::Jellyfin,
        }
    }

    fn checked(vm: &mut LoginVm<MemoryStore>) -> CheckMark {
        vm.handle(LoginIntent::EditAddress("192.168.1.5:8096".into()));
        let Some(LoginEffect::CheckAddress { mark, url }) = vm.handle(LoginIntent::Connect).pop()
        else {
            panic!("no check")
        };
        assert_eq!(url, "http://192.168.1.5:8096");
        vm.handle(LoginIntent::AddressChecked {
            mark: mark.clone(),
            result: Ok(info("Wohnzimmer")),
        });
        mark
    }

    #[test]
    fn session_follows_the_screen() {
        let mut vm = vm();
        assert_eq!(vm.session(), &AccountSession::SignedOut);
        vm.handle(LoginIntent::EditAddress("192.168.1.5:8096".into()));
        let Some(LoginEffect::CheckAddress { mark, .. }) = vm.handle(LoginIntent::Connect).pop()
        else {
            panic!()
        };
        assert!(matches!(vm.session(), AccountSession::Connecting { .. }));
        vm.handle(LoginIntent::AddressChecked {
            mark,
            result: Ok(info("W")),
        });
        assert!(matches!(vm.session(), AccountSession::NeedsLogin { .. }));
        vm.handle(LoginIntent::EditUser("Anna".into()));
        vm.handle(LoginIntent::SignIn);
        assert!(matches!(
            vm.session(),
            AccountSession::SigningIn {
                method: SignInMethod::Password,
                ..
            }
        ));
        assert!(vm.session().is_working());
        vm.handle(LoginIntent::SignedIn(Err(ErrorKind::Http {
            status: 401,
            body: None,
        })));
        assert!(
            matches!(vm.session(), AccountSession::NeedsLogin { .. }),
            "refused: back at the form"
        );
        vm.handle(LoginIntent::SignIn);
        vm.handle(LoginIntent::SignedIn(Ok(session())));
        assert_eq!(
            vm.session(),
            &AccountSession::Ready {
                account: "u".into()
            }
        );
        // The host feeds the account switch; a second switch while one runs is ignored.
        vm.feed_session(SessionEvent::SwitchTo { to: "v".into() });
        vm.feed_session(SessionEvent::SwitchTo { to: "w".into() });
        assert_eq!(
            vm.session(),
            &AccountSession::Switching {
                from: "u".into(),
                to: "v".into()
            }
        );
        vm.feed_session(SessionEvent::SwitchDone {
            account: "v".into(),
        });
        assert_eq!(vm.session().active_account(), Some("v"));
    }

    #[test]
    fn unreachable_server_fails_the_session_and_cancel_returns() {
        let mut vm = vm();
        vm.handle(LoginIntent::EditAddress("a.example.de".into()));
        let mut next = vm.handle(LoginIntent::Connect);
        let down = ErrorKind::Http {
            status: 500,
            body: None,
        };
        while let Some(LoginEffect::CheckAddress { mark, .. }) = next.pop() {
            assert!(matches!(vm.session(), AccountSession::Connecting { .. }));
            next = vm.handle(LoginIntent::AddressChecked {
                mark,
                result: Err(down.clone()),
            });
        }
        assert!(matches!(vm.session(), AccountSession::Failed { .. }));
        // Adding an account while signed in: failure returns to the active account.
        let mut vm2 = self::vm();
        vm2.set_session(AccountSession::Ready {
            account: "u".into(),
        });
        vm2.handle(LoginIntent::EditAddress("a.example.de".into()));
        vm2.handle(LoginIntent::Connect);
        assert!(matches!(
            vm2.session(),
            AccountSession::Connecting { from: Some(_), .. }
        ));
        vm2.handle(LoginIntent::EditAddress("b".into()));
        assert_eq!(
            vm2.session(),
            &AccountSession::Ready {
                account: "u".into()
            }
        );
    }

    #[test]
    fn a_checked_address_leads_to_user_and_password_and_is_remembered() {
        let mut vm = vm();
        checked(&mut vm);
        let p = vm.part();
        assert_eq!((p.screen, p.working), (LoginScreen::Credentials, false));
        assert_eq!(p.server_name.as_deref(), Some("Wohnzimmer"));
        let last = vm.last_server().unwrap();
        assert_eq!(
            (
                last.address.as_str(),
                last.name.as_str(),
                last.version.as_str()
            ),
            ("http://192.168.1.5:8096", "Wohnzimmer", "10.9.0")
        );
        assert_eq!(
            vm.server_name_for("HTTP://192.168.1.5:8096").as_deref(),
            Some("Wohnzimmer")
        );
    }

    #[test]
    fn the_stored_last_server_uses_the_german_keys() {
        let mut vm = vm();
        vm.remember_server("http://a", "A", "1");
        let raw = vm.settings.get(&keys::LETZTER_SERVER).unwrap();
        assert_eq!(
            String::from_utf8(raw).unwrap(),
            r#"{"adresse":"http://a","name":"A","version":"1"}"#
        );
        let again = LoginVm::new(MemoryStore::new(), Locale::parse("de"));
        assert!(again.part().last.is_none());
    }

    #[test]
    fn the_host_name_is_not_cached_as_a_server_name() {
        let vm = vm();
        vm.cache_server_name("tv.example.de", "https://tv.example.de");
        vm.cache_server_name("", "https://x.de");
        assert!(vm.server_name_for("https://tv.example.de").is_none());
        assert!(vm.server_name_for("https://x.de").is_none());
    }

    #[test]
    fn an_old_answer_is_discarded() {
        let mut vm = vm();
        vm.handle(LoginIntent::EditAddress("a.example.de".into()));
        let Some(LoginEffect::CheckAddress { mark: old, .. }) =
            vm.handle(LoginIntent::Connect).pop()
        else {
            panic!()
        };
        vm.handle(LoginIntent::EditAddress("b.example.de".into()));
        vm.handle(LoginIntent::AddressChecked {
            mark: old,
            result: Ok(info("A")),
        });
        assert_eq!(vm.part().screen, LoginScreen::Address);
        assert!(vm.last_server().is_none());
    }

    #[test]
    fn an_unusable_address_says_so_without_a_call() {
        let mut vm = vm();
        vm.handle(LoginIntent::EditAddress("   ".into()));
        assert!(vm.handle(LoginIntent::Connect).is_empty());
        assert!(vm.part().error.is_some() && !vm.part().working);
    }

    #[test]
    fn https_failing_at_the_connection_tries_http_once() {
        let mut vm = vm();
        vm.handle(LoginIntent::EditAddress("tv.example.de".into()));
        let Some(LoginEffect::CheckAddress { mark, url }) = vm.handle(LoginIntent::Connect).pop()
        else {
            panic!()
        };
        assert_eq!(url, "https://tv.example.de");
        let down = ErrorKind::Network { code: -1004 };
        let Some(LoginEffect::CheckAddress { mark: second, url }) = vm
            .handle(LoginIntent::AddressChecked {
                mark,
                result: Err(down.clone()),
            })
            .pop()
        else {
            panic!("no second try")
        };
        assert_eq!(url, "http://tv.example.de");
        assert!(
            vm.handle(LoginIntent::AddressChecked {
                mark: second,
                result: Err(down)
            })
            .is_empty()
        );
        assert!(vm.part().error.is_some() && !vm.part().working);
    }

    #[test]
    fn signing_in_needs_a_user_and_ends_with_the_session() {
        let mut vm = vm();
        checked(&mut vm);
        assert!(!vm.part().can_sign_in);
        assert!(vm.handle(LoginIntent::SignIn).is_empty());
        vm.handle(LoginIntent::EditUser(" Anna ".into()));
        vm.handle(LoginIntent::EditPassword("geheim".into()));
        assert!(vm.part().can_sign_in);
        assert_eq!(
            vm.handle(LoginIntent::SignIn),
            vec![LoginEffect::Authenticate {
                url: "http://192.168.1.5:8096".into(),
                user: "Anna".into(),
                password: "geheim".into()
            }]
        );
        assert!(vm.part().working);
        let done = vm.handle(LoginIntent::SignedIn(Ok(session())));
        assert_eq!(done, vec![LoginEffect::Done(session())]);
        assert_eq!(vm.part().password, "");
    }

    #[test]
    fn a_wrong_password_shows_a_message_and_keeps_the_fields() {
        let mut vm = vm();
        checked(&mut vm);
        vm.handle(LoginIntent::EditUser("Anna".into()));
        vm.handle(LoginIntent::SignIn);
        vm.handle(LoginIntent::SignedIn(Err(ErrorKind::Http {
            status: 401,
            body: None,
        })));
        assert!(vm.part().error.is_some() && !vm.part().working);
        assert_eq!(vm.part().user, "Anna");
    }

    #[test]
    fn quick_connect_goes_through_code_wait_and_sign_in() {
        let mut vm = vm();
        checked(&mut vm);
        assert!(
            vm.handle(LoginIntent::UseQuickConnect).is_empty(),
            "not offered yet"
        );
        vm.handle(LoginIntent::QuickConnectOffered(true));
        assert_eq!(
            vm.handle(LoginIntent::UseQuickConnect),
            vec![LoginEffect::StartQuickConnect]
        );
        let code = LoginCode {
            code: "123456".into(),
            confidential: "secret".into(),
        };
        vm.handle(LoginIntent::QuickConnectStarted(Ok(code.clone())));
        assert_eq!(vm.part().quick_code.as_deref(), Some("123456"));
        assert!(
            vm.handle(LoginIntent::QuickConnectState(QuickConnectState::Opened))
                .is_empty()
        );
        assert_eq!(
            vm.handle(LoginIntent::QuickConnectState(QuickConnectState::Released)),
            vec![LoginEffect::SignInWithQuickConnect(code)]
        );
        assert_eq!(
            vm.handle(LoginIntent::SignedIn(Ok(session()))),
            vec![LoginEffect::Done(session())]
        );
    }

    #[test]
    fn an_expired_code_returns_to_the_password_step_with_a_message() {
        let mut vm = vm();
        checked(&mut vm);
        vm.handle(LoginIntent::QuickConnectOffered(true));
        vm.handle(LoginIntent::UseQuickConnect);
        vm.handle(LoginIntent::QuickConnectStarted(Ok(LoginCode {
            code: "1".into(),
            confidential: "c".into(),
        })));
        vm.handle(LoginIntent::QuickConnectState(QuickConnectState::Expired));
        let p = vm.part();
        assert_eq!(p.screen, LoginScreen::Credentials);
        assert!(p.error.is_some() && p.quick_code.is_none() && !p.working);
    }

    #[test]
    fn back_walks_the_steps_in_reverse() {
        let mut vm = vm();
        checked(&mut vm);
        vm.handle(LoginIntent::QuickConnectOffered(true));
        vm.handle(LoginIntent::UseQuickConnect);
        vm.handle(LoginIntent::Back);
        assert_eq!(vm.part().screen, LoginScreen::Credentials);
        vm.handle(LoginIntent::Back);
        assert_eq!(vm.part().screen, LoginScreen::Address);
        vm.handle(LoginIntent::Back);
        assert_eq!(vm.part().screen, LoginScreen::Address);
    }

    #[test]
    fn found_servers_hide_the_one_in_the_field_and_fill_the_field_when_picked() {
        let mut vm = vm();
        let a = FoundServer {
            id: "1".into(),
            name: "Büro".into(),
            address: "http://10.0.0.2:8096".into(),
        };
        let b = FoundServer {
            id: "2".into(),
            name: "Wohnzimmer".into(),
            address: "http://192.168.1.5:8096".into(),
        };
        vm.handle(LoginIntent::Discovered(vec![b, a]));
        assert_eq!(vm.part().found.len(), 2);
        vm.handle(LoginIntent::EditAddress("192.168.1.5:8096".into()));
        assert_eq!(
            vm.part()
                .found
                .iter()
                .map(|s| s.id.as_str())
                .collect::<Vec<_>>(),
            ["1"]
        );
        vm.handle(LoginIntent::PickServer("1".into()));
        assert_eq!(vm.part().address, "http://10.0.0.2:8096");
    }

    #[test]
    fn the_last_server_can_be_reused() {
        let mut vm = vm();
        vm.remember_server("http://192.168.1.5:8096", "Wohnzimmer", "10.9.0");
        vm.handle(LoginIntent::UseLast);
        assert_eq!(vm.part().address, "http://192.168.1.5:8096");
    }

    #[test]
    fn revoked_message_names_the_next_account_or_asks_to_sign_in_again() {
        let tr = Translator::new(Locale::parse("de"));
        let next = RevokedOutcome {
            dropped_name: "Ben".into(),
            now_name: Some("Anna".into()),
            now_key: None,
        };
        assert_eq!(
            revoked_message(&tr, &next),
            "Die Anmeldung von Ben gilt nicht mehr. Jetzt angemeldet als Anna."
        );
        let none = RevokedOutcome {
            dropped_name: "Ben".into(),
            now_name: None,
            now_key: None,
        };
        assert_eq!(
            revoked_message(&tr, &none),
            "Die Anmeldung gilt nicht mehr. Bitte neu anmelden."
        );
    }

    #[test]
    fn plex_link_carries_the_page_and_the_code() {
        let page = Url::parse("https://plex.tv/link").unwrap();
        let link = plex_link(Some(&page), "ABCD").unwrap();
        assert_eq!(
            (
                link.page.as_str(),
                link.code.as_str(),
                link.qr_payload.as_str()
            ),
            ("https://plex.tv/link", "ABCD", "https://plex.tv/link")
        );
        assert!(plex_link(None, "ABCD").is_none() && plex_link(Some(&page), "").is_none());
    }
}
