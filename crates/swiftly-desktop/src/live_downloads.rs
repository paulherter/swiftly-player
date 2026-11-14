//! Downloads of the real app: files in the Swiftly data directory (`downloads/`), `liste.json` next to them, HTTP
//! transfer with `Range` resume through reqwest on the network runtime. [`Files`] is the `DownloadTransport` and the
//! `DownloadServices` of one `DownloadsVm`; the state machine stays in `swiftly-downloads`.

use crate::downloads_screen::Dyn;
use crate::live::Core;
use crate::load_sheets::Look;
use crate::load_sheets::Pictures;
use crate::net_watch::{Pump, SystemWatcher};
use crate::store::config_dir;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};
use swiftly_downloads::{
    Art, DownloadItem, DownloadManagerState, DownloadQuality, DownloadTransport, Effect, FileKind,
    Intent, Report, RunningTransfer, TaskParts, TransferEvent, encode_list, load_list,
    merge_for_write,
};
use swiftly_jellyfin::DownloadConversion;
use swiftly_l10n::Locale;
use swiftly_playback::media_server::MediaServer;
use swiftly_vm::{AccountRef, DownloadServices, DownloadsIntent, DownloadsVm, ServerClient};

/// Gives the address of a title: id, media source, quality, audio track index.
pub type Resolver = Arc<
    dyn Fn(&str, Option<&str>, DownloadQuality, Option<i64>) -> Result<String, String>
        + Send
        + Sync,
>;

