//! The exported downloads view model (`swiftly_vm::DownloadsVm`). Transfers run on the host
//! (`DownloadHost`: URLSession background session on Apple); the list file lives in the
//! host's key-value store. Everything the host learns comes back through `send`.
//!
//! The host must answer a command (`request_address`, `start_transfer`, ...) later and from
//! its own task, never from inside the call: the vm holds its lock while it runs effects.

use std::collections::HashMap;
use std::sync::Arc;

use swiftly_downloads::{
    Art, AudioStream, AudioTrackRules, DownloadItem, DownloadManagerState, DownloadTransport,
    Effect, FileKind, Intent, RunningTransfer, TaskParts, TransferEvent, load_list,
};
use swiftly_l10n::Locale;
use swiftly_vm::{
    Change, DownloadRow, DownloadServices, DownloadsIntent as VmIntent, DownloadsRejected,
    DownloadsVm as Vm, ItemRow, ListPart, RowState, StoragePart,
};

use crate::core::Platform;
use crate::error::CoreError;
use crate::stores::KeyValueStore;

const LIST_KEY: &str = "downloads.list";

#[uniffi::remote(Enum)]
pub enum RowState {
    Waiting,
    Loading,
    Paused,
    Done,
    Failed,
}

#[uniffi::remote(Record)]
pub struct ItemRow {
    pub id: String,
    pub title: String,
    pub season: Option<i64>,
    pub episode: Option<i64>,
    pub state: RowState,
    pub progress: Option<f32>,
    pub size: String,
    pub progress_text: Option<String>,
    pub reason: Option<String>,
    pub watched: bool,
    pub can_pause: bool,
    pub can_resume: bool,
    pub can_cancel: bool,
    pub can_delete: bool,
}

#[uniffi::remote(Record)]
pub struct DownloadRow {
    pub id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub state: RowState,
    pub progress: Option<f32>,
    pub size: String,
    pub items: Vec<ItemRow>,
}

#[uniffi::remote(Record)]
pub struct ListPart {
    pub version: u64,
    pub rows: Vec<DownloadRow>,
}

#[uniffi::remote(Record)]
pub struct StoragePart {
    pub version: u64,
    pub count: u32,
    pub bytes: i64,
    pub size: String,
    pub summary: String,
    pub free: String,
    pub active: u32,
    pub only_over_wlan: bool,
    pub waiting_for_wlan: bool,
    pub offline: bool,
}

/// A transfer the system still has from an earlier run.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct RunningTransferInfo {
    pub description: Option<String>,
    pub suspended: bool,
    pub bytes_received: i64,
}

/// The platform's transfer layer and file work. Commands return at once.
#[uniffi::export(with_foreign)]
pub trait DownloadHost: Send + Sync {
    fn start_transfer(
        &self,
        id: String,
        generation: i64,
        file: String,
        address: String,
        resume: Option<Vec<u8>>,
    );
    fn cancel_transfer(
        &self,
        id: String,
        task_generation: Option<i64>,
        new_generation: i64,
        want_resume_data: bool,
    );
    fn resume_transfer(&self, id: String);
    /// Transfers left from an earlier run; the answer is synchronous.
    fn running_transfers(&self) -> Vec<RunningTransferInfo>;
    /// Ask the server for the file address; answer with `addressReady` / `addressFailed`.
    fn request_address(
        &self,
        id: String,
        generation: i64,
        source: Option<String>,
        quality: String,
        audio_index: Option<i64>,
    );
    /// `kind` is `media`, `subtitles` or `image`; `name` is relative to the downloads folder.
    fn delete_file(&self, kind: String, name: String);
    fn fetch_image(&self, name: String, url: String);
    /// Measure free space; answer with `spaceChanged`.
    fn measure_space(&self);
    /// A title finished: fetch its external subtitle files (the host writes them next to the
    /// media file). `source` is the media source id.
    fn fetch_subtitles(&self, id: String, source: Option<String>);
    /// A title finished: ask the server for its intro/outro sections, answer with
    /// `DownloadsIntent::SectionsFetched` (an empty list when the server knows none).
    fn fetch_sections(&self, id: String);
    /// A watched title may have a successor: fetch the episodes of `series_id`, answer with
    /// `DownloadsIntent::SuccessorFound` (`None` keeps it pending).
    fn lookup_successor(&self, id: String, series_id: String);
}

