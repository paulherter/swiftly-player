//! The speed and subtitle-offset part of the player menu: ONE model for every host.
//!
//! The core decides which speeds and which offset steps exist, how they read and what a press does
//! ([`crate::PlayerIntent::Tempo`], [`crate::PlayerIntent::SubtitleOffsetStep`],
//! [`crate::PlayerIntent::SubtitleOffsetReset`]). A host draws the rows and sends the intent of the row
//! that was pressed; it keeps no list of speeds, no step sizes and no number formatting of its own.
//! Texts are German catalog keys (the host translates them), numbers carry the host's decimal separator.

use crate::SeasonRow;
use crate::player::{TrackRow, TracksPart};
use crate::player_extra::Quality;
use swiftly_playback::takeover::DevicesKind;
use swiftly_rules::delay::Delay;
use swiftly_rules::playback_levels::{SLEEP_TIMES, SPEED_VALUES, speed_label};
use swiftly_rules::playback_selection::BITRATE_LEVELS;
use swiftly_support::subtitle::{Colour, Size, SubtitleLook};

/// Key of the per-title subtitle offset in the track memory (title id to milliseconds).
pub const OFFSET_KEY: &str = "subtitleOffsetMs";

/// The offset steps in milliseconds, in the order the buttons are drawn.
pub const OFFSET_STEPS_MS: [i32; 4] = [-500, -100, 100, 500];

/// One press of "Früher" / "Später" in the timing level, in milliseconds.
pub const OFFSET_STEP_FINE_MS: i32 = 100;

/// Entries the offset memory keeps; beyond it the oldest guess (any) entries are dropped.
pub const OFFSET_MEMORY_LIMIT: usize = 500;

/// One speed in the menu.
#[derive(Debug, Clone, PartialEq)]
pub struct SpeedRow {
    /// The playback speed, sent back as `PlayerIntent::Tempo(value)`.
    pub value: f32,
    /// "Normal" (a catalog key) for 1x, else "1,25×" with the host's separator.
    pub label: String,
    /// This is the running speed.
    pub selected: bool,
}

/// One offset button.
#[derive(Debug, Clone, PartialEq)]
pub struct OffsetStepRow {
    /// Sent back as `PlayerIntent::SubtitleOffsetStep(step_ms)`.
    pub step_ms: i32,
    /// "−0,5 s", "+0,1 s".
    pub label: String,
}

/// The speed and subtitle-offset rows of the player menu.
#[derive(Debug, Clone, PartialEq)]
pub struct PlayerMenu {
    /// Column title (catalog key).
    pub speed_title: &'static str,
    /// The offered speeds, slowest first.
    pub speeds: Vec<SpeedRow>,
    /// Column title (catalog key).
    pub offset_title: &'static str,
    /// The current offset in milliseconds (positive: the text comes later).
    pub offset_ms: i64,
    /// The current offset as text: "0 s", "+0,5 s", "−1 s".
    pub offset_text: String,
    /// The four buttons: −0,5, −0,1, +0,1, +0,5 seconds.
    pub offset_steps: Vec<OffsetStepRow>,
    /// Label of the reset button (catalog key).
    pub reset_label: &'static str,
    /// The reset button does something (the offset is not zero).
    pub can_reset: bool,
}

/// Seconds with a sign and the host's decimal separator: "+0,5 s", "−1 s", "0 s".
pub fn offset_label(milliseconds: i64, decimal_separator: &str) -> String {
    if milliseconds == 0 {
        return "0 s".to_owned();
    }
    let sign = if milliseconds < 0 { '\u{2212}' } else { '+' };
    let tenths = milliseconds.abs() / 100;
    let hundredths = (milliseconds.abs() % 100) / 10;
    let mut number = format!("{}", tenths / 10);
    if tenths % 10 != 0 || hundredths != 0 {
        number.push_str(decimal_separator);
        number.push_str(&(tenths % 10).to_string());
        if hundredths != 0 {
            number.push_str(&hundredths.to_string());
        }
    }
    format!("{sign}{number} s")
}

/// Builds the menu rows for the running speed and the current offset.
pub fn build(tempo: f32, offset_ms: i64, decimal_separator: &str) -> PlayerMenu {
    PlayerMenu {
        speed_title: "Geschwindigkeit",
        speeds: SPEED_VALUES
            .iter()
            .map(|&value| SpeedRow {
                value,
                label: if (value - 1.0).abs() < f32::EPSILON {
                    "Normal".to_owned()
                } else {
                    speed_label(value, decimal_separator)
                },
                selected: (tempo - value).abs() < 1e-3,
            })
            .collect(),
        offset_title: "Untertitel-Versatz",
        offset_ms,
        offset_text: offset_label(offset_ms, decimal_separator),
        offset_steps: OFFSET_STEPS_MS
            .iter()
            .map(|&step_ms| OffsetStepRow {
                step_ms,
                label: offset_label(i64::from(step_ms), decimal_separator),
            })
            .collect(),
        reset_label: "Zurücksetzen",
        can_reset: offset_ms != 0,
    }
}

/// The offset after a step: clamped and rounded by [`Delay`].
pub fn stepped(current_ms: i64, step_ms: i32) -> Delay {
    Delay::from_milliseconds(current_ms + i64::from(step_ms))
}

/// The remembered offset of a title, if one was stored.
pub fn remembered(all: &std::collections::HashMap<String, String>, title: &str) -> Option<Delay> {
    all.get(title)
        .and_then(|v| v.parse::<i64>().ok())
        .map(Delay::from_milliseconds)
}

