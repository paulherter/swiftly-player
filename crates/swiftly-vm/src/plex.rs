//! The Plex client of a view model: built from the same [`AccountRef`] as the Jellyfin one.
//!
//! A Plex account is an `AccountRef` with `server_kind == ServerKind::Plex`: `base_url` is the
//! address in use, `token` the token the **server** accepts, `user_id` the plex.tv user. The
//! host that also has the Plex block (machine id, plex.tv token, resolver for other addresses)
//! builds a `PlexClient::from_session` itself and hands it to `set_plex`; this is the plain
//! route without the address look-up.

use std::sync::Arc;

use swiftly_jellyfin::ServerKind;
use swiftly_net::{ErrorKind, HttpTransport, Url};
use swiftly_plex::{PlexClient, PlexIdentity};

use crate::account::AccountRef;
use crate::host::{Host, Shared};

/// The Plex client of a view model.
pub(crate) type Plex<T> = PlexClient<Shared<T>>;

/// Whether the account is a Plex account.
pub(crate) fn is_plex(account: &AccountRef) -> bool {
    account.server_kind == ServerKind::Plex
}

/// The platform name Plex shows in its device list.
fn platform() -> &'static str {
    match std::env::consts::OS {
        "macos" => "macOS",
        "ios" => "iOS",
        "windows" => "Windows",
        "android" => "Android",
        "linux" => "Linux",
        other => other,
    }
}

/// A `PlexClient` for `account` (`PlexClient(session:identity:)`).
///
/// # Errors
/// [`ErrorKind::InvalidServerUrl`] if the address is not an http(s) address.
pub(crate) fn build_plex_client<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: &AccountRef,
) -> Result<Plex<T>, ErrorKind> {
    let base = Url::parse(&account.base_url).map_err(|_| ErrorKind::InvalidServerUrl)?;
    if !matches!(base.scheme(), "http" | "https") {
        return Err(ErrorKind::InvalidServerUrl);
    }
    let identity = PlexIdentity::new(
        &account.device_id,
        &host.client_version,
        platform(),
        &host.device_name,
        &host.device_name,
    );
    Ok(PlexClient::new(
        base,
        &account.token,
        identity,
        Arc::new(Shared(Arc::clone(transport))),
    ))
}

/// Builds the Plex client for `account` if it is a Plex account.
pub fn plex_client_for<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: &AccountRef,
) -> Result<Option<Arc<PlexClient<Shared<T>>>>, ErrorKind> {
    if !is_plex(account) {
        return Ok(None);
    }
    build_plex_client(transport, host, account).map(|c| Some(Arc::new(c)))
}
