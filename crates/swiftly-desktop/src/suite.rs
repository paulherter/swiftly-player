//! The whole app in one window (`--demo app`): the four tabs (Start, Filme, Serien, Suche) over the scripted demo
//! server, and the Detail and Series pages pushed over them with the nav animation. Each screen keeps its own UI; this
//! type routes input to the one in front, switches tabs, pushes titles and composes the draw lists.

use crate::browse;
use crate::detail_screen::DetailScreen;
use crate::downloads_screen::{DownloadsScreen, Scenario as DlScenario};
use crate::home::HomeScreen;
use crate::home_data::Scenario;
use crate::library_screen::{Kind, LibraryScreen};
use crate::login_screen::{LoginScreen, Start};
use crate::pages_screen::{Kind as PageKind, PageScreen};
use crate::player_screen::{PlayerKey, PlayerScenario, PlayerScreen};
use crate::search_screen::SearchScreen;
use crate::series_screen::SeriesScreen;
use crate::settings_screen::{Dest, SettingsScreen};
use std::rc::Rc;
use std::sync::Arc;
use swiftly_motion::catalogue::Id;
use swiftly_render::{DrawList, RgbaImage};
use swiftly_ui::nav::{Layers, Nav, NavStyle};
use swiftly_ui::{Cx, Env, NavKey, Outcome};

/// A title page pushed over a tab.
enum Top {
    Detail(Box<DetailScreen>),
    Series(Box<SeriesScreen>),
    Settings(Box<SettingsScreen>),
    Downloads(Box<DownloadsScreen>),
    Login(Box<LoginScreen>),
    Page(Box<PageScreen>),
}

/// How a page opens again: what the Mac's `PagesTarget` is to its stack.
#[derive(Clone, Debug, PartialEq)]
enum Rec {
    Title(crate::title_target::Target),
    Genre(String),
    Collection {
        id: String,
        name: String,
        /// `movies` or `tvshows`; `None`: everything in it (from a library row of Start).
        art: Option<String>,
    },
    Playlist {
        id: String,
        name: String,
        art: String,
    },
    Person(crate::pages_screen::PersonTap),
    Settings,
    Accounts,
    /// A scripted page of the demo.
    Demo(PageKind),
}

/// Where the window stood: the section and its whole page stack (`Navigator.Place`).
#[derive(Clone, Debug, PartialEq)]
struct Place {
    tab: usize,
    pages: Vec<Rec>,
}

/// The account list over the stored accounts of the real app.
/// The server kind as the account list shows it.
/// What the strip says when the server gave no plan to play (`PlayControls.swift:113`): it names the server, not just
/// "failed", so with several servers it is clear which one is meant.
pub fn plan_refused_text(server: Option<&str>) -> String {
    format!(
        "Die Wiedergabe hat nicht geklappt. Von {} kamen keine Daten zum Abspielen.",
        server.unwrap_or("dem Server")
    )
}

fn kind_label(kind: swiftly_jellyfin::ServerKind) -> &'static str {
    match kind {
        swiftly_jellyfin::ServerKind::Plex => "Plex",
        swiftly_jellyfin::ServerKind::Emby => "Emby",
        _ => "Jellyfin",
    }
}

/// The sign-in screen with the pictures of the app's hub, when there is one.
fn with_hub(l: LoginScreen, hub: &Option<Rc<crate::hub::ImageHub>>) -> LoginScreen {
    match hub {
        Some(h) => l.with_images(Rc::clone(h)),
        None => l,
    }
}

fn accounts_screen(env: Env, cx: Cx, core: &crate::live::Core) -> LoginScreen {
    let list = core.accounts_list();
    let active = list.iter().position(|e| e.active).unwrap_or(0);
    LoginScreen::with_accounts(
        env,
        cx,
        list.into_iter()
            .map(|e| (e.name, format!("{} · {}", kind_label(e.kind), e.server)))
            .collect(),
        active,
    )
}

/// The answer of a fetch of an episode: its season id and number.
type FreshSeason = std::sync::mpsc::Receiver<(Option<String>, Option<i64>)>;

/// The app: four tab screens and at most one pushed title page.
pub struct Suite {
    cx: Cx,
    env: Env,
    tab: usize,
    home: HomeScreen,
    movies: LibraryScreen,
    series: LibraryScreen,
    /// "Merkliste": its own page, reached from the sidebar (tab 4).
    watch: LibraryScreen,
    search: SearchScreen,
    top: Option<Top>,
    player: Option<Box<PlayerScreen>>,
    logged: (usize, usize),
    clock: f64,
    seen: [usize; 5],
    /// Titles already fetched ahead by a rest on their tile (`account:id`).
    prefetched: std::collections::HashSet<String>,
    /// The fresh season of an episode that opened its series page (`SeasonTarget`): the series id and the answer.
    fresh_season: Option<(String, FreshSeason)>,
    pushes: usize,
    /// The Start settings the Start page was built from (`home_data::live_fingerprint`), and when they were last read.
    home_settings: (String, f64),
    /// The list changes Start has already reloaded for (`desk::list_changes`).
    home_seen: u64,
    /// The slide of a pushed form page (Settings, Downloads, sign-in): position 0 = base page, 1 = form page.
    slide: Option<Nav<u8>>,
    sliding_out: bool,
    /// The real app (`None`: the demo).
    live: Option<Rc<crate::live::Wiring>>,
    /// The support card's records and counter (real app only) and when it was last looked at.
    support: Option<(crate::support_card::SupportCard, f64, bool)>,
    /// The core of the real app, kept to rebuild the tabs after the sign-in.
    core: Option<std::sync::Arc<crate::live::Core>>,
    /// The real app keeps asking for frames until this time (ms) after the last input or start.
    busy_until: f64,
    /// A title being prepared for the player.
    starting: Option<crate::login_screen::Pending<Result<crate::live_play::Prepared, String>>>,
    /// The live read behind an open season sheet.
    season_read: Option<crate::live_downloads::SeasonRead>,
    film_read: Option<crate::live_downloads::FilmRead>,
    /// The request behind the last Play, for Retry on the plan-failed screen.
    last_play: Option<crate::live_play::PlayRequest>,
    /// Downloaded titles whose file would not open: they stream from then on (`playFailed`).
    file_failed: std::collections::HashSet<String>,
    /// The two history arrows of the 52 pt strip.
    arrows: crate::desk::NavArrows,
    /// The short message at the bottom of the content (a refused plan).
    hint: crate::desk::HintBar,
    /// The hint about the Discord after a few finished titles, and when it is due (ms).
    discord: crate::desk::DiscordCard,
    /// The panel of watching together and continuing on this device, over everything but the player.
    together_ui: crate::together_ui::TogetherUi,
    /// When the groups and devices were last asked for (ms of the suite clock).
    together_at: f64,
    /// The panel that shows the picture leaving for another device, and when it opened.
    /// The next title comes from the group: if it cannot open here, the group is told.
    group_start: bool,
    /// The shell's "Fassung wählen" and the title it asks for.
    version_dialog: (
        crate::desk::VersionDialog,
        Option<crate::live_play::VersionAsk>,
    ),
    nudge: Option<(swiftly_vm::Nudge, f64)>,
    /// The window buttons in the toolbar row (the window has no system frame).
    controls: crate::desk::WindowControls,
    /// The window action the last input asked for (move, minimise, maximise, close).
    win_action: Option<crate::desk::WinAction>,
    /// A press that began on a window button.
    win_press: Option<crate::desk::WinButton>,
    /// The window asked to close.
    quit: bool,
    /// The pushed page of each area while another area is in front (a stack per area).
    parked: [Option<Top>; 5],
    /// Pages below the page in front that came back when it closes: a title page under the person page opened from it.
    under: Vec<Top>,
    /// The genre names being fetched for the chips row (live app).
    genres: Option<crate::login_screen::Pending<Vec<String>>>,
    /// A press that began in the sidebar while a page is pushed: it belongs to the tabs.
    side_press: bool,
    /// The area change in progress: the tab left and when (the 0.12 s out, 0.22 s in cross fade of the content).
    fade: Option<(usize, f64)>,
    /// The launch curtain, when it is on.
    curtain: Option<crate::desk::Curtain>,
    /// The tabs visited before this one, oldest first, and the ones left by going back (the Mac's window history).
    history: Vec<Place>,
    future: Vec<Place>,
    /// What lies on each section's page stack, as records that can open it again.
    trail: [Vec<Rec>; 5],
    /// The section's stack as it was when it was left (the profile is dropped on the way out, history keeps it).
    leaving: Option<Vec<Rec>>,
    /// Pages that close on a history step: their closing is no new step.
    silent_pops: usize,
    /// The pages below the page in front of a section that is not in front.
    parked_under: [Vec<Top>; 5],
    /// A back or forward step is switching the tab: not a new place.
    stepping: bool,
    /// The account switch stage while it runs, with the account to activate when the picture has flown.
    stage: Option<RunningStage>,
    /// The picture hub of the live app: one per window, kept over account changes (each hub claims its own rows of the
    /// shared image page, which is never given back).
    hub: Option<Rc<crate::hub::ImageHub>>,
    /// The navigation state machine: what the sidebar highlights and which way each transition goes.
    nav: crate::nav_machine::NavState,
    /// A panel is sliding out because the user chose another sidebar page; the page then shown is already in place.
    panel_closing: bool,
    /// The page to show once the leaving panel is gone (Downloads is a page, not part of the tab stack).
    after_panel: Option<crate::nav_machine::Page>,
    /// When the Downloads page appeared (its content cross fades in like a section change).
    page_fade: Option<f64>,
    /// Downloads was just left: the next area fade has no old page to fade out (Downloads is already gone).
    left_downloads: bool,
    /// The Downloads page just left: it stays on screen under the new page's fade-in, then goes.
    gone_page: Option<Top>,
    /// The title page an add sheet floats over (the Downloads screen in front draws only the sheet).
    under_sheet: Option<Top>,
    /// Where the pointer last was (window points; `None` outside the window) and which page it was last told about:
    /// when the page under a resting pointer changes, hover is worked out again (the Mac's tracking areas do it).
    pointer_at: Option<(f32, f32)>,
    /// A click hid this tooltip at this point: the page the click opened keeps it hidden while the pointer rests there.
    press_tip: Option<((f32, f32), String)>,
    hover_page: (usize, u8, bool, bool),
    /// The running area fade only fades the new page in.
    fade_in_only: bool,
    /// How far the page behind a moving page or panel is shifted this frame (points; tests, measuring).
    last_below_dx: f32,
    /// What a `swiftly://` link is doing (`link_route::reduce`) and the read behind it.
    link: crate::link_route::LinkState,
    link_fetch: Option<crate::login_screen::Pending<Option<crate::link_route::Found>>>,
}

/// An account switch stage on its way (`AccountSwitchStage.swift`).
struct RunningStage {
    screen: crate::switch_stage::StageScreen,
    /// The account key to make active at the stage's change time (`None`: already active).
    pending: Option<String>,
}

/// Runs `$e` with `$s` bound to the screen of the tab in front.
macro_rules! front {
    ($self:ident, $s:ident => $e:expr) => {
        match $self.tab {
            0 => {
                let $s = &mut $self.home;
                $e
            }
            1 => {
                let $s = &mut $self.movies;
                $e
            }
            2 => {
                let $s = &mut $self.series;
                $e
            }
            4 => {
                let $s = &mut $self.watch;
                $e
            }
            _ => {
                let $s = &mut $self.search;
                $e
            }
        }
    };
}

/// Runs `$e` with `$s` bound to the pushed page.
macro_rules! on_top {
    ($t:expr, $s:ident => $e:expr) => {
        match $t {
            Top::Detail($s) => $e,
            Top::Series($s) => $e,
            Top::Settings($s) => $e,
            Top::Downloads($s) => $e,
            Top::Login($s) => $e,
            Top::Page($s) => $e,
        }
    };
}

impl Suite {
    /// The app for `env` (the idiom of `env` decides the form factor).
    pub fn new(env: Env, cx: Cx) -> Suite {
        Suite::with_state(env, cx, Scenario::Ready)
    }

    /// The demo app with every screen starting in the scripted server state `state` (`--demo app --state S`).
    pub fn with_state(env: Env, cx: Cx, state: Scenario) -> Suite {
        crate::desk::set_card(crate::desk::Card::Demo);
        let ready = match state {
            Scenario::Ready => browse::Scenario::Ready,
            Scenario::Loading => browse::Scenario::Loading,
            Scenario::Offline => browse::Scenario::Offline,
            Scenario::Empty => browse::Scenario::Empty,
            Scenario::Worst => browse::Scenario::Worst,
        };
        let mut home = HomeScreen::new(env, cx.clone(), state);
        // The demo server has the genre chips on.
        home.set_chips(
            [
                "Drama",
                "Kom\u{f6}die",
                "Krimi",
                "Science-Fiction",
                "Dokumentarfilm",
                "Thriller",
            ]
            .map(String::from)
            .to_vec(),
        );
        Suite {
            home,
            movies: LibraryScreen::new(env, cx.clone(), &Kind::Movies, ready),
            series: LibraryScreen::new(env, cx.clone(), &Kind::Series, ready),
            watch: LibraryScreen::new(env, cx.clone(), &Kind::Watchlist, ready),
            search: SearchScreen::new(env, cx.clone(), ready, &[]),
            arrows: crate::desk::NavArrows::new(env, cx.clone()),
            hint: crate::desk::HintBar::new(env, cx.clone()),
            discord: crate::desk::DiscordCard::new(env, cx.clone()),
            together_ui: crate::together_ui::TogetherUi::new(env, cx.clone()),
            together_at: f64::NEG_INFINITY,
            group_start: false,
            version_dialog: (crate::desk::VersionDialog::new(env, cx.clone()), None),
            nudge: None,
            controls: crate::desk::WindowControls::new(env, cx.clone()),
            win_action: None,
            win_press: None,
            quit: false,
            parked: Default::default(),
            under: Vec::new(),
            side_press: false,
            genres: None,
            fade: None,
            curtain: None,
            cx,
            env,
            tab: 0,
            top: None,
            player: None,
            logged: (0, 0),
            clock: 0.0,
            seen: [0; 5],
            prefetched: std::collections::HashSet::new(),
            fresh_season: None,
            pushes: 0,
            home_settings: (String::new(), 0.0),
            home_seen: crate::desk::list_changes(),
            slide: None,
            sliding_out: false,
            live: None,
            support: None,
            core: None,
            busy_until: 0.0,
            starting: None,
            season_read: None,
            film_read: None,
            last_play: None,
            file_failed: std::collections::HashSet::new(),
            history: Vec::new(),
            future: Vec::new(),
            trail: Default::default(),
            leaving: None,
            under_sheet: None,
            pointer_at: None,
            press_tip: None,
            hover_page: (0, 0, false, false),
            silent_pops: 0,
            parked_under: Default::default(),
            stepping: false,
            stage: None,
            hub: None,
            nav: crate::nav_machine::NavState::default(),
            panel_closing: false,
            after_panel: None,
            page_fade: None,
            left_downloads: false,
            gone_page: None,
            fade_in_only: false,
            last_below_dx: 0.0,
            link: crate::link_route::LinkState::Idle,
            link_fetch: None,
        }
    }

    /// The real app: tabs over the stored account, or the sign-in flow when there is none.
    pub fn new_live(env: Env, cx: Cx, core: std::sync::Arc<crate::live::Core>) -> Suite {
        crate::live::install(None);
        let mut s = Suite::new(env, cx);
        s.core = Some(core);
        s.reload_live();
        s.enable_curtain();
        s
    }

    /// Builds the tabs for the stored account, or opens the sign-in when none is stored.
    fn reload_live(&mut self) {
        let Some(core) = self.core.clone() else {
            return;
        };
        self.top = None;
        self.slide = None;
        // A new account starts a new history (`Navigator.emptyAll`).
        self.under.clear();
        self.parked = Default::default();
        self.parked_under = Default::default();
        self.trail = Default::default();
        self.history.clear();
        self.future.clear();
        // The sidebar's account card: the signed-in account, nothing while signing in.
        crate::desk::set_card(match core.accounts_list().into_iter().find(|e| e.active) {
            Some(e) => crate::desk::Card::account(&e.name, &e.server)
                .with_picture(core.avatar_address(&e.key)),
            None => crate::desk::Card::Hidden,
        });
        let Some(account) = core.account() else {
            crate::live::install(None);
            self.live = None;
            let backend = core.sign_in_backend();
            // The faces of "Wer schaut?" and the Plex profiles come from the servers named on the page itself.
            let device = swiftly_images::Device::Mac;
            let loader = swiftly_images::ImageLoader::new(
                Arc::clone(&core.net),
                Some(crate::live::image_disk_cache(device)),
                device,
            );
            let hub = crate::hub::ImageHub::new(Box::new(loader), &self.cx, self.env.scale, device);
            self.hub = Some(Rc::clone(&hub));
            self.top = Some(Top::Login(Box::new(
                LoginScreen::live(self.env, self.cx.clone(), backend).with_images(hub),
            )));
            return;
        };
        let device = swiftly_images::Device::Mac;
        let loader = swiftly_images::ImageLoader::new(
            Arc::clone(&core.net),
            Some(crate::live::image_disk_cache(device)),
            device,
        );
        let hub = match self.hub.take() {
            Some(hub) if hub.scale() == self.env.scale => {
                hub.rebind(Box::new(loader));
                hub
            }
            _ => crate::hub::ImageHub::new(Box::new(loader), &self.cx, self.env.scale, device),
        };
        self.hub = Some(Rc::clone(&hub));
        crate::settings_run::start_sync(Arc::clone(&core));
        crate::desk::set_downloads_on(crate::settings_run::downloads_on(&*core.settings));
        crate::look_glow::set(crate::look_glow::read(crate::support_card::Shared(
            Arc::clone(&core.settings),
        )));
        let w = Rc::new(crate::live::Wiring::new(core, account, Rc::clone(&hub)));
        crate::live::install(Some(Rc::clone(&w)));
        let (env, cx) = (self.env, self.cx.clone());
        let l = Scenario::Loading;
        let ls = browse::Scenario::Loading;
        self.home = HomeScreen::new(env, cx.clone(), l).with_images(Rc::clone(&hub));
        self.movies =
            LibraryScreen::new(env, cx.clone(), &Kind::Movies, ls).with_images(Rc::clone(&hub));
        self.series =
            LibraryScreen::new(env, cx.clone(), &Kind::Series, ls).with_images(Rc::clone(&hub));
        self.watch =
            LibraryScreen::new(env, cx.clone(), &Kind::Watchlist, ls).with_images(Rc::clone(&hub));
        self.search = SearchScreen::new(env, cx, ls, &[]).with_images(hub);
        self.attach_seerr();
        self.home.vm().send(swiftly_vm::HomeIntent::Load);
        self.movies.vm().send(swiftly_vm::LibraryIntent::Load);
        self.series.vm().send(swiftly_vm::LibraryIntent::Load);
        self.watch.start_watchlist();
        self.genres = Some(crate::live::fetch_genres(&w));
        self.live = Some(w);
        self.seen = [0; 5];
        self.tab = 0;
        self.home_settings = (String::new(), 0.0);
    }

