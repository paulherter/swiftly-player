//! Translation of the Swift tests in `Packages/JellyfinKit/Tests/JellyfinKitTests`:
//! `ModelsTests.swift`, `ItemsTests.swift`, `RobustDecodeTests.swift`.

use std::collections::HashMap;

use swiftly_model::{Item, Items, ItemsResponse, Localizer, SeriesNumber, UserItemData};

// ---------------------------------------------------------------- ModelsTests.swift

fn episode_of(season: Option<i64>, number: Option<i64>, series: Option<&str>) -> Item {
    Item {
        series_name: series.map(Into::into),
        index_number: number,
        parent_index_number: season,
        ..Item::new("f1", "Eine Folge", Some("Episode"))
    }
}

fn pre_series_episode(series: Option<&str>, name: Option<&str>) -> Item {
    Item {
        series_name: name.map(Into::into),
        series_id: series.map(Into::into),
        ..Item::new("f1", "Folge 1", Some("Episode"))
    }
}

#[test]
fn pre_common_series_takes_id_and_name_and_is_a_series() {
    let s = Item::pre_common_series(&pre_series_episode(Some("s1"), Some("Young Sheldon")))
        .expect("series");
    assert_eq!(s.id, "s1");
    assert_eq!(s.name, "Young Sheldon");
    assert_eq!(s.type_.as_deref(), Some("Series"));
}

#[test]
fn pre_common_series_without_id_or_name_is_none() {
    assert!(Item::pre_common_series(&pre_series_episode(None, Some("Young Sheldon"))).is_none());
    assert!(Item::pre_common_series(&pre_series_episode(Some("s1"), None)).is_none());
}

#[test]
fn constructor_fills_only_what_is_named() {
    let i = Item::new("x", "Ein Film", Some("Movie"));
    assert!(i.overview.is_none() && i.user_data.is_none() && i.genres.is_none());
}

fn letter_before(text: &str, digit: &str) -> Option<char> {
    let at = text.find(digit)?;
    text[..at].chars().last()
}

#[test]
fn abbreviation_and_context_row_use_the_same_letter() {
    let item = episode_of(Some(7), Some(3), Some("21 Jump Street"));
    let abbreviation = item.episode_code().expect("code");
    let row = item.context_line().expect("row");
    assert!(abbreviation.contains("S7"));
    assert!(row.contains("21 Jump Street"));
    let b_f = letter_before(&abbreviation, "3").expect("letter");
    let b_z = letter_before(&row, "3").expect("letter");
    assert_eq!(b_f, b_z);
    assert!(matches!(b_f, 'F' | 'E'));
}

/// The English catalog maps `F%lld` to `E%lld`; the Swift catalog test pins that
/// the abbreviation and the row stay in step in every language.
struct English;
impl Localizer for English {
    fn text(&self, key: &str, args: &[i64]) -> String {
        let key = match key {
            "S%lld · F%lld" => "S%lld · E%lld",
            "F%lld" => "E%lld",
            "Staffel %lld" => "Season %lld",
            "Folge %lld" => "Episode %lld",
            "%lld neue Folgen" => "%lld new episodes",
            other => other,
        };
        let mut out = key.to_string();
        for a in args {
            out = out.replacen("%lld", &a.to_string(), 1);
        }
        out
    }
    fn language_name(&self, raw: Option<&str>) -> Option<String> {
        raw.map(str::to_string)
    }
}

#[test]
fn abbreviation_and_row_in_english_use_e() {
    let item = episode_of(Some(7), Some(3), Some("21 Jump Street"));
    assert_eq!(item.episode_code_with(&English).as_deref(), Some("S7 · E3"));
    assert_eq!(
        item.context_line_with(&English).as_deref(),
        Some("S7 • E3 • 21 Jump Street")
    );
    assert_eq!(item.episode_code().as_deref(), Some("S7 · F3"));
    assert_eq!(
        item.context_line().as_deref(),
        Some("S7 • F3 • 21 Jump Street")
    );
}

#[test]
fn no_season_or_number_means_no_abbreviation() {
    assert!(
        episode_of(None, Some(3), Some("x"))
            .episode_code()
            .is_none()
    );
    assert!(
        episode_of(Some(7), None, Some("x"))
            .episode_code()
            .is_none()
    );
}

