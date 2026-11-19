//! The Seerr sign-in and setup screen as one view model: drives the core state machine
//! (`swiftly_seerr::SeerrSetup`), runs the calls over the host's transport and words every state.
//!
//! The host's part is small: pass who the user is (admin or not, the per-server configuration, the
//! stored session, and how to sign in by itself), show [`SeerrSetupInfo`] after each await and store
//! what [`SeerrSetupVm::connection`] and `SeerrSetupInfo::server_config` hand back (the session per
//! profile in the secret store, the configuration per server in the setting `seerrServer`).

use std::sync::{Mutex, MutexGuard, PoisonError};

use swiftly_jellyfin::OwnHeader;
use swiftly_l10n::{Arg, Locale, Translator};
use swiftly_net::HttpTransport;
use swiftly_seerr::setup::{check_session, sign_in};
use swiftly_seerr::{
    AddressEntry, Attempt, CookieJar, Seerr, SeerrAccess, SeerrServerConfig, SeerrSetup,
    SetupEvent, SignInCause, SignInKind, SignInMethod,
};

/// The four states of the screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SetupPhase {
    /// Show the form.
    NotConnected,
    /// Show loading.
    SigningIn,
    /// Show the cause over the form.
    Failed,
    /// Show the connected row.
    Connected,
}

/// Whether the screen asks for the address.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SetupEntry {
    /// Address field (the admin, nothing set up yet or after "Adresse ändern").
    AskAddress,
    /// No address field: the address is set up for this server.
    KnownAddress,
    /// Nothing set up and the user cannot set it up: one sentence.
    NotSetUp,
}

/// One way to sign in, as a form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupMethodRow {
    /// Which call.
    pub method: SignInMethod,
    /// The row's title.
    pub title: String,
    /// Label of the first field ("Name", "E-Mail"); none for Plex (the token comes from the Plex sign-in).
    pub user_label: Option<String>,
    /// A password field follows.
    pub needs_password: bool,
}

/// What the screen shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeerrSetupInfo {
    /// Counts up with every change.
    pub version: u64,
    /// The state.
    pub phase: SetupPhase,
    /// Address field or not.
    pub entry: SetupEntry,
    /// The address (set up or connected).
    pub address: Option<String>,
    /// The admin may change the address ("Adresse ändern").
    pub can_edit_address: bool,
    /// The ways to sign in (empty while signing in, connected or not set up).
    pub methods: Vec<SetupMethodRow>,
    /// The loading line.
    pub busy: Option<String>,
    /// The sentence of the failure.
    pub error: Option<String>,
    /// The sentence for [`SetupEntry::NotSetUp`].
    pub not_set_up: Option<String>,
    /// The per-server configuration to store now (set after the admin's first working sign-in).
    pub server_config: Option<String>,
}

/// The sentence of a failed sign-in.
pub fn cause_text(t: &Translator, cause: &SignInCause) -> String {
    use SignInMethod as M;
    match cause {
        SignInCause::BadAddress => t.t("Das ist keine gültige Adresse."),
        SignInCause::Unreachable => t.t("Seerr antwortet nicht. Stimmt die Adresse?"),
        SignInCause::Certificate => t.t("Dem Zertifikat wird nicht vertraut."),
        SignInCause::LoginPage => {
            t.t("Vor Seerr sitzt eine Anmeldeseite. Unter Erweitert kannst du Header setzen.")
        }
        SignInCause::NoSeerr => t.t("Unter dieser Adresse antwortet kein Seerr."),
        SignInCause::Wrong(M::Jellyfin) => t.t("Name oder Passwort stimmen nicht."),
        SignInCause::Wrong(M::Local) => t.t("E-Mail oder Passwort stimmen nicht."),
        SignInCause::Wrong(M::Plex) => {
            t.t("Plex hat die Anmeldung nicht angenommen. Melde dich bei Plex neu an.")
        }
        SignInCause::NoAccess(M::Plex) => {
            t.t("Dein Plex-Konto hat bei Seerr keinen Zugang. Frag die Person, die Seerr verwaltet.")
        }
        SignInCause::NoAccess(_) => {
            t.t("Dein Konto hat bei Seerr keinen Zugang. Frag die Person, die Seerr verwaltet.")
        }
        SignInCause::Disabled(M::Jellyfin) => {
            t.t("Bei diesem Seerr ist die Anmeldung mit Jellyfin abgeschaltet.")
        }
        SignInCause::Disabled(M::Local) => {
            t.t("Bei diesem Seerr ist die Anmeldung mit E-Mail und Passwort abgeschaltet.")
        }
        SignInCause::Disabled(M::Plex) => {
            t.t("Bei diesem Seerr ist die Anmeldung mit Plex abgeschaltet.")
        }
        SignInCause::NotViaMediaServer => t.t(
            "Seerr kennt dein Jellyfin-Konto nicht. Melde dich mit E-Mail und Passwort deines Seerr-Kontos an, oder mit Plex.",
        ),
        SignInCause::MediaServerUnreachable => {
            t.t("Seerr erreicht seinen eigenen Medienserver nicht.")
        }
        SignInCause::NoSession => t.t("Seerr hat keine Sitzung mitgegeben."),
        SignInCause::ServerError(status) => t.t_args(
            "Seerr meldet einen Fehler (%lld).",
            &[Arg::Int(i64::from(*status))],
        ),
    }
}

