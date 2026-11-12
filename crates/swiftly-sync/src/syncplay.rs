//! The pure SyncPlay calculation and message parsing (`SyncPlay.swift`). Modeled on jellyfin-web.

use serde::{Deserialize, Deserializer};
use serde_json::Value;
use unicode_normalization::UnicodeNormalization;

use crate::time::{parse_timestamp, time_read, time_text};

/// Swift compares `String`s by canonical equivalence (`"é" == "e\u{301}"`).
pub(crate) fn same_name(a: &str, b: &str) -> bool {
    a == b || a.nfc().eq(b.nfc())
}

/// Swift's `JSONDecoder` reads a whole number written as `30000000.0` or `1e7` into an `Int64`,
/// and refuses a fraction, a string, a bool or a number outside the range.
fn whole<'de, D: Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
    use serde::de::Error;
    match Option::<Value>::deserialize(d)? {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(n)) => {
            if let Some(i) = n.as_i64() {
                return Ok(Some(i));
            }
            match n.as_f64() {
                #[allow(clippy::cast_possible_truncation)]
                Some(f) if f.fract() == 0.0 && f.abs() < 9.223_372_036_854_775e18 => {
                    Ok(Some(f as i64))
                }
                _ => Err(D::Error::custom("not a whole number")),
            }
        }
        Some(_) => Err(D::Error::custom("not a number")),
    }
}

/// Constants and unit conversion.
pub struct SyncPlay;

impl SyncPlay {
    /// Jellyfin counts in ticks of 100 ns.
    pub const TICKS_PER_SECOND: f64 = 10_000_000.0;
    /// Seek from this offset on (jellyfin-web `minDelaySkipToSync`, 400 ms).
    pub const JUMP_LIMIT: f64 = 0.4;
    /// Catch up while playing only from one second.
    pub const DRIFT_LIMIT: f64 = 1.0;

    /// Ticks to seconds.
    #[allow(clippy::cast_precision_loss)]
    pub fn seconds(ticks: i64) -> f64 {
        ticks as f64 / Self::TICKS_PER_SECOND
    }

    /// Seconds to ticks (rounded; non-finite is 0).
    #[allow(clippy::cast_possible_truncation)]
    pub fn ticks(seconds: f64) -> i64 {
        let t = (seconds * Self::TICKS_PER_SECOND).round();
        if t.is_finite() { t as i64 } else { 0 }
    }

    /// `timeText`.
    pub fn time_text(seconds: f64) -> String {
        time_text(seconds)
    }

    /// `timeRead`.
    pub fn time_read(text: &str) -> Option<f64> {
        time_read(text)
    }
}

/// Group state (`State` of `GET SyncPlay/List`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// `Idle`.
    Empty,
    /// `Waiting`.
    Waits,
    /// `Paused`.
    Halted,
    /// `Playing`.
    Running,
}

impl Phase {
    /// `Phase(rawValue:)`.
    pub fn from_raw(s: &str) -> Option<Self> {
        Some(match s {
            "Idle" => Self::Empty,
            "Waiting" => Self::Waits,
            "Paused" => Self::Halted,
            "Playing" => Self::Running,
            _ => return None,
        })
    }
}

/// A group as the server lists it.
#[derive(Debug, Clone, PartialEq)]
pub struct SyncPlayGroup {
    /// `GroupId`.
    pub id: String,
    /// `GroupName` (empty if missing).
    pub name: String,
    /// `State`.
    pub condition: Option<Phase>,
    /// User names (one per device).
    pub participant: Vec<String>,
    /// `LastUpdatedAt` (seconds since 1970).
    pub state: Option<f64>,
}

