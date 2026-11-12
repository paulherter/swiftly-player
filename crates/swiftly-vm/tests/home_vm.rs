//! The home view model against a scripted server: cold load, preview then network, account
//! switch in the middle of a load, offline fallback, the 30 s refresh rule, and `changed`.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use common::{Net, account, rig, until};
use swiftly_library::{HomeStore, MemoryStore};
use swiftly_vm::{Badge, FailKind, HomeIntent, HomeVm, ImageKind, Load, RailKind, Status, part};

fn titles(vm: &HomeVm<Net>) -> Vec<String> {
    vm.rails().rails.iter().map(|r| r.title.clone()).collect()
}

fn tile_titles(vm: &HomeVm<Net>) -> Vec<String> {
    vm.rails()
        .rails
        .iter()
        .flat_map(|r| r.tiles.iter().map(|t| t.title.clone()))
        .collect()
}

#[test]
fn cold_load_fills_the_rails_with_display_ready_tiles() {
    let rig = rig(
        Net::new(true),
        Arc::new(MemoryStore::new()),
        "de",
        Some("TOKEN-A"),
    );
    let vm = &rig.vm;
    assert_eq!(vm.status().status, Status::Loading);
    assert!(vm.rails().rails.is_empty());

    vm.send(HomeIntent::Load);
    until(vm, "ready", common::ready);

    assert_eq!(
        titles(vm),
        ["Weiterschauen", "Nächste Folge", "Zuletzt hinzugefügt"]
    );
    let rails = vm.rails();
    let resume = &rails.rails[0];
    assert_eq!(
        (resume.id.as_str(), resume.kind),
        ("weiterschauen", RailKind::ContinueWatching)
    );
    assert_eq!(resume.title_key, "Weiterschauen");
    assert_eq!(resume.ids, ["r1", "e1"]);
    // A movie in continue watching: year line, progress, backdrop.
    let movie = &resume.tiles[0];
    assert_eq!(
        (movie.title.as_str(), movie.subtitle.as_deref()),
        ("Der Weg zurück", Some("2019"))
    );
    assert!((movie.progress.unwrap() - 0.4).abs() < 1e-6);
    let image = movie.image.as_ref().unwrap();
    assert_eq!(image.kind, ImageKind::Backdrop);
    assert!(image.address.contains("/Items/r1/Images/Backdrop?tag=b-r1"));
    assert_eq!((image.wanted_width, image.wanted_height), (640, 360));
    // An episode: series name and "S1 · F3".
    let episode = &resume.tiles[1];
    assert_eq!(
        (episode.title.as_str(), episode.subtitle.as_deref()),
        ("Dark Matter", Some("S1 · F3"))
    );
    // The continue-watching line with the time left (`continueWatchingRow`).
    assert_eq!(movie.remaining.as_deref(), Some("2019 · noch 54 Min."));
    assert_eq!(episode.remaining.as_deref(), Some("S1 · F3 · noch 34 Min."));
    // What continue watching has is not repeated in next up.
    assert_eq!(rails.rails[1].ids, ["e2"]);
    // The shared new-additions row, with marks.
    let recent = &rails.rails[2];
    assert_eq!(recent.kind, RailKind::NewArrivals);
    assert_eq!(recent.ids, ["m1", "m2", "m3"]);
    let seen = recent.tiles.iter().find(|t| t.id == "m2").unwrap();
    assert_eq!(seen.badges, [Badge::Watched, Badge::Favorite]);
    assert_eq!(seen.image.as_ref().unwrap().kind, ImageKind::Poster);

    // The page of this account is remembered for the next launch. The snapshot goes to the store after the page is
    // published (outside the lock), so wait for it.
    until(vm, "snapshot stored", |_| {
        HomeStore::load(&*rig.store, &account("TOKEN-A").key()).is_some()
    });
    // The token travels in the header, never in the query of a data request.
    for request in rig.net.seen.lock().unwrap().iter() {
        let header = request.header("Authorization").unwrap();
        assert!(header.contains("Token=\"TOKEN-A\""));
        assert!(!request.url.as_str().contains("TOKEN-A"), "{}", request.url);
    }
}

