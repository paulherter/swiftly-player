//! The home loader (Swift `HomePageLoader.swift`): the fetches that make up the home page, with
//! their fallback levels. One rule for all platforms.

use std::collections::HashSet;
use std::future::Future;

use futures_util::future::{join_all, join5};
use swiftly_model::Item;
use swiftly_net::ErrorKind;

use crate::list_rules::ListRules;
use crate::start_libraries::{StartLibraries, StartLibrary};

/// The fetches that make up the home page (`HomePageSource`, :8-27). A trait so the loader runs
/// without a server. `None` means "the fetch failed", never "empty".
pub trait HomePageSource: Send + Sync {
    /// Started titles (`resumeItems`, throws).
    fn resume_items(&self, limit: i64)
    -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    /// Next unwatched episodes (`nextUp`, throws).
    fn next_up(&self, limit: i64) -> impl Future<Output = Result<Vec<Item>, ErrorKind>> + Send;
    /// Recently added titles of a library (`library` `None`: all), mixed movies and episodes.
    fn last_added(
        &self,
        library: Option<&str>,
        fetch: i64,
        show_item: i64,
    ) -> impl Future<Output = Option<Vec<Item>>> + Send;
    /// New titles of a genre (`title(genre:limit:)`).
    fn title(&self, genre: &str, limit: i64) -> impl Future<Output = Option<Vec<Item>>> + Send;
    /// The account's libraries, or `None` if the fetch failed.
    fn libraries(&self) -> impl Future<Output = Option<Vec<Item>>> + Send;
    /// New additions across all libraries, only of this kind (`Movie`, `Episode`).
    fn new_arrivals(
        &self,
        genre: &str,
        fetch: i64,
        show_item: i64,
    ) -> impl Future<Output = Option<Vec<Item>>> + Send;
    /// The most recently updated series themselves (`IncludeItemTypes=Series`).
    fn new_series(
        &self,
        library: Option<&str>,
        show_item: i64,
    ) -> impl Future<Output = Option<Vec<Item>>> + Send;
    /// The newest titles of one library or collection; `None` if the fetch failed. Default: `None`.
    fn latest_title(
        &self,
        _library: &str,
        _collection: bool,
        _show_item: i64,
    ) -> impl Future<Output = Option<Vec<Item>>> + Send {
        async { None }
    }
    /// Whether `new_arrivals` merges all libraries of a kind by time. Default: no.
    fn merges_libraries(&self) -> bool {
        false
    }
    /// The fallback log (`LogRing.shared.append`). Default: nothing.
    fn log(&self, _line: &str) {}
}

/// A genre row (`Home.GenreRail`).
#[derive(Debug, Clone, PartialEq)]
pub struct GenreRail {
    /// Genre name.
    pub name: String,
    /// Titles.
    pub items: Vec<Item>,
}

/// A chosen library or collection as a row (`Home.LibraryRail`).
#[derive(Debug, Clone, PartialEq)]
pub struct LibraryRail {
    /// Library id.
    pub id: String,
    /// Library name.
    pub name: String,
    /// Titles.
    pub items: Vec<Item>,
}

/// What is on the home page, ready before any UI sees it (`Home`, :64-91). `None` means "the
/// fetch failed", not "empty".
#[derive(Debug, Clone, PartialEq)]
pub struct Home {
    /// Continue watching.
    pub continue_watching: Option<Vec<Item>>,
    /// Next episode.
    pub next_episode: Option<Vec<Item>>,
    /// The shared new-additions row, only if not split.
    pub recent: Option<Vec<Item>>,
    /// New movies (split).
    pub new_movies: Option<Vec<Item>>,
    /// New series (split).
    pub new_series: Option<Vec<Item>>,
    /// Genre rows.
    pub genre_rails: Vec<GenreRail>,
    /// Nothing arrived: no continue watching, no next up, no new items.
    pub disrupted: bool,
    /// Why the two throwing fetches (continue watching, next up) failed, the first one's reason; `None` when
    /// neither failed. Lets the page tell "unreachable" from "refused" and "server error".
    pub failure: Option<swiftly_net::ErrorTopic>,
}