/// The subtitle files of a finished title (id, media source, whether the file is a server-built copy): the server's
/// numbering, the full address, the file ending and what the file is (language, title, flags). Empty when the server cannot be asked.
pub type SubtitleLister = Arc<
    dyn Fn(
            String,
            Option<String>,
            bool,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<
                        Output = Vec<(
                            i64,
                            String,
                            String,
                            swiftly_vm::subtitle_sidecar::SubtitleMeta,
                        )>,
                    > + Send,
            >,
        > + Send
        + Sync,
>;

/// How long a transfer may stay silent before it counts as failed.
const STALL: Duration = Duration::from_secs(60);

/// The folder of the downloaded files.
pub fn downloads_dir() -> PathBuf {
    config_dir().join("downloads")
}

#[derive(Default)]
struct Ctl {
    stop: AtomicBool,
    /// Set by a pause: the generation the resume data is reported under.
    resume_generation: Mutex<Option<i64>>,
}

struct Inner {
    dir: PathBuf,
    account: String,
    rt: tokio::runtime::Handle,
    http: reqwest::Client,
    resolver: Resolver,
    subtitles: Option<SubtitleLister>,
    vm: OnceLock<DownloadsVm<Dyn>>,
    tasks: Mutex<HashMap<String, Arc<Ctl>>>,
}

/// Transfers and file services of the downloads (a handle, cheap to clone).
#[derive(Clone)]
pub struct Files(Arc<Inner>);

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// Free bytes on the volume of `dir` (`df` on unix, `GetDiskFreeSpaceExW` on Windows; "plenty" if the system will not say).
fn free_bytes(dir: &Path) -> i64 {
    let _ = std::fs::create_dir_all(dir);
    #[cfg(unix)]
    if let Ok(out) = std::process::Command::new("df")
        .arg("-Pk")
        .arg(dir)
        .output()
        && let Some(kb) = String::from_utf8_lossy(&out.stdout)
            .lines()
            .nth(1)
            .and_then(|l| l.split_whitespace().nth(3))
            .and_then(|v| v.parse::<i64>().ok())
    {
        return kb.saturating_mul(1024);
    }
    #[cfg(windows)]
    if let Some(bytes) = free_bytes_windows(dir) {
        return bytes;
    }
    i64::MAX / 4
}

/// The bytes available to this user on the volume of `dir` (`GetDiskFreeSpaceExW`).
#[cfg(windows)]
#[allow(unsafe_code)]
fn free_bytes_windows(dir: &Path) -> Option<i64> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let wide: Vec<u16> = dir.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut free_to_caller: u64 = 0;
    // SAFETY: `wide` is a NUL-terminated UTF-16 path that outlives the call; the two other out pointers may be null.
    let ok = unsafe {
        GetDiskFreeSpaceExW(
            wide.as_ptr(),
            &mut free_to_caller,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    (ok != 0).then(|| i64::try_from(free_to_caller).unwrap_or(i64::MAX))
}

impl Inner {
    fn emit(&self, event: TransferEvent) {
        if let Some(vm) = self.vm.get() {
            let _ = vm.send(DownloadsIntent::Transfer(event));
        }
    }

    fn engine(&self, intent: Intent) {
        if let Some(vm) = self.vm.get() {
            let _ = vm.send(DownloadsIntent::Engine(Box::new(intent)));
        }
    }

    fn part_path(&self, file: &str) -> PathBuf {
        self.dir.join(format!("{file}.part"))
    }

    fn list_path(&self) -> PathBuf {
        self.dir.join("liste.json")
    }

    /// Takes the external subtitle files of a finished title along: `<file>.untertitel/<index>.<ext>`, one request each
    /// (a separate folder, so the player does not load a file next to the media twice). A failed file is skipped, the
    /// title plays without it.
    fn fetch_subtitles(self: &Arc<Self>, item: &swiftly_downloads::DownloadItem) {
        let Some(lister) = self.subtitles.clone() else {
            self.engine(Intent::SubtitlesFetched {
                id: item.id.clone(),
                ok: true,
            });
            return;
        };
        let (me, folder, id, source, converted) = (
            Arc::clone(self),
            self.dir.join(item.subtitle_folder_name()),
            item.id.clone(),
            item.source.clone(),
            item.streamed(),
        );
        self.rt.spawn(async move {
            let files = lister(id.clone(), source, converted).await;
            if files.is_empty() {
                // Nothing to fetch (or the server could not be asked: then the catch-up asks again).
                me.engine(Intent::SubtitlesFetched { id, ok: true });
                return;
            }
            let _ = std::fs::create_dir_all(&folder);
            let mut loaded = 0;
            let mut metas = Vec::new();
            for (index, address, ext, meta) in &files {
                let Ok(answer) = me.http.get(address).send().await else {
                    continue;
                };
                if !answer.status().is_success() {
                    continue;
                }
                let Ok(body) = answer.bytes().await else {
                    continue;
                };
                if !body.is_empty()
                    && std::fs::write(folder.join(format!("{index}.{ext}")), &body).is_ok()
                {
                    loaded += 1;
                    metas.push(meta.clone());
                }
            }
            swiftly_vm::subtitle_sidecar::write(&folder, &metas);
            eprintln!("downloads: subtitles of {id}: {loaded} of {}", files.len());
            me.engine(Intent::SubtitlesFetched {
                id,
                ok: loaded == files.len(),
            });
        });
    }

    fn lock_tasks(&self) -> std::sync::MutexGuard<'_, HashMap<String, Arc<Ctl>>> {
        self.tasks.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn failed(&self, parts: &TaskParts, reason: impl Into<String>) {
        self.emit(TransferEvent::Failed {
            parts: parts.clone(),
            reason: reason.into(),
            resume: None,
        });
    }

    /// One transfer: a `.part` file that grows, moved into place when complete.
    async fn transfer(self: Arc<Self>, parts: TaskParts, address: String, ctl: Arc<Ctl>) {
        let _ = std::fs::create_dir_all(&self.dir);
        let (part, done) = (self.part_path(&parts.file), self.dir.join(&parts.file));
        let mut have = std::fs::metadata(&part).map_or(0, |m| m.len());
        let mut retried = false;
        let mut resp = loop {
            let mut req = self.http.get(&address);
            if have > 0 {
                req = req.header("Range", format!("bytes={have}-"));
            }
            let r = match tokio::time::timeout(STALL, req.send()).await {
                Ok(Ok(r)) => r,
                Ok(Err(e)) => return self.failed(&parts, e.to_string()),
                Err(_) => return self.failed(&parts, "Zeitüberschreitung."),
            };
            match r.status().as_u16() {
                200 | 206 => break r,
                416 if have > 0 && !retried => {
                    // The partial file does not fit the server's file: start over.
                    let _ = std::fs::remove_file(&part);
                    (have, retried) = (0, true);
                }
                code => return self.failed(&parts, format!("Der Server antwortet mit {code}.")),
            }
        };
        let append = resp.status().as_u16() == 206 && have > 0;
        if !append {
            have = 0;
        }
        let total = resp.content_length().map_or(0, |l| {
            i64::try_from(l).unwrap_or(0) + i64::try_from(have).unwrap_or(0)
        });
        let file = if append {
            std::fs::OpenOptions::new().append(true).open(&part)
        } else {
            std::fs::File::create(&part)
        };
        let Ok(mut file) = file else {
            return self.failed(&parts, "Die Datei liess sich nicht ablegen.");
        };
        let mut loaded = i64::try_from(have).unwrap_or(0);
        let (mut last, mut quiet_since) = (Instant::now() - Duration::from_secs(1), Instant::now());
        loop {
            if ctl.stop.load(Ordering::SeqCst) {
                drop(file);
                match *ctl
                    .resume_generation
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                {
                    Some(generation) => self.emit(TransferEvent::ResumeData {
                        id: parts.id.clone(),
                        generation,
                        data: loaded.to_string().into_bytes(),
                    }),
                    None => {
                        let _ = std::fs::remove_file(&part);
                    }
                }
                return;
            }
            match tokio::time::timeout(Duration::from_millis(250), resp.chunk()).await {
                Err(_) => {
                    if quiet_since.elapsed() > STALL {
                        return self.failed(&parts, "Zeitüberschreitung.");
                    }
                }
                Ok(Err(e)) => return self.failed(&parts, e.to_string()),
                Ok(Ok(Some(chunk))) => {
                    quiet_since = Instant::now();
                    if std::io::Write::write_all(&mut file, &chunk).is_err() {
                        return self.failed(&parts, "Die Datei liess sich nicht ablegen.");
                    }
                    loaded += i64::try_from(chunk.len()).unwrap_or(0);
                    if last.elapsed() >= Duration::from_millis(200) {
                        last = Instant::now();
                        self.emit(TransferEvent::Progress {
                            parts: parts.clone(),
                            loaded,
                            total,
                            now: now(),
                        });
                    }
                }
                Ok(Ok(None)) => break,
            }
        }
        let _ = std::io::Write::flush(&mut file);
        drop(file);
        let worked = std::fs::rename(&part, &done).is_ok();
        let real_size = std::fs::metadata(&done)
            .ok()
            .and_then(|m| i64::try_from(m.len()).ok());
        self.lock_tasks().remove(&parts.id);
        self.emit(TransferEvent::Finished {
            parts,
            worked,
            real_size,
        });
    }

    fn fetch_image(self: &Arc<Self>, name: String, url: String) {
        let me = Arc::clone(self);
        self.rt.spawn(async move {
            let Ok(r) = me.http.get(&url).send().await else {
                return;
            };
            if !r.status().is_success() {
                return;
            }
            if let Ok(bytes) = r.bytes().await {
                let _ = std::fs::create_dir_all(&me.dir);
                let _ = std::fs::write(me.dir.join(&name), &bytes);
            }
        });
    }

    fn persist(&self, items: Vec<DownloadItem>) {
        let existing = load_list(std::fs::read(self.list_path()).ok().as_deref()).items;
        let all = merge_for_write(existing, &self.account, items);
        if let Ok(bytes) = encode_list(&all) {
            let _ = swiftly_atomic::write(&self.list_path(), &bytes);
        }
    }
}

impl DownloadTransport for Files {
    fn start(&self, parts: &TaskParts, address: &str, _resume: Option<&[u8]>) {
        let ctl = Arc::new(Ctl::default());
        if let Some(old) = self
            .0
            .lock_tasks()
            .insert(parts.id.clone(), Arc::clone(&ctl))
        {
            old.stop.store(true, Ordering::SeqCst);
        }
        let (me, parts, address) = (Arc::clone(&self.0), parts.clone(), address.to_owned());
        self.0.rt.spawn(me.transfer(parts, address, ctl));
    }

    fn cancel(
        &self,
        id: &str,
        _task_generation: Option<i64>,
        new_generation: i64,
        want_resume_data: bool,
    ) {
        if let Some(ctl) = self.0.lock_tasks().remove(id) {
            if want_resume_data {
                *ctl.resume_generation
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner) = Some(new_generation);
            }
            ctl.stop.store(true, Ordering::SeqCst);
        }
    }

    fn resume(&self, _id: &str) {}

    fn running(&self) -> Vec<RunningTransfer> {
        Vec::new()
    }
}

impl DownloadServices for Files {
    fn run(&self, effect: &Effect) {
        let me = &self.0;
        match effect {
            Effect::Persist(items) => me.persist(items.clone()),
            Effect::RequestAddress {
                id,
                generation,
                source,
                quality,
                audio_index,
            } => {
                let intent = match (me.resolver)(id, source.as_deref(), *quality, *audio_index) {
                    Ok(address) => Intent::AddressReady {
                        id: id.clone(),
                        generation: *generation,
                        address,
                    },
                    Err(reason) => Intent::AddressFailed {
                        id: id.clone(),
                        generation: *generation,
                        reason,
                    },
                };
                me.engine(intent);
            }
            Effect::FindRunningTransfers => me.engine(Intent::RunningTransfers(Vec::new())),
            Effect::DeleteFile { kind, name } => {
                let path = me.dir.join(name);
                match kind {
                    FileKind::Subtitles => {
                        let _ = std::fs::remove_dir_all(&path);
                    }
                    FileKind::Media | FileKind::Image => {
                        let _ = std::fs::remove_file(&path);
                        let _ = std::fs::remove_file(me.part_path(name));
                    }
                }
            }
            Effect::FetchImage { name, url } => me.fetch_image(name.clone(), url.clone()),
            Effect::MeasureSpace => me.engine(Intent::SpaceChanged(free_bytes(&me.dir))),
            Effect::Report(Report::Log(line)) => eprintln!("downloads: {line}"),
            Effect::FetchSubtitles { item } => me.fetch_subtitles(item),
            // Skip sections and the next-episode lookup are not fetched yet (see real-app.md).
            _ => {}
        }
    }
}

/// The view model over a file store in `dir` for `account`. The list is read from `liste.json`, then the machine ticks.
pub fn build(
    dir: PathBuf,
    account: &str,
    rt: tokio::runtime::Handle,
    resolver: Resolver,
) -> DownloadsVm<Dyn> {
    build_with(dir, account, rt, resolver, None)
}

/// [`build`] with the lookup of the subtitle files that travel with a finished title.
pub fn build_with(
    dir: PathBuf,
    account: &str,
    rt: tokio::runtime::Handle,
    resolver: Resolver,
    subtitles: Option<SubtitleLister>,
) -> DownloadsVm<Dyn> {
    let http = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .build()
        .unwrap_or_default();
    let inner = Arc::new(Inner {
        dir: dir.clone(),
        account: account.to_owned(),
        rt,
        http,
        resolver,
        subtitles,
        vm: OnceLock::new(),
        tasks: Mutex::new(HashMap::new()),
    });
    let files = Files(inner);
    let machine =
        DownloadManagerState::new(1, true, false, Box::new(swiftly_vm::TrackNames::german()));
    let vm = DownloadsVm::new(
        Arc::new(Dyn(Arc::new(files.clone()))),
        Arc::new(files.clone()),
        Locale::parse("de"),
        machine,
        true,
    );
    let _ = files.0.vm.set(vm.clone());
    let stored = load_list(std::fs::read(dir.join("liste.json")).ok().as_deref()).items;
    for intent in [
        Intent::SignIn {
            account: Some(account.to_owned()),
            stored,
            client: true,
        },
        // Online until the watcher (`start_watch`, polled every few seconds) says otherwise.
        Intent::NetworkChanged {
            wlan: true,
            none: false,
        },
        Intent::RunningTransfers(Vec::new()),
        Intent::SpaceChanged(free_bytes(&dir)),
        Intent::Tick,
        // What a finished title still owed when the app last closed (its subtitle files, its chapter sections) is
        // asked for again, as the Mac does after every server pass (`downloads.sectionsCatchUp()`,
        // `AppModel.swift:1769`). Without it a stored "pending" never cleared and the row stayed "L\u{00E4}dt gerade".
        Intent::SectionsCatchUp,
    ] {
        let _ = vm.send(DownloadsIntent::Engine(Box::new(intent)));
    }
    vm
}

/// The `DownloadConversion` of a level (`None` for the original).
fn conversion(q: DownloadQuality) -> Option<DownloadConversion> {
    Some(DownloadConversion {
        video_bitrate: q.image_bitrate()?,
        audio_bitrate: q.audio_bitrate()?,
        height: q.height()?,
        width: q.width()?,
        channels: q.audio_channels()?,
    })
}

const NO_ADDRESS: &str = "Keine Adresse vom Server.";

/// The address of a download from the server of `account`, whatever its kind: the quality levels of Jellyfin/Emby, the
/// original file of Plex (its address carries the `X-Plex-Token`). The Plex lookup reads the title once (the client
/// caches it), so the caller waits for that one answer.
pub fn resolver_for(core: &Core, account: &AccountRef) -> Resolver {
    let server = core.server_for(account).ok();
    let handle = core.handle();
    Arc::new(
        move |id, source, quality, audio| match server.as_ref().ok_or(NO_ADDRESS)? {
            ServerClient::Jellyfin(c) => c
                .download_url(id, source, conversion(quality), audio)
                .map(|u| u.to_string())
                .map_err(|_| NO_ADDRESS.to_owned()),
            ServerClient::Plex(c) => {
                let (tx, rx) = std::sync::mpsc::channel();
                let (c, id, source) = (Arc::clone(c), id.to_owned(), source.map(str::to_owned));
                handle.spawn(async move {
                    let _ = tx.send(
                        MediaServer::download_url(&*c, &id, source.as_deref(), quality, audio)
                            .await,
                    );
                });
                rx.recv_timeout(Duration::from_secs(30))
                    .map_err(|_| NO_ADDRESS.to_owned())?
                    .map_err(|_| NO_ADDRESS.to_owned())
            }
        },
    )
}

type Slot = Mutex<Option<(String, DownloadsVm<Dyn>)>>;
static SHARED: OnceLock<Slot> = OnceLock::new();
static WATCH: OnceLock<()> = OnceLock::new();

/// Starts the one thread that polls the network watcher and tells the current view model when the answer changes
/// (the machine then shows "Wartet auf Netz" and picks the waiting titles up again when the network returns).
fn start_watch() {
    WATCH.get_or_init(|| {
        std::thread::spawn(|| {
            let mut pump = Pump::new();
            let mut pumped: Option<String> = None;
            loop {
                let current = SHARED
                    .get()
                    .and_then(|s| s.lock().unwrap_or_else(PoisonError::into_inner).clone());
                if let Some((key, vm)) = current {
                    if pumped.as_deref() != Some(key.as_str()) {
                        // A rebuilt view model starts online: report again.
                        pump = Pump::new();
                        pumped = Some(key);
                    }
                    pump.poll(&SystemWatcher, &vm);
                }
                std::thread::sleep(Duration::from_secs(4));
            }
        });
    });
}

/// The one downloads view model of the running app (rebuilt when the account changes).
pub fn shared(core: &Core, account: &AccountRef) -> DownloadsVm<Dyn> {
    start_watch();
    let key = account.key();
    let mut slot = SHARED
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    if let Some((k, vm)) = slot.as_ref()
        && *k == key
    {
        catch_up_covers(core, account, vm);
        return vm.clone();
    }
    let resolver = resolver_for(core, account);
    let vm = build_with(
        downloads_dir(),
        &key,
        core.handle(),
        resolver,
        core.subtitle_lister(account),
    );
    // The stored "Nur über WLAN" and "Nächste Folge laden" go to the engine (`AppModel.init` does this on the Mac).
    crate::settings_run::push_download_settings(&vm, &*core.settings);
    catch_up_covers(core, account, &vm);
    *slot = Some((key, vm.clone()));
    vm
}

/// The poster of title `id` as the Mac's fallback asks for it (`AppModel.posterURL(itemID:)`: the primary picture, 300 high,
/// no tag).
fn bare_poster_address<T: swiftly_net::HttpTransport + 'static>(
    server: &ServerClient<T>,
    id: &str,
) -> Option<String> {
    use swiftly_images::{ImageAddress, ImageKind, ImageMetric, Url};
    let token = server.current_session()?.access_token;
    let base = Url::parse(&server.base_url()).ok()?;
    ImageAddress::new(base, Some(token), server.kind())
        .construct(id, ImageKind::Poster, None, ImageMetric::AtMostHigh(300))
        .map(|u| u.to_string())
}

