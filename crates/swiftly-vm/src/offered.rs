//! What an account offers around its titles, asked once and kept: the collections with their members and the
//! titles of a collection's row. The detail page needs them for "Part of the collection" and used to ask the server
//! for all of it on every visit (the list of collections and a members list per collection). The old app asked once
//! after the home page and kept the answer for a minute (`AppModel.offeringLoad`), refreshing on the side.
//!
//! * [`directory`] hands out the stored directory whatever its age ("an existing directory is enough"); only when
//!   there is none does the caller wait for a fetch, and callers that arrive meanwhile share that one fetch.
//! * [`refresh`] asks again when the stored one is older than [`FRESH`]; pages call it after they have drawn, the home
//!   page calls it once its rows are up ([`warm`]).
//! * A failed fetch is not stored; it is not repeated on a page's critical path for [`RETRY`].
//!
//! Everything is per account (the same key as [`crate::prefetch`]), short-lived and small.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use futures_util::future::{FutureExt, Shared};
use swiftly_library::{CollectionDirectory, Store};
use swiftly_model::Item;

use crate::host::{Clock, Host, age};

/// How long the directory counts as current; older, it is used and refreshed on the side.
pub(crate) const FRESH: Duration = Duration::from_secs(60);
/// How long the titles of a collection's row are kept.
const MEMBERS_LIFETIME: Duration = Duration::from_secs(300);
/// After a failed fetch a page does not wait for another one this long.
const RETRY: Duration = Duration::from_secs(30);
/// Accounts remembered at once.
const ROOM: usize = 6;
/// Collections whose rows are remembered at once per account (a visited collection holds up to 2000 titles).
const MEMBERS_ROOM: usize = 12;

/// What the memory of an account belongs to: the host's store (one per running app, the same for every screen). A
/// second host (a test, a new session) starts from nothing, so an answer never outlives the app instance it came from.
#[derive(Clone)]
pub(crate) struct Owner(Weak<dyn Store>);

impl Owner {
    /// Belongs to this host.
    pub(crate) fn of(host: &Host) -> Self {
        Self(Arc::downgrade(&host.store))
    }

    /// The same host, still alive.
    pub(crate) fn same(&self, other: &Self) -> bool {
        self.0.strong_count() > 0 && std::ptr::addr_eq(self.0.as_ptr(), other.0.as_ptr())
    }
}

/// An account of a connection: the key of its memory and what that memory belongs to.
#[derive(Clone)]
pub(crate) struct Whose {
    pub(crate) key: String,
    pub(crate) owner: Owner,
    /// The host's clock: every age here is measured on it (it counts the time the device sleeps, `Instant` does not).
    pub(crate) clock: Arc<dyn Clock>,
}

impl Whose {
    /// The memory of the account with this key, [`crate::account::AccountRef::key`] (the key of the cache scope too,
    /// so that an event for the account and a sign-out find it), for the host the page runs in.
    pub(crate) fn new(key: &str, host: &Host) -> Self {
        Self {
            key: key.to_owned(),
            owner: Owner::of(host),
            clock: Arc::clone(&host.clock),
        }
    }
}

type Found = Option<Arc<CollectionDirectory>>;
type Pending = Shared<Pin<Box<dyn Future<Output = Found> + Send>>>;

/// The directory a fetch brought, when it came and how many library changes the account had reported by then.
struct Stored {
    found: Arc<CollectionDirectory>,
    /// When it came, on the host's clock.
    at: f64,
    epoch: u64,
}

/// Numbers the memories that were ever made, so that a fetch that comes back can tell whether the memory it began
/// under still stands (it does not after a sign-out, after the account had to make room, or for a new host).
static MADE: AtomicU64 = AtomicU64::new(1);

struct Slot {
    /// Which memory this is: a fetch stores its answer only into the one it began under.
    id: u64,
    owner: Owner,
    directory: Option<Stored>,
    /// Counts the changes of the library the account reported; a directory fetched under a smaller number is old.
    epoch: u64,
    /// Counts how often the stored directory was replaced by a different one (pages that are open compare it).
    version: u64,
    /// All times here are seconds on the host's clock.
    failed: Option<f64>,
    running: Option<(Pending, f64)>,
    members: HashMap<String, (Arc<Vec<Item>>, f64)>,
    used: Option<f64>,
}

impl Slot {
    fn new(owner: Owner) -> Self {
        Self {
            id: MADE.fetch_add(1, Ordering::Relaxed),
            owner,
            directory: None,
            epoch: 0,
            version: 0,
            failed: None,
            running: None,
            members: HashMap::new(),
            used: None,
        }
    }

