//! Redaction helpers: secrets (tokens, passwords, cookies) must not reach logs, `Debug` output,
//! error strings or crash reports. Everything that prints a request or an address goes through here.

use std::fmt;

use url::Url;

/// What replaces a secret value in any printed text.
pub const MASK: &str = "[redacted]";

/// Query names whose value is a secret (compared case-insensitively, so `ApiKey`, `api_key`,
/// `X-Plex-Token`, `X-Emby-Token` and `password` are all covered).
const SECRET_QUERY: &[&str] = &[
    "apikey",
    "api_key",
    "x-plex-token",
    "x-emby-token",
    "x-mediabrowser-token",
    "token",
    "access_token",
    "accesstoken",
    "auth",
    "authtoken",
    "secret",
    "pw",
    "password",
    "pass",
    "key",
    "sig",
    "signature",
];

/// Header names whose value is a secret.
const SECRET_HEADERS: &[&str] = &[
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-emby-authorization",
    "x-emby-token",
    "x-mediabrowser-token",
    "x-plex-token",
    "x-api-key",
    "x-seerr-api-key",
    "cf-access-client-secret",
    "cf-access-jwt-assertion",
];

/// True if a query item with this name carries a secret.
pub fn is_secret_query(name: &str) -> bool {
    SECRET_QUERY.iter().any(|s| s.eq_ignore_ascii_case(name))
}

/// True if a header with this name carries a secret.
pub fn is_secret_header(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    SECRET_HEADERS.contains(&name.as_str())
        || name.starts_with("cf-access-")
        || name.contains("token")
}

/// The address as it may be printed: user name and password dropped, secret query values masked.
pub fn url(url: &Url) -> String {
    let mut out = url.clone();
    let _ = out.set_username("");
    let _ = out.set_password(None);
    out.set_fragment(None);
    if url.query().is_some() {
        let pairs: Vec<(String, String)> = url
            .query_pairs()
            .map(|(k, v)| {
                let v = if is_secret_query(&k) {
                    MASK.to_owned()
                } else {
                    v.into_owned()
                };
                (k.into_owned(), v)
            })
            .collect();
        out.query_pairs_mut()
            .clear()
            .extend_pairs(pairs.iter().map(|(k, v)| (k.as_str(), v.as_str())));
    }
    out.to_string()
}

/// Like [`url`] for address text; text that is not an address is replaced by [`MASK`] (it might hold a secret).
pub fn url_text(text: &str) -> String {
    Url::parse(text).map_or_else(|_| MASK.to_owned(), |u| url(&u))
}

/// A header value as it may be printed.
pub fn header_value<'a>(name: &str, value: &'a str) -> &'a str {
    if is_secret_header(name) { MASK } else { value }
}

/// A string that is a secret: `Debug` and `Display` print [`MASK`], the value is wiped from memory on drop.
/// Read it with [`Secret::expose`] at the one place that must send it.
#[derive(Clone, PartialEq, Eq, Default)]
pub struct Secret(String);

impl Secret {
    /// Wraps a secret.
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// The real value; call only where it is sent or stored.
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(")?;
        f.write_str(MASK)?;
        f.write_str(")")
    }
}

impl fmt::Display for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(MASK)
    }
}

impl Drop for Secret {
    fn drop(&mut self) {
        zeroize::Zeroize::zeroize(&mut self.0);
    }
}

impl From<String> for Secret {
    fn from(value: String) -> Self {
        Self(value)
    }
}

