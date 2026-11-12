//! Jellyfin/Emby data models, ported 1:1 from `Packages/JellyfinKit` (Swift).
//!
//! Wire types decode exactly as the Swift `Codable` types do: PascalCase keys,
//! every optional field an `Option`, one unreadable list entry is skipped
//! instead of failing the whole response ([`Lenient`]), numbers that arrive as
//! text or float are tolerated ([`NumberValue`]), unknown enum values never
//! fail a decode. Derived properties of [`Item`] are methods with the same
//! results. UI text goes through the [`Localizer`] hook; the catalog itself
//! lives in another crate.
#![deny(missing_docs)]

mod l10n;
mod lenient;
mod media;
mod server;
mod time;
mod versions;
mod works;

pub mod item;

pub use item::{Item, ItemKind, MediaUrl, NameId, Person, UserItemData};
pub use l10n::{Localizer, Source};
pub use lenient::{Lenient, NumberValue};
pub use media::{
    ColorRange, DeliveryMethod, MediaSource, MediaStream, PlaybackInfoResponse, codec_name,
};
pub use server::{AuthenticationResult, ItemsResponse, PublicSystemInfo, User};
pub use time::{parse_timestamp, seconds_from_ticks, ticks_from_seconds};
pub use versions::{MediaVersions, VersionStart};
pub use works::{Items, SeriesNumber};
