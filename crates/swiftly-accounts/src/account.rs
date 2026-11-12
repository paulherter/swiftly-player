use serde::{Deserialize, Serialize};
use swiftly_jellyfin::{ServerKind, Session};
use swiftly_plex::PlexSessionDetails;

/// One saved account: the shared [`Session`] plus the Plex block (`Session` in Swift carries
/// both). JSON: the session's keys, `kind` only when not Jellyfin, `plex` only when present.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Account {
    /// The shared session.
    #[serde(flatten)]
    pub session: Session,
    /// The Plex block; `None` for everything else.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plex: Option<PlexSessionDetails>,
}

/// The identity of a server known only by its address: lower case, no trailing slash.
pub fn identity_of_address(url: &str) -> String {
    url.to_lowercase().trim_end_matches('/').to_string()
}

fn prefix(kind: ServerKind) -> &'static str {
    match kind {
        ServerKind::Jellyfin => "",
        ServerKind::Emby => "emby:",
        ServerKind::Plex => "plex:",
    }
}

impl Account {
    /// A plain account without a Plex block.
    pub fn new(session: Session) -> Self {
        Self {
            session,
            plex: None,
        }
    }

    /// Server and user together (`Session.accountKey`). Jellyfin keys have no prefix and stay
    /// byte-identical; Plex uses the machine, not the address.
    pub fn account_key(&self) -> String {
        let kind = self.session.kind;
        if kind == ServerKind::Plex
            && let Some(p) = &self.plex
        {
            return format!(
                "{}{}|{}",
                prefix(kind),
                p.machine_identifier,
                self.session.user_id
            );
        }
        format!(
            "{}{}|{}",
            prefix(kind),
            identity_of_address(&self.session.server_url),
            self.session.user_id
        )
    }

    /// Which server this account belongs to (`Session.serverIdentity`).
    pub fn server_identity(&self) -> String {
        match (&self.plex, self.session.kind) {
            (Some(p), ServerKind::Plex) => format!("plex:{}", p.machine_identifier),
            _ => identity_of_address(&self.session.server_url),
        }
    }
}
