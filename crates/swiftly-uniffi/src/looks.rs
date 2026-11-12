//! Looks, gifts, try-on, seasons, the subtitle look and the support prompt, from `swiftly-support`.
//! The host keeps its views and its store; the rules (what may be worn, when a gift pops up, when to ask
//! for support, the player options of a subtitle look) are decided here. Colours are `0xRRGGBB`.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_support::gift::{
    BatBlock, EffectContext, EffectPage, LookEffects, LookGift, LookProfileEntry,
};
use swiftly_support::look::{Look, LookAccent, LookColor, LookSelection};
use swiftly_support::look_store::{IconStep, LookStore, dock_icon_name, look_icon_step};
use swiftly_support::subtitle::{Colour, Engine, Outline, Position, Size, SubtitleLook};
use swiftly_support::support::{
    PromptContext, Source, SupportPlatform, SupportPrompt, SupportStatus, SupportStore,
    SupportUsage, WatchTimeCounter, WatchTimeFeed,
};
use swiftly_support::try_on::KeepResult;
use swiftly_support::{Calendar, SupportPromptHistory};

use crate::error::CoreError;
use crate::settings::TypedStore;
use crate::stores::KeyValueStore;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn failed(e: impl std::fmt::Display) -> CoreError {
    CoreError::Failed {
        message: e.to_string(),
    }
}

// ---- looks ------------------------------------------------------------------------------------

/// An accent.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LookAccentInfo {
    /// Stable id.
    pub id: String,
    /// Main colour.
    pub main: u32,
    /// Light colour.
    pub light: u32,
    /// Quiet background colour.
    pub quiet: u32,
    /// Colour of text on the main colour.
    pub on: u32,
    /// Warning colour, if the accent has its own.
    pub warning: Option<u32>,
    /// Label key of the name.
    pub name_key: String,
}

fn accent_info(a: &LookAccent) -> LookAccentInfo {
    LookAccentInfo {
        id: a.id.to_owned(),
        main: a.main.hex,
        light: a.light.hex,
        quiet: a.quiet.hex,
        on: a.on.hex,
        warning: a.warning.map(|c| c.hex),
        name_key: a.name_key().to_owned(),
    }
}

/// One look.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LookInfo {
    /// Stable id.
    pub id: String,
    /// Label key of the name.
    pub name_key: String,
    /// Its accent.
    pub accent: LookAccentInfo,
    /// Glow colour.
    pub glow_color: u32,
    /// The glow it comes with (`off`, `soft`, ...).
    pub default_glow: String,
    /// Page background.
    pub background: u32,
    /// Gradient of the logo.
    pub logo_gradient: Vec<u32>,
    /// Alternate app icon.
    pub icon_name: Option<String>,
    /// A gift (free in its season).
    pub is_gift: bool,
    /// Id of its season, for gifts.
    pub season_id: Option<String>,
}

fn glow_name(glow: swiftly_support::look::LookGlow) -> String {
    serde_json::to_value(glow)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default()
}

fn look_info_of(l: &Look) -> LookInfo {
    LookInfo {
        id: l.id.to_owned(),
        name_key: l.name_key.to_owned(),
        accent: accent_info(&l.accent),
        glow_color: l.glow_color.hex,
        default_glow: glow_name(l.default_glow),
        background: l.background.hex,
        logo_gradient: l.logo_gradient.iter().map(|c: &LookColor| c.hex).collect(),
        icon_name: l.icon_name.map(str::to_owned),
        is_gift: l.is_gift,
        season_id: l.availability.map(|s| s.id.to_owned()),
    }
}

/// Every look, in picker order.
#[uniffi::export]
pub fn look_catalog() -> Vec<LookInfo> {
    Look::ALL.iter().map(look_info_of).collect()
}

/// The look with this id (the original for an unknown id).
#[uniffi::export]
pub fn look_info(id: String) -> LookInfo {
    look_info_of(&Look::with_id(&id))
}

/// What the person picked: a look and what they changed on it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LookSelectionInfo {
    /// The look id.
    pub look_id: String,
    /// Accent override.
    pub accent_id: Option<String>,
    /// Glow override.
    pub glow: Option<String>,
    /// `Some(false)` keeps the regular icon.
    pub uses_look_icon: Option<bool>,
}

fn selection_info(s: &LookSelection) -> LookSelectionInfo {
    LookSelectionInfo {
        look_id: s.look_id.clone(),
        accent_id: s.accent_id.clone(),
        glow: s.glow.map(glow_name),
        uses_look_icon: s.uses_look_icon,
    }
}