    /// The titles of a collection's row, remembered as of `now`. Entries past [`MEMBERS_LIFETIME`] leave first, and at
    /// most [`MEMBERS_ROOM`] collections stay: when a new one needs room, the one asked longest ago leaves.
    fn keep(&mut self, collection: &str, list: Arc<Vec<Item>>, now: f64) {
        self.members
            .retain(|_, (_, at)| age(now, *at) < MEMBERS_LIFETIME);
        if !self.members.contains_key(collection)
            && self.members.len() >= MEMBERS_ROOM
            && let Some(oldest) = self
                .members
                .iter()
                .min_by(|(_, (_, a)), (_, (_, b))| a.total_cmp(b))
                .map(|(key, _)| key.clone())
        {
            self.members.remove(&oldest);
        }
        self.members.insert(collection.to_owned(), (list, now));
    }

    /// A directory was fetched (under `epoch`) or handed in: it becomes the stored one. The titles of a row are asked
    /// again only when the collections themselves changed.
    fn store(&mut self, found: Arc<CollectionDirectory>, epoch: u64, now: f64) {
        if self
            .directory
            .as_ref()
            .is_none_or(|old| *old.found != *found)
        {
            self.members.clear();
            self.version += 1;
        }
        self.directory = Some(Stored {
            found,
            at: now,
            epoch,
        });
        self.failed = None;
    }
}

static MEMORY: Mutex<Vec<(String, Slot)>> = Mutex::new(Vec::new());

fn with<R>(whose: &Whose, f: impl FnOnce(&mut Slot) -> R) -> R {
    let mut memory = MEMORY.lock().unwrap_or_else(PoisonError::into_inner);
    let at = match memory.iter().position(|(k, _)| *k == whose.key) {
        Some(at) => at,
        None => {
            if memory.len() >= ROOM {
                // The account that was used longest ago leaves.
                let oldest = memory
                    .iter()
                    .enumerate()
                    .min_by(|(_, (_, a)), (_, (_, b))| {
                        a.used
                            .unwrap_or(f64::MIN)
                            .total_cmp(&b.used.unwrap_or(f64::MIN))
                    })
                    .map(|(i, _)| i);
                if let Some(i) = oldest {
                    memory.remove(i);
                }
            }
            memory.push((whose.key.clone(), Slot::new(whose.owner.clone())));
            memory.len() - 1
        }
    };
    let slot = &mut memory[at].1;
    if !slot.owner.same(&whose.owner) {
        *slot = Slot::new(whose.owner.clone());
    }
    slot.used = Some(whose.clock.now());
    f(slot)
}

/// Runs `f` on the memory of the account when it is still the one with this id; never makes one (a fetch for an
/// account that signed out meanwhile has nobody to tell).
fn with_standing<R>(whose: &Whose, id: u64, f: impl FnOnce(&mut Slot) -> R) -> Option<R> {
    let mut memory = MEMORY.lock().unwrap_or_else(PoisonError::into_inner);
    let slot = memory
        .iter_mut()
        .find(|(k, _)| *k == whose.key)
        .map(|(_, slot)| slot)?;
    (slot.id == id).then(|| f(slot))
}

/// Taken before something is asked of the server for the account: what comes back is stored only if the account's
/// memory still stands then (it does not after a sign-out), so an answer never brings back a memory that was dropped.
#[derive(Clone, Copy)]
pub(crate) struct Stamp(u64);

/// The stamp of the account's memory as it stands now.
pub(crate) fn stamp(whose: &Whose) -> Stamp {
    with(whose, |s| Stamp(s.id))
}

/// The stored directory with its age, whatever that is. One that the library changed under counts as older than
/// any limit ([`Duration::MAX`]): it is still handed to a page, which refreshes it after it has drawn.
fn stored(whose: &Whose) -> Option<(Arc<CollectionDirectory>, Duration)> {
    with(whose, |s| {
        s.directory.as_ref().map(|d| {
            let old = if d.epoch == s.epoch {
                age(whose.clock.now(), d.at)
            } else {
                Duration::MAX
            };
            (Arc::clone(&d.found), old)
        })
    })
}

