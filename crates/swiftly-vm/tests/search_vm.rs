//! The search view model against a scripted server: threshold, debounce, groups, offline versus
//! nothing found, extras that fail quietly, recent terms per account, account switch.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;

use common::account;
use common::script::{GateSleeper, Script, host, list, wait_for};
use swiftly_library::{KeyValue, MemoryKeyValue};
use swiftly_vm::{FailKind, Load, SearchIntent, SearchKind, SearchStatus, SearchVm, part};

fn server() -> Arc<Script> {
    Script::new(|r| {
        let path = r.url.path();
        if !path.ends_with("/Items") {
            return Some("{}".into());
        }
        Some(list(
            &[
                serde_json::json!({"Id": "s1", "Name": "Dark Matter", "Type": "Series"}),
                serde_json::json!({"Id": "m2", "Name": "Dark 10", "Type": "Movie"}),
                serde_json::json!({"Id": "m1", "Name": "Dark 2", "Type": "Movie"}),
            ],
            3,
        ))
    })
}

fn vm(net: &Arc<Script>, kv: &Arc<MemoryKeyValue>, gate: &Arc<common::Gate>) -> SearchVm<Script> {
    SearchVm::new(
        net.clone(),
        host(),
        Arc::new(GateSleeper(gate.clone())),
        kv.clone(),
        Some(account("TOKEN-A")),
    )
    .unwrap()
}

fn open_gate() -> Arc<common::Gate> {
    let gate = Arc::new(common::Gate::default());
    gate.open();
    gate
}

fn query(vm: &SearchVm<Script>, text: &str) {
    vm.send(SearchIntent::Query { text: text.into() });
}

#[test]
fn a_short_term_does_nothing() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), &open_gate());
    assert_eq!(vm.status().status, SearchStatus::Idle);
    query(&vm, "a");
    query(&vm, "  b ");
    assert_eq!(vm.status().status, SearchStatus::Idle);
    assert_eq!(net.urls().len(), 0);
}

#[test]
fn groups_are_split_ordered_and_display_ready() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), &open_gate());
    let seen = vm.version();
    query(&vm, "  dark ");
    wait_for("done", || vm.status().status == SearchStatus::Done);
    let results = vm.results();
    assert_eq!(results.query, "dark");
    let kinds: Vec<_> = results.groups.iter().map(|g| g.kind).collect();
    assert_eq!(kinds, [SearchKind::Series, SearchKind::Movies]);
    // Natural order: "Dark 2" before "Dark 10".
    let movies: Vec<_> = results.groups[1]
        .tiles
        .iter()
        .map(|t| t.title.as_str())
        .collect();
    assert_eq!(movies, ["Dark 2", "Dark 10"]);
    assert_eq!(results.groups[0].tiles[0].title, "Dark Matter");
    // Exactly the Swift request: movies and series, 40 hits, one call.
    let urls = net.urls();
    assert_eq!(urls.len(), 1, "{urls:?}");
    for part in [
        "searchTerm=dark",
        "IncludeItemTypes=Movie,Series",
        "Limit=40",
        "Recursive=true",
    ] {
        assert!(urls[0].contains(part), "{}", urls[0]);
    }
    let change = futures_executor::block_on(vm.changed(seen));
    assert_eq!(change.parts, part::RESULTS | part::STATUS);
    assert!(net.urls().iter().all(|u| !u.contains("TOKEN-A")));
}

#[test]
fn typing_waits_for_the_debounce_and_only_the_last_term_is_asked() {
    let net = server();
    let gate = Arc::new(common::Gate::default());
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), &gate);
    query(&vm, "da");
    query(&vm, "dar");
    query(&vm, "dark");
    assert_eq!(vm.status().status, SearchStatus::Searching);
    assert_eq!(net.urls().len(), 0, "nothing goes out during the rest");
    gate.open();
    wait_for("done", || vm.status().status == SearchStatus::Done);
    std::thread::sleep(std::time::Duration::from_millis(50));
    let searches: Vec<_> = net
        .urls()
        .into_iter()
        .filter(|u| u.contains("searchTerm"))
        .collect();
    assert_eq!(
        searches.len(),
        1,
        "one request for the last term: {searches:?}"
    );
    assert!(searches.iter().all(|u| u.contains("searchTerm=dark")));
}

#[test]
fn clearing_the_field_cancels_a_search_in_flight() {
    let net = server();
    let gate = Arc::new(common::Gate::default());
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), &gate);
    query(&vm, "dark");
    query(&vm, "");
    gate.open();
    std::thread::sleep(std::time::Duration::from_millis(80));
    assert_eq!(net.urls().len(), 0);
    assert_eq!(vm.status().status, SearchStatus::Idle);
    assert!(vm.results().groups.is_empty());
}

