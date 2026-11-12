//! The update check of the desktop apps (`Linux/Sources/SwiftlyLinux/Update.swift`): which
//! release GitHub calls the latest, whether it is newer than the running build, and which
//! attachment is the installer.
//!
//! Sans-I/O: the host sends the request ([`request_headers`], [`LATEST_RELEASE_URL`]) and hands
//! the answer to [`parse_latest`]. **Check only**: nothing here downloads or starts an installer;
//! [`installer_verdict`] and [`installer_file_name`] describe how a host must treat the file it
//! fetches itself. The check runs on request, never at startup (GitHub counts anonymous
//! requests per address, sixty per hour; there is no access token to cut out of a log).

use serde_json::Value;

use crate::version_number::{build_number_from_text, newer};

/// Where the newest release is described. No access token.
pub const LATEST_RELEASE_URL: &str =
    "https://api.github.com/repos/paulherter/swiftly-player/releases/latest";

/// The release page a person can read ("What changes").
pub const RELEASES_PAGE_URL: &str = "https://github.com/paulherter/swiftly-player/releases/latest";

/// Seconds the release query may take (`petition.timeoutInterval`).
pub const CHECK_TIMEOUT_SECS: u64 = 20;

/// Seconds the installer download may take.
pub const DOWNLOAD_TIMEOUT_SECS: u64 = 600;

/// What the host sends with the query. GitHub requires a user agent and answers 403 without.
pub fn request_headers(version: &str) -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_owned(), format!("Swiftly/{version}")),
        (
            "Accept".to_owned(),
            "application/vnd.github+json".to_owned(),
        ),
    ]
}

/// The installer attachment of a release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Installer {
    /// `browser_download_url`.
    pub url: String,
    /// The size GitHub states; 0 when it states none.
    pub size: i64,
    /// The name the file gets on disk ([`installer_file_name`]).
    pub file_name: String,
}

/// A release newer than the running build.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    /// "1.0.4", without the `v` of the tag.
    pub version: String,
    /// The build number the release text names, if it names one.
    pub build: Option<i64>,
    /// What changes, as written on the release page.
    pub notes: String,
    /// The installer; `None` on a platform whose updates come from elsewhere (the Linux package
    /// repository).
    pub installer: Option<Installer>,
}

/// Why a check or a download did not give a usable answer (`Update.Failure`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateFailure {
    /// No 200 or no readable JSON object.
    NoResponse,
    /// The release has no Windows installer attached.
    NoInstaller,
    /// The downloaded file is not as large as GitHub states.
    Incomplete,
}

/// What the check found: `Ok(None)` means there is nothing newer.
///
/// `wants_installer` is true where the app installs itself (Windows): then a newer release
/// without a `-setup.exe` attachment is [`UpdateFailure::NoInstaller`], and the installer is
/// the first attachment whose lower-case name ends in `-setup.exe` (a release also carries
/// `.deb`, `.rpm` and a tarball). Without it the release is reported as it is.
pub fn parse_latest(
    status: u16,
    body: &[u8],
    here_version: &str,
    here_build: i64,
    wants_installer: bool,
) -> Result<Option<Release>, UpdateFailure> {
    if status != 200 {
        return Err(UpdateFailure::NoResponse);
    }
    let Ok(Value::Object(raw)) = serde_json::from_slice::<Value>(body) else {
        return Err(UpdateFailure::NoResponse);
    };
    let tag = raw.get("tag_name").and_then(Value::as_str).unwrap_or("");
    let version = tag.strip_prefix('v').unwrap_or(tag).to_owned();
    let notes = raw
        .get("body")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let build = build_number_from_text(&notes);

    if !newer(&version, here_version, build, here_build) {
        return Ok(None);
    }

    let installer = installer_of(raw.get("assets"), &version);
    if wants_installer && installer.is_none() {
        return Err(UpdateFailure::NoInstaller);
    }
    Ok(Some(Release {
        version,
        build,
        notes,
        installer,
    }))
}