impl SyncPlayGroup {
    /// A group with the given fields and defaults for the rest.
    pub fn new(id: &str, name: &str) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            condition: None,
            participant: Vec::new(),
            state: None,
        }
    }

    /// Reads one group object; `None` without `GroupId`. Wrong types of optional fields count as
    /// missing, as `try?` does in Swift for `LastUpdatedAt`; a wrongly typed name or list fails.
    pub fn from_json(v: &Value) -> Option<Self> {
        let o = v.as_object()?;
        let id = o.get("GroupId")?.as_str()?.to_string();
        let name = match o.get("GroupName") {
            None | Some(Value::Null) => String::new(),
            Some(n) => n.as_str()?.to_string(),
        };
        let condition = match o.get("State") {
            None | Some(Value::Null) => None,
            Some(s) => Phase::from_raw(s.as_str()?),
        };
        let participant = match o.get("Participants") {
            None | Some(Value::Null) => Vec::new(),
            Some(p) => p
                .as_array()?
                .iter()
                .map(|x| x.as_str().map(str::to_string))
                .collect::<Option<Vec<_>>>()?,
        };
        let state = o
            .get("LastUpdatedAt")
            .and_then(Value::as_str)
            .and_then(parse_timestamp);
        Some(Self {
            id,
            name,
            condition,
            participant,
            state,
        })
    }

    /// `GET SyncPlay/List` body.
    pub fn list_from_json(data: &[u8]) -> Option<Vec<Self>> {
        let v: Value = serde_json::from_slice(data).ok()?;
        v.as_array()?.iter().map(Self::from_json).collect()
    }

    /// Everyone except oneself (once), each name once.
    pub fn other(&self, me: Option<&str>) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        let mut result = Vec::new();
        let mut own_skipped = false;
        for name in &self.participant {
            if me.is_some_and(|m| same_name(name, m)) && !own_skipped {
                own_skipped = true;
                continue;
            }
            if seen.insert(name.nfc().collect::<String>()) {
                result.push(name.clone());
            }
        }
        result
    }
}

/// Kind of a command.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandArt {
    /// `Unpause`.
    Proceed,
    /// `Pause`.
    Pause,
    /// `Stop`.
    Stop,
    /// `Seek`.
    Jump,
}

impl CommandArt {
    /// The server's name.
    pub fn raw(self) -> &'static str {
        match self {
            Self::Proceed => "Unpause",
            Self::Pause => "Pause",
            Self::Stop => "Stop",
            Self::Jump => "Seek",
        }
    }
}

/// A command with an execution time.
#[derive(Debug, Clone, PartialEq)]
pub struct SyncPlayCommand {
    /// Group id.
    pub group: String,
    /// `PlaylistItemId`.
    pub entry_record: Option<String>,
    /// Kind.
    pub art: CommandArt,
    /// Server time of execution.
    pub moment: f64,
    /// Position in seconds.
    pub spot: Option<f64>,
    /// Server time of sending.
    pub emitted: Option<f64>,
}

/// One queue entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueRecord {
    /// Jellyfin item id.
    pub title: String,
    /// `PlaylistItemId`.
    pub entry_record: String,
}

/// The group's queue.
#[derive(Debug, Clone, PartialEq)]
pub struct SyncPlayQueue {
    /// `NewPlaylist`, `SetCurrentItem`, ...
    pub reason: String,
    /// `LastUpdate`.
    pub state: Option<f64>,
    /// Entries.
    pub entries: Vec<QueueRecord>,
    /// `PlayingItemIndex` (-1 if missing).
    pub index: i64,
    /// Start position in seconds.
    pub start_point: f64,
    /// `IsPlaying`.
    pub running: bool,
}

impl SyncPlayQueue {
    /// The entry at `index`.
    pub fn current(&self) -> Option<&QueueRecord> {
        usize::try_from(self.index)
            .ok()
            .and_then(|i| self.entries.get(i))
    }

    /// Does the player have to load a title for this?
    pub fn switches_title(&self) -> bool {
        [
            "NewPlaylist",
            "SetCurrentItem",
            "NextItem",
            "PreviousItem",
            "RemoveItems",
        ]
        .contains(&self.reason.as_str())
    }
}