/// Writes the offset of a title into the memory dictionary; zero removes the entry.
pub fn write(all: &mut std::collections::HashMap<String, String>, title: &str, offset: Delay) {
    if offset.milliseconds() == 0 {
        all.remove(title);
        return;
    }
    all.insert(title.to_owned(), offset.milliseconds().to_string());
    while all.len() > OFFSET_MEMORY_LIMIT {
        let Some(any) = all.keys().find(|k| k.as_str() != title).cloned() else {
            break;
        };
        all.remove(&any);
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// The whole menu structure: one model for every host (design "Player-Menüs", round 2).
// ---------------------------------------------------------------------------------------------------------------------

/// A text and how to translate it. Hosts translate `Key` and `Count` through the catalogue (`Count` carries the number
/// for the key's `%lld`), and draw `Literal` as it is (numbers already carry the host's decimal separator).
#[derive(Debug, Clone, PartialEq)]
pub enum Words {
    /// A German catalogue key.
    Key(&'static str),
    /// A catalogue key with one `%lld`, e.g. "%lld Min." and 30.
    Count(&'static str, i64),
    /// Two catalogue keys joined by " · " ("Groß · Fläche").
    Pair(&'static str, &'static str),
    /// Text that is shown as it is (a server name, a formatted number).
    Literal(String),
}

impl Words {
    /// The text in the translator's language.
    pub fn resolve(&self, tr: &swiftly_l10n::Translator) -> String {
        match self {
            Self::Key(k) => tr.t(k),
            Self::Count(k, n) => tr.t_args(k, &[swiftly_l10n::Arg::Int(*n)]),
            Self::Pair(a, b) => format!("{} · {}", tr.t(a), tr.t(b)),
            Self::Literal(s) => s.clone(),
        }
    }
}

fn key(k: &'static str) -> Words {
    Words::Key(k)
}

/// A season's name in the device language. The server names its seasons in its own language ("Staffel 1" on a German
/// server), so the plain "Season N" / "Staffel N" names are rebuilt from the number through the catalogue; a named
/// season (a title, "Specials") stays as the server wrote it.
fn season_words(s: &SeasonRow) -> Words {
    match s.number {
        Some(n)
            if n > 0 && (s.name == format!("Staffel {n}") || s.name == format!("Season {n}")) =>
        {
            Words::Count("Staffel %lld", n)
        }
        Some(0) if s.name == "Specials" => Words::Key("Specials"),
        _ => lit(s.name.clone()),
    }
}

fn lit(s: impl Into<String>) -> Words {
    Words::Literal(s.into())
}

/// The two tabs of the track panel and of the timing level.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrackTab {
    /// "Untertitel".
    Subtitles,
    /// "Ton".
    Audio,
}

/// The two tabs of the episodes panel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PanelTab {
    /// "Folgen" (series only).
    Episodes,
    /// "Kapitel".
    Chapters,
}

/// A page (level) of the menus. Sheets open at [`MenuLevel::Options`], [`MenuLevel::Tracks`] or [`MenuLevel::Episodes`];
/// every other level is reached through a [`MenuAction::Open`] and left with the host's back arrow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuLevel {
    /// The options list (speed, sleep timer, picture, quality, group).
    Options,
    /// Speed choices.
    Speed,
    /// Sleep timer choices.
    Sleep,
    /// Picture: Original / Füllen.
    Picture,
    /// Quality: Original, bitrates, technical overlay.
    Quality,
    /// The watch-together group.
    Together,
    /// Subtitle and audio tracks (two tabs).
    Tracks(TrackTab),
    /// Subtitle style (size, background, colour).
    SubtitleLook,
    /// "Zeit anpassen" for one tab.
    TimeAdjust(TrackTab),
    /// Episodes and chapters (tabs, season button).
    Episodes(PanelTab),
    /// The season list; after a [`MenuAction::SelectSeason`] the host goes back to `Episodes(Episodes)`.
    Seasons,
    /// "Übergeben an …".
    Handoff,
}

/// What a press does. `Player` goes to [`crate::PlayerVm::send`]; the others are decided by the host's glue because
/// they live outside the player model (navigation, settings, the group, the system).
#[derive(Debug, Clone, PartialEq)]
pub enum MenuAction {
    /// Send this intent to the player model.
    Player(crate::PlayerIntent),
    /// Go to another level.
    Open(MenuLevel),
    /// Store this subtitle look in the settings (the whole look that results from the press).
    Look(SubtitleLook),
    /// Set the technical overlay on or off (a host setting).
    TechBadge(bool),
    /// Leave the SyncPlay group.
    LeaveGroup,
    /// Outside a group: open "Gemeinsam schauen starten" for the playing title (the host's sheet).
    StartTogether,
    /// Lock the screen against touches (the host's lock).
    LockScreen,
    /// Open the problem report.
    ReportProblem,
    /// Search subtitles online (the existing subtitle search).
    SearchSubtitles,
    /// Another season for the episodes panel: `SeriesIntent::SelectSeason { id }`.
    SelectSeason(String),
    /// Hand the playback over to this device (the takeover session id).
    Handoff(String),
    /// Hand the picture to AirPlay (Apple only; the row is absent elsewhere).
    AirPlay,
}

/// One choice: a row, a capsule or a segment.
#[derive(Debug, Clone, PartialEq)]
pub struct MenuChoice {
    /// The text.
    pub label: Words,
    /// A second line ("Direct Play" under "Original"), if any.
    pub detail: Option<Words>,
    /// This is the current value.
    pub selected: bool,
    /// What a press does.
    pub action: MenuAction,
}

/// A row with the current value on the right; a press opens its level.
#[derive(Debug, Clone, PartialEq)]
pub struct ValueRow {
    /// Row title.
    pub title: Words,
    /// The current value.
    pub value: Words,
    /// What a press does (opens the level).
    pub action: MenuAction,
}

/// A row without a value (the footer, "Verlassen").
#[derive(Debug, Clone, PartialEq)]
pub struct ActionRow {
    /// Row title.
    pub title: Words,
    /// What a press does.
    pub action: MenuAction,
}

/// The first level: rows with their values, then the footer.
#[derive(Debug, Clone, PartialEq)]
pub struct OptionsPage {
    /// Geschwindigkeit, Schlafzeit, Bild, Qualität and, Gemeinsam schauen (always: inside a group it opens the group, outside it starts one), in this order.
    pub rows: Vec<ValueRow>,
    /// Bildschirm sperren, Problem melden.
    pub footer: Vec<ActionRow>,
}

/// A level with a title and a list of choices (speed, picture).
#[derive(Debug, Clone, PartialEq)]
pub struct ChoicePage {
    /// Level title.
    pub title: Words,
    /// The choices.
    pub choices: Vec<MenuChoice>,
}

/// The sleep timer level.
#[derive(Debug, Clone, PartialEq)]
pub struct SleepPage {
    /// Level title ("Schlafzeit").
    pub title: Words,
    /// "Aus" and "Ende dieser Folge".
    pub choices: Vec<MenuChoice>,
    /// Caption of the capsules ("In Minuten").
    pub minutes_title: Words,
    /// 15, 30, 45, 60, 90 as capsules.
    pub minutes: Vec<MenuChoice>,
}

/// The quality level.
#[derive(Debug, Clone, PartialEq)]
pub struct QualityPage {
    /// Level title.
    pub title: Words,
    /// The title can switch quality (a download, a server that may not convert and a group cannot): when `false`
    /// the host draws `original` selected and no capsules.
    pub offered: bool,
    /// "Original" with the detail "Direct Play".
    pub original: MenuChoice,
    /// Caption of the capsules ("Höchstens (Mbit/s)").
    pub bitrate_title: Words,
    /// 80, 40, 20, 8, 4 Mbit/s as capsules (empty when not offered).
    pub bitrates: Vec<MenuChoice>,
    /// Label of the technical overlay switch.
    pub badge_title: Words,
    /// The switch is on.
    pub badge_on: bool,
    /// The press on the switch: `TechBadge(!badge_on)`.
    pub badge_action: MenuAction,
}

/// One person of the group.
#[derive(Debug, Clone, PartialEq)]
pub struct MemberRow {
    /// The name.
    pub name: String,
    /// This is the signed-in user.
    pub me: bool,
    /// "Du", "schaut mit", "hat pausiert", "wartet".
    pub status: Words,
}

/// The watch-together level; exists only inside a group.
#[derive(Debug, Clone, PartialEq)]
pub struct TogetherPage {
    /// Level title ("Gemeinsam schauen").
    pub title: Words,
    /// The group's name.
    pub group_name: String,
    /// The people, the user first.
    pub members: Vec<MemberRow>,
    /// "Verlassen" (`MenuAction::LeaveGroup`).
    pub leave: ActionRow,
}

/// One track row; the label is the cached track label.
#[derive(Debug, Clone, PartialEq)]
pub struct TrackChoice {
    /// The track label ("Deutsch · Dolby Digital · 5.1"); "Aus" is a catalogue key, see `label_is_key`.
    pub label: String,
    /// `label` is a catalogue key (the "Aus" row), not a track label.
    pub label_is_key: bool,
    /// Chosen now.
    pub selected: bool,
    /// A forced subtitle.
    pub forced: bool,
    /// A subtitle from a file next to the video.
    pub file: bool,
    /// A subtitle for the hard of hearing.
    pub hearing_impaired: bool,
    /// `SelectSubtitle(index)` / `SelectAudio(index)`.
    pub action: MenuAction,
}

/// One tab of the track panel.
#[derive(Debug, Clone, PartialEq)]
pub struct TrackTabPage {
    /// Tab title ("Untertitel", "Ton").
    pub title: Words,
    /// The rows; the subtitle tab starts with "Aus".
    pub rows: Vec<TrackChoice>,
    /// The magnifier of the subtitle tab (`SearchSubtitles`); `None` on the audio tab.
    pub search: Option<MenuAction>,
}

/// The "Ton & Untertitel" level.
#[derive(Debug, Clone, PartialEq)]
pub struct TracksPage {
    /// The tabs, subtitles first.
    pub tabs: Vec<TrackTab>,
    /// The subtitle tab.
    pub subtitles: TrackTabPage,
    /// The audio tab.
    pub audio: TrackTabPage,
    /// "Aussehen" with "Groß · Fläche" (subtitle tab only); its level is titled "Untertitel-Aussehen".
    pub look: ValueRow,
    /// "Zeit anpassen" with the subtitle offset ("0 s", "+0,3 s") on the subtitle tab.
    pub subtitle_time: ValueRow,
    /// "Zeit anpassen" with the audio delay on the audio tab.
    pub audio_time: ValueRow,
}

/// A group of capsules of the subtitle style.
#[derive(Debug, Clone, PartialEq)]
pub struct LookGroup {
    /// "Größe", "Hintergrund", "Farbe".
    pub title: Words,
    /// The capsules; each press stores the whole resulting look.
    pub choices: Vec<MenuChoice>,
}

/// The "Untertitel-Aussehen" level.
#[derive(Debug, Clone, PartialEq)]
pub struct LookPage {
    /// Level title.
    pub title: Words,
    /// Size, background, colour.
    pub groups: Vec<LookGroup>,
}

/// The "Zeit anpassen" level for one tab.
#[derive(Debug, Clone, PartialEq)]
pub struct TimeTab {
    /// Which tab.
    pub tab: TrackTab,
    /// Tab title.
    pub title: Words,
    /// The value in milliseconds (positive: later).
    pub value_ms: i64,
    /// The big value: "+0,3 s".
    pub value: String,
    /// The sentence that says what the value means ("Untertitel kommen später.").
    pub meaning: Words,
    /// "Früher" (-0.1 s).
    pub earlier: ActionRow,
    /// "Später" (+0.1 s).
    pub later: ActionRow,
    /// "Zurücksetzen"; `None` while the value is 0.
    pub reset: Option<ActionRow>,
}

/// The "Zeit anpassen" level.
#[derive(Debug, Clone, PartialEq)]
pub struct TimePage {
    /// Level title.
    pub title: Words,
    /// Subtitles, then audio.
    pub tabs: Vec<TimeTab>,
}

/// The episodes panel: tabs and the season button.
#[derive(Debug, Clone, PartialEq)]
pub struct EpisodesPage {
    /// Series: Folgen (and Kapitel when the file has chapters); film: only Kapitel. One tab means no tab bar.
    pub tabs: Vec<PanelTab>,
    /// The header button of the Folgen tab with the open season ("Staffel 1"); `None` for a film or without seasons.
    pub season_button: Option<ValueRow>,
    /// The season list level: `title` and one choice per season (the open one selected).
    pub seasons_title: Words,
    /// The seasons.
    pub seasons: Vec<MenuChoice>,
}

/// One device in "Übergeben an …".
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceRow {
    /// Name of the device.
    pub name: String,
    /// Kind, for the symbol.
    pub kind: DevicesKind,
    /// The second line (the app on it, "AirPlay"), if any.
    pub detail: Option<String>,
    /// `Handoff(id)` / `AirPlay`.
    pub action: MenuAction,
    /// This device is taking the playback over right now (the row shows its spinner).
    pub busy: bool,
    /// The row can be chosen: false for every other row while one device is taking over.
    pub enabled: bool,
}

/// What the handoff level draws.
#[derive(Debug, Clone, PartialEq)]
pub enum HandoffState {
    /// The device list is being fetched.
    Loading,
    /// Fetched and nothing to hand over to.
    Empty,
    /// At least one row.
    List,
}

/// The "Übergeben an …" level.
#[derive(Debug, Clone, PartialEq)]
pub struct HandoffPage {
    /// Level title.
    pub title: Words,
    /// The state of the list.
    pub state: HandoffState,
    /// The loading or empty sentence ("Suche Geräte …", "Keine Geräte gefunden"), `None` for a list.
    pub text: Option<Words>,
    /// The devices.
    pub rows: Vec<DeviceRow>,
    /// The AirPlay row, on Apple hosts only.
    pub airplay: Option<DeviceRow>,
    /// The note under the list.
    pub note: Words,
}

/// All menus of the player, built at once: the host draws the level it shows and sends the action of a pressed row.
#[derive(Debug, Clone, PartialEq)]
pub struct PlayerMenus {
    /// Options list.
    pub options: OptionsPage,
    /// Speed.
    pub speed: ChoicePage,
    /// Sleep timer.
    pub sleep: SleepPage,
    /// Picture.
    pub picture: ChoicePage,
    /// Quality.
    pub quality: QualityPage,
    /// Group; `None` outside a group.
    pub together: Option<TogetherPage>,
    /// Tracks.
    pub tracks: TracksPage,
    /// Subtitle style.
    pub look: LookPage,
    /// Timing.
    pub time: TimePage,
    /// Episodes and chapters.
    pub episodes: EpisodesPage,
    /// Handoff.
    pub handoff: HandoffPage,
}

/// How far a person of the group is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemberStatus {
    /// Plays along.
    Watching,
    /// Paused.
    Paused,
    /// Waits for the others.
    Waiting,
}