fn installer_of(assets: Option<&Value>, version: &str) -> Option<Installer> {
    let list = assets?.as_array()?;
    let exe = list.iter().find(|a| {
        a.get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_lowercase()
            .ends_with("-setup.exe")
    })?;
    let url = exe.get("browser_download_url")?.as_str()?;
    // The same address rule as `URL(string:)`: an empty or blank string is no address.
    if url.trim().is_empty() {
        return None;
    }
    Some(Installer {
        url: url.to_owned(),
        size: exe.get("size").and_then(Value::as_i64).unwrap_or(0),
        file_name: installer_file_name(version),
    })
}

/// The name the downloaded installer gets in the temporary folder.
pub fn installer_file_name(version: &str) -> String {
    format!("Swiftly-{version}-Setup.exe")
}

/// Whether what came back may be started as the installer. Every response used to be written
/// as `.exe` and executed, including an error page from GitHub (404, 503) or an interrupted
/// transfer. Only a 200 whose size equals the stated one counts; a stated size of 0 or less
/// is not checked.
pub fn installer_verdict(
    status: u16,
    stated_size: i64,
    received: i64,
) -> Result<(), UpdateFailure> {
    if status != 200 {
        return Err(UpdateFailure::NoResponse);
    }
    if stated_size > 0 && received != stated_size {
        return Err(UpdateFailure::Incomplete);
    }
    Ok(())
}

