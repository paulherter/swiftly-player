//! The polling and hand-over flow of `TakeoverModel.swift` as ONE explicit state machine.
//!
//! Sans-I/O: [`reduce`] takes the state and an [`Event`] and returns the next state plus the
//! [`Effect`]s the host has to run (a request, a sleep, a log line). The host (Swift, Kotlin)
//! only does the network and player plumbing and feeds the results back as events.
//!
//! The card the user sees is [`crate::takeover::TakeoverOffer`]; this machine decides *when*
//! to ask, what to do with the answer and in which order the hand-over steps run.
//!
//! ```text
//! Stopped --Start--> Quiet --Tick--> Asking --Answered/AskFailed--> Quiet
//! Quiet|Asking --Adopt--> Preparing --Prepared--> Hinting --HintDone--> Stopping
//!   --StopAccepted--> Settling (max 15 x 100 ms) --Position changed / tries used--> Quiet + Start
//! any --Finish--> Stopped
//! ```

use swiftly_jellyfin::RemoteSession;

use crate::takeover::{offerings, start_point, takes_hint, why_not};

/// How often the host asks the server (seconds).
pub const TICK_SECONDS: f64 = 5.0;
/// How often the saved position is read while the other device stops.
pub const SETTLE_TRIES: u8 = 15;
/// Pause between two reads (milliseconds).
pub const SETTLE_STEP_MS: u32 = 100;

/// The hand-over in progress: what is known about the session being taken over.
#[derive(Debug, Clone, PartialEq)]
pub struct Adoption {
    /// The session handed over from.
    pub session: RemoteSession,
    /// The item's saved position before the other device stopped (ticks).
    pub before: Option<i64>,
    /// The freshest position of the session (seconds).
    pub session_point: f64,
}

/// The one state of the flow.
#[derive(Debug, Clone, PartialEq)]
pub enum Flow {
    /// Not polling (sign-out, view gone).
    Stopped,
    /// Waiting for the next tick. `last_reason` is the last "nothing offered" line written.
    Quiet {
        /// The last reason line, so the same one is not logged every tick.
        last_reason: Option<String>,
    },
    /// The sessions request is in flight.
    Asking {
        /// As in [`Flow::Quiet`].
        last_reason: Option<String>,
    },
    /// Plan, saved item and fresh sessions are being fetched after the tap.
    Preparing(Box<RemoteSession>),
    /// The hint to the sender is being sent (only for a session that understands it).
    Hinting(Box<Adoption>),
    /// The sender is told to stop.
    Stopping(Box<Adoption>),
    /// Waiting for the sender's exact stop position to show up on the item.
    Settling {
        /// The hand-over.
        adoption: Box<Adoption>,
        /// Reads done so far.
        tries: u8,
    },
}

/// What the host reports.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// Polling starts (sign-in, view appears).
    Start,
    /// Polling stops (sign-out, view gone).
    Finish,
    /// The timer fired. `player_runs`: something plays here, so no question is asked.
    /// `signed_in`: a server and a user exist.
    Tick {
        /// Is the player running?
        player_runs: bool,
        /// Are server and user known?
        signed_in: bool,
    },
    /// The sessions answer.
    Answered {
        /// All sessions of the account.
        sessions: Vec<RemoteSession>,
        /// Seconds since 1970.
        now: f64,
    },
    /// The request failed, with the error text for the log.
    AskFailed(String),
    /// The user chose a session to take over.
    Adopt(Box<RemoteSession>),
    /// Plan, saved item and sessions arrived.
    Prepared {
        /// Was a playback plan obtained?
        plan: bool,
        /// Saved position of the item before the stop (ticks).
        saved_before: Option<i64>,
        /// The session's position from the fresh sessions answer (seconds), if it was in there.
        fresh_point: Option<f64>,
    },
    /// The hint was sent, or failed (logged, never fatal).
    HintDone {
        /// Error text if it failed.
        error: Option<String>,
    },
    /// The stop was accepted by the server.
    StopAccepted,
    /// The stop was refused or the request failed (readable text).
    StopFailed(String),
    /// A read of the item's saved position (ticks).
    Position(Option<i64>),
}

