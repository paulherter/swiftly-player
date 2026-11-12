use std::fmt;

use swiftly_jellyfin::ServerKind;

/// The account a view model works for. The host reads the token from its secret store and
/// passes it in; the core never stores it.
#[derive(Clone, PartialEq, Eq)]
pub struct AccountRef {
    /// Server address as the user typed it.
    pub base_url: String,
    /// The user id on that server.
    pub user_id: String,
    /// The access token. Never logged: `Debug` hides it.
    pub token: String,
    /// Jellyfin or Emby.
    pub server_kind: ServerKind,
    /// Stable id of this installation.
    pub device_id: String,
    /// Plex only: the machine id of the server (what stays when its address moves).
    pub plex_machine_id: Option<String>,
    /// Plex only: the plex.tv token, needed to ask for the server's addresses again. Never
    /// logged: `Debug` hides it.
    pub plex_account_token: Option<String>,
}

impl AccountRef {
    /// The key of the stored home page preview: address and user, no token
    /// (`Session.accountKey`).
    pub fn key(&self) -> String {
        format!("{}|{}", self.base_url, self.user_id)
    }
}

impl fmt::Debug for AccountRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AccountRef")
            .field("base_url", &self.base_url)
            .field("user_id", &self.user_id)
            .field("token", &"<hidden>")
            .field("server_kind", &self.server_kind)
            .finish_non_exhaustive()
    }
}
