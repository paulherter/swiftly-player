//! The pure state of the home page (Swift `Sources/Shared/HomePageModel.swift`, class `HomeModel`).
//!
//! `HomeModel.load` is one long `async` function with `await` points; here it is split at those
//! points into steps. The driver (the app's view model) does the I/O the returned
//! [`HomeCommand`]s and the loader ask for and feeds the answers back, in this order:
//!
//! 1. [`HomeState::begin`] returns the run token and maybe `ReadStore`;
//! 2. [`HomeState::store_read`] (only if `ReadStore` was asked for);
//! 3. [`HomeState::views_command`], then once the libraries are there [`HomeState::views_ready`];
//! 4. the driver starts the genre and library rows and `HomeLoader::load`, and passes the
//!    loader's `Home` to [`HomeState::fixed_rows_arrived`];
//! 5. on [`Fixed::AwaitFirst`] it waits for both extras and calls [`HomeState::first_extras_ready`];
//!    on [`Fixed::AwaitLater`] it calls [`HomeState::genres_ready`] and then
//!    [`HomeState::libraries_ready`].
//!
//! Every step re-checks `applies()` (`:81`): a step of a run that was overtaken, or whose account
//! was switched, returns [`Step::Stop`] and changes nothing. After `Stop` (or after the last step)
//! the run is over and the driver must not call further steps of it. Nothing here does I/O.

use swiftly_model::Item;

use crate::home::{GenreRail, Home, LibraryRail};
use crate::home_store::{HomeStore, Rail};
use crate::refresh;
use crate::start_libraries::StartLibrary;

/// An effect the driver has to carry out.
#[derive(Debug, Clone, PartialEq)]
pub enum HomeCommand {
    /// Read the stored preview of this account (`storeRead`, :248).
    ReadStore {
        /// The account key.
        account: String,
    },
    /// Fetch the libraries (`model.loadViews()`, :107-111). With `wait` the run waits for it
    /// (no libraries known yet); without, it runs alongside (they came from storage).
    LoadViews {
        /// Whether the run waits.
        wait: bool,
    },
    /// Put these libraries into the app model (`model.librariesPreOff`, :243).
    AdoptLibraries(Vec<Item>),
    /// Persist the store for the account (`storeWrite`, :280).
    WriteStore {
        /// The account key.
        account: String,
        /// What to write.
        store: HomeStore,
    },
    /// Load collections and shares of mixed libraries (`model.offeringLoad()`, :226).
    OfferingLoad,
    /// Prefetch the series of these rows (`SeriesCache.prefetch`, non-tvOS, :232).
    PrefetchSeries(Vec<Item>),
}

/// Whether a run goes on.
#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    /// The run is over (it no longer applies, was cancelled, or ended early). Change nothing more.
    Stop,
    /// Carry out these commands and go on.
    Continue(Vec<HomeCommand>),
}

/// What [`HomeState::fixed_rows_arrived`] decided.
#[derive(Debug, Clone, PartialEq)]
pub enum Fixed {
    /// The run is over.
    Stop,
    /// First appearance: wait for genres and libraries, then call `first_extras_ready` (:194-198).
    AwaitFirst,
    /// The fixed rows are adopted; collect genres, then libraries (:213-223).
    AwaitLater,
}

/// Identifies one load run (`myOwn` and `itAccount`, :84-88).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HomeRun {
    run: u64,
    account: u64,
}

/// The settings a step reads (`model.newAccessDisconnected`, `genreChips`, `startGenres`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct HomePrefs {
    /// New movies and new series separately.
    pub disconnected: bool,
    /// Genres as chips on top; then there are no rows.
    pub genre_chips: bool,
    /// The chosen genres, in order.
    pub start_genres: Vec<String>,
}

