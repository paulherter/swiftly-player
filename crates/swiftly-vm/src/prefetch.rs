//! What the detail page already asked the server: the full title and the playback plan (the engine's profile). A start
//! a moment later takes them from here instead of asking again, so Play begins from the information the page holds
//! (the old app did the same through the page's own `plan` state). Short-lived and small: an answer is only used within
//! [`LIFETIME`] and only for the same account, title, version choice and bitrate limit. Ages are measured on the host's
//! clock (the callers pass `now` from it), never on `Instant`, which does not count the time a device sleeps.

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use futures_util::future::{FutureExt, Shared};
use swiftly_library::Store;
use swiftly_model::Item;
use swiftly_playback::playback_plan::PlaybackPlan;

use crate::host::{Host, age};

/// How long a remembered answer stays usable (a resume point or a probe result is not much older than a visit).
const LIFETIME: Duration = Duration::from_secs(60);
/// Titles remembered at once.
const ROOM: usize = 8;

struct Entry {
    who: String,
    item_id: String,
    /// The title and the plan age on their own: a fresh title does not make an old plan younger. Each is stamped with
    /// the host clock's seconds.
    item: Option<(f64, Item)>,
    /// The plan with the bitrate limit and the version choice it was asked for.
    plan: Option<(f64, i64, Option<String>, PlaybackPlan)>,
}

impl Entry {
    fn expire(&mut self, now: f64) {
        if self
            .item
            .as_ref()
            .is_some_and(|(at, _)| age(now, *at) >= LIFETIME)
        {
            self.item = None;
        }
        if self
            .plan
            .as_ref()
            .is_some_and(|(at, ..)| age(now, *at) >= LIFETIME)
        {
            self.plan = None;
        }
    }
}

static MEMORY: Mutex<Vec<Entry>> = Mutex::new(Vec::new());

static SCOPES: Mutex<Vec<(Weak<dyn Store>, u64)>> = Mutex::new(Vec::new());
static NEXT_SCOPE: AtomicU64 = AtomicU64::new(1);

/// Which host instance a remembered answer belongs to, as the first part of the `who` key. The memories here are
/// process-wide (the detail page and the start of two view models share them), so an account and a title alone are not
/// a key: two cores in one process (two tests, or a second window) that ask for the same title of the same account would
/// share an answer, and a request still on its way for one would be the other's. The host's blob store is one object
/// per core and shared by all of its view models, so its identity is the scope. The registry keeps a weak handle, which
/// holds the allocation (its address cannot be given to a new store while the entry exists) and shows when the store is gone.
pub(crate) fn scope(host: &Host) -> String {
    let mut scopes = SCOPES.lock().unwrap_or_else(PoisonError::into_inner);
    scopes.retain(|(store, _)| store.strong_count() > 0);
    let here = Arc::as_ptr(&host.store).cast::<()>();
    if let Some((_, id)) = scopes
        .iter()
        .find(|(store, _)| store.as_ptr().cast::<()>() == here)
    {
        return id.to_string();
    }
    let id = NEXT_SCOPE.fetch_add(1, Ordering::Relaxed);
    scopes.push((Arc::downgrade(&host.store), id));
    id.to_string()
}

/// Runs `f` on the memory after the answers of `who` that are too old were dropped, by the caller's `now` (the host
/// clock). Other keys are not judged by this caller's clock: two hosts (or two tests with their own clocks) share the
/// process-wide memory and must not expire each other's answers.
fn with<R>(who: &str, now: f64, f: impl FnOnce(&mut Vec<Entry>) -> R) -> R {
    let mut memory = MEMORY.lock().unwrap_or_else(PoisonError::into_inner);
    memory
        .iter_mut()
        .filter(|e| e.who == who)
        .for_each(|e| e.expire(now));
    memory.retain(|e| e.item.is_some() || e.plan.is_some());
    f(&mut memory)
}

