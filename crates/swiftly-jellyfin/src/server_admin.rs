//! **The server at a glance, for its administrator**: name and version, what the libraries hold, how loaded the
//! machine is, what runs and who plays what right now, plus the few things an administrator does (scan, restart,
//! stop a task or a stream, read a log).
//!
//! Only Jellyfin and only for an account with `Policy.IsAdministrator`; every call here answers 403 to anyone else.
//! CPU and memory are not part of Jellyfin's API at all: they come from the Jelly Twiggy plugin
//! (`GET JellyTwiggy/SystemMetrics`), and without it that part of the page is simply absent. The same plugin counts
//! resolutions per item in one cached request; without it the counts come from three item queries with Jellyfin's own
//! `Is4K` / `IsHd` filters.
//!
//! The types here are what the server said, read leniently (a field of the wrong type is a missing field, a broken
//! entry of a list is dropped). Wording and layout belong to the view model (`swiftly-vm`).

use serde_json::Value;
use swiftly_model::DeliveryMethod;
use swiftly_net::{ErrorKind, HttpTransport, Method, TransportReason};

use crate::client::{JellyfinClient, Query};

/// How much of a log the page shows: the end, where the error just happened.
pub const LOG_LIMIT: usize = 256 * 1024;

/// How far back a session still counts as active, in seconds.
pub const ACTIVE_WITHIN_SECONDS: i64 = 60;

fn text(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn int(v: &Value, key: &str) -> Option<i64> {
    let n = v.get(key)?.as_number()?;
    n.as_i64().or_else(|| {
        let f = n.as_f64()?;
        (f.fract() == 0.0 && f.abs() < 9.0e18).then_some(f as i64)
    })
}

fn float(v: &Value, key: &str) -> Option<f64> {
    v.get(key).and_then(Value::as_f64)
}

fn flag(v: &Value, key: &str) -> Option<bool> {
    v.get(key).and_then(Value::as_bool)
}

// ---------------------------------------------------------------- system

/// `GET System/Info`, the parts the page shows.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ServerSystem {
    /// `ServerName`.
    pub name: String,
    /// `Version`.
    pub version: String,
    /// An update or a plugin waits for a restart (`HasPendingRestart`).
    pub pending_restart: bool,
}

impl ServerSystem {
    /// Reads the answer; every field is optional.
    pub fn read(v: &Value) -> Self {
        Self {
            name: text(v, "ServerName").unwrap_or_default(),
            version: text(v, "Version").unwrap_or_default(),
            pending_restart: flag(v, "HasPendingRestart").unwrap_or(false),
        }
    }
}

/// `GET Items/Counts`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ServerCounts {
    /// `MovieCount`.
    pub movies: i64,
    /// `SeriesCount`.
    pub series: i64,
    /// `EpisodeCount`.
    pub episodes: i64,
}

impl ServerCounts {
    /// Reads the answer; a missing count is 0.
    pub fn read(v: &Value) -> Self {
        Self {
            movies: int(v, "MovieCount").unwrap_or(0),
            series: int(v, "SeriesCount").unwrap_or(0),
            episodes: int(v, "EpisodeCount").unwrap_or(0),
        }
    }
}

/// **Films and episodes by resolution.** HD is 720p and 1080p together. Only what Jellyfin itself can count, so the
/// numbers are the same with and without the plugin; HDR and Dolby Vision sit on the video track, which only the plugin
/// reads, and are left out.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ResolutionCounts {
    /// 4K.
    pub uhd: i64,
    /// 720p and 1080p.
    pub hd: i64,
    /// Below that.
    pub sd: i64,
}

/// What the three fallback counts ask Jellyfin for (`Is4K=true`, `IsHd=true`, `IsHd=false`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolutionFilter {
    /// `Is4K=true` (width of 3800 or more).
    Uhd,
    /// `IsHd=true` (width of 1200 or more); includes 4K.
    HdOrBetter,
    /// `IsHd=false`.
    Sd,
}

impl ResolutionCounts {
    /// The plugin's answer: kind → bucket → count (`Movie`, `Episode`, `MusicVideo`; `4K`, `1080p`, `720p`, `SD`, `HDR`,
    /// `DV`). Films and episodes are summed; music videos are no part of "films, series, episodes", so they stay out
    /// here too. One cached request instead of three counts over the whole library.
    pub fn plugin(answer: &Value) -> Self {
        let sum = |bucket: &str| -> i64 {
            ["Movie", "Episode"]
                .iter()
                .filter_map(|kind| answer.get(*kind))
                .map(|k| int(k, bucket).unwrap_or(0))
                .sum()
        };
        Self {
            uhd: sum("4K"),
            hd: sum("1080p") + sum("720p"),
            sd: sum("SD"),
        }
    }

