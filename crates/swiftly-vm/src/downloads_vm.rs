//! `DownloadsVm`: the download list as parts and intents (`DownloadsView.swift`,
//! `DownloadManager.swift`), on top of the pure state machine of `swiftly-downloads`.
//!
//! The view model owns the [`DownloadManagerState`]. Intents go in, the machine's effects are
//! run: transfers through the platform's [`DownloadTransport`], everything else (persisting the
//! list, deleting files, fetching an address) through [`DownloadServices`]. What those answer
//! comes back as [`DownloadsIntent::Engine`] or [`DownloadsIntent::Transfer`]. Parts are
//! display-ready: sizes and progress are already text in the user's locale.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_downloads::{
    DownloadGroup, DownloadItem, DownloadManagerState, DownloadRules, DownloadState,
    DownloadTransport, Effect, Intent, TransferEvent, apply_effect,
};
use swiftly_l10n::{Arg, Locale, Translator};

use crate::bell::{Bell, Changed};

/// Part bits of the downloads view model.
pub mod downloads_part {
    /// The list of rows.
    pub const LIST: u32 = 1;
    /// The storage summary and network state.
    pub const STORAGE: u32 = 2;
}

/// The decimal separator for sizes in a language (the unit names stay Latin).
pub fn decimal_separator(language: &str) -> &'static str {
    match language {
        "en" | "ja" | "zh" | "ko" | "th" | "he" | "hi" | "ms" | "id" => ".",
        _ => ",",
    }
}

/// "18,6 GB" (thousands steps, like Finder).
pub(crate) fn size_text(bytes: i64, separator: &str) -> String {
    DownloadRules::size(bytes, separator)
}

/// What a platform does for the effects that are not a transfer: persist the list, delete
/// files, fetch images and addresses, measure space, report. The host answers through
/// [`DownloadsVm::send`].
pub trait DownloadServices: Send + Sync {
    /// Run one effect.
    fn run(&self, effect: &Effect);
}

/// The state of a row, as the view draws it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowState {
    /// In the queue.
    Waiting,
    /// Loading now.
    Loading,
    /// Paused.
    Paused,
    /// On the device.
    Done,
    /// Failed.
    Failed,
}

impl From<DownloadState> for RowState {
    fn from(s: DownloadState) -> Self {
        match s {
            DownloadState::Waits => Self::Waiting,
            DownloadState::Loads => Self::Loading,
            DownloadState::Halted => Self::Paused,
            DownloadState::Done => Self::Done,
            DownloadState::Error => Self::Failed,
        }
    }
}

/// One title (a movie or an episode).
#[derive(Debug, Clone, PartialEq)]
pub struct ItemRow {
    /// Item id.
    pub id: String,
    /// Title.
    pub title: String,
    /// Season number of an episode.
    pub season: Option<i64>,
    /// Episode number.
    pub episode: Option<i64>,
    /// State.
    pub state: RowState,
    /// 0 to 1; `None` if the server stated no size.
    pub progress: Option<f32>,
    /// The size in words ("845 MB"); empty while unknown.
    pub size: String,
    /// "0,84 von 2,31 GB" while it loads or is paused part-way.
    pub progress_text: Option<String>,
    /// Why it failed (a catalog key or readable text, already translated if known).
    pub reason: Option<String>,
    /// Watched.
    pub watched: bool,
    /// Pause is possible (waiting or loading).
    pub can_pause: bool,
    /// Resume is possible (paused or failed).
    pub can_resume: bool,
    /// Cancel is possible (anything not finished).
    pub can_cancel: bool,
    /// Delete is possible (finished).
    pub can_delete: bool,
}

/// A row of the list: a movie, or a series with all its downloaded episodes.
#[derive(Debug, Clone, PartialEq)]
pub struct DownloadRow {
    /// Item id, or `serie-<series id>`.
    pub id: String,
    /// Title (the series name for a series).
    pub title: String,
    /// "3 Folgen" for a series.
    pub subtitle: Option<String>,
    /// The state of the row (a series: the most active of its episodes).
    pub state: RowState,
    /// 0 to 1 over all its bytes.
    pub progress: Option<f32>,
    /// Total size in words.
    pub size: String,
    /// The titles: one for a movie, the episodes for a series.
    pub items: Vec<ItemRow>,
}

