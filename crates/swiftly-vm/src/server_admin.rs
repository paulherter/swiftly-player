//! The server page of a Jellyfin administrator and its log files: ONE model for every host.
//!
//! The page has one state, [`ServerAdminState`]: `Loading` until the library counts and the first live read are in (the
//! page appears whole), then `Ready` with the finished page, or `Failed` (with a hint and a retry) or `NotAllowed` (the
//! account is no administrator). The counts load once; load, drives, tasks and sessions are read every second, but only
//! between the [`ServerAdminIntent::Start`] and [`ServerAdminIntent::Stop`] of the host (the page is on screen). A
//! question before something that cannot be undone (restart, stop a task, stop a stream) is part of the state
//! ([`ServerAdminAsk`]); the host draws it and answers with `Confirm` or `Cancel`. Stream cards are keyed by session and
//! title ([`ServerStreamCard::id`]), so posters do not reload while time and bar move. Texts are finished in the host's
//! language. Only Jellyfin has the page ([`server_admin_offered`]); Plex and Emby show no server block.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use futures_util::future::{join, join3, join4};
use swiftly_jellyfin::{
    DiskUse, LOG_LIMIT, ResolutionCounts, ResolutionFilter, ServerCounts, ServerDisk, ServerKind,
    ServerLoad, ServerLogFile, ServerStream, ServerSystem, ServerTask, TitleAddition,
};
use swiftly_l10n::{Arg, Translator};
use swiftly_model::DeliveryMethod;
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_playback::tech_details::codec_name_value;

use crate::account::AccountRef;
use crate::bell::{Bell, Changed};
use crate::downloads_vm::{decimal_separator, size_text};
use crate::home::{Client, build_client};
use crate::host::{Host, Sleeper};

/// Seconds between two live reads while the page is on screen.
pub const TICK_SECONDS: f64 = 1.0;

/// Does this account's server have the page? Only Jellyfin; the host also needs `Policy.IsAdministrator` of the account
/// (`AccountDefaultsInfo::is_administrator`), see [`crate::profile_entry`].
pub fn server_admin_offered(account: &AccountRef) -> bool {
    account.server_kind == ServerKind::Jellyfin
}

// ------------------------------------------------------------------ the page

/// A count with its label ("Filme" 1.204).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerNumber {
    /// "Filme", "4K".
    pub label: String,
    /// The count.
    pub value: i64,
    /// The count with thousands separators.
    pub text: String,
}

/// A running task.
#[derive(Debug, Clone, PartialEq)]
pub struct ServerTaskRow {
    /// The task's id (for `AskStopTask`).
    pub id: String,
    /// "Mediathek scannen".
    pub name: String,
    /// 0...1; `None` in the first moments.
    pub progress: Option<f64>,
    /// "42 %".
    pub progress_text: Option<String>,
}

/// What a badge on a stream card describes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerBadgeKind {
    /// "4K".
    Resolution,
    /// "DV", "HDR10".
    Range,
    /// "HEVC".
    Video,
    /// "AC-3 5.1".
    Audio,
}

/// One badge: the kind decides the colour, on every platform the same.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerBadge {
    /// The kind.
    pub kind: ServerBadgeKind,
    /// The text.
    pub text: String,
}

/// Someone playing something right now, finished for the card.
#[derive(Debug, Clone, PartialEq)]
pub struct ServerStreamCard {
    /// Session and title: the card is rebuilt only when this changes.
    pub id: String,
    /// The session (for `AskStopStream`).
    pub session_id: String,
    /// The viewer.
    pub user_name: String,
    /// The viewer's id, for the profile picture.
    pub user_id: Option<String>,
    /// The tag of the viewer's picture.
    pub user_image_tag: Option<String>,
    /// The film, the series, the song.
    pub title: String,
    /// "2026", "S1 · F3", the artist.
    pub addition: Option<String>,
    /// The episode's own name.
    pub subtitle: Option<String>,
    /// Whose picture is the poster.
    pub poster_id: String,
    /// The poster's tag.
    pub poster_tag: Option<String>,
    /// Music has square covers.
    pub square_poster: bool,
    /// A song.
    pub is_audio: bool,
    /// Resolution, range, codecs: what lies on the disk.
    pub badges: Vec<ServerBadge>,
    /// "Safari · Jellyfin Web · 172.30.212.2".
    pub device_line: String,
    /// 0...1 for the bar.
    pub share: f64,
    /// "0:42 / 2:05:33".
    pub time_line: String,
    /// Paused.
    pub paused: bool,
    /// "Direct Play".
    pub delivery_text: String,
    /// "Direct Play · 26 Mb/s".
    pub delivery_line: String,
    /// Transcoding: drawn in the warning colour.
    pub cautionary: bool,
}

/// A ring: "13%" in the middle.
#[derive(Debug, Clone, PartialEq)]
pub struct ServerMeter {
    /// "CPU", "RAM".
    pub label: String,
    /// 0...1.
    pub share: f64,
    /// "13%".
    pub text: String,
}

