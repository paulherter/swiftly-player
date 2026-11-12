//! One work, one entry, even if it lives in two libraries
//! (JellyfinKit/Items.swift, the pure part; the `JellyfinClient` extensions
//! that fetch the missing facts are not ported).

use std::collections::{HashMap, HashSet};

use crate::item::Item;

/// Provider ids of a series, by series id (Items.swift:42). An episode does
/// not carry its series' ids, only its series id.
pub type SeriesNumber = HashMap<String, HashMap<String, String>>;

/// Namespace of the merge rules (Items.swift:30, Swift `enum Items`).
///
/// Same means sharing a provider id (TMDb, IMDb, TVDb). Without ids nothing
/// is merged. One shared id is enough. The winner moves to the place of the
/// copy that came first.
#[derive(Debug, Clone, Copy)]
pub struct Items;

/// The providers, in order of precedence (Items.swift:33).
const PROVIDER: [&str; 3] = ["Tmdb", "Imdb", "Tvdb"];

/// `.whitespaces` of Foundation: horizontal white space only.
fn is_horizontal_space(c: char) -> bool {
    c.is_whitespace()
        && !matches!(
            c,
            '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
        )
}

fn serial_numbers(ids: Option<&HashMap<String, String>>, prefix: &str) -> Vec<String> {
    PROVIDER
        .iter()
        .filter_map(|a| {
            let nr = ids?.get(*a)?.trim_matches(is_horizontal_space);
            (!nr.is_empty()).then(|| format!("{prefix}:{}:{}", a.to_lowercase(), nr.to_lowercase()))
        })
        .collect()
}

/// Case- and diacritic-insensitive key for series names (Items.swift:169).
/// Foundation folds with Unicode data; this covers the Latin letters that
/// decompose into base letter plus mark (not `ø`, `ł`, `đ` and friends, which
/// Foundation keeps too).
fn fold(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .map(|c| match c {
            'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => 'a',
            'ç' | 'ć' | 'ĉ' | 'ċ' | 'č' => 'c',
            'ď' => 'd',
            'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => 'e',
            'ĝ' | 'ğ' | 'ġ' | 'ģ' => 'g',
            'ĥ' => 'h',
            'ì' | 'í' | 'î' | 'ï' | 'ĩ' | 'ī' | 'ĭ' | 'į' => 'i',
            'ĵ' => 'j',
            'ķ' => 'k',
            'ĺ' | 'ļ' | 'ľ' => 'l',
            'ñ' | 'ń' | 'ņ' | 'ň' => 'n',
            'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ō' | 'ŏ' | 'ő' => 'o',
            'ŕ' | 'ŗ' | 'ř' => 'r',
            'ś' | 'ŝ' | 'ş' | 'š' => 's',
            'ţ' | 'ť' => 't',
            'ù' | 'ú' | 'û' | 'ü' | 'ũ' | 'ū' | 'ŭ' | 'ů' | 'ű' | 'ų' => 'u',
            'ŵ' => 'w',
            'ý' | 'ÿ' | 'ŷ' => 'y',
            'ź' | 'ż' | 'ž' => 'z',
            other => other,
        })
        .collect::<String>()
        .trim_matches(is_horizontal_space)
        .to_string()
}

impl Items {
    /// What identifies an entry as a work. Empty: never merge (Items.swift:46).
    /// With `episodes_per_series` an episode counts as its series (for
    /// "Recently Added").
    pub fn traits(
        item: &Item,
        series_list: &SeriesNumber,
        episodes_per_series: bool,
    ) -> Vec<String> {
        match item.type_.as_deref() {
            Some("Movie") => serial_numbers(item.provider_ids.as_ref(), "film"),
            Some("Series") => serial_numbers(item.provider_ids.as_ref(), "serie"),
            Some("Episode") => {
                let Some(series) = &item.series_id else {
                    return Vec::new();
                };
                if episodes_per_series {
                    return serial_numbers(series_list.get(series), "serie");
                }
                let (Some(season), Some(episode)) = (item.parent_index_number, item.index_number)
                else {
                    return Vec::new();
                };
                serial_numbers(
                    series_list.get(series),
                    &format!("folge:{season}:{episode}"),
                )
            }
            _ => Vec::new(),
        }
    }

