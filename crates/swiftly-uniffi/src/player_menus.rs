//! The player menus (`swiftly_vm::PlayerMenus`) as the Apple hosts read them: every level of every sheet (options,
//! speed, sleep timer, picture, quality, group, tracks, subtitle look, timing, episodes, handoff) built by the core,
//! texts as catalogue keys (`PlayerMenuWords`), every press as a `PlayerMenuAction`. The host only draws the rows and
//! sends the action back through `PlayerVm::press_menu`; it fills `PlayerMenusInputs` with the few things only it knows.

use swiftly_vm::{
    ActionRow, ChoicePage, DeviceRow, EpisodesPage, GroupInfo, GroupMember, HandoffDevice,
    HandoffInput, HandoffPage, HandoffState, LookGroup, LookPage, MemberRow, MemberStatus,
    MenuAction, MenuChoice, MenuInputs, MenuLevel, OptionsPage, PanelTab, PlayerIntent as VmIntent,
    PlayerMenus as VmMenus, QualityPage, SeasonRow, SleepPage, TimePage, TimeTab, TogetherPage,
    TrackChoice, TrackTab, TrackTabPage, TracksPage, ValueRow, Words,
};

use crate::looks::{SubtitleLookInfo, subtitle_info, subtitle_of};
use crate::player::PlayerIntent;
use crate::takeover::TakeoverDevice;

// ---- Words, tabs, levels ---------------------------------------------------------------------------------------------

/// A text and how to translate it.
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum PlayerMenuWords {
    /// A German catalogue key.
    Key { key: String },
    /// A catalogue key with one `%lld` (e.g. "%lld Min." and 30).
    Count { key: String, count: i64 },
    /// Two catalogue keys joined by " · ", each translated.
    Pair { first: String, second: String },
    /// Shown as it is (a server name, a number with the host's separator).
    Literal { text: String },
}