/// The plugin's load.
#[derive(Debug, Clone, PartialEq)]
pub struct ServerLoadView {
    /// The processor.
    pub cpu: Option<ServerMeter>,
    /// The memory.
    pub memory: Option<ServerMeter>,
    /// The read and write rate.
    pub disk_io: Option<ServerDiskIo>,
}

/// The drives' read and write rate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerDiskIo {
    /// "Festplatten".
    pub label: String,
    /// "↓ 12 MB/s · ↑ 1,3 MB/s".
    pub text: String,
}

/// One drive.
#[derive(Debug, Clone, PartialEq)]
pub struct ServerDiskRow {
    /// The drive's id.
    pub id: String,
    /// What lives on it: "Filme, Serien".
    pub title: String,
    /// "50%" free.
    pub free_text: String,
    /// 0...1 free.
    pub free_share: f64,
    /// Under 10 percent: draw it in a colour.
    pub nearly_full: bool,
}

/// What a row of "Verwaltung" does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerActionKind {
    /// `ServerAdminIntent::Scan`.
    ScanLibraries,
    /// `ServerAdminIntent::AskRestart`.
    Restart,
    /// Open the log files (a [`ServerLogsVm`]).
    Logs,
}

/// A row of the "Verwaltung" group.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerAction {
    /// Which.
    pub kind: ServerActionKind,
    /// "Mediathek scannen".
    pub title: String,
    /// The second line.
    pub under: Option<String>,
    /// A restart waits: draw the row in the accent.
    pub accent: bool,
}

/// The question the page asks before it does something; the host draws it and answers `Confirm` or `Cancel`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerAdminAsk {
    /// No question.
    Nothing,
    /// "Server neu starten?".
    Restart {
        /// "Server neu starten?".
        title: String,
        /// "Wer gerade schaut, wird für eine Minute unterbrochen.".
        note: String,
        /// "Neu starten".
        action: String,
    },
    /// "„Scan“ stoppen?".
    StopTask {
        /// The task.
        id: String,
        /// The question.
        title: String,
        /// "Stoppen".
        action: String,
    },
    /// Stop one stream, with a message to the viewer.
    StopStream {
        /// The session.
        session_id: String,
        /// "Wiedergabe stoppen".
        title: String,
        /// "„Tenzing“ bei Andrey wird gestoppt. Die Nachricht erscheint auf dem Gerät.".
        line: String,
        /// "Nachricht (optional)".
        message_label: String,
        /// The text the viewer sees unless the administrator writes another.
        message: String,
        /// "Stoppen".
        action: String,
    },
}

/// The finished page.
#[derive(Debug, Clone, PartialEq)]
pub struct ServerAdminPage {
    /// "Server".
    pub server_title: String,
    /// The server's name.
    pub name: String,
    /// "(10.11.2)" or empty, quieter next to the name.
    pub version: String,
    /// Films, series, episodes.
    pub counts: Vec<ServerNumber>,
    /// 4K, HD, SD; empty when neither the plugin nor the filters answered.
    pub resolutions: Vec<ServerNumber>,
    /// "Aufgaben".
    pub tasks_title: String,
    /// The running tasks (the group is hidden when empty).
    pub tasks: Vec<ServerTaskRow>,
    /// "Wiedergaben".
    pub streams_title: String,
    /// "Gerade spielt niemand etwas ab." (draw it when `streams` is empty).
    pub streams_empty: String,
    /// Who plays what.
    pub streams: Vec<ServerStreamCard>,
    /// "Auslastung" (draw the group when `load` or `disks` has something).
    pub load_title: String,
    /// The plugin's load.
    pub load: Option<ServerLoadView>,
    /// The drives.
    pub disks: Vec<ServerDiskRow>,
    /// "Verwaltung".
    pub actions_title: String,
    /// Scan, restart, log files.
    pub actions: Vec<ServerAction>,
    /// The answer to the last action ("Der Server startet neu.", or why it failed).
    pub notice: Option<String>,
    /// The open question.
    pub ask: ServerAdminAsk,
}

/// The one state of the server page.
#[derive(Debug, Clone, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum ServerAdminState {
    /// The first read runs.
    Loading,
    /// The page.
    Ready {
        /// What to draw.
        page: ServerAdminPage,
    },
    /// The first read failed; `ServerAdminIntent::Retry` asks again.
    Failed {
        /// Why, in the host's language.
        hint: String,
    },
    /// The account is no administrator.
    NotAllowed {
        /// "Nur Administratoren können den Server verwalten.".
        hint: String,
    },
}

/// What the host draws.
#[derive(Debug, Clone, PartialEq)]
pub struct ServerAdminPart {
    /// Grows with every change.
    pub version: u64,
    /// The page title: the server's name once known, else "Server".
    pub title: String,
    /// The state.
    pub state: ServerAdminState,
}

