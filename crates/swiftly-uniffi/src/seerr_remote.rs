//! UniFFI declarations of the Seerr view-model records (generated shapes of `swiftly-vm::seerr_*`).
//! Remote declarations: the types live in `swiftly-vm`, the fields here must match them.
#![allow(clippy::module_name_repetitions)]
use swiftly_seerr::issues::IssueKind;
use swiftly_vm::{
    AdminTab, BadgeKind, DeletePhase, DeleteStepKind, HubCounts, HubState, IssuePill, ListLoad,
    PrimaryKind, ProfileRowKind, RailId, RequestPill, RowWork, SearchGroupKind, SeerrArrival,
    SeerrAttention, SeerrBadge, SeerrCast, SeerrChoiceOption, SeerrChoiceRow, SeerrDeleteInfo,
    SeerrDeleteStep, SeerrDeleteVersion, SeerrDetailRow, SeerrDiscoverRails, SeerrEpisodeInfo,
    SeerrHomeInfo, SeerrHomeShape, SeerrHomeState, SeerrHubInfo, SeerrIssueDetail,
    SeerrIssueMessage, SeerrIssuePill, SeerrIssueRow, SeerrIssuesInfo, SeerrPillInfo, SeerrPrimary,
    SeerrProfileRow, SeerrRail, SeerrRequestRow, SeerrRequestsInfo, SeerrSearchGroup,
    SeerrSearchInfo, SeerrSeasonRowInfo, SeerrSheetInfo, SeerrTabInfo, SeerrTileCard,
    SeerrTitleInfo, SeerrToggleRow, SheetPhase, StepState, TitleLoad,
};

#[uniffi::remote(Enum)]
pub enum IssueKind {
    Video,
    Audio,
    Subtitles,
    Other,
}

#[uniffi::remote(Record)]
pub struct SeerrBadge {
    pub kind: BadgeKind,
    pub word: String,
    pub line: String,
    pub progress: Option<f32>,
    pub symbol: String,
}

#[uniffi::remote(Record)]
pub struct SeerrTileCard {
    pub art: String,
    pub tmdb: i64,
    pub title: String,
    pub year: Option<i64>,
    pub poster: Option<String>,
    pub badge: Option<SeerrBadge>,
    pub media_id: Option<i64>,
    pub on_server: bool,
    pub announcement: String,
}

#[uniffi::remote(Record)]
pub struct SeerrPrimary {
    pub kind: PrimaryKind,
    pub text: String,
    pub enabled: bool,
}

#[uniffi::remote(Record)]
pub struct SeerrSeasonRowInfo {
    pub number: i64,
    pub title: String,
    pub episodes: Option<String>,
    pub badge: SeerrBadge,
    pub on_server: bool,
    pub missing: bool,
    pub selectable: bool,
    pub selected: bool,
    pub waiting_request: Option<i64>,
    pub episode_list: Vec<SeerrEpisodeInfo>,
}

#[uniffi::remote(Record)]
pub struct SeerrEpisodeInfo {
    pub number: i64,
    pub title: String,
    pub meta: String,
    pub overview: Option<String>,
    pub still: Option<String>,
}

#[uniffi::remote(Record)]
pub struct SeerrToggleRow {
    pub label: String,
    pub on: bool,
}

#[uniffi::remote(Record)]
pub struct SeerrChoiceOption {
    pub id: String,
    pub name: String,
}

#[uniffi::remote(Record)]
pub struct SeerrChoiceRow {
    pub label: String,
    pub value: String,
    pub options: Vec<SeerrChoiceOption>,
    pub selected: String,
}

#[uniffi::remote(Record)]
pub struct SeerrSheetInfo {
    pub phase: SheetPhase,
    pub title: String,
    pub rows: Vec<SeerrSeasonRowInfo>,
    pub quota_line: Option<String>,
    pub quota_loading: bool,
    pub quota_warning: bool,
    pub primary: SeerrPrimary,
    pub four_k: Option<SeerrToggleRow>,
    pub quality: Option<SeerrChoiceRow>,
    pub folder: Option<SeerrChoiceRow>,
    pub error: Option<String>,
}

#[uniffi::remote(Record)]
pub struct SeerrTitleInfo {
    pub version: u64,
    pub load: TitleLoad,
    pub art: String,
    pub tmdb: i64,
    pub media_id: Option<i64>,
    pub title: String,
    pub secondary_line: String,
    pub overview: Option<String>,
    pub rating: Option<f64>,
    pub poster: Option<String>,
    pub backdrop: Option<String>,
    pub badge: Option<SeerrBadge>,
    pub on_server: bool,
    pub primary: SeerrPrimary,
    pub seasons: Vec<SeerrSeasonRowInfo>,
    pub cast: Vec<SeerrCast>,
    pub similar: Vec<SeerrTileCard>,
    pub sheet: SeerrSheetInfo,
    pub error: Option<String>,
}

