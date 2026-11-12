//! The control channel (`RemoteControl.swift`): message mapping, reconnect rules, keep-alive and
//! capability report, over an injected WebSocket ([`RemoteLink`]).

use std::future::Future;

use serde_json::{Value, json};

use crate::syncplay::SyncPlayPostDirection;

/// What a remote device asks the player to do.
#[derive(Debug, Clone, PartialEq)]
pub enum RemoteCommand {
    /// Pause.
    Pause,
    /// Resume.
    Proceed,
    /// Toggle.
    Toggle,
    /// Stop.
    Stop,
    /// Seek to seconds.
    JumpOn(f64),
    /// Forward.
    Forward,
    /// Back.
    Back,
    /// Next track.
    Next,
    /// Previous track.
    Previous,
}

/// A "play on this device" order (`PlayOrder`, PlayOn.swift).
#[derive(Debug, Clone, PartialEq)]
pub struct PlayOrder {
    /// Item ids.
    pub item_ids: Vec<String>,
    /// Index to start at.
    pub start_index: usize,
    /// Start in seconds.
    pub start: f64,
    /// Media source.
    pub media_source_id: Option<String>,
    /// Audio stream index.
    pub audio_index: Option<i64>,
    /// Subtitle stream index.
    pub subtitle_index: Option<i64>,
}

impl PlayOrder {
    /// The item to start with.
    pub fn item_id(&self) -> Option<&str> {
        self.item_ids.get(self.start_index).map(String::as_str)
    }

    /// Reads a whole `Play` message; `None` for other commands than `PlayNow` or without items.
    pub fn read(text: &str) -> Option<Self> {
        let v: Value = serde_json::from_str(text).ok()?;
        if v.get("MessageType")?.as_str()? != "Play" {
            return None;
        }
        let c = v.get("Data")?;
        // Wrongly typed fields count as missing (`try?` in Swift).
        let command = c
            .get("PlayCommand")
            .and_then(Value::as_str)
            .unwrap_or("PlayNow");
        if command != "PlayNow" {
            return None;
        }
        let ids: Vec<String> = c
            .get("ItemIds")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .map(|x| x.as_str().map(str::to_string))
                    .collect::<Option<Vec<_>>>()
            })
            .unwrap_or(None)
            .unwrap_or_default()
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect();
        if ids.is_empty() {
            return None;
        }
        let int = |k: &str| c.get(k).and_then(Value::as_i64);
        #[allow(clippy::cast_precision_loss)]
        let start = int("StartPositionTicks").unwrap_or(0).max(0) as f64 / 10_000_000.0;
        let order = Self {
            item_ids: ids,
            start_index: usize::try_from(int("StartIndex").unwrap_or(0)).unwrap_or(usize::MAX),
            start,
            media_source_id: c
                .get("MediaSourceId")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string),
            audio_index: int("AudioStreamIndex"),
            subtitle_index: int("SubtitleStreamIndex"),
        };
        order.item_id().is_some().then_some(order)
    }
}

/// Why a link ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkError {
    /// This platform's libcurl cannot do WebSocket: use the fallback.
    NotSupported,
    /// The connection could not be set up (HTTP status of the upgrade, 0 if unknown).
    SetupFailed {
        /// Status code.
        code: i32,
    },
    /// Any other failure.
    Other(String),
}

/// The WebSocket seam. A platform implements it with URLSession, tungstenite, libcurl...
pub trait RemoteLink: Send {
    /// The next text message; `Ok(None)` for a frame to skip (binary, ping).
    fn receive(&mut self) -> impl Future<Output = Result<Option<String>, LinkError>> + Send;
    /// Sends a text message.
    fn send(&mut self, text: &str) -> impl Future<Output = Result<(), LinkError>> + Send;
    /// Closes.
    fn close(&mut self);
}

