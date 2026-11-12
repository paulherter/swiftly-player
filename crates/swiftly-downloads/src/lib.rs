//! Download rules and the download-manager state machine of the Swiftly core.
//!
//! Ported 1:1 from `Downloads.swift`, `DownloadTask.swift`, `DownloadManager.swift` (rules and
//! persistence behaviour, not its `URLSession` plumbing) and `LoadSelection.swift`. Quality,
//! permission and audio choice already live in `swiftly-rules` and are re-exported, not copied.
//!
//! * [`DownloadItem`], [`DownloadState`], [`DownloadGroup`], [`PathPart`]: the model, with the
//!   exact Swift `Codable` keys (`liste.json` stays readable, see [`list`]).
//! * [`DownloadRules`]: who loads next, Wi-Fi rule, space padding and slot, grouping, offline
//!   episode rules.
//! * [`LoadSelection`]: the pure selection logic behind the series download sheet.
//! * [`DownloadManagerState`]: a pure state machine. Intents go in, [`Effect`]s come out; nothing
//!   here touches the network, the disk or a clock.
//! * [`DownloadTransport`]: what a platform implements to do the transfer.
//!
//! Time is `f64` seconds since 1970 everywhere; only the JSON uses Swift's reference date (2001).

pub mod group;
pub mod item;
pub mod list;
pub mod load_selection;
pub mod machine;
pub mod manager;
pub mod rules;
pub mod size_text;
pub mod state;
pub mod task;
pub mod transport;

pub use group::DownloadGroup;
pub use item::{Art, DownloadItem, PathPart};
pub use list::{LoadedList, decode_list, encode_list, load_list, merge_for_write};
pub use load_selection::{CheckboxState, LoadSelection};
pub use machine::{ItemEvent, ItemPhase, Network, PausedBy, QueuePhase};
pub use manager::{
    DownloadManagerState, Effect, FileKind, Intent, NetworkInfo, REASON_NO_ADDRESS,
    REASON_NOT_ENOUGH_SPACE, REASON_NOT_STORED, Report, RunningTransfer,
};
pub use rules::{
    DownloadRules, FootSpace, NetworkVerdict, PADDING, POINT_OFF, ProgressEstimator, ProgressSync,
    SpaceInfo, SyncEvent, SyncRefused, WATCHED_OFF,
};
pub use state::DownloadState;
pub use task::{DownloadTask, TaskParts};
pub use transport::{DownloadTransport, TransferEvent, apply_effect};

pub use swiftly_rules::download_audio::{
    AudioStream, AudioTrackRules, DownloadAudioChoice, DownloadAudioOption,
};
pub use swiftly_rules::download_quality::DownloadQuality;
pub use swiftly_rules::download_right::DownloadPermission;