#[test]
fn the_text_follows_the_locale() {
    let rig = rig(
        Net::new(true),
        Arc::new(MemoryStore::new()),
        "en",
        Some("TOKEN-A"),
    );
    rig.vm.send(HomeIntent::Load);
    until(&rig.vm, "ready", common::ready);
    assert_eq!(titles(&rig.vm)[0], "Continue watching");
    assert_eq!(rig.vm.rails().rails[0].title_key, "Weiterschauen");
}

#[test]
fn the_stored_preview_shows_first_then_the_network_takes_over() {
    let store = Arc::new(MemoryStore::new());
    let first = rig(Net::new(true), store.clone(), "de", Some("TOKEN-A"));
    first.vm.send(HomeIntent::Load);
    until(&first.vm, "first ready", common::ready);
    let remembered = tile_titles(&first.vm);

    // Next launch: the server is slow (gate closed).
    let net = Net::new(false);
    let second = rig(net.clone(), store, "de", Some("TOKEN-A"));
    let seen = second.vm.version();
    second.vm.send(HomeIntent::Load);
    until(&second.vm, "preview", |vm| {
        vm.status().preview && !vm.rails().rails.is_empty()
    });
    let status = second.vm.status();
    assert_eq!((status.status, status.preview), (Status::Loading, true));
    assert_eq!(tile_titles(&second.vm), remembered);
    let change = futures_executor::block_on(second.vm.changed(seen));
    assert_eq!(change.parts, part::RAILS | part::STATUS);

    net.gate.open();
    until(&second.vm, "network", common::ready);
    assert!(!second.vm.status().preview);
}

#[test]
fn an_account_switch_in_the_middle_of_a_load_shows_only_the_new_account() {
    let net = Net::new(false);
    let rig = rig(
        net.clone(),
        Arc::new(MemoryStore::new()),
        "de",
        Some("TOKEN-A"),
    );
    let vm = &rig.vm;
    vm.send(HomeIntent::Load);
    until(vm, "requests in flight", |_| net.requests() > 0);

    vm.send(HomeIntent::AccountSwitched {
        account: Some(account("TOKEN-B")),
    });
    assert!(vm.rails().rails.is_empty(), "the page is empty at once");
    assert_eq!(vm.status().status, Status::Loading);

    net.gate.open();
    until(vm, "ready", common::ready);
    assert_eq!(titles(vm), ["Weiterschauen", "Zuletzt hinzugefügt"]);
    assert_eq!(tile_titles(vm), ["Zweiter Film", "Neues Konto"]);
    // Nothing of the first account was stored for the second.
    assert!(HomeStore::load(&*rig.store, &account("TOKEN-A").key()).is_none());
    assert!(HomeStore::load(&*rig.store, &account("TOKEN-B").key()).is_some());

    // The aborted run was ended: the refresh rule works again.
    let before = net.requests();
    rig.clock.set(1031.0);
    vm.send(HomeIntent::Refresh);
    until(vm, "reload", |_| net.requests() > before);

    // Signed out: nothing to show.
    vm.send(HomeIntent::AccountSwitched { account: None });
    assert_eq!(vm.status().status, Status::SignedOut);
    assert!(vm.rails().rails.is_empty());
}

