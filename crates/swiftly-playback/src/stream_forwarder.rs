//! The pure part of the stream forwarder in front of the player (JellyfinKit/StreamForwarder.swift).
//!
//! Servers behind a gateway (Cloudflare Access, Authelia ...) only let through requests that
//! carry the user's own headers. The player engine cannot set arbitrary headers, so the app runs
//! a small HTTP service on `127.0.0.1:<port>`: it takes the player's request, fetches the same
//! URL from the server with the headers, and streams status, seek headers and body back.
//!
//! **The seam.** The local TCP listener, the connection threads/tasks and the HTTP client live in
//! the host (tokio only in the host crate). This module is sans-I/O and holds every decision the
//! host needs to make, as plain functions on bytes and strings:
//!
//! - the address table ([`ForwardTable`]): origin to random token and back, rewriting a server
//!   URL to `http://127.0.0.1:<port>/<token>/path?query` and back (the token generator is
//!   passed in);
//! - reading the player's request head ([`RequestHeader::parse`], [`find_head_end`]) and writing
//!   the response head ([`response_head`]);
//! - which of the player's headers pass to the server and which own headers are added
//!   ([`inject_headers`]);
//! - Range handling and fetching in pieces ([`section_read`], [`content_section_read`],
//!   [`piece_end`], [`piece_request`], [`adjust_first_response`]);
//! - HLS playlist rewriting ([`list_write`]);
//! - the backlog rule ([`Backpressure`]): suspend at 8 MiB, resume at 2 MiB, abort at 64 MiB.
//!
//! The host reads the head into a buffer until [`find_head_end`] says it is complete, parses it,
//! answers 405 for anything but GET/HEAD ([`method_allowed`]) and 404 for a wrong token, builds
//! the outgoing request from [`inject_headers`] plus the own headers, and feeds each received
//! chunk to a [`Backpressure`], acting on the returned [`PressureAction`].

use std::collections::BTreeMap;

use swiftly_jellyfin::{OwnHeader, OwnHeaders};
use swiftly_net::Url;

/// Waiting bytes at which the request to the server is paused (StreamForwarder.swift:198).
pub const HALT_OFF: u64 = 8 << 20;
/// ... and at which it resumes (:200).
pub const NEXT_OFF: u64 = 2 << 20;
/// Hard limit: above it, abort; the player resumes with a Range (:202).
pub const UPPER_LIMIT: u64 = 64 << 20;
/// Playlists are small; anything bigger is not one (:204).
pub const LISTS_LIMIT: u64 = 4 << 20;
/// Piece size where throttling is only possible by fetching in pieces (:327).
pub const PIECE: u64 = 16 << 20;
/// More than this much head is not a player request (:430).
pub const HEAD_LIMIT: usize = 65536;

/// Request headers of the player that pass to the server (StreamForwarder.swift:213).
pub const PASSED_REQUEST_HEADERS: [&str; 4] = ["Range", "If-Range", "User-Agent", "Accept"];
/// Response headers that pass back to the player (:253).
pub const PASSED_RESPONSE_HEADERS: [&str; 6] = [
    "Content-Type",
    "Content-Length",
    "Content-Range",
    "Accept-Ranges",
    "Last-Modified",
    "ETag",
];

// MARK: Address table

/// Token to origin (`https://host[:port]`), and back (StreamForwarder.swift:63-66).
#[derive(Debug, Default, Clone)]
pub struct ForwardTable {
    origin_mark: BTreeMap<String, String>,
    mark_origin: BTreeMap<String, String>,
}