/// The list.
#[derive(Debug, Clone, PartialEq)]
pub struct ListPart {
    /// Version of the view model when the part was replaced.
    pub version: u64,
    /// Newest first.
    pub rows: Vec<DownloadRow>,
}

/// How much is stored and what the network allows.
#[derive(Debug, Clone, PartialEq)]
pub struct StoragePart {
    /// Version of the view model when the part was replaced.
    pub version: u64,
    /// Finished titles.
    pub count: u32,
    /// Bytes of the finished titles.
    pub bytes: i64,
    /// "42,8 GB".
    pub size: String,
    /// "12 Titel auf diesem Gerät".
    pub summary: String,
    /// Free space on the device in words, empty while unknown.
    pub free: String,
    /// Titles queued or loading.
    pub active: u32,
    /// Downloads are set to Wi-Fi only.
    pub only_over_wlan: bool,
    /// Queued titles wait because there is no Wi-Fi.
    pub waiting_for_wlan: bool,
    /// No connection at all.
    pub offline: bool,
}

/// What the view and the host send.
pub enum DownloadsIntent {
    /// Queue titles (`images` maps ids to image addresses).
    Start {
        /// The titles.
        items: Vec<DownloadItem>,
        /// Image addresses to fetch along.
        images: HashMap<String, String>,
        /// Refuse the whole batch if it does not fit.
        check_space: bool,
    },
    /// Pause a waiting or loading title.
    Pause(String),
    /// Resume a paused or failed title.
    Resume(String),
    /// Cancel a title that is not finished; its files go.
    Cancel(String),
    /// Delete finished titles.
    Delete(Vec<String>),
    /// Pause everything (the toggle went off).
    PauseAll,
    /// Remove everything.
    DeleteAll,
    /// Change the Wi-Fi rule.
    OnlyOverWlan(bool),
    /// Change "download the next episode".
    NextAuto(bool),
    /// The transfer layer reports.
    Transfer(TransferEvent),
    /// Any other input of the state machine (sign-in, answers of the services, network).
    Engine(Box<Intent>),
}

/// Why an intent was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DownloadsRejected {
    /// No such title in the list.
    UnknownItem,
    /// The title is in a state the intent does not fit.
    WrongState,
}

struct Live {
    manager: DownloadManagerState,
    only_over_wlan: bool,
    list: Arc<ListPart>,
    storage: Arc<StoragePart>,
}

struct Inner<T: DownloadTransport> {
    transport: Arc<T>,
    services: Arc<dyn DownloadServices>,
    translator: Translator,
    separator: &'static str,
    bell: Arc<Bell>,
    live: Mutex<Live>,
}

/// The downloads view model. Cheap to clone (a handle).
pub struct DownloadsVm<T: DownloadTransport + 'static> {
    inner: Arc<Inner<T>>,
}

impl<T: DownloadTransport + 'static> Clone for DownloadsVm<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl<T: DownloadTransport + 'static> DownloadsVm<T> {
    /// A view model over a machine. Feed it [`Intent::SignIn`] through
    /// [`DownloadsIntent::Engine`] to load the list.
    pub fn new(
        transport: Arc<T>,
        services: Arc<dyn DownloadServices>,
        locale: Locale,
        manager: DownloadManagerState,
        only_over_wlan: bool,
    ) -> Self {
        let separator = decimal_separator(locale.language());
        let inner = Arc::new(Inner {
            transport,
            services,
            translator: Translator::new(locale),
            separator,
            bell: Bell::new(),
            live: Mutex::new(Live {
                manager,
                only_over_wlan,
                list: Arc::new(ListPart {
                    version: 1,
                    rows: Vec::new(),
                }),
                storage: Arc::new(StoragePart {
                    version: 1,
                    count: 0,
                    bytes: 0,
                    size: String::new(),
                    summary: String::new(),
                    free: String::new(),
                    active: 0,
                    only_over_wlan,
                    waiting_for_wlan: false,
                    offline: false,
                }),
            }),
        });
        {
            let mut live = inner.live();
            inner.publish(&mut live);
        }
        Self { inner }
    }

    /// The version; moves whenever a part is replaced.
    pub fn version(&self) -> u64 {
        self.inner.bell.version()
    }

    /// The list.
    pub fn list(&self) -> Arc<ListPart> {
        Arc::clone(&self.inner.live().list)
    }

