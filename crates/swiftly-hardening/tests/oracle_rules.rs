//! Differential oracle, group "small pure rules" (swiftly-rules): Rust must equal the recorded
//! output of the real Swift code (Tools/Oracle, Domain_SmallRules.swift / Domain_AlphabetIndex.swift).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::{assert_equal, read};
use swiftly_rules::alphabet_index::{AlphabetIndex, Entry, IndexItem, Sorting};
use swiftly_rules::chapter::{Chapter, ChapterBar};
use swiftly_rules::display_rules::{self, TileMark};
use swiftly_rules::download_quality::DownloadQuality;
use swiftly_rules::{age_rating, episodes_end, whole_number};

fn f(v: &Value) -> Option<f64> {
    v.as_f64()
}
fn i(v: &Value) -> Option<i64> {
    v.as_i64()
}
fn st(v: &Value) -> Option<&str> {
    v.as_str()
}

#[test]
fn age_rating() {
    assert_equal("age_rating", |c| json!(age_rating::text(st(&c["raw"]))));
}

#[test]
fn whole_number() {
    assert_equal("whole_number", |c| {
        let v = match st(&c["value"]) {
            Some("nan") => f64::NAN,
            Some("inf") => f64::INFINITY,
            Some(_) => f64::NEG_INFINITY,
            None => f(&c["value"]).unwrap_or(0.0),
        };
        json!(whole_number::capped(v))
    });
}

#[test]
fn resume_point() {
    assert_equal("resume_point", |c| {
        json!(swiftly_playback::resume_point::since(
            f(&c["position"]),
            f(&c["runtime"])
        ))
    });
}

#[test]
fn download_quality() {
    assert_equal("download_quality", |c| {
        let q = DownloadQuality::from_raw_value(st(&c["quality"]).unwrap()).expect("quality");
        let selectable = DownloadQuality::selectable(c["video"].as_bool(), c["audio"].as_bool());
        let source = i(&c["source"]);
        let files: Vec<(i64, Option<i64>)> = c["files"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| (i(&p[0]).unwrap(), i(&p[1])))
            .collect();
        let raws =
            |v: Vec<DownloadQuality>| v.into_iter().map(|q| q.raw_value()).collect::<Vec<_>>();
        json!({
            "height": q.height(), "width": q.width(), "image_bitrate": q.image_bitrate(),
            "audio_bitrate": q.audio_bitrate(), "audio_channels": q.audio_channels(),
            "total": q.total_bitrate(), "is_original": q.is_original(), "selectable": selectable,
            "offered": raws(DownloadQuality::offered(selectable, source)),
            "offered_all": raws(DownloadQuality::offered(true, source)),
            "bitrate": DownloadQuality::bitrate(i(&c["bytes"]).unwrap(), i(&c["ticks"])),
            "source_bitrate": DownloadQuality::source_bitrate_of(&files),
            "estimated": q.estimated_bytes(i(&c["original"]).unwrap(), i(&c["ticks"])),
            "addition": if q.is_original() { None } else { q.addition(".") },
        })
    });
}

#[test]
fn display_rules() {
    assert_equal("display_rules", |c| {
        let mark = match display_rules::tile_mark(
            st(&c["art"]),
            i(&c["seasons"]),
            c["watched"].as_bool(),
            i(&c["open"]),
        ) {
            Some(TileMark::Watched) => json!(["watched"]),
            Some(TileMark::Opened(n)) => json!(["opened", n]),
            Some(TileMark::Seasons(n)) => json!(["seasons", n]),
            None => Value::Null,
        };
        json!({
            "runtime_show": display_rules::runtime_show(f(&c["seconds"])),
            "fits": display_rules::search_term_fits(st(&c["term"]).unwrap()),
            "mark": mark,
            "character": display_rules::tile_character(st(&c["type"]), st(&c["series_id"])),
        })
    });
}

#[test]
fn episode_end() {
    assert_equal("episode_end", |c| {
        let (p, d) = (f(&c["position"]).unwrap(), f(&c["duration"]).unwrap());
        json!({
            "button": episodes_end::button_show(p, d),
            "at_end": episodes_end::at_end(p, d),
            "advance": episodes_end::advance(p, d, f(&c["since"]).unwrap(), c["card"].as_bool().unwrap()),
        })
    });
}

