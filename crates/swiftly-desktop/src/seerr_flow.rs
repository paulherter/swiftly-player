//! The Seerr side of the desktop pages: the search block "Über Seerr anfragen", the Seerr title page and the person
//! page's request rail. One [`Flow`] drives the core's [`SeerrVm`]: it answers the effects (`searching`, `detail`,
//! `askFor`, the five-second timer of the second tap) through a [`Backend`] and feeds the answers back as intents, the
//! way the Mac's `SeerrCore.Flow` does. Without a stored Seerr session there is no backend and nothing shows at all
//! (an add-on leaves no hole).

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use swiftly_l10n::Locale;
use swiftly_net::ErrorKind;
use swiftly_seerr::models::{SeerrDetail, SeerrHit};
use swiftly_seerr::{NoCookies, SeerrAccess, SeerrClient};
use swiftly_settings::{KeyValueStore, Value};
use swiftly_vm::{SeerrEffect, SeerrIntent, SeerrVm};

/// The wait before a search goes out, so a word typed in a row asks Seerr once (the Mac sleeps 300 ms).
pub const SEARCH_WAIT: Duration = Duration::from_millis(300);

/// What a call to Seerr brought back.
#[derive(Debug)]
pub enum Reply {
    /// `searching`.
    Search {
        /// The term it was for.
        term: String,
        /// The hits.
        hits: Vec<SeerrHit>,
    },
    /// `detail` (`None`: the call failed).
    Detail(Option<SeerrDetail>),
    /// `askFor` (`None`: accepted).
    Asked(Option<ErrorKind>),
    /// `filmography` of a person.
    Films(Vec<SeerrHit>),
}

/// Where the replies land.
pub type Inbox = Arc<Mutex<Vec<Reply>>>;

/// The calls to Seerr. Each one answers into the inbox from wherever it runs.
pub trait Backend: Send + Sync {
    /// Seerr's address, for the "does not answer" text.
    fn address(&self) -> String;
    /// `searching`.
    fn search(&self, term: String, inbox: Inbox);
    /// `detail`.
    fn detail(&self, art: String, id: i64, inbox: Inbox);
    /// `askFor`.
    fn ask(&self, art: String, id: i64, seasons: Option<Vec<i64>>, inbox: Inbox);
    /// `filmography`.
    fn filmography(&self, tmdb: i64, inbox: Inbox);
}

fn put(inbox: &Inbox, reply: Reply) {
    inbox
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .push(reply);
}

/// Seerr over the real transport, with the session of the Settings page.
pub struct Live {
    core: Arc<crate::live::Core>,
    access: SeerrAccess,
}

impl Live {
    /// The backend of the stored session; `None` when Seerr is not connected.
    pub fn stored(core: &Arc<crate::live::Core>) -> Option<Arc<dyn Backend>> {
        let Some(Value::Data(d)) = core.settings.get("seerr") else {
            return None;
        };
        let access = serde_json::from_slice::<SeerrAccess>(&d).ok()?;
        Some(Arc::new(Live {
            core: Arc::clone(core),
            access,
        }))
    }

    fn client(&self) -> SeerrClient<crate::seerr_link::Shared, NoCookies> {
        SeerrClient::with_jar(
            self.access.clone(),
            crate::seerr_link::Shared(Arc::clone(&self.core.net)),
            NoCookies,
        )
    }
}

impl Backend for Live {
    fn address(&self) -> String {
        self.access.address.clone()
    }
    fn search(&self, term: String, inbox: Inbox) {
        let client = self.client();
        self.core.spawn(async move {
            let hits = client.searching(&term).await;
            put(&inbox, Reply::Search { term, hits });
        });
    }
    fn detail(&self, art: String, id: i64, inbox: Inbox) {
        let client = self.client();
        self.core.spawn(async move {
            put(&inbox, Reply::Detail(client.detail(&art, id).await));
        });
    }
    fn ask(&self, art: String, id: i64, seasons: Option<Vec<i64>>, inbox: Inbox) {
        let client = self.client();
        self.core.spawn(async move {
            let got = client.ask_for(&art, id, seasons.as_deref()).await;
            put(&inbox, Reply::Asked(got.err()));
        });
    }
    fn filmography(&self, tmdb: i64, inbox: Inbox) {
        let client = self.client();
        self.core.spawn(async move {
            put(&inbox, Reply::Films(client.filmography(tmdb).await));
        });
    }
}

