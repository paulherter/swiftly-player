//! Server discovery (the local broadcast search) as one state machine, replacing the host's
//! `searching` + `found` + `error` flags. The search runs for a short window; servers arrive
//! one by one. All transitions are in [`DiscoveryPhase::try_reduce`]; `None` = illegal event.

/// Where the search is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryPhase {
    /// Not started (or the page is gone).
    Idle,
    /// The broadcast is out; `found` servers answered so far.
    Searching {
        /// How many servers are known.
        found: usize,
    },
    /// The window ended with servers.
    Found {
        /// How many servers.
        found: usize,
    },
    /// The window ended and nobody answered (offer the address field).
    NothingFound,
    /// The system refused local network access (offer the settings, the address field stays).
    Denied,
}

/// What happens to the search.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryEvent {
    /// The page opens or the user searches again.
    Begin,
    /// Another server answered (`total` is the count now known).
    Heard {
        /// All known servers.
        total: usize,
    },
    /// The window ran out.
    WindowEnded,
    /// The system denied local network access.
    PermissionDenied,
    /// The page closes.
    Stop,
}

impl DiscoveryPhase {
    /// The only place that decides what an event does; `None` = illegal in this state.
    pub fn try_reduce(self, event: DiscoveryEvent) -> Option<Self> {
        use DiscoveryEvent as E;
        use DiscoveryPhase as S;
        match (self, event) {
            (_, E::Stop) => Some(S::Idle),
            (S::Idle | S::Found { .. } | S::NothingFound | S::Denied, E::Begin) => {
                Some(S::Searching { found: 0 })
            }
            (S::Searching { found }, E::Heard { total }) => Some(S::Searching {
                found: total.max(found),
            }),
            (S::Searching { found }, E::WindowEnded) => Some(if found == 0 {
                S::NothingFound
            } else {
                S::Found { found }
            }),
            (S::Searching { .. }, E::PermissionDenied) => Some(S::Denied),
            _ => None,
        }
    }

    /// The next state; an illegal event leaves it unchanged.
    pub fn reduce(self, event: DiscoveryEvent) -> Self {
        self.try_reduce(event).unwrap_or(self)
    }

    /// The spinner shows.
    pub fn searching(self) -> bool {
        matches!(self, Self::Searching { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::DiscoveryEvent as E;
    use super::DiscoveryPhase as S;

    #[test]
    fn transition_table() {
        let table: &[(S, E, Option<S>)] = &[
            (S::Idle, E::Begin, Some(S::Searching { found: 0 })),
            (S::Idle, E::Heard { total: 1 }, None),
            (S::Idle, E::WindowEnded, None),
            (S::Idle, E::PermissionDenied, None),
            (S::Idle, E::Stop, Some(S::Idle)),
            (
                S::Searching { found: 0 },
                E::Heard { total: 2 },
                Some(S::Searching { found: 2 }),
            ),
            (
                S::Searching { found: 3 },
                E::Heard { total: 2 },
                Some(S::Searching { found: 3 }),
            ),
            (
                S::Searching { found: 0 },
                E::WindowEnded,
                Some(S::NothingFound),
            ),
            (
                S::Searching { found: 2 },
                E::WindowEnded,
                Some(S::Found { found: 2 }),
            ),
            (
                S::Searching { found: 0 },
                E::PermissionDenied,
                Some(S::Denied),
            ),
            (S::Searching { found: 0 }, E::Begin, None),
            (S::Searching { found: 1 }, E::Stop, Some(S::Idle)),
            (
                S::Found { found: 2 },
                E::Begin,
                Some(S::Searching { found: 0 }),
            ),
            (S::Found { found: 2 }, E::Heard { total: 3 }, None),
            (S::Found { found: 2 }, E::WindowEnded, None),
            (S::NothingFound, E::Begin, Some(S::Searching { found: 0 })),
            (S::NothingFound, E::Heard { total: 1 }, None),
            (S::NothingFound, E::PermissionDenied, None),
            (S::Denied, E::Begin, Some(S::Searching { found: 0 })),
            (S::Denied, E::WindowEnded, None),
            (S::Denied, E::Heard { total: 1 }, None),
        ];
        for (s, e, want) in table {
            assert_eq!(s.try_reduce(*e), *want, "{s:?} + {e:?}");
            assert_eq!(s.reduce(*e), want.unwrap_or(*s));
        }
        assert!(S::Searching { found: 0 }.searching() && !S::NothingFound.searching());
    }
}