    /// **From Jellyfin's own filters**: each counted with `Limit=0`. `IsHd=true` includes 4K, so 4K is taken off.
    pub fn filters(uhd: i64, hd_or_better: i64, sd: i64) -> Self {
        Self {
            uhd,
            hd: (hd_or_better - uhd).max(0),
            sd,
        }
    }
}

/// `GET JellyTwiggy/SystemMetrics`. Every value can be missing (not Linux, `/proc` unreadable).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ServerLoad {
    /// `CpuPercent`.
    pub cpu_percent: Option<f64>,
    /// `MemoryPercent`.
    pub memory_percent: Option<f64>,
    /// `MemoryUsedBytes`.
    pub memory_used: Option<i64>,
    /// `MemoryTotalBytes`.
    pub memory_total: Option<i64>,
    /// `DiskReadBytesPerSecond`.
    pub disk_read: Option<f64>,
    /// `DiskWriteBytesPerSecond`.
    pub disk_write: Option<f64>,
}

impl ServerLoad {
    /// Reads the answer.
    pub fn read(v: &Value) -> Self {
        Self {
            cpu_percent: float(v, "CpuPercent"),
            memory_percent: float(v, "MemoryPercent"),
            memory_used: int(v, "MemoryUsedBytes"),
            memory_total: int(v, "MemoryTotalBytes"),
            disk_read: float(v, "DiskReadBytesPerSecond"),
            disk_write: float(v, "DiskWriteBytesPerSecond"),
        }
    }

    /// The plugin answers on every server, with nothing in it off Linux. Nothing to show then.
    pub fn is_empty(&self) -> bool {
        self.cpu_percent.is_none() && self.memory_percent.is_none()
    }
}

// ---------------------------------------------------------------- disks

/// What lives on a drive.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiskUse {
    /// A library, by its name.
    Library(String),
    /// Jellyfin's own data, metadata and cache.
    Jellyfin,
    /// The folder transcodes are written to.
    Transcoding,
}

/// **One drive of the server**, with everything that lives on it.
///
/// The server reports per folder, and the free and used space of a folder are those of the drive it sits on. Ten library
/// folders on one array are one drive, not ten; they are joined by the drive's id (its mount point), else by the
/// folder's path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerDisk {
    /// The drive's id, else the folder's path.
    pub id: String,
    /// What lives on it, in the order it first appears.
    pub uses: Vec<DiskUse>,
    /// Free bytes.
    pub free: i64,
    /// Used bytes.
    pub used: i64,
}

impl ServerDisk {
    /// Free and used together.
    pub fn total(&self) -> i64 {
        self.free + self.used
    }

    /// 0...1, how much is free: the bar shows what is left, the number says it.
    pub fn free_share(&self) -> f64 {
        let total = self.total();
        if total > 0 {
            (self.free as f64 / total as f64).clamp(0.0, 1.0)
        } else {
            0.0
        }
    }

    /// Under 10 percent free is worth a colour.
    pub fn nearly_full(&self) -> bool {
        self.free_share() < 0.1
    }

    /// The drives of a `GET System/Info/Storage` answer (Jellyfin 10.11 and later), libraries first.
    pub fn from_storage(storage: &Value) -> Vec<Self> {
        let mut order: Vec<String> = Vec::new();
        let mut found: Vec<Self> = Vec::new();
        let mut add = |folder: Option<&Value>, usage: DiskUse| {
            let Some(folder) = folder else { return };
            let (Some(path), Some(free), Some(used)) = (
                text(folder, "Path"),
                int(folder, "FreeSpace"),
                int(folder, "UsedSpace"),
            ) else {
                return;
            };
            // -1 is the server's "could not read this drive".
            if free < 0 || used < 0 {
                return;
            }
            let key = text(folder, "DeviceId")
                .filter(|d| !d.is_empty())
                .unwrap_or(path);
            if let Some(i) = order.iter().position(|k| *k == key) {
                if !found[i].uses.contains(&usage) {
                    found[i].uses.push(usage);
                }
            } else {
                order.push(key.clone());
                found.push(Self {
                    id: key,
                    uses: vec![usage],
                    free,
                    used,
                });
            }
        };
        if let Some(libraries) = storage.get("Libraries").and_then(Value::as_array) {
            for library in libraries {
                let name = text(library, "Name").unwrap_or_default();
                if let Some(folders) = library.get("Folders").and_then(Value::as_array) {
                    for folder in folders {
                        add(Some(folder), DiskUse::Library(name.clone()));
                    }
                }
            }
        }
        for key in ["ProgramDataFolder", "InternalMetadataFolder", "CacheFolder"] {
            add(storage.get(key), DiskUse::Jellyfin);
        }
        add(storage.get("TranscodingTempFolder"), DiskUse::Transcoding);
        found
    }
}

