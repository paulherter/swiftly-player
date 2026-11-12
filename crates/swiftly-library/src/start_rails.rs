//! Which rows the home page has, and in which order (Swift `StartRails.swift`).

use std::collections::HashSet;

use crate::library_filter::Sorting;

/// A home row (`StartRail`, :10-23).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StartRail {
    /// `weiterschauen`.
    ContinueWatching,
    /// `naechsteFolge`.
    NextEpisode,
    /// `neueFilme`.
    NewMovies,
    /// `neueSerien`.
    NewSeries,
    /// `neuzugaenge`.
    NewArrivals,
}

impl StartRail {
    /// All rows in their basic order (`CaseIterable`).
    pub const ALL: [Self; 5] = [
        Self::ContinueWatching,
        Self::NextEpisode,
        Self::NewMovies,
        Self::NewSeries,
        Self::NewArrivals,
    ];

    /// The stored raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::ContinueWatching => "weiterschauen",
            Self::NextEpisode => "naechsteFolge",
            Self::NewMovies => "neueFilme",
            Self::NewSeries => "neueSerien",
            Self::NewArrivals => "neuzugaenge",
        }
    }
    /// `StartRail(rawValue:)`.
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|r| r.raw_value() == raw)
    }
    /// Whether the row currently exists: new movies and series separately, otherwise the
    /// combined one (`fits(disconnected:)`, :23-29).
    pub fn fits(self, disconnected: bool) -> bool {
        match self {
            Self::NewArrivals => !disconnected,
            Self::NewMovies | Self::NewSeries => disconnected,
            _ => true,
        }
    }
    /// The name in the settings list; German, because German is the catalog key (:36-43).
    pub fn lists_name(self) -> &'static str {
        match self {
            Self::ContinueWatching => "Weiterschauen",
            Self::NextEpisode => "Nächste Folge",
            Self::NewMovies => "Neue Filme",
            Self::NewSeries => "Neue Serien",
            Self::NewArrivals => "Neu hinzugefügt",
        }
    }
    /// The icon in the settings list, Adwaita names (:48-55).
    pub fn symbol_text(self) -> &'static str {
        match self {
            Self::ContinueWatching => "media-playback-start-symbolic",
            Self::NextEpisode => "media-skip-forward-symbolic",
            Self::NewMovies => "video-x-generic-symbolic",
            Self::NewSeries => "tv-symbolic",
            Self::NewArrivals => "starred-symbolic",
        }
    }
    /// The heading above the row on the home page itself (:58-65).
    pub fn rails_title(self) -> &'static str {
        match self {
            Self::ContinueWatching => "Weiterschauen",
            Self::NextEpisode => "Nächste Folge",
            Self::NewMovies => "Zuletzt hinzugefügte Filme",
            Self::NewSeries => "Zuletzt hinzugefügte Serien",
            Self::NewArrivals => "Zuletzt hinzugefügt",
        }
    }
    /// Where the heading of the row leads, `None` for a row with no library of its own (:75-80).
    pub fn library_jump(self) -> Option<LibraryJump> {
        match self {
            Self::NewMovies => Some(LibraryJump {
                art: "movies",
                sorting: Sorting::Latest,
            }),
            Self::NewSeries => Some(LibraryJump {
                art: "tvshows",
                sorting: Sorting::Latest,
            }),
            _ => None,
        }
    }
}

/// A library page to open, and the order to open it in (:86-98).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LibraryJump {
    /// `movies` or `tvshows`.
    pub art: &'static str,
    /// The order to set on the page.
    pub sorting: Sorting,
}

/// How the configured order is read and saved (`StartRailsEpisode`, :107-155).
pub struct StartRailsEpisode;

