//! View models of the Swiftly core (ARCHITECTURE.md D3), without any UI or FFI types.
//!
//! * [`HomeVm`]: the home page. Parts: [`RailsPart`] and [`StatusPart`]. Intents:
//!   [`HomeIntent`]. Observation: [`HomeVm::changed`].
//! * [`LibraryVm`]: the grid of a library, collection or genre (sort, filter, paging).
//! * [`SearchVm`]: search with debounce, result groups and recent terms.
//! * [`SettingsVm`]: sections and rows for every setting, validated writes through the store.
//! * [`DownloadsVm`]: the download list, per-title progress, storage summary and intents.
//! * [`Host`]: what a view model needs from its host (spawner, clock, snapshot store, locale).
//!
//! A view model is generic over the HTTP transport, so tests use `MockTransport` and the app
//! uses reqwest. Display text is produced here from the German key through `swiftly-l10n`; a
//! view only draws.
#![deny(missing_docs)]

mod account;
mod admin_words;
mod bell;
mod cache;
pub mod core_words;
mod detail;
pub use detail::{account_directory, fetch_plan_for, replan_for_subtitle};
mod detail_more;
mod downloads_vm;
mod history;
mod home;
mod home_fail_fast;
pub mod home_rows;
mod home_views;
mod host;
mod language_data;
pub mod language_list;
mod language_names;
mod legacy_detail;
mod legacy_downloads;
mod legacy_downloads_server;
mod legacy_home;
mod legacy_library;
mod legacy_lists;
mod legacy_playback;
mod legacy_playback_run;
mod legacy_search;
mod legacy_section;
mod library;
mod library_list;
mod load_state;
mod login;
mod next_card;
mod offered;
mod parts;
mod person;
mod play_display;
mod player;
mod player_controls;
mod player_extra;
mod player_menu;
mod player_more;
mod player_report;
mod player_stage;
mod player_start;
mod player_switch;
mod playlist;
mod plex;
pub mod plex_sign_in;
mod prefetch;
mod profile_entry;
mod progress_beat;
mod proof_mark;
mod search;
mod seed;
mod seerr;
mod seerr_admin;
mod seerr_admin_io;
mod seerr_delete;
mod seerr_delete_io;
mod seerr_io;
mod seerr_lists;
mod seerr_my_requests;
mod seerr_report;
mod seerr_setup;
mod seerr_stash;
mod seerr_title;
mod series;
mod server;
pub mod server_admin;
mod server_probe;
mod settings_sync_run;
mod settings_vm;
mod shared;
mod stale_lists;
mod start_settings;
pub mod subtitle_search;
pub mod subtitle_sidecar;
mod tile;
mod tile_details;
mod title_text;
mod track_names;
mod transcode_reason;

