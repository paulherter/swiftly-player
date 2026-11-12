//! The Seerr add-on as a view model (`SeerrModel.swift`, `SeerrDetailView.swift`,
//! `SeerrMark.swift`): discover tiles from a search, the detail page of one title and the request
//! flow (movie: ask twice; series: choose seasons in a sheet, never "all"). A state machine:
//! intents go in, effects (calls the host runs over the `swiftly-seerr` client) come out, the
//! parts are what the view draws. [`SeerrVm::run`] runs an effect over a client.

use std::collections::BTreeSet;

use swiftly_l10n::{Arg, Locale, Translator, error_text::readable_error};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_seerr::{CookieJar, SeerrClient, SeerrDetail, SeerrHit, SeerrState};

/// How long the "ask again" question stands before it is taken back, in seconds.
pub const CONFIRM_STANDS_SECONDS: u64 = 5;

/// The four wordings of the second tap (`confirmations`).
const CONFIRMATIONS: [&str; 4] = [
    "Nochmal, dann läuft’s",
    "Nochmal — ab die Post",
    "Nochmal, dann frag ich",
    "Nochmal, her damit",
];

/// One tile of the discover rail (`SeerrTile`).
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrTile {
    /// The hit behind the tile.
    pub hit: SeerrHit,
    /// Poster address (width 342).
    pub poster: Option<String>,
    /// The short status word on the tile (`shortWord`); `None` when nothing is shown.
    pub short_word: Option<String>,
    /// What VoiceOver adds (`announcement`).
    pub announcement: String,
}

/// The discover results.
#[derive(Debug, Clone, PartialEq)]
pub struct DiscoverPart {
    /// Grows with every change.
    pub version: u64,
    /// The term these tiles belong to.
    pub term: String,
    /// The tiles; empty means: show nothing at all (an add-on leaves no hole).
    pub tiles: Vec<SeerrTile>,
}

/// One season row of the request sheet.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrSeasonRow {
    /// Season number.
    pub number: i64,
    /// "Staffel 3".
    pub title: String,
    /// "· 10 Folgen"; `None` when the episode count is unknown.
    pub episodes: Option<String>,
    /// Can be ticked.
    pub requestable: bool,
    /// Is ticked.
    pub selected: bool,
    /// "vorhanden" / "unterwegs" for rows that cannot be ticked.
    pub note: Option<String>,
}

/// One person of the cast row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeerrCast {
    /// Name.
    pub name: String,
    /// Role.
    pub role: Option<String>,
    /// Portrait address.
    pub image: Option<String>,
}

/// The detail page of one Seerr title.
#[derive(Debug, Clone, PartialEq)]
pub struct SeerrPart {
    /// Grows with every change.
    pub version: u64,
    /// The title.
    pub hit: SeerrHit,
    /// The state as best known (the server's word beats the search hit's).
    pub state: SeerrState,
    /// Backdrop address.
    pub backdrop: Option<String>,
    /// "2008 · 7 Staffeln · Drama, Krimi".
    pub secondary_line: String,
    /// The status in words.
    pub status_word: String,
    /// The rating above zero.
    pub rating: Option<f64>,
    /// The description.
    pub description: Option<String>,
    /// The first twelve people.
    pub cast: Vec<SeerrCast>,
    /// Suggestions as tiles.
    pub similar: Vec<SeerrTile>,
    /// The main button is shown (else `note`).
    pub can_request: bool,
    /// Label of the main button.
    pub button_text: String,
    /// The button shows a check instead of a plus (the question is open).
    pub button_checked: bool,
    /// The note in place of the button (status hint) or after a request.
    pub note: Option<String>,
    /// A request is running.
    pub running: bool,
    /// The season sheet is open.
    pub sheet_open: bool,
    /// The rows of the season sheet.
    pub seasons: Vec<SeerrSeasonRow>,
    /// Label of the sheet's button.
    pub sheet_button: String,
    /// The sheet's button can be pressed.
    pub sheet_button_enabled: bool,
    /// The last error, readable.
    pub error: Option<String>,
    /// The detail fetch failed (show the disturbance hint with Seerr's address).
    pub disturbed: bool,
}

