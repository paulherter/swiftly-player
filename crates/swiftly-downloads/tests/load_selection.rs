//! Tests of the selection logic behind the series download sheet (no Swift test file exists for
//! `LoadSelection`; these cover the rules named in its comments).

#![allow(clippy::expect_used)]

mod common;

use std::collections::HashMap;

use common::*;
use swiftly_downloads::{
    CheckboxState, DownloadAudioChoice, DownloadQuality, FootSpace, LoadSelection,
    load_selection::SeasonRight,
};
use swiftly_model::{Item, UserItemData};

fn ep(id: &str, season: i64, number: i64, size: i64, watched: bool) -> Item {
    let mut i = episode_item(id, season, number, vec![]);
    if let Some(src) = i.media_sources.as_mut().and_then(|s| s.first_mut()) {
        src.size = Some(size);
    }
    i.run_time_ticks = Some(36_000_000_000);
    i.user_data = Some(UserItemData {
        played: Some(watched),
        ..Default::default()
    });
    i
}

fn sheet() -> LoadSelection {
    let s1 = vec![
        ep("a", 1, 1, 4_000_000_000, true),
        ep("b", 1, 2, 4_000_000_000, false),
    ];
    let s2 = vec![ep("c", 2, 1, 4_000_000_000, false)];
    let mut sel = LoadSelection::new(
        vec!["s1".into(), "s2".into()],
        HashMap::from([("s1".to_owned(), s1)]),
    );
    sel.record_season("s2", Some(s2));
    sel.finish_load();
    sel
}

fn refs(sel: &LoadSelection) -> Vec<&Item> {
    sel.all_episodes()
}

#[test]
fn toggle_selects_what_is_free_and_deselects_again() {
    let mut sel = sheet();
    sel.set_present(["a".to_owned()]);
    let all: Vec<Item> = refs(&sel).into_iter().cloned().collect();
    let list: Vec<&Item> = all.iter().collect();
    assert_eq!(sel.checkbox_state(&list, true), CheckboxState::Empty);
    sel.toggle(&list);
    // "a" is on the device and never selectable.
    let mut ids: Vec<&str> = sel.selected.iter().map(String::as_str).collect();
    ids.sort_unstable();
    assert_eq!(ids, ["b", "c"]);
    assert_eq!(sel.checkbox_state(&list, true), CheckboxState::Full);
    sel.toggle(&list[1..2]);
    assert_eq!(sel.checkbox_state(&list, true), CheckboxState::Part);
    sel.toggle(&list);
    assert_eq!(sel.checkbox_state(&list, true), CheckboxState::Full);
    sel.toggle(&list);
    assert!(sel.selected.is_empty());
}

#[test]
fn unwatched_only_drops_watched_and_present_counts() {
    let mut sel = sheet();
    sel.only_unwatched = true;
    let all: Vec<Item> = refs(&sel).into_iter().cloned().collect();
    let list: Vec<&Item> = all.iter().collect();
    sel.toggle(&list);
    assert!(!sel.selected.contains("a"));
    assert_eq!(sel.selected.len(), 2);
    // Everything visible is on the device: "present".
    sel.set_present(["b".to_owned(), "c".to_owned()]);
    sel.new_compute();
    assert!(sel.selected.is_empty());
    assert_eq!(sel.checkbox_state(&list, true), CheckboxState::Present);
    // While seasons are still being read the series is not "present".
    assert_eq!(sel.checkbox_state(&list, false), CheckboxState::Empty);
}

#[test]
fn bytes_follow_the_quality_and_levels_follow_the_best_file() {
    let mut sel = sheet();
    sel.selected = ["a".to_owned(), "b".to_owned()].into_iter().collect();
    assert_eq!(sel.bytes(), 8_000_000_000);
    // 4 GB for an hour is about 8.9 Mbit/s: every level is smaller, so all are offered.
    let offered = sel.offered(true);
    assert_eq!(offered[0], DownloadQuality::Original);
    assert_eq!(offered.len(), 4);
    assert_eq!(sel.offered(false), [DownloadQuality::Original]);
    sel.quality = DownloadQuality::Sd480;
    assert!(sel.bytes() < 8_000_000_000);
    // The server no longer allows conversion: Original applies again.
    sel.reset_quality_if_gone(false);
    assert_eq!(sel.quality, DownloadQuality::Original);
}