pub use account::AccountRef;
pub use admin_words::{ADMIN_KEYS, AdminWords};
pub use bell::{Change, Changed, part};
pub use cache::{CachedPage, ViewCache};
pub use detail::{
    ActionsPart, BottomPart, CastTile, DetailEffect, DetailIntent, DetailOptions, DetailVm,
    HeroPart, PlayAction, PlayButton, PlayReadiness, VersionOption, head_picture_ahead,
};
pub use detail_more::{
    CollectionRailPart, DownloadField, DownloadState, FileExcerpt, FileRow, MenuContext, MenuEntry,
    MenuKind, MoreFacts, ProofPart, ProofPhase, TrailerCandidate, WatcherTile, more_menu_for,
    tile_menu_carries, trailer_candidates, web_address,
};
pub use downloads_vm::{
    DownloadRow, DownloadServices, DownloadsIntent, DownloadsRejected, DownloadsVm, ItemRow,
    ListPart, RowState, StoragePart, decimal_separator, downloads_part,
};
pub use history::{Bearing, NavHistory};
pub use home::{HomePrefs, HomeVm, INITIAL_WINDOW, account_client};
pub use host::{Clock, Host, Shared, Sleeper, Spawner, SystemClock};
pub use language_names::{
    LabelWords, NameSource, host_calls, knows_code, language_name, set_name_source, table_knows,
    table_name,
};
pub use legacy_detail::{DetailServer, LegacyDetail, LegacyPlexDetail};
pub use legacy_downloads::*;
pub use legacy_downloads_server::FollowFetch;
pub use legacy_downloads_server::{pending_done, pending_report_record, stops_process};
pub use legacy_home::{LegacyHome, LegacyHomeArgs, LegacyRail, LegacyTile, legacy_home_json};
pub use legacy_library::{
    LegacyLibraryCall, LegacyPageArgs, legacy_count_text, legacy_labels_json, legacy_library_json,
    legacy_saved_genres_json,
};
pub use legacy_lists::{audio_languages, bitrate_levels, buffer_levels, languages, span};
pub use legacy_playback::LegacyPlayback;
pub use legacy_playback_run::Stop as LegacyStop;
pub use legacy_search::{
    legacy_search_json, search_key_delete, search_key_hardware, search_key_rows, search_key_space,
    search_key_space_fits, search_key_typed, search_screen_state, search_titles_shown,
};
pub use legacy_section::LegacySection;
pub use library::{
    GridPart, LibraryIntent, LibrarySpec, LibraryStatus, LibraryStatusPart, LibraryVm, TileRequest,
};
pub use library_list::{LibraryList, ListEntry, selection_label};
pub use load_state::{FailKind, Load, LoadEvent, LoadFailure};
pub use login::{
    LoginEffect, LoginIntent, LoginPart, LoginScreen, LoginVm, PlexLink, ServerReminder,
    connection_error_text, plex_link, quick_countdown, revoked_message,
};
pub use next_card::{NextCard, NextCardEvent};
pub use parts::{
    Badge, HomeIntent, ImageKind, ImageRef, NoticePart, Rail, RailKind, RailsPart, Status,
    StatusPart, Tile, TileFacts,
};
pub use person::{
    PAGE_SIZE as PERSON_PAGE_SIZE, PersonDetail, PersonPart, PersonVm, RequestableHit,
    SeerrPersonRef,
};
pub use play_display::card_image;
pub use play_display::{DisplayNext, PlayDisplay, play_display};
pub use player::{
    AirPlayStart, CONTROLS_HIDE, ChapterRow, ChaptersPart, ControlsPart, GroupHook, JUMP_DISPLAY,
    NextEpisode, OfferPart, OfferView, Phase, PlayerEffect, PlayerIntent, PlayerLayer, PlayerPrefs,
    PlayerSpec, PlayerVm, TrackRow, TracksPart, TransportPart, middle_up, top_bar_up, veil_up,
};
pub use player_controls::{ChainEvent, Controls, ControlsEvent, SeekChain, Side};
pub use player_extra::{
    AfterPlay, CLOSE_WAIT, CloseStep, DISCORD_THRESHOLD, Failure, HINT_SECONDS, MIN_DURATION,
    MemoryTrackStore, Nudge, ORIGINAL_QUALITY_HINT, Quality, RATING_THRESHOLD, READY_SHARE,
    RELOAD_FAILED_HINT, RemoteOrders, ReplaceRunning, START_TIMEOUT_SECONDS, SWITCH_FAILED_HINT,
    StartVeil, StartVeilEvent, TrackMemoryStore, counts_as_ready, kickoff,
};
pub use player_menu::{
    ActionRow, ChoicePage, DeviceRow, EpisodesPage, GroupInfo, GroupMember, HandoffDevice,
    HandoffInput, HandoffPage, HandoffState, LookGroup, LookPage, MemberRow, MemberStatus,
    MenuAction, MenuChoice, MenuInputs, MenuLevel, MenuState, OFFSET_KEY, OFFSET_STEP_FINE_MS,
    OFFSET_STEPS_MS, OffsetStepRow, OptionsPage, PanelTab, PlayerMenu, PlayerMenus, QualityPage,
    SleepPage, SleepState, SpeedRow, TimePage, TimeTab, TogetherPage, TrackChoice, TrackTab,
    TrackTabPage, TracksPage, ValueRow, Words, build_menus, offset_label,
};
pub use player_more::{
    ENDS_AT_KEY, REMAINING_KEY, SMALL_WINDOW_TEXT, StreamReading, TimesLabel, VolumeState,
    clock_text, times_label,
};
pub use player_report::{
    ClientReporter, PendingReport, PendingSink, PlexReporter, REPORT_DEADLINE, ReportDesk,
    ReportKind, ReportMessage, ReportOutcome, Reporter,
};
pub use player_stage::{PlayerStage, Resume, StageEvent, Surface, SurfaceEvent};
pub use player_start::{
    DownloadedFile, MemoryDictionaries, NextSource, ReadyStart, StartAnswer, StartRequest,
    StartSettings, play_chapters, play_plan_only, play_sections, play_start, play_trickplay,
    start_tracks,
};
pub use playlist::{PlaylistEmpty, PlaylistPart, PlaylistVm};
pub use plex::plex_client_for;
pub use profile_entry::{
    HubSection, HubSectionKind, ProfileEntry, ProfileEntryKind, profile_entry,
};
pub use search::{
    DEBOUNCE, SearchGroup, SearchIntent, SearchKind, SearchResultsPart, SearchStatus,
    SearchStatusPart, SearchVm,
};
pub use seed::{page_seed, tile_item};
pub use seerr::{
    CONFIRM_STANDS_SECONDS, DiscoverPart, SeerrCast, SeerrEffect, SeerrIntent, SeerrPart,
    SeerrSeasonRow, SeerrTile, SeerrVm, state_announcement, state_hint, state_word,
};
pub use seerr_admin::{
    AdminTab, IssuePill, SeerrDetailRow, SeerrIssueDetail, SeerrIssueMessage, SeerrIssuePill,
    SeerrIssueRow, SeerrIssuesInfo, SeerrIssuesVm, SeerrTabInfo, request_detail_rows, tabs,
};
pub use seerr_admin_io::{SeerrAdminScreen, SeerrRequestCard};
pub use seerr_delete::{
    DeleteAction, DeletePhase, DeleteStepKind, SeerrDeleteInfo, SeerrDeleteStep,
    SeerrDeleteVersion, SeerrDeleteVm, StepState, delete_allowed, delete_offered,
    delete_place_of_item,
};
pub use seerr_delete_io::{DeleteLibrary, HostFuture, SeerrDeleteScreen};
pub use seerr_io::{ScreenTimer, SeerrHub, SeerrListsScreen, SeerrRequestResult, SeerrTitleScreen};
pub use seerr_lists::{
    ArrivalCandidate, ArrivalDeck, HOME_BUDGET_SECONDS, HubCounts, HubState, LibraryHit, ListLoad,
    ProfileRowKind, RailId, RequestPill, RequestScope, RowWork, SearchGroupKind, SeerrArrival,
    SeerrAttention, SeerrDiscoverRails, SeerrDiscoverVm, SeerrHomeInfo, SeerrHomeShape,
    SeerrHomeState, SeerrHomeVm, SeerrHubInfo, SeerrHubVm, SeerrPillInfo, SeerrProfileRow,
    SeerrRail, SeerrRequestRow, SeerrRequestsInfo, SeerrRequestsVm, SeerrSearchGroup,
    SeerrSearchInfo, SeerrSearchVm, TitleCache, TitleLite, Verdict, request_status,
    seerr_home_memory_key,
};
pub use seerr_my_requests::{HOME_TAKE as HOME_REQUESTS_TAKE, MyRequests};
pub use seerr_report::{
    ReportInfo, ReportKindRow, ReportPhase, ReportSend, SeerrPlace, SeerrReportFlow, SeerrReportVm,
    TitleMenuEntry, TitleMenuKind, place_of_item,
};
pub use seerr_setup::{
    SeerrSetupInfo, SeerrSetupVm, SetupEntry, SetupMethodRow, SetupPhase, cause_text,
};
pub use seerr_stash::SeerrStash;
pub use seerr_title::{
    BadgeKind, PrimaryKind, RequestEnd, SeerrAccount, SeerrBadge, SeerrChoiceOption,
    SeerrChoiceRow, SeerrEpisodeInfo, SeerrPrimary, SeerrSeasonRowInfo, SeerrSheetInfo,
    SeerrTileCard, SeerrTitleInfo, SeerrTitleVm, SeerrToggleRow, SheetNeeds, SheetPhase, TitleLoad,
    ask_text, badge_of, is_offline, quota_line, short_date, tile_of, today_utc, when_text,
};
pub use series::{
    EPISODES_STEP, EpisodeRow, EpisodesPart, EpisodesStatus, MorePart, SeasonRow, SeasonsPart,
    SeriesButtonPart, SeriesEffect, SeriesIntent, SeriesOptions, SeriesRating, SeriesSpec,
    SeriesVm, warm_ids as warm_series_ids,
};
pub use server::{
    EMBY_CAPABILITIES, ServerClient, can, capabilities_for, make_client, make_client_from_session,
    make_signed_out_client,
};
pub use server_admin::{
    ServerAction, ServerActionKind, ServerAdminAsk, ServerAdminIntent, ServerAdminPage,
    ServerAdminPart, ServerAdminState, ServerAdminVm, ServerBadge, ServerBadgeKind, ServerDiskIo,
    ServerDiskRow, ServerLoadView, ServerLogRow, ServerLogsIntent, ServerLogsPart, ServerLogsState,
    ServerLogsVm, ServerMeter, ServerNumber, ServerStreamCard, ServerTaskRow, TICK_SECONDS,
    server_admin_offered,
};
pub use server_probe::{ProbeBoard, ProbeEvent, ServerProbe};
pub use settings_sync_run::{
    Ran as SyncRan, SeerrOutcome, SettingsSyncCore, StoreSync, SyncOutcome, SyncRound,
    keys as sync_keys, seerr_key, stamp_change, store_seerr, stored_seerr, synced_values,
};
pub use settings_vm::{
    Capabilities, ChoiceOption, Confirm, HomeEdit, Platform, Rejected, Row, RowControl, Section,
    SectionsPart, SettingsContext, SettingsEffect, SettingsIntent, SettingsStatusPart, SettingsVm,
    settings_part,
};
pub use shared::{
    CurrentGroup, GroupDetail, GroupRow, HandoffEvent, HandoffStage, SharedDetail, SharedIntent,
    SharedPart, SharedVm, TakeoverPart, TakeoverRow, handoff_next, join_names, phase_text,
};
pub use stale_lists::StaleLists;
pub use start_settings::{apply_stored_settings, load_core_switches};
pub use subtitle_search::{
    MAX_ROWS as SUBTITLE_SEARCH_MAX_ROWS, SubtitleHitRow, SubtitleLanguage, SubtitleSearchIntent,
    SubtitleSearchPart, SubtitleSearchPhase, SubtitleSearchVm, SubtitleTrackRow,
    subtitle_search_offered, subtitle_tracks,
};
pub use tile::{banner_of, poster_tiles, section_cards, set_tile_image_sizes, tile_image_sizes};
pub use tile_details::TileDetails;
pub use title_text::{episode_code, minutes_text, player_head};
pub use track_names::TrackNames;
pub use transcode_reason::reason_text;
