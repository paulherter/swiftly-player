//! Downloads as explicit state machines: one item ([`ItemPhase`]), the network ([`Network`]) and the
//! whole queue ([`QueuePhase`]). Replaces the shipping app's loose flags around `DownloadState`
//! (`wLAN`, `noNetwork`, `networkRead`, `onlyOverWLAN`, `searchesTasks`, "only one loads at a
//! time" as a comment, "who halted it" guessed on resume).
//!
//! All item transitions are in [`ItemPhase::try_reduce`] (`None` = illegal event, nothing
//! changes). A running transfer carries a `generation`: the answer of an older transfer (after a
//! pause and resume, or an account switch) is illegal and cannot finish or fail the new one.

use crate::state::DownloadState;

/// What the network offers right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Network {
    /// Not read yet: nothing may start (the old default `wLAN = true` is gone).
    Unknown,
    /// No connection.
    Offline,
    /// Mobile data.
    Cellular,
    /// Wi-Fi or ethernet.
    Wifi,
}

impl Network {
    /// May a transfer run? With "only over Wi-Fi" cellular does not count.
    pub fn allows(self, only_wifi: bool) -> bool {
        match self {
            Self::Wifi => true,
            Self::Cellular => !only_wifi,
            Self::Unknown | Self::Offline => false,
        }
    }
}

/// Who paused an item.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PausedBy {
    /// The user pressed pause.
    User,
    /// A failed transfer left resume data.
    Transfer,
}

/// Where one download is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ItemPhase {
    /// In the queue, may start when it is its turn.
    Queued,
    /// Loading; `generation` identifies this transfer.
    Running {
        /// The transfer.
        generation: u32,
    },
    /// Paused.
    Paused(PausedBy),
    /// Wants to run but the network does not allow it (none, or cellular with "only Wi-Fi").
    Offline,
    /// Failed (retry offered).
    Failed,
    /// On the device.
    Done,
}

/// What happens to one download.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ItemEvent {
    /// Its turn: a transfer with this generation starts.
    Start {
        /// The new transfer.
        generation: u32,
    },
    /// The user pauses.
    Pause,
    /// The user resumes.
    Resume,
    /// The transfer with this generation finished.
    Finished {
        /// The transfer.
        generation: u32,
    },
    /// The transfer with this generation failed; `resumable` = resume data is there.
    TransferFailed {
        /// The transfer.
        generation: u32,
        /// Resume data exists.
        resumable: bool,
    },
    /// The network no longer allows transfers.
    NetworkLost,
    /// The network allows transfers again.
    NetworkBack,
    /// The user retries a failed download.
    Retry,
}

impl ItemPhase {
    /// The only place that decides what an event does; `None` = illegal in this state.
    pub fn try_reduce(self, event: ItemEvent) -> Option<Self> {
        use ItemEvent as E;
        use ItemPhase as S;
        match (self, event) {
            (S::Queued, E::Start { generation }) => Some(S::Running { generation }),
            (S::Queued | S::Running { .. } | S::Offline, E::Pause) => {
                Some(S::Paused(PausedBy::User))
            }
            (S::Paused(_), E::Resume) => Some(S::Queued),
            (S::Running { generation: g }, E::Finished { generation }) if g == generation => {
                Some(S::Done)
            }
            (
                S::Running { generation: g },
                E::TransferFailed {
                    generation,
                    resumable,
                },
            ) if g == generation => Some(if resumable {
                S::Paused(PausedBy::Transfer)
            } else {
                S::Failed
            }),
            (S::Queued | S::Running { .. }, E::NetworkLost) => Some(S::Offline),
            (S::Offline, E::NetworkBack) => Some(S::Queued),
            (S::Failed, E::Retry) => Some(S::Queued),
            _ => None,
        }
    }

    /// The next state; an illegal event leaves it unchanged.
    pub fn reduce(self, event: ItemEvent) -> Self {
        self.try_reduce(event).unwrap_or(self)
    }

    /// The persisted state this phase is written as (`Offline` waits like `Queued`).
    pub fn persisted(self) -> DownloadState {
        match self {
            Self::Queued | Self::Offline => DownloadState::Waits,
            Self::Running { .. } => DownloadState::Loads,
            Self::Paused(_) => DownloadState::Halted,
            Self::Failed => DownloadState::Error,
            Self::Done => DownloadState::Done,
        }
    }