/// The saved covers `items` lack, as (file name, address) pairs: a title's own picture and its series' poster, each once.
/// A title the engine saved nothing for (downloaded before the pictures went along, or the fetch failed) gets the online
/// poster the Mac shows instead (`MacDownloads.imageAddressValue`).
fn missing_covers(
    dir: &Path,
    items: &[DownloadItem],
    address: &dyn Fn(&str) -> Option<String>,
) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for item in items {
        for id in std::iter::once(&item.id).chain(item.series_identifier.as_ref()) {
            let name = DownloadItem::image_name(&item.account, id);
            if dir.join(&name).exists() || out.iter().any(|(n, _)| *n == name) {
                continue;
            }
            if let Some(url) = address(id) {
                out.push((name, url));
            }
        }
    }
    out
}

/// Saves the online poster of every download that has no saved cover (see [`missing_covers`]), in the background. The page
/// reads the file from disk, so the row shows the picture from the next look on, and offline from then on too.
fn catch_up_covers(core: &Core, account: &AccountRef, vm: &DownloadsVm<Dyn>) {
    static ASKED: OnceLock<Mutex<std::collections::HashSet<String>>> = OnceLock::new();
    let Ok(server) = core.server_for(account) else {
        return;
    };
    let dir = downloads_dir();
    let lacking = missing_covers(&dir, &vm.entries(), &|id| bare_poster_address(&server, id));
    let asked = ASKED.get_or_init(Default::default);
    let lacking: Vec<(String, String)> = lacking
        .into_iter()
        .filter(|(name, _)| {
            asked
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(name.clone())
        })
        .collect();
    if lacking.is_empty() {
        return;
    }
    core.spawn(async move {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(60))
            .build()
            .unwrap_or_default();
        for (name, url) in lacking {
            let Ok(r) = http.get(&url).send().await else {
                continue;
            };
            if !r.status().is_success() {
                continue;
            }
            if let Ok(bytes) = r.bytes().await {
                let _ = std::fs::create_dir_all(&dir);
                let _ = swiftly_atomic::write(&dir.join(&name), &bytes);
            }
        }
    });
}

