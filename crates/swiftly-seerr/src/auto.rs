//! Automatic Seerr sign-in with the Jellyfin account's own credentials (`POST auth/jellyfin`).
//!
//! One enum, every move in [`AutoSignIn::transition`]. The password only ever passes through the
//! `password` closure of [`auto_sign_in`] into the request body; no state, error or log holds it.
//!
//! UI per state: `NotConfigured` = nothing shown, `Checking` / `SigningIn` = loading,
//! `NoPassword` = ask for it (manual sign-in), `Rejected` = error with the readable text (never
//! retried by itself), `Unreachable` = offline hint, `SignedIn` = done.

use swiftly_jellyfin::OwnHeader;
use swiftly_net::{ErrorKind, HttpTransport};

use crate::client::{CookieJar, SeerrClient, SeerrSessionState};
use crate::models::SeerrAccess;

/// Where the automatic sign-in stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AutoSignIn {
    /// Nothing started.
    Idle,
    /// No Seerr set up for this server.
    NotConfigured,
    /// The stored session is being checked.
    Checking(SeerrAccess),
    /// A session is needed and the host has no password for the account.
    NoPassword,
    /// Signing in with the stored credentials.
    SigningIn,
    /// Done: the connection to store.
    SignedIn(SeerrAccess),
    /// Seerr said no (wrong credentials, no Seerr there, login page): shown, not retried.
    Rejected(String),
    /// Seerr could not be reached; the next start tries again.
    Unreachable,
}

/// What can happen to an [`AutoSignIn`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AutoEvent {
    /// Start: `configured` = a Seerr address is set; `stored` = the saved connection, if any.
    Begin {
        /// A Seerr address is set for the server.
        configured: bool,
        /// The saved connection.
        stored: Option<SeerrAccess>,
    },
    /// Answer of `auth/me` for the stored connection.
    Checked(SeerrSessionState),
    /// The host's answer whether it has a password for the account.
    Password(bool),
    /// `auth/jellyfin` worked.
    Signed(SeerrAccess),
    /// `auth/jellyfin` failed.
    Failed(ErrorKind),
}

/// An event that does not fit the state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutoRefused;

impl AutoSignIn {
    /// The only place the state changes.
    ///
    /// # Errors
    /// [`AutoRefused`] for an event the state cannot take; the state stays.
    pub fn transition(self, event: AutoEvent) -> Result<Self, AutoRefused> {
        Ok(match (self, event) {
            // A new run may start from any resting state, never in the middle of one.
            (
                Self::Idle
                | Self::NoPassword
                | Self::Rejected(_)
                | Self::Unreachable
                | Self::SignedIn(_)
                | Self::NotConfigured,
                AutoEvent::Begin { configured, stored },
            ) => match (configured, stored) {
                (false, _) => Self::NotConfigured,
                (true, Some(a)) => Self::Checking(a),
                (true, None) => Self::SigningIn,
            },
            (Self::Checking(a), AutoEvent::Checked(state)) => match state {
                SeerrSessionState::Valid => Self::SignedIn(a),
                SeerrSessionState::Invalid => Self::SigningIn,
                SeerrSessionState::Unreachable => Self::Unreachable,
            },
            (Self::SigningIn, AutoEvent::Password(false)) => Self::NoPassword,
            (Self::SigningIn, AutoEvent::Password(true)) => Self::SigningIn,
            (Self::SigningIn, AutoEvent::Signed(a)) => Self::SignedIn(a),
            (Self::SigningIn, AutoEvent::Failed(e)) => match e {
                ErrorKind::Network { .. } => Self::Unreachable,
                ErrorKind::Http { status, .. } if status >= 500 => Self::Unreachable,
                ErrorKind::Transport(swiftly_net::TransportReason::Other(text)) => {
                    Self::Rejected(text)
                }
                other => Self::Rejected(format!("{other:?}")),
            },
            _ => return Err(AutoRefused),
        })
    }
}

/// Runs the machine to a resting state: checks the stored session, else signs in with the
/// Jellyfin user name and the password `password` yields (the host reads its Keychain there).
/// Returns the final state; a `SignedIn` carries the connection to store.
pub async fn auto_sign_in<T: HttpTransport, J: CookieJar>(
    transport: &T,
    jar: &J,
    typed: &str,
    user: &str,
    stored: Option<SeerrAccess>,
    password: impl FnOnce() -> Option<String>,
    headers: &[OwnHeader],
) -> AutoSignIn {
    let step = |s: AutoSignIn, e: AutoEvent| s.transition(e).unwrap_or(AutoSignIn::Idle);
    let configured = !typed.trim().is_empty() || stored.is_some();
    let mut state = step(AutoSignIn::Idle, AutoEvent::Begin { configured, stored });
    if let AutoSignIn::Checking(a) = &state {
        let verdict = SeerrClient::<T, J>::session_state(transport, a).await;
        state = step(state, AutoEvent::Checked(verdict));
    }
    if state == AutoSignIn::SigningIn {
        let Some(secret) = password() else {
            return step(state, AutoEvent::Password(false));
        };
        state = step(state, AutoEvent::Password(true));
        let result =
            SeerrClient::<T, J>::sign_in_typed(transport, jar, typed, user, &secret, headers).await;
        state = step(
            state,
            match result {
                Ok(a) => AutoEvent::Signed(a),
                Err(e) => AutoEvent::Failed(e),
            },
        );
    }
    state
}
