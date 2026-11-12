//! The server of the active account, whatever its kind: Jellyfin, Emby or Plex. `Core::server_for` builds the client
//! the core's `MediaServerFactory` picks (`swiftly_vm::make_client`); the calls the live screens make themselves (not
//! through a view model) go through the helpers here, so no screen names a concrete client.

use crate::live::Core;
use crate::net::AppTransport;
use std::collections::HashMap;
use swiftly_library::LibraryShare;
use swiftly_model::Item;
use swiftly_net::ErrorKind;
use swiftly_playback::media_server::MediaServer;
use swiftly_vm::{AccountRef, ServerClient};

/// The client of any kind over the app transport.
pub type Server = ServerClient<AppTransport>;

impl Core {
    /// The client for `account`: Plex for a Plex account (its machine token and address), else Jellyfin or Emby.
    ///
    /// # Errors
    /// [`ErrorKind::InvalidServerUrl`] when the stored address cannot be used.
    pub fn server_for(&self, account: &AccountRef) -> Result<Server, ErrorKind> {
        swiftly_vm::make_client(&self.net, &self.host(), account)
    }
}

/// The genre names with movies or series.
///
/// # Errors
/// The transport or decoding error.
pub async fn genres(server: &Server) -> Result<Vec<String>, ErrorKind> {
    match server {
        ServerClient::Jellyfin(c) => c.genres().await,
        ServerClient::Plex(c) => MediaServer::genres(&**c).await,
    }
}

/// The libraries of the account and how movies and series are shared among the mixed ones.
///
/// # Errors
/// The transport or decoding error of the library list.
pub async fn views_and_shares(
    server: &Server,
) -> Result<(Vec<Item>, HashMap<String, LibraryShare>), ErrorKind> {
    match server {
        ServerClient::Jellyfin(c) => {
            let views = c.user_views(false).await?;
            let shares = swiftly_library::client_ext::library_shares(&**c, &views).await;
            Ok((views, shares))
        }
        ServerClient::Plex(c) => {
            let views = MediaServer::user_views(&**c, false).await?;
            let shares = MediaServer::library_shares(&**c, &views).await;
            Ok((views, shares))
        }
    }
}

/// One title by id, fresh from the server (a `swiftly://` link).
///
/// # Errors
/// The transport or decoding error.
pub async fn item(server: &Server, id: &str) -> Result<Item, ErrorKind> {
    match server {
        ServerClient::Jellyfin(c) => c.item(id).await,
        ServerClient::Plex(c) => MediaServer::item(&**c, id).await,
    }
}
