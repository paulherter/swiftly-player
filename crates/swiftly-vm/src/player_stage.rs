//! The player's lifecycle as ONE enum (start, picture, restore, switch, hand-over, failure).
//!
//! The iOS/tvOS/Mac/Android player screens each keep a pile of flags (`restoring`, `startFailed`,
//! `firstImagePresent`, `handoverRuns`, `switches`, `finallyStopped` ...) that allow impossible
//! combinations such as "failed and showing a picture". This machine is the only place that
//! decides what an event does; the exported coarse `Phase` stays as it is and hosts may read
//! [`PlayerStage`] for the finer state.

/// What the transport resumes as after a restore.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Resume {
    /// It ran before.
    Playing,
    /// It was paused before.
    Paused,
}

/// Where the player stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayerStage {
    /// Started, no picture yet (the loading screen is up).
    Opening,
    /// Picture is there and runs.
    Playing,
    /// Picture is there and is paused.
    Paused,
    /// The position is put back (rotation, window change, restore); the picture stays.
    Restoring(Resume),
    /// The title is replaced (next episode, quality switch); the old title is stopped.
    Switching,
    /// The fallback engine takes over the same title.
    HandingOver,
    /// The film is over.
    Ended,
    /// The start or the stream failed (retry offered).
    Failed,
    /// Closed for good.
    Closed,
}

/// What happens to the player.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StageEvent {
    /// A (re)start of the stream is requested: first start, Retry, rebuild, or the new title.
    Begin,
    /// The first picture is there; `running` says whether playback runs.
    PictureShown {
        /// Playback runs.
        running: bool,
    },
    /// The engine started or stopped playing.
    Running(bool),
    /// A restore of the position starts (`true`) or lands (`false`).
    Restore(bool),
    /// The title is being replaced.
    SwitchBegan,
    /// The fallback engine is taking over.
    HandOver,
    /// The film is over.
    Ended,
    /// The start or the stream failed.
    Failed,
    /// The screen closed.
    Closed,
}

impl PlayerStage {
    /// The only place that decides what an event does. Events that make no sense in a state
    /// (a picture after a failure, "running" after the end) leave it unchanged.
    #[must_use]
    pub fn reduce(self, event: StageEvent) -> Self {
        use PlayerStage as S;
        use StageEvent as E;
        let live = |s: Self| matches!(s, S::Opening | S::Playing | S::Paused | S::Restoring(_));
        match (self, event) {
            (S::Closed, _) => S::Closed,
            (_, E::Closed) => S::Closed,
            (_, E::Begin) => S::Opening,
            (S::Failed, _) | (S::Ended, _) => self,
            (_, E::Failed) => S::Failed,
            (s, E::Ended) if live(s) || s == S::HandingOver => S::Ended,
            (S::Switching, E::PictureShown { running })
            | (S::HandingOver, E::PictureShown { running })
            | (S::Opening, E::PictureShown { running }) => {
                if running {
                    S::Playing
                } else {
                    S::Paused
                }
            }
            (S::Playing | S::Paused, E::Running(on)) => {
                if on {
                    S::Playing
                } else {
                    S::Paused
                }
            }
            (S::Restoring(_), E::Running(on)) => {
                S::Restoring(if on { Resume::Playing } else { Resume::Paused })
            }
            (S::Playing, E::Restore(true)) => S::Restoring(Resume::Playing),
            (S::Paused, E::Restore(true)) => S::Restoring(Resume::Paused),
            (S::Restoring(Resume::Playing), E::Restore(false)) => S::Playing,
            (S::Restoring(Resume::Paused), E::Restore(false)) => S::Paused,
            (s, E::SwitchBegan) if live(s) => S::Switching,
            (s, E::HandOver) if live(s) => S::HandingOver,
            _ => self,
        }
    }

    /// The controls accept play/pause/seek.
    #[must_use]
    pub fn accepts_transport(self) -> bool {
        matches!(self, Self::Playing | Self::Paused)
    }

    /// The loading screen is up.
    #[must_use]
    pub fn shows_loading(self) -> bool {
        matches!(self, Self::Opening | Self::Switching | Self::HandingOver)
    }

    /// Nothing more will happen without a new `Begin`.
    #[must_use]
    pub fn is_settled(self) -> bool {
        matches!(self, Self::Ended | Self::Failed | Self::Closed)
    }
}