/// What the home page shows and how it loads it (`HomeModel`).
#[derive(Debug, Clone, Default)]
pub struct HomeState {
    /// Continue watching.
    pub continue_watching: Vec<Item>,
    /// Next episode.
    pub next_episode: Vec<Item>,
    /// The shared new-additions row.
    pub recent: Vec<Item>,
    /// New movies; only filled when split (:25-30).
    pub new_movies: Vec<Item>,
    /// New series; only filled when split.
    pub new_series: Vec<Item>,
    /// The chosen genres as their own rows.
    pub genre_rails: Vec<GenreRail>,
    /// The chosen libraries and collections as their own rows (use [`HomeState::library_rails_for`]).
    pub library_rails: Vec<LibraryRail>,
    /// Whether anything was loaded yet.
    pub loaded: bool,
    /// None of the three calls got through: the server, not an empty library (:48).
    pub disrupted: bool,
    /// Why the page is disrupted, when the failed fetch said so (`None`: unknown, treat as unreachable).
    pub failure: Option<swiftly_net::ErrorTopic>,
    /// When last fetched, `refresh` basis. Set only on success (:50-56).
    pub last_loaded: Option<f64>,
    running_runs: u32,
    for_account: u64,
    run: u64,
    loaded_server: bool,
    change: bool,
    pending: Option<Home>,
}

impl HomeState {
    /// An empty, not yet loaded state.
    pub fn new() -> Self {
        Self::default()
    }

    /// The rows for the current choice: what is no longer chosen drops out at once (:33-36).
    pub fn library_rails_for(&self, choice: &[StartLibrary]) -> Vec<&LibraryRail> {
        choice
            .iter()
            .filter_map(|c| self.library_rails.iter().find(|r| r.id == c.id))
            .collect()
    }

    /// Genre rows count too: someone who hides all fixed rows and shows only genres has a full
    /// home page (:75-82).
    pub fn all_empty(&self) -> bool {
        self.continue_watching.is_empty()
            && self.next_episode.is_empty()
            && self.recent.is_empty()
            && self.new_movies.is_empty()
            && self.new_series.is_empty()
            && self.genre_rails.iter().all(|r| r.items.is_empty())
            && self.library_rails.is_empty()
    }

    /// The state belongs to a previous account (`outdated`, :86).
    pub fn outdated(&self, account_switch: u64) -> bool {
        self.for_account != account_switch
    }

    /// Must it be fetched again when returning to the foreground? Not while a run is in flight
    /// (`needsRefresh`, :328).
    pub fn needs_refresh(&self, now: f64) -> bool {
        self.running_runs == 0 && refresh::due_return(self.last_loaded, now)
    }

    fn applies(&self, run: HomeRun, account_switch_now: u64) -> bool {
        run.run == self.run && run.account == account_switch_now
    }

    fn end(&mut self) {
        self.running_runs = self.running_runs.saturating_sub(1);
    }

    fn stop(&mut self) -> Step {
        self.end();
        Step::Stop
    }

    /// Back to "nothing loaded yet" (`wipe`, :311-325).
    fn wipe(&mut self) {
        self.continue_watching.clear();
        self.next_episode.clear();
        self.recent.clear();
        self.new_movies.clear();
        self.new_series.clear();
        self.genre_rails.clear();
        self.library_rails.clear();
        self.loaded = false;
        self.disrupted = false;
        self.failure = None;
        self.last_loaded = None;
        self.loaded_server = false;
    }

    /// Starts a run (`load`, :84-104). Empty immediately after an account switch; then asks for the
    /// stored preview while nothing is shown yet.
    pub fn begin(
        &mut self,
        account_switch: u64,
        account_key: Option<&str>,
    ) -> (HomeRun, Vec<HomeCommand>) {
        self.running_runs += 1;
        self.run += 1;
        let run = HomeRun {
            run: self.run,
            account: account_switch,
        };
        if account_switch != self.for_account && (self.loaded || !self.all_empty()) {
            self.wipe();
        }
        let mut commands = Vec::new();
        if let Some(account) = account_key.filter(|_| !self.loaded && self.all_empty()) {
            commands.push(HomeCommand::ReadStore {
                account: account.to_string(),
            });
        }
        (run, commands)
    }

