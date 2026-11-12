//! The download manager as a pure state machine (port of the rules and persistence behaviour of
//! `Sources/Shared/DownloadManager.swift`, without its `URLSession` plumbing).
//!
//! [`DownloadManagerState::handle`] takes one [`Intent`] and returns the [`Effect`]s the platform
//! must run: start or cancel a transfer, write the list, delete a file, fetch an image. Nothing
//! in here reads a clock, a file or the network; times arrive in the intents. The platform feeds
//! the outcomes back as intents (progress, finished, failed, address ready ...).
//!
//! Saving happens once per intent: every change only marks the state dirty, and `handle` ends
//! with a single [`Effect::Persist`] (Swift: `secure()` coalesced to one write per pass).

use std::collections::{HashMap, HashSet};

use swiftly_model::{Item, UserItemData};
use swiftly_playback::sections::Segment;
use swiftly_rules::download_audio::AudioTrackRules;
use swiftly_rules::download_quality::DownloadQuality;

use crate::item::DownloadItem;
use crate::list::merge_for_write;
use crate::rules::{DownloadRules, NetworkVerdict, PADDING, SpaceInfo};
use crate::state::DownloadState;
use crate::task::{DownloadTask, TaskParts};

/// Failure reason when the server gave no address (`Keine Adresse vom Server.`). The German
/// source text is the catalog key, like everywhere in the core.
pub const REASON_NO_ADDRESS: &str = "Keine Adresse vom Server.";
/// Failure reason when the finished file could not be stored (`Die Datei liess sich nicht ablegen.`).
pub const REASON_NOT_STORED: &str = "Die Datei liess sich nicht ablegen.";
/// Failure reason when the device has too little space left to start the transfer.
pub const REASON_NOT_ENOUGH_SPACE: &str = "Nicht genug Speicherplatz.";

/// What the machine knows about the network.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NetworkInfo {
    /// Whether the path monitor has reported yet. Before that `wlan` is only the default and
    /// the tick waits (when "Wi-Fi only" is on).
    pub read: bool,
    /// Wi-Fi or cable.
    pub wlan: bool,
    /// No connection at all.
    pub none: bool,
}

/// A transfer the system still has from a previous run (`session.allTasks`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningTransfer {
    /// The transfer's description string ([`DownloadTask::description`]).
    pub description: Option<String>,
    /// It exists but is suspended; the platform resumes it when the machine adopts it.
    pub suspended: bool,
    /// Bytes it has received so far.
    pub bytes_received: i64,
}

/// Which kind of file a [`Effect::DeleteFile`] means. Names are relative to the downloads folder.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FileKind {
    /// The media file.
    Media,
    /// The folder of external subtitles next to it.
    Subtitles,
    /// A poster, landscape or header image.
    Image,
}

/// Something for the UI or the log; the machine does not need an answer.
#[derive(Debug, Clone, PartialEq)]
pub enum Report {
    /// A line for the log.
    Log(String),
    /// The network state changed (after the first report, only real changes).
    Network {
        /// Wi-Fi or cable.
        wlan: bool,
        /// No connection.
        none: bool,
    },
    /// A title failed; `reason` is a catalog key or the transport's readable text.
    Failed {
        /// Item id.
        id: String,
        /// Why.
        reason: String,
    },
    /// A title is on the device.
    Done {
        /// Item id.
        id: String,
    },
    /// `Add` with `check_space` did not fit; nothing was queued. The sheet offers the way out
    /// via watched titles (`dispensable`).
    NotEnoughSpace(SpaceInfo),
}