impl From<Words> for PlayerMenuWords {
    fn from(w: Words) -> Self {
        match w {
            Words::Key(k) => Self::Key { key: k.to_owned() },
            Words::Count(k, n) => Self::Count {
                key: k.to_owned(),
                count: n,
            },
            Words::Pair(a, b) => Self::Pair {
                first: a.to_owned(),
                second: b.to_owned(),
            },
            Words::Literal(text) => Self::Literal { text },
        }
    }
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerMenuTrackTab {
    Subtitles,
    Audio,
}

impl From<TrackTab> for PlayerMenuTrackTab {
    fn from(t: TrackTab) -> Self {
        match t {
            TrackTab::Subtitles => Self::Subtitles,
            TrackTab::Audio => Self::Audio,
        }
    }
}

impl From<PlayerMenuTrackTab> for TrackTab {
    fn from(t: PlayerMenuTrackTab) -> Self {
        match t {
            PlayerMenuTrackTab::Subtitles => Self::Subtitles,
            PlayerMenuTrackTab::Audio => Self::Audio,
        }
    }
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerMenuPanelTab {
    Episodes,
    Chapters,
}

impl From<PanelTab> for PlayerMenuPanelTab {
    fn from(t: PanelTab) -> Self {
        match t {
            PanelTab::Episodes => Self::Episodes,
            PanelTab::Chapters => Self::Chapters,
        }
    }
}

impl From<PlayerMenuPanelTab> for PanelTab {
    fn from(t: PlayerMenuPanelTab) -> Self {
        match t {
            PlayerMenuPanelTab::Episodes => Self::Episodes,
            PlayerMenuPanelTab::Chapters => Self::Chapters,
        }
    }
}

/// A page of the menus. Sheets open at `Options`, `Tracks` or `Episodes`; the other levels come from an `Open` action.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerMenuLevel {
    Options,
    Speed,
    Sleep,
    Picture,
    Quality,
    Together,
    Tracks { tab: PlayerMenuTrackTab },
    SubtitleLook,
    TimeAdjust { tab: PlayerMenuTrackTab },
    Episodes { tab: PlayerMenuPanelTab },
    Seasons,
    Handoff,
}

impl From<MenuLevel> for PlayerMenuLevel {
    fn from(l: MenuLevel) -> Self {
        match l {
            MenuLevel::Options => Self::Options,
            MenuLevel::Speed => Self::Speed,
            MenuLevel::Sleep => Self::Sleep,
            MenuLevel::Picture => Self::Picture,
            MenuLevel::Quality => Self::Quality,
            MenuLevel::Together => Self::Together,
            MenuLevel::Tracks(t) => Self::Tracks { tab: t.into() },
            MenuLevel::SubtitleLook => Self::SubtitleLook,
            MenuLevel::TimeAdjust(t) => Self::TimeAdjust { tab: t.into() },
            MenuLevel::Episodes(t) => Self::Episodes { tab: t.into() },
            MenuLevel::Seasons => Self::Seasons,
            MenuLevel::Handoff => Self::Handoff,
        }
    }
}

impl From<PlayerMenuLevel> for MenuLevel {
    fn from(l: PlayerMenuLevel) -> Self {
        match l {
            PlayerMenuLevel::Options => Self::Options,
            PlayerMenuLevel::Speed => Self::Speed,
            PlayerMenuLevel::Sleep => Self::Sleep,
            PlayerMenuLevel::Picture => Self::Picture,
            PlayerMenuLevel::Quality => Self::Quality,
            PlayerMenuLevel::Together => Self::Together,
            PlayerMenuLevel::Tracks { tab } => Self::Tracks(tab.into()),
            PlayerMenuLevel::SubtitleLook => Self::SubtitleLook,
            PlayerMenuLevel::TimeAdjust { tab } => Self::TimeAdjust(tab.into()),
            PlayerMenuLevel::Episodes { tab } => Self::Episodes(tab.into()),
            PlayerMenuLevel::Seasons => Self::Seasons,
            PlayerMenuLevel::Handoff => Self::Handoff,
        }
    }
}

// ---- Actions ---------------------------------------------------------------------------------------------------------

/// What a press does. `Player` is carried out by `PlayerVm::press_menu` itself; every other action comes back to the
/// host (navigation, settings, the group, the system), see `PlayerVm::press_menu`.
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum PlayerMenuAction {
    Player {
        intent: PlayerIntent,
    },
    Open {
        level: PlayerMenuLevel,
    },
    /// Store this whole subtitle look in the settings.
    Look {
        look: SubtitleLookInfo,
    },
    TechBadge {
        on: bool,
    },
    LeaveGroup,
    /// Outside a group: start "Gemeinsam schauen" for the playing title.
    StartTogether,
    LockScreen,
    ReportProblem,
    SearchSubtitles,
    /// Show this season in the episodes panel (`SeriesIntent::SelectSeason`), then go back to `Episodes`.
    SelectSeason {
        id: String,
    },
    /// Hand the playback to this device (the takeover session id).
    Handoff {
        session_id: String,
    },
    AirPlay,
}

/// The player intent as the host enum has it; `None` for the intents that enum does not carry (no menu uses them).
fn intent_out(i: VmIntent) -> Option<PlayerIntent> {
    Some(match i {
        VmIntent::SelectAudio(index) => PlayerIntent::SelectAudio { index },
        VmIntent::SelectSubtitle(index) => PlayerIntent::SelectSubtitle { index },
        VmIntent::AudioDelay(d) => PlayerIntent::AudioDelay {
            milliseconds: d.milliseconds(),
        },
        VmIntent::SubtitleOffsetStep(step_ms) => PlayerIntent::SubtitleOffsetStep { step_ms },
        VmIntent::SubtitleOffsetReset => PlayerIntent::SubtitleOffsetReset,
        VmIntent::Tempo(tempo) => PlayerIntent::Tempo { tempo },
        VmIntent::Fill(on) => PlayerIntent::Fill { on },
        VmIntent::Sleep(minutes) => PlayerIntent::Sleep { minutes },
        VmIntent::SleepEndOfEpisode => PlayerIntent::SleepEndOfEpisode,
        VmIntent::Quality(limit) => PlayerIntent::Quality { limit },
        VmIntent::JumpToChapter(index) => PlayerIntent::JumpToChapter {
            index: index as u32,
        },
        _ => return None,
    })
}

impl From<MenuAction> for PlayerMenuAction {
    fn from(a: MenuAction) -> Self {
        match a {
            MenuAction::Player(i) => match intent_out(i) {
                Some(intent) => Self::Player { intent },
                None => {
                    debug_assert!(false, "a menu uses a player intent the host enum lacks");
                    Self::Player {
                        intent: PlayerIntent::WakeControls,
                    }
                }
            },
            MenuAction::Open(l) => Self::Open { level: l.into() },
            MenuAction::Look(look) => Self::Look {
                look: subtitle_info(&look),
            },
            MenuAction::TechBadge(on) => Self::TechBadge { on },
            MenuAction::LeaveGroup => Self::LeaveGroup,
            MenuAction::StartTogether => Self::StartTogether,
            MenuAction::LockScreen => Self::LockScreen,
            MenuAction::ReportProblem => Self::ReportProblem,
            MenuAction::SearchSubtitles => Self::SearchSubtitles,
            MenuAction::SelectSeason(id) => Self::SelectSeason { id },
            MenuAction::Handoff(session_id) => Self::Handoff { session_id },
            MenuAction::AirPlay => Self::AirPlay,
        }
    }
}

impl From<PlayerMenuAction> for MenuAction {
    fn from(a: PlayerMenuAction) -> Self {
        match a {
            PlayerMenuAction::Player { intent } => Self::Player(intent.into()),
            PlayerMenuAction::Open { level } => Self::Open(level.into()),
            PlayerMenuAction::Look { look } => Self::Look(subtitle_of(&look)),
            PlayerMenuAction::TechBadge { on } => Self::TechBadge(on),
            PlayerMenuAction::LeaveGroup => Self::LeaveGroup,
            PlayerMenuAction::StartTogether => Self::StartTogether,
            PlayerMenuAction::LockScreen => Self::LockScreen,
            PlayerMenuAction::ReportProblem => Self::ReportProblem,
            PlayerMenuAction::SearchSubtitles => Self::SearchSubtitles,
            PlayerMenuAction::SelectSeason { id } => Self::SelectSeason(id),
            PlayerMenuAction::Handoff { session_id } => Self::Handoff(session_id),
            PlayerMenuAction::AirPlay => Self::AirPlay,
        }
    }
}

// ---- Rows and pages --------------------------------------------------------------------------------------------------

/// One choice: a row, a capsule or a segment.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuChoice {
    pub label: PlayerMenuWords,
    pub detail: Option<PlayerMenuWords>,
    pub selected: bool,
    pub action: PlayerMenuAction,
}

