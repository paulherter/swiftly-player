//! The stream forwarder seam and the audio-output guard. Servers behind a gateway only let through
//! requests that carry the user's own headers; the player engine cannot set them, so the host runs a
//! small HTTP service on `127.0.0.1` and the core decides everything around it: which address the engine
//! gets (the player path rewrites the load address and the external subtitle addresses when a
//! [`StreamForwarder`] is attached), which headers go to the server, how the head is read and written,
//! and when the backlog suspends or aborts the request. The listener, the sockets and the HTTP client
//! stay with the host.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_jellyfin::OwnHeaders;
use swiftly_net::Url;
use swiftly_playback::audio_guards::output_new_build_up;
use swiftly_playback::stream_forwarder::{
    Backpressure, ForwardTable, PressureAction, RequestHeader, adjust_first_response,
    find_head_end, if_range_value, inject_headers, list_write, mark_from_bytes, method_allowed,
    next_piece, piece_request, range_value, response_head, section_read,
};

use crate::player::PlayerVm;
use crate::transport::NetHeader;

/// What the host provides to the forwarder.
#[uniffi::export(with_foreign)]
pub trait StreamForwardHost: Send + Sync {
    /// The port the local service listens on, `None` while it does not run (addresses stay as they are).
    fn listening_port(&self) -> Option<u16>;
    /// 16 random bytes for a new token (the OS random source).
    fn random_bytes(&self) -> Vec<u8>;
}

/// A token and the server address behind a request path.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForwardTarget {
    /// The address at the server.
    pub url: String,
    /// The token of the origin.
    pub mark: String,
}

/// The address table of the forwarder: origin to token and back.
#[derive(uniffi::Object)]
pub struct StreamForwarder {
    host: Arc<dyn StreamForwardHost>,
    table: Mutex<ForwardTable>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl StreamForwarder {
    fn address(&self, url: &str) -> String {
        let Ok(parsed) = Url::parse(url) else {
            return url.to_owned();
        };
        let Some(port) = self.host.listening_port() else {
            return url.to_owned();
        };
        let present = !OwnHeaders::of(&parsed).is_empty();
        let host = &self.host;
        lock(&self.table)
            .address_for(&parsed, port, present, || {
                let mut bytes = [0u8; 16];
                for (slot, b) in bytes.iter_mut().zip(host.random_bytes()) {
                    *slot = b;
                }
                mark_from_bytes(bytes)
            })
            .to_string()
    }
}

#[uniffi::export]
impl StreamForwarder {
    /// A forwarder over the host's local service.
    #[uniffi::constructor]
    pub fn new(host: Arc<dyn StreamForwardHost>) -> Arc<Self> {
        Arc::new(Self {
            host,
            table: Mutex::new(ForwardTable::new()),
        })
    }

    /// The address the engine should get for a server address: unchanged when the service does not run,
    /// no own headers are set for this server, or the address is not http(s).
    pub fn address_for(&self, url: String) -> String {
        self.address(&url)
    }

    /// From the engine's request path (`/<token>/path?query`) the address at the server; `None` for a wrong
    /// token (answer 404).
    pub fn target_for(&self, request_path: String) -> Option<ForwardTarget> {
        let (url, mark) = lock(&self.table).target_for(&request_path)?;
        Some(ForwardTarget {
            url: url.to_string(),
            mark,
        })
    }

    /// The headers of the request to the server: what passes from the engine's request (`head` is its text),
    /// `Accept-Encoding: identity`, then the user's own headers for `server_url`.
    pub fn outgoing_headers(&self, server_url: String, head: String) -> Vec<NetHeader> {
        let Some(request) = RequestHeader::parse(&head) else {
            return Vec::new();
        };
        let own: Vec<(String, String)> = Url::parse(&server_url)
            .map(|u| {
                OwnHeaders::of(&u)
                    .into_iter()
                    .map(|h| (h.name, h.value))
                    .collect()
            })
            .unwrap_or_default();
        inject_headers(&own, &request)
            .into_iter()
            .map(|(name, value)| NetHeader { name, value })
            .collect()
    }
}

/// Attached to the player: its engine gets forwarded addresses.
pub(crate) type SlotValue = Option<Arc<StreamForwarder>>;

/// The place a player keeps its forwarder in.
#[derive(Clone, Default)]
pub(crate) struct ForwarderSlot(Arc<Mutex<SlotValue>>);

/// The address the engine gets: through the forwarder if one is attached.
pub(crate) fn rewritten(slot: &ForwarderSlot, url: &str) -> String {
    let attached = lock(&slot.0).clone();
    attached.map_or_else(|| url.to_owned(), |f| f.address(url))
}

#[uniffi::export]
impl PlayerVm {
    /// Sends the engine's addresses (title and external subtitles) through the forwarder; `None` detaches.
    /// Takes effect with the next load.
    pub fn set_stream_forwarder(&self, forwarder: Option<Arc<StreamForwarder>>) {
        *lock(&self.forwarder_slot().0) = forwarder;
    }
}

/// The engine's request head, dismantled.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ForwardRequest {
    /// `GET` or `HEAD`, or something to answer 405.
    pub procedure: String,
    /// Path and query.
    pub target: String,
    /// The header fields.
    pub headers: Vec<NetHeader>,
}

