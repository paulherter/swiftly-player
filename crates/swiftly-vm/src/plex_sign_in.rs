//! The Plex and Emby sign-in pages as state (`Sources/Shared/SignInModels.swift`,
//! `PlexRun` in `AppModel+Servers.swift`, `P/SignInModels.kt`).
//!
//! **What the screen shows, and nothing that talks to a server.** The host runs the network
//! steps and feeds the answers in; the model says which step is on screen, what the title is
//! and where the arrow at the top leads. One place for the steps, so the pages of every
//! platform cannot drift apart.
//!
//! Swift keeps the failures in one step with a payload ([`PlexStep::Failed`]); the Kotlin twin
//! has three steps for them. This is the Swift shape.

use std::collections::BTreeSet;

use swiftly_jellyfin::EmbyProblem;
use swiftly_l10n::{Arg, Translator};
use swiftly_plex::PlexError;

// MARK: Plex

/// One server of the Plex account, as the list needs it (`PlexServerChoice`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexServerChoice {
    /// The machine identifier.
    pub id: String,
    /// Display name.
    pub name: String,
    /// `None` = the account's own server; otherwise whoever shared it. An empty string means
    /// the sharing account is unknown (the row says "einem anderen Konto").
    pub shared_by: Option<String>,
    /// One of its addresses is in the local network.
    pub local: bool,
    /// plex.tv's `presence`. Shown, not trusted: the list stays tappable either way.
    pub online: bool,
}

impl PlexServerChoice {
    /// The "shared by" line of the row, `None` for the account's own server.
    pub fn shared_by_text(&self, tr: &Translator) -> Option<String> {
        self.shared_by.as_ref().map(|who| {
            if who.is_empty() {
                tr.t("einem anderen Konto")
            } else {
                who.clone()
            }
        })
    }
}

/// A person of the Plex Home (`PlexProfileChoice`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexProfileChoice {
    /// The Plex Home user id.
    pub id: String,
    /// Name.
    pub name: String,
    /// Picture address.
    pub image: Option<String>,
    /// Switching to it asks for the four-digit PIN.
    pub protected: bool,
}

/// What the browser sign-in needs (`PlexPinPrompt`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexPinPrompt {
    /// The plex.tv auth page, or the link page on a TV.
    pub url: String,
    /// The short code to type at plex.tv/link; `None` hides the row.
    pub code: Option<String>,
    /// Seconds until the code expires; `None` hides the countdown.
    pub seconds_left: Option<i64>,
}

/// Errors that end the flow (`PlexSignInProblem`). Problems with one server stay in its row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlexSignInProblem {
    /// plex.tv did not answer at all.
    PlexUnreachable,
    /// The code expired before the sign-in was finished.
    Expired,
    /// Anything else, with the sentence to show (already translated).
    Other(String),
}

impl PlexSignInProblem {
    /// Headline and text of the empty state that tells the problem.
    pub fn texts(&self, tr: &Translator) -> (String, String) {
        match self {
            Self::PlexUnreachable => (
                tr.t("plex.tv antwortet nicht"),
                tr.t("Ohne plex.tv klappt die Anmeldung nicht. Hängt vielleicht das WLAN?"),
            ),
            Self::Expired => (
                tr.t("Die Anmeldung ist abgelaufen"),
                tr.t("Der Code war zu lange offen. Hol dir einfach einen neuen."),
            ),
            Self::Other(message) => (tr.t("Anmeldung hat nicht geklappt"), message.clone()),
        }
    }

    /// The problem a [`PlexError`] ends the flow with (`PlexRun.fail`). `None` for
    /// [`PlexError::NoServer`]: that is not a failure, the server list is just empty.
    /// `readable` gives the sentence for anything that has no case of its own.
    pub fn from_error(error: &PlexError, readable: impl FnOnce() -> String) -> Option<Self> {
        use swiftly_net::ErrorKind;
        match error {
            PlexError::PinExpired => Some(Self::Expired),
            PlexError::NoServer => None,
            PlexError::Request(ErrorKind::Network { .. } | ErrorKind::Transport(_)) => {
                Some(Self::PlexUnreachable)
            }
            _ => Some(Self::Other(readable())),
        }
    }
}