/// What the server says about one title's watch state (`UserData`).
#[derive(uniffi::Record, Clone, Debug)]
pub struct DownloadWatchState {
    pub id: String,
    pub played: Option<bool>,
    pub position_ticks: Option<i64>,
    pub played_percentage: Option<f64>,
    pub last_played_date: Option<String>,
}

/// What the server says about the downloaded titles: the ids it knows and their watch state.
#[derive(uniffi::Record, Clone, Debug)]
pub struct DownloadFollow {
    pub available: Vec<String>,
    pub states: Vec<DownloadWatchState>,
}

/// The series' episodes (the server's `Items` JSON) and the next episode's landscape image.
#[derive(uniffi::Record, Clone, Debug)]
pub struct DownloadSuccessor {
    pub episodes_json: Vec<u8>,
    pub image: Option<String>,
}

/// What a download of some size would cost (`DownloadRules.slot`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct DownloadSpace {
    /// Fits without clearing, with the reserve.
    pub suffices: bool,
    pub free_after: i64,
    /// Ids of watched, finished titles, largest first.
    pub dispensable: Vec<String>,
    pub dispensable_bytes: i64,
    pub suffices_after_clean_up: bool,
}

/// A title to queue.
#[derive(uniffi::Record, Clone, Debug)]
pub struct DownloadRequest {
    pub id: String,
    pub account: String,
    pub episode_kind: bool,
    pub title: String,
    pub series: Option<String>,
    pub series_id: Option<String>,
    pub season: Option<i64>,
    pub episode: Option<i64>,
    pub runtime_ticks: Option<i64>,
    pub container: Option<String>,
    pub source: Option<String>,
    pub bytes: i64,
    /// Unix seconds.
    pub created: f64,
    pub image: Option<String>,
    /// `original`, `hd1080`, `hd720` or `sd480`; `None` is the original.
    pub quality: Option<String>,
    /// The one audio track a built file holds (server stream index) and the language it was chosen by.
    pub audio_index: Option<i64>,
    pub audio_language: Option<String>,
    pub video_codec: Option<String>,
    /// The watched episode this one is loaded to follow.
    pub replaces: Option<String>,
}

/// An image to fetch along: the title's own (key = its id), the series poster (key = the series
/// id) or the series header (key = `kopf:<series id>`).
#[derive(uniffi::Record, Clone, Debug)]
pub struct DownloadImage {
    pub key: String,
    pub url: String,
}

#[derive(uniffi::Enum, Clone, Debug)]
pub enum DownloadsIntent {
    Start {
        items: Vec<DownloadRequest>,
        /// More images than the requests' own (series poster and header).
        images: Vec<DownloadImage>,
        check_space: bool,
    },
    Pause {
        id: String,
    },
    Resume {
        id: String,
    },
    Cancel {
        id: String,
    },
    Delete {
        ids: Vec<String>,
    },
    PauseAll,
    DeleteAll,
    OnlyOverWlan {
        on: bool,
    },
    NextAuto {
        on: bool,
    },
    /// Sign in (or out with `None`); the core reads the stored list itself.
    SignIn {
        account: Option<String>,
        client: bool,
    },
    Tick,
    /// The path monitor was stopped (the feature is switched off).
    NetworkObserveStopped,
    NetworkChanged {
        wlan: bool,
        none: bool,
    },
    SpaceChanged {
        bytes: i64,
    },
    AddressReady {
        id: String,
        generation: i64,
        address: String,
    },
    AddressFailed {
        id: String,
        generation: i64,
        reason: String,
    },
    TransferProgress {
        id: String,
        generation: i64,
        file: String,
        loaded: i64,
        total: i64,
        now: f64,
    },
    TransferFinished {
        id: String,
        generation: i64,
        file: String,
        worked: bool,
        real_size: Option<i64>,
    },
    TransferFailed {
        id: String,
        generation: i64,
        file: String,
        reason: String,
        resume: Option<Vec<u8>>,
    },
    ResumeData {
        id: String,
        generation: i64,
        data: Vec<u8>,
    },
    RunningTransfers {
        found: Vec<RunningTransferInfo>,
    },
    /// Answer to `fetch_sections`.
    SectionsFetched {
        id: String,
        sections: Vec<crate::player::PlayerSection>,
    },
    /// Answer to `fetch_subtitles`: `ok` once every subtitle file and `info.json` are written.
    SubtitlesFetched {
        id: String,
        ok: bool,
    },
    /// A playback was recorded on this device (also offline): the list shows the check mark and
    /// the remembered position, and the next episode is queued when the rules want it.
    PlaybackRemembered {
        id: String,
        ticks: i64,
        now: f64,
    },
    /// What the server says about the titles: `available` are the ids it answered with.
    ServerFollow {
        available: Vec<String>,
        states: Vec<DownloadWatchState>,
    },
    /// Every finished title without stored sections asks again.
    SectionsCatchUp,
    /// Every title with a pending successor looks it up again.
    SmartCatchUp,
    /// Answer to `lookup_successor`: the server's `Items` JSON of the series' episodes (`None`:
    /// no answer), the landscape image address of the next episode, and the clock (Unix seconds).
    SuccessorFound {
        id: String,
        episodes_json: Option<Vec<u8>>,
        image: Option<String>,
        now: f64,
    },
}

