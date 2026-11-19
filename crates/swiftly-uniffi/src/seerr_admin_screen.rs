//! The admin side of Seerr over one hub, exported. The queue, the request details, the issue list
//! with its thread and reporting a problem are `swiftly_vm::SeerrAdminScreen`, the same code the
//! desktop runs; only the delete flow (files, Seerr, Jellyfin rescan, verify) lives here, because it
//! needs the host's library handle.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use swiftly_seerr::issues::IssueKind;
use swiftly_vm::{
    AdminTab, DeleteAction, IssuePill, RequestPill, SeerrDeleteInfo, SeerrDeleteVm, SeerrDetailRow,
    SeerrIssueDetail, SeerrIssuesInfo, SeerrRequestRow, SeerrRequestsInfo, SeerrTabInfo, ask_text,
};

use crate::error::CoreError;
use crate::seerr::JarAdapter;
use crate::seerr_lists_screen::{SeerrHub, lock};
use crate::transport::CoreTransport;

/// A request opened.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SeerrRequestDetail {
    /// The row on top.
    pub row: SeerrRequestRow,
    /// "Angefragt von", "Fassung", "Qualität", "Ordner".
    pub rows: Vec<SeerrDetailRow>,
}

/// The admin screens of one hub.
#[derive(uniffi::Object)]
pub struct SeerrAdminScreen {
    hub: Arc<SeerrHub>,
    core: Arc<swiftly_vm::SeerrAdminScreen<CoreTransport, JarAdapter>>,
    delete: Mutex<Option<DeleteState>>,
}

struct DeleteState {
    vm: SeerrDeleteVm,
    art: String,
    tmdb: i64,
    media_id: i64,
}

impl SeerrAdminScreen {
    async fn run_delete(&self, first: Option<DeleteAction>) -> SeerrDeleteInfo {
        let mut next = first;
        while let Some(action) = next {
            let (art, tmdb, media_id) = match lock(&self.delete).as_ref() {
                Some(d) => (d.art.clone(), d.tmdb, d.media_id),
                None => break,
            };
            let result = self.do_action(action, &art, tmdb, media_id).await;
            let mut g = lock(&self.delete);
            let Some(d) = g.as_mut() else { break };
            let result = result.map_err(|e| e.unwrap_or_else(|| d.vm.default_error(action)));
            next = d.vm.finished(result);
        }
        self.delete_info()
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
            DeleteAction::RefreshLibrary => match &self.hub.library {
                Some(l) if l.refresh().await.is_ok() => Ok(()),
                _ => Err(None),
            },
            DeleteAction::VerifyGone => {
                let Some(l) = &self.hub.library else {
                    return Err(None);
                };
                // Jellyfin needs a moment: ask every two seconds, at most 20 seconds in all.
                for attempt in 0..10 {
                    if l.find(art.to_string(), tmdb).await.ok().flatten().is_none() {
                        return Ok(());
                    }
                    if attempt < 9 {
                        tokio::time::sleep(Duration::from_secs(2)).await;
                    }
                }
                Err(None)
            }
        }
    }
}

/// The admin page as the last visit left it (see `SeerrAdminScreen::restore_all`).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SeerrAdminStale {
    /// The tabs with their counts.
    pub tabs: Vec<SeerrTabInfo>,
    /// The queue (`None` without the right to manage requests).
    pub queue: Option<SeerrRequestsInfo>,
    /// The problems (`None` without the right to see them).
    pub issues: Option<SeerrIssuesInfo>,
}

#[uniffi::export]
impl SeerrAdminScreen {
    /// The admin screens over a hub.
    #[uniffi::constructor]
    pub fn new(hub: Arc<SeerrHub>) -> Arc<Self> {
        Arc::new(Self {
            core: swiftly_vm::SeerrAdminScreen::new(Arc::clone(&hub.core)),
            hub,
            delete: Mutex::new(None),
        })
    }

    /// The tabs this account may open, with open counts (the queue needs `MANAGE_REQUESTS`, the
    /// problems `VIEW_ISSUES` or `MANAGE_ISSUES`).
    pub fn tabs(&self) -> Vec<SeerrTabInfo> {
        self.core.tabs()
    }

