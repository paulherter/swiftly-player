//! The gift offer flow, one rule set for every app (`GiftFlow` in `LookGiftSheet.swift`): what comes up a moment after the
//! home page ("What's new" after an update, which carries the gift when there is one, else the offer "A look for you"),
//! and the steps of the one sheet: offer, picking it up, the looks panel. The hosts keep the clock, the sleeping and the
//! drawing; the decisions and the stage changes are here.

use std::collections::BTreeSet;

use crate::gift::{GiftContext, LookGift};
use crate::look::Look;
use crate::time::{Calendar, Timestamp};

/// How long the pick-up animation runs before the looks panel comes, in milliseconds.
pub const CLAIM_MS: f64 = 900.0;

/// What the "What's new" rules said (`whats_new::decide`; this crate does not know the file format).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WhatsNewDue {
    /// After an update with a file for this version.
    Show,
    /// Fresh install or no file: store the version, show nothing.
    MarkSeen,
    /// Seen already.
    Nothing,
}

/// Everything the evaluation looks at.
#[derive(Clone, Debug, PartialEq)]
pub struct GiftEval {
    /// The clock.
    pub now: Timestamp,
    /// A sheet of this flow is open.
    pub stage_open: bool,
    /// Another big ask showed this session (the support card, rating, a hint).
    pub big_ask_shown: bool,
    /// Signed in and the home page loaded and in view.
    pub home_ready: bool,
    /// The player, another sheet, or a card that asks something is up.
    pub blocked: bool,
    /// How long the home page has been standing.
    pub seconds_on_home: f64,
    /// The "What's new" verdict for this version.
    pub whats_new: WhatsNewDue,
    /// The gift look the entry for this version offers, if it has a gift module.
    pub whats_new_gift: Option<Look>,
    /// The gifts picked up.
    pub owned: BTreeSet<String>,
    /// The offers already made (`<look>-<year>`).
    pub offered: BTreeSet<String>,
}

/// What to show.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GiftOutcome {
    /// Nothing now.
    Nothing,
    /// The "What's new" sheet; `gift` is the look it can still hand out (in its window, not owned).
    WhatsNew {
        /// The gift on the card, or `None`.
        gift: Option<Look>,
    },
    /// The offer "A look for you".
    Offer(Look),
}

/// The result of one evaluation, with what the host has to store.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GiftEvaluation {
    /// Store the current version as seen.
    pub mark_seen: bool,
    /// Store this gift's offer for the season (`LookStore::mark_offered`).
    pub mark_offered: Option<Look>,
    /// The sheet to show.
    pub outcome: GiftOutcome,
}

/// Whether a gift can still be handed out: in its window and not owned (`giftDue`).
pub fn gift_due(look: &Look, owned: &BTreeSet<String>, now: Timestamp, calendar: Calendar) -> bool {
    !owned.contains(look.id)
        && look
            .availability
            .is_some_and(|s| s.is_active(now, calendar))
}

/// **Called a moment after the home page came up** (`GiftFlow.evaluate`): "What's new" first, which carries the gift when
/// there is one, else the gift once in its window. Nothing on top of another sheet, nothing during playback, nothing when
/// the session already asked.
pub fn evaluate(input: &GiftEval, looks: &[Look], calendar: Calendar) -> GiftEvaluation {
    let none = GiftEvaluation {
        mark_seen: false,
        mark_offered: None,
        outcome: GiftOutcome::Nothing,
    };
    if input.stage_open || input.big_ask_shown || !input.home_ready || input.blocked {
        return none;
    }
    let mut mark_seen = false;
    match input.whats_new {
        WhatsNewDue::Show => {
            let gift = input
                .whats_new_gift
                .filter(|g| gift_due(g, &input.owned, input.now, calendar));
            return GiftEvaluation {
                mark_seen: true,
                mark_offered: gift,
                outcome: GiftOutcome::WhatsNew { gift },
            };
        }
        WhatsNewDue::MarkSeen => mark_seen = true,
        WhatsNewDue::Nothing => {}
    }
    let context = GiftContext {
        now: input.now,
        home_ready: true,
        playing: false,
        asked_this_session: false,
        seconds_on_home: input.seconds_on_home,
        owned: input.owned.clone(),
        offered: input.offered.clone(),
    };
    match LookGift::due(&context, looks, calendar) {
        Some(gift) => GiftEvaluation {
            mark_seen,
            mark_offered: Some(gift),
            outcome: GiftOutcome::Offer(gift),
        },
        None => GiftEvaluation { mark_seen, ..none },
    }
}

