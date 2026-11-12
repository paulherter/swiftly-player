#![allow(missing_docs)]
//! The search calls of the old Android facade: the flat result list (`Kern.search`) and the pure rules of the TV
//! keyboard and the search screen (`SearchKeys`, `SearchGroups`, `SearchScreen` of JellyfinKit). Same JSON as before.

use std::sync::Arc;

use serde::Serialize;
use swiftly_l10n::Arg;
use swiftly_library::ListRules;
use swiftly_model::{Item, ItemKind};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_playback::media_server::MediaServer;
use swiftly_rules::display_rules::search_term_fits;

use crate::account::AccountRef;
use crate::home::{Source, build_source};
use crate::host::Host;
use crate::legacy_library::{LegacyGridTile, grid_tile_sorted};
use crate::tile::Words;
use crate::title_text::TitleText;
use swiftly_rules::alphabet_index::Sorting;

/// `Item.hitInfo`: kind, episode code, year, seasons and runtime in one line.
fn hit_info(item: &Item, words: &Words, text: &TitleText) -> String {
    let mut parts: Vec<String> = Vec::new();
    match item.kind() {
        ItemKind::Movie => parts.push(text.key("Film")),
        ItemKind::Series => parts.push(text.key("Serie")),
        ItemKind::Episode => parts.push(
            item.series_name
                .clone()
                .unwrap_or_else(|| text.key("Folge")),
        ),
        _ => {}
    }
    if let Some(code) = item.episode_code_with(words) {
        parts.push(code);
    }
    if let Some(year) = item.production_year
        && item.kind() != ItemKind::Episode
    {
        parts.push(year.to_string());
    }
    if let Some(count) = item.child_count
        && item.kind() == ItemKind::Series
    {
        parts.push(text.with("%lld Staffeln", &[Arg::Int(count)]));
    }
    if let Some(seconds) = item.runtime_seconds()
        && item.kind() != ItemKind::Series
    {
        parts.push(text.runtime(seconds));
    }
    parts.join(" · ")
}

/// `Kern.search`: movies and series only, each work once, the line under the poster from `hitInfo`; `[]` below the
/// minimum length.
pub async fn legacy_search_json<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: &AccountRef,
    term: &str,
) -> Result<String, ErrorKind> {
    let source = build_source(transport, host, account)?;
    let a = source.addresses().ok_or(ErrorKind::NotAuthenticated)?;
    let clean = swiftly_rules::trim_whitespaces_and_newlines(term).to_owned();
    if !search_term_fits(&clean) {
        return Ok("[]".into());
    }
    let found = match &source {
        Source::Jellyfin(c) => {
            let main = c.search(&clean, 40).await?;
            swiftly_library::client_ext::items_in_times(&**c, &main, false, None).await
        }
        Source::Plex(c) => MediaServer::search(&**c, &clean, 40).await?,
    };
    // Jellyfin's client sorts "by name", as in the libraries (natural order), instead of the server's order; the Plex client
    // keeps the order of the hubs (movies, then series), so the old answer for Plex is that order.
    let found = match (
        &source,
        swiftly_rules::natural_order::NaturalCollator::new(host.locale.language()),
    ) {
        (Source::Jellyfin(_), Ok(c)) => {
            swiftly_rules::natural_order::NaturalOrder::sorted(found, &c, |i| {
                (i.name.as_str(), i.sort_name.as_deref())
            })
        }
        _ => found,
    };
    let words = Words::new(host.locale.clone());
    let text = TitleText::new(host.locale.clone());
    let tiles: Vec<LegacyGridTile> = ListRules::without_double(&found)
        .iter()
        .map(|i| {
            let mut tile = grid_tile_sorted(i, &a, &words, Sorting::Name);
            tile.subline = Some(hit_info(i, &words, &text));
            tile.letter = None;
            tile
        })
        .collect();
    serde_json::to_string(&tiles).map_err(|e| ErrorKind::Decoding(e.to_string()))
}

// ---- the TV keyboard ------------------------------------------------------------------------------------------------

const COLUMNS: usize = 6;
const LETTERS: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\u{c4}\u{d6}\u{dc}\u{df}1234567890-";

#[derive(Serialize)]
struct Key {
    kind: &'static str,
    character: String,
    span: usize,
}

fn letter_key(c: char) -> Key {
    Key {
        kind: "letter",
        character: c.to_string(),
        span: 1,
    }
}

/// `SearchKeys.rows(speech:)` as `[[{"character","kind","span"}]]`.
pub fn search_key_rows(speech: bool) -> String {
    let letters: Vec<char> = LETTERS.chars().collect();
    let mut rows: Vec<Vec<Key>> = Vec::new();
    let mut i = 0;
    while i + COLUMNS <= 30 {
        rows.push(
            letters[i..i + COLUMNS]
                .iter()
                .copied()
                .map(letter_key)
                .collect(),
        );
        i += COLUMNS;
    }
    rows.push(letters[30..36].iter().copied().map(letter_key).collect());
    let mut last: Vec<Key> = letters[36..41].iter().copied().map(letter_key).collect();
    last.push(Key {
        kind: "space",
        character: String::new(),
        span: 1,
    });
    rows.push(last);
    rows.push(if speech {
        vec![
            Key {
                kind: "delete",
                character: String::new(),
                span: 3,
            },
            Key {
                kind: "speak",
                character: String::new(),
                span: 3,
            },
        ]
    } else {
        vec![Key {
            kind: "delete",
            character: String::new(),
            span: COLUMNS,
        }]
    });
    // Swift writes the keys with sorted keys (`encoded`).
    serde_json::to_value(rows)
        .map(|v| v.to_string())
        .unwrap_or_else(|_| "[]".into())
}

/// `SearchKeys.typed`: a capital at the start of a word, lower case otherwise (core: `swiftly_rules::search_keys`).
pub fn search_key_typed(character: &str, term: &str) -> String {
    swiftly_rules::search_keys::typed(character, term)
}

/// `SearchKeys.spaceFits`.
pub fn search_key_space_fits(term: &str) -> bool {
    swiftly_rules::search_keys::space_fits(term)
}

/// `SearchKeys.withSpace`.
pub fn search_key_space(term: &str) -> String {
    swiftly_rules::search_keys::with_space(term)
}

/// `SearchKeys.withoutLast`.
pub fn search_key_delete(term: &str) -> String {
    swiftly_rules::search_keys::without_last(term)
}

/// `SearchKeys.hardware`.
pub fn search_key_hardware(text: &str, term: &str) -> String {
    swiftly_rules::search_keys::hardware(text, term)
}

/// `SearchGroups.showsTitles`: block titles only stand when more than one block is there.
pub fn search_titles_shown(series: i64, films: i64, requests: i64) -> bool {
    swiftly_rules::search_keys::shows_titles(series, films, requests)
}

/// `SearchScreen.state`: `history`, `start`, `loading`, `blank`, `hits`, `nothing` or `disrupted`.
pub fn search_screen_state(
    term: &str,
    history_count: i64,
    has_hits: bool,
    answered: bool,
    disrupted: bool,
    waited: bool,
) -> &'static str {
    swiftly_rules::search_keys::screen_state(
        term,
        history_count,
        has_hits,
        answered,
        disrupted,
        waited,
    )
}
