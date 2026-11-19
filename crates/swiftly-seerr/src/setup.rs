//! Seerr sign-in and setup: the three ways in (`auth/jellyfin`, `auth/local`, `auth/plex`), the
//! per-server configuration and ONE state machine, [`SeerrSetup`].
//!
//! * Who may type the address: the admin of the media server, once per server. The address (and the
//!   user's own gateway headers) is a [`SeerrServerConfig`], stored with the server and synced through
//!   the settings sync (`seerrServer`, per server). Every other profile of that server only signs in:
//!   its state carries [`AddressEntry::Known`], never an address field.
//! * One state enum, every move in [`SeerrSetup::transition`]: not connected, signing in, failed (with
//!   a typed [`SignInCause`] the screen words), connected.
//! * Passwords and tokens only pass through [`SignInKind`] into the request body; their `Debug` is
//!   redacted and no state, cause or log holds them.
//!
//! UI per state: `NotConnected` = the sign-in form (address row only for [`AddressEntry::Ask`]),
//! `SigningIn` = loading, `Failed` = the cause's sentence over the form again, `Connected` = the
//! connected row with "Trennen".

use serde::{Deserialize, Serialize};
use swiftly_jellyfin::OwnHeader;
use swiftly_net::{ErrorKind, HttpTransport};

use crate::client::{CookieJar, NO_SESSION, SeerrClient, SeerrSessionState};
use crate::mapping::Seerr;
use crate::models::SeerrAccess;

/// Which account the user signs in with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SignInMethod {
    /// The media server's Jellyfin (or Emby) account: name and password.
    Jellyfin,
    /// A Seerr account of its own: e-mail and password.
    Local,
    /// A Plex account: the plex.tv token.
    Plex,
}

/// The credentials of one sign-in. The secrets never show in `Debug`.
#[derive(Clone, PartialEq, Eq)]
pub enum SignInKind {
    /// `POST auth/jellyfin` `{username, password}`.
    Jellyfin {
        /// The media server's user name.
        user: String,
        /// Its password.
        password: String,
    },
    /// `POST auth/local` `{email, password}`.
    Local {
        /// The e-mail address of the Seerr account.
        email: String,
        /// Its password.
        password: String,
    },
    /// `POST auth/plex` `{authToken}`.
    Plex {
        /// The plex.tv account token.
        token: String,
    },
}

impl std::fmt::Debug for SignInKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SignInKind::{:?}(..)", self.method())
    }
}

impl SignInKind {
    /// Which way in this is.
    pub fn method(&self) -> SignInMethod {
        match self {
            Self::Jellyfin { .. } => SignInMethod::Jellyfin,
            Self::Local { .. } => SignInMethod::Local,
            Self::Plex { .. } => SignInMethod::Plex,
        }
    }

    /// The API path below `/api/v1/`.
    pub(crate) fn path(&self) -> &'static str {
        match self {
            Self::Jellyfin { .. } => "auth/jellyfin",
            Self::Local { .. } => "auth/local",
            Self::Plex { .. } => "auth/plex",
        }
    }

    /// The JSON body of the call.
    pub(crate) fn body(&self) -> serde_json::Value {
        match self {
            Self::Jellyfin { user, password } => {
                serde_json::json!({ "username": user, "password": password })
            }
            Self::Local { email, password } => {
                serde_json::json!({ "email": email, "password": password })
            }
            Self::Plex { token } => serde_json::json!({ "authToken": token }),
        }
    }
}

/// What the admin sets up once per server: where Seerr is, and the headers of a gateway in front of it.
/// Stored with the server (settings key `seerrServer`, per server, synced); no secret session in it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SeerrServerConfig {
    /// The cleaned base address without `/api`.
    pub address: String,
    /// The gateway headers (Cloudflare Access, Authelia, ...); empty for almost everyone.
    #[serde(default)]
    pub headers: Vec<OwnHeader>,
}

impl SeerrServerConfig {
    /// A configuration from what the admin typed; `None` for an address that cannot be used.
    pub fn typed(address: &str, headers: &[OwnHeader]) -> Option<Self> {
        Some(Self {
            address: Seerr::address(address)?,
            headers: headers.to_vec(),
        })
    }

    /// The configuration a working connection implies.
    pub fn of(access: &SeerrAccess) -> Self {
        Self {
            address: access.address.clone(),
            headers: access.headers.clone(),
        }
    }

    /// The value to store.
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    /// Reads a stored value; `None` for anything else (empty, damaged, an empty address).
    pub fn from_json(bytes: &[u8]) -> Option<Self> {
        let c: Self = serde_json::from_slice(bytes).ok()?;
        (!c.address.trim().is_empty()).then_some(c)
    }
}

