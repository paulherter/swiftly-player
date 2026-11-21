//! A server that refuses the connection: the home load sends each call once and reports `Offline` at once. Before, the
//! network layer tried every call three times (0.2 s and 0.4 s apart, plus 1.5 to 2 s per refused connect on Apple and
//! Windows), and the fallback chain of a split "new" row went on level by level, so the notice over the stored rows came
//! after 6 to 9 s.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::collections::HashSet;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::{Manual, Net, Pool, account};
use swiftly_l10n::Locale;
use swiftly_library::{HomeStore, MemoryStore};
use swiftly_net::{
    ErrorKind, HttpRequest, HttpResponse, HttpTransport, LayeredTransport, Timer, url_error,
};
use swiftly_vm::{HomeIntent, HomePrefs, HomeVm, Host, Status};

/// A server that is not there: every send is refused. The paths are recorded.
struct Refusing(Arc<Mutex<Vec<String>>>);

impl HttpTransport for Refusing {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        self.0.lock().unwrap().push(format!(
            "{}?{}",
            request.url.path(),
            request.url.query().unwrap_or("")
        ));
        async {
            Err(ErrorKind::Network {
                code: url_error::CANNOT_CONNECT_TO_HOST,
            })
        }
    }
}

/// The layer's retry pause, taken at once: the test counts sends, it does not wait for them.
struct NoWait;

impl Timer for NoWait {
    fn sleep(&self, _d: Duration) -> std::pin::Pin<Box<dyn Future<Output = ()> + Send>> {
        Box::pin(std::future::ready(()))
    }
}

fn vm<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    store: &Arc<MemoryStore>,
    disconnected: bool,
) -> HomeVm<T> {
    let host = Host {
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
        disconnected,
        ..HomePrefs::default()
    };
    HomeVm::new(transport.clone(), host, prefs, Some(account("TOKEN-A"))).unwrap()
}

fn wait(what: &str, mut done: impl FnMut() -> bool) {
    let end = Instant::now() + Duration::from_secs(30);
    while !done() {
        assert!(Instant::now() < end, "timed out: {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn refused_server() -> (Arc<LayeredTransport<Refusing>>, Arc<Mutex<Vec<String>>>) {
    let sent = Arc::new(Mutex::new(Vec::new()));
    let layered = LayeredTransport::new(Refusing(sent.clone()), Arc::new(NoWait));
    (Arc::new(layered), sent)
}

/// The paths that went out more than once.
fn repeated(sent: &Mutex<Vec<String>>) -> Vec<String> {
    let sent = sent.lock().unwrap();
    let mut seen = HashSet::new();
    sent.iter()
        .filter(|p| !seen.insert((*p).clone()))
        .cloned()
        .collect()
}

#[test]
fn a_refused_server_is_asked_once_per_call_and_the_page_is_offline() {
    for disconnected in [false, true] {
        let (transport, sent) = refused_server();
        let vm = vm(&transport, &Arc::new(MemoryStore::new()), disconnected);
        vm.send(HomeIntent::Load);
        wait("Offline", || {
            let s = vm.status();
            s.status == Status::Offline && !s.refreshing
        });
        // Settle: nothing more may go out after the page said so.
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(repeated(&sent), Vec::<String>::new(), "retried: {sent:?}");
        // The first try of the run ends it: the loader's fan-out (continue watching, next up, newest, libraries) is
        // sent once, and the fallback levels of the split "new" rows behind a failed call are not.
        let n = sent.lock().unwrap().len();
        assert!(n <= 4, "{n} requests for a refused server: {sent:?}");
    }
}

#[test]
fn a_refused_server_over_stored_rows_ends_in_offline_with_the_rows_still_there() {
    // The stored page of an earlier session, from a server that answered.
    let store = Arc::new(MemoryStore::new());
    let open = Net::new(true);
    let seed = vm(&open, &store, false);
    seed.send(HomeIntent::Load);
    wait("first load", || {
        let s = seed.status();
        s.status == Status::Ready && !s.preview && !s.refreshing
    });
    let key = account("TOKEN-A").key();
    wait("snapshot stored", || {
        HomeStore::load(&*store, &key).is_some()
    });
    let rows = seed.rails().rails.len();
    assert!(rows > 0);

    // The server is gone: the page shows the stored rows and ends in `Offline` after one refused try per call.
    let (transport, sent) = refused_server();
    let vm = vm(&transport, &store, false);
    vm.send(HomeIntent::Load);
    wait("Offline over the stored rows", || {
        let s = vm.status();
        s.status == Status::Offline && !s.refreshing
    });
    assert_eq!(vm.rails().rails.len(), rows, "the stored rows stay");
    assert_eq!(repeated(&sent), Vec::<String>::new(), "retried: {sent:?}");
}