/// What the channel hands to the app.
#[derive(Debug, Clone, PartialEq)]
pub enum RemoteOutput {
    /// A player command.
    Command(RemoteCommand),
    /// A SyncPlay message (including `ConnectionLost` / `ConnectionAgain`).
    SyncPlay(SyncPlayPostDirection),
    /// A takeover hint from another device (its name).
    Handoff(String),
    /// A play order.
    Play(PlayOrder),
    /// Send this text back (keep-alive answer).
    Send(String),
    /// A SyncPlay or Play message that could not be read (first 300 chars, for the log).
    Unreadable(String),
}

/// The keep-alive message.
pub const KEEP_ALIVE: &str = r#"{"MessageType":"KeepAlive"}"#;
/// Seconds between keep-alives.
pub const KEEP_ALIVE_INTERVAL: f64 = 30.0;
/// The header of a takeover hint (`Takeover.hintHeader`).
pub const HINT_HEADER: &str = "Swiftly-Uebernahme";
/// libcurl setup failures before the URLSession fallback.
pub const LINE_SETUP_LIMIT: u32 = 3;

/// The pure state of the channel.
#[derive(Debug, Default)]
pub struct RemoteControl {
    teardowns: u32,
    line_setup_failures: u32,
    stands_already: bool,
    torn_down_reported: bool,
}

impl RemoteControl {
    /// A fresh channel state.
    pub fn new() -> Self {
        Self::default()
    }

