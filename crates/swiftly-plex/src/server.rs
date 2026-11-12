//! A server as plex.tv lists it, with all the ways to reach it (`PlexAccount.swift:284-360`).

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Value, json};

use crate::loose;

/// A server of the account (`/api/v2/resources`, PlexAccount.swift:284).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexServerResource {
    /// Server name.
    pub name: String,
    /// `clientIdentifier`: the machine; the identity of the server.
    pub machine_identifier: String,
    /// What the resource provides (`server`, `client`, `player`, ...).
    pub provides: Vec<String>,
    /// Does the account own it?
    pub owned: bool,
    /// The token the server accepts (for a shared server a separate one).
    pub access_token: Option<String>,
    /// Does the server insist on https?
    pub https_required: bool,
    /// Is it online?
    pub presence: bool,
    /// All addresses.
    pub connections: Vec<PlexConnectionInfo>,
    /// Who shares it.
    pub source_title: Option<String>,
}

impl PlexServerResource {
    /// Reads one resource; `None` without `clientIdentifier` (:~305).
    pub fn parse(v: &Value) -> Option<Self> {
        Some(Self {
            machine_identifier: loose::string(v, "clientIdentifier")?,
            name: loose::string(v, "name").unwrap_or_default(),
            provides: loose::string(v, "provides")
                .unwrap_or_default()
                .split(',')
                .filter(|p| !p.is_empty())
                .map(String::from)
                .collect(),
            owned: loose::boolean(v, "owned").unwrap_or(false),
            access_token: loose::string(v, "accessToken"),
            https_required: loose::boolean(v, "httpsRequired").unwrap_or(false),
            presence: loose::boolean(v, "presence").unwrap_or(true),
            connections: loose::list(v, "connections", PlexConnectionInfo::parse)
                .unwrap_or_default(),
            source_title: loose::string(v, "sourceTitle"),
        })
    }
}

/// One address of a server (PlexAccount.swift:322).
///
/// plex.tv writes `"protocol": "https"`, `"local"`, `"relay"`, `"IPv6"`; the stored form (the
/// `Serialize` impl) uses `isLocal` / `isRelayStored` next to them, and both are read.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PlexConnectionInfo {
    /// The address.
    pub uri: String,
    /// Host or IP.
    pub address: String,
    /// Port.
    pub port: i64,
    /// https?
    pub is_https: bool,
    /// On the home network?
    pub is_local: bool,
    /// A relay (slow, throttled)?
    pub is_relay: bool,
    /// IPv6?
    pub is_ipv6: bool,
}

impl PlexConnectionInfo {
    /// A connection by hand.
    pub fn new(uri: &str, is_https: bool, is_local: bool, is_relay: bool, is_ipv6: bool) -> Self {
        Self {
            uri: uri.into(),
            address: String::new(),
            port: 32400,
            is_https,
            is_local,
            is_relay,
            is_ipv6,
        }
    }

    /// Reads one connection; `None` without `uri` (:~345).
    pub fn parse(v: &Value) -> Option<Self> {
        let uri = loose::string(v, "uri")?;
        let proto = loose::string(v, "protocol");
        let is_https = proto
            .map(|p| p.to_lowercase() == "https")
            .unwrap_or_else(|| uri.to_lowercase().starts_with("https"));
        Some(Self {
            address: loose::string(v, "address").unwrap_or_default(),
            port: loose::int(v, "port").unwrap_or(32400),
            is_https,
            is_local: loose::boolean(v, "local")
                .or_else(|| loose::boolean(v, "isLocal"))
                .unwrap_or(false),
            is_relay: loose::boolean(v, "relay")
                .or_else(|| loose::boolean(v, "isRelayStored"))
                .unwrap_or(false),
            is_ipv6: loose::boolean(v, "IPv6").unwrap_or(false),
            uri,
        })
    }
}

impl Serialize for PlexConnectionInfo {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        json!({
            "uri": self.uri,
            "address": self.address,
            "port": self.port,
            "protocol": if self.is_https { "https" } else { "http" },
            "isLocal": self.is_local,
            "isRelayStored": self.is_relay,
            "IPv6": self.is_ipv6,
        })
        .serialize(s)
    }
}

impl<'de> Deserialize<'de> for PlexConnectionInfo {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = Value::deserialize(d)?;
        Self::parse(&v).ok_or_else(|| serde::de::Error::missing_field("uri"))
    }
}
