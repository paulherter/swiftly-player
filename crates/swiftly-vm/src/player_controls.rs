//! Controls visibility and the seek chain of the player UI as explicit state machines.
//!
//! Before: `controls` + `hide_at` + `jump` tuple in the core and `controlsVisible`,
//! `controlsGripBar`, `lastTap`, `inSeekChain`, `atPush`, `swipes`, `edgeConfirms` in every
//! host. Now: [`Controls`] (what the bar does, including the two animated steps) and
//! [`SeekChain`] (double-tap/arrow chains; cannot coexist with scrubbing). Time comes in as
//! seconds, never from a clock.

/// Seconds the controls take to fade in (enter is slower than exit, ui-gefuehl).
pub const SHOW_SECONDS: f64 = 0.20;
/// Seconds the controls take to fade out.
pub const HIDE_SECONDS: f64 = 0.15;
/// Seconds the controls stay after the last activity.
pub const IDLE_SECONDS: f64 = 4.0;
/// Seconds a seek chain waits for the next tap.
pub const CHAIN_SECONDS: f64 = 0.7;

/// What the control bar does.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Controls {
    /// Not on screen; taps on the picture show it.
    Hidden,
    /// Fading in (no hide timer yet).
    Showing {
        /// When the fade-in started.
        since: f64,
    },
    /// On screen; `hide_at` is the idle deadline.
    Visible {
        /// When the idle timer hides the bar.
        hide_at: f64,
    },
    /// Fading out; a tap during it brings the bar back from where it is.
    Hiding {
        /// When the fade-out started.
        since: f64,
    },
}

/// What happens to the control bar.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ControlsEvent {
    /// The user wants the bar (tap, key, wake).
    Show {
        /// Now.
        now: f64,
    },
    /// The user wants it gone (tap while visible).
    Hide {
        /// Now.
        now: f64,
    },
    /// Show when hidden, hide when visible.
    Toggle {
        /// Now.
        now: f64,
    },
    /// Any use of the bar keeps it up.
    Activity {
        /// Now.
        now: f64,
    },
    /// Time passes. `may_hide` is false while scrubbing, paused or with a panel open.
    Tick {
        /// Now.
        now: f64,
        /// The idle timer may hide the bar.
        may_hide: bool,
    },
}

impl Controls {
    /// The only place that decides what an event does.
    #[must_use]
    pub fn reduce(self, event: ControlsEvent) -> Self {
        use Controls as C;
        use ControlsEvent as E;
        match (self, event) {
            (C::Hidden | C::Hiding { .. }, E::Show { now } | E::Toggle { now }) => {
                C::Showing { since: now }
            }
            (C::Visible { .. } | C::Showing { .. }, E::Show { now }) => self.kept(now),
            (C::Visible { .. } | C::Showing { .. }, E::Hide { now } | E::Toggle { now }) => {
                C::Hiding { since: now }
            }
            (C::Visible { .. }, E::Activity { now }) => C::Visible {
                hide_at: now + IDLE_SECONDS,
            },
            (C::Showing { since }, E::Tick { now, .. }) if now - since >= SHOW_SECONDS => {
                C::Visible {
                    hide_at: now + IDLE_SECONDS,
                }
            }
            (C::Hiding { since }, E::Tick { now, .. }) if now - since >= HIDE_SECONDS => C::Hidden,
            (C::Visible { hide_at }, E::Tick { now, may_hide }) if may_hide && now >= hide_at => {
                C::Hiding { since: now }
            }
            (
                C::Visible { .. },
                E::Tick {
                    now,
                    may_hide: false,
                },
            ) => {
                // The timer does not run out under a panel or a scrub: it restarts.
                C::Visible {
                    hide_at: now + IDLE_SECONDS,
                }
            }
            _ => self,
        }
    }

    fn kept(self, now: f64) -> Self {
        match self {
            Self::Visible { .. } => Self::Visible {
                hide_at: now + IDLE_SECONDS,
            },
            other => other,
        }
    }

    /// The bar is on screen (also while it fades).
    #[must_use]
    pub fn on_screen(self) -> bool {
        !matches!(self, Self::Hidden)
    }

    /// Taps hit the bar's buttons (not while it is hidden or fading out).
    #[must_use]
    pub fn accepts_taps(self) -> bool {
        matches!(self, Self::Showing { .. } | Self::Visible { .. })
    }
}