#[test]
fn context_row_without_details_is_none() {
    assert!(
        Item::new("m1", "Ein Film", Some("Movie"))
            .context_line()
            .is_none()
    );
}

// ---------------------------------------------------------------- ItemsTests.swift

fn film(id: &str, tmdb: Option<&str>, imdb: Option<&str>, state: bool) -> Item {
    let mut numbers = HashMap::new();
    if let Some(t) = tmdb {
        numbers.insert("Tmdb".to_string(), t.to_string());
    }
    if let Some(i) = imdb {
        numbers.insert("Imdb".to_string(), i.to_string());
    }
    Item {
        user_data: state.then(|| UserItemData {
            playback_position_ticks: Some(600_000_000),
            ..Default::default()
        }),
        provider_ids: (!numbers.is_empty()).then_some(numbers),
        ..Item::new(id, "Obsession", Some("Movie"))
    }
}

fn episode(id: &str, series: &str, season: i64, nr: i64) -> Item {
    Item {
        series_name: Some("The Lighthouse".into()),
        index_number: Some(nr),
        parent_index_number: Some(season),
        series_id: Some(series.into()),
        ..Item::new(id, "Folge", Some("Episode"))
    }
}

fn libraries() -> Vec<Item> {
    vec![
        Item::new("videothek", "Videothek", None),
        Item {
            collection_type: Some("movies".into()),
            ..Item::new("filme", "Filme", None)
        },
        Item {
            collection_type: Some("movies".into()),
            ..Item::new("kino", "Kinoabend", None)
        },
    ]
}

fn origin(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs
        .iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect()
}

fn ids(items: &[Item]) -> Vec<&str> {
    items.iter().map(|i| i.id.as_str()).collect()
}

fn merge(list: &[Item], o: &[(&str, &str)], series: &SeriesNumber) -> Vec<Item> {
    Items::merge(list, &origin(o), &libraries(), series, false)
}

#[test]
fn same_tmdb_from_two_libraries_movie_library_wins() {
    let list = [
        film("v", Some("1"), None, false),
        film("f", Some("1"), None, false),
    ];
    let r = merge(
        &list,
        &[("v", "videothek"), ("f", "filme")],
        &SeriesNumber::new(),
    );
    assert_eq!(ids(&r), ["f"]);
}

#[test]
fn same_kind_first_library_wins() {
    let list = [
        film("k", Some("1"), None, false),
        film("f", Some("1"), None, false),
    ];
    let r = merge(
        &list,
        &[("k", "kino"), ("f", "filme")],
        &SeriesNumber::new(),
    );
    assert_eq!(ids(&r), ["f"]);
}

#[test]
fn same_library_entry_with_state_wins() {
    let list = [
        film("a", Some("1"), None, false),
        film("b", Some("1"), None, true),
    ];
    let r = Items::merge(&list, &HashMap::new(), &[], &SeriesNumber::new(), false);
    assert_eq!(ids(&r), ["b"]);
}

#[test]
fn one_shared_number_suffices() {
    let list = [
        film("v", Some("1"), Some("tt9"), false),
        film("f", None, Some("TT9"), false),
    ];
    let r = merge(
        &list,
        &[("v", "videothek"), ("f", "filme")],
        &SeriesNumber::new(),
    );
    assert_eq!(ids(&r), ["f"]);
}

#[test]
fn without_provider_numbers_nothing_merges() {
    let list = [film("a", None, None, false), film("b", None, None, false)];
    let r = Items::merge(&list, &HashMap::new(), &[], &SeriesNumber::new(), false);
    assert_eq!(ids(&r), ["a", "b"]);
    assert!(!Items::has_double(&list, &SeriesNumber::new(), false));
}

#[test]
fn episodes_same_series_season_and_number_are_one() {
    let series: SeriesNumber = [
        ("s1", [("Tvdb", "80")]),
        ("s2", [("Tvdb", "80")]),
        ("s3", [("Tvdb", "99")]),
    ]
    .into_iter()
    .map(|(k, v)| {
        (
            k.to_string(),
            v.into_iter()
                .map(|(a, b)| (a.to_string(), b.to_string()))
                .collect(),
        )
    })
    .collect();
    let list = [
        episode("a", "s2", 1, 2),
        episode("b", "s1", 1, 2),
        episode("c", "s1", 1, 3),
        episode("d", "s3", 1, 2),
    ];
    let r = merge(&list, &[("a", "videothek"), ("b", "filme")], &series);
    assert_eq!(ids(&r), ["b", "c", "d"]);
}