// ---------------------------------------------------------------- tasks and logs

/// One scheduled task (`GET ScheduledTasks`). The page lists only the running ones.
#[derive(Debug, Clone, PartialEq)]
pub struct ServerTask {
    /// `Id`.
    pub id: String,
    /// `Name`.
    pub name: String,
    /// `Category`.
    pub category: Option<String>,
    /// `Idle`, `Running`, `Cancelling`.
    pub state: String,
    /// 0...100 while running; the server sends none in the first moments.
    pub progress: Option<f64>,
}

impl ServerTask {
    /// Reads one entry; `None` without an `Id`.
    pub fn read(v: &Value) -> Option<Self> {
        Some(Self {
            id: text(v, "Id")?,
            name: text(v, "Name").unwrap_or_default(),
            category: text(v, "Category"),
            state: text(v, "State").unwrap_or_else(|| "Idle".into()),
            progress: float(v, "CurrentProgressPercentage"),
        })
    }

    /// `Running` and `Cancelling`; both still take the machine.
    pub fn is_running(&self) -> bool {
        self.state != "Idle"
    }

    /// Running tasks only, the furthest along first.
    pub fn running(all: Vec<Self>) -> Vec<Self> {
        let mut list: Vec<Self> = all.into_iter().filter(Self::is_running).collect();
        list.sort_by(|a, b| {
            b.progress
                .unwrap_or(0.0)
                .total_cmp(&a.progress.unwrap_or(0.0))
        });
        list
    }
}

/// One log file (`GET System/Logs`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerLogFile {
    /// `Name`.
    pub name: String,
    /// `Size` in bytes.
    pub size: i64,
    /// `DateModified` as the server wrote it (ISO 8601).
    pub modified: Option<String>,
}

impl ServerLogFile {
    /// Reads one entry; `None` without a `Name`.
    pub fn read(v: &Value) -> Option<Self> {
        Some(Self {
            name: text(v, "Name")?,
            size: int(v, "Size").unwrap_or(0),
            modified: text(v, "DateModified"),
        })
    }

    /// Newest first: the one that is being written is what someone looking for an error wants. The server writes one
    /// timestamp shape, so the text compares like the time.
    pub fn newest_first(mut files: Vec<Self>) -> Vec<Self> {
        files.sort_by(|a, b| b.modified.cmp(&a.modified));
        files
    }

    /// **The end of a log, at a line start.** A log of a busy day is tens of megabytes; a phone shows the last part,
    /// which is where the error just happened. Cut after a line break so the first line shown is whole.
    pub fn tail(data: &[u8], limit: usize) -> String {
        if data.len() <= limit {
            return String::from_utf8_lossy(data).into_owned();
        }
        let mut part = &data[data.len() - limit..];
        if let Some(newline) = part.iter().position(|b| *b == b'\n') {
            part = &part[newline + 1..];
        }
        String::from_utf8_lossy(part).into_owned()
    }
}

// ---------------------------------------------------------------- streams

/// One track of the playing file.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StreamTrack {
    /// `Video`, `Audio`, `Subtitle`.
    pub kind: Option<String>,
    /// The codec as the server names it.
    pub codec: Option<String>,
    /// Picture width.
    pub width: Option<i64>,
    /// Picture height.
    pub height: Option<i64>,
    /// `VideoRangeType`.
    pub range_type: Option<String>,
    /// Audio channels.
    pub channels: Option<i64>,
    /// Bits per second.
    pub bit_rate: Option<i64>,
    /// The track's index.
    pub index: Option<i64>,
    /// The file's default track.
    pub is_default: Option<bool>,
}

