//! `SeasonSelectionRule` (Swift `SeriesState.swift:48-72`): which season is shown on opening.
//! The client calls `stateInSeries` / `stateInSeriesChecked` are in `client_ext`.

use crate::list_rules::canon;
use swiftly_model::Item;

/// `SeasonSelectionRule` namespace.
pub struct SeasonSelectionRule;

impl SeasonSelectionRule {
    /// Pure calculation, without a request (`choose(from:hintID:hintNumber:state:)`, :56-65).
    /// The hint (id, then number) wins over the state (season id, then season number); a
    /// season without a number never matches an empty number; else the first season.
    pub fn choose<'a>(
        list: &'a [Item],
        hint_id: Option<&str>,
        hint_number: Option<i64>,
        state: Option<&Item>,
    ) -> Option<&'a Item> {
        let by_number = |n: Option<i64>| {
            list.iter()
                .find(|s| s.index_number.is_some() && s.index_number == n)
        };
        // Swift compares ids by canonical equivalence (F-oracle-F03).
        let is = |wanted: Option<&str>, id: &str| {
            wanted.is_some_and(|w| w == id || canon(w) == canon(id))
        };
        list.iter()
            .find(|s| is(hint_id, &s.id))
            .or_else(|| by_number(hint_number))
            .or_else(|| {
                let sid = state.and_then(|s| s.season_id.as_deref());
                list.iter().find(|s| is(sid, &s.id))
            })
            .or_else(|| by_number(state.and_then(|s| s.parent_index_number)))
            .or_else(|| list.first())
    }

    /// Whether the state has to be fetched at all: only without a hint (:68-70).
    pub fn needs_state(hint_id: Option<&str>, hint_number: Option<i64>) -> bool {
        hint_id.is_none() && hint_number.is_none()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn season(id: &str, number: Option<i64>) -> Item {
        Item {
            index_number: number,
            ..Item::new(id, "Staffel", Some("Season"))
        }
    }
    fn episode(season_id: Option<&str>, number: Option<i64>) -> Item {
        Item {
            season_id: season_id.map(Into::into),
            parent_index_number: number,
            ..Item::new("f1", "Folge", Some("Episode"))
        }
    }
    fn all() -> Vec<Item> {
        vec![
            season("s1", Some(1)),
            season("s5", Some(5)),
            season("s6", Some(6)),
        ]
    }
    fn id(i: Option<&Item>) -> Option<&str> {
        i.map(|i| i.id.as_str())
    }

    #[test]
    fn hint_with_id_counts() {
        let a = all();
        assert_eq!(
            id(SeasonSelectionRule::choose(&a, Some("s5"), None, None)),
            Some("s5")
        );
    }
    #[test]
    fn without_id_the_number_counts() {
        let a = all();
        assert_eq!(
            id(SeasonSelectionRule::choose(&a, None, Some(6), None)),
            Some("s6")
        );
        assert_eq!(
            id(SeasonSelectionRule::choose(
                &a,
                Some("gibtsnicht"),
                Some(5),
                None
            )),
            Some("s5")
        );
    }
    #[test]
    fn without_hint_the_running_season() {
        let a = all();
        let state = episode(Some("s6"), Some(6));
        assert_eq!(
            id(SeasonSelectionRule::choose(&a, None, None, Some(&state))),
            Some("s6")
        );
    }
    #[test]
    fn state_without_id_uses_its_number() {
        let a = all();
        let state = episode(None, Some(5));
        assert_eq!(
            id(SeasonSelectionRule::choose(&a, None, None, Some(&state))),
            Some("s5")
        );
    }
    #[test]
    fn hint_number_beats_state_id() {
        let a = all();
        let state = episode(Some("s5"), Some(5));
        assert_eq!(
            id(SeasonSelectionRule::choose(&a, None, Some(6), Some(&state))),
            Some("s6")
        );
    }
    #[test]
    fn without_everything_the_first() {
        let a = all();
        assert_eq!(
            id(SeasonSelectionRule::choose(&a, None, None, None)),
            Some("s1")
        );
        assert_eq!(id(SeasonSelectionRule::choose(&[], None, None, None)), None);
    }
    #[test]
    fn state_only_without_hint() {
        assert!(SeasonSelectionRule::needs_state(None, None));
        assert!(!SeasonSelectionRule::needs_state(Some("s1"), None));
        assert!(!SeasonSelectionRule::needs_state(None, Some(1)));
    }
    #[test]
    fn season_without_number_matches_no_empty_hint() {
        let mut with_specials = vec![season("sp", None)];
        with_specials.extend(all());
        assert_eq!(
            id(SeasonSelectionRule::choose(
                &with_specials,
                None,
                None,
                None
            )),
            Some("sp")
        );
        assert_eq!(
            id(SeasonSelectionRule::choose(
                &with_specials,
                None,
                Some(5),
                None
            )),
            Some("s5")
        );
        let state = episode(None, None);
        assert_eq!(
            id(SeasonSelectionRule::choose(
                &with_specials,
                None,
                None,
                Some(&state)
            )),
            Some("sp")
        );
    }
}