/// Where the head in `buffer` is complete (the index just past the blank line), `None` while more is needed.
#[uniffi::export]
pub fn forward_find_head_end(buffer: Vec<u8>) -> Option<u64> {
    find_head_end(&buffer).map(|i| i as u64)
}

/// Only `GET` and `HEAD` are served; anything else gets 405.
#[uniffi::export]
pub fn forward_method_allowed(procedure: String) -> bool {
    method_allowed(&procedure)
}

/// Dismantles the engine's request head.
#[uniffi::export]
pub fn forward_request(head: String) -> Option<ForwardRequest> {
    let r = RequestHeader::parse(&head)?;
    Some(ForwardRequest {
        procedure: r.procedure,
        target: r.target,
        headers: r
            .headers
            .into_iter()
            .map(|(name, value)| NetHeader { name, value })
            .collect(),
    })
}

/// The response head for the engine.
#[uniffi::export]
pub fn forward_response_head(status: u16, fields: Vec<NetHeader>, length: Option<u64>) -> Vec<u8> {
    let map: BTreeMap<String, String> = fields.into_iter().map(|h| (h.name, h.value)).collect();
    response_head(status, &map, length)
}

/// A byte range the player or the forwarder asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ForwardRange {
    /// First byte.
    pub from: u64,
    /// Last byte (inclusive); `None`: to the end.
    pub until: Option<u64>,
}

/// A piece still to fetch (both ends inclusive).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ForwardPiece {
    /// First byte.
    pub since: u64,
    /// Last byte.
    pub until: u64,
}

/// The first response of a piecewise fetch, adjusted for the player.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ForwardFirstResponse {
    /// The status the player gets.
    pub status: u16,
    /// The header fields the player gets.
    pub fields: Vec<NetHeader>,
    /// The next piece to fetch, `None` when this one was the last.
    pub next: Option<ForwardPiece>,
}

/// What follows a further piece.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ForwardNext {
    /// The server did not serve the piece as asked: end the connection.
    Failed,
    /// Everything was served.
    Done,
    /// Fetch this piece next.
    Piece {
        /// First byte.
        since: u64,
        /// Last byte.
        until: u64,
    },
}

fn range_of((from, until): (u64, Option<u64>)) -> ForwardRange {
    ForwardRange { from, until }
}

fn field_map(fields: Vec<NetHeader>) -> BTreeMap<String, String> {
    fields.into_iter().map(|h| (h.name, h.value)).collect()
}

/// The player's `Range` header: no header is everything from 0, `bytes=N-` and `bytes=N-E` are ranges;
/// suffix, multiple or malformed ranges give `None` and go through in one go.
#[uniffi::export]
pub fn forward_section_read(header: Option<String>) -> Option<ForwardRange> {
    section_read(header.as_deref()).map(range_of)
}

/// The range to ask the server for when fetching in pieces; `None` when the request goes through in one go
/// (halting works, not a `GET`, a playlist, or an unsupported `Range`).
#[uniffi::export]
pub fn forward_piece_request(
    halt_acts: bool,
    procedure: String,
    is_playlist: bool,
    range: Option<String>,
) -> Option<ForwardRange> {
    piece_request(halt_acts, &procedure, is_playlist, range.as_deref()).map(range_of)
}

/// The `Range` header value for the piece starting at `from` (at most 8 MiB, never past `until`).
#[uniffi::export]
pub fn forward_range_value(from: u64, until: Option<u64>) -> String {
    range_value(from, until)
}

