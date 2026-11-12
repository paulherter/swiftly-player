//! **Signing in at plex.tv and finding the servers of the account** (`PlexAccount.swift`).
//!
//! The PIN flow: `POST /api/v2/pins?strong=true` makes a code, the user confirms it in the
//! browser at `https://app.plex.tv/auth#...`, `GET /api/v2/pins/{id}?code=` is polled until a
//! token appears. The token then lists the servers (`clients.plex.tv/api/v2/resources`) and the
//! Plex Home profiles. Nothing here talks to a real service unless the caller hands in a real
//! transport.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::Value;
use swiftly_jellyfin::encode_query_value;
use swiftly_net::{ErrorKind, HttpRequest, HttpTransport, Method};
use url::Url;

use crate::connections::Sleep;
use crate::identity::{PlexError, PlexIdentity};
use crate::loose;
use crate::server::PlexServerResource;

/// A sign-in code at plex.tv (PlexAccount.swift:6).
#[derive(Clone, PartialEq, Eq)]
pub struct PlexPin {
    /// Pin id.
    pub id: i64,
    /// The code the user types or the browser carries.
    pub code: String,
    /// Set once the user confirmed in the browser.
    pub auth_token: Option<String>,
    /// Seconds left.
    pub expires_in: Option<i64>,
    /// Expiry time as plex.tv writes it.
    pub expires_at: Option<String>,
}

/// `Debug` never shows the code or the token.
impl std::fmt::Debug for PlexPin {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PlexPin")
            .field("id", &self.id)
            .field("code", &swiftly_net::redact::MASK)
            .field(
                "auth_token",
                &self.auth_token.as_ref().map(|_| swiftly_net::redact::MASK),
            )
            .field("expires_in", &self.expires_in)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

impl PlexPin {
    /// A pin by hand.
    pub fn new(id: i64, code: &str) -> Self {
        Self {
            id,
            code: code.into(),
            auth_token: None,
            expires_in: None,
            expires_at: None,
        }
    }

    /// Reads a pin; `None` without `id` and `code`. An empty token is none.
    pub fn parse(v: &Value) -> Option<Self> {
        Some(Self {
            id: loose::int(v, "id")?,
            code: loose::string(v, "code")?,
            auth_token: loose::string(v, "authToken").filter(|t| !t.is_empty()),
            expires_in: loose::int(v, "expiresIn"),
            expires_at: loose::string(v, "expiresAt"),
        })
    }
}

/// A profile of a Plex Home (PlexAccount.swift:~50).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexHomeUser {
    /// User id.
    pub id: String,
    /// Uuid, needed for the switch.
    pub uuid: String,
    /// Name.
    pub title: String,
    /// Picture address at plex.tv.
    pub thumb: Option<String>,
    /// Asks for a PIN?
    pub is_protected: bool,
    /// The home's admin?
    pub is_admin: bool,
    /// A restricted (child) profile?
    pub is_restricted: bool,
    /// A guest?
    pub is_guest: bool,
}

impl PlexHomeUser {
    /// Reads a profile; `None` without `id` and `uuid`.
    pub fn parse(v: &Value) -> Option<Self> {
        Some(Self {
            id: loose::string(v, "id")?,
            uuid: loose::string(v, "uuid")?,
            title: loose::string(v, "title").unwrap_or_default(),
            thumb: loose::string(v, "thumb"),
            is_protected: loose::boolean(v, "protected").unwrap_or(false),
            is_admin: loose::boolean(v, "admin").unwrap_or(false),
            is_restricted: loose::boolean(v, "restricted").unwrap_or(false),
            is_guest: loose::boolean(v, "guest").unwrap_or(false),
        })
    }
}

/// The signed-in plex.tv user (`GET /api/v2/user`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexAccount {
    /// User id.
    pub id: String,
    /// Uuid.
    pub uuid: Option<String>,
    /// `title`, else `friendlyName`, else `username`.
    pub title: String,
    /// Picture address.
    pub thumb: Option<String>,
}

impl PlexAccount {
    /// Reads the user; `None` without `id`.
    pub fn parse(v: &Value) -> Option<Self> {
        Some(Self {
            id: loose::string(v, "id")?,
            uuid: loose::string(v, "uuid"),
            title: loose::string(v, "title")
                .or_else(|| loose::string(v, "friendlyName"))
                .or_else(|| loose::string(v, "username"))
                .unwrap_or_default(),
            thumb: loose::string(v, "thumb"),
        })
    }
}

/// Whether a stored token still works (`PlexAccountService.TokenState`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenState {
    /// Valid, for this user.
    Valid(PlexAccount),
    /// plex.tv answered `401`.
    Invalid,
}

/// The calls to plex.tv (PlexAccount.swift:~120). Generic over the transport so tests run
/// against a mock.
pub struct PlexAccountService<T: HttpTransport> {
    /// Who is asking.
    pub identity: PlexIdentity,
    transport: Arc<T>,
    tv_base: String,
    clients_base: String,
    app_base: String,
}