fn selection_of(s: &LookSelectionInfo) -> LookSelection {
    LookSelection {
        look_id: s.look_id.clone(),
        accent_id: s.accent_id.clone(),
        glow: s
            .glow
            .as_deref()
            .and_then(|g| serde_json::from_value(serde_json::Value::String(g.to_owned())).ok()),
        uses_look_icon: s.uses_look_icon,
    }
}

/// Reads a stored selection (JSON); anything unreadable gives the original look.
#[uniffi::export]
pub fn look_selection_read(data: Option<Vec<u8>>) -> LookSelectionInfo {
    selection_info(&LookSelection::decoded(data.as_deref()))
}

/// The JSON of a selection, sorted keys like the Swift encoder.
#[uniffi::export]
pub fn look_selection_write(selection: LookSelectionInfo) -> Vec<u8> {
    selection_of(&selection).encoded()
}

/// The colours a selection resolves to.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LookPaletteInfo {
    /// The look.
    pub look: LookInfo,
    /// Accent after the overrides.
    pub accent: LookAccentInfo,
    /// Glow after the overrides.
    pub glow: String,
    /// Alternate icon after the overrides.
    pub icon_name: Option<String>,
    /// Glow colour.
    pub glow_color: u32,
    /// Tint of the glow, if it shows.
    pub glow_tint: Option<u32>,
    /// Colour of the logo mark.
    pub mark_color: u32,
}

/// The palette of a selection.
#[uniffi::export]
pub fn look_palette(selection: LookSelectionInfo) -> LookPaletteInfo {
    let p = selection_of(&selection).palette();
    LookPaletteInfo {
        look: look_info_of(&p.look),
        accent: accent_info(&p.accent),
        glow: glow_name(p.glow),
        icon_name: p.icon_name.map(str::to_owned),
        glow_color: p.glow_color().hex,
        glow_tint: p.glow_tint().map(|c| c.hex),
        mark_color: p.mark_color().hex,
    }
}

// ---- seasons, gifts, effects ------------------------------------------------------------------

/// Whether the look's season is on at `now` (seconds since 1970) in a calendar `utc_offset` seconds from UTC.
/// Looks without a season are always available.
#[uniffi::export]
pub fn look_season_active(look_id: String, now: f64, utc_offset: i64) -> bool {
    Look::with_id(&look_id)
        .availability
        .is_none_or(|s| s.is_active(now, Calendar::fixed(utc_offset)))
}

/// The stored offer id of a gift in its season (`halloween-2026`).
#[uniffi::export]
pub fn look_gift_offer_id(look_id: String, now: f64, utc_offset: i64) -> Option<String> {
    LookGift::offer_id(&Look::with_id(&look_id), now, Calendar::fixed(utc_offset))
}

/// Where the bats and details are asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LookEffectPage {
    /// The rare bat.
    Home,
    /// The web in the corner of the look card.
    Profile,
    /// Only the accent.
    Detail,
    /// Any other page.
    Other,
}

/// What the effects check looks at.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LookEffectContext {
    /// The look worn.
    pub look_id: String,
    /// The clock.
    pub now: f64,
    /// The "bats and details" switch.
    pub switch_on: bool,
    /// Playback runs.
    pub playing: bool,
    /// Reduce Motion is on.
    pub reduce_motion: bool,
    /// Low Power Mode.
    pub low_power: bool,
    /// The app is in the foreground.
    pub foreground: bool,
}

fn page_of(p: LookEffectPage) -> EffectPage {
    match p {
        LookEffectPage::Home => EffectPage::Home,
        LookEffectPage::Profile => EffectPage::Profile,
        LookEffectPage::Detail => EffectPage::Detail,
        LookEffectPage::Other => EffectPage::Other,
    }
}

fn effect_context(c: &LookEffectContext) -> EffectContext {
    EffectContext {
        look: Look::with_id(&c.look_id),
        now: c.now,
        switch_on: c.switch_on,
        playing: c.playing,
        reduce_motion: c.reduce_motion,
        low_power: c.low_power,
        foreground: c.foreground,
    }
}

/// Whether the details (the web) show on this page.
#[uniffi::export]
pub fn look_effect_details(
    page: LookEffectPage,
    context: LookEffectContext,
    utc_offset: i64,
) -> bool {
    LookEffects::details(
        page_of(page),
        &effect_context(&context),
        Calendar::fixed(utc_offset),
    )
}

