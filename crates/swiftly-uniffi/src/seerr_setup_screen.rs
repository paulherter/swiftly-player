//! The Seerr sign-in and setup screen for the hosts: one state (not connected / signing in / failed /
//! connected), three ways in (Jellyfin account, Seerr e-mail account, Plex token), the address asked once
//! per server of the admin only. State, words and calls are the core's (`swiftly_vm::SeerrSetupVm`); a host
//! forwards the fields and redraws after each await.
//!
//! The host stores two things: `connection()` per profile in its secret store (`seerr|<account>`), and
//! `SeerrSetupInfo::server_config` per server in the setting `seerrServer` (synced, per server) and passes
//! it back as `config` on the next `start` of any profile of that server.
#![allow(clippy::module_name_repetitions)]

use std::sync::Arc;

use swiftly_jellyfin::OwnHeader;
use swiftly_seerr::{SeerrAccess, SeerrServerConfig, SignInKind, SignInMethod};
use swiftly_vm::{SeerrSetupInfo, SeerrSetupVm, SetupEntry, SetupMethodRow, SetupPhase};

use crate::error::CoreError;
use crate::seerr::{JarAdapter, SeerrConnection, SeerrCookieJar, SeerrPasswordSource};
use crate::transport::CoreTransport;

#[uniffi::remote(Enum)]
pub enum SignInMethod {
    Jellyfin,
    Local,
    Plex,
}

#[uniffi::remote(Enum)]
pub enum SetupPhase {
    NotConnected,
    SigningIn,
    Failed,
    Connected,
}

#[uniffi::remote(Enum)]
pub enum SetupEntry {
    AskAddress,
    KnownAddress,
    NotSetUp,
}

#[uniffi::remote(Record)]
pub struct SetupMethodRow {
    pub method: SignInMethod,
    pub title: String,
    pub user_label: Option<String>,
    pub needs_password: bool,
}

#[uniffi::remote(Record)]
pub struct SeerrSetupInfo {
    pub version: u64,
    pub phase: SetupPhase,
    pub entry: SetupEntry,
    pub address: Option<String>,
    pub can_edit_address: bool,
    pub methods: Vec<SetupMethodRow>,
    pub busy: Option<String>,
    pub error: Option<String>,
    pub not_set_up: Option<String>,
    pub server_config: Option<String>,
}

/// The Seerr sign-in and setup screen.
#[derive(uniffi::Object)]
pub struct SeerrSetupScreen {
    vm: SeerrSetupVm<CoreTransport, JarAdapter>,
}

impl SeerrSetupScreen {
    pub(crate) fn build(
        transport: CoreTransport,
        jar: Option<Arc<dyn SeerrCookieJar>>,
        locale: &str,
    ) -> Arc<Self> {
        Arc::new(Self {
            vm: SeerrSetupVm::new(transport, JarAdapter(jar), locale),
        })
    }
}

#[uniffi::export]
impl SeerrSetupScreen {
    /// What the screen shows; poll it after every await.
    pub fn info(&self) -> SeerrSetupInfo {
        self.vm.info()
    }

    /// Opens the screen. `config` is the per-server setting `seerrServer` (JSON, `None` = not set up),
    /// `stored` this profile's session. When no session works and the address is known, Seerr is signed
    /// in by itself: with the media server account (`user` plus the password of `secret`, read only then),
    /// else with `plex_token` of a Plex account. Otherwise the form shows.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn start(
        &self,
        is_admin: bool,
        config: Option<String>,
        stored: Option<SeerrConnection>,
        user: Option<String>,
        secret: Option<Arc<dyn SeerrPasswordSource>>,
        plex_token: Option<String>,
    ) -> Result<(), CoreError> {
        let config = config.and_then(|c| SeerrServerConfig::from_json(c.as_bytes()));
        let stored = stored.map(|c| SeerrAccess::new(&c.address, &c.cookie, &c.headers));
        self.vm
            .start(is_admin, config, stored, move || {
                if let (Some(user), Some(secret)) = (user, secret)
                    && let Some(password) = secret.password()
                {
                    return Some(SignInKind::Jellyfin { user, password });
                }
                plex_token.map(|token| SignInKind::Plex { token })
            })
            .await;
        Ok(())
    }

    /// Signs in with the media server's Jellyfin (or Emby) account. `typed` is only used for the admin's
    /// first sign-in of a server; `headers` are the gateway headers typed under Advanced.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn sign_in_jellyfin(
        &self,
        typed: String,
        headers: Vec<OwnHeader>,
        user: String,
        password: String,
    ) -> Result<(), CoreError> {
        self.vm
            .sign_in(&typed, &headers, SignInKind::Jellyfin { user, password })
            .await;
        Ok(())
    }

    /// Signs in with a Seerr account of its own (e-mail and password).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn sign_in_local(
        &self,
        typed: String,
        headers: Vec<OwnHeader>,
        email: String,
        password: String,
    ) -> Result<(), CoreError> {
        self.vm
            .sign_in(&typed, &headers, SignInKind::Local { email, password })
            .await;
        Ok(())
    }

    /// Signs in with a Plex account (the plex.tv token of the Plex sign-in).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn sign_in_plex(
        &self,
        typed: String,
        headers: Vec<OwnHeader>,
        token: String,
    ) -> Result<(), CoreError> {
        self.vm
            .sign_in(&typed, &headers, SignInKind::Plex { token })
            .await;
        Ok(())
    }

    /// The admin wants to change the address ("Adresse ändern").
    pub fn edit_address(&self) -> bool {
        self.vm.edit_address()
    }

    /// "Trennen": the platform cookies of the address are forgotten here; the host deletes its stored session.
    pub fn disconnect(&self) -> bool {
        self.vm.disconnect()
    }

    /// The session to keep (per profile) once connected.
    pub fn connection(&self) -> Option<SeerrConnection> {
        self.vm.connection().map(SeerrConnection::from)
    }
}