    /// Which entries are the same work: per group the positions in the list,
    /// ascending. Entries without a duplicate form a group of their own.
    /// Groups are ordered by their first entry (Items.swift:76).
    pub fn groups(
        items: &[Item],
        series_list: &SeriesNumber,
        episodes_per_series: bool,
    ) -> Vec<Vec<usize>> {
        let mut parent: Vec<usize> = (0..items.len()).collect();
        fn root(parent: &mut [usize], mut i: usize) -> usize {
            while parent[i] != i {
                parent[i] = parent[parent[i]];
                i = parent[i];
            }
            i
        }
        let mut first_one: HashMap<String, usize> = HashMap::new();
        for (i, item) in items.iter().enumerate() {
            for m in Self::traits(item, series_list, episodes_per_series) {
                if let Some(&j) = first_one.get(&m) {
                    let (a, b) = (root(&mut parent, i), root(&mut parent, j));
                    if a != b {
                        parent[a.max(b)] = a.min(b);
                    }
                } else {
                    first_one.insert(m, i);
                }
            }
        }
        let mut by_root: HashMap<usize, Vec<usize>> = HashMap::new();
        let mut order: Vec<usize> = Vec::new();
        for i in 0..items.len() {
            let w = root(&mut parent, i);
            let group = by_root.entry(w).or_default();
            if group.is_empty() {
                order.push(w);
            }
            group.push(i);
        }
        order
            .into_iter()
            .filter_map(|w| by_root.remove(&w))
            .collect()
    }

    /// Whether there is anything to merge in the list at all (Items.swift:105).
    pub fn has_double(
        items: &[Item],
        series_list: &SeriesNumber,
        episodes_per_series: bool,
    ) -> bool {
        Self::groups(items, series_list, episodes_per_series)
            .iter()
            .any(|g| g.len() > 1)
    }

    /// Rank of an entry by its library; smaller is better (Items.swift:117).
    /// Unknown origin goes last.
    pub fn rank(item: &Item, origin: &HashMap<String, String>, libraries: &[Item]) -> (i64, i64) {
        let spot = origin
            .get(&item.id)
            .and_then(|from| libraries.iter().position(|l| &l.id == from));
        let Some(spot) = spot else {
            return (2, i64::MAX);
        };
        let kind = libraries[spot]
            .collection_type
            .as_deref()
            .map(str::to_lowercase);
        let tier = if matches!(kind.as_deref(), Some("movies" | "tvshows")) {
            0
        } else {
            1
        };
        (tier, spot as i64)
    }

    /// Whether the entry has any watch state (Items.swift:125).
    pub fn has_status(item: &Item) -> bool {
        let Some(d) = &item.user_data else {
            return false;
        };
        d.playback_position_ticks.unwrap_or(0) > 0
            || d.played == Some(true)
            || d.last_played_date.is_some()
    }

    /// One entry per work, at the position of its first occurrence
    /// (Items.swift:140). Winner: library tier, then library order, then
    /// watch state, then the earlier entry.
    pub fn merge(
        items: &[Item],
        origin: &HashMap<String, String>,
        libraries: &[Item],
        series_list: &SeriesNumber,
        episodes_per_series: bool,
    ) -> Vec<Item> {
        Self::groups(items, series_list, episodes_per_series)
            .into_iter()
            .filter_map(|group| {
                // Strict "less" keeps the first minimal element, like Swift's `min(by:)`.
                let less = |a: usize, b: usize| {
                    let (ra, rb) = (
                        Self::rank(&items[a], origin, libraries),
                        Self::rank(&items[b], origin, libraries),
                    );
                    if ra != rb {
                        return ra < rb;
                    }
                    let (sa, sb) = (Self::has_status(&items[a]), Self::has_status(&items[b]));
                    if sa != sb {
                        return sa;
                    }
                    a < b
                };
                let mut best = *group.first()?;
                for &candidate in &group[1..] {
                    if less(candidate, best) {
                        best = candidate;
                    }
                }
                Some(items[best].clone())
            })
            .collect()
    }

    /// The entries whose origin matters: all that have a duplicate (Items.swift:158).
    pub fn with_double(
        items: &[Item],
        series_list: &SeriesNumber,
        episodes_per_series: bool,
    ) -> Vec<Item> {
        Self::groups(items, series_list, episodes_per_series)
            .into_iter()
            .filter(|g| g.len() > 1)
            .flatten()
            .map(|i| items[i].clone())
            .collect()
    }

    /// Series ids whose episodes share a name under different ids, so it is
    /// worth fetching the series' provider ids (Items.swift:167). Pre-check by
    /// folded series name; the ids decide.
    pub fn series_suspicion(items: &[Item]) -> HashSet<String> {
        let mut by_name: HashMap<String, HashSet<String>> = HashMap::new();
        for i in items
            .iter()
            .filter(|i| i.type_.as_deref() == Some("Episode"))
        {
            let (Some(id), Some(name)) = (&i.series_id, &i.series_name) else {
                continue;
            };
            by_name.entry(fold(name)).or_default().insert(id.clone());
        }
        by_name
            .into_values()
            .filter(|ids| ids.len() > 1)
            .flatten()
            .collect()
    }
}