/// Which side a jump goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    /// Back (left).
    Back,
    /// Forward (right).
    Forward,
}

/// The seek chain.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SeekChain {
    /// No chain.
    None,
    /// Taps (or arrow repeats) add up on one side.
    Chain {
        /// The side.
        side: Side,
        /// Seconds added so far.
        seconds: i64,
        /// Taps so far.
        taps: u32,
        /// The next tap must come before this, or it starts a new chain.
        until: f64,
    },
    /// The finger holds the progress bar: no chain.
    Scrubbing,
}

/// What happens to the chain.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ChainEvent {
    /// A jump of `seconds` (sign ignored) on `side`.
    Tap {
        /// The side.
        side: Side,
        /// Seconds of this tap.
        seconds: i64,
        /// Now.
        now: f64,
    },
    /// Time passes.
    Tick {
        /// Now.
        now: f64,
    },
    /// The finger took the progress bar.
    ScrubBegan,
    /// The finger let go.
    ScrubEnded,
}

impl SeekChain {
    /// The only place that decides what an event does.
    #[must_use]
    pub fn reduce(self, event: ChainEvent) -> Self {
        use ChainEvent as E;
        match (self, event) {
            (Self::Scrubbing, E::Tap { .. } | E::Tick { .. } | E::ScrubBegan) => Self::Scrubbing,
            (_, E::ScrubBegan) => Self::Scrubbing,
            (Self::Scrubbing, E::ScrubEnded) => Self::None,
            (_, E::ScrubEnded) => self,
            (
                Self::Chain {
                    side: s,
                    seconds,
                    taps,
                    until,
                },
                E::Tap {
                    side,
                    seconds: add,
                    now,
                },
            ) if s == side && now < until => Self::Chain {
                side,
                seconds: seconds + add.abs(),
                taps: taps + 1,
                until: now + CHAIN_SECONDS,
            },
            (_, E::Tap { side, seconds, now }) => Self::Chain {
                side,
                seconds: seconds.abs(),
                taps: 1,
                until: now + CHAIN_SECONDS,
            },
            (Self::Chain { until, .. }, E::Tick { now }) if now >= until => Self::None,
            _ => self,
        }
    }

    /// What the jump overlay shows: bearing (-1/1) and total seconds.
    #[must_use]
    pub fn display(self) -> Option<(i32, i64)> {
        match self {
            Self::Chain { side, seconds, .. } => {
                Some((if side == Side::Back { -1 } else { 1 }, seconds))
            }
            _ => None,
        }
    }