/// What a session plays (`NowPlayingItem`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PlayingItem {
    /// `Id`.
    pub id: String,
    /// `Name`.
    pub name: String,
    /// `Type`: `Movie`, `Episode`, `Audio`.
    pub kind: Option<String>,
    /// `MediaType`.
    pub media_type: Option<String>,
    /// `ProductionYear`.
    pub year: Option<i64>,
    /// `SeriesName`.
    pub series_name: Option<String>,
    /// `SeriesId`.
    pub series_id: Option<String>,
    /// `SeriesPrimaryImageTag`.
    pub series_image_tag: Option<String>,
    /// `ParentIndexNumber`.
    pub season: Option<i64>,
    /// `IndexNumber`.
    pub episode: Option<i64>,
    /// `AlbumId`.
    pub album_id: Option<String>,
    /// `AlbumPrimaryImageTag`.
    pub album_image_tag: Option<String>,
    /// `AlbumArtist`.
    pub album_artist: Option<String>,
    /// `Artists`.
    pub artists: Vec<String>,
    /// `RunTimeTicks`.
    pub runtime_ticks: Option<i64>,
    /// `ImageTags.Primary`.
    pub primary_tag: Option<String>,
    /// `MediaStreams`.
    pub streams: Vec<StreamTrack>,
}

/// `TranscodingInfo`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct StreamTranscoding {
    /// The picture passes unchanged.
    pub video_direct: Option<bool>,
    /// The sound passes unchanged.
    pub audio_direct: Option<bool>,
    /// The transcoder's rate in bits per second.
    pub bitrate: Option<i64>,
}

/// What the line under the title says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TitleAddition {
    /// The year of a film.
    Year(i64),
    /// Season and episode.
    Episode {
        /// Season.
        season: i64,
        /// Episode.
        episode: i64,
    },
    /// The artist of a song.
    Artist(String),
}

/// **Someone playing something on the server right now** (`GET Sessions`, only sessions with a `NowPlayingItem`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerStream {
    /// The session's id.
    pub session_id: String,
    /// `UserId`.
    pub user_id: Option<String>,
    /// `UserName`.
    pub user_name: String,
    /// `UserPrimaryImageTag`.
    pub user_image_tag: Option<String>,
    /// The app (`Client`).
    pub client: String,
    /// The device (`DeviceName`).
    pub device: String,
    /// `RemoteEndPoint`.
    pub address: Option<String>,
    /// What plays.
    pub item: PlayingItem,
    /// `PlayState.PositionTicks`.
    pub position_ticks: i64,
    /// `PlayState.IsPaused`.
    pub paused: bool,
    /// `PlayState.PlayMethod`.
    pub play_method: Option<String>,
    /// `PlayState.AudioStreamIndex`.
    pub audio_index: Option<i64>,
    /// `TranscodingInfo`.
    pub transcoding: Option<StreamTranscoding>,
}

impl StreamTrack {
    fn read(v: &Value) -> Self {
        Self {
            kind: text(v, "Type"),
            codec: text(v, "Codec"),
            width: int(v, "Width"),
            height: int(v, "Height"),
            range_type: text(v, "VideoRangeType"),
            channels: int(v, "Channels"),
            bit_rate: int(v, "BitRate"),
            index: int(v, "Index"),
            is_default: flag(v, "IsDefault"),
        }
    }
}

impl PlayingItem {
    fn read(v: &Value) -> Option<Self> {
        Some(Self {
            id: text(v, "Id")?,
            name: text(v, "Name").unwrap_or_default(),
            kind: text(v, "Type"),
            media_type: text(v, "MediaType"),
            year: int(v, "ProductionYear"),
            series_name: text(v, "SeriesName"),
            series_id: text(v, "SeriesId"),
            series_image_tag: text(v, "SeriesPrimaryImageTag"),
            season: int(v, "ParentIndexNumber"),
            episode: int(v, "IndexNumber"),
            album_id: text(v, "AlbumId"),
            album_image_tag: text(v, "AlbumPrimaryImageTag"),
            album_artist: text(v, "AlbumArtist"),
            artists: v
                .get("Artists")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|n| n.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default(),
            runtime_ticks: int(v, "RunTimeTicks"),
            primary_tag: v.get("ImageTags").and_then(|t| text(t, "Primary")),
            streams: v
                .get("MediaStreams")
                .and_then(Value::as_array)
                .map(|a| a.iter().map(StreamTrack::read).collect())
                .unwrap_or_default(),
        })
    }
}