/// What goes in.
pub enum Intent {
    /// Sign in (or out with `account: None`). `stored` is the whole list of all accounts as read
    /// from disk ([`crate::list::load_list`]); `client` says whether a server client exists
    /// (without it nothing starts).
    SignIn {
        /// The user id, or `None` after sign-out.
        account: Option<String>,
        /// The list file's items, all accounts.
        stored: Vec<DownloadItem>,
        /// Whether addresses can be requested.
        client: bool,
    },
    /// Queue titles. `images` maps ids (and `kopf:<series id>` header keys) to image addresses.
    Add {
        /// The titles; ones already in the list are skipped.
        items: Vec<DownloadItem>,
        /// Image addresses to fetch along.
        images: HashMap<String, String>,
        /// Refuse the whole batch if it does not fit (with the reserve), as the sheet does.
        check_space: bool,
    },
    /// Pause a title.
    Halt(String),
    /// Resume a paused or failed title (it queues again).
    Resume(String),
    /// Remove titles with their files.
    Remove(Vec<String>),
    /// Pause everything without deleting anything (the toggle goes off).
    AllHalt,
    /// Remove everything.
    AllRemove,
    /// Run the tick (app start, anything that may have changed what is next).
    Tick,
    /// Progress from the transfer. `now` is seconds on any consistent clock.
    Progress {
        /// Which transfer.
        parts: TaskParts,
        /// Bytes on disk.
        loaded: i64,
        /// Bytes expected (0 if unknown).
        total: i64,
        /// Clock reading.
        now: f64,
    },
    /// The path monitor reported.
    NetworkChanged {
        /// Wi-Fi or cable.
        wlan: bool,
        /// No connection.
        none: bool,
    },
    /// The path monitor was stopped (the feature is switched off).
    NetworkObserveStopped,
    /// The "Wi-Fi only" setting changed.
    SetOnlyOverWlan(bool),
    /// The "load next episode" setting changed.
    SetNextAuto(bool),
    /// Free space measured (bytes, "important usage" capacity). `0` means unknown.
    SpaceChanged(i64),
    /// The server's address for a started title is here.
    AddressReady {
        /// Item id.
        id: String,
        /// The generation [`Effect::RequestAddress`] carried.
        generation: i64,
        /// The address to download from.
        address: String,
    },
    /// No address came.
    AddressFailed {
        /// Item id.
        id: String,
        /// The generation [`Effect::RequestAddress`] carried.
        generation: i64,
        /// Readable reason; [`REASON_NO_ADDRESS`] if the server gave none.
        reason: String,
    },
    /// A transfer finished. `worked` is whether the file could be moved into place;
    /// `real_size` is its size on disk (used for built files, which only know their size at the
    /// end).
    TransferFinished {
        /// Which transfer.
        parts: TaskParts,
        /// The file is in place.
        worked: bool,
        /// Size of the file on disk.
        real_size: Option<i64>,
    },
    /// A transfer failed or was cancelled. With resume data it counts as a pause, not an error.
    TransferFailed {
        /// Which transfer.
        parts: TaskParts,
        /// Readable reason.
        reason: String,
        /// Opaque resume data, if the platform got some.
        resume: Option<Vec<u8>>,
    },
    /// Resume data that arrived after [`Effect::CancelTransfer`] with `want_resume_data`.
    ResumeData {
        /// Item id.
        id: String,
        /// The `new_generation` of the cancel.
        generation: i64,
        /// The data.
        data: Vec<u8>,
    },
    /// The system's transfers from before the launch (answer to [`Effect::FindRunningTransfers`]).
    RunningTransfers(Vec<RunningTransfer>),
    /// A playback was recorded on this device, with or without network.
    PlaybackRemembered {
        /// Item id.
        id: String,
        /// Where it ended, in ticks.
        ticks: i64,
        /// Clock reading (Unix seconds).
        now: f64,
    },
    /// What the server says about the titles: `available` are the ids it answered with.
    ServerFollow {
        /// Ids the server knows.
        available: HashSet<String>,
        /// Watch states by id.
        watch_state: HashMap<String, UserItemData>,
    },
    /// Intro/credits fetched for a finished title.
    SectionsFetched {
        /// Item id.
        id: String,
        /// The segments (empty: the server knows none).
        sections: Vec<Segment>,
    },
    /// The subtitle files of a finished title are written (`ok`) or could not all be fetched;
    /// only `ok` lets the title count as finished, otherwise the next catch-up tries again.
    SubtitlesFetched {
        /// Item id.
        id: String,
        /// Every file and `info.json` are on the device.
        ok: bool,
    },
    /// Everything finished without stored segments asks again (and every title whose subtitle
    /// files are still open).
    SectionsCatchUp,
    /// Everything with a pending successor looks it up.
    SmartCatchUp,
    /// The series' episode list for a successor lookup (`None`: no answer, stays pending).
    SuccessorFound {
        /// The watched episode that asked.
        id: String,
        /// The series' episodes.
        episodes: Option<Vec<Item>>,
        /// Landscape image address of the next episode.
        image: Option<String>,
        /// Clock reading (Unix seconds), the new item's creation time.
        now: f64,
    },
}

/// What comes out: the platform runs these.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Write the whole list (all accounts) in one atomic write, in order.
    Persist(Vec<DownloadItem>),
    /// Ask the server for the download address of a started title, then answer with
    /// [`Intent::AddressReady`] or [`Intent::AddressFailed`].
    RequestAddress {
        /// Item id.
        id: String,
        /// Echo it back.
        generation: i64,
        /// `mediaSourceId`.
        source: Option<String>,
        /// Quality to ask for.
        quality: DownloadQuality,
        /// Audio stream index when the file is cut to one track.
        audio_index: Option<i64>,
    },
    /// Start a transfer. `parts.description()` goes into the transfer so callbacks find it.
    StartTransfer {
        /// Id, generation and file name.
        parts: TaskParts,
        /// Where from.
        address: String,
        /// Resume data from an earlier cancel.
        resume: Option<Vec<u8>>,
    },
    /// Cancel the transfer of `id` (the one with `task_generation`). If `want_resume_data`, send
    /// [`Intent::ResumeData`] tagged with `new_generation` when the data is there.
    CancelTransfer {
        /// Item id.
        id: String,
        /// The generation of the transfer to cancel.
        task_generation: Option<i64>,
        /// The generation now current for the title.
        new_generation: i64,
        /// Whether resume data should be kept.
        want_resume_data: bool,
    },
    /// Resume a suspended transfer that was adopted after a relaunch.
    ResumeTransfer {
        /// Item id.
        id: String,
    },
    /// Look up transfers the system kept from a previous run; answer with
    /// [`Intent::RunningTransfers`].
    FindRunningTransfers,
    /// Delete a file or folder in the downloads folder (missing is fine).
    DeleteFile {
        /// What it is.
        kind: FileKind,
        /// Name relative to the downloads folder.
        name: String,
    },
    /// Fetch an image into the downloads folder unless it exists.
    FetchImage {
        /// Target file name.
        name: String,
        /// Where from.
        url: String,
    },
    /// Fetch the external subtitles for a finished title; answer with
    /// [`Intent::SubtitlesFetched`] once they and `info.json` are written.
    FetchSubtitles {
        /// The finished item.
        item: Box<DownloadItem>,
    },
    /// Fetch intro/credits for a finished title; answer with [`Intent::SectionsFetched`].
    FetchSections {
        /// Item id.
        id: String,
    },
    /// Fetch the series' episodes; answer with [`Intent::SuccessorFound`].
    LookupSuccessor {
        /// The watched episode.
        id: String,
        /// Its series.
        series_id: String,
    },
    /// Measure free space; answer with [`Intent::SpaceChanged`].
    MeasureSpace,
    /// Something to show or log.
    Report(Report),
}