    /// A tap on the picture means "jump" (a chain is running) and not "toggle the bar".
    #[must_use]
    pub fn is_chaining(self) -> bool {
        matches!(self, Self::Chain { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::ChainEvent as CE;
    use super::Controls::*;
    use super::ControlsEvent as E;
    use super::*;

    #[test]
    fn controls_transition_table() {
        let v = |h| Visible { hide_at: h };
        let table: &[(Controls, ControlsEvent, Controls)] = &[
            (Hidden, E::Show { now: 1.0 }, Showing { since: 1.0 }),
            (Hidden, E::Toggle { now: 1.0 }, Showing { since: 1.0 }),
            (
                Showing { since: 1.0 },
                E::Tick {
                    now: 1.1,
                    may_hide: true,
                },
                Showing { since: 1.0 },
            ),
            (
                Showing { since: 1.0 },
                E::Tick {
                    now: 1.25,
                    may_hide: true,
                },
                v(5.25),
            ),
            (v(5.0), E::Hide { now: 2.0 }, Hiding { since: 2.0 }),
            (v(5.0), E::Toggle { now: 2.0 }, Hiding { since: 2.0 }),
            (v(5.0), E::Activity { now: 3.0 }, v(7.0)),
            (v(5.0), E::Show { now: 3.0 }, v(7.0)),
            (
                v(5.0),
                E::Tick {
                    now: 4.9,
                    may_hide: true,
                },
                v(5.0),
            ),
            (
                v(5.0),
                E::Tick {
                    now: 5.0,
                    may_hide: true,
                },
                Hiding { since: 5.0 },
            ),
            (
                v(5.0),
                E::Tick {
                    now: 5.0,
                    may_hide: false,
                },
                v(9.0),
            ),
            (
                Hiding { since: 5.0 },
                E::Tick {
                    now: 5.1,
                    may_hide: true,
                },
                Hiding { since: 5.0 },
            ),
            (
                Hiding { since: 5.0 },
                E::Tick {
                    now: 5.25,
                    may_hide: true,
                },
                Hidden,
            ),
            (
                Hiding { since: 5.0 },
                E::Show { now: 5.05 },
                Showing { since: 5.05 },
            ),
            // Illegal: nothing to hide, nothing to keep.
            (Hidden, E::Hide { now: 1.0 }, Hidden),
            (Hidden, E::Activity { now: 1.0 }, Hidden),
            (
                Hidden,
                E::Tick {
                    now: 9.0,
                    may_hide: true,
                },
                Hidden,
            ),
            (
                Hiding { since: 5.0 },
                E::Hide { now: 5.1 },
                Hiding { since: 5.0 },
            ),
            (
                Hiding { since: 5.0 },
                E::Activity { now: 5.1 },
                Hiding { since: 5.0 },
            ),
            (
                Showing { since: 1.0 },
                E::Activity { now: 1.1 },
                Showing { since: 1.0 },
            ),
        ];
        for &(from, ev, to) in table {
            assert_eq!(from.reduce(ev), to, "{from:?} + {ev:?}");
        }
    }

    #[test]
    fn controls_taps_and_screen() {
        assert!(!Hidden.on_screen() && !Hidden.accepts_taps());
        assert!(Hiding { since: 0.0 }.on_screen() && !Hiding { since: 0.0 }.accepts_taps());
        assert!(Showing { since: 0.0 }.accepts_taps() && Visible { hide_at: 1.0 }.accepts_taps());
    }

    #[test]
    fn chain_transition_table() {
        let ch = |side, seconds, taps, until| SeekChain::Chain {
            side,
            seconds,
            taps,
            until,
        };
        let tap = |side, seconds, now| CE::Tap { side, seconds, now };
        use Side::{Back, Forward};
        let table: &[(SeekChain, ChainEvent, SeekChain)] = &[
            (
                SeekChain::None,
                tap(Forward, 10, 1.0),
                ch(Forward, 10, 1, 1.7),
            ),
            (
                ch(Forward, 10, 1, 1.7),
                tap(Forward, 10, 1.5),
                ch(Forward, 20, 2, 2.2),
            ),
            (
                ch(Forward, 10, 1, 1.7),
                tap(Back, -10, 1.5),
                ch(Back, 10, 1, 2.2),
            ),
            (
                ch(Forward, 10, 1, 1.7),
                tap(Forward, 10, 1.7),
                ch(Forward, 10, 1, 2.4),
            ),
            (
                ch(Forward, 10, 1, 1.7),
                CE::Tick { now: 1.6 },
                ch(Forward, 10, 1, 1.7),
            ),
            (
                ch(Forward, 10, 1, 1.7),
                CE::Tick { now: 1.7 },
                SeekChain::None,
            ),
            (
                ch(Forward, 10, 1, 1.7),
                CE::ScrubBegan,
                SeekChain::Scrubbing,
            ),
            (SeekChain::None, CE::ScrubBegan, SeekChain::Scrubbing),
            (SeekChain::Scrubbing, CE::ScrubEnded, SeekChain::None),
            // Illegal: a chain cannot start or tick under the finger.
            (
                SeekChain::Scrubbing,
                tap(Forward, 10, 1.0),
                SeekChain::Scrubbing,
            ),
            (
                SeekChain::Scrubbing,
                CE::Tick { now: 9.0 },
                SeekChain::Scrubbing,
            ),
            (SeekChain::None, CE::ScrubEnded, SeekChain::None),
            (SeekChain::None, CE::Tick { now: 1.0 }, SeekChain::None),
            (
                ch(Forward, 10, 1, 1.7),
                CE::ScrubEnded,
                ch(Forward, 10, 1, 1.7),
            ),
        ];
        for &(from, ev, to) in table {
            assert_eq!(from.reduce(ev), to, "{from:?} + {ev:?}");
        }
        assert_eq!(ch(Back, 30, 3, 9.0).display(), Some((-1, 30)));
        assert_eq!(SeekChain::Scrubbing.display(), None);
        assert!(ch(Back, 30, 3, 9.0).is_chaining() && !SeekChain::Scrubbing.is_chaining());
    }
}