/// The view model with the host around it.
pub struct Flow {
    vm: SeerrVm,
    backend: Arc<dyn Backend>,
    inbox: Inbox,
    /// A term waiting for its 300 ms.
    waiting: Option<(String, Instant)>,
    /// The second tap's time runs out at this moment.
    confirm_by: Option<Instant>,
    /// The person's filmography, once it came (`None` while out).
    films: Option<Vec<SeerrHit>>,
    /// Bumps with every change the page has to draw.
    changed: u64,
    /// Calls out to Seerr that have not answered yet.
    pending: u32,
}

impl Flow {
    /// A flow over `backend`.
    pub fn new(backend: Arc<dyn Backend>, locale: Locale) -> Flow {
        Flow {
            vm: SeerrVm::new(locale),
            backend,
            inbox: Inbox::default(),
            waiting: None,
            confirm_by: None,
            films: None,
            changed: 0,
            pending: 0,
        }
    }

    /// The model.
    pub fn vm(&self) -> &SeerrVm {
        &self.vm
    }

    /// Seerr's address.
    pub fn address(&self) -> String {
        self.backend.address()
    }

    /// The filmography of a person once it came.
    pub fn films(&self) -> Option<&[SeerrHit]> {
        self.films.as_deref()
    }

    /// Grows whenever something the page shows changed.
    pub fn changed(&self) -> u64 {
        self.changed
    }

    /// The term of the search box changed: it goes out after [`SEARCH_WAIT`], a newer one replaces it.
    pub fn search(&mut self, term: &str, now: Instant) {
        let clean = term.trim().to_owned();
        if self.vm.discover().term == clean && self.waiting.is_none() {
            return;
        }
        if !swiftly_rules::display_rules::search_term_fits(&clean) {
            self.waiting = None;
            self.send(SeerrIntent::Search(clean));
            return;
        }
        self.waiting = Some((clean, now + SEARCH_WAIT));
    }

    /// A tile was opened.
    pub fn open(&mut self, hit: SeerrHit) {
        self.send(SeerrIntent::Open(hit));
    }

    /// Asks Seerr for the filmography of a person (the person page's rail).
    pub fn ask_films(&mut self, tmdb: i64) {
        self.films = None;
        self.pending += 1;
        self.backend.filmography(tmdb, Arc::clone(&self.inbox));
    }

    /// Hands an intent to the model and runs what it asks for.
    pub fn send(&mut self, intent: SeerrIntent) {
        let fx = self.vm.handle(intent);
        self.changed += 1;
        for e in fx {
            match e {
                SeerrEffect::Search(term) => {
                    self.pending += 1;
                    self.backend.search(term, Arc::clone(&self.inbox));
                }
                SeerrEffect::LoadDetail { art, id } => {
                    self.pending += 1;
                    self.backend.detail(art, id, Arc::clone(&self.inbox));
                }
                SeerrEffect::Ask { art, id, seasons } => {
                    self.pending += 1;
                    self.backend.ask(art, id, seasons, Arc::clone(&self.inbox));
                }
                SeerrEffect::StartConfirmTimer => {
                    self.confirm_by = Some(
                        Instant::now() + Duration::from_secs(swiftly_vm::CONFIRM_STANDS_SECONDS),
                    );
                }
            }
        }
    }

    /// Takes the answers and runs the timers; `true` when the page has to be drawn again.
    pub fn poll(&mut self, now: Instant) -> bool {
        let before = self.changed;
        if let Some((term, at)) = self.waiting.clone()
            && now >= at
        {
            self.waiting = None;
            self.send(SeerrIntent::Search(term));
        }
        if let Some(at) = self.confirm_by
            && now >= at
        {
            self.confirm_by = None;
            self.send(SeerrIntent::ConfirmExpired);
        }
        let got: Vec<Reply> = std::mem::take(
            &mut *self
                .inbox
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        );
        for r in got {
            self.pending = self.pending.saturating_sub(1);
            match r {
                Reply::Search { term, hits } => {
                    // Anything already on the own server belongs in the library block.
                    let hits = hits
                        .into_iter()
                        .filter(|h| !h.state.already_present())
                        .collect();
                    self.send(SeerrIntent::SearchLoaded { term, hits });
                }
                Reply::Detail(d) => self.send(SeerrIntent::DetailLoaded(d)),
                Reply::Asked(e) => self.send(SeerrIntent::Asked(e)),
                Reply::Films(h) => {
                    self.films = Some(h);
                    self.changed += 1;
                }
            }
        }
        self.changed != before
    }