/// A random 128-bit token as 32 lowercase hex characters (StreamForwarder.swift:144).
pub fn mark_from_bytes(bytes: [u8; 16]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

impl ForwardTable {
    /// An empty table.
    pub fn new() -> Self {
        Self::default()
    }

    /// The address the player should get (StreamForwarder.swift:94).
    ///
    /// Unchanged if no headers are configured for the server (`headers_present` false) or the
    /// URL is not `http(s)` with a host. Each origin gets one token, made by `new_mark` the first
    /// time. `port` is the port the host listens on.
    pub fn address_for(
        &mut self,
        url: &Url,
        port: u16,
        headers_present: bool,
        new_mark: impl FnOnce() -> String,
    ) -> Url {
        let scheme = url.scheme().to_lowercase();
        let Some(host) = url.host_str().filter(|h| !h.is_empty()) else {
            return url.clone();
        };
        if !headers_present || (scheme != "http" && scheme != "https") {
            return url.clone();
        }
        let origin = match url.port() {
            Some(p) => format!("{scheme}://{host}:{p}"),
            None => format!("{scheme}://{host}"),
        };
        let mark = match self.mark_origin.get(&origin) {
            Some(m) => m.clone(),
            None => {
                let m = new_mark();
                self.mark_origin.insert(origin.clone(), m.clone());
                self.origin_mark.insert(m.clone(), origin);
                m
            }
        };
        let query = url.query().map(|q| format!("?{q}")).unwrap_or_default();
        Url::parse(&format!(
            "http://127.0.0.1:{port}/{mark}{}{query}",
            url.path()
        ))
        .unwrap_or_else(|_| url.clone())
    }

    /// From the player's request path the address at the server and the token; `None` for a
    /// wrong token (StreamForwarder.swift:129).
    pub fn target_for(&self, request_path: &str) -> Option<(Url, String)> {
        let without = request_path.strip_prefix('/')?;
        let end = without.find(['/', '?']).unwrap_or(without.len());
        let mark = &without[..end];
        let mut rest = without[end..].to_owned();
        if !rest.starts_with('/') {
            rest.insert(0, '/');
        }
        let origin = self.origin_mark.get(mark)?;
        let url = Url::parse(&format!("{origin}{rest}")).ok()?;
        Some((url, mark.to_owned()))
    }

    /// The token of an origin, if one was handed out.
    pub fn mark_of(&self, origin: &str) -> Option<&str> {
        self.mark_origin.get(origin).map(String::as_str)
    }
}

// MARK: Request head

/// The player's request head, dismantled (StreamForwarder.swift:437).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestHeader {
    /// Method ("GET").
    pub procedure: String,
    /// Request target (path and query).
    pub target: String,
    /// Header names in lower case.
    pub headers: BTreeMap<String, String>,
}

impl RequestHeader {
    /// Dismantle a request head (StreamForwarder.swift:456); `None` without method and target.
    pub fn parse(text: &str) -> Option<Self> {
        let mut rows = text.split("\r\n");
        let first: Vec<&str> = rows.next()?.split(' ').filter(|p| !p.is_empty()).collect();
        if first.len() < 2 {
            return None;
        }
        let mut headers = BTreeMap::new();
        for row in rows {
            let Some((name, value)) = row.split_once(':') else {
                continue;
            };
            headers.insert(
                name.trim_matches([' ', '\t']).to_lowercase(),
                value.trim_matches([' ', '\t']).to_owned(),
            );
        }
        Some(Self {
            procedure: first[0].to_owned(),
            target: first[1].to_owned(),
            headers,
        })
    }

    /// A header by case-insensitive name.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(&name.to_lowercase()).map(String::as_str)
    }
}

/// Where the head is complete: the index just past the blank line (StreamForwarder.swift:439).
pub fn find_head_end(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4)
}

/// Only GET and HEAD are served; anything else gets 405 (StreamForwarder.swift:186).
pub fn method_allowed(procedure: &str) -> bool {
    procedure == "GET" || procedure == "HEAD"
}

/// The headers of the outgoing request to the server (StreamForwarder.swift:210-218).
///
/// Passed through unchanged what matters for seeking (Range, If-Range, User-Agent, Accept);
/// everything else (cookies, Icy-MetaData) stays out. `Accept-Encoding: identity` is forced so
/// Content-Length stays right. The own headers come last and replace a same-named entry (they
/// are cleaned first: empty, malformed and locked ones never go out).
pub fn inject_headers(
    own: &[(String, String)],
    vlc_request: &RequestHeader,
) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for name in PASSED_REQUEST_HEADERS {
        if let Some(value) = vlc_request.header(name) {
            out.push((name.to_owned(), value.to_owned()));
        }
    }
    out.push(("Accept-Encoding".to_owned(), "identity".to_owned()));
    let own: Vec<OwnHeader> = own.iter().map(|(n, v)| OwnHeader::new(n, v)).collect();
    for header in OwnHeaders::cleaned(&own) {
        out.retain(|(n, _)| !n.eq_ignore_ascii_case(&header.name));
        out.push((header.name, header.value));
    }
    out
}

// MARK: Response head

/// The response head bytes (StreamForwarder.swift:410). Fields are written sorted by name;
/// `length` adds `Content-Length` after them; the connection always closes.
pub fn response_head(
    status: u16,
    fields: &BTreeMap<String, String>,
    length: Option<u64>,
) -> Vec<u8> {
    let reason = match status {
        200 => "OK",
        206 => "Partial Content",
        404 => "Not Found",
        405 => "Method Not Allowed",
        502 => "Bad Gateway",
        _ => "Status",
    };
    let mut s = format!("HTTP/1.1 {status} {reason}\r\n");
    for (n, w) in fields {
        s.push_str(&format!("{n}: {w}\r\n"));
    }
    if let Some(length) = length {
        s.push_str(&format!("Content-Length: {length}\r\n"));
    }
    s.push_str("Connection: close\r\n\r\n");
    s.into_bytes()
}