/// What the host has to do.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Request all sessions.
    Ask,
    /// Our own session is missing on the server: report the capabilities again.
    ReportCapabilities,
    /// These can be taken over now (most recent first). Empty clears the badge.
    Offer(Vec<RemoteSession>),
    /// All sessions, for the "play on" list.
    PublishSessions(Vec<RemoteSession>),
    /// Fill the image cache for these offerings (first two).
    Preload(Vec<RemoteSession>),
    /// Write a line to the log.
    Log(String),
    /// Fetch plan, saved item and sessions for this item id.
    Prepare {
        /// The item that plays on the other device.
        item_id: String,
    },
    /// Send the takeover hint to this session id.
    SendHint {
        /// Session id.
        session_id: String,
    },
    /// Tell this session id to stop.
    SendStop {
        /// Session id.
        session_id: String,
    },
    /// Sleep [`SETTLE_STEP_MS`], then read the item's saved position and answer [`Event::Position`].
    ReadPosition {
        /// The item id.
        item_id: String,
    },
    /// Start playing here at `since` seconds; the badge goes.
    Play {
        /// The item id.
        item_id: String,
        /// Start point in seconds.
        since: f64,
        /// Was the sender's stop position never reported?
        position_unreported: bool,
        /// Position of the session at the tap (seconds), for the log.
        session_point: f64,
    },
    /// No playback plan: show "the server sent no data".
    NoPlan,
    /// Show this error (stop failed).
    ShowError(String),
}

/// The pure transition. Events that do not fit the state are ignored (state unchanged, no
/// effects), so late answers after `Finish` or a double tap do nothing.
pub fn reduce(
    state: Flow,
    event: Event,
    own_device_id: &str,
    own_user_id: &str,
) -> (Flow, Vec<Effect>) {
    use Effect as X;
    use Event as E;
    use Flow as S;
    match (state, event) {
        (_, E::Finish) => (S::Stopped, vec![X::Offer(vec![])]),
        (S::Stopped, E::Start) => (S::Quiet { last_reason: None }, vec![]),
        (
            S::Quiet { last_reason },
            E::Tick {
                player_runs,
                signed_in,
            },
        ) => {
            // Whoever is watching does not ask.
            if player_runs {
                (S::Quiet { last_reason }, vec![])
            } else if !signed_in {
                (S::Quiet { last_reason }, vec![X::Offer(vec![])])
            } else {
                (S::Asking { last_reason }, vec![X::Ask])
            }
        }
        (S::Asking { last_reason }, E::AskFailed(error)) => (
            S::Quiet { last_reason },
            vec![
                X::Log(format!("[Uebernahme] Abfrage fehlgeschlagen: {error}")),
                X::Offer(vec![]),
            ],
        ),
        (S::Asking { last_reason }, E::Answered { sessions, now }) => {
            let mut fx = vec![];
            if !sessions
                .iter()
                .any(|s| s.device_id.as_deref() == Some(own_device_id))
            {
                fx.push(X::Log(
                    "[Abspielen auf] eigene Sitzung fehlt, Fähigkeiten neu gemeldet".into(),
                ));
                fx.push(X::ReportCapabilities);
            }
            let list: Vec<RemoteSession> = offerings(&sessions, own_device_id, own_user_id, now)
                .into_iter()
                .cloned()
                .collect();
            fx.push(X::Offer(list.clone()));
            fx.push(X::PublishSessions(sessions.clone()));
            let last_reason = if list.is_empty() {
                let grounds: Vec<String> = sessions
                    .iter()
                    .map(|s| {
                        let who = s
                            .device_name
                            .as_deref()
                            .or(s.program.as_deref())
                            .unwrap_or("?");
                        let why = why_not(s, own_device_id, own_user_id, now)
                            .unwrap_or_else(|| "taugt".into());
                        format!("{who}: {why}")
                    })
                    .collect();
                let row = format!("[Uebernahme] {} Sitzungen, kein Angebot", sessions.len())
                    + &if grounds.is_empty() {
                        String::new()
                    } else {
                        format!(" — {}", grounds.join(" · "))
                    };
                // Only on change: it asks every few seconds and the answer is mostly the same.
                if last_reason.as_deref() != Some(row.as_str()) {
                    fx.push(X::Log(row.clone()));
                }
                Some(row)
            } else {
                fx.push(X::Preload(list.into_iter().take(2).collect()));
                None
            };
            (S::Quiet { last_reason }, fx)
        }
        (S::Quiet { .. } | S::Asking { .. }, E::Adopt(session)) => match session.running.as_ref() {
            Some(title) => {
                let fx = vec![X::Prepare {
                    item_id: title.id.clone(),
                }];
                (S::Preparing(session), fx)
            }
            None => (S::Quiet { last_reason: None }, vec![]),
        },
        (S::Preparing(_), E::Prepared { plan: false, .. }) => {
            (S::Quiet { last_reason: None }, vec![X::NoPlan])
        }
        (
            S::Preparing(session),
            E::Prepared {
                plan: true,
                saved_before,
                fresh_point,
            },
        ) => {
            let session_point = fresh_point
                .or_else(|| session.state.as_ref().map(|p| p.spot()))
                .unwrap_or(0.0);
            let hint = takes_hint(&session);
            let id = session.id.clone();
            let adoption = Box::new(Adoption {
                session: *session,
                before: saved_before,
                session_point,
            });
            // First the notice, then the stop: only then does the sender know its stop is a
            // hand-over. Without a notice the stop follows at once.
            if hint {
                (S::Hinting(adoption), vec![X::SendHint { session_id: id }])
            } else {
                (S::Stopping(adoption), vec![X::SendStop { session_id: id }])
            }
        }
        (S::Hinting(adoption), E::HintDone { error }) => {
            let mut fx = vec![];
            if let Some(error) = error {
                fx.push(X::Log(format!(
                    "[Uebergabe] Hinweis nicht gesendet: {error}"
                )));
            }
            fx.push(X::SendStop {
                session_id: adoption.session.id.clone(),
            });
            (S::Stopping(adoption), fx)
        }
        (S::Stopping(_), E::StopFailed(text)) => {
            (S::Quiet { last_reason: None }, vec![X::ShowError(text)])
        }
        (S::Stopping(adoption), E::StopAccepted) => {
            let fx = vec![X::ReadPosition {
                item_id: item_id(&adoption),
            }];
            (S::Settling { adoption, tries: 0 }, fx)
        }
        (S::Settling { adoption, tries }, E::Position(now)) => {
            let tries = tries + 1;
            if now != adoption.before {
                (S::Quiet { last_reason: None }, finish(&adoption, now))
            } else if tries >= SETTLE_TRIES {
                (S::Quiet { last_reason: None }, finish(&adoption, None))
            } else {
                let fx = vec![X::ReadPosition {
                    item_id: item_id(&adoption),
                }];
                (S::Settling { adoption, tries }, fx)
            }
        }
        (s, _) => (s, vec![]),
    }
}

