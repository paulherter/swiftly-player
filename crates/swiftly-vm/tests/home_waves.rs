//! How many requests the start page needs one after the other. A request counts as one level
//! deeper than the deepest request that had finished before it was sent, so the number is the
//! length of the longest chain of dependent round trips, whatever the latency.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

use common::{Manual, Net, Pool, account};
use swiftly_l10n::Locale;
use swiftly_library::{HomeStore, MemoryStore};
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use swiftly_vm::{HomeIntent, HomePrefs, HomeVm, Host, Status};

/// The scripted server behind a recorder of request depth.
struct Depth {
    net: Arc<Net>,
    finished: Arc<AtomicUsize>,
    sent: Arc<Mutex<Vec<(usize, String)>>>,
}

/// Pending a number of passes, so that everything that starts side by side (a few passes apart at most) is sent
/// before any answer is taken.
struct Yield(u32);

impl Future for Yield {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if self.0 == 0 {
            return Poll::Ready(());
        }
        self.0 -= 1;
        cx.waker().wake_by_ref();
        Poll::Pending
    }
}

impl Depth {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            net: Net::new(true),
            finished: Arc::new(AtomicUsize::new(0)),
            sent: Arc::new(Mutex::new(Vec::new())),
        })
    }
    /// The levels at which requests matching `needle` were sent. Only the requests of the rows are pinned: what the
    /// page asks for after it is up (collections, series ahead) is not waited for.
    fn levels(&self, needle: &str) -> Vec<usize> {
        self.sent
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, l)| l.contains(needle))
            .map(|(d, _)| *d)
            .collect()
    }
}

impl HttpTransport for Depth {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        let level = self.finished.load(Ordering::SeqCst) + 1;
        self.sent.lock().unwrap().push((
            level,
            format!(
                "{}?{}",
                request.url.path(),
                request.url.query().unwrap_or("")
            ),
        ));
        let finished = self.finished.clone();
        let answer = self.net.send(request);
        async move {
            Yield(40).await;
            let reply = answer.await;
            finished.fetch_max(level, Ordering::SeqCst);
            reply
        }
    }
}

fn vm(depth: &Arc<Depth>, store: &Arc<MemoryStore>) -> HomeVm<Depth> {
    let host = Host {
        // One worker thread: the tasks of a run take turns at their waiting points, so the depth is the same on
        // every run (with two threads a sibling request can start after an unrelated answer already came in).
        spawner: Arc::new(Pool(
            futures_executor::ThreadPool::builder()
                .pool_size(1)
                .create()
                .unwrap(),
        )),
        clock: Manual::at(1000.0),
        store: store.clone(),
        locale: Locale::parse("de"),
        device_name: "Test".into(),
        client_version: "0.0.0".into(),
        cache: None,
    };
    let prefs = HomePrefs {
        disconnected: true,
        ..HomePrefs::default()
    };
    HomeVm::new(depth.clone(), host, prefs, Some(account("TOKEN-A"))).unwrap()
}

fn settled(vm: &HomeVm<Depth>) {
    let end = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let s = vm.status();
        if s.status == Status::Ready && !s.preview && !s.refreshing {
            return;
        }
        assert!(std::time::Instant::now() < end, "timed out: {s:?}");
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
}

fn rows(vm: &HomeVm<Depth>) -> Vec<(String, Vec<String>)> {
    vm.rails()
        .rails
        .iter()
        .map(|r| (r.title.clone(), r.ids.clone()))
        .collect()
}

#[test]
fn a_cold_start_needs_three_waves_and_asks_the_libraries_once() {
    let depth = Depth::new();
    let store = Arc::new(MemoryStore::new());
    let vm = vm(&depth, &store);
    vm.send(HomeIntent::Load);
    settled(&vm);

    // The libraries, then the ids of the new movies, then the movies; everything else goes out in the first wave.
    // Before: the libraries were asked a second time inside the loader, one wave after the first.
    for first in ["UserItems/Resume", "Shows/NextUp", "DateLastContentAdded"] {
        assert_eq!(depth.levels(first), [1], "{first}");
    }
    assert_eq!(depth.levels("ParentId=lib-movies"), [2]);
    assert_eq!(depth.levels("Ids=m1,m2,m3"), [3]);
    let early: Vec<usize> = depth
        .levels("UserViews")
        .into_iter()
        .filter(|d| *d <= 3)
        .collect();
    assert_eq!(early, [1], "the libraries are asked once, with the rows");
    assert_eq!(
        rows(&vm),
        [
            (
                "Weiterschauen".to_owned(),
                vec!["r1".to_owned(), "e1".into()]
            ),
            ("Nächste Folge".to_owned(), vec!["e2".to_owned()]),
            (
                "Zuletzt hinzugefügte Filme".to_owned(),
                vec!["m1".to_owned(), "m2".into(), "m3".into()]
            ),
            (
                "Zuletzt hinzugefügte Serien".to_owned(),
                vec!["m1".to_owned(), "m2".into(), "m3".into()]
            ),
        ]
    );
}

#[test]
fn a_warm_start_needs_two_waves_and_no_blocking_libraries_request() {
    let store = Arc::new(MemoryStore::new());
    let first = Depth::new();
    let seed = vm(&first, &store);
    seed.send(HomeIntent::Load);
    settled(&seed);
    let cold_rows = rows(&seed);
    let key = account("TOKEN-A").key();
    let end = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while HomeStore::load(&*store, &key).is_none() {
        assert!(std::time::Instant::now() < end, "snapshot not stored");
        std::thread::sleep(std::time::Duration::from_millis(2));
    }

    let depth = Depth::new();
    let vm = vm(&depth, &store);
    vm.send(HomeIntent::Load);
    settled(&vm);
    // The libraries come from the stored page: the ids of the new movies go out with the first wave, the movies
    // follow. Before: the loader asked for the libraries first (three waves).
    assert_eq!(depth.levels("ParentId=lib-movies"), [1]);
    assert_eq!(depth.levels("Ids=m1,m2,m3"), [2]);
    // The same rows as the cold load.
    assert_eq!(rows(&vm), cold_rows);
}