/// Adjusts the first server response of a piecewise fetch to what the player asked for. Only a `206` with
/// a known total that starts where asked is rewritten; anything else stays as it is.
#[uniffi::export]
pub fn forward_adjust_first_response(
    asked: ForwardRange,
    player_sent_range: bool,
    status: u16,
    content_range: Option<String>,
    fields: Vec<NetHeader>,
) -> ForwardFirstResponse {
    let mut map = field_map(fields);
    let (status, next) = adjust_first_response(
        (asked.from, asked.until),
        player_sent_range,
        status,
        content_range.as_deref(),
        &mut map,
    );
    ForwardFirstResponse {
        status,
        fields: map
            .into_iter()
            .map(|(name, value)| NetHeader { name, value })
            .collect(),
        next: next.map(|(since, until)| ForwardPiece { since, until }),
    }
}

/// After a further piece: the next one, when the server served it as asked and more remains.
#[uniffi::export]
pub fn forward_next_piece(
    since: u64,
    until: u64,
    status: u16,
    content_range: Option<String>,
) -> ForwardNext {
    match next_piece(since, until, status, content_range.as_deref()) {
        None => ForwardNext::Failed,
        Some(None) => ForwardNext::Done,
        Some(Some((since, until))) => ForwardNext::Piece { since, until },
    }
}

/// The `If-Range` value that keeps the following pieces on one file version: a strong `ETag`, else
/// `Last-Modified`.
#[uniffi::export]
pub fn forward_if_range_value(fields: Vec<NetHeader>) -> Option<String> {
    if_range_value(&field_map(fields))
}

/// Rewrites an HLS playlist so every segment, key and map address goes through the forwarder: root-relative
/// paths get the origin's `mark`, absolute `http(s)` addresses go through `forwarder` (unchanged without
/// one), relative ones stay (the player resolves them against the playlist's own address).
#[uniffi::export]
pub fn forward_list_write(
    text: String,
    mark: String,
    forwarder: Option<Arc<StreamForwarder>>,
) -> String {
    list_write(&text, &mark, |a| forwarder.as_ref().map(|f| f.address(a)))
}

/// What the host does with the request to the server.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ForwardAction {
    /// Nothing.
    None,
    /// Pause the request to the server.
    Suspend,
    /// Resume the paused request.
    Resume,
    /// Cancel the request; the engine resumes with a Range at that point.
    Abort,
}

fn action_of(a: PressureAction) -> ForwardAction {
    match a {
        PressureAction::None => ForwardAction::None,
        PressureAction::Suspend => ForwardAction::Suspend,
        PressureAction::Resume => ForwardAction::Resume,
        PressureAction::Abort => ForwardAction::Abort,
    }
}

/// The backlog between the server and a slow engine for one request: suspend at 8 MiB, resume at 2 MiB,
/// abort at 64 MiB.
#[derive(uniffi::Object)]
pub struct ForwardBacklog {
    inner: Mutex<Backpressure>,
}

#[uniffi::export]
impl ForwardBacklog {
    /// A fresh counter; `halt_acts` is whether suspending really stops the transfer (Apple).
    #[uniffi::constructor]
    pub fn new(halt_acts: bool) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(Backpressure::new(halt_acts)),
        })
    }

    /// Bytes arrived from the server.
    pub fn on_data(&self, bytes: u64) -> ForwardAction {
        action_of(lock(&self.inner).on_data(bytes))
    }

    /// The engine took bytes.
    pub fn on_taken(&self) -> ForwardAction {
        action_of(lock(&self.inner).on_taken())
    }

    /// The server's answer ended.
    pub fn on_end(&self) {
        lock(&self.inner).on_end();
    }

    /// Bytes waiting for the engine.
    pub fn waiting(&self) -> u64 {
        lock(&self.inner).waiting()
    }
}