/// What the view reports.
#[derive(Debug)]
pub enum SeerrIntent {
    /// Search for a term (also the discover rail).
    Search(String),
    /// The search came back.
    SearchLoaded {
        /// The term it was for.
        term: String,
        /// The hits.
        hits: Vec<SeerrHit>,
    },
    /// A tile was opened.
    Open(SeerrHit),
    /// The detail came back; `None` = the call failed.
    DetailLoaded(Option<SeerrDetail>),
    /// The main button. `roll` picks the wording of the second tap.
    Press {
        /// Any number; used to pick one of the other wordings.
        roll: usize,
    },
    /// A season row was tapped.
    ToggleSeason(i64),
    /// The sheet's button.
    ConfirmSeasons,
    /// The sheet was closed without asking.
    CloseSheet,
    /// The request came back; `None` = accepted.
    Asked(Option<ErrorKind>),
    /// The hint strip was dismissed.
    DismissError,
    /// The question's time ran out ([`CONFIRM_STANDS_SECONDS`]).
    ConfirmExpired,
}

/// What the host runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SeerrEffect {
    /// `searching`; answer with [`SeerrIntent::SearchLoaded`].
    Search(String),
    /// `detail`; answer with [`SeerrIntent::DetailLoaded`].
    LoadDetail {
        /// `movie` or `tv`.
        art: String,
        /// TMDB id.
        id: i64,
    },
    /// `askFor`; answer with [`SeerrIntent::Asked`].
    Ask {
        /// `movie` or `tv`.
        art: String,
        /// TMDB id.
        id: i64,
        /// The seasons; `None` only for a movie.
        seasons: Option<Vec<i64>>,
    },
    /// Start a timer and answer [`SeerrIntent::ConfirmExpired`] when it runs out.
    StartConfirmTimer,
}

/// The short word of a state on a tile.
fn short_word(t: &Translator, state: SeerrState) -> Option<String> {
    Some(t.t(match state {
        SeerrState::Opened | SeerrState::Deleted | SeerrState::Present => return None,
        SeerrState::WaitsSharing => "wartet",
        SeerrState::Loads => "angefragt",
        SeerrState::PartWayPresent => "teilweise",
    }))
}

/// The status in words (`SeerrState.word`).
pub fn state_word(t: &Translator, state: SeerrState) -> String {
    t.t(match state {
        SeerrState::Opened | SeerrState::Deleted => "Nicht auf deinem Server",
        SeerrState::WaitsSharing => "Wartet auf Freigabe",
        SeerrState::Loads => "Angefragt",
        SeerrState::PartWayPresent => "Teilweise vorhanden",
        SeerrState::Present => "Auf deinem Server",
    })
}

/// What VoiceOver reads (`SeerrState.announcement`).
pub fn state_announcement(t: &Translator, state: SeerrState) -> String {
    t.t(match state {
        SeerrState::Opened | SeerrState::Deleted => "kann angefragt werden",
        SeerrState::WaitsSharing => "wartet auf Freigabe",
        SeerrState::Loads => "angefragt",
        SeerrState::PartWayPresent => "teilweise vorhanden",
        SeerrState::Present => "auf deinem Server",
    })
}

/// The sentence under the status for states that cannot be requested (`SeerrState.hint`).
pub fn state_hint(t: &Translator, state: SeerrState) -> String {
    t.t(match state {
        SeerrState::WaitsSharing => {
            "Deine Anfrage liegt beim Verwalter des Servers. Du musst nichts weiter tun."
        }
        SeerrState::Loads => {
            "Deine Anfrage ist durch. Der Titel erscheint von selbst in deiner Bibliothek."
        }
        _ => "Dieser Titel liegt bereits auf deinem Server.",
    })
}

/// The Seerr view model.
pub struct SeerrVm {
    translator: Translator,
    discover: DiscoverPart,
    page: Option<SeerrPart>,
    detail: Option<SeerrDetail>,
    selected: BTreeSet<i64>,
    confirmed: bool,
    wording: usize,
    requested: bool,
    after_request: bool,
}

impl SeerrVm {
    /// A model without a search and without a page.
    pub fn new(locale: Locale) -> Self {
        Self {
            translator: Translator::new(locale),
            discover: DiscoverPart {
                version: 0,
                term: String::new(),
                tiles: Vec::new(),
            },
            page: None,
            detail: None,
            selected: BTreeSet::new(),
            confirmed: false,
            wording: 0,
            requested: false,
            after_request: false,
        }
    }

