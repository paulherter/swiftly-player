//! The user's own request headers for servers behind a gateway (Cloudflare Access, Authelia),
//! ported from `OwnHeaders.swift`. The table is global, keyed by the server's origin and base
//! path, so only requests to that server carry them (never TMDB or another host).

use std::collections::BTreeMap;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use swiftly_net::{HttpRequest, Url};

/// One header of the user's own (`OwnHeader`, OwnHeaders.swift:9-20). Persisted as
/// `{"name":…,"wert":…}`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct OwnHeader {
    /// Header name.
    pub name: String,
    /// Header value.
    #[serde(rename = "wert")]
    pub value: String,
}

impl OwnHeader {
    /// A header.
    pub fn new(name: &str, value: &str) -> Self {
        Self {
            name: name.into(),
            value: value.into(),
        }
    }
}

type Table = BTreeMap<String, Vec<OwnHeader>>;

static PANEL: Mutex<Table> = Mutex::new(BTreeMap::new());

fn panel() -> std::sync::MutexGuard<'static, Table> {
    PANEL
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Namespace of the own-header rules and the shared table.
pub struct OwnHeaders;

const LOCKED: [&str; 13] = [
    "authorization",
    "x-emby-authorization",
    "x-emby-token",
    "x-mediabrowser-token",
    "cookie",
    "accept",
    "content-type",
    "content-length",
    "host",
    "connection",
    "transfer-encoding",
    "proxy-authorization",
    "upgrade",
];

struct Parts {
    origin: String,
    path: String,
}

fn parts(url: &Url) -> Option<Parts> {
    let mut scheme = url.scheme().to_lowercase();
    let host = url.host_str()?.to_lowercase();
    if host.is_empty() {
        return None;
    }
    if scheme == "ws" {
        scheme = "http".into();
    }
    if scheme == "wss" {
        scheme = "https".into();
    }
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let port = url
        .port()
        .unwrap_or(if scheme == "https" { 443 } else { 80 });
    let mut path = url.path().to_string();
    if path.split('/').any(|s| s == "..") {
        return None;
    }
    while path.ends_with('/') {
        path.pop();
    }
    Some(Parts {
        origin: format!("{scheme}://{host}:{port}"),
        path,
    })
}

fn key(base: &Url) -> Option<String> {
    parts(base).map(|p| p.origin + &p.path)
}

impl OwnHeaders {
    /// Names that never go out (OwnHeaders.swift:28-33).
    pub fn is_locked(name: &str) -> bool {
        LOCKED.contains(&name.trim().to_lowercase().as_str())
    }