    /// Reads the counts, the queue and the problems side by side (one round after the account, not three one after
    /// the other); read the results with `tabs`, `requests`, `issues`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_all(&self) -> Result<Vec<SeerrTabInfo>, CoreError> {
        Ok(self.core.load_all().await)
    }

    /// What the page showed at its last visit, from the stash and without a call (`None`: nothing stored, or not
    /// complete). The page paints this at once and then calls `load_all`; nothing of this touches the live screen.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn restore_all(&self) -> Result<Option<SeerrAdminStale>, CoreError> {
        let began = std::time::Instant::now();
        let mut waited = false;
        let (twin, tabs) = loop {
            let twin = Self::new(Arc::new(SeerrHub {
                library: self.hub.library.clone(),
                core: self.hub.core.stale_twin(),
            }));
            let seen = swiftly_seerr::replaying(twin.core.load_all()).await;
            if let Some(tabs) = seen.filter(|tabs| !tabs.is_empty()) {
                break (twin, tabs);
            }
            if waited || !self.hub.core.after_warm_up().await {
                self.hub.core.took("admin", "stash miss", began);
                return Ok(None);
            }
            waited = true;
        };
        self.hub.core.took("admin", "first paint from stash", began);
        let queue = tabs
            .iter()
            .any(|t| t.tab == AdminTab::Requests)
            .then(|| twin.core.requests());
        let issues = tabs
            .iter()
            .any(|t| t.tab == AdminTab::Issues)
            .then(|| twin.core.issues());
        Ok(Some(SeerrAdminStale {
            tabs,
            queue,
            issues,
        }))
    }

    /// The first tab to show (`None`: nothing to administer).
    pub fn first_tab(&self) -> Option<AdminTab> {
        self.core.first_tab()
    }

    // ---- request queue

    /// The queue now.
    pub fn requests(&self) -> SeerrRequestsInfo {
        self.core.requests()
    }

    /// Reads all requests (managers see everyone's).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_requests(&self) -> Result<SeerrRequestsInfo, CoreError> {
        Ok(self.core.load_requests().await)
    }

    /// Picks a filter pill.
    pub fn select_pill(&self, pill: RequestPill) -> SeerrRequestsInfo {
        self.core.select_pill(pill)
    }

    /// "Freigeben": the row reads "Wird freigegeben…" until the server answers.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn approve(&self, id: i64) -> Result<SeerrRequestsInfo, CoreError> {
        Ok(self.core.approve(id).await)
    }

    /// "Ablehnen" (Seerr takes no reason).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn decline(&self, id: i64) -> Result<SeerrRequestsInfo, CoreError> {
        Ok(self.core.decline(id).await)
    }

    /// "Nochmal" on a failed request.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn retry(&self, id: i64) -> Result<SeerrRequestsInfo, CoreError> {
        Ok(self.core.retry(id).await)
    }

    /// Withdraws a waiting request.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn withdraw(&self, id: i64) -> Result<SeerrRequestsInfo, CoreError> {
        Ok(self.core.withdraw(id).await)
    }

    /// The detail card of one request.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn request_detail(&self, id: i64) -> Result<Option<SeerrRequestDetail>, CoreError> {
        Ok(self
            .core
            .request_detail(id)
            .await
            .map(|c| SeerrRequestDetail {
                row: c.row,
                rows: c.rows,
            }))
    }

    // ---- issues

    /// The issue list now.
    pub fn issues(&self) -> SeerrIssuesInfo {
        self.core.issues()
    }

    /// Reads the issues (everyone's for issue managers, else the account's own).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_issues(&self) -> Result<SeerrIssuesInfo, CoreError> {
        Ok(self.core.load_issues().await)
    }

    /// Picks an issue pill.
    pub fn select_issue_pill(&self, pill: IssuePill) -> SeerrIssuesInfo {
        self.core.select_issue_pill(pill)
    }

    /// Opens one issue with its thread.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn open_issue(&self, id: i64) -> Result<Option<SeerrIssueDetail>, CoreError> {
        Ok(self.core.open_issue(id).await)
    }

    /// The open issue now; `library_has` says the title is on the server (offers "Ab 23:14 abspielen").
    pub fn issue_detail(&self, library_has: bool) -> Option<SeerrIssueDetail> {
        self.core.issue_detail(library_has)
    }

    /// Back to the list.
    pub fn close_issue(&self) {
        self.core.close_issue();
    }

    /// Posts a reply to the open issue.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn reply(&self, text: String) -> Result<Option<SeerrIssueDetail>, CoreError> {
        Ok(self.core.reply(text).await)
    }

    /// "Erledigt".
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn resolve_issue(&self) -> Result<Option<SeerrIssueDetail>, CoreError> {
        Ok(self.core.resolve_issue().await)
    }

    /// "Wieder öffnen".
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn reopen_issue(&self) -> Result<Option<SeerrIssueDetail>, CoreError> {
        Ok(self.core.reopen_issue().await)
    }

    /// Reports a problem with a title. `season` / `episode` 0 = none; `at` is the position
    /// ("23:14") the player was at. Returns the error text when it did not work.
    #[uniffi::method(async_runtime = "tokio")]
    #[allow(clippy::too_many_arguments)]
    pub async fn report_issue(
        &self,
        art: String,
        tmdb: i64,
        kind: IssueKind,
        message: String,
        season: i64,
        episode: i64,
        at: Option<String>,
    ) -> Result<Option<String>, CoreError> {
        Ok(self
            .core
            .report_issue(art, tmdb, kind, message, season, episode, at)
            .await)
    }

    // ---- delete from the server

    /// Prepares "Vom Server löschen" for a title: reads which versions Seerr knows. `sizes` are the
    /// host's file sizes as text, standard then 4K (`None` where unknown).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn delete_prepare(
        &self,
        art: String,
        tmdb: i64,
        title: String,
        standard_size: Option<String>,
        four_k_size: Option<String>,
    ) -> Result<Option<SeerrDeleteInfo>, CoreError> {
        let Some(c) = self.hub.client().filter(|_| self.hub.available()) else {
            return Ok(None);
        };
        // The core's one rule: the right to manage requests and no "Löschen vom Server sperren" on this device.
        if !swiftly_vm::delete_offered(lock(self.hub.vm()).perms().can_manage_requests()) {
            return Ok(None);
        }
        let Ok(info) = c.title(&art, tmdb).await else {
            return Ok(None);
        };
        let Some(media) = info.media else {
            return Ok(None);
        };
        use swiftly_seerr::SeerrState as S;
        let has = |s: S| matches!(s, S::Present | S::PartWayPresent);
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
        *lock(&self.delete) = Some(DeleteState {
            vm: SeerrDeleteVm::new(self.hub.locale_of(), &title, &versions),
            art,
            tmdb,
            media_id: media.id,
        });
        Ok(Some(self.delete_info()))
    }

    /// The delete sheet now.
    pub fn delete_info(&self) -> SeerrDeleteInfo {
        lock(&self.delete)
            .as_ref()
            .map(|d| d.vm.info())
            .unwrap_or_else(|| SeerrDeleteVm::new(self.hub.locale_of(), "", &[]).info())
    }

    /// Deletes the chosen versions (`true` = 4K) and runs every step; returns when the flow is done
    /// or a step failed (then `delete_retry` resumes there).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn delete_run(&self, lanes: Vec<bool>) -> Result<SeerrDeleteInfo, CoreError> {
        // A sheet that was open when the lock went on does not run.
        if swiftly_model::switches::server_delete_locked() {
            return Ok(self.delete_info());
        }
        let first = lock(&self.delete).as_mut().and_then(|d| d.vm.start(&lanes));
        Ok(self.run_delete(first).await)
    }

    /// "Nochmal versuchen": resumes at the failed step.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn delete_retry(&self) -> Result<SeerrDeleteInfo, CoreError> {
        if swiftly_model::switches::server_delete_locked() {
            return Ok(self.delete_info());
        }
        let first = lock(&self.delete).as_mut().and_then(|d| d.vm.retry());
        Ok(self.run_delete(first).await)
    }
}