/// One person of the group, as the host's SyncPlay model knows them.
#[derive(Debug, Clone, PartialEq)]
pub struct GroupMember {
    /// The name.
    pub name: String,
    /// The signed-in user.
    pub me: bool,
    /// The state.
    pub status: MemberStatus,
}

/// The group the player is in.
#[derive(Debug, Clone, PartialEq)]
pub struct GroupInfo {
    /// The group's name.
    pub name: String,
    /// All people including the user.
    pub members: Vec<GroupMember>,
}

/// The device list of the handoff level.
#[derive(Debug, Clone, PartialEq)]
pub enum HandoffInput {
    /// Being fetched.
    Loading,
    /// Fetched (possibly empty).
    Devices(Vec<HandoffDevice>),
    /// Fetched, and the device with id `busy` is taking the playback over right now (design frame 14).
    Handing {
        /// All devices.
        devices: Vec<HandoffDevice>,
        /// Takeover session id of the device that is being handed to.
        busy: String,
    },
}

/// One device that can take the playback.
#[derive(Debug, Clone, PartialEq)]
pub struct HandoffDevice {
    /// Takeover session id.
    pub id: String,
    /// Device name.
    pub name: String,
    /// Kind.
    pub kind: DevicesKind,
    /// The second line, if any.
    pub detail: Option<String>,
}

/// What only the host knows; everything else the model reads from the player.
#[derive(Debug, Clone, PartialEq)]
pub struct MenuInputs {
    /// "," or "." of the host's locale.
    pub decimal_separator: String,
    /// The technical overlay is on (a host setting).
    pub tech_badge: bool,
    /// The SyncPlay group, `None` outside.
    pub group: Option<GroupInfo>,
    /// The current subtitle style (a host setting).
    pub look: SubtitleLook,
    /// The seasons of the series (`SeasonsPart::seasons`); empty for a film.
    pub seasons: Vec<SeasonRow>,
    /// The season the episodes panel shows (`SeasonsPart::selected`).
    pub shown_season: Option<String>,
    /// The device list.
    pub handoff: HandoffInput,
    /// An AirPlay row is offered (Apple hosts).
    pub airplay: bool,
}

/// The sleep timer as the player holds it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SleepState {
    /// No timer.
    Off,
    /// Pauses at the end of this episode.
    EndOfEpisode,
    /// Pauses after this many minutes.
    Minutes(u32),
}

/// What the menus read from the player; [`crate::PlayerVm::menus`] fills it.
#[derive(Debug, Clone, PartialEq)]
pub struct MenuState {
    /// Playback speed.
    pub tempo: f32,
    /// Sleep timer.
    pub sleep: SleepState,
    /// The picture fills the frame.
    pub fill: bool,
    /// Quality choice, `None` when not offered.
    pub quality: Option<Quality>,
    /// The title is an episode of a series.
    pub series: bool,
    /// The file has chapters.
    pub has_chapters: bool,
    /// The tracks.
    pub tracks: TracksPart,
}