/// Whether a route change of the audio output should rebuild the output: only real device changes
/// (`real_device_switch`: the system reason was a new device or an override), only while something plays,
/// and not within the grace period after the player took the central controller (`since_takeover` in
/// seconds).
#[uniffi::export]
pub fn audio_output_should_rebuild(
    real_device_switch: bool,
    plays_now: bool,
    since_takeover: f64,
) -> bool {
    output_new_build_up(real_device_switch, plays_now, since_takeover)
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_jellyfin::OwnHeader;

    struct Host(Option<u16>);
    impl StreamForwardHost for Host {
        fn listening_port(&self) -> Option<u16> {
            self.0
        }
        fn random_bytes(&self) -> Vec<u8> {
            (1u8..=16).collect()
        }
    }

    #[test]
    fn addresses_go_through_the_service_only_with_own_headers_and_a_running_port() {
        let server = "https://gate.forwarder-test.example/jf";
        let url = format!("{server}/Videos/1/stream?static=true");
        let running = StreamForwarder::new(Arc::new(Host(Some(4711))));
        assert_eq!(running.address_for(url.clone()), url, "no own headers yet");
        OwnHeaders::set_down(
            &[OwnHeader {
                name: "X-Gate".into(),
                value: "k".into(),
            }],
            &Url::parse(server).unwrap(),
        );
        let rewritten = running.address_for(url.clone());
        assert!(
            rewritten.starts_with("http://127.0.0.1:4711/0102030405060708090a0b0c0d0e0f10/"),
            "{rewritten}"
        );
        assert_eq!(
            running.address_for(url.clone()),
            rewritten,
            "one token per origin"
        );
        let path = rewritten
            .trim_start_matches("http://127.0.0.1:4711")
            .to_owned();
        assert_eq!(running.target_for(path).map(|t| t.url), Some(url.clone()));
        assert!(running.target_for("/wrong/Videos".into()).is_none());
        let stopped = StreamForwarder::new(Arc::new(Host(None)));
        assert_eq!(stopped.address_for(url.clone()), url);
        let head = "GET /x HTTP/1.1\r\nRange: bytes=0-\r\nCookie: a=b\r\n\r\n".to_owned();
        let out = running.outgoing_headers(url, head);
        assert!(out.iter().any(|h| h.name == "X-Gate"));
        assert!(out.iter().any(|h| h.name == "Range"));
        assert!(!out.iter().any(|h| h.name == "Cookie"));
        OwnHeaders::set_down(&[], &Url::parse(server).unwrap());
    }

    #[test]
    fn head_reading_methods_and_backlog() {
        assert_eq!(
            forward_find_head_end(b"GET / HTTP/1.1\r\n\r\nrest".to_vec()),
            Some(18)
        );
        assert!(forward_find_head_end(b"GET / HTTP/1.1\r\n".to_vec()).is_none());
        assert!(forward_method_allowed("GET".into()) && !forward_method_allowed("POST".into()));
        let r =
            forward_request("GET /a?b=1 HTTP/1.1\r\nRange: bytes=5-\r\n\r\n".into()).expect("head");
        assert_eq!((r.procedure.as_str(), r.target.as_str()), ("GET", "/a?b=1"));
        let head = forward_response_head(
            206,
            vec![NetHeader {
                name: "Content-Type".into(),
                value: "video/mp4".into(),
            }],
            Some(10),
        );
        assert!(String::from_utf8_lossy(&head).starts_with("HTTP/1.1 206"));
        let backlog = ForwardBacklog::new(true);
        assert_eq!(backlog.on_data(9 << 20), ForwardAction::Suspend);
        assert_eq!(backlog.on_data(60 << 20), ForwardAction::Abort);
    }

    fn field(name: &str, value: &str) -> NetHeader {
        NetHeader {
            name: name.into(),
            value: value.into(),
        }
    }

    #[test]
    fn ranges_and_pieces_follow_the_swift_forwarder() {
        let r = |from, until| Some(ForwardRange { from, until });
        assert_eq!(forward_section_read(None), r(0, None));
        assert_eq!(
            forward_section_read(Some("bytes=100-".into())),
            r(100, None)
        );
        assert_eq!(
            forward_section_read(Some("bytes=100-199".into())),
            r(100, Some(199))
        );
        for bad in ["bytes=-500", "bytes=0-1,5-9", "bytes=9-3", "items=1-2"] {
            assert_eq!(forward_section_read(Some(bad.into())), None, "{bad}");
        }
        assert_eq!(forward_piece_request(true, "GET".into(), false, None), None);
        assert_eq!(
            forward_piece_request(false, "HEAD".into(), false, None),
            None
        );
        assert_eq!(forward_piece_request(false, "GET".into(), true, None), None);
        assert_eq!(
            forward_piece_request(false, "GET".into(), false, Some("bytes=7-".into())),
            r(7, None)
        );
        assert_eq!(forward_range_value(10, Some(20)), "bytes=10-20");
        assert!(forward_range_value(0, None).starts_with("bytes=0-"));
        // No Range from the player: the first piece answers 206, the player gets 200 with the total.
        let total = "20000000";
        let first_end = forward_range_value(0, None)
            .trim_start_matches("bytes=0-")
            .parse::<u64>()
            .expect("end");
        let cr = format!("bytes 0-{first_end}/{total}");
        let first = forward_adjust_first_response(
            ForwardRange {
                from: 0,
                until: None,
            },
            false,
            206,
            Some(cr.clone()),
            vec![
                field("Content-Range", &cr),
                field("Content-Length", &(first_end + 1).to_string()),
            ],
        );
        assert_eq!(first.status, 200);
        assert!(
            first
                .fields
                .iter()
                .any(|h| h.name == "Content-Length" && h.value == total)
        );
        assert!(!first.fields.iter().any(|h| h.name == "Content-Range"));
        assert_eq!(
            first.next,
            Some(ForwardPiece {
                since: first_end + 1,
                until: 19_999_999
            })
        );
        // A server that ignored the Range stays untouched.
        let plain = forward_adjust_first_response(
            ForwardRange {
                from: 0,
                until: None,
            },
            false,
            200,
            None,
            vec![],
        );
        assert_eq!((plain.status, plain.next), (200, None));
        // The chain of further pieces.
        assert_eq!(
            forward_next_piece(100, 999, 206, Some("bytes 100-499/1000".into())),
            ForwardNext::Piece {
                since: 500,
                until: 999
            }
        );
        assert_eq!(
            forward_next_piece(500, 999, 206, Some("bytes 500-999/1000".into())),
            ForwardNext::Done
        );
        assert_eq!(
            forward_next_piece(0, 9, 200, Some("bytes 0-9/10".into())),
            ForwardNext::Failed
        );
        assert_eq!(
            forward_next_piece(5, 9, 206, Some("bytes 0-9/10".into())),
            ForwardNext::Failed
        );
        let strong = vec![field("ETag", "\"abc\""), field("Last-Modified", "x")];
        assert_eq!(forward_if_range_value(strong), Some("\"abc\"".into()));
        let weak = vec![field("ETag", "W/\"abc\""), field("Last-Modified", "x")];
        assert_eq!(forward_if_range_value(weak), Some("x".into()));
    }

    #[test]
    fn playlists_are_rewritten_through_the_forwarder() {
        let text = "#EXTM3U\r\n#EXT-X-MAP:URI=\"/Videos/1/init.mp4\"\r\n#EXTINF:6,\r\nseg0.ts\r\n/Videos/1/seg1.ts\r\nhttps://list-test.example/Videos/1/seg2.ts\r\n";
        let none = forward_list_write(text.into(), "MARK".into(), None);
        assert!(
            none.contains("URI=\"/MARK/Videos/1/init.mp4\"")
                && none.contains("\n/MARK/Videos/1/seg1.ts\r"),
            "{none}"
        );
        assert!(none.contains("seg0.ts\r") && !none.contains("/MARK/seg0.ts"));
        assert!(
            none.contains("https://list-test.example/Videos/1/seg2.ts"),
            "no forwarder leaves absolute ones"
        );
        let server = "https://list-test.example";
        OwnHeaders::set_down(
            &[OwnHeader {
                name: "X-Gate".into(),
                value: "k".into(),
            }],
            &Url::parse(server).unwrap(),
        );
        let forwarder = StreamForwarder::new(Arc::new(Host(Some(4711))));
        let out = forward_list_write(text.into(), "MARK".into(), Some(forwarder));
        assert!(
            out.contains("http://127.0.0.1:4711/0102030405060708090a0b0c0d0e0f10/Videos/1/seg2.ts"),
            "{out}"
        );
        OwnHeaders::set_down(&[], &Url::parse(server).unwrap());
    }

    #[test]
    fn the_audio_output_is_rebuilt_only_for_a_real_switch_after_the_grace_period() {
        assert!(audio_output_should_rebuild(true, true, 30.0));
        assert!(!audio_output_should_rebuild(true, true, 1.0));
        assert!(!audio_output_should_rebuild(false, true, 30.0));
        assert!(!audio_output_should_rebuild(true, false, 30.0));
    }
}