/// `HomeLoader.LoadRequest` (:100-130).
#[derive(Debug, Clone, PartialEq)]
pub struct LoadRequest {
    /// New movies and new series separately (`newAccessDisconnected`).
    pub disconnected: bool,
    /// Chosen movie library.
    pub film_library: Option<String>,
    /// Chosen series library.
    pub series_library: Option<String>,
    /// `None` if genres are shown as chips on top; then there are no rows.
    pub genres: Option<Vec<String>>,
    /// What was last in "continue watching".
    pub until_from_continue_watching: Vec<Item>,
}

impl LoadRequest {
    /// `init(disconnected:...)`: the section choice also stores "All", "Collections" and
    /// "Playlists" under the library name; none of them is a library (:106-113).
    pub fn new(disconnected: bool) -> Self {
        Self {
            disconnected,
            film_library: None,
            series_library: None,
            genres: None,
            until_from_continue_watching: Vec::new(),
        }
    }
    /// Sets the movie library, dropping the pseudo values.
    #[must_use]
    pub fn film_library(mut self, stored: Option<&str>) -> Self {
        self.film_library = library(stored);
        self
    }
    /// Sets the series library, dropping the pseudo values.
    #[must_use]
    pub fn series_library(mut self, stored: Option<&str>) -> Self {
        self.series_library = library(stored);
        self
    }
}

fn library(stored: Option<&str>) -> Option<String> {
    stored
        .filter(|s| !["", "alle", "sammlungen", "wiedergabelisten"].contains(s))
        .map(String::from)
}

/// `HomeLoader` namespace.
pub struct HomeLoader;

const SHOW: i64 = 24;
const FETCH: i64 = 200;

fn count_text(list: &Option<Vec<Item>>) -> String {
    list.as_ref().map_or_else(
        || "kam nicht durch".to_string(),
        |l| format!("{} Titel", l.len()),
    )
}

impl HomeLoader {
    /// The genre rows on their own, fetched all at once; the order comes from `names`, empty
    /// ones drop out, without duplicates (:141-155).
    pub async fn genre_rails(source: &impl HomePageSource, names: &[String]) -> Vec<GenreRail> {
        let fetched = join_all(names.iter().map(|n| source.title(n, 24))).await;
        names
            .iter()
            .zip(fetched)
            .filter_map(|(name, title)| {
                let title = title.filter(|t| !t.is_empty())?;
                Some(GenreRail {
                    name: name.clone(),
                    items: ListRules::without_double(&title),
                })
            })
            .collect()
    }

    /// The chosen libraries as rows, all at once, in the chosen order; a failed or empty one
    /// drops out silently (:165-182).
    pub async fn library_rails(
        source: &impl HomePageSource,
        choice: &[StartLibrary],
    ) -> Vec<LibraryRail> {
        let choice = StartLibraries::clean(choice);
        let fetched = join_all(
            choice
                .iter()
                .map(|w| source.latest_title(&w.id, w.collection, SHOW)),
        )
        .await;
        choice
            .iter()
            .zip(fetched)
            .filter_map(|(w, title)| {
                let title = title.filter(|t| !t.is_empty())?;
                Some(LibraryRail {
                    id: w.id.clone(),
                    name: w.name.clone(),
                    items: ListRules::without_double(&title),
                })
            })
            .collect()
    }

    /// A split new-additions row: the library first, never silently empty (:207-246).
    async fn new_row(
        source: &impl HomePageSource,
        library: Option<&str>,
        art: &str,
    ) -> Option<Vec<Item>> {
        if art != "tvshows" {
            let fetched = Self::new_levels(source, library, art).await;
            if art != "movies" {
                return fetched;
            }
            return fetched.map(|f| {
                f.into_iter()
                    .filter(|i| {
                        !matches!(i.type_.as_deref(), Some("Episode" | "Series" | "Season"))
                    })
                    .collect()
            });
        }
        // The series row asks for series, not libraries.
        if let Some(lib) = library
            && let Some(fetched) = source
                .new_series(Some(lib), SHOW)
                .await
                .filter(|f| !f.is_empty())
        {
            return Some(fetched);
        }
        let series_list = source.new_series(None, SHOW).await;
        if let Some(list) = series_list.as_ref().filter(|l| !l.is_empty()) {
            source.log(&format!(
                "Startseite: Neu tvshows: Serien-Abfrage (Series, DateLastContentAdded), {} Titel",
                list.len()
            ));
            return series_list;
        }
        let rung = if series_list.is_none() {
            "kam nicht durch"
        } else {
            "leer"
        };
        let rest = Self::new_levels(source, library, art).await.map(|r| {
            r.into_iter()
                .filter(|i| i.type_.as_deref() != Some("Movie"))
                .collect::<Vec<_>>()
        });
        source.log(&format!(
            "Startseite: Neu tvshows: Serien-Abfrage {rung}; Rueckfall ueber Bibliotheken/Folgen ohne Filme: {}",
            count_text(&rest)
        ));
        rest
    }