/// Why no bat flies (`wrong_page`, `switch_off`, `playing`, `outside_window`, `reduce_motion`, `low_power`,
/// `background`), or `None` when one may.
#[uniffi::export]
pub fn look_bat_block(
    page: LookEffectPage,
    context: LookEffectContext,
    utc_offset: i64,
) -> Option<String> {
    let block = LookEffects::bat_block(
        page_of(page),
        &effect_context(&context),
        Calendar::fixed(utc_offset),
    )?;
    Some(
        match block {
            BatBlock::WrongPage => "wrong_page",
            BatBlock::SwitchOff => "switch_off",
            BatBlock::Playing => "playing",
            BatBlock::OutsideWindow => "outside_window",
            BatBlock::ReduceMotion => "reduce_motion",
            BatBlock::LowPower => "low_power",
            BatBlock::Background => "background",
        }
        .to_owned(),
    )
}

/// The wait before the next bat in seconds; `unit` is a random number from 0 to 1 from the host.
#[uniffi::export]
pub fn look_bat_wait(first: bool, unit: f64) -> f64 {
    LookEffects::wait(first, unit)
}

/// Whether the "Look" row shows in the profile: `supporter_features` (the platform has them), the person
/// is a supporter, owns the look, and a gift is available.
#[uniffi::export]
pub fn look_profile_row_shows(
    supporter_features: bool,
    is_supporter: bool,
    owns_look: bool,
    gift_available: bool,
) -> bool {
    LookProfileEntry::shows_looks_row(
        LookProfileEntry::at(supporter_features, is_supporter, owns_look),
        gift_available,
    )
}

/// What to do with the app icon: `None` leaves it, `Some(name)` switches (an empty name puts the regular one
/// back).
#[uniffi::export]
pub fn look_icon_change(
    current_alternate: Option<String>,
    wanted: Option<String>,
) -> Option<String> {
    match look_icon_step(current_alternate.as_deref(), wanted.as_deref()) {
        IconStep::Keep => None,
        IconStep::Set(name) => Some(name.unwrap_or_default().to_owned()),
    }
}

/// The Mac Dock icon asset for a look icon.
#[uniffi::export]
pub fn look_dock_icon_name(icon: String) -> String {
    dock_icon_name(&icon)
}

// ---- the look store ---------------------------------------------------------------------------

/// What "Keep" did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LookKeep {
    /// Stored; the preview is closed.
    Kept,
    /// Nothing stored; open the support sheet.
    NeedsSupport,
    /// There was no preview.
    Nothing,
}

/// The look state over the host's store (selection, owned gifts, effects switch, offers made, try-on).
#[derive(uniffi::Object)]
pub struct LookModel {
    inner: Mutex<LookStore<TypedStore>>,
}

impl LookModel {
    pub(crate) fn build(kv: Arc<dyn KeyValueStore>) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(LookStore::load(TypedStore::new(kv))),
        })
    }
}

#[uniffi::export]
impl LookModel {
    /// The saved selection.
    pub fn selection(&self) -> LookSelectionInfo {
        selection_info(&lock(&self.inner).selection())
    }

    /// What is shown: the preview while trying on, else the saved selection.
    pub fn shown(&self) -> LookSelectionInfo {
        selection_info(&lock(&self.inner).state().shown())
    }

    /// Whether this selection may be worn (a supporter, or a free or owned look).
    pub fn may_wear(&self, selection: LookSelectionInfo) -> bool {
        lock(&self.inner)
            .state()
            .may_wear(&selection_of(&selection))
    }

    /// The stored choice, whatever is previewed or may be worn.
    pub fn saved(&self) -> LookSelectionInfo {
        selection_info(lock(&self.inner).state().saved())
    }

    /// Ids of the gifts picked up (sorted).
    pub fn owned(&self) -> Vec<String> {
        lock(&self.inner).state().owned().iter().cloned().collect()
    }

    /// Whether any gift was picked up.
    pub fn owns_look(&self) -> bool {
        !lock(&self.inner).state().owned().is_empty()
    }

    /// Whether the support state allows storing a look.
    pub fn is_supporter(&self) -> bool {
        lock(&self.inner).state().is_supporter()
    }

    /// Whether a preview is open.
    pub fn is_previewing(&self) -> bool {
        lock(&self.inner).state().is_previewing()
    }

    /// The "bats and details" switch.
    pub fn effects_on(&self) -> bool {
        lock(&self.inner).effects_on()
    }

    /// Sets the switch.
    pub fn set_effects_on(&self, on: bool) -> Result<(), CoreError> {
        lock(&self.inner).set_effects_on(on).map_err(failed)
    }