impl ServerStream {
    /// Reads one session; `None` when it plays nothing (an open app) or is broken.
    pub fn read(v: &Value) -> Option<Self> {
        let item = PlayingItem::read(v.get("NowPlayingItem")?)?;
        let state = v.get("PlayState");
        Some(Self {
            session_id: text(v, "Id")?,
            user_id: text(v, "UserId"),
            user_name: text(v, "UserName").unwrap_or_default(),
            user_image_tag: text(v, "UserPrimaryImageTag"),
            client: text(v, "Client").unwrap_or_default(),
            device: text(v, "DeviceName").unwrap_or_default(),
            address: text(v, "RemoteEndPoint"),
            item,
            position_ticks: state.and_then(|s| int(s, "PositionTicks")).unwrap_or(0),
            paused: state.and_then(|s| flag(s, "IsPaused")).unwrap_or(false),
            play_method: state.and_then(|s| text(s, "PlayMethod")),
            audio_index: state.and_then(|s| int(s, "AudioStreamIndex")),
            transcoding: v.get("TranscodingInfo").map(|t| StreamTranscoding {
                video_direct: flag(t, "IsVideoDirect"),
                audio_direct: flag(t, "IsAudioDirect"),
                bitrate: int(t, "Bitrate"),
            }),
        })
    }

    /// Only sessions that play something; the others are open apps. A broken entry does not take the others with it.
    ///
    /// # Errors
    /// [`ErrorKind::Decoding`] when the answer is no list.
    pub fn playing(body: &[u8]) -> Result<Vec<Self>, ErrorKind> {
        let value: Value =
            serde_json::from_slice(body).map_err(|e| ErrorKind::Decoding(e.to_string()))?;
        let list = value
            .as_array()
            .ok_or_else(|| ErrorKind::Decoding("sessions: not a list".into()))?;
        Ok(list.iter().filter_map(Self::read).collect())
    }

    /// **Session and title together.** The card is rebuilt (poster, badges) only when this changes: a new session, or
    /// the same one moving on to the next episode. Position and pause change every second under the same id.
    pub fn id(&self) -> String {
        format!("{}/{}", self.session_id, self.item.id)
    }

    /// The film, the series, the song.
    pub fn title(&self) -> String {
        match self.item.kind.as_deref() {
            Some("Episode") => self
                .item
                .series_name
                .clone()
                .unwrap_or_else(|| self.item.name.clone()),
            _ => self.item.name.clone(),
        }
    }

    /// After the title, quieter: the year of a film, the season and episode, the artist of a song.
    pub fn addition(&self) -> Option<TitleAddition> {
        let item = &self.item;
        match item.kind.as_deref() {
            Some("Episode") => Some(TitleAddition::Episode {
                season: item.season?,
                episode: item.episode?,
            }),
            Some("Audio") => item
                .album_artist
                .clone()
                .or_else(|| item.artists.first().cloned())
                .map(TitleAddition::Artist),
            _ => item.year.map(TitleAddition::Year),
        }
    }

    /// The episode's own name under the series; nothing for the rest.
    pub fn subtitle(&self) -> Option<String> {
        (self.item.kind.as_deref() == Some("Episode") && self.item.series_name.is_some())
            .then(|| self.item.name.clone())
    }

    /// Whose image is the poster, and its tag: the series for an episode, the album for a song.
    pub fn poster(&self) -> (String, Option<String>) {
        let item = &self.item;
        match item.kind.as_deref() {
            Some("Episode") if item.series_id.is_some() && item.series_image_tag.is_some() => (
                item.series_id.clone().unwrap_or_default(),
                item.series_image_tag.clone(),
            ),
            Some("Audio") if item.album_id.is_some() && item.album_image_tag.is_some() => (
                item.album_id.clone().unwrap_or_default(),
                item.album_image_tag.clone(),
            ),
            _ => (item.id.clone(), item.primary_tag.clone()),
        }
    }

    /// Music has square covers, everything else portrait posters.
    pub fn square_poster(&self) -> bool {
        matches!(self.item.kind.as_deref(), Some("Audio" | "MusicAlbum"))
    }

    /// A song or other audio.
    pub fn is_audio(&self) -> bool {
        self.item.media_type.as_deref() == Some("Audio")
            || self.item.kind.as_deref() == Some("Audio")
    }

    /// The first video track.
    pub fn video_track(&self) -> Option<&StreamTrack> {
        self.item
            .streams
            .iter()
            .find(|t| t.kind.as_deref() == Some("Video"))
    }

    /// The audio track that plays: the chosen one, else the file's default, else the first.
    pub fn audio_track(&self) -> Option<&StreamTrack> {
        let audio = || {
            self.item
                .streams
                .iter()
                .filter(|t| t.kind.as_deref() == Some("Audio"))
        };
        if let Some(i) = self.audio_index
            && let Some(chosen) = audio().find(|t| t.index == Some(i))
        {
            return Some(chosen);
        }
        audio()
            .find(|t| t.is_default == Some(true))
            .or_else(|| audio().next())
    }