    /// The storage summary.
    pub fn storage(&self) -> Arc<StoragePart> {
        Arc::clone(&self.inner.live().storage)
    }

    /// The signed-in account's titles with the running progress merged in (the screens that
    /// need the whole item: the player, the series page, the selection sheet).
    pub fn entries(&self) -> Vec<DownloadItem> {
        self.inner.live().manager.entries()
    }

    /// Offline playback the server has not seen: one report per finished title of `account` whose local
    /// position is newer than the server's state in `states` (by id). The host records them through the
    /// pending-report store and `pending_submit` sends them (newer wins, checked again there).
    pub fn unreported_progress(
        &self,
        account: &str,
        states: &HashMap<String, swiftly_model::UserItemData>,
    ) -> Vec<swiftly_jellyfin::PendingReport> {
        let mut out: Vec<_> = self
            .entries()
            .iter()
            .filter(|e| e.account == account)
            .filter_map(|e| {
                let (ticks, moment) = DownloadRules::unreported_progress(e, states.get(&e.id))?;
                Some(swiftly_jellyfin::PendingReport::new(
                    &e.id, account, ticks, moment,
                ))
            })
            .collect();
        out.sort_by(|a, b| a.moment.total_cmp(&b.moment));
        out
    }

    /// One title with its running progress.
    pub fn item(&self, id: &str) -> Option<DownloadItem> {
        self.inner.live().manager.item(id)
    }

    /// The file name of a finished title, or `None` while it is not done.
    pub fn file_for(&self, id: &str) -> Option<String> {
        self.inner.live().manager.file_for(id)
    }

    /// What a download of `bytes` would cost against the last measured free space.
    pub fn inquiry(&self, bytes: i64) -> swiftly_downloads::SpaceInfo {
        self.inner.live().manager.inquiry(bytes)
    }

    /// Resolves when the version moves past `seen`.
    pub fn changed(&self, seen: u64) -> Changed {
        self.inner.bell.changed(seen)
    }

    /// The whole queue as one state (empty, running, ready, offline, paused, idle) for the
    /// given network; replaces the host's `wLAN` / `noNetwork` / `networkRead` flags.
    pub fn queue_phase(
        &self,
        network: swiftly_downloads::Network,
        only_wifi: bool,
    ) -> swiftly_downloads::QueuePhase {
        let phases: Vec<_> = self
            .inner
            .live()
            .manager
            .entries()
            .iter()
            .map(|e| swiftly_downloads::ItemPhase::restored_running(e.state))
            .collect();
        swiftly_downloads::QueuePhase::of(&phases, network, only_wifi)
    }

    /// Whether anyone waits on [`Self::changed`].
    pub fn waiters(&self) -> u32 {
        self.inner.bell.waiting()
    }

    /// An intent from the view or the host. Effects run after the state is updated and the
    /// lock is released, so a service may answer at once.
    ///
    /// # Errors
    /// [`DownloadsRejected`] when the title is unknown or in the wrong state; nothing changes.
    pub fn send(&self, intent: DownloadsIntent) -> Result<(), DownloadsRejected> {
        let inner = &self.inner;
        let effects = {
            let mut live = inner.live();
            let engine = inner.translate(&mut live, intent)?;
            let effects = engine
                .into_iter()
                .flat_map(|i| live.manager.handle(i))
                .collect::<Vec<_>>();
            inner.publish(&mut live);
            effects
        };
        for effect in &effects {
            if !apply_effect(&*inner.transport, effect) {
                inner.services.run(effect);
            }
        }
        Ok(())
    }
}

