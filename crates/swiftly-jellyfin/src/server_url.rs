//! Turning what the user typed into a server address (`AppModelURLNormalizer`, ServerURL.swift).
//!
//! "tv.example.de" or "192.168.1.5:8096" becomes a usable base address. Without a scheme the
//! guess goes the right way round: home-network addresses get `http`, everything else `https`.

use url::Url;

/// A server address with the zone id of a link-local IPv6 host (`http://[fe80::1%25en0]:8096`)
/// kept apart: the `url` crate cannot hold a zone, Foundation's `URL` can (and so connects).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ZonedAddress {
    /// The address without the zone (`http://[fe80::1]:8096`).
    pub url: Url,
    /// The zone as written after `%25` (`en0`), if the host had one.
    pub zone: Option<String>,
    /// A port the user typed that is the default of the scheme (`https://h:443`): the `url` crate drops it, Foundation's
    /// `URL` keeps it in `absoluteString`, so the stored text keeps it too (the same endpoint either way).
    pub explicit_default_port: Option<u16>,
}

impl ZonedAddress {
    /// `text` (a serialisation of an address made from [`Self::url`], e.g. after `set_scheme`)
    /// with the zone put back into the host and an explicit default port kept (only while the scheme is the same:
    /// the `http` retry of an `https://h:443` address goes to `http://h`, not to plain text on port 443).
    pub fn with_zone(&self, other: &Url) -> String {
        let mut text = other.to_string();
        if let (Some(port), Some(host)) = (self.explicit_default_port, other.host_str())
            && other.scheme() == self.url.scheme()
            && other.port().is_none()
            && let Some(start) = text.find("://").map(|i| i + 3)
            && text[start..].starts_with(host)
        {
            text.insert_str(start + host.len(), &format!(":{port}"));
        }
        let (Some(zone), Some(host)) = (&self.zone, other.host_str()) else {
            return text;
        };
        match host.strip_suffix(']') {
            Some(inner) => {
                let start = text.find("://").map_or(0, |i| i + 3);
                text.replace_range(start..start + host.len(), &format!("{inner}%25{zone}]"));
                text
            }
            None => text,
        }
    }

    /// The host as `URL.host()` reports it in Swift: no brackets, the zone as `%25en0`.
    pub fn host(&self) -> Option<String> {
        let host = self
            .url
            .host_str()?
            .trim_start_matches('[')
            .trim_end_matches(']')
            .to_string();
        Some(match &self.zone {
            Some(zone) => format!("{host}%25{zone}"),
            None => host,
        })
    }
}

/// Cuts the zone out of a bracketed IPv6 host of `text`: `[fe80::1%25en0]` and `[fe80::1%en0]`
/// (Foundation writes both as `%25en0`). Only a real IPv6 address and a zone of letters, digits
/// and `.-_~` count; anything else is left alone for the normal parser to refuse.
fn split_zone(text: &str) -> (String, Option<String>) {
    let Some(start) = text.find("://").map(|i| i + 3) else {
        return (text.to_string(), None);
    };
    let rest = &text[start..];
    let authority_end = rest.find(['/', '?', '#', '\\']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    let Some(open) = authority.find('[') else {
        return (text.to_string(), None);
    };
    let Some(close) = authority[open..].find(']').map(|i| open + i) else {
        return (text.to_string(), None);
    };
    let inside = &authority[open + 1..close];
    let Some((address, zone)) = inside.split_once('%') else {
        return (text.to_string(), None);
    };
    // `%25` is the encoded percent sign; "%25" alone is an empty zone.
    let zone = zone.strip_prefix("25").unwrap_or(zone);
    let sound = !zone.is_empty()
        && zone
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | '~'))
        && address.parse::<std::net::Ipv6Addr>().is_ok();
    if !sound {
        return (text.to_string(), None);
    }
    let from = start + open + 1;
    let stripped = format!("{}{}{}", &text[..from], address, &text[start + close..]);
    (stripped, Some(zone.to_string()))
}

/// `AppModelURLNormalizer.normalize` (ServerURL.swift:7): trim, add a scheme when there is
/// none, drop trailing slashes. `None` for an empty text or one without a host. A zone id of
/// an IPv6 host is accepted but not part of the `Url`; [`normalize_zoned`] and
/// [`normalize_string`] keep it.
pub fn normalize(raw: &str) -> Option<Url> {
    normalize_zoned(raw).map(|a| a.url)
}