#[test]
fn episodes_without_series_numbers_stay_apart() {
    let list = [episode("a", "s1", 1, 2), episode("b", "s2", 1, 2)];
    let r = Items::merge(&list, &HashMap::new(), &[], &SeriesNumber::new(), false);
    assert_eq!(ids(&r), ["a", "b"]);
    let suspicion = Items::series_suspicion(&list);
    assert_eq!(
        suspicion,
        ["s1".to_string(), "s2".to_string()].into_iter().collect()
    );
}

#[test]
fn list_order_stays_winner_moves_to_first_place() {
    let list = [
        film("x", Some("7"), None, false),
        film("v", Some("1"), None, false),
        film("y", Some("8"), None, false),
        film("f", Some("1"), None, false),
        film("z", Some("9"), None, false),
    ];
    let r = merge(
        &list,
        &[("v", "videothek"), ("f", "filme")],
        &SeriesNumber::new(),
    );
    assert_eq!(ids(&r), ["x", "f", "y", "z"]);
}

// ---------------------------------------------------------------- RobustDecodeTests.swift

fn large_page(count: usize) -> String {
    let long = "Sehr langer Titel ".repeat(150);
    let mut parts: Vec<String> = Vec::with_capacity(count);
    for i in 0..count {
        parts.push(match i % 10 {
            1 => format!(r#"{{"Id":"f{i}","Name":"{long}{i}","Type":"Movie"}}"#),
            2 => format!(
                r#"{{"Id":"f{i}","Name":"F{i}","RunTimeTicks":null,"UserData":null,"ImageTags":null,"ProductionYear":null}}"#
            ),
            3 => format!(
                r#"{{"Id":"f{i}","Name":"F{i}","UserData":{{"PlaybackPositionTicks":1000000000000000000,"PlayedPercentage":1e308}}}}"#
            ),
            4 => r#"{"Id":null,"Name":"ohne Kennung"}"#.to_string(),
            5 => r#"{"Name":"ohne Kennung und Typ"}"#.to_string(),
            6 => "null".to_string(),
            _ => format!(
                r#"{{"Id":"f{i}","Name":"F{i}","Type":"Movie","RunTimeTicks":60000000000,"UserData":{{"Played":true}}}}"#
            ),
        });
    }
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{count}}}"#,
        parts.join(",")
    )
}

#[test]
fn large_library_with_gaps() {
    let answer: ItemsResponse = serde_json::from_str(&large_page(5000)).expect("decode");
    // Rest 4, 5 and 6 are unreadable; three of ten drop out.
    assert_eq!(answer.items.len(), 3500);
    assert_eq!(answer.total_record_count, 5000);
    assert!(answer.items.iter().all(|i| !i.id.is_empty()));
}

#[test]
fn watched_share_stays_between_0_and_100() {
    let share = |raw: &str| {
        serde_json::from_str::<UserItemData>(&format!(r#"{{"PlayedPercentage":{raw}}}"#))
            .expect("decode")
            .played_percentage
    };
    assert_eq!(share("1e308"), Some(100.0));
    assert_eq!(share("-3"), Some(0.0));
    assert_eq!(share("42.5"), Some(42.5));
    assert_eq!(share("null"), None);
    let item: Item =
        serde_json::from_str(r#"{"Id":"a","Name":"b","UserData":{"PlayedPercentage":1e308}}"#)
            .expect("decode");
    assert_eq!((item.watched_share().expect("share") * 100.0) as i64, 100);
}

#[test]
fn ticks_from_seconds_does_not_throw() {
    use swiftly_model::ticks_from_seconds as t;
    assert_eq!(t(f64::NAN), 0);
    assert_eq!(t(f64::INFINITY), 0);
    assert_eq!(t(f64::NEG_INFINITY), 0);
    assert_eq!(t(-5.0), 0);
    assert!(t(1e300) > 0);
    assert_eq!(t(90.0), 900_000_000);
    assert_eq!(t(1.5), 15_000_000);
}