impl From<MenuChoice> for PlayerMenuChoice {
    fn from(c: MenuChoice) -> Self {
        Self {
            label: c.label.into(),
            detail: c.detail.map(Into::into),
            selected: c.selected,
            action: c.action.into(),
        }
    }
}

fn choices(v: Vec<MenuChoice>) -> Vec<PlayerMenuChoice> {
    v.into_iter().map(Into::into).collect()
}

/// A row with a value on the right (opens a level or toggles).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuValueRow {
    pub title: PlayerMenuWords,
    pub value: PlayerMenuWords,
    pub action: PlayerMenuAction,
}

impl From<ValueRow> for PlayerMenuValueRow {
    fn from(r: ValueRow) -> Self {
        Self {
            title: r.title.into(),
            value: r.value.into(),
            action: r.action.into(),
        }
    }
}

/// A plain action row.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuActionRow {
    pub title: PlayerMenuWords,
    pub action: PlayerMenuAction,
}

impl From<ActionRow> for PlayerMenuActionRow {
    fn from(r: ActionRow) -> Self {
        Self {
            title: r.title.into(),
            action: r.action.into(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuOptionsPage {
    pub rows: Vec<PlayerMenuValueRow>,
    pub footer: Vec<PlayerMenuActionRow>,
}

impl From<OptionsPage> for PlayerMenuOptionsPage {
    fn from(p: OptionsPage) -> Self {
        Self {
            rows: p.rows.into_iter().map(Into::into).collect(),
            footer: p.footer.into_iter().map(Into::into).collect(),
        }
    }
}

/// Speed and picture.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuChoicePage {
    pub title: PlayerMenuWords,
    pub choices: Vec<PlayerMenuChoice>,
}

impl From<ChoicePage> for PlayerMenuChoicePage {
    fn from(p: ChoicePage) -> Self {
        Self {
            title: p.title.into(),
            choices: choices(p.choices),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuSleepPage {
    pub title: PlayerMenuWords,
    pub choices: Vec<PlayerMenuChoice>,
    pub minutes_title: PlayerMenuWords,
    pub minutes: Vec<PlayerMenuChoice>,
}

impl From<SleepPage> for PlayerMenuSleepPage {
    fn from(p: SleepPage) -> Self {
        Self {
            title: p.title.into(),
            choices: choices(p.choices),
            minutes_title: p.minutes_title.into(),
            minutes: choices(p.minutes),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuQualityPage {
    pub title: PlayerMenuWords,
    /// `false`: nothing to choose (download, no conversion, group): show no capsules.
    pub offered: bool,
    pub original: PlayerMenuChoice,
    pub bitrate_title: PlayerMenuWords,
    pub bitrates: Vec<PlayerMenuChoice>,
    pub badge_title: PlayerMenuWords,
    pub badge_on: bool,
    pub badge_action: PlayerMenuAction,
}

impl From<QualityPage> for PlayerMenuQualityPage {
    fn from(p: QualityPage) -> Self {
        Self {
            title: p.title.into(),
            offered: p.offered,
            original: p.original.into(),
            bitrate_title: p.bitrate_title.into(),
            bitrates: choices(p.bitrates),
            badge_title: p.badge_title.into(),
            badge_on: p.badge_on,
            badge_action: p.badge_action.into(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuMemberRow {
    pub name: String,
    pub me: bool,
    pub status: PlayerMenuWords,
}

impl From<MemberRow> for PlayerMenuMemberRow {
    fn from(m: MemberRow) -> Self {
        Self {
            name: m.name,
            me: m.me,
            status: m.status.into(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuTogetherPage {
    pub title: PlayerMenuWords,
    pub group_name: String,
    pub members: Vec<PlayerMenuMemberRow>,
    pub leave: PlayerMenuActionRow,
}

impl From<TogetherPage> for PlayerMenuTogetherPage {
    fn from(p: TogetherPage) -> Self {
        Self {
            title: p.title.into(),
            group_name: p.group_name,
            members: p.members.into_iter().map(Into::into).collect(),
            leave: p.leave.into(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuTrackChoice {
    pub label: String,
    /// `label` is a catalogue key ("Aus"); otherwise the track's own name.
    pub label_is_key: bool,
    pub selected: bool,
    pub forced: bool,
    pub file: bool,
    pub hearing_impaired: bool,
    pub action: PlayerMenuAction,
}

impl From<TrackChoice> for PlayerMenuTrackChoice {
    fn from(t: TrackChoice) -> Self {
        Self {
            label: t.label,
            label_is_key: t.label_is_key,
            selected: t.selected,
            forced: t.forced,
            file: t.file,
            hearing_impaired: t.hearing_impaired,
            action: t.action.into(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuTrackTabPage {
    pub title: PlayerMenuWords,
    pub rows: Vec<PlayerMenuTrackChoice>,
    /// The online subtitle search button, if offered.
    pub search: Option<PlayerMenuAction>,
}

impl From<TrackTabPage> for PlayerMenuTrackTabPage {
    fn from(p: TrackTabPage) -> Self {
        Self {
            title: p.title.into(),
            rows: p.rows.into_iter().map(Into::into).collect(),
            search: p.search.map(Into::into),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuTracksPage {
    pub tabs: Vec<PlayerMenuTrackTab>,
    pub subtitles: PlayerMenuTrackTabPage,
    pub audio: PlayerMenuTrackTabPage,
    pub look: PlayerMenuValueRow,
    pub subtitle_time: PlayerMenuValueRow,
    pub audio_time: PlayerMenuValueRow,
}

impl From<TracksPage> for PlayerMenuTracksPage {
    fn from(p: TracksPage) -> Self {
        Self {
            tabs: p.tabs.into_iter().map(Into::into).collect(),
            subtitles: p.subtitles.into(),
            audio: p.audio.into(),
            look: p.look.into(),
            subtitle_time: p.subtitle_time.into(),
            audio_time: p.audio_time.into(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuLookGroup {
    pub title: PlayerMenuWords,
    pub choices: Vec<PlayerMenuChoice>,
}

impl From<LookGroup> for PlayerMenuLookGroup {
    fn from(g: LookGroup) -> Self {
        Self {
            title: g.title.into(),
            choices: choices(g.choices),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuLookPage {
    pub title: PlayerMenuWords,
    pub groups: Vec<PlayerMenuLookGroup>,
}

impl From<LookPage> for PlayerMenuLookPage {
    fn from(p: LookPage) -> Self {
        Self {
            title: p.title.into(),
            groups: p.groups.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuTimeTab {
    pub tab: PlayerMenuTrackTab,
    pub title: PlayerMenuWords,
    pub value_ms: i64,
    /// "+0,3 s".
    pub value: String,
    pub meaning: PlayerMenuWords,
    pub earlier: PlayerMenuActionRow,
    pub later: PlayerMenuActionRow,
    /// Only when the value is not 0.
    pub reset: Option<PlayerMenuActionRow>,
}

impl From<TimeTab> for PlayerMenuTimeTab {
    fn from(t: TimeTab) -> Self {
        Self {
            tab: t.tab.into(),
            title: t.title.into(),
            value_ms: t.value_ms,
            value: t.value,
            meaning: t.meaning.into(),
            earlier: t.earlier.into(),
            later: t.later.into(),
            reset: t.reset.map(Into::into),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuTimePage {
    pub title: PlayerMenuWords,
    pub tabs: Vec<PlayerMenuTimeTab>,
}

impl From<TimePage> for PlayerMenuTimePage {
    fn from(p: TimePage) -> Self {
        Self {
            title: p.title.into(),
            tabs: p.tabs.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuEpisodesPage {
    /// One tab: no tab bar.
    pub tabs: Vec<PlayerMenuPanelTab>,
    /// Series only: its value is the open season, its action opens `Seasons`.
    pub season_button: Option<PlayerMenuValueRow>,
    pub seasons_title: PlayerMenuWords,
    pub seasons: Vec<PlayerMenuChoice>,
}

impl From<EpisodesPage> for PlayerMenuEpisodesPage {
    fn from(p: EpisodesPage) -> Self {
        Self {
            tabs: p.tabs.into_iter().map(Into::into).collect(),
            season_button: p.season_button.map(Into::into),
            seasons_title: p.seasons_title.into(),
            seasons: choices(p.seasons),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuDeviceRow {
    pub name: String,
    pub kind: TakeoverDevice,
    pub detail: Option<String>,
    pub action: PlayerMenuAction,
    /// This device is taking the playback over (spinner).
    pub busy: bool,
    /// Can be chosen; false for the others while one takes over.
    pub enabled: bool,
}

impl From<DeviceRow> for PlayerMenuDeviceRow {
    fn from(r: DeviceRow) -> Self {
        Self {
            name: r.name,
            kind: crate::takeover::device_of(r.kind),
            detail: r.detail,
            action: r.action.into(),
            busy: r.busy,
            enabled: r.enabled,
        }
    }
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerMenuHandoffState {
    Loading,
    Empty,
    List,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuHandoffPage {
    pub title: PlayerMenuWords,
    pub state: PlayerMenuHandoffState,
    /// The loading or empty sentence.
    pub text: Option<PlayerMenuWords>,
    pub rows: Vec<PlayerMenuDeviceRow>,
    /// Apple only.
    pub airplay: Option<PlayerMenuDeviceRow>,
    pub note: PlayerMenuWords,
}

impl From<HandoffPage> for PlayerMenuHandoffPage {
    fn from(p: HandoffPage) -> Self {
        Self {
            title: p.title.into(),
            state: match p.state {
                HandoffState::Loading => PlayerMenuHandoffState::Loading,
                HandoffState::Empty => PlayerMenuHandoffState::Empty,
                HandoffState::List => PlayerMenuHandoffState::List,
            },
            text: p.text.map(Into::into),
            rows: p.rows.into_iter().map(Into::into).collect(),
            airplay: p.airplay.map(Into::into),
            note: p.note.into(),
        }
    }
}

/// Every level at once. Read it when a sheet opens and again when the player, season, group, look or device list changes.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenus {
    pub options: PlayerMenuOptionsPage,
    pub speed: PlayerMenuChoicePage,
    pub sleep: PlayerMenuSleepPage,
    pub picture: PlayerMenuChoicePage,
    pub quality: PlayerMenuQualityPage,
    /// `None` outside a group.
    pub together: Option<PlayerMenuTogetherPage>,
    pub tracks: PlayerMenuTracksPage,
    pub look: PlayerMenuLookPage,
    pub time: PlayerMenuTimePage,
    pub episodes: PlayerMenuEpisodesPage,
    pub handoff: PlayerMenuHandoffPage,
}

impl From<VmMenus> for PlayerMenus {
    fn from(m: VmMenus) -> Self {
        Self {
            options: m.options.into(),
            speed: m.speed.into(),
            sleep: m.sleep.into(),
            picture: m.picture.into(),
            quality: m.quality.into(),
            together: m.together.map(Into::into),
            tracks: m.tracks.into(),
            look: m.look.into(),
            time: m.time.into(),
            episodes: m.episodes.into(),
            handoff: m.handoff.into(),
        }
    }
}

// ---- What the host gives ---------------------------------------------------------------------------------------------

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerMenuMemberStatus {
    Watching,
    Paused,
    Waiting,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuGroupMember {
    pub name: String,
    pub me: bool,
    pub status: PlayerMenuMemberStatus,
}

/// The SyncPlay group the player is in.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuGroup {
    pub name: String,
    /// Everyone including the user.
    pub members: Vec<PlayerMenuGroupMember>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenuHandoffDevice {
    /// Takeover session id.
    pub id: String,
    pub name: String,
    pub kind: TakeoverDevice,
    pub detail: Option<String>,
}

/// The device list of the handoff level.
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum PlayerMenuHandoffInput {
    Loading,
    Devices {
        devices: Vec<PlayerMenuHandoffDevice>,
    },
    /// The device with this takeover session id is taking the playback over right now.
    Handing {
        devices: Vec<PlayerMenuHandoffDevice>,
        busy: String,
    },
}

/// What only the host knows; everything else the core reads from the player.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenusInputs {
    /// "," or "." of the host's locale.
    pub decimal_separator: String,
    /// The technical overlay is on (a host setting).
    pub tech_badge: bool,
    /// `None` outside a group.
    pub group: Option<PlayerMenuGroup>,
    /// The current subtitle look (a host setting).
    pub look: SubtitleLookInfo,
    /// `SeasonsPart.seasons`; empty for a film.
    pub seasons: Vec<SeasonRow>,
    /// `SeasonsPart.selected`.
    pub shown_season: Option<String>,
    pub handoff: PlayerMenuHandoffInput,
    /// Offer an AirPlay row.
    pub airplay: bool,
}

impl From<PlayerMenusInputs> for MenuInputs {
    fn from(i: PlayerMenusInputs) -> Self {
        Self {
            decimal_separator: i.decimal_separator,
            tech_badge: i.tech_badge,
            group: i.group.map(|g| GroupInfo {
                name: g.name,
                members: g
                    .members
                    .into_iter()
                    .map(|m| GroupMember {
                        name: m.name,
                        me: m.me,
                        status: match m.status {
                            PlayerMenuMemberStatus::Watching => MemberStatus::Watching,
                            PlayerMenuMemberStatus::Paused => MemberStatus::Paused,
                            PlayerMenuMemberStatus::Waiting => MemberStatus::Waiting,
                        },
                    })
                    .collect(),
            }),
            look: subtitle_of(&i.look),
            seasons: i.seasons,
            shown_season: i.shown_season,
            handoff: {
                let devices = |v: Vec<PlayerMenuHandoffDevice>| -> Vec<HandoffDevice> {
                    v.into_iter()
                        .map(|d| HandoffDevice {
                            id: d.id,
                            name: d.name,
                            kind: crate::takeover::kind_of(d.kind),
                            detail: d.detail,
                        })
                        .collect()
                };
                match i.handoff {
                    PlayerMenuHandoffInput::Loading => HandoffInput::Loading,
                    PlayerMenuHandoffInput::Devices { devices: d } => {
                        HandoffInput::Devices(devices(d))
                    }
                    PlayerMenuHandoffInput::Handing { devices: d, busy } => HandoffInput::Handing {
                        devices: devices(d),
                        busy,
                    },
                }
            },
            airplay: i.airplay,
        }
    }
}

// ---- The menus without a PlayerVm ------------------------------------------------------------------------------------

/// The sleep timer as a host that plays by itself (Android's Media3 player) holds it.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayerMenuSleep {
    Off,
    EndOfEpisode,
    Minutes { minutes: u32 },
}

/// What the menus read from a player the host runs itself (what `PlayerVm::menus` reads from the VM): the same
/// `build_menus` builds the pages, so the rows are the same on every platform.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PlayerMenusState {
    pub tempo: f32,
    pub sleep: PlayerMenuSleep,
    pub fill: bool,
    /// `None` when the title cannot switch quality (a download, a group, an account that may not convert).
    pub quality: Option<crate::player::PlayerQuality>,
    pub series: bool,
    pub has_chapters: bool,
    pub tracks: crate::player::PlayerTracks,
}

/// Every menu for a host-run player: `state` is what the player shows now, `inputs` what only the host knows.
#[uniffi::export]
pub fn player_menus_for(state: PlayerMenusState, inputs: PlayerMenusInputs) -> PlayerMenus {
    let row = |r: crate::player::PlayerTrackRow| swiftly_vm::TrackRow {
        index: r.index,
        label: r.label,
        selected: r.selected,
        forced: r.forced,
        file: r.file,
        hearing_impaired: r.hearing_impaired,
    };
    let t = state.tracks;
    let state = swiftly_vm::MenuState {
        tempo: state.tempo,
        sleep: match state.sleep {
            PlayerMenuSleep::Off => swiftly_vm::SleepState::Off,
            PlayerMenuSleep::EndOfEpisode => swiftly_vm::SleepState::EndOfEpisode,
            PlayerMenuSleep::Minutes { minutes } => swiftly_vm::SleepState::Minutes(minutes),
        },
        fill: state.fill,
        quality: state.quality.map(|q| swiftly_vm::Quality {
            direct_play: q.direct_play,
            limit: q.limit,
        }),
        series: state.series,
        has_chapters: state.has_chapters,
        tracks: swiftly_vm::TracksPart {
            audio: t.audio.into_iter().map(row).collect(),
            subtitles: t.subtitles.into_iter().map(row).collect(),
            subtitles_off: t.subtitles_off,
            audio_delay_ms: t.audio_delay_ms,
            subtitle_delay_ms: t.subtitle_delay_ms,
        },
    };
    swiftly_vm::build_menus(&state, &inputs.into()).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_support::subtitle::SubtitleLook;
    use swiftly_vm::{MenuState, Quality, SleepState, TrackRow, TracksPart, build_menus};

    fn track(index: i64, label: &str) -> TrackRow {
        TrackRow {
            index,
            label: label.to_owned(),
            selected: index == 1,
            forced: false,
            file: false,
            hearing_impaired: false,
        }
    }

    fn built(series: bool) -> VmMenus {
        let state = MenuState {
            tempo: 1.0,
            sleep: SleepState::Minutes(30),
            fill: false,
            quality: Some(Quality {
                direct_play: false,
                limit: 8,
            }),
            series,
            has_chapters: true,
            tracks: TracksPart {
                audio: vec![track(1, "Deutsch"), track(2, "Englisch")],
                subtitles: vec![track(3, "Deutsch")],
                subtitles_off: true,
                audio_delay_ms: -300,
                subtitle_delay_ms: 500,
            },
        };
        let inputs = PlayerMenusInputs {
            decimal_separator: ",".into(),
            tech_badge: true,
            group: Some(PlayerMenuGroup {
                name: "Abend".into(),
                members: vec![
                    PlayerMenuGroupMember {
                        name: "Paul".into(),
                        me: true,
                        status: PlayerMenuMemberStatus::Watching,
                    },
                    PlayerMenuGroupMember {
                        name: "Mia".into(),
                        me: false,
                        status: PlayerMenuMemberStatus::Waiting,
                    },
                ],
            }),
            look: subtitle_info(&SubtitleLook::STANDARD),
            seasons: vec![SeasonRow {
                id: "s1".into(),
                name: "Staffel 1".into(),
                number: Some(1),
            }],
            shown_season: Some("s1".into()),
            handoff: PlayerMenuHandoffInput::Devices {
                devices: vec![PlayerMenuHandoffDevice {
                    id: "x".into(),
                    name: "Wohnzimmer".into(),
                    kind: TakeoverDevice::Tv,
                    detail: Some("Folge 2".into()),
                }],
            },
            airplay: true,
        };
        build_menus(&state, &inputs.into())
    }

    #[test]
    fn every_menu_action_reaches_the_host_enum_and_comes_back_unchanged() {
        for series in [true, false] {
            let core = built(series);
            let host: PlayerMenus = core.clone().into();
            // A fallback would show up as `WakeControls`, which no menu sends.
            let text = format!("{host:?}");
            assert!(!text.contains("WakeControls"), "{text}");
            // The roundtrip: every action of a page equals the core's own action.
            let mut core_actions = Vec::new();
            let mut host_actions = Vec::new();
            for c in core.speed.choices.iter().chain(&core.picture.choices) {
                core_actions.push(c.action.clone());
            }
            for c in host.speed.choices.iter().chain(&host.picture.choices) {
                host_actions.push(MenuAction::from(c.action.clone()));
            }
            for c in core.sleep.choices.iter().chain(&core.sleep.minutes) {
                core_actions.push(c.action.clone());
            }
            for c in host.sleep.choices.iter().chain(&host.sleep.minutes) {
                host_actions.push(MenuAction::from(c.action.clone()));
            }
            for t in &core.time.tabs {
                core_actions.extend([t.earlier.action.clone(), t.later.action.clone()]);
                core_actions.extend(t.reset.iter().map(|r| r.action.clone()));
            }
            for t in &host.time.tabs {
                host_actions.extend([
                    MenuAction::from(t.earlier.action.clone()),
                    MenuAction::from(t.later.action.clone()),
                ]);
                host_actions.extend(t.reset.iter().map(|r| MenuAction::from(r.action.clone())));
            }
            for l in &core.look.groups {
                core_actions.extend(l.choices.iter().map(|c| c.action.clone()));
            }
            for l in &host.look.groups {
                host_actions.extend(l.choices.iter().map(|c| MenuAction::from(c.action.clone())));
            }
            core_actions.extend(core.tracks.audio.rows.iter().map(|r| r.action.clone()));
            host_actions.extend(
                host.tracks
                    .audio
                    .rows
                    .iter()
                    .map(|r| MenuAction::from(r.action.clone())),
            );
            assert!(core_actions.len() > 20);
            assert_eq!(core_actions, host_actions);
        }
    }

    #[test]
    fn the_host_inputs_reach_the_core() {
        let m: PlayerMenus = built(true).into();
        assert_eq!(m.handoff.rows.len(), 1);
        assert_eq!(m.handoff.rows[0].kind, TakeoverDevice::Tv);
        assert!(m.handoff.airplay.is_some());
        assert_eq!(m.together.as_ref().map(|t| t.members.len()), Some(2));
        assert!(m.quality.badge_on);
    }

    #[test]
    fn a_host_run_player_gets_the_same_menus() {
        let row = |index: i64, label: &str| crate::player::PlayerTrackRow {
            index,
            label: label.to_owned(),
            selected: index == 1,
            forced: false,
            file: false,
            hearing_impaired: false,
        };
        let state = PlayerMenusState {
            tempo: 1.0,
            sleep: PlayerMenuSleep::Off,
            fill: false,
            quality: None,
            series: true,
            has_chapters: false,
            tracks: crate::player::PlayerTracks {
                audio: vec![row(1, "Deutsch"), row(2, "English")],
                subtitles: (0..12).map(|i| row(i, "Untertitel")).collect(),
                subtitles_off: true,
                audio_delay_ms: 0,
                subtitle_delay_ms: 0,
            },
        };
        let inputs = PlayerMenusInputs {
            decimal_separator: ",".to_owned(),
            tech_badge: false,
            group: None,
            look: subtitle_info(&swiftly_support::subtitle::SubtitleLook::default()),
            seasons: vec![],
            shown_season: None,
            handoff: PlayerMenuHandoffInput::Loading,
            airplay: false,
        };
        let m = player_menus_for(state, inputs);
        assert_eq!(m.tracks.audio.rows.len(), 2);
        // 12 tracks plus the core's "Aus" row.
        assert_eq!(m.tracks.subtitles.rows.len(), 13);
        assert!(!m.options.rows.is_empty());
    }
}