/// What the host does with the page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerAdminIntent {
    /// The page is on screen: load once, then read every second.
    Start,
    /// The page left the screen: stop reading.
    Stop,
    /// Ask again after `Failed`.
    Retry,
    /// Scan every library.
    Scan,
    /// Ask before restarting.
    AskRestart,
    /// Ask before stopping a task.
    AskStopTask {
        /// The task's id.
        id: String,
    },
    /// Ask before stopping a stream (the sheet has the message field).
    AskStopStream {
        /// The session's id.
        session_id: String,
    },
    /// Do what the open question asks. `message` is the text for a stopped viewer (empty: none).
    Confirm {
        /// The message, only read for a stream.
        message: Option<String>,
    },
    /// Close the question.
    Cancel,
}

struct Once {
    system: ServerSystem,
    counts: ServerCounts,
    resolutions: Option<ResolutionCounts>,
}

#[derive(Clone, Default)]
struct Tick {
    load: Option<ServerLoad>,
    disks: Vec<ServerDisk>,
    tasks: Vec<ServerTask>,
    streams: Vec<ServerStream>,
}

enum Phase {
    Loading,
    Ready,
    Failed(String),
    NotAllowed(String),
}

enum Ask {
    Nothing,
    Restart,
    StopTask {
        id: String,
        name: String,
    },
    StopStream {
        session_id: String,
        title: String,
        user: String,
    },
}

struct Live {
    generation: u64,
    visible: bool,
    phase: Phase,
    once: Option<Once>,
    tick: Tick,
    notice: Option<String>,
    ask: Ask,
    part: Arc<ServerAdminPart>,
}

struct Inner<T: HttpTransport + 'static> {
    host: Host,
    sleeper: Arc<dyn Sleeper>,
    client: Arc<Client<T>>,
    t: Translator,
    sep: &'static str,
    bell: Arc<Bell>,
    live: Mutex<Live>,
}

/// The server page of one account. Cheap to clone (a handle).
pub struct ServerAdminVm<T: HttpTransport + 'static> {
    inner: Arc<Inner<T>>,
}

impl<T: HttpTransport + 'static> Clone for ServerAdminVm<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl<T: HttpTransport + 'static> ServerAdminVm<T> {
    /// The page of `account`. Nothing is sent before `Start`.
    ///
    /// # Errors
    /// [`ErrorKind::InvalidServerUrl`] for an account that is not on a Jellyfin server (the host asks
    /// [`server_admin_offered`] first and shows no row), or an unusable address.
    pub fn new(
        transport: Arc<T>,
        host: Host,
        sleeper: Arc<dyn Sleeper>,
        account: &AccountRef,
    ) -> Result<Self, ErrorKind> {
        if !server_admin_offered(account) {
            return Err(ErrorKind::InvalidServerUrl);
        }
        let client = Arc::new(build_client(&transport, &host, account)?);
        let t = Translator::new(host.locale.clone());
        let sep = decimal_separator(host.locale.language());
        let part = ServerAdminPart {
            version: 1,
            title: t.t("Server"),
            state: ServerAdminState::Loading,
        };
        Ok(Self {
            inner: Arc::new(Inner {
                host,
                sleeper,
                client,
                t,
                sep,
                bell: Bell::new(),
                live: Mutex::new(Live {
                    generation: 0,
                    visible: false,
                    phase: Phase::Loading,
                    once: None,
                    tick: Tick::default(),
                    notice: None,
                    ask: Ask::Nothing,
                    part: Arc::new(part),
                }),
            }),
        })
    }

    /// The version; moves whenever the part changes.
    pub fn version(&self) -> u64 {
        self.inner.bell.version()
    }

    /// The screen state.
    pub fn part(&self) -> Arc<ServerAdminPart> {
        Arc::clone(&self.inner.live().part)
    }

    /// Waits until the part is newer than `seen`.
    pub fn changed(&self, seen: u64) -> Changed {
        self.inner.bell.changed(seen)
    }

    /// Observers currently parked in [`Self::changed`].
    pub fn waiters(&self) -> u32 {
        self.inner.bell.waiting()
    }

