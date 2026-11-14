//! One shared load state for every list or detail screen.
//!
//! Replaces the flag pile `loads` + `items.is_empty()` + `disrupted` (and the "no empty state
//! before the first answer" patches) by one enum. All transitions are in [`Load::reduce`];
//! the exported per-screen status enums are derived from it, so no impossible combination
//! (spinner over error over data) can be built.

/// Why a load failed although the network was reachable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailKind {
    /// The server answered with an error.
    Server,
    /// The answer could not be read.
    Unreadable,
    /// The server refused the account.
    Denied,
}

/// Where a load stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Load {
    /// Nothing asked yet (or the account changed): the host shows nothing, not "empty".
    Idle,
    /// The first answer is on its way and nothing is shown.
    Loading,
    /// Data is shown and a fresh answer is on its way.
    Refreshing,
    /// Data is shown.
    Loaded,
    /// The server answered: nothing here.
    Empty,
    /// The server answered with an error and nothing is shown (retry offered).
    Failed(FailKind),
    /// The server could not be reached.
    Offline,
}

/// What happens to a load.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoadEvent {
    /// A request starts.
    Begin,
    /// The server answered with `items` entries.
    Answered {
        /// Number of entries in the answer.
        items: usize,
    },
    /// The server answered with an error.
    Failed(FailKind),
    /// The server could not be reached.
    WentOffline,
    /// The request was aborted (not an answer: never "empty").
    Cancelled,
    /// The account or server changed: forget everything.
    Reset,
}

impl Load {
    /// The only place that decides what an event does. Events that make no sense in a state
    /// (an answer nobody asked for) leave it unchanged.
    #[must_use]
    pub fn reduce(self, event: LoadEvent) -> Self {
        use LoadEvent as E;
        match (self, event) {
            (_, E::Reset) => Self::Idle,
            (Self::Loaded | Self::Refreshing, E::Begin) => Self::Refreshing,
            (_, E::Begin) => Self::Loading,
            (Self::Loading | Self::Refreshing, E::Answered { items }) => {
                if items == 0 {
                    Self::Empty
                } else {
                    Self::Loaded
                }
            }
            (Self::Loading | Self::Refreshing, E::Failed(kind)) => Self::Failed(kind),
            (Self::Loading | Self::Refreshing, E::WentOffline) => Self::Offline,
            (Self::Loading, E::Cancelled) => Self::Idle,
            (Self::Refreshing, E::Cancelled) => Self::Loaded,
            (state, E::Answered { .. } | E::Failed(_) | E::WentOffline | E::Cancelled) => state,
        }
    }

    /// The state a screen is in, from the facts it already holds (additive bridge: the flags
    /// stay where they are, the enum is what the exported status derives from). `failure` wins
    /// over everything only when `loading` is false; callers decide that priority.
    #[must_use]
    pub fn from_facts(loading: bool, has_data: bool, failure: Option<LoadFailure>) -> Self {
        match (loading, has_data, failure) {
            (true, true, _) => Self::Refreshing,
            (true, false, _) => Self::Loading,
            (false, _, Some(LoadFailure::Offline)) => Self::Offline,
            (false, false, Some(LoadFailure::Failed(kind))) => Self::Failed(kind),
            (false, true, Some(LoadFailure::Failed(_))) => Self::Loaded,
            (false, true, None) => Self::Loaded,
            (false, false, None) => Self::Empty,
        }
    }

    /// The load state a search status stands for (`SignedOut` has no load: `Idle`).
    #[must_use]
    pub fn from_search(status: crate::search::SearchStatus) -> Self {
        use crate::search::SearchStatus as S;
        match status {
            S::Idle | S::SignedOut => Self::Idle,
            S::Searching => Self::Loading,
            S::Done => Self::Loaded,
            S::Empty => Self::Empty,
            S::Offline => Self::Offline,
        }
    }

    /// Data is on screen.
    #[must_use]
    pub fn shows_data(self) -> bool {
        matches!(self, Self::Refreshing | Self::Loaded)
    }

    /// A request is on its way.
    #[must_use]
    pub fn is_busy(self) -> bool {
        matches!(self, Self::Loading | Self::Refreshing)
    }

    /// The screen may offer "try again".
    #[must_use]
    pub fn can_retry(self) -> bool {
        matches!(self, Self::Failed(_) | Self::Offline)
    }
}

/// A failure fact for [`Load::from_facts`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoadFailure {
    /// Unreachable.
    Offline,
    /// Answered with an error.
    Failed(FailKind),
}

impl LoadFailure {
    /// The heading and sentence of the whole-page error (`Trouble.copy(server:)`); `server` is the address or
    /// "Der Server". Unreachable and a server error keep the shipping wording; a refused sign-in and an unreadable
    /// answer get their own, because "does it still run?" is the wrong question for them.
    #[must_use]
    pub fn copy(self, server: &str) -> (&'static str, String) {
        match self {
            Self::Offline | Self::Failed(FailKind::Server) => (
                "Server ist abgetaucht",
                format!("{server} antwortet nicht. Läuft er noch, oder hängt das WLAN?"),
            ),
            Self::Failed(FailKind::Denied) => (
                "Anmeldung abgelehnt",
                format!(
                    "{server} hat die Anmeldung abgelehnt. Wechsel den Server oder melde dich neu an."
                ),
            ),
            Self::Failed(FailKind::Unreadable) => (
                "Antwort unlesbar",
                format!(
                    "{server} hat etwas geschickt, das die App nicht lesen kann. Versuch es gleich nochmal."
                ),
            ),
        }
    }

