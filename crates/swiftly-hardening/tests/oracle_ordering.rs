//! Differential oracle, ordering/filtering domains: the Rust output must equal the real Swift
//! output (Tools/Oracle, Domain_Ordering.swift).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use std::collections::HashSet;
use swiftly_hardening::oracle::assert_equal;
use swiftly_library::library_filter::{LibraryFilter, RememberGenre, SortingExt};
use swiftly_library::search_history;
use swiftly_library::{
    LibraryGenre, ListRules, StartLibraries, StartLibrary, StartRail, StartRailsEpisode,
    TitleFilter,
};
use swiftly_model::Item;
use swiftly_playback::sections::{Art, ButtonOffering, SectionLogic, Segment};
use swiftly_rules::alphabet_index::Sorting;

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

fn item(v: &Value) -> Option<Item> {
    serde_json::from_value(v.clone()).ok()
}

fn items(v: &Value) -> Vec<Item> {
    v.as_array()
        .map(|a| a.iter().filter_map(item).collect())
        .unwrap_or_default()
}

fn ids(list: &[Item]) -> Value {
    json!(list.iter().map(|i| i.id.clone()).collect::<Vec<_>>())
}

fn rails(list: Vec<StartRail>) -> Value {
    json!(
        list.into_iter()
            .map(StartRail::raw_value)
            .collect::<Vec<_>>()
    )
}

#[test]
fn start_rails() {
    assert_equal("start_rails", |c| {
        let stored = strings(&c["stored"]);
        let disc = c["disc"].as_bool().unwrap_or(false);
        match c["op"].as_str().unwrap() {
            "applicable" => rails(StartRailsEpisode::applicable(&stored)),
            "visible" => {
                let hidden: HashSet<String> = strings(&c["hidden"]).into_iter().collect();
                rails(StartRailsEpisode::visible(&stored, &hidden, disc))
            }
            "shifted" => {
                let Some(r) = StartRail::from_raw(c["rail"].as_str().unwrap()) else {
                    return Value::Null;
                };
                json!(StartRailsEpisode::shifted(
                    r,
                    c["step"].as_i64().unwrap(),
                    &stored,
                    disc
                ))
            }
            _ => {
                let Some(r) = StartRail::from_raw(c["rail"].as_str().unwrap()) else {
                    return Value::Null;
                };
                let jump = r
                    .library_jump()
                    .map_or(Value::Null, |j| json!([j.art, j.sorting.raw_value()]));
                json!({ "fits": r.fits(disc), "list": r.lists_name(), "symbol": r.symbol_text(), "title": r.rails_title(), "jump": jump })
            }
        }
    });
}

#[test]
fn start_libraries() {
    assert_equal("start_libraries", |c| match c["op"].as_str().unwrap() {
        "read" => {
            let list = StartLibraries::read(c["text"].as_str().map(str::as_bytes));
            json!(
                list.iter()
                    .map(|l| json!([l.id, l.name, l.collection]))
                    .collect::<Vec<_>>()
            )
        }
        "data" => {
            let choice: Vec<StartLibrary> = c["choice"]
                .as_array()
                .unwrap()
                .iter()
                .map(|e| {
                    StartLibrary::new(
                        e["id"].as_str().unwrap(),
                        e["name"].as_str().unwrap(),
                        e["collection"].as_bool().unwrap(),
                    )
                })
                .collect();
            StartLibraries::data(&choice)
                .map_or(Value::Null, |d| json!(String::from_utf8(d).unwrap()))
        }
        "selectable" => match item(&c["item"]) {
            Some(i) => json!({ "decoded": true, "selectable": StartLibraries::selectable(&i) }),
            None => json!({ "decoded": false }),
        },
        _ => {
            let selected: Vec<StartLibrary> = c["selected"]
                .as_array()
                .unwrap()
                .iter()
                .map(|e| StartLibrary::new(e["id"].as_str().unwrap(), "", false))
                .collect();
            ids(&StartLibraries::pick(
                &items(&c["libraries"]),
                &items(&c["collections"]),
                &selected,
            ))
        }
    });
}

#[test]
fn search_history() {
    assert_equal("search_history", |c| match c["op"].as_str().unwrap() {
        "key" => json!(search_history::key_for(c["account"].as_str())),
        "list" => json!(search_history::list(c["raw"].as_str().unwrap())),
        _ => json!(search_history::remember(
            c["word"].as_str().unwrap(),
            c["raw"].as_str().unwrap()
        )),
    });
}

#[test]
fn library_genre() {
    assert_equal("library_genre", |c| {
        let art = c["art"].as_str();
        json!({ "types": LibraryGenre::types_toward(art), "recursive": LibraryGenre::recursive_toward(art) })
    });
}