    /// An intent from the view. Never blocks.
    pub fn send(&self, intent: ServerAdminIntent) {
        let me = &self.inner;
        match intent {
            ServerAdminIntent::Start => {
                let generation = {
                    let mut live = me.live();
                    if live.visible {
                        return;
                    }
                    live.visible = true;
                    live.generation += 1;
                    live.generation
                };
                Inner::spawn_run(me, generation);
            }
            ServerAdminIntent::Stop => {
                let mut live = me.live();
                live.visible = false;
                live.generation += 1;
            }
            ServerAdminIntent::Retry => {
                let generation = {
                    let mut live = me.live();
                    if !matches!(live.phase, Phase::Failed(_)) || !live.visible {
                        return;
                    }
                    live.phase = Phase::Loading;
                    live.generation += 1;
                    me.publish(&mut live);
                    live.generation
                };
                Inner::spawn_run(me, generation);
            }
            ServerAdminIntent::Scan => Inner::act(me, Act::Scan),
            ServerAdminIntent::AskRestart => me.ask(|_| Some(Ask::Restart)),
            ServerAdminIntent::AskStopTask { id } => me.ask(|live| {
                live.tick
                    .tasks
                    .iter()
                    .find(|t| t.id == id)
                    .map(|t| Ask::StopTask {
                        id: t.id.clone(),
                        name: t.name.clone(),
                    })
            }),
            ServerAdminIntent::AskStopStream { session_id } => me.ask(|live| {
                live.tick
                    .streams
                    .iter()
                    .find(|s| s.session_id == session_id)
                    .map(|s| Ask::StopStream {
                        session_id: s.session_id.clone(),
                        title: s.title(),
                        user: s.user_name.clone(),
                    })
            }),
            ServerAdminIntent::Cancel => me.ask(|_| Some(Ask::Nothing)),
            ServerAdminIntent::Confirm { message } => {
                let ask = {
                    let mut live = me.live();
                    let ask = std::mem::replace(&mut live.ask, Ask::Nothing);
                    live.notice = None;
                    me.publish(&mut live);
                    ask
                };
                match ask {
                    Ask::Nothing => {}
                    Ask::Restart => Inner::act(me, Act::Restart),
                    Ask::StopTask { id, .. } => Inner::act(me, Act::StopTask(id)),
                    Ask::StopStream { session_id, .. } => {
                        let text = message.unwrap_or_default();
                        Inner::act(me, Act::StopStream(session_id, text));
                    }
                }
            }
        }
    }
}

enum Act {
    Scan,
    Restart,
    StopTask(String),
    StopStream(String, String),
}