/// The running state of one title, kept apart from the list (Swift `DownloadProgress`).
#[derive(Debug, Clone, Copy)]
struct Live {
    loaded: i64,
    total: i64,
}

/// A started title waiting for its address.
struct PendingStart {
    generation: i64,
    resume: Option<Vec<u8>>,
}

/// The download manager's whole state.
pub struct DownloadManagerState {
    rules: Box<dyn AudioTrackRules + Send>,
    entries: Vec<DownloadItem>,
    /// Entries of the other accounts, kept for writing.
    others: Vec<DownloadItem>,
    account: Option<String>,
    client: bool,
    only_over_wlan: bool,
    next_auto: bool,
    network: NetworkInfo,
    free: i64,
    /// Item id of a running transfer.
    tasks: HashSet<String>,
    resume_data: HashMap<String, Vec<u8>>,
    generation: HashMap<String, i64>,
    generation_counter: i64,
    live: HashMap<String, Live>,
    reported: HashMap<String, (i64, f64)>,
    pending_start: HashMap<String, PendingStart>,
    searches_tasks: bool,
    successor_searches: HashSet<String>,
    dirty: bool,
}

impl DownloadManagerState {
    /// A fresh machine. `seed` starts the generation counter; use the clock in milliseconds so a
    /// number from an earlier process run cannot match again. `only_over_wlan` defaults to true
    /// in the app (`nurUeberWLAN`), `next_auto` to false (`naechsteFolgeLaden`).
    pub fn new(
        seed: i64,
        only_over_wlan: bool,
        next_auto: bool,
        rules: Box<dyn AudioTrackRules + Send>,
    ) -> Self {
        Self {
            rules,
            entries: Vec::new(),
            others: Vec::new(),
            account: None,
            client: false,
            only_over_wlan,
            next_auto,
            network: NetworkInfo {
                read: false,
                wlan: true,
                none: false,
            },
            free: 0,
            tasks: HashSet::new(),
            resume_data: HashMap::new(),
            generation: HashMap::new(),
            generation_counter: seed,
            live: HashMap::new(),
            reported: HashMap::new(),
            pending_start: HashMap::new(),
            searches_tasks: false,
            successor_searches: HashSet::new(),
            dirty: false,
        }
    }

    // MARK: Reading

    /// The list of the signed-in account, with the running progress merged in (`current`).
    pub fn entries(&self) -> Vec<DownloadItem> {
        self.entries.iter().map(|e| self.current(e)).collect()
    }

    /// One title with its running progress (`entries(for:)`).
    pub fn item(&self, id: &str) -> Option<DownloadItem> {
        self.entries
            .iter()
            .find(|e| e.id == id)
            .map(|e| self.current(e))
    }

    /// The file name of a finished title (the player asks the platform whether it exists).
    pub fn file_for(&self, id: &str) -> Option<String> {
        self.entries
            .iter()
            .find(|e| e.id == id && e.state == DownloadState::Done)
            .map(DownloadItem::file_name)
    }

    /// Last measured free space (0: unknown).
    pub fn free(&self) -> i64 {
        self.free
    }

    /// Whether Wi-Fi is currently available.
    pub fn wlan(&self) -> bool {
        self.network.wlan
    }

    /// No connection at all.
    pub fn no_network(&self) -> bool {
        self.network.none
    }

    /// The signed-in account.
    pub fn account(&self) -> Option<&str> {
        self.account.as_deref()
    }

    /// Whether a transfer runs for this title.
    pub fn is_running(&self, id: &str) -> bool {
        self.tasks.contains(id)
    }

    /// The current generation of a title.
    pub fn generation_of(&self, id: &str) -> Option<i64> {
        self.generation.get(id).copied()
    }

    /// What a download would cost, for the sheet before starting (`inquiry(for:)`).
    pub fn inquiry(&self, bytes: i64) -> SpaceInfo {
        DownloadRules::slot(bytes, self.free, &self.entries)
    }

    /// Under this key the series page hands the large header image to [`Intent::Add`].
    pub fn header_key(series_identifier: &str) -> String {
        format!("kopf:{series_identifier}")
    }

    /// An item with what is currently downloaded. Progress is not in the list.
    fn current(&self, p: &DownloadItem) -> DownloadItem {
        let Some(f) = self.live.get(&p.id) else {
            return p.clone();
        };
        let mut q = p.clone();
        q.loaded = f.loaded;
        if q.bytes == 0 {
            q.bytes = f.total;
        }
        q
    }

    // MARK: Handling