fn item_id(a: &Adoption) -> String {
    a.session
        .running
        .as_ref()
        .map(|t| t.id.clone())
        .unwrap_or_default()
}

fn finish(a: &Adoption, afterwards: Option<i64>) -> Vec<Effect> {
    let since = start_point(a.session_point, a.before, afterwards);
    vec![
        Effect::Offer(vec![]),
        Effect::Play {
            item_id: item_id(a),
            since,
            position_unreported: afterwards.is_none(),
            session_point: a.session_point,
        },
    ]
}

#[cfg(test)]
#[allow(clippy::expect_used)]
mod tests {
    use super::*;
    use serde_json::json;

    const NOW: f64 = 1_700_000_000.0;
    const TICKS: i64 = 10_000_000;

    fn session(id: &str, device: &str, program: &str, ticks: i64) -> RemoteSession {
        serde_json::from_value(json!({
            "Id": id, "DeviceId": device, "UserId": "paul", "DeviceName": "Wohnzimmer",
            "Client": program, "SupportsRemoteControl": true,
            "NowPlayingItem": {"Id": "item1", "Name": "Folge", "Type": "Episode"},
            "PlayState": {"IsPaused": false, "PositionTicks": ticks},
            "LastActivityDate": "2023-11-14T22:13:00Z",
        }))
        .expect("session")
    }

    fn step(s: Flow, e: Event) -> (Flow, Vec<Effect>) {
        reduce(s, e, "own", "paul")
    }

    fn quiet() -> Flow {
        Flow::Quiet { last_reason: None }
    }