/// Where the picture goes, beside the lifecycle: on this screen, in the small window (PiP), or on a
/// TV through AirPlay. Orthogonal to [`PlayerStage`] (a film is playing *and* in PiP), so a second
/// enum with its own `reduce` instead of a product of both. [`Surface::allows`] reads the stage.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Surface {
    /// The picture is on this screen.
    #[default]
    Inline,
    /// The picture is in the small window.
    Pip,
    /// AirPlay was asked for: the plan is being fetched (the screen keeps its picture).
    AirPlayAsking,
    /// The TV shows the picture; this device only controls.
    AirPlay,
}

/// What happens to the surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SurfaceEvent {
    /// The small window opened (`true`) or closed (`false`).
    Pip(bool),
    /// The audio route went to an AirPlay device: the host wants the TV to take over.
    AirPlayAsk,
    /// The plan for the TV is ready and handed over.
    AirPlayTaken,
    /// The check or the server said no, or the fetch failed.
    AirPlayRefused,
    /// The route went back to the device (or the user stopped AirPlay).
    AirPlayBack,
    /// The player closed.
    Closed,
}

impl Surface {
    /// The only place that decides what a surface event does; illegal events change nothing.
    #[must_use]
    pub fn reduce(self, event: SurfaceEvent) -> Self {
        use Surface as S;
        use SurfaceEvent as E;
        match (self, event) {
            (_, E::Closed) => S::Inline,
            (S::Inline, E::Pip(true)) => S::Pip,
            (S::Pip, E::Pip(false)) => S::Inline,
            (S::Inline, E::AirPlayAsk) => S::AirPlayAsking,
            (S::AirPlayAsking, E::AirPlayTaken) => S::AirPlay,
            (S::AirPlayAsking, E::AirPlayRefused) => S::Inline,
            (S::AirPlayAsking | S::AirPlay, E::AirPlayBack) => S::Inline,
            _ => self,
        }
    }

    /// AirPlay may be asked for: the picture is on this screen and the title is live.
    #[must_use]
    pub fn allows_airplay(self, stage: PlayerStage) -> bool {
        self == Self::Inline && matches!(stage, PlayerStage::Playing | PlayerStage::Paused)
    }

    /// The screen's own controls (zoom, fill, gestures on the picture) work: not while the TV shows it
    /// or the small window holds it.
    #[must_use]
    pub fn controls_picture(self) -> bool {
        self == Self::Inline
    }
}

#[cfg(test)]
mod tests {
    use super::PlayerStage::*;
    use super::*;
    use StageEvent as E;

    const RP: Resume = Resume::Playing;
    const RZ: Resume = Resume::Paused;

    #[test]
    fn transition_table() {
        let pic = E::PictureShown { running: true };
        let picp = E::PictureShown { running: false };
        let table: &[(PlayerStage, StageEvent, PlayerStage)] = &[
            (Opening, pic, Playing),
            (Opening, picp, Paused),
            (Opening, E::Failed, Failed),
            (Opening, E::HandOver, HandingOver),
            (Opening, E::SwitchBegan, Switching),
            (Opening, E::Ended, Ended),
            (Playing, E::Running(false), Paused),
            (Paused, E::Running(true), Playing),
            (Playing, E::Restore(true), Restoring(RP)),
            (Paused, E::Restore(true), Restoring(RZ)),
            (Restoring(RP), E::Running(false), Restoring(RZ)),
            (Restoring(RP), E::Restore(false), Playing),
            (Restoring(RZ), E::Restore(false), Paused),
            (Playing, E::SwitchBegan, Switching),
            (Restoring(RP), E::SwitchBegan, Switching),
            (Switching, pic, Playing),
            (Switching, E::Begin, Opening),
            (Playing, E::HandOver, HandingOver),
            (HandingOver, pic, Playing),
            (HandingOver, picp, Paused),
            (Playing, E::Ended, Ended),
            (Playing, E::Failed, Failed),
            (Restoring(RP), E::Failed, Failed),
            (Switching, E::Failed, Failed),
            (Failed, E::Begin, Opening),
            (Ended, E::Begin, Opening),
            (Playing, E::Begin, Opening),
            // Illegal events change nothing.
            (Failed, pic, Failed),
            (Failed, E::Running(true), Failed),
            (Failed, E::Ended, Failed),
            (Failed, E::HandOver, Failed),
            (Ended, E::Running(true), Ended),
            (Ended, pic, Ended),
            (Ended, E::Failed, Ended),
            (Opening, E::Running(true), Opening),
            (Opening, E::Restore(true), Opening),
            (Playing, pic, Playing),
            (Paused, E::Restore(false), Paused),
            (Switching, E::Running(true), Switching),
            (Switching, E::Restore(true), Switching),
            (Switching, E::HandOver, Switching),
            (Switching, E::SwitchBegan, Switching),
            (HandingOver, E::SwitchBegan, HandingOver),
            (HandingOver, E::Restore(true), HandingOver),
            (Restoring(RP), E::HandOver, HandingOver),
            (Restoring(RP), pic, Restoring(RP)),
        ];
        for &(from, ev, to) in table {
            assert_eq!(from.reduce(ev), to, "{from:?} + {ev:?}");
        }
    }

