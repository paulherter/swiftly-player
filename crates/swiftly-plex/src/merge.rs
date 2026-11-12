//! **Several libraries as one list** (`PlexMerge.swift`).
//!
//! A server can hold more than one library of a kind ("Serien", "Kids"). Each answers its own
//! sorted run; gluing the runs together puts the whole first library before the second, so
//! months-old Kids titles came first in "newest". The runs are merged by the field they were
//! sorted by instead.

use std::cmp::Ordering;
use std::collections::HashSet;
use std::ops::Range;

use crate::wire::PlexMetadata;

/// Newest first across the runs, once per title (PlexMerge.swift:11).
pub fn newest(runs: &[Vec<PlexMetadata>], limit: usize) -> Vec<PlexMetadata> {
    let mut seen = HashSet::new();
    merged(runs, Some("addedAt:desc"))
        .into_iter()
        .filter(|m| seen.insert(m.rating_key.clone()))
        .take(limit)
        .collect()
}

/// **Which part of each library's sorted run a page needs** (PlexMerge.swift:26-37).
///
/// `totals` are the library sizes (from a `size=0` request each). An item at place `p` of its
/// run sits at merged place `p ... p + (items of the other libraries)`, so everything with
/// `p + others < start` is certainly before the page and need not be fetched; and nothing at
/// `p >= start + size` can be on it. Items left out are all before `start`, so the merge of the
/// parts is the full merge minus a prefix of known length (`skipped`).
pub fn window(totals: &[i64], start: i64, size: i64) -> (Vec<Range<i64>>, i64) {
    // The sizes come from the server: sums and offsets saturate instead of overflowing.
    let all: i64 = totals.iter().fold(0, |sum, &t| sum.saturating_add(t));
    let mut skipped: i64 = 0;
    let ranges = totals
        .iter()
        .map(|&total| {
            let from = total.min(start.saturating_sub(all.saturating_sub(total)).max(0));
            let to = from.max(total.min(start.saturating_add(size)));
            skipped = skipped.saturating_add(from);
            from..to
        })
        .collect();
    (ranges, skipped)
}

/// The page `start ..< start + size` of the merged list, from runs that hold only the parts
/// [`window`] named (PlexMerge.swift:41).
pub fn page(
    runs: &[Vec<PlexMetadata>],
    skipped: i64,
    sort: Option<&str>,
    start: i64,
    size: i64,
) -> Vec<PlexMetadata> {
    merged(runs, sort)
        .into_iter()
        .skip(usize::try_from(start.saturating_sub(skipped).max(0)).unwrap_or(usize::MAX))
        .take(usize::try_from(size.max(0)).unwrap_or(usize::MAX))
        .collect()
}

/// The runs, each sorted by `sort` (a Plex expression such as `year:desc,titleSort:asc`),
/// merged into one sorted list. Ties keep the order of the runs. Without a known order
/// (`random`, none) the runs stay one after the other (PlexMerge.swift:50).
pub fn merged(runs: &[Vec<PlexMetadata>], sort: Option<&str>) -> Vec<PlexMetadata> {
    let keys = parse(sort);
    if keys.is_empty() {
        return runs.iter().flatten().cloned().collect();
    }
    let mut positions = vec![0usize; runs.len()];
    let mut out = Vec::with_capacity(runs.iter().map(Vec::len).sum());
    loop {
        let mut best: Option<usize> = None;
        for (spot, run) in runs.iter().enumerate() {
            if positions[spot] >= run.len() {
                continue;
            }
            match best {
                Some(current) => {
                    if before(
                        &run[positions[spot]],
                        &runs[current][positions[current]],
                        &keys,
                    ) {
                        best = Some(spot);
                    }
                }
                None => best = Some(spot),
            }
        }
        let Some(best) = best else { return out };
        out.push(runs[best][positions[best]].clone());
        positions[best] += 1;
    }
}

struct Key {
    field: String,
    descending: bool,
}

fn parse(sort: Option<&str>) -> Vec<Key> {
    let Some(sort) = sort.filter(|s| !s.is_empty()) else {
        return Vec::new();
    };
    let mut keys = Vec::new();
    // Swift `split(separator:)` drops empty pieces.
    for part in sort.split(',').filter(|p| !p.is_empty()) {
        let pieces: Vec<&str> = part.splitn(2, ':').filter(|p| !p.is_empty()).collect();
        let Some(field) = pieces.first() else {
            continue;
        };
        if *field == "random" {
            return Vec::new();
        }
        keys.push(Key {
            field: (*field).to_string(),
            descending: pieces.last().is_some_and(|p| p.starts_with("desc")),
        });
    }
    keys
}

#[derive(PartialEq, PartialOrd)]
enum Value {
    Number(f64),
    Text(String),
}

fn value(m: &PlexMetadata, field: &str) -> Option<Value> {
    match field {
        "addedAt" => m.added_at.map(|n| Value::Number(n as f64)),
        "year" => m.year.map(|n| Value::Number(n as f64)),
        "audienceRating" => m.audience_rating.map(Value::Number),
        "rating" => m.rating.map(Value::Number),
        "lastViewedAt" => m.last_viewed_at.map(|n| Value::Number(n as f64)),
        "originallyAvailableAt" => m.originally_available_at.clone().map(Value::Text),
        // `titleSort` is what the server sorted by; the title is its stand-in.
        _ => Some(Value::Text(
            m.title_sort
                .as_deref()
                .filter(|s| !s.is_empty())
                .unwrap_or(&m.title)
                .to_lowercase(),
        )),
    }
}

/// `a` comes strictly before `b`. A missing value goes last in either direction.
fn before(a: &PlexMetadata, b: &PlexMetadata, keys: &[Key]) -> bool {
    for key in keys {
        match (value(a, &key.field), value(b, &key.field)) {
            (None, None) => continue,
            (None, Some(_)) => return false,
            (Some(_), None) => return true,
            (Some(x), Some(y)) => {
                if x == y {
                    continue;
                }
                let order = x.partial_cmp(&y).unwrap_or(Ordering::Equal);
                return if key.descending {
                    order == Ordering::Greater
                } else {
                    order == Ordering::Less
                };
            }
        }
    }
    false
}
