//! Who is asking, and what can go wrong (`PlexIdentity.swift`).

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};

use swiftly_net::{ErrorKind, TransportReason};

/// The fixed facts every Plex request carries as headers (PlexIdentity.swift:8).
///
/// `client_id` is created once per installation and kept; Plex lists the device under it and
/// ties tokens to it. The app decides where it lives, this crate only uses it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexIdentity {
    /// The installation id (a lower-case UUID).
    pub client_id: String,
    /// Product name, "Swiftly Player".
    pub product: String,
    /// App version.
    pub version: String,
    /// `iOS`, `tvOS`, `macOS`, `Android`, `Linux`, `Windows`.
    pub platform: String,
    /// OS version, if known.
    pub platform_version: Option<String>,
    /// Model, e.g. `iPhone15,2`.
    pub device: String,
    /// The name the user gave the device; UTF-8 is allowed.
    pub device_name: String,
}

impl PlexIdentity {
    /// The default product name (PlexIdentity.swift:19).
    pub const PRODUCT: &'static str = "Swiftly Player";

    /// An identity with the default product name.
    pub fn new(
        client_id: &str,
        version: &str,
        platform: &str,
        device: &str,
        device_name: &str,
    ) -> Self {
        Self {
            client_id: client_id.into(),
            product: Self::PRODUCT.into(),
            version: version.into(),
            platform: platform.into(),
            platform_version: None,
            device: device.into(),
            device_name: device_name.into(),
        }
    }

    /// A fresh id for the first start (`makeClientID`, :52): a random UUID v4, lower case.
    /// The caller stores it.
    pub fn make_client_id() -> String {
        random_uuid()
    }

    /// The header fields for a request, in the order Swift's dictionary is filled; `token`
    /// only for routes that need one (PlexIdentity.swift:56-69).
    pub fn headers(&self, token: Option<&str>, session_id: Option<&str>) -> Vec<(String, String)> {
        let mut fields = vec![
            ("Accept".to_string(), "application/json".to_string()),
            ("X-Plex-Client-Identifier".into(), self.client_id.clone()),
            ("X-Plex-Product".into(), self.product.clone()),
            ("X-Plex-Version".into(), self.version.clone()),
            ("X-Plex-Platform".into(), self.platform.clone()),
            ("X-Plex-Device".into(), self.device.clone()),
            (
                "X-Plex-Device-Name".into(),
                Self::safe_value(&self.device_name),
            ),
        ];
        if let Some(v) = &self.platform_version {
            fields.push(("X-Plex-Platform-Version".into(), v.clone()));
        }
        if let Some(t) = token {
            fields.push(("X-Plex-Token".into(), t.into()));
        }
        if let Some(s) = session_id {
            fields.push(("X-Plex-Session-Identifier".into(), s.into()));
        }
        fields
    }

    /// A header value cannot hold a line break. Everything else (umlauts, emoji) is fine
    /// (PlexIdentity.swift:73, `CharacterSet.controlCharacters` = general category Cc).
    pub fn safe_value(raw: &str) -> String {
        raw.chars().filter(|c| !c.is_control()).collect()
    }
}

/// A random UUID v4 in lower case, from the standard library's randomly keyed hasher.
pub(crate) fn random_uuid() -> String {
    let state = RandomState::new();
    let mut bytes = [0u8; 16];
    for (n, chunk) in bytes.chunks_mut(8).enumerate() {
        let mut h = state.build_hasher();
        h.write_u64(n as u64);
        let word = h.finish().to_be_bytes();
        chunk.copy_from_slice(&word);
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// What can go wrong with Plex beyond what the Jellyfin errors already say (`PlexError`,
/// PlexIdentity.swift:82), plus the request failure of the shared error type.
///
/// The sentences are wording and live in the l10n crate; the German keys are in
/// [`PlexError::text_key`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlexError {
    /// The browser sign-in was not finished in time or the code expired.
    PinExpired,
    /// The profile asks for its PIN, or the PIN was wrong.
    ProfilePinWrong,
    /// plex.tv shows no server for this account.
    NoServer,
    /// No address of the server answered; none of local, remote or relay.
    ServerUnreachable,
    /// A different server answered at the remembered address.
    WrongServer,
    /// The server refuses remote streaming without Plex Pass / Remote Watch Pass.
    RemoteAccessMissing,
    /// The title has no file to play.
    NoFile,
    /// The call has no counterpart on a Plex server.
    Unsupported,
    /// A request failed (the Swift `JellyfinError`).
    Request(ErrorKind),
}

impl From<ErrorKind> for PlexError {
    fn from(kind: ErrorKind) -> Self {
        Self::Request(kind)
    }
}

impl PlexError {
    /// The German source sentence, which is the catalog key (PlexIdentity.swift:98-116).
    /// `None` for [`PlexError::Request`], whose text comes from the shared error.
    pub fn text_key(&self) -> Option<&'static str> {
        Some(match self {
            Self::PinExpired => "Die Anmeldung bei Plex ist abgelaufen. Bitte noch einmal starten.",
            Self::ProfilePinWrong => "Die PIN des Profils stimmt nicht.",
            Self::NoServer => "Zu diesem Plex-Konto gehört kein Server.",
            Self::ServerUnreachable => "Der Plex-Server antwortet unter keiner seiner Adressen.",
            Self::WrongServer => "Unter dieser Adresse meldet sich ein anderer Server.",
            Self::RemoteAccessMissing => {
                "Dieser Server erlaubt das Abspielen von unterwegs nicht. Der Besitzer braucht dafür Plex Pass oder den Remote Watch Pass."
            }
            Self::NoFile => "Zu diesem Titel gibt es keine Datei.",
            Self::Unsupported => "Das kann ein Plex-Server nicht.",
            Self::Request(_) => return None,
        })
    }

    /// The same failure as the shared error type, for the [`MediaServer`] binding. A Plex case
    /// travels as `Transport(Other("plex:<case>"))`; [`PlexError::from_kind`] reads it back.
    ///
    /// [`MediaServer`]: swiftly_playback::media_server::MediaServer
    pub fn into_kind(self) -> ErrorKind {
        let case = match self {
            Self::Request(kind) => return kind,
            Self::PinExpired => "pinExpired",
            Self::ProfilePinWrong => "profilePinWrong",
            Self::NoServer => "noServer",
            Self::ServerUnreachable => "serverUnreachable",
            Self::WrongServer => "wrongServer",
            Self::RemoteAccessMissing => "remoteAccessMissing",
            Self::NoFile => "noFile",
            Self::Unsupported => "unsupported",
        };
        ErrorKind::Transport(TransportReason::Other(format!("plex:{case}")))
    }

    /// Reads a Plex case back from [`PlexError::into_kind`].
    pub fn from_kind(kind: ErrorKind) -> Self {
        if let ErrorKind::Transport(TransportReason::Other(text)) = &kind {
            let case = match text.as_str() {
                "plex:pinExpired" => Some(Self::PinExpired),
                "plex:profilePinWrong" => Some(Self::ProfilePinWrong),
                "plex:noServer" => Some(Self::NoServer),
                "plex:serverUnreachable" => Some(Self::ServerUnreachable),
                "plex:wrongServer" => Some(Self::WrongServer),
                "plex:remoteAccessMissing" => Some(Self::RemoteAccessMissing),
                "plex:noFile" => Some(Self::NoFile),
                "plex:unsupported" => Some(Self::Unsupported),
                _ => None,
            };
            if let Some(case) = case {
                return case;
            }
        }
        Self::Request(kind)
    }
}
