//! The client (`SeerrClient`, Seerr.swift) over an injected transport and cookie jar.

use swiftly_jellyfin::{OwnHeader, OwnHeaders};
use swiftly_net::{
    ErrorKind, HttpRequest, HttpResponse, HttpTransport, Method, TransportReason, Url, url_error,
};

use crate::errors::AskError;
use crate::setup::SignInKind;

use crate::mapping::Seerr;
use crate::models::{SeerrAccess, SeerrDetail, SeerrHit};

/// Where the platform keeps cookies it received on its own (the shared `URLSession` store on
/// Apple). Only used as the fallback of the sign-in and to forget them on sign-out; every other
/// call sends the cookie of [`SeerrAccess`] explicitly.
pub trait CookieJar: Send + Sync {
    /// The session cookie (`name=value`, name contains `sid`, value not empty) for this address.
    fn session_cookie(&self, address: &Url) -> Option<String>;
    /// Removes all cookies of this address.
    fn forget(&self, address: &Url);
}

/// A jar that holds nothing (Rust transports without cookie handling).
pub struct NoCookies;

impl CookieJar for NoCookies {
    fn session_cookie(&self, _address: &Url) -> Option<String> {
        None
    }
    fn forget(&self, _address: &Url) {}
}

/// State of a stored session (`GET auth/me`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeerrSessionState {
    /// 200.
    Valid,
    /// 401 or 403: sign in again.
    Invalid,
    /// Anything else (also no answer).
    Unreachable,
}

impl SeerrSessionState {
    /// `init(status:)`.
    pub fn from_status(status: u16) -> Self {
        match status {
            200 => Self::Valid,
            401 | 403 => Self::Invalid,
            _ => Self::Unreachable,
        }
    }
}

/// The redirect rule of the sign-in session: follow only a redirect that keeps the method.
pub struct KeepPostRedirects;

impl KeepPostRedirects {
    /// `keepsMethod(original:redirected:)`; a missing method counts as GET.
    pub fn keeps_method(original: Option<&str>, redirected: Option<&str>) -> bool {
        original
            .unwrap_or("GET")
            .eq_ignore_ascii_case(redirected.unwrap_or("GET"))
    }
}

/// Which of two failed scheme attempts to show: the first when the second only says "this scheme
/// is wrong" (redirect, 405, TLS or parse failure), otherwise the second.
pub fn error_to_show(first: ErrorKind, second: ErrorKind) -> ErrorKind {
    let keep_first = match &second {
        ErrorKind::Http { status, .. } => (300..400).contains(status) || *status == 405,
        ErrorKind::Network { code } => matches!(
            *code,
            -1022
                | -1002
                | url_error::SECURE_CONNECTION_FAILED
                | url_error::TOO_MANY_REDIRECTS
                | -1010
                | -1011
                | url_error::CANNOT_PARSE_RESPONSE
                | url_error::CERTIFICATE_UNTRUSTED
                | url_error::CLIENT_CERTIFICATE_REQUIRED
        ),
        ErrorKind::Certificate(_) => true,
        _ => false,
    };
    if keep_first { first } else { second }
}

/// The text of a sign-in that worked but brought no cookie (also what the cause classifier looks for).
pub(crate) const NO_SESSION: &str = "Seerr hat keine Sitzung mitgegeben.";

/// The sentences the Jellyfin-only sign-in has always shown for 401/403 and 404.
fn legacy_text(e: ErrorKind) -> ErrorKind {
    match e {
        ErrorKind::Http {
            status: 401 | 403, ..
        } => other("Name oder Passwort stimmen nicht."),
        ErrorKind::Http { status: 404, .. } => other("Unter dieser Adresse antwortet kein Seerr."),
        e => e,
    }
}

fn other(text: &str) -> ErrorKind {
    ErrorKind::Transport(TransportReason::Other(text.to_string()))
}

fn api_url(address: &str, path: &str, query: &[(&str, &str)]) -> Result<Url, ErrorKind> {
    let mut text = format!("{}/api/v1/{path}", address.trim_end_matches('/'));
    for (i, (k, v)) in query.iter().enumerate() {
        text.push(if i == 0 { '?' } else { '&' });
        text.push_str(&encode(k));
        text.push('=');
        text.push_str(&encode(v));
    }
    Url::parse(&text).map_err(|_| other("Adresse unbrauchbar."))
}