/// What the placeholders in the shape of the next step look like (`Placeholder`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Placeholder {
    /// Profile cards on their way.
    Profiles,
    /// Server rows on their way.
    Servers,
}

/// Where the page is (`PlexSignInModel.Step`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlexStep {
    /// The page with the one button.
    Start,
    /// The button was pressed, the code is being fetched. "Wird geöffnet…"
    Opening,
    /// The browser is open (or was closed unfinished); the connection polls.
    Waiting(PlexPinPrompt),
    /// Signed in, profiles or servers on their way.
    Loading(Placeholder),
    /// Plex Home: who is watching.
    Profiles(Vec<PlexProfileChoice>),
    /// The chosen profile is protected.
    Pin(PlexProfileChoice),
    /// The account's servers; empty = the empty state.
    Servers(Vec<PlexServerChoice>),
    /// The flow ended with a problem.
    Failed(PlexSignInProblem),
}

/// What the core answered to a step; the host maps its reply to this.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlexAnswer {
    /// Still waiting. `url` is set on the first answer; a beat that only says "nothing yet"
    /// has none and keeps the countdown going when `seconds_left` is positive.
    Waiting {
        /// The page to open or to type in.
        url: Option<String>,
        /// The short code, TV only.
        code: Option<String>,
        /// Seconds until the code is gone.
        seconds_left: i64,
    },
    /// Plex Home profiles.
    Profiles {
        /// The plex.tv account's name.
        account: Option<String>,
        /// The people.
        profiles: Vec<PlexProfileChoice>,
    },
    /// The servers of the account.
    Servers {
        /// The plex.tv account's name.
        account: Option<String>,
        /// The chosen profile's name.
        profile: Option<String>,
        /// The servers.
        servers: Vec<PlexServerChoice>,
    },
    /// plex.tv did not answer.
    PlexUnreachable,
    /// The code expired.
    Expired,
    /// Anything else.
    Failed(String),
    /// Signed in and connected; the session is stored.
    Done,
}

/// What [`PlexSignInModel::apply`] tells the host.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Applied {
    /// The answer was `Done`: the page is leaving.
    pub done: bool,
    /// The step left "waiting": the sign-in window of a phone did its job.
    pub waiting_ended: bool,
}

/// The arrow at the top.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Back {
    /// One step back within the flow.
    Stepped,
    /// Out of the flow: stop polling, reset what the core holds, leave the page.
    Leave,
}

/// The Plex sign-in page (`PlexSignInModel`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlexSignInModel {
    /// The step on screen.
    pub step: PlexStep,
    /// The plex.tv account's name once known; it becomes the page title.
    pub account: Option<String>,
    /// The profile chosen in Plex Home; shown above the server list.
    pub profile: Option<String>,
    /// The server being connected to right now.
    pub connecting: Option<String>,
    /// Servers that did not answer at any of their addresses.
    pub unreachable: BTreeSet<String>,
    /// The PIN of the profile was wrong.
    pub pin_wrong: bool,
    /// The PIN is being checked.
    pub pin_checking: bool,
    /// Remembered so the PIN page can go back without asking plex.tv again.
    pub last_profiles: Option<Vec<PlexProfileChoice>>,
}

impl Default for PlexSignInModel {
    fn default() -> Self {
        Self::new()
    }
}

impl PlexSignInModel {
    /// A model on the first page.
    pub fn new() -> Self {
        Self {
            step: PlexStep::Start,
            account: None,
            profile: None,
            connecting: None,
            unreachable: BTreeSet::new(),
            pin_wrong: false,
            pin_checking: false,
            last_profiles: None,
        }
    }

    /// The page title: the account's name once signed in. On the first page it is the action;
    /// while waiting and on failure the kind with its "(Beta)" mark; after that the account.
    pub fn page_title(&self, tr: &Translator) -> String {
        match &self.step {
            PlexStep::Start | PlexStep::Opening => tr.t("Mit Plex anmelden"),
            PlexStep::Waiting(_) | PlexStep::Failed(_) => "Plex (Beta)".into(),
            _ => self.account.clone().unwrap_or_else(|| "Plex".into()),
        }
    }

