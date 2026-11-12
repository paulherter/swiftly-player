//! The detail view model off the happy path: signed out, failing calls (flag, similar, trailer, reset,
//! metadata), trailer fall-through to the web, menu picks, account switch with late answers, the stored
//! copy and cache events. Complements `detail_vm.rs`.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use common::account;
use common::script::{Script, host, list, wait_for};
use swiftly_cache::{CacheConfig, EntityCache};
use swiftly_model::Item;
use swiftly_vm::{
    AccountRef, DetailEffect, DetailIntent, DetailOptions, DetailVm, Host, MenuKind, PlayAction,
    ViewCache,
};

fn entry_json(extra: serde_json::Value) -> Item {
    let mut v = serde_json::json!({
        "Id": "f1", "Name": "Film", "Type": "Movie", "ProductionYear": 2019,
        "UserData": {"Played": false, "IsFavorite": false}
    });
    for (k, val) in extra.as_object().cloned().unwrap_or_default() {
        v[k] = val;
    }
    serde_json::from_value(v).unwrap()
}

fn entry() -> Item {
    entry_json(serde_json::json!({}))
}

fn path_count(net: &Script, suffix: &str) -> usize {
    net.seen
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.url.path().ends_with(suffix))
        .count()
}

/// A healthy server: the title, a plan, two similar titles. `similar_up` switches the similar list off.
fn server(similar_up: Arc<AtomicBool>) -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path();
        if p.ends_with("/Items/f1") {
            return Some(
                serde_json::json!({"Id": "f1", "Name": "Film", "Type": "Movie", "ProductionYear": 2019,
                "Overview": "Text", "Genres": ["Drama"], "MediaSources": [{"Id": "s0", "Name": "V0"}],
                "UserData": {"Played": false, "IsFavorite": false}})
                .to_string(),
            );
        }
        if p.ends_with("/Items/f1/PlaybackInfo") {
            return Some(
                serde_json::json!({"PlaySessionId": "ps", "MediaSources": [{"Id": "s0",
                "Container": "mkv", "SupportsDirectPlay": true, "MediaStreams": []}]})
                .to_string(),
            );
        }
        if p.ends_with("/Items/f1/Similar") {
            if !similar_up.load(Ordering::SeqCst) {
                return None;
            }
            let o = serde_json::json!({"Id": "o1", "Name": "Anderer", "Type": "Movie"});
            return Some(list(&[o], 1));
        }
        if p.ends_with("/SpecialFeatures") || p.ends_with("/LocalTrailers") {
            return Some("[]".into());
        }
        Some("{}".into())
    })
}

fn up() -> Arc<AtomicBool> {
    Arc::new(AtomicBool::new(true))
}

fn vm_for(
    net: &Arc<Script>,
    item: Item,
    host: Host,
    account_: Option<AccountRef>,
) -> DetailVm<Script> {
    DetailVm::new(net.clone(), host, item, account_).unwrap()
}

fn signed_in(net: &Arc<Script>) -> DetailVm<Script> {
    vm_for(net, entry(), host(), Some(account("TOKEN-A")))
}

#[test]
fn signed_out_every_server_action_says_so_or_stays_silent() {
    let net = server(up());
    let vm = vm_for(&net, entry(), host(), None);
    vm.send(DetailIntent::Load);
    vm.send(DetailIntent::Refresh);
    vm.send(DetailIntent::RetrySimilar);
    assert!(net.urls().is_empty());
    for kind in [MenuKind::ResetProgress, MenuKind::RefreshMetadata] {
        vm.send(DetailIntent::DismissMessage);
        assert!(vm.actions().message.is_none());
        vm.send(DetailIntent::Menu(kind));
        assert_eq!(vm.actions().message.as_deref(), Some("Nicht angemeldet."));
    }
    vm.send(DetailIntent::DismissMessage);
    vm.send(DetailIntent::Trailer);
    assert_eq!(vm.actions().message.as_deref(), Some("Nicht angemeldet."));
    assert!(vm.take_effects().is_empty());
    assert!(net.urls().is_empty(), "nothing was sent: {:?}", net.urls());
}