/// The response fields to pass on, looked up by name; a `Content-Encoding` drops
/// `Content-Length`, which no longer matches (StreamForwarder.swift:252-259).
pub fn passed_fields(lookup: impl Fn(&str) -> Option<String>) -> BTreeMap<String, String> {
    let mut fields = BTreeMap::new();
    for name in PASSED_RESPONSE_HEADERS {
        if let Some(value) = lookup(name) {
            fields.insert(name.to_owned(), value);
        }
    }
    if lookup("Content-Encoding").is_some() {
        fields.remove("Content-Length");
    }
    fields
}

// MARK: Ranges and pieces

/// Last byte of the piece from `from`, at most up to `until` (StreamForwarder.swift:353).
pub fn piece_end(from: u64, until: Option<u64>) -> u64 {
    let end = from + PIECE - 1;
    until.map_or(end, |u| u.min(end))
}

/// `Range` from the player: without the header everything from 0, otherwise `bytes=N-` or
/// `bytes=N-E`. Suffix and multiple ranges give `None` and are handled in one go
/// (StreamForwarder.swift:361).
pub fn section_read(header: Option<&str>) -> Option<(u64, Option<u64>)> {
    let Some(header) = header else {
        return Some((0, None));
    };
    let t = header.trim_matches([' ', '\t']);
    let spec = t.strip_prefix("bytes=").filter(|s| !s.contains(','))?;
    let (from, behind) = spec.split_once('-')?;
    let from: u64 = from.trim_matches([' ', '\t']).parse().ok()?;
    let behind = behind.trim_matches([' ', '\t']);
    if behind.is_empty() {
        return Some((from, None));
    }
    let until: u64 = behind.parse().ok().filter(|u| *u >= from)?;
    Some((from, Some(until)))
}

/// `Content-Range: bytes A-B/T` with known total length (StreamForwarder.swift:374).
pub fn content_section_read(header: Option<&str>) -> Option<(u64, u64, u64)> {
    let rest = header?.strip_prefix("bytes ")?;
    let (range, total) = rest.split_once('/')?;
    let total: u64 = total.parse().ok()?;
    let (from, until) = range.split_once('-')?;
    let (from, until): (u64, u64) = (from.parse().ok()?, until.parse().ok()?);
    (from <= until && until < total).then_some((from, until, total))
}

/// The byte range to ask the server for when fetching in pieces, `None` when the request goes
/// through in one go (halting works, not a GET, or a playlist; StreamForwarder.swift:230).
pub fn piece_request(
    halt_acts: bool,
    procedure: &str,
    is_playlist: bool,
    range: Option<&str>,
) -> Option<(u64, Option<u64>)> {
    if halt_acts || procedure != "GET" || is_playlist {
        return None;
    }
    section_read(range)
}

/// The `Range` value for the first (or a next) piece (StreamForwarder.swift:234).
pub fn range_value(from: u64, until: Option<u64>) -> String {
    format!("bytes={from}-{}", piece_end(from, until))
}

/// Adjusts the first response when fetching in pieces (StreamForwarder.swift:265-282).
///
/// Only if the server served the Range exactly as asked (206 with a known total, same start) the
/// answer is rewritten to what the player asked for: without a Range header 200 with the total
/// length, otherwise the requested `Content-Range`/`Content-Length`. Returns the status and the
/// next piece `(since, until)` still to fetch, if any. Otherwise nothing changes and the
/// upper limit is the last stop.
pub fn adjust_first_response(
    asked: (u64, Option<u64>),
    player_sent_range: bool,
    status: u16,
    content_range: Option<&str>,
    fields: &mut BTreeMap<String, String>,
) -> (u16, Option<(u64, u64)>) {
    let Some((from, until, total)) =
        content_section_read(content_range).filter(|p| status == 206 && p.0 == asked.0)
    else {
        return (status, None);
    };
    let last = asked.1.unwrap_or(total - 1).min(total - 1);
    let mut status = status;
    if player_sent_range {
        fields.insert(
            "Content-Range".to_owned(),
            format!("bytes {from}-{last}/{total}"),
        );
        fields.insert("Content-Length".to_owned(), (last - from + 1).to_string());
    } else {
        status = 200;
        fields.remove("Content-Range");
        fields.insert("Content-Length".to_owned(), total.to_string());
    }
    (status, (until < last).then_some((until + 1, last)))
}

