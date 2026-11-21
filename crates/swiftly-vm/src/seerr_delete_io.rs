//! "Vom Server löschen" over one hub, the one implementation for every host: the desktop uses it directly, the UniFFI
//! screen of the Apple and Android apps is a thin export over it. It prepares the sheet (which versions Seerr knows),
//! runs the steps of [`SeerrDeleteVm`] one by one (files, Seerr, library rescan, verify) and keeps the sheet's state.
//! What only the host can do (ask its media server for a title, rescan, wait) comes in as a [`DeleteLibrary`].

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use swiftly_net::HttpTransport;
use swiftly_seerr::{CookieJar, SeerrState};

use crate::seerr_delete::{DeleteAction, SeerrDeleteInfo, SeerrDeleteVm, delete_offered};
use crate::seerr_io::SeerrHub;
use crate::seerr_title::ask_text;

/// A boxed future, as the host's calls return it.
pub type HostFuture<T> = Pin<Box<dyn Future<Output = T> + Send>>;

/// How often "Prüfen" asks the library, and how long it waits between two asks.
const VERIFY_TRIES: u32 = 10;
const VERIFY_PAUSE: Duration = Duration::from_secs(2);

/// What the host's media server gives the delete flow.
#[derive(Clone)]
pub struct DeleteLibrary {
    /// The library item id of a title (`movie` / `tv`, TMDB id); `None` when the server has none (or does not answer).
    pub find: Arc<dyn Fn(String, i64) -> HostFuture<Option<String>> + Send + Sync>,
    /// Asks the server to scan its libraries again; `true` when it took the call.
    pub refresh: Arc<dyn Fn() -> HostFuture<bool> + Send + Sync>,
    /// Waits (the core has no timer of its own).
    pub pause: Arc<dyn Fn(Duration) -> HostFuture<()> + Send + Sync>,
}

struct State {
    vm: SeerrDeleteVm,
    art: String,
    tmdb: i64,
    media_id: i64,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The delete sheet of one title over a hub.
pub struct SeerrDeleteScreen<T: HttpTransport, J: CookieJar> {
    hub: Arc<SeerrHub<T, J>>,
    library: Option<DeleteLibrary>,
    state: Mutex<Option<State>>,
    on_done: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

impl<T: HttpTransport, J: CookieJar> SeerrDeleteScreen<T, J> {
    /// The screen over a hub and the host's media server (`None`: the steps that need it fail).
    pub fn new(hub: Arc<SeerrHub<T, J>>, library: Option<DeleteLibrary>) -> Arc<Self> {
        Arc::new(Self {
            hub,
            library,
            state: Mutex::new(None),
            on_done: Mutex::new(None),
        })
    }

    /// What runs once when a delete reaches Done (never on a failed step): the host side uses it to mark the account's
    /// lists stale, so Home's rows (Continue Watching, Next Up) and every list reload without the deleted title.
    pub fn set_on_done(&self, hook: Arc<dyn Fn() + Send + Sync>) {
        *lock(&self.on_done) = Some(hook);
    }

    /// Prepares the sheet for a title: reads which versions Seerr knows. `None` when this account or device may not
    /// delete, or Seerr does not know the title. `standard_size` / `four_k_size` are the host's file sizes as text.
    pub async fn prepare(
        &self,
        art: String,
        tmdb: i64,
        title: String,
        standard_size: Option<String>,
        four_k_size: Option<String>,
    ) -> Option<SeerrDeleteInfo> {
        let c = self.hub.client().filter(|_| self.hub.available())?;
        // The core's one rule: the right to manage requests and no "Löschen vom Server sperren" on this device.
        if !delete_offered(lock(self.hub.vm()).perms().can_manage_requests()) {
            return None;
        }
        let media = c.title(&art, tmdb).await.ok()?.media?;
        let has = |s: SeerrState| matches!(s, SeerrState::Present | SeerrState::PartWayPresent);
        let mut versions = Vec::new();
        if has(media.status) {
            versions.push((false, standard_size.clone()));
        }
        if has(media.status4k) {
            versions.push((true, four_k_size));
        }
        if versions.is_empty() {
            versions.push((false, standard_size));
        }
        *lock(&self.state) = Some(State {
            vm: SeerrDeleteVm::new(self.hub.locale_of(), &title, &versions),
            art,
            tmdb,
            media_id: media.id,
        });
        Some(self.info())
    }