fn slot<'a>(memory: &'a mut Vec<Entry>, who: &str, item_id: &str) -> &'a mut Entry {
    if let Some(i) = memory
        .iter()
        .position(|e| e.who == who && e.item_id == item_id)
    {
        return &mut memory[i];
    }
    if memory.len() >= ROOM {
        memory.remove(0);
    }
    memory.push(Entry {
        who: who.to_owned(),
        item_id: item_id.to_owned(),
        item: None,
        plan: None,
    });
    let last = memory.len() - 1;
    &mut memory[last]
}

/// The page holds the full title now (`now`: the host clock).
pub(crate) fn remember_item(who: &str, item: &Item, now: f64) {
    with(who, now, |m| {
        let e = slot(m, who, &item.id);
        e.item = Some((now, item.clone()));
    });
}

/// The page holds the plan asked with `max_bitrate` for `source_id` (`None`: the server's own pick).
pub(crate) fn remember_plan(
    who: &str,
    item_id: &str,
    max_bitrate: i64,
    source_id: Option<&str>,
    plan: &PlaybackPlan,
    now: f64,
) {
    with(who, now, |m| {
        let e = slot(m, who, item_id);
        e.plan = Some((now, max_bitrate, source_id.map(str::to_owned), plan.clone()));
    });
}

type Raw = Option<Arc<serde_json::Value>>;
type Pending = Shared<Pin<Box<dyn Future<Output = Raw> + Send>>>;

/// The requests of this kind that are on their way: (account, title, the shared answer).
static EXTRAS: Mutex<Vec<(String, String, Pending)>> = Mutex::new(Vec::new());

/// The title's chapters and preview-sheet information as raw JSON: callers that ask while the request is on its way
/// share it (the host asks for the chapters and for the preview sheets a moment apart, the start asks for both at
/// once). Nothing is kept once it has answered: what a title says about its chapters is not something to keep around.
pub(crate) async fn extras<F>(who: &str, item_id: &str, ask: F) -> Raw
where
    F: FnOnce() -> Pin<Box<dyn Future<Output = Raw> + Send>>,
{
    let pending = {
        let mut memory = EXTRAS.lock().unwrap_or_else(PoisonError::into_inner);
        memory.retain(|(_, _, run)| run.peek().is_none());
        if let Some((_, _, run)) = memory.iter().find(|(w, id, _)| w == who && id == item_id) {
            run.clone()
        } else {
            let run: Pending = ask().shared();
            memory.push((who.to_owned(), item_id.to_owned(), run.clone()));
            run
        }
    };
    pending.await
}

/// The remembered full title (`now`: the host clock).
pub(crate) fn item(who: &str, item_id: &str, now: f64) -> Option<Item> {
    with(who, now, |m| {
        m.iter()
            .find(|e| e.who == who && e.item_id == item_id)
            .and_then(|e| e.item.as_ref().map(|(_, item)| item.clone()))
    })
}

/// What the page remembered about this title is out of date (the viewer changed the state of the title, or played it):
/// the next start asks the server again.
pub(crate) fn forget(who: &str, item_id: &str) {
    let mut memory = MEMORY.lock().unwrap_or_else(PoisonError::into_inner);
    memory.retain(|e| !(e.who == who && e.item_id == item_id));
}

