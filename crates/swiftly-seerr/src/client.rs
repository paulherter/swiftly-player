//! The client (`SeerrClient`, Seerr.swift) over an injected transport and cookie jar.

use swiftly_jellyfin::{OwnHeader, OwnHeaders};
use swiftly_net::{ErrorKind, HttpRequest, HttpTransport, Method, TransportReason, Url, url_error};

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

/// The Seerr client of one stored connection.
pub struct SeerrClient<T: HttpTransport, J: CookieJar = NoCookies> {
    access: SeerrAccess,
    transport: T,
    jar: J,
}

impl<T: HttpTransport> SeerrClient<T, NoCookies> {
    /// A client without a cookie jar.
    pub fn new(access: SeerrAccess, transport: T) -> Self {
        Self {
            access,
            transport,
            jar: NoCookies,
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

    /// `POST auth/jellyfin`. No old cookie goes along (express-session would then keep the old
    /// session and send no `Set-Cookie`). The cookie comes from `Set-Cookie`, else from the jar.
    pub async fn sign_in(
        transport: &T,
        jar: &J,
        address: &str,
        user: &str,
        password: &str,
        headers: &[OwnHeader],
    ) -> Result<SeerrAccess, ErrorKind> {
        let mut req = HttpRequest::new(Method::Post, api_url(address, "auth/jellyfin", &[])?);
        apply_headers(&mut req, headers);
        req.set_header("Content-Type", "application/json");
        // `signInSession`: a 301/302 on the way (http -> https) must not turn the POST into a GET.
        req.keep_method = true;
        req.body = Some(
            serde_json::to_vec(&serde_json::json!({ "username": user, "password": password }))
                .map_err(|e| ErrorKind::Decoding(e.to_string()))?,
        );
        let answer = transport.send(req).await?;
        // A login page in front of Seerr first; 404 is "no Seerr here" (HTML error page too).
        if answer.status != 404 && answer.is_login_page() {
            return Err(ErrorKind::Transport(TransportReason::LoginPage));
        }
        match answer.status {
            200 | 201 => {}
            401 | 403 => return Err(other("Name oder Passwort stimmen nicht.")),
            404 => return Err(other("Unter dieser Adresse antwortet kein Seerr.")),
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
        .ok_or_else(|| other("Seerr hat keine Sitzung mitgegeben."))?;
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
        let candidates = Seerr::addresses(typed);
        let mut first_error: Option<ErrorKind> = None;
        for address in &candidates {
            match Self::sign_in(transport, jar, address, user, password, headers).await {
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
        let answer = self.transport.send(req).await.ok()?;
        (answer.status == 200).then_some(answer.body)
    }

    /// `GET search?query=`; any failure gives an empty list.
    pub async fn searching(&self, term: &str) -> Vec<SeerrHit> {
        let Ok(req) = self.petition("search", Method::Get, &[("query", term)], None) else {
            return Vec::new();
        };
        match self.transport.send(req).await {
            Ok(a) if a.status == 200 => Seerr::hit_from_search(&a.body),
            _ => Vec::new(),
        }
    }

    /// `POST request`. 409 (someone was faster) is no error.
    pub async fn ask_for(
        &self,
        art: &str,
        id: i64,
        seasons: Option<&[i64]>,
    ) -> Result<(), ErrorKind> {
        let body = serde_json::to_vec(&Seerr::request_body(art, id, seasons))
            .map_err(|e| ErrorKind::Decoding(e.to_string()))?;
        let req = self.petition("request", Method::Post, &[], Some(body))?;
        let answer = self.transport.send(req).await?;
        match answer.status {
            200 | 201 | 409 => Ok(()),
            401 | 403 => Err(other("Deine Seerr-Anmeldung gilt nicht mehr.")),
            status => Err(ErrorKind::Http {
                status,
                body: answer.text_prefix(200),
            }),
        }
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
        match self.transport.send(req).await {
            Ok(a) => SeerrSessionState::from_status(a.status),
            Err(_) => SeerrSessionState::Unreachable,
        }
    }
}
