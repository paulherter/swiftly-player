//! Looks, supporter rules and copy, the subtitle look and licence data.
//!
//! Pure logic, sans-I/O: the clock and a calendar offset are passed in, storage goes through
//! [`swiftly_settings::KeyValueStore`]. Ported from `Packages/JellyfinKit` (`Look*.swift`,
//! `Support*.swift`, `SubtitleLook.swift`) and the Apple app's `LookStore.swift`.
//!
//! - [`look`], [`season`], [`try_on`], [`gift`], [`look_store`]: the look system.
//! - [`support`], [`copy`]: status, usage, prompt rules, watch-time feed, German/English copy,
//!   tips, product ids, supporter icons.
//! - [`subtitle`]: `SubtitleLook`, its VLC options and the mpv mapping.
//! - [`licenses`]: the typed `LICENSES/components.json`.

pub mod copy;
pub mod discord;
pub mod gift;
pub mod licenses;
pub mod log_ring;
pub mod look;
pub mod look_store;
pub mod marks;
pub mod season;
pub mod subtitle;
pub mod support;
#[cfg(feature = "supporter-key")]
pub mod supporter_key;
pub mod time;
pub mod try_on;

pub use copy::{SupportCopy, SupportProductId, SupportTip, SupporterIcon};
pub use gift::{
    BatBlock, EffectContext, EffectPage, GiftContext, LookEffects, LookGift, LookProfileEntry,
};
pub use look::{Look, LookAccent, LookColor, LookGlow, LookPalette, LookSelection};
pub use look_store::{IconStep, LookStore, dock_icon_name, look_icon_step};
pub use season::LookSeason;
pub use subtitle::SubtitleLook;
pub use support::{
    Decision, PromptContext, Source, SupportPlan, SupportPlatform, SupportPrompt,
    SupportPromptHistory, SupportStatus, SupportStore, SupportUsage, WatchTimeCounter,
    WatchTimeFeed,
};
pub use time::{Calendar, MonthDay, Timestamp};
pub use try_on::{KeepResult, LookTryOn};