    /// The support status changed.
    pub fn set_supporter(&self, supporter: bool) -> Result<(), CoreError> {
        lock(&self.inner).set_supporter(supporter).map_err(failed)
    }

    /// A try-on starts.
    pub fn begin_preview(&self) -> Result<(), CoreError> {
        lock(&self.inner).begin_preview().map_err(failed)
    }

    /// Previews a selection.
    pub fn try_on(&self, selection: LookSelectionInfo) -> Result<(), CoreError> {
        lock(&self.inner)
            .try_on(selection_of(&selection))
            .map_err(failed)
    }

    /// The try-on is over; the saved look returns.
    pub fn end_preview(&self) -> Result<(), CoreError> {
        lock(&self.inner).end_preview().map_err(failed)
    }

    /// Keeps the previewed look.
    pub fn keep(&self) -> Result<LookKeep, CoreError> {
        Ok(match lock(&self.inner).keep().map_err(failed)? {
            KeepResult::Kept => LookKeep::Kept,
            KeepResult::NeedsSupport => LookKeep::NeedsSupport,
            KeepResult::Nothing => LookKeep::Nothing,
        })
    }

    /// The support sheet closed without a purchase.
    pub fn support_sheet_closed(&self) -> Result<(), CoreError> {
        lock(&self.inner).support_sheet_closed().map_err(failed)
    }

    /// A purchase completed; answers the look that was waiting to be kept.
    pub fn purchase_completed(&self) -> Result<Option<LookSelectionInfo>, CoreError> {
        Ok(lock(&self.inner)
            .purchase_completed()
            .map_err(failed)?
            .map(|s| selection_info(&s)))
    }

    /// Picks a selection; `false` if it may not be worn.
    pub fn choose(&self, selection: LookSelectionInfo) -> Result<bool, CoreError> {
        lock(&self.inner)
            .choose(selection_of(&selection))
            .map_err(failed)
    }

    /// Picks up a gift; answers the selection that now applies.
    pub fn claim(&self, look_id: String) -> Result<Option<LookSelectionInfo>, CoreError> {
        let look = Look::with_id(&look_id);
        Ok(lock(&self.inner)
            .claim(&look)
            .map_err(failed)?
            .map(|s| selection_info(&s)))
    }

    /// Back to the original look, gifts and offers forgotten, effects on.
    pub fn reset(&self) -> Result<(), CoreError> {
        lock(&self.inner).reset().map_err(failed)
    }

    /// Remembers that the pop-up for this gift was shown in this season.
    pub fn mark_offered(
        &self,
        look_id: String,
        now: f64,
        utc_offset: i64,
    ) -> Result<(), CoreError> {
        lock(&self.inner)
            .mark_offered(&Look::with_id(&look_id), now, Calendar::fixed(utc_offset))
            .map_err(failed)
    }

    /// The gift whose pop-up is due now, if any.
    pub fn gift_due(
        &self,
        now: f64,
        home_ready: bool,
        playing: bool,
        asked_this_session: bool,
        seconds_on_home: f64,
        utc_offset: i64,
    ) -> Option<String> {
        let store = lock(&self.inner);
        let ctx = store.gift_context(
            now,
            home_ready,
            playing,
            asked_this_session,
            seconds_on_home,
        );
        LookGift::due(&ctx, &Look::ALL, Calendar::fixed(utc_offset)).map(|l| l.id.to_owned())
    }

    /// Ids of the looks this person can pick from right now.
    pub fn free_looks(&self, now: f64, utc_offset: i64) -> Vec<String> {
        lock(&self.inner)
            .free_looks(now, Calendar::fixed(utc_offset))
            .iter()
            .map(|l| l.id.to_owned())
            .collect()
    }

    /// Ids of every look the picker shows, the locked ones too.
    pub fn picker_looks(&self, now: f64, utc_offset: i64) -> Vec<String> {
        lock(&self.inner)
            .picker_looks(now, Calendar::fixed(utc_offset))
            .iter()
            .map(|l| l.id.to_owned())
            .collect()
    }
}

// ---- the subtitle look ------------------------------------------------------------------------

/// Text size step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SubtitleSize {
    /// Small.
    Small,
    /// Normal.
    Normal,
    /// Large.
    Large,
    /// Huge.
    Huge,
}

/// Text colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SubtitleColour {
    /// White.
    White,
    /// Yellow.
    Yellow,
    /// Grey.
    Grey,
}

/// Outline step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SubtitleOutline {
    /// None.
    Off,
    /// Thin.
    Thin,
    /// Normal.
    Normal,
}