    /// The discover tiles.
    pub fn discover(&self) -> &DiscoverPart {
        &self.discover
    }

    /// The open detail page, if any.
    pub fn page(&self) -> Option<&SeerrPart> {
        self.page.as_ref()
    }

    fn tile(&self, hit: &SeerrHit) -> SeerrTile {
        SeerrTile {
            hit: hit.clone(),
            poster: hit.poster(342),
            short_word: short_word(&self.translator, hit.state),
            announcement: state_announcement(&self.translator, hit.state),
        }
    }

    fn seasons_label(&self, n: usize) -> String {
        if n == 1 {
            self.translator.t("1 Staffel")
        } else {
            self.translator
                .plural("%lld Staffeln", n as i64, &[Arg::Int(n as i64)])
        }
    }

    fn secondary_line(&self, hit: &SeerrHit) -> String {
        let t = &self.translator;
        let mut parts: Vec<String> = Vec::new();
        if let Some(year) = hit.year {
            parts.push(year.to_string());
        }
        if hit.is_series() {
            let n = self.detail.as_ref().map_or(0, |d| d.seasons.len());
            if n > 0 {
                parts.push(self.seasons_label(n));
            }
        } else if let Some(m) = self
            .detail
            .as_ref()
            .and_then(|d| d.runtime)
            .filter(|m| *m > 0)
        {
            parts.push(t.t_args("%lld Min.", &[Arg::Int(m)]));
        }
        let genres = self
            .detail
            .as_ref()
            .map(|d| d.genres.join(", "))
            .unwrap_or_default();
        if !genres.is_empty() {
            parts.push(genres);
        }
        if parts.is_empty() {
            parts.push(t.t(if hit.is_series() { "Serie" } else { "Film" }));
        }
        parts.join(" · ")
    }

    fn season_rows(&self) -> Vec<SeerrSeasonRow> {
        let t = &self.translator;
        let Some(d) = &self.detail else {
            return Vec::new();
        };
        d.seasons
            .iter()
            .map(|s| SeerrSeasonRow {
                number: s.number,
                title: t.t_args("Staffel %lld", &[Arg::Int(s.number)]),
                episodes: (s.episodes > 0)
                    .then(|| t.t_args("· %lld Folgen", &[Arg::Int(s.episodes)])),
                requestable: s.state.requestable(),
                selected: self.selected.contains(&s.number),
                note: (!s.state.requestable()).then(|| {
                    t.t(if s.state == SeerrState::Present {
                        "vorhanden"
                    } else {
                        "unterwegs"
                    })
                }),
            })
            .collect()
    }

