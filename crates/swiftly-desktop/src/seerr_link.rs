//! The Seerr connection behind the Settings page (`SeerrModel.swift`): connect with address, name and password,
//! show the session state, disconnect. The page talks to [`SeerrLink`]; the demo uses [`ScriptedSeerr`], the real app
//! [`LiveSeerr`] over `swiftly-seerr` (the session is kept per server in `settings.json` under `seerr|<server>` and travels with the settings sync, never the password).

use std::sync::{Arc, Mutex};
use swiftly_jellyfin::OwnHeader;
use swiftly_net::ErrorKind;
use swiftly_seerr::{
    NoCookies, SeerrAccess, SeerrClient, SeerrSessionState, SignInCause, SignInKind, SignInMethod,
};

/// The shared transport of the app as an owned value for the client.
pub struct Shared(pub(crate) Arc<crate::net::AppTransport>);

impl swiftly_net::HttpTransport for Shared {
    async fn send(
        &self,
        request: swiftly_net::HttpRequest,
    ) -> Result<swiftly_net::HttpResponse, ErrorKind> {
        self.0.send(request).await
    }
}

/// What the page shows about the connection.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SeerrConn {
    /// A session is stored.
    pub connected: bool,
    /// Its address.
    pub address: String,
    /// "Aktiv", "Sitzung abgelaufen" or "Seerr nicht erreichbar" (empty until looked up).
    pub session: String,
    /// A connect is running ("Verbinde…").
    pub busy: bool,
    /// The last error, in German.
    pub error: Option<String>,
}

/// The connection as the Settings page uses it.
pub trait SeerrLink {
    /// The current state (polled every frame; cheap).
    fn state(&self) -> SeerrConn;
    /// Connects; the result shows in [`state`](SeerrLink::state).
    fn connect(&self, address: &str, user: &str, password: &str, headers: Vec<(String, String)>);
    /// Connects with any of the three ways (Jellyfin account, Seerr e-mail account, Plex token). The page
    /// offers the other two once its forms exist; until then only `connect` is called.
    fn connect_as(&self, address: &str, kind: SignInKind, headers: Vec<(String, String)>) {
        if let SignInKind::Jellyfin { user, password } = kind {
            self.connect(address, &user, &password, headers);
        }
    }
    /// Removes the stored session (nothing changes at Seerr itself).
    fn disconnect(&self);
    /// Looks the stored session up again when the page opens (`seerr.lookUp()`), so the row says "Aktiv" or why not.
    fn look_up(&self) {}
}

/// The German word of a session state (`SeerrSettingsView.sessionText`).
pub fn session_word(s: SeerrSessionState) -> &'static str {
    match s {
        SeerrSessionState::Valid => swiftly_l10n::tr("Aktiv"),
        SeerrSessionState::Invalid => swiftly_l10n::tr("Sitzung abgelaufen"),
        SeerrSessionState::Unreachable => swiftly_l10n::tr("Seerr nicht erreichbar"),
    }
}

/// The German sentence of a failed sign-in: the core's cause words (`swiftly_vm::cause_text`), the same on every platform.
fn say(e: &ErrorKind, method: SignInMethod) -> String {
    swiftly_vm::cause_text(
        &swiftly_l10n::Translator::new(swiftly_l10n::current_locale()),
        &SignInCause::classify(e, method),
    )
}

/// The scripted Seerr of the demo: a password of "falsch" fails, anything else connects.
#[derive(Default)]
pub struct ScriptedSeerr(Mutex<SeerrConn>);

impl SeerrLink for ScriptedSeerr {
    fn state(&self) -> SeerrConn {
        self.0.lock().map(|g| g.clone()).unwrap_or_default()
    }
    fn connect(&self, address: &str, _user: &str, password: &str, _headers: Vec<(String, String)>) {
        let mut s = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if password == "falsch" {
            s.error = Some(swiftly_l10n::tr("Name oder Passwort stimmen nicht.").into());
        } else {
            *s = SeerrConn {
                connected: true,
                address: swiftly_seerr::Seerr::address(address)
                    .unwrap_or_else(|| address.to_owned()),
                session: swiftly_l10n::tr("Aktiv").into(),
                busy: false,
                error: None,
            };
        }
    }
    fn disconnect(&self) {
        *self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = SeerrConn::default();
    }
}