/// The bitrate capsules, highest first (the settings levels without "no limit").
fn bitrate_levels() -> Vec<i64> {
    let mut levels: Vec<i64> = BITRATE_LEVELS.iter().copied().filter(|&n| n > 0).collect();
    levels.reverse();
    levels
}

fn background_name(look: &SubtitleLook) -> &'static str {
    if look.background {
        "Fläche"
    } else if look.shadow {
        "Schatten"
    } else {
        "Ohne"
    }
}

/// The explanation under the timing value.
fn meaning(tab: TrackTab, ms: i64) -> Words {
    key(match (tab, ms.signum()) {
        (_, 0) => "Keine Verschiebung.",
        (TrackTab::Subtitles, 1) => "Untertitel kommen später.",
        (TrackTab::Subtitles, _) => "Untertitel kommen früher.",
        (TrackTab::Audio, 1) => "Ton kommt später.",
        (TrackTab::Audio, _) => "Ton kommt früher.",
    })
}

fn time_tab(tab: TrackTab, ms: i64, sep: &str) -> TimeTab {
    let (step_earlier, step_later) = (-OFFSET_STEP_FINE_MS, OFFSET_STEP_FINE_MS);
    let intent = |step: i32| match tab {
        TrackTab::Subtitles => crate::PlayerIntent::SubtitleOffsetStep(step),
        TrackTab::Audio => crate::PlayerIntent::AudioDelay(stepped(ms, step)),
    };
    TimeTab {
        tab,
        title: key(match tab {
            TrackTab::Subtitles => "Untertitel",
            TrackTab::Audio => "Ton",
        }),
        value_ms: ms,
        value: offset_label(ms, sep),
        meaning: meaning(tab, ms),
        earlier: ActionRow {
            title: key("Früher"),
            action: MenuAction::Player(intent(step_earlier)),
        },
        later: ActionRow {
            title: key("Später"),
            action: MenuAction::Player(intent(step_later)),
        },
        reset: (ms != 0).then(|| ActionRow {
            title: key("Zurücksetzen"),
            action: MenuAction::Player(match tab {
                TrackTab::Subtitles => crate::PlayerIntent::SubtitleOffsetReset,
                TrackTab::Audio => crate::PlayerIntent::AudioDelay(Delay::NULL),
            }),
        }),
    }
}

