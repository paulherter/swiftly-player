//! **The Plex part of a session** (`PlexSession.swift`).
//!
//! A Jellyfin account is "this address, this token". A Plex account is "this server of this
//! plex.tv account", and the address is only the way that worked last: it changes with the
//! network (home, mobile data, relay). So the session keeps what does not change and what is
//! needed to ask plex.tv for the addresses again.
//!
//! In the shared [`Session`] the usual fields mean: `access_token` is the token the **server**
//! accepts; `user_id` / `user_name` the plex.tv user (the home profile that signed in);
//! `server_url` the address in use, replaced when the client switches. The Plex details are
//! kept next to it in [`PlexAccountSession`] and are written only when present, so every
//! Jellyfin session stays as it was.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use swiftly_jellyfin::{ServerKind, Session};

use crate::connections::PlexChosenConnection;
use crate::identity::PlexError;
use crate::server::PlexServerResource;

/// The details a Plex account needs beyond the shared session (PlexSession.swift:18).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlexSessionDetails {
    /// The server, for good: what `/identity` and plex.tv call `machineIdentifier`.
    #[serde(rename = "machineIdentifier")]
    pub machine_identifier: String,
    /// The server's name.
    #[serde(rename = "serverName", default)]
    pub server_name: String,
    /// The plex.tv token of this profile. Needed to list the server's addresses again.
    #[serde(rename = "accountToken")]
    pub account_token: String,
    /// Whether the address in the session is on the home network.
    #[serde(rename = "isLocal", default)]
    pub is_local: bool,
    /// Whether the address in the session is a relay.
    #[serde(rename = "isRelay", default)]
    pub is_relay: bool,
    /// The home profile's `uuid`, if the account is a profile of a Plex Home.
    #[serde(
        rename = "homeUserUUID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub home_user_uuid: Option<String>,
    /// The profile's picture: a full address at plex.tv.
    #[serde(rename = "userImage", default, skip_serializing_if = "Option::is_none")]
    pub user_image: Option<String>,
}

/// `Debug` never shows the plex.tv token.
impl std::fmt::Debug for PlexSessionDetails {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PlexSessionDetails")
            .field("machine_identifier", &self.machine_identifier)
            .field("server_name", &self.server_name)
            .field("account_token", &swiftly_net::redact::MASK)
            .field("is_local", &self.is_local)
            .field("is_relay", &self.is_relay)
            .field("home_user_uuid", &self.home_user_uuid)
            .finish_non_exhaustive()
    }
}

impl PlexSessionDetails {
    /// Details with the required fields and defaults for the rest.
    pub fn new(machine_identifier: &str, server_name: &str, account_token: &str) -> Self {
        Self {
            machine_identifier: machine_identifier.into(),
            server_name: server_name.into(),
            account_token: account_token.into(),
            is_local: false,
            is_relay: false,
            home_user_uuid: None,
            user_image: None,
        }
    }

    /// The same details after the client moved to another address (:49).
    pub fn moved(&self, connection: &PlexChosenConnection) -> Self {
        Self {
            is_local: connection.is_local,
            is_relay: connection.is_relay,
            ..self.clone()
        }
    }
}

/// A session of a Plex account: the shared [`Session`] plus the Plex block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexAccountSession {
    /// The shared session (`kind` is Plex).
    pub session: Session,
    /// The Plex block; `None` for a client built from an address alone.
    pub plex: Option<PlexSessionDetails>,
}

impl PlexAccountSession {
    /// A Plex session from what sign-in found out (PlexSession.swift:80).
    pub fn from_server(
        server: &PlexServerResource,
        connection: &PlexChosenConnection,
        account_token: &str,
        user_id: &str,
        user_name: &str,
        home_user_uuid: Option<&str>,
        user_image: Option<&str>,
    ) -> Self {
        Self {
            session: Session {
                access_token: server
                    .access_token
                    .clone()
                    .unwrap_or_else(|| account_token.to_string()),
                user_id: user_id.into(),
                user_name: user_name.into(),
                server_url: connection.uri.clone(),
                kind: ServerKind::Plex,
            },
            plex: Some(PlexSessionDetails {
                machine_identifier: server.machine_identifier.clone(),
                server_name: server.name.clone(),
                account_token: account_token.into(),
                is_local: connection.is_local,
                is_relay: connection.is_relay,
                home_user_uuid: home_user_uuid.map(Into::into),
                user_image: user_image.map(Into::into),
            }),
        }
    }

    /// The stored JSON: the shared session's keys, plus `plex` when present.
    pub fn to_json(&self) -> Result<String, PlexError> {
        let mut value = serde_json::to_value(&self.session)
            .map_err(|e| swiftly_net::ErrorKind::Decoding(e.to_string()))?;
        if let (Value::Object(map), Some(plex)) = (&mut value, &self.plex) {
            let block = serde_json::to_value(plex)
                .map_err(|e| swiftly_net::ErrorKind::Decoding(e.to_string()))?;
            map.insert("plex".into(), block);
        }
        serde_json::to_string(&value)
            .map_err(|e| swiftly_net::ErrorKind::Decoding(e.to_string()).into())
    }

    /// Reads the stored JSON; the `plex` block is optional (older sessions have none).
    pub fn from_json(text: &str) -> Result<Self, PlexError> {
        let decoding = |e: serde_json::Error| swiftly_net::ErrorKind::Decoding(e.to_string());
        let mut map: Map<String, Value> = serde_json::from_str(text).map_err(decoding)?;
        let plex = match map.remove("plex") {
            Some(Value::Null) | None => None,
            Some(block) => Some(serde_json::from_value(block).map_err(decoding)?),
        };
        let session = serde_json::from_value(Value::Object(map)).map_err(decoding)?;
        Ok(Self { session, plex })
    }

    /// **Which account this is, as a stable key** (`Session.accountKey`): a Plex server is its
    /// machine, never its address, so the key survives a change of network.
    pub fn account_key(&self) -> String {
        match &self.plex {
            Some(p) => format!("plex:{}|{}", p.machine_identifier, self.session.user_id),
            None => format!("plex:{}|{}", self.session.server_url, self.session.user_id),
        }
    }

    /// **Which server this account belongs to, as a stable text** (PlexSession.swift:94). For a
    /// Plex server its machine, never its address.
    pub fn server_identity(&self) -> String {
        match &self.plex {
            Some(p) => format!("plex:{}", p.machine_identifier),
            None => identity_of_address(&self.session.server_url),
        }
    }

    /// The suffix of a setting that applies per server (`"immerDirectPlay" + suffix`) (:111).
    pub fn server_suffix(&self) -> String {
        match &self.plex {
            Some(p) => format!("|plex:{}", p.machine_identifier),
            None => format!("|{}", self.session.server_url),
        }
    }

    /// **The account as downloads, positions to send later and offline lists keep it**: the
    /// machine in front of the user id, because a `ratingKey` is only unique per server (:119).
    pub fn storage_account(&self) -> String {
        match &self.plex {
            Some(p) => format!("plex-{}-{}", p.machine_identifier, self.session.user_id),
            None => self.session.user_id.clone(),
        }
    }
}

/// The identity of a server known only by its address: lower case, no trailing slash
/// (`Session.serverIdentity(of:)`).
pub fn identity_of_address(url: &str) -> String {
    url.to_lowercase().trim_end_matches('/').to_string()
}