impl<T: HttpTransport + 'static> Inner<T> {
    fn live(&self) -> MutexGuard<'_, Live> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Sets the open question if the page is `Ready` and `pick` finds one.
    fn ask(&self, pick: impl FnOnce(&Live) -> Option<Ask>) {
        let mut live = self.live();
        if !matches!(live.phase, Phase::Ready) {
            return;
        }
        if let Some(ask) = pick(&live) {
            live.ask = ask;
            self.publish(&mut live);
        }
    }

    fn spawn_run(me: &Arc<Self>, generation: u64) {
        let inner = Arc::clone(me);
        let lost = Arc::clone(me);
        me.host.spawn_guarded(
            Box::pin(async move { inner.run(generation).await }),
            move || {
                let mut live = lost.live();
                if live.generation == generation {
                    let hint = lost.t.t("Der Server antwortet nicht.");
                    live.phase = Phase::Failed(hint);
                    lost.publish(&mut live);
                }
            },
        );
    }

    fn current(&self, generation: u64) -> bool {
        let live = self.live();
        live.generation == generation && live.visible
    }

    async fn run(self: Arc<Self>, generation: u64) {
        if self.live().once.is_none() {
            let prev = self.live().tick.clone();
            let (once, tick) = join(self.load_once(), self.read_tick(prev)).await;
            let mut live = self.live();
            if live.generation != generation {
                return;
            }
            match once {
                Ok(once) => {
                    live.once = Some(once);
                    live.tick = tick;
                    live.phase = Phase::Ready;
                }
                Err(ErrorKind::Http { status: 403, .. }) => {
                    live.phase = Phase::NotAllowed(
                        self.t.t("Nur Administratoren können den Server verwalten."),
                    );
                }
                Err(e) => {
                    live.phase =
                        Phase::Failed(swiftly_l10n::error_text::readable_error(&self.t, &e));
                }
            }
            self.publish(&mut live);
            if !matches!(live.phase, Phase::Ready) {
                return;
            }
        }
        while self.current(generation) {
            self.sleeper.sleep(TICK_SECONDS).await;
            if !self.current(generation) {
                break;
            }
            let prev = self.live().tick.clone();
            let tick = self.read_tick(prev).await;
            let mut live = self.live();
            if live.generation != generation || !live.visible {
                break;
            }
            live.tick = tick;
            self.publish(&mut live);
        }
    }

    async fn load_once(&self) -> Result<Once, ErrorKind> {
        let c = &self.client;
        let (system, counts, resolutions) =
            join3(c.server_system(), c.item_counts(), self.resolutions()).await;
        Ok(Once {
            system: system?,
            counts: counts?,
            resolutions,
        })
    }

    /// The plugin's counts first (one request, cached on the server); otherwise three counts with Jellyfin's filters.
    async fn resolutions(&self) -> Option<ResolutionCounts> {
        let c = &self.client;
        if let Some(r) = c.plugin_resolutions().await {
            return Some(r);
        }
        let (u, h, s) = join3(
            c.resolution_filter_count(ResolutionFilter::Uhd),
            c.resolution_filter_count(ResolutionFilter::HdOrBetter),
            c.resolution_filter_count(ResolutionFilter::Sd),
        )
        .await;
        Some(ResolutionCounts::filters(u?, h?, s?))
    }

    /// Load, drives, tasks and streams, every one on its own: a server before 10.11 has no storage endpoint, one without
    /// the plugin no load, and neither may take the streams with it. A failed read of tasks or streams keeps what the
    /// page showed.
    async fn read_tick(&self, prev: Tick) -> Tick {
        let c = &self.client;
        let (load, disks, tasks, streams) = join4(
            c.system_load(),
            c.disks(),
            c.running_tasks(),
            c.active_streams(),
        )
        .await;
        Tick {
            load,
            disks,
            tasks: tasks.unwrap_or(prev.tasks),
            streams: streams.unwrap_or(prev.streams),
        }
    }

    fn act(me: &Arc<Self>, act: Act) {
        {
            let mut live = me.live();
            if !matches!(live.phase, Phase::Ready) {
                return;
            }
            live.notice = None;
        }
        let inner = Arc::clone(me);
        let lost = Arc::clone(me);
        me.host.spawn_guarded(
            Box::pin(async move {
                let c = &inner.client;
                let (result, done) = match act {
                    Act::Scan => (
                        c.scan_libraries().await,
                        Some("Die Mediathek wird gescannt."),
                    ),
                    Act::Restart => (c.restart_server().await, Some("Der Server startet neu.")),
                    Act::StopTask(id) => (c.stop_task(&id).await, None),
                    Act::StopStream(session, text) => {
                        let text = if text.trim().is_empty() {
                            String::new()
                        } else {
                            text
                        };
                        let header = inner.t.t("Nachricht vom Administrator");
                        (c.stop_playback(&session, &header, &text).await, None)
                    }
                };
                let notice = match result {
                    Ok(()) => done.map(|key| inner.t.t(key)),
                    Err(e) => Some(swiftly_l10n::error_text::readable_error(&inner.t, &e)),
                };
                let mut live = inner.live();
                live.notice = notice;
                inner.publish(&mut live);
            }),
            move || {
                let mut live = lost.live();
                live.notice = Some(lost.t.t("Der Server antwortet nicht."));
                lost.publish(&mut live);
            },
        );
    }

    /// Builds the part from the live data; rings the bell only when what the host draws changed.
    fn publish(&self, live: &mut Live) {
        let title = live
            .once
            .as_ref()
            .map(|o| o.system.name.clone())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| self.t.t("Server"));
        let state = match &live.phase {
            Phase::Loading => ServerAdminState::Loading,
            Phase::Failed(hint) => ServerAdminState::Failed { hint: hint.clone() },
            Phase::NotAllowed(hint) => ServerAdminState::NotAllowed { hint: hint.clone() },
            Phase::Ready => match &live.once {
                Some(once) => ServerAdminState::Ready {
                    page: self.page(once, live),
                },
                None => ServerAdminState::Loading,
            },
        };
        if live.part.title == title && live.part.state == state {
            return;
        }
        let version = self.bell.bump(&[0]);
        live.part = Arc::new(ServerAdminPart {
            version,
            title,
            state,
        });
    }

    fn number(&self, label: &str, value: i64) -> ServerNumber {
        ServerNumber {
            label: label.to_owned(),
            value,
            text: group(value, self.sep),
        }
    }

    fn percent(value: f64) -> String {
        format!("{}%", value.clamp(0.0, 100.0).round() as i64)
    }

    fn page(&self, once: &Once, live: &Live) -> ServerAdminPage {
        let t = &self.t;
        let counts = vec![
            self.number(&t.t("Filme"), once.counts.movies),
            self.number(&t.t("Serien"), once.counts.series),
            self.number(&t.t("Folgen"), once.counts.episodes),
        ];
        let resolutions = once.resolutions.map_or_else(Vec::new, |r| {
            vec![
                self.number("4K", r.uhd),
                self.number("HD", r.hd),
                self.number("SD", r.sd),
            ]
        });
        let tasks = live
            .tick
            .tasks
            .iter()
            .map(|task| ServerTaskRow {
                id: task.id.clone(),
                name: task.name.clone(),
                progress: task.progress.map(|p| (p / 100.0).clamp(0.0, 1.0)),
                progress_text: task
                    .progress
                    .map(|p| format!("{} %", p.clamp(0.0, 100.0).round() as i64)),
            })
            .collect();
        let pending = once.system.pending_restart;
        let actions = vec![
            ServerAction {
                kind: ServerActionKind::ScanLibraries,
                title: t.t("Mediathek scannen"),
                under: Some(t.t("Alle Bibliotheken nach neuen Dateien durchsuchen")),
                accent: false,
            },
            ServerAction {
                kind: ServerActionKind::Restart,
                title: t.t("Server neu starten"),
                under: pending.then(|| t.t("Ein Neustart steht aus")),
                accent: pending,
            },
            ServerAction {
                kind: ServerActionKind::Logs,
                title: t.t("Protokoll"),
                under: Some(t.t("Die Logdateien des Servers")),
                accent: false,
            },
        ];
        ServerAdminPage {
            server_title: t.t("Server"),
            name: once.system.name.clone(),
            version: if once.system.version.is_empty() {
                String::new()
            } else {
                format!("({})", once.system.version)
            },
            counts,
            resolutions,
            tasks_title: t.t("Aufgaben"),
            tasks,
            streams_title: t.t("Wiedergaben"),
            streams_empty: t.t("Gerade spielt niemand etwas ab."),
            streams: live.tick.streams.iter().map(|s| self.card(s)).collect(),
            load_title: t.t("Auslastung"),
            load: live.tick.load.as_ref().map(|l| self.load_view(l)),
            disks: live.tick.disks.iter().map(|d| self.disk_row(d)).collect(),
            actions_title: t.t("Verwaltung"),
            actions,
            notice: live.notice.clone(),
            ask: self.ask_view(&live.ask),
        }
    }

    fn ask_view(&self, ask: &Ask) -> ServerAdminAsk {
        let t = &self.t;
        match ask {
            Ask::Nothing => ServerAdminAsk::Nothing,
            Ask::Restart => ServerAdminAsk::Restart {
                title: t.t("Server neu starten?"),
                note: t.t("Wer gerade schaut, wird für eine Minute unterbrochen."),
                action: t.t("Neu starten"),
            },
            Ask::StopTask { id, name } => ServerAdminAsk::StopTask {
                id: id.clone(),
                title: t.t_args("„%@“ stoppen?", &[Arg::Str(name.clone())]),
                action: t.t("Stoppen"),
            },
            Ask::StopStream {
                session_id,
                title,
                user,
            } => ServerAdminAsk::StopStream {
                session_id: session_id.clone(),
                title: t.t("Wiedergabe stoppen"),
                line: t.t_args(
                    "„%1$@“ bei %2$@ wird gestoppt. Die Nachricht erscheint auf dem Gerät.",
                    &[Arg::Str(title.clone()), Arg::Str(user.clone())],
                ),
                message_label: t.t("Nachricht (optional)"),
                message: t.t("Die Wiedergabe wurde vom Administrator beendet."),
                action: t.t("Stoppen"),
            },
        }
    }

    fn load_view(&self, load: &ServerLoad) -> ServerLoadView {
        let meter = |label: &str, value: Option<f64>| {
            value.map(|v| ServerMeter {
                label: label.to_owned(),
                share: (v / 100.0).clamp(0.0, 1.0),
                text: Self::percent(v),
            })
        };
        let rate = |v: f64| format!("{}/s", size_text(v.round() as i64, self.sep));
        ServerLoadView {
            cpu: meter(&self.t.t("CPU"), load.cpu_percent),
            memory: meter(&self.t.t("RAM"), load.memory_percent),
            disk_io: load
                .disk_read
                .zip(load.disk_write)
                .map(|(r, w)| ServerDiskIo {
                    label: self.t.t("Festplatten"),
                    text: format!("↓ {} · ↑ {}", rate(r), rate(w)),
                }),
        }
    }

    fn disk_row(&self, disk: &ServerDisk) -> ServerDiskRow {
        let names: Vec<String> = disk
            .uses
            .iter()
            .map(|u| match u {
                DiskUse::Library(name) => name.clone(),
                DiskUse::Jellyfin => "Jellyfin".to_owned(),
                DiskUse::Transcoding => self.t.t("Transkodierung"),
            })
            .collect();
        ServerDiskRow {
            id: disk.id.clone(),
            title: names.join(", "),
            free_text: Self::percent(disk.free_share() * 100.0),
            free_share: disk.free_share(),
            nearly_full: disk.nearly_full(),
        }
    }

    fn card(&self, s: &ServerStream) -> ServerStreamCard {
        let t = &self.t;
        let mut badges = Vec::new();
        let mut push = |kind, text: String| badges.push(ServerBadge { kind, text });
        if let Some(v) = s.video_track() {
            if let Some(r) = ServerStream::resolution(v.width, v.height) {
                push(ServerBadgeKind::Resolution, r.to_owned());
            }
            if let Some(r) = ServerStream::range(v.range_type.as_deref()) {
                push(ServerBadgeKind::Range, r.to_owned());
            }
            if let Some(c) = codec_name_value(v.codec.as_deref()) {
                push(ServerBadgeKind::Video, c);
            }
        }
        if let Some(a) = s.audio_track()
            && let Some(c) = codec_name_value(a.codec.as_deref())
        {
            push(
                ServerBadgeKind::Audio,
                ServerStream::channels(a.channels)
                    .map_or_else(|| c.clone(), |ch| format!("{c} {ch}")),
            );
        }
        let method = s.delivery();
        let delivery_text = t.t(match method {
            DeliveryMethod::DirectPlay => "Direct Play",
            DeliveryMethod::DirectStream => "Direct Stream",
            DeliveryMethod::Transcode => "Transkodiert",
        });
        let delivery_line = match ServerStream::short_rate(s.bitrate()) {
            Some(rate) => format!("{delivery_text} · {rate}"),
            None => delivery_text.clone(),
        };
        let now = ServerStream::clock(
            s.position(),
            s.runtime().unwrap_or_else(|| s.position()) >= 3600.0,
        );
        let time_line = match s.runtime() {
            Some(r) => format!("{now} / {}", ServerStream::clock(r, r >= 3600.0)),
            None => now,
        };
        let (poster_id, poster_tag) = s.poster();
        ServerStreamCard {
            id: s.id(),
            session_id: s.session_id.clone(),
            user_name: s.user_name.clone(),
            user_id: s.user_id.clone(),
            user_image_tag: s.user_image_tag.clone(),
            title: s.title(),
            addition: s.addition().map(|a| match a {
                TitleAddition::Year(y) => y.to_string(),
                TitleAddition::Episode { season, episode } => {
                    t.t_args("S%lld · F%lld", &[Arg::Int(season), Arg::Int(episode)])
                }
                TitleAddition::Artist(name) => name,
            }),
            subtitle: s.subtitle(),
            poster_id,
            poster_tag,
            square_poster: s.square_poster(),
            is_audio: s.is_audio(),
            badges,
            device_line: [
                s.device.as_str(),
                s.client.as_str(),
                s.address.as_deref().unwrap_or(""),
            ]
            .iter()
            .filter(|p| !p.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join(" · "),
            share: s.share(),
            time_line,
            paused: s.paused,
            cautionary: method == DeliveryMethod::Transcode,
            delivery_text,
            delivery_line,
        }
    }
}

