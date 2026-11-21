//! The old Android facade opens a title page complete in frame 1: `title_seed` answers from the stored list entry (the
//! same copies the view models seed from), in the shape of `title`, without any network.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;

use common::account;
use common::script::{Script, host};
use swiftly_cache::{CacheConfig, EntityCache};
use swiftly_model::Item;
use swiftly_vm::{Host, LegacyDetail, ViewCache};

fn with(cache: &ViewCache) -> Host {
    Host {
        cache: Some(cache.clone()),
        ..host()
    }
}

#[test]
fn a_title_seed_has_the_stored_text_and_chips_and_no_plan() {
    let cache = ViewCache::new(EntityCache::in_memory(CacheConfig::default()).unwrap());
    let scope = ViewCache::scope(&account("TOKEN-A"));
    let listed: Item = serde_json::from_value(serde_json::json!({
        "Id": "m1", "Name": "Die Brücke", "Type": "Movie", "ProductionYear": 1959,
        "Overview": "Ein Dorf, eine Brücke, sieben Jungen.", "Genres": ["Drama", "Krieg"],
        "CommunityRating": 8.1, "OfficialRating": "FSK 12", "RunTimeTicks": 6_000_000_000_i64,
        "ImageTags": {"Primary": "p1"}, "BackdropImageTags": ["b1"]
    }))
    .unwrap();
    let ticket = cache.ticket(&scope);
    cache.note_tiles(&ticket, &[listed]);

    let net = Script::new(|_| Some("{}".into()));
    net.offline.store(true, std::sync::atomic::Ordering::SeqCst);
    let detail = LegacyDetail::new(&Arc::clone(&net), &with(&cache), &account("TOKEN-A")).unwrap();

    let seed: serde_json::Value = serde_json::from_str(&detail.title_seed("m1")).unwrap();
    assert_eq!(seed["name"], "Die Brücke");
    assert_eq!(
        seed["beschreibung"],
        "Ein Dorf, eine Brücke, sieben Jungen."
    );
    assert_eq!(seed["bewertung"], 8.1);
    assert_eq!(seed["freigabe"], "FSK 12");
    assert_eq!(seed["planDa"], false, "a seed has no playback plan");
    assert_eq!(seed["vorab"], true);
    assert!(
        seed["kopfbild"]
            .as_str()
            .is_some_and(|a| a.contains("/Items/m1/Images/"))
    );
    assert!(
        seed["nebenzeile"]
            .as_str()
            .is_some_and(|l| l.contains("Drama")),
        "the genre line is in frame 1: {seed}"
    );

    assert_eq!(detail.title_seed("unknown"), "", "nothing stored: no seed");
    assert_eq!(detail.series_seed("unknown"), "");
    assert_eq!(detail.episodes_seed("unknown", "s1"), "");
}

#[test]
fn a_seed_from_a_poster_only_tile_names_no_head_picture_and_the_slot_shows_the_runtime() {
    let cache = ViewCache::new(EntityCache::in_memory(CacheConfig::default()).unwrap());
    let scope = ViewCache::scope(&account("TOKEN-A"));
    let listed: Item = serde_json::from_value(serde_json::json!({
        "Id": "m2", "Name": "Sommerregen", "Type": "Movie", "RunTimeTicks": 6_000_000_000_i64,
        "ImageTags": {"Primary": "p1"}
    }))
    .unwrap();
    let series: Item = serde_json::from_value(serde_json::json!({
        "Id": "s1", "Name": "Hafenlichter", "Type": "Series", "ChildCount": 1,
        "ImageTags": {"Primary": "p2"}
    }))
    .unwrap();
    let ticket = cache.ticket(&scope);
    cache.note_tiles(&ticket, &[listed, series]);

    let net = Script::new(|_| Some("{}".into()));
    net.offline.store(true, std::sync::atomic::Ordering::SeqCst);
    let detail = LegacyDetail::new(&Arc::clone(&net), &with(&cache), &account("TOKEN-A")).unwrap();

    let seed: serde_json::Value = serde_json::from_str(&detail.title_seed("m2")).unwrap();
    assert!(
        seed.get("kopfbild").is_none_or(serde_json::Value::is_null),
        "the poster must not stand in the landscape head: {seed}"
    );
    assert!(
        seed["restzeit"].is_string(),
        "a never-started title shows its runtime in the slot under Play: {seed}"
    );

    let seed: serde_json::Value = serde_json::from_str(&detail.series_seed("s1")).unwrap();
    assert_eq!(
        seed["staffelpfeil"], true,
        "the season chevron is always shown"
    );
    assert!(
        seed.get("kopfbild").is_none_or(serde_json::Value::is_null),
        "{seed}"
    );
}

#[test]
fn a_play_seed_has_the_player_top_bar_facts_of_a_stored_title_and_nothing_without_a_copy() {
    let cache = ViewCache::new(EntityCache::in_memory(CacheConfig::default()).unwrap());
    let scope = ViewCache::scope(&account("TOKEN-A"));
    let movie: Item = serde_json::from_value(serde_json::json!({
        "Id": "m1", "Name": "Die Brücke", "Type": "Movie", "ProductionYear": 1959,
        "RunTimeTicks": 6_000_000_000_i64, "ImageTags": {"Primary": "p1"}
    }))
    .unwrap();
    let episode: Item = serde_json::from_value(serde_json::json!({
        "Id": "e3", "Name": "Der Hafen", "Type": "Episode", "SeriesName": "Hafenlichter", "SeriesId": "s1",
        "SeasonId": "s1-2", "ParentIndexNumber": 2, "IndexNumber": 3, "RunTimeTicks": 2_700_000_000_i64
    }))
    .unwrap();
    let ticket = cache.ticket(&scope);
    cache.note_tiles(&ticket, &[movie, episode]);

    let net = Script::new(|_| Some("{}".into()));
    net.offline.store(true, std::sync::atomic::Ordering::SeqCst);
    let detail = LegacyDetail::new(&Arc::clone(&net), &with(&cache), &account("TOKEN-A")).unwrap();

    let film: serde_json::Value = serde_json::from_str(&detail.play_seed("m1")).unwrap();
    assert_eq!(film["titel"], "Die Brücke");
    assert_eq!(film["episode"], false, "a film has no episode slot: {film}");
    assert_eq!(film["kopfzeile"], "Die Brücke");
    assert!(
        film["nebenzeile"]
            .as_str()
            .is_some_and(|l| l.contains("1959")),
        "the film's meta line is year and runtime: {film}"
    );
    assert!(film.get("serieId").is_none());

    let folge: serde_json::Value = serde_json::from_str(&detail.play_seed("e3")).unwrap();
    assert_eq!(folge["episode"], true);
    assert_eq!(
        folge["kopfzeile"], "Hafenlichter",
        "the bar's title is the series"
    );
    assert_eq!(folge["serieId"], "s1");
    assert_eq!(folge["staffelId"], "s1-2");
    assert_eq!(folge["staffelNr"], 2);
    assert_eq!(folge["folgeNr"], 3);
    assert_eq!(folge["itemId"], "e3");

    assert_eq!(
        detail.play_seed("unknown"),
        "",
        "nothing stored: no seed, the page's `kopf` is the source"
    );
}