#[test]
fn footer_uses_the_selection_in_the_chosen_quality() {
    let mut sel = sheet();
    sel.selected = ["b".to_owned()].into_iter().collect();
    assert_eq!(
        sel.foot_space(100_000_000_000),
        FootSpace::Free(96_000_000_000)
    );
    assert!(matches!(sel.foot_space(4_500_000_000), FootSpace::Few(_)));
}

#[test]
fn audio_is_offered_when_languages_differ_and_never_a_missing_one() {
    let mut sel = sheet();
    // Give episode b two languages, c one.
    let two = vec![
        audio_stream(1, "ger", "ac3", true),
        audio_stream(2, "eng", "ac3", false),
    ];
    let mut all = vec![ep("a", 1, 1, 1, false), ep("b", 1, 2, 1, false)];
    if let Some(src) = all[1].media_sources.as_mut().and_then(|s| s.first_mut()) {
        src.media_streams = Some(two);
    }
    sel.episodes = HashMap::from([("s1".to_owned(), all)]);
    sel.selected = ["b".to_owned()].into_iter().collect();
    assert!(sel.audio_offered(&Fake));
    assert_eq!(sel.audio_options(&Fake).len(), 3);
    assert_eq!(
        sel.audio(&Fake, "en"),
        DownloadAudioChoice::Language("en".into())
    );
    // A language the selection does not hold falls back to all tracks.
    assert_eq!(sel.audio(&Fake, "fr"), DownloadAudioChoice::All);
    sel.audio_chosen = Some(DownloadAudioChoice::Language("de".into()));
    assert_eq!(
        sel.audio(&Fake, "en"),
        DownloadAudioChoice::Language("de".into())
    );
    // Selecting only a single-language episode: nothing to choose.
    sel.selected = ["a".to_owned()].into_iter().collect();
    assert!(!sel.audio_offered(&Fake));
    assert_eq!(sel.audio(&Fake, "en"), DownloadAudioChoice::All);
}

#[test]
fn seasons_are_fetched_three_at_a_time_and_failures_are_not_remembered() {
    let seasons: Vec<String> = (1..=7).map(|n| format!("s{n}")).collect();
    let mut sel = LoadSelection::new(seasons, HashMap::from([("s2".to_owned(), vec![])]));
    let batches = sel.batches();
    assert_eq!(batches.iter().map(Vec::len).collect::<Vec<_>>(), [3, 3]);
    assert!(!batches.concat().contains(&"s2".to_owned()));
    sel.record_season("s1", None);
    assert!(sel.disrupted && !sel.episodes.contains_key("s1"));
    // `Some(empty)` is a fact, `None` is not: s1 is fetched again on the next try.
    sel.begin_load();
    assert!(!sel.disrupted && sel.batches().concat().contains(&"s1".to_owned()));
}

#[test]
fn season_row_text_cases() {
    let sel = sheet();
    let a = ep("a", 1, 1, 1, false);
    let one = [a.clone()];
    let vis: Vec<&Item> = one.iter().collect();
    assert_eq!(
        sel.season_right(None, &vis, CheckboxState::Empty),
        SeasonRight::Dash
    );
    assert_eq!(
        sel.season_right(Some(&[]), &[], CheckboxState::Empty),
        SeasonRight::NoEpisodes
    );
    assert_eq!(
        sel.season_right(Some(&one), &[], CheckboxState::Empty),
        SeasonRight::AllWatched
    );
    assert_eq!(
        sel.season_right(Some(&one), &vis, CheckboxState::Present),
        SeasonRight::AllThere
    );
    assert_eq!(
        sel.season_right(Some(&one), &vis, CheckboxState::Empty),
        SeasonRight::Count(1)
    );
}