struct Inner {
    state: SeerrSetup,
    /// The per-server configuration in force (headers for the calls).
    config: Option<SeerrServerConfig>,
    /// Set after the admin typed the address and it worked: the host stores it per server.
    to_store: Option<SeerrServerConfig>,
    version: u64,
}

/// The Seerr sign-in screen. All methods take `&self`: the state sits behind a lock that is never held
/// across a call to Seerr.
pub struct SeerrSetupVm<T: HttpTransport, J: CookieJar> {
    transport: T,
    jar: J,
    words: Translator,
    inner: Mutex<Inner>,
}

impl<T: HttpTransport, J: CookieJar> SeerrSetupVm<T, J> {
    /// A screen over a transport and the platform's cookie jar (`NoCookies` where there is none).
    pub fn new(transport: T, jar: J, locale: &str) -> Self {
        Self {
            transport,
            jar,
            words: Translator::new(Locale::parse(locale)),
            inner: Mutex::new(Inner {
                state: SeerrSetup::new(),
                config: None,
                to_store: None,
                version: 0,
            }),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The only way the state moves; `false` when the machine refused the event.
    fn apply(&self, event: SetupEvent) -> bool {
        let mut g = self.lock();
        match g.state.clone().transition(event) {
            Ok(next) => {
                g.state = next;
                g.version += 1;
                true
            }
            Err(_) => false,
        }
    }

    /// The first, synchronous part of opening the screen, so the first `info()` is right: the entry
    /// (address row or not) and "looking up the stored session". Returns whether a session is looked up.
    pub fn begin(
        &self,
        is_admin: bool,
        config: Option<SeerrServerConfig>,
        stored: Option<SeerrAccess>,
    ) -> bool {
        let looking = stored.is_some();
        {
            let mut g = self.lock();
            g.config = config.clone();
            g.to_store = None;
        }
        self.apply(SetupEvent::Begin {
            is_admin,
            config,
            stored,
        }) && looking
    }

    /// Opens the screen to the end: looks the stored session up, else signs in by itself when the
    /// per-server address is known and `auto` yields the media server account's credentials (the host
    /// reads its secret store there, only now). Stops in `NotConnected` when `auto` has nothing.
    pub async fn start(
        &self,
        is_admin: bool,
        config: Option<SeerrServerConfig>,
        stored: Option<SeerrAccess>,
        auto: impl FnOnce() -> Option<SignInKind> + Send,
    ) {
        let looked_up = stored.clone();
        if self.begin(is_admin, config, stored)
            && let Some(access) = looked_up
        {
            let state = check_session::<T, J>(&self.transport, &access).await;
            self.apply(SetupEvent::Checked { state, access });
        }
        let known = match self.lock().state.clone() {
            SeerrSetup::NotConnected {
                entry: AddressEntry::Known { address, .. },
            } => Some(address),
            _ => None,
        };
        if let Some(address) = known
            && let Some(kind) = auto()
        {
            self.run(Attempt::Automatic, &address, kind).await;
        }
    }

    /// The user signs in. The address comes from the per-server configuration when there is one (the
    /// typed text and `headers` are then ignored); the admin's first sign-in uses what was typed.
    pub async fn sign_in(&self, typed: &str, headers: &[OwnHeader], kind: SignInKind) {
        let entry = self.lock().state.entry().clone();
        match entry {
            AddressEntry::NotSetUp => {}
            AddressEntry::Known { address, .. } => {
                self.run(Attempt::By(kind.method()), &address, kind).await;
            }
            AddressEntry::Ask => {
                if Seerr::addresses(typed).is_empty() {
                    self.apply(SetupEvent::Try(Attempt::By(kind.method())));
                    self.apply(SetupEvent::Failed(SignInCause::BadAddress));
                    return;
                }
                self.lock().config = SeerrServerConfig::typed(typed, headers);
                self.run(Attempt::By(kind.method()), typed, kind).await;
            }
        }
    }

    async fn run(&self, attempt: Attempt, typed: &str, kind: SignInKind) {
        if !self.apply(SetupEvent::Try(attempt)) {
            return;
        }
        let (asked, headers) = {
            let g = self.lock();
            (
                matches!(
                    &g.state,
                    SeerrSetup::SigningIn {
                        entry: AddressEntry::Ask,
                        ..
                    }
                ),
                g.config
                    .as_ref()
                    .map(|c| c.headers.clone())
                    .unwrap_or_default(),
            )
        };
        let result = sign_in(&self.transport, &self.jar, typed, &kind, &headers).await;
        match result {
            Ok(access) => {
                if asked {
                    self.lock().to_store = Some(SeerrServerConfig::of(&access));
                }
                self.apply(SetupEvent::Signed(access));
            }
            Err(cause) => {
                self.apply(SetupEvent::Failed(cause));
            }
        }
    }

    /// The admin wants to change the address.
    pub fn edit_address(&self) -> bool {
        self.apply(SetupEvent::EditAddress)
    }

    /// "Trennen": back to the form; the platform cookies of the address are forgotten here. The host deletes its stored session.
    pub fn disconnect(&self) -> bool {
        // A still-valid cookie in the platform store would stop Seerr from issuing a new session at the next sign-in.
        if let Some(access) = self.connection()
            && let Ok(url) = swiftly_net::Url::parse(&access.address)
        {
            self.jar.forget(&url);
        }
        self.apply(SetupEvent::Disconnect)
    }

    /// The session to keep once connected.
    pub fn connection(&self) -> Option<SeerrAccess> {
        match &self.lock().state {
            SeerrSetup::Connected { access, .. } => Some(access.clone()),
            _ => None,
        }
    }

    /// What the screen shows.
    pub fn info(&self) -> SeerrSetupInfo {
        let g = self.lock();
        let t = &self.words;
        let (phase, entry) = match &g.state {
            SeerrSetup::NotConnected { entry } => (SetupPhase::NotConnected, entry),
            SeerrSetup::SigningIn { entry, .. } => (SetupPhase::SigningIn, entry),
            SeerrSetup::Failed { entry, .. } => (SetupPhase::Failed, entry),
            SeerrSetup::Connected { entry, .. } => (SetupPhase::Connected, entry),
        };
        let (entry_kind, known, can_edit_address) = match entry {
            AddressEntry::Ask => (SetupEntry::AskAddress, None, false),
            AddressEntry::Known { address, editable } => {
                (SetupEntry::KnownAddress, Some(address.clone()), *editable)
            }
            AddressEntry::NotSetUp => (SetupEntry::NotSetUp, None, false),
        };
        let address = match &g.state {
            SeerrSetup::Connected { access, .. } => Some(access.address.clone()),
            _ => known,
        };
        let forms = matches!(phase, SetupPhase::NotConnected | SetupPhase::Failed)
            && entry_kind != SetupEntry::NotSetUp;
        SeerrSetupInfo {
            version: g.version,
            phase,
            entry: entry_kind,
            address,
            can_edit_address,
            methods: if forms {
                vec![
                    SetupMethodRow {
                        method: SignInMethod::Jellyfin,
                        title: t.t("Mit Jellyfin-Konto"),
                        user_label: Some(t.t("Name")),
                        needs_password: true,
                    },
                    SetupMethodRow {
                        method: SignInMethod::Local,
                        title: t.t("Mit E-Mail und Passwort"),
                        user_label: Some(t.t("E-Mail")),
                        needs_password: true,
                    },
                    SetupMethodRow {
                        method: SignInMethod::Plex,
                        title: t.t("Mit Plex"),
                        user_label: None,
                        needs_password: false,
                    },
                ]
            } else {
                Vec::new()
            },
            busy: match &g.state {
                SeerrSetup::SigningIn {
                    attempt: Attempt::Session,
                    ..
                } => Some(t.t("Prüfe die Anmeldung…")),
                SeerrSetup::SigningIn { .. } => Some(t.t("Melde an…")),
                _ => None,
            },
            error: match &g.state {
                SeerrSetup::Failed { cause, .. } => Some(cause_text(t, cause)),
                _ => None,
            },
            not_set_up: (entry_kind == SetupEntry::NotSetUp).then(|| {
                t.t("Seerr ist für diesen Server noch nicht eingerichtet. Das kann nur, wer den Server verwaltet.")
            }),
            server_config: g.to_store.as_ref().map(SeerrServerConfig::to_json),
        }
    }
}
