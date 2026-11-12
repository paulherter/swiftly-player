use std::sync::{Mutex, MutexGuard, PoisonError};

use serde::Serialize;
use serde::de::DeserializeOwned;
use swiftly_net::{
    ErrorKind, HttpRequest, HttpResponse, HttpTransport, Method, TransportReason, Url,
};

use crate::own_headers::OwnHeaders;
use crate::query::build_url;
use crate::session::{ServerKind, Session};

/// Who the client says it is (JellyfinClient.swift:140-155).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientConfig {
    /// Stable id of this installation (`DeviceId`).
    pub device_id: String,
    /// Name of the device as the user sees it in the server's device list (`Device`).
    pub device_name: String,
    /// App version (`Version`).
    pub client_version: String,
    /// The name under which the server lists this client (`Client`), "Swiftly Player".
    pub program: String,
    /// Jellyfin or Emby. A `Plex` here counts as Jellyfin (JellyfinClient.swift:156).
    pub kind: ServerKind,
    /// Ask for what the tiles show and nothing else: no description in lists, one picture per
    /// type, only the primary picture where only posters show, no total count where it is not
    /// read. The same items come back for the fields the screens use, with fewer bytes. Off by
    /// default so the request goldens of the Swift client keep matching.
    pub lean_tiles: bool,
}

impl ClientConfig {
    /// A configuration with the store name "Swiftly Player" and Jellyfin.
    pub fn new(device_id: &str, device_name: &str, client_version: &str) -> Self {
        Self {
            device_id: device_id.into(),
            device_name: device_name.into(),
            client_version: client_version.into(),
            program: "Swiftly Player".into(),
            kind: ServerKind::Jellyfin,
            lean_tiles: false,
        }
    }

    /// Sets [`lean_tiles`](Self::lean_tiles).
    #[must_use]
    pub fn lean_tiles(mut self, on: bool) -> Self {
        self.lean_tiles = on;
        self
    }

    /// Sets the server kind.
    #[must_use]
    pub fn kind(mut self, kind: ServerKind) -> Self {
        self.kind = kind;
        self
    }

    /// Sets the client name (Android adds a suffix, JellyfinClient.swift:131).
    #[must_use]
    pub fn program(mut self, program: &str) -> Self {
        self.program = program.into();
        self
    }
}

#[derive(Default)]
pub(crate) struct State {
    pub(crate) session: Option<Session>,
    /// `Policy.EnableContentDownloading` as the last `accountDefaults` answer gave it;
    /// `None` = unknown = allowed (JellyfinClient.swift:158).
    pub(crate) download_allowed: Option<bool>,
    /// The Jelly Twiggy plugin answered "not here" (JellyfinClient.swift:151).
    pub(crate) watchers_absent: bool,
    pub(crate) watchers_not_found: std::collections::HashSet<String>,
}

/// The client for one server. Cheap to share by reference; the session sits behind a lock
/// that is never held across an await.
pub struct JellyfinClient<T: HttpTransport> {
    pub(crate) transport: T,
    pub(crate) base_url: Url,
    /// The address as it was given, for `Session.server_url` (no added trailing slash).
    pub(crate) base_text: String,
    pub(crate) config: ClientConfig,
    pub(crate) state: Mutex<State>,
}

/// A query string under construction; keeps the order the Swift code appends in.
#[derive(Default, Debug, Clone)]
pub(crate) struct Query(pub(crate) Vec<(String, String)>);

impl Query {
    pub(crate) fn new() -> Self {
        Self::default()
    }
    pub(crate) fn add(mut self, name: &str, value: impl ToString) -> Self {
        self.0.push((name.into(), value.to_string()));
        self
    }
    pub(crate) fn push(&mut self, name: &str, value: impl ToString) {
        self.0.push((name.into(), value.to_string()));
    }
}