    /// The phase a persisted state starts as after a launch (nothing runs yet, so `Loads`
    /// becomes `Queued`). The network decides `Offline` afterwards.
    pub fn restored(state: DownloadState) -> Self {
        match state {
            DownloadState::Waits | DownloadState::Loads => Self::Queued,
            DownloadState::Halted => Self::Paused(PausedBy::User),
            DownloadState::Done => Self::Done,
            DownloadState::Error => Self::Failed,
        }
    }

    /// Like [`Self::restored`] but a loading entry stays a running transfer (generation 0): used to
    /// fold the live list into a [`QueuePhase`].
    pub fn restored_running(state: DownloadState) -> Self {
        match state {
            DownloadState::Loads => Self::Running { generation: 0 },
            other => Self::restored(other),
        }
    }

    /// May this item start now?
    pub fn can_start(self) -> bool {
        self == Self::Queued
    }
}

/// Where the whole queue is, derived from its items and the network.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueuePhase {
    /// Nothing in the list.
    Empty,
    /// One item runs; `waiting` more are queued.
    Running {
        /// Items queued behind the running one.
        waiting: usize,
    },
    /// Items wait, none runs: the queue can pick the next one.
    Ready {
        /// Items queued.
        waiting: usize,
    },
    /// Items want to run but the network does not allow it.
    Offline {
        /// Items held back.
        waiting: usize,
    },
    /// Only paused items (no one runs, no one waits).
    Paused {
        /// Items paused.
        paused: usize,
    },
    /// Everything is done or failed; nothing left to do.
    Idle {
        /// Items that failed.
        failed: usize,
    },
    /// More than one item runs: the invariant "only one loads at a time" is broken.
    Broken {
        /// Items running.
        running: usize,
    },
}

impl QueuePhase {
    /// Fold the items into one queue state. With `Network` not allowing transfers, queued
    /// items count as held back (offline) even if no event moved them yet.
    pub fn of(items: &[ItemPhase], network: Network, only_wifi: bool) -> Self {
        if items.is_empty() {
            return Self::Empty;
        }
        let running = items
            .iter()
            .filter(|p| matches!(p, ItemPhase::Running { .. }))
            .count();
        let queued = items
            .iter()
            .filter(|p| matches!(p, ItemPhase::Queued))
            .count();
        let held = items
            .iter()
            .filter(|p| matches!(p, ItemPhase::Offline))
            .count();
        let paused = items
            .iter()
            .filter(|p| matches!(p, ItemPhase::Paused(_)))
            .count();
        let failed = items
            .iter()
            .filter(|p| matches!(p, ItemPhase::Failed))
            .count();
        let allowed = network.allows(only_wifi);
        if running > 1 {
            Self::Broken { running }
        } else if running == 1 {
            if allowed {
                Self::Running {
                    waiting: queued + held,
                }
            } else {
                Self::Offline {
                    waiting: queued + held + 1,
                }
            }
        } else if queued + held > 0 {
            if allowed && held == 0 {
                Self::Ready { waiting: queued }
            } else {
                Self::Offline {
                    waiting: queued + held,
                }
            }
        } else if paused > 0 {
            Self::Paused { paused }
        } else {
            Self::Idle { failed }
        }
    }

