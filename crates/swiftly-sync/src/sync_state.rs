//! Settings sync as one state machine (replaces the host's `syncing` / `pushing` / `error` /
//! `lastSync` flags): pull the server's copy, decide who wins ([`crate::Decision`]), apply or
//! push, end in `Done`, `Conflict` or `Failed`. All transitions are in [`SyncPhase::try_reduce`];
//! an illegal event (a second pull while one runs, an answer nobody asked for) returns `None`.

use crate::Decision;

/// Where the settings sync is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncPhase {
    /// Nothing happens (also after an account switch).
    Idle,
    /// The server's copy is being fetched.
    Pulling,
    /// The server's copy wins and is written into the local settings.
    Applying,
    /// Our copy wins and is written to the server.
    Pushing,
    /// The server changed while we pushed: pull again before anything else.
    Conflict,
    /// In sync.
    Done,
    /// The last run failed (retry offered).
    Failed,
}

/// What happens to the sync.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncEvent {
    /// A run starts (app start, settings changed, retry).
    Pull,
    /// The server's copy arrived and the comparison decided.
    Fetched(Decision),
    /// The local settings are written.
    Applied,
    /// The server took our copy.
    Pushed,
    /// The server refused our push because it is newer.
    Rejected,
    /// The request failed.
    Failed,
    /// The account or server changed: forget everything.
    Reset,
}

impl SyncPhase {
    /// The only place that decides what an event does; `None` = illegal in this state.
    pub fn try_reduce(self, event: SyncEvent) -> Option<Self> {
        use SyncEvent as E;
        use SyncPhase as S;
        match (self, event) {
            (_, E::Reset) => Some(S::Idle),
            (S::Idle | S::Conflict | S::Done | S::Failed, E::Pull) => Some(S::Pulling),
            (S::Pulling, E::Fetched(Decision::Apply)) => Some(S::Applying),
            (S::Pulling, E::Fetched(Decision::Push)) => Some(S::Pushing),
            (S::Pulling, E::Fetched(Decision::Nothing)) => Some(S::Done),
            (S::Applying, E::Applied) => Some(S::Done),
            (S::Pushing, E::Pushed) => Some(S::Done),
            (S::Pushing, E::Rejected) => Some(S::Conflict),
            (S::Pulling | S::Applying | S::Pushing, E::Failed) => Some(S::Failed),
            _ => None,
        }
    }

    /// The next state; an illegal event leaves it unchanged.
    pub fn reduce(self, event: SyncEvent) -> Self {
        self.try_reduce(event).unwrap_or(self)
    }

    /// A request is on its way: the UI shows progress and a new run is refused.
    pub fn busy(self) -> bool {
        matches!(self, Self::Pulling | Self::Applying | Self::Pushing)
    }

    /// May a new run start?
    pub fn can_pull(self) -> bool {
        !self.busy()
    }
}

#[cfg(test)]
mod tests {
    use super::SyncEvent as E;
    use super::SyncPhase as S;
    use super::*;

    #[test]
    fn transition_table() {
        let table: &[(S, E, Option<S>)] = &[
            (S::Idle, E::Pull, Some(S::Pulling)),
            (S::Idle, E::Fetched(Decision::Apply), None),
            (S::Idle, E::Applied, None),
            (S::Idle, E::Pushed, None),
            (S::Idle, E::Failed, None),
            (S::Pulling, E::Pull, None),
            (S::Pulling, E::Fetched(Decision::Apply), Some(S::Applying)),
            (S::Pulling, E::Fetched(Decision::Push), Some(S::Pushing)),
            (S::Pulling, E::Fetched(Decision::Nothing), Some(S::Done)),
            (S::Pulling, E::Failed, Some(S::Failed)),
            (S::Pulling, E::Applied, None),
            (S::Pulling, E::Pushed, None),
            (S::Applying, E::Applied, Some(S::Done)),
            (S::Applying, E::Failed, Some(S::Failed)),
            (S::Applying, E::Pull, None),
            (S::Applying, E::Pushed, None),
            (S::Pushing, E::Pushed, Some(S::Done)),
            (S::Pushing, E::Rejected, Some(S::Conflict)),
            (S::Pushing, E::Failed, Some(S::Failed)),
            (S::Pushing, E::Pull, None),
            (S::Pushing, E::Applied, None),
            (S::Conflict, E::Pull, Some(S::Pulling)),
            (S::Conflict, E::Pushed, None),
            (S::Conflict, E::Failed, None),
            (S::Done, E::Pull, Some(S::Pulling)),
            (S::Done, E::Failed, None),
            (S::Done, E::Rejected, None),
            (S::Failed, E::Pull, Some(S::Pulling)),
            (S::Failed, E::Applied, None),
            (S::Failed, E::Failed, None),
        ];
        for (s, e, want) in table {
            assert_eq!(s.try_reduce(*e), *want, "{s:?} + {e:?}");
            assert_eq!(s.reduce(*e), want.unwrap_or(*s));
        }
        for s in [
            S::Idle,
            S::Pulling,
            S::Applying,
            S::Pushing,
            S::Conflict,
            S::Done,
            S::Failed,
        ] {
            assert_eq!(s.try_reduce(E::Reset), Some(S::Idle));
        }
    }

    #[test]
    fn busy_refuses_a_second_run() {
        for s in [S::Pulling, S::Applying, S::Pushing] {
            assert!(s.busy() && !s.can_pull());
        }
        for s in [S::Idle, S::Conflict, S::Done, S::Failed] {
            assert!(!s.busy() && s.can_pull());
        }
    }
}