    /// `wss://host/socket?ApiKey=...&deviceId=...` (`ApiKey`, not `api_key`: it works on 10.8 and 12).
    pub fn socket_url(base: &str, token: &str, device_id: &str) -> Option<String> {
        let base = base.trim_end_matches('/');
        let rest = base
            .strip_prefix("https://")
            .map(|r| ("wss", r))
            .or_else(|| base.strip_prefix("http://").map(|r| ("ws", r)))?;
        let enc = |s: &str| {
            s.bytes().fold(String::new(), |mut o, b| {
                if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                    o.push(char::from(b));
                } else {
                    o.push_str(&format!("%{b:02X}"));
                }
                o
            })
        };
        Some(format!(
            "{}://{}/socket?ApiKey={}&deviceId={}",
            rest.0,
            rest.1,
            enc(token),
            enc(device_id)
        ))
    }

    /// Seconds to wait before reconnecting: 2, 4, 8, 16, 30, 30...; counts the drop.
    pub fn next_reconnect_wait(&mut self) -> f64 {
        self.teardowns += 1;
        f64::from(30.min(1u32 << self.teardowns.min(5)))
    }

    /// Something arrived: the connection is up. Returns the "again" message after a drop.
    pub fn on_received(&mut self) -> Option<RemoteOutput> {
        self.teardowns = 0;
        self.line_setup_failures = 0;
        if self.stands_already {
            return None;
        }
        self.stands_already = true;
        if self.torn_down_reported {
            self.torn_down_reported = false;
            return Some(RemoteOutput::SyncPlay(
                SyncPlayPostDirection::ConnectionAgain,
            ));
        }
        None
    }

    /// The link dropped: SyncPlay learns of it.
    pub fn on_lost(&mut self) -> RemoteOutput {
        self.stands_already = false;
        self.torn_down_reported = true;
        RemoteOutput::SyncPlay(SyncPlayPostDirection::ConnectionLost)
    }

    /// Does a setup failure with this code blame the libcurl line (so the fallback is used)?
    /// True once the limit is reached.
    pub fn line_setup_gives_up(&mut self, code: i32) -> bool {
        // Codes that blame the line, not the server: no upgrade possible (426, 400, 0).
        if !matches!(code, 0 | 400 | 426 | 101) {
            return false;
        }
        self.line_setup_failures += 1;
        self.line_setup_failures >= LINE_SETUP_LIMIT
    }

    /// Back to the initial state (`finish`).
    pub fn finish(&mut self) {
        *self = Self::default();
    }

    /// The takeover hint: `DisplayMessage` with our header and a non-empty text.
    pub fn handoff_hint(raw: &Value) -> Option<String> {
        let c = raw.get("Data")?;
        if c.get("Name")?.as_str()? != "DisplayMessage" {
            return None;
        }
        let a = c.get("Arguments")?;
        if a.get("Header")?.as_str()? != HINT_HEADER {
            return None;
        }
        a.get("Text")?
            .as_str()
            .filter(|t| !t.is_empty())
            .map(str::to_string)
    }

    /// `Playstate` command names to commands.
    pub fn translate(command: &str, target: Option<i64>) -> Option<RemoteCommand> {
        Some(match command {
            "Pause" => RemoteCommand::Pause,
            "Unpause" => RemoteCommand::Proceed,
            "PlayPause" => RemoteCommand::Toggle,
            "Stop" => RemoteCommand::Stop,
            #[allow(clippy::cast_precision_loss)]
            "Seek" => RemoteCommand::JumpOn(target? as f64 / 10_000_000.0),
            "FastForward" => RemoteCommand::Forward,
            "Rewind" => RemoteCommand::Back,
            "NextTrack" => RemoteCommand::Next,
            "PreviousTrack" => RemoteCommand::Previous,
            _ => return None,
        })
    }

    /// Maps one incoming text message.
    pub fn process(&self, text: &str) -> Vec<RemoteOutput> {
        let Ok(raw) = serde_json::from_str::<Value>(text) else {
            return Vec::new();
        };
        let Some(kind) = raw.get("MessageType").and_then(Value::as_str) else {
            return Vec::new();
        };
        let unreadable = || RemoteOutput::Unreadable(text.chars().take(300).collect());
        match kind {
            "ForceKeepAlive" => vec![RemoteOutput::Send(KEEP_ALIVE.into())],
            "SyncPlayCommand" | "SyncPlayGroupUpdate" => {
                vec![
                    SyncPlayPostDirection::read(text)
                        .map_or_else(unreadable, RemoteOutput::SyncPlay),
                ]
            }
            "GeneralCommand" => Self::handoff_hint(&raw)
                .map(RemoteOutput::Handoff)
                .into_iter()
                .collect(),
            "Playstate" => {
                let Some(content) = raw.get("Data") else {
                    return Vec::new();
                };
                let Some(command) = content.get("Command").and_then(Value::as_str) else {
                    return Vec::new();
                };
                let target = content.get("SeekPositionTicks").and_then(Value::as_i64);
                Self::translate(command, target)
                    .map(RemoteOutput::Command)
                    .into_iter()
                    .collect()
            }
            "Play" => vec![PlayOrder::read(text).map_or_else(unreadable, RemoteOutput::Play)],
            _ => Vec::new(),
        }
    }

    /// Reads from a link until it fails, handing every output to `sink` (keep-alive answers are
    /// sent on the link). Returns the error that ended it; the caller decides about the
    /// reconnect (`on_lost`, `next_reconnect_wait`, fallback on `NotSupported`).
    pub async fn pump<L: RemoteLink>(
        &mut self,
        link: &mut L,
        mut sink: impl FnMut(RemoteOutput) + Send,
    ) -> LinkError {
        loop {
            match link.receive().await {
                Ok(Some(text)) => {
                    for out in self.process(&text) {
                        if let RemoteOutput::Send(reply) = &out {
                            if let Err(e) = link.send(reply).await {
                                return e;
                            }
                            continue;
                        }
                        sink(out);
                    }
                    if let Some(again) = self.on_received() {
                        sink(again);
                    }
                }
                Ok(None) => {
                    if let Some(again) = self.on_received() {
                        sink(again);
                    }
                }
                Err(e) => return e,
            }
        }
    }

    /// Body of `POST Sessions/Capabilities/Full`. Every name must match the server's
    /// `GeneralCommandType` (`PlayState` with a capital S): one typo discards the whole report.
    pub fn capabilities_body() -> Value {
        json!({
            "PlayableMediaTypes": ["Video", "Audio"],
            "SupportedCommands": ["Play", "PlayState", "PlayNext", "PlayMediaSource",
                "DisplayMessage", "SetAudioStreamIndex", "SetSubtitleStreamIndex",
                "Mute", "Unmute", "ToggleMute", "SetVolume"],
            "SupportsMediaControl": true,
            "SupportsPersistentIdentifier": true,
        })
    }
}