    /// May the queue start another item? Only when none runs and the network allows it.
    pub fn may_start_next(self) -> bool {
        matches!(self, Self::Ready { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::ItemEvent as E;
    use super::ItemPhase as S;
    use super::*;

    const USER: S = S::Paused(PausedBy::User);
    const XFER: S = S::Paused(PausedBy::Transfer);

    #[test]
    fn item_transition_table() {
        let r1 = S::Running { generation: 1 };
        let table: &[(S, E, Option<S>)] = &[
            (S::Queued, E::Start { generation: 1 }, Some(r1)),
            (S::Queued, E::Pause, Some(USER)),
            (S::Queued, E::NetworkLost, Some(S::Offline)),
            (S::Queued, E::Resume, None),
            (S::Queued, E::Finished { generation: 1 }, None),
            (S::Queued, E::Retry, None),
            (S::Queued, E::NetworkBack, None),
            (r1, E::Finished { generation: 1 }, Some(S::Done)),
            (r1, E::Finished { generation: 0 }, None),
            (
                r1,
                E::TransferFailed {
                    generation: 1,
                    resumable: true,
                },
                Some(XFER),
            ),
            (
                r1,
                E::TransferFailed {
                    generation: 1,
                    resumable: false,
                },
                Some(S::Failed),
            ),
            (
                r1,
                E::TransferFailed {
                    generation: 2,
                    resumable: false,
                },
                None,
            ),
            (r1, E::Pause, Some(USER)),
            (r1, E::NetworkLost, Some(S::Offline)),
            (r1, E::Start { generation: 2 }, None),
            (r1, E::Resume, None),
            (USER, E::Resume, Some(S::Queued)),
            (XFER, E::Resume, Some(S::Queued)),
            (USER, E::Start { generation: 1 }, None),
            (USER, E::NetworkLost, None),
            (USER, E::Pause, None),
            (S::Offline, E::NetworkBack, Some(S::Queued)),
            (S::Offline, E::Pause, Some(USER)),
            (S::Offline, E::Start { generation: 1 }, None),
            (S::Offline, E::Resume, None),
            (S::Failed, E::Retry, Some(S::Queued)),
            (S::Failed, E::Start { generation: 1 }, None),
            (S::Failed, E::Pause, None),
            (S::Done, E::Retry, None),
            (S::Done, E::Pause, None),
            (S::Done, E::Start { generation: 1 }, None),
            (S::Done, E::NetworkLost, None),
        ];
        for (s, e, want) in table {
            assert_eq!(s.try_reduce(*e), *want, "{s:?} + {e:?}");
            assert_eq!(s.reduce(*e), want.unwrap_or(*s));
        }
    }

    #[test]
    fn persisted_round_trip() {
        for s in DownloadState::ALL {
            let phase = S::restored(s);
            // a launch never restores a running transfer
            let back = phase.persisted();
            assert_eq!(
                back,
                if s == DownloadState::Loads {
                    DownloadState::Waits
                } else {
                    s
                }
            );
        }
        assert_eq!(S::Offline.persisted(), DownloadState::Waits);
        assert!(S::Queued.can_start() && !S::Offline.can_start());
    }

    #[test]
    fn network_table() {
        for (n, only_wifi, want) in [
            (Network::Unknown, false, false),
            (Network::Unknown, true, false),
            (Network::Offline, false, false),
            (Network::Cellular, false, true),
            (Network::Cellular, true, false),
            (Network::Wifi, false, true),
            (Network::Wifi, true, true),
        ] {
            assert_eq!(n.allows(only_wifi), want, "{n:?} wifi-only {only_wifi}");
        }
    }

    #[test]
    fn queue_fold() {
        let r = S::Running { generation: 1 };
        let q = |items: &[S], n, w| QueuePhase::of(items, n, w);
        assert_eq!(q(&[], Network::Wifi, false), QueuePhase::Empty);
        assert_eq!(
            q(&[r, S::Queued], Network::Wifi, true),
            QueuePhase::Running { waiting: 1 }
        );
        assert_eq!(
            q(&[S::Queued, S::Done], Network::Wifi, true),
            QueuePhase::Ready { waiting: 1 }
        );
        assert!(q(&[S::Queued], Network::Wifi, true).may_start_next());
        // network unknown or cellular with wifi-only: nothing may start
        assert_eq!(
            q(&[S::Queued], Network::Unknown, false),
            QueuePhase::Offline { waiting: 1 }
        );
        assert_eq!(
            q(&[S::Queued], Network::Cellular, true),
            QueuePhase::Offline { waiting: 1 }
        );
        assert!(!q(&[S::Queued], Network::Cellular, true).may_start_next());
        assert_eq!(
            q(&[S::Offline, S::Queued], Network::Wifi, false),
            QueuePhase::Offline { waiting: 2 }
        );
        assert_eq!(
            q(&[r], Network::Offline, false),
            QueuePhase::Offline { waiting: 1 }
        );
        assert_eq!(
            q(&[USER, S::Done], Network::Wifi, false),
            QueuePhase::Paused { paused: 1 }
        );
        assert_eq!(
            q(&[S::Done, S::Failed], Network::Wifi, false),
            QueuePhase::Idle { failed: 1 }
        );
        assert_eq!(
            q(&[r, S::Running { generation: 2 }], Network::Wifi, false),
            QueuePhase::Broken { running: 2 }
        );
        assert!(!q(&[r], Network::Wifi, false).may_start_next());
    }
}