/// [`normalize`] with the zone id of an IPv6 host kept apart.
pub fn normalize_zoned(raw: &str) -> Option<ZonedAddress> {
    let mut text = raw.trim().to_string();
    if text.is_empty() {
        return None;
    }
    if !text.contains("://") {
        // A bare IPv6 address needs brackets, otherwise its colons read as a port.
        if is_ipv6(&text) {
            text = format!("[{text}]");
        }
        let scheme = if is_home_network(&text) {
            "http://"
        } else {
            "https://"
        };
        text = format!("{scheme}{text}");
    }
    while text.ends_with('/') {
        text.pop();
    }
    let (text, zone) = split_zone(&text);
    // Foundation refuses blanks and control characters behind a zone host; the `url` crate would trim them.
    if zone.is_some() && text.ends_with(|c: char| c.is_whitespace() || c.is_control()) {
        return None;
    }
    let mut url = Url::parse(&text).ok()?;
    url.host_str().filter(|h| !h.is_empty())?;
    // Security: only http(s) is a server address (no ftp:, file:, ws:), and user info never stays in the stored
    // address (it would reach logs, the UI and every later request). Swift keeps both; Rust is stricter on purpose.
    if !matches!(url.scheme(), "http" | "https") {
        return None;
    }
    let _ = url.set_username("");
    let _ = url.set_password(None);
    let explicit_default_port = typed_default_port(&text, &url);
    Some(ZonedAddress {
        url,
        zone,
        explicit_default_port,
    })
}

/// The port typed in `text` when it is the default of the parsed scheme (the `url` crate has dropped it from `url`).
fn typed_default_port(text: &str, url: &Url) -> Option<u16> {
    let default = match url.scheme() {
        "http" => 80,
        "https" => 443,
        _ => return None,
    };
    if url.port().is_some() {
        return None;
    }
    let start = text.find("://")? + 3;
    let rest = &text[start..];
    let authority = &rest[..rest.find(['/', '?', '#', '\\']).unwrap_or(rest.len())];
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    // A bracketed IPv6 host holds colons of its own: the port is what follows the closing bracket.
    let port_text = match host_port.rfind(']') {
        Some(close) => host_port[close + 1..].strip_prefix(':')?,
        None => host_port.rsplit_once(':')?.1,
    };
    (port_text == default.to_string()).then_some(default)
}

/// The normalised address as text without the trailing slash `Url` adds to a bare host
/// (`absoluteString` of the Swift `URL` keeps what was typed), with the zone id of an IPv6 host.
pub fn normalize_string(raw: &str) -> Option<String> {
    let address = normalize_zoned(raw)?;
    let s = address.with_zone(&address.url);
    Some(match address.url.path() {
        "/" if address.url.query().is_none() && address.url.fragment().is_none() => {
            s.trim_end_matches('/').to_string()
        }
        _ => s,
    })
}

/// [`reversed`] for an address as text, zone id included (`None` unless it is `https`).
pub fn reversed_string(raw: &str) -> Option<String> {
    let address = normalize_zoned(raw)?;
    let other = reversed(&address.url)?;
    Some(address.with_zone(&other).trim_end_matches('/').to_string())
}

/// `AppModelURLNormalizer.reversed` (ServerURL.swift:58): the same address with `http`, for the
/// second attempt after `https` failed at the connection. `None` if it is not `https`: a step
/// back to unencrypted must never happen when the user asked for `https`... and from `http`
/// there is nowhere to go.
pub fn reversed(url: &Url) -> Option<Url> {
    if url.scheme() != "https" {
        return None;
    }
    let mut other = url.clone();
    other.set_scheme("http").ok()?;
    Some(other)
}