impl<T: DownloadTransport + 'static> Inner<T> {
    fn live(&self) -> MutexGuard<'_, Live> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Checks an intent against the list and turns it into machine input.
    fn translate(
        &self,
        live: &mut Live,
        intent: DownloadsIntent,
    ) -> Result<Vec<Intent>, DownloadsRejected> {
        let state_of = |live: &Live, id: &str| {
            live.manager
                .item(id)
                .map(|i| i.state)
                .ok_or(DownloadsRejected::UnknownItem)
        };
        Ok(match intent {
            DownloadsIntent::Start {
                items,
                images,
                check_space,
            } => vec![Intent::Add {
                items,
                images,
                check_space,
            }],
            DownloadsIntent::Pause(id) => {
                match state_of(live, &id)? {
                    DownloadState::Waits | DownloadState::Loads => {}
                    _ => return Err(DownloadsRejected::WrongState),
                }
                vec![Intent::Halt(id)]
            }
            DownloadsIntent::Resume(id) => {
                match state_of(live, &id)? {
                    DownloadState::Halted | DownloadState::Error => {}
                    _ => return Err(DownloadsRejected::WrongState),
                }
                vec![Intent::Resume(id)]
            }
            DownloadsIntent::Cancel(id) => {
                if state_of(live, &id)? == DownloadState::Done {
                    return Err(DownloadsRejected::WrongState);
                }
                vec![Intent::Remove(vec![id])]
            }
            DownloadsIntent::Delete(ids) => {
                for id in &ids {
                    if state_of(live, id)? != DownloadState::Done {
                        return Err(DownloadsRejected::WrongState);
                    }
                }
                vec![Intent::Remove(ids)]
            }
            DownloadsIntent::PauseAll => vec![Intent::AllHalt],
            DownloadsIntent::DeleteAll => vec![Intent::AllRemove],
            DownloadsIntent::OnlyOverWlan(on) => {
                live.only_over_wlan = on;
                vec![Intent::SetOnlyOverWlan(on)]
            }
            DownloadsIntent::NextAuto(on) => vec![Intent::SetNextAuto(on)],
            DownloadsIntent::Transfer(event) => vec![event.into_intent()],
            DownloadsIntent::Engine(intent) => {
                if let Intent::SetOnlyOverWlan(on) = *intent {
                    live.only_over_wlan = on;
                }
                vec![*intent]
            }
        })
    }

    fn reason_text(&self, reason: &str) -> String {
        // The machine's reasons are catalog keys or the transport's readable text.
        self.translator.t(reason)
    }

    fn item_row(&self, item: &DownloadItem) -> ItemRow {
        let state = item.state;
        let progress_text = (matches!(state, DownloadState::Loads | DownloadState::Halted)
            && item.bytes > 0
            && item.loaded > 0)
            .then(|| {
                let (done, total) =
                    DownloadRules::progress(item.loaded, item.bytes, self.separator);
                self.translator
                    .t_args("%@ von %@", &[Arg::Str(done), Arg::Str(total)])
            });
        ItemRow {
            id: item.id.clone(),
            title: item.title.clone(),
            season: item.season,
            episode: item.episode,
            state: if item.subtitles_pending && state == DownloadState::Done {
                RowState::Loading
            } else {
                state.into()
            },
            progress: item.share().map(|s| s as f32),
            size: if item.bytes > 0 {
                size_text(item.bytes, self.separator)
            } else {
                String::new()
            },
            progress_text,
            reason: (state == DownloadState::Error)
                .then(|| item.reason.as_deref().map(|r| self.reason_text(r)))
                .flatten(),
            watched: item.watched,
            can_pause: matches!(state, DownloadState::Waits | DownloadState::Loads),
            can_resume: matches!(state, DownloadState::Halted | DownloadState::Error),
            can_cancel: state != DownloadState::Done,
            can_delete: state == DownloadState::Done && !item.subtitles_pending,
        }
    }

    fn rows(&self, entries: &[DownloadItem]) -> Vec<DownloadRow> {
        DownloadRules::grouped(entries)
            .into_iter()
            .map(|group| match &group {
                DownloadGroup::Single(item) => {
                    let row = self.item_row(item);
                    DownloadRow {
                        id: group.id(),
                        title: group.title().to_owned(),
                        subtitle: None,
                        state: row.state,
                        progress: row.progress,
                        size: row.size.clone(),
                        items: vec![row],
                    }
                }
                DownloadGroup::Series { episodes, .. } => {
                    let items: Vec<ItemRow> = episodes.iter().map(|e| self.item_row(e)).collect();
                    let bytes: i64 = episodes.iter().map(|e| e.bytes).sum();
                    let loaded: i64 = episodes
                        .iter()
                        .map(|e| {
                            if e.state == DownloadState::Done {
                                e.bytes
                            } else {
                                e.loaded.min(e.bytes.max(e.loaded))
                            }
                        })
                        .sum();
                    let count = i64::try_from(episodes.len()).unwrap_or(i64::MAX);
                    DownloadRow {
                        id: group.id(),
                        title: group.title().to_owned(),
                        subtitle: Some(self.translator.plural("%lld Folgen", count, &[])),
                        state: series_state(episodes),
                        progress: (bytes > 0)
                            .then(|| (loaded as f64 / bytes as f64).clamp(0.0, 1.0) as f32),
                        size: if bytes > 0 {
                            size_text(bytes, self.separator)
                        } else {
                            String::new()
                        },
                        items,
                    }
                }
            })
            .collect()
    }

    /// Recomputes both parts; replaces the ones whose content changed and rings the bell once.
    fn publish(&self, live: &mut Live) {
        let entries = live.manager.entries();
        let rows = self.rows(&entries);
        let (count, bytes) = DownloadRules::allocation(&entries);
        let free = live.manager.free();
        let active = entries
            .iter()
            .filter(|e| matches!(e.state, DownloadState::Waits | DownloadState::Loads))
            .count();
        let waiting = entries.iter().any(|e| e.state == DownloadState::Waits);
        let next = StoragePart {
            version: 0,
            count: u32::try_from(count).unwrap_or(u32::MAX),
            bytes,
            size: size_text(bytes, self.separator),
            summary: self.translator.t_args(
                "%lld Titel auf diesem Gerät",
                &[Arg::Int(i64::try_from(count).unwrap_or(i64::MAX))],
            ),
            free: if free > 0 {
                size_text(free, self.separator)
            } else {
                String::new()
            },
            active: u32::try_from(active).unwrap_or(u32::MAX),
            only_over_wlan: live.only_over_wlan,
            waiting_for_wlan: live.only_over_wlan && !live.manager.wlan() && waiting,
            offline: live.manager.no_network(),
        };
        let mut changed = Vec::new();
        if rows != live.list.rows {
            changed.push(0);
        }
        if (StoragePart {
            version: 0,
            ..(*live.storage).clone()
        }) != next
        {
            changed.push(1);
        }
        if changed.is_empty() {
            return;
        }
        let version = self.bell.bump(&changed);
        if changed.contains(&0) {
            live.list = Arc::new(ListPart { version, rows });
        }
        if changed.contains(&1) {
            live.storage = Arc::new(StoragePart { version, ..next });
        }
        const { assert!(downloads_part::LIST == 1 << 0 && downloads_part::STORAGE == 1 << 1) };
    }
}

