//! One place for what differs between Jellyfin, Emby and Plex: the capability sets, and the
//! client factory (`MediaServerFactory`, `ServerKind.capabilities`, MediaServer.swift:25).
//!
//! [`ServerClient`] is the one handle a front end holds; the calls every server answers are
//! methods on it, so a screen does not name a concrete client.

use std::sync::Arc;

use swiftly_jellyfin::{ClientConfig, JellyfinClient, ServerKind, Session};
use swiftly_library::VideoPlaylist;
use swiftly_library::client_ext::title_person_page;
use swiftly_model::{Item, PublicSystemInfo};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_playback::endpoints::PlaybackEndpoints;
use swiftly_playback::media_server::{MediaServer, ServerCapability};
use swiftly_playback::offering_layer::AccountPreGift;
use swiftly_plex::PlexFeatures;

use crate::account::AccountRef;
use crate::home::{Client, build_client};
use crate::host::{Host, Shared};
use crate::plex::{Plex, build_plex_client, is_plex};

/// What an Emby server can do (`ServerKind.embyCapabilities`, EmbyPaths.swift:73). Left out:
/// Quick Connect, SyncPlay, remote control, play on another device, settings sync, trickplay,
/// intro segments and Seerr.
pub const EMBY_CAPABILITIES: [ServerCapability; 10] = [
    ServerCapability::PublicUsers,
    ServerCapability::Chapters,
    ServerCapability::Collections,
    ServerCapability::Playlists,
    ServerCapability::Favorites,
    ServerCapability::MarkWatched,
    ServerCapability::Similar,
    ServerCapability::Extras,
    ServerCapability::Genres,
    ServerCapability::Downloads,
];

/// What a server of this kind can do (`ServerKind.capabilities`, MediaServer.swift:25): Jellyfin
/// everything, Emby and Plex their own tables. Usable before a client is connected.
pub fn capabilities_for(kind: ServerKind) -> Vec<ServerCapability> {
    match kind {
        ServerKind::Jellyfin => ServerCapability::ALL.to_vec(),
        ServerKind::Emby => EMBY_CAPABILITIES.to_vec(),
        ServerKind::Plex => PlexFeatures::capabilities(),
    }
}

/// Whether servers of this kind offer `capability` (`AppModel.can(_:)`).
pub fn can(kind: ServerKind, capability: ServerCapability) -> bool {
    capabilities_for(kind).contains(&capability)
}

/// A client for one server, of whatever kind.
pub enum ServerClient<T: HttpTransport + 'static> {
    /// Jellyfin or Emby (`kind()` tells which).
    Jellyfin(Arc<Client<T>>),
    /// Plex.
    Plex(Arc<Plex<T>>),
}

impl<T: HttpTransport + 'static> Clone for ServerClient<T> {
    fn clone(&self) -> Self {
        match self {
            Self::Jellyfin(c) => Self::Jellyfin(Arc::clone(c)),
            Self::Plex(c) => Self::Plex(Arc::clone(c)),
        }
    }
}

/// Builds the client for a known account (`MediaServerFactory.make(kind:baseURL:...session:)`).
///
/// # Errors
/// [`ErrorKind::InvalidServerUrl`] if the address cannot be used.
pub fn make_client<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: &AccountRef,
) -> Result<ServerClient<T>, ErrorKind> {
    if is_plex(account) {
        build_plex_client(transport, host, account).map(|c| ServerClient::Plex(Arc::new(c)))
    } else {
        build_client(transport, host, account).map(|c| ServerClient::Jellyfin(Arc::new(c)))
    }
}

/// Builds the client for a stored session (`MediaServerFactory.make(session:deviceID:...)`):
/// kind and address come from the session.
///
/// # Errors
/// [`ErrorKind::InvalidServerUrl`] if the address cannot be used.
pub fn make_client_from_session<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    session: &Session,
    device_id: &str,
) -> Result<ServerClient<T>, ErrorKind> {
    make_client(
        transport,
        host,
        &AccountRef {
            base_url: session.server_url.clone(),
            user_id: session.user_id.clone(),
            token: session.access_token.clone(),
            server_kind: session.kind,
            device_id: device_id.into(),
            plex_machine_id: None,
            plex_account_token: None,
        },
    )
}

/// Builds a client without an account, for asking a server who it is or for signing in
/// (`MediaServerFactory.make(kind:baseURL:...)` with no session).
///
/// # Errors
/// [`ErrorKind::InvalidServerUrl`] if the address cannot be used.
pub fn make_signed_out_client<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    kind: ServerKind,
    base_url: &str,
    device_id: &str,
) -> Result<ServerClient<T>, ErrorKind> {
    if kind == ServerKind::Plex {
        return make_client(
            transport,
            host,
            &AccountRef {
                base_url: base_url.into(),
                user_id: String::new(),
                token: String::new(),
                server_kind: kind,
                device_id: device_id.into(),
                plex_machine_id: None,
                plex_account_token: None,
            },
        );
    }
    let config = ClientConfig::new(device_id, &host.device_name, &host.client_version)
        .kind(kind)
        .lean_tiles(true);
    JellyfinClient::new(Shared(Arc::clone(transport)), base_url, config)
        .map(|c| ServerClient::Jellyfin(Arc::new(c)))
}