/// `AppModelURLNormalizer.isHomeNetwork` (ServerURL.swift:69): IP literals, `.local`, `.lan`,
/// `.home`, `.internal`, `localhost` and bare host names.
pub fn is_home_network(text: &str) -> bool {
    let name = text.split('/').find(|s| !s.is_empty()).unwrap_or(text);
    if let Some(rest) = name.strip_prefix('[') {
        return rest.find(']').is_some_and(|i| is_ipv6(&rest[..i]));
    }
    if is_ipv6(name) {
        return true;
    }
    let without_port = name.split(':').find(|s| !s.is_empty()).unwrap_or(name);
    let small = without_port.to_lowercase();
    if [".local", ".lan", ".home", ".internal"]
        .iter()
        .any(|s| small.ends_with(s))
        || small == "localhost"
    {
        return true;
    }
    if !small.contains('.') {
        return true;
    }
    let parts: Vec<&str> = small.split('.').collect();
    parts.len() == 4
        && parts.iter().all(|p| {
            !p.is_empty()
                && p.chars().all(|c| c.is_ascii_digit())
                && p.parse::<u32>().is_ok_and(|n| n < 256)
        })
}

/// `AppModelURLNormalizer.isIPv6`: at least two colons, otherwise only hex digits and dots; a
/// zone ("fe80::1%en0") is cut off first.
pub fn is_ipv6(text: &str) -> bool {
    let without_zone = text.split('%').next().unwrap_or(text);
    without_zone.matches(':').count() >= 2
        && without_zone
            .chars()
            .all(|c| c == ':' || c == '.' || c.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    // AuthRequestTests.swift:308 ipGetsHTTP
    #[test]
    fn ip_gets_http() {
        let url = normalize("192.168.1.5:8096").unwrap();
        assert_eq!(url.scheme(), "http");
        assert_eq!(url.host_str(), Some("192.168.1.5"));
        assert_eq!(url.port(), Some(8096));
    }

    // Swift keeps an explicit default port in `absoluteString` ("https://h:443"); so does the stored text.
    #[test]
    fn an_explicit_default_port_stays_in_the_stored_text() {
        assert_eq!(
            normalize_string("https://tv.example.de:443/jellyfin/").as_deref(),
            Some("https://tv.example.de:443/jellyfin")
        );
        assert_eq!(
            normalize_string("http://box.home:80").as_deref(),
            Some("http://box.home:80")
        );
        assert_eq!(
            normalize_string("tv.example.de:443").as_deref(),
            Some("https://tv.example.de:443")
        );
        assert_eq!(
            normalize_string("https://[2001:db8::1]:443/x").as_deref(),
            Some("https://[2001:db8::1]:443/x")
        );
        // A port that is not the default of the scheme is a normal port, nothing else changes.
        assert_eq!(
            normalize_string("https://tv.example.de:8920").as_deref(),
            Some("https://tv.example.de:8920")
        );
        assert_eq!(
            normalize_string("http://tv.example.de:443").as_deref(),
            Some("http://tv.example.de:443")
        );
        assert_eq!(
            normalize_string("https://tv.example.de").as_deref(),
            Some("https://tv.example.de")
        );
        assert_eq!(
            normalize_string("https://tv.example.de:0443").as_deref(),
            Some("https://tv.example.de")
        );
        // The Url itself cannot hold it; the retry over http goes to port 80, not plain text on port 443.
        assert_eq!(normalize("https://tv.example.de:443").unwrap().port(), None);
        assert_eq!(
            reversed_string("https://tv.example.de:443").as_deref(),
            Some("http://tv.example.de")
        );
    }

    // :316 localGetsHTTP
    #[test]
    fn local_gets_http() {
        assert_eq!(normalize("kiste.local:8096").unwrap().scheme(), "http");
    }

    // :321 publicGetsHTTPS
    #[test]
    fn public_gets_https() {
        assert_eq!(normalize("jellyfin.example.com").unwrap().scheme(), "https");
        assert_eq!(normalize("tv.example.de").unwrap().scheme(), "https");
    }

    // :326 schemaStays
    #[test]
    fn scheme_stays() {
        assert_eq!(normalize("http://tv.example.de").unwrap().scheme(), "http");
        assert_eq!(normalize("https://192.168.1.5").unwrap().scheme(), "https");
    }

    // :332 alternate
    #[test]
    fn alternate_address_for_the_second_try() {
        let url = normalize("tv.example.de").unwrap();
        assert_eq!(reversed(&url).unwrap().scheme(), "http");
        let local = normalize("192.168.1.5").unwrap();
        assert!(reversed(&local).is_none());
    }

    #[test]
    fn empty_or_hostless_text_is_nothing() {
        assert!(normalize("").is_none());
        assert!(normalize("   \n").is_none());
        assert!(normalize("http://").is_none());
    }

    #[test]
    fn trailing_slashes_and_blanks_are_dropped() {
        assert_eq!(
            normalize_string("  https://h.de/jellyfin//  ").as_deref(),
            Some("https://h.de/jellyfin")
        );
        assert_eq!(
            normalize_string("192.168.1.5:8096").as_deref(),
            Some("http://192.168.1.5:8096")
        );
    }

    #[test]
    fn bare_ipv6_gets_brackets_and_http() {
        let url = normalize("fd00::5").unwrap();
        assert_eq!(url.scheme(), "http");
        assert_eq!(url.host_str(), Some("[fd00::5]"));
        let with_port = normalize("[fd00::5]:8096").unwrap();
        assert_eq!((with_port.scheme(), with_port.port()), ("http", Some(8096)));
    }

    // Foundation's URL takes a link-local IPv6 host with a zone id; Swift writes it as `%25en0`.
    #[test]
    fn zone_id_of_a_link_local_address_is_kept() {
        for (typed, text) in [
            ("fe80::1%en0", "http://[fe80::1%25en0]"),
            ("[fe80::1%en0]:8096", "http://[fe80::1%25en0]:8096"),
            ("http://[fe80::1%25en0]:8096", "http://[fe80::1%25en0]:8096"),
            (
                "http://[fe80::1%en0]:8096/jellyfin/",
                "http://[fe80::1%25en0]:8096/jellyfin",
            ),
            ("https://[FE80::1%25en0.1]", "https://[fe80::1%25en0.1]"),
            ("  [::1%25lo0]  ", "http://[::1%25lo0]"),
        ] {
            assert_eq!(normalize_string(typed).as_deref(), Some(text), "{typed}");
            assert!(normalize(typed).is_some(), "{typed}");
        }
        let a = normalize_zoned("http://[fe80::1%25en0]:8096").unwrap();
        assert_eq!(
            (a.url.host_str(), a.url.port(), a.zone.as_deref()),
            (Some("[fe80::1]"), Some(8096), Some("en0"))
        );
        assert_eq!(a.host().as_deref(), Some("fe80::1%25en0"));
        assert_eq!(normalize_zoned("192.168.1.5").unwrap().zone, None);
    }

    #[test]
    fn zone_id_survives_the_second_try_with_http() {
        assert_eq!(
            reversed_string("https://[fe80::1%25en0]:8920").as_deref(),
            Some("http://[fe80::1%25en0]:8920")
        );
        assert_eq!(reversed_string("http://[fe80::1%25en0]"), None);
        assert_eq!(
            reversed_string("tv.example.de").as_deref(),
            Some("http://tv.example.de")
        );
    }

    // What stays refused: no real IPv6 address, an empty or odd zone, text around the brackets.
    #[test]
    fn broken_zone_ids_stay_refused() {
        for typed in [
            "http://[fe80::1%25]",
            "http://[fe80::1%]",
            "http://[fe80::zz%25en0]",
            "http://[1.2.3.4%25en0]",
            "http://[fe80::1%25en0/x]",
            "http://[fe80::1%25en 0]",
            "http://[fe80::1%25en0:1]",
            "http://[fe80::1%25ä]",
            "http://[fe80::1%25en0",
            "http://[fe80::1%25en0]x",
            "http://[fe80::1%25en0]:8096:1",
            "http://[fe80::1%25en0]:0x50",
            "http://[fe80::1%25en0]:99999",
            "http://fe80::1%en0:8096/",
            "fe80::1%en0:8096",
            "ftp://[fe80::1%25en0]",
        ] {
            assert!(normalize(typed).is_none(), "{typed}");
            assert!(normalize_string(typed).is_none(), "{typed}");
        }
    }

    #[test]
    fn home_network_rules() {
        for home in [
            "localhost",
            "nas",
            "box.lan",
            "x.home",
            "y.internal",
            "10.0.0.2",
            "fe80::1%en0",
        ] {
            assert!(is_home_network(home), "{home}");
        }
        for public in ["example.com", "300.1.1.1", "1.2.3", "media.home.arpa"] {
            assert!(!is_home_network(public), "{public}");
        }
    }
}
