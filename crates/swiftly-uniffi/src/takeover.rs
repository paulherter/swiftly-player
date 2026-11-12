//! The takeover card ("Wo weiterschauen?"): the host polls `/Sessions` every few seconds and hands the
//! answer over; the model keeps what can be taken over here, moves the card (badge, choice, running,
//! failed) and tells the host what to draw. The host fetches the position and starts its player, then
//! reports the outcome. Also the two pure rules the host needs around a handover.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_jellyfin::RemoteSession;
use swiftly_l10n::Locale;
use swiftly_playback::handoff_flow::{
    Effect as FlowEffect, Event as FlowEvent, Flow, reduce as reduce_flow,
};
use swiftly_playback::takeover::{self, DevicesKind, TakeoverEvent};
use swiftly_vm::{SharedVm, TakeoverPart, TakeoverRow};

use crate::error::CoreError;

/// Which device, guessed from program and name (the symbol stays with the platform).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TakeoverDevice {
    /// Phone.
    Phone,
    /// Tablet.
    Tablet,
    /// Computer.
    Computer,
    /// TV.
    Tv,
    /// Unknown.
    Unknown,
}

/// One session that can be taken over.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TakeoverRowInfo {
    /// Session id.
    pub id: String,
    /// The device's name.
    pub device: String,
    /// Kind of device, for the symbol.
    pub kind: TakeoverDevice,
    /// "Series · S1E2" or the device's name.
    pub title: String,
}

fn row_info(r: TakeoverRow) -> TakeoverRowInfo {
    TakeoverRowInfo {
        id: r.id,
        device: r.device,
        kind: match r.kind {
            DevicesKind::Phone => TakeoverDevice::Phone,
            DevicesKind::Tablet => TakeoverDevice::Tablet,
            DevicesKind::Computer => TakeoverDevice::Computer,
            DevicesKind::Tv => TakeoverDevice::Tv,
            DevicesKind::Unknown => TakeoverDevice::Unknown,
        },
        title: r.title,
    }
}

/// What the card draws.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TakeoverCard {
    /// Nothing to take over.
    Hidden,
    /// The badge; a tap takes the only session or opens the choice.
    Badge {
        /// The offered sessions.
        rows: Vec<TakeoverRowInfo>,
    },
    /// The choice among several.
    Choosing {
        /// The offered sessions.
        rows: Vec<TakeoverRowInfo>,
    },
    /// A handover runs: fetch the position, start the player, then report `succeeded` or `failed`.
    Taking {
        /// The chosen session.
        row: TakeoverRowInfo,
    },
    /// It failed; the message stays until `cancelled`.
    Failed {
        /// The message.
        message: String,
    },
}

/// The card with its version (redraw when it changes).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TakeoverState {
    /// Counts up with every change.
    pub version: u64,
    /// The card.
    pub card: TakeoverCard,
}

/// The takeover model of one signed-in user on this device.
#[derive(uniffi::Object)]
pub struct TakeoverModel {
    vm: Mutex<SharedVm>,
}

impl TakeoverModel {
    pub(crate) fn build(locale: &str, own_device_id: &str, own_user_id: &str) -> Arc<Self> {
        Arc::new(Self {
            vm: Mutex::new(SharedVm::new(
                Locale::parse(locale),
                None,
                own_device_id,
                own_user_id,
            )),
        })
    }