    /// The library levels of a split row (`newLevels`, :248-295).
    async fn new_levels(
        source: &impl HomePageSource,
        library: Option<&str>,
        art: &str,
    ) -> Option<Vec<Item>> {
        let reason: String;
        if let Some(lib) = library {
            let fetched = source.last_added(Some(lib), FETCH, SHOW).await;
            if let Some(f) = fetched.as_ref().filter(|f| !f.is_empty()) {
                return Some(f.clone());
            }
            reason = if fetched.is_none() {
                "Abruf der gewaehlten Bibliothek kam nicht durch".into()
            } else {
                "gewaehlte Bibliothek ohne Neuzugaenge".into()
            };
        } else if let Some(all) = source.libraries().await {
            let matches: Vec<&Item> = all
                .iter()
                .filter(|i| {
                    i.collection_type
                        .as_deref()
                        .map(str::to_lowercase)
                        .as_deref()
                        == Some(art)
                })
                .collect();
            // Several libraries of the kind and none chosen: all of them, merged.
            if matches.len() > 1
                && art == "movies"
                && source.merges_libraries()
                && let Some(every) = source
                    .new_arrivals("Movie", FETCH, SHOW)
                    .await
                    .filter(|e| !e.is_empty())
            {
                return Some(every);
            }
            let mut empty = 0;
            for candidate in &matches {
                if let Some(fetched) = source.last_added(Some(&candidate.id), FETCH, SHOW).await {
                    if !fetched.is_empty() {
                        return Some(fetched);
                    }
                    empty += 1;
                }
            }
            reason = if matches.is_empty() {
                let kinds: Vec<&str> = all
                    .iter()
                    .map(|i| i.collection_type.as_deref().unwrap_or("ohne"))
                    .collect();
                format!(
                    "keine Bibliothek der Art ({} Bibliotheken: {})",
                    all.len(),
                    kinds.join(",")
                )
            } else {
                format!(
                    "{} Bibliothek(en) der Art, {empty} leer, Rest nicht erreichbar",
                    matches.len()
                )
            };
        } else {
            reason = "Bibliotheksliste nicht lesbar".into();
        }
        let genre = if art == "movies" { "Movie" } else { "Episode" };
        let only_genre = source.new_arrivals(genre, FETCH, SHOW).await;
        if let Some(og) = only_genre.as_ref().filter(|g| !g.is_empty()) {
            source.log(&format!(
                "Startseite: Neu {art}: {reason}; Rueckfall ohne Bibliothek ({genre}), {} Titel",
                og.len()
            ));
            return only_genre;
        }
        let mixed = source.last_added(None, FETCH, SHOW).await;
        let level1 = if only_genre.is_none() {
            "kam nicht durch"
        } else {
            "leer"
        };
        source.log(&format!(
            "Startseite: Neu {art}: {reason}; Rueckfall {genre} {level1}; gemischt wie 1.0.4: {}",
            count_text(&mixed)
        ));
        mixed.or(only_genre)
    }

