//! The navigation state machine of the desktop app: ONE enum for what is selected in the sidebar, what is on top and
//! which way every transition travels. All transitions are in [`reduce`]; the suite only plays the returned [`Motion`].
//!
//! Model (the Mac's `MainView`): a sidebar page (tab or Downloads) with its own stack of pushed title pages, and at most
//! one panel (Settings, accounts, sign-in) in front of everything. A panel counts as the sidebar's "Settings" entry.

/// The pages of the sidebar. Downloads is a page like the others, not a push.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Page {
    /// Start, Movies, Series, Search (0 to 3) and the Watchlist (4).
    Tab(u8),
    /// The Downloads page.
    Downloads,
}

impl Page {
    fn index(self) -> usize {
        match self {
            Page::Tab(i) => usize::from(i).min(4),
            Page::Downloads => 5,
        }
    }
}

/// A panel that slides in from the right over the page.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Panel {
    /// Profile and settings.
    Settings,
    /// Account list or sign-in (a panel replacing the settings one in place).
    Accounts,
}

/// What the sidebar highlights.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Selected {
    /// A tab row.
    Tab(u8),
    /// The Watchlist row.
    Watchlist,
    /// The Downloads row.
    Downloads,
    /// The profile row at the bottom left (a panel is open).
    Settings,
}

/// What happened.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    /// A sidebar row (or a shortcut) asked for a page.
    Select(Page),
    /// The profile row, a shortcut or a link asked for a panel.
    OpenPanel(Panel),
    /// The panel asked to leave (back, Esc, the profile row again).
    ClosePanel,
    /// A title page is pushed over the page.
    PushTitle,
    /// The top title page leaves.
    PopTitle,
}

/// The way a transition moves. The suite draws it; nothing else decides directions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Motion {
    /// Nothing to play (illegal or no-op event).
    None,
    /// Another page: the content cross fades, the sidebar stays.
    Section,
    /// The panel enters from the right, the page behind moves back to the left.
    PanelIn,
    /// The panel leaves to the right; the page behind (the same or the one asked for) travels in from the left.
    PanelOut,
    /// A title page enters from the right.
    Push,
    /// The title page leaves to the right, the page behind travels from the left into place.
    Pop,
}

/// The whole navigation state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NavState {
    /// The page in front of the sidebar (behind a panel).
    pub page: Page,
    /// The panel in front of the page.
    pub panel: Option<Panel>,
    /// Pushed title pages per page (index 0 to 3 tabs, 4 watchlist, 5 downloads): each page keeps its own stack.
    pub stacks: [u8; 6],
}

impl Default for NavState {
    fn default() -> Self {
        NavState {
            page: Page::Tab(0),
            panel: None,
            stacks: [0; 6],
        }
    }
}

impl NavState {
    /// What the sidebar highlights: an open panel wins, then the page.
    pub fn selected(&self) -> Selected {
        match (self.panel, self.page) {
            (Some(_), _) => Selected::Settings,
            (None, Page::Tab(4)) => Selected::Watchlist,
            (None, Page::Tab(i)) => Selected::Tab(i),
            (None, Page::Downloads) => Selected::Downloads,
        }
    }

    /// Title pages pushed over the page in front.
    pub fn titles(&self) -> u8 {
        self.stacks[self.page.index()]
    }

    /// Whether the page behind a panel changes when the panel leaves because of `event`.
    pub fn page_after(&self, event: Event) -> Page {
        match event {
            Event::Select(p) if self.panel.is_some() => p,
            _ => self.page,
        }
    }
}