    #[test]
    fn closed_is_absorbing_and_closes_from_everywhere() {
        let all = [
            Opening,
            Playing,
            Paused,
            Restoring(RP),
            Switching,
            HandingOver,
            Ended,
            Failed,
            Closed,
        ];
        let events = [
            E::Begin,
            E::PictureShown { running: true },
            E::Running(true),
            E::Restore(true),
            E::SwitchBegan,
            E::HandOver,
            E::Ended,
            E::Failed,
        ];
        for s in all {
            assert_eq!(s.reduce(E::Closed), Closed);
        }
        for e in events {
            assert_eq!(Closed.reduce(e), Closed, "Closed + {e:?}");
        }
    }

    #[test]
    fn no_failed_with_picture_and_helpers() {
        // A failed start can only leave through Begin: a late picture never revives it.
        assert!(
            Failed
                .reduce(E::PictureShown { running: true })
                .is_settled()
        );
        assert!(
            Opening.shows_loading() && Switching.shows_loading() && HandingOver.shows_loading()
        );
        assert!(Playing.accepts_transport() && Paused.accepts_transport());
        assert!(!Restoring(RP).accepts_transport() && !Failed.accepts_transport());
    }

    #[test]
    fn surface_table() {
        use Surface as S;
        use SurfaceEvent as V;
        let table: &[(Surface, SurfaceEvent, Surface)] = &[
            (S::Inline, V::Pip(true), S::Pip),
            (S::Pip, V::Pip(false), S::Inline),
            (S::Inline, V::AirPlayAsk, S::AirPlayAsking),
            (S::AirPlayAsking, V::AirPlayTaken, S::AirPlay),
            (S::AirPlayAsking, V::AirPlayRefused, S::Inline),
            (S::AirPlayAsking, V::AirPlayBack, S::Inline),
            (S::AirPlay, V::AirPlayBack, S::Inline),
            (S::Pip, V::Closed, S::Inline),
            (S::AirPlay, V::Closed, S::Inline),
            // Illegal: nothing changes.
            (S::Pip, V::AirPlayAsk, S::Pip),
            (S::AirPlay, V::Pip(true), S::AirPlay),
            (S::AirPlay, V::AirPlayAsk, S::AirPlay),
            (S::Inline, V::AirPlayTaken, S::Inline),
            (S::Inline, V::AirPlayBack, S::Inline),
            (S::Inline, V::Pip(false), S::Inline),
            (S::AirPlay, V::AirPlayRefused, S::AirPlay),
            (S::AirPlayAsking, V::Pip(true), S::AirPlayAsking),
        ];
        for &(from, ev, to) in table {
            assert_eq!(from.reduce(ev), to, "{from:?} + {ev:?}");
        }
    }

    #[test]
    fn airplay_only_inline_and_live() {
        assert!(Surface::Inline.allows_airplay(Playing) && Surface::Inline.allows_airplay(Paused));
        assert!(
            !Surface::Inline.allows_airplay(Opening) && !Surface::Inline.allows_airplay(Failed)
        );
        assert!(!Surface::Pip.allows_airplay(Playing) && !Surface::AirPlay.allows_airplay(Playing));
        assert!(Surface::Inline.controls_picture() && !Surface::AirPlay.controls_picture());
    }
}
