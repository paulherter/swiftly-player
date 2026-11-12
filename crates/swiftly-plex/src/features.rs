//! What a Plex server gives the app (`PlexFeatures.swift`).
//!
//! Left out on purpose: SyncPlay, Quick Connect, remote control, "play on another device" and
//! settings sync have no counterpart in the Plex client API in use, and there is no list of
//! public users to pick from. Seerr is out: its sign-in is the media server's user name and
//! password, and a Plex account has no such pair.
//!
//! Some entries depend on the server: intro and credits markers exist only with Plex Pass and
//! an analysed library; preview pictures only when the server made them. When they are
//! missing the lists are simply empty.

use swiftly_playback::media_server::ServerCapability;

/// Namespace for the capability tables.
pub struct PlexFeatures;

impl PlexFeatures {
    /// What a Plex server can do (PlexFeatures.swift:15).
    pub fn capabilities() -> Vec<ServerCapability> {
        use ServerCapability::*;
        vec![
            Trickplay,
            IntroSegments,
            Chapters,
            Collections,
            Playlists,
            Favorites,
            MarkWatched,
            Similar,
            Extras,
            Genres,
            Downloads,
        ]
    }

    /// The ones deliberately missing, for a test that keeps both lists complete.
    pub fn missing() -> Vec<ServerCapability> {
        let can = Self::capabilities();
        ServerCapability::ALL
            .into_iter()
            .filter(|c| !can.contains(c))
            .collect()
    }
}
