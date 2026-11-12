use serde::{Deserialize, Serialize};
use swiftly_net::{ErrorKind, HttpTransport, Method, TransportReason, Url};

use crate::client::{JellyfinClient, Query};
use crate::query::build_url;
use crate::session::Session;

/// A user from the public list (`PublicUser`, Login.swift:9-20).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublicUser {
    /// User id.
    #[serde(rename = "Id")]
    pub id: String,
    /// User name.
    #[serde(rename = "Name")]
    pub name: String,
    /// Tag of the profile picture.
    #[serde(
        rename = "PrimaryImageTag",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub image_mark: Option<String>,
}

/// What Quick Connect hands out: the code the user types elsewhere, and the secret that only
/// this device holds (`LoginCode`, Login.swift:23-28).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoginCode {
    /// The short code to show.
    pub code: String,
    /// The secret for polling and sign-in.
    pub confidential: String,
}

/// State of the Quick Connect wait (`QuickConnectState`, Login.swift:160-181).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuickConnectState {
    /// Waiting for approval (`offen`).
    Opened,
    /// Approved elsewhere (`freigegeben`).
    Released,
    /// The code ran out (`abgelaufen`).
    Expired,
    /// The question failed (`gescheitert`).
    Failed,
}

impl QuickConnectState {
    /// The state a failed question stands for: an expired code, or a plain failure.
    pub fn from_error(error: &ErrorKind) -> Self {
        if *error == ErrorKind::QuickConnectExpired {
            Self::Expired
        } else {
            Self::Failed
        }
    }

    /// Does this state end the wait? A network error does not, the next tick asks again.
    pub fn ended_wait(self) -> bool {
        matches!(self, Self::Released | Self::Expired)
    }
}

/// Timing of the Quick Connect wait (`QuickConnectDeadline`, Login.swift:140-158).
pub struct QuickConnectDeadline;

impl QuickConnectDeadline {
    /// The code lives five minutes.
    pub const SECONDS: u64 = 300;
    /// Ask every two seconds.
    pub const TICK: u64 = 2;

    /// How often to ask in all.
    pub const fn attempts() -> u64 {
        Self::SECONDS / Self::TICK
    }

    /// Does the closing text say "server did not answer" (last state failed) or "code expired"?
    pub fn end_is_failure(last: QuickConnectState) -> bool {
        last == QuickConnectState::Failed
    }
}

impl<T: HttpTransport> JellyfinClient<T> {
    /// `GET Users/Public` (Login.swift:34). Anything but a readable 200 is an empty list: the
    /// server may have turned the list off, and then the user types the name.
    pub async fn public_users(&self) -> Result<Vec<PublicUser>, ErrorKind> {
        let req = self.get("Users/Public", &Query::new())?;
        let response = self.execute(req).await?;
        if response.status != 200 {
            return Ok(Vec::new());
        }
        Ok(serde_json::from_slice(&response.body).unwrap_or_default())
    }

    /// The profile picture address (`userImage`, Login.swift:57-65).
    pub fn user_image(&self, user: &PublicUser, border: i64) -> Option<Url> {
        let mark = user.image_mark.as_ref()?;
        let q = Query::new()
            .add("tag", mark)
            .add("fillWidth", border)
            .add("quality", 90);
        build_url(
            &self.base_url,
            &format!("Users/{}/Images/Primary", user.id),
            &q.0,
        )
    }

    /// `POST QuickConnect/Initiate` (Login.swift:74). 503 means the server turned it off.
    pub async fn quick_connect_start(&self) -> Result<LoginCode, ErrorKind> {
        #[derive(Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Reply {
            secret: String,
            code: String,
        }
        let req = self.request("QuickConnect/Initiate", Method::Post, &Query::new(), None)?;
        let response = self.execute(req).await?;
        if response.status != 200 {
            if response.status == 503 {
                return Err(ErrorKind::Transport(TransportReason::QuickConnectDisabled));
            }
            return Err(ErrorKind::Http {
                status: response.status,
                body: response.text_prefix(200),
            });
        }
        let reply: Reply = serde_json::from_slice(&response.body)
            .map_err(|e| ErrorKind::Decoding(e.to_string()))?;
        Ok(LoginCode {
            code: reply.code,
            confidential: reply.secret,
        })
    }

    /// `GET QuickConnect/Connect?secret` (Login.swift:98): has the code been approved? A 404
    /// means the code is gone ([`ErrorKind::QuickConnectExpired`]); other failures are `false`.
    pub async fn quick_connect_released(&self, code: &LoginCode) -> Result<bool, ErrorKind> {
        #[derive(Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Reply {
            authenticated: bool,
        }
        let q = Query::new().add("secret", &code.confidential);
        let response = self.execute(self.get("QuickConnect/Connect", &q)?).await?;
        if response.status == 404 {
            return Err(ErrorKind::QuickConnectExpired);
        }
        if response.status != 200 {
            return Ok(false);
        }
        Ok(serde_json::from_slice::<Reply>(&response.body).is_ok_and(|r| r.authenticated))
    }

    /// One poll as a state (`quickConnectAskAgain`, Login.swift:118).
    pub async fn quick_connect_ask_again(&self, code: &LoginCode) -> QuickConnectState {
        match self.quick_connect_released(code).await {
            Ok(true) => QuickConnectState::Released,
            Ok(false) => QuickConnectState::Opened,
            Err(e) => QuickConnectState::from_error(&e),
        }
    }

    /// `POST Users/AuthenticateWithQuickConnect {Secret}` (Login.swift:131). Sets the session.
    pub async fn sign_in_with_quick_connect(&self, code: &LoginCode) -> Result<Session, ErrorKind> {
        #[derive(Serialize)]
        #[serde(rename_all = "PascalCase")]
        struct Shell<'a> {
            secret: &'a str,
        }
        self.sign_in_with(
            "Users/AuthenticateWithQuickConnect",
            &Shell {
                secret: &code.confidential,
            },
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // QuickConnectStateTests.swift
    #[test]
    fn expired_code_ends_the_wait() {
        let state = QuickConnectState::from_error(&ErrorKind::QuickConnectExpired);
        assert_eq!(state, QuickConnectState::Expired);
        assert!(state.ended_wait());
    }

    #[test]
    fn network_error_does_not_end_the_wait() {
        for code in [-1001, -1003, -1004, -1005, -1009] {
            let state = QuickConnectState::from_error(&ErrorKind::Network { code });
            assert_eq!(state, QuickConnectState::Failed);
            assert!(!state.ended_wait());
        }
    }

    #[test]
    fn released_ends_opened_does_not() {
        assert!(QuickConnectState::Released.ended_wait());
        assert!(!QuickConnectState::Opened.ended_wait());
    }

    #[test]
    fn end_text_distinguishes_network_and_deadline() {
        assert!(QuickConnectDeadline::end_is_failure(
            QuickConnectState::Failed
        ));
        assert!(!QuickConnectDeadline::end_is_failure(
            QuickConnectState::Expired
        ));
        assert!(!QuickConnectDeadline::end_is_failure(
            QuickConnectState::Opened
        ));
        assert_eq!(QuickConnectDeadline::attempts(), 150);
    }
}