    /// What goes over the line, in bits per second: the transcoder's rate, else the file's tracks together.
    pub fn bitrate(&self) -> Option<f64> {
        if let Some(t) = self.transcoding.and_then(|t| t.bitrate).filter(|t| *t > 0) {
            return Some(t as f64);
        }
        let sum: i64 = self
            .item
            .streams
            .iter()
            .filter(|t| matches!(t.kind.as_deref(), Some("Video" | "Audio")))
            .filter_map(|t| t.bit_rate)
            .sum();
        (sum > 0).then_some(sum as f64)
    }

    /// The server's `PlayMethod`. A transcoding session whose picture and sound both pass unchanged is only a new
    /// container: that is Direct Stream, not the expensive case.
    pub fn delivery(&self) -> DeliveryMethod {
        match self.play_method.as_deref() {
            Some("DirectPlay") => DeliveryMethod::DirectPlay,
            Some("DirectStream") => DeliveryMethod::DirectStream,
            Some("Transcode") => {
                if let Some(t) = self.transcoding
                    && t.video_direct == Some(true)
                    && t.audio_direct == Some(true)
                {
                    DeliveryMethod::DirectStream
                } else {
                    DeliveryMethod::Transcode
                }
            }
            _ => {
                if self.transcoding.is_none() {
                    DeliveryMethod::DirectPlay
                } else {
                    DeliveryMethod::Transcode
                }
            }
        }
    }

    /// The position in seconds.
    pub fn position(&self) -> f64 {
        self.position_ticks as f64 / 10_000_000.0
    }

    /// The runtime in seconds, when the server knows one.
    pub fn runtime(&self) -> Option<f64> {
        self.item
            .runtime_ticks
            .map(|t| t as f64 / 10_000_000.0)
            .filter(|r| *r > 0.0)
    }

    /// 0...1 for the bar.
    pub fn share(&self) -> f64 {
        self.runtime()
            .map_or(0.0, |r| (self.position() / r).clamp(0.0, 1.0))
    }

    /// "8K", "4K", "1080p", "720p", "SD". Width first: a scope film is 3840x1600 and still 4K. The same buckets as the
    /// Jelly Twiggy plugin, so the badge and the library counts agree.
    pub fn resolution(width: Option<i64>, height: Option<i64>) -> Option<&'static str> {
        let (w, h) = (width.unwrap_or(0), height.unwrap_or(0));
        if w <= 0 && h <= 0 {
            return None;
        }
        Some(if w >= 7000 || h >= 4000 {
            "8K"
        } else if w >= 3200 || h >= 2000 {
            "4K"
        } else if w >= 1800 || h >= 1000 {
            "1080p"
        } else if w >= 1200 || h >= 700 {
            "720p"
        } else {
            "SD"
        })
    }

    /// "DV", "HDR10+", "HDR10", "HLG"; nothing for SDR, which is the normal case.
    pub fn range(raw: Option<&str>) -> Option<&'static str> {
        let raw = raw?;
        if raw.starts_with("DOVI") && raw != "DOVIInvalid" {
            return Some("DV");
        }
        match raw {
            "HDR10Plus" => Some("HDR10+"),
            "HDR10" => Some("HDR10"),
            "HLG" => Some("HLG"),
            _ => None,
        }
    }

    /// "2.0", "5.1", "7.1" next to an audio codec, where "Stereo" would be a word among codes.
    pub fn channels(count: Option<i64>) -> Option<String> {
        match count? {
            1 => Some("1.0".into()),
            2 => Some("2.0".into()),
            6 => Some("5.1".into()),
            8 => Some("7.1".into()),
            n if n > 0 => Some(format!("{n}ch")),
            _ => None,
        }
    }

    /// "26 Mb/s" from 10 Mbit up, "4.5 Mb/s" below, "320 kb/s" under one megabit. Latin units like every other technical
    /// value next to it.
    pub fn short_rate(bit_per_second: Option<f64>) -> Option<String> {
        let b = bit_per_second.filter(|b| *b > 0.0)?;
        Some(if b >= 10_000_000.0 {
            format!("{} Mb/s", (b / 1_000_000.0).round() as i64)
        } else if b >= 1_000_000.0 {
            format!("{:.1} Mb/s", b / 1_000_000.0)
        } else {
            format!("{} kb/s", (b / 1_000.0).round() as i64)
        })
    }

    /// "4:07" or "1:04:07". Hours only when the whole runs that long, so both sides match.
    pub fn clock(seconds: f64, long: bool) -> String {
        let t = if seconds.is_finite() {
            seconds.max(0.0) as i64
        } else {
            0
        };
        let (h, m, s) = (t / 3600, (t % 3600) / 60, t % 60);
        if long {
            format!("{h}:{m:02}:{s:02}")
        } else {
            format!("{}:{s:02}", t / 60)
        }
    }
}