/// Bit of `Change.parts`: the list.
#[uniffi::export]
pub fn part_downloads_list() -> u32 {
    swiftly_vm::downloads_part::LIST
}

/// Bit of `Change.parts`: the storage summary.
#[uniffi::export]
pub fn part_downloads_storage() -> u32 {
    swiftly_vm::downloads_part::STORAGE
}

/// Track names for the download picker: the same wording rules as the player's track panel.
pub(crate) struct TrackNames {
    words: swiftly_vm::LabelWords,
    tr: swiftly_l10n::Translator,
}

impl TrackNames {
    pub(crate) fn new(locale: &str) -> Self {
        Self {
            words: swiftly_vm::LabelWords::new(Locale::parse(locale)),
            tr: swiftly_l10n::Translator::new(Locale::parse(locale)),
        }
    }
}

impl AudioTrackRules for TrackNames {
    fn language_key(&self, language: Option<&str>) -> Option<String> {
        swiftly_playback::track_mapping::language_key(language)
    }
    fn language_label(&self, key: &str) -> Option<String> {
        swiftly_playback::track_label::language(Some(key), &self.words)
    }
    fn audio_label(
        &self,
        language: Option<&str>,
        codec: Option<&str>,
        channels: Option<i64>,
    ) -> Option<String> {
        let codec = swiftly_playback::track_label::codec_name_value(codec);
        swiftly_playback::track_label::audio(language, codec.as_deref(), channels, &self.words)
    }
    fn distinct(&self, labels: Vec<String>) -> Vec<String> {
        swiftly_playback::track_label::distinct(&labels)
    }
    fn preferred_audio_index(&self, streams: &[AudioStream], preferred: &str) -> Option<i64> {
        let media: Vec<swiftly_model::MediaStream> = streams
            .iter()
            .map(|s| swiftly_model::MediaStream {
                index: s.index,
                type_: Some(s.kind.clone()),
                language: s.language.clone(),
                codec: s.codec.clone(),
                channels: s.channels,
                display_title: s.display_title.clone(),
                is_default: s.is_default,
                ..swiftly_model::MediaStream::default()
            })
            .collect();
        swiftly_playback::track_rule::audio(&media, None, preferred, None, None)
    }
    fn all_label(&self) -> String {
        self.tr.t("Alle Tonspuren")
    }
    fn track_word(&self) -> String {
        self.tr.t("Tonspur")
    }
}

struct HostTransport(Arc<dyn DownloadHost>);

impl DownloadTransport for HostTransport {
    fn start(&self, parts: &TaskParts, address: &str, resume: Option<&[u8]>) {
        self.0.start_transfer(
            parts.id.clone(),
            parts.generation,
            parts.file.clone(),
            address.to_owned(),
            resume.map(<[u8]>::to_vec),
        );
    }
    fn cancel(&self, id: &str, task_generation: Option<i64>, new_generation: i64, want: bool) {
        self.0
            .cancel_transfer(id.to_owned(), task_generation, new_generation, want);
    }
    fn resume(&self, id: &str) {
        self.0.resume_transfer(id.to_owned());
    }
    fn running(&self) -> Vec<RunningTransfer> {
        self.0
            .running_transfers()
            .into_iter()
            .map(|r| RunningTransfer {
                description: r.description,
                suspended: r.suspended,
                bytes_received: r.bytes_received,
            })
            .collect()
    }
}

