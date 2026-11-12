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
mod bell;
mod cache;
mod detail;
pub use detail::{fetch_plan_for, replan_for_subtitle};
mod detail_more;
mod downloads_vm;
mod history;
mod home;
mod host;
mod language_data;
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
mod parts;
mod person;
mod play_display;
mod player;
mod player_controls;
mod player_extra;
mod player_more;
mod player_report;
mod player_stage;
mod player_start;
mod playlist;
mod plex;
pub mod plex_sign_in;
mod search;
mod seerr;
mod series;
mod server;
mod server_probe;
mod settings_vm;
mod shared;
pub mod subtitle_sidecar;
mod tile;
mod tile_details;
mod title_text;

pub use account::AccountRef;
pub use bell::{Change, Changed, part};
pub use cache::{CachedPage, ViewCache};
pub use detail::{
    ActionsPart, BottomPart, CastTile, DetailEffect, DetailIntent, DetailOptions, DetailVm,
    HeroPart, PlayAction, PlayButton, VersionOption,
};
pub use detail_more::{
    CollectionRailPart, DownloadField, DownloadState, FileExcerpt, FileRow, MenuContext, MenuEntry,
    MenuKind, ProofPart, TrailerCandidate, WatcherTile, tile_menu_carries, trailer_candidates,
    web_address,
};
pub use downloads_vm::{
    DownloadRow, DownloadServices, DownloadsIntent, DownloadsRejected, DownloadsVm, ItemRow,
    ListPart, RowState, StoragePart, decimal_separator, downloads_part,
};
pub use history::{Bearing, NavHistory};
pub use home::{HomePrefs, HomeVm, INITIAL_WINDOW, account_client};
pub use host::{Clock, Host, Shared, Sleeper, Spawner, SystemClock};
pub use language_names::{
    LabelWords, NameSource, knows_code, language_name, set_name_source, table_knows, table_name,
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
pub use legacy_lists::{bitrate_levels, buffer_levels, languages, span};
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
    Badge, HomeIntent, ImageKind, ImageRef, Rail, RailKind, RailsPart, Status, StatusPart, Tile,
    TileFacts,
};
pub use person::{
    PAGE_SIZE as PERSON_PAGE_SIZE, PersonDetail, PersonPart, PersonVm, RequestableHit,
};
pub use play_display::card_image;
pub use play_display::{DisplayNext, PlayDisplay, play_display};
pub use player::{
    AirPlayStart, CONTROLS_HIDE, ControlsPart, GroupHook, JUMP_DISPLAY, NextEpisode, OfferPart,
    OfferView, Phase, PlayerEffect, PlayerIntent, PlayerLayer, PlayerPrefs, PlayerSpec, PlayerVm,
    TrackRow, TracksPart, TransportPart,
};
pub use player_controls::{ChainEvent, Controls, ControlsEvent, SeekChain, Side};
pub use player_extra::{
    AfterPlay, CLOSE_WAIT, CloseStep, DISCORD_THRESHOLD, Failure, MIN_DURATION, MemoryTrackStore,
    Nudge, ORIGINAL_QUALITY_HINT, Quality, RATING_THRESHOLD, READY_SHARE, RemoteOrders,
    ReplaceRunning, TrackMemoryStore, counts_as_ready, kickoff,
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
pub use search::{
    DEBOUNCE, SearchGroup, SearchIntent, SearchKind, SearchResultsPart, SearchStatus,
    SearchStatusPart, SearchVm,
};
pub use seerr::{
    CONFIRM_STANDS_SECONDS, DiscoverPart, SeerrCast, SeerrEffect, SeerrIntent, SeerrPart,
    SeerrSeasonRow, SeerrTile, SeerrVm, state_announcement, state_hint, state_word,
};
pub use series::{
    EPISODES_STEP, EpisodeRow, EpisodesPart, EpisodesStatus, MorePart, SeasonRow, SeasonsPart,
    SeriesButtonPart, SeriesEffect, SeriesIntent, SeriesOptions, SeriesRating, SeriesSpec,
    SeriesVm,
};
pub use server::{
    EMBY_CAPABILITIES, ServerClient, can, capabilities_for, make_client, make_client_from_session,
    make_signed_out_client,
};
pub use server_probe::{ProbeBoard, ProbeEvent, ServerProbe};
pub use settings_vm::{
    Capabilities, ChoiceOption, Confirm, Platform, Rejected, Row, RowControl, Section,
    SectionsPart, SettingsContext, SettingsEffect, SettingsIntent, SettingsStatusPart, SettingsVm,
    settings_part,
};
pub use shared::{
    CurrentGroup, GroupDetail, GroupRow, HandoffEvent, HandoffStage, SharedDetail, SharedIntent,
    SharedPart, SharedVm, TakeoverPart, TakeoverRow, handoff_next, join_names, phase_text,
};
pub use tile::{banner_of, poster_tiles, set_tile_image_sizes};
pub use tile_details::TileDetails;
pub use title_text::minutes_text;