impl<T: HttpTransport> PlexAccountService<T> {
    /// The real hosts: `plex.tv`, `clients.plex.tv`, `app.plex.tv`.
    pub fn new(identity: PlexIdentity, transport: Arc<T>) -> Self {
        Self::with_bases(
            identity,
            transport,
            "https://plex.tv",
            "https://clients.plex.tv",
            "https://app.plex.tv",
        )
    }

    /// Other hosts, for tests.
    pub fn with_bases(
        identity: PlexIdentity,
        transport: Arc<T>,
        tv_base: &str,
        clients_base: &str,
        app_base: &str,
    ) -> Self {
        Self {
            identity,
            transport,
            tv_base: tv_base.trim_end_matches('/').into(),
            clients_base: clients_base.trim_end_matches('/').into(),
            app_base: app_base.trim_end_matches('/').into(),
        }
    }

    fn at(base: &str, path: &str, query: &[(&str, &str)]) -> Result<Url, PlexError> {
        // Swift's `appendingPathComponent` keeps a `?` or `#` inside the path (`%3F`, `%23`), and `URL(string:)` makes
        // a stray `%` / space an escape.
        let path = crate::playback::escape_stray(&path.replace('?', "%3F").replace('#', "%23"));
        let mut text = format!("{base}/{path}");
        if !query.is_empty() {
            let pairs: Vec<String> = query
                .iter()
                .map(|(k, v)| format!("{}={}", encode_query_value(k), encode_query_value(v)))
                .collect();
            text.push('?');
            text.push_str(&pairs.join("&"));
        }
        Url::parse(&text).map_err(|_| ErrorKind::InvalidServerUrl.into())
    }

    // MARK: PIN sign-in

    /// Makes a code: `POST /api/v2/pins?strong=true` (PlexAccount.swift:129). `strong` codes
    /// are long and meant for the browser link.
    pub async fn start_pin(&self, strong: bool) -> Result<PlexPin, PlexError> {
        let query: &[(&str, &str)] = if strong { &[("strong", "true")] } else { &[] };
        let url = Self::at(&self.tv_base, "api/v2/pins", query)?;
        let value = self.send(url, Method::Post, None).await?;
        PlexPin::parse(&value).ok_or_else(|| ErrorKind::Decoding("pin".into()).into())
    }

    /// The page in the browser where the user confirms the code. The parameters live behind
    /// the `#`, as the web app reads them there (:157).
    pub fn auth_url(&self, pin: &PlexPin, forward_url: Option<&str>) -> Option<Url> {
        let enc = crate::playback::PlexPlayback::escape;
        let mut fragment = format!(
            "?clientID={}&code={}",
            enc(&self.identity.client_id),
            enc(&pin.code)
        );
        fragment.push_str(&format!(
            "&context%5Bdevice%5D%5Bproduct%5D={}",
            enc(&self.identity.product)
        ));
        if let Some(f) = forward_url {
            fragment.push_str(&format!("&forwardUrl={}", enc(f)));
        }
        Url::parse(&format!("{}/auth#{fragment}", self.app_base)).ok()
    }

    /// The page where a code is typed by hand (`plex.tv/link`).
    pub fn link_page(&self) -> Option<Url> {
        Self::at(&self.tv_base, "link", &[]).ok()
    }

    /// Asks whether the code was confirmed: `GET /api/v2/pins/{id}?code=` (:175).
    pub async fn check_pin(&self, pin: &PlexPin) -> Result<PlexPin, PlexError> {
        let url = Self::at(
            &self.tv_base,
            &format!("api/v2/pins/{}", pin.id),
            &[("code", &pin.code)],
        )?;
        let value = self.send(url, Method::Get, None).await?;
        PlexPin::parse(&value).ok_or_else(|| ErrorKind::Decoding("pin".into()).into())
    }

    /// Polls until the user has confirmed, then returns the account token (:190).
    ///
    /// Gives up with [`PlexError::PinExpired`] when plex.tv forgot the code (`404`/`410`) or
    /// `limit` has run out. A dropped request or a plex.tv hiccup does not end a sign-in the
    /// user is confirming in the browser right now; five in a row do. Cancel by dropping the
    /// future. `sleep` is the caller's timer.
    pub async fn await_token(
        &self,
        pin: &PlexPin,
        pause: Duration,
        limit: Duration,
        sleep: &Sleep,
    ) -> Result<String, PlexError> {
        let deadline = Instant::now() + limit;
        let mut failures = 0;
        while Instant::now() < deadline {
            match self.check_pin(pin).await {
                Ok(checked) => {
                    if let Some(token) = checked.auth_token {
                        return Ok(token);
                    }
                    failures = 0;
                }
                Err(PlexError::Request(ErrorKind::Http { status, .. }))
                    if status == 404 || status == 410 =>
                {
                    // Plex forgets an expired code: 404 (measured elsewhere: 410).
                    return Err(PlexError::PinExpired);
                }
                Err(PlexError::Request(error)) => {
                    failures += 1;
                    let retry = match &error {
                        ErrorKind::Network { .. } | ErrorKind::Transport(_) => true,
                        ErrorKind::Http { status, .. } => *status >= 500 || *status == 429,
                        _ => false,
                    };
                    if !retry || failures >= 5 {
                        return Err(error.into());
                    }
                }
                Err(other) => return Err(other),
            }
            sleep(pause).await;
        }
        Err(PlexError::PinExpired)
    }