    /// Apply one intent; run the returned effects in order.
    pub fn handle(&mut self, intent: Intent) -> Vec<Effect> {
        let mut fx = Vec::new();
        self.dirty = false;
        match intent {
            Intent::SignIn {
                account,
                stored,
                client,
            } => {
                self.sign_in(account, stored, client, &mut fx);
            }
            Intent::Add {
                items,
                images,
                check_space,
            } => {
                self.add(items, &images, check_space, &mut fx);
            }
            Intent::Halt(id) => self.halt(&id, &mut fx),
            Intent::Resume(id) => self.resume(&id, &mut fx),
            Intent::Remove(ids) => self.remove(&ids, &mut fx),
            Intent::AllHalt => self.all_halt(&mut fx),
            Intent::AllRemove => {
                let ids: Vec<String> = self.entries.iter().map(|e| e.id.clone()).collect();
                self.remove(&ids, &mut fx);
            }
            Intent::Tick => self.tick(&mut fx),
            Intent::Progress {
                parts,
                loaded,
                total,
                now,
            } => self.progress(&parts, loaded, total, now),
            Intent::NetworkChanged { wlan, none } => self.network_status(wlan, none, &mut fx),
            Intent::NetworkObserveStopped => self.network.read = false,
            Intent::SetOnlyOverWlan(value) => {
                self.only_over_wlan = value;
                self.tick(&mut fx);
            }
            Intent::SetNextAuto(value) => self.next_auto = value,
            Intent::SpaceChanged(free) => self.free = free.max(0),
            Intent::AddressReady {
                id,
                generation,
                address,
            } => {
                self.task_start(&id, generation, address, &mut fx);
            }
            Intent::AddressFailed {
                id,
                generation,
                reason,
            } => {
                let file = self.file_name_of(&id);
                self.failed(&TaskParts::new(id, generation, file), reason, None, &mut fx);
            }
            Intent::TransferFinished {
                parts,
                worked,
                real_size,
            } => {
                self.completed(&parts, worked, real_size, &mut fx);
            }
            Intent::TransferFailed {
                parts,
                reason,
                resume,
            } => {
                self.failed(&parts, reason, resume, &mut fx);
            }
            Intent::ResumeData {
                id,
                generation,
                data,
            } => {
                if self.generation.get(&id) == Some(&generation) {
                    self.resume_data.insert(id, data);
                }
            }
            Intent::RunningTransfers(list) => self.adopt(&list, &mut fx),
            Intent::PlaybackRemembered { id, ticks, now } => {
                self.playback_remember(&id, ticks, now, &mut fx);
            }
            Intent::ServerFollow {
                available,
                watch_state,
            } => {
                self.follow(&available, &watch_state, &mut fx);
            }
            Intent::SectionsFetched { id, sections } => {
                if let Some(i) = self.index_of(&id) {
                    self.entries[i].sections = Some(sections);
                    self.secure();
                }
            }
            Intent::SubtitlesFetched { id, ok } => {
                if let Some(i) = self.index_of(&id)
                    && self.entries[i].state == DownloadState::Done
                    && self.entries[i].subtitles_pending
                    && ok
                {
                    self.entries[i].subtitles_pending = false;
                    fx.push(Effect::Report(Report::Done { id }));
                    self.secure();
                }
            }
            Intent::SectionsCatchUp => {
                for p in &self.entries {
                    if p.state == DownloadState::Done && p.subtitles_pending {
                        fx.push(Effect::FetchSubtitles {
                            item: Box::new(p.clone()),
                        });
                    }
                }
                for p in &self.entries {
                    if p.state == DownloadState::Done && p.sections.is_none() {
                        fx.push(Effect::FetchSections { id: p.id.clone() });
                    }
                }
            }
            Intent::SmartCatchUp => self.smart_catch_up(&mut fx),
            Intent::SuccessorFound {
                id,
                episodes,
                image,
                now,
            } => {
                self.successor_found(&id, episodes, image, now, &mut fx);
            }
        }
        if self.dirty {
            self.dirty = false;
            if let Some(account) = &self.account {
                let own: Vec<DownloadItem> = self.entries.iter().map(|e| self.current(e)).collect();
                fx.push(Effect::Persist(merge_for_write(
                    self.others.clone(),
                    account,
                    own,
                )));
            }
        }
        fx
    }

    fn index_of(&self, id: &str) -> Option<usize> {
        self.entries.iter().position(|e| e.id == id)
    }

    fn file_name_of(&self, id: &str) -> String {
        self.entries
            .iter()
            .find(|e| e.id == id)
            .map(DownloadItem::file_name)
            .unwrap_or_default()
    }

    /// Mark the list as changed; `handle` writes it once at the end.
    fn secure(&mut self) {
        if self.account.is_some() {
            self.dirty = true;
        }
    }

    fn new_generation(&mut self, id: &str) -> i64 {
        self.generation_counter += 1;
        self.generation
            .insert(id.to_owned(), self.generation_counter);
        self.generation_counter
    }

    // MARK: Account

    fn sign_in(
        &mut self,
        account: Option<String>,
        stored: Vec<DownloadItem>,
        client: bool,
        fx: &mut Vec<Effect>,
    ) {
        self.client = client;
        // What is queued goes out now, still under the old account.
        if self.account.is_some() && account != self.account {
            self.dirty = false;
            if let Some(old) = &self.account {
                let own: Vec<DownloadItem> = self.entries.iter().map(|e| self.current(e)).collect();
                fx.push(Effect::Persist(merge_for_write(
                    self.others.clone(),
                    old,
                    own,
                )));
            }
        }
        if account != self.account {
            self.release(fx);
        }
        self.account = account;
        self.load(stored);
        fx.push(Effect::MeasureSpace);
        // Set before the lookup answers: in between no other tick may start a title whose
        // transfer is about to be found again.
        if self.account.is_some() {
            self.searches_tasks = true;
            fx.push(Effect::FindRunningTransfers);
        } else {
            self.searches_tasks = false;
            self.tick(fx);
        }
    }