// ---------------------------------------------------------------- calls

/// The message a stopped viewer is shown (`POST Sessions/{id}/Message`). No `TimeoutMs`: the clients then show a dialog
/// to confirm.
fn message_body(header: &str, text: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({"Header": header, "Text": text})).unwrap_or_default()
}

impl<T: HttpTransport> JellyfinClient<T> {
    async fn admin_get(&self, path: &str, query: &Query) -> Result<Value, ErrorKind> {
        self.require_session()?;
        let req = self.get(path, query)?;
        self.send(req).await
    }

    /// A signed-in call whose answer is only the status.
    async fn admin_call(
        &self,
        path: &str,
        method: Method,
        body: Option<Vec<u8>>,
    ) -> Result<(), ErrorKind> {
        self.require_session()?;
        let req = self.request(path, method, &Query::new(), body)?;
        self.send_ignoring_body(req).await
    }

    /// `GET System/Info`: name, version and whether a restart waits.
    ///
    /// # Errors
    /// The transport or decoding error; 403 for an account that is no administrator.
    pub async fn server_system(&self) -> Result<ServerSystem, ErrorKind> {
        Ok(ServerSystem::read(
            &self.admin_get("System/Info", &Query::new()).await?,
        ))
    }

    /// `GET Items/Counts`: films, series, episodes.
    ///
    /// # Errors
    /// The transport or decoding error.
    pub async fn item_counts(&self) -> Result<ServerCounts, ErrorKind> {
        Ok(ServerCounts::read(
            &self.admin_get("Items/Counts", &Query::new()).await?,
        ))
    }

    /// The Jelly Twiggy plugin's counts by resolution (one request, cached on the server). `None` when the plugin is
    /// missing or does not answer; the caller then counts with [`Self::resolution_filter_count`].
    pub async fn plugin_resolutions(&self) -> Option<ResolutionCounts> {
        if self.state().twiggy_absent {
            return None;
        }
        let answer = self
            .admin_get("JellyTwiggy/LibraryResolutions", &Query::new())
            .await
            .ok()?;
        Some(ResolutionCounts::plugin(&answer))
    }

    /// One count of films and episodes with Jellyfin's own resolution filter (`Limit=0`, only the total is read).
    pub async fn resolution_filter_count(&self, filter: ResolutionFilter) -> Option<i64> {
        let (name, value) = match filter {
            ResolutionFilter::Uhd => ("Is4K", "true"),
            ResolutionFilter::HdOrBetter => ("IsHd", "true"),
            ResolutionFilter::Sd => ("IsHd", "false"),
        };
        let query = Query::new()
            .add("Recursive", "true")
            .add("IncludeItemTypes", "Movie,Episode")
            .add("IsMissing", "false")
            .add(name, value)
            .add("Limit", "0")
            .add("EnableTotalRecordCount", "true");
        int(
            &self.admin_get("Items", &query).await.ok()?,
            "TotalRecordCount",
        )
    }

    /// The plugin's load. A 404 means no plugin, and the client stops asking: the page asks every second, and a
    /// missing plugin does not appear by itself. `None` also for an answer with nothing in it (not Linux).
    pub async fn system_load(&self) -> Option<ServerLoad> {
        if self.state().twiggy_absent {
            return None;
        }
        match self
            .admin_get("JellyTwiggy/SystemMetrics", &Query::new())
            .await
        {
            Ok(v) => Some(ServerLoad::read(&v)).filter(|l| !l.is_empty()),
            Err(ErrorKind::Http { status, .. }) if status == 404 || status == 405 => {
                self.state().twiggy_absent = true;
                None
            }
            Err(_) => None,
        }
    }

    /// `GET System/Info/Storage` (10.11 and later): the drives. Empty on an older server.
    pub async fn disks(&self) -> Vec<ServerDisk> {
        self.admin_get("System/Info/Storage", &Query::new())
            .await
            .map(|v| ServerDisk::from_storage(&v))
            .unwrap_or_default()
    }