/// Why a sign-in did not work. Typed so every UI words it the same way (core words in `swiftly-vm`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignInCause {
    /// The address cannot be used.
    BadAddress,
    /// No answer, a timeout, or a gateway error (502/503/504).
    Unreachable,
    /// The certificate is not trusted.
    Certificate,
    /// A login page of a gateway answered, not Seerr.
    LoginPage,
    /// 404: no Seerr at this address.
    NoSeerr,
    /// 401, or 403 of a password: the name, e-mail or password is wrong (Plex: the token was refused).
    Wrong(SignInMethod),
    /// 403: the account is known but has no access (Seerr blocks new Plex or Jellyfin users).
    NoAccess(SignInMethod),
    /// Seerr switched this way of signing in off.
    Disabled(SignInMethod),
    /// The automatic sign-in with the media server's account was refused: this Seerr user is a local or
    /// Plex account (or Seerr does not use this media server). Ask for the other ways.
    NotViaMediaServer,
    /// Seerr itself cannot reach its media server (500 with that message).
    MediaServerUnreachable,
    /// Signed in but Seerr sent no session.
    NoSession,
    /// Any other 4xx/5xx of Seerr.
    ServerError(u16),
}

fn message_of(body: Option<&str>) -> String {
    let Some(body) = body else {
        return String::new();
    };
    serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| {
            ["message", "error"]
                .iter()
                .find_map(|k| v.get(k).and_then(|m| m.as_str()).map(str::to_lowercase))
        })
        .unwrap_or_else(|| body.to_lowercase())
}

impl SignInCause {
    /// Sorts a raw failure of `auth/<method>` (see `SeerrClient::sign_in_with`).
    pub fn classify(error: &ErrorKind, method: SignInMethod) -> Self {
        use swiftly_net::TransportReason as R;
        match error {
            ErrorKind::InvalidServerUrl => Self::BadAddress,
            ErrorKind::Certificate(_) => Self::Certificate,
            ErrorKind::Transport(R::LoginPage) => Self::LoginPage,
            ErrorKind::Transport(R::Other(t)) if t == NO_SESSION => Self::NoSession,
            ErrorKind::Http { status, body } => {
                let text = message_of(body.as_deref());
                match *status {
                    404 => Self::NoSeerr,
                    _ if text.contains("disabled") => Self::Disabled(method),
                    _ if text.contains("cannot be reached") || text.contains("hostname") => {
                        Self::MediaServerUnreachable
                    }
                    401 => Self::Wrong(method),
                    // Overseerr/Jellyseerr answer a wrong e-mail or password with 403 "Access denied".
                    403 if method == SignInMethod::Plex || text.contains("admin") => {
                        Self::NoAccess(method)
                    }
                    403 => Self::Wrong(method),
                    502..=504 => Self::Unreachable,
                    other => Self::ServerError(other),
                }
            }
            _ => Self::Unreachable,
        }
    }
}

/// What is being tried.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Attempt {
    /// The stored session is being looked up (`auth/me`).
    Session,
    /// Signing in by itself with the media server account's own credentials.
    Automatic,
    /// The user's own choice.
    By(SignInMethod),
}

/// Where the address comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AddressEntry {
    /// Nothing set up for this server and the user is its admin: show the address row.
    Ask,
    /// Set up already: no address row, the user only signs in. `editable` = the admin may change it.
    Known {
        /// The address.
        address: String,
        /// The admin may change it ("Adresse ändern").
        editable: bool,
    },
    /// Nothing set up and the user is not the admin: say so; only the admin can set it up.
    NotSetUp,
}

impl AddressEntry {
    /// The entry for a server: what is stored and whether the user administers the media server.
    pub fn of(is_admin: bool, config: Option<&SeerrServerConfig>) -> Self {
        match (config, is_admin) {
            (Some(c), _) => Self::Known {
                address: c.address.clone(),
                editable: is_admin,
            },
            (None, true) => Self::Ask,
            (None, false) => Self::NotSetUp,
        }
    }
}

/// The one state of the Seerr sign-in screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SeerrSetup {
    /// Not connected: show the form.
    NotConnected {
        /// Address row or not.
        entry: AddressEntry,
    },
    /// A call is running: show loading.
    SigningIn {
        /// What is tried.
        attempt: Attempt,
        /// Address row or not.
        entry: AddressEntry,
    },
    /// The last try failed: the cause's sentence over the form.
    Failed {
        /// Why.
        cause: SignInCause,
        /// Address row or not.
        entry: AddressEntry,
    },
    /// Connected: the connection to keep (per profile; the cookie is the profile's own).
    Connected {
        /// The session.
        access: SeerrAccess,
        /// Address row or not (after "Trennen").
        entry: AddressEntry,
    },
}