/// The step the sheet is on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GiftStage {
    /// "What's new"; `gift` is the card's gift, if it can still be picked up.
    WhatsNew {
        /// The gift on the card.
        gift: Option<Look>,
    },
    /// "A look for you".
    Offer(Look),
    /// "Grab it" was pressed: the short animation before the looks panel.
    Claiming(Look),
    /// The looks panel; `from_gift`: the icon lands in its row.
    Choosing {
        /// Came from picking up a gift.
        from_gift: bool,
    },
}

/// Where the sheet stands, and the rule that keeps big asks apart: at most one per session.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GiftFlow {
    stage: Option<GiftStage>,
    big_ask_shown: bool,
}

impl GiftFlow {
    /// The step the sheet is on; `None`: closed.
    pub fn stage(&self) -> Option<&GiftStage> {
        self.stage.as_ref()
    }

    /// The sheet is open.
    pub fn presented(&self) -> bool {
        self.stage.is_some()
    }

    /// The looks panel is up, over the real home page.
    pub fn looks_open(&self) -> bool {
        matches!(self.stage, Some(GiftStage::Choosing { .. }))
    }

    /// One big ask showed this session.
    pub fn big_ask_shown(&self) -> bool {
        self.big_ask_shown
    }

    /// Another big ask showed (support card, rating, hint): the gift waits.
    pub fn note_big_ask(&mut self) {
        self.big_ask_shown = true;
    }

    /// Shows a step; that counts as this session's ask.
    pub fn show(&mut self, stage: GiftStage) {
        self.big_ask_shown = true;
        self.stage = Some(stage);
    }

    /// Shows what an evaluation decided.
    pub fn apply(&mut self, evaluation: &GiftEvaluation) {
        match evaluation.outcome {
            GiftOutcome::Nothing => {}
            GiftOutcome::WhatsNew { gift } => self.show(GiftStage::WhatsNew { gift }),
            GiftOutcome::Offer(look) => self.show(GiftStage::Offer(look)),
        }
    }

    /// The looks panel over the page that is showing.
    pub fn open_looks(&mut self) {
        self.stage = Some(GiftStage::Choosing { from_gift: false });
    }

    /// **"Grab it"**: returns the look the host has to claim in the store now (picked up for good the moment it is pressed),
    /// or `None` when the animation already runs. With Reduce Motion the panel comes at once.
    pub fn grab(&mut self, look: Look, reduce_motion: bool) -> Option<Look> {
        if matches!(self.stage, Some(GiftStage::Claiming(_))) {
            return None;
        }
        self.stage = Some(if reduce_motion {
            GiftStage::Choosing { from_gift: true }
        } else {
            GiftStage::Claiming(look)
        });
        Some(look)
    }

    /// The pick-up animation ended (after [`CLAIM_MS`], or a tap on it): the looks panel.
    pub fn land(&mut self) {
        if matches!(self.stage, Some(GiftStage::Claiming(_))) {
            self.stage = Some(GiftStage::Choosing { from_gift: true });
        }
    }

    /// Closes the sheet. `true` when it was the looks panel or the animation: the host then drops a preview and follows
    /// the worn look with the icon.
    pub fn close(&mut self) -> bool {
        let was = matches!(
            self.stage,
            Some(GiftStage::Choosing { .. } | GiftStage::Claiming(_))
        );
        self.stage = None;
        was
    }

    /// Back to before the gift (Settings, Preview, Reset).
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}