impl<T: HttpTransport> JellyfinClient<T> {
    /// A client without a session.
    ///
    /// # Errors
    /// [`ErrorKind::InvalidServerUrl`] if `base_url` is not an http(s) address.
    pub fn new(transport: T, base_url: &str, config: ClientConfig) -> Result<Self, ErrorKind> {
        let base = Url::parse(base_url).map_err(|_| ErrorKind::InvalidServerUrl)?;
        if !matches!(base.scheme(), "http" | "https") || base.host_str().is_none() {
            return Err(ErrorKind::InvalidServerUrl);
        }
        let kind = if config.kind == ServerKind::Emby {
            ServerKind::Emby
        } else {
            ServerKind::Jellyfin
        };
        Ok(Self {
            transport,
            base_url: base,
            base_text: base_url.to_string(),
            config: ClientConfig { kind, ..config },
            state: Mutex::new(State::default()),
        })
    }

    pub(crate) fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The transport (tests read what a mock recorded).
    pub fn transport(&self) -> &T {
        &self.transport
    }

    /// The server address.
    pub fn base_url(&self) -> &Url {
        &self.base_url
    }

    /// Jellyfin, or Emby (`serverKind`, JellyfinClient.swift:153).
    pub fn server_kind(&self) -> ServerKind {
        self.config.kind
    }

    /// Sets or clears the session (`setSession`, JellyfinClient.swift:177).
    pub fn set_session(&self, session: Option<Session>) {
        let mut state = self.state();
        state.session = session;
        // The permission belongs to the account (JellyfinClient.swift:187-193).
        state.download_allowed = None;
    }

    /// The current session (`currentSession`).
    pub fn current_session(&self) -> Option<Session> {
        self.state().session.clone()
    }

    pub(crate) fn require_session(&self) -> Result<Session, ErrorKind> {
        self.current_session().ok_or(ErrorKind::NotAuthenticated)
    }

