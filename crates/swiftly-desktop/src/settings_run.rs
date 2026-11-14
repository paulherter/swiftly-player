//! What the desktop does when a setting changes, the way the Mac does it (`SettingsRowsFeed.written()`,
//! `AppModel.downloadsAn`, `SettingsSyncRun.swift`):
//!
//! * [`apply_effect`] runs the effects the settings core hands out: switching Downloads off pauses everything,
//!   "Alles entfernen" deletes every stored download, and "Nur über WLAN" / "Nächste Folge laden" reach the
//!   download engine ([`push_download_settings`] sends the stored values once when the engine is built).
//! * [`start_sync`] keeps the synced settings equal to the other devices through the server's display
//!   preferences (the shared runner is `swiftly_vm::StoreSync`): a run when the account changes, every 20 s, and
//!   2 s after a change made here.
//!
//! There is no mobile data on a PC: like the Mac on Wi-Fi or Ethernet, a connection counts as Wi-Fi
//! (`net_watch.rs`), so "Nur über WLAN" never blocks a connected PC but is carried to the engine all the same.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use swiftly_settings::KeyValueStore;
use swiftly_vm::{
    DownloadsIntent, DownloadsVm, SettingsEffect, StoreSync, SyncRan, stamp_change, synced_values,
};

use crate::downloads_screen::Dyn;

/// Whether the downloads are switched on (`downloadsAn`, off until enabled).
pub fn downloads_on(store: &dyn KeyValueStore) -> bool {
    store.get_bool("downloadsAn").unwrap_or(false)
}

/// "Wi-Fi only" as stored (`nurUeberWLAN`, on at first activation).
pub fn only_over_wlan(store: &dyn KeyValueStore) -> bool {
    store.get_bool("nurUeberWLAN").unwrap_or(true)
}

/// "Load next episode" as stored (`naechsteFolgeLaden`, off by default).
pub fn next_auto(store: &dyn KeyValueStore) -> bool {
    store.get_bool("naechsteFolgeLaden").unwrap_or(false)
}

/// Sends the stored download settings to a freshly built engine (the Mac's `AppModel.init` pushes the same two
/// values into the manager), and pauses everything when the feature is off.
pub fn push_download_settings(vm: &DownloadsVm<Dyn>, store: &dyn KeyValueStore) {
    let _ = vm.send(DownloadsIntent::OnlyOverWlan(only_over_wlan(store)));
    let _ = vm.send(DownloadsIntent::NextAuto(next_auto(store)));
    if !downloads_on(store) {
        let _ = vm.send(DownloadsIntent::PauseAll);
    }
}

/// Runs one effect of the settings core against the download engine.
pub fn apply_effect(vm: &DownloadsVm<Dyn>, store: &dyn KeyValueStore, effect: &SettingsEffect) {
    match effect {
        SettingsEffect::DownloadsSwitched { on: false } => {
            crate::desk::set_downloads_on(false);
            let _ = vm.send(DownloadsIntent::PauseAll);
        }
        SettingsEffect::DownloadsSwitched { on: true } => {
            crate::desk::set_downloads_on(true);
            // Back on: the stored rules go to the engine again (the watcher keeps running on the desktop).
            let _ = vm.send(DownloadsIntent::OnlyOverWlan(only_over_wlan(store)));
        }
        SettingsEffect::DeleteDownloads => {
            let _ = vm.send(DownloadsIntent::DeleteAll);
        }
        SettingsEffect::Changed { key, .. } => match key.as_str() {
            "nurUeberWLAN" => {
                let _ = vm.send(DownloadsIntent::OnlyOverWlan(only_over_wlan(store)));
            }
            "naechsteFolgeLaden" => {
                let _ = vm.send(DownloadsIntent::NextAuto(next_auto(store)));
            }
            _ => {}
        },
    }
}

