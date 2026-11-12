//! Quick Connect, the approving side (`QuickConnect.swift`): this device is signed in and
//! authorizes the code another device shows.

use swiftly_net::{ErrorKind, HttpTransport, Method, TransportReason};
use unicode_segmentation::UnicodeSegmentation;

use crate::client::{JellyfinClient, Query};

impl<T: HttpTransport> JellyfinClient<T> {
    /// `GET QuickConnect/Enabled` (`quickConnectAddBar`): whether the server offers Quick
    /// Connect at all. Any failure, a 503 (switched off) or a non-200 is `false`.
    pub async fn quick_connect_enabled(&self) -> bool {
        let Ok(req) = self.get("QuickConnect/Enabled", &Query::new()) else {
            return false;
        };
        let Ok(response) = self.execute(req).await else {
            return false;
        };
        response.status == 200
            && String::from_utf8_lossy(&response.body)
                .to_lowercase()
                .contains("true")
    }

    /// `POST QuickConnect/Authorize?code=` (`quickConnectShare`): approves a code shown on
    /// another device.
    ///
    /// No `userId` is sent: the signed-in user applies, and setting it would ask the server for
    /// access to that user (403 "Unknown user id"). A session is still required, without a
    /// token the call has no sender.
    ///
    /// # Errors
    /// [`ErrorKind::NotAuthenticated`] without a session; "Der Code ist zu kurz." for fewer than
    /// four characters; [`ErrorKind::QuickConnectExpired`] when the server answers `false`;
    /// "Der Server hat die Freigabe abgelehnt." on 403; `QuickConnectDisabled` on 503; any
    /// other status as [`ErrorKind::Http`] with the first 200 bytes.
    pub async fn quick_connect_share(&self, code: &str) -> Result<(), ErrorKind> {
        self.require_session()?;
        let clean = code.trim();
        if clean.graphemes(true).count() < 4 {
            return Err(ErrorKind::Transport(TransportReason::Other(
                "Der Code ist zu kurz.".into(),
            )));
        }
        let q = Query::new().add("code", clean);
        let req = self.request("QuickConnect/Authorize", Method::Post, &q, None)?;
        let response = self.execute(req).await?;
        match response.status {
            200 => {
                if String::from_utf8_lossy(&response.body)
                    .to_lowercase()
                    .contains("false")
                {
                    return Err(ErrorKind::QuickConnectExpired);
                }
                Ok(())
            }
            403 => Err(ErrorKind::Transport(TransportReason::Other(
                "Der Server hat die Freigabe abgelehnt.".into(),
            ))),
            503 => Err(ErrorKind::Transport(TransportReason::QuickConnectDisabled)),
            status => Err(ErrorKind::Http {
                status,
                body: response.text_prefix(200),
            }),
        }
    }
}