/// The finished download `id` of `account`: the item and the path of its file.
pub fn finished(dir: &Path, account: &str, id: &str) -> Option<(DownloadItem, PathBuf)> {
    let items = load_list(std::fs::read(dir.join("liste.json")).ok().as_deref()).items;
    let item = items.into_iter().find(|i| {
        i.account == account && i.id == id && i.state == swiftly_downloads::DownloadState::Done
    })?;
    let path = dir.join(item.file_name());
    path.is_file().then_some((item, path))
}

// ---- the season sheet of a series ------------------------------------------------------------------------------------

/// Where the seasons and episodes of a series come from (the server; a fake in tests). Calls block.
pub trait SeasonSource: Send + Sync {
    /// The seasons of the series in display order (`None`: the request failed).
    fn seasons(&self, series: &str) -> Option<Vec<swiftly_model::Item>>;
    /// The episodes of one season, with their media sources (`None`: the request failed).
    fn episodes(&self, series: &str, season: &str) -> Option<Vec<swiftly_model::Item>>;
    /// The series itself, with its image tags (`None`: not known; its pictures are then not saved along).
    fn series(&self, _series: &str) -> Option<swiftly_model::Item> {
        None
    }
    /// The address of a picture of `item` (`None`: no server, or it has no such picture).
    fn address(&self, _item: &swiftly_model::Item, _look: Look) -> Option<String> {
        None
    }
}