/// The one transition function: `(state, event)` to `(state, motion)`.
pub fn reduce(state: NavState, event: Event) -> (NavState, Motion) {
    let mut next = state;
    let motion = match event {
        Event::Select(page) => {
            if state.panel.is_some() {
                // The panel slides out to the right; the chosen page (maybe the one behind) travels in from the left.
                next.panel = None;
                next.page = page;
                Motion::PanelOut
            } else if page == state.page {
                // The row of the page already shown: back to its root.
                if state.titles() > 0 {
                    next.stacks[page.index()] = 0;
                    Motion::Pop
                } else {
                    Motion::None
                }
            } else {
                next.page = page;
                Motion::Section
            }
        }
        Event::OpenPanel(panel) => match state.panel {
            None => {
                next.panel = Some(panel);
                Motion::PanelIn
            }
            Some(open) if open == panel => Motion::None,
            // A panel that replaces another one takes its place at once.
            Some(_) => {
                next.panel = Some(panel);
                Motion::None
            }
        },
        Event::ClosePanel => {
            if state.panel.is_some() {
                next.panel = None;
                Motion::PanelOut
            } else {
                Motion::None
            }
        }
        Event::PushTitle => {
            if state.panel.is_some() {
                Motion::None
            } else {
                let i = state.page.index();
                next.stacks[i] = state.stacks[i].saturating_add(1);
                Motion::Push
            }
        }
        Event::PopTitle => {
            let i = state.page.index();
            if state.panel.is_none() && state.stacks[i] > 0 {
                next.stacks[i] -= 1;
                Motion::Pop
            } else {
                Motion::None
            }
        }
    };
    (next, motion)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(events: &[Event]) -> (NavState, Vec<Motion>) {
        let mut s = NavState::default();
        let mut out = Vec::new();
        for e in events {
            let (n, m) = reduce(s, *e);
            s = n;
            out.push(m);
        }
        (s, out)
    }

    #[test]
    fn every_sidebar_page_is_a_section_with_its_own_highlight() {
        for (page, sel) in [
            (Page::Tab(1), Selected::Tab(1)),
            (Page::Tab(2), Selected::Tab(2)),
            (Page::Tab(3), Selected::Tab(3)),
            (Page::Tab(4), Selected::Watchlist),
            (Page::Downloads, Selected::Downloads),
            (Page::Tab(0), Selected::Tab(0)),
        ] {
            let start = if page == Page::Tab(0) {
                Page::Tab(1)
            } else {
                Page::Tab(0)
            };
            let (s, m) = reduce(
                NavState {
                    page: start,
                    ..NavState::default()
                },
                Event::Select(page),
            );
            assert_eq!(m, Motion::Section, "{page:?}");
            assert_eq!(s.selected(), sel, "{page:?}");
            assert_eq!(s.panel, None);
        }
    }

    #[test]
    fn downloads_is_never_a_push() {
        let (s, m) = run(&[Event::Select(Page::Downloads)]);
        assert_eq!(m, [Motion::Section]);
        assert_eq!(s.selected(), Selected::Downloads);
        assert_eq!(s.titles(), 0);
    }

    #[test]
    fn settings_slide_in_and_count_as_selected() {
        let (s, m) = run(&[Event::OpenPanel(Panel::Settings)]);
        assert_eq!(m, [Motion::PanelIn]);
        assert_eq!(s.selected(), Selected::Settings);
        assert_eq!(s.page, Page::Tab(0), "the page stays behind the panel");
    }

    #[test]
    fn a_panel_leaves_to_the_right_for_every_sidebar_page() {
        for page in [
            Page::Tab(0),
            Page::Tab(1),
            Page::Tab(2),
            Page::Tab(3),
            Page::Tab(4),
            Page::Downloads,
        ] {
            let (s, m) = run(&[Event::OpenPanel(Panel::Settings), Event::Select(page)]);
            assert_eq!(m, [Motion::PanelIn, Motion::PanelOut], "{page:?}");
            assert_eq!(s.panel, None);
            assert_eq!(s.page, page);
        }
    }

    #[test]
    fn closing_the_panel_keeps_the_page() {
        let (s, m) = run(&[
            Event::Select(Page::Tab(2)),
            Event::OpenPanel(Panel::Settings),
            Event::ClosePanel,
        ]);
        assert_eq!(m, [Motion::Section, Motion::PanelIn, Motion::PanelOut]);
        assert_eq!(s.page, Page::Tab(2));
        assert_eq!(s.selected(), Selected::Tab(2));
    }

    #[test]
    fn panel_replacing_panel_is_in_place_and_same_panel_is_a_no_op() {
        let (s, m) = run(&[
            Event::OpenPanel(Panel::Settings),
            Event::OpenPanel(Panel::Accounts),
            Event::OpenPanel(Panel::Accounts),
        ]);
        assert_eq!(m, [Motion::PanelIn, Motion::None, Motion::None]);
        assert_eq!(s.panel, Some(Panel::Accounts));
    }

    #[test]
    fn push_and_pop_and_each_page_keeps_its_stack() {
        let (s, m) = run(&[
            Event::PushTitle,
            Event::PushTitle,
            Event::Select(Page::Tab(1)),
            Event::PushTitle,
            Event::Select(Page::Tab(0)),
        ]);
        assert_eq!(
            m,
            [
                Motion::Push,
                Motion::Push,
                Motion::Section,
                Motion::Push,
                Motion::Section
            ]
        );
        assert_eq!(s.titles(), 2);
        let (s, m) = reduce(s, Event::PopTitle);
        assert_eq!((m, s.titles()), (Motion::Pop, 1));
        let (s, _) = reduce(s, Event::Select(Page::Tab(1)));
        assert_eq!(s.titles(), 1);
    }

    #[test]
    fn the_row_of_the_shown_page_pops_to_its_root() {
        let (s, m) = run(&[
            Event::PushTitle,
            Event::PushTitle,
            Event::Select(Page::Tab(0)),
            Event::Select(Page::Tab(0)),
        ]);
        assert_eq!(m, [Motion::Push, Motion::Push, Motion::Pop, Motion::None]);
        assert_eq!(s.titles(), 0);
    }

    #[test]
    fn illegal_events_change_nothing() {
        let (s, m) = run(&[Event::PopTitle, Event::ClosePanel]);
        assert_eq!(m, [Motion::None, Motion::None]);
        assert_eq!(s, NavState::default());
        let (s, m) = run(&[
            Event::OpenPanel(Panel::Settings),
            Event::PushTitle,
            Event::PopTitle,
        ]);
        assert_eq!(m, [Motion::PanelIn, Motion::None, Motion::None]);
        assert_eq!(s.titles(), 0);
    }

    #[test]
    fn page_after_names_the_page_behind_a_leaving_panel() {
        let (s, _) = run(&[
            Event::Select(Page::Tab(1)),
            Event::OpenPanel(Panel::Settings),
        ]);
        assert_eq!(s.page_after(Event::ClosePanel), Page::Tab(1));
        assert_eq!(
            s.page_after(Event::Select(Page::Downloads)),
            Page::Downloads
        );
    }
}