#[test]
fn a_failed_watched_flag_goes_back_with_the_reason_and_a_new_try_clears_it() {
    let fail = Arc::new(AtomicBool::new(true));
    let f = fail.clone();
    let net = Script::new(move |r| {
        if r.url.path().contains("UserPlayedItems") && f.load(Ordering::SeqCst) {
            None
        } else {
            Some("{}".into())
        }
    });
    let vm = signed_in(&net);
    vm.send(DetailIntent::SetWatched { on: true });
    assert!(vm.actions().watched, "at once");
    wait_for("revert", || vm.actions().toggle_error.is_some());
    assert!(!vm.actions().watched, "put back");
    fail.store(false, Ordering::SeqCst);
    vm.send(DetailIntent::SetWatched { on: true });
    assert!(
        vm.actions().toggle_error.is_none(),
        "the old reason is cleared before the new try"
    );
    wait_for("second call", || net.count("UserPlayedItems/f1") == 2);
    std::thread::sleep(std::time::Duration::from_millis(30));
    assert!(vm.actions().watched && vm.actions().toggle_error.is_none());
}

#[test]
fn retry_similar_replaces_a_failed_row_and_a_new_failure_is_shown_again() {
    let similar = up();
    similar.store(false, Ordering::SeqCst);
    let net = server(similar.clone());
    let vm = signed_in(&net);
    vm.send(DetailIntent::Load);
    wait_for("bottom", || vm.bottom().ready);
    assert!(vm.bottom().similar_failed);
    similar.store(true, Ordering::SeqCst);
    vm.send(DetailIntent::RetrySimilar);
    wait_for("recovered", || {
        !vm.bottom().similar_failed && vm.bottom().similar.len() == 1
    });
    assert_eq!(vm.bottom().similar[0].id, "o1");
    // A failure after a success keeps the success visible (only the flag is set).
    similar.store(false, Ordering::SeqCst);
    vm.send(DetailIntent::RetrySimilar);
    wait_for("failed again", || vm.bottom().similar_failed);
    assert_eq!(vm.bottom().similar.len(), 1);
}

fn trailer_item() -> Item {
    entry_json(serde_json::json!({"RemoteTrailers": [{"Url": "https://example.com/trailer"}]}))
}

fn trailer_server(local: serde_json::Value, plan_ok: Option<bool>) -> Arc<Script> {
    Script::new(move |r| {
        let p = r.url.path();
        if p.ends_with("/Items/f1/LocalTrailers") {
            return Some(local.to_string());
        }
        if p.ends_with("/PlaybackInfo") {
            return match plan_ok {
                None => None,
                Some(false) => Some(serde_json::json!({"MediaSources": []}).to_string()),
                Some(true) => Some(
                    serde_json::json!({"PlaySessionId": "p", "MediaSources": [{"Id": "x",
                    "SupportsDirectPlay": true}]})
                    .to_string(),
                ),
            };
        }
        Some("{}".into())
    })
}

fn web_enabled() -> DetailIntent {
    DetailIntent::Options(Box::new(DetailOptions {
        can_open_web: true,
        ..DetailOptions::default()
    }))
}

#[test]
fn a_trailer_that_cannot_be_planned_falls_through_to_the_linked_page() {
    let local = serde_json::json!([{"Id": "t1", "Name": "T", "Type": "Trailer"}]);
    let net = trailer_server(local, None);
    let vm = vm_for(&net, trailer_item(), host(), Some(account("TOKEN-A")));
    vm.send(web_enabled());
    vm.send(DetailIntent::Trailer);
    wait_for("effect", || vm.actions().effect_seq > 0);
    match vm.take_effects().as_slice() {
        [DetailEffect::OpenWeb(url)] => assert_eq!(url.as_str(), "https://example.com/trailer"),
        other => panic!("{other:?}"),
    }
    assert_eq!(path_count(&net, "/Items/t1/PlaybackInfo"), 1);
    assert!(
        vm.actions().message.is_none(),
        "the failed plan is not mentioned when the web page opens"
    );
}

#[test]
fn a_last_trailer_that_fails_says_why_and_a_planless_one_stays_silent() {
    let local = serde_json::json!([{"Id": "t1", "Name": "T", "Type": "Trailer"}]);
    // Web is not allowed: the file is the last candidate and its failure is reported.
    let net = trailer_server(local.clone(), None);
    let vm = vm_for(&net, trailer_item(), host(), Some(account("TOKEN-A")));
    vm.send(DetailIntent::Trailer);
    wait_for("reason", || vm.actions().message.is_some());
    assert_ne!(
        vm.actions().message.as_deref(),
        Some("Für diesen Titel liegt kein Trailer vor.")
    );
    assert!(vm.take_effects().is_empty());

    // A server that names no source for the trailer is "nothing to play", not an error text.
    let net = trailer_server(local, Some(false));
    let vm = vm_for(&net, entry(), host(), Some(account("TOKEN-A")));
    vm.send(DetailIntent::Trailer);
    wait_for("asked", || path_count(&net, "/Items/t1/PlaybackInfo") == 1);
    std::thread::sleep(std::time::Duration::from_millis(50));
    assert!(vm.actions().message.is_none());
    assert!(vm.take_effects().is_empty());
}