impl<T: HttpTransport + 'static> ServerClient<T> {
    /// Which kind of server this is.
    pub fn kind(&self) -> ServerKind {
        match self {
            Self::Jellyfin(c) => c.server_kind(),
            Self::Plex(_) => ServerKind::Plex,
        }
    }

    /// What this server can do.
    pub fn capabilities(&self) -> Vec<ServerCapability> {
        capabilities_for(self.kind())
    }

    /// The server address.
    pub fn base_url(&self) -> String {
        match self {
            Self::Jellyfin(c) => c.base_url().to_string(),
            Self::Plex(c) => c.base_url().to_string(),
        }
    }

    /// The signed-in session, if any.
    pub fn current_session(&self) -> Option<Session> {
        match self {
            Self::Jellyfin(c) => c.current_session(),
            Self::Plex(c) => c.current_session().map(|s| s.session),
        }
    }

    /// Who the server says it is, without signing in.
    ///
    /// # Errors
    /// The transport or decoding error.
    pub async fn public_system_info(&self) -> Result<PublicSystemInfo, ErrorKind> {
        match self {
            Self::Jellyfin(c) => c.public_system_info().await,
            Self::Plex(c) => MediaServer::public_system_info(&**c).await,
        }
    }

    /// Like [`Self::public_system_info`], for the address check.
    ///
    /// # Errors
    /// The transport or decoding error.
    pub async fn check_reachability(&self) -> Result<PublicSystemInfo, ErrorKind> {
        match self {
            Self::Jellyfin(c) => c.check_reachability().await,
            Self::Plex(c) => MediaServer::check_reachability(&**c).await,
        }
    }

    /// Signs in with name and password (Plex signs in at plex.tv and answers an error here).
    ///
    /// # Errors
    /// The sign-in error.
    pub async fn authenticate(&self, user: &str, password: &str) -> Result<Session, ErrorKind> {
        match self {
            Self::Jellyfin(c) => c.authenticate(user, password).await,
            Self::Plex(c) => MediaServer::authenticate(&**c, user, password).await,
        }
    }

    /// Tells the server the account signs out (`signOff`, JellyfinClient.swift:417: `POST
    /// Sessions/Logout`) and forgets the session on this client. Errors do not matter: signing
    /// out locally must work without a network. Plex has no server call, it forgets the account.
    pub async fn sign_off(&self) {
        match self {
            Self::Jellyfin(c) => c.sign_off().await,
            Self::Plex(c) => MediaServer::sign_off(&**c).await,
        }
    }

    /// What the server says about the account (`accountDefaults`, JellyfinClient.swift:1195:
    /// `GET Users/{id}`): next-episode autoplay and the download and transcoding permissions.
    /// `None` on any failure.
    pub async fn account_defaults(&self) -> Option<AccountPreGift> {
        match self {
            Self::Jellyfin(c) => PlaybackEndpoints::account_defaults(&**c).await,
            Self::Plex(c) => MediaServer::account_defaults(&**c).await,
        }
    }

    /// The entries of a playlist, video only, in the playlist's order (`playlistEntries`).
    ///
    /// # Errors
    /// The transport or decoding error.
    pub async fn playlist_entries(&self, playlist: &str) -> Result<Vec<Item>, ErrorKind> {
        match self {
            Self::Jellyfin(c) => Ok(c
                .playlist_entries(playlist, false)
                .await?
                .into_iter()
                .filter(VideoPlaylist::is_video_entry)
                .collect()),
            Self::Plex(c) => MediaServer::playlist_entries(&**c, playlist, false).await,
        }
    }

    /// One page of a person's titles (movies and series, newest production year first) with the
    /// server's total; each work once within the page. `None` if the server did not answer
    /// (`titleWithNumber(person:)`, People.swift:68).
    pub async fn title_with_number_person(
        &self,
        id: &str,
        limit: i64,
        start_index: i64,
    ) -> Option<(Vec<Item>, i64)> {
        match self {
            Self::Jellyfin(c) => title_person_page(&**c, id, limit, start_index).await,
            Self::Plex(c) => {
                MediaServer::title_with_number_person(&**c, id, limit, start_index).await
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ServerCapability::*;

    // MediaServerTests.swift:104 capabilityTable
    #[test]
    fn the_table_per_kind() {
        assert_eq!(
            capabilities_for(ServerKind::Jellyfin),
            ServerCapability::ALL.to_vec()
        );
        assert_eq!(
            capabilities_for(ServerKind::Emby),
            EMBY_CAPABILITIES.to_vec()
        );
        // Emby trickplay (index.bif) was never measured on a server: decision "not supported" (core-gap-current.md).
        assert!(!can(ServerKind::Emby, ServerCapability::Trickplay));
        assert_eq!(
            capabilities_for(ServerKind::Plex),
            PlexFeatures::capabilities()
        );
    }

    #[test]
    fn emby_and_plex_lack_what_swiftly_only_has_for_jellyfin() {
        for lacking in [
            QuickConnect,
            SyncPlay,
            RemoteControl,
            PlayOnOtherDevice,
            SettingsSync,
            Seerr,
        ] {
            assert!(can(ServerKind::Jellyfin, lacking));
            assert!(!can(ServerKind::Emby, lacking), "{lacking:?}");
            assert!(!can(ServerKind::Plex, lacking), "{lacking:?}");
        }
        assert!(can(ServerKind::Emby, PublicUsers));
        assert!(!can(ServerKind::Plex, PublicUsers));
        assert!(can(ServerKind::Plex, IntroSegments) && !can(ServerKind::Emby, IntroSegments));
    }
}