/// Builds every menu from the player's state and the host's inputs.
pub fn build_menus(state: &MenuState, inputs: &MenuInputs) -> PlayerMenus {
    use crate::PlayerIntent as I;
    let sep = inputs.decimal_separator.as_str();
    let choice = |label: Words, selected: bool, action: MenuAction| MenuChoice {
        label,
        detail: None,
        selected,
        action,
    };

    // Speed.
    let speed_rows = build(state.tempo, 0, sep).speeds;
    let speed_value = speed_rows
        .iter()
        .find(|r| r.selected)
        .map_or_else(|| lit(speed_label(state.tempo, sep)), speed_words);
    let speed = ChoicePage {
        title: key("Geschwindigkeit"),
        choices: speed_rows
            .iter()
            .map(|r| {
                choice(
                    speed_words(r),
                    r.selected,
                    MenuAction::Player(I::Tempo(r.value)),
                )
            })
            .collect(),
    };

    // Sleep.
    let sleep_value = match state.sleep {
        SleepState::Off => key("Aus"),
        SleepState::EndOfEpisode => key("Ende dieser Folge"),
        SleepState::Minutes(m) => Words::Count("%lld Min.", i64::from(m)),
    };
    let sleep = SleepPage {
        title: key("Schlafzeit"),
        choices: vec![
            choice(
                key("Aus"),
                state.sleep == SleepState::Off,
                MenuAction::Player(I::Sleep(None)),
            ),
            choice(
                key("Ende dieser Folge"),
                state.sleep == SleepState::EndOfEpisode,
                MenuAction::Player(I::SleepEndOfEpisode),
            ),
        ],
        minutes_title: key("In Minuten"),
        minutes: SLEEP_TIMES
            .iter()
            .map(|&m| {
                choice(
                    lit(m.to_string()),
                    state.sleep == SleepState::Minutes(m as u32),
                    MenuAction::Player(I::Sleep(Some(m as u32))),
                )
            })
            .collect(),
    };

    // Picture.
    let picture_value = key(if state.fill { "Füllen" } else { "Original" });
    let picture = ChoicePage {
        title: key("Bild"),
        choices: vec![
            choice(
                key("Original"),
                !state.fill,
                MenuAction::Player(I::Fill(false)),
            ),
            choice(key("Füllen"), state.fill, MenuAction::Player(I::Fill(true))),
        ],
    };

    // Quality.
    let offered = state.quality.is_some();
    let q = state.quality.unwrap_or(Quality {
        direct_play: true,
        limit: 0,
    });
    let original_on = !offered || q.direct_play || q.limit == 0;
    let quality_value = if original_on {
        key("Direct Play")
    } else {
        Words::Count("%lld Mbit/s", q.limit)
    };
    let quality = QualityPage {
        title: key("Qualität"),
        offered,
        original: MenuChoice {
            label: key("Original"),
            detail: Some(key("Direct Play")),
            selected: original_on,
            action: MenuAction::Player(I::Quality(None)),
        },
        bitrate_title: key("Höchstens (Mbit/s)"),
        bitrates: if offered {
            bitrate_levels()
                .into_iter()
                .map(|n| {
                    choice(
                        lit(n.to_string()),
                        !original_on && q.limit == n,
                        MenuAction::Player(I::Quality(Some(n))),
                    )
                })
                .collect()
        } else {
            Vec::new()
        },
        badge_title: key("Technikschild"),
        badge_on: inputs.tech_badge,
        badge_action: MenuAction::TechBadge(!inputs.tech_badge),
    };

    // Group.
    let together = inputs.group.as_ref().map(|g| {
        let mut members: Vec<MemberRow> = g
            .members
            .iter()
            .map(|m| MemberRow {
                name: m.name.clone(),
                me: m.me,
                status: key(if m.me {
                    "Du"
                } else {
                    match m.status {
                        MemberStatus::Watching => "schaut mit",
                        MemberStatus::Paused => "hat pausiert",
                        MemberStatus::Waiting => "wartet",
                    }
                }),
            })
            .collect();
        members.sort_by_key(|m| !m.me);
        TogetherPage {
            title: key("Gemeinsam schauen"),
            group_name: g.name.clone(),
            members,
            leave: ActionRow {
                title: key("Verlassen"),
                action: MenuAction::LeaveGroup,
            },
        }
    });

    // Tracks and timing.
    let subtitle_ms = state.tracks.subtitle_delay_ms;
    let audio_ms = state.tracks.audio_delay_ms;
    let mut subtitle_rows = vec![TrackChoice {
        label: "Aus".to_owned(),
        label_is_key: true,
        selected: state.tracks.subtitles_off,
        forced: false,
        file: false,
        hearing_impaired: false,
        action: MenuAction::Player(I::SelectSubtitle(-1)),
    }];
    let track_row = |t: &TrackRow, action: MenuAction| TrackChoice {
        label: t.label.clone(),
        label_is_key: false,
        selected: t.selected,
        forced: t.forced,
        file: t.file,
        hearing_impaired: t.hearing_impaired,
        action,
    };
    subtitle_rows.extend(
        state
            .tracks
            .subtitles
            .iter()
            .map(|t| track_row(t, MenuAction::Player(I::SelectSubtitle(t.index)))),
    );
    let tracks = TracksPage {
        tabs: vec![TrackTab::Subtitles, TrackTab::Audio],
        subtitles: TrackTabPage {
            title: key("Untertitel"),
            rows: subtitle_rows,
            search: Some(MenuAction::SearchSubtitles),
        },
        audio: TrackTabPage {
            title: key("Ton"),
            rows: state
                .tracks
                .audio
                .iter()
                .map(|t| track_row(t, MenuAction::Player(I::SelectAudio(t.index))))
                .collect(),
            search: None,
        },
        look: ValueRow {
            title: key("Aussehen"),
            value: Words::Pair(inputs.look.size.name_key(), background_name(&inputs.look)),
            action: MenuAction::Open(MenuLevel::SubtitleLook),
        },
        subtitle_time: ValueRow {
            title: key("Zeit anpassen"),
            value: lit(offset_label(subtitle_ms, sep)),
            action: MenuAction::Open(MenuLevel::TimeAdjust(TrackTab::Subtitles)),
        },
        audio_time: ValueRow {
            title: key("Zeit anpassen"),
            value: lit(offset_label(audio_ms, sep)),
            action: MenuAction::Open(MenuLevel::TimeAdjust(TrackTab::Audio)),
        },
    };

    // Subtitle style.
    let look = inputs.look;
    let look_choices = |f: &dyn Fn() -> Vec<(Words, bool, SubtitleLook)>| -> Vec<MenuChoice> {
        f().into_iter()
            .map(|(label, selected, result)| choice(label, selected, MenuAction::Look(result)))
            .collect()
    };
    let look_page = LookPage {
        title: key("Untertitel-Aussehen"),
        groups: vec![
            LookGroup {
                title: key("Größe"),
                choices: look_choices(&|| {
                    Size::ALL
                        .iter()
                        .map(|&size| {
                            (
                                key(size.name_key()),
                                look.size == size,
                                SubtitleLook { size, ..look },
                            )
                        })
                        .collect()
                }),
            },
            LookGroup {
                title: key("Hintergrund"),
                choices: look_choices(&|| {
                    [
                        ("Ohne", false, false),
                        ("Schatten", true, false),
                        ("Fläche", false, true),
                    ]
                    .iter()
                    .map(|&(name, shadow, background)| {
                        (
                            key(name),
                            background_name(&look) == name,
                            SubtitleLook {
                                shadow,
                                background,
                                ..look
                            },
                        )
                    })
                    .collect()
                }),
            },
            LookGroup {
                title: key("Farbe"),
                choices: look_choices(&|| {
                    Colour::ALL
                        .iter()
                        .map(|&colour| {
                            (
                                key(colour.name_key()),
                                look.colour == colour,
                                SubtitleLook { colour, ..look },
                            )
                        })
                        .collect()
                }),
            },
        ],
    };
    let time = TimePage {
        title: key("Zeit anpassen"),
        tabs: vec![
            time_tab(TrackTab::Subtitles, subtitle_ms, sep),
            time_tab(TrackTab::Audio, audio_ms, sep),
        ],
    };

    // Episodes and chapters.
    let shown = inputs
        .seasons
        .iter()
        .find(|s| Some(&s.id) == inputs.shown_season.as_ref())
        .or_else(|| inputs.seasons.first());
    let mut panel_tabs = Vec::new();
    if state.series {
        panel_tabs.push(PanelTab::Episodes);
    }
    if !state.series || state.has_chapters {
        panel_tabs.push(PanelTab::Chapters);
    }
    let episodes = EpisodesPage {
        tabs: panel_tabs,
        season_button: shown.filter(|_| state.series).map(|s| ValueRow {
            title: key("Staffel"),
            value: season_words(s),
            action: MenuAction::Open(MenuLevel::Seasons),
        }),
        seasons_title: key("Staffel wählen"),
        seasons: inputs
            .seasons
            .iter()
            .map(|s| {
                choice(
                    season_words(s),
                    shown.is_some_and(|c| c.id == s.id),
                    MenuAction::SelectSeason(s.id.clone()),
                )
            })
            .collect(),
    };

    // Handoff.
    let (devices, busy): (&[HandoffDevice], Option<&str>) = match &inputs.handoff {
        HandoffInput::Loading => (&[], None),
        HandoffInput::Devices(d) => (d, None),
        HandoffInput::Handing { devices, busy } => (devices, Some(busy)),
    };
    let (hstate, rows) = match &inputs.handoff {
        HandoffInput::Loading => (HandoffState::Loading, Vec::new()),
        _ if devices.is_empty() => (HandoffState::Empty, Vec::new()),
        _ => (
            HandoffState::List,
            devices
                .iter()
                .map(|d| DeviceRow {
                    name: d.name.clone(),
                    kind: d.kind,
                    detail: d.detail.clone(),
                    action: MenuAction::Handoff(d.id.clone()),
                    busy: busy == Some(d.id.as_str()),
                    enabled: busy.is_none() || busy == Some(d.id.as_str()),
                })
                .collect(),
        ),
    };
    // While a device takes over, the note says what the player does meanwhile (design frame 14); else where it continues (frame 13).
    let note = if busy.is_some() {
        key("Hier ist angehalten, bis der Fernseher übernimmt.")
    } else {
        key("Läuft dort an derselben Stelle weiter.")
    };
    let handoff = HandoffPage {
        title: key("Übergeben an …"),
        text: match hstate {
            HandoffState::Loading => Some(key("Suche Geräte …")),
            HandoffState::Empty => Some(key("Keine Geräte gefunden")),
            HandoffState::List => None,
        },
        state: hstate,
        rows,
        airplay: inputs.airplay.then(|| DeviceRow {
            name: "AirPlay".to_owned(),
            kind: DevicesKind::Tv,
            detail: None,
            action: MenuAction::AirPlay,
            busy: false,
            enabled: busy.is_none(),
        }),
        note,
    };

    // Options.
    let row = |title: &'static str, value: Words, level: MenuLevel| ValueRow {
        title: key(title),
        value,
        action: MenuAction::Open(level),
    };
    let mut rows = vec![
        row("Geschwindigkeit", speed_value, MenuLevel::Speed),
        row("Schlafzeit", sleep_value, MenuLevel::Sleep),
        row("Bild", picture_value, MenuLevel::Picture),
        row("Qualität", quality_value, MenuLevel::Quality),
    ];
    match &together {
        Some(g) => rows.push(row(
            "Gemeinsam schauen",
            lit(g.group_name.clone()),
            MenuLevel::Together,
        )),
        // Outside a group the row is still there, without a value; a press starts a group.
        None => rows.push(ValueRow {
            title: key("Gemeinsam schauen"),
            value: lit(String::new()),
            action: MenuAction::StartTogether,
        }),
    }
    let options = OptionsPage {
        rows,
        footer: vec![
            ActionRow {
                title: key("Bildschirm sperren"),
                action: MenuAction::LockScreen,
            },
            ActionRow {
                title: key("Problem melden"),
                action: MenuAction::ReportProblem,
            },
        ],
    };

    PlayerMenus {
        options,
        speed,
        sleep,
        picture,
        quality,
        together,
        tracks,
        look: look_page,
        time,
        episodes,
        handoff,
    }
}

