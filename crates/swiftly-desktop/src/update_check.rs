//! The update check of Settings → General: check only, never an install. One enum with all transitions in `reduce`
//! (Idle → Checking → UpToDate | Available | Failed); the real check runs on its own thread and the screen polls
//! [`UpdateCheck::state`] every frame, like the server check.

use std::sync::{Arc, Mutex};
use swiftly_l10n::update as logic;

/// What the "Update" row shows.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum UpdateState {
    /// Nothing asked yet.
    #[default]
    Idle,
    /// A request is on its way.
    Checking,
    /// The running build is the newest.
    UpToDate,
    /// A newer release exists.
    Available {
        /// "1.0.4" without the `v`.
        version: String,
        /// First readable line of the release notes.
        headline: Option<String>,
    },
    /// No usable answer (offline, rate limit, bad reply).
    Failed,
}

/// What can happen to the state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UpdateEvent {
    /// The user asks for a check.
    Ask,
    /// The answer: a newer release, or none.
    Found(Option<(String, Option<String>)>),
    /// No usable answer.
    Broke,
}

/// The one place where the state changes. Illegal events (an answer nobody asked for, a second ask while one runs)
/// leave the state alone.
pub fn reduce(s: &UpdateState, e: UpdateEvent) -> UpdateState {
    use UpdateEvent::*;
    use UpdateState::*;
    match (s, e) {
        (Checking, Ask) => Checking,
        (_, Ask) => Checking,
        (Checking, Found(Some((version, headline)))) => Available { version, headline },
        (Checking, Found(None)) => UpToDate,
        (Checking, Broke) => Failed,
        (other, _) => other.clone(),
    }
}

/// Turns the answer of the releases request into an event (pure, tested).
pub fn outcome(status: u16, body: &[u8], here_version: &str) -> UpdateEvent {
    match logic::parse_latest(status, body, here_version, 0, cfg!(windows)) {
        Ok(found) => UpdateEvent::Found(found.map(|r| {
            let headline = logic::notes_headline(&r.notes);
            (r.version, headline)
        })),
        // A release whose installer is not uploaded yet is no release yet (not "GitHub does not answer").
        Err(logic::UpdateFailure::NoInstaller) => UpdateEvent::Found(None),
        Err(_) => UpdateEvent::Broke,
    }
}

/// The address of the release page the "Update available" row opens.
pub fn release_link() -> &'static str {
    logic::RELEASES_PAGE_URL
}

/// The check the screen owns.
#[derive(Clone, Default)]
pub struct UpdateCheck(Arc<Mutex<UpdateState>>);

impl UpdateCheck {
    /// The current state (cheap).
    pub fn state(&self) -> UpdateState {
        self.0.lock().map(|g| g.clone()).unwrap_or_default()
    }

    fn apply(&self, e: UpdateEvent) {
        if let Ok(mut g) = self.0.lock() {
            *g = reduce(&g, e);
        }
    }

    /// Starts a check; ignored while one runs. Never at start: only on the user's tap.
    pub fn start(&self) {
        if self.state() == UpdateState::Checking {
            return;
        }
        self.apply(UpdateEvent::Ask);
        let me = self.clone();
        std::thread::spawn(move || me.apply(fetch(env!("CARGO_PKG_VERSION"))));
    }

    /// A finished state for tests and scripted screens.
    pub fn with_state(s: UpdateState) -> UpdateCheck {
        UpdateCheck(Arc::new(Mutex::new(s)))
    }
}

fn fetch(version: &str) -> UpdateEvent {
    use swiftly_net::{HttpRequest, HttpTransport, Method, ReqwestTransport, Url};
    let run = || -> Option<UpdateEvent> {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .ok()?;
        let transport = ReqwestTransport::new().ok()?;
        let mut req = HttpRequest::new(Method::Get, Url::parse(logic::LATEST_RELEASE_URL).ok()?);
        for (n, v) in logic::request_headers(version) {
            req.set_header(&n, &v);
        }
        req.timeout = Some(std::time::Duration::from_secs(logic::CHECK_TIMEOUT_SECS));
        let answer = rt.block_on(transport.send(req)).ok()?;
        Some(outcome(answer.status, &answer.body, version))
    };
    run().unwrap_or(UpdateEvent::Broke)
}

#[cfg(test)]
mod tests {
    use super::*;
    use UpdateEvent::*;
    use UpdateState::*;

    fn avail() -> UpdateState {
        Available {
            version: "9.9.9".into(),
            headline: None,
        }
    }

    #[test]
    fn transition_table() {
        let found = || Found(Some(("9.9.9".into(), None)));
        let cases: Vec<(UpdateState, UpdateEvent, UpdateState)> = vec![
            (Idle, Ask, Checking),
            (Checking, Ask, Checking),
            (UpToDate, Ask, Checking),
            (avail(), Ask, Checking),
            (Failed, Ask, Checking),
            (Checking, found(), avail()),
            (Checking, Found(None), UpToDate),
            (Checking, Broke, Failed),
            // Illegal: an answer without a question changes nothing.
            (Idle, found(), Idle),
            (UpToDate, Broke, UpToDate),
            (avail(), Found(None), avail()),
            (Failed, found(), Failed),
        ];
        for (from, ev, to) in cases {
            assert_eq!(reduce(&from, ev.clone()), to, "{from:?} + {ev:?}");
        }
    }

    #[test]
    fn answers_become_events() {
        assert_eq!(outcome(500, b"", "1.0.0"), Broke);
        assert_eq!(outcome(200, b"nonsense", "1.0.0"), Broke);
        let body = br#"{"tag_name":"v99.0.0","body":"Build 5\nNeu: alles","assets":[{"name":"Swiftly-99.0.0-setup.exe","browser_download_url":"https://x/y","size":5}]}"#;
        assert!(matches!(outcome(200, body, "1.0.0"), Found(Some((v, _))) if v == "99.0.0"));
        // Windows: a newer release without its installer yet counts as current.
        let bare = br#"{"tag_name":"v99.0.0","body":"x","assets":[]}"#;
        assert_eq!(
            outcome(200, bare, "1.0.0"),
            if cfg!(windows) {
                Found(None)
            } else {
                Found(Some(("99.0.0".into(), None)))
            }
        );
        let old = br#"{"tag_name":"v0.0.1","body":"x","assets":[]}"#;
        assert_eq!(outcome(200, old, "1.0.0"), Found(None));
    }
}