/// What can happen to a [`SeerrSetup`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SetupEvent {
    /// The screen opens: whether the user administers the server, the stored per-server
    /// configuration and the profile's stored session.
    Begin {
        /// The signed-in media server account is an administrator.
        is_admin: bool,
        /// The per-server configuration, if the admin set it up.
        config: Option<SeerrServerConfig>,
        /// This profile's stored session.
        stored: Option<SeerrAccess>,
    },
    /// A sign-in starts (the user's choice, or the automatic one).
    Try(Attempt),
    /// The answer of `auth/me` for the stored session.
    Checked {
        /// What it said.
        state: SeerrSessionState,
        /// The session that was looked up.
        access: SeerrAccess,
    },
    /// A sign-in worked.
    Signed(SeerrAccess),
    /// A sign-in failed.
    Failed(SignInCause),
    /// The admin wants to change the address.
    EditAddress,
    /// "Trennen".
    Disconnect,
}

/// An event that does not fit the state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupRefused;

impl SeerrSetup {
    /// Before the screen opened.
    pub fn new() -> Self {
        Self::NotConnected {
            entry: AddressEntry::NotSetUp,
        }
    }

    /// The address row logic of any state.
    pub fn entry(&self) -> &AddressEntry {
        match self {
            Self::NotConnected { entry }
            | Self::SigningIn { entry, .. }
            | Self::Failed { entry, .. }
            | Self::Connected { entry, .. } => entry,
        }
    }

    /// The only place the state changes.
    ///
    /// # Errors
    /// [`SetupRefused`] for an event the state cannot take; the state stays with the caller's copy.
    pub fn transition(self, event: SetupEvent) -> Result<Self, SetupRefused> {
        use SeerrSetup as S;
        use SetupEvent as E;
        Ok(match (self, event) {
            // A new run starts from a resting state, never in the middle of one.
            (
                S::NotConnected { .. } | S::Failed { .. } | S::Connected { .. },
                E::Begin {
                    is_admin,
                    config,
                    stored,
                },
            ) => {
                let entry = AddressEntry::of(is_admin, config.as_ref());
                match stored {
                    Some(_) => S::SigningIn {
                        attempt: Attempt::Session,
                        entry,
                    },
                    None => S::NotConnected { entry },
                }
            }
            (
                S::NotConnected { entry } | S::Failed { entry, .. },
                E::Try(attempt @ (Attempt::Automatic | Attempt::By(_))),
            ) if entry != AddressEntry::NotSetUp => S::SigningIn { attempt, entry },
            (
                S::SigningIn {
                    attempt: Attempt::Session,
                    entry,
                },
                E::Checked { state, access },
            ) => match state {
                SeerrSessionState::Valid => S::Connected { access, entry },
                SeerrSessionState::Invalid => S::NotConnected { entry },
                SeerrSessionState::Unreachable => S::Failed {
                    cause: SignInCause::Unreachable,
                    entry,
                },
            },
            (S::SigningIn { attempt, entry }, E::Signed(access)) if attempt != Attempt::Session => {
                // The first sign-in of an admin fixes the address for the server.
                let entry = match entry {
                    AddressEntry::Ask => AddressEntry::Known {
                        address: access.address.clone(),
                        editable: true,
                    },
                    AddressEntry::Known { editable, .. } => AddressEntry::Known {
                        address: access.address.clone(),
                        editable,
                    },
                    AddressEntry::NotSetUp => AddressEntry::NotSetUp,
                };
                S::Connected { access, entry }
            }
            (S::SigningIn { attempt, entry }, E::Failed(cause)) if attempt != Attempt::Session => {
                let cause = match (attempt, cause) {
                    (
                        Attempt::Automatic,
                        SignInCause::Wrong(_) | SignInCause::NoAccess(_) | SignInCause::Disabled(_),
                    ) => SignInCause::NotViaMediaServer,
                    (_, cause) => cause,
                };
                S::Failed { cause, entry }
            }
            (
                S::NotConnected {
                    entry: AddressEntry::Known { editable: true, .. },
                }
                | S::Failed {
                    entry: AddressEntry::Known { editable: true, .. },
                    ..
                },
                E::EditAddress,
            ) => S::NotConnected {
                entry: AddressEntry::Ask,
            },
            (S::Connected { entry, .. }, E::Disconnect) => S::NotConnected { entry },
            _ => return Err(SetupRefused),
        })
    }
}

impl Default for SeerrSetup {
    fn default() -> Self {
        Self::new()
    }
}

/// Signs in with any of the three ways and returns the connection or the typed cause. The typed
/// address is tried with its schemes and ports (`Seerr::addresses`).
pub async fn sign_in<T: HttpTransport, J: CookieJar>(
    transport: &T,
    jar: &J,
    typed: &str,
    kind: &SignInKind,
    headers: &[OwnHeader],
) -> Result<SeerrAccess, SignInCause> {
    SeerrClient::<T, J>::sign_in_typed_with(transport, jar, typed, kind, headers)
        .await
        .map_err(|e| SignInCause::classify(&e, kind.method()))
}

/// Looks the stored session up (`auth/me`).
pub async fn check_session<T: HttpTransport, J: CookieJar>(
    transport: &T,
    access: &SeerrAccess,
) -> SeerrSessionState {
    SeerrClient::<T, J>::session_state(transport, access).await
}