/// Everything about SyncPlay that arrives over the control channel.
#[derive(Debug, Clone, PartialEq)]
pub enum SyncPlayPostDirection {
    /// A command.
    Command(SyncPlayCommand),
    /// In the group (after New and Join).
    Joined(SyncPlayGroup),
    /// `GroupLeft`.
    Leave,
    /// `NotInGroup`.
    NotInGroup,
    /// `GroupDoesNotExist`.
    DoesNotExist,
    /// `LibraryAccessDenied`.
    NoAccess,
    /// `UserJoined`.
    SomeoneJoined(String),
    /// `UserLeft`.
    SomeoneLeft(String),
    /// `StateUpdate`.
    Condition(Phase, Option<String>),
    /// `PlayQueue`.
    Queue(SyncPlayQueue),
    /// The channel dropped (from the channel itself).
    ConnectionLost,
    /// Something arrived again after a drop.
    ConnectionAgain,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct CommandData {
    group_id: String,
    playlist_item_id: Option<String>,
    when: String,
    #[serde(default, deserialize_with = "whole")]
    position_ticks: Option<i64>,
    command: String,
    emitted_at: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct PlaylistEntry {
    item_id: String,
    playlist_item_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct QueueData {
    reason: String,
    last_update: Option<String>,
    playlist: Option<Vec<PlaylistEntry>>,
    #[serde(default, deserialize_with = "whole")]
    playing_item_index: Option<i64>,
    #[serde(default, deserialize_with = "whole")]
    start_position_ticks: Option<i64>,
    is_playing: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct StateData {
    state: String,
    reason: Option<String>,
}

impl SyncPlayPostDirection {
    /// Parses a whole control-channel message; `None` for anything that is not SyncPlay or
    /// cannot be read.
    pub fn read(text: &str) -> Option<Self> {
        // Swift's `JSONDecoder` skips a byte order mark at the start.
        let text = text.strip_prefix('\u{FEFF}').unwrap_or(text);
        let v: Value = serde_json::from_str(text).ok()?;
        let kind = v.get("MessageType")?.as_str()?;
        let data = v.get("Data")?;
        match kind {
            "SyncPlayCommand" => {
                let c: CommandData = serde_json::from_value(data.clone()).ok()?;
                let art = match c.command.as_str() {
                    "Unpause" => CommandArt::Proceed,
                    "Pause" => CommandArt::Pause,
                    "Stop" => CommandArt::Stop,
                    "Seek" => CommandArt::Jump,
                    _ => return None,
                };
                Some(Self::Command(SyncPlayCommand {
                    group: c.group_id,
                    entry_record: c.playlist_item_id,
                    art,
                    moment: parse_timestamp(&c.when)?,
                    spot: c.position_ticks.map(SyncPlay::seconds),
                    emitted: match c.emitted_at {
                        Some(e) => Some(parse_timestamp(&e)?),
                        None => None,
                    },
                }))
            }
            "SyncPlayGroupUpdate" => {
                let art = data.get("Type")?.as_str()?;
                let inner = data.get("Data");
                match art {
                    "GroupJoined" => SyncPlayGroup::from_json(inner?).map(Self::Joined),
                    "GroupLeft" => Some(Self::Leave),
                    "NotInGroup" => Some(Self::NotInGroup),
                    "GroupDoesNotExist" => Some(Self::DoesNotExist),
                    "LibraryAccessDenied" => Some(Self::NoAccess),
                    "UserJoined" => Some(Self::SomeoneJoined(inner?.as_str()?.to_string())),
                    "UserLeft" => Some(Self::SomeoneLeft(inner?.as_str()?.to_string())),
                    "StateUpdate" => {
                        let s: StateData = serde_json::from_value(inner?.clone()).ok()?;
                        Some(Self::Condition(Phase::from_raw(&s.state)?, s.reason))
                    }
                    "PlayQueue" => {
                        let q: QueueData = serde_json::from_value(inner?.clone()).ok()?;
                        Some(Self::Queue(SyncPlayQueue {
                            reason: q.reason,
                            // A `LastUpdate` that is present but unreadable drops the whole message (Swift: `DateField` throws).
                            state: match q.last_update.as_deref() {
                                Some(t) => Some(parse_timestamp(t)?),
                                None => None,
                            },
                            entries: q
                                .playlist
                                .unwrap_or_default()
                                .into_iter()
                                .map(|e| QueueRecord {
                                    title: e.item_id,
                                    entry_record: e.playlist_item_id,
                                })
                                .collect(),
                            index: q.playing_item_index.unwrap_or(-1),
                            start_point: SyncPlay::seconds(q.start_position_ticks.unwrap_or(0)),
                            running: q.is_playing.unwrap_or(false),
                        }))
                    }
                    _ => None,
                }
            }
            _ => None,
        }
    }
}

/// One clock measurement: four timestamps.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Reading {
    /// Request sent (local).
    pub sent: f64,
    /// Received by the server.
    pub server_receive: f64,
    /// Response sent by the server.
    pub server_sent: f64,
    /// Response received (local).
    pub receive: f64,
}

impl Reading {
    /// Server minus local (NTP).
    pub fn offset(&self) -> f64 {
        ((self.server_receive - self.sent) + (self.server_sent - self.receive)) / 2.0
    }

    /// Round trip without the server's own time.
    pub fn runtime(&self) -> f64 {
        (self.receive - self.sent) - (self.server_sent - self.server_receive)
    }
}

/// How far the server's clock is from ours: the shortest round trip of the last eight counts.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TimeReconcile {
    measurements: Vec<Reading>,
}

impl TimeReconcile {
    /// Measurements kept.
    pub const KEEP: usize = 8;

    /// Empty.
    pub fn new() -> Self {
        Self::default()
    }

    /// The kept measurements.
    pub fn measurements(&self) -> &[Reading] {
        &self.measurements
    }

    /// The measurement that counts (first of equal runtimes).
    pub fn best(&self) -> Option<Reading> {
        self.measurements
            .iter()
            .copied()
            .reduce(|a, b| if b.runtime() < a.runtime() { b } else { a })
    }

    /// At least one measurement.
    pub fn ready(&self) -> bool {
        !self.measurements.is_empty()
    }

    /// Server minus local; 0 without a measurement.
    pub fn offset(&self) -> f64 {
        self.best().map_or(0.0, |b| b.offset())
    }

    /// One direction in milliseconds, as `/SyncPlay/Ping` wants it.
    #[allow(clippy::cast_possible_truncation)]
    pub fn ping_milliseconds(&self) -> i64 {
        let v = (self.best().map_or(0.0, |b| b.runtime()) / 2.0 * 1000.0)
            .max(0.0)
            .round();
        if v.is_finite() { v as i64 } else { 0 }
    }

    /// Adds a measurement, keeping the last eight.
    pub fn record(&mut self, m: Reading) {
        self.measurements.push(m);
        if self.measurements.len() > Self::KEEP {
            let extra = self.measurements.len() - Self::KEEP;
            self.measurements.drain(..extra);
        }
    }

    /// Server time to local time.
    pub fn local_only(&self, server: f64) -> f64 {
        server - self.offset()
    }

    /// Local time to server time.
    pub fn server(&self, local_only: f64) -> f64 {
        local_only + self.offset()
    }

    /// Pause before the next measurement: 1 s three times, then a minute.
    pub fn pause_to_measurements(count: usize) -> f64 {
        if count < 3 { 1.0 } else { 60.0 }
    }
}

/// What the player does with a command.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// Resume.
    Proceed,
    /// Pause.
    Pause,
    /// Seek.
    Jump,
    /// Stop.
    Stop,
}

/// What to do with a command, and when (jellyfin-web `PlaybackCore.js` rules).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SyncPlayExecution {
    /// The step.
    pub step: Step,
    /// Where to seek (before; for pause: after). `None` means stay.
    pub spot: Option<f64>,
    /// Seconds to wait from now.
    pub wait: f64,
}