/// A series row shows its most active episode: loading, then waiting, paused, failed, done.
fn series_state(episodes: &[DownloadItem]) -> RowState {
    let has = |s: DownloadState| episodes.iter().any(|e| e.state == s);
    [
        DownloadState::Loads,
        DownloadState::Waits,
        DownloadState::Halted,
        DownloadState::Error,
    ]
    .into_iter()
    .find(|&s| has(s))
    .map_or(RowState::Done, RowState::from)
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_downloads::{Art, AudioStream, AudioTrackRules, RunningTransfer, TaskParts};

    struct NoRules;
    impl AudioTrackRules for NoRules {
        fn language_key(&self, _: Option<&str>) -> Option<String> {
            None
        }
        fn language_label(&self, _: &str) -> Option<String> {
            None
        }
        fn audio_label(&self, _: Option<&str>, _: Option<&str>, _: Option<i64>) -> Option<String> {
            None
        }
        fn distinct(&self, labels: Vec<String>) -> Vec<String> {
            labels
        }
        fn preferred_audio_index(&self, _: &[AudioStream], _: &str) -> Option<i64> {
            None
        }
        fn all_label(&self) -> String {
            String::new()
        }
        fn track_word(&self) -> String {
            String::new()
        }
    }

    #[derive(Default)]
    struct Recorder {
        started: Mutex<Vec<String>>,
        cancelled: Mutex<Vec<String>>,
        services: Mutex<Vec<Effect>>,
    }
    impl DownloadTransport for Recorder {
        fn start(&self, parts: &TaskParts, _: &str, _: Option<&[u8]>) {
            self.started.lock().unwrap().push(parts.description());
        }
        fn cancel(&self, id: &str, _: Option<i64>, _: i64, _: bool) {
            self.cancelled.lock().unwrap().push(id.to_owned());
        }
        fn resume(&self, _: &str) {}
        fn running(&self) -> Vec<RunningTransfer> {
            Vec::new()
        }
    }
    impl DownloadServices for Recorder {
        fn run(&self, effect: &Effect) {
            self.services.lock().unwrap().push(effect.clone());
        }
    }

    fn vm(locale: &str) -> (DownloadsVm<Recorder>, Arc<Recorder>) {
        let rec = Arc::new(Recorder::default());
        let machine = DownloadManagerState::new(1, true, false, Box::new(NoRules));
        let vm = DownloadsVm::new(
            Arc::clone(&rec),
            Arc::clone(&rec) as Arc<dyn DownloadServices>,
            Locale::parse(locale),
            machine,
            true,
        );
        (vm, rec)
    }

    fn sign_in(vm: &DownloadsVm<Recorder>, items: Vec<DownloadItem>) {
        vm.send(DownloadsIntent::Engine(Box::new(Intent::SignIn {
            account: Some("u1".into()),
            stored: items,
            client: true,
        })))
        .unwrap();
        vm.send(DownloadsIntent::Engine(Box::new(Intent::NetworkChanged {
            wlan: true,
            none: false,
        })))
        .unwrap();
        vm.send(DownloadsIntent::Engine(Box::new(Intent::RunningTransfers(
            Vec::new(),
        ))))
        .unwrap();
        vm.send(DownloadsIntent::Engine(Box::new(Intent::SpaceChanged(
            100_000_000_000,
        ))))
        .unwrap();
    }

    fn done(id: &str, bytes: i64, created: f64) -> DownloadItem {
        let mut i = DownloadItem::new(id, "u1", Art::Film, format!("Film {id}"), bytes, created);
        i.state = DownloadState::Done;
        i.loaded = bytes;
        i
    }

    fn episode(id: &str, n: i64, state: DownloadState, bytes: i64, loaded: i64) -> DownloadItem {
        let mut i = DownloadItem::new(
            id,
            "u1",
            Art::Episode,
            format!("Folge {n}"),
            bytes,
            10.0 + n as f64,
        );
        i.series = Some("Serie".into());
        i.series_identifier = Some("s1".into());
        i.season = Some(1);
        i.episode = Some(n);
        i.state = state;
        i.loaded = loaded;
        i
    }

    #[test]
    fn list_groups_series_and_sums_storage() {
        let (vm, _) = vm("de");
        let before = vm.version();
        sign_in(
            &vm,
            vec![
                done("a", 850_000_000, 1.0),
                episode("e1", 1, DownloadState::Done, 1_000_000_000, 1_000_000_000),
                episode("e2", 2, DownloadState::Halted, 1_000_000_000, 500_000_000),
            ],
        );
        assert!(vm.version() > before);
        let list = vm.list();
        assert_eq!(list.rows.len(), 2);
        let series = list.rows.iter().find(|r| r.id == "serie-s1").unwrap();
        assert_eq!(series.subtitle.as_deref(), Some("2 Folgen"));
        assert_eq!(series.state, RowState::Paused);
        assert_eq!(series.size, "2 GB");
        assert!((series.progress.unwrap() - 0.75).abs() < 1e-6);
        let paused = &series.items[1];
        assert_eq!(paused.progress_text.as_deref(), Some("0,50 von 1,00 GB"));
        assert!(paused.can_resume && !paused.can_pause && paused.can_cancel && !paused.can_delete);
        let storage = vm.storage();
        assert_eq!((storage.count, storage.bytes), (2, 1_850_000_000));
        assert_eq!(storage.size, "1,85 GB");
        assert_eq!(storage.summary, "2 Titel auf diesem Gerät");
        assert!(storage.only_over_wlan);
    }

    #[test]
    fn whole_items_file_and_space_are_readable() {
        let (vm, _) = vm("de");
        sign_in(
            &vm,
            vec![
                done("a", 850_000_000, 1.0),
                episode("e2", 2, DownloadState::Halted, 1_000_000_000, 500_000_000),
            ],
        );
        let entries = vm.entries();
        assert_eq!(entries.len(), 2);
        assert_eq!(vm.item("e2").unwrap().loaded, 500_000_000);
        assert!(vm.item("zzz").is_none());
        assert_eq!(vm.file_for("a"), Some(done("a", 1, 1.0).file_name()));
        assert_eq!(vm.file_for("e2"), None);
        // 100 GB free: a 1 GB title fits.
        assert!(vm.inquiry(1_000_000_000).suffices);
        assert!(!vm.inquiry(200_000_000_000).suffices);
    }

    #[test]
    fn intents_are_checked_against_state() {
        let (vm, rec) = vm("de");
        sign_in(
            &vm,
            vec![
                done("a", 100, 1.0),
                episode("e2", 2, DownloadState::Halted, 100, 10),
            ],
        );
        assert_eq!(
            vm.send(DownloadsIntent::Pause("zzz".into())),
            Err(DownloadsRejected::UnknownItem)
        );
        assert_eq!(
            vm.send(DownloadsIntent::Pause("a".into())),
            Err(DownloadsRejected::WrongState)
        );
        assert_eq!(
            vm.send(DownloadsIntent::Cancel("a".into())),
            Err(DownloadsRejected::WrongState)
        );
        assert_eq!(
            vm.send(DownloadsIntent::Delete(vec!["e2".into()])),
            Err(DownloadsRejected::WrongState)
        );
        assert_eq!(
            vm.send(DownloadsIntent::Resume("a".into())),
            Err(DownloadsRejected::WrongState)
        );

        vm.send(DownloadsIntent::Delete(vec!["a".into()])).unwrap();
        assert!(vm.list().rows.iter().all(|r| r.id != "a"));
        assert!(
            rec.services
                .lock()
                .unwrap()
                .iter()
                .any(|e| matches!(e, Effect::DeleteFile { .. }))
        );

        vm.send(DownloadsIntent::Resume("e2".into())).unwrap();
        let state = vm.list().rows[0].items[0].state;
        assert!(matches!(state, RowState::Waiting | RowState::Loading));
        vm.send(DownloadsIntent::Pause("e2".into())).unwrap();
        assert_eq!(vm.list().rows[0].items[0].state, RowState::Paused);
        vm.send(DownloadsIntent::Cancel("e2".into())).unwrap();
        assert!(vm.list().rows.is_empty());
        assert_eq!(vm.storage().count, 0);
    }

    #[test]
    fn start_queues_and_asks_for_an_address() {
        let (vm, rec) = vm("de");
        sign_in(&vm, Vec::new());
        let item = DownloadItem::new("m1", "u1", Art::Film, "Neu", 2_000_000_000, 5.0);
        vm.send(DownloadsIntent::Start {
            items: vec![item],
            images: HashMap::new(),
            check_space: false,
        })
        .unwrap();
        let row = &vm.list().rows[0];
        assert_eq!(row.title, "Neu");
        assert!(matches!(row.state, RowState::Waiting | RowState::Loading));
        assert!(
            rec.services
                .lock()
                .unwrap()
                .iter()
                .any(|e| matches!(e, Effect::RequestAddress { .. }))
        );
        assert_eq!(vm.storage().active, 1);
    }

    #[test]
    fn wlan_rule_shows_in_storage() {
        let (vm, _) = vm("en");
        sign_in(&vm, vec![episode("e2", 2, DownloadState::Waits, 100, 0)]);
        vm.send(DownloadsIntent::Engine(Box::new(Intent::NetworkChanged {
            wlan: false,
            none: false,
        })))
        .unwrap();
        assert!(vm.storage().waiting_for_wlan);
        vm.send(DownloadsIntent::OnlyOverWlan(false)).unwrap();
        assert!(!vm.storage().waiting_for_wlan && !vm.storage().only_over_wlan);
        vm.send(DownloadsIntent::Engine(Box::new(Intent::NetworkChanged {
            wlan: false,
            none: true,
        })))
        .unwrap();
        assert!(vm.storage().offline);
    }

    #[test]
    fn english_sizes_use_a_point() {
        let (vm, _) = vm("en");
        sign_in(&vm, vec![done("a", 1_100_000_000, 1.0)]);
        assert_eq!(vm.storage().size, "1.1 GB");
    }

    #[test]
    fn unchanged_input_does_not_ring() {
        let (vm, _) = vm("de");
        sign_in(&vm, vec![done("a", 100, 1.0)]);
        let v = vm.version();
        vm.send(DownloadsIntent::Engine(Box::new(Intent::Tick)))
            .unwrap();
        assert_eq!(vm.version(), v);
    }
}
