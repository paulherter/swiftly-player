//! Seerr (Jellyseerr / Overseerr): search, details, requests, the person filmography and the
//! sign-in with an explicit cookie. The session cookie is part of [`SeerrConnection`], which the
//! host keeps in its secret store (`seerr|<account>`); the platform cookie jar is only the
//! fallback of the sign-in and is forgotten on sign-out.

use std::sync::Arc;

use swiftly_jellyfin::{OwnHeader, OwnHeaders};
use swiftly_net::Url;
use swiftly_seerr::{
    CookieJar, SeerrAccess, SeerrClient, SeerrDetail, SeerrHit, SeerrPerson, SeerrSeason,
    SeerrSessionState, SeerrState,
};

use crate::error::CoreError;
use crate::transport::CoreTransport;

#[uniffi::remote(Record)]
pub struct OwnHeader {
    pub name: String,
    pub value: String,
}

#[uniffi::remote(Enum)]
pub enum SeerrState {
    Opened,
    WaitsSharing,
    Loads,
    PartWayPresent,
    Present,
    Deleted,
}

#[uniffi::remote(Record)]
pub struct SeerrHit {
    pub id: i64,
    pub art: String,
    pub title: String,
    pub year: Option<i64>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    pub state: SeerrState,
}

#[uniffi::remote(Record)]
pub struct SeerrPerson {
    pub id: i64,
    pub name: String,
    pub role: Option<String>,
    pub image_path: Option<String>,
}

#[uniffi::remote(Record)]
pub struct SeerrSeason {
    pub number: i64,
    pub episodes: i64,
    pub state: SeerrState,
}

#[uniffi::remote(Record)]
pub struct SeerrDetail {
    pub description: Option<String>,
    pub genres: Vec<String>,
    pub runtime: Option<i64>,
    pub rating: Option<f64>,
    pub seasons: Vec<SeerrSeason>,
    pub cast: Vec<SeerrPerson>,
    pub similar_one: Vec<SeerrHit>,
    pub state: Option<SeerrState>,
}

#[uniffi::remote(Enum)]
pub enum SeerrSessionState {
    Valid,
    Invalid,
    Unreachable,
}

/// The stored connection of a Seerr: address and session cookie (`name=value`), plus the
/// user's own headers.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SeerrConnection {
    /// Base address without `/api`.
    pub address: String,
    /// The session cookie.
    pub cookie: String,
    /// The user's own headers.
    pub headers: Vec<OwnHeader>,
}

impl From<SeerrAccess> for SeerrConnection {
    fn from(a: SeerrAccess) -> Self {
        Self {
            address: a.address,
            cookie: a.cookie,
            headers: a.headers,
        }
    }
}

/// The platform's cookie store (`HTTPCookieStorage` on Apple). Optional: every call sends the
/// cookie of the connection itself.
#[uniffi::export(with_foreign)]
pub trait SeerrCookieJar: Send + Sync {
    /// The session cookie (`name=value`) the platform received for this address, if any.
    fn session_cookie(&self, address: String) -> Option<String>;
    /// Removes all cookies of this address.
    fn forget(&self, address: String);
}

/// The host's secret seam for the Jellyfin account's password (Keychain / Keystore). Read only
/// when a sign-in is needed; never logged.
#[uniffi::export(with_foreign)]
pub trait SeerrPasswordSource: Send + Sync {
    /// The stored password of the signed-in Jellyfin account, if the host has one.
    fn password(&self) -> Option<String>;
}

/// Where the automatic Seerr sign-in ended (one state, one UI each).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SeerrAutoState {
    /// No Seerr for this server: show nothing.
    NotConfigured,
    /// Signed in (stored session still valid, or a new one): store this connection.
    SignedIn { connection: SeerrConnection },
    /// The host has no password: ask the user (manual sign-in).
    NoPassword,
    /// Seerr said no: show the text, do not retry by itself.
    Rejected { message: String },
    /// Seerr not reachable: offline hint, try again later.
    Unreachable,
}

impl From<swiftly_seerr::AutoSignIn> for SeerrAutoState {
    fn from(s: swiftly_seerr::AutoSignIn) -> Self {
        use swiftly_seerr::AutoSignIn as A;
        match s {
            A::SignedIn(a) => Self::SignedIn {
                connection: a.into(),
            },
            A::NoPassword => Self::NoPassword,
            A::Rejected(message) => Self::Rejected { message },
            A::Unreachable | A::Checking(_) | A::SigningIn => Self::Unreachable,
            A::NotConfigured | A::Idle => Self::NotConfigured,
        }
    }
}

pub(crate) struct JarAdapter(Option<Arc<dyn SeerrCookieJar>>);

impl CookieJar for JarAdapter {
    fn session_cookie(&self, address: &Url) -> Option<String> {
        self.0.as_ref()?.session_cookie(address.to_string())
    }
    fn forget(&self, address: &Url) {
        if let Some(j) = &self.0 {
            j.forget(address.to_string());
        }
    }
}