/// The remembered plan, when it was asked with these same limits (`now`: the host clock).
pub(crate) fn plan(
    who: &str,
    item_id: &str,
    max_bitrate: i64,
    source_id: Option<&str>,
    now: f64,
) -> Option<PlaybackPlan> {
    with(who, now, |m| {
        m.iter()
            .find(|e| e.who == who && e.item_id == item_id)
            .and_then(|e| e.plan.as_ref())
            .filter(|(_, bitrate, source, _)| {
                *bitrate == max_bitrate && source.as_deref() == source_id
            })
            .map(|(_, _, _, p)| p.clone())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::{Clock, JumpClock};

    fn item(id: &str) -> Item {
        Item::new(id, id, Some("Movie"))
    }

    struct NoSpawn;
    impl crate::host::Spawner for NoSpawn {
        fn spawn(&self, _: Pin<Box<dyn Future<Output = ()> + Send>>) {}
    }

    fn a_host() -> Host {
        Host {
            spawner: Arc::new(NoSpawn),
            clock: Arc::new(crate::host::SystemClock),
            store: Arc::new(swiftly_library::MemoryStore::new()),
            locale: swiftly_l10n::Locale::parse("de"),
            device_name: "Test".into(),
            client_version: "0.0.0".into(),
            cache: None,
        }
    }

    #[test]
    fn a_host_and_its_clones_share_a_scope_and_another_host_has_its_own() {
        let (a, b) = (a_host(), a_host());
        assert_eq!(scope(&a), scope(&a.clone()));
        assert_ne!(scope(&a), scope(&b));
    }

    /// Two cores in one process asking for the same title of the same account (parallel tests did) must not share a
    /// request that is still on its way: the second would be answered with the first one's result, or never.
    #[test]
    fn a_request_on_its_way_is_not_shared_with_another_host() {
        let (a, b) = (a_host(), a_host());
        let who = |h: &Host| format!("{}|https://x.example|u-scope", scope(h));
        let (who_a, who_b) = (who(&a), who(&b));
        futures_executor::block_on(async {
            let mut first = Box::pin(extras(&who_a, "t-scope", || {
                Box::pin(std::future::pending::<Raw>())
            }));
            assert!(
                first.as_mut().now_or_never().is_none(),
                "the first request waits"
            );
            let second = extras(&who_b, "t-scope", || {
                Box::pin(async { Some(Arc::new(serde_json::json!("own"))) })
            })
            .await;
            assert_eq!(second.as_deref(), Some(&serde_json::json!("own")));
            // The same host asking again while its request waits does share it (that is what the map is for).
            let mut again = Box::pin(extras(&who_a, "t-scope", || {
                Box::pin(async { Some(Arc::new(serde_json::json!("never asked"))) })
            }));
            assert!(again.as_mut().now_or_never().is_none());
        });
    }

    fn a_plan() -> PlaybackPlan {
        PlaybackPlan::from_slab("f.mkv", Some("mkv"), None, None)
    }

    #[test]
    fn a_fresh_title_does_not_make_an_old_plan_younger() {
        let who = "https://a.example|u-age";
        let clock = JumpClock::new();
        remember_plan(who, "t1", 1, None, &a_plan(), clock.now());
        // The plan is 59 s old when the title is refreshed.
        clock.sleep_through(59.0);
        remember_item(who, &item("t1"), clock.now());
        assert!(super::plan(who, "t1", 1, None, clock.now()).is_some());
        clock.sleep_through(2.0);
        assert!(
            super::plan(who, "t1", 1, None, clock.now()).is_none(),
            "the plan expired although the title is newer"
        );
        assert!(
            super::item(who, "t1", clock.now()).is_some(),
            "the fresh title stays"
        );
    }

    #[test]
    fn nothing_prefetched_before_a_night_in_the_background_is_used_after_it() {
        // The host clock counts the time the device sleeps, `Instant` does not: the old code kept a title and a plan
        // from the evening as fresh in the morning.
        let who = "https://a.example|u-night";
        let clock = JumpClock::new();
        remember_item(who, &item("t3"), clock.now());
        remember_plan(who, "t3", 1, None, &a_plan(), clock.now());
        assert!(super::item(who, "t3", clock.now()).is_some());
        assert!(super::plan(who, "t3", 1, None, clock.now()).is_some());
        clock.sleep_through(8.0 * 3600.0);
        assert!(super::item(who, "t3", clock.now()).is_none());
        assert!(super::plan(who, "t3", 1, None, clock.now()).is_none());
    }

    #[test]
    fn forgetting_a_title_drops_both_answers() {
        let who = "https://a.example|u-forget";
        let clock = JumpClock::new();
        remember_item(who, &item("t2"), clock.now());
        remember_plan(who, "t2", 1, None, &a_plan(), clock.now());
        forget(who, "t2");
        assert!(super::item(who, "t2", clock.now()).is_none());
        assert!(super::plan(who, "t2", 1, None, clock.now()).is_none());
    }
}