#[test]
fn offline_the_preview_stays_and_the_status_says_so() {
    let store = Arc::new(MemoryStore::new());
    let first = rig(Net::new(true), store.clone(), "de", Some("TOKEN-A"));
    first.vm.send(HomeIntent::Load);
    until(&first.vm, "ready", common::ready);
    let remembered = titles(&first.vm);

    let net = Net::new(true);
    net.offline.store(true, Ordering::SeqCst);
    let second = rig(net.clone(), store, "de", Some("TOKEN-A"));
    second.vm.send(HomeIntent::Load);
    until(&second.vm, "offline", |vm| {
        vm.status().status == Status::Offline
    });
    assert_eq!(titles(&second.vm), remembered);
    assert!(second.vm.status().preview, "what is shown is the old state");

    // Without a stored page: offline and empty.
    let bare = rig(net, Arc::new(MemoryStore::new()), "de", Some("TOKEN-A"));
    bare.vm.send(HomeIntent::Load);
    until(&bare.vm, "offline", |vm| {
        vm.status().status == Status::Offline
    });
    assert!(bare.vm.rails().rails.is_empty());
}

#[test]
fn refresh_reloads_only_after_thirty_seconds() {
    let net = Net::new(true);
    let rig = rig(
        net.clone(),
        Arc::new(MemoryStore::new()),
        "de",
        Some("TOKEN-A"),
    );
    let vm = &rig.vm;
    vm.send(HomeIntent::Load);
    until(vm, "ready", common::ready);
    let loaded = net.requests();

    rig.clock.set(1029.9);
    vm.send(HomeIntent::Refresh);
    std::thread::sleep(Duration::from_millis(80));
    assert_eq!(net.requests(), loaded, "29.9 s: still fresh");

    rig.clock.set(1030.0);
    vm.send(HomeIntent::Refresh);
    until(vm, "reload", |_| net.requests() > loaded);
    until(vm, "ready again", common::ready);
    let reloaded = net.requests();

    // `Load` (pull to refresh) is not bound by the rule.
    vm.send(HomeIntent::Load);
    until(vm, "forced reload", |_| net.requests() > reloaded);
}

#[test]
fn the_window_grows_when_a_rail_is_visible() {
    let net = Net::new(true);
    net.many.store(true, Ordering::SeqCst);
    let rig = rig(net, Arc::new(MemoryStore::new()), "de", Some("TOKEN-A"));
    let vm = &rig.vm;
    vm.send(HomeIntent::Load);
    until(vm, "ready", common::ready);
    let rails = vm.rails();
    let recent = rails.rails.iter().find(|r| r.id == "neuzugaenge").unwrap();
    assert_eq!(
        (recent.count, recent.ids.len(), recent.tiles.len()),
        (24, 24, 12)
    );

    let seen = vm.version();
    vm.send(HomeIntent::Visible {
        rail: "neuzugaenge".into(),
    });
    let change = futures_executor::block_on(vm.changed(seen));
    assert_eq!(change.parts, part::RAILS, "only the rails part moved");
    let rails = vm.rails();
    let grown = rails.rails.iter().find(|r| r.id == "neuzugaenge").unwrap();
    assert_eq!(grown.tiles.len(), 24);
    // Beyond the window, on demand.
    let tail = vm.tiles("neuzugaenge", 20, 10);
    assert_eq!(tail.len(), 4);
    assert_eq!(tail[0].id, recent.ids[20]);
}

#[test]
fn changed_coalesces_and_a_dropped_future_unparks() {
    let rig = rig(
        Net::new(true),
        Arc::new(MemoryStore::new()),
        "de",
        Some("TOKEN-A"),
    );
    let vm = &rig.vm;
    // Newer than 0 at once.
    assert!(futures_executor::block_on(vm.changed(0)).version > 0);
    // Not newer: parked.
    let now = vm.version();
    let mut parked = Box::pin(vm.changed(now));
    let mut cx = Context::from_waker(Waker::noop());
    assert!(matches!(parked.as_mut().poll(&mut cx), Poll::Pending));
    assert_eq!(vm.waiters(), 1);
    // Several changes while parked: one answer.
    vm.send(HomeIntent::Load);
    until(vm, "ready", common::ready);
    let Poll::Ready(change) = parked.as_mut().poll(&mut cx) else {
        panic!("woken by the load");
    };
    assert_eq!(change.version, vm.version());
    assert_eq!(change.parts, part::RAILS | part::STATUS);
    drop(parked);
    let mut again = Box::pin(vm.changed(vm.version()));
    assert!(matches!(again.as_mut().poll(&mut cx), Poll::Pending));
    assert_eq!(vm.waiters(), 1);
    drop(again);
    assert_eq!(vm.waiters(), 0);
}