#[test]
fn chapter_bar() {
    assert_equal("chapter_bar", |c| {
        let chapters: Vec<Chapter> = c["chapters"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| Chapter::new(st(&x["name"]).unwrap(), f(&x["from"]).unwrap()))
            .collect();
        let (duration, width) = (f(&c["duration"]).unwrap(), f(&c["width"]).unwrap());
        let usable = ChapterBar::usable(&chapters);
        let limits = ChapterBar::limits(&usable, duration);
        let pieces = ChapterBar::pieces(&limits, duration, width, f(&c["min_width"]).unwrap());
        let gap = f(&c["gap"]).unwrap();
        let ch = |x: &Chapter| json!({ "name": x.name, "from": x.from });
        json!({
            "usable": usable.iter().map(ch).collect::<Vec<_>>(),
            "limits": limits,
            "pieces": pieces.iter().map(|p| json!({ "from": p.from, "until": p.until })).collect::<Vec<_>>(),
            "snap": ChapterBar::snap_cuts(&pieces, duration, width),
            "frames": pieces.iter().map(|p| { let (x, w) = p.frame_rect(width, gap); json!([x, w]) }).collect::<Vec<_>>(),
            "piece_at": c["shares"].as_array().unwrap().iter().map(|s| json!(ChapterBar::piece_at(f(s).unwrap(), &pieces))).collect::<Vec<_>>(),
            "chapter_at": c["spots"].as_array().unwrap().iter()
                .map(|s| ChapterBar::chapter_at(f(s).unwrap(), &usable).map_or(Value::Null, ch)).collect::<Vec<_>>(),
        })
    });
}

#[test]
fn alphabet_index() {
    // Month names are platform locale data: take the ones Swift recorded, compare the logic.
    let swift = read("alphabet_index.swift.json").expect("swift results");
    let symbols: Vec<String> = swift["results"][0]["symbols"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap().to_owned())
        .collect();
    let symbol_refs: Vec<&str> = symbols.iter().map(String::as_str).collect();
    assert_equal("alphabet_index", |c| {
        let sorting = match st(&c["sorting"]).unwrap() {
            "name" => Sorting::Name,
            "neueste" => Sorting::Latest,
            "bewertung" => Sorting::Rating,
            _ => Sorting::Erscheinung,
        };
        let items: Vec<IndexItem> = c["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| IndexItem {
                name: st(&x["name"]).unwrap().to_owned(),
                sort_name: st(&x["sort"]).map(str::to_owned),
                premiere_date: st(&x["premiere"]).map(str::to_owned),
                production_year: i(&x["year"]),
                community_rating: f(&x["rating"]),
                date_created: st(&x["created"]).map(str::to_owned),
            })
            .collect();
        let index = AlphabetIndex::from_items(&items, sorting, &symbol_refs);
        let entry = |e: &Entry| json!({ "letter": e.letter, "first": e.first, "label": e.label, "gap": e.gap });
        let keys: Vec<String> = items.iter().map(|x| index.key(x)).collect();
        let height = f(&c["height"]).unwrap();
        json!({
            "entries": index.entries.iter().map(entry).collect::<Vec<_>>(),
            "count": index.count, "monthly": index.monthly, "useful": index.is_useful(),
            "keys": keys,
            "letters": items.iter().map(|x| AlphabetIndex::letter_for(&x.name)).collect::<Vec<_>>(),
            "name_letters": items.iter().map(|x| AlphabetIndex::letter(&x.name, x.sort_name.as_deref())).collect::<Vec<_>>(),
            "condensed": index.condensed(i(&c["slots"]).unwrap()).iter().map(entry).collect::<Vec<_>>(),
            "rows": AlphabetIndex::rows(&index.entries),
            "at": c["ys"].as_array().unwrap().iter()
                .map(|y| json!(AlphabetIndex::entry_at(f(y).unwrap(), height, &index.entries).map(|e| e.letter.clone())))
                .collect::<Vec<_>>(),
            "label_first": index.label_of(keys.first().map(String::as_str)),
            "target_last": keys.last().and_then(|k| index.target_for_key(k, &items)),
            "symbols": symbols,
        })
    });
}

#[test]
fn download_task() {
    use swiftly_downloads::task::{DownloadTask, TaskParts};
    let parts = |p: Option<TaskParts>| match p {
        None => Value::Null,
        Some(p) => json!({ "id": p.id, "generation": p.generation, "file": p.file }),
    };
    assert_equal("download_task", |c| {
        let text = DownloadTask::description(
            st(&c["id"]).unwrap(),
            i(&c["gen"]).unwrap(),
            st(&c["file"]).unwrap(),
        );
        json!({
            "description": text,
            "round": parts(DownloadTask::dismantle(Some(&text))),
            "raw": parts(DownloadTask::dismantle(st(&c["text"]))),
            "applies": DownloadTask::applies(i(&c["reported"]).unwrap(), i(&c["current"])),
        })
    });
}

#[test]
fn term_trim() {
    assert_equal("term_trim", |c| {
        json!(display_rules::search_term_fits(st(&c["term"]).unwrap()))
    });
}