/// After a further piece: the next one, if the server served it as asked and more remains
/// (StreamForwarder.swift:316-325). `None` for the outer option means the piece was not served
/// properly and the connection ends.
pub fn next_piece(
    since: u64,
    until: u64,
    status: u16,
    content_range: Option<&str>,
) -> Option<Option<(u64, u64)>> {
    let (from, got_until, _) = content_section_read(content_range).filter(|_| status == 206)?;
    if from != since || got_until < since {
        return None;
    }
    Some((got_until < until).then_some((got_until + 1, until)))
}

/// The `If-Range` value that keeps the following pieces on the same file version: a strong ETag,
/// else the Last-Modified date (StreamForwarder.swift:305-311).
pub fn if_range_value(fields: &BTreeMap<String, String>) -> Option<String> {
    match fields.get("ETag") {
        Some(tag) if !tag.starts_with("W/") => Some(tag.clone()),
        _ => fields.get("Last-Modified").cloned(),
    }
}

// MARK: Playlists

/// Redirect absolute addresses and root-relative paths in an HLS playlist to the forwarder
/// (StreamForwarder.swift:385). Relative ones stay as they are; the player resolves them against
/// the playlist's address, which already points at the forwarder.
///
/// `rewrite_absolute` gets an absolute `http(s)` address and returns the forwarder address for
/// it (the host passes [`ForwardTable::address_for`]), or `None` to leave it alone.
pub fn list_write(
    text: &str,
    mark: &str,
    mut rewrite_absolute: impl FnMut(&str) -> Option<String>,
) -> String {
    let mut bend = |a: &str| -> String {
        if a.starts_with('/') && !a.starts_with("//") {
            return format!("/{mark}{a}");
        }
        let small = a.to_lowercase();
        if (small.starts_with("http://") || small.starts_with("https://"))
            && let Some(new) = rewrite_absolute(a)
        {
            return new;
        }
        a.to_owned()
    };
    text.split('\n')
        .map(|raw| {
            let (row, cr) = match raw.strip_suffix('\r') {
                Some(r) => (r, true),
                None => (raw, false),
            };
            let trimmed = row.trim_matches([' ', '\t']);
            let mut row = row.to_owned();
            if trimmed.is_empty() {
                // stays
            } else if trimmed.starts_with('#') {
                // URI="..." in EXT-X-MAP, EXT-X-MEDIA, EXT-X-KEY ...
                if let Some(a) = row.find("URI=\"").map(|i| i + 5)
                    && let Some(len) = row[a..].find('"')
                {
                    let new = bend(&row[a..a + len]);
                    row.replace_range(a..a + len, &new);
                }
            } else {
                row = bend(trimmed);
            }
            if cr { row + "\r" } else { row }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

// MARK: Backlog

/// What the host does with the request to the server after a state change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PressureAction {
    /// Nothing to do.
    None,
    /// Pause the request to the server (only where pausing really stops the transfer).
    Suspend,
    /// Resume the paused request.
    Resume,
    /// Cancel the request; the player resumes with a Range at exactly that point.
    Abort,
}

/// The backlog between the server and a slow player (`Line`, StreamForwarder.swift:480-555) as a
/// pure state function: suspend at [`HALT_OFF`], resume at [`NEXT_OFF`], abort at [`UPPER_LIMIT`].
#[derive(Debug, Clone, Default)]
pub struct Backpressure {
    /// Whether suspending works on this platform (Apple); elsewhere only the abort limit acts.
    halt_acts: bool,
    waiting: u64,
    halted: bool,
    done: bool,
}

impl Backpressure {
    /// A fresh counter.
    pub fn new(halt_acts: bool) -> Self {
        Self {
            halt_acts,
            ..Self::default()
        }
    }

    /// Bytes waiting for the player.
    pub fn waiting(&self) -> u64 {
        self.waiting
    }

    /// Whether the request is currently paused.
    pub fn is_halted(&self) -> bool {
        self.halted
    }

    /// Whether the transfer is over (ended or aborted).
    pub fn is_done(&self) -> bool {
        self.done
    }

    /// A chunk of `bytes` arrived from the server. After the end or abort, late chunks are
    /// neither counted nor sent.
    pub fn on_data(&mut self, bytes: u64) -> PressureAction {
        if self.done {
            return PressureAction::None;
        }
        self.waiting += bytes;
        if self.waiting > UPPER_LIMIT {
            self.done = true;
            PressureAction::Abort
        } else if self.halt_acts && !self.halted && self.waiting > HALT_OFF {
            self.halted = true;
            PressureAction::Suspend
        } else {
            PressureAction::None
        }
    }

    /// The connection thread took everything that was waiting.
    pub fn on_taken(&mut self) -> PressureAction {
        self.waiting = 0;
        if self.halted && self.waiting < NEXT_OFF {
            self.halted = false;
            PressureAction::Resume
        } else {
            PressureAction::None
        }
    }

    /// The server ended the body.
    pub fn on_end(&mut self) {
        self.done = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    fn counter() -> impl FnMut() -> String {
        let mut n = 0u8;
        move || {
            n += 1;
            mark_from_bytes([n; 16])
        }
    }

    /// StreamNextLeaderTests.withoutHeaders
    #[test]
    fn address_unchanged_without_headers_or_for_files() {
        let mut t = ForwardTable::new();
        let u = url("https://ohne-koepfe.test/Videos/1/stream.mkv?static=true");
        assert_eq!(t.address_for(&u, 5000, false, || unreachable!()), u);
        let file = url("file:///tmp/film.mkv");
        assert_eq!(t.address_for(&file, 5000, true, || unreachable!()), file);
    }

    /// StreamNextLeaderTests.headersGoWith (address part)
    #[test]
    fn address_goes_through_loopback_with_token_and_query() {
        let mut t = ForwardTable::new();
        let u = url("https://tv.example.test:8443/Videos/1/stream.mkv?static=true&api_key=geheim");
        let a = t.address_for(&u, 5000, true, counter());
        assert_eq!(a.host_str(), Some("127.0.0.1"));
        assert_eq!(a.port(), Some(5000));
        assert_eq!(
            a.as_str(),
            format!(
                "http://127.0.0.1:5000/{}/Videos/1/stream.mkv?static=true&api_key=geheim",
                mark_from_bytes([1; 16])
            )
        );
        // The same origin keeps its token, another origin gets a new one.
        let b = t.address_for(
            &url("https://tv.example.test:8443/Items"),
            5000,
            true,
            || unreachable!(),
        );
        assert!(
            b.path()
                .starts_with(&format!("/{}/", mark_from_bytes([1; 16])))
        );
        let c = t.address_for(&url("https://other.test/x"), 5000, true, counter());
        assert!(
            c.path()
                .starts_with(&format!("/{}/", mark_from_bytes([1; 16])))
        );
    }

    #[test]
    fn target_maps_back_and_rejects_wrong_token() {
        let mut t = ForwardTable::new();
        let u = url("https://tv.example.test/Videos/1/stream.mkv?static=true");
        let a = t.address_for(&u, 5000, true, counter());
        let path = format!("{}?{}", a.path(), a.query().unwrap());
        let (back, mark) = t.target_for(&path).unwrap();
        assert_eq!(back, u);
        assert_eq!(mark, mark_from_bytes([1; 16]));
        // Token only, with query: rest becomes "/".
        let (root, _) = t.target_for(&format!("/{mark}?x=1")).unwrap();
        assert_eq!(root.as_str(), "https://tv.example.test/?x=1");
        // StreamNextLeaderTests: wrong mark gives 404.
        assert!(t.target_for("/falsch/Videos/1/stream.mkv").is_none());
        assert!(t.target_for("Videos/1").is_none());
        assert!(t.target_for("/Videos/1/stream.mkv").is_none());
    }

    #[test]
    fn mark_is_32_lowercase_hex_characters() {
        let m = mark_from_bytes([0x0a, 0xff, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]);
        assert_eq!(m.len(), 32);
        assert!(m.starts_with("0aff0001"));
    }

    /// StreamNextLeaderTests.requestHeader
    #[test]
    fn request_header_parse() {
        let k = RequestHeader::parse(
            "GET /a/b?c=d HTTP/1.1\r\nRange: bytes=0-\r\nUser-Agent: VLC\r\n\r\n",
        )
        .unwrap();
        assert_eq!(k.procedure, "GET");
        assert_eq!(k.target, "/a/b?c=d");
        assert_eq!(k.headers["range"], "bytes=0-");
        assert_eq!(k.headers["user-agent"], "VLC");
        assert_eq!(k.header("User-Agent"), Some("VLC"));
        assert!(RequestHeader::parse("GET\r\n\r\n").is_none());
        assert!(RequestHeader::parse("").is_none());
    }

    #[test]
    fn head_end_is_found_past_the_blank_line() {
        assert_eq!(
            find_head_end(b"GET / HTTP/1.1\r\nA: b\r\n\r\nbody"),
            Some(24)
        );
        assert_eq!(find_head_end(b"GET / HTTP/1.1\r\nA: b\r\n"), None);
        assert_eq!(find_head_end(b"\r\n\r"), None);
        assert!(method_allowed("GET") && method_allowed("HEAD"));
        assert!(!method_allowed("POST"));
    }

    /// StreamNextLeaderTests.sectionRead
    #[test]
    fn range_headers() {
        assert_eq!(section_read(None), Some((0, None)));
        assert_eq!(section_read(Some("bytes=100-")), Some((100, None)));
        assert_eq!(section_read(Some("bytes=100-199")), Some((100, Some(199))));
        assert_eq!(section_read(Some("bytes=-500")), None);
        assert_eq!(section_read(Some("bytes=0-1,5-9")), None);
        assert_eq!(section_read(Some("bytes=9-3")), None);
        assert_eq!(section_read(Some("items=1-2")), None);
        assert_eq!(
            content_section_read(Some("bytes 0-99/1000")),
            Some((0, 99, 1000))
        );
        assert_eq!(content_section_read(Some("bytes 0-99/*")), None);
        assert_eq!(content_section_read(Some("bytes 0-1000/1000")), None);
        assert_eq!(content_section_read(None), None);
        assert_eq!(piece_end(10, Some(20)), 20);
        assert_eq!(piece_end(10, None), 10 + PIECE - 1);
        assert_eq!(piece_end(10, Some(PIECE * 2)), 10 + PIECE - 1);
    }

    fn vlc() -> RequestHeader {
        RequestHeader::parse(
            "GET /x HTTP/1.1\r\nHost: 127.0.0.1\r\nrange: bytes=5-\r\nUser-Agent: VLC/4\r\nCookie: a=b\r\nIcy-MetaData: 1\r\nAccept-Encoding: gzip\r\n\r\n",
        )
        .unwrap()
    }

    #[test]
    fn injected_headers_pass_seek_headers_and_add_own() {
        let own = [
            ("CF-Access-Client-Id".to_owned(), "id".to_owned()),
            ("X-Auth".to_owned(), "k".to_owned()),
        ];
        let out = inject_headers(&own, &vlc());
        let get = |n: &str| out.iter().find(|(h, _)| h == n).map(|(_, v)| v.as_str());
        assert_eq!(get("Range"), Some("bytes=5-"));
        assert_eq!(get("User-Agent"), Some("VLC/4"));
        assert_eq!(get("Accept-Encoding"), Some("identity"));
        assert_eq!(get("CF-Access-Client-Id"), Some("id"));
        assert_eq!(get("X-Auth"), Some("k"));
        // Cookies, Host and Icy-MetaData never go to the server.
        assert!(get("Cookie").is_none() && get("Host").is_none() && get("Icy-MetaData").is_none());
    }

    #[test]
    fn own_headers_replace_same_name_and_locked_ones_never_go_out() {
        let own = [
            ("user-agent".to_owned(), "Own".to_owned()),
            ("Host".to_owned(), "evil".to_owned()),
            ("Bad Name".to_owned(), "x".to_owned()),
            ("X-Empty".to_owned(), "  ".to_owned()),
        ];
        let out = inject_headers(&own, &vlc());
        assert_eq!(
            out.iter()
                .filter(|(n, _)| n.eq_ignore_ascii_case("user-agent"))
                .count(),
            1
        );
        assert!(out.contains(&("user-agent".to_owned(), "Own".to_owned())));
        assert!(
            !out.iter()
                .any(|(n, _)| n == "Host" || n == "Bad Name" || n == "X-Empty")
        );
    }

    #[test]
    fn response_head_is_sorted_with_length_and_close() {
        let mut f = BTreeMap::new();
        f.insert("Content-Type".to_owned(), "video/x-matroska".to_owned());
        f.insert("Accept-Ranges".to_owned(), "bytes".to_owned());
        let head = String::from_utf8(response_head(206, &f, Some(10))).unwrap();
        assert_eq!(
            head,
            "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Type: video/x-matroska\r\nContent-Length: 10\r\nConnection: close\r\n\r\n"
        );
        let mut allow = BTreeMap::new();
        allow.insert("Allow".to_owned(), "GET, HEAD".to_owned());
        assert!(
            response_head(405, &allow, Some(0))
                .starts_with(b"HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\n")
        );
        assert_eq!(
            response_head(404, &BTreeMap::new(), Some(0)),
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        );
        assert!(response_head(418, &BTreeMap::new(), None).starts_with(b"HTTP/1.1 418 Status\r\n"));
    }

    #[test]
    fn passed_fields_drop_length_for_encoded_bodies() {
        let lookup = |name: &str| match name {
            "Content-Length" => Some("99".to_owned()),
            "ETag" => Some("\"abc\"".to_owned()),
            "Set-Cookie" => Some("no".to_owned()),
            "Content-Encoding" => Some("gzip".to_owned()),
            _ => None,
        };
        let f = passed_fields(lookup);
        assert_eq!(f.len(), 1);
        assert!(f.contains_key("ETag"));
        let plain = passed_fields(|n| (n == "Content-Length").then(|| "99".to_owned()));
        assert_eq!(plain["Content-Length"], "99");
    }

    /// StreamNextLeaderTests.list
    #[test]
    fn playlist_rewriting() {
        let text = "#EXTM3U\r\n#EXT-X-MAP:URI=\"/Videos/1/init.mp4\",BYTERANGE=\"1@0\"\r\nmain.m3u8?api_key=geheim\r\n/Videos/1/hls/0.ts\r\nhttp://srv.test:8096/Videos/1/hls/1.ts\r\nhttps://fremd.test/werbung.ts\r\n//cdn.test/x.ts\r\n\r\n  seg2.ts  ";
        let out = list_write(text, "MARK", |a| {
            a.starts_with("http://srv.test")
                .then(|| a.replace("http://srv.test:8096", "http://127.0.0.1:5000/MARK"))
        });
        let rows: Vec<&str> = out.split('\n').collect();
        assert_eq!(rows[0], "#EXTM3U\r");
        assert_eq!(
            rows[1],
            "#EXT-X-MAP:URI=\"/MARK/Videos/1/init.mp4\",BYTERANGE=\"1@0\"\r"
        );
        assert_eq!(rows[2], "main.m3u8?api_key=geheim\r");
        assert_eq!(rows[3], "/MARK/Videos/1/hls/0.ts\r");
        assert_eq!(rows[4], "http://127.0.0.1:5000/MARK/Videos/1/hls/1.ts\r");
        // A foreign address the closure leaves alone, and a protocol-relative one, stay.
        assert_eq!(rows[5], "https://fremd.test/werbung.ts\r");
        assert_eq!(rows[6], "//cdn.test/x.ts\r");
        assert_eq!(rows[7], "\r");
        assert_eq!(rows[8], "seg2.ts");
    }

    #[test]
    fn playlist_rewriting_through_the_table() {
        let mut t = ForwardTable::new();
        let first = t.address_for(
            &url("https://srv.test/Videos/1/master.m3u8"),
            6000,
            true,
            counter(),
        );
        let mark = first.path_segments().unwrap().next().unwrap().to_owned();
        let out = list_write("https://srv.test/Videos/1/hls/1.ts", &mark, |a| {
            Some(
                t.address_for(&url(a), 6000, true, || unreachable!())
                    .to_string(),
            )
        });
        assert_eq!(
            out,
            format!("http://127.0.0.1:6000/{mark}/Videos/1/hls/1.ts")
        );
    }

    #[test]
    fn pieces_are_only_used_where_halting_does_not_work() {
        assert_eq!(piece_request(true, "GET", false, None), None);
        assert_eq!(piece_request(false, "HEAD", false, None), None);
        assert_eq!(piece_request(false, "GET", true, None), None);
        assert_eq!(
            piece_request(false, "GET", false, Some("bytes=7-")),
            Some((7, None))
        );
        assert_eq!(piece_request(false, "GET", false, Some("bytes=-5")), None);
        assert_eq!(range_value(0, None), format!("bytes=0-{}", PIECE - 1));
        assert_eq!(range_value(10, Some(20)), "bytes=10-20");
    }

    #[test]
    fn first_response_is_rewritten_to_what_the_player_asked() {
        let total = 100 << 20;
        let mut f = BTreeMap::new();
        // Player sent no Range: the server's 206 becomes 200 with the whole length.
        f.insert(
            "Content-Range".to_owned(),
            format!("bytes 0-{}/{total}", PIECE - 1),
        );
        let (status, next) = adjust_first_response(
            (0, None),
            false,
            206,
            Some(&f["Content-Range"].clone()),
            &mut f,
        );
        assert_eq!(status, 200);
        assert_eq!(f["Content-Length"], total.to_string());
        assert!(!f.contains_key("Content-Range"));
        assert_eq!(next, Some((PIECE, total - 1)));

        // With a Range the requested window is reported and the next piece is the rest of it.
        let mut g = BTreeMap::new();
        let cr = format!("bytes 100-{}/{total}", 100 + PIECE - 1);
        let (status, next) =
            adjust_first_response((100, Some(40 << 20)), true, 206, Some(&cr), &mut g);
        assert_eq!(status, 206);
        assert_eq!(
            g["Content-Range"],
            format!("bytes 100-{}/{total}", 40 << 20)
        );
        assert_eq!(g["Content-Length"], ((40 << 20) - 100 + 1).to_string());
        assert_eq!(next, Some((100 + PIECE, 40 << 20)));
    }

    #[test]
    fn first_response_stays_if_the_server_did_not_serve_the_range() {
        let mut f = BTreeMap::new();
        assert_eq!(
            adjust_first_response((0, None), false, 200, None, &mut f),
            (200, None)
        );
        assert_eq!(
            adjust_first_response((5, None), true, 206, Some("bytes 0-9/10"), &mut f),
            (206, None)
        );
        assert!(f.is_empty());
        // The whole file fits into the first piece: nothing follows.
        let (s, next) = adjust_first_response((0, None), true, 206, Some("bytes 0-99/100"), &mut f);
        assert_eq!((s, next), (206, None));
        assert_eq!(f["Content-Length"], "100");
    }

    /// StreamNextLeaderTests: "every byte at its place across pieces" (the piece chain).
    #[test]
    fn piece_chain_covers_the_window_without_gap() {
        let total = 3 * PIECE + 5;
        let (mut since, until) = (7, total - 1);
        let mut covered = 7;
        let mut guard = 0;
        loop {
            let end = piece_end(since, Some(until));
            let cr = format!("bytes {since}-{end}/{total}");
            covered = covered.max(end + 1);
            match next_piece(since, until, 206, Some(&cr)).expect("piece served") {
                Some((s, _)) => since = s,
                None => break,
            }
            guard += 1;
            assert!(guard < 10);
        }
        assert_eq!(covered, total);
        assert_eq!(next_piece(0, 9, 200, Some("bytes 0-9/10")), None);
        assert_eq!(next_piece(5, 9, 206, Some("bytes 0-9/10")), None);
    }

    #[test]
    fn if_range_prefers_strong_etag() {
        let mut f = BTreeMap::new();
        f.insert("Last-Modified".to_owned(), "Mon".to_owned());
        assert_eq!(if_range_value(&f).as_deref(), Some("Mon"));
        f.insert("ETag".to_owned(), "W/\"x\"".to_owned());
        assert_eq!(if_range_value(&f).as_deref(), Some("Mon"));
        f.insert("ETag".to_owned(), "\"x\"".to_owned());
        assert_eq!(if_range_value(&f).as_deref(), Some("\"x\""));
        assert_eq!(if_range_value(&BTreeMap::new()), None);
    }

    #[test]
    fn backpressure_suspends_at_8_mib_and_resumes_when_taken() {
        let mut b = Backpressure::new(true);
        assert_eq!(b.on_data(HALT_OFF), PressureAction::None);
        assert_eq!(b.on_data(1), PressureAction::Suspend);
        assert!(b.is_halted());
        assert_eq!(b.on_data(1), PressureAction::None);
        assert_eq!(b.on_taken(), PressureAction::Resume);
        assert!(!b.is_halted());
        assert_eq!(b.waiting(), 0);
        assert_eq!(b.on_taken(), PressureAction::None);
    }

    #[test]
    fn backpressure_aborts_at_64_mib_and_ignores_late_chunks() {
        let mut b = Backpressure::new(false);
        // Without working suspend only the upper limit acts.
        assert_eq!(b.on_data(UPPER_LIMIT), PressureAction::None);
        assert!(!b.is_halted());
        assert_eq!(b.on_data(1), PressureAction::Abort);
        assert!(b.is_done());
        let waiting = b.waiting();
        assert_eq!(b.on_data(1 << 20), PressureAction::None);
        assert_eq!(b.waiting(), waiting);
    }

    #[test]
    fn backpressure_abort_wins_over_suspend_and_end_stops_counting() {
        let mut b = Backpressure::new(true);
        assert_eq!(b.on_data(UPPER_LIMIT + 1), PressureAction::Abort);
        let mut c = Backpressure::new(true);
        c.on_end();
        assert!(c.is_done());
        assert_eq!(c.on_data(HALT_OFF + 1), PressureAction::None);
        assert_eq!(
            (HALT_OFF, NEXT_OFF, UPPER_LIMIT, LISTS_LIMIT, PIECE),
            (8 << 20, 2 << 20, 64 << 20, 4 << 20, 16 << 20)
        );
    }
}
