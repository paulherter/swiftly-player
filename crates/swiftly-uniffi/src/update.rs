//! The update check of the desktop apps (Update.swift on Linux/Windows): the latest GitHub release,
//! whether it is newer than the running build, which attachment is the installer. **Check only**:
//! nothing here downloads or starts an installer. The host that installs fetches the file itself
//! (so Windows sets no web mark on it) and asks [`update_installer_verdict`] before starting it.

use std::time::Duration;

use swiftly_l10n::update as logic;
use swiftly_net::{HttpRequest, HttpTransport, Method, Url};

use crate::core::Core;
use crate::error::CoreError;
use crate::transport::{NetHeader, NetMethod, NetRequest};

/// Why a check or a download gave no usable answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum UpdateError {
    /// No 200 or no readable release.
    NoResponse,
    /// The release has no Windows installer attached.
    NoInstaller,
    /// The downloaded file is smaller or larger than GitHub states.
    Incomplete,
}

impl std::fmt::Display for UpdateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::NoResponse => "no response",
            Self::NoInstaller => "no installer",
            Self::Incomplete => "incomplete download",
        })
    }
}

impl std::error::Error for UpdateError {}

impl From<logic::UpdateFailure> for UpdateError {
    fn from(f: logic::UpdateFailure) -> Self {
        match f {
            logic::UpdateFailure::NoResponse => Self::NoResponse,
            logic::UpdateFailure::NoInstaller => Self::NoInstaller,
            logic::UpdateFailure::Incomplete => Self::Incomplete,
        }
    }
}

/// The installer attachment of a release.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UpdateInstaller {
    /// Where to fetch it.
    pub url: String,
    /// The size GitHub states, 0 if none.
    pub size: i64,
    /// The name the file gets in the temporary folder.
    pub file_name: String,
}

/// A release newer than the running build.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UpdateRelease {
    /// "1.0.4" without the `v`.
    pub version: String,
    /// The build number the release text names.
    pub build: Option<i64>,
    /// The release text.
    pub notes: String,
    /// The first readable line of the text for a row, if there is one.
    pub headline: Option<String>,
    /// The installer; none where updates come from elsewhere.
    pub installer: Option<UpdateInstaller>,
}

impl From<logic::Release> for UpdateRelease {
    fn from(r: logic::Release) -> Self {
        Self {
            headline: logic::notes_headline(&r.notes),
            version: r.version,
            build: r.build,
            notes: r.notes,
            installer: r.installer.map(|i| UpdateInstaller {
                url: i.url,
                size: i.size,
                file_name: i.file_name,
            }),
        }
    }
}

/// The request for the latest release (GET, user agent, 20 s) for a host that sends it itself.
#[uniffi::export]
pub fn update_request(version: String) -> NetRequest {
    NetRequest {
        method: NetMethod::Get,
        url: logic::LATEST_RELEASE_URL.to_owned(),
        headers: logic::request_headers(&version)
            .into_iter()
            .map(|(name, value)| NetHeader { name, value })
            .collect(),
        body: None,
        timeout_ms: Some(logic::CHECK_TIMEOUT_SECS * 1000),
        keep_method: false,
    }
}

/// The answer to [`update_request`]: `None` when nothing is newer. `wants_installer` is true
/// where the app installs itself (Windows): a newer release without installer is then an error.
#[uniffi::export]
pub fn update_parse_latest(
    status: u16,
    body: Vec<u8>,
    here_version: String,
    here_build: i64,
    wants_installer: bool,
) -> Result<Option<UpdateRelease>, UpdateError> {
    Ok(
        logic::parse_latest(status, &body, &here_version, here_build, wants_installer)?
            .map(Into::into),
    )
}

/// Whether a downloaded file may be started as the installer (200 and the size GitHub stated).
#[uniffi::export]
pub fn update_installer_verdict(
    status: u16,
    stated_size: i64,
    received: i64,
) -> Result<(), UpdateError> {
    Ok(logic::installer_verdict(status, stated_size, received)?)
}

/// The first readable line of release notes for a row ("Read it on GitHub" when `None`).
#[uniffi::export]
pub fn update_notes_headline(notes: String) -> Option<String> {
    logic::notes_headline(&notes)
}

/// The page a person reads the changes on.
#[uniffi::export]
pub fn update_releases_page() -> String {
    logic::RELEASES_PAGE_URL.to_owned()
}

/// Seconds the installer download may take.
#[uniffi::export]
pub fn update_download_timeout_seconds() -> u64 {
    logic::DOWNLOAD_TIMEOUT_SECS
}

#[uniffi::export]
impl Core {
    /// Asks GitHub for the latest release through the host's HTTP. On request only, never at
    /// start. `None` means nothing newer.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn check_for_update(
        &self,
        here_version: String,
        here_build: i64,
        wants_installer: bool,
    ) -> Result<Option<UpdateRelease>, CoreError> {
        let transport = self.transport_handle();
        let url = Url::parse(logic::LATEST_RELEASE_URL).map_err(|_| CoreError::Failed {
            message: "bad address".into(),
        })?;
        let mut request = HttpRequest::new(Method::Get, url);
        for (name, value) in logic::request_headers(&here_version) {
            request.set_header(&name, &value);
        }
        request.timeout = Some(Duration::from_secs(logic::CHECK_TIMEOUT_SECS));
        let answer = transport.send(request).await.map_err(CoreError::from)?;
        logic::parse_latest(
            answer.status,
            &answer.body,
            &here_version,
            here_build,
            wants_installer,
        )
        .map(|found| found.map(Into::into))
        .map_err(|e| CoreError::Failed {
            message: UpdateError::from(e).to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_request_is_a_get_with_a_user_agent_and_a_timeout() {
        let r = update_request("1.2.3".into());
        assert!(matches!(r.method, NetMethod::Get));
        assert!(r.url.ends_with("/releases/latest"));
        assert_eq!(r.headers[0].value, "Swiftly/1.2.3");
        assert_eq!(r.timeout_ms, Some(20_000));
    }

    #[test]
    fn a_newer_release_comes_out_with_installer_and_headline() {
        let body = br###"{"tag_name":"v2.0.0","body":"## Big\n- The player is faster than before","assets":[{"name":"Swiftly-2.0.0-Setup.exe","browser_download_url":"https://x/s.exe","size":9}]}"###;
        let got = update_parse_latest(200, body.to_vec(), "1.0.0".into(), 1, true)
            .unwrap()
            .unwrap();
        assert_eq!(got.version, "2.0.0");
        assert_eq!(
            got.headline.as_deref(),
            Some("The player is faster than before")
        );
        assert_eq!(got.installer.unwrap().file_name, "Swiftly-2.0.0-Setup.exe");
        assert_eq!(
            update_parse_latest(200, body.to_vec(), "2.0.0".into(), 1, true),
            Ok(None)
        );
        assert_eq!(
            update_parse_latest(500, body.to_vec(), "1.0.0".into(), 1, true),
            Err(UpdateError::NoResponse)
        );
        assert_eq!(
            update_installer_verdict(200, 9, 4),
            Err(UpdateError::Incomplete)
        );
    }
}