    /// What a failed request means for the page's own error text: the network could not be
    /// reached, the account was refused, the server errored, or the answer was unreadable.
    #[must_use]
    pub fn from_error(e: &swiftly_net::ErrorKind) -> Self {
        Self::from_topic(e.topic())
    }

    /// The same from the failure group alone (what the state machines keep).
    #[must_use]
    pub fn from_topic(topic: swiftly_net::ErrorTopic) -> Self {
        use swiftly_net::ErrorTopic;
        match topic {
            ErrorTopic::Network => Self::Offline,
            ErrorTopic::Auth => Self::Failed(FailKind::Denied),
            ErrorTopic::Server => Self::Failed(FailKind::Server),
            ErrorTopic::Decode => Self::Failed(FailKind::Unreadable),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use FailKind::Server;
    use Load::*;
    use LoadEvent as E;

    const ALL: [Load; 7] = [
        Idle,
        Loading,
        Refreshing,
        Loaded,
        Empty,
        Failed(Server),
        Offline,
    ];

    #[test]
    fn transition_table() {
        let a1 = E::Answered { items: 3 };
        let a0 = E::Answered { items: 0 };
        let f = E::Failed(Server);
        let table: &[(Load, LoadEvent, Load)] = &[
            (Idle, E::Begin, Loading),
            (Loading, E::Begin, Loading),
            (Loaded, E::Begin, Refreshing),
            (Refreshing, E::Begin, Refreshing),
            (Empty, E::Begin, Loading),
            (Failed(Server), E::Begin, Loading),
            (Offline, E::Begin, Loading),
            (Loading, a1, Loaded),
            (Loading, a0, Empty),
            (Refreshing, a1, Loaded),
            (Refreshing, a0, Empty),
            (Loading, f, Failed(Server)),
            (Refreshing, f, Failed(Server)),
            (Loading, E::WentOffline, Offline),
            (Refreshing, E::WentOffline, Offline),
            (Loading, E::Cancelled, Idle),
            (Refreshing, E::Cancelled, Loaded),
            // Illegal: answers nobody asked for change nothing.
            (Idle, a1, Idle),
            (Idle, a0, Idle),
            (Loaded, a0, Loaded),
            (Empty, a1, Empty),
            (Offline, a1, Offline),
            (Failed(Server), a1, Failed(Server)),
            (Idle, f, Idle),
            (Loaded, f, Loaded),
            (Empty, E::WentOffline, Empty),
            (Idle, E::Cancelled, Idle),
            (Loaded, E::Cancelled, Loaded),
            (Empty, E::Cancelled, Empty),
        ];
        for &(from, ev, to) in table {
            assert_eq!(from.reduce(ev), to, "{from:?} + {ev:?}");
        }
    }

    #[test]
    fn reset_from_everywhere_and_cancel_is_never_empty() {
        for s in ALL {
            assert_eq!(s.reduce(E::Reset), Idle);
            if s != Empty {
                assert_ne!(s.reduce(E::Cancelled), Empty);
            }
        }
        assert_eq!(Loading.reduce(E::Cancelled), Idle);
    }

    #[test]
    fn busy_data_retry_flags() {
        for s in ALL {
            assert_eq!(s.is_busy(), matches!(s, Loading | Refreshing));
            assert_eq!(s.shows_data(), matches!(s, Loaded | Refreshing));
            assert_eq!(s.can_retry(), matches!(s, Failed(_) | Offline));
        }
    }

    #[test]
    fn from_facts_table() {
        use LoadFailure as F;
        let rows: &[(bool, bool, Option<LoadFailure>, Load)] = &[
            (true, false, None, Loading),
            (true, true, None, Refreshing),
            (true, false, Some(F::Offline), Loading),
            (false, false, None, Empty),
            (false, true, None, Loaded),
            (false, false, Some(F::Offline), Offline),
            (false, true, Some(F::Offline), Offline),
            (false, false, Some(F::Failed(Server)), Failed(Server)),
            (false, true, Some(F::Failed(Server)), Loaded),
        ];
        for &(l, d, f, want) in rows {
            assert_eq!(Load::from_facts(l, d, f), want, "{l} {d} {f:?}");
        }
    }

    #[test]
    fn errors_sort_into_the_four_copies() {
        use swiftly_net::ErrorKind as K;
        assert_eq!(
            LoadFailure::from_error(&K::Network { code: -1009 }),
            LoadFailure::Offline
        );
        assert_eq!(
            LoadFailure::from_error(&K::NotAuthenticated),
            LoadFailure::Failed(FailKind::Denied)
        );
        assert_eq!(
            LoadFailure::from_error(&K::Http {
                status: 500,
                body: None
            }),
            LoadFailure::Failed(FailKind::Server)
        );
        assert_eq!(
            LoadFailure::from_error(&K::Decoding(String::new())),
            LoadFailure::Failed(FailKind::Unreadable)
        );
    }
}
