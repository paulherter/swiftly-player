//! "Meine Anfragen": the account's own request list over one hub, with its filter pills, withdrawing and the paint
//! from the stash. One implementation for every host (the desktop's list screen and the uniffi export both hold it).

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_net::HttpTransport;
use swiftly_seerr::requests::{RequestFilter, RequestQuery};
use swiftly_seerr::types::RequestRow;
use swiftly_seerr::{AskError, CookieJar};

use crate::ListLoad;
use crate::seerr_io::SeerrHub;
use crate::seerr_lists::{RequestPill, RequestScope, SeerrRequestsInfo, SeerrRequestsVm, Verdict};
use crate::seerr_title::today_utc;

/// How many of the account's own requests the list reads.
const LIST_TAKE: u32 = 50;
/// How many the home block reads.
pub const HOME_TAKE: u32 = 20;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The list "Meine Anfragen" of one hub.
pub struct MyRequests<T: HttpTransport, J: CookieJar> {
    hub: Arc<SeerrHub<T, J>>,
    vm: Mutex<Option<SeerrRequestsVm>>,
}

impl<T: HttpTransport, J: CookieJar> MyRequests<T, J> {
    /// The list over `hub`, nothing read yet.
    pub fn new(hub: Arc<SeerrHub<T, J>>) -> Self {
        Self {
            hub,
            vm: Mutex::new(None),
        }
    }

    fn new_vm(&self) -> SeerrRequestsVm {
        let vm = lock(&self.hub.vm);
        SeerrRequestsVm::new(
            self.hub.locale_of(),
            &today_utc(),
            RequestScope::Mine,
            vm.user_id(),
            vm.perms(),
        )
    }

    fn vm(&self) -> MutexGuard<'_, Option<SeerrRequestsVm>> {
        let mut g = lock(&self.vm);
        if g.is_none() {
            *g = Some(self.new_vm());
        }
        g
    }

    /// The read of the account's own requests; the stash keys on exactly this query.
    fn query(&self, take: u32) -> RequestQuery {
        RequestQuery {
            filter: RequestFilter::All,
            requested_by: Some(lock(&self.hub.vm).user_id()),
            by_modified: true,
            take,
            ..RequestQuery::default()
        }
    }

    /// The account's own requests, newest change first (`take` rows): the list and the home block read them.
    pub async fn rows(&self, take: u32) -> Result<Vec<RequestRow>, AskError> {
        let Some(c) = self.hub.client() else {
            return Ok(Vec::new());
        };
        Ok(c.request_list(&self.query(take)).await?.results)
    }

    /// The list now.
    pub fn info(&self) -> SeerrRequestsInfo {
        let cache = lock(&self.hub.titles).clone();
        match self.vm().as_ref() {
            Some(vm) => vm.info(&cache),
            None => self.new_vm().info(&cache),
        }
    }

    /// Reads the account's requests.
    pub async fn load(&self) -> SeerrRequestsInfo {
        let began = std::time::Instant::now();
        let info = self.load_read().await;
        self.hub.took("requests", "live ready", began);
        info
    }

    async fn load_read(&self) -> SeerrRequestsInfo {
        if !self.hub.ensure().await {
            return self.info();
        }
        {
            let summary = lock(&self.hub.vm).info().quota_summary;
            if let Some(vm) = self.vm().as_mut() {
                vm.begin();
                vm.set_quota_summary(summary);
            }
        }
        let rows = self.rows(LIST_TAKE).await;
        if let Ok(list) = &rows {
            self.hub.resolve_requests(list).await;
        }
        if let Some(vm) = self.vm().as_mut() {
            vm.loaded(rows);
        }
        self.info()
    }

    /// Paints the list of the last visit from the stash, without a call to Seerr (`false`: no complete list is stored,
    /// or the list was read already; nothing is touched then). The live [`Self::load`] that follows replaces it, and
    /// the filter pills work on the stored rows meanwhile. A withdrawn request is dropped from the stored answers
    /// ([`Self::withdraw`]), so it does not come back. A hub that is live already stays live; one that was not is
    /// flagged as painted from the stash, so the account is still read live.
    pub async fn restore(&self) -> bool {
        if self.info().load != ListLoad::Idle {
            return false;
        }
        let began = std::time::Instant::now();
        let cold = self.hub.cold();
        let mut waited = false;
        loop {
            let probe = Self::new(self.hub.stale_twin());
            let seen = swiftly_seerr::replaying(probe.load()).await;
            if seen.is_some_and(|r| r.load == ListLoad::Content) {
                break;
            }
            if waited || !self.hub.after_warm_up().await {
                self.hub.took("requests", "stash miss", began);
                return false;
            }
            waited = true;
        }
        swiftly_seerr::replaying(self.load()).await;
        if cold {
            self.hub.painted_from_stash();
        }
        self.hub.took("requests", "first paint from stash", began);
        self.info().load == ListLoad::Content
    }

    /// Picks a filter pill.
    pub fn select_pill(&self, pill: RequestPill) -> SeerrRequestsInfo {
        if let Some(vm) = self.vm().as_mut() {
            vm.select(pill);
        }
        self.info()
    }

    /// "Zurückziehen" on an own waiting request; the row goes at once and comes back with its error text when the
    /// server refuses. Once Seerr agrees, the stored answers lose the row too.
    pub async fn withdraw(&self, id: i64) -> SeerrRequestsInfo {
        if let Some(vm) = self.vm().as_mut() {
            vm.begin_verdict(id, Verdict::Withdraw);
        }
        let result = match self.hub.client() {
            Some(c) => c.cancel_request(id).await,
            None => Err(AskError::SessionLost),
        };
        let agreed = result.is_ok();
        if let Some(vm) = self.vm().as_mut() {
            vm.verdict_done(id, Verdict::Withdraw, result);
        }
        if let Some(c) = self.hub.client().filter(|_| agreed) {
            for take in [LIST_TAKE, HOME_TAKE] {
                c.drop_request_from_stash(&self.query(take), id);
            }
        }
        let _ = self.hub.refresh_counts().await;
        self.info()
    }
}