    /// Back within the flow before leaving it: from the PIN to the profiles, from the servers
    /// to the profiles if there were several. `None` = leave the page.
    pub fn step_back(&self) -> Option<PlexStep> {
        let profiles = self.last_profiles.as_ref().filter(|p| p.len() > 1)?;
        match self.step {
            PlexStep::Pin(_) | PlexStep::Servers(_) | PlexStep::Loading(Placeholder::Servers) => {
                Some(PlexStep::Profiles(profiles.clone()))
            }
            _ => None,
        }
    }

    /// The arrow at the top.
    pub fn go_back(&mut self) -> Back {
        match self.step_back() {
            Some(earlier) => {
                self.step = earlier;
                Back::Stepped
            }
            None => Back::Leave,
        }
    }

    /// "Mit Plex anmelden" and "Neuen Code holen": the code is being fetched.
    pub fn start(&mut self) {
        self.step = PlexStep::Opening;
    }

    /// Takes the core's answer into the page (`PlexSignInModel.apply` in the Kotlin twin).
    pub fn apply(&mut self, answer: PlexAnswer) -> Applied {
        let before_waiting = matches!(self.step, PlexStep::Waiting(_));
        match answer {
            PlexAnswer::Waiting {
                url,
                code,
                seconds_left,
            } => {
                let seconds = (seconds_left > 0).then_some(seconds_left);
                if let Some(url) = url {
                    self.step = PlexStep::Waiting(PlexPinPrompt {
                        url,
                        code,
                        seconds_left: seconds,
                    });
                } else if let (PlexStep::Waiting(prompt), Some(s)) = (&mut self.step, seconds) {
                    // A beat that only says "nothing yet" keeps the countdown.
                    prompt.seconds_left = Some(s);
                }
            }
            PlexAnswer::Profiles { account, profiles } => {
                if account.is_some() {
                    self.account = account;
                }
                self.last_profiles = Some(profiles.clone());
                self.step = PlexStep::Profiles(profiles);
            }
            PlexAnswer::Servers {
                account,
                profile,
                servers,
            } => {
                if account.is_some() {
                    self.account = account;
                }
                self.profile = profile;
                self.unreachable.clear();
                self.step = PlexStep::Servers(servers);
            }
            PlexAnswer::PlexUnreachable => {
                self.step = PlexStep::Failed(PlexSignInProblem::PlexUnreachable);
            }
            PlexAnswer::Expired => self.step = PlexStep::Failed(PlexSignInProblem::Expired),
            PlexAnswer::Failed(message) => {
                self.step = PlexStep::Failed(PlexSignInProblem::Other(message));
            }
            PlexAnswer::Done => {
                return Applied {
                    done: true,
                    waiting_ended: false,
                };
            }
        }
        let waiting_ended = before_waiting && !matches!(self.step, PlexStep::Waiting(_));
        Applied {
            done: false,
            waiting_ended,
        }
    }

    /// A profile was tapped. A protected one asks for its PIN; any other starts the server
    /// look-up. Returns `true` when the host has to switch to the profile now.
    pub fn pick_profile(&mut self, profile: &PlexProfileChoice) -> bool {
        if profile.protected {
            self.pin_wrong = false;
            self.step = PlexStep::Pin(profile.clone());
            return false;
        }
        self.step = PlexStep::Loading(Placeholder::Servers);
        true
    }

    /// Four digits were entered. `false` while an earlier check is still running.
    pub fn submit_pin(&mut self) -> bool {
        if self.pin_checking {
            return false;
        }
        self.pin_checking = true;
        self.pin_wrong = false;
        true
    }

    /// The PIN check came back. A wrong PIN stays on the PIN page; an unprotected profile that
    /// is refused (`pin` was `None`) has nothing to retry and ends the flow.
    pub fn pin_checked(&mut self, wrong: bool, had_pin: bool, refused: impl FnOnce() -> String) {
        self.pin_checking = false;
        if !wrong {
            return;
        }
        if had_pin {
            self.pin_wrong = true;
        } else {
            self.step = PlexStep::Failed(PlexSignInProblem::Other(refused()));
        }
    }

