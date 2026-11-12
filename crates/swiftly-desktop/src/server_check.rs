//! The server line and "Verbindung prüfen" of Settings > Allgemein (`SettingsView.swift` `server`,
//! `AppModel.connectionCheck`). The page talks to [`ServerCheck`]; the demo uses [`ScriptedCheck`], the real app
//! [`LiveCheck`], which sends a real `System/Info/Public` request on the Core runtime.

use std::sync::{Arc, Mutex};
use swiftly_jellyfin::ServerKind;
use swiftly_l10n::{Locale, Translator};

/// The longest a check may take before the answer is "no answer" (`connectionCheck(deadline: .seconds(12))`).
pub const DEADLINE: f64 = 12.0;

/// What the server line and the check row show.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CheckState {
    /// `serverName` of the last answer.
    pub name: Option<String>,
    /// `serverVersion` of the last answer.
    pub version: Option<String>,
    /// A check is running ("Moment…").
    pub running: bool,
    /// The sentence of the last check; stays until the next one.
    pub result: Option<String>,
}

/// The check as the Settings page uses it.
pub trait ServerCheck {
    /// The current state (polled every frame; cheap).
    fn state(&self) -> CheckState;
    /// Starts a check at time `now` (milliseconds of the screen clock); ignored while one runs.
    fn start(&self, now: f64);
    /// Lets a scripted answer arrive; the real check needs no clock.
    fn tick(&self, _now: f64) {}
}

/// "Erreichbar — Jellyfin 10.10.3".
pub fn reachable(kind: ServerKind, version: Option<&str>) -> String {
    let name = match kind {
        ServerKind::Jellyfin => "Jellyfin",
        ServerKind::Emby => "Emby",
        ServerKind::Plex => "Plex",
    };
    format!("Erreichbar — {name} {}", version.unwrap_or("?"))
}

/// The scripted check of the demo: answers 600 ms after the start with the demo server.
pub struct ScriptedCheck(Mutex<(CheckState, f64)>);

impl ScriptedCheck {
    /// The demo server line is known from the start.
    pub fn new(name: &str, version: &str) -> ScriptedCheck {
        ScriptedCheck(Mutex::new((
            CheckState {
                name: Some(name.to_owned()),
                version: Some(version.to_owned()),
                ..CheckState::default()
            },
            0.0,
        )))
    }
}

impl ScriptedCheck {
    /// No server known yet: the line shows "Server" and "?" (the real app until its first answer).
    pub fn unknown() -> ScriptedCheck {
        ScriptedCheck(Mutex::new((CheckState::default(), 0.0)))
    }
}

impl ServerCheck for ScriptedCheck {
    fn state(&self) -> CheckState {
        self.0.lock().map(|g| g.0.clone()).unwrap_or_default()
    }
    fn start(&self, now: f64) {
        let mut g = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !g.0.running {
            g.0.running = true;
            g.0.result = None;
            g.1 = now + 600.0;
        }
    }
    fn tick(&self, now: f64) {
        let mut g = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if g.0.running && now >= g.1 {
            g.0.running = false;
            let v = g.0.version.clone();
            g.0.result = Some(reachable(ServerKind::Jellyfin, v.as_deref()));
        }
    }
}

/// The real check over the Core runtime.
pub struct LiveCheck {
    core: Arc<crate::live::Core>,
    now: Arc<Mutex<CheckState>>,
}

impl LiveCheck {
    /// Looks the server up once in the background so the line shows its name and version.
    pub fn new(core: Arc<crate::live::Core>) -> LiveCheck {
        let check = LiveCheck {
            core,
            now: Arc::new(Mutex::new(CheckState::default())),
        };
        check.spawn(false);
        check
    }

    /// `shown`: the button was pressed, so the row says "Moment…" and then the sentence.
    fn spawn(&self, shown: bool) {
        let (core, out) = (Arc::clone(&self.core), Arc::clone(&self.now));
        let tr = Translator::new(Locale::parse("de"));
        let Some(account) = core.account() else {
            if shown && let Ok(mut s) = out.lock() {
                s.result = Some(tr.t("Nicht angemeldet."));
            }
            return;
        };
        if shown && let Ok(mut s) = out.lock() {
            s.running = true;
            s.result = None;
        }
        let kind = account.server_kind;
        let worker = Arc::clone(&core);
        core.spawn(async move {
            let answer = match worker.client_for(&account) {
                Ok(client) => match tokio::time::timeout(
                    std::time::Duration::from_secs_f64(DEADLINE),
                    client.public_system_info(),
                )
                .await
                {
                    Ok(Ok(info)) => Ok(info),
                    Ok(Err(e)) => Err(swiftly_l10n::error_text::readable_error(&tr, &e)),
                    Err(_) => Err(tr.t("Der Server hat nicht geantwortet.")),
                },
                Err(e) => Err(swiftly_l10n::error_text::readable_error(&tr, &e)),
            };
            let Ok(mut s) = out.lock() else { return };
            match answer {
                Ok(info) => {
                    if info.server_name.is_some() {
                        s.name = info.server_name.clone();
                    }
                    if info.version.is_some() {
                        s.version = info.version.clone();
                    }
                    if shown {
                        s.result = Some(reachable(kind, info.version.as_deref()));
                    }
                }
                Err(text) if shown => s.result = Some(text),
                Err(_) => {}
            }
            if shown {
                s.running = false;
            }
        });
    }
}

impl ServerCheck for LiveCheck {
    fn state(&self) -> CheckState {
        self.now.lock().map(|g| g.clone()).unwrap_or_default()
    }
    fn start(&self, _now: f64) {
        if self.now.lock().is_ok_and(|s| s.running) {
            return;
        }
        self.spawn(true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scripted_check_runs_for_a_moment_then_answers() {
        let c = ScriptedCheck::new("Kino", "10.10.3");
        assert_eq!(c.state().name.as_deref(), Some("Kino"));
        c.start(1000.0);
        assert!(c.state().running && c.state().result.is_none());
        c.tick(1300.0);
        assert!(c.state().running);
        c.tick(1700.0);
        let s = c.state();
        assert!(!s.running);
        assert_eq!(s.result.as_deref(), Some("Erreichbar — Jellyfin 10.10.3"));
    }
}