#[uniffi::remote(Enum)]
pub enum BadgeKind {
    Requestable,
    Waits,
    Searching,
    Soon,
    Fetching,
    Partial,
    Available,
    Declined,
    Failed,
    Blocked,
}

#[uniffi::remote(Enum)]
pub enum PrimaryKind {
    Request,
    Requested,
    Busy,
    Locked,
    Hidden,
}

#[uniffi::remote(Enum)]
pub enum SheetPhase {
    Closed,
    Editing,
    Sending,
    Failed,
}

#[uniffi::remote(Enum)]
pub enum TitleLoad {
    Loading,
    Unavailable,
    Offline,
    Failed,
    Content,
}

#[uniffi::remote(Record)]
pub struct SeerrProfileRow {
    pub kind: ProfileRowKind,
    pub title: String,
    pub detail: Option<String>,
    pub count: i64,
}

#[uniffi::remote(Record)]
pub struct HubCounts {
    pub my_running: i64,
    pub my_issues: i64,
    pub pending: i64,
    pub issues_open: i64,
}

#[uniffi::remote(Record)]
pub struct SeerrHubInfo {
    pub version: u64,
    pub state: HubState,
    pub user_id: i64,
    pub user_name: String,
    pub is_admin: bool,
    pub can_request_movie: bool,
    pub can_request_tv: bool,
    pub can_view_all_requests: bool,
    pub can_manage_requests: bool,
    pub can_create_issues: bool,
    pub can_view_issues: bool,
    pub can_manage_issues: bool,
    pub four_k_movie: bool,
    pub four_k_tv: bool,
    pub partial_requests: bool,
    pub quota_summary: Option<String>,
    pub counts: HubCounts,
    pub profile_rows: Vec<SeerrProfileRow>,
    pub admin_line: Option<String>,
}

#[uniffi::remote(Record)]
pub struct SeerrRail {
    pub id: RailId,
    pub title: String,
    pub tiles: Vec<SeerrTileCard>,
}

#[uniffi::remote(Record)]
pub struct SeerrDiscoverRails {
    pub version: u64,
    pub load: ListLoad,
    pub rails: Vec<SeerrRail>,
    pub error: Option<String>,
}

#[uniffi::remote(Record)]
pub struct SeerrSearchGroup {
    pub kind: SearchGroupKind,
    pub title: String,
    pub tiles: Vec<SeerrTileCard>,
}

#[uniffi::remote(Record)]
pub struct SeerrSearchInfo {
    pub version: u64,
    pub load: ListLoad,
    pub term: String,
    pub block_title: String,
    pub groups: Vec<SeerrSearchGroup>,
    pub count: i64,
    pub error: Option<String>,
    pub nothing_line: Option<String>,
}

#[uniffi::remote(Record)]
pub struct SeerrPillInfo {
    pub pill: RequestPill,
    pub title: String,
    pub count: i64,
    pub selected: bool,
}

#[uniffi::remote(Record)]
pub struct SeerrRequestRow {
    pub id: i64,
    pub art: String,
    pub tmdb: i64,
    pub media_id: Option<i64>,
    pub title: String,
    pub year: Option<i64>,
    pub poster: Option<String>,
    pub badge: SeerrBadge,
    pub requested_by: Option<String>,
    pub detail: Option<String>,
    pub can_withdraw: bool,
    pub can_approve: bool,
    pub can_decline: bool,
    pub can_retry: bool,
    pub work: RowWork,
    pub work_text: Option<String>,
}

#[uniffi::remote(Record)]
pub struct SeerrRequestsInfo {
    pub version: u64,
    pub load: ListLoad,
    pub pills: Vec<SeerrPillInfo>,
    pub rows: Vec<SeerrRequestRow>,
    pub quota_summary: Option<String>,
    pub error: Option<String>,
}

#[uniffi::remote(Record)]
pub struct SeerrArrival {
    pub request_id: i64,
    pub art: String,
    pub tmdb: i64,
    pub title: String,
    pub poster: Option<String>,
    pub library_id: String,
    pub line: String,
}

#[uniffi::remote(Record)]
pub struct SeerrAttention {
    pub title: String,
    pub detail: String,
    pub count: i64,
}

#[uniffi::remote(Record)]
pub struct SeerrHomeShape {
    pub arrival: bool,
    pub stacked: bool,
    pub deep: bool,
    pub attention: bool,
    pub rail: bool,
}

#[uniffi::remote(Enum)]
pub enum SeerrHomeState {
    Pending,
    Hidden,
    Shown,
}