    /// Whether a timer or a call is still out, so the screen keeps asking.
    pub fn busy(&self) -> bool {
        self.pending > 0
            || self.waiting.is_some()
            || self.confirm_by.is_some()
            || self.vm.page().is_some_and(|p| p.running)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use swiftly_seerr::models::SeerrState;

    /// Answers at once from a script, the way a quick Seerr would.
    #[derive(Default)]
    pub(crate) struct Script {
        pub(crate) calls: Mutex<Vec<String>>,
        pub(crate) hits: Vec<SeerrHit>,
        pub(crate) detail: Option<SeerrDetail>,
    }
    impl Backend for Script {
        fn address(&self) -> String {
            "https://seerr.example".into()
        }
        fn search(&self, term: String, inbox: Inbox) {
            self.calls.lock().unwrap().push(format!("search {term}"));
            put(
                &inbox,
                Reply::Search {
                    term,
                    hits: self.hits.clone(),
                },
            );
        }
        fn detail(&self, art: String, id: i64, inbox: Inbox) {
            self.calls
                .lock()
                .unwrap()
                .push(format!("detail {art} {id}"));
            put(&inbox, Reply::Detail(self.detail.clone()));
        }
        fn ask(&self, art: String, id: i64, seasons: Option<Vec<i64>>, inbox: Inbox) {
            self.calls
                .lock()
                .unwrap()
                .push(format!("ask {art} {id} {seasons:?}"));
            put(&inbox, Reply::Asked(None));
        }
        fn filmography(&self, tmdb: i64, inbox: Inbox) {
            self.calls.lock().unwrap().push(format!("films {tmdb}"));
            put(&inbox, Reply::Films(self.hits.clone()));
        }
    }

    pub(crate) fn hit(id: i64, state: SeerrState) -> SeerrHit {
        SeerrHit {
            id,
            art: "movie".into(),
            title: format!("Film {id}"),
            year: Some(2019),
            poster_path: None,
            backdrop_path: None,
            state,
        }
    }

    fn flow(hits: Vec<SeerrHit>) -> (Flow, Arc<Script>) {
        let script = Arc::new(Script {
            hits,
            ..Script::default()
        });
        let b = Arc::clone(&script) as Arc<dyn Backend>;
        (Flow::new(b, Locale::parse("de")), script)
    }

    #[test]
    fn a_search_waits_300_ms_asks_once_and_drops_what_the_own_server_has() {
        let (mut f, script) = flow(vec![
            hit(1, SeerrState::Opened),
            hit(2, SeerrState::Present),
            hit(3, SeerrState::Loads),
        ]);
        let t0 = Instant::now();
        f.search("lic", t0);
        f.search("licht", t0 + Duration::from_millis(100));
        assert!(!f.poll(t0 + Duration::from_millis(350)), "not yet");
        assert!(script.calls.lock().unwrap().is_empty());
        assert!(f.poll(t0 + Duration::from_millis(450)));
        assert_eq!(*script.calls.lock().unwrap(), vec!["search licht"]);
        let ids: Vec<i64> = f.vm().discover().tiles.iter().map(|t| t.hit.id).collect();
        assert_eq!(ids, vec![1, 3]);
    }

    #[test]
    fn a_term_too_short_clears_the_block_without_a_call() {
        let (mut f, script) = flow(vec![hit(1, SeerrState::Opened)]);
        let t0 = Instant::now();
        f.search("licht", t0);
        f.poll(t0 + SEARCH_WAIT);
        assert_eq!(f.vm().discover().tiles.len(), 1);
        f.search("l", t0);
        assert!(f.vm().discover().tiles.is_empty());
        assert_eq!(script.calls.lock().unwrap().len(), 1);
    }

    #[test]
    fn opening_a_tile_loads_the_detail_and_a_failed_call_shows_as_disturbed() {
        let (mut f, script) = flow(vec![]);
        f.open(hit(7, SeerrState::Opened));
        f.poll(Instant::now());
        assert_eq!(*script.calls.lock().unwrap(), vec!["detail movie 7"]);
        assert!(f.vm().page().is_some_and(|p| p.disturbed));
    }

    #[test]
    fn the_filmography_of_a_person_arrives_through_the_inbox() {
        let (mut f, _) = flow(vec![hit(4, SeerrState::Opened)]);
        assert!(f.films().is_none());
        f.ask_films(77);
        assert!(f.poll(Instant::now()));
        assert_eq!(f.films().map(<[SeerrHit]>::len), Some(1));
    }
}