#[test]
fn a_linked_trailer_alone_opens_the_web_and_without_permission_says_there_is_none() {
    let net = trailer_server(serde_json::json!([]), Some(true));
    let vm = vm_for(&net, trailer_item(), host(), Some(account("TOKEN-A")));
    vm.send(DetailIntent::Trailer);
    wait_for("message", || vm.actions().message.is_some());
    assert_eq!(
        vm.actions().message.as_deref(),
        Some("Für diesen Titel liegt kein Trailer vor.")
    );
    vm.send(web_enabled());
    vm.send(DetailIntent::Trailer);
    wait_for("effect", || vm.actions().effect_seq > 0);
    assert!(matches!(
        vm.take_effects().as_slice(),
        [DetailEffect::OpenWeb(_)]
    ));
}

#[test]
fn a_trailer_with_a_plan_plays_it() {
    let local = serde_json::json!([{"Id": "t1", "Name": "T", "Type": "Trailer"}]);
    let net = trailer_server(local, Some(true));
    let vm = vm_for(&net, entry(), host(), Some(account("TOKEN-A")));
    vm.send(DetailIntent::Trailer);
    wait_for("effect", || vm.actions().effect_seq > 0);
    assert!(
        matches!(vm.take_effects().as_slice(), [DetailEffect::PlayTrailer { item, .. }] if item.id == "t1")
    );
}

#[test]
fn menu_picks_play_toggle_or_pass_on_to_the_host() {
    let net = server(up());
    let vm = signed_in(&net);
    vm.send(DetailIntent::Load);
    wait_for("title", || vm.actions().play.enabled);
    // Play and "from start" queue the very action the buttons would give.
    vm.send(DetailIntent::Menu(MenuKind::Play));
    vm.send(DetailIntent::Menu(MenuKind::PlayFromStart));
    let expected = vm.play(None);
    assert!(matches!(expected, PlayAction::Start { .. }));
    assert_eq!(
        vm.take_effects(),
        [
            DetailEffect::Play(expected.clone()),
            DetailEffect::Play(vm.play_from_start(None))
        ]
    );
    // Watched marks go to the server and flip the toggle at once.
    vm.send(DetailIntent::Menu(MenuKind::MarkWatched));
    assert!(vm.actions().watched);
    wait_for("mark", || net.count("UserPlayedItems/f1") == 1);
    vm.send(DetailIntent::Menu(MenuKind::MarkUnwatched));
    assert!(!vm.actions().watched);
    wait_for("unmark", || net.count("UserPlayedItems/f1") == 2);
    let methods: Vec<String> = net
        .seen
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.url.path().contains("UserPlayedItems/f1"))
        .map(|r| format!("{:?}", r.method))
        .collect();
    assert_eq!(methods.len(), 2);
    assert_ne!(
        methods[0], methods[1],
        "mark and unmark use different verbs"
    );
    // Both writes reached the server: the host hears twice that the watched state changed.
    let heard = std::cell::RefCell::new(Vec::new());
    wait_for("state changed", || {
        heard.borrow_mut().extend(vm.take_effects());
        heard.borrow().len() == 2
    });
    assert_eq!(
        *heard.borrow(),
        [DetailEffect::StateChanged, DetailEffect::StateChanged]
    );
    // Everything else is the host's business.
    vm.send(DetailIntent::Menu(MenuKind::Together));
    vm.send(DetailIntent::Menu(MenuKind::PlayOn {
        id: "d1".into(),
        name: "TV".into(),
    }));
    assert_eq!(
        vm.take_effects(),
        [
            DetailEffect::Menu(MenuKind::Together),
            DetailEffect::Menu(MenuKind::PlayOn {
                id: "d1".into(),
                name: "TV".into()
            })
        ]
    );
}

