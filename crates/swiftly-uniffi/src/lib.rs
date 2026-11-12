//! The only exported surface of the Swiftly core. Slice 1: a hello surface that proves async
//! calls, cancellation and foreign (Swift-implemented) traits through UniFFI. Slice 2: the
//! home view model (`Core::home_vm`) with the core's own HTTP and the host's stores.

mod accounts;
mod airplay;
mod core;
mod detail;
mod diagnostics;
mod downloads;
mod error;
mod hello;
mod home;
mod images;
mod legacy;
mod legacy_bundle;
mod legacy_detail;
mod legacy_downloads;
mod legacy_handoff;
mod legacy_library;
mod legacy_login;
mod legacy_looks;
mod legacy_playback;
mod legacy_player;
mod legacy_plex_detail;
mod legacy_search;
mod legacy_seerr;
mod legacy_statics;
mod legacy_support;
#[cfg(test)]
mod legacy_support_golden;
mod library;
mod load_selection;
mod login;
mod looks;
mod pages;
mod play_start;
mod player;
mod plex_live;
mod plex_sign_in;
mod probe;
mod remote;
mod rules;
mod search;
mod seerr;
mod settings;
mod settings_sync;
mod state;
mod state_more;
mod sync_play;
mod visual;
pub use state_more::{
    DiscoveryPhaseState, DiscoveryStep, DownloadItemEvent, DownloadItemPhase, DownloadNetwork,
    DownloadPausedBy, DownloadQueuePhase, NextCardEvent, NextCardState, QuickConnectEvent,
    QuickConnectPhase, ServerProbeEvent, ServerProbeState, SettingsSyncEventKind,
    SettingsSyncPhaseState,
};
mod forwarder;
mod seerr_screen;
mod stores;
mod support;
mod takeover;
mod takeover_calls;
mod transport;
mod update;