impl SyncPlayExecution {
    /// `of(_:now:reconcile:localPoint:)`.
    pub fn of(
        command: &SyncPlayCommand,
        now: f64,
        reconcile: &TimeReconcile,
        local_point: f64,
    ) -> Self {
        let when_local = reconcile.local_only(command.moment);
        let wait = (when_local - now).max(0.0);
        let only_if_off = |target: Option<f64>| {
            target.and_then(|t| {
                ((t - local_point).abs() > SyncPlay::JUMP_LIMIT).then_some(t.max(0.0))
            })
        };
        match command.art {
            CommandArt::Proceed => {
                if wait > 0.0 {
                    return Self {
                        step: Step::Proceed,
                        spot: only_if_off(command.spot),
                        wait,
                    };
                }
                let now_there = command
                    .spot
                    .map(|s| Self::estimated_point(s, command.moment, now, reconcile));
                Self {
                    step: Step::Proceed,
                    spot: only_if_off(now_there),
                    wait: 0.0,
                }
            }
            CommandArt::Pause => Self {
                step: Step::Pause,
                spot: only_if_off(command.spot),
                wait,
            },
            CommandArt::Jump => Self {
                step: Step::Jump,
                spot: command.spot.map(|s| s.max(0.0)),
                wait,
            },
            CommandArt::Stop => Self {
                step: Step::Stop,
                spot: None,
                wait,
            },
        }
    }