#[test]
fn play_from_start_keeps_every_kind_of_action_but_drops_the_resume_point() {
    let net = server(up());
    let item = entry_json(
        serde_json::json!({"MediaSources": [{"Id": "a", "Name": "A"}, {"Id": "b", "Name": "B"}],
        "UserData": {"PlaybackPositionTicks": 18_000_000_000_i64}}),
    );
    let vm = vm_for(&net, item, host(), Some(account("TOKEN-A")));
    // The list entry already knows two versions and the position: "ask" with the resume point.
    match vm.play(None) {
        PlayAction::Choose {
            since, versions, ..
        } => {
            assert!((since - 1800.0).abs() < 1e-9);
            assert_eq!(versions.len(), 2);
        }
        other => panic!("{other:?}"),
    }
    match vm.play_from_start(None) {
        PlayAction::Choose {
            since,
            versions,
            item_id,
        } => {
            assert_eq!((since, versions.len(), item_id.as_str()), (0.0, 2, "f1"));
        }
        other => panic!("{other:?}"),
    }
    // A chosen version starts at 0 and keeps the choice.
    match vm.play_from_start(Some("b")) {
        PlayAction::Start {
            since, source_id, ..
        } => assert_eq!((since, source_id.as_deref()), (0.0, Some("b"))),
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_failing_reset_or_refresh_says_what_the_server_said_and_does_not_reload() {
    let net = Script::new(|r| {
        let p = r.url.path();
        if p.contains("UserPlayedItems") || p.contains("/Refresh") {
            None
        } else {
            Some("{}".into())
        }
    });
    let vm = signed_in(&net);
    vm.send(DetailIntent::Menu(MenuKind::ResetProgress));
    wait_for("reset reason", || vm.actions().message.is_some());
    let reset = vm.actions().message.clone().unwrap();
    assert_ne!(reset, "Der Fortschritt ist zurückgesetzt.");
    assert!(
        vm.take_effects().is_empty(),
        "no StateChanged after a failure"
    );
    assert_eq!(
        path_count(&net, "/Items/f1"),
        0,
        "no reload after a failure"
    );
    vm.send(DetailIntent::DismissMessage);
    vm.send(DetailIntent::Menu(MenuKind::RefreshMetadata));
    wait_for("refresh reason", || vm.actions().message.is_some());
    assert_ne!(
        vm.actions().message.as_deref(),
        Some("Der Server liest die Metadaten neu ein.")
    );
}

#[test]
fn a_successful_reset_tells_the_host_and_reloads_the_title() {
    let net = server(up());
    let vm = signed_in(&net);
    vm.send(DetailIntent::Menu(MenuKind::ResetProgress));
    wait_for("reload", || path_count(&net, "/Items/f1") == 1);
    assert_eq!(
        vm.actions().message.as_deref(),
        Some("Der Fortschritt ist zurückgesetzt.")
    );
    assert_eq!(vm.take_effects(), [DetailEffect::StateChanged]);
}

#[test]
fn a_local_plan_none_keeps_the_servers_plan() {
    let net = server(up());
    let vm = signed_in(&net);
    vm.send(DetailIntent::Load);
    wait_for("plan", || vm.actions().proof.visible && vm.plan().is_some());
    let plan = vm.plan().unwrap();
    vm.send(DetailIntent::LocalPlan(None));
    assert_eq!(vm.plan().as_deref(), Some(&*plan));
}

fn headers_of(net: &Script, path_part: &str) -> Vec<String> {
    net.seen
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.url.path().contains(path_part))
        .flat_map(|r| {
            r.headers
                .iter()
                .map(|(_, v)| v.clone())
                .chain(std::iter::once(r.url.to_string()))
        })
        .collect()
}

#[test]
fn switching_the_account_starts_over_with_the_new_token() {
    let net = server(up());
    let vm = signed_in(&net);
    vm.send(DetailIntent::Load);
    wait_for("page", || vm.bottom().ready && vm.actions().play.enabled);
    assert!(
        headers_of(&net, "/Items/f1")
            .iter()
            .any(|h| h.contains("TOKEN-A"))
    );
    // Hold the new account's answers: otherwise a fast server (or a loaded machine) finishes the reload
    // before the assertions below look at the cleared state.
    net.gate.close();
    vm.send(DetailIntent::SetWatchlist { on: true });
    vm.send(DetailIntent::AccountSwitched {
        account: Some(account("TOKEN-B")),
    });
    // Gone at once: the toggles are the list entry's, the bottom is not ready, the play button is gray.
    assert!(!vm.actions().favorite);
    assert!(!vm.bottom().ready);
    assert!(!vm.actions().play.enabled);
    assert_eq!(vm.play(None), PlayAction::Wait);
    net.gate.open();
    wait_for("second load", || {
        vm.bottom().ready && vm.actions().play.enabled
    });
    assert!(
        headers_of(&net, "/Items/f1")
            .iter()
            .any(|h| h.contains("TOKEN-B"))
    );
}

#[test]
fn switching_to_signed_out_ignores_late_answers_of_the_old_account() {
    let net = server(up());
    net.gate.close();
    let vm = signed_in(&net);
    vm.send(DetailIntent::Load);
    wait_for("requests are out", || path_count(&net, "/Items/f1") == 1);
    vm.send(DetailIntent::AccountSwitched { account: None });
    net.gate.open();
    std::thread::sleep(std::time::Duration::from_millis(100));
    assert!(!vm.bottom().ready);
    assert!(vm.bottom().similar.is_empty());
    assert!(vm.plan().is_none());
    assert!(!vm.actions().play.enabled);
    assert_eq!(vm.hero().overview, None);
}

fn cached_host() -> (Host, ViewCache) {
    let cache = ViewCache::new(EntityCache::in_memory(CacheConfig::default()).unwrap());
    (
        Host {
            cache: Some(cache.clone()),
            ..host()
        },
        cache,
    )
}

fn changed(ids: &str) -> swiftly_cache::Invalidation {
    let message = format!(
        r#"{{"MessageType":"LibraryChanged","Data":{{"ItemsAdded":[],"ItemsUpdated":[{ids}],"ItemsRemoved":[]}}}}"#
    );
    swiftly_cache::parse_ws(&message).unwrap()
}

#[test]
fn a_second_visit_paints_the_stored_title_while_the_server_is_gone() {
    let (host_a, cache) = cached_host();
    let net = server(up());
    let first = vm_for(&net, entry(), host_a, Some(account("TOKEN-A")));
    first.send(DetailIntent::Load);
    wait_for("page", || {
        first.hero().overview.as_deref() == Some("Text") && first.bottom().ready
    });

    let gone = server(up());
    gone.offline.store(true, Ordering::SeqCst);
    let second = vm_for(
        &gone,
        entry(),
        Host {
            cache: Some(cache.clone()),
            ..host()
        },
        Some(account("TOKEN-A")),
    );
    assert_eq!(second.hero().overview, None, "nothing before the load");
    second.send(DetailIntent::Load);
    wait_for("stored copy", || {
        second.hero().overview.as_deref() == Some("Text")
    });
    // The stored copy has no versions: Play is not offered from it alone... but a failed fresh load
    // lets a press resolve the title.
    wait_for("failure", || second.actions().play.enabled);
    assert!(matches!(second.play(None), PlayAction::Resolve { .. }));

    // Another account never sees the copy.
    let third = vm_for(
        &gone,
        entry(),
        Host {
            cache: Some(cache),
            ..host()
        },
        Some(account("TOKEN-OTHER")),
    );
    third.send(DetailIntent::Load);
    wait_for("asked", || gone.count("/Items/f1") >= 2);
    assert_eq!(third.hero().overview, None);
}

#[test]
fn a_cache_event_of_the_account_refreshes_once_per_burst_and_other_accounts_do_nothing() {
    let (host_a, cache) = cached_host();
    let net = server(up());
    let vm = vm_for(&net, entry(), host_a, Some(account("TOKEN-A")));
    vm.send(DetailIntent::Load);
    wait_for("page", || vm.bottom().ready && vm.actions().play.enabled);
    let scope = ViewCache::scope(&account("TOKEN-A"));
    let before = path_count(&net, "/Items/f1");

    cache
        .entity_cache()
        .apply_event(&ViewCache::scope(&account("TOKEN-B")), &changed(r#""f1""#));
    std::thread::sleep(std::time::Duration::from_millis(50));
    assert_eq!(path_count(&net, "/Items/f1"), before);

    cache
        .entity_cache()
        .apply_event(&scope, &changed(r#""f1""#));
    wait_for("refresh", || path_count(&net, "/Items/f1") == before + 1);
    // The clock stands still: a second event inside three seconds belongs to the same burst.
    cache
        .entity_cache()
        .apply_event(&scope, &changed(r#""f1""#));
    std::thread::sleep(std::time::Duration::from_millis(100));
    assert_eq!(path_count(&net, "/Items/f1"), before + 1);
    // A refresh does not load the bottom again.
    assert_eq!(path_count(&net, "/Items/f1/Similar"), 1);

    // Once the page is gone its watcher is gone: a dropped scope and later events reload nothing.
    drop(vm);
    cache.entity_cache().drop_scope(&scope);
    cache
        .entity_cache()
        .apply_event(&scope, &changed(r#""f1""#));
    assert_eq!(path_count(&net, "/Items/f1"), before + 1);
}