    fn reduce_fade(&self) -> bool {
        self.env.reduce_motion
    }

    /// Width of the sidebar on the desktop layout (the pushed pages start right of it), 0 elsewhere.
    fn side(&self) -> f32 {
        if self.env.idiom == swiftly_ui::Idiom::Desktop && !self.first_run() {
            swiftly_design::tokens::desktop::SIDEBAR_WIDTH
        } else {
            0.0
        }
    }

    /// The window-point frame of the control `key` on the pushed settings or sign-in page (tests).
    #[doc(hidden)]
    pub fn top_frame_of(&self, key: &str) -> Option<[f32; 4]> {
        let off = self.side();
        let f = match self.top.as_ref()? {
            Top::Settings(s) => s.frame_of(key),
            Top::Login(l) => l.frame_of(key),
            _ => None,
        }?;
        Some([f[0] + off, f[1], f[2], f[3]])
    }

    /// The address typed on the sign-in page and whether its field shows the keyboard (tests).
    #[doc(hidden)]
    pub fn login_address(&self) -> Option<(String, bool)> {
        match self.top.as_ref()? {
            Top::Login(l) => Some(l.address_state()),
            _ => None,
        }
    }

    /// The Merkliste and Downloads rows follow their settings (`merklisteAn`, on unless switched off; `downloadsAn`, off
    /// unless switched on): a section that is switched off has no sidebar row and no shortcut, and switching the
    /// Merkliste off while it is open goes back to Start (`onChange(of: model.watchlistShown)`).
    fn sync_mine(&mut self, now: f64) {
        use swiftly_settings::{KeyValueStore, Value};
        let Some(w) = crate::live::current() else {
            return;
        };
        let on = |key: &str, default: bool| match w.core.settings.get(key) {
            Some(Value::Bool(b)) => b,
            _ => default,
        };
        let (watchlist, downloads) = (
            on("merklisteAn", true),
            crate::settings_run::downloads_on(&*w.core.settings),
        );
        crate::desk::set_mine(watchlist, downloads);
        if !watchlist && self.tab == 4 && self.player.is_none() {
            self.goto_tab(0, now);
        }
    }

    /// Start follows its settings while the app runs: a changed row order, hidden row, chosen library, genre chip or
    /// "Neuzugänge getrennt" builds Start again and loads it (the Mac's `.task(id:)` over the same settings). Read a few
    /// times a second.
    fn sync_home_settings(&mut self, now: f64) {
        let Some(w) = self.live.clone() else {
            return;
        };
        if now - self.home_settings.1 < 250.0 {
            return;
        }
        self.home_settings.1 = now;
        crate::look_glow::set(crate::look_glow::read(crate::support_card::Shared(
            Arc::clone(&w.core.settings),
        )));
        let print = crate::home_data::live_fingerprint(&w);
        if self.home_settings.0.is_empty() {
            self.home_settings.0 = print;
            return;
        }
        if print == self.home_settings.0 {
            return;
        }
        self.home_settings.0 = print;
        self.rebuild_home();
    }

    /// A fresh Start page over the stored settings, loading.
    fn rebuild_home(&mut self) {
        let mut home = HomeScreen::new(self.env, self.cx.clone(), Scenario::Loading);
        if let Some(hub) = self.hub.clone() {
            home = home.with_images(hub);
        }
        self.home = home;
        self.home.vm().send(swiftly_vm::HomeIntent::Load);
        if let Some(w) = self.live.clone() {
            self.genres = Some(crate::live::fetch_genres(&w));
        }
        self.seen[0] = 0;
    }

    /// Start shows the server's answer from before a list change (Merkliste, watched, a finished playback) until it is
    /// fetched again: once Start is in front with the real app behind it, it loads again (old rows stay until the new
    /// ones arrive).
    fn refresh_home_if_stale(&mut self) {
        let seen = crate::desk::list_changes();
        if seen == self.home_seen || self.live.is_none() {
            self.home_seen = seen;
            return;
        }
        if self.tab == 0 && self.top.is_none() && self.player.is_none() {
            self.home_seen = seen;
            self.home.vm().send(swiftly_vm::HomeIntent::Load);
        }
    }

    /// Start came to the front (sidebar, history) or the window was activated: rows older than the grace period of
    /// the Mac (`Refresh`, 30 s) are fetched again, so a change made on another device shows up (`HomeView.returned`,
    /// `didBecomeActiveNotification`). The view model starts nothing while a run is in flight or the rows are fresh.
    fn start_in_front(&mut self) {
        if self.tab == 0 && self.live.is_some() && self.top.is_none() && self.player.is_none() {
            self.home.vm().send(swiftly_vm::HomeIntent::Refresh);
        }
    }

    /// The window became the active one again (the Mac refreshes Start on `didBecomeActiveNotification`).
    pub fn window_activated(&mut self) {
        self.start_in_front();
    }

    /// The first start of the real app: no account yet, the sign-in page is the whole window (the Mac shows no sidebar,
    /// no account card and no history arrows until someone is signed in).
    /// The first-start sign-in shows its back chevron (every step but the kind picker, which is the first page).
    fn first_start_back(&self) -> bool {
        self.first_run()
            && matches!(&self.top, Some(Top::Login(l)) if l.step() != crate::login_screen::Step::Kind)
    }

    fn first_run(&self) -> bool {
        self.core.is_some() && self.live.is_none() && matches!(self.top, Some(Top::Login(_)))
    }

    /// Whether the sidebar is on screen (tests).
    #[doc(hidden)]
    pub fn sidebar_shown(&self) -> bool {
        self.side() > 0.0
    }

    /// The environment of a pushed page: the content column.
    fn page_env(&self) -> Env {
        let mut e = self.env;
        e.size.w = (e.size.w - self.side()).max(1.0);
        e
    }

    /// Turns the launch curtain on (the real app plays it once at start).
    pub fn enable_curtain(&mut self) {
        self.curtain = Some(crate::desk::Curtain::new(self.env, self.cx.clone()));
    }

    /// The curtain is still showing at `now` (tests).
    pub fn curtain_up(&mut self, now: f64) -> bool {
        self.curtain.as_mut().is_some_and(|c| c.alpha(now) > 0.0)
    }

    /// The tab in front (0 Start, 1 Filme, 2 Serien, 3 Suche).
    pub fn tab(&self) -> usize {
        self.tab
    }

    /// Whether a title page is pushed (or sliding in or out).
    pub fn title_open(&self) -> bool {
        self.top.is_some()
    }

    /// Whether the pushed page is a series page.
    pub fn title_is_series(&self) -> bool {
        matches!(self.top, Some(Top::Series(_)))
    }

    /// How many title pages were pushed so far.
    pub fn pushes(&self) -> usize {
        self.pushes
    }

    /// The Library screen of "Filme" (tests).
    pub fn movies(&mut self) -> &mut LibraryScreen {
        &mut self.movies
    }

    /// The Library screen of the Merkliste (tests).
    pub fn watch(&mut self) -> &mut LibraryScreen {
        &mut self.watch
    }

    /// The search screen (tests).
    pub fn search(&mut self) -> &mut SearchScreen {
        &mut self.search
    }

    /// The services (atlas pages) the renderers read.
    pub fn cx(&self) -> &Cx {
        &self.cx
    }

    /// Renders a list with the software renderer.
    pub fn render_software(&self, list: &DrawList) -> RgbaImage {
        self.home.render_software(list)
    }

    /// A new window size or scale.
    pub fn set_env(&mut self, env: Env) {
        self.env = env;
        self.home.set_env(env);
        self.movies.set_env(env);
        self.series.set_env(env);
        self.watch.set_env(env);
        self.search.set_env(env);
        self.arrows.set_env(env);
        self.together_ui.set_env(env);
        self.controls.set_env(env);
        if let Some(c) = &mut self.curtain {
            c.set_env(env);
        }
        // The player covers the whole window (also the sidebar's strip): a window that grows or goes fullscreen relays it out.
        if let Some(p) = &mut self.player {
            p.set_env(env);
        }
        let pe = self.page_env();
        if let Some(t) = &mut self.top {
            on_top!(t, s => s.set_env(pe));
        }
        for t in self
            .parked
            .iter_mut()
            .flatten()
            .chain(self.under_sheet.as_mut())
            .chain(self.under.iter_mut())
            .chain(self.parked_under.iter_mut().flatten())
        {
            on_top!(t, s => s.set_env(pe));
        }
    }

    /// The tile with `id` on the tab in front.
    /// What the create panel says the group will watch: the page on top knows its own episodes and tiles best, then the
    /// tab's tiles.
    fn together_line(&self, id: &str) -> String {
        let page = match &self.top {
            Some(Top::Series(s)) => s.together_line(id),
            Some(Top::Detail(d)) => d.together_line(id),
            _ => None,
        };
        page.or_else(|| self.tile_of(id).map(|t| crate::together_ui::tile_line(&t)))
            .unwrap_or_default()
    }

    fn tile_of(&self, id: &str) -> Option<swiftly_vm::Tile> {
        let is = |t: &&swiftly_vm::Tile| t.id == id;
        match self.tab {
            0 => self
                .home
                .vm()
                .rails()
                .rails
                .iter()
                .flat_map(|r| r.tiles.iter())
                .find(is)
                .cloned(),
            1 => self.movies.vm().grid().tiles.iter().find(is).cloned(),
            2 => self.series.vm().grid().tiles.iter().find(is).cloned(),
            4 => self.watch.vm().grid().tiles.iter().find(is).cloned(),
            _ => self
                .search
                .vm()
                .results()
                .groups
                .iter()
                .flat_map(|g| g.tiles.iter())
                .find(is)
                .cloned(),
        }
    }

    /// After an input: a tapped bar entry switches the tab, a tapped tile pushes its page.
    fn after_base(&mut self, now: f64) {
        if crate::forms::take_profile() {
            let screen = self.settings_screen();
            self.show(Top::Settings(Box::new(screen)), now);
            return;
        }
        match crate::desk::take_go() {
            Some(crate::desk::Go::Downloads) if self.top.is_none() => {
                let screen = self.downloads_page();
                self.show(Top::Downloads(Box::new(screen)), now);
                return;
            }
            Some(crate::desk::Go::Watchlist) => {
                front!(self, s => s.set_tab(4));
            }
            Some(crate::desk::Go::Offer) => self.badge_tapped(),
            _ => {}
        }
        if self.tab == 0 && self.top.is_none() {
            for id in self.home.take_rested() {
                self.prefetch(&id);
            }
        }
        if self.tab == 0 && self.top.is_none() {
            // The Continue rail resumes at once, like the Mac: no detail page first.
            if let Some(id) = self.home.take_resumed().pop() {
                self.resume(&id, now);
                return;
            }
        }
        if self.tab == 0 && self.top.is_none() {
            let libs = self.home.take_libraries();
            let genres = self.home.take_genres();
            if let Some(w) = self.live.clone() {
                // The real app opens the real page: the chosen library or collection, or the tapped genre.
                if let Some(id) = libs.last() {
                    let rail = format!("library:{id}");
                    let name = self
                        .home
                        .vm()
                        .rails()
                        .rails
                        .iter()
                        .find(|r| r.id == rail)
                        .map(|r| r.title.clone())
                        .unwrap_or_default();
                    let page =
                        PageScreen::collection_live(self.env, self.cx.clone(), &w, id, &name, None);
                    self.push_live_page(
                        page,
                        &w,
                        Rec::Collection {
                            id: id.clone(),
                            name: name.clone(),
                            art: None,
                        },
                        now,
                    );
                    return;
                }
                if let Some(name) = genres.last() {
                    let page = PageScreen::genre_live(self.env, self.cx.clone(), &w, name);
                    self.push_live_page(page, &w, Rec::Genre(name.clone()), now);
                    return;
                }
            } else if !libs.is_empty() {
                self.open_page(PageKind::Collection, now);
                return;
            } else if !genres.is_empty() {
                self.open_page(PageKind::Genre, now);
                return;
            }
        }
        if let Some(series) = self.home.take_jump() {
            // `AppModel.openLibrary`: the row's order (newest first) applies to the library that opens.
            let screen = if series { &self.series } else { &self.movies };
            screen.vm().send(swiftly_vm::LibraryIntent::SetSorting {
                sorting: swiftly_library::library_filter::Sorting::Latest,
            });
        }
        let asked = front!(self, s => s.tab());
        if asked != self.tab {
            let old = self.tab;
            self.leave_section(old);
            if self.side() > 0.0 && !self.reduce_fade() {
                self.start_fade(old);
            }
            front!(self, s => s.set_tab(old));
            self.tab = asked.min(4);
            if self.tab == 3 {
                self.attach_seerr();
            }
            self.seen[self.tab] = front!(self, s => s.opened().len());
            self.start_in_front();
            // `SearchView.onAppear { inField = true }`: the field has the keyboard whenever the section opens.
            if self.tab == 3 && crate::home::Form::of(self.env.idiom) == crate::home::Form::Desktop
            {
                self.search.focus();
            }
            return;
        }
        let opened: Vec<String> = front!(self, s => s.opened().to_vec());
        if opened.len() > self.seen[self.tab] {
            self.seen[self.tab] = opened.len();
            let Some(id) = opened.last() else { return };
            if self.open_card(id, now) {
                return;
            }
            let tile = self.tile_of(id);
            self.push(tile, now);
        }
    }

    /// The Mac's hover prefetch (`SeriesCache.prefetch`, `PlanPreAdvice.prefetch`): the title behind the tile at rest
    /// (the series of an episode) is fetched ahead, so its page starts from the whole title when the push slides in. Once per title and account.
    fn prefetch(&mut self, id: &str) {
        let (Some(w), Some(tile)) = (&self.live, self.tile_of(id)) else {
            return;
        };
        let target = crate::title_target::target_of(&tile);
        let key = format!("{}:{}", w.account.key(), target.id);
        if !self.prefetched.insert(key) {
            return;
        }
        let Ok(server) = w.core.server_for(&w.account) else {
            return;
        };
        let ahead = Arc::clone(&w.ahead);
        w.core.spawn(async move {
            if let Ok(item) = crate::live_server::item(&server, &target.id).await
                && let Ok(mut all) = ahead.lock()
            {
                all.insert(item.id.clone(), item);
            }
        });
    }

    /// Starts playing `id` from the server's resume position (the Continue rail, the Mac's tap).
    fn resume(&mut self, id: &str, now: f64) {
        if let Some(w) = &self.live {
            let req = crate::live_play::PlayRequest {
                item_id: id.to_owned(),
                since: -1.0,
                source_id: None,
            };
            self.last_play = Some(req.clone());
            self.starting = Some(w.core.prepare_play(&w.account, req));
            self.busy_until = now + 30_000.0;
        } else {
            self.player = Some(Box::new(PlayerScreen::new(
                self.env,
                self.cx.clone(),
                PlayerScenario::Playing,
                now,
            )));
        }
    }

    /// Opens the page of a tapped tile: an episode or a season leads to its series (see `title_target`).
    fn push(&mut self, tile: Option<swiftly_vm::Tile>, now: f64) {
        let target = tile.as_ref().map(crate::title_target::target_of);
        if let (Some(w), Some(t)) = (&self.live, &target) {
            *w.next_kind.borrow_mut() = t.kind.clone();
            *w.last_title.borrow_mut() = (t.id.clone(), t.name.clone());
            *w.next_spec.borrow_mut() = t.spec.clone();
        }
        let series = target.as_ref().is_some_and(|t| t.series);
        // `SeasonTarget`: an episode tile carries the season it had when its list loaded; the episode is fetched
        // fresh and the page moves to its real season (the Mac's "Weiter S6E1 oben, Staffel 5 in der Liste" fix).
        self.fresh_season = None;
        if let (Some(w), Some(tile), true) = (&self.live, &tile, series)
            && tile
                .facts
                .kind
                .as_deref()
                .is_some_and(|k| k.eq_ignore_ascii_case("Episode"))
            && let Ok(server) = w.core.server_for(&w.account)
        {
            let (tx, rx) = std::sync::mpsc::channel();
            let episode = tile.id.clone();
            w.core.spawn(async move {
                if let Ok(item) = crate::live_server::item(&server, &episode).await {
                    let _ = tx.send((item.season_id, item.parent_index_number));
                }
            });
            let series_id = target.as_ref().map(|t| t.id.clone()).unwrap_or_default();
            self.fresh_season = Some((series_id, rx));
        }
        let name = target.as_ref().map(|t| (t.id.clone(), t.name.clone()));
        self.push_page(series, name, target, now);
    }

    /// A collection or playlist card of the title menu opens its page (`PagesTarget.collection`, `.playlist`).
    pub fn open_card(&mut self, id: &str, now: f64) -> bool {
        let (is_playlist, key) =
            match (id.strip_prefix("collection:"), id.strip_prefix("playlist:")) {
                (Some(k), _) => (false, k),
                (_, Some(k)) => (true, k),
                _ => return false,
            };
        let Some(w) = self.live.clone() else {
            return true;
        };
        let series = self.tab == 2;
        let screen = if series { &self.series } else { &self.movies };
        let name = screen
            .vm()
            .cards()
            .into_iter()
            .find(|t| t.id == id)
            .map(|t| t.title)
            .unwrap_or_default();
        let art = if series { "tvshows" } else { "movies" };
        let (rec, page) = if is_playlist {
            (
                Rec::Playlist {
                    id: key.to_owned(),
                    name: name.clone(),
                    art: art.to_owned(),
                },
                PageScreen::playlist_live(self.env, self.cx.clone(), &w, key, &name, art),
            )
        } else {
            (
                Rec::Collection {
                    id: key.to_owned(),
                    name: name.clone(),
                    art: Some(art.to_owned()),
                },
                PageScreen::collection_live(self.env, self.cx.clone(), &w, key, &name, Some(art)),
            )
        };
        self.push_live_page(page, &w, rec, now);
        true
    }