impl StartRailsEpisode {
    /// The effective order: what is stored (unknown names dropped, each row once, the first
    /// entry counts), followed by everything missing from it (:126-130).
    pub fn applicable(stored: &[String]) -> Vec<StartRail> {
        let known = Self::clean(
            &stored
                .iter()
                .filter_map(|s| StartRail::from_raw(s))
                .collect::<Vec<_>>(),
        );
        let mut out = known.clone();
        out.extend(StartRail::ALL.into_iter().filter(|r| !known.contains(r)));
        out
    }

    /// Each row exactly once, in the order of first occurrence (:139-142).
    pub fn clean(rails: &[StartRail]) -> Vec<StartRail> {
        let mut watched = HashSet::new();
        rails
            .iter()
            .copied()
            .filter(|r| watched.insert(*r))
            .collect()
    }

    /// What ends up on the page: in order, without the hidden ones and those that do not
    /// currently exist (:146-150).
    pub fn visible(
        stored: &[String],
        from: &HashSet<String>,
        disconnected: bool,
    ) -> Vec<StartRail> {
        Self::applicable(stored)
            .into_iter()
            .filter(|r| !from.contains(r.raw_value()) && r.fits(disconnected))
            .collect()
    }

    /// Moves a row by `step` positions within the visible ones; unchanged at the edge (:152-165).
    /// Swift's `shifted(_:um:...)`.
    pub fn shifted(
        was: StartRail,
        step: i64,
        stored: &[String],
        disconnected: bool,
    ) -> Vec<String> {
        let applicable = Self::applicable(stored);
        let mut visible: Vec<StartRail> = applicable
            .iter()
            .copied()
            .filter(|r| r.fits(disconnected))
            .collect();
        let Some(from) = visible.iter().position(|r| *r == was) else {
            return stored.to_vec();
        };
        let Some(to) = i64::try_from(from)
            .ok()
            .and_then(|f| usize::try_from(f + step).ok())
        else {
            return stored.to_vec();
        };
        if to >= visible.len() {
            return stored.to_vec();
        }
        visible.swap(from, to);
        let invisible = applicable.iter().copied().filter(|r| !r.fits(disconnected));
        visible
            .into_iter()
            .chain(invisible)
            .map(|r| r.raw_value().to_string())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all() -> Vec<String> {
        StartRail::ALL
            .iter()
            .map(|r| r.raw_value().to_string())
            .collect()
    }
    fn s(list: &[&str]) -> Vec<String> {
        list.iter().map(|x| (*x).to_string()).collect()
    }
    fn raw(v: &[StartRail]) -> Vec<&'static str> {
        v.iter().map(|r| r.raw_value()).collect()
    }