    /// A server row was tapped. `false` while another connection is running.
    pub fn pick_server(&mut self, id: &str) -> bool {
        if self.connecting.is_some() {
            return false;
        }
        self.connecting = Some(id.to_string());
        self.unreachable.remove(id);
        true
    }

    /// The connection attempt ended. `reachable == false` marks the row; success leaves the page.
    pub fn server_connected(&mut self, id: &str, reachable: bool) {
        if !reachable {
            self.unreachable.insert(id.to_string());
        }
        self.connecting = None;
    }

    /// "Anderes Plex-Konto": sign out of plex.tv and back to the first page.
    pub fn other_account(&mut self) {
        *self = Self::new();
    }

    /// An error ends the flow (`PlexRun.fail`): the step it leads to.
    pub fn fail(&mut self, error: &PlexError, readable: impl FnOnce() -> String) {
        match PlexSignInProblem::from_error(error, readable) {
            Some(problem) => self.step = PlexStep::Failed(problem),
            None => self.step = PlexStep::Servers(Vec::new()),
        }
    }
}

/// How many polls in a row may fail before the flow gives up (`PlexRun.poll`).
pub const POLL_FAILURES_ALLOWED: u32 = 5;

/// What one poll beat found (`PlexRun.Poll`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PollResult {
    /// The token is there.
    Token(String),
    /// Nothing yet.
    Waiting,
    /// The request failed; `expired` when plex.tv says the code is gone (404 or 410).
    Failed {
        /// The code is gone.
        expired: bool,
    },
}

/// What the poll loop does after a beat.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PollNext {
    /// Sleep a second and look again.
    Again,
    /// Continue with this token.
    SignedIn(String),
    /// The flow ends with this step.
    End(PlexSignInProblem),
}

/// The poll loop of the browser sign-in as a pure counter (`PlexRun.poll`): the clock decides
/// the expiry, five failed beats in a row end it, a code that plex.tv says is gone ends it at once.
#[derive(Debug, Clone, Default)]
pub struct PlexPoll {
    failures: u32,
}

impl PlexPoll {
    /// A fresh loop.
    pub fn new() -> Self {
        Self::default()
    }

    /// [`Self::beat`] for a beat that failed with `error`: the fifth failure in a row ends the flow
    /// the way `PlexRun.fail` does for that error (plex.tv not reachable for a network error, the
    /// readable sentence for anything else), where [`PollResult::Failed`] alone can only say "other".
    pub fn beat_error(
        &mut self,
        now: f64,
        expires: f64,
        error: &PlexError,
        readable: impl FnOnce() -> String,
    ) -> PollNext {
        let expired = matches!(error, PlexError::PinExpired);
        match self.beat(now, expires, PollResult::Failed { expired }, String::new) {
            PollNext::End(PlexSignInProblem::Other(_)) => PollNext::End(
                PlexSignInProblem::from_error(error, readable)
                    .unwrap_or(PlexSignInProblem::Other(String::new())),
            ),
            other => other,
        }
    }

    /// One beat. `now` and `expires` are seconds on the same steady clock; `readable` makes the
    /// sentence for a failure that ends the flow.
    pub fn beat(
        &mut self,
        now: f64,
        expires: f64,
        result: PollResult,
        readable: impl FnOnce() -> String,
    ) -> PollNext {
        if now >= expires {
            return PollNext::End(PlexSignInProblem::Expired);
        }
        match result {
            PollResult::Token(token) => PollNext::SignedIn(token),
            PollResult::Waiting => {
                self.failures = 0;
                PollNext::Again
            }
            PollResult::Failed { expired: true } => PollNext::End(PlexSignInProblem::Expired),
            PollResult::Failed { expired: false } => {
                self.failures += 1;
                if self.failures >= POLL_FAILURES_ALLOWED {
                    PollNext::End(PlexSignInProblem::Other(readable()))
                } else {
                    PollNext::Again
                }
            }
        }
    }
}

// MARK: Emby