    /// The stored preview arrived, `None` if there is none (:98-103). Only shown while nothing is
    /// on screen.
    pub fn store_read(
        &mut self,
        run: HomeRun,
        account_switch_now: u64,
        store: Option<&HomeStore>,
        prefs: &HomePrefs,
    ) -> Step {
        let Some(store) = store else {
            return Step::Continue(Vec::new());
        };
        if !self.applies(run, account_switch_now) {
            return self.stop();
        }
        let mut commands = Vec::new();
        if self.all_empty() {
            commands.push(HomeCommand::AdoptLibraries(store.libraries.clone()));
            self.preview_show(store, prefs);
        }
        self.for_account = run.account;
        Step::Continue(commands)
    }

    /// `previewShow` (:241-261): only genres that are still chosen, in the chosen order.
    fn preview_show(&mut self, store: &HomeStore, prefs: &HomePrefs) {
        self.continue_watching = store.continue_watching.clone();
        self.next_episode = store.next_episode.clone();
        self.recent = if prefs.disconnected {
            Vec::new()
        } else {
            store.recent.clone()
        };
        self.new_movies = if prefs.disconnected {
            store.new_movies.clone()
        } else {
            Vec::new()
        };
        self.new_series = if prefs.disconnected {
            store.new_series.clone()
        } else {
            Vec::new()
        };
        self.genre_rails = if prefs.genre_chips {
            Vec::new()
        } else {
            prefs
                .start_genres
                .iter()
                .filter_map(|name| {
                    // `uniquingKeysWith: { a, _ in a }`: the first rail of a name counts.
                    let rail: &Rail = store.genre_rails.iter().find(|r| &r.name == name)?;
                    Some(GenreRail {
                        name: name.clone(),
                        items: rail.items.clone(),
                    })
                })
                .collect()
        };
        self.loaded = true;
    }

    /// Which commands the libraries need (:105-111): fetch and wait if none are known, fetch
    /// alongside if they came from storage, nothing once the server has answered.
    pub fn views_command(&self, views_empty: bool) -> Option<HomeCommand> {
        if views_empty {
            Some(HomeCommand::LoadViews { wait: true })
        } else if !self.loaded_server {
            Some(HomeCommand::LoadViews { wait: false })
        } else {
            None
        }
    }

    /// The libraries are there (:112-118). Without a client nothing arrived: disrupted, unless
    /// cancelled.
    pub fn views_ready(
        &mut self,
        run: HomeRun,
        account_switch_now: u64,
        has_client: bool,
        cancelled: bool,
    ) -> Step {
        if !self.applies(run, account_switch_now) {
            return self.stop();
        }
        if !has_client {
            self.disrupted = !cancelled;
            self.failure = None;
            self.loaded = true;
            return self.stop();
        }
        Step::Continue(Vec::new())
    }

    /// The loader's fixed rows arrived (:140-196). Cancelled does not mean "server silent".
    pub fn fixed_rows_arrived(
        &mut self,
        run: HomeRun,
        account_switch_now: u64,
        cancelled: bool,
        disconnected: bool,
        home: Home,
        now: f64,
    ) -> Fixed {
        if !self.applies(run, account_switch_now) || cancelled {
            self.end();
            return Fixed::Stop;
        }
        if !self.loaded {
            self.pending = Some(home);
            return Fixed::AwaitFirst;
        }
        self.adopt_fixed(run, disconnected, home, cancelled, now);
        Fixed::AwaitLater
    }

    /// The adoption of the fixed rows (:164-191). `adopt`: a missing answer keeps the old state,
    /// except after an account switch.
    fn adopt_fixed(
        &mut self,
        run: HomeRun,
        disconnected: bool,
        home: Home,
        cancelled: bool,
        now: f64,
    ) {
        self.change = run.account != self.for_account;
        self.for_account = run.account;
        let change = self.change;
        let adopt = |new: &Option<Vec<Item>>, alt: &Vec<Item>| -> Vec<Item> {
            match new {
                Some(n) => n.clone(),
                None if change => Vec::new(),
                None => alt.clone(),
            }
        };
        self.continue_watching = adopt(&home.continue_watching, &self.continue_watching);
        self.next_episode = adopt(&home.next_episode, &self.next_episode);
        if disconnected {
            self.recent = Vec::new();
            self.new_movies = adopt(&home.new_movies, &self.new_movies);
            self.new_series = adopt(&home.new_series, &self.new_series);
        } else {
            self.new_movies = Vec::new();
            self.new_series = Vec::new();
            self.recent = adopt(&home.recent, &self.recent);
        }
        self.disrupted = !cancelled && home.disrupted;
        self.failure = if self.disrupted { home.failure } else { None };
        // If only one of the fixed fetches did not get through, the old state stays and does not
        // count as fresh.
        let part_failure = home.continue_watching.is_none() || home.next_episode.is_none();
        if !self.disrupted && !part_failure {
            self.last_loaded = Some(now);
        }
        self.loaded = true;
    }