/// The stash key of a read: the path with its query.
fn stash_key(path: &str, query: &[(&str, &str)]) -> String {
    let mut key = path.to_owned();
    for (i, (k, v)) in query.iter().enumerate() {
        key.push(if i == 0 { '?' } else { '&' });
        key.push_str(k);
        key.push('=');
        key.push_str(v);
    }
    key
}

fn encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn apply_headers(req: &mut HttpRequest, headers: &[OwnHeader]) {
    for h in OwnHeaders::cleaned(headers) {
        req.set_header(&h.name, &h.value);
    }
}

/// Where the client keeps the last answer of every read (`GET`) call, so a screen can show what it last saw before
/// Seerr answers (see [`replaying`]). One per connection; the key is the call's path and query.
pub trait BodyStash: Send + Sync {
    /// The stored answer of `key`: `None` = never stored; `Some(empty)` = the server last said "not found".
    fn get(&self, key: &str) -> Option<Vec<u8>>;
    /// Stores the answer of `key` (`body` empty = the server said "not found").
    fn put(&self, key: &str, body: &[u8]);
}

thread_local! {
    /// Set while a [`Replaying`] future is polled on this thread: reads then come from the stash, not the network.
    static REPLAY: std::cell::Cell<Option<bool>> = const { std::cell::Cell::new(None) };
}

/// Runs `work` with every read answered from the client's stash, without a network call, so a screen paints its last
/// seen content at once. `None` when any read was not stored (the pass is then incomplete and must be dropped).
/// `work` must not spawn: the switch is per poll on the polling thread, so a concurrent live read on another
/// thread is never answered from the stash.
pub async fn replaying<F: std::future::Future>(work: F) -> Option<F::Output> {
    let mut work = std::pin::pin!(work);
    let mut missed = false;
    let out = std::future::poll_fn(|cx| {
        REPLAY.with(|r| r.set(Some(false)));
        let polled = work.as_mut().poll(cx);
        missed |= REPLAY.with(|r| r.replace(None)) == Some(true);
        polled
    })
    .await;
    (!missed).then_some(out)
}

/// True while a [`replaying`] pass is polled on this thread (nothing goes to the network then).
pub fn is_replaying() -> bool {
    REPLAY.with(std::cell::Cell::get).is_some()
}

/// The Seerr client of one stored connection.
pub struct SeerrClient<T: HttpTransport, J: CookieJar = NoCookies> {
    access: SeerrAccess,
    transport: T,
    jar: J,
    stash: Option<std::sync::Arc<dyn BodyStash>>,
    log: Option<SeerrLog>,
}

/// Where the client writes its timing lines (the host's log). A line never holds a secret: only the method, the
/// path without its query, the status and the milliseconds.
pub type SeerrLog = std::sync::Arc<dyn Fn(&str) + Send + Sync>;

impl<T: HttpTransport> SeerrClient<T, NoCookies> {
    /// A client without a cookie jar.
    pub fn new(access: SeerrAccess, transport: T) -> Self {
        Self {
            access,
            transport,
            jar: NoCookies,
            stash: None,
            log: None,
        }
    }
}

impl<T: HttpTransport, J: CookieJar> SeerrClient<T, J> {
    /// A client with a jar (used to forget cookies on sign-out).
    pub fn with_jar(access: SeerrAccess, transport: T, jar: J) -> Self {
        Self {
            access,
            transport,
            jar,
            stash: None,
            log: None,
        }
    }

    /// The same client writing one `[Seerr]` line per call (method, path, status, milliseconds) to `log`.
    #[must_use]
    pub fn with_log(mut self, log: SeerrLog) -> Self {
        self.log = Some(log);
        self
    }

    /// One `[Seerr]` line into the host's log (nothing without a log). Screens use it for their own timings.
    pub fn note(&self, line: &str) {
        if let Some(log) = &self.log {
            log(&format!("[Seerr] {line}"));
        }
    }

    /// The log of this client, for a timer that outlives a borrow of it.
    pub fn log_sink(&self) -> Option<SeerrLog> {
        self.log.clone()
    }