#[test]
fn library_filter() {
    assert_equal("library_filter", |c| {
        let filters: Vec<LibraryFilter> = strings(&c["filters"])
            .iter()
            .filter_map(|s| LibraryFilter::from_raw(s))
            .collect();
        let raw = c["raw"].as_str().unwrap_or("");
        match c["op"].as_str().unwrap() {
            "sorting" => Sorting::from_raw(raw).map_or(
                Value::Null,
                |s| json!({ "field": s.input_field(), "bearing": s.bearing() }),
            ),
            "filter" => LibraryFilter::from_raw(raw).map_or(
                Value::Null,
                |f| json!({ "jf": f.jellyfin_filter(), "watched": f.is_watched() }),
            ),
            "offered" => json!(
                LibraryFilter::offered(&filters, c["watchlist"].as_bool().unwrap())
                    .into_iter()
                    .map(LibraryFilter::raw_value)
                    .collect::<Vec<_>>()
            ),
            "kept" => LibraryFilter::from_raw(raw)
                .map_or(Value::Null, |f| json!(f.kept(&filters).raw_value())),
            "remember" => RememberGenre::from_raw(raw).map_or(
                Value::Null,
                |g| json!({ "art": g.art(), "types": g.types() }),
            ),
            _ => json!(RememberGenre::toward(c["art"].as_str()).raw_value()),
        }
    });
}

#[test]
fn list_rules() {
    assert_equal("list_rules", |c| {
        let list = items(&c["items"]);
        let more = items(&c["more"]);
        match c["op"].as_str().unwrap() {
            "double" => ids(&ListRules::without_double(&list)),
            "title" => ids(&ListRules::je_title_in_times(
                &list,
                usize::try_from(c["show"].as_i64().unwrap()).unwrap(),
            )),
            "append" => ids(&ListRules::append(&more, &list)),
            "refresh" => ids(&ListRules::refresh(
                &more,
                &list,
                c["before"].as_i64().unwrap(),
                c["now"].as_i64().unwrap(),
            )),
            "rails" => ids(&ListRules::in_rails_episode(&list, &more)),
            "post" => json!(ListRules::post_load_section(
                c["id"].as_str().unwrap(),
                &list,
                c["columns"].as_i64().unwrap()
            )),
            _ => json!(ListRules::still_more_present(
                c["loaded"].as_i64().unwrap(),
                c["total"].as_i64().unwrap()
            )),
        }
    });
}

#[test]
fn title_filter() {
    assert_equal("title_filter", |c| {
        let libs: Vec<(String, Vec<Item>)> = c["libs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| (l["id"].as_str().unwrap().to_owned(), items(&l["items"])))
            .collect();
        let mut filter = TitleFilter::new(&libs);
        let front = c["front_after"].as_i64();
        let mut pages = Vec::new();
        for (n, page) in c["pages"].as_array().unwrap().iter().enumerate() {
            pages.push(ids(&filter.sift(&items(page))));
            if front == i64::try_from(n).ok() {
                filter.from_front();
            }
        }
        json!({ "total": filter.total, "pages": pages })
    });
}

fn art_raw(a: Art) -> &'static str {
    match a {
        Art::Unknown => "Unknown",
        Art::Ads => "Commercial",
        Art::Preview => "Preview",
        Art::LookBack => "Recap",
        Art::Credits => "Outro",
        Art::IntroSegment => "Intro",
    }
}

fn offering(o: ButtonOffering) -> Value {
    match o {
        ButtonOffering::Nobody => json!(["nobody"]),
        ButtonOffering::Skip { to, art } => json!(["skip", to, art_raw(art)]),
        ButtonOffering::NextEpisode => json!(["next"]),
    }
}

#[test]
fn section_logic() {
    assert_equal("section_logic", |c| {
        let position = c["position"].as_f64().unwrap();
        let duration = c["duration"].as_f64().unwrap();
        let sections: Vec<Segment> = c["sections"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| {
                Segment::new(
                    Art::from_raw(s["art"].as_str().unwrap()).unwrap(),
                    s["from"].as_f64().unwrap(),
                    s["until"].as_f64().unwrap(),
                )
            })
            .collect();
        let next = c["next"].as_bool().unwrap();
        let window = c["window"].as_f64();
        match c["op"].as_str().unwrap() {
            "automatic" => SectionLogic::automatic(position, duration, &sections, next).map_or(
                Value::Null,
                |a| {
                    json!([
                        art_raw(a.segment.art),
                        a.segment.from,
                        a.segment.until,
                        offering(a.offering)
                    ])
                },
            ),
            "card" => json!(SectionLogic::card_due(
                position, duration, &sections, next, window
            )),
            "countdown" => json!(SectionLogic::countdown(position, duration)),
            "countdown2" => json!(SectionLogic::countdown_with_sections(
                position, duration, &sections, window
            )),
            _ => offering(SectionLogic::offering(position, duration, &sections, next)),
        }
    });
}
