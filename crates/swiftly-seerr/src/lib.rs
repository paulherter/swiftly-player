//! Seerr (Jellyseerr / Overseerr) support of the Swiftly core, ported from
//! `JellyfinKit/Seerr.swift`.
//!
//! * [`models`]: hits, details, the stored [`SeerrAccess`] (JSON keys equal the Swift `Codable`).
//! * [`mapping`]: response mapping, request body, cookie cutting, address rules.
//! * [`setup`]: the three sign-in ways (Jellyfin, local, Plex), the per-server configuration and the one
//!   sign-in state machine [`SeerrSetup`].
//! * [`client`]: [`SeerrClient`] over an `HttpTransport` and an explicit [`CookieJar`].
//! * [`errors`], [`perms`], [`status`], [`types`]: typed failures, the permission bitmask, the one
//!   status vocabulary (`SeerrStatus`) and the wire types of the full API.
//! * [`titles`], [`discover`], [`requests`], [`issues`]: the calls (account, search, title pages,
//!   discover sections, requests, issues, delete) as methods of [`SeerrClient`].
//!
//! Cookies stay explicit: the Apple transport (a Swift `URLSession` foreign client) has no cookie
//! handling in the Rust core, so the credential is the `Cookie` header value kept in
//! [`SeerrAccess`], and the optional jar only supplies the fallback of the sign-in.

pub mod auto;
pub mod client;
pub mod discover;
pub mod errors;
pub mod issues;
pub mod mapping;
pub mod models;
pub mod perms;
pub mod requests;
pub mod setup;
pub mod status;
pub mod titles;
pub mod types;

pub use auto::{AutoEvent, AutoRefused, AutoSignIn, auto_sign_in};
pub use client::{
    BodyStash, CookieJar, KeepPostRedirects, NoCookies, SeerrClient, SeerrLog, SeerrSessionState,
    error_to_show, is_replaying, replaying,
};
pub use errors::AskError;
pub use mapping::Seerr;
pub use models::{SeerrAccess, SeerrDetail, SeerrHit, SeerrPerson, SeerrSeason, SeerrState};
pub use perms::Perms;
pub use setup::{
    AddressEntry, Attempt, SeerrServerConfig, SeerrSetup, SetupEvent, SetupRefused, SignInCause,
    SignInKind, SignInMethod,
};
pub use status::{
    SeasonDays, SeerrStatus, StatusInput, combine_seasons, season_request_status, status_of,
};
