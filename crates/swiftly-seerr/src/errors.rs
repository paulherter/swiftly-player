//! Typed outcomes of a failed Seerr call. Every call of the client returns these, so the UI can say
//! "quota used up", "not allowed", "blocklisted", "sign in again" or "already requested" instead of
//! one generic line.

use swiftly_net::ErrorKind;

/// Why a call did not work.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AskError {
    /// 403 with the server's quota text (`Movie Quota exceeded.`, ...).
    QuotaExceeded(String),
    /// 403: the account may not do this.
    NoPermission,
    /// 403: the title is on the blocklist.
    Blocked,
    /// 409 on a new request: someone asked for it before (a duplicate, not a success).
    Exists,
    /// 202 on a new request: no season is left to ask for.
    NoSeasons,
    /// 401, or 403 without a reason in the body: the session is gone, sign in again.
    SessionLost,
    /// 404.
    NotFound,
    /// 409 on another call (a request that is no longer pending, ...), with the server's text.
    Conflict(String),
    /// Another status of the server, with its text (`message`, else the first bytes).
    Failed {
        /// The HTTP status.
        status: u16,
        /// The text.
        text: String,
    },
    /// No answer (offline, TLS, ...), or an answer that is not what the call expects.
    Network(ErrorKind),
}

fn message_of(body: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    ["message", "error"]
        .iter()
        .find_map(|k| v.get(k).and_then(|m| m.as_str()))
        .map(str::to_string)
}

impl AskError {
    /// Sorts an answer outside 2xx. `creating` is true for the `POST request` that makes a request:
    /// there 409 means "already requested".
    ///
    /// Seerr answers 403 with `{"message": ...}` for a refused request (quota, permission,
    /// blocklist) and with `{"status":403,"error": ...}` (or nothing) when the session is invalid.
    pub fn from_answer(status: u16, body: &str, creating: bool) -> Self {
        let text = message_of(body);
        match status {
            401 => Self::SessionLost,
            403 => {
                let has_message = serde_json::from_str::<serde_json::Value>(body)
                    .ok()
                    .is_some_and(|v| v.get("message").is_some());
                let lower = text.as_deref().unwrap_or("").to_lowercase();
                if lower.contains("quota") {
                    Self::QuotaExceeded(text.unwrap_or_default())
                } else if lower.contains("blocklist") || lower.contains("blacklist") {
                    Self::Blocked
                } else if has_message {
                    Self::NoPermission
                } else {
                    Self::SessionLost
                }
            }
            404 => Self::NotFound,
            409 if creating => Self::Exists,
            409 => Self::Conflict(text.unwrap_or_default()),
            _ => Self::Failed {
                status,
                text: text.unwrap_or_else(|| {
                    let t: String = body.chars().take(200).collect();
                    if t.is_empty() {
                        format!("HTTP {status}")
                    } else {
                        t
                    }
                }),
            },
        }
    }

    /// The server's own text for the quota / conflict / failure cases.
    pub fn server_text(&self) -> Option<&str> {
        match self {
            Self::QuotaExceeded(t) | Self::Conflict(t) | Self::Failed { text: t, .. }
                if !t.is_empty() =>
            {
                Some(t)
            }
            _ => None,
        }
    }

    /// True when the session has to be renewed before anything else.
    pub fn is_session_lost(&self) -> bool {
        matches!(self, Self::SessionLost)
    }

    /// The same failure as the transport's error kind (for callers that only know that).
    pub fn into_kind(self) -> ErrorKind {
        match self {
            Self::Network(k) => k,
            Self::SessionLost => ErrorKind::Transport(swiftly_net::TransportReason::Other(
                "Deine Seerr-Anmeldung gilt nicht mehr.".into(),
            )),
            Self::NoPermission => ErrorKind::Transport(swiftly_net::TransportReason::Other(
                "Dafür fehlt deinem Konto die Berechtigung.".into(),
            )),
            Self::Blocked => ErrorKind::Transport(swiftly_net::TransportReason::Other(
                "Dieser Titel ist gesperrt.".into(),
            )),
            Self::QuotaExceeded(t) | Self::Conflict(t) => {
                ErrorKind::Transport(swiftly_net::TransportReason::Other(t))
            }
            Self::Failed { status, text } => ErrorKind::Http {
                status,
                body: Some(text),
            },
            Self::Exists => ErrorKind::Http {
                status: 409,
                body: None,
            },
            Self::NoSeasons => ErrorKind::Http {
                status: 202,
                body: None,
            },
            Self::NotFound => ErrorKind::Http {
                status: 404,
                body: None,
            },
        }
    }
}

impl std::fmt::Display for AskError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::QuotaExceeded(t) | Self::Conflict(t) | Self::Failed { text: t, .. } => {
                f.write_str(t)
            }
            Self::NoPermission => f.write_str("no permission"),
            Self::Blocked => f.write_str("blocklisted"),
            Self::Exists => f.write_str("already requested"),
            Self::NoSeasons => f.write_str("no season left to request"),
            Self::SessionLost => f.write_str("session invalid"),
            Self::NotFound => f.write_str("not found"),
            Self::Network(k) => write!(f, "{k:?}"),
        }
    }
}

impl std::error::Error for AskError {}
