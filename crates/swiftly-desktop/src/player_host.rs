//! The host side of the player core's effects on the desktop (`PlayerCalls` in `PlayerModel.swift`,
//! `CorePlaybackBackend.takeCalls`). The screen folds one `take_effects()` look into [`PlayerCalls`] and runs each call
//! exactly once, in one place; the plan request goes through a [`Planner`] and the answer reloads the title at the same
//! position ([`SwitchState`] is the only state of that wait).

use crate::login_screen::Pending;
use swiftly_playback::sections::Segment;
use swiftly_playback::trickplay::Trickplay;
use swiftly_rules::chapter::Chapter;
use swiftly_vm::{Nudge, PlayerEffect, PlayerSpec, Quality};

/// One look at the core's effects, folded (the last one of a kind wins, like the Swift `PlayerCalls.init`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct PlayerCalls {
    /// Fetch the plan of this title and load it: the next episode, or the same title again (quality, subtitle).
    pub switch_to: Option<SwitchTo>,
    /// With `switch_to`: the plan is asked with this subtitle (server index, `-1` off).
    pub reload_subtitle: Option<i64>,
    /// File the new quality in the settings.
    pub quality: Option<Quality>,
    /// A prepared plan of the next episode carries the old quality.
    pub forget_prepared: bool,
    /// Leave the screen.
    pub close: bool,
    /// Warm the plan of this next episode.
    pub prepare_next: Option<String>,
    /// Rating or Discord prompt, due after the close.
    pub nudge: Option<Nudge>,
    /// A wanted subtitle is not in the engine: (server index, why).
    pub hand_over: Option<(i64, String)>,
    /// The stream was reopened: (position, paused, why); log only.
    pub stream_rebuilt: Option<(f64, bool, String)>,
}

/// A title switch the core asked for.
#[derive(Debug, Clone, PartialEq)]
pub struct SwitchTo {
    /// Item id.
    pub id: String,
    /// The countdown card started it.
    pub from_card: bool,
    /// Start position in seconds.
    pub since: f64,
}

impl PlayerCalls {
    /// Folds the effects of one look.
    pub fn fold(effects: Vec<PlayerEffect>) -> PlayerCalls {
        let mut c = PlayerCalls::default();
        for e in effects {
            match e {
                PlayerEffect::Close => c.close = true,
                PlayerEffect::StartEpisode {
                    id,
                    from_card,
                    since,
                } => {
                    c.switch_to = Some(SwitchTo {
                        id,
                        from_card,
                        since,
                    })
                }
                PlayerEffect::ReloadForSubtitle {
                    id,
                    subtitle,
                    since,
                } => {
                    c.switch_to = Some(SwitchTo {
                        id,
                        from_card: false,
                        since,
                    });
                    c.reload_subtitle = Some(subtitle);
                }
                PlayerEffect::QualityChosen(q) => c.quality = Some(q),
                PlayerEffect::ForgetPrepared => c.forget_prepared = true,
                PlayerEffect::Nudge(n) => c.nudge = Some(n),
                PlayerEffect::PrepareNext(id) => c.prepare_next = Some(id),
                PlayerEffect::StreamRebuilt {
                    position,
                    paused,
                    reason,
                } => c.stream_rebuilt = Some((position, paused, reason)),
                PlayerEffect::HandOver { subtitle, reason } => {
                    c.hand_over = Some((subtitle, reason))
                }
            }
        }
        c
    }

    /// Nothing to run.
    pub fn is_empty(&self) -> bool {
        *self == PlayerCalls::default()
    }
}

/// The plan request of a switch: what the server is asked, with the settings of that moment.
#[derive(Debug, Clone, PartialEq)]
pub struct PlanAsk {
    /// The title to plan.
    pub id: String,
    /// Where it starts (the same position for a reload, `0` for the next episode).
    pub since: f64,
    /// The countdown card started it.
    pub from_card: bool,
    /// The same title again: a quality choice or a subtitle on a transcode.
    pub reload: bool,
    /// The subtitle to ask the plan with (server index, `-1` off): a transcode burns it in or drops it.
    pub subtitle: Option<i64>,
    /// The version that plays now (a reload keeps it).
    pub source_id: Option<String>,
    /// The quality the plan is asked with: the choice just made, else the settings.
    pub quality: Quality,
}