pub(crate) fn readable(e: &swiftly_net::ErrorKind) -> CoreError {
    use swiftly_net::{ErrorKind, TransportReason};
    let message = match e {
        ErrorKind::Transport(TransportReason::Other(t)) => t.clone(),
        other => swiftly_l10n::error_text::readable_error(
            &swiftly_l10n::Translator::new(swiftly_l10n::Locale::parse("de")),
            other,
        ),
    };
    CoreError::Failed { message }
}

/// A Seerr connection to talk to.
#[derive(uniffi::Object)]
pub struct SeerrModel {
    client: SeerrClient<CoreTransport, JarAdapter>,
}

impl SeerrModel {
    /// The client, for the screens over the same connection.
    pub(crate) fn client(&self) -> &SeerrClient<CoreTransport, JarAdapter> {
        &self.client
    }

    pub(crate) fn build(
        transport: CoreTransport,
        connection: SeerrConnection,
        jar: Option<Arc<dyn SeerrCookieJar>>,
    ) -> Arc<Self> {
        let access = SeerrAccess::new(&connection.address, &connection.cookie, &connection.headers);
        Arc::new(Self {
            client: SeerrClient::with_jar(access, transport, JarAdapter(jar)),
        })
    }

    /// Checks the stored session; without a valid one signs in with the Jellyfin user name and the
    /// password of `secret` (`swiftly_seerr::auto_sign_in`).
    pub(crate) async fn auto_sign_in(
        transport: CoreTransport,
        jar: Option<Arc<dyn SeerrCookieJar>>,
        typed: &str,
        user: &str,
        stored: Option<SeerrConnection>,
        secret: Arc<dyn SeerrPasswordSource>,
        headers: &[OwnHeader],
    ) -> SeerrAutoState {
        let jar = JarAdapter(jar);
        let stored = stored.map(|c| SeerrAccess::new(&c.address, &c.cookie, &c.headers));
        swiftly_seerr::auto_sign_in(
            &transport,
            &jar,
            typed,
            user,
            stored,
            || secret.password(),
            headers,
        )
        .await
        .into()
    }

    /// Signs in with the Jellyfin user (`auth/jellyfin`), trying the typed address with the
    /// schemes and ports of `Seerr.addresses`.
    pub(crate) async fn sign_in(
        transport: CoreTransport,
        jar: Option<Arc<dyn SeerrCookieJar>>,
        typed: &str,
        user: &str,
        password: &str,
        headers: &[OwnHeader],
    ) -> Result<SeerrConnection, CoreError> {
        let jar = JarAdapter(jar);
        SeerrClient::<CoreTransport, JarAdapter>::sign_in_typed(
            &transport, &jar, typed, user, password, headers,
        )
        .await
        .map(SeerrConnection::from)
        .map_err(|e| readable(&e))
    }
}

#[uniffi::export]
impl SeerrModel {
    /// The address this model talks to.
    pub fn address(&self) -> String {
        self.client.address().to_owned()
    }

    /// Hits for a term, people left out by the caller's view (empty on any failure).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn search(&self, term: String) -> Result<Vec<SeerrHit>, CoreError> {
        Ok(self.client.searching(&term).await)
    }

    /// The detail of a title (`art` = `movie` or `tv`); `None` when the call failed.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn detail(&self, art: String, id: i64) -> Result<Option<SeerrDetail>, CoreError> {
        Ok(self.client.detail(&art, id).await)
    }

    /// Requests a title (`seasons` only for a series).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn ask_for(
        &self,
        art: String,
        id: i64,
        seasons: Option<Vec<i64>>,
    ) -> Result<(), CoreError> {
        self.client
            .ask_for(&art, id, seasons.as_deref())
            .await
            .map_err(|e| readable(&e))
    }

    /// The titles of a person (TMDB id) that Seerr knows.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn filmography(&self, person_tmdb: i64) -> Result<Vec<SeerrHit>, CoreError> {
        Ok(self.client.filmography(person_tmdb).await)
    }

    /// Whether the stored session still works.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn applies(&self) -> Result<SeerrSessionState, CoreError> {
        Ok(self.client.applies().await)
    }

    /// Forgets the platform cookies of this address (sign-out).
    pub fn forget_cookies(&self) {
        self.client.forget_cookies();
    }
}

/// Registers the user's own headers for a server address (an empty list removes them). The
/// core's HTTP path sends them with every request to that origin and path.
#[uniffi::export]
pub fn set_own_headers(server_url: String, headers: Vec<OwnHeader>) {
    if let Ok(base) = Url::parse(&server_url) {
        OwnHeaders::set_down(&headers, &base);
    }
}

/// The headers registered for exactly this server address.
#[uniffi::export]
pub fn own_headers_of(server_url: String) -> Vec<OwnHeader> {
    Url::parse(&server_url)
        .map(|u| OwnHeaders::registered(&u))
        .unwrap_or_default()
}

/// The headers cleaned like the Swift `OwnHeaders.cleaned`: locked names and bad names removed.
#[uniffi::export]
pub fn own_headers_cleaned(headers: Vec<OwnHeader>) -> Vec<OwnHeader> {
    OwnHeaders::cleaned(&headers)
}

/// Whether a header name is allowed as an own header.
#[uniffi::export]
pub fn own_header_name_suits(name: String) -> bool {
    OwnHeaders::name_suits(&name) && !OwnHeaders::is_locked(&name)
}