    // MARK: Token

    /// Whether a stored token still works: `GET /api/v2/user` (:194). `401` is
    /// [`TokenState::Invalid`]; anything else that fails is an error, not a sign-out.
    pub async fn validate(&self, token: &str) -> Result<TokenState, PlexError> {
        let url = Self::at(&self.tv_base, "api/v2/user", &[])?;
        match self.send(url, Method::Get, Some(token)).await {
            Ok(value) => PlexAccount::parse(&value)
                .map(TokenState::Valid)
                .ok_or_else(|| ErrorKind::Decoding("user".into()).into()),
            Err(PlexError::Request(ErrorKind::Http { status: 401, .. })) => Ok(TokenState::Invalid),
            Err(other) => Err(other),
        }
    }

    // MARK: Servers

    /// The servers of the account, with every address: `GET clients.plex.tv/api/v2/resources`
    /// (:207). Only those that provide a server; clients and players are dropped.
    pub async fn servers(&self, token: &str) -> Result<Vec<PlexServerResource>, PlexError> {
        let url = Self::at(
            &self.clients_base,
            "api/v2/resources",
            &[
                ("includeHttps", "1"),
                ("includeRelay", "1"),
                ("includeIPv6", "1"),
            ],
        )?;
        let value = self.send(url, Method::Get, Some(token)).await?;
        let Value::Array(entries) = value else {
            return Err(ErrorKind::Decoding("resources".into()).into());
        };
        Ok(entries
            .iter()
            .filter_map(PlexServerResource::parse)
            .filter(|s| s.provides.iter().any(|p| p == "server"))
            .collect())
    }

    // MARK: Plex Home

    /// The profiles of the Plex Home: `GET clients.plex.tv/api/v2/home/users` (:220).
    pub async fn home_users(&self, token: &str) -> Result<Vec<PlexHomeUser>, PlexError> {
        let url = Self::at(&self.clients_base, "api/v2/home/users", &[])?;
        let value = self.send(url, Method::Get, Some(token)).await?;
        if !value.is_object() {
            return Err(ErrorKind::Decoding("users".into()).into());
        }
        Ok(loose::list(&value, "users", PlexHomeUser::parse).unwrap_or_default())
    }

    /// Switches to a profile and returns **its own token**: `POST
    /// clients.plex.tv/api/v2/home/users/{uuid}/switch` (+`pin`) (:236). A wrong PIN is
    /// [`PlexError::ProfilePinWrong`] (plex.tv answers `401`/`403`, `429` after too many).
    pub async fn switch_user(
        &self,
        user: &PlexHomeUser,
        pin: Option<&str>,
        token: &str,
    ) -> Result<String, PlexError> {
        let query: Vec<(&str, &str)> = match pin {
            Some(p) if !p.is_empty() => vec![("pin", p)],
            _ => vec![],
        };
        let url = Self::at(
            &self.clients_base,
            &format!("api/v2/home/users/{}/switch", user.uuid),
            &query,
        )?;
        match self.send(url, Method::Post, Some(token)).await {
            Ok(value) => match loose::string(&value, "authToken").filter(|t| !t.is_empty()) {
                Some(fresh) => Ok(fresh),
                None => Err(ErrorKind::Decoding("Kein Token in der Antwort.".into()).into()),
            },
            Err(PlexError::Request(ErrorKind::Http { status, .. }))
                if [401, 403, 429].contains(&status) =>
            {
                // plex.tv answers a wrong PIN with 401/403.
                Err(PlexError::ProfilePinWrong)
            }
            Err(other) => Err(other),
        }
    }

    // MARK: Transport

    async fn send(
        &self,
        url: Url,
        method: Method,
        token: Option<&str>,
    ) -> Result<Value, PlexError> {
        let mut request = HttpRequest::new(method, url);
        for (name, value) in self.identity.headers(token, None) {
            request.set_header(&name, &value);
        }
        let response = self.transport.send(request).await?;
        if !response.is_success() {
            return Err(ErrorKind::Http {
                status: response.status,
                body: response.text_prefix(300),
            }
            .into());
        }
        serde_json::from_slice(&response.body)
            .map_err(|e| ErrorKind::Decoding(e.to_string()).into())
    }
}
