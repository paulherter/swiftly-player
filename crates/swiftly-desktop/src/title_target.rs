//! Which page a tapped tile opens, exactly as the Mac's `navigationDestination(for: Item.self)` in `MainView.swift`: a
//! Series opens the series page, an Episode opens its series at the episode's season (`SeasonTarget`; there is no
//! page for a single episode), and everything else (a Movie, a Season, a Playlist...) opens the item page of the tile
//! itself. The Mac's Home rows never contain a Season tile (`last_added` groups episodes per series in the shared core).

use swiftly_vm::{SeriesSpec, Tile};

/// The page a tile leads to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    /// The series page (else the movie page).
    pub series: bool,
    /// Id of the title whose page opens (the series for an episode or a season).
    pub id: String,
    /// Its name, as far as the tile knows it (the page loads the real one).
    pub name: String,
    /// The server `Type` of the title whose page opens.
    pub kind: String,
    /// Where the series page starts.
    pub spec: SeriesSpec,
}

/// The page for `tile`.
#[must_use]
pub fn target_of(tile: &Tile) -> Target {
    let kind = tile.facts.kind.as_deref().unwrap_or_default();
    let is = |k: &str| kind.eq_ignore_ascii_case(k);
    let from = tile.facts.series_id.clone().filter(|_| is("Episode"));
    if let Some(series) = from {
        return Target {
            series: true,
            id: series,
            name: tile.title.clone(),
            kind: "Series".into(),
            spec: SeriesSpec {
                start_season_id: tile.facts.season_id.clone(),
                start_season_number: tile.facts.season_number.map(i64::from),
            },
        };
    }
    Target {
        series: is("Series"),
        id: tile.id.clone(),
        name: tile.title.clone(),
        kind: kind.to_owned(),
        spec: SeriesSpec::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_vm::TileFacts;

    fn tile(id: &str, kind: &str, facts: TileFacts) -> Tile {
        Tile {
            id: id.into(),
            title: "Hafenlichter".into(),
            subtitle: None,
            progress: None,
            image: None,
            badges: Vec::new(),
            remaining: None,
            facts: TileFacts {
                kind: Some(kind.into()),
                ..facts
            },
        }
    }

    #[test]
    fn an_episode_opens_its_series_at_its_season() {
        let t = tile(
            "e7",
            "Episode",
            TileFacts {
                series_id: Some("s1".into()),
                season_id: Some("se5".into()),
                season_number: Some(5),
                episode_number: Some(7),
                ..TileFacts::default()
            },
        );
        let target = target_of(&t);
        assert!(target.series);
        assert_eq!((target.id.as_str(), target.kind.as_str()), ("s1", "Series"));
        assert_eq!(target.name, "Hafenlichter");
        assert_eq!(target.spec.start_season_id.as_deref(), Some("se5"));
        assert_eq!(target.spec.start_season_number, Some(5));
    }

    #[test]
    fn a_season_opens_its_own_item_page_like_the_mac() {
        let t = tile(
            "se5",
            "Season",
            TileFacts {
                series_id: Some("s1".into()),
                episode_number: Some(5),
                ..TileFacts::default()
            },
        );
        let target = target_of(&t);
        assert!(!target.series);
        assert_eq!(
            (target.id.as_str(), target.kind.as_str()),
            ("se5", "Season")
        );
        assert_eq!(target.spec, SeriesSpec::default());
    }

    #[test]
    fn movies_and_series_open_themselves() {
        let movie = target_of(&tile("m1", "Movie", TileFacts::default()));
        assert!(!movie.series);
        assert_eq!((movie.id.as_str(), movie.kind.as_str()), ("m1", "Movie"));
        let series = target_of(&tile("s1", "Series", TileFacts::default()));
        assert!(series.series);
        assert_eq!(series.id, "s1");
        assert_eq!(series.spec, SeriesSpec::default());
    }

    #[test]
    fn an_episode_without_a_series_id_falls_back_to_itself() {
        let target = target_of(&tile("e1", "Episode", TileFacts::default()));
        assert!(!target.series);
        assert_eq!(target.id, "e1");
    }
}