/// The first readable line of the release notes for the row under "What changes": lines are
/// trimmed of blanks, then of `#`, `*`, `-`, bullets and blanks; the first with more than 12
/// characters wins, cut at 120. `None` when no line qualifies (the host shows "Read it on
/// GitHub"). A line break may be `\r\n` (notes edited on the web page carry it).
pub fn notes_headline(notes: &str) -> Option<String> {
    for row in notes.split('\n') {
        let blank = |c: char| c == ' ' || c == '\t' || c == '\r' || c.is_whitespace() && c != '\n';
        let clean = row
            .trim_matches(blank)
            .trim_matches(|c: char| matches!(c, '#' | '*' | '-' | '•' | ' '));
        if clean.chars().count() > 12 {
            return Some(clean.chars().take(120).collect());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(tag: &str, body: &str, assets: &str) -> Vec<u8> {
        format!(r#"{{"tag_name":"{tag}","body":{body:?},"assets":{assets}}}"#).into_bytes()
    }

    const ASSETS: &str = r#"[
        {"name":"swiftly_1.2.0_amd64.deb","browser_download_url":"https://x/deb","size":10},
        {"name":"Swiftly-1.2.0-Setup.exe","browser_download_url":"https://x/setup.exe","size":4096}
    ]"#;

    #[test]
    fn a_newer_release_names_the_installer_not_the_first_attachment() {
        let body = release("v1.2.0", "Build 9\nNew things", ASSETS);
        let got = parse_latest(200, &body, "1.1.0", 5, true).unwrap().unwrap();
        assert_eq!(got.version, "1.2.0");
        assert_eq!(got.build, Some(9));
        let installer = got.installer.unwrap();
        assert_eq!(installer.url, "https://x/setup.exe");
        assert_eq!(installer.size, 4096);
        assert_eq!(installer.file_name, "Swiftly-1.2.0-Setup.exe");
    }

    #[test]
    fn nothing_newer_is_none_even_without_an_installer() {
        let body = release("v1.1.0", "", "[]");
        assert_eq!(parse_latest(200, &body, "1.1.0", 5, true), Ok(None));
        // 1.0.10 against 1.0.9 is a number comparison, not a string one.
        assert!(
            parse_latest(200, &release("1.0.10", "", ASSETS), "1.0.9", 1, true)
                .unwrap()
                .is_some()
        );
        assert_eq!(
            parse_latest(200, &release("1.0.9", "", ASSETS), "1.0.10", 1, true),
            Ok(None)
        );
    }

    #[test]
    fn the_same_version_with_a_higher_build_is_newer() {
        let body = release("v1.1.0", "Build 7", ASSETS);
        assert!(
            parse_latest(200, &body, "1.1.0", 5, true)
                .unwrap()
                .is_some()
        );
        assert_eq!(parse_latest(200, &body, "1.1.0", 7, true), Ok(None));
    }

    #[test]
    fn a_missing_installer_is_a_failure_only_where_the_app_installs() {
        let body = release(
            "v2.0.0",
            "",
            r#"[{"name":"x.tar.gz","browser_download_url":"https://x/t","size":1}]"#,
        );
        assert_eq!(
            parse_latest(200, &body, "1.0.0", 1, true),
            Err(UpdateFailure::NoInstaller)
        );
        let got = parse_latest(200, &body, "1.0.0", 1, false)
            .unwrap()
            .unwrap();
        assert_eq!(got.version, "2.0.0");
        assert!(got.installer.is_none());
        assert_eq!(
            parse_latest(200, &release("v2.0.0", "", "null"), "1.0.0", 1, true),
            Err(UpdateFailure::NoInstaller)
        );
    }

    #[test]
    fn upper_case_names_and_a_missing_size_count() {
        let assets = r#"[{"name":"SWIFTLY-2.0.0-SETUP.EXE","browser_download_url":"https://x/s"}]"#;
        let got = parse_latest(200, &release("v2.0.0", "", assets), "1.0.0", 1, true)
            .unwrap()
            .unwrap();
        assert_eq!(got.installer.unwrap().size, 0);
    }

    #[test]
    fn an_answer_that_is_not_a_release_is_no_response() {
        assert_eq!(
            parse_latest(403, b"{}", "1.0.0", 1, true),
            Err(UpdateFailure::NoResponse)
        );
        assert_eq!(
            parse_latest(200, b"[1]", "1.0.0", 1, true),
            Err(UpdateFailure::NoResponse)
        );
        assert_eq!(
            parse_latest(200, b"not json", "1.0.0", 1, true),
            Err(UpdateFailure::NoResponse)
        );
        // An object without a tag reads as version "" and is never newer.
        assert_eq!(parse_latest(200, b"{}", "1.0.0", 1, true), Ok(None));
    }

    #[test]
    fn the_download_is_only_started_when_it_is_what_github_stated() {
        assert_eq!(installer_verdict(200, 4096, 4096), Ok(()));
        assert_eq!(installer_verdict(200, 0, 17), Ok(()));
        assert_eq!(
            installer_verdict(200, 4096, 17),
            Err(UpdateFailure::Incomplete)
        );
        assert_eq!(
            installer_verdict(503, 4096, 4096),
            Err(UpdateFailure::NoResponse)
        );
    }

    #[test]
    fn the_headline_is_the_first_real_line() {
        assert_eq!(
            notes_headline("## Heading\n\n- short\n* The player remembers the audio track.\n"),
            Some("The player remembers the audio track.".into())
        );
        assert_eq!(notes_headline("short\n twelve chars"), None);
        assert_eq!(notes_headline("123456789012\n"), None);
        assert_eq!(
            notes_headline("1234567890123").as_deref(),
            Some("1234567890123")
        );
        let long = "x".repeat(200);
        assert_eq!(notes_headline(&long).map(|s| s.chars().count()), Some(120));
        assert_eq!(
            notes_headline("x\r\n- A line that is long enough\r\n").as_deref(),
            Some("A line that is long enough")
        );
        assert_eq!(notes_headline(""), None);
    }

    #[test]
    fn the_query_carries_a_user_agent() {
        let h = request_headers("1.2.3");
        assert_eq!(h[0], ("User-Agent".to_owned(), "Swiftly/1.2.3".to_owned()));
        assert_eq!(h[1].1, "application/vnd.github+json");
    }
}