    /// Is this a legal header name (RFC 7230 token)? (OwnHeaders.swift:40-45)
    pub fn name_suits(name: &str) -> bool {
        !name.is_empty()
            && name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "!#$%&'*+-.^_`|~".contains(c))
    }

    /// Drops empty, malformed, locked and duplicate entries; trims name and value
    /// (OwnHeaders.swift:50-62). The first of two names that differ only in case wins.
    pub fn cleaned(headers: &[OwnHeader]) -> Vec<OwnHeader> {
        let mut seen = std::collections::HashSet::new();
        headers
            .iter()
            .filter_map(|h| {
                // Swift trims `.whitespacesAndNewlines` (zero-width space and BOM included, F-oracle-E04).
                let name = swiftly_rules::trim_whitespaces_and_newlines(&h.name);
                let value = swiftly_rules::trim_whitespaces_and_newlines(&h.value);
                let bad_value = value.chars().any(|c| (c as u32) < 0x20 || c as u32 == 0x7F);
                if !Self::name_suits(name)
                    || value.is_empty()
                    || LOCKED.contains(&name.to_lowercase().as_str())
                    || bad_value
                    || !seen.insert(name.to_lowercase())
                {
                    return None;
                }
                Some(OwnHeader::new(name, value))
            })
            .collect()
    }

    /// The names for the log, never the values (OwnHeaders.swift:66).
    pub fn names(headers: &[OwnHeader]) -> String {
        if headers.is_empty() {
            "keine".into()
        } else {
            headers
                .iter()
                .map(|h| h.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        }
    }

    /// Registers the headers for a server; an empty list removes the server
    /// (OwnHeaders.swift:85-91).
    pub fn set_down(headers: &[OwnHeader], base: &Url) {
        let Some(key) = key(base) else { return };
        let clean = Self::cleaned(headers);
        let mut table = panel();
        if clean.is_empty() {
            table.remove(&key);
        } else {
            table.insert(key, clean);
        }
    }

    /// The headers registered for exactly this base (OwnHeaders.swift:94-98).
    pub fn registered(base: &Url) -> Vec<OwnHeader> {
        key(base)
            .and_then(|k| panel().get(&k).cloned())
            .unwrap_or_default()
    }

    /// The headers that belong to a request address: same origin and under the base path;
    /// the longest base wins (OwnHeaders.swift:104-120). `wss` counts as `https`.
    pub fn of(url: &Url) -> Vec<OwnHeader> {
        let Some(target) = parts(url) else {
            return Vec::new();
        };
        let table = panel();
        let mut best: Option<(usize, &Vec<OwnHeader>)> = None;
        for (k, headers) in table.iter() {
            let Some(base) = Url::parse(k).ok().and_then(|u| parts(&u)) else {
                continue;
            };
            let under = base.path.is_empty()
                || target.path == base.path
                || target.path.starts_with(&format!("{}/", base.path));
            if base.origin == target.origin
                && under
                && base.path.len() as isize >= best.map_or(-1, |b| b.0 as isize)
            {
                best = Some((base.path.len(), headers));
            }
        }
        best.map(|b| b.1.clone()).unwrap_or_default()
    }

    /// The headers as a name-to-value map (OwnHeaders.swift:123-125).
    pub fn fields(url: &Url) -> BTreeMap<String, String> {
        let mut map = BTreeMap::new();
        for h in Self::of(url) {
            map.entry(h.name).or_insert(h.value);
        }
        map
    }

    /// Sets the registered headers for the request's address on the request
    /// (`ownHeadersSet`, OwnHeaders.swift:128-137).
    pub fn apply(request: &mut HttpRequest) {
        for h in Self::cleaned(&Self::of(&request.url)) {
            request.set_header(&h.name, &h.value);
        }
    }

    /// The table as JSON for storage.
    pub fn store() -> String {
        serde_json::to_string(&*panel()).unwrap_or_else(|_| "{}".into())
    }

    /// Loads a stored table; unreadable data gives an empty table (OwnHeaders.swift:152-162).
    pub fn load(data: Option<&str>) {
        let read: Table = data
            .and_then(|d| serde_json::from_str(d).ok())
            .unwrap_or_default();
        let mut clean = Table::new();
        for (s, k) in read {
            let headers = Self::cleaned(&k);
            if let (false, Some(new)) = (
                headers.is_empty(),
                Url::parse(&s).ok().and_then(|u| key(&u)),
            ) {
                clean.insert(new, headers);
            }
        }
        *panel() = clean;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(s: &str) -> Url {
        Url::parse(s).expect("url")
    }

    /// The table is global (as in Swift, where the suite is `.serialized`); `load` replaces
    /// all of it, so the tests that touch it run one after the other.
    fn lock() -> std::sync::MutexGuard<'static, ()> {
        static SERIAL: Mutex<()> = Mutex::new(());
        SERIAL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    // OwnHeadersTests.swift:20 cleaned
    #[test]
    fn cleaned_drops_empty_broken_locked_and_duplicates() {
        let raw = vec![
            OwnHeader::new(" CF-Access-Client-Id ", " id.access "),
            OwnHeader::new("", "ohne-namen"),
            OwnHeader::new("Ohne-Wert", "   "),
            OwnHeader::new("Mit Leerzeichen", "x"),
            OwnHeader::new("Doppel:punkt", "x"),
            OwnHeader::new("Authorization", "Bearer fremd"),
            OwnHeader::new("x-emby-token", "fremd"),
            OwnHeader::new("Cookie", "a=b"),
            OwnHeader::new("X-Umbruch", "a\r\nX-Boese: 1"),
            OwnHeader::new("cf-access-client-id", "zweiter"),
            OwnHeader::new("P-Access-Token", "erfunden"),
        ];
        assert_eq!(
            OwnHeaders::cleaned(&raw),
            vec![
                OwnHeader::new("CF-Access-Client-Id", "id.access"),
                OwnHeader::new("P-Access-Token", "erfunden")
            ]
        );
    }

    #[test]
    fn locked_is_case_independent() {
        assert!(OwnHeaders::is_locked("AUTHORIZATION"));
        assert!(OwnHeaders::is_locked(" X-Emby-Authorization"));
        assert!(!OwnHeaders::is_locked("CF-Access-Client-Secret"));
        assert!(!OwnHeaders::is_locked("User-Agent"));
    }

    #[test]
    fn log_gets_names_never_values() {
        let z = OwnHeaders::names(&[OwnHeader::new("CF-Access-Client-Secret", "streng-geheim")]);
        assert_eq!(z, "CF-Access-Client-Secret");
    }

    #[test]
    fn only_the_own_server_not_tmdb() {
        let _g = lock();
        let base = url("https://jf.eins.test");
        OwnHeaders::set_down(&[OwnHeader::new("X-Tor", "auf")], &base);
        assert_eq!(
            OwnHeaders::of(&url("https://jf.eins.test/Items/1/Images/Primary?tag=a")).len(),
            1
        );
        assert_eq!(
            OwnHeaders::of(&url("https://JF.eins.test:443/System/Info")).len(),
            1
        );
        assert!(OwnHeaders::of(&url("https://image.tmdb.org/t/p/w342/a.jpg")).is_empty());
        assert!(
            OwnHeaders::of(&url("http://jf.eins.test/System/Info")).is_empty(),
            "other scheme"
        );
        assert!(
            OwnHeaders::of(&url("https://jf.eins.test:8920/System/Info")).is_empty(),
            "other port"
        );
        assert!(OwnHeaders::of(&url("https://jf.eins.test.boese.test/")).is_empty());
        OwnHeaders::set_down(&[], &base);
    }

    #[test]
    fn control_channel_counts_wss_like_https() {
        let _g = lock();
        let base = url("https://jf.zwei.test");
        OwnHeaders::set_down(&[OwnHeader::new("X-Tor", "auf")], &base);
        assert_eq!(
            OwnHeaders::of(&url("wss://jf.zwei.test/socket?api_key=x")).len(),
            1
        );
        OwnHeaders::set_down(&[], &base);
    }

    #[test]
    fn under_a_path_only_the_path_and_the_longest_base_wins() {
        let _g = lock();
        let jf = url("https://proxy.drei.test/jellyfin/");
        let seerr = url("https://proxy.drei.test/jellyfin/seerr");
        OwnHeaders::set_down(&[OwnHeader::new("X-Wer", "jf")], &jf);
        OwnHeaders::set_down(&[OwnHeader::new("X-Wer", "seerr")], &seerr);
        let who = |u: &str| OwnHeaders::fields(&url(u)).get("X-Wer").cloned();
        assert_eq!(
            who("https://proxy.drei.test/jellyfin/Items").as_deref(),
            Some("jf")
        );
        assert_eq!(
            who("https://proxy.drei.test/jellyfin/seerr/api").as_deref(),
            Some("seerr")
        );
        assert!(OwnHeaders::of(&url("https://proxy.drei.test/jellyfinx/Items")).is_empty());
        assert!(OwnHeaders::of(&url("https://proxy.drei.test/anderes")).is_empty());
        assert!(OwnHeaders::of(&url("https://proxy.drei.test/jellyfin/../anderes")).is_empty());
        OwnHeaders::set_down(&[], &jf);
        OwnHeaders::set_down(&[], &seerr);
    }

    #[test]
    fn empty_list_removes_the_server_and_leaves_requests_alone() {
        let _g = lock();
        let base = url("https://jf.vier.test");
        OwnHeaders::set_down(&[OwnHeader::new("X-Tor", "auf")], &base);
        OwnHeaders::set_down(&[], &base);
        assert!(OwnHeaders::registered(&base).is_empty());
        let mut req = HttpRequest::new(
            swiftly_net::Method::Get,
            url("https://jf.vier.test/System/Info"),
        );
        OwnHeaders::apply(&mut req);
        assert!(req.headers.is_empty());
    }

    // The table survives storing, garbage does not (OwnHeadersTests.swift:107).
    // `load` replaces the whole table, so this test uses its own base and restores nothing
    // else; the other tests re-register what they need.
    #[test]
    fn store_roundtrip_and_garbage() {
        let _g = lock();
        let base = url("https://jf.fuenf.test/");
        OwnHeaders::set_down(&[OwnHeader::new("X-Tor", "auf")], &base);
        let stored = OwnHeaders::store();
        OwnHeaders::set_down(&[], &base);
        assert!(OwnHeaders::registered(&base).is_empty());
        OwnHeaders::load(Some(&stored));
        assert_eq!(
            OwnHeaders::registered(&base),
            vec![OwnHeader::new("X-Tor", "auf")]
        );
        OwnHeaders::set_down(&[], &base);
        OwnHeaders::load(Some("kein json"));
        assert!(OwnHeaders::registered(&base).is_empty());
    }
}
