//! The gift offer flow for the Apple hosts: what comes up a moment after the home page ("What's new" after an update, which
//! carries the gift, else the offer "A look for you"), and the steps of the one sheet (offer, picking it up, the looks
//! panel). The rules are `swiftly_support::gift_flow`; the host keeps the clock, the sleeping, the stored "version seen"
//! and the drawing.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_l10n::whats_new::{WhatsNewDecision, WhatsNewEntry, decide};
use swiftly_support::Calendar;
use swiftly_support::gift_flow::{
    CLAIM_MS, GiftEval, GiftFlow, GiftOutcome, GiftStage, WhatsNewDue, evaluate,
};
use swiftly_support::look::Look;

use crate::looks::LookModel;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// How long the pick-up animation runs before the looks panel comes, in milliseconds.
#[uniffi::export]
pub fn gift_claim_ms() -> f64 {
    CLAIM_MS
}

/// The step the sheet is on.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum GiftStageInfo {
    /// "What's new"; the look is the gift on its card, if it can still be picked up.
    WhatsNew { gift_look_id: Option<String> },
    /// "A look for you".
    Offer { look_id: String },
    /// "Grab it" was pressed: the short animation before the looks panel.
    Claiming { look_id: String },
    /// The looks panel; `from_gift`: the icon lands in its row.
    Choosing { from_gift: bool },
}

fn stage_info(stage: &GiftStage) -> GiftStageInfo {
    match stage {
        GiftStage::WhatsNew { gift } => GiftStageInfo::WhatsNew {
            gift_look_id: gift.map(|l| l.id.to_owned()),
        },
        GiftStage::Offer(l) => GiftStageInfo::Offer {
            look_id: l.id.to_owned(),
        },
        GiftStage::Claiming(l) => GiftStageInfo::Claiming {
            look_id: l.id.to_owned(),
        },
        GiftStage::Choosing { from_gift } => GiftStageInfo::Choosing {
            from_gift: *from_gift,
        },
    }
}

fn stage_from(info: GiftStageInfo) -> GiftStage {
    match info {
        GiftStageInfo::WhatsNew { gift_look_id } => GiftStage::WhatsNew {
            gift: gift_look_id.as_deref().map(Look::with_id),
        },
        GiftStageInfo::Offer { look_id } => GiftStage::Offer(Look::with_id(&look_id)),
        GiftStageInfo::Claiming { look_id } => GiftStage::Claiming(Look::with_id(&look_id)),
        GiftStageInfo::Choosing { from_gift } => GiftStage::Choosing { from_gift },
    }
}

/// What one evaluation looks at; the flow's own state (sheet open, session ask) and the looks' (owned, offered) are added.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GiftEvalInput {
    /// The clock, unix seconds.
    pub now: f64,
    /// Seconds east of UTC at `now`.
    pub utc_offset: i64,
    /// Signed in, loaded, and the home page in view.
    pub home_ready: bool,
    /// The player, another sheet or a card that asks something is up.
    pub blocked: bool,
    /// How long the home page has been standing.
    pub seconds_on_home: f64,
    /// The version whose "What's new" was seen last.
    pub last_seen: Option<String>,
    /// The app was used before this launch.
    pub used_before: bool,
    /// The current app version.
    pub current: String,
    /// The "What's new" file for the current version, if the app has one.
    pub entry_json: Option<Vec<u8>>,
}

/// What to show.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum GiftOutcomeInfo {
    /// Nothing now.
    Nothing,
    /// The "What's new" sheet; the look is the gift on its card, if it can still be picked up.
    WhatsNew { gift_look_id: Option<String> },
    /// The offer "A look for you".
    Offer { look_id: String },
}

/// The result of one evaluation. The offer is already stored in the looks; the host stores the "version seen".
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GiftEvaluationInfo {
    /// Store the current version as seen.
    pub mark_seen: bool,
    /// The sheet the flow now shows.
    pub outcome: GiftOutcomeInfo,
}

/// Where the gift sheet stands, for the whole app, and the rule that keeps big asks apart: at most one per session.
#[derive(uniffi::Object)]
pub struct GiftFlowModel {
    inner: Mutex<GiftFlow>,
}

