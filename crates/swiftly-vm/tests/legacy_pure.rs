//! The pure helpers of the old Android facade (`legacy_*`): list JSON, search keys, download rules. These had no
//! coverage; the checks pin shape and the branches that matter (empty, broken input, unknown values).

#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::Value;
use swiftly_l10n::Locale;
use swiftly_vm::*;

fn de() -> Locale {
    Locale::parse("de")
}

fn parse(s: &str) -> Value {
    serde_json::from_str(s).expect("valid JSON")
}

#[test]
fn settings_lists_have_values_and_texts() {
    let b = parse(&bitrate_levels(de()));
    let b = b.as_array().unwrap();
    assert!(b.len() > 2);
    assert_eq!(b[0]["wert"], "0", "0 is Unlimited and comes first");
    assert!(b.iter().all(|r| !r["text"].as_str().unwrap().is_empty()));
    assert!(parse(&span()).as_array().is_some_and(|a| !a.is_empty()));
    let buf = parse(&buffer_levels(de()));
    assert_eq!(buf.as_array().unwrap().len(), 3);
    assert!(buf[0].get("netz").is_none() || buf[0]["netz"].is_number());
    let like_file = parse(&languages("", de()));
    let own = parse(&languages("Deutsch", de()));
    assert_ne!(
        like_file[0]["text"], own[0]["text"],
        "an empty label becomes the 'like the file' text"
    );
    assert_eq!(own[0]["text"], "Deutsch");
}

#[test]
fn library_labels_and_genres() {
    let l = parse(&legacy_labels_json(de()));
    assert_eq!(l["sortierung"].as_array().unwrap().len(), 4);
    assert_eq!(l["filter"].as_array().unwrap().len(), 4);
    assert_eq!(l["sortierung"][0]["wert"], "name");
    let g = parse(&legacy_saved_genres_json(de()));
    assert_eq!(g.as_array().unwrap().len(), 3);
    assert_eq!(g[0]["wert"], "", "All has no kind");
    assert!(!legacy_count_text(de(), "Movie", 3).is_empty());
}

#[test]
fn search_keys_layout_and_editing() {
    for speech in [false, true] {
        let rows = parse(&search_key_rows(speech));
        let rows = rows.as_array().unwrap();
        let last = rows.last().unwrap().as_array().unwrap();
        assert_eq!(last.len(), if speech { 2 } else { 1 });
        assert_eq!(last[0]["kind"], "delete");
        assert_eq!(
            rows.iter()
                .flat_map(|r| r.as_array().unwrap())
                .filter(|k| k["kind"] == "letter")
                .count(),
            41
        );
    }
    assert_eq!(search_key_typed("a", ""), "A");
    assert_eq!(
        search_key_typed("b", "a"),
        "ab",
        "inside a word the letter stays lower case"
    );
    assert!(
        search_key_typed("b", "a ").ends_with('B'),
        "a capital at the start of a word"
    );
    assert!(!search_key_space_fits(""));
    assert!(search_key_space_fits("ab"));
    assert_eq!(search_key_space("ab"), "ab ");
    assert_eq!(search_key_delete("ab"), "a");
    assert_eq!(search_key_delete(""), "");
    assert!(search_key_hardware("x", "").starts_with(['x', 'X']));
}

#[test]
fn search_screen_states() {
    assert!(!search_titles_shown(1, 0, 0));
    assert!(search_titles_shown(1, 1, 0));
    assert!(search_titles_shown(0, 1, 1));
    assert_eq!(
        search_screen_state("", 0, false, false, false, false),
        "start"
    );
    assert_eq!(
        search_screen_state("", 2, false, false, false, false),
        "history"
    );
    assert_eq!(
        search_screen_state("abc", 0, true, true, false, false),
        "hits"
    );
    assert_eq!(
        search_screen_state("abc", 0, false, true, false, false),
        "nothing"
    );
    assert_eq!(
        search_screen_state("abc", 0, false, true, true, false),
        "disrupted"
    );
}

const LIST: &str = "[]";

#[test]
fn downloads_with_empty_or_broken_lists() {
    for list in [LIST, "", "not json"] {
        assert_eq!(download_next(list, true, false), "");
        assert_eq!(parse(&download_groups(list)), Value::Array(vec![]));
        assert_eq!(download_shared(list, de()), "");
        assert_eq!(download_next_episode(list, de()), "{}");
        assert!(!download_in_quality(list, "original").is_empty());
        let s = parse(&download_space(100, 10_000_000_000, list));
        assert_eq!(s["reicht"], true);
        assert_eq!(s["entbehrlich"], Value::Array(vec![]));
    }
    assert_eq!(download_resume_from("garbage"), 0.0);
}

#[test]
fn download_numbers_and_rules() {
    assert!(download_may_load(true, true));
    assert!(download_may_load(false, false));
    assert!(!download_may_load(false, true));
    let tight = parse(&download_space(5_000, 1_000, LIST));
    assert_eq!(tight["reicht"], false);
    assert_eq!(
        parse(&download_footer_space(100, 10_000_000_000))["reicht"],
        true
    );
    let few = parse(&download_footer_space(10_000_000_000, 100));
    assert_eq!(few["reicht"], false);
    assert!(
        few["bytes"].as_i64().unwrap() >= 9_999_999_900,
        "the shortfall includes the reserve"
    );
    let p = parse(&download_progress(512, 1024, de()));
    assert_eq!(p.as_array().unwrap().len(), 2);
    assert!(!download_size(1_500_000, de()).is_empty());
    assert!(download_progress_show(10, 100, -1, -1.0) || !download_progress_show(10, 100, 10, 0.0));
    assert!(!download_error_text(404, de()).is_empty());
    assert!(
        !download_error_text(-5, de()).is_empty(),
        "a status outside u16 is still readable"
    );
    // Unknown quality ids fall back to Original: no name, a direct-play badge.
    assert_eq!(download_quality_name("nonsense", de()), "");
    assert!(download_badge("nonsense", de()).contains("Direct Play"));
    assert_eq!(
        download_estimated("nonsense", 1234, 0),
        download_estimated("original", 1234, 0)
    );
    assert!(download_estimated("original", 1234, 0) > 0);
}

#[test]
fn download_qualities_follow_the_picker_rules() {
    let off = parse(&download_qualities(false, "[]", de()));
    let on = parse(&download_qualities(
        true,
        "[[1000000000, 36000000000]]",
        de(),
    ));
    assert!(on.as_array().unwrap().len() >= off.as_array().unwrap().len());
    for r in on.as_array().unwrap() {
        assert!(r["id"].is_string() && r["zeile"].as_str().unwrap().contains(" · "));
    }
    // Broken `files` input is ignored, not a panic.
    assert!(parse(&download_qualities(true, "oops", de())).is_array());
    assert!(parse(&download_qualities(true, "[[1],[2,3,4]]", de())).is_array());
}

#[test]
fn download_rights_buttons() {
    assert!(
        download_button_show("", true),
        "no server answer: the function decides"
    );
    assert!(!download_button_show("", false));
    assert!(download_button_show("1", true));
    assert!(!download_button_show("0", true));
}

#[test]
fn estimator_lifecycle() {
    let id = "legacy-pure-test";
    assert_eq!(
        download_estimator_value(id, 42),
        42,
        "unknown id passes the loaded bytes through"
    );
    download_estimator_report(id, 100, 1000);
    let v = download_estimator_value(id, 100);
    assert!((0..=1000).contains(&v));
    download_estimator_halt(id);
    download_estimator_halt("never-reported");
    download_estimator_forget(id);
    assert_eq!(download_estimator_value(id, 7), 7);
}