struct Services {
    host: Arc<dyn DownloadHost>,
    kv: Arc<dyn KeyValueStore>,
    platform: Arc<dyn Platform>,
}

impl DownloadServices for Services {
    fn run(&self, effect: &Effect) {
        match effect {
            Effect::Persist(items) => match swiftly_downloads::encode_list(items) {
                Ok(bytes) => self.kv.set(LIST_KEY.to_owned(), bytes),
                Err(e) => self
                    .platform
                    .log(format!("downloads: list not written: {e}")),
            },
            Effect::RequestAddress {
                id,
                generation,
                source,
                quality,
                audio_index,
            } => self.host.request_address(
                id.clone(),
                *generation,
                source.clone(),
                format!("{quality:?}"),
                *audio_index,
            ),
            Effect::DeleteFile { kind, name } => self.host.delete_file(
                match kind {
                    FileKind::Media => "media",
                    FileKind::Subtitles => "subtitles",
                    FileKind::Image => "image",
                }
                .to_owned(),
                name.clone(),
            ),
            Effect::FetchImage { name, url } => self.host.fetch_image(name.clone(), url.clone()),
            Effect::MeasureSpace => self.host.measure_space(),
            Effect::FetchSubtitles { item } => self
                .host
                .fetch_subtitles(item.id.clone(), item.source.clone()),
            Effect::FetchSections { id } => self.host.fetch_sections(id.clone()),
            Effect::LookupSuccessor { id, series_id } => {
                self.host.lookup_successor(id.clone(), series_id.clone());
            }
            _ => {}
        }
    }
}

#[derive(uniffi::Object)]
pub struct DownloadsVm {
    vm: Vm<HostTransport>,
    kv: Arc<dyn KeyValueStore>,
    host: Arc<dyn DownloadHost>,
}

impl DownloadsVm {
    pub(crate) fn new(
        host: Arc<dyn DownloadHost>,
        kv: Arc<dyn KeyValueStore>,
        platform: Arc<dyn Platform>,
        locale: &str,
        only_over_wlan: bool,
        next_auto: bool,
    ) -> Arc<Self> {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(1, |d| i64::try_from(d.as_millis()).unwrap_or(1));
        let machine = DownloadManagerState::new(
            seed,
            only_over_wlan,
            next_auto,
            Box::new(TrackNames::new(locale)),
        );
        let services = Arc::new(Services {
            host: Arc::clone(&host),
            kv: Arc::clone(&kv),
            platform,
        });
        let vm = Vm::new(
            Arc::new(HostTransport(Arc::clone(&host))),
            services,
            Locale::parse(locale),
            machine,
            only_over_wlan,
        );
        Arc::new(Self { vm, kv, host })
    }