pub use accounts::{
    AccountDefaultsInfo, AccountInfo, AccountsModel, PublicUserInfo, QuickCode,
    QuickConnectListener, QuickEnd, RevokedInfo, ServerCheck, SignedIn,
};
pub use core::{Core, Platform};
pub use detail::{
    DetailEffect, DetailIntent, DetailOptions, DetailVm, EpisodesPart, MorePart, PlayOnDevice,
    SeriesEffect, SeriesIntent, SeriesOptions, SeriesVm,
};
pub use diagnostics::{
    DiscordAction, DiscordDisplayInfo, DiscordPresenceModel, DiscordSocketEnv,
    DiscordSocketPlatform, DiscordStep, LogRingModel, LogoMeasurement, LogoSize, MarksFrame,
    log_redact, log_share_text, title_marks_density_factor, title_marks_is_dark,
    title_marks_measure, title_marks_size,
};
pub use downloads::{
    DownloadHost, DownloadRequest, DownloadsIntent, DownloadsVm, RunningTransferInfo,
};
pub use error::CoreError;
pub use hello::{HelloChange, HelloIntent, HelloState, HelloVm};
pub use home::HomeVm;
pub use images::{ImageDevice, ImageLoader, ImagePixels, ImagePriority, ImageSlot, ImageStats};
pub use library::{LibrarySpec, LibraryVm};
pub use login::{
    DatagramHost, DiscoverInterface, DiscoverTiming, FoundServerInfo, LoginModel, LoginScreenKind,
    LoginState, ServerReminderInfo, discover, discover_parse, discover_probe, discover_targets,
    discover_timing,
};
pub use looks::{
    LookAccentInfo, LookEffectContext, LookEffectPage, LookInfo, LookKeep, LookModel,
    LookPaletteInfo, LookSelectionInfo, SubtitleColour, SubtitleLookInfo, SubtitleOption,
    SubtitleOutline, SubtitlePosition, SubtitleSize, SupportDecision, SupportModel,
    SupportPlatformKind, SupportStatusInfo, look_bat_block, look_bat_wait, look_catalog,
    look_dock_icon_name, look_effect_details, look_gift_offer_id, look_icon_change, look_info,
    look_palette, look_profile_row_shows, look_season_active, look_selection_read,
    look_selection_write, subtitle_look_is_standard, subtitle_look_mpv_options,
    subtitle_look_preview_points, subtitle_look_read, subtitle_look_sentence_keys,
    subtitle_look_standard, subtitle_look_text_scale_percent, subtitle_look_vlc_options,
    subtitle_look_write,
};
pub use pages::{
    DateText, PersonInfo, PersonModel, PersonPage, PlaylistEmptyText, PlaylistModel, PlaylistPage,
};
pub use player::{PlayerEngine, PlayerIntent, PlayerStart, PlayerVm};
pub use seerr::{
    SeerrConnection, SeerrCookieJar, SeerrModel, own_header_name_suits, own_headers_cleaned,
    own_headers_of, set_own_headers,
};
pub use settings_sync::{
    SeerrSyncOutcome, SettingsSyncModel, SettingsSyncOutcome, SettingsSyncRound, SyncEntry,
    SyncSetting, settings_sync_entries,
};
pub use state::{
    AccountSessionEvent, AccountSessionPart, AccountSessionState, AccountSignInMethod,
    ControlsStage, LoadFailKind, LoadPart, LoadState, PlayerResume, PlayerStageState,
    PlayerSurface, PlayerSurfaceEvent, SeekChainState, SeekSide,
};
pub use sync_play::{
    SyncPlayCurrent, SyncPlayGroupRow, SyncPlayHost, SyncPlayModel, SyncPlayPage, SyncPlayPlayer,
    SyncPlayStep,
};
pub use visual::{
    LicenseEntry, MoodMesh, MoodPoint, ToneGridPoint, detail_mood_mesh, licenses_for_platform,
    mood_mesh, mood_noise_tile, picture_tones, tone_grid,
};
// Types of the engine seam, for tests and tools that implement a host engine.
pub use forwarder::{
    ForwardAction, ForwardBacklog, ForwardRequest, ForwardTarget, StreamForwardHost,
    StreamForwarder, audio_output_should_rebuild, forward_find_head_end, forward_method_allowed,
    forward_request, forward_response_head,
};
pub use player::{
    PlayerBuffer, PlayerEngineEvent, PlayerEngineState, PlayerLoad, PlayerMethod, PlayerPip,
    PlayerRect, PlayerStream, PlayerSubtitleRoute,
};
pub use probe::{
    EngineEvent, EngineLoad, EngineProbe, EngineState, PlayerProbe, ProbeReport, SubtitleRoute,
};
pub use remote::{
    RemoteChannel, RemoteCommandKind, RemoteEvent, RemoteListener, RemotePlayOrder, SocketFailure,
    WebSocketLink,
};
pub use rules::{
    HostSubtitleFile, HostTrack, HostTrackMapping, SubtitleCueIndex, audio_is_original,
    audio_label_with_original, map_host_tracks, matching_next_version, migrate_subtitle_auto,
};
pub use search::SearchVm;
pub use seerr_screen::{
    SeerrCastInfo, SeerrDiscoverInfo, SeerrPageInfo, SeerrScreen, SeerrSeasonInfo, SeerrTileInfo,
};
pub use settings::{SettingsFacts, SettingsIntent, SettingsPlatform, SettingsVm};
pub use stores::{KeyValueStore, SecretStore};
pub use support::{
    WhatsNewAction, WhatsNewLine, WhatsNewSheet, readable_network_error, version_is_newer,
    whats_new_decide, whats_new_sheet,
};
pub use takeover::{
    HandoffEffect, HandoffEvent, HandoffFlowModel, TakeoverCard, TakeoverDevice, TakeoverModel,
    TakeoverRowInfo, TakeoverState, takeover_is_handoff, takeover_start_point,
};
pub use transport::{
    ForeignTransport, HttpClient, HttpFailure, NetHeader, NetMethod, NetRequest, NetResponse,
};

uniffi::setup_scaffolding!();