    /// Stop and forget everything that ran for the previous account.
    fn release(&mut self, fx: &mut Vec<Effect>) {
        let ids: Vec<String> = self.tasks.iter().cloned().collect();
        for id in ids {
            let old = self.generation.get(&id).copied();
            let new = self.new_generation(&id);
            fx.push(Effect::CancelTransfer {
                id,
                task_generation: old,
                new_generation: new,
                want_resume_data: false,
            });
        }
        self.tasks.clear();
        self.resume_data.clear();
        self.pending_start.clear();
        self.reported.clear();
        self.live.clear();
    }

    /// The list on disk holds the titles of all accounts; only the current one is shown. What was
    /// mid-download last time waits again, unless its transfer still runs in this process.
    fn load(&mut self, stored: Vec<DownloadItem>) {
        let Some(account) = &self.account else {
            self.entries.clear();
            self.others.clear();
            return;
        };
        let (own, others): (Vec<_>, Vec<_>) =
            stored.into_iter().partition(|e| &e.account == account);
        self.entries = own;
        self.others = others;
        for e in &mut self.entries {
            if e.state == DownloadState::Loads && !self.tasks.contains(&e.id) {
                e.state = DownloadState::Waits;
            }
        }
    }

    /// What kept running in the system belongs again.
    fn adopt(&mut self, list: &[RunningTransfer], fx: &mut Vec<Effect>) {
        if self.account.is_some() {
            for t in list {
                let Some(parts) = DownloadTask::dismantle(t.description.as_deref()) else {
                    continue;
                };
                if self.tasks.contains(&parts.id) {
                    continue;
                }
                let Some(i) = self.index_of(&parts.id).filter(|i| {
                    matches!(
                        self.entries[*i].state,
                        DownloadState::Waits | DownloadState::Loads
                    )
                }) else {
                    // Belongs to no waiting title of this account: paused, removed, or another
                    // account. Then it does not continue.
                    fx.push(Effect::CancelTransfer {
                        id: parts.id.clone(),
                        task_generation: Some(parts.generation),
                        new_generation: parts.generation,
                        want_resume_data: false,
                    });
                    continue;
                };
                self.generation.insert(parts.id.clone(), parts.generation);
                self.tasks.insert(parts.id.clone());
                self.entries[i].state = DownloadState::Loads;
                self.live.insert(
                    parts.id.clone(),
                    Live {
                        loaded: self.entries[i].loaded.max(t.bytes_received),
                        total: self.entries[i].bytes,
                    },
                );
                if t.suspended {
                    fx.push(Effect::ResumeTransfer {
                        id: parts.id.clone(),
                    });
                }
                fx.push(Effect::Report(Report::Log(format!(
                    "[Download] laufende Aufgabe uebernommen: {}",
                    parts.id
                ))));
            }
        }
        self.searches_tasks = false;
        self.tick(fx);
    }

    // MARK: Kicking off

    fn add(
        &mut self,
        items: Vec<DownloadItem>,
        images: &HashMap<String, String>,
        check_space: bool,
        fx: &mut Vec<Effect>,
    ) {
        let fresh: Vec<DownloadItem> =
            items
                .into_iter()
                .fold(Vec::new(), |mut acc: Vec<DownloadItem>, p| {
                    let known = self.entries.iter().any(|e| e.id == p.id)
                        || acc.iter().any(|e| e.id == p.id);
                    if !known {
                        acc.push(p);
                    }
                    acc
                });
        if check_space {
            let total: i64 = fresh.iter().map(|p| p.bytes).sum();
            let info = self.inquiry(total);
            if !info.suffices {
                fx.push(Effect::Report(Report::NotEnoughSpace(info)));
                return;
            }
        }
        for p in fresh {
            if let Some(url) = images.get(&p.id) {
                fx.push(Effect::FetchImage {
                    name: DownloadItem::image_name(&p.account, &p.id),
                    url: url.clone(),
                });
            }
            if let Some(sid) = &p.series_identifier {
                if let Some(url) = images.get(sid) {
                    fx.push(Effect::FetchImage {
                        name: DownloadItem::image_name(&p.account, sid),
                        url: url.clone(),
                    });
                }
                // The series' large header image, once per series (the platform skips existing).
                if let Some(url) = images.get(&Self::header_key(sid)) {
                    fx.push(Effect::FetchImage {
                        name: DownloadItem::image_name(&p.account, &format!("{sid}-kopf")),
                        url: url.clone(),
                    });
                }
            }
            self.entries.push(p);
        }
        self.secure();
        self.tick(fx);
    }

    // MARK: Pause, resume, remove

    /// Pausing is not an error: it advances the generation, so the cancellation the transfer
    /// reports afterwards carries the old one and is ignored.
    fn halt(&mut self, id: &str, fx: &mut Vec<Effect>) {
        let Some(i) = self.index_of(id) else { return };
        self.cancel_running(id, true, fx);
        self.state_let(i);
        self.entries[i].state = DownloadState::Halted;
        self.secure();
        self.tick(fx);
    }

    /// Like `halt`, but the title waits afterwards: the network change stopped it, not the pause
    /// button. Resume data is kept.
    fn put_back(&mut self, id: &str, fx: &mut Vec<Effect>) {
        let Some(i) = self.index_of(id) else { return };
        self.cancel_running(id, true, fx);
        self.state_let(i);
        self.entries[i].state = DownloadState::Waits;
        self.secure();
    }