/// Seerr over the real transport; the stored session lives in the settings file.
pub struct LiveSeerr {
    core: Arc<crate::live::Core>,
    now: Arc<Mutex<SeerrConn>>,
}

impl LiveSeerr {
    /// Reads the stored session and checks it in the background.
    pub fn new(core: Arc<crate::live::Core>) -> LiveSeerr {
        let now = Arc::new(Mutex::new(SeerrConn::default()));
        let stored = core.seerr_stored();
        let link = LiveSeerr { core, now };
        link.check(stored);
        link
    }

    /// Shows the stored session as connected and asks Seerr in the background whether it still works.
    fn check(&self, stored: Option<SeerrAccess>) {
        let Some(access) = stored else { return };
        if let Ok(mut s) = self.now.lock() {
            *s = SeerrConn {
                connected: true,
                address: access.address.clone(),
                ..SeerrConn::default()
            };
        }
        let (net, out) = (Arc::clone(&self.core.net), Arc::clone(&self.now));
        self.core.spawn(async move {
            let word = session_word(
                SeerrClient::with_jar(access, Shared(net), NoCookies)
                    .applies()
                    .await,
            );
            if let Ok(mut s) = out.lock() {
                s.session = word.into();
            }
        });
    }
}

impl SeerrLink for LiveSeerr {
    fn state(&self) -> SeerrConn {
        self.now.lock().map(|g| g.clone()).unwrap_or_default()
    }
    fn connect(&self, address: &str, user: &str, password: &str, headers: Vec<(String, String)>) {
        let kind = SignInKind::Jellyfin {
            user: user.to_owned(),
            password: password.to_owned(),
        };
        self.connect_as(address, kind, headers);
    }
    fn connect_as(&self, address: &str, kind: SignInKind, headers: Vec<(String, String)>) {
        if let Ok(mut s) = self.now.lock() {
            if s.busy {
                return;
            }
            s.busy = true;
            s.error = None;
        }
        let (net, out, core) = (
            Arc::clone(&self.core.net),
            Arc::clone(&self.now),
            Arc::clone(&self.core),
        );
        let typed = address.to_owned();
        let headers: Vec<OwnHeader> = headers.iter().map(|(n, v)| OwnHeader::new(n, v)).collect();
        self.core.spawn(async move {
            let result =
                SeerrClient::sign_in_typed_with(&Shared(net), &NoCookies, &typed, &kind, &headers)
                    .await;
            let Ok(mut s) = out.lock() else { return };
            s.busy = false;
            match result {
                Ok(access) => {
                    core.seerr_set(Some(&access));
                    *s = SeerrConn {
                        connected: true,
                        address: access.address,
                        session: swiftly_l10n::tr("Aktiv").into(),
                        busy: false,
                        error: None,
                    };
                }
                Err(e) => s.error = Some(say(&e, kind.method())),
            }
        });
    }
    fn look_up(&self) {
        let stored = self.core.seerr_stored();
        // Not while a sign-in runs: it would overwrite the answer.
        if !self.now.lock().is_ok_and(|s| s.busy) {
            self.check(stored);
        }
    }
    fn disconnect(&self) {
        self.core.seerr_set(None);
        if let Ok(mut s) = self.now.lock() {
            *s = SeerrConn::default();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scripted_connect_fails_then_works_then_disconnects() {
        let s = ScriptedSeerr::default();
        s.connect("seerr.example.de", "paul", "falsch", vec![]);
        assert!(!s.state().connected);
        assert!(s.state().error.is_some());
        s.connect("seerr.example.de", "paul", "richtig", vec![]);
        assert!(s.state().connected);
        assert_eq!(s.state().session, "Aktiv");
        s.disconnect();
        assert_eq!(s.state(), SeerrConn::default());
    }
}