    /// Hands the fresh season of an episode to the series page it opened.
    fn pump_fresh_season(&mut self) {
        let Some((series, rx)) = &self.fresh_season else {
            return;
        };
        if let Ok((id, number)) = rx.try_recv() {
            let series = series.clone();
            self.fresh_season = None;
            if let Some(Top::Series(s)) = &mut self.top {
                s.apply_fresh_season(&series, id, number);
            }
        }
    }

    /// Pushes the title page (the wiring already knows the kind and name of the title).
    fn push_page(
        &mut self,
        series: bool,
        tile: Option<(String, String)>,
        target: Option<crate::title_target::Target>,
        now: f64,
    ) {
        self.record(Rec::Title(target.unwrap_or_else(|| {
            crate::title_target::Target {
                series,
                id: String::new(),
                name: String::new(),
                kind: String::new(),
                spec: swiftly_vm::SeriesSpec::default(),
            }
        })));
        let (env, cx) = (self.env, self.cx.clone());
        let mut top = if series {
            Top::Series(Box::new(SeriesScreen::overlay(env, cx, Scenario::Ready)))
        } else {
            match &tile {
                Some((id, title)) => Top::Detail(Box::new(DetailScreen::overlay_for(
                    env,
                    cx,
                    Scenario::Ready,
                    (id, title),
                ))),
                None => Top::Detail(Box::new(DetailScreen::overlay(env, cx, Scenario::Ready))),
            }
        };
        {
            let pe = self.page_env();
            on_top!(&mut top, s => s.set_env(pe));
            on_top!(&mut top, s => s.open(now));
        }
        if let Some(w) = &self.live {
            let hub = Rc::clone(&w.hub);
            top = match top {
                Top::Detail(d) => Top::Detail(Box::new(d.with_images(hub))),
                Top::Series(d) => Top::Series(Box::new(d.with_images(hub))),
                other => other,
            };
        }
        self.top = Some(top);
        self.pushes += 1;
    }

    /// A Downloads page over the real downloads of the active account (the demo list without one).
    fn downloads_page(&self) -> DownloadsScreen {
        let (env, cx) = (self.env, self.cx.clone());
        let live = self.core.clone().filter(|_| self.live.is_some());
        match (&live, &self.live) {
            (Some(core), Some(w)) => {
                DownloadsScreen::over(env, cx, crate::live_downloads::shared(core, &w.account))
            }
            _ => DownloadsScreen::new(env, cx, DlScenario::Mixed),
        }
    }

    /// The Downloads page when it is in front.
    pub fn downloads(&mut self) -> Option<&mut DownloadsScreen> {
        match &mut self.top {
            Some(Top::Downloads(d)) => Some(d),
            _ => None,
        }
    }

    /// Pushes `screen` as the Downloads page (tests, parity frames with a chosen scenario).
    pub fn show_downloads(&mut self, screen: DownloadsScreen, now: f64) {
        self.show(Top::Downloads(Box::new(screen)), now);
    }

    /// The settings page when it is in front (tests, parity frames).
    pub fn settings(&mut self) -> Option<&mut SettingsScreen> {
        match &mut self.top {
            Some(Top::Settings(s)) => Some(s),
            _ => None,
        }
    }

    /// The Delete key: removes the selected rows when the Downloads page is in edit mode (also on its series page).
    /// Returns whether it did something.
    pub fn delete_key(&mut self, now: f64) -> bool {
        self.busy_until = self.busy_until.max(now + 2500.0);
        let done = match &mut self.top {
            Some(Top::Downloads(d)) if self.player.is_none() => d.delete_key(),
            _ => false,
        };
        if done {
            self.after_top();
        }
        done
    }

    /// Closes the menu a title page opened its sheet from.
    fn close_page_menu(page: &mut Top) {
        match page {
            Top::Detail(s) => s.close_menu(),
            Top::Series(s) => s.close_menu(),
            _ => {}
        }
    }

    /// A download button on Detail or Series asks for the add popover or the season sheet. The Downloads page takes
    /// it; when it is not in front it is pushed first (a title page in front is replaced by it, as a form page
    /// replaces another one). The series page's "Laden" builds the season request from live data (`pump_season_read`, `live_downloads::SeasonRead`),
    /// which answers the season reads through [`Suite::season_pending`], [`Suite::season_loaded`] and [`Suite::season_finished`].
    pub fn request_load(&mut self, request: crate::load_sheets::LoadRequest, now: f64) {
        self.busy_until = self.busy_until.max(now + 2500.0);
        if matches!(self.top, Some(Top::Detail(_) | Top::Series(_))) {
            // A title page stays on screen: the sheet floats over it (the Mac's popover under the button) and the
            // Downloads page is never shown. The screen only keeps the sheet's state and input.
            let mut screen = self.downloads_page();
            screen.set_sheet_only(true);
            let pe = self.page_env();
            screen.set_env(pe);
            self.under_sheet = self.top.replace(Top::Downloads(Box::new(screen)));
            if let Some(page) = self.under_sheet.as_mut() {
                Self::close_page_menu(page);
            }
        } else if !matches!(self.top, Some(Top::Downloads(_))) {
            let screen = self.downloads_page();
            self.show(Top::Downloads(Box::new(screen)), now);
        }
        if let Some(Top::Downloads(d)) = &mut self.top {
            d.request_load(request);
        }
    }

    /// The seasons of the open season sheet that still have to be read, in batches of three.
    pub fn season_pending(&self) -> Vec<Vec<String>> {
        match &self.top {
            Some(Top::Downloads(d)) => d.season_pending(),
            _ => Vec::new(),
        }
    }

    /// The answer for one season of the open season sheet (`None`: the request failed).
    pub fn season_loaded(&mut self, season: &str, episodes: Option<Vec<swiftly_model::Item>>) {
        if let Some(Top::Downloads(d)) = &mut self.top {
            d.season_loaded(season, episodes);
        }
    }

    /// All seasons of the open season sheet have been tried.
    pub fn season_finished(&mut self) {
        if let Some(Top::Downloads(d)) = &mut self.top {
            d.season_finished();
        }
    }

    /// Whether the title page's anchored menu (More, season list) is open, also while the add sheet floats over it (tests).
    pub fn title_menu_open(&mut self) -> bool {
        let page = self.under_sheet.as_mut().or(self.top.as_mut());
        match page {
            Some(Top::Detail(s)) => s.menu_open(),
            Some(Top::Series(s)) => s.menu_open(),
            _ => false,
        }
    }

    /// Whether the add popover or the season sheet is open on the Downloads page in front.
    pub fn load_open(&self) -> bool {
        matches!(&self.top, Some(Top::Downloads(d)) if d.load_open())
    }

    /// Starts the account switch stage: the profile picture of `name` flies from the middle of the window to its slot in
    /// the top strip. With `key` the account becomes active (and the tabs reload) when the picture has flown, at
    /// `SwitchStage::change_at`; without it only the stage plays.
    pub fn begin_switch_stage(&mut self, name: &str, key: Option<String>, now: f64) {
        self.busy_until = self.busy_until.max(now + 2500.0);
        let size = 120.0;
        let from = (self.env.size.w / 2.0, self.env.size.h / 2.0);
        let to = (self.env.size.w - 36.0, 26.0);
        let stage = crate::switch_stage::SwitchStage::new(from, size, to, self.env.reduce_motion);
        if key.is_some() {
            // The old account's rows leave on the tap (`AccountRowsOut`); the new ones come in at the change.
            self.home.begin_rail_out();
        }
        let initial = name.chars().find(|c| c.is_alphanumeric()).unwrap_or('?');
        // The new account's picture (`userImageURL(for:)`), the initial only while there is none.
        let picture = self.core.as_ref().and_then(|core| {
            let key = key.clone().or_else(|| {
                core.accounts_list()
                    .into_iter()
                    .find(|e| e.name == name)
                    .map(|e| e.key)
            })?;
            core.avatar_address(&key)
        });
        let slot = crate::hub::HubSlot::default();
        if let Some(hub) = &self.hub {
            crate::hub::HubSlotExt::attach(&slot, Rc::clone(hub));
        }
        let screen = crate::switch_stage::StageScreen::with_picture(
            self.env,
            self.cx.clone(),
            stage,
            initial,
            slot,
            picture,
        );
        self.stage = Some(RunningStage {
            screen,
            pending: key,
        });
    }

    /// Server pictures currently placed in the live app's picture region (tests).
    pub fn pictures_placed(&self) -> usize {
        self.hub.as_ref().map_or(0, |h| h.placed())
    }

    /// Whether the account switch stage is running.
    pub fn switch_stage_running(&self) -> bool {
        self.stage.is_some()
    }

    /// Advances the stage to `now`: switches the account at its change time and draws it over `list`. True while it runs.
    fn frame_stage(&mut self, list: &mut DrawList, now: f64) -> bool {
        let Some(run) = &mut self.stage else {
            return false;
        };
        let over = run.screen.frame(now);
        let t = run.screen.elapsed(now);
        let (change, finished) = (
            run.screen.stage().change_at(),
            run.screen.stage().finished(t),
        );
        let key = if t >= change {
            run.pending.take()
        } else {
            None
        };
        if finished {
            self.stage = None;
        } else {
            list.append_shifted(&over, 0.0);
        }
        if let (Some(key), Some(core)) = (key, self.core.clone()) {
            if core.switch_account(&key) {
                self.reload_live();
                self.home.begin_rail_stagger();
            } else {
                self.home.end_rail_out();
            }
        }
        !finished
    }

    /// Pushes a form page over the tabs.
    /// Feeds `event` to the navigation machine and returns the motion it asks for.
    fn nav_event(&mut self, event: crate::nav_machine::Event) -> crate::nav_machine::Motion {
        let (next, motion) = crate::nav_machine::reduce(self.nav, event);
        self.nav = next;
        motion
    }

    /// Keeps the machine's page and panel equal to what is on screen (a shortcut or a screen may have changed it).
    fn resync_nav(&mut self) {
        use crate::nav_machine::{Page, Panel};
        let panel = match &self.top {
            Some(Top::Settings(_)) if !self.panel_closing => Some(Panel::Settings),
            Some(Top::Login(_)) if !self.panel_closing => Some(Panel::Accounts),
            _ => None,
        };
        self.nav.panel = panel;
        self.nav.page = match (&self.top, self.after_panel) {
            (Some(Top::Downloads(d)), _) if !d.is_sheet_only() => Page::Downloads,
            (_, Some(p)) => p,
            _ => Page::Tab(self.tab.min(4) as u8),
        };
    }

    /// The settings and profile panel over the active account.
    fn settings_screen(&self) -> SettingsScreen {
        let mut screen = match &self.core {
            Some(core) if self.live.is_some() => {
                SettingsScreen::live(self.env, self.cx.clone(), core, false)
                    .with_seerr(Box::new(crate::seerr_link::LiveSeerr::new(
                        std::sync::Arc::clone(core),
                    )))
                    .with_check(Box::new(crate::server_check::LiveCheck::new(
                        std::sync::Arc::clone(core),
                    )))
                    .with_choices(Box::new(crate::home_choices::LiveChoices::new(
                        std::sync::Arc::clone(core),
                    )))
            }
            _ => SettingsScreen::new(self.env, self.cx.clone(), false),
        };
        if let (Some(core), true) = (&self.core, self.live.is_some()) {
            screen.set_accounts(
                core.accounts_list()
                    .into_iter()
                    .map(|e| {
                        (
                            e.name,
                            format!("{} \u{b7} {}", kind_label(e.kind), e.server),
                            e.active,
                        )
                    })
                    .collect(),
            );
            screen.set_pictures(
                core.accounts_list()
                    .iter()
                    .map(|e| core.avatar_address(&e.key))
                    .collect(),
            );
        }
        if let Some(w) = &self.live {
            screen = screen.with_images(Rc::clone(&w.hub));
            if let Some(core) = &self.core {
                screen = screen.with_downloads(crate::live_downloads::shared(core, &w.account));
            }
        }
        screen
    }

    /// A sidebar tap while a panel is open: the panel slides out to the right and the page asked for (or the one behind)
    /// travels in from the left. The page change happens now; the panel stays on top until it has left.
    fn close_panel_for(&mut self, page: Option<crate::nav_machine::Page>, now: f64) {
        use crate::nav_machine::{Event, Page};
        let event = page.map_or(Event::ClosePanel, Event::Select);
        self.resync_nav();
        self.drop_panels_below();
        let motion = self.nav_event(event);
        debug_assert!(
            motion == crate::nav_machine::Motion::PanelOut
                || motion == crate::nav_machine::Motion::None
        );
        self.panel_closing = true;
        match page {
            Some(Page::Tab(i)) if usize::from(i) != self.tab => {
                let old = self.tab;
                self.leave_section(old);
                front!(self, s => s.set_tab(old));
                front!(self, s => s.set_tab(usize::from(i)));
                self.tab = usize::from(i).min(4);
                if self.tab == 3 {
                    self.attach_seerr();
                }
                self.seen[self.tab] = front!(self, s => s.opened().len());
                self.fade = None;
                self.gone_page = None;
                self.start_in_front();
            }
            Some(Page::Downloads) => self.after_panel = Some(Page::Downloads),
            _ => {}
        }
        // Ask the panel to close: it sheds a sheet or a sub page first, so ask until it is closed.
        if let Some(t) = &mut self.top {
            for _ in 0..4 {
                if !on_top!(t, s => s.is_open()) {
                    break;
                }
                on_top!(t, s => s.back(now));
            }
        }
    }

    fn show(&mut self, mut top: Top, now: f64) {
        match &top {
            Top::Settings(_) | Top::Login(_) => {
                // A form page that replaces another one takes its record.
                if matches!(self.top, Some(Top::Settings(_) | Top::Login(_))) {
                    self.trail[self.tab].pop();
                }
                let rec = if matches!(top, Top::Settings(_)) {
                    Rec::Settings
                } else {
                    Rec::Accounts
                };
                self.record(rec);
            }
            _ => {}
        }
        {
            let pe = self.page_env();
            on_top!(&mut top, s => s.set_env(pe));
            on_top!(&mut top, s => s.open(now));
        }
        // A form page pushed over a base page slides in like a title page (the base page moves back); a form page that
        // replaces another one takes its place at once.
        // Downloads is a page of the sidebar: no slide, its content cross fades in.
        let panel = !matches!(top, Top::Downloads(_));
        if self.top.is_none() && panel {
            let mut nav = Nav::new(0_u8, NavStyle::for_idiom(self.env.idiom));
            nav.push(1, now);
            self.slide = Some(nav);
        } else {
            self.slide = None;
        }
        self.page_fade = (!panel && !self.reduce_fade()).then_some(now);
        self.panel_closing = false;
        self.sliding_out = false;
        self.top = Some(top);
        self.pushes += 1;
    }

