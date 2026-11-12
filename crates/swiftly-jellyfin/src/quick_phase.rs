//! Quick Connect as one state machine (replaces `QuickConnectModel`'s `preGait`, `error`,
//! `secondsLeft`, `released`, `newServer`, `run`, `waitTask`). `QuickConnectState` in `login.rs` is
//! only the wait's answer; this enum is the whole flow from "nothing asked" to "signed in".
//!
//! Every run has a number. The answers of an older run (a code from before "get a new code", a
//! poll after cancel) are illegal events and cannot touch the new run. All transitions are in
//! [`QuickPhase::try_reduce`]; `None` = illegal, [`QuickPhase::reduce`] leaves the state alone.

/// Where Quick Connect is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuickPhase {
    /// Nothing asked yet (the page shows the start).
    Idle,
    /// The code is being requested.
    Requesting {
        /// This run.
        run: u32,
    },
    /// The code is shown and the server is asked every two seconds.
    Waiting {
        /// This run.
        run: u32,
    },
    /// Approved elsewhere: signing in with the secret.
    Approved {
        /// This run.
        run: u32,
    },
    /// Signed in. Final.
    SignedIn,
    /// The code ran out (new code offered).
    Expired,
    /// The request or the sign-in failed (retry offered).
    Failed,
}

/// What happens to Quick Connect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuickEvent {
    /// The user opens the page or asks for a new code; starts run `run`.
    Start {
        /// The new run.
        run: u32,
    },
    /// The server handed out a code.
    Code {
        /// The run that asked.
        run: u32,
    },
    /// The server says: approved.
    Released {
        /// The run that polled.
        run: u32,
    },
    /// The code ran out (the clock, or the server says so).
    Expired {
        /// The run that polled.
        run: u32,
    },
    /// The request failed.
    Failed {
        /// The run that failed.
        run: u32,
    },
    /// The sign-in with the secret worked.
    SignedIn {
        /// The run.
        run: u32,
    },
    /// The user leaves the page.
    Cancel,
}

impl QuickPhase {
    /// The run this state belongs to, if it is one.
    pub fn run(self) -> Option<u32> {
        match self {
            Self::Requesting { run } | Self::Waiting { run } | Self::Approved { run } => Some(run),
            _ => None,
        }
    }

    /// The only place that decides what an event does; `None` = illegal in this state.
    pub fn try_reduce(self, event: QuickEvent) -> Option<Self> {
        use QuickEvent as E;
        use QuickPhase as S;
        match (self, event) {
            (S::SignedIn, _) => None,
            (_, E::Cancel) => Some(S::Idle),
            // a new code replaces any running wait; not while a request is still open
            (S::Idle | S::Waiting { .. } | S::Expired | S::Failed, E::Start { run }) => {
                Some(S::Requesting { run })
            }
            (S::Requesting { run: r }, E::Code { run }) if r == run => Some(S::Waiting { run }),
            (S::Requesting { run: r }, E::Failed { run }) if r == run => Some(S::Failed),
            (S::Waiting { run: r }, E::Released { run }) if r == run => Some(S::Approved { run }),
            (S::Waiting { run: r }, E::Expired { run }) if r == run => Some(S::Expired),
            // a poll that failed on the network does not end the wait: no event for it
            (S::Waiting { run: r }, E::Failed { run }) if r == run => Some(S::Failed),
            (S::Approved { run: r }, E::SignedIn { run }) if r == run => Some(S::SignedIn),
            (S::Approved { run: r }, E::Failed { run }) if r == run => Some(S::Failed),
            _ => None,
        }
    }

    /// The next state; an illegal event leaves it unchanged.
    pub fn reduce(self, event: QuickEvent) -> Self {
        self.try_reduce(event).unwrap_or(self)
    }

    /// A request is on its way (spinner, no second start).
    pub fn busy(self) -> bool {
        matches!(self, Self::Requesting { .. } | Self::Approved { .. })
    }