    fn vm(&self) -> MutexGuard<'_, SharedVm> {
        self.vm.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl TakeoverModel {
    /// A `/Sessions` answer (the JSON array) arrived at `now` (seconds since 1970). An unreadable answer
    /// is an error and leaves the card as it is.
    pub fn polled(&self, sessions_json: Vec<u8>, now: f64) -> Result<(), CoreError> {
        let sessions: Vec<RemoteSession> =
            serde_json::from_slice(&sessions_json).map_err(|e| CoreError::Failed {
                message: e.to_string(),
            })?;
        self.vm().sessions_polled(&sessions, now);
        Ok(())
    }

    /// The badge was tapped.
    pub fn tapped(&self) {
        self.vm().takeover_event(TakeoverEvent::Tapped);
    }

    /// A row of the choice card was picked (session id).
    pub fn selected(&self, session_id: String) {
        self.vm()
            .takeover_event(TakeoverEvent::Selected(session_id));
    }

    /// Scrim, "Abbrechen" or the failure message was dismissed.
    pub fn cancelled(&self) {
        self.vm().takeover_event(TakeoverEvent::Cancelled);
    }

    /// The handover started playing here.
    pub fn succeeded(&self) {
        self.vm().takeover_event(TakeoverEvent::Succeeded);
    }

    /// The handover failed; `message` is shown.
    pub fn failed(&self, message: String) {
        self.vm().takeover_event(TakeoverEvent::Failed(message));
    }

    /// Polling stopped (sign-out, view gone); the card goes.
    pub fn finished(&self) {
        self.vm().takeover_event(TakeoverEvent::Finished);
    }

    /// What the card draws now.
    pub fn state(&self) -> TakeoverState {
        let (version, part) = self.vm().takeover();
        let card = match part {
            TakeoverPart::Hidden => TakeoverCard::Hidden,
            TakeoverPart::Badge { rows } => TakeoverCard::Badge {
                rows: rows.into_iter().map(row_info).collect(),
            },
            TakeoverPart::Choosing { rows } => TakeoverCard::Choosing {
                rows: rows.into_iter().map(row_info).collect(),
            },
            TakeoverPart::Taking { row } => TakeoverCard::Taking { row: row_info(row) },
            TakeoverPart::Failed { message } => TakeoverCard::Failed { message },
        };
        TakeoverState { version, card }
    }
}

/// What the host reports to the hand-over flow (see `swiftly_playback::handoff_flow`).
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum HandoffEvent {
    /// Polling starts.
    Start,
    /// Polling stops.
    Finish,
    /// The timer fired.
    Tick { player_runs: bool, signed_in: bool },
    /// The `/Sessions` answer (JSON array) arrived at `now` (seconds since 1970).
    Answered { sessions_json: Vec<u8>, now: f64 },
    /// The sessions request failed.
    AskFailed { error: String },
    /// The user chose an offered session.
    Adopt { session_id: String },
    /// Plan, saved item and fresh sessions arrived.
    Prepared {
        plan: bool,
        saved_before: Option<i64>,
        fresh_point: Option<f64>,
    },
    /// The hint was sent (`error` set if it failed).
    HintDone { error: Option<String> },
    /// The stop was accepted.
    StopAccepted,
    /// The stop failed.
    StopFailed { text: String },
    /// The item's saved position (ticks) was read.
    Position { ticks: Option<i64> },
}

/// What the host does next.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum HandoffEffect {
    /// Request all sessions.
    Ask,
    /// Report the capabilities again.
    ReportCapabilities,
    /// These sessions can be taken over (most recent first); empty clears the badge.
    Offer { session_ids: Vec<String> },
    /// The last answer is the list for "play on".
    PublishSessions,
    /// Preload the images of these sessions' items.
    Preload { session_ids: Vec<String> },
    /// Write to the log.
    Log { line: String },
    /// Fetch plan, saved item and sessions of the item.
    Prepare { item_id: String },
    /// Send the takeover hint.
    SendHint { session_id: String },
    /// Tell the session to stop.
    SendStop { session_id: String },
    /// Sleep 100 ms, read the item's saved position, report `Position`.
    ReadPosition { item_id: String },
    /// Start here.
    Play {
        item_id: String,
        since: f64,
        position_unreported: bool,
        session_point: f64,
    },
    /// Show that no plan came.
    NoPlan,
    /// Show this error.
    ShowError { text: String },
}

struct FlowInner {
    flow: Flow,
    own_device_id: String,
    own_user_id: String,
    known: Vec<RemoteSession>,
}

/// The polling and hand-over flow as one explicit state machine; the host runs the network and the
/// player and feeds the results back as events.
#[derive(uniffi::Object)]
pub struct HandoffFlowModel {
    inner: Mutex<FlowInner>,
}

impl HandoffFlowModel {
    pub(crate) fn build(own_device_id: &str, own_user_id: &str) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(FlowInner {
                flow: Flow::Stopped,
                own_device_id: own_device_id.into(),
                own_user_id: own_user_id.into(),
                known: vec![],
            }),
        })
    }
}

fn ids(list: &[RemoteSession]) -> Vec<String> {
    list.iter().map(|s| s.id.clone()).collect()
}