/// The seasons and episodes of a series from the account's server, whatever its kind (Jellyfin/Emby `Shows/{id}/...`,
/// Plex children), through the core's `MediaServer` path: the same client the file downloads use.
struct ServerSeasons {
    client: Arc<crate::live_server::Server>,
    rt: tokio::runtime::Handle,
}

impl SeasonSource for ServerSeasons {
    fn seasons(&self, series: &str) -> Option<Vec<swiftly_model::Item>> {
        match &*self.client {
            ServerClient::Jellyfin(c) => self.rt.block_on(c.seasons(series)).ok(),
            ServerClient::Plex(c) => self.rt.block_on(MediaServer::seasons(&**c, series)).ok(),
        }
    }
    fn episodes(&self, series: &str, season: &str) -> Option<Vec<swiftly_model::Item>> {
        match &*self.client {
            ServerClient::Jellyfin(c) => self.rt.block_on(c.episodes(series, Some(season))).ok(),
            ServerClient::Plex(c) => self
                .rt
                .block_on(MediaServer::episodes(&**c, series, Some(season)))
                .ok(),
        }
    }
    fn series(&self, series: &str) -> Option<swiftly_model::Item> {
        self.rt
            .block_on(crate::live_server::item(&self.client, series))
            .ok()
    }
    fn address(&self, item: &swiftly_model::Item, look: Look) -> Option<String> {
        picture_address(&self.client, item, look)
    }
}

enum Msg {
    /// The seasons, and the series item when the server gave it.
    Seasons(
        Option<Vec<swiftly_model::Item>>,
        Option<Box<swiftly_model::Item>>,
    ),
    Episodes(String, Option<Vec<swiftly_model::Item>>),
}

/// What one [`SeasonRead::poll`] asks the host to do with the Downloads page.
#[derive(Default)]
pub struct SeasonPoll {
    /// The seasons are known: open the season sheet with this request (the Downloads page comes first if needed).
    pub open: Option<crate::load_sheets::LoadRequest>,
    /// Seasons that were read (`None`: failed), for `season_loaded`.
    pub loaded: Vec<(String, Option<Vec<swiftly_model::Item>>)>,
    /// Every season has been tried: call `season_finished`.
    pub finished: bool,
    /// The read is over (done, failed or the sheet was closed): drop it.
    pub gone: bool,
}

/// The live feed of `LoadRequest::Season` for one series: reads the seasons, opens the sheet, then answers
/// `season_pending` batches with the episodes of each season.
pub struct SeasonRead {
    source: Arc<dyn SeasonSource>,
    series: swiftly_model::Item,
    account: String,
    anchor: Option<swiftly_layout::Rect>,
    pictures: Pictures,
    tx: std::sync::mpsc::Sender<Msg>,
    rx: std::sync::mpsc::Receiver<Msg>,
    requested: std::collections::HashSet<String>,
    answered: usize,
    opened: bool,
}

impl SeasonRead {
    /// Starts reading the seasons of series `id` off-thread.
    pub fn start(
        source: Arc<dyn SeasonSource>,
        id: &str,
        name: &str,
        account: &str,
        anchor: Option<swiftly_layout::Rect>,
    ) -> SeasonRead {
        let (tx, rx) = std::sync::mpsc::channel();
        let series = swiftly_model::Item {
            id: id.to_owned(),
            name: name.to_owned(),
            ..swiftly_model::Item::default()
        };
        let (src, me, out) = (Arc::clone(&source), id.to_owned(), tx.clone());
        // The seasons and the series item (its image tags) are asked for side by side.
        std::thread::spawn(move || {
            let (seasons, item) = std::thread::scope(|scope| {
                let item = scope.spawn(|| src.series(&me));
                (src.seasons(&me), item.join().ok().flatten())
            });
            let _ = out.send(Msg::Seasons(seasons, item.map(Box::new)));
        });
        let for_pictures = Arc::clone(&source);
        SeasonRead {
            source,
            series,
            account: account.to_owned(),
            anchor,
            pictures: Pictures::new(move |item, look| for_pictures.address(item, look)),
            tx,
            rx,
            requested: Default::default(),
            answered: 0,
            opened: false,
        }
    }

    /// Takes what has arrived. `sheet_open` and `pending` (`season_pending` flattened) are the Downloads page's state
    /// before this poll's answers are applied.
    pub fn poll(&mut self, sheet_open: bool, pending: &[String]) -> SeasonPoll {
        let mut out = SeasonPoll::default();
        while let Ok(m) = self.rx.try_recv() {
            match m {
                Msg::Seasons(Some(seasons), item) => {
                    self.opened = true;
                    // The name the page knew stays; the item brings the image tags.
                    if let Some(item) = item {
                        self.series = swiftly_model::Item {
                            name: self.series.name.clone(),
                            ..*item
                        };
                    }
                    out.open = Some(crate::load_sheets::LoadRequest::Season {
                        account: self.account.clone(),
                        series: Box::new(self.series.clone()),
                        seasons,
                        episodes: std::collections::HashMap::new(),
                        quality_select: true,
                        anchor: self.anchor,
                        pictures: self.pictures.clone(),
                    });
                }
                Msg::Seasons(None, _) => out.gone = true,
                Msg::Episodes(id, list) => {
                    self.answered += 1;
                    out.loaded.push((id, list));
                }
            }
        }
        if out.open.is_some() || !self.opened {
            return out;
        }
        if !sheet_open {
            // The user closed the sheet: late answers fall away.
            out.gone = true;
            return out;
        }
        for id in pending {
            if self.requested.insert(id.clone()) {
                let (src, series, season, tx) = (
                    Arc::clone(&self.source),
                    self.series.id.clone(),
                    id.clone(),
                    self.tx.clone(),
                );
                std::thread::spawn(move || {
                    let _ = tx.send(Msg::Episodes(
                        season.clone(),
                        src.episodes(&series, &season),
                    ));
                });
            }
        }
        if pending.iter().all(|p| self.requested.contains(p))
            && self.answered >= self.requested.len()
            && out.loaded.is_empty()
        {
            out.finished = true;
            out.gone = true;
        }
        out
    }
}