/// An account the Emby server offers on its sign-in page (`EmbyUserChoice`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbyUserChoice {
    /// User id.
    pub id: String,
    /// Name.
    pub name: String,
    /// Picture address.
    pub image: Option<String>,
}

/// Where the Emby page is (`EmbySignInModel.Step`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EmbyStep {
    /// Where the server is.
    Address,
    /// The server answered: name and version for the header.
    SignIn {
        /// The server's name.
        server_name: String,
        /// Its version.
        version: String,
    },
}

/// The Emby sign-in page (`EmbySignInModel`): the Jellyfin way, two steps on one page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbySignInModel {
    /// The step on screen.
    pub step: EmbyStep,
    /// The address as typed, then as the server answered.
    pub address: String,
    /// The address is being checked.
    pub checking: bool,
    /// What went wrong at the address step.
    pub problem: Option<EmbyProblem>,
    /// `None` while being fetched, empty when the server shows none.
    pub users: Option<Vec<EmbyUserChoice>>,
    /// The name typed or tapped.
    pub user: String,
    /// Signing in.
    pub signing_in: bool,
    /// The sentence after a failed sign-in.
    pub sign_in_error: Option<String>,
}

impl Default for EmbySignInModel {
    fn default() -> Self {
        Self::new()
    }
}

impl EmbySignInModel {
    /// A model on the address step.
    pub fn new() -> Self {
        Self {
            step: EmbyStep::Address,
            address: String::new(),
            checking: false,
            problem: None,
            users: None,
            user: String::new(),
            signing_in: false,
            sign_in_error: None,
        }
    }

    /// The server answered as Emby: the sign-in step. One account: nothing to choose, its name is
    /// filled in (as on the Jellyfin page).
    pub fn checked(
        &mut self,
        address: &str,
        server_name: &str,
        version: &str,
        users: Vec<EmbyUserChoice>,
    ) {
        self.checking = false;
        self.address = address.to_string();
        if users.len() == 1 && self.user.is_empty() {
            self.user = users[0].name.clone();
        }
        self.users = Some(users);
        self.step = EmbyStep::SignIn {
            server_name: server_name.to_string(),
            version: version.to_string(),
        };
    }

    /// The arrow at the top: from the sign-in back to the address (`true`), from the address out
    /// (`false`, the host cancels and leaves).
    pub fn go_back(&mut self) -> bool {
        if matches!(self.step, EmbyStep::SignIn { .. }) {
            self.step = EmbyStep::Address;
            self.sign_in_error = None;
            true
        } else {
            false
        }
    }
}

/// The red line under the address field for a problem (`problemView`). `None` for
/// [`EmbyProblem::Unreachable`], which gets the shared "server does not answer" hint with the address.
pub fn emby_problem_text(tr: &Translator, problem: &EmbyProblem) -> Option<String> {
    match problem {
        EmbyProblem::Unreachable { .. } => None,
        EmbyProblem::NotEmby { found: Some(found) } => Some(tr.t_args(
            "Unter der Adresse läuft %@, kein Emby.",
            &[Arg::Str(found.clone())],
        )),
        EmbyProblem::NotEmby { found: None } => {
            Some(tr.t("Unter der Adresse antwortet etwas, aber kein Emby."))
        }
        EmbyProblem::BadAddress => Some(tr.t("Die Adresse konnte nicht gelesen werden.")),
        EmbyProblem::LoginPage => Some(tr.t(
            "Vor dem Server sitzt eine Anmeldeseite, etwa Cloudflare Access oder Authelia. Trag die Header, die sie verlangt, unter „Erweitert“ ein.",
        )),
    }
}