    /// `transport.send` with its duration in the log: `GET request 200 143ms`, or `no answer` after a failure.
    async fn timed(&self, req: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        let Some(log) = &self.log else {
            return self.transport.send(req).await;
        };
        let what = format!(
            "{} {}",
            format!("{:?}", req.method).to_uppercase(),
            req.url
                .path()
                .trim_start_matches("/api/v1/")
                .trim_start_matches('/')
        );
        let began = std::time::Instant::now();
        let answer = self.transport.send(req).await;
        let ms = began.elapsed().as_millis();
        match &answer {
            Ok(a) => log(&format!("[Seerr] {what} {} {ms}ms", a.status)),
            Err(_) => log(&format!("[Seerr] {what} no answer {ms}ms")),
        }
        answer
    }

    /// The same client keeping the answers of its reads in `stash` (see [`BodyStash`], [`replaying`]).
    #[must_use]
    pub fn with_stash(mut self, stash: std::sync::Arc<dyn BodyStash>) -> Self {
        self.stash = Some(stash);
        self
    }

    /// A list read of `path` / `query` that this client stashed no longer shows the row `id` (the row was withdrawn
    /// or deleted): the stored answer loses it, so a later paint from the stash cannot bring it back. Nothing is
    /// touched when no such answer is stored.
    pub fn drop_from_stored_list(&self, path: &str, query: &[(&str, &str)], id: i64) {
        let Some(stash) = &self.stash else { return };
        let key = stash_key(path, query);
        let Some(body) = stash.get(&key) else { return };
        let Ok(mut page) = serde_json::from_slice::<serde_json::Value>(&body) else {
            return;
        };
        if let Some(rows) = page.get_mut("results").and_then(|r| r.as_array_mut()) {
            rows.retain(|row| row.get("id").and_then(serde_json::Value::as_i64) != Some(id));
        }
        if let Ok(kept) = serde_json::to_vec(&page) {
            stash.put(&key, &kept);
        }
    }

    /// The connection's address.
    pub fn address(&self) -> &str {
        &self.access.address
    }

    /// Forgets the platform's cookies of this address (sign-out).
    pub fn forget_cookies(&self) {
        if let Ok(u) = Url::parse(&self.access.address) {
            self.jar.forget(&u);
        }
    }

    /// `POST auth/jellyfin` with the media server's account. No old cookie goes along
    /// (express-session would then keep the old session and send no `Set-Cookie`). The cookie comes
    /// from `Set-Cookie`, else from the jar.
    pub async fn sign_in(
        transport: &T,
        jar: &J,
        address: &str,
        user: &str,
        password: &str,
        headers: &[OwnHeader],
    ) -> Result<SeerrAccess, ErrorKind> {
        let kind = SignInKind::Jellyfin {
            user: user.to_owned(),
            password: password.to_owned(),
        };
        Self::sign_in_with(transport, jar, address, &kind, headers)
            .await
            .map_err(legacy_text)
    }

    /// One sign-in of any kind (`auth/jellyfin`, `auth/local`, `auth/plex`) at one address. Errors
    /// stay raw: a refusal is `ErrorKind::Http` with the first bytes of the body, which
    /// [`SignInCause::classify`](crate::setup::SignInCause::classify) turns into a cause.
    pub async fn sign_in_with(
        transport: &T,
        jar: &J,
        address: &str,
        kind: &SignInKind,
        headers: &[OwnHeader],
    ) -> Result<SeerrAccess, ErrorKind> {
        let mut req = HttpRequest::new(Method::Post, api_url(address, kind.path(), &[])?);
        apply_headers(&mut req, headers);
        req.set_header("Content-Type", "application/json");
        // `signInSession`: a 301/302 on the way (http -> https) must not turn the POST into a GET.
        req.keep_method = true;
        req.body =
            Some(serde_json::to_vec(&kind.body()).map_err(|e| ErrorKind::Decoding(e.to_string()))?);
        let answer = transport.send(req).await?;
        // A login page in front of Seerr first; 404 is "no Seerr here" (HTML error page too).
        if answer.status != 404 && answer.is_login_page() {
            return Err(ErrorKind::Transport(TransportReason::LoginPage));
        }
        match answer.status {
            200 | 201 => {}
            status => {
                return Err(ErrorKind::Http {
                    status,
                    body: answer.text_prefix(200),
                });
            }
        }
        let set_cookie: Vec<&str> = answer
            .headers
            .iter()
            .filter(|(n, _)| n.eq_ignore_ascii_case("set-cookie"))
            .map(|(_, v)| v.as_str())
            .collect();
        let cookie = if set_cookie.is_empty() {
            None
        } else {
            Seerr::cookie_from_header(&set_cookie.join(", "))
        }
        .or_else(|| {
            Url::parse(address)
                .ok()
                .and_then(|u| jar.session_cookie(&u))
        })
        .ok_or_else(|| other(NO_SESSION))?;
        Ok(SeerrAccess::new(address, &cookie, headers))
    }