fn speed_words(row: &SpeedRow) -> Words {
    if row.label == "Normal" {
        key("Normal")
    } else {
        lit(row.label.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn the_speeds_are_the_shared_steps_and_one_is_marked() {
        let m = build(1.5, 0, ",");
        let values: Vec<f32> = m.speeds.iter().map(|r| r.value).collect();
        assert_eq!(values, SPEED_VALUES.to_vec());
        assert_eq!(m.speeds.iter().filter(|r| r.selected).count(), 1);
        assert!(m.speeds.iter().find(|r| r.value == 1.5).unwrap().selected);
        assert_eq!(m.speeds[1].label, "Normal");
        assert_eq!(m.speeds[0].label, "0,75×");
        assert_eq!(build(1.0, 0, ".").speeds[2].label, "1.25×");
    }

    #[test]
    fn the_offset_reads_in_seconds_with_a_sign() {
        assert_eq!(offset_label(0, ","), "0 s");
        assert_eq!(offset_label(500, ","), "+0,5 s");
        assert_eq!(offset_label(-100, "."), "\u{2212}0.1 s");
        assert_eq!(offset_label(1000, ","), "+1 s");
        assert_eq!(offset_label(-1500, ","), "\u{2212}1,5 s");
        assert_eq!(offset_label(50, ","), "+0,05 s");
        assert_eq!(offset_label(10_000, ","), "+10 s");
    }

    #[test]
    fn the_four_steps_and_the_reset_state() {
        let m = build(1.0, 0, ",");
        let steps: Vec<i32> = m.offset_steps.iter().map(|s| s.step_ms).collect();
        assert_eq!(steps, vec![-500, -100, 100, 500]);
        assert_eq!(m.offset_steps[0].label, "\u{2212}0,5 s");
        assert!(!m.can_reset);
        assert!(build(1.0, 300, ",").can_reset);
    }

    #[test]
    fn every_text_of_the_menu_is_in_the_catalogue_for_each_language() {
        // The texts are German catalogue keys the host translates; a key missing from the catalogue would show German.
        use swiftly_l10n::{Locale, Translator};
        let m = build(1.0, 0, ",");
        let keys = [m.speed_title, m.offset_title, m.reset_label, "Normal"];
        for language in ["en", "ru"] {
            let tr = Translator::new(Locale::parse(language));
            for key in keys {
                // "Normal" is the same word in English.
                if key == "Normal" && language == "en" {
                    continue;
                }
                assert_ne!(tr.t(key), key, "{key} has no {language} text");
            }
        }
        assert_eq!(
            Translator::new(Locale::parse("de")).t("Geschwindigkeit"),
            "Geschwindigkeit"
        );
    }

    #[test]
    fn steps_add_up_and_stop_at_the_limit() {
        assert_eq!(stepped(0, 500).milliseconds(), 500);
        assert_eq!(stepped(500, -100).milliseconds(), 400);
        assert_eq!(stepped(9_800, 500).milliseconds(), Delay::LIMIT);
        assert_eq!(stepped(-9_800, -500).milliseconds(), -Delay::LIMIT);
    }

    #[test]
    fn the_memory_keeps_nonzero_offsets_per_title_and_drops_zero() {
        let mut all = HashMap::new();
        write(&mut all, "film-1", Delay::from_milliseconds(1000));
        write(&mut all, "film-2", Delay::from_milliseconds(-250));
        assert_eq!(remembered(&all, "film-1").unwrap().milliseconds(), 1000);
        assert_eq!(remembered(&all, "film-2").unwrap().milliseconds(), -250);
        assert!(remembered(&all, "film-3").is_none());
        write(&mut all, "film-1", Delay::NULL);
        assert!(remembered(&all, "film-1").is_none());
        assert_eq!(all.len(), 1);
    }

    #[test]
    fn the_memory_stays_bounded_and_keeps_the_newest_write() {
        let mut all = HashMap::new();
        for i in 0..(OFFSET_MEMORY_LIMIT + 40) {
            write(&mut all, &format!("t{i}"), Delay::from_milliseconds(100));
        }
        write(&mut all, "latest", Delay::from_milliseconds(500));
        assert!(all.len() <= OFFSET_MEMORY_LIMIT);
        assert_eq!(remembered(&all, "latest").unwrap().milliseconds(), 500);
    }

    fn state(series: bool) -> MenuState {
        let row = |index: i64, label: &str, selected: bool| TrackRow {
            index,
            label: label.to_owned(),
            selected,
            forced: false,
            file: false,
            hearing_impaired: false,
        };
        MenuState {
            tempo: 1.0,
            sleep: SleepState::Off,
            fill: false,
            quality: Some(Quality {
                direct_play: true,
                limit: 0,
            }),
            series,
            has_chapters: true,
            tracks: TracksPart {
                audio: vec![
                    row(1, "Deutsch · AC-3 · 5.1", true),
                    row(2, "Englisch · DTS", false),
                ],
                subtitles: vec![row(3, "Deutsch", true), row(4, "Englisch", false)],
                subtitles_off: false,
                audio_delay_ms: 0,
                subtitle_delay_ms: 0,
            },
        }
    }

    fn inputs() -> MenuInputs {
        let season = |n: i64| SeasonRow {
            id: format!("s{n}"),
            name: format!("Staffel {n}"),
            number: Some(n),
        };
        MenuInputs {
            decimal_separator: ",".to_owned(),
            tech_badge: false,
            group: None,
            look: SubtitleLook::STANDARD,
            seasons: vec![season(1), season(2), season(3)],
            shown_season: Some("s1".to_owned()),
            handoff: HandoffInput::Loading,
            airplay: false,
        }
    }

    fn value_of<'a>(menus: &'a PlayerMenus, title: &str) -> Option<&'a Words> {
        menus
            .options
            .rows
            .iter()
            .find(|r| r.title == Words::Key(title_key(title)))
            .map(|r| &r.value)
    }

    fn title_key(title: &str) -> &'static str {
        [
            "Geschwindigkeit",
            "Schlafzeit",
            "Bild",
            "Qualität",
            "Gemeinsam schauen",
        ]
        .into_iter()
        .find(|k| *k == title)
        .unwrap()
    }

    #[test]
    fn the_options_rows_show_the_current_values() {
        let mut s = state(true);
        s.tempo = 1.25;
        s.sleep = SleepState::Minutes(30);
        s.fill = true;
        let m = build_menus(&s, &inputs());
        assert_eq!(
            value_of(&m, "Geschwindigkeit"),
            Some(&Words::Literal("1,25×".into()))
        );
        assert_eq!(
            value_of(&m, "Schlafzeit"),
            Some(&Words::Count("%lld Min.", 30))
        );
        assert_eq!(value_of(&m, "Bild"), Some(&Words::Key("Füllen")));
        assert_eq!(value_of(&m, "Qualität"), Some(&Words::Key("Direct Play")));
        let titles: Vec<&Words> = m.options.rows.iter().map(|r| &r.title).collect();
        assert_eq!(titles.len(), 5, "the group row is always there");
        let last = m.options.rows.last().unwrap();
        assert_eq!(last.title, Words::Key("Gemeinsam schauen"));
        assert_eq!(
            last.action,
            MenuAction::StartTogether,
            "outside a group it starts one"
        );
        assert_eq!(m.options.footer.len(), 2);
        // A different separator reaches the speed.
        let dot = MenuInputs {
            decimal_separator: ".".into(),
            ..inputs()
        };
        assert_eq!(
            value_of(&build_menus(&s, &dot), "Geschwindigkeit"),
            Some(&Words::Literal("1.25×".into()))
        );
        // Normal reads as the catalogue key.
        assert_eq!(
            value_of(&build_menus(&state(true), &inputs()), "Geschwindigkeit"),
            Some(&Words::Key("Normal"))
        );
    }

    #[test]
    fn sleep_choices_mark_one_and_end_of_episode_is_its_own() {
        let mut s = state(true);
        s.sleep = SleepState::EndOfEpisode;
        let m = build_menus(&s, &inputs());
        assert_eq!(
            value_of(&m, "Schlafzeit"),
            Some(&Words::Key("Ende dieser Folge"))
        );
        assert!(m.sleep.choices[1].selected && !m.sleep.choices[0].selected);
        assert!(m.sleep.minutes.iter().all(|c| !c.selected));
        let minutes: Vec<_> = m.sleep.minutes.iter().map(|c| c.label.clone()).collect();
        assert_eq!(
            minutes,
            ["15", "30", "45", "60", "90"].map(|n| Words::Literal(n.into()))
        );
        assert_eq!(
            m.sleep.minutes[1].action,
            MenuAction::Player(crate::PlayerIntent::Sleep(Some(30)))
        );
        s.sleep = SleepState::Minutes(45);
        let m = build_menus(&s, &inputs());
        assert!(m.sleep.minutes[2].selected && !m.sleep.choices[1].selected);
    }

    #[test]
    fn quality_shows_original_bitrates_and_the_overlay_switch() {
        let m = build_menus(&state(true), &inputs());
        assert!(m.quality.offered && m.quality.original.selected);
        let labels: Vec<_> = m.quality.bitrates.iter().map(|c| c.label.clone()).collect();
        assert_eq!(
            labels,
            ["80", "40", "20", "8", "4"].map(|n| Words::Literal(n.into()))
        );
        assert_eq!(m.quality.badge_action, MenuAction::TechBadge(true));
        let mut s = state(true);
        s.quality = Some(Quality {
            direct_play: false,
            limit: 20,
        });
        let m = build_menus(
            &s,
            &MenuInputs {
                tech_badge: true,
                ..inputs()
            },
        );
        assert!(!m.quality.original.selected);
        assert!(
            m.quality.bitrates[2].selected
                && m.quality.bitrates.iter().filter(|c| c.selected).count() == 1
        );
        assert_eq!(
            value_of(&m, "Qualität"),
            Some(&Words::Count("%lld Mbit/s", 20))
        );
        assert_eq!(m.quality.badge_action, MenuAction::TechBadge(false));
        // Not offered (a download): no capsules, the overlay switch stays.
        s.quality = None;
        let m = build_menus(&s, &inputs());
        assert!(!m.quality.offered && m.quality.bitrates.is_empty() && m.quality.original.selected);
    }

    #[test]
    fn together_exists_only_inside_a_group() {
        assert!(build_menus(&state(true), &inputs()).together.is_none());
        let group = GroupInfo {
            name: "Filmabend".into(),
            members: vec![
                GroupMember {
                    name: "Lena".into(),
                    me: false,
                    status: MemberStatus::Paused,
                },
                GroupMember {
                    name: "Paul".into(),
                    me: true,
                    status: MemberStatus::Watching,
                },
                GroupMember {
                    name: "Jonas".into(),
                    me: false,
                    status: MemberStatus::Waiting,
                },
            ],
        };
        let m = build_menus(
            &state(true),
            &MenuInputs {
                group: Some(group),
                ..inputs()
            },
        );
        let page = m.together.as_ref().unwrap();
        assert_eq!(page.members[0].name, "Paul");
        assert_eq!(page.members[0].status, Words::Key("Du"));
        assert_eq!(page.members[1].status, Words::Key("hat pausiert"));
        assert_eq!(page.members[2].status, Words::Key("wartet"));
        assert_eq!(page.leave.action, MenuAction::LeaveGroup);
        assert_eq!(
            value_of(&m, "Gemeinsam schauen"),
            Some(&Words::Literal("Filmabend".into()))
        );
        assert_eq!(m.options.rows.len(), 5);
    }

    #[test]
    fn tracks_have_two_tabs_and_subtitles_start_with_off() {
        let m = build_menus(&state(true), &inputs());
        assert_eq!(m.tracks.tabs, vec![TrackTab::Subtitles, TrackTab::Audio]);
        let subs = &m.tracks.subtitles.rows;
        assert_eq!(subs.len(), 3);
        assert!(subs[0].label_is_key && subs[0].label == "Aus" && !subs[0].selected);
        assert_eq!(
            subs[0].action,
            MenuAction::Player(crate::PlayerIntent::SelectSubtitle(-1))
        );
        assert!(subs[1].selected && subs[1].label == "Deutsch");
        assert_eq!(
            subs[2].action,
            MenuAction::Player(crate::PlayerIntent::SelectSubtitle(4))
        );
        assert_eq!(
            m.tracks.audio.rows[1].action,
            MenuAction::Player(crate::PlayerIntent::SelectAudio(2))
        );
        assert!(m.tracks.subtitles.search.is_some() && m.tracks.audio.search.is_none());
        let mut s = state(true);
        s.tracks.subtitles_off = true;
        assert!(build_menus(&s, &inputs()).tracks.subtitles.rows[0].selected);
        assert_eq!(m.tracks.look.value, Words::Pair("Normal", "Ohne"));
    }

    #[test]
    fn the_timing_level_shows_one_value_per_tab_and_reset_only_when_not_zero() {
        use crate::PlayerIntent as I;
        let m = build_menus(&state(true), &inputs());
        let (sub, audio) = (&m.time.tabs[0], &m.time.tabs[1]);
        assert_eq!((sub.tab, audio.tab), (TrackTab::Subtitles, TrackTab::Audio));
        assert_eq!(sub.value, "0 s");
        assert_eq!(sub.meaning, Words::Key("Keine Verschiebung."));
        assert!(sub.reset.is_none() && audio.reset.is_none());
        assert_eq!(
            sub.earlier.action,
            MenuAction::Player(I::SubtitleOffsetStep(-100))
        );
        assert_eq!(
            sub.later.action,
            MenuAction::Player(I::SubtitleOffsetStep(100))
        );

        let mut s = state(true);
        s.tracks.subtitle_delay_ms = 300;
        s.tracks.audio_delay_ms = -200;
        let m = build_menus(&s, &inputs());
        let (sub, audio) = (&m.time.tabs[0], &m.time.tabs[1]);
        assert_eq!(sub.value, "+0,3 s");
        assert_eq!(sub.meaning, Words::Key("Untertitel kommen später."));
        assert_eq!(
            sub.reset.as_ref().unwrap().action,
            MenuAction::Player(I::SubtitleOffsetReset)
        );
        assert_eq!(audio.value, "\u{2212}0,2 s");
        assert_eq!(audio.meaning, Words::Key("Ton kommt früher."));
        assert_eq!(
            audio.reset.as_ref().unwrap().action,
            MenuAction::Player(I::AudioDelay(Delay::NULL))
        );
        assert_eq!(
            audio.later.action,
            MenuAction::Player(I::AudioDelay(Delay::from_milliseconds(-100)))
        );
        assert_eq!(
            audio.earlier.action,
            MenuAction::Player(I::AudioDelay(Delay::from_milliseconds(-300)))
        );
        assert_eq!(
            m.tracks.subtitle_time.value,
            Words::Literal("+0,3 s".into())
        );
        assert_eq!(
            m.tracks.audio_time.value,
            Words::Literal("\u{2212}0,2 s".into())
        );
    }

    #[test]
    fn the_subtitle_look_choices_carry_the_whole_resulting_look() {
        let m = build_menus(&state(true), &inputs());
        let [size, background, colour] = &m.look.groups[..] else {
            panic!("three groups")
        };
        assert_eq!(size.choices.len(), 4);
        assert!(size.choices[1].selected);
        assert_eq!(background.choices.len(), 3);
        assert!(background.choices[0].selected);
        let MenuAction::Look(look) = &background.choices[2].action else {
            panic!()
        };
        assert!(look.background && !look.shadow && look.size == Size::Normal);
        let MenuAction::Look(look) = &colour.choices[1].action else {
            panic!()
        };
        assert_eq!(look.colour, Colour::Yellow);
        let styled = SubtitleLook {
            size: Size::Large,
            background: true,
            ..SubtitleLook::STANDARD
        };
        let m = build_menus(
            &state(true),
            &MenuInputs {
                look: styled,
                ..inputs()
            },
        );
        assert_eq!(m.tracks.look.value, Words::Pair("Groß", "Fläche"));
        assert!(m.look.groups[1].choices[2].selected);
    }

    #[test]
    fn a_series_panel_has_episodes_then_chapters_and_a_film_only_chapters() {
        let series = build_menus(&state(true), &inputs()).episodes;
        assert_eq!(series.tabs, vec![PanelTab::Episodes, PanelTab::Chapters]);
        let mut s = state(true);
        s.has_chapters = false;
        assert_eq!(
            build_menus(&s, &inputs()).episodes.tabs,
            vec![PanelTab::Episodes]
        );
        let film = build_menus(
            &state(false),
            &MenuInputs {
                seasons: Vec::new(),
                shown_season: None,
                ..inputs()
            },
        )
        .episodes;
        assert_eq!(film.tabs, vec![PanelTab::Chapters]);
        assert!(film.season_button.is_none() && film.seasons.is_empty());
    }

    #[test]
    fn the_season_button_shows_the_open_season_and_the_list_switches_it() {
        let m = build_menus(&state(true), &inputs()).episodes;
        let button = m.season_button.as_ref().unwrap();
        assert_eq!(button.value, Words::Count("Staffel %lld", 1));
        assert_eq!(button.action, MenuAction::Open(MenuLevel::Seasons));
        assert_eq!(m.seasons.len(), 3);
        assert!(m.seasons[0].selected && m.seasons.iter().filter(|c| c.selected).count() == 1);
        assert_eq!(m.seasons[2].action, MenuAction::SelectSeason("s3".into()));
        // After the switch the button reads the new season.
        let m = build_menus(
            &state(true),
            &MenuInputs {
                shown_season: Some("s3".into()),
                ..inputs()
            },
        )
        .episodes;
        assert_eq!(
            m.season_button.unwrap().value,
            Words::Count("Staffel %lld", 3)
        );
        assert!(m.seasons[2].selected);
        // An unknown id falls back to the first season.
        let m = build_menus(
            &state(true),
            &MenuInputs {
                shown_season: None,
                ..inputs()
            },
        )
        .episodes;
        assert_eq!(
            m.season_button.unwrap().value,
            Words::Count("Staffel %lld", 1)
        );
    }

    #[test]
    fn the_handoff_level_has_loading_empty_and_list_states() {
        let loading = build_menus(&state(true), &inputs()).handoff;
        assert_eq!(loading.state, HandoffState::Loading);
        assert_eq!(loading.text, Some(Words::Key("Suche Geräte …")));
        assert!(loading.airplay.is_none());
        assert_eq!(
            loading.note,
            Words::Key("Läuft dort an derselben Stelle weiter.")
        );
        let empty = build_menus(
            &state(true),
            &MenuInputs {
                handoff: HandoffInput::Devices(vec![]),
                airplay: true,
                ..inputs()
            },
        )
        .handoff;
        assert_eq!(empty.state, HandoffState::Empty);
        assert!(empty.airplay.is_some());
        let device = HandoffDevice {
            id: "d1".into(),
            name: "Wohnzimmer".into(),
            kind: DevicesKind::Tv,
            detail: Some("Apple TV".into()),
        };
        let list = build_menus(
            &state(true),
            &MenuInputs {
                handoff: HandoffInput::Devices(vec![device]),
                ..inputs()
            },
        )
        .handoff;
        assert_eq!(list.state, HandoffState::List);
        assert!(list.text.is_none());
        assert_eq!(list.rows[0].action, MenuAction::Handoff("d1".into()));
        assert_eq!(list.rows[0].detail.as_deref(), Some("Apple TV"));
        assert!(!list.rows[0].busy && list.rows[0].enabled);
        let handing = build_menus(
            &state(true),
            &MenuInputs {
                handoff: HandoffInput::Handing {
                    devices: vec![
                        HandoffDevice {
                            id: "d1".into(),
                            name: "Wohnzimmer".into(),
                            kind: DevicesKind::Tv,
                            detail: None,
                        },
                        HandoffDevice {
                            id: "d2".into(),
                            name: "Küche".into(),
                            kind: DevicesKind::Tv,
                            detail: None,
                        },
                    ],
                    busy: "d1".into(),
                },
                airplay: true,
                ..inputs()
            },
        )
        .handoff;
        assert_eq!(handing.state, HandoffState::List);
        assert_eq!(
            handing.note,
            Words::Key("Hier ist angehalten, bis der Fernseher übernimmt.")
        );
        assert!(handing.rows[0].busy && handing.rows[0].enabled);
        assert!(!handing.rows[1].busy && !handing.rows[1].enabled);
        assert!(!handing.airplay.unwrap().enabled);
    }

    #[test]
    fn every_menu_text_is_in_the_catalogue_for_each_language() {
        use swiftly_l10n::{Locale, Translator};
        let group = GroupInfo {
            name: "g".into(),
            members: vec![
                GroupMember {
                    name: "a".into(),
                    me: true,
                    status: MemberStatus::Watching,
                },
                GroupMember {
                    name: "b".into(),
                    me: false,
                    status: MemberStatus::Watching,
                },
                GroupMember {
                    name: "c".into(),
                    me: false,
                    status: MemberStatus::Paused,
                },
                GroupMember {
                    name: "d".into(),
                    me: false,
                    status: MemberStatus::Waiting,
                },
            ],
        };
        let m = build_menus(
            &state(true),
            &MenuInputs {
                group: Some(group),
                ..inputs()
            },
        );
        let mut words: Vec<&Words> = Vec::new();
        for r in &m.options.rows {
            words.push(&r.title);
            words.push(&r.value);
        }
        words.extend(m.options.footer.iter().map(|r| &r.title));
        for p in [&m.speed, &m.picture] {
            words.push(&p.title);
            words.extend(p.choices.iter().map(|c| &c.label));
        }
        words.push(&m.sleep.title);
        words.push(&m.sleep.minutes_title);
        words.extend(m.sleep.choices.iter().map(|c| &c.label));
        words.push(&m.quality.title);
        words.push(&m.quality.bitrate_title);
        words.push(&m.quality.badge_title);
        words.push(&m.quality.original.label);
        words.extend(m.quality.original.detail.iter());
        let t = m.together.as_ref().unwrap();
        words.push(&t.title);
        words.push(&t.leave.title);
        words.extend(t.members.iter().map(|x| &x.status));
        words.push(&m.tracks.subtitles.title);
        words.push(&m.tracks.audio.title);
        for r in [&m.tracks.look, &m.tracks.subtitle_time] {
            words.push(&r.title);
        }
        words.push(&m.look.title);
        for g in &m.look.groups {
            words.push(&g.title);
            words.extend(g.choices.iter().map(|c| &c.label));
        }
        words.push(&m.time.title);
        for tab in &m.time.tabs {
            words.extend([
                &tab.title,
                &tab.meaning,
                &tab.earlier.title,
                &tab.later.title,
            ]);
        }
        let loading_note = build_menus(&state(true), &inputs()).handoff.note;
        let reset = build_menus(
            &MenuState {
                tracks: TracksPart {
                    subtitle_delay_ms: 100,
                    ..state(true).tracks
                },
                ..state(true)
            },
            &inputs(),
        );
        words.push(&reset.time.tabs[0].reset.as_ref().unwrap().title);
        words.push(&m.episodes.seasons_title);
        words.push(&m.handoff.title);
        words.push(&m.handoff.note);
        words.push(&loading_note);
        let (loading, empty) = (
            Words::Key("Suche Geräte …"),
            Words::Key("Keine Geräte gefunden"),
        );
        words.extend([&loading, &empty]);
        let up = [Words::Key("Du")];
        words.extend(up.iter());
        for language in ["en", "ru"] {
            let tr = Translator::new(Locale::parse(language));
            for w in &words {
                let keys: Vec<&str> = match w {
                    Words::Key(k) | Words::Count(k, _) => vec![k],
                    Words::Pair(a, b) => vec![a, b],
                    Words::Literal(_) => continue,
                };
                for k in keys {
                    // These read the same in English.
                    if language == "en" && ["Normal", "Original", "Direct Play"].contains(&k) {
                        continue;
                    }
                    assert_ne!(tr.t(k), k, "{k} has no {language} text");
                }
            }
        }
        let tr = Translator::new(Locale::parse("en"));
        assert_eq!(Words::Count("%lld Min.", 30).resolve(&tr), "30 min");
        assert_eq!(Words::Pair("Groß", "Fläche").resolve(&tr), "Large · Box");
    }
}