    /// Advance the generation and cancel the title's transfer if one runs.
    fn cancel_running(&mut self, id: &str, want_resume_data: bool, fx: &mut Vec<Effect>) {
        let old = self.generation.get(id).copied();
        let new = self.new_generation(id);
        self.pending_start.remove(id);
        if self.tasks.remove(id) {
            fx.push(Effect::CancelTransfer {
                id: id.to_owned(),
                task_generation: old,
                new_generation: new,
                want_resume_data,
            });
        }
    }

    /// Move the running state into the item and stop tracking it separately.
    fn state_let(&mut self, i: usize) {
        let id = self.entries[i].id.clone();
        self.entries[i] = self.current(&self.entries[i]);
        self.live.remove(&id);
        self.reported.remove(&id);
    }

    fn resume(&mut self, id: &str, fx: &mut Vec<Effect>) {
        let Some(i) = self.index_of(id) else { return };
        self.entries[i].state = DownloadState::Waits;
        self.entries[i].reason = None;
        self.secure();
        self.tick(fx);
    }

    fn remove_without_save(&mut self, id: &str, fx: &mut Vec<Effect>) {
        self.cancel_running(id, false, fx);
        self.resume_data.remove(id);
        self.live.remove(id);
        self.reported.remove(id);
        if let Some(p) = self.entries.iter().find(|e| e.id == id) {
            let file = p.file_name();
            fx.push(Effect::DeleteFile {
                kind: FileKind::Subtitles,
                name: format!("{file}.untertitel"),
            });
            fx.push(Effect::DeleteFile {
                kind: FileKind::Media,
                name: file,
            });
            // Its own image always goes.
            fx.push(Effect::DeleteFile {
                kind: FileKind::Image,
                name: DownloadItem::image_name(&p.account, &p.id),
            });
            // All episodes share the series poster; it goes with the last one.
            if let Some(sid) = &p.series_identifier
                && !self
                    .entries
                    .iter()
                    .any(|e| e.id != id && e.series_identifier.as_ref() == Some(sid))
            {
                fx.push(Effect::DeleteFile {
                    kind: FileKind::Image,
                    name: DownloadItem::image_name(&p.account, sid),
                });
                fx.push(Effect::DeleteFile {
                    kind: FileKind::Image,
                    name: DownloadItem::image_name(&p.account, &format!("{sid}-kopf")),
                });
            }
        }
        self.entries.retain(|e| e.id != id);
    }

    /// Several at once: measure once, tick once, not per title.
    fn remove(&mut self, ids: &[String], fx: &mut Vec<Effect>) {
        for id in ids {
            self.remove_without_save(id, fx);
        }
        self.secure();
        fx.push(Effect::MeasureSpace);
        self.tick(fx);
    }

    /// Pause everything without deleting anything. What is on disk stays; what was running
    /// waits. Iterates over the list as it was when the call began, like Swift.
    fn all_halt(&mut self, fx: &mut Vec<Effect>) {
        let ids: Vec<String> = self
            .entries
            .iter()
            .filter(|p| matches!(p.state, DownloadState::Loads | DownloadState::Waits))
            .map(|p| p.id.clone())
            .collect();
        for id in ids {
            self.halt(&id, fx);
        }
    }

    // MARK: The tick

    /// The single place where a download starts. Called after every change: queued, paused,
    /// finished, network change, app start. `DownloadRules::next_one` is the only decision about
    /// who is next.
    fn tick(&mut self, fx: &mut Vec<Effect>) {
        if self.searches_tasks {
            return;
        }
        let known = self.network.read.then_some(self.network.wlan);
        match DownloadRules::network_verdict(known, self.only_over_wlan) {
            NetworkVerdict::Load => {}
            // The path monitor's first update is still pending: start nothing, stop nothing.
            NetworkVerdict::WaitFor => return,
            NetworkVerdict::PutBack => {
                // No Wi-Fi with Wi-Fi-only set: what runs goes back to the queue ("waiting", not
                // paused: nobody would pick a paused item up again on Wi-Fi).
                let running: Vec<String> = self
                    .entries
                    .iter()
                    .filter(|p| p.state == DownloadState::Loads)
                    .map(|p| p.id.clone())
                    .collect();
                for id in running {
                    self.put_back(&id, fx);
                }
                return;
            }
        }
        // A start that fails at once (too little space) may leave the next one to try.
        loop {
            let Some(next) =
                DownloadRules::next_one(&self.entries, self.network.wlan, self.only_over_wlan)
            else {
                return;
            };
            let id = next.id.clone();
            if !self.start(&id, fx) {
                return;
            }
            if self.entries.iter().any(|e| e.state == DownloadState::Loads) {
                return;
            }
        }
    }

