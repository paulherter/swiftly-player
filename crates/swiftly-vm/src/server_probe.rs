//! The Plex server choice as a per-server state machine (replaces the host's `connecting` id plus
//! `unreachable` set): every server in the list is `Idle`, `Probing`, `Reachable` or
//! `Unreachable`, and [`ProbeBoard`] keeps the rule "one server probes at a time".
//! Transitions are in [`ServerProbe::try_reduce`]; `None` = illegal event.

/// One server's probe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerProbe {
    /// Not tried yet (or reset).
    Idle,
    /// The addresses are being tried; `attempt` counts retries of this server.
    Probing {
        /// 1 for the first try.
        attempt: u32,
    },
    /// An address answered; the sign-in continues on it.
    Reachable,
    /// No address answered (the row shows "not reachable", retry offered).
    Unreachable,
}

/// What happens to one server's probe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeEvent {
    /// The user taps the server (or retries).
    Tap,
    /// An address answered.
    Answered,
    /// All addresses failed.
    AllFailed,
    /// The user went back or another server was chosen.
    Cancel,
    /// The list was reloaded: forget the probe.
    Reset,
}

impl ServerProbe {
    /// The only place that decides what an event does; `None` = illegal in this state.
    pub fn try_reduce(self, event: ProbeEvent) -> Option<Self> {
        use ProbeEvent as E;
        use ServerProbe as S;
        match (self, event) {
            (_, E::Reset) => Some(S::Idle),
            (S::Idle, E::Tap) => Some(S::Probing { attempt: 1 }),
            (S::Unreachable, E::Tap) => Some(S::Probing { attempt: 1 }),
            (S::Probing { .. }, E::Answered) => Some(S::Reachable),
            (S::Probing { .. }, E::AllFailed) => Some(S::Unreachable),
            (S::Probing { .. }, E::Cancel) => Some(S::Idle),
            _ => None,
        }
    }

    /// The next state; an illegal event leaves it unchanged.
    pub fn reduce(self, event: ProbeEvent) -> Self {
        self.try_reduce(event).unwrap_or(self)
    }

    /// The row shows its spinner.
    pub fn probing(self) -> bool {
        matches!(self, Self::Probing { .. })
    }
}

/// All servers of the choice step.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ProbeBoard {
    probes: Vec<ServerProbe>,
}

impl ProbeBoard {
    /// A board with `n` servers, all idle.
    pub fn new(n: usize) -> Self {
        Self {
            probes: vec![ServerProbe::Idle; n],
        }
    }

    /// The probes in list order.
    pub fn probes(&self) -> &[ServerProbe] {
        &self.probes
    }

    /// The server being probed, if any.
    pub fn connecting(&self) -> Option<usize> {
        self.probes.iter().position(|p| p.probing())
    }

    /// Tap on server `i`. Refused (`false`) while another one probes, for an unknown index and for a
    /// reachable or already-probing server; a tap on a failed server starts again.
    pub fn tap(&mut self, i: usize) -> bool {
        if self.connecting().is_some() {
            return false;
        }
        self.apply(i, ProbeEvent::Tap)
    }

    /// Feed server `i` an event. `false` = illegal (nothing changed).
    pub fn apply(&mut self, i: usize, event: ProbeEvent) -> bool {
        let Some(p) = self.probes.get_mut(i) else {
            return false;
        };
        match p.try_reduce(event) {
            Some(next) => {
                *p = next;
                true
            }
            None => false,
        }
    }

    /// Back to the list: nothing probes any more, failed marks stay.
    pub fn cancel(&mut self) {
        for p in &mut self.probes {
            if p.probing() {
                *p = ServerProbe::Idle;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ProbeEvent as E;
    use super::ServerProbe as S;
    use super::*;

    #[test]
    fn transition_table() {
        let p1 = S::Probing { attempt: 1 };
        let table: &[(S, E, Option<S>)] = &[
            (S::Idle, E::Tap, Some(p1)),
            (S::Idle, E::Answered, None),
            (S::Idle, E::AllFailed, None),
            (S::Idle, E::Cancel, None),
            (p1, E::Answered, Some(S::Reachable)),
            (p1, E::AllFailed, Some(S::Unreachable)),
            (p1, E::Cancel, Some(S::Idle)),
            (p1, E::Tap, None),
            (S::Reachable, E::Tap, None),
            (S::Reachable, E::AllFailed, None),
            (S::Reachable, E::Cancel, None),
            (S::Unreachable, E::Tap, Some(p1)),
            (S::Unreachable, E::Answered, None),
            (S::Unreachable, E::Cancel, None),
        ];
        for (s, e, want) in table {
            assert_eq!(s.try_reduce(*e), *want, "{s:?} + {e:?}");
            assert_eq!(s.reduce(*e), want.unwrap_or(*s));
        }
        for s in [S::Idle, p1, S::Reachable, S::Unreachable] {
            assert_eq!(s.try_reduce(E::Reset), Some(S::Idle));
        }
    }

    #[test]
    fn board_probes_one_server_at_a_time() {
        let mut b = ProbeBoard::new(3);
        assert!(b.tap(1));
        assert_eq!(b.connecting(), Some(1));
        assert!(!b.tap(0), "second tap while one probes");
        assert!(!b.tap(9), "unknown server");
        assert!(b.apply(1, E::AllFailed));
        assert_eq!(b.probes()[1], S::Unreachable);
        assert!(!b.apply(1, E::AllFailed), "stale answer");
        assert!(b.tap(0));
        b.cancel();
        assert_eq!(b.connecting(), None);
        assert_eq!(
            b.probes()[1],
            S::Unreachable,
            "failed marks survive a cancel"
        );
        assert!(b.tap(1), "retry of a failed server");
        assert!(b.apply(1, E::Answered));
        assert!(!b.tap(1), "reachable stays");
    }
}
