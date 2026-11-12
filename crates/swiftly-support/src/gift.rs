//! When the gift pop-up for a seasonal look may appear, where the seasonal extras may show,
//! and what the profile shows about looks (`LookGift.swift`).

use std::collections::BTreeSet;

use crate::look::Look;
use crate::time::{Calendar, Timestamp};

/// The gift pop-up rules.
pub struct LookGift;

/// How long the home page stands before the pop-up comes, in seconds.
pub const QUIET_AFTER_HOME: f64 = 3.0;

/// Everything the gift check looks at.
#[derive(Clone, Debug, PartialEq)]
pub struct GiftContext {
    /// The clock.
    pub now: Timestamp,
    /// Signed in and the home page loaded.
    pub home_ready: bool,
    /// Player, mini player or Picture in Picture.
    pub playing: bool,
    /// Another big ask already showed this session.
    pub asked_this_session: bool,
    /// How long the home page has been standing.
    pub seconds_on_home: f64,
    /// The gifts picked up.
    pub owned: BTreeSet<String>,
    /// The offers already made (`<look>-<year>`).
    pub offered: BTreeSet<String>,
}

impl LookGift {
    /// The stored id of one offer: `halloween-2026`.
    pub fn offer_id(look: &Look, at: Timestamp, calendar: Calendar) -> Option<String> {
        let season = look.availability?;
        let year = season.season_year(at, calendar)?;
        Some(format!("{}-{year}", season.id))
    }

    /// The gift whose pop-up is due now, if any, among `looks`.
    pub fn due(context: &GiftContext, looks: &[Look], calendar: Calendar) -> Option<Look> {
        if !context.home_ready
            || context.playing
            || context.asked_this_session
            || context.seconds_on_home < QUIET_AFTER_HOME
        {
            return None;
        }
        looks.iter().copied().find(|look| {
            if !look.is_gift || context.owned.contains(look.id) {
                return false;
            }
            match Self::offer_id(look, context.now, calendar) {
                Some(id) => !context.offered.contains(&id),
                None => false,
            }
        })
    }

    /// Whether a gift can be picked up now (in its window), or is picked up already.
    pub fn is_available(
        look: &Look,
        owned: &BTreeSet<String>,
        now: Timestamp,
        calendar: Calendar,
    ) -> bool {
        if !look.is_gift || owned.contains(look.id) {
            return true;
        }
        look.availability.is_none_or(|s| s.is_active(now, calendar))
    }
}

/// Where the small seasonal extras may show.
pub struct LookEffects;

/// The page an effect would show on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EffectPage {
    /// The rare bat.
    Home,
    /// The web in the corner of the look card.
    Profile,
    /// No effect at all: only the accent.
    Detail,
    /// Any other page.
    Other,
}

/// Everything the effects check looks at.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EffectContext {
    /// The look worn.
    pub look: Look,
    /// The clock.
    pub now: Timestamp,
    /// "Bats and details" switch.
    pub switch_on: bool,
    /// Playback is running.
    pub playing: bool,
    /// Reduce Motion is on.
    pub reduce_motion: bool,
    /// Low Power Mode.
    pub low_power: bool,
    /// The app is in the foreground.
    pub foreground: bool,
}

/// Why no bat flies right now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BatBlock {
    /// Not the home page.
    WrongPage,
    /// Switch off.
    SwitchOff,
    /// Playback.
    Playing,
    /// Outside the look's window.
    OutsideWindow,
    /// Reduce Motion.
    ReduceMotion,
    /// Low Power Mode.
    LowPower,
    /// App in the background.
    Background,
}

impl LookEffects {
    /// The first bat comes about this many seconds after the page stands.
    pub const FIRST_BAT: f64 = 6.0;
    /// The pause between bats, seconds (inclusive range).
    pub const PAUSE: (f64, f64) = (45.0, 90.0);
    /// The flight takes this long, seconds (inclusive range).
    pub const FLIGHT: (f64, f64) = (2.5, 3.5);

    /// The standing details: the web in the corner of the look card.
    pub fn details(page: EffectPage, context: &EffectContext, calendar: Calendar) -> bool {
        if !matches!(page, EffectPage::Home | EffectPage::Profile)
            || !context.switch_on
            || context.playing
        {
            return false;
        }
        context
            .look
            .availability
            .is_some_and(|s| s.is_active(context.now, calendar))
    }

    /// Why no bat flies right now, or `None` when one may.
    pub fn bat_block(
        page: EffectPage,
        context: &EffectContext,
        calendar: Calendar,
    ) -> Option<BatBlock> {
        if page != EffectPage::Home {
            return Some(BatBlock::WrongPage);
        }
        if !context.switch_on {
            return Some(BatBlock::SwitchOff);
        }
        if context.playing {
            return Some(BatBlock::Playing);
        }
        if !context
            .look
            .availability
            .is_some_and(|s| s.is_active(context.now, calendar))
        {
            return Some(BatBlock::OutsideWindow);
        }
        if context.reduce_motion {
            return Some(BatBlock::ReduceMotion);
        }
        if context.low_power {
            return Some(BatBlock::LowPower);
        }
        if !context.foreground {
            return Some(BatBlock::Background);
        }
        None
    }

    /// Whether a bat may fly.
    pub fn bats(page: EffectPage, context: &EffectContext, calendar: Calendar) -> bool {
        Self::bat_block(page, context, calendar).is_none()
    }

    /// The wait before the next bat; `unit` is a random number in 0 to 1 from the host.
    pub fn wait(first: bool, unit: f64) -> f64 {
        if first {
            Self::FIRST_BAT
        } else {
            Self::PAUSE.0 + (Self::PAUSE.1 - Self::PAUSE.0) * unit.clamp(0.0, 1.0)
        }
    }
}

/// What the profile shows at the top about looks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LookProfileEntry {
    /// Nothing.
    None,
    /// "Make Swiftly yours": the way to the preview (supporter update only).
    Teaser,
    /// A quiet line with the look's name and "Change".
    Current,
}

impl LookProfileEntry {
    /// The entry for a state.
    pub fn at(supporter_features: bool, is_supporter: bool, owns_look: bool) -> Self {
        if is_supporter || owns_look {
            return Self::Current;
        }
        if supporter_features {
            Self::Teaser
        } else {
            Self::None
        }
    }

    /// The plain "Looks" row under Appearance: only where the profile shows nothing and a gift
    /// is there to pick up.
    pub fn shows_looks_row(entry: Self, gift_available: bool) -> bool {
        entry == Self::None && gift_available
    }
}
