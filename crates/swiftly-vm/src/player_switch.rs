//! The replacement of the running title (next episode, quality or subtitle reload) as ONE enum.
//!
//! Replaces the `switching` flag of the player: the flag was set when the old title was stopped and
//! the host asked for the new plan, but nothing ever cleared it when that plan failed, so the player
//! stayed in `Switching` for good (no picture, no controls, no way back). This machine is the only
//! place that decides what a switch event does; the player reads [`Switch::busy`] and
//! [`Switch::allows_automatic`].

/// What the old title was doing when the switch began, and so what it goes back to if the plan fails.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Back {
    /// It ran.
    Playing,
    /// It was paused.
    Paused,
    /// It was over (the end-of-title advance asks for the next one).
    Ended,
}

/// Where the title replacement stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Switch {
    /// None runs; an automatic advance may start one.
    #[default]
    Idle,
    /// The old title is stopped and the host fetches the plan.
    Planning {
        /// What the old title goes back to if the plan fails.
        back: Back,
        /// The same title again (quality or subtitle), not the next episode.
        reload: bool,
    },
    /// The plan failed and the old title is back. No automatic advance asks again; only the user does.
    Failed,
}

/// What happens to the switch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwitchEvent {
    /// The old title was stopped and the plan is asked for.
    Begin {
        /// What the old title was doing.
        back: Back,
        /// The same title again (quality or subtitle), not the next episode.
        reload: bool,
    },
    /// The host answered that there is no plan.
    PlanFailed,
    /// The user asked for a switch again (Next, the card, a quality or subtitle choice).
    Asked,
}

impl Switch {
    /// The only place that decides what a switch event does; an event that makes no sense changes nothing
    /// (a second failure answer, an answer without a request).
    #[must_use]
    pub fn reduce(self, event: SwitchEvent) -> Self {
        use Switch as S;
        use SwitchEvent as E;
        match (self, event) {
            (S::Idle | S::Failed, E::Begin { back, reload }) => S::Planning { back, reload },
            (S::Planning { .. }, E::PlanFailed) => S::Failed,
            (S::Failed, E::Asked) => S::Idle,
            _ => self,
        }
    }

    /// A plan is on its way: the old title is stopped and the controls wait.
    #[must_use]
    pub fn busy(self) -> bool {
        matches!(self, Self::Planning { .. })
    }

    /// Time or position may start a switch by themselves (the countdown, the end of the title). Never after
    /// a failure: that would ask the host for the same plan on every tick.
    #[must_use]
    pub fn allows_automatic(self) -> bool {
        self == Self::Idle
    }

    /// What the old title goes back to and whether it is a reload, while a plan is on its way.
    #[must_use]
    pub fn planning(self) -> Option<(Back, bool)> {
        match self {
            Self::Planning { back, reload } => Some((back, reload)),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Back::*;
    use super::Switch::*;
    use super::*;
    use SwitchEvent as E;

    const fn begin(back: Back) -> SwitchEvent {
        E::Begin {
            back,
            reload: false,
        }
    }

    const fn plan(back: Back) -> Switch {
        Planning {
            back,
            reload: false,
        }
    }

    #[test]
    fn transition_table() {
        let table: &[(Switch, SwitchEvent, Switch)] = &[
            (Idle, begin(Playing), plan(Playing)),
            (Idle, begin(Ended), plan(Ended)),
            (plan(Paused), E::PlanFailed, Failed),
            (Failed, E::Asked, Idle),
            // A manual retry may begin straight from Failed.
            (Failed, begin(Paused), plan(Paused)),
            // Illegal events change nothing.
            (Idle, E::PlanFailed, Idle),
            (Idle, E::Asked, Idle),
            (Failed, E::PlanFailed, Failed),
            (plan(Playing), E::Asked, plan(Playing)),
            (plan(Playing), begin(Paused), plan(Playing)),
        ];
        for &(from, ev, to) in table {
            assert_eq!(from.reduce(ev), to, "{from:?} + {ev:?}");
        }
    }

    #[test]
    fn only_idle_starts_by_itself_and_only_planning_is_busy() {
        assert!(Idle.allows_automatic() && !Idle.busy());
        assert!(!plan(Playing).allows_automatic() && plan(Playing).busy());
        assert!(!Failed.allows_automatic() && !Failed.busy());
        assert_eq!(plan(Ended).planning(), Some((Ended, false)));
        assert_eq!(Failed.planning(), None);
    }
}