#[uniffi::export]
impl HandoffFlowModel {
    /// Feed one event; returns what to do now. Events that do not fit the state return nothing.
    pub fn step(&self, event: HandoffEvent) -> Result<Vec<HandoffEffect>, CoreError> {
        let mut g = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let ev = match event {
            HandoffEvent::Start => FlowEvent::Start,
            HandoffEvent::Finish => FlowEvent::Finish,
            HandoffEvent::Tick {
                player_runs,
                signed_in,
            } => FlowEvent::Tick {
                player_runs,
                signed_in,
            },
            HandoffEvent::Answered { sessions_json, now } => {
                let sessions: Vec<RemoteSession> =
                    serde_json::from_slice(&sessions_json).map_err(|e| CoreError::Failed {
                        message: e.to_string(),
                    })?;
                FlowEvent::Answered { sessions, now }
            }
            HandoffEvent::AskFailed { error } => FlowEvent::AskFailed(error),
            HandoffEvent::Adopt { session_id } => match g.known.iter().find(|s| s.id == session_id)
            {
                Some(s) => FlowEvent::Adopt(Box::new(s.clone())),
                None => return Ok(vec![]),
            },
            HandoffEvent::Prepared {
                plan,
                saved_before,
                fresh_point,
            } => FlowEvent::Prepared {
                plan,
                saved_before,
                fresh_point,
            },
            HandoffEvent::HintDone { error } => FlowEvent::HintDone { error },
            HandoffEvent::StopAccepted => FlowEvent::StopAccepted,
            HandoffEvent::StopFailed { text } => FlowEvent::StopFailed(text),
            HandoffEvent::Position { ticks } => FlowEvent::Position(ticks),
        };
        let state = std::mem::replace(&mut g.flow, Flow::Stopped);
        let (next, effects) = reduce_flow(state, ev, &g.own_device_id, &g.own_user_id);
        g.flow = next;
        let mut out = Vec::with_capacity(effects.len());
        for e in effects {
            out.push(match e {
                FlowEffect::Ask => HandoffEffect::Ask,
                FlowEffect::ReportCapabilities => HandoffEffect::ReportCapabilities,
                FlowEffect::Offer(list) => {
                    g.known = list.clone();
                    HandoffEffect::Offer {
                        session_ids: ids(&list),
                    }
                }
                FlowEffect::PublishSessions(_) => HandoffEffect::PublishSessions,
                FlowEffect::Preload(list) => HandoffEffect::Preload {
                    session_ids: ids(&list),
                },
                FlowEffect::Log(line) => HandoffEffect::Log { line },
                FlowEffect::Prepare { item_id } => HandoffEffect::Prepare { item_id },
                FlowEffect::SendHint { session_id } => HandoffEffect::SendHint { session_id },
                FlowEffect::SendStop { session_id } => HandoffEffect::SendStop { session_id },
                FlowEffect::ReadPosition { item_id } => HandoffEffect::ReadPosition { item_id },
                FlowEffect::Play {
                    item_id,
                    since,
                    position_unreported,
                    session_point,
                } => HandoffEffect::Play {
                    item_id,
                    since,
                    position_unreported,
                    session_point,
                },
                FlowEffect::NoPlan => HandoffEffect::NoPlan,
                FlowEffect::ShowError(text) => HandoffEffect::ShowError { text },
            });
        }
        Ok(out)
    }

    /// A short name of the state, for the log and tests.
    pub fn phase(&self) -> String {
        let g = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        match g.flow {
            Flow::Stopped => "stopped",
            Flow::Quiet { .. } => "quiet",
            Flow::Asking { .. } => "asking",
            Flow::Preparing(_) => "preparing",
            Flow::Hinting(_) => "hinting",
            Flow::Stopping(_) => "stopping",
            Flow::Settling { .. } => "settling",
        }
        .into()
    }
}

/// Whether a stop belongs to a takeover: `hint_pre` is the seconds since the hint (`None` without one).
/// Only then does the picture go off as a card.
#[uniffi::export]
pub fn takeover_is_handoff(hint_pre: Option<f64>) -> bool {
    takeover::is_handoff(hint_pre)
}

