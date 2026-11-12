//! The "next episode" card of the player as one state machine (replaces the host flags
//! `cardsSwitch`, `cardsEpisode`, `cardsClock`, `cardsZoom`, `shownOffering`, `startPostSwitch`).
//!
//! The switch itself (stop old session, fetch plan, start) is `swiftly_rules::episodes_switch`;
//! this enum is what the card on screen shows while that runs. All transitions are in
//! [`NextCard::try_reduce`]; an event that makes no sense in a state returns `None` and
//! [`NextCard::reduce`] leaves the state alone.

/// Where the next-episode card stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NextCard {
    /// No card.
    Hidden,
    /// The card is shown and its countdown runs; `episode` counts which offer this is, so an
    /// answer for an older offer cannot touch it.
    Offered {
        /// Which offer.
        episode: u32,
    },
    /// The user (or the countdown) accepted: the card zooms to the full picture.
    Zooming {
        /// Which offer.
        episode: u32,
    },
    /// The zoom is over and the episode switch runs (stop old, start new).
    Switching {
        /// Which offer.
        episode: u32,
    },
    /// The user waved the card away; it stays away for this episode.
    Dismissed {
        /// Which offer.
        episode: u32,
    },
}

/// What happens to the card.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NextCardEvent {
    /// The offering layer shows the card for this offer.
    Offer {
        /// Which offer.
        episode: u32,
    },
    /// Tap on the card or the countdown ran out.
    Accept,
    /// The zoom animation finished.
    ZoomDone,
    /// The new episode plays.
    Switched,
    /// No plan for the new episode: the old one keeps running, the card does not come back.
    SwitchFailed,
    /// Dismissed by the user, or the user jumped away from the end.
    Dismiss,
    /// The playback position left the offer window (seeked back).
    WindowLeft,
    /// A new episode started or the player closed: forget everything.
    Reset,
}

impl NextCard {
    /// The only place that decides what an event does; `None` = illegal in this state.
    pub fn try_reduce(self, event: NextCardEvent) -> Option<Self> {
        use NextCard as S;
        use NextCardEvent as E;
        match (self, event) {
            (_, E::Reset) => Some(S::Hidden),
            (S::Hidden, E::Offer { episode }) => Some(S::Offered { episode }),
            // a dismissed card is not offered again for the same episode
            (S::Dismissed { episode: old }, E::Offer { episode }) if episode != old => {
                Some(S::Offered { episode })
            }
            (S::Offered { episode }, E::Accept) => Some(S::Zooming { episode }),
            (S::Offered { episode }, E::Dismiss) => Some(S::Dismissed { episode }),
            (S::Offered { .. }, E::WindowLeft) => Some(S::Hidden),
            (S::Zooming { episode }, E::ZoomDone) => Some(S::Switching { episode }),
            // a dismiss while zooming turns the zoom back: the card is gone, the old episode plays
            (S::Zooming { episode }, E::Dismiss) => Some(S::Dismissed { episode }),
            (S::Switching { .. }, E::Switched) => Some(S::Hidden),
            (S::Switching { episode } | S::Zooming { episode }, E::SwitchFailed) => {
                Some(S::Dismissed { episode })
            }
            _ => None,
        }
    }

    /// The next state; an illegal event leaves it unchanged.
    pub fn reduce(self, event: NextCardEvent) -> Self {
        self.try_reduce(event).unwrap_or(self)
    }

    /// The card is on screen (any of the states that draw it).
    pub fn visible(self) -> bool {
        matches!(self, Self::Offered { .. } | Self::Zooming { .. })
    }

    /// A switch is under way: no second trigger may start one.
    pub fn busy(self) -> bool {
        matches!(self, Self::Zooming { .. } | Self::Switching { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::NextCard as S;
    use super::NextCardEvent as E;

    #[test]
    fn transition_table() {
        // (state, event, expected); None = illegal
        let table: &[(S, E, Option<S>)] = &[
            (
                S::Hidden,
                E::Offer { episode: 1 },
                Some(S::Offered { episode: 1 }),
            ),
            (S::Hidden, E::Accept, None),
            (S::Hidden, E::ZoomDone, None),
            (S::Hidden, E::Switched, None),
            (S::Hidden, E::Dismiss, None),
            (
                S::Offered { episode: 1 },
                E::Accept,
                Some(S::Zooming { episode: 1 }),
            ),
            (
                S::Offered { episode: 1 },
                E::Dismiss,
                Some(S::Dismissed { episode: 1 }),
            ),
            (S::Offered { episode: 1 }, E::WindowLeft, Some(S::Hidden)),
            (S::Offered { episode: 1 }, E::Offer { episode: 2 }, None),
            (S::Offered { episode: 1 }, E::ZoomDone, None),
            (S::Offered { episode: 1 }, E::Switched, None),
            (
                S::Zooming { episode: 1 },
                E::ZoomDone,
                Some(S::Switching { episode: 1 }),
            ),
            (S::Zooming { episode: 1 }, E::Accept, None),
            (
                S::Zooming { episode: 1 },
                E::Dismiss,
                Some(S::Dismissed { episode: 1 }),
            ),
            (
                S::Zooming { episode: 1 },
                E::SwitchFailed,
                Some(S::Dismissed { episode: 1 }),
            ),
            (S::Switching { episode: 1 }, E::Switched, Some(S::Hidden)),
            (
                S::Switching { episode: 1 },
                E::SwitchFailed,
                Some(S::Dismissed { episode: 1 }),
            ),
            (S::Switching { episode: 1 }, E::Accept, None),
            (S::Switching { episode: 1 }, E::Dismiss, None),
            (S::Switching { episode: 1 }, E::Offer { episode: 2 }, None),
            (S::Dismissed { episode: 1 }, E::Offer { episode: 1 }, None),
            (
                S::Dismissed { episode: 1 },
                E::Offer { episode: 2 },
                Some(S::Offered { episode: 2 }),
            ),
            (S::Dismissed { episode: 1 }, E::Accept, None),
        ];
        for (s, e, want) in table {
            assert_eq!(s.try_reduce(*e), *want, "{s:?} + {e:?}");
            assert_eq!(s.reduce(*e), want.unwrap_or(*s), "{s:?} + {e:?} reduce");
        }
        // Reset always lands on Hidden
        for s in [
            S::Hidden,
            S::Offered { episode: 3 },
            S::Zooming { episode: 3 },
            S::Switching { episode: 3 },
            S::Dismissed { episode: 3 },
        ] {
            assert_eq!(s.try_reduce(E::Reset), Some(S::Hidden));
        }
    }

    #[test]
    fn busy_blocks_a_second_switch() {
        assert!(
            !S::Hidden.busy()
                && !S::Offered { episode: 1 }.busy()
                && !S::Dismissed { episode: 1 }.busy()
        );
        assert!(S::Zooming { episode: 1 }.busy() && S::Switching { episode: 1 }.busy());
        assert!(S::Offered { episode: 1 }.visible() && !S::Switching { episode: 1 }.visible());
    }
}