    /// First appearance, everything in one go (:194-210): genres and libraries are set as they
    /// came, the stashed fixed rows are adopted.
    #[allow(clippy::too_many_arguments)]
    pub fn first_extras_ready(
        &mut self,
        run: HomeRun,
        account_switch_now: u64,
        cancelled: bool,
        disconnected: bool,
        genres: Vec<GenreRail>,
        libraries: Vec<LibraryRail>,
        now: f64,
        finish: &HomeFinish<'_>,
    ) -> Step {
        if !self.applies(run, account_switch_now) {
            return self.stop();
        }
        if let Some(home) = self.pending.take() {
            self.adopt_fixed(run, disconnected, home, cancelled, now);
        }
        self.genre_rails = genres;
        self.library_rails = libraries;
        self.finish_run(finish)
    }

    /// The genre rows arrived on a standing page (:212-217). The old rows stay until new ones are
    /// there, unless there are none to show.
    pub fn genres_ready(
        &mut self,
        run: HomeRun,
        account_switch_now: u64,
        fresh: Vec<GenreRail>,
        genre_chips: bool,
    ) -> Step {
        if !self.applies(run, account_switch_now) {
            return self.stop();
        }
        if !fresh.is_empty() || self.change || genre_chips {
            self.genre_rails = fresh;
        }
        Step::Continue(Vec::new())
    }

    /// The library rows arrived on a standing page (:218-224); the last step of the run.
    pub fn libraries_ready(
        &mut self,
        run: HomeRun,
        account_switch_now: u64,
        fresh: Vec<LibraryRail>,
        choice_empty: bool,
        finish: &HomeFinish<'_>,
    ) -> Step {
        if !self.applies(run, account_switch_now) {
            return self.stop();
        }
        if !fresh.is_empty() || self.change || choice_empty {
            self.library_rails = fresh;
        }
        self.finish_run(finish)
    }

    /// The end of a successful run (:225-240): remember the page, load the offerings, prefetch.
    fn finish_run(&mut self, finish: &HomeFinish<'_>) -> Step {
        let mut commands = Vec::new();
        if !self.disrupted {
            self.loaded_server = true;
            if let Some(account) = finish.account_key {
                commands.push(HomeCommand::WriteStore {
                    account: account.to_string(),
                    store: self.store_snapshot(finish.views),
                });
            }
            commands.push(HomeCommand::OfferingLoad);
        }
        let mut rows = self.continue_watching.clone();
        rows.extend(self.next_episode.iter().cloned());
        rows.extend(self.recent.iter().cloned());
        rows.extend(self.new_series.iter().cloned());
        commands.push(HomeCommand::PrefetchSeries(rows));
        self.end();
        Step::Continue(commands)
    }

    /// What `storeWrite` persists (:280-286).
    fn store_snapshot(&self, views: &[Item]) -> HomeStore {
        HomeStore::new(
            views.to_vec(),
            self.continue_watching.clone(),
            self.next_episode.clone(),
            self.recent.clone(),
            self.new_movies.clone(),
            self.new_series.clone(),
            self.genre_rails
                .iter()
                .map(|r| Rail {
                    name: r.name.clone(),
                    items: r.items.clone(),
                })
                .collect(),
        )
    }
}

