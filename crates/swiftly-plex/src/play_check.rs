//! **The Plex play check as an explicit state machine.** When the file at `Part.key` is refused
//! with `500` (a server that caps the remote bitrate, Plezy #2909), the host asks the server once
//! ([`crate::PlexDecision`]) whether the file may go out as it is. One enum, all moves in
//! [`reduce`]; every other event is ignored in a state that cannot use it.
//!
//! ```text
//! Idle --FileRefused(500)--> Asking --Verdict(yes)--> Allowed   (the refusal was not final: retry the file)
//!                              |  \--Verdict(no)---> Refused    (show the server's reason)
//!                              \-----AskFailed-----> Unknown    (no answer: show the file error)
//! any --Reset--> Idle;   Idle --FileRefused(other)--> Idle
//! ```
//! Swift never asks (the plan is always `Part.key`), so there is no oracle; the table below is
//! the specification.

use crate::PlexDecision;

/// Where the check stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlayCheck {
    /// Nothing asked.
    Idle,
    /// The server is being asked.
    Asking,
    /// The server lets the file go out as it is.
    Allowed,
    /// The server says no; `reason` is its text when it gave one.
    Refused {
        /// The server's own words.
        reason: Option<String>,
    },
    /// The question got no usable answer.
    Unknown,
}

/// What happened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlayCheckEvent {
    /// The file answered with this HTTP status.
    FileRefused {
        /// The HTTP status.
        status: u16,
    },
    /// The server answered the question.
    Verdict(PlexDecision),
    /// The question failed (offline, undecodable).
    AskFailed,
    /// A new title or a new try.
    Reset,
}

/// What the host has to do next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayCheckEffect {
    /// Nothing.
    None,
    /// Send the decision request and feed the answer back.
    Ask,
}

/// The only status that starts a question.
pub const ASK_STATUS: u16 = 500;

/// One move of the machine.
pub fn reduce(state: PlayCheck, event: PlayCheckEvent) -> (PlayCheck, PlayCheckEffect) {
    use PlayCheck::{Allowed, Asking, Idle, Refused, Unknown};
    match (state, event) {
        (_, PlayCheckEvent::Reset) => (Idle, PlayCheckEffect::None),
        (Idle, PlayCheckEvent::FileRefused { status }) if status == ASK_STATUS => {
            (Asking, PlayCheckEffect::Ask)
        }
        (Asking, PlayCheckEvent::Verdict(d)) => {
            if d.allows_direct_play() {
                (Allowed, PlayCheckEffect::None)
            } else {
                let reason = d
                    .direct_play_text
                    .or(d.general_text)
                    .filter(|t| !t.is_empty());
                (Refused { reason }, PlayCheckEffect::None)
            }
        }
        (Asking, PlayCheckEvent::AskFailed) => (Unknown, PlayCheckEffect::None),
        (state, _) => (state, PlayCheckEffect::None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(code: Option<i64>, text: Option<&str>) -> PlexDecision {
        PlexDecision {
            general_code: None,
            direct_play_code: code,
            general_text: None,
            direct_play_text: text.map(Into::into),
        }
    }

    #[test]
    fn transition_table() {
        use PlayCheck::*;
        use PlayCheckEvent as E;
        let no = Some("Not enough bandwidth");
        let table: Vec<(PlayCheck, E, PlayCheck, PlayCheckEffect)> = vec![
            (
                Idle,
                E::FileRefused { status: 500 },
                Asking,
                PlayCheckEffect::Ask,
            ),
            (
                Idle,
                E::FileRefused { status: 404 },
                Idle,
                PlayCheckEffect::None,
            ),
            (
                Idle,
                E::Verdict(d(Some(1000), None)),
                Idle,
                PlayCheckEffect::None,
            ),
            (Idle, E::AskFailed, Idle, PlayCheckEffect::None),
            (
                Asking,
                E::Verdict(d(Some(1000), None)),
                Allowed,
                PlayCheckEffect::None,
            ),
            (
                Asking,
                E::Verdict(d(Some(2000), no)),
                Refused {
                    reason: no.map(Into::into),
                },
                PlayCheckEffect::None,
            ),
            (
                Asking,
                E::Verdict(d(Some(2000), Some(""))),
                Refused { reason: None },
                PlayCheckEffect::None,
            ),
            (
                Asking,
                E::Verdict(d(None, None)),
                Refused { reason: None },
                PlayCheckEffect::None,
            ),
            (Asking, E::AskFailed, Unknown, PlayCheckEffect::None),
            (
                Asking,
                E::FileRefused { status: 500 },
                Asking,
                PlayCheckEffect::None,
            ),
            (
                Allowed,
                E::FileRefused { status: 500 },
                Allowed,
                PlayCheckEffect::None,
            ),
            (Allowed, E::AskFailed, Allowed, PlayCheckEffect::None),
            (
                Refused { reason: None },
                E::Verdict(d(Some(1000), None)),
                Refused { reason: None },
                PlayCheckEffect::None,
            ),
            (
                Unknown,
                E::FileRefused { status: 500 },
                Unknown,
                PlayCheckEffect::None,
            ),
            (Allowed, E::Reset, Idle, PlayCheckEffect::None),
            (
                Refused { reason: None },
                E::Reset,
                Idle,
                PlayCheckEffect::None,
            ),
            (Unknown, E::Reset, Idle, PlayCheckEffect::None),
            (Asking, E::Reset, Idle, PlayCheckEffect::None),
        ];
        for (from, event, to, effect) in table {
            let label = format!("{from:?} + {event:?}");
            assert_eq!(reduce(from, event), (to, effect), "{label}");
        }
    }
}