/// Position.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SubtitlePosition {
    /// At the bottom.
    Bottom,
    /// Raised.
    Raised,
}

/// The subtitle look (`utAussehen`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SubtitleLookInfo {
    /// Box behind the text.
    pub background: bool,
    /// Text colour.
    pub colour: SubtitleColour,
    /// ASS and SSA are drawn by their own file.
    pub keep_file_style: bool,
    /// Outline step.
    pub outline: SubtitleOutline,
    /// Position.
    pub position: SubtitlePosition,
    /// Hard shadow.
    pub shadow: bool,
    /// Size step.
    pub size: SubtitleSize,
}

/// One named player option.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SubtitleOption {
    /// Option name.
    pub name: String,
    /// Option value.
    pub value: String,
}

fn subtitle_of(l: &SubtitleLookInfo) -> SubtitleLook {
    SubtitleLook {
        background: l.background,
        colour: match l.colour {
            SubtitleColour::White => Colour::White,
            SubtitleColour::Yellow => Colour::Yellow,
            SubtitleColour::Grey => Colour::Grey,
        },
        keep_file_style: l.keep_file_style,
        outline: match l.outline {
            SubtitleOutline::Off => Outline::Off,
            SubtitleOutline::Thin => Outline::Thin,
            SubtitleOutline::Normal => Outline::Normal,
        },
        position: match l.position {
            SubtitlePosition::Bottom => Position::Bottom,
            SubtitlePosition::Raised => Position::Raised,
        },
        shadow: l.shadow,
        size: match l.size {
            SubtitleSize::Small => Size::Small,
            SubtitleSize::Normal => Size::Normal,
            SubtitleSize::Large => Size::Large,
            SubtitleSize::Huge => Size::Huge,
        },
    }
}

fn subtitle_info(l: &SubtitleLook) -> SubtitleLookInfo {
    SubtitleLookInfo {
        background: l.background,
        colour: match l.colour {
            Colour::White => SubtitleColour::White,
            Colour::Yellow => SubtitleColour::Yellow,
            Colour::Grey => SubtitleColour::Grey,
        },
        keep_file_style: l.keep_file_style,
        outline: match l.outline {
            Outline::Off => SubtitleOutline::Off,
            Outline::Thin => SubtitleOutline::Thin,
            Outline::Normal => SubtitleOutline::Normal,
        },
        position: match l.position {
            Position::Bottom => SubtitlePosition::Bottom,
            Position::Raised => SubtitlePosition::Raised,
        },
        shadow: l.shadow,
        size: match l.size {
            Size::Small => SubtitleSize::Small,
            Size::Normal => SubtitleSize::Normal,
            Size::Large => SubtitleSize::Large,
            Size::Huge => SubtitleSize::Huge,
        },
    }
}

/// The built-in look.
#[uniffi::export]
pub fn subtitle_look_standard() -> SubtitleLookInfo {
    subtitle_info(&SubtitleLook::STANDARD)
}

/// Reads a stored look (JSON, tolerant: a missing or unreadable field takes its default).
#[uniffi::export]
pub fn subtitle_look_read(data: Option<Vec<u8>>) -> SubtitleLookInfo {
    subtitle_info(&SubtitleLook::read(data.as_deref()))
}

/// The stable JSON of a look (the value of the synced `utAussehen` setting).
#[uniffi::export]
pub fn subtitle_look_write(look: SubtitleLookInfo) -> Vec<u8> {
    subtitle_of(&look).encoded()
}

/// Whether everything is on its default.
#[uniffi::export]
pub fn subtitle_look_is_standard(look: SubtitleLookInfo) -> bool {
    subtitle_of(&look).is_standard()
}

/// The VLC text options (`vlc4` is the VLC 4 build on Apple, else VLC 3).
#[uniffi::export]
pub fn subtitle_look_vlc_options(
    look: SubtitleLookInfo,
    base_scale: f64,
    output_height: i64,
    vlc4: bool,
) -> Vec<String> {
    let engine = if vlc4 {
        Engine::Vlc4Apple
    } else {
        Engine::Vlc3
    };
    subtitle_of(&look).vlc_options(base_scale, output_height, engine)
}

/// The mpv options for the look at this output height and font family.
#[uniffi::export]
pub fn subtitle_look_mpv_options(
    look: SubtitleLookInfo,
    output_height: i64,
    font: String,
) -> Vec<SubtitleOption> {
    subtitle_of(&look)
        .mpv_style(output_height, &font)
        .options()
        .into_iter()
        .map(|(name, value)| SubtitleOption { name, value })
        .collect()
}