/// 1204 -> "1.204" (German), "1,204" (English), a narrow gap elsewhere.
fn group(n: i64, decimal: &str) -> String {
    let sep = if decimal == "." { "," } else { "." };
    let digits = n.unsigned_abs().to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push_str(sep);
        }
        out.push(c);
    }
    if n < 0 { format!("-{out}") } else { out }
}

// ------------------------------------------------------------------ the log files

/// One log file of the list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerLogRow {
    /// The file's name (for `ServerLogsIntent::Open`).
    pub name: String,
    /// "1,4 MB".
    pub size_text: String,
    /// The day of the last write, as the server wrote it ("2026-11-17").
    pub day: Option<String>,
}

/// The one state of the log screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerLogsState {
    /// The list or a file is being read.
    Loading,
    /// The files, newest first.
    Files {
        /// The rows.
        rows: Vec<ServerLogRow>,
    },
    /// The server has no log files.
    Empty {
        /// "Der Server hat keine Logdateien.".
        hint: String,
    },
    /// The end of one file.
    Text {
        /// The file.
        name: String,
        /// The last part of it, from a line start.
        text: String,
    },
    /// The read failed.
    Failed {
        /// Why.
        hint: String,
    },
}

/// What the log screen draws.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerLogsPart {
    /// Grows with every change.
    pub version: u64,
    /// "Protokoll", or the open file's name.
    pub title: String,
    /// The state.
    pub state: ServerLogsState,
}