    /// Returns false if nothing could start (no client / unknown id).
    fn start(&mut self, id: &str, fx: &mut Vec<Effect>) -> bool {
        let Some(i) = self.index_of(id) else {
            return false;
        };
        if !self.client {
            return false;
        }

        // Addition to the Swift behaviour: with a measured free space, a title that would leave
        // less than the reserve free fails at once with a reason instead of filling the disk.
        let remaining = (self.entries[i].bytes - self.entries[i].loaded).max(0);
        if self.free > 0 && remaining > 0 && self.free - remaining < PADDING {
            self.entries[i].state = DownloadState::Error;
            self.entries[i].reason = Some(REASON_NOT_ENOUGH_SPACE.to_owned());
            self.secure();
            fx.push(Effect::Report(Report::Failed {
                id: id.to_owned(),
                reason: REASON_NOT_ENOUGH_SPACE.to_owned(),
            }));
            return true;
        }

        // State is set before the address comes, not after: a second tick in between must see a
        // running download and not start the same title again.
        self.entries[i].state = DownloadState::Loads;
        self.entries[i].reason = None;
        self.secure();
        let now = self.new_generation(id);

        let resume = self.resume_data.remove(id);
        // A built file starts from scratch (converted, or cut down to one audio track): the
        // server accepts no range requests, so what was downloaded before no longer counts.
        if resume.is_none() && self.entries[i].streamed() {
            self.entries[i].loaded = 0;
        }
        self.live.insert(
            id.to_owned(),
            Live {
                loaded: self.entries[i].loaded,
                total: self.entries[i].bytes,
            },
        );
        self.pending_start.insert(
            id.to_owned(),
            PendingStart {
                generation: now,
                resume,
            },
        );
        fx.push(Effect::RequestAddress {
            id: id.to_owned(),
            generation: now,
            source: self.entries[i].source.clone(),
            quality: self.entries[i].guete(),
            audio_index: self.entries[i].audio_index,
        });
        true
    }

    fn task_start(&mut self, id: &str, generation: i64, address: String, fx: &mut Vec<Effect>) {
        // In the meantime the item may have been removed or paused; then nothing starts. And not
        // twice: whoever paused and resumed while waiting has a newer generation.
        if self.generation.get(id) != Some(&generation) {
            return;
        }
        let Some(i) = self
            .index_of(id)
            .filter(|i| self.entries[*i].state == DownloadState::Loads)
        else {
            return;
        };
        let resume = match self.pending_start.remove(id) {
            Some(p) if p.generation == generation => p.resume,
            _ => None,
        };
        self.tasks.insert(id.to_owned());
        fx.push(Effect::StartTransfer {
            parts: TaskParts::new(id, generation, self.entries[i].file_name()),
            address,
            resume,
        });
    }

    // MARK: Callbacks from the transfer

    fn applies(&self, t: &TaskParts) -> bool {
        DownloadTask::applies(t.generation, self.generation.get(&t.id).copied())
    }

    fn progress(&mut self, t: &TaskParts, loaded: i64, total: i64, now: f64) {
        if !self.applies(t) {
            return;
        }
        let id = &t.id;
        let Some(i) = self.index_of(id) else { return };
        // Not every callback is a visible change: at most once per second.
        let shown = DownloadRules::progress_show(
            loaded,
            if total > 0 {
                total
            } else {
                self.entries[i].bytes
            },
            self.reported.get(id).map(|r| r.0),
            self.reported.get(id).map(|r| now - r.1),
        );
        if !shown {
            return;
        }
        self.reported.insert(id.clone(), (loaded, now));
        // If the server gives no size in the catalog, the bar takes the one from the response.
        // Not saved: that would be a write per progress update.
        let new_total = if self.entries[i].bytes == 0 && total > 0 {
            total
        } else {
            self.entries[i].bytes
        };
        match self.live.get_mut(id) {
            Some(f) => {
                f.loaded = loaded;
                if f.total != new_total {
                    f.total = new_total;
                }
            }
            None => {
                self.live.insert(
                    id.clone(),
                    Live {
                        loaded,
                        total: new_total,
                    },
                );
            }
        }
    }

    fn completed(
        &mut self,
        t: &TaskParts,
        worked: bool,
        real_size: Option<i64>,
        fx: &mut Vec<Effect>,
    ) {
        if !self.applies(t) {
            return;
        }
        let id = t.id.clone();
        self.tasks.remove(&id);
        let Some(i) = self.index_of(&id) else {
            self.live.remove(&id);
            self.reported.remove(&id);
            return;
        };
        self.state_let(i);
        // A file of zero bytes is a failure, never "done" (Streamyfin #2077: some servers answer 200 with
        // an empty body); only a measured size can tell, an unmeasured one stays as reported.
        let worked = worked && real_size != Some(0);
        if worked {
            self.entries[i].state = DownloadState::Done;
            // The estimate yields to the real size once the built file exists.
            if self.entries[i].streamed()
                && let Some(real) = real_size.filter(|r| *r > 0)
            {
                self.entries[i].bytes = real;
            }
            self.entries[i].loaded = self.entries[i].bytes;
            self.entries[i].subtitles_pending = true;
            fx.push(Effect::FetchSubtitles {
                item: Box::new(self.entries[i].clone()),
            });
            fx.push(Effect::FetchSections { id: id.clone() });
            // `Report::Done` follows with `Intent::SubtitlesFetched`.
            // The watched episode goes only now, with its successor safely on the device.
            let replaced = if self.next_auto {
                DownloadRules::replaced_one(&self.entries[i], &self.entries)
            } else {
                None
            };
            self.entries[i].replaces = None;
            if let Some(old) = replaced {
                self.remove_without_save(&old, fx);
            }
        } else {
            self.entries[i].state = DownloadState::Error;
            self.entries[i].reason = Some(REASON_NOT_STORED.to_owned());
            fx.push(Effect::Report(Report::Failed {
                id: id.clone(),
                reason: REASON_NOT_STORED.to_owned(),
            }));
        }
        self.secure();
        fx.push(Effect::MeasureSpace);
        self.tick(fx);
    }