/// The text scale in percent for a base scale.
#[uniffi::export]
pub fn subtitle_look_text_scale_percent(look: SubtitleLookInfo, base_scale: f64) -> i64 {
    subtitle_of(&look).text_scale_percent(base_scale)
}

/// The preview size in points for a picture height.
#[uniffi::export]
pub fn subtitle_look_preview_points(
    look: SubtitleLookInfo,
    picture_height: f64,
    base_scale: f64,
) -> f64 {
    subtitle_of(&look).preview_points(picture_height, base_scale)
}

/// The six label keys of the look's sentence.
#[uniffi::export]
pub fn subtitle_look_sentence_keys(look: SubtitleLookInfo) -> Vec<String> {
    subtitle_of(&look)
        .sentence_keys()
        .iter()
        .map(|k| (*k).to_owned())
        .collect()
}

// ---- support ----------------------------------------------------------------------------------

/// The platform, for the support prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SupportPlatformKind {
    /// iPhone.
    IPhone,
    /// iPad.
    IPad,
    /// Mac.
    Mac,
    /// Apple TV.
    AppleTv,
    /// Android.
    Android,
    /// Android TV.
    AndroidTv,
    /// Linux.
    Linux,
    /// Windows.
    Windows,
}

fn platform_of(p: SupportPlatformKind) -> SupportPlatform {
    match p {
        SupportPlatformKind::IPhone => SupportPlatform::IPhone,
        SupportPlatformKind::IPad => SupportPlatform::IPad,
        SupportPlatformKind::Mac => SupportPlatform::Mac,
        SupportPlatformKind::AppleTv => SupportPlatform::AppleTv,
        SupportPlatformKind::Android => SupportPlatform::Android,
        SupportPlatformKind::AndroidTv => SupportPlatform::AndroidTv,
        SupportPlatformKind::Linux => SupportPlatform::Linux,
        SupportPlatformKind::Windows => SupportPlatform::Windows,
    }
}

/// The support status.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SupportStatusInfo {
    /// A supporter.
    pub supporter: bool,
    /// `store` or `key` for a supporter.
    pub source: Option<String>,
    /// When this device learned about it.
    pub since: Option<f64>,
}

/// What the support prompt decides.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SupportDecision {
    /// The "Support Swiftly" entry in Settings and About.
    pub shows_heart: bool,
    /// The card at the end of the home page.
    pub shows_card: bool,
    /// The one-time thank-you sheet.
    pub shows_sheet: bool,
}

/// Support state over the host's store: status, usage, prompt history, watch time.
#[derive(uniffi::Object)]
pub struct SupportModel {
    store: SupportStore<TypedStore>,
    counter: Mutex<WatchTimeCounter>,
}

impl SupportModel {
    pub(crate) fn build(kv: Arc<dyn KeyValueStore>) -> Arc<Self> {
        let store = SupportStore::new(TypedStore::new(kv));
        let counter = WatchTimeCounter::new(store.usage().watched_seconds);
        Arc::new(Self {
            store,
            counter: Mutex::new(counter),
        })
    }
}

#[uniffi::export]
impl SupportModel {
    /// The status.
    pub fn status(&self) -> SupportStatusInfo {
        match self.store.status() {
            SupportStatus::None => SupportStatusInfo {
                supporter: false,
                source: None,
                since: None,
            },
            SupportStatus::Supporter { source, since } => SupportStatusInfo {
                supporter: true,
                source: Some(
                    match source {
                        Source::Store => "store",
                        Source::Key => "key",
                    }
                    .to_owned(),
                ),
                since,
            },
        }
    }

    /// Stores the status; a source other than `store` or `key` counts as `store`.
    pub fn set_status(&self, status: SupportStatusInfo) -> Result<(), CoreError> {
        let value = if status.supporter {
            let source = if status.source.as_deref() == Some("key") {
                Source::Key
            } else {
                Source::Store
            };
            SupportStatus::Supporter {
                source,
                since: status.since,
            }
        } else {
            SupportStatus::None
        };
        self.store.set_status(value).map_err(failed)
    }

    /// Hours watched so far.
    pub fn watched_hours(&self) -> i64 {
        lock(&self.counter).watched_hours()
    }

    /// Notes a start of the app.
    pub fn record_launch(&self, now: f64) -> Result<(), CoreError> {
        self.store.record_launch(now).map_err(failed)
    }

