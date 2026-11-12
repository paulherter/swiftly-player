//! Seerr (Jellyseerr / Overseerr) support of the Swiftly core, ported from
//! `JellyfinKit/Seerr.swift`.
//!
//! * [`models`]: hits, details, the stored [`SeerrAccess`] (JSON keys equal the Swift `Codable`).
//! * [`mapping`]: response mapping, request body, cookie cutting, address rules.
//! * [`client`]: [`SeerrClient`] over an `HttpTransport` and an explicit [`CookieJar`].
//!
//! Cookies stay explicit: the Apple transport (a Swift `URLSession` foreign client) has no cookie
//! handling in the Rust core, so the credential is the `Cookie` header value kept in
//! [`SeerrAccess`], and the optional jar only supplies the fallback of the sign-in.

pub mod auto;
pub mod client;
pub mod mapping;
pub mod models;

pub use auto::{AutoEvent, AutoRefused, AutoSignIn, auto_sign_in};
pub use client::{
    CookieJar, KeepPostRedirects, NoCookies, SeerrClient, SeerrSessionState, error_to_show,
};
pub use mapping::Seerr;
pub use models::{SeerrAccess, SeerrDetail, SeerrHit, SeerrPerson, SeerrSeason, SeerrState};