#[uniffi::export]
impl GiftFlowModel {
    /// A closed flow, no ask shown yet.
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(GiftFlow::default()),
        })
    }

    /// The step the sheet is on; `None`: closed.
    pub fn stage(&self) -> Option<GiftStageInfo> {
        lock(&self.inner).stage().map(stage_info)
    }

    /// The looks panel is up, over the real home page.
    pub fn looks_open(&self) -> bool {
        lock(&self.inner).looks_open()
    }

    /// One big ask showed this session.
    pub fn big_ask_shown(&self) -> bool {
        lock(&self.inner).big_ask_shown()
    }

    /// Another big ask showed (support sheet, rating, hint): the gift waits.
    pub fn note_big_ask(&self) {
        lock(&self.inner).note_big_ask();
    }

    /// **Called a moment after the home page came up.** Decides what shows (What's new first, which carries the gift, else
    /// the offer), shows it, and stores the offer in `looks`.
    pub fn evaluate(&self, looks: Arc<LookModel>, input: GiftEvalInput) -> GiftEvaluationInfo {
        let calendar = Calendar::fixed(input.utc_offset);
        let entry = input.entry_json.as_deref().and_then(WhatsNewEntry::decoded);
        let whats_new = match decide(
            input.last_seen.as_deref(),
            input.used_before,
            &input.current,
            entry.is_some(),
        ) {
            WhatsNewDecision::Show => WhatsNewDue::Show,
            WhatsNewDecision::MarkSeen => WhatsNewDue::MarkSeen,
            WhatsNewDecision::Nothing => WhatsNewDue::Nothing,
        };
        let (owned, offered) = looks.gift_facts();
        let mut flow = lock(&self.inner);
        let eval = GiftEval {
            now: input.now,
            stage_open: flow.presented(),
            big_ask_shown: flow.big_ask_shown(),
            home_ready: input.home_ready,
            blocked: input.blocked,
            seconds_on_home: input.seconds_on_home,
            whats_new,
            whats_new_gift: entry
                .as_ref()
                .and_then(|e| e.gift_look_id())
                .map(Look::with_id)
                .filter(|l| l.is_gift),
            owned,
            offered,
        };
        let out = evaluate(&eval, &Look::ALL, calendar);
        if let Some(look) = &out.mark_offered {
            looks.remember_offer(look, input.now, input.utc_offset);
        }
        flow.apply(&out);
        GiftEvaluationInfo {
            mark_seen: out.mark_seen,
            outcome: match out.outcome {
                GiftOutcome::Nothing => GiftOutcomeInfo::Nothing,
                GiftOutcome::WhatsNew { gift } => GiftOutcomeInfo::WhatsNew {
                    gift_look_id: gift.map(|l| l.id.to_owned()),
                },
                GiftOutcome::Offer(l) => GiftOutcomeInfo::Offer {
                    look_id: l.id.to_owned(),
                },
            },
        }
    }

    /// Shows a step (a tap that opens the sheet, a debug entry); that counts as this session's ask.
    pub fn show(&self, stage: GiftStageInfo) {
        lock(&self.inner).show(stage_from(stage));
    }

    /// The looks panel over the page that is showing.
    pub fn open_looks(&self) {
        lock(&self.inner).open_looks();
    }

    /// **"Grab it"**: the look the host has to claim in the store now, or `None` when the animation already runs. With
    /// Reduce Motion the panel comes at once.
    pub fn grab(&self, look_id: String, reduce_motion: bool) -> Option<String> {
        lock(&self.inner)
            .grab(Look::with_id(&look_id), reduce_motion)
            .map(|l| l.id.to_owned())
    }

    /// The pick-up animation ended (after `gift_claim_ms`, or a tap on it): the looks panel.
    pub fn land(&self) {
        lock(&self.inner).land();
    }

    /// Closes the sheet (named `dismiss`: a generated `close` collides with Kotlin's `AutoCloseable.close`).
    /// `true` when it was the looks panel or the animation: the host then drops a preview and follows
    /// the worn look with the icon.
    pub fn dismiss(&self) -> bool {
        lock(&self.inner).close()
    }

    /// Back to before the gift (Settings, Preview, Reset).
    pub fn reset(&self) {
        lock(&self.inner).reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_round_trip_through_the_records() {
        for s in [
            GiftStageInfo::WhatsNew {
                gift_look_id: Some("halloween".into()),
            },
            GiftStageInfo::Offer {
                look_id: "halloween".into(),
            },
            GiftStageInfo::Claiming {
                look_id: "halloween".into(),
            },
            GiftStageInfo::Choosing { from_gift: true },
        ] {
            assert_eq!(stage_info(&stage_from(s.clone())), s);
        }
    }

    #[test]
    fn grab_claims_once_and_lands_in_the_panel() {
        let flow = GiftFlowModel::new();
        flow.show(GiftStageInfo::Offer {
            look_id: "halloween".into(),
        });
        assert!(flow.big_ask_shown());
        assert_eq!(
            flow.grab("halloween".into(), false).as_deref(),
            Some("halloween")
        );
        assert_eq!(flow.grab("halloween".into(), false), None);
        flow.land();
        assert_eq!(
            flow.stage(),
            Some(GiftStageInfo::Choosing { from_gift: true })
        );
        assert!(flow.looks_open());
        assert!(flow.dismiss());
        assert_eq!(flow.stage(), None);
    }
}