/// What the host does with the log screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerLogsIntent {
    /// Read the list (also asks again after `Failed`).
    Load,
    /// Read the end of one file.
    Open {
        /// The file's name.
        name: String,
    },
    /// Back from a file to the list.
    Back,
}

struct LogsLive {
    generation: u64,
    rows: Vec<ServerLogRow>,
    part: Arc<ServerLogsPart>,
}

struct LogsInner<T: HttpTransport + 'static> {
    host: Host,
    client: Arc<Client<T>>,
    t: Translator,
    sep: &'static str,
    bell: Arc<Bell>,
    live: Mutex<LogsLive>,
}

/// The log files of the server, a list and one file at a time.
pub struct ServerLogsVm<T: HttpTransport + 'static> {
    inner: Arc<LogsInner<T>>,
}

impl<T: HttpTransport + 'static> Clone for ServerLogsVm<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl<T: HttpTransport + 'static> ServerLogsVm<T> {
    /// The log screen of `account`. Nothing is sent before `Load`.
    ///
    /// # Errors
    /// As [`ServerAdminVm::new`].
    pub fn new(transport: Arc<T>, host: Host, account: &AccountRef) -> Result<Self, ErrorKind> {
        if !server_admin_offered(account) {
            return Err(ErrorKind::InvalidServerUrl);
        }
        let client = Arc::new(build_client(&transport, &host, account)?);
        let t = Translator::new(host.locale.clone());
        let sep = decimal_separator(host.locale.language());
        let part = ServerLogsPart {
            version: 1,
            title: t.t("Protokoll"),
            state: ServerLogsState::Loading,
        };
        Ok(Self {
            inner: Arc::new(LogsInner {
                host,
                client,
                t,
                sep,
                bell: Bell::new(),
                live: Mutex::new(LogsLive {
                    generation: 0,
                    rows: Vec::new(),
                    part: Arc::new(part),
                }),
            }),
        })
    }

