//! Jellyfin and Emby client of the Swiftly core, ported from `Packages/JellyfinKit`.
//!
//! [`JellyfinClient`] is generic over [`swiftly_net::HttpTransport`], so tests run against
//! the mock and the app against reqwest. Every request builder cites the Swift line it
//! mirrors; the tests in `tests/request_golden.rs` assert the exact address, query string,
//! headers and body of each call.
#![deny(missing_docs)]

mod address;
mod client;
pub mod discovery;
mod discovery_phase;
mod emby;
mod endpoints;
mod extras;
mod login;
mod own_headers;
mod pending;
mod query;
mod quick_phase;
mod quick_share;
mod quick_wait;
mod reporting;
mod server_url;
mod session;
mod sessions;

pub use address::{ADDRESS_CHECK_DEADLINE, CheckMark, CheckState};
pub use client::{ClientConfig, JellyfinClient};
pub use discovery::{DatagramSocket, FoundServer};
pub use discovery_phase::{DiscoveryEvent, DiscoveryPhase};
pub use emby::{
    EmbyAttempt, EmbyProblem, classify_attempt as emby_classify_attempt,
    classify_failure as emby_classify_failure, not_emby_jellyfin, rewrite_path as emby_rewrite,
    sign_in_header as emby_sign_in_header, token_name,
};
pub use endpoints::ItemsQuery;
pub use extras::{DownloadConversion, Watcher};
pub use login::{LoginCode, PublicUser, QuickConnectDeadline, QuickConnectState};
pub use own_headers::{OwnHeader, OwnHeaders};
pub use pending::{PendingReport, PostReportOutput, PostReportRules};
pub use query::{encode_query_value, image_key, without_secret};
pub use quick_phase::{QuickEvent, QuickPhase};
pub use quick_wait::{QuickConnectWait, WaitClock, WaitEvent, WaitStep};
pub use reporting::{PlayMethod, ReportPlan, TrackIndices, seconds_from_ticks, ticks_from_seconds};
pub use server_url::{
    ZonedAddress, is_home_network, is_ipv6, normalize as normalize_server_url,
    normalize_string as normalize_server_url_string, normalize_zoned as normalize_server_url_zoned,
    reversed as reversed_server_url, reversed_string as reversed_server_url_string,
};
pub use session::{ServerKind, Session};
pub use sessions::{
    ForeignCommand, HINT_HEADER, RemoteCommand, RemoteSession, RemoteSessionPlayState,
    SUPPORTED_COMMANDS, SocketMessage,
};