    /// Whether the page in front is a settings, downloads or sign-in page (tests).
    pub fn form_open(&self) -> Option<&'static str> {
        match &self.top {
            Some(Top::Settings(_)) => Some("settings"),
            Some(Top::Downloads(_)) => Some("downloads"),
            Some(Top::Login(l)) => Some(if l.step() == crate::login_screen::Step::Accounts {
                "accounts"
            } else {
                "login"
            }),
            _ => None,
        }
    }

    /// A sheet of the page in front is open: it is modal and takes every click and shortcut (the Mac's `.sheet`).
    fn sheet_modal(&self) -> bool {
        self.load_open() || self.form_sheet_open()
    }

    /// Whether the settings or downloads page in front has a sheet or a choice list open (tests).
    pub fn form_sheet_open(&self) -> bool {
        match &self.top {
            Some(Top::Settings(s)) => s.sheet_open(),
            Some(Top::Downloads(d)) => d.sheet_open(),
            _ => false,
        }
    }

    /// A hub row or the account list asked for another form page: it replaces the one in front.
    fn follow(&mut self) {
        let (env, cx) = (self.env, self.cx.clone());
        let live = self.core.clone().filter(|_| self.live.is_some());
        let hub = self.hub.clone();
        let mut sign_out = false;
        if let Some(Top::Settings(s)) = &mut self.top {
            for e in s.take_effects() {
                crate::effects::post(e);
            }
        }
        let next = match &mut self.top {
            Some(Top::Settings(s)) => s.take_dest().and_then(|d| match d {
                Dest::Downloads => Some(Top::Downloads(Box::new(match (&live, &self.live) {
                    (Some(core), Some(w)) => DownloadsScreen::over(
                        env,
                        cx.clone(),
                        crate::live_downloads::shared(core, &w.account),
                    ),
                    _ => DownloadsScreen::new(env, cx.clone(), DlScenario::Mixed),
                }))),
                Dest::Accounts => Some(Top::Login(Box::new(match &live {
                    Some(core) => accounts_screen(env, cx, core),
                    None => LoginScreen::new(env, cx, Start::Accounts),
                }))),
                Dest::QuickShare => Some(Top::Login(Box::new(match &live {
                    Some(core) => LoginScreen::share(env, cx, core.sign_in_backend()),
                    None => LoginScreen::new(env, cx, Start::Share),
                }))),
                Dest::AddServer => Some(Top::Login(Box::new(match &live {
                    Some(core) => with_hub(
                        LoginScreen::live(env, cx, core.sign_in_backend()).into_add(),
                        &hub,
                    ),
                    None => LoginScreen::new(env, cx, Start::AddKind),
                }))),
                // The Support sheet is the host's (`SupportModel.open`).
                Dest::Support => None,
                Dest::SignOut => {
                    sign_out = true;
                    None
                }
            }),
            Some(Top::Login(l)) => l.add_server().then(|| {
                Top::Login(Box::new(match &live {
                    Some(core) => with_hub(
                        LoginScreen::live(env, cx, core.sign_in_backend()).into_add(),
                        &hub,
                    ),
                    None => LoginScreen::new(env, cx, Start::AddKind),
                }))
            }),
            _ => None,
        };
        if let Some(t) = next {
            if matches!(self.top, Some(Top::Settings(_))) && matches!(t, Top::Login(_)) {
                // The account pages are pushed over the profile page (the Mac's navigation stack): it stays drawn
                // below while they slide in and is where back leads.
                let prev = self.top.take();
                let now = self.clock;
                self.show(t, now);
                self.under.extend(prev);
            } else {
                self.show(t, 0.0);
            }
        }
        if sign_out
            && let Some(core) = live
            && let Some(e) = core.active_entry()
        {
            core.sign_out_account(&e.key);
            self.reload_live();
        }
    }

    /// The pushed page left the stack: drop it.
    /// The pushed page that closed leaves the stack: its way back is a step forward again (Downloads is no page of the
    /// stack), and the page behind it (or the base screen) is in front.
    fn finish_pop(&mut self, was_downloads: bool) {
        // The page leaves the stack; its way back is a step forward again (Downloads is no page of the stack).
        if !was_downloads {
            let old = self.here();
            self.trail[self.tab].pop();
            if self.silent_pops > 0 {
                self.silent_pops -= 1;
            } else if !self.stepping {
                self.went_back(old);
            }
        }
        self.slide = None;
        self.top = None;
        self.panel_closing = false;
        if self.after_panel.take() == Some(crate::nav_machine::Page::Downloads) {
            let now = self.clock;
            let screen = self.downloads_page();
            self.show(Top::Downloads(Box::new(screen)), now);
        } else if let Some(prev) = self.under.pop() {
            // Back from a person page leads to the title page it was opened from (the Mac's navigation stack); back
            // from the account pages leads to the profile page, which is a panel and rests at the end of its slide.
            if matches!(prev, Top::Settings(_) | Top::Login(_)) {
                let mut nav = Nav::new(0_u8, NavStyle::for_idiom(self.env.idiom));
                nav.push(1, self.clock - 10_000.0);
                nav.update(self.clock);
                self.slide = Some(nav);
            }
            self.top = Some(prev);
        } else {
            // The page behind brings back its own pushed stack.
            self.top = self.parked[self.tab].take();
        }
    }

    /// A page that is closing (`is_open` false, still sliding out): a click now belongs to what is behind it.
    fn top_closing(&self) -> bool {
        matches!(
            &self.top,
            Some(Top::Detail(_) | Top::Series(_) | Top::Page(_))
        ) && self
            .top
            .as_ref()
            .is_some_and(|t| on_top!(t, s => !s.is_open()))
    }

    fn after_top(&mut self) {
        self.follow();
        // The sign-in asks the system for the clipboard (Quick Connect code) and the browser (Plex).
        if let Some(Top::Login(l)) = &mut self.top {
            if let Some(text) = l.take_copy() {
                crate::signin_flows::copy_text(&text);
            }
            if let Some(url) = l.take_open() {
                crate::signin_flows::open_url(&url);
            }
        }
        if let (Some(core), Some(Top::Settings(sc)), true) =
            (self.core.clone(), &mut self.top, self.live.is_some())
            && let Some(i) = sc.take_picked()
        {
            let entry = core
                .accounts_list()
                .get(i)
                .map(|e| (e.key.clone(), e.name.clone()));
            // Picking the account that is already active changes nothing.
            if let Some((key, name)) = entry
                && !core.active_entry().is_some_and(|a| a.key == key)
                && self.stage.is_none()
            {
                let now = self.clock;
                self.begin_switch_stage(&name, Some(key), now);
            }
            return;
        }
        if let (Some(core), Some(Top::Login(l)), true) =
            (self.core.clone(), &self.top, self.live.is_some())
            && let Some(i) = l.switched()
        {
            let entry = core
                .accounts_list()
                .get(i)
                .map(|e| (e.key.clone(), e.name.clone()));
            if let Some((key, name)) = entry {
                if let Some(Top::Login(l)) = &mut self.top {
                    l.clear_switched();
                }
                // Picking the account that is already active changes nothing.
                if !core.active_entry().is_some_and(|a| a.key == key) && self.stage.is_none() {
                    let now = self.clock;
                    self.begin_switch_stage(&name, Some(key), now);
                }
                return;
            }
        }
        if let (Some(core), Some(Top::Login(l))) = (self.core.clone(), &mut self.top)
            && self.live.is_some()
            && let Some(i) = l.take_sign_out()
            && let Some(e) = core.accounts_list().get(i).cloned()
        {
            let was_active = e.active;
            core.sign_out_account(&e.key);
            if was_active {
                self.reload_live();
            } else {
                self.top = Some(Top::Login(Box::new(accounts_screen(
                    self.env,
                    self.cx.clone(),
                    &core,
                ))));
            }
            return;
        }
        if self.core.is_some()
            && matches!(&self.top, Some(Top::Login(l)) if l.signed_in().is_some())
        {
            self.reload_live();
            return;
        }
        if let Some(t) = &self.top {
            let moving = self.slide.as_ref().is_some_and(Nav::is_animating);
            let gone = on_top!(t, s => !s.is_open() && !s.wants_frame()) && !moving;
            let was_downloads = matches!(t, Top::Downloads(_));
            if gone {
                self.finish_pop(was_downloads);
            }
        }
    }

    /// The real app is idle: nothing was touched for a while and nothing animates. The shell then looks again about
    /// four times a second (answers of the network) instead of every vsync.
    pub fn live_idle(&self, now: f64) -> bool {
        self.live.is_some()
            && now >= self.busy_until
            && self.starting.is_none()
            && self.player.is_none()
    }

    /// Fills the rest of the image page with grey blocks, as a long session of posters and icons does (live checks:
    /// `--script` step `fill-images`). Returns how many blocks fitted.
    pub fn fill_image_page(&self) -> usize {
        // Big blocks first, then smaller ones, until not even a thin strip fits.
        [256_u32, 64, 8]
            .into_iter()
            .map(|side| {
                let block = vec![40_u8; (side * side * 4) as usize];
                std::iter::from_fn(|| self.cx.add_image(side, side, &block)).count()
            })
            .sum()
    }

    /// Whether the player is open over the app.
    pub fn player_open(&self) -> bool {
        self.player.is_some()
    }

    /// What the system's media widgets show (`None` when no player plays).
    pub fn now_playing(&self) -> Option<crate::media_keys::NowPlaying> {
        self.player.as_ref().and_then(|p| p.now_playing())
    }

    /// A button of the system's media widgets or a headset: the intent goes to the player like the on-screen button.
    pub fn player_intent(&mut self, intent: swiftly_vm::PlayerIntent, now: f64) {
        if let Some(p) = self.player.as_mut() {
            p.send_intent(intent, now);
        }
        self.after_player();
    }

    /// The pointer moved with no button held (hover, tooltips, controls wake in the player).
    pub fn player_pointer(&mut self, x: f32, y: f32, now: f64) {
        if let Some(p) = &mut self.player {
            p.pointer_move(x, y, now);
        }
    }

    /// The pointer left the window.
    pub fn player_pointer_left(&mut self, now: f64) {
        if let Some(p) = &mut self.player {
            p.pointer_leave(now);
        }
    }

    /// The window is closing: a running player stops and reports its position (`NSWindow.willCloseNotification`).
    /// Returns whether a player was open.
    pub fn player_window_closing(&mut self, now: f64) -> bool {
        match &mut self.player {
            Some(p) => {
                p.window_closing(now);
                true
            }
            None => false,
        }
    }

    /// The wheel over the player's volume control; whether it was used.
    pub fn player_wheel(&mut self, x: f32, y: f32, dy: f32, precise: bool, now: f64) -> bool {
        self.player
            .as_mut()
            .is_some_and(|p| p.volume_wheel(x, y, dy, precise, now))
    }

    /// The window fullscreen state for the player's button glyph and Esc.
    pub fn player_set_fullscreen(&mut self, on: bool) {
        if let Some(p) = &mut self.player {
            p.set_fullscreen(on);
        }
    }

    /// The player asked the window to toggle fullscreen (read once).
    pub fn player_fullscreen_request(&mut self) -> bool {
        self.player
            .as_mut()
            .is_some_and(|p| p.take_fullscreen_request())
    }

    /// The cursor hides together with the controls.
    pub fn player_cursor_hidden(&self) -> bool {
        self.player.as_ref().is_some_and(|p| p.cursor_hidden())
    }

    /// Puts a ready player in front of the app, as a started film does (tests and demos).
    pub fn show_player(&mut self, player: PlayerScreen) {
        self.player = Some(Box::new(player));
    }

    /// The player in front (tests).
    pub fn player(&mut self) -> Option<&mut PlayerScreen> {
        self.player.as_deref_mut()
    }

    /// Play on a Detail or Series page opens the player with the fake engine.
    fn check_play(&mut self, now: f64) {
        // A trailer page of the core opens in the browser (the Mac's `NSWorkspace.open`).
        let links = match &mut self.top {
            Some(Top::Detail(d)) => d.take_web(),
            Some(Top::Series(s)) => s.take_web(),
            _ => Vec::new(),
        };
        for link in links {
            let _ = crate::signin_flows::open_url(&link);
        }
        let (n, last) = match &self.top {
            Some(Top::Detail(d)) => (d.log().len(), d.log().last().cloned()),
            Some(Top::Series(d)) => (d.log().len(), d.log().last().cloned()),
            _ => return,
        };
        if self.logged.0 != self.pushes {
            self.logged = (self.pushes, 0);
        }
        if n > self.logged.1 {
            self.logged.1 = n;
            if self.live.is_some() {
                let req = match &mut self.top {
                    Some(Top::Detail(d)) => d.take_play(),
                    Some(Top::Series(d)) => d.take_play(),
                    _ => None,
                };
                if let (Some(req), Some(w)) = (req, &self.live) {
                    self.last_play = Some(req.clone());
                    self.starting = Some(w.core.prepare_play(&w.account, req));
                    self.busy_until = now + 30_000.0;
                }
            } else if last.is_some_and(|l| l.starts_with("play") || l.starts_with("start version"))
            {
                self.player = Some(Box::new(PlayerScreen::new(
                    self.env,
                    self.cx.clone(),
                    PlayerScenario::Playing,
                    now,
                )));
            }
        }
    }

    /// Gives the search the Seerr block when a Seerr session is stored (it is read again when the search is shown, so
    /// a connection made in Settings counts without a restart).
    fn attach_seerr(&mut self) {
        let (Some(core), Some(w)) = (&self.core, &self.live) else {
            return;
        };
        if self.search.has_seerr() {
            return;
        }
        if let Some(backend) = crate::seerr_flow::Live::stored(core) {
            let flow = crate::seerr_flow::Flow::new(backend, w.core.host().locale);
            self.search.set_seerr(flow);
        }
    }

    /// A Seerr tile (search block, suggestions, the person's request rail) opens the Seerr title page over the stack
    /// (the Mac's `navigator.openIt(.seerrTitle)`).
    fn check_seerr(&mut self, now: f64) {
        let hit = match &mut self.top {
            Some(Top::Page(p)) => p.take_seerr(),
            None if self.tab == 3 => self.search.take_seerr(),
            _ => None,
        };
        let (Some(hit), Some(w)) = (hit, self.live.clone()) else {
            return;
        };
        let Some(page) = PageScreen::seerr_live(self.env, self.cx.clone(), &w, hit) else {
            return;
        };
        let mut top = Top::Page(Box::new(page.with_images(Rc::clone(&w.hub))));
        let pe = self.page_env();
        on_top!(&mut top, s => s.set_env(pe));
        on_top!(&mut top, s => s.open(now));
        if let Some(prev) = self.top.take() {
            self.under.push(prev);
        }
        self.top = Some(top);
        self.pushes += 1;
        self.busy_until = self.busy_until.max(now + 2500.0);
    }

    /// A cast tile on a title page opens the person page over it; a similar or collection tile on a title page, and a
    /// title tile on the person page, open that title over it (the Mac's `navigator.openIt`).
    fn check_person(&mut self, now: f64) {
        let (tap, tile) = match &mut self.top {
            Some(Top::Detail(d)) => (d.take_person(), d.take_tile()),
            Some(Top::Series(s)) => (s.take_person(), s.take_tile()),
            Some(Top::Page(p)) => (None, p.take_tile()),
            _ => return,
        };
        if tap.is_some() && self.live.is_none() {
            // The demo app has no server: the scripted person page opens over the title.
            let prev = self.top.take();
            self.open_page(PageKind::Person, now);
            if let Some(prev) = prev {
                self.under.push(prev);
            }
        } else if let (Some(tap), Some(w)) = (tap, self.live.clone()) {
            let (env, cx) = (self.env, self.cx.clone());
            self.record(Rec::Person(tap.clone()));
            let mut top = Top::Page(Box::new(
                PageScreen::person_live(env, cx, &w, tap).with_images(Rc::clone(&w.hub)),
            ));
            let pe = self.page_env();
            on_top!(&mut top, s => s.set_env(pe));
            on_top!(&mut top, s => s.open(now));
            if let Some(prev) = self.top.take() {
                self.under.push(prev);
            }
            self.top = Some(top);
            self.pushes += 1;
            self.busy_until = self.busy_until.max(now + 2500.0);
        } else if let Some(tile) = tile {
            let prev = self.top.take();
            self.push(Some(tile), now);
            if let Some(prev) = prev {
                self.under.push(prev);
            }
        }
    }

    /// Closes the open player the way the Close button does (stop to the engine, stopped and position to the server)
    /// and hands it back; `None` without a player. The caller drops it once whatever replaces it is under way.
    fn close_open_player(&mut self, now: f64) -> Option<Box<PlayerScreen>> {
        let mut p = self.player.take()?;
        p.window_closing(now);
        // The resume position and the watched state moved.
        crate::desk::note_list_change();
        Some(p)
    }

    fn after_player(&mut self) {
        if let Some((id, since)) = self.player.as_mut().and_then(|p| p.take_stream_fallback())
            && let Some(w) = &self.live
        {
            self.file_failed.insert(id.clone());
            self.player = None;
            let req = crate::live_play::PlayRequest {
                item_id: id,
                since,
                source_id: None,
            };
            self.last_play = Some(req.clone());
            self.starting = Some(w.core.prepare_play(&w.account, req));
        }
        if self.player.as_ref().is_some_and(|p| p.is_closed()) {
            self.together_ui.receive_cancel();
            // The prompt the finished title earned comes 1.5 s after the player is gone.
            if let Some(n) = self.player.as_mut().and_then(|p| p.take_nudge()) {
                self.queue_nudge(n, self.clock);
            }
            if let Some(p) = self.player.as_mut()
                && let Some(device) = p.taken_to().map(str::to_owned)
            {
                let (title, line) = p.head().clone();
                let line = crate::together_ui::exit_line(&line);
                // Which edge the card leaves by: towards the bigger device, up (`departurePostTop`).
                let own = self
                    .live
                    .as_ref()
                    .map_or_else(|| "Linux".to_owned(), |w| w.core.host().device_name);
                let top = swiftly_playback::handoff_card::departure_post_top(&own, &device);
                self.together_ui.show(crate::together_ui::Mode::Exit {
                    title,
                    line,
                    device,
                    still: p.take_exit_still(),
                    top,
                });
            }
            self.player = None;
            // The resume position and the watched state moved.
            crate::desk::note_list_change();
        }
    }

    /// A desktop shortcut for the player (Space, arrows, letters); `false` when no player is open or the key is not used.
    pub fn player_key(&mut self, key: PlayerKey, now: f64) -> bool {
        self.busy_until = self.busy_until.max(now + 2500.0);
        let used = self.player.as_mut().is_some_and(|p| p.key(key, now));
        self.after_player();
        used
    }

    /// Downloads is a page, not a pushed title: leaving it drops it and brings back the stack of the area behind it.
    fn leave_downloads(&mut self) {
        if matches!(self.top, Some(Top::Downloads(_))) {
            self.gone_page = std::mem::replace(&mut self.top, self.parked[self.tab].take());
            self.page_fade = None;
            self.left_downloads = true;
        }
    }

    /// Starts the area cross fade away from `old`; leaving Downloads only fades the new page in (the old page is gone).
    fn start_fade(&mut self, old: usize) {
        self.fade = Some((old, self.clock));
        self.fade_in_only = std::mem::take(&mut self.left_downloads);
    }

    /// Whether the running area fade only fades the new page in (tests).
    pub fn fade_in_only(&self) -> bool {
        self.fade.is_some() && self.fade_in_only
    }

    /// Where the window stands now.
    fn here(&self) -> Place {
        Place {
            tab: self.tab,
            pages: self.trail[self.tab].clone(),
        }
    }

    /// A page was opened over the section's stack: the place before it is a step back, forward is gone.
    fn record(&mut self, rec: Rec) {
        if !self.stepping {
            let place = self.here();
            self.history.push(place);
            self.future.clear();
        }
        self.trail[self.tab].push(rec);
    }

    /// A section is left for another one (`Navigator.leave`).
    fn leave_section(&mut self, old: usize) {
        if self.stepping {
            return;
        }
        let pages = self
            .leaving
            .take()
            .unwrap_or_else(|| self.trail[old].clone());
        self.history.push(Place { tab: old, pages });
        self.future.clear();
    }

    /// A page closed by itself or by the back arrow: forward can open it again (`Navigator.wentBack`).
    fn went_back(&mut self, old: Place) {
        let now = self.here();
        if now == old {
            return;
        }
        self.future.push(old);
        while self.history.last() == Some(&now) {
            self.history.pop();
        }
    }

    /// The profile page below an account page goes (a sidebar click or Downloads takes the whole panel away, not just its
    /// top): what lies below it is drawn again.
    fn drop_panels_below(&mut self) {
        while matches!(self.under.last(), Some(Top::Settings(_) | Top::Login(_))) {
            self.under.pop();
            self.trail[self.tab].pop();
        }
    }

    /// Takes the page stack of the section away for another one. The profile does not stay in the section left
    /// (`onChange(of: section)`): it closes, and only history remembers it.
    fn park_current(&mut self) {
        let tab = self.tab;
        self.leaving = Some(self.trail[tab].clone());
        while matches!(self.top, Some(Top::Settings(_) | Top::Login(_))) {
            self.top = self.under.pop();
            self.trail[tab].pop();
            self.panel_closing = false;
        }
        self.parked[tab] = self.top.take();
        self.parked_under[tab] = std::mem::take(&mut self.under);
    }

    /// Brings the stack of the section now in front back.
    fn unpark_current(&mut self) {
        if self.top.is_none() {
            self.top = self.parked[self.tab].take();
            self.under = std::mem::take(&mut self.parked_under[self.tab]);
        }
    }

    /// A click on the section already open: every page of its stack goes, in one motion (`back(in:until: 0)`).
    fn pop_to_root(&mut self, now: f64) -> bool {
        let old = self.here();
        if old.pages.is_empty() || self.top.is_none() {
            return false;
        }
        self.trail[self.tab].clear();
        self.under.clear();
        if !self.stepping {
            self.went_back(old);
        }
        self.silent_pops += 1;
        if let Some(t) = &mut self.top {
            on_top!(t, s => s.back(now));
        }
        true
    }

    /// Opens a recorded page again over what lies now.
    fn reopen(&mut self, rec: &Rec, now: f64) {
        let prev = self.top.take();
        match rec {
            Rec::Title(t) if !t.id.is_empty() => {
                if let Some(w) = &self.live {
                    *w.next_kind.borrow_mut() = t.kind.clone();
                    *w.last_title.borrow_mut() = (t.id.clone(), t.name.clone());
                    *w.next_spec.borrow_mut() = t.spec.clone();
                }
                self.fresh_season = None;
                self.push_page(
                    t.series,
                    Some((t.id.clone(), t.name.clone())),
                    Some(t.clone()),
                    now,
                );
            }
            Rec::Title(t) => self.push_page(t.series, None, None, now),
            Rec::Genre(name) => match self.live.clone() {
                Some(w) => {
                    let page = PageScreen::genre_live(self.env, self.cx.clone(), &w, name);
                    self.push_live_page(page, &w, Rec::Genre(name.clone()), now);
                }
                None => self.open_page(PageKind::Genre, now),
            },
            Rec::Collection { id, name, art } => match self.live.clone() {
                Some(w) => {
                    let page = PageScreen::collection_live(
                        self.env,
                        self.cx.clone(),
                        &w,
                        id,
                        name,
                        art.as_deref(),
                    );
                    self.push_live_page(page, &w, rec.clone(), now);
                }
                None => self.open_page(PageKind::Collection, now),
            },
            Rec::Playlist { id, name, art } => match self.live.clone() {
                Some(w) => {
                    let page =
                        PageScreen::playlist_live(self.env, self.cx.clone(), &w, id, name, art);
                    self.push_live_page(page, &w, rec.clone(), now);
                }
                None => self.open_page(PageKind::Playlist, now),
            },
            Rec::Person(tap) => match self.live.clone() {
                Some(w) => {
                    let page = PageScreen::person_live(self.env, self.cx.clone(), &w, tap.clone());
                    self.push_live_page(page, &w, rec.clone(), now);
                }
                None => self.open_page(PageKind::Person, now),
            },
            Rec::Demo(kind) => self.open_page(*kind, now),
            Rec::Settings => {
                let screen = self.settings_screen();
                self.show(Top::Settings(Box::new(screen)), now);
            }
            Rec::Accounts => {
                let screen = match &self.core {
                    Some(core) if self.live.is_some() => {
                        accounts_screen(self.env, self.cx.clone(), core)
                    }
                    _ => LoginScreen::new(self.env, self.cx.clone(), Start::Accounts),
                };
                self.show(Top::Login(Box::new(screen)), now);
            }
        }
        if let Some(p) = prev {
            self.under.push(p);
        }
    }

    /// Puts the window where `place` was: another section is switched to (its stack set), the same section closes or
    /// opens pages to get there.
    fn restore(&mut self, place: Place, now: f64) {
        self.stepping = true;
        self.leave_downloads();
        if place.tab != self.tab {
            self.park_current();
            self.leaving = None;
            self.slide = None;
            front!(self, s => s.set_tab(place.tab));
            self.after_base(now);
            self.unpark_current();
        }
        let have = self.trail[self.tab].clone();
        if have != place.pages {
            let common = have
                .iter()
                .zip(&place.pages)
                .take_while(|(a, b)| a == b)
                .count();
            if common == place.pages.len() && have.len() == common + 1 && self.top.is_some() {
                // One page less: it slides out like any back.
                self.trail[self.tab].pop();
                self.silent_pops += 1;
                if let Some(t) = &mut self.top {
                    on_top!(t, s => s.back(now));
                }
            } else {
                if common < have.len() {
                    // Not a prefix, or several pages less: the stack is set without motion, then the pages open.
                    self.top = None;
                    self.under.clear();
                    self.slide = None;
                    self.trail[self.tab].clear();
                }
                let opened = self.trail[self.tab].len();
                for rec in &place.pages[opened..] {
                    self.reopen(rec, now);
                }
            }
        }
        self.stepping = false;
    }

    /// A keyboard shortcut of the Mac app: switches to a tab (0 Start, 1 Filme, 2 Serien, 3 Suche). Only from a base page
    /// (no title page or player in front). Returns whether it switched.
    pub fn goto_tab(&mut self, n: usize, now: f64) -> bool {
        if n > 4 || self.player.is_some() || self.sheet_modal() {
            return false;
        }
        let from_downloads = matches!(self.top, Some(Top::Downloads(_)));
        self.leave_downloads();
        if n == self.tab {
            // The row of the open section: its pages close, down to the root (`sectionSelect`, "as in Finder").
            if !from_downloads && self.pop_to_root(now) {
                return true;
            }
            if from_downloads && self.reduce_fade() {
                return true;
            }
            if from_downloads {
                self.start_fade(self.tab);
            }
            return from_downloads;
        }
        // Each area keeps its own pushed pages: park these, bring back the ones of the area we go to.
        self.park_current();
        self.slide = None;
        front!(self, s => s.set_tab(n));
        self.after_base(now);
        self.leaving = None;
        self.unpark_current();
        true
    }

    /// A keyboard shortcut of the Mac app: pushes the settings page. Only from a base page. Returns whether it opened.
    pub fn open_settings(&mut self, now: f64) -> bool {
        if self.top.is_some() || self.player.is_some() {
            return false;
        }
        let screen = self.settings_screen();
        self.show(Top::Settings(Box::new(screen)), now);
        true
    }

    /// A finger or button goes down.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        if self.curtain.is_some() {
            return;
        }
        // The version dialog is modal: every click belongs to it.
        if self.version_dialog.0.is_open() {
            match self.version_dialog.0.click(x, y) {
                Some(crate::desk::VersionClick::Pick(i)) => self.pick_version(Some(i)),
                Some(crate::desk::VersionClick::Cancel) => self.pick_version(None),
                _ => {}
            }
            return;
        }
        if self.player.is_none() && self.together_ui.open() {
            self.together_ui.touch_down(x, y, now);
            return;
        }
        if self.env.idiom == swiftly_ui::Idiom::Desktop {
            // The caption buttons are not drawn while a player is open, so they must not catch the click either: the
            // player's own X sits in the same corner and must close the player, not the app.
            if self.player.is_none()
                && let Some(b) = self.controls.hit(x, y)
            {
                self.win_press = Some(b);
                return;
            }
            if y < crate::desk::TOOLBAR_H
                && !crate::desk::NavArrows::hits(x, y)
                && !(self.first_start_back() && crate::forms::on_back_arrow(x, y))
                && self.player.is_none()
            {
                self.win_action = Some(crate::desk::WinAction::DragMove);
                return;
            }
        }
        // A click 60 to 300 ms after Back lands while the page still slides out: the page behind is live at once (the Mac's
        // stack pops on the click), so the slide ends here and the click goes to what is behind.
        if self.player.is_none() && self.top_closing() && x >= self.side() - 0.5 {
            let was_downloads = false;
            self.finish_pop(was_downloads);
        }
        let off = self.side();
        self.busy_until = self.busy_until.max(now + 2500.0);
        if let Some(p) = &mut self.player {
            p.touch_down(x, y, now);
            return;
        }
        // The Discord card: its button opens the invitation, the X closes it; a click on the card is its own.
        if self.env.idiom == swiftly_ui::Idiom::Desktop && self.discord.hits(x - self.side(), y) {
            match self.discord.click(x - self.side(), y) {
                Some(crate::desk::CardTap::Join) => {
                    crate::signin_flows::open_url(crate::effects::DISCORD_URL);
                    self.discord.set_open(false);
                }
                Some(crate::desk::CardTap::Close) => self.discord.set_open(false),
                None => {}
            }
            return;
        }
        // A click on the strip at the bottom of the content withdraws it (`TileMessageStrip`).
        if self.env.idiom == swiftly_ui::Idiom::Desktop && self.hint.hits(x - self.side(), y) {
            self.hint.tap(x - self.side(), y);
            return;
        }
        if self.env.idiom == swiftly_ui::Idiom::Desktop
            && !self.first_run()
            && crate::desk::NavArrows::hits(x, y)
        {
            let (back, forward) = self.can_step();
            match self.arrows.click(x, y, now) {
                Some(true) if back => {
                    self.back(now);
                }
                Some(false) if forward => {
                    self.forward(now);
                }
                _ => {}
            }
            return;
        }
        if self.top.is_some() && x < off && self.sheet_modal() {
            // A sheet is modal, as on the Mac: the sidebar beside it does nothing until the sheet is closed.
            return;
        }
        if self.top.is_some() && x < off {
            // The sidebar stays clickable beside a pushed page (the Mac gives it zIndex 1).
            self.side_press = true;
            front!(self, s => s.touch_down(x, y, now));
            self.note_press_tip(x, y);
            return;
        }
        if let Some(Top::Login(l)) = &mut self.top {
            l.pointer_press(x - off, y, false);
        }
        match &mut self.top {
            Some(t) => on_top!(t, s => s.touch_down(x - off, y, now)),
            None => {
                front!(self, s => s.touch_down(x, y, now));
                self.note_press_tip(x, y);
                self.after_base(now);
            }
        }
        self.after_top();
    }

    /// A sidebar click while a page is pushed: another tab brings its own stack, the active tab goes to its root, the
    /// footer opens the settings, Meins opens Merkliste or Downloads.
    fn sidebar_done(&mut self, now: f64) {
        let cur = self.tab;
        let go = crate::desk::take_go();
        let profile = crate::forms::take_profile();
        // The base screen has already moved its own tab; put it back, the suite decides.
        front!(self, s => s.set_tab(cur));
        // A panel in front: it leaves to the right, the page behind (or the one asked for) travels in from the left.
        if matches!(self.top, Some(Top::Settings(_) | Top::Login(_)))
            && self.slide.is_some()
            && !self.panel_closing
        {
            use crate::nav_machine::Page;
            let dest = match go {
                Some(crate::desk::Go::Tab(i)) => Some(Some(Page::Tab(i.min(4) as u8))),
                Some(crate::desk::Go::Watchlist) => Some(Some(Page::Tab(4))),
                Some(crate::desk::Go::Downloads) => Some(Some(Page::Downloads)),
                None if profile => Some(None),
                Some(crate::desk::Go::Offer) | None => None,
            };
            if let Some(d) = dest {
                self.close_panel_for(d, now);
                return;
            }
        }
        match go {
            Some(crate::desk::Go::Tab(i)) if i == cur => {
                // The row of the open section: its pages close down to the root.
                if !self.pop_to_root(now) {
                    while self.top.is_some() {
                        if !self.back(now) {
                            break;
                        }
                        self.top = None;
                        self.slide = None;
                    }
                }
            }
            Some(crate::desk::Go::Tab(i)) => {
                self.goto_tab(i, now);
            }
            Some(crate::desk::Go::Offer) => self.badge_tapped(),
            Some(crate::desk::Go::Watchlist) => {
                self.goto_tab(4, now);
            }
            Some(crate::desk::Go::Downloads) => {
                self.run_command("cmd.downloads", now);
            }
            None if profile => {
                self.slide = None;
                if let Some(t) = self.top.take() {
                    self.under.push(t);
                }
                self.open_settings(now);
            }
            None => {}
        }
    }

    /// The finger moves.
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        if self.player.is_none() && self.together_ui.open() {
            self.together_ui.touch_move(x, y, now);
            return;
        }
        let off = self.side();
        self.busy_until = self.busy_until.max(now + 2500.0);
        if let Some(p) = &mut self.player {
            p.touch_move(x, y, now);
            if p.take_window_drag() {
                self.win_action = Some(crate::desk::WinAction::MoveWindow);
            }
            return;
        }
        if self.side_press {
            front!(self, s => s.touch_move(x, y, now));
            return;
        }
        if let Some(Top::Login(l)) = &mut self.top {
            l.pointer_drag(x - off, y);
        }
        match &mut self.top {
            Some(t) => on_top!(t, s => s.touch_move(x - off, y, now)),
            None => front!(self, s => s.touch_move(x, y, now)),
        }
    }

    /// The finger lifts.
    pub fn touch_up(&mut self, x: f32, y: f32, now: f64) {
        if self.player.is_none() && self.together_ui.open() {
            self.together_ui.touch_up(x, y, now);
            return;
        }
        if let Some(Top::Login(l)) = &mut self.top {
            l.pointer_release();
        }
        if let Some(b) = self.win_press.take() {
            if self.controls.hit(x, y) == Some(b) {
                self.win_action = Some(match b {
                    crate::desk::WinButton::Min => crate::desk::WinAction::Minimize,
                    crate::desk::WinButton::Max => crate::desk::WinAction::ToggleMaximize,
                    crate::desk::WinButton::Close => {
                        self.quit = true;
                        crate::desk::WinAction::Close
                    }
                });
            }
            return;
        }
        let off = self.side();
        self.busy_until = self.busy_until.max(now + 2500.0);
        if let Some(p) = &mut self.player {
            p.touch_up(x, y, now);
            self.after_player();
            return;
        }
        if std::mem::take(&mut self.side_press) {
            front!(self, s => s.touch_up(x, y, now));
            self.sidebar_done(now);
            return;
        }
        match &mut self.top {
            Some(t) => on_top!(t, s => s.touch_up(x - off, y, now)),
            None => {
                front!(self, s => s.touch_up(x, y, now));
                self.after_base(now);
            }
        }
        self.after_top();
        self.check_play(now);
        self.check_person(now);
        self.check_seerr(now);
        self.pump_fresh_season();
    }

    /// The touch is cancelled.
    pub fn touch_cancel(&mut self, now: f64) {
        if let Some(p) = &mut self.player {
            p.touch_cancel(now);
            return;
        }
        if std::mem::take(&mut self.side_press) {
            front!(self, s => s.touch_cancel(now));
            return;
        }
        match &mut self.top {
            Some(t) => on_top!(t, s => s.touch_cancel(now)),
            None => front!(self, s => s.touch_cancel(now)),
        }
    }

    /// Arrow, Tab, Enter or Esc on the focus engine.
    pub fn nav_key(&mut self, key: NavKey, down: bool, now: f64) -> Outcome {
        if self.player.is_none() && self.together_ui.open() {
            if down {
                match key {
                    NavKey::Escape => self.together_ui.escape(),
                    NavKey::Enter => self.together_ui.confirm(),
                    _ => {}
                }
            }
            return Outcome::None;
        }
        self.busy_until = self.busy_until.max(now + 2500.0);
        if let Some(p) = &mut self.player {
            let o = p.nav_key(key, down, now);
            self.after_player();
            return o;
        }
        // Tab in the sign-in form moves the keyboard from field to field (the focus engine only knows the buttons).
        if let Some(Top::Login(l)) = &mut self.top
            && matches!(key, NavKey::Tab | NavKey::ShiftTab)
        {
            if down {
                l.tab_field(matches!(key, NavKey::ShiftTab));
            }
            if l.wants_text() {
                return Outcome::None;
            }
        }
        let out = match &mut self.top {
            Some(t) => on_top!(t, s => s.nav_key(key, down, now)),
            None => {
                let o = front!(self, s => s.nav_key(key, down, now));
                self.after_base(now);
                o
            }
        };
        self.after_top();
        self.check_play(now);
        self.check_person(now);
        self.check_seerr(now);
        self.pump_fresh_season();
        out
    }

    /// Back (Esc, mouse back button): closes a sheet or the keyboard first, then pops the title page.
    pub fn back(&mut self, now: f64) -> bool {
        if self.version_dialog.0.is_open() {
            self.pick_version(None);
            return true;
        }
        if self.player.is_none() && self.together_ui.open() {
            self.together_ui.escape();
            return true;
        }
        if let Some(p) = &mut self.player {
            p.back(now);
            self.after_player();
            return true;
        }
        if let Some(t) = &mut self.top {
            return on_top!(t, s => s.back(now));
        }
        if self.tab == 3 && self.search.menu_open() {
            let _ = self.search.nav_key(NavKey::Escape, true, now);
            return true;
        }
        if self.tab == 3 && self.search.wants_text() {
            self.search.unfocus();
            return true;
        }
        if self.tab == 0 && self.home.sheet_open() {
            let _ = self.home.nav_key(NavKey::Escape, true, now);
            return true;
        }
        if self.tab == 1 && self.movies.sheet_open()
            || self.tab == 2 && self.series.sheet_open()
            || self.tab == 4 && self.watch.sheet_open()
        {
            front!(self, s => s.nav_key(NavKey::Escape, true, now));
            return true;
        }
        self.step(true, now)
    }

    /// A step through the window history: back or forward to the place before or after this one, sections and closed
    /// pages included (`Navigator.goBack`, `goForward`).
    fn step(&mut self, back: bool, now: f64) -> bool {
        let here = self.here();
        loop {
            let place = if back {
                self.history.pop()
            } else {
                self.future.pop()
            };
            let Some(place) = place else { return false };
            if place == here {
                continue;
            }
            if back {
                self.future.push(here);
            } else {
                self.history.push(here);
            }
            self.restore(place, now);
            return true;
        }
    }

    /// Runs a command of a Ctrl shortcut. Returns whether it did something.
    pub fn run_command(&mut self, cmd: &str, now: f64) -> bool {
        if self.player.is_some() && cmd != "cmd.quit" {
            return false;
        }
        match cmd {
            "cmd.settings" => self.open_settings(now),
            "cmd.profile" => {
                let (env, cx) = (self.env, self.cx.clone());
                let screen = match &self.core {
                    Some(core) if self.live.is_some() => accounts_screen(env, cx, core),
                    _ => LoginScreen::new(env, cx, Start::Accounts),
                };
                self.show(Top::Login(Box::new(screen)), now);
                true
            }
            "cmd.start" => self.goto_tab(0, now),
            "cmd.movies" => self.goto_tab(1, now),
            "cmd.series" => self.goto_tab(2, now),
            "cmd.search" => {
                // Cmd+F: the search section, field focused, also when it is already open.
                let moved = self.goto_tab(3, now);
                let here = self.tab == 3 && self.top.is_none();
                if here && crate::home::Form::of(self.env.idiom) == crate::home::Form::Desktop {
                    self.search.focus();
                }
                moved || here
            }
            // The shortcuts exist only while the section does (`if model.watchlistShown`, `if model.downloadsAn`).
            "cmd.watchlist" => crate::desk::mine().0 && self.goto_tab(4, now),
            "cmd.downloads" => {
                if !crate::desk::mine().1 {
                    return false;
                }
                if matches!(self.top, Some(Top::Downloads(_))) || self.player.is_some() {
                    return false;
                }
                // Downloads is a page of the sidebar: the pushed titles of this area wait behind it.
                if !matches!(self.top, Some(Top::Settings(_) | Top::Login(_))) {
                    self.parked[self.tab] = self.top.take();
                }
                self.drop_panels_below();
                self.slide = None;
                let screen = self.downloads_page();
                self.show(Top::Downloads(Box::new(screen)), now);
                true
            }
            "cmd.back" => self.back(now),
            "cmd.forward" => self.forward(now),
            "cmd.quit" => {
                self.quit = true;
                true
            }
            _ => false,
        }
    }

    /// The window action the last input asked for, left in place.
    pub fn peek_window_action(&self) -> Option<crate::desk::WinAction> {
        self.win_action
    }

    /// The window action the last input asked for since the last call.
    pub fn take_window_action(&mut self) -> Option<crate::desk::WinAction> {
        self.win_action.take()
    }

    /// The window is (no longer) maximised.
    pub fn set_maximized(&mut self, on: bool) {
        self.controls.set_maximized(on);
    }

    /// The window should close.
    pub fn quit_asked(&self) -> bool {
        self.quit
    }

    /// Whether the arrows can go back and forward.
    pub fn can_step(&self) -> (bool, bool) {
        let here = self.here();
        (
            self.top.is_some() || self.history.iter().any(|p| *p != here),
            self.future.iter().any(|p| *p != here),
        )
    }

    /// Forward in the history (mouse forward button, Alt+Right, the arrow).
    pub fn forward(&mut self, now: f64) -> bool {
        self.player.is_none() && self.step(false, now)
    }

    /// The vertical scroll offset of the page in front (tests, measuring).
    pub fn page_offset(&mut self) -> f64 {
        match self.tab {
            0 => self.home.page_offset(),
            _ => 0.0,
        }
    }

    /// Whether the wheel may scroll the page in front directly (a base page, no player).
    pub fn wheel_direct(&self) -> bool {
        // The player takes the wheel only for its episode strip (the volume wheel is handled before).
        if let Some(p) = &self.player {
            return p.episodes_open();
        }
        matches!(
            &self.top,
            None | Some(Top::Detail(_) | Top::Series(_) | Top::Page(_))
        )
    }

    /// Pushes a page of `kind` (a person, a playlist, a genre, a collection) over the tabs.
    pub fn open_page(&mut self, kind: PageKind, now: f64) {
        self.record(Rec::Demo(kind));
        let mut top = Top::Page(Box::new(PageScreen::new(
            self.env,
            self.cx.clone(),
            kind,
            Scenario::Ready,
        )));
        {
            let pe = self.page_env();
            on_top!(&mut top, s => s.set_env(pe));
            on_top!(&mut top, s => s.open(now));
        }
        self.top = Some(top);
        self.pushes += 1;
    }

    /// Pushes a live genre, collection or playlist page over the page in front, with its pictures.
    fn push_live_page(&mut self, page: PageScreen, w: &crate::live::Wiring, rec: Rec, now: f64) {
        self.record(rec);
        let mut top = Top::Page(Box::new(page.with_images(Rc::clone(&w.hub))));
        let pe = self.page_env();
        on_top!(&mut top, s => s.set_env(pe));
        on_top!(&mut top, s => s.open(now));
        self.top = Some(top);
        self.pushes += 1;
    }

    /// What the sidebar highlights now (the navigation machine's answer; tests).
    pub fn selected(&self) -> crate::nav_machine::Selected {
        self.nav.selected()
    }

    /// Whether a push, pop or panel slide is running (tests).
    pub fn sliding(&self) -> bool {
        self.slide.as_ref().is_some_and(Nav::is_animating)
    }

    /// The shift of the page behind a moving page in the last frame, in points (negative: left of its place; tests).
    pub fn below_shift(&self) -> f32 {
        self.last_below_dx
    }

    /// Whether the pushed page is open (not on its way out; tests). A page that is closed must leave with its slide.
    pub fn top_open(&self) -> bool {
        self.top
            .as_ref()
            .is_some_and(|t| on_top!(t, s => s.is_open()))
    }

    /// Which pushed page is in front: "detail", "series", "page" (tests).
    pub fn top_kind(&self) -> Option<&'static str> {
        match &self.top {
            Some(Top::Detail(_)) => Some("detail"),
            Some(Top::Series(_)) => Some("series"),
            Some(Top::Page(_)) => Some("page"),
            _ => None,
        }
    }

    /// Remembers the tooltip the press at `(x, y)` just hid on the page in front.
    fn note_press_tip(&mut self, x: f32, y: f32) {
        self.press_tip = front!(self, s => s.dismissed_tooltip()).map(|t| ((x, y), t));
    }

    /// The pointer moved with no button held: hover, tooltips, cursor and the rail arrows of the page in front.
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        self.pointer_at = Some((x, y));
        // A click that changed the page (a sidebar row) hid its tooltip: the page in front keeps it hidden while the
        // pointer rests on the same spot (the Mac's help tag comes back only after the pointer left the row).
        match self.press_tip.clone() {
            Some((at, text)) if at == (x, y) => {
                front!(self, s => s.inherit_dismissed_tooltip(Some(text.clone())));
            }
            _ => self.press_tip = None,
        }
        let off = self.side();
        if self.player.is_none() && self.together_ui.open() {
            self.together_ui.pointer_move(x, y, now);
            return;
        }
        if self.player.is_some() {
            return;
        }
        self.controls.pointer(x, y, now);
        if !self.first_run() && crate::desk::NavArrows::hits(x, y) {
            self.arrows.pointer(x, y, now);
        } else {
            self.arrows.leave(now);
        }
        if self.top.is_some() && x < off {
            front!(self, s => s.pointer_move(x, y, now));
            return;
        }
        match &mut self.top {
            None => front!(self, s => s.pointer_move(x, y, now)),
            Some(Top::Detail(s)) => s.pointer_move(x - off, y, now),
            Some(Top::Series(s)) => s.pointer_move(x - off, y, now),
            Some(Top::Page(s)) => s.pointer_move(x - off, y, now),
            Some(Top::Settings(s)) => s.pointer_move(x - off, y, now),
            Some(Top::Downloads(s)) => s.pointer_move(x - off, y, now),
            Some(Top::Login(s)) => s.pointer_move(x - off, y, now),
        }
    }

    /// The pointer left the window.
    pub fn pointer_leave(&mut self, now: f64) {
        self.pointer_at = None;
        self.arrows.leave(now);
        self.controls.leave(now);
        if self.player.is_some() {
            return;
        }
        if self.top.is_some() {
            // The pointer may have been over the base page beside the pushed one (the sidebar strip).
            front!(self, s => s.pointer_leave(now));
        }
        match &mut self.top {
            None => front!(self, s => s.pointer_leave(now)),
            Some(Top::Detail(s)) => s.pointer_leave(now),
            Some(Top::Series(s)) => s.pointer_leave(now),
            Some(Top::Page(s)) => s.pointer_leave(now),
            Some(Top::Settings(s)) => s.pointer_leave(now),
            Some(Top::Downloads(s)) => s.pointer_leave(now),
            Some(Top::Login(s)) => s.pointer_leave(now),
        }
    }

    /// The cursor the page in front asks for.
    pub fn cursor(&mut self) -> swiftly_ui::Cursor {
        if self.player.is_some() {
            return swiftly_ui::Cursor::Arrow;
        }
        match &mut self.top {
            None => front!(self, s => s.cursor()),
            Some(Top::Detail(s)) => s.cursor(),
            Some(Top::Series(s)) => s.cursor(),
            Some(Top::Page(s)) => s.cursor(),
            Some(_) => swiftly_ui::Cursor::Arrow,
        }
    }

    /// The tooltip the base page in front has earned at `now` (tests).
    #[doc(hidden)]
    pub fn base_tooltip(&mut self, now: f64) -> Option<(String, swiftly_layout::Rect)> {
        front!(self, s => s.visible_tooltip(now))
    }

    /// The tooltip to draw over the page in front (the pushed pages draw their own through `Ui::frame`).
    pub fn tooltip(&mut self, now: f64) -> Option<(String, swiftly_layout::Rect)> {
        match &mut self.top {
            Some(Top::Detail(s)) => s.visible_tooltip(now),
            Some(Top::Series(s)) => s.visible_tooltip(now),
            Some(Top::Page(s)) => s.visible_tooltip(now),
            _ => None,
        }
    }

    /// A right click: the context menu of a tile or button under the pointer.
    pub fn secondary_click(&mut self, x: f32, y: f32, now: f64) -> bool {
        let off = self.side();
        if let Some(p) = &mut self.player {
            return p.secondary_click(x, y, now);
        }
        self.busy_until = self.busy_until.max(now + 2500.0);
        match &mut self.top {
            None => front!(self, s => s.secondary_click(x, y, now)),
            Some(Top::Detail(s)) => s.secondary_click(x - off, y, now),
            Some(Top::Series(s)) => s.secondary_click(x - off, y, now),
            Some(Top::Page(s)) => s.secondary_click(x - off, y, now),
            Some(_) => false,
        }
    }

    /// A wheel notch on the page in front.
    pub fn wheel_scroll(&mut self, x: f32, y: f32, dx: f32, dy: f32, now: f64) -> bool {
        let off = self.side();
        if !self.wheel_direct() {
            return false;
        }
        if let Some(p) = &mut self.player {
            return p.wheel_scroll(x, y, dx, dy, now);
        }
        match &mut self.top {
            None => front!(self, s => s.wheel_scroll(x, y, dx, dy, now)),
            Some(Top::Detail(s)) => s.wheel_scroll(x - off, y, dx, dy, now),
            Some(Top::Series(s)) => s.wheel_scroll(x - off, y, dx, dy, now),
            Some(Top::Page(s)) => s.wheel_scroll(x - off, y, dx, dy, now),
            Some(_) => false,
        }
    }

    /// Home, End, Page up and down on the page in front.
    pub fn scroll_key(&mut self, key: swiftly_ui::shortcuts::ScrollKey, now: f64) -> bool {
        if self.top.is_some() || self.player.is_some() || !self.wheel_direct() {
            return false;
        }
        front!(self, s => s.scroll_key(key, now))
    }

    /// Whether a focused text field takes typed text. The player has none: its keys (Space, arrows, letters) go to the
    /// window rules, so only a real field in front (search, settings, sign-in, a Together code) may swallow keys.
    pub fn wants_text(&self) -> bool {
        if self.player.is_some() {
            return false;
        }
        if self.together_ui.wants_text() {
            return true;
        }
        match &self.top {
            Some(Top::Settings(s)) => s.wants_text(),
            Some(Top::Login(l)) => l.wants_text(),
            Some(_) => false,
            None => self.tab == 3 && self.search.wants_text(),
        }
    }

    /// What the input method needs for the screen in front: open only over a text field, a password purpose on a
    /// password field, and the caret's rectangle in window points.
    pub fn ime_state(&self) -> crate::ime::ImeState {
        if self.player.is_some() {
            return crate::ime::ImeState::default();
        }
        match &self.top {
            Some(Top::Settings(s)) => s.ime_state(),
            Some(Top::Login(l)) => l.ime_state(),
            Some(_) => crate::ime::ImeState::default(),
            None if self.tab == 3 => self.search.ime_state(),
            None => crate::ime::ImeState::default(),
        }
    }

    /// Typed text for the search field.
    pub fn type_text(&mut self, s: &str) {
        if let Some(p) = &mut self.player {
            p.type_text(s, self.clock);
            return;
        }
        if !self.wants_text() {
            return;
        }
        if self.together_ui.wants_text() {
            self.together_ui.type_text(s);
            return;
        }
        if let Some(Top::Settings(st)) = &mut self.top {
            st.type_text(s);
        } else if let Some(Top::Login(l)) = &mut self.top {
            l.type_text(s);
        } else {
            self.search.type_text(s);
        }
    }

    /// A full text-input event (composition, caret keys, clipboard, undo) for the field in front. The login form only
    /// takes typed text, Backspace and Return. Returns whether the field used it.
    pub fn text_event(&mut self, ev: &swiftly_text::TextInputEvent) -> bool {
        if self.player.is_some() || !self.wants_text() {
            return false;
        }
        if self.together_ui.wants_text() {
            return self.together_ui.text_event(ev);
        }
        if let Some(Top::Settings(st)) = &mut self.top {
            return st.edit(ev);
        }
        if let Some(Top::Login(l)) = &mut self.top {
            return l.edit(ev);
        }
        let _ = self.search.text_event(ev);
        true
    }

    /// Backspace in the search field.
    pub fn backspace(&mut self) {
        if self.player.is_some() || !self.wants_text() {
            return;
        }
        if self.together_ui.wants_text() {
            self.together_ui.backspace();
            return;
        }
        if let Some(Top::Settings(st)) = &mut self.top {
            st.backspace();
        } else if let Some(Top::Login(l)) = &mut self.top {
            l.backspace();
        } else {
            self.search.backspace();
        }
    }

    /// Return in the search field.
    pub fn submit(&mut self) {
        if self.player.is_some() || !self.wants_text() {
            return;
        }
        if self.together_ui.wants_text() {
            self.together_ui.confirm();
            return;
        }
        if let Some(Top::Settings(st)) = &mut self.top {
            st.submit();
        } else if let Some(Top::Login(l)) = &mut self.top {
            l.submit();
        } else {
            self.search.submit();
        }
    }

    /// One frame at `now` ms. Returns the quads and whether another frame is wanted.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        // Downloads is a section on the Mac: while it is the page in front, its sidebar row is the active one.
        self.resync_nav();
        let sel = self.nav.selected();
        crate::desk::set_downloads_front(
            sel == crate::nav_machine::Selected::Downloads && self.player.is_none(),
        );
        crate::desk::set_settings_front(
            sel == crate::nav_machine::Selected::Settings && self.player.is_none(),
        );
        self.pump_support(now);
        let (list, more) = self.frame_inner(now);
        // What a page posted while it ran (a play that cannot start) shows in the strip, on the next frame.
        let posted = crate::desk::take_hints();
        let more = more || !posted.is_empty();
        for text in &posted {
            self.show_hint(text, now);
        }
        // The real app waits for the network: view models and pictures arrive between input events, so it keeps asking.
        let waiting = (self.live.is_some()
            && (now < self.busy_until
                || self.starting.is_some()
                || self.season_read.is_some()
                || self.film_read.is_some()))
            || matches!(&self.top, Some(Top::Login(l)) if l.pending());
        (list, more || waiting)
    }

    /// The support card at the end of Start (`SupportModel.cardVisible`): feeds the watch time while the player is open,
    /// decides about once a second (never with the player open), and runs the card's two buttons.
    fn pump_support(&mut self, now: f64) {
        let Some(w) = self.live.clone() else { return };
        let wall = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        if self.support.is_none() {
            self.support = Some((
                crate::support_card::SupportCard::new(Arc::clone(&w.core.settings), wall),
                f64::MIN,
                false,
            ));
        }
        let open = self.player.is_some();
        let playing = open && self.now_playing().is_some_and(|n| n.playing);
        let Some((card, looked, was_open)) = self.support.as_mut() else {
            return;
        };
        if open {
            card.feed(playing, wall);
        } else if *was_open {
            card.stopped(wall);
        }
        *was_open = open;
        match self.home.take_support_tap() {
            Some(crate::home::SupportTap::Open) => {
                let _ = crate::signin_flows::open_url(crate::support_card::SUPPORTER_PAGE);
            }
            Some(crate::home::SupportTap::Snooze) => {
                card.snooze(wall);
                self.home.set_support(None);
            }
            None => {}
        }
        if now - *looked >= 1000.0 {
            *looked = now;
            let due = if open { None } else { card.due(false, wall) };
            self.home.set_support(due);
        }
    }

    /// The "Laden" of a film's detail page reads the live title and opens the add sheet on the Downloads page.
    fn pump_film_read(&mut self, now: f64) {
        if let Some(Top::Detail(d)) = &mut self.top
            && let Some(anchor) = d.take_download()
            && let Some(w) = &self.live
        {
            let (id, _) = w.last_title.borrow().clone();
            self.film_read = crate::live_downloads::film_read(&w.core, &w.account, &id, anchor);
            self.busy_until = self.busy_until.max(now + 2500.0);
        }
        let Some(read) = self.film_read.take() else {
            return;
        };
        match read.poll() {
            Ok(Some(request)) => self.request_load(request, now),
            Ok(None) => self.film_read = Some(read),
            Err(()) => {}
        }
    }

    /// The window-point frame of the control `key` on the detail page in front (tests).
    #[doc(hidden)]
    pub fn detail_frame_of(&mut self, key: &str) -> Option<[f32; 4]> {
        let off = self.side();
        match self.top.as_mut()? {
            Top::Detail(d) => d.frame_of(key).map(|f| [f[0] + off, f[1], f[2], f[3]]),
            _ => None,
        }
    }

    /// The window-point frame of the control `key` on the pushed page (person, collection, ...) in front (tests).
    #[doc(hidden)]
    pub fn page_frame_of(&mut self, key: &str) -> Option<[f32; 4]> {
        let off = self.side();
        match self.top.as_mut()? {
            Top::Page(p) => p.frame_of(key).map(|f| [f.x + off, f.y, 0.0, 0.0]),
            _ => None,
        }
    }

    /// The reading list of the pushed page (person, collection, ...) in front (tests).
    #[doc(hidden)]
    pub fn page_a11y_nodes(&mut self) -> Vec<swiftly_ui::a11y::A11yNode> {
        match self.top.as_mut() {
            Some(Top::Page(p)) => p.a11y_nodes(),
            _ => Vec::new(),
        }
    }

    /// The "Laden" of a series page starts the live season read; its answers feed the season sheet on the Downloads page.
    fn pump_season_read(&mut self, now: f64) {
        if let Some(Top::Series(s)) = &mut self.top
            && let Some(anchor) = s.take_download()
            && let Some(w) = &self.live
        {
            let (id, name) = w.last_title.borrow().clone();
            self.season_read =
                crate::live_downloads::season_read(&w.core, &w.account, &id, &name, anchor);
            self.busy_until = self.busy_until.max(now + 2500.0);
        }
        let Some(mut read) = self.season_read.take() else {
            return;
        };
        let pending: Vec<String> = self.season_pending().concat();
        let poll = read.poll(self.load_open(), &pending);
        if let Some(request) = poll.open {
            self.request_load(request, now);
        }
        for (id, episodes) in poll.loaded {
            self.season_loaded(&id, episodes);
        }
        if poll.finished {
            self.season_finished();
        }
        if !poll.gone {
            self.season_read = Some(read);
        }
    }

    /// A `swiftly://` link arrived (command line or second launch): see `link_route`.
    pub fn open_link(&mut self, link: crate::deep_link::DeepLink, now: f64) {
        self.link_step(crate::link_route::Event::Arrived(link), now);
        self.busy_until = self.busy_until.max(now + 2500.0);
    }

    /// Runs one event through the link machine and does what comes out.
    fn link_step(&mut self, event: crate::link_route::Event, now: f64) {
        use crate::link_route::{Action, Ctx};
        let ctx = Ctx {
            signed_in: self.live.is_some(),
            player_busy: self.player.is_some() || self.starting.is_some(),
        };
        let (next, action) = crate::link_route::reduce(
            std::mem::replace(&mut self.link, crate::link_route::LinkState::Idle),
            ctx,
            event,
        );
        self.link = next;
        match action {
            Action::None => {}
            Action::PlayerBusy => {
                if let Some(p) = &mut self.player {
                    p.announce(
                        "Es läuft schon ein Titel. Schließe ihn, dann öffnet der Link.".to_owned(),
                        now,
                    );
                }
            }
            Action::Fetch(id) => {
                let (tx, rx) = crate::login_screen::Pending::channel();
                if let Some(w) = &self.live
                    && let Ok(server) = w.core.server_for(&w.account)
                {
                    w.core.spawn(async move {
                        let found = crate::live_server::item(&server, &id).await.ok().map(|i| {
                            crate::link_route::Found {
                                kind: i.type_.clone().unwrap_or_default(),
                                id: i.id,
                                title: i.name,
                            }
                        });
                        let _ = tx.send(found);
                    });
                } else {
                    let _ = tx.send(None);
                }
                self.link_fetch = Some(rx);
            }
            Action::Play(id) => {
                // An open player closes first, through the same path as Esc and the window close: the old title is
                // reported as stopped with its resume position before the new one starts.
                drop(self.close_open_player(now));
                self.starting = None;
                self.reset_to_start(now);
                self.resume(&id, now);
            }
            Action::Show(found) => {
                self.reset_to_start(now);
                if let Some(w) = &self.live {
                    *w.next_kind.borrow_mut() = found.kind.clone();
                    *w.last_title.borrow_mut() = (found.id.clone(), found.title.clone());
                    *w.next_spec.borrow_mut() = swiftly_vm::SeriesSpec::default();
                }
                let target = crate::title_target::Target {
                    series: found.series_page(),
                    id: found.id.clone(),
                    name: found.title.clone(),
                    kind: found.kind.clone(),
                    spec: swiftly_vm::SeriesSpec::default(),
                };
                self.push_page(
                    found.series_page(),
                    Some((found.id, found.title)),
                    Some(target),
                    now,
                );
            }
            Action::Home => self.reset_to_start(now),
            Action::Settings => {
                self.reset_to_start(now);
                self.open_settings(now);
            }
            Action::Search(q) => {
                self.reset_to_start(now);
                self.goto_tab(3, now);
                self.search.type_text(&q);
            }
        }
    }

    /// Start with no page pushed on any area: where the Mac sends a link (`section = .start`, stacks emptied).
    fn reset_to_start(&mut self, now: f64) {
        if self.player.is_some() || matches!(self.top, Some(Top::Login(_))) {
            return;
        }
        self.top = None;
        self.slide = None;
        self.parked = Default::default();
        self.parked_under = Default::default();
        self.under.clear();
        self.trail = Default::default();
        self.history.clear();
        self.future.clear();
        self.sliding_out = false;
        if self.tab != 0 {
            self.goto_tab(0, now);
        }
    }

    /// Feeds the link machine: the account being there and the finished read of a title.
    fn poll_link(&mut self, now: f64) {
        if let Some(p) = &self.link_fetch
            && let Ok(found) = p.0.try_recv()
        {
            self.link_fetch = None;
            self.link_step(crate::link_route::Event::Fetched(found), now);
        } else if matches!(
            self.link,
            crate::link_route::LinkState::WaitingForAccount(_)
        ) {
            self.link_step(crate::link_route::Event::Tick, now);
        }
    }

    /// What the hub of the account has for the app: steps and remote commands go to the open player, a title to start
    /// (the group's, a "play on this device" order, a takeover that went through) opens the player on it.
    fn pump_hub(&mut self, now: f64) {
        use crate::together::HubEvent as E;
        let Some(w) = self.live.clone() else { return };
        let Some(hub) = w.together() else { return };
        for line in hub.take_log() {
            eprintln!("together: {line}");
        }
        for event in hub.take_events() {
            let start = match event {
                E::LoadTitle { title, since } => {
                    self.group_start = true;
                    Some((title, since, None))
                }
                E::StartHere { item_id, since } => Some((item_id, since, None)),
                E::Play(order) => {
                    let id = order.item_id().map(str::to_owned);
                    id.map(|i| (i, order.start, order.media_source_id.clone()))
                }
                other => {
                    if let Some(p) = &mut self.player {
                        p.hub_event(other, now);
                    }
                    None
                }
            };
            if let Some((item_id, since, source_id)) = start {
                // The old picture goes without leaving the group: the new player joins in again on its own. A group's
                // title only drops it; any other order closes it first, so the old title is reported as stopped.
                if self.group_start {
                    self.player = None;
                } else {
                    drop(self.close_open_player(now));
                }
                let req = crate::live_play::PlayRequest {
                    item_id,
                    since,
                    source_id,
                };
                self.starting = Some(w.core.prepare_play(&w.account, req));
            }
        }
    }

    // ---- watching together and continuing on another device ----

    /// The sessions that play elsewhere and the groups open to join (`OfferingRow`: groups count only while in none).
    fn together_offers(
        hub: &crate::together::Hub,
    ) -> (Vec<swiftly_vm::TakeoverRow>, Vec<swiftly_vm::GroupRow>) {
        use swiftly_vm::TakeoverPart as T;
        let sessions = match hub.takeover().1 {
            T::Badge { rows } | T::Choosing { rows } => rows,
            T::Hidden | T::Taking { .. } | T::Failed { .. } => Vec::new(),
        };
        let part = hub.part();
        let groups = if part.current.is_none() && part.may_join {
            part.groups
        } else {
            Vec::new()
        };
        (sessions, groups)
    }

    /// Once per frame: the offer row of the sidebars, the rows and the state of the panel, what the panel chose and the
    /// requests of the tile menus.
    fn together_tick(&mut self, now: f64) {
        use crate::together_ui::{Act, Mode, PickRow, PickTarget};
        let hub = self.live.as_ref().and_then(|w| w.together());
        let Some(hub) = hub else {
            crate::desk::set_offer(None);
            if self.together_ui.open() {
                self.together_ui.close();
            }
            return;
        };
        if self.player.is_none() && now - self.together_at >= 8000.0 {
            self.together_at = now;
            hub.refresh();
            hub.poll_now();
        }
        let (sessions, groups) = Self::together_offers(&hub);
        let count = sessions.len() + groups.len();
        let offer = (count > 0 && self.player.is_none()).then(|| crate::desk::Offer {
            symbol: sessions
                .first()
                .map_or("users.fill", |s| crate::together_ui::device_symbol(s.kind))
                .to_owned(),
            title: if count > 1 {
                "Läuft gerade"
            } else if sessions.is_empty() {
                "Gemeinsam schauen"
            } else {
                "Hier weiterschauen"
            }
            .to_owned(),
            under: sessions
                .iter()
                .map(|s| s.title.clone())
                .chain(groups.iter().map(|g| g.name.clone()))
                .collect::<Vec<_>>()
                .join(", "),
            count,
        });
        crate::desk::set_offer(offer);
        // The picker of several devices and a failed takeover come from the hub.
        let take = hub.takeover().1;
        match (&take, self.together_ui.mode()) {
            (swiftly_vm::TakeoverPart::Choosing { .. }, Mode::Closed) => {
                self.together_ui.show(Mode::Pick);
            }
            (swiftly_vm::TakeoverPart::Taking { .. }, m) if !matches!(m, Mode::Receive { .. }) => {
                if let Some((title, line, device)) = hub.taking_texts() {
                    self.together_ui.show(Mode::Receive {
                        title,
                        line,
                        device,
                    });
                }
            }
            (swiftly_vm::TakeoverPart::Failed { .. }, Mode::Receive { .. }) => {
                self.together_ui.receive_cancel();
            }
            (swiftly_vm::TakeoverPart::Failed { message }, m)
                if !matches!(m, Mode::Failed(_) | Mode::Receive { .. }) =>
            {
                self.together_ui.show(Mode::Failed(message.clone()));
            }
            _ => {}
        }
        let rows: Vec<PickRow> = sessions
            .iter()
            .map(|s| PickRow {
                target: PickTarget::Session(s.id.clone()),
                symbol: crate::together_ui::device_symbol(s.kind).to_owned(),
                title: if s.device.is_empty() {
                    "Gerät".to_owned()
                } else {
                    s.device.clone()
                },
                under: s.title.clone(),
            })
            .chain(groups.iter().map(|g| PickRow {
                target: PickTarget::Group(g.clone()),
                symbol: "users.fill".to_owned(),
                title: g.name.clone(),
                under: g.who.clone(),
            }))
            .collect();
        let empty = rows.is_empty();
        self.together_ui.set_rows(rows);
        self.together_ui.set_works(hub.part().works);
        match self.together_ui.mode().clone() {
            Mode::Pick if empty => self.together_ui.close(),
            Mode::Create { .. } | Mode::Join(_) if hub.in_group() => self.together_ui.close(),
            Mode::Exit { .. } if self.together_ui.exit_over() => self.together_ui.close(),
            Mode::Receive { .. } if self.together_ui.receive_over() => self.together_ui.close(),
            _ => {}
        }
        for act in self.together_ui.take_acts() {
            match act {
                Act::Cancel => {
                    hub.takeover_cancel();
                    self.together_ui.close();
                }
                Act::Create { name, title_id } => hub.create(&name, &title_id),
                Act::Join(g) => {
                    hub.join(&g.id);
                    self.together_ui.close();
                }
                Act::Take(id) => {
                    self.together_ui.close();
                    hub.takeover_pick(&id);
                }
            }
        }
        self.pump_tile_requests(&hub);
    }

    /// The sidebar row was clicked: one device is taken at once, one group opens its "Beitreten", the rest opens the picker
    /// (`MainView.badgePressed`).
    fn badge_tapped(&mut self) {
        let Some(hub) = self.live.as_ref().and_then(|w| w.together()) else {
            return;
        };
        let (sessions, groups) = Self::together_offers(&hub);
        // The picker grows out of the middle of the row.
        self.together_ui.set_origin(
            swiftly_design::tokens::desktop::SIDEBAR_WIDTH / 2.0,
            self.env.size.h - 48.0 - 10.0 - 12.0 - 20.0,
        );
        if groups.is_empty() {
            hub.badge_tapped();
        } else if sessions.is_empty() && groups.len() == 1 {
            self.together_ui
                .show(crate::together_ui::Mode::Join(groups[0].clone()));
        } else {
            self.together_ui.show(crate::together_ui::Mode::Pick);
        }
    }

    /// "Abspielen auf …" and "Gemeinsam schauen" of the tile menus on the pages and in the rails.
    fn pump_tile_requests(&mut self, hub: &crate::together::Hub) {
        use swiftly_vm::TileRequest as R;
        let mut requests: Vec<R> = Vec::new();
        match &mut self.top {
            Some(Top::Detail(d)) => requests.extend(d.take_requests()),
            Some(Top::Series(s)) => requests.extend(s.take_requests()),
            _ => {}
        }
        requests.extend(self.search.take_requests());
        for screen in [&self.movies, &self.series, &self.watch] {
            requests.extend(screen.vm().take_requests());
        }
        for line in self.home.take_requests() {
            let mut parts = line.splitn(3, ':');
            match (parts.next(), parts.next(), parts.next()) {
                (Some("Together"), Some(id), _) => requests.push(R::Together { id: id.to_owned() }),
                (Some("PlayOn"), Some(id), Some(device)) => requests.push(R::PlayOn {
                    id: id.to_owned(),
                    device: device.to_owned(),
                }),
                _ => {}
            }
        }
        for request in requests {
            match request {
                R::PlayOn { id, device } => hub.play_on(&id, &device, None),
                R::Together { id } => {
                    let line = self.together_line(&id);
                    self.together_ui
                        .show(crate::together_ui::Mode::Create { title_id: id, line });
                }
                R::Load { .. } => {}
            }
        }
    }

    fn poll_start(&mut self, now: f64) {
        self.together_tick(now);
        self.pump_hub(now);
        self.poll_link(now);
        self.pump_season_read(now);
        self.pump_film_read(now);
        if self.starting.is_none()
            && let (Some(Top::Downloads(d)), Some(w)) = (&mut self.top, &self.live)
            && let Some(id) = d.take_opened().pop()
        {
            self.starting = Some(if self.file_failed.contains(&id) {
                // The file did not open before: the stream, from the saved position.
                w.core.prepare_play(
                    &w.account,
                    crate::live_play::PlayRequest {
                        item_id: id,
                        since: -1.0,
                        source_id: None,
                    },
                )
            } else {
                crate::live_offline::pending_offline(&w.core, &w.account, &id)
            });
        }
        let Some(p) = &self.starting else { return };
        let Ok(done) = p.0.try_recv() else { return };
        self.starting = None;
        let (Some(w), true) = (&self.live, self.player.is_none()) else {
            return;
        };
        let done = match done {
            // Several versions (Plex): the title page shows its version sheet; elsewhere the first version plays.
            Ok(crate::live_play::Prepared::Choose(ask)) => {
                if let Some(Top::Detail(d)) = &mut self.top {
                    d.offer_versions(ask.item_id, ask.since, ask.versions);
                } else {
                    // Anywhere else the shell asks, like the Mac's `.versionChoice` on its main view.
                    let labels = ask.versions.iter().map(|v| v.label.clone()).collect();
                    self.version_dialog.0.set(Some(labels));
                    self.version_dialog.1 = Some(ask);
                }
                return;
            }
            other => other,
        };
        let opened_id = done
            .as_ref()
            .ok()
            .and_then(|p| p.ready())
            .map(|r| r.item_id().to_owned());
        match done.and_then(|prep| w.core.open_player(self.env, self.cx.clone(), now, prep)) {
            Ok(mut screen) => {
                self.group_start = false;
                if let (Some(hub), Some(id)) = (w.together(), &opened_id) {
                    screen.attach_together(hub, id);
                }
                // The next episode, a quality choice and a subtitle on a transcode all go through this host.
                screen.set_planner(w.core.planner(&w.account));
                self.player = Some(Box::new(screen));
                self.together_ui.receive_player_up();
            }
            Err(e) => {
                eprintln!("play: {e}");
                self.together_ui.receive_cancel();
                // The group's title does not open here: the group is told, so it does not wait for this device.
                if std::mem::take(&mut self.group_start)
                    && let Some(hub) = w.together()
                {
                    hub.title_load_failed();
                }
                // The Mac's `PlayControls`: no player, the strip at the bottom of the content says it.
                let server = match crate::desk::card() {
                    crate::desk::Card::Account { server, .. } => Some(server),
                    _ => None,
                };
                self.show_hint(&plan_refused_text(server.as_deref()), now);
            }
        }
    }

    /// A finished title earned `nudge`: the card comes [`crate::desk::DISCORD_CARD_DELAY_MS`] after `now`.
    pub fn queue_nudge(&mut self, nudge: swiftly_vm::Nudge, now: f64) {
        self.nudge = Some((nudge, now + crate::desk::DISCORD_CARD_DELAY_MS));
    }

    /// Puts the card up when its time has come and no player is open; while a player runs the wait starts again, so the card
    /// never appears over a film (`RootView.swift:84`). It counts as shown only now.
    fn discord_due(&mut self, now: f64) {
        let Some((n, at)) = self.nudge else { return };
        if self.player.is_some() {
            self.nudge = Some((n, now + crate::desk::DISCORD_CARD_DELAY_MS));
            return;
        }
        if now < at {
            return;
        }
        self.nudge = None;
        match n {
            swiftly_vm::Nudge::Discord => {
                if let Some(w) = &self.live {
                    w.core.after_play().mark_shown(n);
                }
                self.discord.set_open(true);
            }
            // No review prompt on the desktop (`AfterPlay` is built without one), so this never comes.
            swiftly_vm::Nudge::Rating => {}
        }
    }

    /// Whether the Discord card is in view.
    pub fn discord_card_open(&self) -> bool {
        self.discord.is_open()
    }

    /// Shows `text` in the strip at the bottom of the content for four seconds.
    pub fn show_hint(&mut self, text: &str, now: f64) {
        self.hint.show(text, now);
    }

    /// Whether the version dialog is open.
    pub fn version_dialog_open(&self) -> bool {
        self.version_dialog.0.is_open()
    }

    /// Opens the version dialog for a title (tests; the app opens it when a start comes back with several versions).
    pub fn ask_versions(&mut self, ask: crate::live_play::VersionAsk) {
        let labels = ask.versions.iter().map(|v| v.label.clone()).collect();
        self.version_dialog.0.set(Some(labels));
        self.version_dialog.1 = Some(ask);
    }

    /// Closes the version dialog; with a pick the title starts on that version.
    fn pick_version(&mut self, pick: Option<usize>) {
        self.version_dialog.0.set(None);
        let Some(ask) = self.version_dialog.1.take() else {
            return;
        };
        let (Some(i), Some(w)) = (pick, self.live.clone()) else {
            return;
        };
        if let Some(v) = ask.versions.get(i) {
            let req = crate::live_play::PlayRequest {
                item_id: ask.item_id.clone(),
                since: ask.since,
                source_id: Some(v.id.clone()),
            };
            self.starting = Some(w.core.prepare_play(&w.account, req));
        }
    }

    /// Shows `text` in the strip for what went wrong with the shared session (above the tile strip).
    pub fn show_shared_error(&mut self, text: &str, now: f64) {
        self.hint.show_in(crate::desk::Strip::Shared, text, now);
    }

    /// The text of the shared-session strip, when one is in view.
    pub fn shared_error_text(&self) -> Option<&str> {
        self.hint.text_in(crate::desk::Strip::Shared)
    }

    /// The text of the strip at the bottom of the content, when one is in view.
    pub fn hint_text(&self) -> Option<&str> {
        self.hint.text()
    }

    fn frame_inner(&mut self, now: f64) -> (DrawList, bool) {
        // The launch curtain only plays over the pages. A title given at launch (a video file, a link) opens the player
        // under it, and the player draws no curtain: a curtain left up would swallow every click of the player.
        if self.player.is_some() {
            self.curtain = None;
        }
        if let Some(p) = &self.genres
            && let Ok(mut names) = p.0.try_recv()
        {
            // The chips row shows the first dozen genres (it scrolls on the Mac; here the row has the width of the page).
            names.truncate(8);
            self.home.set_chips(names);
            self.genres = None;
        }
        let (mut list, mut more) = self.frame_pages(now);
        more |= self.frame_stage(&mut list, now);
        if self.player.is_none() {
            let (panel, wants) = self.together_ui.frame(now);
            list.append_shifted(&panel, 0.0);
            more |= wants;
        }
        if self.env.idiom == swiftly_ui::Idiom::Desktop && self.player.is_none() {
            let mut wants = false;
            if !self.first_run() {
                let (arrows, w) = self.arrows.frame(self.can_step(), now);
                list.append_shifted(&arrows, 0.0);
                wants = w;
            }
            let (bar, bar_wants) = self.controls.frame(now);
            list.append_shifted(&bar, 0.0);
            self.hint.set_env(self.page_env());
            let (hint, hint_wants) = self.hint.frame(now);
            list.append_shifted(&hint, self.side());
            wants |= hint_wants;
            self.discord_due(now);
            self.discord.set_env(self.page_env());
            let (card, card_wants) = self.discord.frame(now);
            list.append_shifted(&card, self.side());
            wants |= card_wants || self.nudge.is_some();
            self.version_dialog.0.set_env(self.env);
            let (dialog, dialog_wants) = self.version_dialog.0.frame(now);
            list.append_shifted(&dialog, 0.0);
            wants |= dialog_wants;
            let mut curtain_wants = false;
            if let Some(c) = &mut self.curtain {
                match c.frame(now) {
                    Some(cur) => {
                        list.append_shifted(&cur, 0.0);
                        curtain_wants = true;
                    }
                    None => self.curtain = None,
                }
            }
            return (list, more || wants || bar_wants || curtain_wants);
        }
        (list, more)
    }

    /// The tab in front, with the content cross fade of an area change (the sidebar stays). The old page stays at full
    /// strength until the new one, ground included, has faded in over it with the Mac's `easeOut(0.22)`: the area never
    /// shows the bare ground between two pages (the Mac's out-then-in left a blank gap of a hundred milliseconds).
    fn base_frame(&mut self, now: f64) -> (DrawList, bool) {
        let (list, wants) = front!(self, s => s.frame(now));
        let off = self.side();
        let Some((from, t0)) = self.fade else {
            self.gone_page = None;
            return (list, wants);
        };
        let e = (now - t0) / 1000.0;
        // The fade-in curve carries the Mac's 0.12 s delay (the old page's time to leave): start it at once.
        let (out_curve, in_curve) = (Id::SectionOut.curve(), Id::SectionIn.curve());
        let e_in = e + out_curve.settle_seconds();
        if off == 0.0 || e_in >= in_curve.settle_seconds() {
            self.fade = None;
            self.gone_page = None;
            return (list, wants);
        }
        let (w, h) = (self.env.size.w, self.env.size.h);
        let mut out = list.clone();
        out.clip_x(0.0, off);
        // The window ground: the Mac fades over its window background, so the content area never shows the clear colour.
        let mut ground = list.clone();
        ground.clear();
        ground.fill(
            swiftly_render::Rect::new(off, 0.0, w - off, h),
            crate::desk::ground(),
            0.0,
        );
        out.append_shifted(&ground, 0.0);
        // The old page under the new one.
        if self.fade_in_only {
            // Leaving Downloads: the page is no longer the one in front, but it is kept for this fade.
            // It leaves within three frames (the Mac's page goes first), so its text does not show through the new page's
            // ground while that fades in.
            if let Some(t) = self.gone_page.as_mut() {
                let (mut over, _) = on_top!(t, s => s.frame(now));
                over.fade((1.0 - e / 0.05).clamp(0.0, 1.0) as f32);
                out.append_shifted(&over, off);
            }
        } else {
            let keep = self.tab;
            self.tab = from;
            let (mut old, _) = front!(self, s => s.frame(now));
            self.tab = keep;
            old.clip_x(off, w);
            out.append_shifted(&old, 0.0);
        }
        // The new page: its ground and content fade in together over the old one.
        let mut content = list;
        content.clip_x(off, w);
        ground.append_shifted(&content, 0.0);
        ground.fade(in_curve.progress(e_in) as f32);
        out.append_shifted(&ground, 0.0);
        (out, true)
    }

    fn frame_pages(&mut self, now: f64) -> (DrawList, bool) {
        self.clock = now;
        self.poll_start(now);
        if let Some(p) = &mut self.player {
            let mut r = p.frame(now);
            // The arriving card lies over the player until its first picture is up, then it zooms into it.
            if self.together_ui.receiving() {
                if p.video_frames() > 0 {
                    self.together_ui.receive_picture();
                }
                let (card, wants) = self.together_ui.frame(now);
                r.0.append_shifted(&card, 0.0);
                r.1 |= wants;
            }
            self.after_player();
            return r;
        }
        self.sync_mine(now);
        self.sync_home_settings(now);
        self.refresh_home_if_stale();
        self.refresh_hover(now);
        // The sections behind the one in front read their libraries too, so none opens on skeleton tiles.
        for (i, screen) in [
            (1, &mut self.movies),
            (2, &mut self.series),
            (4, &mut self.watch),
        ] {
            if i != self.tab {
                screen.pump(now);
            }
        }
        let off = self.side();
        let page_w = self.page_env().size.w;
        // The add sheet over a title page is done: the title page is in front again.
        if self.under_sheet.is_some()
            && !matches!(&self.top, Some(Top::Downloads(d)) if d.load_open())
        {
            self.top = self.under_sheet.take();
            if let Some(page) = self.top.as_mut() {
                Self::close_page_menu(page);
            }
        }
        if let Some(t) = &mut self.top {
            let (over, more_top) = on_top!(t, s => (s.frame(now), s.covers()));
            let ((mut over, mut wants_top), mut covers) = (over, more_top);
            if let Some(u) = self.under_sheet.as_mut() {
                let ((mut page, w2), c2) = on_top!(u, s => (s.frame(now), s.covers()));
                page.append_shifted(&over, 0.0);
                (over, wants_top, covers) = (page, wants_top || w2, c2);
            }
            let mut below = match t {
                Top::Detail(s) => s.below(),
                Top::Series(s) => s.below(),
                Top::Page(s) => s.below(),
                _ => None,
            };
            if let Some(nav) = &mut self.slide {
                let closed = !on_top!(t, s => s.is_open());
                if closed && !self.sliding_out {
                    self.sliding_out = true;
                    nav.pop(now);
                }
                nav.update(now);
                let layers = Layers::at(nav.position(), 2);
                let style = NavStyle::for_idiom(self.env.idiom);
                let w = page_w;
                let place = |i| swiftly_ui::nav::place(style, &layers, i, w);
                over.shift_all(place(1).x);
                let b = place(0);
                // At rest the page below sits where it was (hidden under the page); only a moving push shifts it.
                below = nav.is_animating().then_some((b.x, b.dim));
                covers = covers && !nav.is_animating() && !closed;
                wants_top = wants_top || nav.is_animating();
            }

            if let (Some(t0), Some(Top::Downloads(_))) = (self.page_fade, &self.top) {
                // Downloads appears like a section change: its content fades in over the page it replaces.
                let e = (now - t0) / 1000.0;
                let curve = Id::SectionIn.curve();
                if e < curve.settle_seconds() {
                    over.fade(curve.progress(e) as f32);
                    wants_top = true;
                    covers = false;
                } else {
                    self.page_fade = None;
                }
            }
            // The page below the one in front stays drawn while it slides in or out, at every depth (a title page
            // under a person page, the profile page under the account pages), not the base page of the section. It
            // is drawn before `after_top`: the frame in which the page in front is gone still shows it.
            let under_page = if below.is_some() || !covers {
                self.under
                    .last_mut()
                    .map(|u| on_top!(u, s => s.frame(now)).0)
            } else {
                None
            };
            self.after_top();
            if covers && off == 0.0 {
                return (over, wants_top);
            }
            // The tab below a page at rest shows only its sidebar: its pictures must not push the page's own out.
            let hidden = covers && under_page.is_none() && off > 0.0;
            if let Some(hub) = &self.hub {
                hub.set_hidden(hidden.then(|| front!(self, s => s.hub_owner())));
            }
            let (mut list, wants) = front!(self, s => s.frame(now));
            if let Some(page) = &under_page {
                list.append_shifted(page, off);
            }
            if hidden {
                // The page in front is at rest: it alone fills the content column, over its own opaque ground (the Mac's
                // window background), so a part it has not drawn yet (a backdrop still loading, a gradient that fades
                // out) never shows the rows of the tab below. Only the sidebar of the tab stays.
                let (w, h) = (self.env.size.w, self.env.size.h);
                list.clip_x(0.0, off);
                list.fill(
                    swiftly_render::Rect::new(off, 0.0, w - off, h),
                    crate::desk::ground(),
                    0.0,
                );
            }
            // Push parallax: the page below moves back and dims while the title page slides over it. On the desktop only
            // the content column moves and dims; the sidebar stays where it is and stays clickable.
            self.last_below_dx = below.map_or(0.0, |b| b.0);
            if let Some((dx, dim)) = below {
                if off > 0.0 {
                    let mut side = list.clone();
                    side.clip_x(0.0, off);
                    list.shift_all(dx);
                    list.clip_x(off, self.env.size.w);
                    let (w, h) = (self.env.size.w, self.env.size.h);
                    list.fill(
                        swiftly_render::Rect::new(off, 0.0, w - off, h),
                        swiftly_render::Color::new(0.063, 0.063, 0.063, dim),
                        0.0,
                    );
                    list.append_shifted(&side, 0.0);
                } else {
                    list.shift_all(dx);
                    list.veil(dim);
                }
            }
            list.append_shifted(&over, off);
            return (list, wants || wants_top);
        }
        if let Some(hub) = &self.hub {
            hub.set_hidden(None);
        }
        let (list, wants) = self.base_frame(now);
        self.after_base(now);
        (list, wants)
    }

    /// What a screen reader gets for the screen in front (player, pushed page or tab), with its window-level title.
    pub fn a11y_nodes(&self) -> (&'static str, Vec<swiftly_ui::a11y::A11yNode>) {
        // The together panel is modal over the whole window (it takes every click and key): it alone is reachable.
        if self.player.is_none() && self.together_ui.open() {
            return ("Gemeinsam", self.together_ui.a11y_nodes());
        }
        // The version choice is modal over the whole window (clicks beside it cancel): it alone is reachable.
        if self.version_dialog.0.is_open() {
            return (
                crate::desk::VERSION_TITLE,
                self.version_dialog.0.a11y_nodes(),
            );
        }
        let (title, mut nodes) = self.a11y_pages();
        // The player covers the whole window: its nodes are already in window points, with no sidebar beside them.
        if self.top_shown() && self.player.is_none() {
            shift_x(&mut nodes, self.side());
            // The sidebar stays beside a pushed page and is still the tabs'.
            if self.side() > 0.0 {
                let mut side = Vec::new();
                collect_side(&self.a11y_tab().1, self.side(), &mut side);
                nodes.extend(side);
            }
        }
        if self.env.idiom == swiftly_ui::Idiom::Desktop && self.player.is_none() {
            nodes.extend(self.controls.a11y_nodes());
            if !self.first_run() {
                nodes.extend(self.arrows.a11y_nodes());
            }
        }
        (title, nodes)
    }

    /// The page under the pointer changed (a page opened, closed or left, a section changed) while the pointer rests:
    /// hover follows what is under it now, not what was under it before (a tile kept its hover for seconds).
    fn refresh_hover(&mut self, now: f64) {
        let kind = match &self.top {
            None => 0,
            Some(Top::Detail(_)) => 1,
            Some(Top::Series(_)) => 2,
            Some(Top::Page(_)) => 3,
            Some(Top::Settings(_)) => 4,
            Some(Top::Downloads(_)) => 5,
            Some(Top::Login(_)) => 6,
        };
        let sig = (self.tab, kind, self.top_shown(), self.under_sheet.is_some());
        if sig == self.hover_page {
            return;
        }
        self.hover_page = sig;
        if let Some((x, y)) = self.pointer_at {
            self.pointer_move(x, y, now);
        }
    }

    /// Whether the pushed page is the one the window shows. A title page that was closed is only on its way out (it
    /// slides away under the page behind it): the reading list and the window title are already the page behind's.
    fn top_shown(&self) -> bool {
        match &self.top {
            None => false,
            Some(Top::Detail(_) | Top::Series(_) | Top::Page(_)) => self.top_open(),
            Some(_) => true,
        }
    }

    fn a11y_pages(&self) -> (&'static str, Vec<swiftly_ui::a11y::A11yNode>) {
        if let Some(p) = &self.player {
            return ("Player", p.a11y_nodes());
        }
        if let Some(t) = self.top.as_ref().filter(|_| self.top_shown()) {
            let (title, nodes) = match t {
                Top::Detail(s) => ("Film", s.a11y_nodes()),
                Top::Series(s) => ("Serie", s.a11y_nodes()),
                Top::Settings(s) => ("Einstellungen", s.a11y_nodes()),
                Top::Downloads(s) => ("Downloads", s.a11y_nodes()),
                Top::Login(s) => ("Anmelden", s.a11y_nodes()),
                Top::Page(s) => (s.window_title(), s.a11y_nodes()),
            };
            // The add sheet floats over a title page: the window is still that page, only its input is the sheet's.
            let title = match &self.under_sheet {
                Some(Top::Detail(_)) => "Film",
                Some(Top::Series(_)) => "Serie",
                Some(Top::Page(p)) => p.window_title(),
                _ => title,
            };
            return (title, nodes);
        }
        self.a11y_tab()
    }

    /// The reading list of the tab in front (its sidebar included).
    fn a11y_tab(&self) -> (&'static str, Vec<swiftly_ui::a11y::A11yNode>) {
        match self.tab {
            0 => ("Start", self.home.a11y_nodes()),
            1 => ("Filme", self.movies.a11y_nodes()),
            2 => ("Serien", self.series.a11y_nodes()),
            4 => ("Merkliste", self.watch.a11y_nodes()),
            _ => ("Suche", self.search.a11y_nodes()),
        }
    }

    /// Whether a frame is wanted without a new event.
    pub fn wants_frame(&self) -> bool {
        if self.stage.is_some()
            || self.live.is_some() && (self.clock < self.busy_until || self.starting.is_some())
            || matches!(&self.top, Some(Top::Login(l)) if l.pending())
        {
            return true;
        }
        if (self.player.is_none() || self.together_ui.receiving()) && self.together_ui.wants_frame()
        {
            return true;
        }
        if let Some(p) = &self.player {
            return p.wants_frame();
        }
        if [(1, &self.movies), (2, &self.series), (4, &self.watch)]
            .iter()
            .any(|(i, s)| *i != self.tab && s.awaiting_libraries())
        {
            return true;
        }
        let top = self
            .top
            .as_ref()
            .is_some_and(|t| on_top!(t, s => s.wants_frame()))
            || self.slide.as_ref().is_some_and(Nav::is_animating);
        top || match self.tab {
            0 => self.home.wants_frame(),
            1 => self.movies.wants_frame(),
            2 => self.series.wants_frame(),
            4 => self.watch.wants_frame(),
            _ => self.search.wants_frame(),
        }
    }
}