    /// One observation of playback; saves about once a minute.
    pub fn playback_progress(&self, is_playing: bool, at: f64) -> Result<(), CoreError> {
        let mut c = lock(&self.counter);
        c.playback_progress(is_playing, at);
        self.save_if_needed(&mut c)
    }

    /// Playback ended, the player closed or the app went to the background; saves.
    pub fn playback_stopped(&self, at: f64) -> Result<(), CoreError> {
        let mut c = lock(&self.counter);
        c.playback_stopped(at);
        self.store.save(&mut c).map_err(failed)
    }

    /// The card was snoozed.
    pub fn snooze_card(&self, now: f64) -> Result<(), CoreError> {
        let mut h = self.store.prompt_history();
        h.snooze_card(now);
        self.store.set_prompt_history(&h).map_err(failed)
    }

    /// The card was dismissed for good.
    pub fn dismiss_card(&self) -> Result<(), CoreError> {
        let mut h: SupportPromptHistory = self.store.prompt_history();
        h.dismiss_card();
        self.store.set_prompt_history(&h).map_err(failed)
    }

    /// The thank-you sheet was shown.
    pub fn record_sheet_shown(&self, now: f64) -> Result<(), CoreError> {
        let mut h = self.store.prompt_history();
        h.record_sheet_shown(now);
        self.store.set_prompt_history(&h).map_err(failed)
    }

    /// What to show now.
    pub fn decide(
        &self,
        now: f64,
        is_playing: bool,
        seconds_since_launch: f64,
        platform: SupportPlatformKind,
        utc_offset: i64,
    ) -> SupportDecision {
        let history = self.store.prompt_history();
        let usage = SupportUsage {
            watched_seconds: lock(&self.counter).total_seconds(),
            ..self.store.usage()
        };
        let d = SupportPrompt::decide(
            &PromptContext {
                now,
                status: self.store.status(),
                usage,
                history: &history,
                is_playing,
                seconds_since_launch,
                platform: platform_of(platform),
            },
            Calendar::fixed(utc_offset),
        );
        SupportDecision {
            shows_heart: d.shows_heart,
            shows_card: d.shows_card,
            shows_sheet: d.shows_sheet,
        }
    }
}