/// What the last step needs from the app model.
#[derive(Debug, Clone, Copy)]
pub struct HomeFinish<'a> {
    /// `model.session?.accountKey`.
    pub account_key: Option<&'a str>,
    /// `model.views`.
    pub views: &'a [Item],
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(id: &str) -> Item {
        Item::new(id, id, None)
    }
    fn ids(v: &[Item]) -> Vec<&str> {
        v.iter().map(|i| i.id.as_str()).collect()
    }
    fn home(cw: Option<Vec<Item>>, next: Option<Vec<Item>>, recent: Option<Vec<Item>>) -> Home {
        let disrupted = cw.is_none() && next.is_none() && recent.is_none();
        Home {
            continue_watching: cw,
            next_episode: next,
            recent,
            new_movies: None,
            new_series: None,
            genre_rails: vec![],
            disrupted,
            failure: None,
        }
    }
    fn rail(name: &str, id: &str) -> GenreRail {
        GenreRail {
            name: name.into(),
            items: vec![t(id)],
        }
    }
    fn finish() -> HomeFinish<'static> {
        HomeFinish {
            account_key: Some("acc"),
            views: &[],
        }
    }

    /// A whole first run, driven the way the app does it.
    fn first_run(s: &mut HomeState, account: u64, h: Home, now: f64) {
        let (run, cmds) = s.begin(account, Some("acc"));
        assert!(matches!(cmds.as_slice(), [HomeCommand::ReadStore { .. }]));
        assert!(matches!(
            s.store_read(run, account, None, &HomePrefs::default()),
            Step::Continue(_)
        ));
        assert!(matches!(
            s.views_ready(run, account, true, false),
            Step::Continue(_)
        ));
        assert_eq!(
            s.fixed_rows_arrived(run, account, false, false, h, now),
            Fixed::AwaitFirst
        );
        let r = s.first_extras_ready(
            run,
            account,
            false,
            false,
            vec![rail("Drama", "d")],
            vec![],
            now,
            &finish(),
        );
        assert!(matches!(r, Step::Continue(_)));
    }

    #[test]
    fn first_run_waits_for_extras_then_writes_the_store() {
        let mut s = HomeState::new();
        let (run, _) = s.begin(0, Some("acc"));
        s.views_ready(run, 0, true, false);
        let h = home(Some(vec![t("a")]), Some(vec![t("b")]), Some(vec![t("c")]));
        assert_eq!(
            s.fixed_rows_arrived(run, 0, false, false, h, 100.0),
            Fixed::AwaitFirst
        );
        // Nothing adopted yet, the page waits for the genres.
        assert!(s.continue_watching.is_empty() && !s.loaded);
        let step = s.first_extras_ready(
            run,
            0,
            false,
            false,
            vec![rail("Drama", "d")],
            vec![],
            100.0,
            &finish(),
        );
        let Step::Continue(cmds) = step else {
            panic!("run ended")
        };
        assert_eq!(ids(&s.continue_watching), ["a"]);
        assert_eq!(s.genre_rails.len(), 1);
        assert!(s.loaded && !s.disrupted);
        assert_eq!(s.last_loaded, Some(100.0));
        assert!(matches!(cmds[0], HomeCommand::WriteStore { .. }));
        assert_eq!(cmds[1], HomeCommand::OfferingLoad);
        assert!(matches!(cmds[2], HomeCommand::PrefetchSeries(_)));
    }

    #[test]
    fn only_the_latest_run_writes() {
        let mut s = HomeState::new();
        let (old, _) = s.begin(0, None);
        let (new, _) = s.begin(0, None);
        // The older run is overtaken: it stops, changes nothing.
        let h = home(Some(vec![t("old")]), Some(vec![]), Some(vec![]));
        assert_eq!(
            s.fixed_rows_arrived(old, 0, false, false, h, 1.0),
            Fixed::Stop
        );
        assert!(s.continue_watching.is_empty() && !s.loaded);
        // Two runs began, one ended: the other is still counted.
        assert!(!s.needs_refresh(1e9));
        let h = home(Some(vec![t("new")]), Some(vec![]), Some(vec![]));
        assert_eq!(
            s.fixed_rows_arrived(new, 0, false, false, h, 1.0),
            Fixed::AwaitFirst
        );
    }

    #[test]
    fn account_switch_during_a_run_stops_it() {
        let mut s = HomeState::new();
        let (run, _) = s.begin(1, None);
        assert_eq!(s.views_ready(run, 2, true, false), Step::Stop);
        let h = home(Some(vec![t("x")]), Some(vec![]), Some(vec![]));
        assert_eq!(
            s.fixed_rows_arrived(run, 2, false, false, h, 1.0),
            Fixed::Stop
        );
        assert!(s.continue_watching.is_empty());
    }

    #[test]
    fn missing_answer_keeps_the_old_rows_except_after_an_account_switch() {
        let mut s = HomeState::new();
        first_run(
            &mut s,
            0,
            home(Some(vec![t("a")]), Some(vec![t("b")]), Some(vec![t("c")])),
            10.0,
        );
        // Refresh: continue watching did not get through; the old row stays, and it is not fresh.
        let (run, cmds) = s.begin(0, Some("acc"));
        assert!(cmds.is_empty(), "no preview while something is shown");
        s.views_ready(run, 0, true, false);
        let h = home(None, Some(vec![t("b2")]), Some(vec![t("c2")]));
        assert_eq!(
            s.fixed_rows_arrived(run, 0, false, false, h, 50.0),
            Fixed::AwaitLater
        );
        assert_eq!(ids(&s.continue_watching), ["a"]);
        assert_eq!(ids(&s.next_episode), ["b2"]);
        assert_eq!(
            s.last_loaded,
            Some(10.0),
            "a part failure does not make the rows fresh"
        );
        s.genres_ready(run, 0, vec![], false);
        // An empty genre result on a standing page keeps the old genre rows.
        assert_eq!(s.genre_rails.len(), 1);
        let Step::Continue(_) = s.libraries_ready(run, 0, vec![], true, &finish()) else {
            panic!()
        };
    }

    #[test]
    fn adopt_after_account_switch_is_empty_when_the_fetch_missed() {
        let mut s = HomeState::new();
        first_run(
            &mut s,
            0,
            home(Some(vec![t("a")]), Some(vec![t("b")]), Some(vec![t("c")])),
            10.0,
        );
        // A new account, but the state is not wiped because begin() wipes only on a switch:
        let (run, _) = s.begin(1, None);
        s.views_ready(run, 1, true, false);
        let h = home(None, Some(vec![t("n")]), Some(vec![t("r")]));
        // `loaded` is false after the wipe, so this is a first appearance again.
        assert_eq!(
            s.fixed_rows_arrived(run, 1, false, false, h, 70.0),
            Fixed::AwaitFirst
        );
        s.first_extras_ready(run, 1, false, false, vec![], vec![], 70.0, &finish());
        assert!(
            s.continue_watching.is_empty(),
            "no leftovers of the previous account"
        );
        assert_eq!(ids(&s.next_episode), ["n"]);
        assert_eq!(ids(&s.recent), ["r"]);
    }

    #[test]
    fn preview_from_the_store_shows_chosen_genres_only() {
        let mut s = HomeState::new();
        let (run, cmds) = s.begin(0, Some("acc"));
        assert_eq!(
            cmds,
            [HomeCommand::ReadStore {
                account: "acc".into()
            }]
        );
        let store = HomeStore::new(
            vec![t("lib")],
            vec![t("a")],
            vec![],
            vec![t("recent")],
            vec![t("nm")],
            vec![],
            vec![
                Rail {
                    name: "Drama".into(),
                    items: vec![t("d")],
                },
                Rail {
                    name: "Horror".into(),
                    items: vec![t("h")],
                },
            ],
        );
        let prefs = HomePrefs {
            disconnected: true,
            genre_chips: false,
            start_genres: vec!["Horror".into(), "Fehlt".into()],
        };
        let Step::Continue(cmds) = s.store_read(run, 0, Some(&store), &prefs) else {
            panic!()
        };
        assert_eq!(cmds, [HomeCommand::AdoptLibraries(vec![t("lib")])]);
        assert!(s.loaded);
        assert_eq!(ids(&s.continue_watching), ["a"]);
        assert!(s.recent.is_empty(), "split: the shared row is empty");
        assert_eq!(ids(&s.new_movies), ["nm"]);
        assert_eq!(
            s.genre_rails
                .iter()
                .map(|r| r.name.as_str())
                .collect::<Vec<_>>(),
            ["Horror"]
        );
    }

    #[test]
    fn preview_is_not_shown_over_existing_rows() {
        let mut s = HomeState::new();
        first_run(
            &mut s,
            0,
            home(Some(vec![t("a")]), Some(vec![]), Some(vec![])),
            1.0,
        );
        let (run, _) = s.begin(0, Some("acc"));
        let store = HomeStore::new(
            vec![],
            vec![t("stored")],
            vec![],
            vec![],
            vec![],
            vec![],
            vec![],
        );
        s.store_read(run, 0, Some(&store), &HomePrefs::default());
        assert_eq!(ids(&s.continue_watching), ["a"]);
    }

    #[test]
    fn libraries_without_a_client_are_disrupted_unless_cancelled() {
        let mut s = HomeState::new();
        let (run, _) = s.begin(0, None);
        assert_eq!(s.views_ready(run, 0, false, false), Step::Stop);
        assert!(s.disrupted && s.loaded);
        let mut c = HomeState::new();
        let (run, _) = c.begin(0, None);
        assert_eq!(c.views_ready(run, 0, false, true), Step::Stop);
        assert!(!c.disrupted && c.loaded);
    }

    #[test]
    fn views_commands() {
        let mut s = HomeState::new();
        assert_eq!(
            s.views_command(true),
            Some(HomeCommand::LoadViews { wait: true })
        );
        assert_eq!(
            s.views_command(false),
            Some(HomeCommand::LoadViews { wait: false })
        );
        first_run(
            &mut s,
            0,
            home(Some(vec![t("a")]), Some(vec![]), Some(vec![])),
            1.0,
        );
        assert_eq!(s.views_command(false), None);
    }

    #[test]
    fn refresh_waits_for_running_runs_and_the_deadline() {
        let mut s = HomeState::new();
        let (run, _) = s.begin(0, None);
        assert!(!s.needs_refresh(1e9), "a run is in flight");
        s.views_ready(run, 0, false, false);
        assert!(
            s.needs_refresh(1e9),
            "the run is over and nothing was ever fresh"
        );
        let mut f = HomeState::new();
        first_run(
            &mut f,
            0,
            home(Some(vec![t("a")]), Some(vec![]), Some(vec![])),
            100.0,
        );
        assert!(!f.needs_refresh(110.0));
        assert!(f.needs_refresh(130.0));
    }

    #[test]
    fn disrupted_run_does_not_write_the_store_or_count_as_fresh() {
        let mut s = HomeState::new();
        let (run, _) = s.begin(0, None);
        s.views_ready(run, 0, true, false);
        let h = home(None, None, None);
        assert_eq!(
            s.fixed_rows_arrived(run, 0, false, false, h, 5.0),
            Fixed::AwaitFirst
        );
        let Step::Continue(cmds) =
            s.first_extras_ready(run, 0, false, false, vec![], vec![], 5.0, &finish())
        else {
            panic!()
        };
        assert!(s.disrupted && s.last_loaded.is_none());
        assert!(cmds.iter().all(|c| !matches!(
            c,
            HomeCommand::WriteStore { .. } | HomeCommand::OfferingLoad
        )));
    }

    #[test]
    fn library_rails_follow_the_current_choice() {
        let mut s = HomeState::new();
        s.library_rails = vec![
            LibraryRail {
                id: "a".into(),
                name: "A".into(),
                items: vec![],
            },
            LibraryRail {
                id: "b".into(),
                name: "B".into(),
                items: vec![],
            },
        ];
        let choice = [
            StartLibrary::new("b", "B", false),
            StartLibrary::new("gone", "x", false),
        ];
        assert_eq!(
            s.library_rails_for(&choice)
                .iter()
                .map(|r| r.id.as_str())
                .collect::<Vec<_>>(),
            ["b"]
        );
    }

    #[test]
    fn cancelled_fixed_rows_are_not_adopted() {
        let mut s = HomeState::new();
        let (run, _) = s.begin(0, None);
        let h = home(None, None, None);
        assert_eq!(
            s.fixed_rows_arrived(run, 0, true, false, h, 1.0),
            Fixed::Stop
        );
        assert!(!s.loaded && !s.disrupted);
    }
}