#[test]
fn a_picked_recent_term_searches_without_waiting() {
    let net = server();
    let gate = Arc::new(common::Gate::default());
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), &gate);
    vm.send(SearchIntent::Pick {
        term: "dark".into(),
    });
    wait_for("done", || vm.status().status == SearchStatus::Done);
}

#[test]
fn offline_is_not_nothing_found() {
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), &open_gate());
    net.offline.store(true, Ordering::SeqCst);
    query(&vm, "dark");
    wait_for("offline", || vm.status().status == SearchStatus::Offline);

    // Nothing found.
    let empty = Script::new(|_| Some(list(&[], 0)));
    let quiet = SearchVm::new(
        empty,
        host(),
        Arc::new(GateSleeper(open_gate())),
        Arc::new(MemoryKeyValue::new()),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    query(&quiet, "zzzz");
    wait_for("empty", || quiet.status().status == SearchStatus::Empty);
}

#[test]
fn recent_terms_are_kept_per_account_newest_first() {
    let net = server();
    let kv = Arc::new(MemoryKeyValue::new());
    let vm = vm(&net, &kv, &open_gate());
    assert!(vm.recents().is_empty());
    for term in ["Dune", "Severance", "x", "dune"] {
        query(&vm, term);
        vm.send(SearchIntent::Remember);
    }
    // "x" is too short; "dune" replaces "Dune" and moves to the front.
    assert_eq!(*vm.recents(), ["dune", "Severance"]);
    assert!(
        kv.get(&format!("letzteSuchen.{}", account("TOKEN-A").key()))
            .is_some()
    );

    vm.send(SearchIntent::AccountSwitched {
        account: Some(account("TOKEN-B")),
    });
    assert!(vm.recents().is_empty());
    assert_eq!(vm.status().status, SearchStatus::Idle);
    vm.send(SearchIntent::AccountSwitched {
        account: Some(account("TOKEN-A")),
    });
    assert_eq!(*vm.recents(), ["dune", "Severance"]);
    vm.send(SearchIntent::ClearRecents);
    assert!(vm.recents().is_empty());
    vm.send(SearchIntent::AccountSwitched { account: None });
    assert_eq!(vm.status().status, SearchStatus::SignedOut);
}

#[test]
fn an_account_switch_drops_a_search_in_flight() {
    let net = server();
    let gate = Arc::new(common::Gate::default());
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), &gate);
    query(&vm, "dark");
    vm.send(SearchIntent::AccountSwitched {
        account: Some(account("TOKEN-B")),
    });
    gate.open();
    std::thread::sleep(std::time::Duration::from_millis(80));
    assert_eq!(net.urls().len(), 0);
    assert!(vm.results().groups.is_empty());
}

#[test]
fn a_failed_search_names_its_kind_and_unreachable_stays_offline() {
    let cases = [
        (500, "{}", Load::Failed(FailKind::Server)),
        (401, "{}", Load::Failed(FailKind::Denied)),
        (200, "not json", Load::Failed(FailKind::Unreadable)),
    ];
    for (status, body, expected) in cases {
        let net = server();
        let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), &open_gate());
        *net.force.lock().unwrap() = Some((status, body.to_owned()));
        query(&vm, "dark");
        wait_for("failed", || vm.status().status == SearchStatus::Offline);
        assert_eq!(vm.load(), expected, "status {status}");
    }
    let net = server();
    let vm = vm(&net, &Arc::new(MemoryKeyValue::new()), &open_gate());
    net.offline.store(true, Ordering::SeqCst);
    query(&vm, "dark");
    wait_for("offline", || vm.status().status == SearchStatus::Offline);
    assert_eq!(vm.load(), Load::Offline);
}

/// A debounce that panics (a timer with no runtime behind it did exactly that on the desktop).
struct PanickingSleeper;

impl swiftly_vm::Sleeper for PanickingSleeper {
    fn sleep(
        &self,
        _seconds: f64,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        panic!("there is no reactor running");
    }
}

#[test]
fn a_panic_in_the_search_task_ends_in_a_failed_state_not_in_searching_forever() {
    let net = server();
    let vm = SearchVm::new(
        net.clone(),
        host(),
        Arc::new(PanickingSleeper),
        Arc::new(MemoryKeyValue::new()),
        Some(account("TOKEN-A")),
    )
    .unwrap();
    query(&vm, "dark");
    wait_for("failed", || vm.status().status == SearchStatus::Offline);
    assert_eq!(vm.load(), Load::Failed(FailKind::Server));
    assert!(vm.results().groups.is_empty());
}