    /// The sheet now.
    pub fn info(&self) -> SeerrDeleteInfo {
        lock(&self.state).as_ref().map_or_else(
            || SeerrDeleteVm::new(self.hub.locale_of(), "", &[]).info(),
            |s| s.vm.info(),
        )
    }

    /// Ticks or unticks one version (`true` = 4K) on the confirm sheet.
    pub fn toggle(&self, is4k: bool) -> SeerrDeleteInfo {
        if let Some(s) = lock(&self.state).as_mut() {
            s.vm.toggle(is4k);
        }
        self.info()
    }

    /// Deletes these lanes (`true` = 4K) and runs every step; returns when the flow is done or a step failed.
    pub async fn run(&self, lanes: &[bool]) -> SeerrDeleteInfo {
        // A sheet that was open when the lock went on does not run.
        if swiftly_model::switches::server_delete_locked() {
            return self.info();
        }
        let first = lock(&self.state).as_mut().and_then(|s| s.vm.start(lanes));
        self.run_from(first).await
    }

    /// Deletes the ticked versions (the core's own selection).
    pub async fn run_chosen(&self) -> SeerrDeleteInfo {
        if swiftly_model::switches::server_delete_locked() {
            return self.info();
        }
        let first = lock(&self.state).as_mut().and_then(|s| s.vm.start_chosen());
        self.run_from(first).await
    }

    /// "Nochmal versuchen": resumes at the failed step.
    pub async fn retry(&self) -> SeerrDeleteInfo {
        if swiftly_model::switches::server_delete_locked() {
            return self.info();
        }
        let first = lock(&self.state).as_mut().and_then(|s| s.vm.retry());
        self.run_from(first).await
    }

    /// The sheet is closed: the next [`Self::prepare`] starts fresh.
    pub fn close(&self) {
        *lock(&self.state) = None;
    }

    async fn run_from(&self, first: Option<DeleteAction>) -> SeerrDeleteInfo {
        let mut next = first;
        while let Some(action) = next {
            let (art, tmdb, media_id) = match lock(&self.state).as_ref() {
                Some(s) => (s.art.clone(), s.tmdb, s.media_id),
                None => break,
            };
            let result = self.do_action(action, &art, tmdb, media_id).await;
            let mut g = lock(&self.state);
            let Some(s) = g.as_mut() else { break };
            let result = result.map_err(|e| e.unwrap_or_else(|| s.vm.default_error(action)));
            next = s.vm.finished(result);
        }
        let info = self.info();
        if info.phase == crate::DeletePhase::Done {
            let hook = lock(&self.on_done).take();
            if let Some(hook) = hook {
                hook();
            }
        }
        info
    }

    /// Runs one action; `Err(None)` = failed without a text of its own.
    async fn do_action(
        &self,
        action: DeleteAction,
        art: &str,
        tmdb: i64,
        media_id: i64,
    ) -> Result<(), Option<String>> {
        let Some(c) = self.hub.client() else {
            return Err(None);
        };
        let t = swiftly_l10n::Translator::new(self.hub.locale_of());
        match action {
            DeleteAction::DeleteFiles { is4k } => c
                .delete_media_file(media_id, is4k)
                .await
                .map_err(|e| Some(ask_text(&t, &e))),
            DeleteAction::ForgetMedia => c
                .delete_media(media_id)
                .await
                .map_err(|e| Some(ask_text(&t, &e))),
            DeleteAction::RefreshLibrary => match &self.library {
                Some(l) if (l.refresh)().await => Ok(()),
                _ => Err(None),
            },
            DeleteAction::VerifyGone => {
                let Some(l) = &self.library else {
                    return Err(None);
                };
                // The server needs a moment: ask every two seconds, at most 20 seconds in all.
                for attempt in 0..VERIFY_TRIES {
                    if (l.find)(art.to_string(), tmdb).await.is_none() {
                        return Ok(());
                    }
                    if attempt + 1 < VERIFY_TRIES {
                        (l.pause)(VERIFY_PAUSE).await;
                    }
                }
                Err(None)
            }
        }
    }
}