    #[test]
    fn polling_rules() {
        let (s, fx) = step(Flow::Stopped, Event::Start);
        assert_eq!((s.clone(), fx), (quiet(), vec![]));
        // Player runs: no question.
        let (s2, fx) = step(
            s.clone(),
            Event::Tick {
                player_runs: true,
                signed_in: true,
            },
        );
        assert_eq!((s2, fx), (quiet(), vec![]));
        // Not signed in: clears the badge.
        let (_, fx) = step(
            s.clone(),
            Event::Tick {
                player_runs: false,
                signed_in: false,
            },
        );
        assert_eq!(fx, vec![Effect::Offer(vec![])]);
        // Asks.
        let (s3, fx) = step(
            s,
            Event::Tick {
                player_runs: false,
                signed_in: true,
            },
        );
        assert_eq!(
            (s3.clone(), fx),
            (Flow::Asking { last_reason: None }, vec![Effect::Ask])
        );
        // Failure logs and clears.
        let (s4, fx) = step(s3, Event::AskFailed("timeout".into()));
        assert_eq!(s4, quiet());
        assert!(matches!(&fx[0], Effect::Log(l) if l.contains("timeout")));
        assert_eq!(fx[1], Effect::Offer(vec![]));
    }

    #[test]
    fn an_answer_offers_reports_and_logs_only_on_change() {
        let other = session("s1", "other", "Swiftly Player", 5 * TICKS);
        let asking = Flow::Asking { last_reason: None };
        // Own session missing -> report; other session fits -> offer + preload.
        let (s, fx) = step(
            asking.clone(),
            Event::Answered {
                sessions: vec![other.clone()],
                now: NOW,
            },
        );
        assert_eq!(s, quiet());
        assert!(fx.contains(&Effect::ReportCapabilities));
        assert!(fx.contains(&Effect::Offer(vec![other.clone()])));
        assert!(fx.contains(&Effect::Preload(vec![other])));
        // Only ourselves: no offer, one log line, the second identical answer logs nothing.
        let me = session("m", "own", "Swiftly Player", 0);
        let (s, fx) = step(
            asking,
            Event::Answered {
                sessions: vec![me.clone()],
                now: NOW,
            },
        );
        assert!(
            fx.iter()
                .any(|e| matches!(e, Effect::Log(l) if l.contains("1 Sitzungen, kein Angebot")))
        );
        assert!(!fx.contains(&Effect::ReportCapabilities));
        let Flow::Quiet {
            last_reason: Some(r),
        } = s
        else {
            panic!("no reason")
        };
        let (_, fx) = step(
            Flow::Asking {
                last_reason: Some(r),
            },
            Event::Answered {
                sessions: vec![me],
                now: NOW,
            },
        );
        assert!(!fx.iter().any(|e| matches!(e, Effect::Log(_))));
    }

    fn adopt_to_stop(program: &str) -> (Flow, Vec<Effect>) {
        let s = session("s1", "other", program, 100 * TICKS);
        let (st, fx) = step(quiet(), Event::Adopt(Box::new(s)));
        assert_eq!(
            fx,
            vec![Effect::Prepare {
                item_id: "item1".into()
            }]
        );
        step(
            st,
            Event::Prepared {
                plan: true,
                saved_before: Some(50 * TICKS),
                fresh_point: Some(120.0),
            },
        )
    }

    #[test]
    fn handover_with_hint_runs_in_order_and_uses_the_saved_stop() {
        let (st, fx) = adopt_to_stop("Swiftly Player");
        assert_eq!(
            fx,
            vec![Effect::SendHint {
                session_id: "s1".into()
            }]
        );
        let (st, fx) = step(
            st,
            Event::HintDone {
                error: Some("x".into()),
            },
        );
        assert!(matches!(&fx[0], Effect::Log(l) if l.contains("Hinweis nicht gesendet")));
        assert_eq!(
            fx[1],
            Effect::SendStop {
                session_id: "s1".into()
            }
        );
        let (st, fx) = step(st, Event::StopAccepted);
        assert_eq!(
            fx,
            vec![Effect::ReadPosition {
                item_id: "item1".into()
            }]
        );
        // Unchanged twice, then the sender's stop shows up.
        let (st, _) = step(st, Event::Position(Some(50 * TICKS)));
        let (st, _) = step(st, Event::Position(Some(50 * TICKS)));
        let (st, fx) = step(st, Event::Position(Some(130 * TICKS)));
        assert_eq!(st, quiet());
        assert_eq!(
            fx[1],
            Effect::Play {
                item_id: "item1".into(),
                since: 130.0,
                position_unreported: false,
                session_point: 120.0
            }
        );
    }