    fn convert(&self, intent: DownloadsIntent) -> VmIntent {
        let parts = |id: String, generation: i64, file: String| TaskParts {
            id,
            generation,
            file,
        };
        match intent {
            DownloadsIntent::Start {
                items,
                images: more,
                check_space,
            } => {
                let mut images: HashMap<String, String> =
                    more.into_iter().map(|i| (i.key, i.url)).collect();
                let items = items
                    .into_iter()
                    .map(|r| {
                        if let Some(url) = &r.image {
                            images.insert(r.id.clone(), url.clone());
                        }
                        let art = if r.episode_kind {
                            Art::Episode
                        } else {
                            Art::Film
                        };
                        let mut item =
                            DownloadItem::new(r.id, r.account, art, r.title, r.bytes, r.created);
                        item.series = r.series;
                        item.series_identifier = r.series_id;
                        item.season = r.season;
                        item.episode = r.episode;
                        item.runtime_ticks = r.runtime_ticks;
                        item.container = r.container;
                        item.source = r.source;
                        item.quality = r.quality.as_deref().and_then(
                            swiftly_rules::download_quality::DownloadQuality::from_raw_value,
                        );
                        item.audio_index = r.audio_index;
                        item.audio_language = r.audio_language;
                        item.video_codec = r.video_codec;
                        item.replaces = r.replaces;
                        item
                    })
                    .collect();
                VmIntent::Start {
                    items,
                    images,
                    check_space,
                }
            }
            DownloadsIntent::Pause { id } => VmIntent::Pause(id),
            DownloadsIntent::Resume { id } => VmIntent::Resume(id),
            DownloadsIntent::Cancel { id } => VmIntent::Cancel(id),
            DownloadsIntent::Delete { ids } => VmIntent::Delete(ids),
            DownloadsIntent::PauseAll => VmIntent::PauseAll,
            DownloadsIntent::DeleteAll => VmIntent::DeleteAll,
            DownloadsIntent::OnlyOverWlan { on } => VmIntent::OnlyOverWlan(on),
            DownloadsIntent::NextAuto { on } => VmIntent::NextAuto(on),
            DownloadsIntent::SignIn { account, client } => {
                let stored = load_list(self.kv.get(LIST_KEY.to_owned()).as_deref()).items;
                VmIntent::Engine(Box::new(Intent::SignIn {
                    account,
                    stored,
                    client,
                }))
            }
            DownloadsIntent::Tick => VmIntent::Engine(Box::new(Intent::Tick)),
            DownloadsIntent::NetworkObserveStopped => {
                VmIntent::Engine(Box::new(Intent::NetworkObserveStopped))
            }
            DownloadsIntent::NetworkChanged { wlan, none } => {
                VmIntent::Engine(Box::new(Intent::NetworkChanged { wlan, none }))
            }
            DownloadsIntent::SpaceChanged { bytes } => {
                VmIntent::Engine(Box::new(Intent::SpaceChanged(bytes)))
            }
            DownloadsIntent::AddressReady {
                id,
                generation,
                address,
            } => VmIntent::Engine(Box::new(Intent::AddressReady {
                id,
                generation,
                address,
            })),
            DownloadsIntent::AddressFailed {
                id,
                generation,
                reason,
            } => VmIntent::Engine(Box::new(Intent::AddressFailed {
                id,
                generation,
                reason,
            })),
            DownloadsIntent::TransferProgress {
                id,
                generation,
                file,
                loaded,
                total,
                now,
            } => VmIntent::Transfer(TransferEvent::Progress {
                parts: parts(id, generation, file),
                loaded,
                total,
                now,
            }),
            DownloadsIntent::TransferFinished {
                id,
                generation,
                file,
                worked,
                real_size,
            } => VmIntent::Transfer(TransferEvent::Finished {
                parts: parts(id, generation, file),
                worked,
                real_size,
            }),
            DownloadsIntent::TransferFailed {
                id,
                generation,
                file,
                reason,
                resume,
            } => VmIntent::Transfer(TransferEvent::Failed {
                parts: parts(id, generation, file),
                reason,
                resume,
            }),
            DownloadsIntent::ResumeData {
                id,
                generation,
                data,
            } => VmIntent::Engine(Box::new(Intent::ResumeData {
                id,
                generation,
                data,
            })),
            DownloadsIntent::SectionsFetched { id, sections } => {
                VmIntent::Engine(Box::new(Intent::SectionsFetched {
                    id,
                    sections: sections.into_iter().map(Into::into).collect(),
                }))
            }
            DownloadsIntent::SubtitlesFetched { id, ok } => {
                VmIntent::Engine(Box::new(Intent::SubtitlesFetched { id, ok }))
            }
            DownloadsIntent::PlaybackRemembered { id, ticks, now } => {
                VmIntent::Engine(Box::new(Intent::PlaybackRemembered { id, ticks, now }))
            }
            DownloadsIntent::ServerFollow { available, states } => {
                VmIntent::Engine(Box::new(Intent::ServerFollow {
                    available: available.into_iter().collect(),
                    watch_state: states
                        .into_iter()
                        .map(|s| {
                            (
                                s.id,
                                swiftly_model::UserItemData {
                                    played: s.played,
                                    playback_position_ticks: s.position_ticks,
                                    played_percentage: s.played_percentage,
                                    last_played_date: s.last_played_date,
                                    ..swiftly_model::UserItemData::default()
                                },
                            )
                        })
                        .collect(),
                }))
            }
            DownloadsIntent::SectionsCatchUp => VmIntent::Engine(Box::new(Intent::SectionsCatchUp)),
            DownloadsIntent::SmartCatchUp => VmIntent::Engine(Box::new(Intent::SmartCatchUp)),
            DownloadsIntent::SuccessorFound {
                id,
                episodes_json,
                image,
                now,
            } => VmIntent::Engine(Box::new(Intent::SuccessorFound {
                id,
                episodes: episodes_json.and_then(|b| {
                    serde_json::from_slice::<swiftly_model::ItemsResponse>(&b)
                        .ok()
                        .map(|r| r.items)
                }),
                image,
                now,
            })),
            DownloadsIntent::RunningTransfers { found } => {
                VmIntent::Engine(Box::new(Intent::RunningTransfers(
                    found
                        .into_iter()
                        .map(|r| RunningTransfer {
                            description: r.description,
                            suspended: r.suspended,
                            bytes_received: r.bytes_received,
                        })
                        .collect(),
                )))
            }
        }
    }
}