    /// Loads the home page (`load(from:_:)`, :297-330). The five first fetches run side by
    /// side; the genre rows are fetched afterwards from `wish.genres`.
    pub async fn load(source: &impl HomePageSource, wish: &LoadRequest) -> Home {
        let disconnected = wish.disconnected;
        let (begun, next, shared, movies, series_list) = join5(
            async { source.resume_items(20).await },
            async { source.next_up(20).await },
            async {
                if disconnected {
                    None
                } else {
                    source.last_added(None, FETCH, SHOW).await
                }
            },
            async {
                if disconnected {
                    Self::new_row(source, wish.film_library.as_deref(), "movies").await
                } else {
                    None
                }
            },
            async {
                if disconnected {
                    Self::new_row(source, wish.series_library.as_deref(), "tvshows").await
                } else {
                    None
                }
            },
        )
        .await;

        let failure = [&begun, &next]
            .into_iter()
            .find_map(|r| r.as_ref().err().map(swiftly_net::ErrorKind::topic));
        let (begun, next) = (begun.ok(), next.ok());

        let already_present: HashSet<&str> = begun
            .as_ref()
            .unwrap_or(&wish.until_from_continue_watching)
            .iter()
            .map(|i| i.id.as_str())
            .collect();
        let next_filtered = next.as_ref().map(|n| {
            n.iter()
                .filter(|i| !already_present.contains(i.id.as_str()))
                .cloned()
                .collect::<Vec<_>>()
        });

        let rails = Self::genre_rails(source, wish.genres.as_deref().unwrap_or(&[])).await;

        let new_present = if disconnected {
            movies.is_some() || series_list.is_some()
        } else {
            shared.is_some()
        };
        let dedupe = |l: &Option<Vec<Item>>| l.as_ref().map(|l| ListRules::without_double(l));
        Home {
            continue_watching: dedupe(&begun),
            next_episode: dedupe(&next_filtered),
            recent: dedupe(&shared),
            new_movies: dedupe(&movies),
            new_series: dedupe(&series_list),
            genre_rails: rails,
            disrupted: begun.is_none() && next_filtered.is_none() && !new_present,
            failure,
        }
    }
}

/// A scripted source for tests: the Swift test `Source` structs.
#[cfg(test)]
pub(crate) mod testing {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    /// Mirrors `HomePageLoaderTests.Source` (and the `StartLibrariesTests.Source`).
    #[derive(Default)]
    pub struct Source {
        pub proceed: Option<Vec<Item>>,
        pub next: Option<Vec<Item>>,
        pub new: HashMap<String, Vec<Item>>,
        pub genres: HashMap<String, Vec<Item>>,
        pub review: Option<Vec<Item>>,
        pub typed: HashMap<String, Vec<Item>>,
        pub series_list: HashMap<String, Vec<Item>>,
        pub latest: HashMap<String, Vec<Item>>,
        pub log: Mutex<Vec<String>>,
    }

    impl Source {
        pub fn base() -> Self {
            Self {
                proceed: Some(vec![]),
                next: Some(vec![]),
                review: Some(vec![]),
                ..Self::default()
            }
        }
        pub fn lines(&self) -> String {
            self.log.lock().map(|l| l.join("\n")).unwrap_or_default()
        }
    }