    /// Whoever paused does not see an error: the cancellation arrives as an error, but pausing
    /// advanced the generation and the report carries the old one.
    fn failed(
        &mut self,
        t: &TaskParts,
        reason: String,
        resume: Option<Vec<u8>>,
        fx: &mut Vec<Effect>,
    ) {
        if !self.applies(t) {
            return;
        }
        let id = t.id.clone();
        self.tasks.remove(&id);
        self.pending_start.remove(&id);
        let has_resume = resume.is_some();
        if let Some(data) = resume {
            self.resume_data.insert(id.clone(), data);
        }
        let Some(i) = self.index_of(&id) else { return };
        self.state_let(i);
        // A cancelled download with resume data is not an error but a pause, usually a network
        // change.
        if has_resume {
            self.entries[i].state = DownloadState::Halted;
            self.entries[i].reason = None;
        } else {
            self.entries[i].state = DownloadState::Error;
            self.entries[i].reason = Some(reason.clone());
            fx.push(Effect::Report(Report::Failed {
                id: id.clone(),
                reason,
            }));
        }
        self.secure();
        self.tick(fx);
    }

    // MARK: Network

    fn network_status(&mut self, wlan: bool, none: bool, fx: &mut Vec<Effect>) {
        let first = !self.network.read;
        self.network.read = true;
        if !(first || wlan != self.network.wlan || none != self.network.none) {
            return;
        }
        self.network.wlan = wlan;
        self.network.none = none;
        fx.push(Effect::Report(Report::Network { wlan, none }));
        // The tick stops or continues, depending on what applies now.
        self.tick(fx);
    }

    // MARK: Server state

    fn on_server(&mut self, id: &str, on: bool) {
        let Some(i) = self.index_of(id) else { return };
        if self.entries[i].still_on_the_server == on {
            return;
        }
        self.entries[i].still_on_the_server = on;
        self.secure();
    }

    fn watch_state(&mut self, id: &str, state: Option<&UserItemData>) {
        let Some(i) = self.index_of(id) else { return };
        let new = DownloadRules::follow(&self.entries[i], state);
        if new == self.entries[i] {
            return;
        }
        self.entries[i] = new;
        self.secure();
    }

    /// Pull in what the server says in one go. What comes in is explicitly answered, not
    /// queried: someone offline gets no answer, and the caller keeps those apart.
    fn follow(
        &mut self,
        available: &HashSet<String>,
        watch_state: &HashMap<String, UserItemData>,
        fx: &mut Vec<Effect>,
    ) {
        let ids: Vec<String> = self.entries.iter().map(|e| e.id.clone()).collect();
        for id in ids {
            if available.contains(&id) {
                self.watch_state(&id, watch_state.get(&id));
            }
            self.on_server(&id, available.contains(&id));
        }
        self.smart_catch_up(fx);
    }

    // MARK: Next episode

    fn playback_remember(&mut self, id: &str, ticks: i64, now: f64, fx: &mut Vec<Effect>) {
        let Some(i) = self.index_of(id) else { return };
        self.entries[i] = self.entries[i].post_playback(ticks, now);
        // Watched to the end: the next episode is due. Marked first, so a lookup that finds no
        // server is repeated on the next contact.
        if self.next_auto
            && DownloadRules::has_successor(&self.entries[i])
            && DownloadRules::reached_end(ticks, self.entries[i].runtime_ticks)
        {
            self.entries[i].next_pending = Some(true);
            self.smart_next(id, fx);
        }
        self.secure();
    }

    /// Queue the successor of a watched, downloaded episode. Wi-Fi-only needs no extra code: the
    /// entry joins the queue like any other and the tick holds it back.
    fn smart_next(&mut self, id: &str, fx: &mut Vec<Effect>) {
        if !self.next_auto || !self.client || self.successor_searches.contains(id) {
            return;
        }
        let Some(watched) = self.entries.iter().find(|e| e.id == id) else {
            return;
        };
        if watched.next_pending != Some(true) || !DownloadRules::has_successor(watched) {
            return;
        }
        let Some(series_id) = watched.series_identifier.clone() else {
            return;
        };
        self.successor_searches.insert(id.to_owned());
        fx.push(Effect::LookupSuccessor {
            id: id.to_owned(),
            series_id,
        });
    }

    fn smart_catch_up(&mut self, fx: &mut Vec<Effect>) {
        let ids: Vec<String> = self
            .entries
            .iter()
            .filter(|p| p.next_pending == Some(true))
            .map(|p| p.id.clone())
            .collect();
        for id in ids {
            self.smart_next(&id, fx);
        }
    }

    fn successor_found(
        &mut self,
        id: &str,
        episodes: Option<Vec<Item>>,
        image: Option<String>,
        now: f64,
        fx: &mut Vec<Effect>,
    ) {
        self.successor_searches.remove(id);
        // No answer (offline): stays pending.
        let (Some(all), Some(i)) = (episodes, self.index_of(id)) else {
            return;
        };
        let current = self.entries[i].clone();
        self.entries[i].next_pending = None;
        self.secure();
        // After the last episode the watched one simply stays. An episode already on the device
        // or in the queue is not loaded again.
        let Some(next) = DownloadRules::following_episode(&current, &all) else {
            return;
        };
        if self.entries.iter().any(|e| e.id == next.id) {
            return;
        }
        let follower = DownloadRules::follow_up(self.rules.as_ref(), &current, next, now);
        if !self.inquiry(follower.bytes).suffices {
            return;
        }
        let mut images = HashMap::new();
        if let Some(url) = image {
            images.insert(next.id.clone(), url);
        }
        self.add(vec![follower], &images, false, fx);
        fx.push(Effect::Report(Report::Log(format!(
            "[Download] naechste Folge {} nach {id}",
            next.id
        ))));
    }
}