/// A fetch of the directory is running or starts now: this call and every other one share it. `None` when a recent
/// fetch failed and `quiet` says a page must not wait for another.
fn shared<F>(whose: &Whose, fetch: F, quiet: bool) -> Option<Pending>
where
    F: FnOnce() -> Pin<Box<dyn Future<Output = Option<CollectionDirectory>> + Send>>,
{
    with(whose, |s| {
        let now = whose.clock.now();
        if let Some((pending, at)) = &s.running
            && age(now, *at) < Duration::from_secs(30)
        {
            return Some(pending.clone());
        }
        if quiet && s.failed.is_some_and(|at| age(now, at) < RETRY) {
            return None;
        }
        let key = whose.clone();
        let started = s.epoch;
        let standing = s.id;
        let run = fetch();
        let pending: Pending = async move {
            let answer = run.await.map(Arc::new);
            // An account that signed out while this was on its way keeps nothing of it.
            with_standing(&key, standing, |s| {
                s.running = None;
                match &answer {
                    Some(d) => s.store(Arc::clone(d), started, key.clock.now()),
                    None => s.failed = Some(key.clock.now()),
                }
            });
            answer
        }
        .boxed()
        .shared();
        s.running = Some((pending.clone(), now));
        Some(pending)
    })
}

/// The directory for a page: the stored one at once, whatever its age; without one this waits for the (shared) fetch.
pub(crate) async fn directory<F>(whose: &Whose, fetch: F) -> Found
where
    F: FnOnce() -> Pin<Box<dyn Future<Output = Option<CollectionDirectory>> + Send>>,
{
    if let Some((found, _)) = stored(whose) {
        return Some(found);
    }
    shared(whose, fetch, true)?.await
}

/// Asks again when the stored directory is older than [`FRESH`] (or there is none); a fetch that is already running is
/// shared. For the time after a page has drawn: nothing waits for it.
pub(crate) async fn refresh<F>(whose: &Whose, fetch: F)
where
    F: FnOnce() -> Pin<Box<dyn Future<Output = Option<CollectionDirectory>> + Send>>,
{
    if stored(whose).is_some_and(|(_, age)| age < FRESH) {
        return;
    }
    if let Some(run) = shared(whose, fetch, false) {
        run.await;
    }
}

/// Puts a directory somebody else fetched into the memory (the library page does), unless the memory the fetch began
/// under is gone ([`Stamp`]).
pub(crate) fn remember(whose: &Whose, began: Stamp, found: &CollectionDirectory) {
    with_standing(whose, began.0, |s| {
        let epoch = s.epoch;
        s.store(Arc::new(found.clone()), epoch, whose.clock.now());
    });
}

/// The library of the account changed (`LibraryChanged`, or events may have been missed meanwhile): the stored
/// directory stays for pages that need something at once but is old now, so the next page refreshes it after it has
/// drawn. The titles of the rows stay until that refresh brings a different directory (a title that joined or left a
/// collection changes it), so the page that asks next still draws without a request.
pub(crate) fn changed(key: &str) {
    let mut memory = MEMORY.lock().unwrap_or_else(PoisonError::into_inner);
    for (_, slot) in memory.iter_mut().filter(|(k, _)| k == key) {
        slot.epoch += 1;
    }
}

/// The account is gone (sign-out): nothing stays.
pub(crate) fn forget(key: &str) {
    MEMORY
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .retain(|(k, _)| k != key);
}

/// Moves whenever the stored directory is replaced by a different one: a page that drew from an earlier directory
/// sees that its row may be out of date.
pub(crate) fn version(whose: &Whose) -> u64 {
    with(whose, |s| s.version)
}

/// The stored directory when it is current (less than [`FRESH`] old).
pub(crate) fn current(whose: &Whose) -> Option<CollectionDirectory> {
    stored(whose)
        .filter(|(_, age)| *age < FRESH)
        .map(|(d, _)| (*d).clone())
}

/// The titles of a collection's row, when they were asked a short while ago.
pub(crate) fn members(whose: &Whose, collection: &str) -> Option<Arc<Vec<Item>>> {
    with(whose, |s| {
        s.members
            .get(collection)
            .filter(|(_, at)| age(whose.clock.now(), *at) < MEMBERS_LIFETIME)
            .map(|(m, _)| Arc::clone(m))
    })
}