/// Free text (a panic message, an error chain) as it may be logged: every `name=value` / `name: value` / `"name":"value"`
/// pair whose name is a secret name, every `Bearer`/`Basic`/`MediaBrowser Token=` credential and every `user:pass@`
/// address part is replaced by [`MASK`]. Over-masking is fine; leaking is not.
pub fn scrub(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while !rest.is_empty() {
        let end = rest
            .find(|c: char| !(c.is_alphanumeric() || c == '_' || c == '-'))
            .unwrap_or(rest.len());
        let (word, tail) = rest.split_at(end);
        let secret_name = !word.is_empty() && (is_secret_query(word) || is_secret_header(word));
        let credential_word = matches!(word.to_ascii_lowercase().as_str(), "bearer" | "basic");
        out.push_str(word);
        rest = tail;
        if secret_name || credential_word {
            // Skip a closing quote, then the separator, then the value (quoted or up to the next delimiter).
            let sep_len = rest
                .find(|c: char| !matches!(c, '"' | '\'' | '=' | ':' | ' ' | '\\'))
                .unwrap_or(rest.len());
            let (sep, after) = rest.split_at(sep_len);
            if credential_word || sep.contains('=') || sep.contains(':') {
                let quote = after.chars().next().filter(|c| matches!(c, '"' | '\''));
                let value_len = match quote {
                    Some(q) => after[1..].find(q).map_or(after.len(), |i| i + 2),
                    None if is_whole_line_header(word) => {
                        after.find(['\n', '"', '\'']).unwrap_or(after.len())
                    }
                    None => after
                        .find(|c: char| {
                            c.is_whitespace()
                                || matches!(c, '&' | ',' | ';' | ')' | '}' | '"' | '\'')
                        })
                        .unwrap_or(after.len()),
                };
                if value_len > 0 {
                    out.push_str(sep);
                    out.push_str(MASK);
                    rest = &after[value_len..];
                }
            }
        }
        // Make progress on a delimiter that is not part of a word.
        if let Some(c) = rest.chars().next().filter(|_| end == 0 || word.is_empty()) {
            out.push(c);
            rest = &rest[c.len_utf8()..];
        }
    }
    strip_userinfo(&out)
}

/// Headers whose value has spaces inside (`Bearer abc`, `MediaBrowser Token=..., Client=...`, cookie lists).
fn is_whole_line_header(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    n.contains("authorization") || n.contains("cookie")
}

/// `scheme://user:password@host` -> `scheme://host`.
fn strip_userinfo(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(i) = rest.find("://") {
        let (head, tail) = rest.split_at(i + 3);
        out.push_str(head);
        let stop = tail
            .find(|c: char| c.is_whitespace() || c == '/')
            .unwrap_or(tail.len());
        match tail[..stop].rfind('@') {
            Some(at) => {
                out.push_str(MASK);
                out.push('@');
                rest = &tail[at + 1..];
            }
            None => rest = tail,
        }
    }
    out.push_str(rest);
    out
}

/// Installs a panic hook that hands a scrubbed one-line description to `sink` (the host log) instead of printing the raw
/// payload. Replaces any earlier hook; unwinding stays on, so `catch_unwind` at the FFI still turns the panic into an error.
pub fn install_panic_hook(sink: impl Fn(String) + Send + Sync + 'static) {
    std::panic::set_hook(Box::new(move |info| {
        let payload = info.payload();
        let message = payload
            .downcast_ref::<&str>()
            .map(|s| (*s).to_owned())
            .or_else(|| payload.downcast_ref::<String>().cloned())
            .unwrap_or_default();
        let place = info
            .location()
            .map_or_else(String::new, |l| format!(" at {}:{}", l.file(), l.line()));
        sink(format!("PANIC{place}: {}", scrub(&message)));
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn masks_query_userinfo_and_keeps_the_rest() {
        let u = Url::parse("https://user:pw@h.test:8096/Items/1/Images/Primary?maxWidth=300&ApiKey=SECRET1&x-plex-token=SECRET2#frag").expect("url");
        let shown = url(&u);
        assert!(!shown.contains("SECRET"), "{shown}");
        assert!(!shown.contains("user"), "{shown}");
        assert!(shown.contains("maxWidth=300"), "{shown}");
    }

    #[test]
    fn secret_never_prints() {
        let s = Secret::new("hunter2");
        assert!(!format!("{s:?} {s}").contains("hunter2"));
        assert_eq!(s.expose(), "hunter2");
    }

    #[test]
    fn header_names() {
        assert!(is_secret_header("Authorization"));
        assert!(is_secret_header("CF-Access-Client-Id"));
        assert!(is_secret_header("X-Plex-Token"));
        assert!(!is_secret_header("Accept"));
    }

    #[test]
    fn scrub_masks_planted_secrets_in_free_text() {
        let cases = [
            "request failed: https://h.test/Items?api_key=SECRETA&limit=5",
            "header Authorization: Bearer SECRETB end",
            "MediaBrowser Token=\"SECRETC\", Client=\"x\"",
            "{\"AccessToken\":\"SECRETD\",\"Id\":1}",
            "connect to https://bob:SECRETE@host.test/path failed",
            "x-plex-token=SECRETF",
            "password: SECRETG",
        ];
        for c in cases {
            let shown = scrub(c);
            assert!(!shown.contains("SECRET"), "{c} -> {shown}");
        }
        assert_eq!(
            scrub("nothing to hide: limit=5"),
            "nothing to hide: limit=5"
        );
    }
}
