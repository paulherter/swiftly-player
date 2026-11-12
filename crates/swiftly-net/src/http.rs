use std::time::Duration;

use url::Url;

/// HTTP method; only the ones the clients use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Method {
    /// GET
    Get,
    /// POST
    Post,
    /// PUT
    Put,
    /// DELETE
    Delete,
}

impl Method {
    /// The method name as sent on the wire.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Get => "GET",
            Self::Post => "POST",
            Self::Put => "PUT",
            Self::Delete => "DELETE",
        }
    }
}

/// A request. Headers keep their insertion order; names compare case-insensitively.
#[derive(Clone, PartialEq)]
pub struct HttpRequest {
    /// Method.
    pub method: Method,
    /// Complete address including the query string.
    pub url: Url,
    /// Header fields in the order they were set.
    pub headers: Vec<(String, String)>,
    /// Body, if any.
    pub body: Option<Vec<u8>>,
    /// Overrides the transport's timeouts for this one request (address check).
    pub timeout: Option<Duration>,
    /// Refuse a redirect that would change the method (a POST turned into a GET by a 301/302/303):
    /// the 3xx answer then comes back as the result instead of a misleading answer from the target
    /// (`KeepPostRedirects`, Seerr sign-in).
    pub keep_method: bool,
}

/// `Debug` never shows the body, secret headers (`Authorization`, cookies, tokens) or secret query values.
impl std::fmt::Debug for HttpRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let headers: Vec<(&str, &str)> = self
            .headers
            .iter()
            .map(|(n, v)| (n.as_str(), crate::redact::header_value(n, v)))
            .collect();
        f.debug_struct("HttpRequest")
            .field("method", &self.method)
            .field("url", &crate::redact::url(&self.url))
            .field("headers", &headers)
            .field("body_len", &self.body.as_ref().map(Vec::len))
            .field("timeout", &self.timeout)
            .finish()
    }
}

impl HttpRequest {
    /// A request without headers or body.
    pub fn new(method: Method, url: Url) -> Self {
        Self {
            method,
            url,
            headers: Vec::new(),
            body: None,
            timeout: None,
            keep_method: false,
        }
    }

    /// Sets a header, replacing an earlier one of the same name
    /// (`URLRequest.setValue(_:forHTTPHeaderField:)`).
    pub fn set_header(&mut self, name: &str, value: &str) {
        if let Some(slot) = self
            .headers
            .iter_mut()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
        {
            slot.1 = value.to_string();
        } else {
            self.headers.push((name.to_string(), value.to_string()));
        }
    }

    /// The value of a header, name compared case-insensitively.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

/// A complete answer.
#[derive(Clone, PartialEq, Eq)]
pub struct HttpResponse {
    /// Status code.
    pub status: u16,
    /// Header fields.
    pub headers: Vec<(String, String)>,
    /// Body.
    pub body: Vec<u8>,
    /// The address that finally answered (after redirects).
    pub url: Option<Url>,
}

/// `Debug` shows the body size only (bodies carry tokens on sign-in) and masks secret headers (`Set-Cookie`).
impl std::fmt::Debug for HttpResponse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let headers: Vec<(&str, &str)> = self
            .headers
            .iter()
            .map(|(n, v)| (n.as_str(), crate::redact::header_value(n, v)))
            .collect();
        f.debug_struct("HttpResponse")
            .field("status", &self.status)
            .field("headers", &headers)
            .field("body_len", &self.body.len())
            .field("url", &self.url.as_ref().map(crate::redact::url))
            .finish()
    }
}

impl HttpResponse {
    /// An answer with a status and a body and no headers.
    pub fn new(status: u16, body: impl Into<Vec<u8>>) -> Self {
        Self {
            status,
            headers: Vec::new(),
            body: body.into(),
            url: None,
        }
    }

    /// Adds a header (builder style).
    #[must_use]
    pub fn with_header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.to_string(), value.to_string()));
        self
    }

    /// The value of a header, name compared case-insensitively.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    /// `200..300`.
    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }

    /// The first `n` bytes as UTF-8 text, `None` if they are not valid UTF-8
    /// (Swift: `String(data: data.prefix(n), encoding: .utf8)`).
    pub fn text_prefix(&self, n: usize) -> Option<String> {
        let end = self.body.len().min(n);
        std::str::from_utf8(&self.body[..end])
            .ok()
            .map(str::to_string)
    }

    /// An answer whose `Content-Type` starts with `text/html`: a gateway in front of
    /// the server answered, not the server (`OwnHeaders.loginPage`, OwnHeaders.swift).
    pub fn is_login_page(&self) -> bool {
        self.header("Content-Type")
            .is_some_and(|t| t.to_lowercase().starts_with("text/html"))
    }
}