/// Where the taken-over title starts, in seconds: `session` from the freshest session query,
/// `saved_before` and `saved_afterwards` the item's `PlaybackPositionTicks` before and after the other
/// device stopped.
#[uniffi::export]
pub fn takeover_start_point(
    session: f64,
    saved_before: Option<i64>,
    saved_afterwards: Option<i64>,
) -> f64 {
    takeover::start_point(session, saved_before, saved_afterwards)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sessions(user: &str, device: &str, activity: &str) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!([{
            "Id": "s1", "UserId": user, "DeviceId": device, "DeviceName": "Wohnzimmer TV",
            "Client": "Swiftly Player", "SupportsRemoteControl": true,
            "LastActivityDate": activity,
            "NowPlayingItem": {"Id":"i","Name":"Folge","Type":"Episode","SeriesName":"Serie"},
            "PlayState": {"IsPaused": false}
        }]))
        .unwrap_or_default()
    }

    #[test]
    fn a_session_of_the_same_user_becomes_a_badge_and_a_tap_starts_the_handover() {
        let m = TakeoverModel::build("de", "own", "u1");
        assert_eq!(m.state().card, TakeoverCard::Hidden);
        let now = 1_700_000_000.0;
        m.polled(sessions("u1", "other", "2023-11-14T22:13:00Z"), now)
            .unwrap();
        let TakeoverCard::Badge { rows } = m.state().card else {
            panic!("no badge")
        };
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].device, "Wohnzimmer TV");
        let v = m.state().version;
        m.tapped();
        assert!(matches!(m.state().card, TakeoverCard::Taking { .. }));
        assert!(m.state().version > v);
        m.failed("nicht erreichbar".into());
        assert_eq!(
            m.state().card,
            TakeoverCard::Failed {
                message: "nicht erreichbar".into()
            }
        );
        m.cancelled();
        m.finished();
        assert_eq!(m.state().card, TakeoverCard::Hidden);
    }

    #[test]
    fn our_own_device_other_users_and_broken_answers_offer_nothing() {
        let m = TakeoverModel::build("de", "own", "u1");
        let now = 1_700_000_000.0;
        m.polled(sessions("u1", "own", "2023-11-14T22:13:00Z"), now)
            .unwrap();
        m.polled(sessions("u2", "other", "2023-11-14T22:13:00Z"), now)
            .unwrap();
        assert_eq!(m.state().card, TakeoverCard::Hidden);
        assert!(m.polled(b"nope".to_vec(), now).is_err());
    }

    #[test]
    fn the_flow_polls_offers_and_hands_over() {
        let m = HandoffFlowModel::build("own", "u1");
        assert_eq!(m.phase(), "stopped");
        m.step(HandoffEvent::Start).unwrap();
        let fx = m
            .step(HandoffEvent::Tick {
                player_runs: false,
                signed_in: true,
            })
            .unwrap();
        assert_eq!(fx, vec![HandoffEffect::Ask]);
        let answer = sessions("u1", "other", "2023-11-14T22:13:00Z");
        let fx = m
            .step(HandoffEvent::Answered {
                sessions_json: answer,
                now: 1_700_000_000.0,
            })
            .unwrap();
        assert!(fx.contains(&HandoffEffect::Offer {
            session_ids: vec!["s1".into()]
        }));
        assert!(
            m.step(HandoffEvent::Adopt {
                session_id: "nope".into()
            })
            .unwrap()
            .is_empty()
        );
        let fx = m
            .step(HandoffEvent::Adopt {
                session_id: "s1".into(),
            })
            .unwrap();
        assert_eq!(
            fx,
            vec![HandoffEffect::Prepare {
                item_id: "i".into()
            }]
        );
        assert_eq!(m.phase(), "preparing");
        assert!(
            m.step(HandoffEvent::Answered {
                sessions_json: b"nope".to_vec(),
                now: 0.0
            })
            .is_err()
        );
    }

    #[test]
    fn the_rules_around_a_handover() {
        assert!(takeover_is_handoff(Some(1.0)));
        assert!(!takeover_is_handoff(Some(5.0)));
        assert!(!takeover_is_handoff(None));
        assert!(
            (takeover_start_point(100.0, Some(10_000_000), Some(1_200_000_000)) - 120.0).abs()
                < 1e-9
        );
        assert!((takeover_start_point(100.0, None, None) - 100.0).abs() < 1e-9);
    }
}