    /// The query name that carries the token in an address opened without headers.
    pub(crate) fn token_name(&self) -> &'static str {
        crate::emby::token_name(self.config.kind)
    }

    /// The `Authorization` header value (JellyfinClient.swift:204-218). The token is missing on
    /// the first call (login) and added afterwards. The same value serves the control channel.
    pub fn authorization_header(&self) -> String {
        let c = &self.config;
        let mut parts = vec![
            format!("Client=\"{}\"", header_value(&c.program)),
            format!("Device=\"{}\"", header_value(&c.device_name)),
            format!("DeviceId=\"{}\"", header_value(&c.device_id)),
            format!("Version=\"{}\"", header_value(&c.client_version)),
        ];
        if let Some(s) = self.current_session() {
            parts.push(format!("Token=\"{}\"", header_value(&s.access_token)));
        }
        format!("MediaBrowser {}", parts.join(", "))
    }

    /// Builds a request (`request(_:method:query:body:)`, JellyfinClient.swift:263-290).
    ///
    /// Headers in the order the Swift code sets them: own headers, `Authorization`, `Accept`,
    /// and `Content-Type` when there is a body. Emby gets its user-bound path.
    pub(crate) fn request(
        &self,
        path: &str,
        method: Method,
        query: &Query,
        body: Option<Vec<u8>>,
    ) -> Result<HttpRequest, ErrorKind> {
        let session = self.current_session();
        let path = if self.config.kind == ServerKind::Emby {
            crate::emby::rewrite_path(path, session.as_ref().map(|s| s.user_id.as_str()))
        } else {
            path.to_string()
        };
        let url = build_url(&self.base_url, &path, &query.0).ok_or(ErrorKind::InvalidServerUrl)?;
        let mut req = HttpRequest::new(method, url);
        OwnHeaders::apply(&mut req);
        req.set_header("Authorization", &self.authorization_header());
        req.set_header("Accept", "application/json");
        if let Some(body) = body {
            req.set_header("Content-Type", "application/json");
            req.body = Some(body);
        }
        Ok(req)
    }

    pub(crate) fn get(&self, path: &str, query: &Query) -> Result<HttpRequest, ErrorKind> {
        self.request(path, Method::Get, query, None)
    }

    pub(crate) fn json_body(body: &impl Serialize) -> Result<Vec<u8>, ErrorKind> {
        serde_json::to_vec(body).map_err(|e| ErrorKind::Decoding(e.to_string()))
    }

    /// The answer of a request, whatever its status.
    pub(crate) async fn execute(&self, req: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        self.transport.send(req).await
    }

    /// Sends and decodes (`send(_:as:)`, JellyfinClient.swift:292-322): non-2xx is
    /// [`ErrorKind::Http`] with the first 400 bytes, except 401/403 from a gateway's login
    /// page; HTML instead of JSON also means a gateway answered.
    pub(crate) async fn send<D: DeserializeOwned>(&self, req: HttpRequest) -> Result<D, ErrorKind> {
        let response = self.execute(req).await?;
        if !response.is_success() {
            if matches!(response.status, 401 | 403) && response.is_login_page() {
                return Err(ErrorKind::Transport(TransportReason::LoginPage));
            }
            return Err(ErrorKind::Http {
                status: response.status,
                body: response.text_prefix(400),
            });
        }
        serde_json::from_slice(&response.body).map_err(|e| {
            if response.is_login_page() {
                ErrorKind::Transport(TransportReason::LoginPage)
            } else {
                ErrorKind::Decoding(e.to_string())
            }
        })
    }

    /// For endpoints that only answer success (`sendIgnoringBody`, JellyfinClient.swift:340):
    /// non-2xx is [`ErrorKind::Http`] with the first 300 bytes.
    pub(crate) async fn send_ignoring_body(&self, req: HttpRequest) -> Result<(), ErrorKind> {
        let response = self.execute(req).await?;
        if response.is_success() {
            Ok(())
        } else {
            Err(ErrorKind::Http {
                status: response.status,
                body: response.text_prefix(300),
            })
        }
    }

    /// Sign-in paths that do not go through name and password (`signInWith`,
    /// JellyfinClient.swift:359): sets the session on success.
    pub(crate) async fn sign_in_with(
        &self,
        path: &str,
        body: &impl Serialize,
    ) -> Result<Session, ErrorKind> {
        let req = self.request(
            path,
            Method::Post,
            &Query::new(),
            Some(Self::json_body(body)?),
        )?;
        let result: swiftly_model::AuthenticationResult = self.send(req).await?;
        Ok(self.adopt(result))
    }

    pub(crate) fn adopt(&self, result: swiftly_model::AuthenticationResult) -> Session {
        let session = Session {
            access_token: result.access_token,
            user_id: result.user.id,
            user_name: result.user.name,
            server_url: self.base_text.clone(),
            kind: self.config.kind,
        };
        self.state().session = Some(session.clone());
        session
    }
}

/// A value that cannot break out of the header field (`headerValue`, JellyfinClient.swift:231-238):
/// the straight quote becomes a single quote, line breaks and control characters are dropped.
pub(crate) fn header_value(raw: &str) -> String {
    raw.chars()
        .filter_map(|c| match c {
            '"' => Some('\''),
            // Swift drops `CharacterSet.controlCharacters`: general categories Cc and Cf (zero-width joiner,
            // soft hyphen, direction marks ...), so an emoji family in a device name loses its joiners.
            c if c.is_control() || is_format_character(c) => None,
            c => Some(c),
        })
        .collect()
}

/// Unicode general category Cf (format characters).
fn is_format_character(c: char) -> bool {
    matches!(
        u32::from(c),
        0x00AD | 0x0600..=0x0605 | 0x061C | 0x06DD | 0x070F | 0x0890..=0x0891 | 0x08E2 | 0x180E | 0x200B..=0x200F | 0x202A..=0x202E
            | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD | 0x13430..=0x1343F
            | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    // AuthRequestTests.swift:393 headerValueMasked
    #[test]
    fn quote_in_device_name_does_not_break_the_header() {
        assert_eq!(header_value("Pauls \"Kiste\""), "Pauls 'Kiste'");
        assert_eq!(header_value("Zeile\nzwei"), "Zeilezwei");
        assert_eq!(header_value("Wohnzimmer-TV"), "Wohnzimmer-TV");
    }
}