    impl HomePageSource for Source {
        async fn resume_items(&self, _limit: i64) -> Result<Vec<Item>, ErrorKind> {
            self.proceed.clone().ok_or(ErrorKind::Cancelled)
        }
        async fn next_up(&self, _limit: i64) -> Result<Vec<Item>, ErrorKind> {
            self.next.clone().ok_or(ErrorKind::Cancelled)
        }
        async fn last_added(&self, library: Option<&str>, _f: i64, _s: i64) -> Option<Vec<Item>> {
            self.new.get(library.unwrap_or("")).cloned()
        }
        async fn title(&self, genre: &str, _limit: i64) -> Option<Vec<Item>> {
            self.genres.get(genre).cloned()
        }
        async fn libraries(&self) -> Option<Vec<Item>> {
            self.review.clone()
        }
        async fn new_arrivals(&self, genre: &str, _f: i64, _s: i64) -> Option<Vec<Item>> {
            self.typed.get(genre).cloned().or_else(|| {
                self.new.get("").map(|l| {
                    l.iter()
                        .filter(|i| i.type_.as_deref() == Some(genre))
                        .cloned()
                        .collect()
                })
            })
        }
        async fn new_series(&self, library: Option<&str>, _s: i64) -> Option<Vec<Item>> {
            self.series_list.get(library.unwrap_or("")).cloned()
        }
        async fn latest_title(&self, library: &str, _c: bool, _s: i64) -> Option<Vec<Item>> {
            self.latest.get(library).cloned()
        }
        fn log(&self, line: &str) {
            if let Ok(mut l) = self.log.lock() {
                l.push(line.to_string());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::Source;
    use super::*;
    use futures_executor::block_on;
    use std::collections::HashMap;

    fn t(id: &str) -> Item {
        Item::new(id, id, None)
    }
    fn film(id: &str) -> Item {
        Item::new(id, id, Some("Movie"))
    }
    fn episode(id: &str) -> Item {
        Item::new(id, id, Some("Episode"))
    }
    fn lib(id: &str, name: &str, kind: Option<&str>) -> Item {
        Item {
            collection_type: kind.map(Into::into),
            ..Item::new(id, name, None)
        }
    }
    fn ids(v: &Option<Vec<Item>>) -> Option<Vec<&str>> {
        v.as_ref()
            .map(|l| l.iter().map(|i| i.id.as_str()).collect())
    }
    fn map(pairs: &[(&str, Vec<Item>)]) -> HashMap<String, Vec<Item>> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), v.clone()))
            .collect()
    }
    fn over_all() -> Vec<Item> {
        vec![film("f1"), episode("e1"), film("f2"), episode("e2")]
    }
    fn run(q: &Source, wish: &LoadRequest) -> Home {
        block_on(HomeLoader::load(q, wish))
    }

    #[test]
    fn next_without_started() {
        let q = Source {
            proceed: Some(vec![t("a")]),
            next: Some(vec![t("a"), t("b")]),
            ..Source::base()
        };
        assert_eq!(
            ids(&run(&q, &LoadRequest::new(false)).next_episode),
            Some(vec!["b"])
        );
    }
    #[test]
    fn next_against_previous_state() {
        let q = Source {
            proceed: None,
            next: Some(vec![t("a"), t("b")]),
            ..Source::base()
        };
        let mut wish = LoadRequest::new(false);
        wish.until_from_continue_watching = vec![t("a")];
        let s = run(&q, &wish);
        assert_eq!(s.continue_watching, None);
        assert_eq!(ids(&s.next_episode), Some(vec!["b"]));
    }
    #[test]
    fn disconnected_per_library_shared_one_row() {
        let q = Source {
            new: map(&[
                ("", vec![t("x")]),
                ("filme", vec![t("f")]),
                ("serien", vec![t("s")]),
            ]),
            ..Source::base()
        };
        let d = run(
            &q,
            &LoadRequest::new(true)
                .film_library(Some("filme"))
                .series_library(Some("serien")),
        );
        assert_eq!(d.recent, None);
        assert_eq!(ids(&d.new_movies), Some(vec!["f"]));
        assert_eq!(ids(&d.new_series), Some(vec!["s"]));
        let g = run(&q, &LoadRequest::new(false));
        assert_eq!(ids(&g.recent), Some(vec!["x"]));
        assert!(g.new_movies.is_none() && g.new_series.is_none());
    }
    #[test]
    fn disconnected_without_id_first_library_of_the_kind() {
        let q = Source {
            new: map(&[
                ("", vec![t("film")]),
                ("filme", vec![t("f")]),
                ("serien", vec![t("s")]),
                ("mix", vec![t("m")]),
            ]),
            review: Some(vec![
                lib("mix", "Gemischt", None),
                lib("filme", "Filme", Some("movies")),
                lib("serien", "Serien", Some("tvshows")),
            ]),
            ..Source::base()
        };
        let s = run(&q, &LoadRequest::new(true));
        assert_eq!(ids(&s.new_movies), Some(vec!["f"]));
        assert_eq!(ids(&s.new_series), Some(vec!["s"]));
    }
    #[test]
    fn only_mixed_libraries_fall_back_per_kind() {
        let q = Source {
            new: map(&[
                ("", over_all()),
                ("a", vec![film("x")]),
                ("b", vec![episode("y")]),
            ]),
            review: Some(vec![
                lib("a", "Medien", None),
                lib("b", "Mediathek", Some("mixed")),
            ]),
            ..Source::base()
        };
        let s = run(&q, &LoadRequest::new(true));
        assert_eq!(ids(&s.new_movies), Some(vec!["f1", "f2"]));
        assert_eq!(ids(&s.new_series), Some(vec!["e1", "e2"]));
    }
    #[test]
    fn only_movie_library_series_fall_back_to_episodes() {
        let q = Source {
            new: map(&[("", over_all()), ("filme", vec![film("f")])]),
            review: Some(vec![lib("filme", "Filme", Some("movies"))]),
            ..Source::base()
        };
        let s = run(&q, &LoadRequest::new(true));
        assert_eq!(ids(&s.new_movies), Some(vec!["f"]));
        assert_eq!(ids(&s.new_series), Some(vec!["e1", "e2"]));
    }
    #[test]
    fn multiple_of_a_kind_first_empty_next_with_news() {
        let q = Source {
            new: map(&[
                ("", over_all()),
                ("leer", vec![]),
                ("filme2", vec![film("g")]),
                ("serien", vec![episode("s")]),
            ]),
            review: Some(vec![
                lib("leer", "4K", Some("movies")),
                lib("filme2", "Films", Some("movies")),
                lib("serien", "Séries", Some("tvshows")),
            ]),
            ..Source::base()
        };
        let s = run(&q, &LoadRequest::new(true));
        assert_eq!(ids(&s.new_movies), Some(vec!["g"]));
        assert_eq!(ids(&s.new_series), Some(vec!["s"]));
    }
    #[test]
    fn collection_type_spelling_is_recognised() {
        let q = Source {
            new: map(&[
                ("", over_all()),
                ("filme", vec![film("f")]),
                ("serien", vec![episode("s")]),
            ]),
            review: Some(vec![
                lib("filme", "Filme", Some("Movies")),
                lib("serien", "Serien", Some("TvShows")),
            ]),
            ..Source::base()
        };
        let s = run(&q, &LoadRequest::new(true));
        assert_eq!(ids(&s.new_movies), Some(vec!["f"]));
        assert_eq!(ids(&s.new_series), Some(vec!["s"]));
    }
    #[test]
    fn selected_empty_or_unreachable_falls_back() {
        let q = Source {
            new: map(&[("", over_all()), ("filme", vec![])]),
            ..Source::base()
        };
        let s = run(
            &q,
            &LoadRequest::new(true)
                .film_library(Some("filme"))
                .series_library(Some("weg")),
        );
        assert_eq!(ids(&s.new_movies), Some(vec!["f1", "f2"]));
        assert_eq!(ids(&s.new_series), Some(vec!["e1", "e2"]));
    }
    #[test]
    fn libraries_unreadable_falls_back_nothing_gives_none() {
        let q = Source {
            new: map(&[("", over_all())]),
            review: None,
            ..Source::base()
        };
        let s = run(&q, &LoadRequest::new(true));
        assert_eq!(ids(&s.new_movies), Some(vec!["f1", "f2"]));
        assert_eq!(ids(&s.new_series), Some(vec!["e1", "e2"]));
        let distance = Source {
            review: None,
            ..Source::base()
        };
        let w = run(&distance, &LoadRequest::new(true));
        assert!(w.new_movies.is_none() && w.new_series.is_none());
    }
    #[test]
    fn movies_displace_episodes_series_asks_only_episodes() {
        let movies: Vec<Item> = (1..=24).map(|i| film(&format!("f{i}"))).collect();
        let q = Source {
            new: map(&[("", movies)]),
            review: Some(vec![
                lib("a", "Filme", Some("movies")),
                lib("b", "Serien", None),
            ]),
            typed: map(&[("Episode", vec![episode("e1")])]),
            ..Source::base()
        };
        let s = run(&q, &LoadRequest::new(true).film_library(Some("a")));
        assert_eq!(ids(&s.new_series), Some(vec!["e1"]));
    }
    #[test]
    fn no_episodes_recognised_falls_back_like_1_0_4() {
        let mixed = vec![film("f1"), Item::new("v1", "v1", Some("Video"))];
        let q = Source {
            new: map(&[("", mixed)]),
            review: Some(vec![lib("m", "Alles", Some("mixed"))]),
            typed: map(&[("Episode", vec![])]),
            ..Source::base()
        };
        let s = run(&q, &LoadRequest::new(true));
        assert_eq!(ids(&s.new_movies), Some(vec!["f1"]));
        // Never movies under "New series", not even in the last fallback.
        assert_eq!(ids(&s.new_series), Some(vec!["v1"]));
    }
    #[test]
    fn series_query_carries_the_row() {
        let movies: Vec<Item> = (1..=24).map(|i| film(&format!("f{i}"))).collect();
        let mut all = movies;
        all.push(episode("e1"));
        let q = Source {
            new: map(&[("", all)]),
            review: Some(vec![
                lib("a", "Filme", Some("movies")),
                lib("b", "Serien", None),
            ]),
            typed: map(&[("Episode", vec![])]),
            series_list: map(&[("", vec![Item::new("s1", "s1", Some("Series"))])]),
            ..Source::base()
        };
        let s = run(&q, &LoadRequest::new(true).film_library(Some("a")));
        assert_eq!(ids(&s.new_series), Some(vec!["s1"]));
        assert!(
            s.new_movies
                .iter()
                .flatten()
                .all(|i| i.type_.as_deref() == Some("Movie"))
        );
        assert!(q.lines().contains("Neu tvshows: Serien-Abfrage"));
    }
    #[test]
    fn series_row_never_shows_movies() {
        let q = Source {
            new: map(&[("", vec![film("f1"), film("f2")])]),
            review: None,
            ..Source::base()
        };
        let s = run(&q, &LoadRequest::new(true));
        assert_eq!(s.new_series.as_ref().map(Vec::len), Some(0));
        assert_eq!(ids(&s.new_movies), Some(vec!["f1", "f2"]));
    }
    #[test]
    fn grouped_answer_is_not_filtered_away() {
        let series = Item::new("s1", "Serie", Some("Series"));
        let q = Source {
            new: map(&[("", vec![film("f1"), series.clone()])]),
            review: Some(vec![lib("b", "Serien", None)]),
            typed: map(&[("Episode", vec![series])]),
            ..Source::base()
        };
        let s = run(&q, &LoadRequest::new(true));
        assert_eq!(ids(&s.new_series), Some(vec!["s1"]));
    }
    #[test]
    fn fallback_is_logged_with_reason() {
        let q = Source {
            new: map(&[("", over_all())]),
            review: Some(vec![lib("a", "Medien", None)]),
            ..Source::base()
        };
        run(&q, &LoadRequest::new(true));
        let rows = q.lines();
        assert!(rows.contains("Neu movies: keine Bibliothek der Art"));
        assert!(rows.contains("Neu tvshows: keine Bibliothek der Art"));
    }
    #[test]
    fn nothing_arrived_is_disrupted_one_row_is_enough() {
        let nothing = Source {
            proceed: None,
            next: None,
            review: Some(vec![]),
            ..Source::default()
        };
        assert!(run(&nothing, &LoadRequest::new(false)).disrupted);
        let something = Source {
            proceed: None,
            next: None,
            new: map(&[("", vec![])]),
            ..Source::default()
        };
        assert!(!run(&something, &LoadRequest::new(false)).disrupted);
    }
    #[test]
    fn genre_rails_in_chosen_order_empty_drop_no_doubles() {
        let q = Source {
            genres: map(&[
                ("Drama", vec![t("d"), t("d")]),
                ("Horror", vec![]),
                ("Komödie", vec![t("k")]),
            ]),
            ..Source::base()
        };
        let mut wish = LoadRequest::new(false);
        wish.genres = Some(
            ["Komödie", "Horror", "Drama", "Fehlt"]
                .iter()
                .map(|s| (*s).to_string())
                .collect(),
        );
        let s = run(&q, &wish);
        assert_eq!(
            s.genre_rails
                .iter()
                .map(|r| r.name.as_str())
                .collect::<Vec<_>>(),
            ["Komödie", "Drama"]
        );
        assert_eq!(
            s.genre_rails[1]
                .items
                .iter()
                .map(|i| i.id.as_str())
                .collect::<Vec<_>>(),
            ["d"]
        );
    }
    #[test]
    fn chips_give_no_genre_rails() {
        let q = Source {
            genres: map(&[("Drama", vec![t("d")])]),
            ..Source::base()
        };
        assert!(run(&q, &LoadRequest::new(false)).genre_rails.is_empty());
    }
    #[test]
    fn library_pseudo_values_are_dropped() {
        for pseudo in ["", "alle", "sammlungen", "wiedergabelisten"] {
            assert_eq!(
                LoadRequest::new(true)
                    .film_library(Some(pseudo))
                    .film_library,
                None
            );
        }
        assert_eq!(
            LoadRequest::new(true)
                .film_library(Some("x"))
                .film_library
                .as_deref(),
            Some("x")
        );
    }
    #[test]
    fn library_rails_in_chosen_order_gone_and_empty_drop() {
        let q = Source {
            latest: map(&[("a", vec![t("1"), t("1"), t("2")]), ("c", vec![])]),
            ..Source::base()
        };
        let w = [
            StartLibrary::new("c", "leer", false),
            StartLibrary::new("a", "A", false),
            StartLibrary::new("weg", "gelöscht", false),
        ];
        let r = block_on(HomeLoader::library_rails(&q, &w));
        assert_eq!(r.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), ["a"]);
        assert_eq!(
            r[0].items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            ["1", "2"]
        );
    }
}