#[uniffi::remote(Record)]
pub struct SeerrHomeInfo {
    pub version: u64,
    pub state: SeerrHomeState,
    pub shape: SeerrHomeShape,
    pub memory: String,
    pub holds_page: bool,
    pub show: bool,
    pub arrival: Option<SeerrArrival>,
    pub arrivals: Vec<SeerrArrival>,
    pub arrivals_expanded: bool,
    pub attention: Option<SeerrAttention>,
    pub rail_title: String,
    pub rail: Vec<SeerrTileCard>,
}

#[uniffi::remote(Enum)]
pub enum HubState {
    Loading,
    Unavailable,
    Offline,
    Ready,
}

#[uniffi::remote(Enum)]
pub enum ProfileRowKind {
    Requests,
    Issues,
    Admin,
}

#[uniffi::remote(Enum)]
pub enum RailId {
    Trending,
    PopularMovies,
    PopularTv,
    UpcomingMovies,
    UpcomingTv,
    Recent,
}

#[uniffi::remote(Enum)]
pub enum ListLoad {
    Idle,
    Loading,
    Empty,
    Offline,
    Failed,
    Content,
}

#[uniffi::remote(Enum)]
pub enum SearchGroupKind {
    Movies,
    Series,
    People,
    Collections,
}

#[uniffi::remote(Enum)]
pub enum RequestPill {
    All,
    Open,
    Running,
    Done,
    Declined,
    Failed,
}

#[uniffi::remote(Enum)]
pub enum RowWork {
    Idle,
    Working,
    Failed,
}

#[uniffi::remote(Record)]
pub struct SeerrTabInfo {
    pub tab: AdminTab,
    pub title: String,
    pub count: i64,
}

#[uniffi::remote(Record)]
pub struct SeerrDetailRow {
    pub label: String,
    pub value: String,
}

#[uniffi::remote(Record)]
pub struct SeerrIssuePill {
    pub pill: IssuePill,
    pub title: String,
    pub count: i64,
    pub selected: bool,
}

#[uniffi::remote(Record)]
pub struct SeerrIssueRow {
    pub id: i64,
    pub art: String,
    pub tmdb: i64,
    pub title: String,
    pub poster: Option<String>,
    pub kind_word: String,
    pub place: Option<String>,
    pub time_text: Option<String>,
    pub is_open: bool,
    pub status_word: String,
    pub reporter: Option<String>,
    pub message: String,
    pub messages: i64,
}

#[uniffi::remote(Record)]
pub struct SeerrIssueMessage {
    pub id: i64,
    pub author: String,
    pub text: String,
    pub when_text: Option<String>,
    pub by_admin: bool,
    pub mine: bool,
}

#[uniffi::remote(Record)]
pub struct SeerrIssuesInfo {
    pub version: u64,
    pub load: ListLoad,
    pub pills: Vec<SeerrIssuePill>,
    pub rows: Vec<SeerrIssueRow>,
    pub error: Option<String>,
}

#[uniffi::remote(Record)]
pub struct SeerrIssueDetail {
    pub version: u64,
    pub row: SeerrIssueRow,
    pub messages: Vec<SeerrIssueMessage>,
    pub play_from: Option<String>,
    pub can_reply: bool,
    pub can_resolve: bool,
    pub can_reopen: bool,
    pub work: RowWork,
    pub error: Option<String>,
}

#[uniffi::remote(Enum)]
pub enum AdminTab {
    Requests,
    Issues,
}

#[uniffi::remote(Enum)]
pub enum IssuePill {
    Open,
    Resolved,
    All,
}

#[uniffi::remote(Record)]
pub struct SeerrDeleteStep {
    pub kind: DeleteStepKind,
    pub label: String,
    pub state: StepState,
}

#[uniffi::remote(Record)]
pub struct SeerrDeleteVersion {
    pub is4k: bool,
    pub label: String,
    pub size: Option<String>,
}

#[uniffi::remote(Record)]
pub struct SeerrDeleteInfo {
    pub version: u64,
    pub phase: DeletePhase,
    pub title: String,
    pub versions: Vec<SeerrDeleteVersion>,
    pub steps: Vec<SeerrDeleteStep>,
    pub headline: Option<String>,
    pub error: Option<String>,
    pub can_retry: bool,
}

#[uniffi::remote(Enum)]
pub enum DeleteStepKind {
    Files,
    Seerr,
    Library,
    Verify,
}

#[uniffi::remote(Enum)]
pub enum StepState {
    Pending,
    Running,
    Done,
    Failed,
}

#[uniffi::remote(Enum)]
pub enum DeletePhase {
    Confirm,
    Running,
    Failed,
    Done,
}

#[uniffi::remote(Record)]
pub struct SeerrCast {
    pub person: i64,
    pub name: String,
    pub role: Option<String>,
    pub image: Option<String>,
}