    #[test]
    fn library_jump() {
        assert_eq!(
            StartRail::NewMovies.library_jump(),
            Some(LibraryJump {
                art: "movies",
                sorting: Sorting::Latest
            })
        );
        assert_eq!(
            StartRail::NewSeries.library_jump(),
            Some(LibraryJump {
                art: "tvshows",
                sorting: Sorting::Latest
            })
        );
        assert_eq!(StartRail::NewArrivals.library_jump(), None);
        assert_eq!(StartRail::ContinueWatching.library_jump(), None);
        assert_eq!(StartRail::NextEpisode.library_jump(), None);
    }
    #[test]
    fn empty_store_gives_basic_order() {
        assert_eq!(StartRailsEpisode::applicable(&[]), StartRail::ALL);
    }
    #[test]
    fn missing_rail_is_appended() {
        let old = s(&["neuzugaenge", "weiterschauen"]);
        let now = StartRailsEpisode::applicable(&old);
        assert_eq!(raw(&now[..2]), ["neuzugaenge", "weiterschauen"]);
        assert_eq!(now.iter().collect::<HashSet<_>>().len(), 5);
    }
    #[test]
    fn double_store_comes_back_once() {
        let broken = s(&[
            "weiterschauen",
            "naechsteFolge",
            "neueFilme",
            "neueFilme",
            "neueSerien",
            "neuzugaenge",
        ]);
        let now = StartRailsEpisode::applicable(&broken);
        assert_eq!(now.len(), 5);
        assert_eq!(
            raw(&now),
            [
                "weiterschauen",
                "naechsteFolge",
                "neueFilme",
                "neueSerien",
                "neuzugaenge"
            ]
        );
    }
    #[test]
    fn visible_and_shifted_carry_no_doubles() {
        let broken = s(&["neueFilme", "neueFilme", "weiterschauen"]);
        let v = StartRailsEpisode::visible(&broken, &HashSet::new(), true);
        assert_eq!(v.iter().filter(|r| **r == StartRail::NewMovies).count(), 1);
        let new = StartRailsEpisode::shifted(StartRail::ContinueWatching, -1, &broken, true);
        assert_eq!(new.len(), 5);
        assert_eq!(
            new.iter().collect::<HashSet<_>>(),
            all().iter().collect::<HashSet<_>>()
        );
    }
    #[test]
    fn clean_is_stable() {
        let once = StartRailsEpisode::clean(&[
            StartRail::NewMovies,
            StartRail::ContinueWatching,
            StartRail::NewMovies,
        ]);
        assert_eq!(once, [StartRail::NewMovies, StartRail::ContinueWatching]);
        assert_eq!(StartRailsEpisode::clean(&once), once);
    }
    #[test]
    fn unknown_names_are_dropped() {
        let now = StartRailsEpisode::applicable(&s(&["gibtsnicht", "weiterschauen"]));
        assert_eq!(now[0], StartRail::ContinueWatching);
        assert_eq!(now.len(), 5);
    }
    #[test]
    fn disconnected_shows_the_pair() {
        let with = StartRailsEpisode::visible(&all(), &HashSet::new(), true);
        assert!(with.contains(&StartRail::NewMovies) && with.contains(&StartRail::NewSeries));
        assert!(!with.contains(&StartRail::NewArrivals));
        let without = StartRailsEpisode::visible(&all(), &HashSet::new(), false);
        assert!(without.contains(&StartRail::NewArrivals));
        assert!(
            !without.contains(&StartRail::NewMovies) && !without.contains(&StartRail::NewSeries)
        );
    }
    #[test]
    fn hidden_is_not_on_the_page() {
        let hidden: HashSet<String> = ["weiterschauen".to_string()].into();
        let v = StartRailsEpisode::visible(&all(), &hidden, false);
        assert!(!v.contains(&StartRail::ContinueWatching));
        assert!(v.contains(&StartRail::NextEpisode));
    }
    #[test]
    fn move_swaps_neighbours() {
        let new = StartRailsEpisode::shifted(StartRail::NextEpisode, -1, &all(), false);
        assert_eq!(
            StartRailsEpisode::applicable(&new)[0],
            StartRail::NextEpisode
        );
    }
    #[test]
    fn at_the_edge_nothing_moves() {
        assert_eq!(
            StartRailsEpisode::shifted(StartRail::ContinueWatching, -1, &all(), false),
            all()
        );
    }
    #[test]
    fn invisible_rails_do_not_count_when_moving() {
        let new = StartRailsEpisode::shifted(StartRail::NewArrivals, -1, &all(), false);
        let v = StartRailsEpisode::visible(&new, &HashSet::new(), false);
        assert_eq!(raw(&v), ["weiterschauen", "neuzugaenge", "naechsteFolge"]);
        assert_eq!(
            StartRailsEpisode::applicable(&new)
                .into_iter()
                .collect::<HashSet<_>>()
                .len(),
            5
        );
    }
    #[test]
    fn list_name_differs_from_title() {
        assert_eq!(StartRail::NewMovies.lists_name(), "Neue Filme");
        assert_eq!(
            StartRail::NewMovies.rails_title(),
            "Zuletzt hinzugefügte Filme"
        );
        assert_eq!(
            StartRail::ContinueWatching.lists_name(),
            StartRail::ContinueWatching.rails_title()
        );
    }
}