/// Moves the bounds of reading-list nodes `dx` right (a pushed page lives in the content column).
fn shift_x(nodes: &mut [swiftly_ui::a11y::A11yNode], dx: f32) {
    for n in nodes {
        if let Some(b) = n.bounds.as_mut() {
            b[0] += dx;
        }
        shift_x(&mut n.children, dx);
    }
}

/// The nodes that lie wholly in the sidebar (x within `width`), without their children.
fn collect_side(
    nodes: &[swiftly_ui::a11y::A11yNode],
    width: f32,
    out: &mut Vec<swiftly_ui::a11y::A11yNode>,
) {
    for n in nodes {
        if n.bounds.is_some_and(|b| b[0] + b[2] <= width + 1.0) {
            let mut c = n.clone();
            c.children.clear();
            out.push(c);
        } else {
            collect_side(&n.children, width, out);
        }
    }
}

/// Two sample versions for the version dialog (the live script's `ask-versions` step and the tests).
pub fn sample_versions() -> crate::live_play::VersionAsk {
    let v = |id: &str, label: &str| swiftly_vm::VersionOption {
        id: id.to_owned(),
        name: label.to_owned(),
        label: label.to_owned(),
    };
    crate::live_play::VersionAsk {
        item_id: "sample".into(),
        since: 0.0,
        versions: vec![
            v("a", "Kinofassung \u{b7} 2160p \u{b7} HEVC \u{b7} 18,6 GB"),
            v("b", "Extended \u{b7} 1080p \u{b7} H.264 \u{b7} 9,2 GB"),
        ],
    }
}