/// The synced values by name as they are stored now (what a run compares).
fn snapshot(store: &dyn KeyValueStore, suffix: &str) -> HashMap<String, String> {
    synced_values(store, suffix).into_iter().collect()
}

/// What the loop learns when it looks at the store: `true` when the synced values differ from the last look.
/// The first look is the baseline and counts as no change.
#[derive(Default)]
pub struct Watch {
    last: Option<HashMap<String, String>>,
}

impl Watch {
    /// Looks at the store; returns whether the user changed a synced value since the last look.
    pub fn changed(&mut self, store: &dyn KeyValueStore, suffix: &str) -> bool {
        let now = snapshot(store, suffix);
        let changed = self.last.as_ref().is_some_and(|l| *l != now);
        self.last = Some(now);
        changed
    }

    /// Takes the current values as the baseline (after a run wrote values into the store, or the account changed).
    pub fn rebase(&mut self, store: &dyn KeyValueStore, suffix: &str) {
        self.last = Some(snapshot(store, suffix));
    }
}

/// The seconds between two runs while the app runs (`SettingsSyncRun.pollEvery`).
pub const POLL: Duration = Duration::from_secs(20);
/// The wait after a local change (`request(after: .seconds(2))`).
pub const AFTER_CHANGE: Duration = Duration::from_secs(2);

fn now_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

static SYNC: OnceLock<()> = OnceLock::new();
static RUNNING: Mutex<bool> = Mutex::new(false);

/// Starts the one thread that keeps the synced settings equal across devices for the active account. Safe to call
/// again (it starts once). Only Jellyfin accounts have display preferences.
pub fn start_sync(core: Arc<crate::live::Core>) {
    SYNC.get_or_init(|| {
        std::thread::spawn(move || sync_loop(&core));
    });
}

fn sync_loop(core: &Arc<crate::live::Core>) {
    let store: Arc<dyn KeyValueStore> =
        Arc::<swiftly_settings::JsonFileStore>::clone(&core.settings);
    let mut watch = Watch::default();
    let mut account_seen: Option<String> = None;
    let mut next_run = Instant::now();
    loop {
        std::thread::sleep(Duration::from_millis(500));
        let Some(entry) = core.active_entry() else {
            account_seen = None;
            continue;
        };
        // Only Jellyfin accounts have display preferences on the server.
        if entry.kind != swiftly_jellyfin::ServerKind::Jellyfin {
            continue;
        }
        if account_seen.as_deref() != Some(entry.key.as_str()) {
            account_seen = Some(entry.key.clone());
            watch.rebase(&*store, &entry.suffix);
            next_run = Instant::now();
        } else if watch.changed(&*store, &entry.suffix) {
            stamp_change(&*store, now_seconds());
            next_run = Instant::now() + AFTER_CHANGE;
        }
        if Instant::now() < next_run {
            continue;
        }
        next_run = Instant::now() + POLL;
        run_now(core, &store, &entry.suffix, &entry.key, &mut watch);
    }
}

/// One run for the active account, on the app's runtime (blocking the sync thread only).
fn run_now(
    core: &Arc<crate::live::Core>,
    store: &Arc<dyn KeyValueStore>,
    suffix: &str,
    key: &str,
    watch: &mut Watch,
) {
    {
        let mut running = RUNNING.lock().unwrap_or_else(PoisonError::into_inner);
        if *running {
            return;
        }
        *running = true;
    }
    if let Some(account) = core.account()
        && let Ok(sync) = swiftly_vm::SettingsSyncCore::new(&core.net, &core.host(), &account)
    {
        let run = StoreSync::new(sync, Arc::clone(store), suffix, key);
        let handle = core.handle();
        let ran = handle.block_on(run.run(now_seconds()));
        if ran == SyncRan::Applied {
            // What the server wrote into the store is not a change of the user's.
            watch.rebase(&**store, suffix);
        }
    }
    *RUNNING.lock().unwrap_or_else(PoisonError::into_inner) = false;
}