/// The titles of a collection's row as just asked (kept unless the memory the fetch began under is gone, [`Stamp`]).
pub(crate) fn remember_members(
    whose: &Whose,
    began: Stamp,
    collection: &str,
    list: Vec<Item>,
) -> Arc<Vec<Item>> {
    let list = Arc::new(list);
    with_standing(whose, began.0, |s| {
        s.keep(collection, Arc::clone(&list), whose.clock.now());
    });
    list
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::JumpClock;
    use swiftly_library::{ItemCollection, Store};

    struct NoStore;
    impl Store for NoStore {
        fn read(&self, _: &str) -> Option<Vec<u8>> {
            None
        }
        fn write(&self, _: &str, _: &[u8]) {}
        fn remove(&self, _: &str) {}
    }

    /// An account of its own (the memory is a process-wide static, so every test takes a key of its own) and the
    /// host store it belongs to, which must stay alive for the test.
    fn account(key: &str) -> (Whose, Arc<dyn Store>) {
        let (who, store, _clock) = account_on_clock(key);
        (who, store)
    }

    /// The same, with the host clock handed out so a test can make time pass.
    fn account_on_clock(key: &str) -> (Whose, Arc<dyn Store>, Arc<JumpClock>) {
        let store: Arc<dyn Store> = Arc::new(NoStore);
        let owner = Owner(Arc::downgrade(&store));
        let clock = JumpClock::new();
        (
            Whose {
                key: key.to_owned(),
                owner,
                clock: Arc::clone(&clock) as Arc<dyn Clock>,
            },
            store,
            clock,
        )
    }

    fn title(id: &str) -> Item {
        Item {
            id: id.to_owned(),
            ..Item::default()
        }
    }

    fn directory_of(collections: &[&str]) -> CollectionDirectory {
        CollectionDirectory {
            all: collections
                .iter()
                .map(|id| ItemCollection::new(title(id), &[]))
                .collect(),
        }
    }

    #[test]
    fn a_remembered_directory_that_differs_drops_the_titles_of_the_old_one() {
        let (who, _store) = account("offered-test|remember-clears");
        remember(&who, stamp(&who), &directory_of(&["c1"]));
        remember_members(&who, stamp(&who), "c1", vec![title("m1")]);
        assert!(members(&who, "c1").is_some());
        // The same directory again keeps them; a different one does not.
        remember(&who, stamp(&who), &directory_of(&["c1"]));
        assert!(members(&who, "c1").is_some());
        remember(&who, stamp(&who), &directory_of(&["c1", "c2"]));
        assert!(members(&who, "c1").is_none());
    }

    fn keep(slot: &mut Slot, collection: &str, at: f64) {
        slot.keep(collection, Arc::new(vec![title("m")]), at);
    }

    #[test]
    fn the_titles_of_collection_rows_are_bounded_and_the_oldest_leave_first() {
        let (who, _store) = account("offered-test|members-bound");
        let mut slot = Slot::new(who.owner.clone());
        let start = 1_000.0;
        for n in 0..=MEMBERS_ROOM {
            keep(&mut slot, &format!("c{n}"), start + n as f64);
        }
        assert_eq!(slot.members.len(), MEMBERS_ROOM);
        assert!(!slot.members.contains_key("c0"), "the oldest is gone");
        assert!(slot.members.contains_key(&format!("c{MEMBERS_ROOM}")));
        // Asking a collection again replaces its entry and pushes nobody else out.
        keep(&mut slot, "c1", start + 100.0);
        assert_eq!(slot.members.len(), MEMBERS_ROOM);
        assert!(slot.members.contains_key("c2"));
    }

    #[test]
    fn an_expired_entry_leaves_on_the_next_insert() {
        let (who, _store) = account("offered-test|members-expired");
        let mut slot = Slot::new(who.owner.clone());
        let start = 1_000.0;
        keep(&mut slot, "old", start);
        keep(&mut slot, "also-old", start + 1.0);
        keep(
            &mut slot,
            "new",
            start + MEMBERS_LIFETIME.as_secs_f64() + 2.0,
        );
        assert_eq!(slot.members.len(), 1, "{:?}", slot.members.keys());
        assert!(slot.members.contains_key("new"));
    }

    #[test]
    fn a_change_of_the_library_makes_the_stored_directory_old_but_keeps_it_for_pages() {
        let (who, _store) = account("offered-test|changed");
        remember(&who, stamp(&who), &directory_of(&["c1"]));
        remember_members(&who, stamp(&who), "c1", vec![title("m1")]);
        assert!(current(&who).is_some());
        changed(&who.key);
        assert!(current(&who).is_none(), "old: the next page asks again");
        assert!(
            stored(&who).is_some(),
            "but a page still draws from it at once"
        );
        assert!(
            members(&who, "c1").is_some(),
            "the rows draw from memory too"
        );
    }

    #[test]
    fn a_fetch_that_began_before_a_change_is_stored_as_old() {
        let (who, _store) = account("offered-test|changed-during");
        let key = who.key.clone();
        futures_executor::block_on(refresh(&who, move || {
            Box::pin(async move {
                changed(&key);
                Some(directory_of(&["c1"]))
            })
        }));
        assert!(stored(&who).is_some());
        assert!(current(&who).is_none());
    }

    #[test]
    fn the_version_moves_only_when_the_directory_differs() {
        let (who, _store) = account("offered-test|version");
        remember(&who, stamp(&who), &directory_of(&["c1"]));
        let first = version(&who);
        remember(&who, stamp(&who), &directory_of(&["c1"]));
        assert_eq!(version(&who), first);
        remember(&who, stamp(&who), &directory_of(&["c1", "c2"]));
        assert_ne!(version(&who), first);
    }

    #[test]
    fn forgetting_an_account_drops_what_it_remembered() {
        let (who, _store) = account("offered-test|forget");
        remember(&who, stamp(&who), &directory_of(&["c1"]));
        forget(&who.key);
        assert!(stored(&who).is_none());
    }

    /// Whether the memory holds a slot for the key (looking does not make one).
    fn remembered(key: &str) -> bool {
        MEMORY
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .any(|(k, _)| k == key)
    }

    #[test]
    fn a_fetch_for_an_account_that_was_forgotten_meanwhile_stores_nothing() {
        let (who, _store) = account("offered-test|forgotten-during");
        let key = who.key.clone();
        let answer = futures_executor::block_on(directory(&who, move || {
            Box::pin(async move {
                // The account signs out while the answer is on its way.
                forget(&key);
                Some(directory_of(&["c1"]))
            })
        }));
        assert!(
            answer.is_some(),
            "the page that asked still gets its answer"
        );
        assert!(
            !remembered(&who.key),
            "the answer made the account's memory again"
        );
        assert!(stored(&who).is_none());
    }

    #[test]
    fn a_row_asked_before_the_account_was_forgotten_is_not_stored() {
        let (who, _store) = account("offered-test|members-forgotten");
        remember(&who, stamp(&who), &directory_of(&["c1"]));
        let began = stamp(&who);
        forget(&who.key);
        let list = remember_members(&who, began, "c1", vec![title("m1")]);
        assert_eq!(list.len(), 1, "the page that asked still gets its titles");
        assert!(!remembered(&who.key));
    }

    #[test]
    fn a_directory_handed_in_for_a_forgotten_account_is_not_stored() {
        let (who, _store) = account("offered-test|handed-in-forgotten");
        let began = stamp(&who);
        forget(&who.key);
        remember(&who, began, &directory_of(&["c1"]));
        assert!(!remembered(&who.key));
    }

    #[test]
    fn a_night_the_device_slept_makes_the_directory_and_the_rows_old() {
        // The stored answer is current for a minute, a row for five. Time that passes while the device sleeps counts:
        // the host clock moves, the runtime's own clock (`Instant`) does not, which is what this test stands for.
        let (who, _store, clock) = account_on_clock("offered-test|slept");
        remember(&who, stamp(&who), &directory_of(&["c1"]));
        remember_members(&who, stamp(&who), "c1", vec![title("m1")]);
        clock.sleep_through(FRESH.as_secs_f64() - 1.0);
        assert!(current(&who).is_some(), "59 s: still current");
        assert!(members(&who, "c1").is_some());
        clock.sleep_through(2.0);
        assert!(current(&who).is_none(), "61 s: old");
        assert!(stored(&who).is_some(), "but a page still draws from it");
        assert!(
            members(&who, "c1").is_some(),
            "a row lives for five minutes"
        );
        clock.sleep_through(8.0 * 3600.0);
        assert!(current(&who).is_none());
        assert!(
            members(&who, "c1").is_none(),
            "a night later no row is fresh"
        );
    }

    #[test]
    fn a_failed_fetch_is_retried_after_a_night() {
        let (who, _store, clock) = account_on_clock("offered-test|failed-slept");
        let none = || -> Pin<Box<dyn Future<Output = Option<CollectionDirectory>> + Send>> {
            Box::pin(async { None })
        };
        assert!(futures_executor::block_on(directory(&who, none)).is_none());
        // A page does not wait for another fetch right after a failed one ...
        assert!(shared(&who, none, true).is_none());
        // ... but it does after the retry time, which also passes while the device sleeps.
        clock.sleep_through(8.0 * 3600.0);
        assert!(shared(&who, none, true).is_some());
    }
}