    /// The code is on screen with its countdown.
    pub fn shows_code(self) -> bool {
        matches!(self, Self::Waiting { .. })
    }

    /// Does the page offer "new code" / "try again"?
    pub fn can_restart(self) -> bool {
        matches!(
            self,
            Self::Idle | Self::Waiting { .. } | Self::Expired | Self::Failed
        )
    }
}

#[cfg(test)]
mod tests {
    use super::QuickEvent as E;
    use super::QuickPhase as S;

    #[test]
    fn transition_table() {
        let w1 = S::Waiting { run: 1 };
        let table: &[(S, E, Option<S>)] = &[
            (S::Idle, E::Start { run: 1 }, Some(S::Requesting { run: 1 })),
            (S::Idle, E::Code { run: 1 }, None),
            (S::Idle, E::Released { run: 1 }, None),
            (S::Idle, E::SignedIn { run: 1 }, None),
            (S::Idle, E::Cancel, Some(S::Idle)),
            (S::Requesting { run: 1 }, E::Code { run: 1 }, Some(w1)),
            (S::Requesting { run: 1 }, E::Code { run: 0 }, None),
            (
                S::Requesting { run: 1 },
                E::Failed { run: 1 },
                Some(S::Failed),
            ),
            (S::Requesting { run: 1 }, E::Failed { run: 0 }, None),
            (S::Requesting { run: 1 }, E::Start { run: 2 }, None),
            (S::Requesting { run: 1 }, E::Released { run: 1 }, None),
            (S::Requesting { run: 1 }, E::Cancel, Some(S::Idle)),
            (w1, E::Released { run: 1 }, Some(S::Approved { run: 1 })),
            (w1, E::Released { run: 0 }, None),
            (w1, E::Expired { run: 1 }, Some(S::Expired)),
            (w1, E::Expired { run: 0 }, None),
            (w1, E::Failed { run: 1 }, Some(S::Failed)),
            (w1, E::Start { run: 2 }, Some(S::Requesting { run: 2 })),
            (w1, E::Code { run: 1 }, None),
            (w1, E::SignedIn { run: 1 }, None),
            (w1, E::Cancel, Some(S::Idle)),
            (
                S::Approved { run: 1 },
                E::SignedIn { run: 1 },
                Some(S::SignedIn),
            ),
            (S::Approved { run: 1 }, E::SignedIn { run: 0 }, None),
            (
                S::Approved { run: 1 },
                E::Failed { run: 1 },
                Some(S::Failed),
            ),
            (S::Approved { run: 1 }, E::Start { run: 2 }, None),
            (S::Approved { run: 1 }, E::Expired { run: 1 }, None),
            (
                S::Expired,
                E::Start { run: 2 },
                Some(S::Requesting { run: 2 }),
            ),
            (S::Expired, E::Released { run: 1 }, None),
            (S::Expired, E::Cancel, Some(S::Idle)),
            (
                S::Failed,
                E::Start { run: 2 },
                Some(S::Requesting { run: 2 }),
            ),
            (S::Failed, E::Code { run: 1 }, None),
            (S::SignedIn, E::Start { run: 2 }, None),
            (S::SignedIn, E::Cancel, None),
        ];
        for (s, e, want) in table {
            assert_eq!(s.try_reduce(*e), *want, "{s:?} + {e:?}");
            assert_eq!(s.reduce(*e), want.unwrap_or(*s));
        }
    }

    #[test]
    fn views() {
        assert!(
            S::Requesting { run: 1 }.busy()
                && S::Approved { run: 1 }.busy()
                && !S::Waiting { run: 1 }.busy()
        );
        assert!(S::Waiting { run: 1 }.shows_code() && !S::Expired.shows_code());
        assert!(
            S::Expired.can_restart()
                && !S::Requesting { run: 1 }.can_restart()
                && !S::SignedIn.can_restart()
        );
        assert_eq!(S::Waiting { run: 7 }.run(), Some(7));
        assert_eq!(S::Idle.run(), None);
    }
}