/// A season read of series `id` over the server of `account` (`None` without a client).
pub fn season_read(
    core: &Core,
    account: &AccountRef,
    id: &str,
    name: &str,
    anchor: Option<swiftly_layout::Rect>,
) -> Option<SeasonRead> {
    let client = Arc::new(core.server_for(account).ok()?);
    let source = Arc::new(ServerSeasons {
        client,
        rt: core.handle(),
    });
    Some(SeasonRead::start(source, id, name, &account.key(), anchor))
}

// ---- the add sheet of a film ---------------------------------------------------------------------------------------------

/// The add sheet's request for a live title: its size, container, source and audio tracks come from the server's item.
pub fn film_request(
    item: &swiftly_model::Item,
    account: &str,
    now: f64,
    anchor: Option<swiftly_layout::Rect>,
    poster: Option<String>,
) -> crate::load_sheets::LoadRequest {
    let src = swiftly_downloads::item::first_source(item);
    let mut d = DownloadItem::new(
        item.id.clone(),
        account,
        Art::Film,
        item.name.clone(),
        src.and_then(|s| s.size).unwrap_or(0),
        now,
    );
    d.runtime_ticks = item.run_time_ticks;
    d.container = src.and_then(|s| s.container.clone());
    d.source = src.and_then(|s| s.id.clone());
    crate::load_sheets::LoadRequest::Add {
        // The bare title: the sheet adds " laden" itself (`MacDownloads.swift:269`).
        title: item.name.clone(),
        // The poster the engine saves along (`DetailView.loadImages`), so the finished row shows its cover.
        images: poster
            .map(|url| HashMap::from([(item.id.clone(), url)]))
            .unwrap_or_default(),
        items: vec![d],
        quality_select: true,
        streams: vec![swiftly_downloads::item::audio_streams(src)],
        anchor,
    }
}

/// The width the series' header image is asked for: what the series page of Downloads needs at 2x
/// (`DownloadSeriesOverviewPage.headerPixel`, the Mac's 62 % hero at its minimum).
const HEADER_PIXELS: i64 = 2016;

/// The address of a picture of `item` on `server` (`AppModel.imageURL`, `headerImageURL`): what the engine fetches along
/// as the saved cover. The image rules are the Mac's (`ImageSelection`).
fn picture_address<T: swiftly_net::HttpTransport + 'static>(
    server: &ServerClient<T>,
    item: &swiftly_model::Item,
    look: Look,
) -> Option<String> {
    use swiftly_images::{ImageAddress, ImageKind, ImageMetric, ImageSelection, Url};
    let token = server.current_session()?.access_token;
    let base = Url::parse(&server.base_url()).ok()?;
    let addresses = ImageAddress::new(base, Some(token), server.kind());
    match look {
        Look::Poster => ImageSelection::portrait(item, &addresses, 600),
        Look::Header => ImageSelection::header(item, &addresses, HEADER_PIXELS),
        Look::Still => {
            let mark = item.image_tags.as_ref()?.get("Primary")?.clone();
            addresses.construct(
                &item.id,
                ImageKind::Poster,
                Some(&mark),
                ImageMetric::AtMostHigh(220),
            )
        }
    }
    .map(|u| u.to_string())
}

/// The poster address of `item` on `server` (`AppModel.posterURL`): what the engine fetches along as the saved cover.
fn poster_address<T: swiftly_net::HttpTransport + 'static>(
    server: &ServerClient<T>,
    item: &swiftly_model::Item,
) -> Option<String> {
    picture_address(server, item, Look::Poster)
}

/// The live read behind a film's "Laden": the item comes off-thread, then `poll` yields the request once.
pub struct FilmRead {
    rx: std::sync::mpsc::Receiver<Option<crate::load_sheets::LoadRequest>>,
}

impl FilmRead {
    /// Polls: `Ok(Some)` the request, `Ok(None)` not yet, `Err` the read failed (dropped).
    ///
    /// # Errors
    /// The server did not answer for the title.
    #[allow(clippy::result_unit_err)] // the only failure is "the server did not answer"
    pub fn poll(&self) -> Result<Option<crate::load_sheets::LoadRequest>, ()> {
        match self.rx.try_recv() {
            Ok(Some(r)) => Ok(Some(r)),
            Ok(None) | Err(std::sync::mpsc::TryRecvError::Disconnected) => Err(()),
            Err(std::sync::mpsc::TryRecvError::Empty) => Ok(None),
        }
    }
}

