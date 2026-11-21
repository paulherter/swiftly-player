//! The admin side of Seerr over one hub, the one implementation for every host (the desktop uses it directly, the
//! UniFFI screen of the iPhone, iPad, Mac, TV and Android is a thin export over it): the request queue with approve /
//! decline / retry / withdraw, the request detail card, the issue list with its thread, reply / resolve / reopen and
//! reporting a problem. The state machines are `seerr_admin` and `seerr_lists`, this type runs the calls of a
//! [`SeerrClient`] and feeds the answers in. The delete flow stays with the UniFFI screen (it needs the host's
//! library handle).

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_net::HttpTransport;
use swiftly_seerr::issues::{Issue, IssueFilter, IssueKind, IssueQuery, IssueSpec};
use swiftly_seerr::requests::{RequestFilter, RequestQuery};
use swiftly_seerr::{AskError, CookieJar, SeerrClient};

use crate::seerr_admin::{
    AdminTab, IssuePill, SeerrDetailRow, SeerrIssueDetail, SeerrIssuesInfo, SeerrIssuesVm,
    SeerrTabInfo, request_detail_rows,
};
use crate::seerr_io::SeerrHub;
use crate::seerr_lists::{
    RequestPill, RequestScope, SeerrRequestRow, SeerrRequestsInfo, SeerrRequestsVm, Verdict,
};
use crate::seerr_title::{ask_text, today_utc};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A request opened: the row on top and the detail lines under it.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrRequestCard {
    /// The row on top.
    pub row: SeerrRequestRow,
    /// "Angefragt von", "Fassung", "Qualität", "Ordner".
    pub rows: Vec<SeerrDetailRow>,
}

/// Reads request `id` as a card: the row on top as `scope` lists it (the account's own list can withdraw, the queue
/// decides) and the detail lines under it. `None` when Seerr cannot be asked or does not know the request.
pub(crate) async fn read_card<T: HttpTransport, J: CookieJar>(
    hub: &Arc<SeerrHub<T, J>>,
    scope: RequestScope,
    id: i64,
) -> Option<SeerrRequestCard> {
    let c = hub.client()?;
    let req = c.request_by_id(id).await.ok()?;
    hub.resolve_requests(std::slice::from_ref(&req)).await;
    let service = match (&req.media_type, req.server_id) {
        (Some(art), Some(server)) if lock(&hub.vm).perms().can_choose_advanced() => {
            c.service_detail(art, server).await.ok()
        }
        _ => None,
    };
    let rows = request_detail_rows(&hub.locale_of(), &req, service.as_ref());
    let cache = lock(&hub.titles).clone();
    let mut vm = {
        let v = lock(&hub.vm);
        SeerrRequestsVm::new(hub.locale_of(), &today_utc(), scope, v.user_id(), v.perms())
    };
    vm.loaded(Ok(vec![req]));
    let row = vm.info(&cache).rows.into_iter().next()?;
    Some(SeerrRequestCard { row, rows })
}

type IssueFuture<'a> = Pin<Box<dyn Future<Output = Result<Issue, AskError>> + Send + 'a>>;

/// The admin screens of one hub.
pub struct SeerrAdminScreen<T: HttpTransport, J: CookieJar> {
    hub: Arc<SeerrHub<T, J>>,
    queue: Mutex<Option<SeerrRequestsVm>>,
    issues: Mutex<Option<SeerrIssuesVm>>,
}

impl<T: HttpTransport, J: CookieJar> SeerrAdminScreen<T, J> {
    /// The admin screens over a hub.
    pub fn new(hub: Arc<SeerrHub<T, J>>) -> Arc<Self> {
        Arc::new(Self {
            hub,
            queue: Mutex::new(None),
            issues: Mutex::new(None),
        })
    }

    fn new_queue_vm(&self) -> SeerrRequestsVm {
        let vm = lock(&self.hub.vm);
        SeerrRequestsVm::new(
            self.hub.locale_of(),
            &today_utc(),
            RequestScope::Queue,
            vm.user_id(),
            vm.perms(),
        )
    }