    /// Where the group is now if it has run from `spot` since `valid_from` (server time).
    pub fn estimated_point(spot: f64, valid_from: f64, now: f64, reconcile: &TimeReconcile) -> f64 {
        spot + (reconcile.server(now) - valid_from).max(0.0)
    }

    /// Which position "ready" reports after a seek: the target within one second.
    pub fn ready_point(target: f64, actual: f64) -> f64 {
        if (actual - target).abs() <= 1.0 {
            target
        } else {
            actual
        }
    }

    /// Catching up during playback: the position to seek to, or `None` while close enough.
    pub fn bring_up_to_date(
        last_one: Option<&SyncPlayCommand>,
        entry_record: Option<&str>,
        now: f64,
        reconcile: &TimeReconcile,
        local_point: f64,
    ) -> Option<f64> {
        let last = last_one?;
        let spot = last.spot?;
        if last.art != CommandArt::Proceed
            || !(last.entry_record.is_none() || last.entry_record.as_deref() == entry_record)
            || reconcile.local_only(last.moment) > now
        {
            return None;
        }
        let should = Self::estimated_point(spot, last.moment, now, reconcile);
        ((should - local_point).abs() > SyncPlay::DRIFT_LIMIT).then_some(should)
    }
}

/// What the buffering watcher reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BufferMessage {
    /// The movie stands although it should run.
    Buffers,
    /// It runs again.
    Ready,
}

/// Is the movie stopped although it should be playing? Measured on the position.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct BufferGuard {
    buffers: bool,
    last_point: Option<f64>,
    stands_since: Option<f64>,
}

impl BufferGuard {
    /// Seconds without progress before it counts as buffering.
    pub const DEADLINE: f64 = 3.0;

    /// Fresh.
    pub fn new() -> Self {
        Self::default()
    }

    /// Currently reported as buffering.
    pub fn buffers(&self) -> bool {
        self.buffers
    }

    /// One tick.
    pub fn tick(&mut self, spot: f64, should_run: bool, now: f64) -> Option<BufferMessage> {
        let previous = self.last_point.replace(spot);
        if !should_run {
            self.stands_since = None;
            return None;
        }
        if previous.is_some_and(|p| spot - p > 0.05) {
            self.stands_since = None;
            if self.buffers {
                self.buffers = false;
                return Some(BufferMessage::Ready);
            }
            return None;
        }
        let since = *self.stands_since.get_or_insert(now);
        if !self.buffers && now - since >= Self::DEADLINE {
            self.buffers = true;
            return Some(BufferMessage::Buffers);
        }
        None
    }

    /// Start counting again after a seek or a new title.
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

/// `Policy.SyncPlayAccess`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncPlayRight {
    /// `CreateAndJoinGroups`.
    CreateAndJoin,
    /// `JoinGroups`.
    Join,
    /// `None`.
    No,
}

impl SyncPlayRight {
    /// `SyncPlayRight(rawValue:)`.
    pub fn from_raw(s: &str) -> Option<Self> {
        Some(match s {
            "CreateAndJoinGroups" => Self::CreateAndJoin,
            "JoinGroups" => Self::Join,
            "None" => Self::No,
            _ => return None,
        })
    }

    /// May create groups.
    pub fn may_create(self) -> bool {
        self == Self::CreateAndJoin
    }

    /// May join groups.
    pub fn may_join(self) -> bool {
        self != Self::No
    }
}