    /// Tries each typed-address candidate in turn (https then http, or the reverse) and shows
    /// the error picked by [`error_to_show`].
    pub async fn sign_in_typed(
        transport: &T,
        jar: &J,
        typed: &str,
        user: &str,
        password: &str,
        headers: &[OwnHeader],
    ) -> Result<SeerrAccess, ErrorKind> {
        let kind = SignInKind::Jellyfin {
            user: user.to_owned(),
            password: password.to_owned(),
        };
        Self::sign_in_typed_with(transport, jar, typed, &kind, headers)
            .await
            .map_err(legacy_text)
    }

    /// [`sign_in_typed`](Self::sign_in_typed) for any kind of sign-in, with raw errors.
    pub async fn sign_in_typed_with(
        transport: &T,
        jar: &J,
        typed: &str,
        kind: &SignInKind,
        headers: &[OwnHeader],
    ) -> Result<SeerrAccess, ErrorKind> {
        let candidates = Seerr::addresses(typed);
        let mut first_error: Option<ErrorKind> = None;
        for address in &candidates {
            match Self::sign_in_with(transport, jar, address, kind, headers).await {
                Ok(a) => return Ok(a),
                Err(e) => {
                    first_error = Some(match first_error {
                        None => e,
                        Some(first) => error_to_show(first, e),
                    });
                }
            }
        }
        Err(first_error.unwrap_or(ErrorKind::InvalidServerUrl))
    }

    fn petition(
        &self,
        path: &str,
        method: Method,
        query: &[(&str, &str)],
        body: Option<Vec<u8>>,
    ) -> Result<HttpRequest, ErrorKind> {
        let mut req = HttpRequest::new(method, api_url(&self.access.address, path, query)?);
        // Own headers first: `Cookie` is locked there, so the cookie stays the app's own.
        apply_headers(&mut req, &self.access.headers);
        req.set_header("Cookie", &self.access.cookie);
        if let Some(b) = body {
            req.body = Some(b);
            req.set_header("Content-Type", "application/json");
        }
        Ok(req)
    }

    async fn hole(&self, path: &str) -> Option<Vec<u8>> {
        let req = self.petition(path, Method::Get, &[], None).ok()?;
        let answer = self.timed(req).await.ok()?;
        (answer.status == 200).then_some(answer.body)
    }

    /// `GET search?query=`; any failure gives an empty list.
    pub async fn searching(&self, term: &str) -> Vec<SeerrHit> {
        let Ok(req) = self.petition("search", Method::Get, &[("query", term)], None) else {
            return Vec::new();
        };
        match self.timed(req).await {
            Ok(a) if a.status == 200 => Seerr::hit_from_search(&a.body),
            _ => Vec::new(),
        }
    }

    /// `POST request` for the old screens (desktop, Android). A duplicate (409) still counts as done
    /// there; every other refusal says its real reason. New code uses [`SeerrClient::request`].
    pub async fn ask_for(
        &self,
        art: &str,
        id: i64,
        seasons: Option<&[i64]>,
    ) -> Result<(), ErrorKind> {
        let body = Seerr::request_body(art, id, seasons);
        match self
            .send(Method::Post, "request", &[], Some(body), true)
            .await
        {
            Ok(_) | Err(AskError::Exists) => Ok(()),
            Err(e) => Err(e.into_kind()),
        }
    }

