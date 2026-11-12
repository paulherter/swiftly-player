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

/// The account list over the stored accounts of the real app.
/// The server kind as the account list shows it.
fn kind_label(kind: swiftly_jellyfin::ServerKind) -> &'static str {
    match kind {
        swiftly_jellyfin::ServerKind::Plex => "Plex",
        swiftly_jellyfin::ServerKind::Emby => "Emby",
        _ => "Jellyfin",
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
    pushes: usize,
    /// The list changes Start has already reloaded for (`desk::list_changes`).
    home_seen: u64,
    /// The slide of a pushed form page (Settings, Downloads, sign-in): position 0 = base page, 1 = form page.
    slide: Option<Nav<u8>>,
    sliding_out: bool,
    /// The real app (`None`: the demo).
    live: Option<Rc<crate::live::Wiring>>,
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
    /// The two history arrows of the 52 pt strip.
    arrows: crate::desk::NavArrows,
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
    /// The genre names being fetched for the chips row (live app).
    genres: Option<crate::login_screen::Pending<Vec<String>>>,
    /// A press that began in the sidebar while a page is pushed: it belongs to the tabs.
    side_press: bool,
    /// The area change in progress: the tab left and when (the 0.12 s out, 0.22 s in cross fade of the content).
    fade: Option<(usize, f64)>,
    /// The launch curtain, when it is on.
    curtain: Option<crate::desk::Curtain>,
    /// The tabs visited before this one, oldest first, and the ones left by going back (the Mac's window history).
    history: Vec<usize>,
    future: Vec<usize>,
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
            controls: crate::desk::WindowControls::new(env, cx.clone()),
            win_action: None,
            win_press: None,
            quit: false,
            parked: Default::default(),
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
            pushes: 0,
            home_seen: crate::desk::list_changes(),
            slide: None,
            sliding_out: false,
            live: None,
            core: None,
            busy_until: 0.0,
            starting: None,
            season_read: None,
            film_read: None,
            last_play: None,
            history: Vec::new(),
            future: Vec::new(),
            stepping: false,
            stage: None,
            hub: None,
            nav: crate::nav_machine::NavState::default(),
            panel_closing: false,
            after_panel: None,
            page_fade: None,
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
        // The sidebar's account card: the signed-in account, nothing while signing in.
        crate::desk::set_card(match core.accounts_list().into_iter().find(|e| e.active) {
            Some(e) => crate::desk::Card::account(&e.name, &e.server),
            None => crate::desk::Card::Hidden,
        });
        let Some(account) = core.account() else {
            crate::live::install(None);
            self.live = None;
            let backend = core.sign_in_backend();
            self.top = Some(Top::Login(Box::new(LoginScreen::live(
                self.env,
                self.cx.clone(),
                backend,
            ))));
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
        let w = Rc::new(crate::live::Wiring {
            core,
            account,
            hub: Rc::clone(&hub),
            next_kind: Default::default(),
            last_title: Default::default(),
        });
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
        self.home.vm().send(swiftly_vm::HomeIntent::Load);
        self.movies.vm().send(swiftly_vm::LibraryIntent::Load);
        self.series.vm().send(swiftly_vm::LibraryIntent::Load);
        self.watch.start_watchlist();
        self.genres = Some(crate::live::fetch_genres(&w));
        self.live = Some(w);
        self.seen = [0; 5];
        self.tab = 0;
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
        self.controls.set_env(env);
        if let Some(c) = &mut self.curtain {
            c.set_env(env);
        }
        let pe = self.page_env();
        if let Some(t) = &mut self.top {
            on_top!(t, s => s.set_env(pe));
        }
        for t in self.parked.iter_mut().flatten() {
            on_top!(t, s => s.set_env(pe));
        }
    }

    /// The tile with `id` on the tab in front.
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
            _ => {}
        }
        if self.tab == 0 && self.top.is_none() {
            // The Continue rail resumes at once, like the Mac: no detail page first.
            if let Some(id) = self.home.take_resumed().pop() {
                self.resume(&id, now);
                return;
            }
        }
        if self.tab == 0 && !self.home.take_libraries().is_empty() && self.top.is_none() {
            self.open_page(PageKind::Collection, now);
            return;
        }
        if self.tab == 0 && !self.home.take_genres().is_empty() && self.top.is_none() {
            self.open_page(PageKind::Genre, now);
            return;
        }
        let asked = front!(self, s => s.tab());
        if asked != self.tab {
            let old = self.tab;
            if !self.stepping {
                self.history.push(old);
                self.future.clear();
            }
            if self.side() > 0.0 && !self.reduce_fade() {
                self.fade = Some((old, self.clock));
            }
            front!(self, s => s.set_tab(old));
            self.tab = asked.min(4);
            self.seen[self.tab] = front!(self, s => s.opened().len());
            self.start_in_front();
            return;
        }
        let opened: Vec<String> = front!(self, s => s.opened().to_vec());
        if opened.len() > self.seen[self.tab] {
            self.seen[self.tab] = opened.len();
            let Some(id) = opened.last() else { return };
            let tile = self.tile_of(id);
            let series = tile.as_ref().is_some_and(|t| {
                t.facts
                    .kind
                    .as_deref()
                    .is_some_and(|k| k.eq_ignore_ascii_case("series"))
            });
            self.push(series, tile, now);
        }
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

    fn push(&mut self, series: bool, tile: Option<swiftly_vm::Tile>, now: f64) {
        if let (Some(w), Some(t)) = (&self.live, &tile) {
            *w.next_kind.borrow_mut() = t.facts.kind.clone().unwrap_or_default();
            *w.last_title.borrow_mut() = (t.id.clone(), t.title.clone());
        }
        self.push_page(series, tile.map(|t| (t.id, t.title)), now);
    }

    /// Pushes the title page (the wiring already knows the kind and name of the title).
    fn push_page(&mut self, series: bool, tile: Option<(String, String)>, now: f64) {
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

    /// A download button on Detail or Series asks for the add popover or the season sheet. The Downloads page takes
    /// it; when it is not in front it is pushed first (a title page in front is replaced by it, as a form page
    /// replaces another one). The series page's "Laden" builds the season request from live data (`pump_season_read`, `live_downloads::SeasonRead`),
    /// which answers the season reads through [`Suite::season_pending`], [`Suite::season_loaded`] and [`Suite::season_finished`].
    pub fn request_load(&mut self, request: crate::load_sheets::LoadRequest, now: f64) {
        self.busy_until = self.busy_until.max(now + 2500.0);
        if !matches!(self.top, Some(Top::Downloads(_))) {
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
        let screen = crate::switch_stage::StageScreen::with_initial(
            self.env,
            self.cx.clone(),
            stage,
            initial,
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
            (Some(Top::Downloads(_)), _) => Page::Downloads,
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
        }
        screen
    }

    /// A sidebar tap while a panel is open: the panel slides out to the right and the page asked for (or the one behind)
    /// travels in from the left. The page change happens now; the panel stays on top until it has left.
    fn close_panel_for(&mut self, page: Option<crate::nav_machine::Page>, now: f64) {
        use crate::nav_machine::{Event, Page};
        let event = page.map_or(Event::ClosePanel, Event::Select);
        self.resync_nav();
        let motion = self.nav_event(event);
        debug_assert!(
            motion == crate::nav_machine::Motion::PanelOut
                || motion == crate::nav_machine::Motion::None
        );
        self.panel_closing = true;
        match page {
            Some(Page::Tab(i)) if usize::from(i) != self.tab => {
                let old = self.tab;
                self.history.push(old);
                self.future.clear();
                front!(self, s => s.set_tab(old));
                front!(self, s => s.set_tab(usize::from(i)));
                self.tab = usize::from(i).min(4);
                self.seen[self.tab] = front!(self, s => s.opened().len());
                self.fade = None;
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
                Dest::AddServer => Some(Top::Login(Box::new(match &live {
                    Some(core) => LoginScreen::live(env, cx, core.sign_in_backend()).into_add(),
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
                    Some(core) => LoginScreen::live(env, cx, core.sign_in_backend()).into_add(),
                    None => LoginScreen::new(env, cx, Start::AddKind),
                }))
            }),
            _ => None,
        };
        if let Some(t) = next {
            self.show(t, 0.0);
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
            if gone {
                self.slide = None;
                self.top = None;
                self.panel_closing = false;
                if self.after_panel.take() == Some(crate::nav_machine::Page::Downloads) {
                    let now = self.clock;
                    let screen = self.downloads_page();
                    self.show(Top::Downloads(Box::new(screen)), now);
                } else {
                    // The page behind brings back its own pushed stack.
                    self.top = self.parked[self.tab].take();
                }
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

    /// The player in front (tests).
    pub fn player(&mut self) -> Option<&mut PlayerScreen> {
        self.player.as_deref_mut()
    }

    /// Play on a Detail or Series page opens the player with the fake engine.
    fn check_play(&mut self, now: f64) {
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

    fn after_player(&mut self) {
        if let Some(p) = self.player.as_mut()
            && p.is_plan_failed()
            && p.retry_asked()
            && let (Some(req), Some(w)) = (self.last_play.clone(), &self.live)
        {
            self.player = None;
            self.starting = Some(w.core.prepare_play(&w.account, req));
        }
        if self.player.as_ref().is_some_and(|p| p.is_closed()) {
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
            self.top = self.parked[self.tab].take();
            self.page_fade = None;
        }
    }

    /// A keyboard shortcut of the Mac app: switches to a tab (0 Start, 1 Filme, 2 Serien, 3 Suche). Only from a base page
    /// (no title page or player in front). Returns whether it switched.
    pub fn goto_tab(&mut self, n: usize, now: f64) -> bool {
        if n > 4 || self.player.is_some() {
            return false;
        }
        let from_downloads = matches!(self.top, Some(Top::Downloads(_)));
        self.leave_downloads();
        if n == self.tab {
            if from_downloads && self.reduce_fade() {
                return true;
            }
            if from_downloads {
                self.fade = Some((self.tab, self.clock));
            }
            return from_downloads;
        }
        // Each area keeps its own pushed page: park this one, bring back the one of the area we go to.
        self.parked[self.tab] = self.top.take();
        self.slide = None;
        front!(self, s => s.set_tab(n));
        self.after_base(now);
        if self.top.is_none() {
            self.top = self.parked[self.tab].take();
        }
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
                && self.player.is_none()
            {
                self.win_action = Some(crate::desk::WinAction::DragMove);
                return;
            }
        }
        let off = self.side();
        self.busy_until = self.busy_until.max(now + 2500.0);
        if let Some(p) = &mut self.player {
            p.touch_down(x, y, now);
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
        if self.top.is_some() && x < off {
            // The sidebar stays clickable beside a pushed page (the Mac gives it zIndex 1).
            self.side_press = true;
            front!(self, s => s.touch_down(x, y, now));
            return;
        }
        if let Some(Top::Login(l)) = &mut self.top {
            l.pointer_press(x - off, y, false);
        }
        match &mut self.top {
            Some(t) => on_top!(t, s => s.touch_down(x - off, y, now)),
            None => {
                front!(self, s => s.touch_down(x, y, now));
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
                None => None,
            };
            if let Some(d) = dest {
                self.close_panel_for(d, now);
                return;
            }
        }
        match go {
            Some(crate::desk::Go::Tab(i)) if i == cur => {
                while self.top.is_some() {
                    if !self.back(now) {
                        break;
                    }
                    self.top = None;
                    self.slide = None;
                }
            }
            Some(crate::desk::Go::Tab(i)) => {
                self.goto_tab(i, now);
            }
            Some(crate::desk::Go::Watchlist) => {
                self.goto_tab(4, now);
            }
            Some(crate::desk::Go::Downloads) => {
                self.run_command("cmd.downloads", now);
            }
            None if profile => {
                self.parked[cur] = self.top.take();
                self.slide = None;
                self.open_settings(now);
            }
            None => {}
        }
    }

    /// The finger moves.
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        let off = self.side();
        self.busy_until = self.busy_until.max(now + 2500.0);
        if let Some(p) = &mut self.player {
            p.touch_move(x, y, now);
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
        out
    }

    /// Back (Esc, mouse back button): closes a sheet or the keyboard first, then pops the title page.
    pub fn back(&mut self, now: f64) -> bool {
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

    /// A step through the window history: back (the tab visited before) or forward (the one left by going back).
    fn step(&mut self, back: bool, now: f64) -> bool {
        let target = if back {
            self.history.pop()
        } else {
            self.future.pop()
        };
        let Some(n) = target else { return false };
        if back {
            self.future.push(self.tab);
        } else {
            self.history.push(self.tab);
        }
        self.stepping = true;
        self.leave_downloads();
        self.parked[self.tab] = self.top.take();
        self.slide = None;
        front!(self, s => s.set_tab(n));
        self.after_base(now);
        if self.top.is_none() {
            self.top = self.parked[self.tab].take();
        }
        self.stepping = false;
        true
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
            "cmd.search" => self.goto_tab(3, now),
            "cmd.watchlist" => self.goto_tab(4, now),
            "cmd.downloads" => {
                if matches!(self.top, Some(Top::Downloads(_))) || self.player.is_some() {
                    return false;
                }
                // Downloads is a page of the sidebar: the pushed titles of this area wait behind it.
                if !matches!(self.top, Some(Top::Settings(_) | Top::Login(_))) {
                    self.parked[self.tab] = self.top.take();
                }
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
        (
            self.top.is_some() || !self.history.is_empty(),
            !self.future.is_empty(),
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
        self.player.is_none()
            && matches!(
                &self.top,
                None | Some(Top::Detail(_) | Top::Series(_) | Top::Page(_))
            )
    }

    /// Pushes a page of `kind` (a person, a playlist, a genre, a collection) over the tabs.
    pub fn open_page(&mut self, kind: PageKind, now: f64) {
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

    /// Which pushed page is in front: "detail", "series", "page" (tests).
    pub fn top_kind(&self) -> Option<&'static str> {
        match &self.top {
            Some(Top::Detail(_)) => Some("detail"),
            Some(Top::Series(_)) => Some("series"),
            Some(Top::Page(_)) => Some("page"),
            _ => None,
        }
    }

    /// The pointer moved with no button held: hover, tooltips, cursor and the rail arrows of the page in front.
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        let off = self.side();
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
        if self.player.is_some() {
            return false;
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
        if self.top.is_some() || !self.wheel_direct() {
            return false;
        }
        front!(self, s => s.scroll_key(key, now))
    }

    /// Typing with nothing focused opens the search with that text (the Mac's type-to-search).
    pub fn type_to_search(&mut self, text: &str, now: f64) -> bool {
        if !self.wheel_direct() || self.wants_text() {
            return false;
        }
        if self.tab != 3 {
            self.goto_tab(3, now);
        }
        self.search.type_text(text);
        true
    }

    /// Whether typed text goes into the search field.
    pub fn wants_text(&self) -> bool {
        if self.player.is_some() {
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
        let (list, more) = self.frame_inner(now);
        // The real app waits for the network: view models and pictures arrive between input events, so it keeps asking.
        let waiting = (self.live.is_some()
            && (now < self.busy_until
                || self.starting.is_some()
                || self.season_read.is_some()
                || self.film_read.is_some()))
            || matches!(&self.top, Some(Top::Login(l)) if l.pending());
        (list, more || waiting)
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
                self.reset_to_start(now);
                self.resume(&id, now);
            }
            Action::Show(found) => {
                self.reset_to_start(now);
                if let Some(w) = &self.live {
                    *w.next_kind.borrow_mut() = found.kind.clone();
                    *w.last_title.borrow_mut() = (found.id.clone(), found.title.clone());
                }
                self.push_page(found.series_page(), Some((found.id, found.title)), now);
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

    fn poll_start(&mut self, now: f64) {
        self.poll_link(now);
        self.pump_season_read(now);
        self.pump_film_read(now);
        if self.starting.is_none()
            && let (Some(Top::Downloads(d)), Some(w)) = (&mut self.top, &self.live)
            && let Some(id) = d.take_opened().pop()
        {
            self.starting = Some(crate::live_offline::pending_offline(
                &w.core, &w.account, &id,
            ));
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
                } else if let Some(first) = ask.versions.first() {
                    let req = crate::live_play::PlayRequest {
                        item_id: ask.item_id,
                        since: ask.since,
                        source_id: Some(first.id.clone()),
                    };
                    self.starting = Some(w.core.prepare_play(&w.account, req));
                }
                return;
            }
            other => other,
        };
        match done.and_then(|prep| w.core.open_player(self.env, self.cx.clone(), now, prep)) {
            Ok(mut screen) => {
                // The next episode, a quality choice and a subtitle on a transcode all go through this host.
                screen.set_planner(w.core.planner(&w.account));
                self.player = Some(Box::new(screen));
            }
            Err(e) => {
                eprintln!("play: {e}");
                let message = if e.starts_with("Der Server") {
                    e
                } else {
                    "Der Titel lässt sich gerade nicht abspielen.".to_owned()
                };
                self.player = Some(Box::new(PlayerScreen::plan_failed(
                    self.env,
                    self.cx.clone(),
                    now,
                    &message,
                    (String::new(), String::new()),
                )));
            }
        }
    }

    fn frame_inner(&mut self, now: f64) -> (DrawList, bool) {
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
        if self.env.idiom == swiftly_ui::Idiom::Desktop && self.player.is_none() {
            let mut wants = false;
            if !self.first_run() {
                let (arrows, w) = self.arrows.frame(self.can_step(), now);
                list.append_shifted(&arrows, 0.0);
                wants = w;
            }
            let (bar, bar_wants) = self.controls.frame(now);
            list.append_shifted(&bar, 0.0);
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

    /// The tab in front, with the content cross fade of an area change (0.12 s out, 0.22 s in, the sidebar stays).
    fn base_frame(&mut self, now: f64) -> (DrawList, bool) {
        let (list, wants) = front!(self, s => s.frame(now));
        let off = self.side();
        let Some((from, t0)) = self.fade else {
            return (list, wants);
        };
        let e = (now - t0) / 1000.0;
        // The Mac's `sectionSwitch`: the old tab leaves with `easeIn(0.12)`, the new one arrives with `easeOut(0.22)` after 0.12 s.
        let (out_curve, in_curve) = (Id::SectionOut.curve(), Id::SectionIn.curve());
        if off == 0.0 || e >= in_curve.settle_seconds() {
            self.fade = None;
            return (list, wants);
        }
        let w = self.env.size.w;
        let mut out = list.clone();
        out.clip_x(0.0, off);
        let (mut content, alpha) = if e < out_curve.settle_seconds() {
            let (old, _) = {
                let keep = self.tab;
                self.tab = from;
                let r = front!(self, s => s.frame(now));
                self.tab = keep;
                r
            };
            (old, out_curve.displacement(e))
        } else {
            (list, in_curve.progress(e))
        };
        content.clip_x(off, w);
        content.fade(alpha as f32);
        out.append_shifted(&content, 0.0);
        (out, true)
    }

    fn frame_pages(&mut self, now: f64) -> (DrawList, bool) {
        self.clock = now;
        self.poll_start(now);
        if let Some(p) = &mut self.player {
            let r = p.frame(now);
            self.after_player();
            return r;
        }
        self.refresh_home_if_stale();
        let off = self.side();
        let page_w = self.page_env().size.w;
        if let Some(t) = &mut self.top {
            let (over, more_top) = on_top!(t, s => (s.frame(now), s.covers()));
            let ((mut over, mut wants_top), mut covers) = (over, more_top);
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
            self.after_top();
            if covers && off == 0.0 {
                return (over, wants_top);
            }
            let (mut list, wants) = front!(self, s => s.frame(now));
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
        let (list, wants) = self.base_frame(now);
        self.after_base(now);
        (list, wants)
    }

    /// What a screen reader gets for the screen in front (player, pushed page or tab), with its window-level title.
    pub fn a11y_nodes(&self) -> (&'static str, Vec<swiftly_ui::a11y::A11yNode>) {
        let (title, mut nodes) = self.a11y_pages();
        if self.top.is_some() {
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

    fn a11y_pages(&self) -> (&'static str, Vec<swiftly_ui::a11y::A11yNode>) {
        if let Some(p) = &self.player {
            return ("Player", p.a11y_nodes());
        }
        if let Some(t) = &self.top {
            let (title, nodes) = match t {
                Top::Detail(s) => ("Film", s.a11y_nodes()),
                Top::Series(s) => ("Serie", s.a11y_nodes()),
                Top::Settings(s) => ("Einstellungen", s.a11y_nodes()),
                Top::Downloads(s) => ("Downloads", s.a11y_nodes()),
                Top::Login(s) => ("Anmelden", s.a11y_nodes()),
                Top::Page(_) => ("Seite", Vec::new()),
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
        if let Some(p) = &self.player {
            return p.wants_frame();
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