impl SupportModel {
    fn save_if_needed(&self, c: &mut WatchTimeCounter) -> Result<(), CoreError> {
        if c.needs_save() {
            self.store.save(c).map_err(failed)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Mem(Mutex<HashMap<String, Vec<u8>>>);
    impl KeyValueStore for Mem {
        fn get(&self, key: String) -> Option<Vec<u8>> {
            lock(&self.0).get(&key).cloned()
        }
        fn set(&self, key: String, value: Vec<u8>) {
            lock(&self.0).insert(key, value);
        }
        fn remove(&self, key: String) {
            lock(&self.0).remove(&key);
        }
    }

    fn kv() -> Arc<dyn KeyValueStore> {
        Arc::new(Mem::default())
    }

    #[test]
    fn catalog_and_selection_round_trip() {
        let cat = look_catalog();
        assert_eq!(cat.len(), Look::ALL.len());
        assert!(cat.iter().any(|l| l.is_gift && l.season_id.is_some()));
        let sel = LookSelectionInfo {
            look_id: "sunset".into(),
            accent_id: None,
            glow: None,
            uses_look_icon: Some(false),
        };
        assert_eq!(
            look_selection_read(Some(look_selection_write(sel.clone()))),
            sel
        );
        assert_eq!(
            look_selection_read(Some(b"broken".to_vec())).look_id,
            look_selection_read(None).look_id
        );
        assert_eq!(look_palette(sel).look.id, "sunset");
    }

    #[test]
    fn try_on_needs_support_then_keeps_after_the_purchase() {
        let m = LookModel::build(kv());
        let sunset = LookSelectionInfo {
            look_id: "sunset".into(),
            accent_id: None,
            glow: None,
            uses_look_icon: None,
        };
        assert!(!m.may_wear(sunset.clone()));
        m.begin_preview().unwrap();
        m.try_on(sunset.clone()).unwrap();
        assert!(m.is_previewing());
        assert_eq!(m.shown().look_id, "sunset");
        assert_eq!(m.keep().unwrap(), LookKeep::NeedsSupport);
        m.set_supporter(true).unwrap();
        assert_eq!(
            m.purchase_completed().unwrap().map(|s| s.look_id),
            Some("sunset".to_owned())
        );
        assert_eq!(m.selection().look_id, "sunset");
        // A second model over the same store sees the choice only when it was stored.
        m.reset().unwrap();
        assert!(m.effects_on());
    }

    #[test]
    fn owned_and_supporter_reads_follow_changes() {
        let m = LookModel::build(kv());
        assert!(!m.is_supporter() && !m.owns_look() && m.owned().is_empty());
        assert_eq!(m.saved().look_id, m.selection().look_id);
        m.set_supporter(true).unwrap();
        assert!(m.is_supporter());
        let gift = look_catalog()
            .into_iter()
            .find(|l| l.is_gift && l.season_id.is_some())
            .unwrap()
            .id;
        let sel = m.claim(gift.clone()).unwrap();
        assert!(sel.is_some());
        assert_eq!(m.owned(), vec![gift]);
        assert!(m.owns_look());
        m.reset().unwrap();
        assert!(m.owned().is_empty());
    }

    #[test]
    fn a_gift_is_due_once_per_season() {
        let m = LookModel::build(kv());
        let cal = Calendar::UTC;
        let day = cal.timestamp(2026, 10, 31, 12, 0);
        let due = m.gift_due(day, true, false, false, 10.0, 0).expect("due");
        assert!(look_season_active(due.clone(), day, 0));
        assert!(look_gift_offer_id(due.clone(), day, 0).is_some());
        assert!(m.gift_due(day, true, true, false, 10.0, 0).is_none());
        m.mark_offered(due, day, 0).unwrap();
        assert!(m.gift_due(day, true, false, false, 10.0, 0).is_none());
        assert!(!m.free_looks(day, 0).is_empty());
    }

    #[test]
    fn subtitle_look_json_round_trips_and_is_tolerant() {
        let std = subtitle_look_standard();
        assert!(subtitle_look_is_standard(std));
        let custom = SubtitleLookInfo {
            size: SubtitleSize::Large,
            shadow: true,
            ..std
        };
        assert_eq!(
            subtitle_look_read(Some(subtitle_look_write(custom))),
            custom
        );
        assert_eq!(
            subtitle_look_read(Some(br#"{"size":"large","colour":"nope"}"#.to_vec())).size,
            SubtitleSize::Large
        );
        assert_eq!(subtitle_look_read(None), std);
        assert!(!subtitle_look_vlc_options(custom, 0.82, 1080, true).is_empty());
        assert!(!subtitle_look_mpv_options(custom, 1080, "Sans".into()).is_empty());
        assert_eq!(subtitle_look_sentence_keys(std).len(), 6);
    }

    #[test]
    fn support_prompt_waits_for_two_hours_and_a_quiet_minute() {
        let m = SupportModel::build(kv());
        assert!(!m.status().supporter);
        let t0 = 1_800_000_000.0;
        m.record_launch(t0).unwrap();
        let early = m.decide(t0 + 10.0, false, 10.0, SupportPlatformKind::IPhone, 0);
        assert!(early.shows_heart && !early.shows_card && !early.shows_sheet);
        m.set_status(SupportStatusInfo {
            supporter: true,
            source: Some("key".into()),
            since: Some(t0),
        })
        .unwrap();
        assert_eq!(m.status().source.as_deref(), Some("key"));
        // Watching: one tick playing, one tick a few seconds later, then stop.
        m.playback_progress(true, t0).unwrap();
        m.playback_progress(true, t0 + 20.0).unwrap();
        m.playback_stopped(t0 + 25.0).unwrap();
        assert_eq!(m.watched_hours(), 0);
        m.dismiss_card().unwrap();
    }

    #[test]
    fn effects_and_icons_follow_the_rules() {
        let ctx = LookEffectContext {
            look_id: "halloween".into(),
            now: Calendar::UTC.timestamp(2026, 10, 31, 12, 0),
            switch_on: true,
            playing: false,
            reduce_motion: false,
            low_power: false,
            foreground: true,
        };
        assert_eq!(look_bat_block(LookEffectPage::Home, ctx.clone(), 0), None);
        assert_eq!(
            look_bat_block(LookEffectPage::Other, ctx.clone(), 0).as_deref(),
            Some("wrong_page")
        );
        let calm = LookEffectContext {
            reduce_motion: true,
            ..ctx
        };
        assert_eq!(
            look_bat_block(LookEffectPage::Home, calm, 0).as_deref(),
            Some("reduce_motion")
        );
        assert!((look_bat_wait(true, 0.5) - 6.0).abs() < 1e-9);
        assert_eq!(look_icon_change(None, None), None);
        assert_eq!(
            look_dock_icon_name("AppIcon-Halloween".into()),
            "DockIcon-Halloween"
        );
    }
}