    /// One call with the typed failure of [`AskError`]: any 2xx answers `Ok`. `creating` is the
    /// `POST request` that makes a new request (409 = duplicate, 202 = no season left).
    pub(crate) async fn send(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, &str)],
        body: Option<serde_json::Value>,
        creating: bool,
    ) -> Result<HttpResponse, AskError> {
        let body = match body {
            Some(v) => Some(
                serde_json::to_vec(&v)
                    .map_err(|e| AskError::Network(ErrorKind::Decoding(e.to_string())))?,
            ),
            None => None,
        };
        let req = self
            .petition(path, method, query, body)
            .map_err(AskError::Network)?;
        let answer = self.timed(req).await.map_err(AskError::Network)?;
        if answer.status != 404 && answer.is_login_page() {
            return Err(AskError::Network(ErrorKind::Transport(
                TransportReason::LoginPage,
            )));
        }
        if creating && answer.status == 202 {
            return Err(AskError::NoSeasons);
        }
        if (200..300).contains(&answer.status) {
            return Ok(answer);
        }
        let text = String::from_utf8_lossy(&answer.body).into_owned();
        Err(AskError::from_answer(answer.status, &text, creating))
    }

    /// `GET path` read as `D` (a body that is no JSON of that shape is a `Network(Decoding)` error). Every answer
    /// is stashed; inside [`replaying`] the stashed answer is returned and nothing goes out.
    pub(crate) async fn get_json<D: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<D, AskError> {
        let key = stash_key(path, query);
        if REPLAY.with(std::cell::Cell::get).is_some() {
            let stored = self.stash.as_ref().and_then(|s| s.get(&key));
            return match stored {
                Some(body) if body.is_empty() => Err(AskError::NotFound),
                Some(body) => serde_json::from_slice(&body)
                    .map_err(|e| AskError::Network(ErrorKind::Decoding(e.to_string()))),
                None => {
                    REPLAY.with(|r| r.set(Some(true)));
                    Err(AskError::NotFound)
                }
            };
        }
        let answer = self.send(Method::Get, path, query, None, false).await;
        if let Some(stash) = &self.stash {
            match &answer {
                Ok(a) => stash.put(&key, &a.body),
                Err(AskError::NotFound) => stash.put(&key, &[]),
                Err(_) => {}
            }
        }
        serde_json::from_slice(&answer?.body)
            .map_err(|e| AskError::Network(ErrorKind::Decoding(e.to_string())))
    }

    /// Detail plus suggestions (two fetches side by side). Missing suggestions keep the page.
    pub async fn detail(&self, art: &str, id: i64) -> Option<SeerrDetail> {
        let main = format!("{art}/{id}");
        let rec = format!("{art}/{id}/recommendations");
        let (a, b) = futures_util::future::join(self.hole(&main), self.hole(&rec)).await;
        let inquiry = Seerr::detail(&a?)?;
        match b {
            Some(b) => Some(inquiry.with_similar_one(Seerr::suggestions(&b, art))),
            None => Some(inquiry),
        }
    }

    /// `GET person/{id}/combined_credits`.
    pub async fn filmography(&self, person_tmdb: i64) -> Vec<SeerrHit> {
        match self
            .hole(&format!("person/{person_tmdb}/combined_credits"))
            .await
        {
            Some(d) => Seerr::hit_from_filmography(&d),
            None => Vec::new(),
        }
    }

    /// `GET auth/me` for a stored connection, without owning the transport.
    pub async fn session_state(transport: &T, access: &SeerrAccess) -> SeerrSessionState {
        let Ok(mut req) =
            api_url(&access.address, "auth/me", &[]).map(|u| HttpRequest::new(Method::Get, u))
        else {
            return SeerrSessionState::Unreachable;
        };
        apply_headers(&mut req, &access.headers);
        req.set_header("Cookie", &access.cookie);
        match transport.send(req).await {
            Ok(a) => SeerrSessionState::from_status(a.status),
            Err(_) => SeerrSessionState::Unreachable,
        }
    }

    /// `GET auth/me`.
    pub async fn applies(&self) -> SeerrSessionState {
        let Ok(req) = self.petition("auth/me", Method::Get, &[], None) else {
            return SeerrSessionState::Unreachable;
        };
        match self.timed(req).await {
            Ok(a) => SeerrSessionState::from_status(a.status),
            Err(_) => SeerrSessionState::Unreachable,
        }
    }
}