    /// The version; moves whenever the part changes.
    pub fn version(&self) -> u64 {
        self.inner.bell.version()
    }

    /// The screen state.
    pub fn part(&self) -> Arc<ServerLogsPart> {
        Arc::clone(&self.inner.live().part)
    }

    /// Waits until the part is newer than `seen`.
    pub fn changed(&self, seen: u64) -> Changed {
        self.inner.bell.changed(seen)
    }

    /// Observers currently parked in [`Self::changed`].
    pub fn waiters(&self) -> u32 {
        self.inner.bell.waiting()
    }

    /// An intent from the view. Never blocks; the state is `Loading` when it returns.
    pub fn send(&self, intent: ServerLogsIntent) {
        let me = &self.inner;
        match intent {
            ServerLogsIntent::Load => LogsInner::read_list(me),
            ServerLogsIntent::Open { name } => LogsInner::read_file(me, name),
            ServerLogsIntent::Back => {
                let mut live = me.live();
                if matches!(live.part.state, ServerLogsState::Text { .. }) {
                    live.generation += 1;
                    let state = if live.rows.is_empty() {
                        ServerLogsState::Empty {
                            hint: me.t.t("Der Server hat keine Logdateien."),
                        }
                    } else {
                        ServerLogsState::Files {
                            rows: live.rows.clone(),
                        }
                    };
                    me.put(&mut live, me.t.t("Protokoll"), state);
                }
            }
        }
    }
}

impl<T: HttpTransport + 'static> LogsInner<T> {
    fn live(&self) -> MutexGuard<'_, LogsLive> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn put(&self, live: &mut LogsLive, title: String, state: ServerLogsState) {
        let version = self.bell.bump(&[0]);
        live.part = Arc::new(ServerLogsPart {
            version,
            title,
            state,
        });
    }

    fn start(&self, title: String) -> u64 {
        let mut live = self.live();
        live.generation += 1;
        self.put(&mut live, title, ServerLogsState::Loading);
        live.generation
    }

    fn read_list(me: &Arc<Self>) {
        let generation = me.start(me.t.t("Protokoll"));
        let inner = Arc::clone(me);
        let lost = Arc::clone(me);
        me.host.spawn_guarded(
            Box::pin(async move {
                let answer = inner.client.log_files().await;
                inner.finish_list(generation, answer);
            }),
            move || lost.finish_list(generation, Err(ErrorKind::Decoding("lost".into()))),
        );
    }

    fn finish_list(&self, generation: u64, answer: Result<Vec<ServerLogFile>, ErrorKind>) {
        let mut live = self.live();
        if live.generation != generation {
            return;
        }
        let title = self.t.t("Protokoll");
        match answer {
            Err(e) => {
                let hint = swiftly_l10n::error_text::readable_error(&self.t, &e);
                self.put(&mut live, title, ServerLogsState::Failed { hint });
            }
            Ok(files) if files.is_empty() => {
                live.rows.clear();
                let hint = self.t.t("Der Server hat keine Logdateien.");
                self.put(&mut live, title, ServerLogsState::Empty { hint });
            }
            Ok(files) => {
                let rows: Vec<ServerLogRow> = files
                    .iter()
                    .map(|f| ServerLogRow {
                        name: f.name.clone(),
                        size_text: size_text(f.size, self.sep),
                        day: f
                            .modified
                            .as_deref()
                            .and_then(|d| d.get(..10))
                            .map(str::to_owned),
                    })
                    .collect();
                live.rows.clone_from(&rows);
                self.put(&mut live, title, ServerLogsState::Files { rows });
            }
        }
    }

    fn read_file(me: &Arc<Self>, name: String) {
        let generation = me.start(name.clone());
        let inner = Arc::clone(me);
        let lost = Arc::clone(me);
        let lost_name = name.clone();
        me.host.spawn_guarded(
            Box::pin(async move {
                let answer = inner.client.log_text(&name, LOG_LIMIT).await;
                inner.finish_file(generation, name, answer);
            }),
            move || {
                lost.finish_file(
                    generation,
                    lost_name,
                    Err(ErrorKind::Decoding("lost".into())),
                )
            },
        );
    }

    fn finish_file(&self, generation: u64, name: String, answer: Result<String, ErrorKind>) {
        let mut live = self.live();
        if live.generation != generation {
            return;
        }
        let state = match answer {
            Ok(text) => ServerLogsState::Text {
                name: name.clone(),
                text,
            },
            Err(e) => ServerLogsState::Failed {
                hint: swiftly_l10n::error_text::readable_error(&self.t, &e),
            },
        };
        self.put(&mut live, name, state);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thousands_are_grouped_by_language() {
        assert_eq!(group(1_204, ","), "1.204");
        assert_eq!(group(1_204_567, "."), "1,204,567");
        assert_eq!(group(12, ","), "12");
        assert_eq!(group(-1_000, ","), "-1.000");
    }
}