    /// `GET ScheduledTasks`: the running ones, the furthest along first.
    ///
    /// # Errors
    /// The transport or decoding error.
    pub async fn running_tasks(&self) -> Result<Vec<ServerTask>, ErrorKind> {
        let v = self
            .admin_get("ScheduledTasks", &Query::new().add("isHidden", "false"))
            .await?;
        let all = v
            .as_array()
            .map(|a| a.iter().filter_map(ServerTask::read).collect())
            .unwrap_or_default();
        Ok(ServerTask::running(all))
    }

    /// `GET Sessions` for the ones active in the last minute that play something.
    ///
    /// # Errors
    /// The transport or decoding error.
    pub async fn active_streams(&self) -> Result<Vec<ServerStream>, ErrorKind> {
        self.require_session()?;
        let req = self.get(
            "Sessions",
            &Query::new().add("activeWithinSeconds", ACTIVE_WITHIN_SECONDS),
        )?;
        let response = self.execute(req).await?;
        if !response.is_success() {
            return Err(ErrorKind::Http {
                status: response.status,
                body: response.text_prefix(300),
            });
        }
        ServerStream::playing(&response.body)
    }

    /// `POST System/Restart`.
    ///
    /// # Errors
    /// The transport error; 403 for an account that is no administrator.
    pub async fn restart_server(&self) -> Result<(), ErrorKind> {
        self.admin_call("System/Restart", Method::Post, None).await
    }

    /// `POST Library/Refresh`: every library, as "Scan all libraries" on the server's dashboard does.
    ///
    /// # Errors
    /// The transport error.
    pub async fn scan_libraries(&self) -> Result<(), ErrorKind> {
        self.admin_call("Library/Refresh", Method::Post, None).await
    }

    /// `DELETE ScheduledTasks/Running/{id}`: cancels a running task; the server sets it to `Cancelling`, then `Idle`.
    ///
    /// # Errors
    /// The transport error.
    pub async fn stop_task(&self, id: &str) -> Result<(), ErrorKind> {
        self.admin_call(
            &format!("ScheduledTasks/Running/{id}"),
            Method::Delete,
            None,
        )
        .await
    }

    /// **Stops a session's playback, then tells the viewer why.** Stop first: a message sent while the player is open
    /// sits behind it on some clients and goes with it when it closes. Without a timeout Jellyfin's clients show the
    /// message as a dialog the viewer confirms, so it cannot pass unseen. A failed message does not undo the stop and
    /// is not reported; the stop is what was asked for.
    ///
    /// # Errors
    /// The error of the stop call.
    pub async fn stop_playback(
        &self,
        session_id: &str,
        header: &str,
        message: &str,
    ) -> Result<(), ErrorKind> {
        self.admin_call(
            &format!("Sessions/{session_id}/Playing/Stop"),
            Method::Post,
            None,
        )
        .await?;
        let text = message.trim();
        if text.is_empty() {
            return Ok(());
        }
        let _ = self
            .admin_call(
                &format!("Sessions/{session_id}/Message"),
                Method::Post,
                Some(message_body(header, text)),
            )
            .await;
        Ok(())
    }

    /// `GET System/Logs`: the log files, newest first.
    ///
    /// # Errors
    /// The transport or decoding error.
    pub async fn log_files(&self) -> Result<Vec<ServerLogFile>, ErrorKind> {
        let v = self.admin_get("System/Logs", &Query::new()).await?;
        let files = v
            .as_array()
            .map(|a| a.iter().filter_map(ServerLogFile::read).collect())
            .unwrap_or_default();
        Ok(ServerLogFile::newest_first(files))
    }

    /// `GET System/Logs/Log?name=...`: the end of one file, at most `limit` bytes.
    ///
    /// # Errors
    /// The transport error; a login page of a gateway is [`TransportReason::LoginPage`].
    pub async fn log_text(&self, name: &str, limit: usize) -> Result<String, ErrorKind> {
        self.require_session()?;
        let req = self.get("System/Logs/Log", &Query::new().add("name", name))?;
        let response = self.execute(req).await?;
        if !response.is_success() {
            return Err(ErrorKind::Http {
                status: response.status,
                body: response.text_prefix(300),
            });
        }
        if response.is_login_page() {
            return Err(ErrorKind::Transport(TransportReason::LoginPage));
        }
        Ok(ServerLogFile::tail(&response.body, limit))
    }
}
