//! Plex Media Server support of the Swiftly core, ported 1:1 from
//! `Packages/JellyfinKit/Sources/JellyfinKit/Plex`.
//!
//! * [`wire`]: the answers of a server, read leniently ([`loose`]).
//! * [`PlexMapper`]: wire types into the shared `Item`, `MediaSource`, `Segment`, `Chapter`.
//! * [`merge`]: several libraries as one sorted list.
//! * [`PlexPlayback`]: file, subtitle, photo-transcode and preview addresses, the direct-play
//!   plan, the `/:/timeline` query; [`PlexBif`]: the preview-picture file.
//! * [`PlexAccountService`]: the plex.tv PIN sign-in, token check, server list, Plex Home.
//! * [`PlexConnector`]: which address of a server to use.
//! * [`PlexDecision`]: the play decision, asked only to learn whether a file may go out as it is;
//!   [`notifications`]: the library-change socket (address, frame reader, throttle).
//! * [`PlexClient`]: the server client over [`swiftly_net::HttpTransport`], with the
//!   address-change logic; bound to `swiftly_playback::media_server::MediaServer`.
//!
//! Nothing here contacts plex.tv or a server by itself: the caller hands in the transport.
#![deny(missing_docs)]

mod account;
mod bif;
mod client;
mod connections;
mod decision;
mod features;
mod identity;
mod loose;
mod mapping;
mod media_server;
pub mod merge;
pub mod notifications;
mod playback;
mod server;
mod session;
pub mod wire;

pub use account::{PlexAccount, PlexAccountService, PlexHomeUser, PlexPin, TokenState};
pub use bif::{BifFrame, PlexBif};
pub use client::{
    ImageKind, PlexClient, PlexDetail, PlexPage, PlexResolvedRoute, PlexServerInfo, Resolver,
};
pub use connections::{PlexChosenConnection, PlexConnector, Probe, Sleep};
pub mod play_check;
pub use decision::{DECISION_OK, PlexDecision};
pub use features::PlexFeatures;
pub use identity::{PlexError, PlexIdentity};
pub use mapping::PlexMapper;
pub use playback::{PlexFile, PlexPlayback, TimelineState};
pub use server::{PlexConnectionInfo, PlexServerResource};
pub use session::{PlexAccountSession, PlexSessionDetails, identity_of_address};
pub use wire::{
    PlexChapter, PlexHub, PlexListing, PlexMarker, PlexMedia, PlexMetadata, PlexPart, PlexSection,
    PlexStream, PlexTag,
};