/// Everything the screen needs of a title that was planned, ready to load.
pub struct Switched {
    /// The new title.
    pub spec: PlayerSpec,
    /// Title and second line of the header.
    pub head: (String, String),
    /// Skip sections.
    pub sections: Vec<Segment>,
    /// Chapters.
    pub chapters: Vec<Chapter>,
    /// The preview pictures and how to fetch a sheet.
    pub trickplay: Option<(Trickplay, crate::trick_preview::SheetSource)>,
    /// The picture of the next episode for the card.
    pub still: Option<crate::player_card::StillSource>,
    /// The title's poster for the system's media widgets: source, directory, file name.
    pub poster: Option<(crate::player_card::StillSource, std::path::PathBuf, String)>,
}

impl Switched {
    /// A title with nothing around it (tests, downloads without extras).
    pub fn bare(spec: PlayerSpec, head: (String, String)) -> Switched {
        Switched {
            spec,
            head,
            sections: Vec::new(),
            chapters: Vec::new(),
            trickplay: None,
            still: None,
            poster: None,
        }
    }
}

/// What the host does for the screen: plan a title, keep the quality, warm the next plan. Every call returns at once.
pub trait Planner: Send + Sync {
    /// Fetches the plan and the extras of a title (a download needs no server).
    fn plan(&self, ask: PlanAsk) -> Pending<Result<Switched, String>>;
    /// The quality of the settings now (`alwaysDirectPlay`, `bitratesLimit` of this server).
    fn quality(&self) -> Quality;
    /// Files a quality choice in the settings.
    fn save_quality(&self, quality: Quality);
    /// Starts planning the next episode while this one plays (once per title; `plan` takes the result).
    fn prepare_next(&self, _ask: PlanAsk) {}
    /// Drops what `prepare_next` made (it carries the old quality).
    fn forget_prepared(&self) {}
}

/// Where the screen stands while a switch runs. One value, one place that changes it ([`SwitchState::step`]).
#[derive(Default)]
pub enum SwitchState {
    /// No switch.
    #[default]
    Idle,
    /// The plan was asked; the answer decides.
    Planning(PlanAsk, Pending<Result<Switched, String>>),
}

impl SwitchState {
    /// Whether a plan is on its way.
    pub fn busy(&self) -> bool {
        matches!(self, SwitchState::Planning(..))
    }

    /// The ask in flight (tests).
    pub fn ask(&self) -> Option<&PlanAsk> {
        match self {
            SwitchState::Planning(a, _) => Some(a),
            SwitchState::Idle => None,
        }
    }

    /// Polls the answer once: back to `Idle` with the answer, or stay.
    pub fn step(&mut self) -> Option<(PlanAsk, Result<Switched, String>)> {
        let SwitchState::Planning(_, p) = self else {
            return None;
        };
        let answer = match p.0.try_recv() {
            Ok(a) => a,
            Err(std::sync::mpsc::TryRecvError::Empty) => return None,
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                Err("Der Titel lässt sich gerade nicht abspielen.".to_owned())
            }
        };
        let SwitchState::Planning(ask, _) = std::mem::take(self) else {
            return None;
        };
        Some((ask, answer))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_subtitle_reload_is_a_switch_with_the_track() {
        let c = PlayerCalls::fold(vec![PlayerEffect::ReloadForSubtitle {
            id: "e1".into(),
            subtitle: 4,
            since: 12.0,
        }]);
        assert_eq!(
            c.switch_to,
            Some(SwitchTo {
                id: "e1".into(),
                from_card: false,
                since: 12.0
            })
        );
        assert_eq!(c.reload_subtitle, Some(4));
        assert!(!c.close);
    }

    #[test]
    fn a_quality_choice_folds_with_its_reload() {
        let q = Quality {
            direct_play: false,
            limit: 8,
        };
        let c = PlayerCalls::fold(vec![
            PlayerEffect::QualityChosen(q),
            PlayerEffect::ForgetPrepared,
            PlayerEffect::StartEpisode {
                id: "e1".into(),
                from_card: false,
                since: 30.0,
            },
        ]);
        assert_eq!(c.quality, Some(q));
        assert!(c.forget_prepared);
        assert_eq!(c.switch_to.map(|s| s.since), Some(30.0));
        assert!(PlayerCalls::fold(Vec::new()).is_empty());
    }
}