#[cfg(test)]
mod player_resize_tests {
    use super::*;
    use swiftly_layout::Size;
    use swiftly_ui::Idiom;

    /// A play link while a title plays closes the old one through the Close path: the engine stops and the stop report goes.
    #[test]
    fn closing_the_open_player_for_a_new_title_stops_the_old_one() {
        let env = Env::new(Size::new(1280.0, 800.0), 1.5, Idiom::Desktop);
        let mut s = Suite::new(env, Cx::deterministic());
        assert!(
            s.close_open_player(0.0).is_none(),
            "nothing open, nothing to close"
        );
        s.player = Some(Box::new(PlayerScreen::new(
            env,
            s.cx.clone(),
            PlayerScenario::Playing,
            0.0,
        )));
        let old = s.close_open_player(500.0).expect("the open player");
        assert!(s.player.is_none());
        assert!(old.is_closed(), "closed through the Close intent");
        assert!(
            old.engine_calls().iter().any(|c| c.starts_with("stop")),
            "{:?}",
            old.engine_calls()
        );
    }

    /// Going fullscreen changes the window size: the open player lays out at the new size (it stayed in the old, small one,
    /// squeezed into the top left corner).
    #[test]
    fn an_open_player_follows_the_window_size() {
        let small = Env::new(Size::new(1280.0, 800.0), 1.5, Idiom::Desktop);
        let mut s = Suite::new(small, Cx::deterministic());
        s.player = Some(Box::new(PlayerScreen::new(
            small,
            s.cx.clone(),
            PlayerScenario::Playing,
            0.0,
        )));
        let width = |s: &mut Suite, now: f64| s.player().unwrap().frame(now).0.width();
        assert_eq!(width(&mut s, 0.0), 1280.0);
        let full = Env::new(Size::new(2560.0, 1440.0), 1.5, Idiom::Desktop);
        s.set_env(full);
        assert_eq!(width(&mut s, 16.0), 2560.0);
    }
}