    fn new_issues_vm(&self) -> SeerrIssuesVm {
        let vm = lock(&self.hub.vm);
        SeerrIssuesVm::new(self.hub.locale_of(), vm.user_id(), vm.perms())
    }

    fn queue_vm(&self) -> MutexGuard<'_, Option<SeerrRequestsVm>> {
        let mut g = lock(&self.queue);
        if g.is_none() {
            *g = Some(self.new_queue_vm());
        }
        g
    }

    fn issues_vm(&self) -> MutexGuard<'_, Option<SeerrIssuesVm>> {
        let mut g = lock(&self.issues);
        if g.is_none() {
            *g = Some(self.new_issues_vm());
        }
        g
    }

    async fn resolve_issues(&self, issues: &[Issue]) {
        let keys: Vec<(String, i64)> = issues
            .iter()
            .filter_map(|i| {
                let m = i.media.as_ref()?;
                Some((
                    m.media_type.clone().unwrap_or_else(|| "movie".into()),
                    m.tmdb_id?,
                ))
            })
            .filter(|(a, id)| lock(&self.hub.titles).get(a, *id).is_none())
            .collect();
        if !keys.is_empty() {
            self.hub.resolve_titles(keys).await;
        }
    }

    async fn verdict(&self, id: i64, verdict: Verdict) -> SeerrRequestsInfo {
        if let Some(vm) = self.queue_vm().as_mut() {
            vm.begin_verdict(id, verdict);
        }
        let result = match self.hub.client() {
            Some(c) => match verdict {
                Verdict::Approve => c.approve_request(id).await.map(|_| ()),
                Verdict::Decline => c.decline_request(id).await.map(|_| ()),
                Verdict::Retry => c.retry_request(id).await.map(|_| ()),
                Verdict::Withdraw => c.cancel_request(id).await,
            },
            None => Err(AskError::SessionLost),
        };
        if let Some(vm) = self.queue_vm().as_mut() {
            vm.verdict_done(id, verdict, result);
        }
        let _ = self.hub.refresh_counts().await;
        self.requests()
    }

    async fn issue_action<F>(&self, call: F) -> Option<SeerrIssueDetail>
    where
        F: for<'a> FnOnce(&'a SeerrClient<T, J>, i64) -> IssueFuture<'a>,
    {
        let id = self.issue_detail(false)?.row.id;
        let c = self.hub.client()?;
        if let Some(vm) = self.issues_vm().as_mut() {
            vm.begin_action();
        }
        let result = call(c, id).await;
        if let Some(vm) = self.issues_vm().as_mut() {
            vm.action_done(result);
        }
        self.issue_detail(false)
    }

    // ---- tabs and the request queue

    /// The tabs this account may open, with open counts (the queue needs `MANAGE_REQUESTS`, the problems
    /// `VIEW_ISSUES` or `MANAGE_ISSUES`).
    pub fn tabs(&self) -> Vec<SeerrTabInfo> {
        let info = self.hub.info();
        let perms = lock(&self.hub.vm).perms();
        crate::seerr_admin::tabs(
            &self.hub.locale_of(),
            perms,
            info.counts.pending,
            info.counts.issues_open,
        )
    }

    /// Everything the page needs, read side by side after the account: the counts, the queue and the problems the
    /// account may see. Returns the tabs (with their counts) when it is over.
    pub async fn load_all(&self) -> Vec<SeerrTabInfo> {
        let began = std::time::Instant::now();
        let tabs = self.load_all_read().await;
        self.hub.took("admin", "live ready", began);
        tabs
    }

    async fn load_all_read(&self) -> Vec<SeerrTabInfo> {
        if !self.hub.ensure().await {
            return self.tabs();
        }
        let tabs = self.tabs();
        let queue = tabs.iter().any(|t| t.tab == AdminTab::Requests);
        let issues = tabs.iter().any(|t| t.tab == AdminTab::Issues);
        futures_util::future::join3(
            self.hub.read_counts(),
            async {
                if queue {
                    self.load_requests().await;
                }
            },
            async {
                if issues {
                    self.load_issues().await;
                }
            },
        )
        .await;
        self.tabs()
    }

    /// Paints the page of the last visit (tabs, queue, problems) into this screen from the stash, without a call to
    /// Seerr (`false`: nothing complete is stored, or the screen already read). The live `load_all` replaces it.
    pub async fn restore_all(&self) -> bool {
        if !self.hub.untouched() {
            return false;
        }
        let began = std::time::Instant::now();
        let mut waited = false;
        loop {
            let probe = Self::new(self.hub.stale_twin());
            let seen = swiftly_seerr::replaying(probe.load_all()).await;
            if seen.is_some_and(|tabs| !tabs.is_empty()) {
                break;
            }
            if waited || !self.hub.after_warm_up().await {
                self.hub.took("admin", "stash miss", began);
                return false;
            }
            waited = true;
        }
        let shown = swiftly_seerr::replaying(self.load_all()).await;
        self.hub.painted_from_stash();
        self.hub.took("admin", "first paint from stash", began);
        shown.is_some()
    }

    /// The first tab to show (`None`: nothing to administer).
    pub fn first_tab(&self) -> Option<AdminTab> {
        self.tabs().first().map(|t| t.tab)
    }

    /// The queue now.
    pub fn requests(&self) -> SeerrRequestsInfo {
        let cache = lock(&self.hub.titles).clone();
        match lock(&self.queue).as_ref() {
            Some(vm) => vm.info(&cache),
            None => self.new_queue_vm().info(&cache),
        }
    }

    /// Reads all requests (managers see everyone's).
    pub async fn load_requests(&self) -> SeerrRequestsInfo {
        if !self.hub.ensure().await {
            return self.requests();
        }
        let (uid, perms) = {
            let vm = lock(&self.hub.vm);
            (vm.user_id(), vm.perms())
        };
        if let Some(vm) = self.queue_vm().as_mut() {
            vm.set_account(uid, perms);
            vm.begin();
        }
        let rows = match self.hub.client() {
            Some(c) => c
                .request_list(&RequestQuery {
                    filter: RequestFilter::All,
                    by_modified: true,
                    take: 100,
                    ..RequestQuery::default()
                })
                .await
                .map(|p| p.results),
            None => Err(AskError::SessionLost),
        };
        if let Ok(list) = &rows {
            self.hub.resolve_requests(list).await;
        }
        if let Some(vm) = self.queue_vm().as_mut() {
            vm.loaded(rows);
        }
        self.requests()
    }

    /// Picks a filter pill.
    pub fn select_pill(&self, pill: RequestPill) -> SeerrRequestsInfo {
        if let Some(vm) = self.queue_vm().as_mut() {
            vm.select(pill);
        }
        self.requests()
    }

    /// "Freigeben": the row reads "Wird freigegeben..." until the server answers.
    pub async fn approve(&self, id: i64) -> SeerrRequestsInfo {
        self.verdict(id, Verdict::Approve).await
    }

    /// "Ablehnen" (Seerr takes no reason).
    pub async fn decline(&self, id: i64) -> SeerrRequestsInfo {
        self.verdict(id, Verdict::Decline).await
    }

    /// "Nochmal" on a failed request.
    pub async fn retry(&self, id: i64) -> SeerrRequestsInfo {
        self.verdict(id, Verdict::Retry).await
    }

    /// Withdraws a waiting request.
    pub async fn withdraw(&self, id: i64) -> SeerrRequestsInfo {
        self.verdict(id, Verdict::Withdraw).await
    }

    /// The detail card of one request, as the queue lists it (the verbs of a manager, no "Zurückziehen").
    pub async fn request_detail(&self, id: i64) -> Option<SeerrRequestCard> {
        read_card(&self.hub, RequestScope::Queue, id).await
    }

    // ---- issues

    /// The issue list now.
    pub fn issues(&self) -> SeerrIssuesInfo {
        let cache = lock(&self.hub.titles).clone();
        match lock(&self.issues).as_ref() {
            Some(vm) => vm.info(&cache),
            None => self.new_issues_vm().info(&cache),
        }
    }

    /// Reads the issues (everyone's for issue managers, else the account's own).
    pub async fn load_issues(&self) -> SeerrIssuesInfo {
        if !self.hub.ensure().await {
            return self.issues();
        }
        let (uid, perms) = {
            let vm = lock(&self.hub.vm);
            (vm.user_id(), vm.perms())
        };
        if let Some(vm) = self.issues_vm().as_mut() {
            vm.set_account(uid, perms);
            vm.begin();
        }
        let list = match self.hub.client() {
            Some(c) => c
                .issue_list(&IssueQuery {
                    filter: IssueFilter::All,
                    by_modified: true,
                    requested_by: (!perms.can_manage_issues()).then_some(uid),
                    take: 100,
                    ..IssueQuery::default()
                })
                .await
                .map(|p| p.results),
            None => Err(AskError::SessionLost),
        };
        if let Ok(l) = &list {
            self.resolve_issues(l).await;
        }
        if let Some(vm) = self.issues_vm().as_mut() {
            vm.loaded(list);
        }
        self.issues()
    }

    /// Picks an issue pill.
    pub fn select_issue_pill(&self, pill: IssuePill) -> SeerrIssuesInfo {
        if let Some(vm) = self.issues_vm().as_mut() {
            vm.select(pill);
        }
        self.issues()
    }

    /// Opens one issue with its thread.
    pub async fn open_issue(&self, id: i64) -> Option<SeerrIssueDetail> {
        let c = self.hub.client()?;
        let mut issue = c.issue(id).await.ok()?;
        if issue.media.is_none() {
            issue.media = self.issues_vm().as_ref().and_then(|vm| {
                vm.issues()
                    .iter()
                    .find(|i| i.id == id)
                    .and_then(|i| i.media.clone())
            });
        }
        self.resolve_issues(std::slice::from_ref(&issue)).await;
        if let Some(vm) = self.issues_vm().as_mut() {
            vm.opened(issue);
        }
        self.issue_detail(false)
    }

    /// The open issue now; `library_has` says the title is on the server (offers "Ab 23:14 abspielen").
    pub fn issue_detail(&self, library_has: bool) -> Option<SeerrIssueDetail> {
        let cache = lock(&self.hub.titles).clone();
        lock(&self.issues)
            .as_ref()
            .and_then(|vm| vm.detail(&cache, library_has))
    }

    /// Back to the list.
    pub fn close_issue(&self) {
        if let Some(vm) = self.issues_vm().as_mut() {
            vm.closed();
        }
    }

    /// Posts a reply to the open issue.
    pub async fn reply(&self, text: String) -> Option<SeerrIssueDetail> {
        self.issue_action(|c, id| Box::pin(async move { c.comment_issue(id, &text).await }))
            .await
    }

    /// "Erledigt".
    pub async fn resolve_issue(&self) -> Option<SeerrIssueDetail> {
        let out = self
            .issue_action(|c, id| Box::pin(async move { c.resolve_issue(id).await }))
            .await;
        let _ = self.hub.refresh_counts().await;
        out
    }

    /// "Wieder öffnen".
    pub async fn reopen_issue(&self) -> Option<SeerrIssueDetail> {
        let out = self
            .issue_action(|c, id| Box::pin(async move { c.reopen_issue(id).await }))
            .await;
        let _ = self.hub.refresh_counts().await;
        out
    }

    /// Reports a problem with a title; `season` / `episode` 0 = none, `at` the player's position ("23:14").
    /// Returns the error text when it did not work.
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
    ) -> Option<String> {
        let t = swiftly_l10n::Translator::new(self.hub.locale_of());
        let Some(c) = self.hub.client().filter(|_| self.hub.available()) else {
            return Some(t.t("Seerr braucht eine neue Anmeldung."));
        };
        let media_id = match c.title(&art, tmdb).await {
            Ok(info) => info.media.map(|m| m.id).filter(|id| *id > 0),
            Err(e) => return Some(ask_text(&t, &e)),
        };
        let Some(media_id) = media_id else {
            return Some(t.t("Das gibt es bei Seerr nicht mehr."));
        };
        let spec = IssueSpec {
            kind,
            message,
            media_id,
            season,
            episode,
            at,
        };
        match c.create_issue(&spec).await {
            Ok(_) => {
                let _ = self.hub.refresh_counts().await;
                None
            }
            Err(e) => Some(ask_text(&t, &e)),
        }
    }
}
