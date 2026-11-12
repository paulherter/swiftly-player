//! Watching together, settings that follow the account, and the remote-control channel.
//!
//! Ported from `JellyfinKit` (`SyncPlay.swift`, `SyncPlaySession.swift`, `SettingsSync.swift`,
//! `RemoteControl.swift`). Everything is sans-IO: times are `f64` seconds since 1970 passed in by
//! the caller (the clock seam), the player is a [`session::PlayerView`] snapshot plus
//! [`session::Effect`]s to execute, HTTP goes through `swiftly_net::HttpTransport`, and the
//! WebSocket is the [`remote::RemoteLink`] trait.

pub mod api;
pub mod remote;
pub mod session;
pub mod settings;
pub mod sync_state;
pub mod syncplay;
pub mod time;

pub use api::{CallResult, Clock, ServerCtx, SyncPlayCall, SyncPlayClient};
pub use remote::{
    KEEP_ALIVE, KEEP_ALIVE_INTERVAL, LinkError, PlayOrder, RemoteCommand, RemoteControl,
    RemoteLink, RemoteOutput,
};
pub use session::{
    Effect, PlayerAction, PlayerView, SyncPlayError, SyncPlaySession, SyncPlayStatus,
};
pub use settings::{Decision, DisplayPreferencesCopy, Kind, SettingsSync, Value};
pub use sync_state::{SyncEvent as SettingsSyncEvent, SyncPhase as SettingsSyncPhase};
pub use syncplay::{
    BufferGuard, SyncPlay, SyncPlayCommand, SyncPlayExecution, SyncPlayGroup,
    SyncPlayPostDirection, SyncPlayQueue, SyncPlayRight, TimeReconcile,
};