/// F4 (dossier 16, `b2db80d5`): a host callback must never run under a lock the UI thread can wait
/// for. The host store blocks its `write`; while it blocks, `rails()` and `status()` (what the main
/// thread reads) must still answer.
#[test]
fn a_blocked_host_store_write_does_not_block_the_readers() {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Instant;
    use swiftly_library::Store;

    struct Blocking {
        inner: MemoryStore,
        writing: AtomicBool,
        release: AtomicBool,
    }
    impl Store for Blocking {
        fn read(&self, name: &str) -> Option<Vec<u8>> {
            self.inner.read(name)
        }
        fn write(&self, name: &str, data: &[u8]) {
            self.writing.store(true, Ordering::SeqCst);
            let until = Instant::now() + Duration::from_secs(10);
            while !self.release.load(Ordering::SeqCst) && Instant::now() < until {
                std::thread::sleep(Duration::from_millis(2));
            }
            self.inner.write(name, data);
        }
        fn remove(&self, name: &str) {
            self.inner.remove(name);
        }
    }

    let store = Arc::new(Blocking {
        inner: MemoryStore::new(),
        writing: AtomicBool::new(false),
        release: AtomicBool::new(false),
    });
    let host = swiftly_vm::Host {
        spawner: Arc::new(common::Pool(common::pool())),
        clock: common::Manual::at(1000.0),
        store: store.clone(),
        locale: swiftly_l10n::Locale::parse("de"),
        device_name: "Test".into(),
        client_version: "0.0.0".into(),
        cache: None,
    };
    let vm = HomeVm::new(
        Net::new(true),
        host,
        swiftly_vm::HomePrefs::default(),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    vm.send(HomeIntent::Load);
    let start = Instant::now();
    while !store.writing.load(Ordering::SeqCst) {
        assert!(
            start.elapsed() < Duration::from_secs(8),
            "the store was never written"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
    // The write is blocked now: the readers answer from another thread within a second.
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = vm.clone();
    std::thread::spawn(move || {
        let _ = reader.rails();
        let _ = reader.status();
        let _ = reader.version();
        let _ = tx.send(());
    });
    let answered = rx.recv_timeout(Duration::from_secs(2)).is_ok();
    store.release.store(true, Ordering::SeqCst);
    assert!(
        answered,
        "rails()/status() waited for the host's blocked store write"
    );
}

#[test]
fn chosen_libraries_are_rails_after_the_fixed_ones_and_default_prefs_have_none() {
    use swiftly_library::start_libraries::StartLibrary;
    let rig = common::rig(
        Net::new(true),
        Arc::new(MemoryStore::new()),
        "de",
        Some("TOKEN-A"),
    );
    let vm = &rig.vm;
    vm.set_start_libraries(vec![StartLibrary::new("lib-1", "Meine Filme", false)]);
    vm.send(HomeIntent::Load);
    until(vm, "ready", common::ready);
    let rails = vm.rails();
    // The fixed rows first, then the chosen library, titled with its stored name; it reuses the genre kind.
    assert_eq!(
        rails
            .rails
            .iter()
            .map(|r| r.title.as_str())
            .collect::<Vec<_>>(),
        [
            "Weiterschauen",
            "Nächste Folge",
            "Zuletzt hinzugefügt",
            "Meine Filme"
        ]
    );
    let lib = rails.rails.last().unwrap();
    assert!(lib.is_library() && !lib.is_genre());
    assert_eq!(
        (lib.id.as_str(), lib.kind),
        ("library:lib-1", RailKind::Genre)
    );
    assert!(!lib.ids.is_empty());
    // The library was asked for by its id.
    assert!(
        rig.net
            .seen
            .lock()
            .unwrap()
            .iter()
            .any(|r| r.url.as_str().contains("ParentId=lib-1"))
    );
}

#[test]
fn one_stored_order_places_fixed_and_library_rows_together() {
    use swiftly_library::start_libraries::StartLibrary;
    let rig = common::rig(
        Net::new(true),
        Arc::new(MemoryStore::new()),
        "de",
        Some("TOKEN-A"),
    );
    let vm = &rig.vm;
    vm.set_start_libraries(vec![StartLibrary::new("lib-1", "Meine Filme", false)]);
    vm.set_row_order(vec![
        "library:lib-1".into(),
        "neuzugaenge".into(),
        "library:unknown".into(),
    ]);
    vm.send(HomeIntent::Load);
    until(vm, "ready", common::ready);
    let titles = |vm: &swiftly_vm::HomeVm<_>| {
        vm.rails()
            .rails
            .iter()
            .map(|r| r.title.clone())
            .collect::<Vec<_>>()
    };
    // Library first, then the new-arrivals row, the rest of the fixed rows after (healed list).
    assert_eq!(
        titles(vm),
        [
            "Meine Filme",
            "Zuletzt hinzugefügt",
            "Weiterschauen",
            "Nächste Folge"
        ]
    );
    // Moving it back at runtime republishes at once; an empty order is the old default.
    vm.set_row_order(Vec::new());
    assert_eq!(
        titles(vm),
        [
            "Weiterschauen",
            "Nächste Folge",
            "Zuletzt hinzugefügt",
            "Meine Filme"
        ]
    );
}

#[test]
fn a_failed_load_names_its_kind_and_unreachable_stays_offline() {
    let cases = [
        (500, "{}", Load::Failed(FailKind::Server)),
        (401, "{}", Load::Failed(FailKind::Denied)),
        (200, "not json", Load::Failed(FailKind::Unreadable)),
    ];
    for (status, body, expected) in cases {
        let net = Net::new(true);
        *net.force.lock().unwrap() = Some((status, body.to_owned()));
        let rig = rig(net, Arc::new(MemoryStore::new()), "de", Some("TOKEN-A"));
        rig.vm.send(HomeIntent::Load);
        until(&rig.vm, "failed", |vm| {
            vm.status().status == Status::Offline
        });
        assert_eq!(rig.vm.load(), expected, "status {status}");
    }
    let net = Net::new(true);
    net.offline.store(true, Ordering::SeqCst);
    let rig = rig(net, Arc::new(MemoryStore::new()), "de", Some("TOKEN-A"));
    rig.vm.send(HomeIntent::Load);
    until(&rig.vm, "offline", |vm| {
        vm.status().status == Status::Offline
    });
    assert_eq!(rig.vm.load(), Load::Offline);
}

/// Line 7 / Continue watching: a title watched to its end leaves the rail when the page is pulled
/// to refresh, and an account that has nothing started shows no "Weiterschauen" rail at all.
#[test]
fn continue_watching_drops_a_finished_title_on_refresh() {
    let net = Net::new(true);
    let rig = rig(
        net.clone(),
        Arc::new(MemoryStore::new()),
        "de",
        Some("TOKEN-A"),
    );
    let vm = &rig.vm;
    vm.send(HomeIntent::Load);
    until(vm, "ready", common::ready);
    assert_eq!(vm.rails().rails[0].ids, ["r1", "e1"]);
    net.r1_finished.store(true, Ordering::SeqCst);
    let before = net.requests();
    vm.send(HomeIntent::Load);
    until(vm, "reloaded", |_| net.requests() > before);
    until(vm, "ready again", common::ready);
    let rails = vm.rails();
    let resume = rails
        .rails
        .iter()
        .find(|r| r.kind == RailKind::ContinueWatching)
        .unwrap();
    assert_eq!(resume.ids, ["e1"], "the finished film is still on the rail");
    assert_eq!(resume.tiles.len(), 1);
}