#[uniffi::export]
impl DownloadsVm {
    pub fn version(&self) -> u64 {
        self.vm.version()
    }

    pub fn list(&self) -> ListPart {
        ListPart::clone(&self.vm.list())
    }

    pub fn storage(&self) -> StoragePart {
        StoragePart::clone(&self.vm.storage())
    }

    /// The signed-in account's whole items as the list file's JSON array (German keys, the
    /// running progress merged in). The host decodes it with the item type it already has.
    pub fn items_json(&self) -> Vec<u8> {
        swiftly_downloads::encode_list(&self.vm.entries()).unwrap_or_default()
    }

    /// Offline playback the server has not seen, as the pending-report list JSON (the format of
    /// `pending_report_record`: send each entry through it, then `pending_submit`). `states` is the
    /// server's watch state per id, as `DownloadFollow.states`; call it after a `ServerFollow`.
    pub fn unreported_progress_json(
        &self,
        account: String,
        states: Vec<DownloadWatchState>,
    ) -> String {
        let states = states
            .into_iter()
            .map(|s| {
                (
                    s.id,
                    swiftly_model::UserItemData {
                        played: s.played,
                        playback_position_ticks: s.position_ticks,
                        played_percentage: s.played_percentage,
                        last_played_date: s.last_played_date,
                        ..swiftly_model::UserItemData::default()
                    },
                )
            })
            .collect();
        serde_json::to_string(&self.vm.unreported_progress(&account, &states))
            .unwrap_or_else(|_| "[]".into())
    }

    /// The file name of a finished title (the host checks that it exists on disk).
    pub fn file_for(&self, id: String) -> Option<String> {
        self.vm.file_for(&id)
    }

    /// What a download of `bytes` costs against the last measured free space.
    pub fn inquiry(&self, bytes: i64) -> DownloadSpace {
        let info = self.vm.inquiry(bytes);
        DownloadSpace {
            suffices: info.suffices,
            free_after: info.free_after,
            suffices_after_clean_up: info.suffices_to_clean_up(),
            dispensable_bytes: info.dispensable_bytes,
            dispensable: info.dispensable.into_iter().map(|i| i.id).collect(),
        }
    }

    /// An intent. A title that is unknown or in a state the intent does not fit throws.
    pub fn send(&self, intent: DownloadsIntent) -> Result<(), CoreError> {
        let sign_in = matches!(intent, DownloadsIntent::SignIn { .. });
        let failed = |r| CoreError::Failed {
            message: match r {
                DownloadsRejected::UnknownItem => "unknown download".to_owned(),
                DownloadsRejected::WrongState => "download is in another state".to_owned(),
            },
        };
        self.vm.send(self.convert(intent)).map_err(failed)?;
        if sign_in {
            // The machine waits for the transfers of an earlier run before it starts anything.
            let found = DownloadsIntent::RunningTransfers {
                found: self.host.running_transfers(),
            };
            self.vm.send(self.convert(found)).map_err(failed)?;
        }
        Ok(())
    }

    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<Change, CoreError> {
        Ok(self.vm.changed(seen).await)
    }

    pub fn waiters(&self) -> u32 {
        self.vm.waiters()
    }

    /// The whole queue as one state for this network (`only_wifi` = the Wi-Fi-only setting).
    pub fn queue_phase(
        &self,
        network: crate::state_more::DownloadNetwork,
        only_wifi: bool,
    ) -> crate::state_more::DownloadQueuePhase {
        self.vm.queue_phase(network.into(), only_wifi).into()
    }
}