    #[test]
    fn handover_without_hint_and_without_reported_stop_uses_the_session_point() {
        let (mut st, fx) = adopt_to_stop("Jellyfin Web");
        assert_eq!(
            fx,
            vec![Effect::SendStop {
                session_id: "s1".into()
            }]
        );
        (st, _) = step(st, Event::StopAccepted);
        for i in 1..SETTLE_TRIES {
            let (n, fx) = step(st, Event::Position(Some(50 * TICKS)));
            assert!(matches!(fx[0], Effect::ReadPosition { .. }), "try {i}");
            st = n;
        }
        let (st, fx) = step(st, Event::Position(Some(50 * TICKS)));
        assert_eq!(st, quiet());
        assert_eq!(
            fx[1],
            Effect::Play {
                item_id: "item1".into(),
                since: 120.0,
                position_unreported: true,
                session_point: 120.0
            }
        );
    }

    #[test]
    fn failures_return_to_quiet() {
        let s = session("s1", "other", "Swiftly Player", 0);
        let (st, _) = step(quiet(), Event::Adopt(Box::new(s)));
        let (st, fx) = step(
            st,
            Event::Prepared {
                plan: false,
                saved_before: None,
                fresh_point: None,
            },
        );
        assert_eq!((st, fx), (quiet(), vec![Effect::NoPlan]));
        let (st, _) = adopt_to_stop("Jellyfin Web");
        let (st, fx) = step(st, Event::StopFailed("nein".into()));
        assert_eq!((st, fx), (quiet(), vec![Effect::ShowError("nein".into())]));
    }

    /// Every (state, event) pair that must not do anything.
    #[test]
    fn illegal_events_change_nothing() {
        let s = session("s1", "other", "Swiftly Player", 0);
        let (hinting, _) = adopt_to_stop("Swiftly Player");
        let preparing = step(quiet(), Event::Adopt(Box::new(s.clone()))).0;
        let (stopping, _) = adopt_to_stop("Jellyfin Web");
        let settling = step(stopping.clone(), Event::StopAccepted).0;
        let busy = [preparing, hinting, stopping, settling];
        let stray = [
            Event::Start,
            Event::Tick {
                player_runs: false,
                signed_in: true,
            },
            Event::Answered {
                sessions: vec![],
                now: NOW,
            },
            Event::AskFailed("x".into()),
            Event::Adopt(Box::new(s.clone())),
        ];
        for b in &busy {
            for e in &stray {
                assert_eq!(
                    step(b.clone(), e.clone()),
                    (b.clone(), vec![]),
                    "{b:?} / {e:?}"
                );
            }
        }
        // Late hand-over results while idle, or polling stopped.
        for st in [Flow::Stopped, quiet()] {
            for e in [
                Event::Prepared {
                    plan: true,
                    saved_before: None,
                    fresh_point: None,
                },
                Event::HintDone { error: None },
                Event::StopAccepted,
                Event::StopFailed("x".into()),
                Event::Position(None),
                Event::Answered {
                    sessions: vec![],
                    now: NOW,
                },
            ] {
                assert_eq!(
                    step(st.clone(), e.clone()),
                    (st.clone(), vec![]),
                    "{st:?} / {e:?}"
                );
            }
        }
        // Stopped does not tick; an item-less session cannot be adopted.
        assert_eq!(
            step(
                Flow::Stopped,
                Event::Tick {
                    player_runs: false,
                    signed_in: true
                }
            )
            .1,
            vec![]
        );
        let mut none = s;
        none.running = None;
        assert_eq!(
            step(quiet(), Event::Adopt(Box::new(none))),
            (quiet(), vec![])
        );
        // Finish stops from anywhere and clears the badge.
        for b in &busy {
            assert_eq!(
                step(b.clone(), Event::Finish),
                (Flow::Stopped, vec![Effect::Offer(vec![])])
            );
        }
    }
}