/// A film read of title `id` over the server of `account` (`None` without a client).
pub fn film_read(
    core: &Core,
    account: &AccountRef,
    id: &str,
    anchor: Option<swiftly_layout::Rect>,
) -> Option<FilmRead> {
    let server = core.server_for(account).ok()?;
    let (tx, rx) = std::sync::mpsc::channel();
    let (id, key) = (id.to_owned(), account.key());
    core.spawn(async move {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        let request = crate::live_server::item(&server, &id).await.ok().map(|i| {
            let poster = poster_address(&server, &i);
            film_request(&i, &key, now, anchor, poster)
        });
        let _ = tx.send(request);
    });
    Some(FilmRead { rx })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use swiftly_downloads::DownloadState;
    use swiftly_vm::RowState;

    #[test]
    fn a_title_without_a_saved_cover_gets_the_online_poster_once() {
        let dir = std::env::temp_dir().join(format!("swiftly-catchup-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut a = DownloadItem::new("e1", "acc", Art::Episode, "Folge 1", 1, 1.0);
        a.series_identifier = Some("s1".into());
        let mut b = DownloadItem::new("e2", "acc", Art::Episode, "Folge 2", 1, 1.0);
        b.series_identifier = Some("s1".into());
        let film = DownloadItem::new("f1", "acc", Art::Film, "Film", 1, 1.0);
        // The film's cover is there already.
        std::fs::write(dir.join(DownloadItem::image_name("acc", "f1")), b"x").unwrap();
        let url = |id: &str| Some(format!("http://s/{id}.jpg"));
        let got = missing_covers(&dir, &[a, b, film], &url);
        let ids: Vec<&str> = got.iter().map(|(_, u)| u.as_str()).collect();
        assert_eq!(
            ids,
            ["http://s/e1.jpg", "http://s/s1.jpg", "http://s/e2.jpg"],
            "each missing picture once, the series poster shared, the film left alone"
        );
        assert_eq!(got[0].0, DownloadItem::image_name("acc", "e1"));
        assert!(missing_covers(&dir, &[], &url).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_film_request_carries_size_source_and_audio_of_the_live_item() {
        let item: swiftly_model::Item = serde_json::from_str(
            r#"{"Id":"g1","Name":"Player-Extras","Type":"Movie","RunTimeTicks":120000000,"MediaSources":[{"Id":"srcg1","Container":"mkv","Size":4200,"MediaStreams":[{"Type":"Audio","Codec":"aac","Index":1,"Language":"eng"},{"Type":"Audio","Codec":"ac3","Index":2,"Language":"deu"}]}]}"#,
        )
        .unwrap();
        let crate::load_sheets::LoadRequest::Add {
            title,
            items,
            quality_select,
            streams,
            images,
            ..
        } = film_request(&item, "acc", 5.0, None, Some("http://s/p.jpg".into()))
        else {
            panic!("an add request")
        };
        assert_eq!(title, "Player-Extras", "the sheet adds \" laden\" itself");
        assert!(quality_select);
        assert_eq!(
            (
                items[0].bytes,
                items[0].container.as_deref(),
                items[0].source.as_deref(),
                items[0].account.as_str()
            ),
            (4200, Some("mkv"), Some("srcg1"), "acc")
        );
        assert_eq!(streams[0].len(), 2);
        // The poster goes along, or the finished row has no cover to show.
        assert_eq!(images.get("g1").map(String::as_str), Some("http://s/p.jpg"));
    }

    /// A tiny server for one file with `Range` support; `slow` sends the body in pieces with pauses.
    fn serve(body: Vec<u8>, slow: bool) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let body = body.clone();
                std::thread::spawn(move || {
                    let mut s = stream;
                    let mut buf = [0u8; 4096];
                    let n = s.read(&mut buf).unwrap_or(0);
                    let head = String::from_utf8_lossy(&buf[..n]).to_string();
                    let from = head.lines().find_map(|l| {
                        l.to_ascii_lowercase()
                            .strip_prefix("range: bytes=")
                            .and_then(|r| r.trim_end_matches('-').parse::<usize>().ok())
                    });
                    let (code, slice) = match from {
                        Some(f) if f < body.len() => ("206 Partial Content", &body[f..]),
                        _ => ("200 OK", &body[..]),
                    };
                    let _ = write!(
                        s,
                        "HTTP/1.1 {code}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        slice.len()
                    );
                    for piece in slice.chunks(if slow { 20_000 } else { 1 << 20 }) {
                        if s.write_all(piece).is_err() {
                            return;
                        }
                        if slow {
                            std::thread::sleep(Duration::from_millis(60));
                        }
                    }
                });
            }
        });
        format!("http://{addr}/v.mkv")
    }

    fn item(id: &str, bytes: i64) -> DownloadItem {
        let mut i = DownloadItem::new(id, "acc", Art::Film, "Film", bytes, 1.0);
        i.container = Some("mkv".into());
        i
    }

    fn wait(vm: &DownloadsVm<Dyn>, what: &str, ok: impl Fn(&DownloadsVm<Dyn>) -> bool) {
        let t = Instant::now();
        while !ok(vm) {
            assert!(t.elapsed() < Duration::from_secs(20), "timeout: {what}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn setup(url: String, name: &str) -> (tokio::runtime::Runtime, PathBuf, DownloadsVm<Dyn>) {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let dir = std::env::temp_dir().join(format!("swiftly-dl-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let resolver: Resolver = Arc::new(move |_, _, _, _| Ok(url.clone()));
        let vm = build(dir.clone(), "acc", rt.handle().clone(), resolver);
        (rt, dir, vm)
    }

    fn add(vm: &DownloadsVm<Dyn>, id: &str, bytes: i64) {
        vm.send(DownloadsIntent::Start {
            items: vec![item(id, bytes)],
            images: HashMap::new(),
            check_space: false,
        })
        .unwrap();
    }

    fn state(vm: &DownloadsVm<Dyn>) -> Option<RowState> {
        vm.list()
            .rows
            .first()
            .and_then(|r| r.items.first())
            .map(|i| i.state)
    }

    #[test]
    fn downloads_a_file_lists_it_and_deletes_it() {
        let body: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let (_rt, dir, vm) = setup(serve(body.clone(), false), "full");
        add(&vm, "m1", body.len() as i64);
        wait(&vm, "done", |v| state(v) == Some(RowState::Done));
        let file = dir.join(item("m1", 0).file_name());
        assert_eq!(std::fs::read(&file).unwrap(), body);
        assert_eq!(vm.storage().count, 1);
        // The list file is written after the row shows Done: wait for it instead of reading it at once.
        let persisted = |dir: &std::path::Path| {
            load_list(std::fs::read(dir.join("liste.json")).ok().as_deref()).items
        };
        wait(&vm, "list file says done", |_| {
            persisted(&dir)
                .first()
                .is_some_and(|d| d.state == DownloadState::Done)
        });
        let listed = persisted(&dir);
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].state, DownloadState::Done);
        assert!(finished(&dir, "acc", "m1").is_some());
        vm.send(DownloadsIntent::Delete(vec!["m1".into()])).unwrap();
        wait(&vm, "deleted", |v| v.list().rows.is_empty());
        wait(&vm, "file gone", |_| !file.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// L10: the catalogue says 1.5 MB, the stream ends after 139 KB (and a subtitle fetch that did not finish before the
    /// app closed). The title is finished when the stream ends, and after a restart it is a finished row again, not
    /// "Lädt gerade": the start sends the catch-up the Mac sends after its server pass (`sectionsCatchUp`).
    #[test]
    fn a_size_mismatch_and_a_restart_still_leave_a_finished_title() {
        let body: Vec<u8> = (0..139_068u32).map(|i| (i % 251) as u8).collect();
        let (rt, dir, vm) = setup(serve(body.clone(), false), "mismatch");
        add(&vm, "m1", 1_500_000);
        wait(&vm, "done", |v| state(v) == Some(RowState::Done));
        // The app is closed before the subtitle answer arrived: the list keeps `subtitles_pending`.
        wait(&vm, "list file says done", |_| {
            load_list(std::fs::read(dir.join("liste.json")).ok().as_deref())
                .items
                .first()
                .is_some_and(|d| d.state == DownloadState::Done)
        });
        let mut stored = load_list(std::fs::read(dir.join("liste.json")).ok().as_deref()).items;
        stored[0].subtitles_pending = true;
        std::fs::write(
            dir.join("liste.json"),
            swiftly_downloads::list::encode_list(&stored).unwrap(),
        )
        .unwrap();
        drop(vm);
        let resolver: Resolver = Arc::new(|_, _, _, _| Err("offline".to_owned()));
        let vm = build(dir.clone(), "acc", rt.handle().clone(), resolver);
        wait(&vm, "finished again after the restart", |v| {
            state(v) == Some(RowState::Done)
        });
        let (item, path) = finished(&dir, "acc", "m1").expect("playable");
        assert_eq!(std::fs::read(path).unwrap(), body);
        assert!(
            !item.subtitles_pending,
            "the pending subtitle fetch ran again"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_finished_download_takes_its_subtitle_files_along() {
        let body: Vec<u8> = (0..50_000u32).map(|i| (i % 251) as u8).collect();
        let cues = b"1\n00:00:01,000 --> 00:00:02,000\nHallo\n".to_vec();
        let (cue_url, media) = (
            serve(cues.clone(), false).replace("v.mkv", "Stream.srt?api_key=x"),
            serve(body.clone(), false),
        );
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let dir = std::env::temp_dir().join(format!("swiftly-dl-subs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let resolver: Resolver = Arc::new(move |_, _, _, _| Ok(media.clone()));
        let lister: SubtitleLister = Arc::new(move |_, _, _| {
            let url = cue_url.clone();
            Box::pin(async move {
                vec![(
                    3,
                    url,
                    "srt".to_owned(),
                    swiftly_vm::subtitle_sidecar::SubtitleMeta {
                        index: 3,
                        language: Some("eng".into()),
                        codec: Some("subrip".into()),
                        ..Default::default()
                    },
                )]
            })
        });
        let vm = build_with(
            dir.clone(),
            "acc",
            rt.handle().clone(),
            resolver,
            Some(lister),
        );
        add(&vm, "m9", body.len() as i64);
        wait(&vm, "done", |v| state(v) == Some(RowState::Done));
        let file = dir
            .join(item("m9", 0).file_name())
            .with_file_name(item("m9", 0).subtitle_folder_name())
            .join("3.srt");
        let t = Instant::now();
        while !file.is_file() && t.elapsed() < Duration::from_secs(10) {
            std::thread::sleep(Duration::from_millis(50));
        }
        assert_eq!(
            std::fs::read(&file).unwrap_or_default(),
            cues,
            "the subtitle file lies next to the title"
        );
        let t = Instant::now();
        while !file.with_file_name("info.json").is_file() && t.elapsed() < Duration::from_secs(10) {
            std::thread::sleep(Duration::from_millis(50));
        }
        let streams = swiftly_vm::subtitle_sidecar::streams(file.parent().unwrap());
        assert_eq!(
            streams[0].language.as_deref(),
            Some("eng"),
            "what the file is is stored with it"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pause_then_resume_continues_with_range() {
        let body: Vec<u8> = (0..400_000u32).map(|i| (i % 253) as u8).collect();
        let (_rt, dir, vm) = setup(serve(body.clone(), true), "pause");
        add(&vm, "m2", body.len() as i64);
        wait(&vm, "some bytes", |v| {
            v.list()
                .rows
                .first()
                .and_then(|r| r.progress)
                .is_some_and(|p| p > 0.0)
        });
        vm.send(DownloadsIntent::Pause("m2".into())).unwrap();
        wait(&vm, "paused", |v| state(v) == Some(RowState::Paused));
        let name = item("m2", 0).file_name();
        let kept = std::fs::metadata(dir.join(format!("{name}.part")))
            .unwrap()
            .len();
        assert!(kept > 0 && (kept as usize) < body.len(), "kept {kept}");
        vm.send(DownloadsIntent::Resume("m2".into())).unwrap();
        wait(&vm, "done", |v| state(v) == Some(RowState::Done));
        assert_eq!(std::fs::read(dir.join(name)).unwrap(), body);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The free space is the real figure of the volume, never the "plenty" stand-in (it read "2,31 EB" on Windows).
    #[test]
    fn free_space_is_the_volume_figure_not_the_stand_in() {
        let dir = std::env::temp_dir().join("swiftly-free-space-probe");
        let free = free_bytes(&dir);
        let _ = std::fs::remove_dir_all(&dir);
        assert!(free > 0, "{free}");
        assert!(free < i64::MAX / 4, "stand-in value: {free}");
    }
}