/// Whether the "Mit Jellyfin weiter" button shows: a Jellyfin answered and the host can switch.
pub fn offers_jellyfin(problem: &EmbyProblem, can_switch: bool) -> bool {
    can_switch && matches!(problem, EmbyProblem::NotEmby { found: Some(f) } if f == "Jellyfin")
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_l10n::Locale;

    fn tr() -> Translator {
        Translator::new(Locale::parse("de"))
    }

    fn profile(id: &str, protected: bool) -> PlexProfileChoice {
        PlexProfileChoice {
            id: id.into(),
            name: id.into(),
            image: None,
            protected,
        }
    }

    fn server(id: &str) -> PlexServerChoice {
        PlexServerChoice {
            id: id.into(),
            name: id.into(),
            shared_by: None,
            local: false,
            online: true,
        }
    }

    fn two_profiles(m: &mut PlexSignInModel) {
        m.apply(PlexAnswer::Profiles {
            account: Some("paul".into()),
            profiles: vec![profile("a", false), profile("b", true)],
        });
    }

    #[test]
    fn titles_follow_the_step() {
        let mut m = PlexSignInModel::new();
        assert_eq!(m.page_title(&tr()), "Mit Plex anmelden");
        m.start();
        assert_eq!(m.step, PlexStep::Opening);
        assert_eq!(m.page_title(&tr()), "Mit Plex anmelden");
        m.apply(PlexAnswer::Waiting {
            url: Some("u".into()),
            code: None,
            seconds_left: 90,
        });
        assert_eq!(m.page_title(&tr()), "Plex (Beta)");
        two_profiles(&mut m);
        assert_eq!(m.page_title(&tr()), "paul");
        m.apply(PlexAnswer::Expired);
        assert_eq!(m.page_title(&tr()), "Plex (Beta)");
        let mut fresh = PlexSignInModel::new();
        fresh.step = PlexStep::Servers(vec![]);
        assert_eq!(fresh.page_title(&tr()), "Plex");
    }

    #[test]
    fn waiting_keeps_the_countdown_on_a_quiet_beat() {
        let mut m = PlexSignInModel::new();
        m.start();
        let a = m.apply(PlexAnswer::Waiting {
            url: Some("u".into()),
            code: Some("AB12".into()),
            seconds_left: 900,
        });
        assert_eq!(a, Applied::default());
        m.apply(PlexAnswer::Waiting {
            url: None,
            code: None,
            seconds_left: 899,
        });
        match &m.step {
            PlexStep::Waiting(p) => {
                assert_eq!(p.seconds_left, Some(899));
                assert_eq!(p.code.as_deref(), Some("AB12"));
            }
            other => panic!("{other:?}"),
        }
        // 0 means the core has nothing to add.
        m.apply(PlexAnswer::Waiting {
            url: None,
            code: None,
            seconds_left: 0,
        });
        assert!(matches!(&m.step, PlexStep::Waiting(p) if p.seconds_left == Some(899)));
        // A quiet beat outside the waiting step changes nothing.
        let mut idle = PlexSignInModel::new();
        idle.apply(PlexAnswer::Waiting {
            url: None,
            code: None,
            seconds_left: 5,
        });
        assert_eq!(idle.step, PlexStep::Start);
    }

    #[test]
    fn leaving_the_waiting_step_is_reported() {
        let mut m = PlexSignInModel::new();
        m.apply(PlexAnswer::Waiting {
            url: Some("u".into()),
            code: None,
            seconds_left: 0,
        });
        assert!(matches!(&m.step, PlexStep::Waiting(p) if p.seconds_left.is_none()));
        let a = m.apply(PlexAnswer::PlexUnreachable);
        assert_eq!(
            a,
            Applied {
                done: false,
                waiting_ended: true
            }
        );
        assert_eq!(m.step, PlexStep::Failed(PlexSignInProblem::PlexUnreachable));
        let mut d = PlexSignInModel::new();
        assert!(d.apply(PlexAnswer::Done).done);
    }

    #[test]
    fn protected_profile_asks_for_the_pin_and_back_returns_to_the_list() {
        let mut m = PlexSignInModel::new();
        two_profiles(&mut m);
        assert!(!m.pick_profile(&profile("b", true)));
        assert!(matches!(m.step, PlexStep::Pin(_)));
        assert!(m.submit_pin());
        assert!(!m.submit_pin(), "one check at a time");
        m.pin_checked(true, true, String::new);
        assert!(m.pin_wrong && !m.pin_checking);
        assert_eq!(m.go_back(), Back::Stepped);
        assert!(matches!(&m.step, PlexStep::Profiles(l) if l.len() == 2));
        assert_eq!(m.go_back(), Back::Leave);
        // An open profile goes straight to the servers, and back from there to the list.
        assert!(m.pick_profile(&profile("a", false)));
        assert_eq!(m.step, PlexStep::Loading(Placeholder::Servers));
        assert_eq!(m.go_back(), Back::Stepped);
    }

    #[test]
    fn single_profile_has_no_step_back() {
        let mut m = PlexSignInModel::new();
        m.apply(PlexAnswer::Profiles {
            account: None,
            profiles: vec![profile("a", false)],
        });
        m.step = PlexStep::Servers(vec![server("s")]);
        assert_eq!(m.step_back(), None);
        assert_eq!(m.go_back(), Back::Leave);
    }

    #[test]
    fn refused_open_profile_ends_the_flow_but_a_wrong_pin_stays() {
        let mut m = PlexSignInModel::new();
        m.pin_checked(true, false, || "refused".into());
        assert_eq!(
            m.step,
            PlexStep::Failed(PlexSignInProblem::Other("refused".into()))
        );
    }

    #[test]
    fn one_server_connects_at_a_time_and_unreachable_is_per_row() {
        let mut m = PlexSignInModel::new();
        m.apply(PlexAnswer::Servers {
            account: Some("p".into()),
            profile: Some("kid".into()),
            servers: vec![server("s1"), server("s2")],
        });
        assert_eq!(m.profile.as_deref(), Some("kid"));
        assert!(m.pick_server("s1"));
        assert!(!m.pick_server("s2"));
        m.server_connected("s1", false);
        assert!(m.unreachable.contains("s1") && m.connecting.is_none());
        // Trying again clears the mark; a new server list clears all marks.
        assert!(m.pick_server("s1"));
        assert!(!m.unreachable.contains("s1"));
        m.server_connected("s1", false);
        m.apply(PlexAnswer::Servers {
            account: None,
            profile: None,
            servers: vec![],
        });
        assert!(m.unreachable.is_empty());
        assert_eq!(
            m.account.as_deref(),
            Some("p"),
            "no name in the answer keeps the old one"
        );
    }

    #[test]
    fn other_account_resets_everything() {
        let mut m = PlexSignInModel::new();
        two_profiles(&mut m);
        m.pick_server("x");
        m.other_account();
        assert_eq!(m, PlexSignInModel::new());
    }

    #[test]
    fn errors_end_the_flow_like_plex_run_fail() {
        use swiftly_net::{ErrorKind, TransportReason};
        let mut m = PlexSignInModel::new();
        m.fail(&PlexError::PinExpired, || "x".into());
        assert_eq!(m.step, PlexStep::Failed(PlexSignInProblem::Expired));
        m.fail(&PlexError::NoServer, || "x".into());
        assert_eq!(m.step, PlexStep::Servers(vec![]));
        m.fail(
            &PlexError::Request(ErrorKind::Network { code: -1009 }),
            || "x".into(),
        );
        assert_eq!(m.step, PlexStep::Failed(PlexSignInProblem::PlexUnreachable));
        m.fail(
            &PlexError::Request(ErrorKind::Transport(TransportReason::NoHttpResponse)),
            || "x".into(),
        );
        assert_eq!(m.step, PlexStep::Failed(PlexSignInProblem::PlexUnreachable));
        m.fail(&PlexError::WrongServer, || "sentence".into());
        assert_eq!(
            m.step,
            PlexStep::Failed(PlexSignInProblem::Other("sentence".into()))
        );
    }

    #[test]
    fn problem_texts_are_the_catalogue_keys() {
        let t = tr();
        assert_eq!(
            PlexSignInProblem::PlexUnreachable.texts(&t).0,
            "plex.tv antwortet nicht"
        );
        assert_eq!(
            PlexSignInProblem::Expired.texts(&t).0,
            "Die Anmeldung ist abgelaufen"
        );
        let (head, text) = PlexSignInProblem::Other("Boom".into()).texts(&t);
        assert_eq!(
            (head.as_str(), text.as_str()),
            ("Anmeldung hat nicht geklappt", "Boom")
        );
        let mut s = server("s");
        assert_eq!(s.shared_by_text(&t), None);
        s.shared_by = Some(String::new());
        assert_eq!(s.shared_by_text(&t).as_deref(), Some("einem anderen Konto"));
        s.shared_by = Some("Anna".into());
        assert_eq!(s.shared_by_text(&t).as_deref(), Some("Anna"));
    }

    #[test]
    fn poll_gives_up_after_five_failures_in_a_row_or_when_the_code_is_gone() {
        let mut p = PlexPoll::new();
        let fail = || PollResult::Failed { expired: false };
        for _ in 0..4 {
            assert_eq!(p.beat(0.0, 100.0, fail(), String::new), PollNext::Again);
        }
        // A quiet beat resets the count.
        assert_eq!(
            p.beat(0.0, 100.0, PollResult::Waiting, String::new),
            PollNext::Again
        );
        for _ in 0..4 {
            assert_eq!(p.beat(0.0, 100.0, fail(), String::new), PollNext::Again);
        }
        assert_eq!(
            p.beat(0.0, 100.0, fail(), || "down".into()),
            PollNext::End(PlexSignInProblem::Other("down".into()))
        );
        let mut p = PlexPoll::new();
        assert_eq!(
            p.beat(
                0.0,
                100.0,
                PollResult::Failed { expired: true },
                String::new
            ),
            PollNext::End(PlexSignInProblem::Expired)
        );
        assert_eq!(
            PlexPoll::new().beat(0.0, 100.0, PollResult::Token("t".into()), String::new),
            PollNext::SignedIn("t".into())
        );
    }

    #[test]
    fn poll_ends_on_the_clock_before_it_looks() {
        let mut p = PlexPoll::new();
        assert_eq!(
            p.beat(100.0, 100.0, PollResult::Token("t".into()), String::new),
            PollNext::End(PlexSignInProblem::Expired)
        );
    }

    #[test]
    fn emby_steps_and_single_account_prefill() {
        let mut m = EmbySignInModel::new();
        m.checking = true;
        let user = EmbyUserChoice {
            id: "1".into(),
            name: "anna".into(),
            image: None,
        };
        m.checked("https://e.example", "Emby", "4.8", vec![user.clone()]);
        assert_eq!(m.user, "anna");
        assert!(!m.checking);
        assert!(matches!(&m.step, EmbyStep::SignIn { version, .. } if version == "4.8"));
        m.sign_in_error = Some("wrong".into());
        assert!(m.go_back());
        assert_eq!(m.step, EmbyStep::Address);
        assert!(m.sign_in_error.is_none());
        assert!(!m.go_back(), "from the address the host leaves");
        // Two accounts: nothing is filled in; a typed name is kept.
        let mut two = EmbySignInModel::new();
        two.checked("a", "E", "?", vec![user.clone(), user.clone()]);
        assert!(two.user.is_empty());
        let mut typed = EmbySignInModel::new();
        typed.user = "me".into();
        typed.checked("a", "E", "?", vec![user]);
        assert_eq!(typed.user, "me");
    }

    #[test]
    fn emby_problem_texts() {
        let t = tr();
        let text = |p| emby_problem_text(&t, &p);
        assert_eq!(
            text(EmbyProblem::Unreachable {
                address: "x".into()
            }),
            None
        );
        assert_eq!(
            text(EmbyProblem::NotEmby {
                found: Some("Jellyfin".into())
            })
            .as_deref(),
            Some("Unter der Adresse läuft Jellyfin, kein Emby.")
        );
        assert_eq!(
            text(EmbyProblem::NotEmby { found: None }).as_deref(),
            Some("Unter der Adresse antwortet etwas, aber kein Emby.")
        );
        assert_eq!(
            text(EmbyProblem::BadAddress).as_deref(),
            Some("Die Adresse konnte nicht gelesen werden.")
        );
        assert!(text(EmbyProblem::LoginPage).is_some());
        let jf = EmbyProblem::NotEmby {
            found: Some("Jellyfin".into()),
        };
        assert!(offers_jellyfin(&jf, true));
        assert!(!offers_jellyfin(&jf, false));
        assert!(!offers_jellyfin(
            &EmbyProblem::NotEmby { found: None },
            true
        ));
    }
}