    fn rebuild(&mut self, error: Option<Option<String>>, flags: (bool, bool, bool)) {
        // flags = (running, sheet_open, disturbed)
        let Some(old) = self.page.take() else { return };
        let t = &self.translator;
        let state = old.state;
        let (running, sheet_open, disturbed) = flags;
        let button_text = if running {
            t.t("Wird angefragt…")
        } else if self.confirmed {
            t.t(CONFIRMATIONS[self.wording])
        } else {
            t.t("Anfragen")
        };
        let count = self.selected.len() as i64;
        let note = if self.requested {
            Some(t.t("Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
        } else if state.requestable() {
            None
        } else {
            Some(state_hint(t, state))
        };
        let seasons = self.season_rows();
        let hit = old.hit.clone();
        self.page = Some(SeerrPart {
            version: old.version + 1,
            state,
            backdrop: hit.backdrop(780),
            secondary_line: self.secondary_line(&hit),
            status_word: state_word(t, state),
            rating: self
                .detail
                .as_ref()
                .and_then(|d| d.rating)
                .filter(|r| *r > 0.0),
            description: self.detail.as_ref().and_then(|d| d.description.clone()),
            cast: self.detail.as_ref().map_or_else(Vec::new, |d| {
                d.cast
                    .iter()
                    .take(12)
                    .map(|p| SeerrCast {
                        name: p.name.clone(),
                        role: p.role.clone(),
                        image: p.image(185),
                    })
                    .collect()
            }),
            similar: self.detail.as_ref().map_or_else(Vec::new, |d| {
                d.similar_one.iter().map(|h| self.tile(h)).collect()
            }),
            can_request: !self.requested && state.requestable(),
            button_text,
            button_checked: self.confirmed,
            note,
            running,
            sheet_open,
            seasons,
            sheet_button: if count == 0 {
                t.t("Staffel wählen")
            } else {
                t.t_args("%lld anfragen", &[Arg::Int(count)])
            },
            sheet_button_enabled: count > 0,
            error: error.unwrap_or(old.error),
            disturbed,
            hit,
        });
    }

    fn flags(&self) -> (bool, bool, bool) {
        self.page.as_ref().map_or((false, false, false), |p| {
            (p.running, p.sheet_open, p.disturbed)
        })
    }

    /// Takes an intent and returns what the host must run.
    pub fn handle(&mut self, intent: SeerrIntent) -> Vec<SeerrEffect> {
        match intent {
            SeerrIntent::Search(term) => {
                if swiftly_rules::display_rules::search_term_fits(&term) {
                    vec![SeerrEffect::Search(term)]
                } else {
                    self.discover.version += 1;
                    self.discover.term = term;
                    self.discover.tiles.clear();
                    Vec::new()
                }
            }
            SeerrIntent::SearchLoaded { term, hits } => {
                self.discover.tiles = hits.iter().map(|h| self.tile(h)).collect();
                self.discover.term = term;
                self.discover.version += 1;
                Vec::new()
            }
            SeerrIntent::Open(hit) => {
                let (art, id) = (hit.art.clone(), hit.id);
                self.detail = None;
                self.selected.clear();
                self.confirmed = false;
                self.requested = false;
                self.after_request = false;
                self.wording = 0;
                self.page = Some(SeerrPart {
                    version: 0,
                    state: hit.state,
                    backdrop: None,
                    secondary_line: String::new(),
                    status_word: String::new(),
                    rating: None,
                    description: None,
                    cast: Vec::new(),
                    similar: Vec::new(),
                    can_request: false,
                    button_text: String::new(),
                    button_checked: false,
                    note: None,
                    running: false,
                    sheet_open: false,
                    seasons: Vec::new(),
                    sheet_button: String::new(),
                    sheet_button_enabled: false,
                    error: None,
                    disturbed: false,
                    hit,
                });
                self.rebuild(None, (false, false, false));
                vec![SeerrEffect::LoadDetail { art, id }]
            }
            SeerrIntent::DetailLoaded(found) => self.detail_loaded(found),
            SeerrIntent::Press { roll } => self.press(roll),
            SeerrIntent::ToggleSeason(number) => {
                let ok = self.detail.as_ref().is_some_and(|d| {
                    d.seasons
                        .iter()
                        .any(|s| s.number == number && s.state.requestable())
                });
                if ok && !self.selected.remove(&number) {
                    self.selected.insert(number);
                }
                let f = self.flags();
                self.rebuild(None, f);
                Vec::new()
            }
            SeerrIntent::CloseSheet => {
                let (r, _, d) = self.flags();
                self.rebuild(None, (r, false, d));
                Vec::new()
            }
            SeerrIntent::ConfirmSeasons => {
                let (r, _, d) = self.flags();
                self.rebuild(None, (r, false, d));
                self.ask()
            }
            SeerrIntent::Asked(error) => self.asked(error),
            SeerrIntent::DismissError => {
                let f = self.flags();
                self.rebuild(Some(None), f);
                Vec::new()
            }
            SeerrIntent::ConfirmExpired => {
                // After an error it stays; likewise while the request runs.
                let (running, _, _) = self.flags();
                let has_error = self.page.as_ref().is_some_and(|p| p.error.is_some());
                if self.confirmed && !running && !has_error {
                    self.confirmed = false;
                    let f = self.flags();
                    self.rebuild(None, f);
                }
                Vec::new()
            }
        }
    }

    fn detail_loaded(&mut self, found: Option<SeerrDetail>) -> Vec<SeerrEffect> {
        let Some(p) = &mut self.page else {
            return Vec::new();
        };
        let disturbed = found.is_none();
        if let Some(d) = found {
            // The server knows better than the search hit from before.
            if let Some(new) = d.state {
                p.state = new;
            }
            self.detail = Some(d);
        }
        let mut running = p.running;
        let sheet = p.sheet_open;
        if self.after_request {
            self.after_request = false;
            running = false;
            if p.state.requestable() {
                p.state = SeerrState::WaitsSharing;
            }
            self.requested = p.state == SeerrState::WaitsSharing;
        }
        self.rebuild(None, (running, sheet, disturbed));
        Vec::new()
    }

    fn press(&mut self, roll: usize) -> Vec<SeerrEffect> {
        let Some(p) = &self.page else {
            return Vec::new();
        };
        if p.running || !p.can_request {
            return Vec::new();
        }
        if p.hit.is_series() {
            let (r, _, d) = self.flags();
            self.rebuild(None, (r, true, d));
            return Vec::new();
        }
        if !self.confirmed {
            // Roll once, and not the same as last time.
            let others: Vec<usize> = (0..CONFIRMATIONS.len())
                .filter(|i| *i != self.wording)
                .collect();
            self.wording = others[roll % others.len()];
            self.confirmed = true;
            let f = self.flags();
            self.rebuild(None, f);
            return vec![SeerrEffect::StartConfirmTimer];
        }
        self.ask()
    }

    fn ask(&mut self) -> Vec<SeerrEffect> {
        let Some(p) = &self.page else {
            return Vec::new();
        };
        let (art, id) = (p.hit.art.clone(), p.hit.id);
        // Never empty for a series: `nil` would mean "all seasons" to Seerr.
        let seasons = if p.hit.is_series() {
            if self.selected.is_empty() {
                return Vec::new();
            }
            Some(self.selected.iter().copied().collect::<Vec<_>>())
        } else {
            None
        };
        let (_, s, d) = self.flags();
        self.rebuild(Some(None), (true, s, d));
        vec![SeerrEffect::Ask { art, id, seasons }]
    }

    fn asked(&mut self, error: Option<ErrorKind>) -> Vec<SeerrEffect> {
        let Some(p) = &self.page else {
            return Vec::new();
        };
        match error {
            Some(e) => {
                let text = readable_error(&self.translator, &e);
                let (_, s, d) = self.flags();
                self.rebuild(Some(Some(text)), (false, s, d));
                Vec::new()
            }
            None => {
                // Read the state, do not assume: Seerr may approve at once.
                let (art, id) = (p.hit.art.clone(), p.hit.id);
                self.selected.clear();
                self.after_request = true;
                let f = self.flags();
                self.rebuild(None, f);
                vec![SeerrEffect::LoadDetail { art, id }]
            }
        }
    }

    /// Runs one effect over a client and returns the intent to feed back (`None` for the timer,
    /// which the host runs itself).
    pub async fn run<T: HttpTransport, J: CookieJar>(
        effect: SeerrEffect,
        client: &SeerrClient<T, J>,
    ) -> Option<SeerrIntent> {
        match effect {
            SeerrEffect::Search(term) => {
                let hits = client.searching(&term).await;
                Some(SeerrIntent::SearchLoaded { term, hits })
            }
            SeerrEffect::LoadDetail { art, id } => {
                Some(SeerrIntent::DetailLoaded(client.detail(&art, id).await))
            }
            SeerrEffect::Ask { art, id, seasons } => {
                let r = client.ask_for(&art, id, seasons.as_deref()).await;
                Some(SeerrIntent::Asked(r.err()))
            }
            SeerrEffect::StartConfirmTimer => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_executor::block_on;
    use swiftly_net::{Method, MockTransport};
    use swiftly_seerr::SeerrAccess;
    use swiftly_seerr::mapping::Seerr;

    const ANSWER: &str = r#"{"results":[
      {"id":1,"mediaType":"movie","title":"Lighthouse Live","releaseDate":"2014-03-01","posterPath":"/abc.jpg","backdropPath":"/q.jpg"},
      {"id":2,"mediaType":"tv","name":"The Lighthouse","firstAirDate":"2008-09-23","posterPath":"/def.jpg","mediaInfo":{"status":5}},
      {"id":3,"mediaType":"tv","name":"UK","firstAirDate":"2011-01-01","mediaInfo":{"status":2}},
      {"id":4,"mediaType":"person","name":"Simon Baker"}]}"#;

    const DETAIL_TV: &str = r#"{"overview":"Text","genres":[{"name":"Krimi"},{"name":"Drama"}],
      "voteAverage":8.1,"mediaInfo":{"status":1,"seasons":[{"seasonNumber":1,"status":5}]},
      "seasons":[{"seasonNumber":0,"episodeCount":3},{"seasonNumber":1,"episodeCount":10},
                 {"seasonNumber":2,"episodeCount":12},{"seasonNumber":3,"episodeCount":0}]}"#;

    fn hit(id: i64) -> SeerrHit {
        Seerr::hit_from_search(ANSWER.as_bytes())
            .into_iter()
            .find(|h| h.id == id)
            .unwrap()
    }

    fn vm() -> SeerrVm {
        SeerrVm::new(Locale::parse("de"))
    }

    fn detail(json: &str) -> SeerrDetail {
        Seerr::detail(json.as_bytes()).unwrap()
    }

    #[test]
    fn a_search_gives_tiles_with_short_words_and_no_people() {
        let mut vm = vm();
        let eff = vm.handle(SeerrIntent::Search("Lighthouse".into()));
        assert_eq!(eff, vec![SeerrEffect::Search("Lighthouse".into())]);
        vm.handle(SeerrIntent::SearchLoaded {
            term: "Lighthouse".into(),
            hits: Seerr::hit_from_search(ANSWER.as_bytes()),
        });
        let tiles = &vm.discover().tiles;
        assert_eq!(tiles.len(), 3);
        assert_eq!(tiles[0].short_word, None);
        assert_eq!(tiles[1].short_word, None); // present: no word on the tile
        assert_eq!(tiles[2].short_word.as_deref(), Some("wartet"));
        assert_eq!(
            tiles[0].poster.as_deref(),
            Some("https://image.tmdb.org/t/p/w342/abc.jpg")
        );
        assert_eq!(tiles[0].announcement, "kann angefragt werden");
    }

    #[test]
    fn a_term_that_does_not_fit_asks_nothing_and_clears_the_rail() {
        let mut vm = vm();
        vm.handle(SeerrIntent::SearchLoaded {
            term: "x".into(),
            hits: vec![hit(1)],
        });
        assert_eq!(vm.discover().tiles.len(), 1);
        assert!(vm.handle(SeerrIntent::Search(String::new())).is_empty());
        assert!(vm.discover().tiles.is_empty());
    }

    #[test]
    fn opening_a_page_loads_the_detail_and_the_server_state_wins() {
        let mut vm = vm();
        let eff = vm.handle(SeerrIntent::Open(hit(2)));
        assert_eq!(
            eff,
            vec![SeerrEffect::LoadDetail {
                art: "tv".into(),
                id: 2
            }]
        );
        assert_eq!(vm.page().unwrap().state, SeerrState::Present);
        vm.handle(SeerrIntent::DetailLoaded(Some(detail(DETAIL_TV))));
        let p = vm.page().unwrap();
        assert_eq!(p.state, SeerrState::Opened);
        assert!(p.can_request);
        assert_eq!(p.secondary_line, "2008 · 3 Staffeln · Krimi, Drama");
        assert_eq!(p.rating, Some(8.1));
        assert!(!p.disturbed);
    }

    #[test]
    fn a_failed_detail_marks_the_page_disturbed_and_keeps_the_hit_state() {
        let mut vm = vm();
        vm.handle(SeerrIntent::Open(hit(3)));
        vm.handle(SeerrIntent::DetailLoaded(None));
        let p = vm.page().unwrap();
        assert!(p.disturbed);
        assert_eq!(p.state, SeerrState::WaitsSharing);
        assert!(!p.can_request);
        assert_eq!(
            p.note.as_deref(),
            Some("Deine Anfrage liegt beim Verwalter des Servers. Du musst nichts weiter tun.")
        );
        // The year is there, so no kind word (as in the Swift page).
        assert_eq!(p.secondary_line, "2011");
    }

    #[test]
    fn a_movie_needs_two_taps_and_the_question_times_out() {
        let mut vm = vm();
        vm.handle(SeerrIntent::Open(hit(1)));
        assert_eq!(vm.page().unwrap().button_text, "Anfragen");
        let eff = vm.handle(SeerrIntent::Press { roll: 0 });
        assert_eq!(eff, vec![SeerrEffect::StartConfirmTimer]);
        let p = vm.page().unwrap();
        assert!(p.button_checked);
        assert_ne!(p.button_text, "Anfragen");
        let first = p.button_text.clone();
        vm.handle(SeerrIntent::ConfirmExpired);
        assert_eq!(vm.page().unwrap().button_text, "Anfragen");
        // The next question is never the same wording as the one before.
        vm.handle(SeerrIntent::Press { roll: 0 });
        let second = vm.page().unwrap().button_text.clone();
        assert!(CONFIRMATIONS.contains(&second.as_str()));
        let _ = first;
    }

    #[test]
    fn the_second_tap_asks_without_seasons_and_the_state_is_read_back() {
        let mut vm = vm();
        vm.handle(SeerrIntent::Open(hit(1)));
        vm.handle(SeerrIntent::Press { roll: 1 });
        let eff = vm.handle(SeerrIntent::Press { roll: 1 });
        assert_eq!(
            eff,
            vec![SeerrEffect::Ask {
                art: "movie".into(),
                id: 1,
                seasons: None
            }]
        );
        let p = vm.page().unwrap();
        assert!(p.running);
        assert_eq!(p.button_text, "Wird angefragt…");
        // While it runs, a tap does nothing.
        assert!(vm.handle(SeerrIntent::Press { roll: 1 }).is_empty());
        let eff = vm.handle(SeerrIntent::Asked(None));
        assert_eq!(
            eff,
            vec![SeerrEffect::LoadDetail {
                art: "movie".into(),
                id: 1
            }]
        );
        // The detail still says "open": the page then shows "waits for approval".
        vm.handle(SeerrIntent::DetailLoaded(Some(detail(
            r#"{"mediaInfo":{"status":1}}"#,
        ))));
        let p = vm.page().unwrap();
        assert!(!p.running && !p.can_request);
        assert_eq!(p.state, SeerrState::WaitsSharing);
        assert_eq!(
            p.note.as_deref(),
            Some("Angefragt. Sobald sie freigegeben ist, lädt sie von selbst.")
        );
    }

    #[test]
    fn an_immediate_approval_is_shown_as_it_is() {
        let mut vm = vm();
        vm.handle(SeerrIntent::Open(hit(1)));
        vm.handle(SeerrIntent::Press { roll: 0 });
        vm.handle(SeerrIntent::Press { roll: 0 });
        vm.handle(SeerrIntent::Asked(None));
        vm.handle(SeerrIntent::DetailLoaded(Some(detail(
            r#"{"mediaInfo":{"status":3}}"#,
        ))));
        let p = vm.page().unwrap();
        assert_eq!(p.state, SeerrState::Loads);
        assert_eq!(
            p.note.as_deref(),
            Some("Deine Anfrage ist durch. Der Titel erscheint von selbst in deiner Bibliothek.")
        );
    }

    #[test]
    fn a_series_opens_the_sheet_and_never_asks_for_all_seasons() {
        let mut vm = vm();
        vm.handle(SeerrIntent::Open(hit(2)));
        vm.handle(SeerrIntent::DetailLoaded(Some(detail(DETAIL_TV))));
        assert!(vm.handle(SeerrIntent::Press { roll: 0 }).is_empty());
        let p = vm.page().unwrap();
        assert!(p.sheet_open);
        assert_eq!(p.sheet_button, "Staffel wählen");
        assert!(!p.sheet_button_enabled);
        // Nothing ticked: the sheet's button asks nothing.
        assert!(vm.handle(SeerrIntent::ConfirmSeasons).is_empty());
        assert!(!vm.page().unwrap().running);
    }

    #[test]
    fn season_rows_tick_only_requestable_seasons_and_ask_sorted() {
        let mut vm = vm();
        vm.handle(SeerrIntent::Open(hit(2)));
        vm.handle(SeerrIntent::DetailLoaded(Some(detail(DETAIL_TV))));
        vm.handle(SeerrIntent::Press { roll: 0 });
        let rows = vm.page().unwrap().seasons.clone();
        let one = rows.iter().find(|r| r.number == 1).unwrap();
        assert_eq!(one.title, "Staffel 1");
        assert_eq!(one.episodes.as_deref(), Some("· 10 Folgen"));
        assert!(!one.requestable);
        assert_eq!(one.note.as_deref(), Some("vorhanden"));
        assert_eq!(rows.iter().find(|r| r.number == 3).unwrap().episodes, None);
        // A season that is there cannot be ticked.
        vm.handle(SeerrIntent::ToggleSeason(1));
        assert!(!vm.page().unwrap().sheet_button_enabled);
        vm.handle(SeerrIntent::ToggleSeason(3));
        vm.handle(SeerrIntent::ToggleSeason(2));
        assert_eq!(vm.page().unwrap().sheet_button, "2 anfragen");
        vm.handle(SeerrIntent::ToggleSeason(3));
        vm.handle(SeerrIntent::ToggleSeason(3));
        let eff = vm.handle(SeerrIntent::ConfirmSeasons);
        assert_eq!(
            eff,
            vec![SeerrEffect::Ask {
                art: "tv".into(),
                id: 2,
                seasons: Some(vec![2, 3])
            }]
        );
        assert!(!vm.page().unwrap().sheet_open);
        vm.handle(SeerrIntent::Asked(None));
        assert!(vm.page().unwrap().seasons.iter().all(|r| !r.selected));
    }

    #[test]
    fn an_error_stays_until_dismissed_and_keeps_the_question_open() {
        let mut vm = vm();
        vm.handle(SeerrIntent::Open(hit(1)));
        vm.handle(SeerrIntent::Press { roll: 0 });
        vm.handle(SeerrIntent::Press { roll: 0 });
        vm.handle(SeerrIntent::Asked(Some(ErrorKind::Network { code: -1009 })));
        let p = vm.page().unwrap();
        assert!(!p.running && p.error.is_some());
        // After an error the question stands: the next tap is the retry.
        vm.handle(SeerrIntent::ConfirmExpired);
        assert!(vm.page().unwrap().button_checked);
        let eff = vm.handle(SeerrIntent::Press { roll: 0 });
        assert!(matches!(eff.as_slice(), [SeerrEffect::Ask { .. }]));
        assert!(vm.page().unwrap().error.is_none());
        vm.handle(SeerrIntent::Asked(Some(ErrorKind::Http {
            status: 500,
            body: None,
        })));
        vm.handle(SeerrIntent::DismissError);
        assert!(vm.page().unwrap().error.is_none());
    }

    #[test]
    fn state_words_follow_the_mark_table() {
        let t = Translator::new(Locale::parse("de"));
        assert_eq!(
            state_word(&t, SeerrState::Deleted),
            "Nicht auf deinem Server"
        );
        assert_eq!(
            state_word(&t, SeerrState::PartWayPresent),
            "Teilweise vorhanden"
        );
        assert_eq!(
            state_hint(&t, SeerrState::Present),
            "Dieser Titel liegt bereits auf deinem Server."
        );
        assert_eq!(
            short_word(&t, SeerrState::Loads).as_deref(),
            Some("angefragt")
        );
        assert_eq!(short_word(&t, SeerrState::Deleted), None);
    }

    #[test]
    fn run_asks_the_client_and_hands_back_the_intent() {
        let mock = MockTransport::new()
            .route("search", 200, ANSWER)
            .route_method(Method::Post, "request", 409, "{}");
        let client = SeerrClient::new(
            SeerrAccess::new("https://s.example", "connect.sid=a", &[]),
            mock,
        );
        block_on(async {
            let Some(SeerrIntent::SearchLoaded { hits, .. }) =
                SeerrVm::run(SeerrEffect::Search("m".into()), &client).await
            else {
                panic!("search")
            };
            assert_eq!(hits.len(), 3);
            // 409 (someone was faster) is no error.
            let Some(SeerrIntent::Asked(e)) = SeerrVm::run(
                SeerrEffect::Ask {
                    art: "movie".into(),
                    id: 1,
                    seasons: None,
                },
                &client,
            )
            .await
            else {
                panic!("ask")
            };
            assert!(e.is_none());
        });
    }
}
