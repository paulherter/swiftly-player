use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Which kind of server an account belongs to (`ServerKind`, MediaServer.swift:6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ServerKind {
    /// Jellyfin.
    #[default]
    Jellyfin,
    /// Emby: user-bound paths, `api_key`.
    Emby,
    /// Plex; has its own client, counts as Jellyfin here.
    Plex,
}

/// A signed-in session (`Session`, JellyfinClient.swift:79-129). Stored by the app in the
/// secret store; the JSON keys are the Swift ones, and `kind` is written only when it is not
/// Jellyfin, so a Jellyfin session stays byte-identical to the one older versions wrote.
#[derive(Clone, PartialEq, Eq)]
pub struct Session {
    /// Token for the `Authorization` header and for token-in-query addresses.
    pub access_token: String,
    /// The user id.
    pub user_id: String,
    /// The user name.
    pub user_name: String,
    /// Server base address.
    pub server_url: String,
    /// Kind of server.
    pub kind: ServerKind,
}

/// `Debug` never shows the access token.
impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session")
            .field("access_token", &swiftly_net::redact::MASK)
            .field("user_id", &self.user_id)
            .field("user_name", &self.user_name)
            .field(
                "server_url",
                &swiftly_net::redact::url_text(&self.server_url),
            )
            .field("kind", &self.kind)
            .finish()
    }
}

#[derive(Serialize, Deserialize)]
struct Wire {
    #[serde(rename = "accessToken")]
    access_token: String,
    #[serde(rename = "userID")]
    user_id: String,
    #[serde(rename = "userName")]
    user_name: String,
    #[serde(rename = "serverURL")]
    server_url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    kind: Option<ServerKind>,
}

impl Serialize for Session {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        Wire {
            access_token: self.access_token.clone(),
            user_id: self.user_id.clone(),
            user_name: self.user_name.clone(),
            server_url: self.server_url.clone(),
            kind: (self.kind != ServerKind::Jellyfin).then_some(self.kind),
        }
        .serialize(s)
    }
}

impl<'de> Deserialize<'de> for Session {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let w = Wire::deserialize(d)?;
        Ok(Self {
            access_token: w.access_token,
            user_id: w.user_id,
            user_name: w.user_name,
            server_url: w.server_url,
            kind: w.kind.unwrap_or_default(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // EmbyTests.swift:127 sessionKind
    #[test]
    fn kind_is_written_only_when_not_jellyfin() {
        let emby = Session {
            access_token: "t".into(),
            user_id: "u".into(),
            user_name: "n".into(),
            server_url: "https://e.test".into(),
            kind: ServerKind::Emby,
        };
        let json = serde_json::to_string(&emby).expect("encode");
        assert!(json.contains(r#""kind":"emby""#));
        assert_eq!(
            serde_json::from_str::<Session>(&json).expect("decode"),
            emby
        );
        let old = Session {
            kind: ServerKind::Jellyfin,
            ..emby
        };
        assert!(
            !serde_json::to_string(&old)
                .expect("encode")
                .contains("kind")
        );
        let back: Session =
            serde_json::from_str(&serde_json::to_string(&old).expect("encode")).expect("decode");
        assert_eq!(back.kind, ServerKind::Jellyfin);
    }
}
