//! The desktop player's menu box: the core's `PlayerVm::menus()` flattened into rows the box draws. The core owns the
//! levels, the texts and every action; this file only decides which rows a level shows on a desktop and where the box
//! hangs under the bar's capsule.

use crate::player_host::EpisodeCardData;
use swiftly_layout::Rect;
use swiftly_vm::{
    ChaptersPart, HandoffState, MenuAction, MenuLevel, PanelTab, PlayerMenus, TrackChoice,
    TrackTab, Words,
};

/// The capsule button a menu opens from (the box hangs under it and the button shows the open state).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Half {
    /// "Folgen": the episodes and chapters box (films: chapters only).
    Folgen,
    /// "Untertitel": Ton & Untertitel and the levels below it.
    Tracks,
    /// "Einstellungen": Optionen and the levels below it.
    Settings,
    /// "Übergeben an".
    Handoff,
}

impl Half {
    /// The level the box starts on.
    pub fn first_level(self) -> MenuLevel {
        match self {
            Half::Folgen => MenuLevel::Episodes(PanelTab::Episodes),
            Half::Tracks => MenuLevel::Tracks(TrackTab::Subtitles),
            Half::Settings => MenuLevel::Options,
            Half::Handoff => MenuLevel::Handoff,
        }
    }
}

/// The open menu box: which button it hangs under, the level it shows and the highlighted row (keyboard).
#[derive(Clone, Debug, PartialEq)]
pub struct Pm {
    pub from: Half,
    pub level: MenuLevel,
    /// Index into [`Page::actions`].
    pub hl: Option<usize>,
}

/// One drawn row of a level.
#[derive(Clone, Debug, PartialEq)]
pub enum Item {
    /// The level's title; `back` (an action index) draws the back chevron.
    Title { text: String, back: Option<usize> },
    /// The tab row (Untertitel | Ton): text, selected, action index.
    Tabs(Vec<(String, bool, usize)>),
    /// A row that opens a level: title, value, action index.
    Nav {
        title: String,
        value: String,
        act: usize,
    },
    /// A choice row with a check.
    Check {
        label: String,
        detail: Option<String>,
        selected: bool,
        act: usize,
    },
    /// A plain action row; `key` names the node when a screen test or the host looks for it.
    Press {
        title: String,
        act: usize,
        key: Option<&'static str>,
    },
    /// A small heading above capsules.
    Heading(String),
    /// Capsules in one row: text, selected, action index.
    Capsules(Vec<(String, bool, usize)>),
    /// The timing stepper: earlier, value, later.
    Stepper {
        earlier: (String, usize),
        value: String,
        later: (String, usize),
    },
    /// A quiet sentence.
    Note(String),
    /// A hairline between groups.
    Rule,
    /// The "Staffel N" button of the Folgen tab (opens the season list): text, action index.
    Season { text: String, act: usize },
    /// One episode row: the card the core's host built, `card` its index.
    Episode {
        card: usize,
        title: String,
        sub: Option<String>,
        progress: Option<f32>,
        watched: bool,
        current: bool,
        act: usize,
    },
}

/// Height of a row of the box (pt).
pub const ROW_H: f32 = 44.0;

impl Item {
    /// The height the box gives this row.
    pub fn height(&self) -> f32 {
        match self {
            Item::Title { .. } => 44.0,
            Item::Tabs(_) => 44.0,
            Item::Heading(_) => 32.0,
            Item::Capsules(_) => 44.0,
            Item::Stepper { .. } => 56.0,
            Item::Note(_) => 32.0,
            Item::Rule => 13.0,
            Item::Season { .. } => 48.0,
            Item::Episode { .. } => 60.0,
            _ => ROW_H,
        }
    }

    /// The action index of a row that can be pressed.
    pub fn act(&self) -> Option<usize> {
        match self {
            Item::Nav { act, .. }
            | Item::Check { act, .. }
            | Item::Press { act, .. }
            | Item::Episode { act, .. } => Some(*act),
            _ => None,
        }
    }

    /// Rows that stay above the scrolling part of the box (title and tabs).
    pub fn sticky(&self) -> bool {
        matches!(
            self,
            Item::Title { .. } | Item::Tabs(_) | Item::Season { .. }
        )
    }
}

/// A level as rows, and the actions the rows refer to by index.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Page {
    pub items: Vec<Item>,
    pub actions: Vec<MenuAction>,
    /// Action indices of the rows the keyboard walks through, in order.
    pub walk: Vec<usize>,
    /// Action index of an episode row -> its card index (the host plays it; the core has no action for it).
    pub episode_of: Vec<(usize, usize)>,
}

/// What the Folgen box shows besides the core's tabs and season list: the host's episode cards and the core's chapters.
pub struct Panel<'a> {
    pub cards: &'a [EpisodeCardData],
    /// The running episode's card.
    pub current: Option<usize>,
    pub chapters: &'a ChaptersPart,
    /// Formats a start time.
    pub time: fn(f64) -> String,
}

impl Page {
    fn add(&mut self, a: MenuAction) -> usize {
        self.actions.push(a);
        self.actions.len() - 1
    }

    /// Top of item `i` (pt) from the top of the scrolling part, and its height.
    pub fn scroll_span(&self, item: usize) -> (f32, f32) {
        let mut y = 0.0;
        for (i, it) in self.items.iter().filter(|it| !it.sticky()).enumerate() {
            if i == item {
                return (y, it.height());
            }
            y += it.height();
        }
        (y, 0.0)
    }

    /// The scrolling item that shows action `act`.
    pub fn item_of(&self, act: usize) -> Option<usize> {
        self.items
            .iter()
            .filter(|it| !it.sticky())
            .position(|it| it.act() == Some(act))
    }

    /// The pressed row after `step` (±1) from `hl`, wrapping.
    pub fn walk_from(&self, hl: Option<usize>, step: i32) -> Option<usize> {
        if self.walk.is_empty() {
            return None;
        }
        let at = hl.and_then(|h| self.walk.iter().position(|a| *a == h));
        let n = self.walk.len() as i32;
        let next = match at {
            Some(i) => (i as i32 + step).rem_euclid(n),
            None if step > 0 => 0,
            None => n - 1,
        };
        Some(self.walk[next as usize])
    }
}

/// What a desktop cannot do from the core's rows: the host has no screen lock and no start-together sheet over the
/// player, and no AirPlay (the host tells `airplay: false`). "Problem melden" is listed only while the Seerr account
/// may report (`desk::report_offered`, the core's title menu).
fn supported(a: &MenuAction) -> bool {
    match a {
        MenuAction::ReportProblem => crate::desk::report_offered(),
        _ => !matches!(
            a,
            MenuAction::LockScreen | MenuAction::StartTogether | MenuAction::AirPlay
        ),
    }
}

/// Which level the back chevron goes to (`None`: the level is the box's first page).
pub fn parent(level: MenuLevel, from: Half) -> Option<MenuLevel> {
    match level {
        MenuLevel::Speed
        | MenuLevel::Sleep
        | MenuLevel::Picture
        | MenuLevel::Quality
        | MenuLevel::Together => Some(MenuLevel::Options),
        MenuLevel::SubtitleLook => Some(MenuLevel::Tracks(TrackTab::Subtitles)),
        MenuLevel::TimeAdjust(tab) => Some(MenuLevel::Tracks(tab)),
        MenuLevel::Options | MenuLevel::Tracks(_) | MenuLevel::Handoff => {
            let _ = from;
            None
        }
        MenuLevel::Episodes(_) => None,
        MenuLevel::Seasons => Some(MenuLevel::Episodes(PanelTab::Episodes)),
    }
}

fn words(w: &Words) -> String {
    match w {
        Words::Key(k) => swiftly_l10n::t(k),
        Words::Count(k, n) => swiftly_l10n::t_args(k, &[swiftly_l10n::Arg::Int(*n)]),
        Words::Pair(a, b) => format!("{} · {}", swiftly_l10n::t(a), swiftly_l10n::t(b)),
        Words::Literal(s) => s.clone(),
    }
}

fn track_label(t: &TrackChoice) -> String {
    if t.label_is_key {
        swiftly_l10n::t(&t.label)
    } else {
        t.label.clone()
    }
}

fn capsules(page: &mut Page, choices: &[swiftly_vm::MenuChoice]) -> Item {
    let mut cells = Vec::new();
    for c in choices {
        let a = page.add(c.action.clone());
        cells.push((words(&c.label), c.selected, a));
    }
    Item::Capsules(cells)
}

/// The rows of `level` from the core's menus.
/// `search_offered`: the server can search subtitles (a host fact; the core lists the row either way).
pub fn page(
    menus: &PlayerMenus,
    level: MenuLevel,
    from: Half,
    search_offered: bool,
    panel: &Panel<'_>,
) -> Page {
    let mut p = Page::default();
    let back = parent(level, from).map(|l| p.add(MenuAction::Open(l)));
    let title = |p: &mut Page, text: String| {
        p.items.push(Item::Title { text, back });
    };
    match level {
        MenuLevel::Options => {
            for r in &menus.options.rows {
                if !supported(&r.action) {
                    continue;
                }
                let act = p.add(r.action.clone());
                p.items.push(Item::Nav {
                    title: words(&r.title),
                    value: words(&r.value),
                    act,
                });
            }
            let foot: Vec<_> = menus
                .options
                .footer
                .iter()
                .filter(|r| supported(&r.action))
                .collect();
            if !foot.is_empty() {
                p.items.push(Item::Rule);
            }
            for r in foot {
                let act = p.add(r.action.clone());
                p.items.push(Item::Press {
                    title: words(&r.title),
                    act,
                    key: None,
                });
            }
        }
        MenuLevel::Episodes(tab) => {
            let e = &menus.episodes;
            if e.tabs.len() > 1 {
                let mut cells = Vec::new();
                for x in &e.tabs {
                    let act = p.add(MenuAction::Open(MenuLevel::Episodes(*x)));
                    let name = match x {
                        PanelTab::Episodes => swiftly_l10n::t("Folgen"),
                        PanelTab::Chapters => swiftly_l10n::t(panel.chapters.title),
                    };
                    cells.push((name, *x == tab, act));
                }
                p.items.push(Item::Tabs(cells));
            }
            if tab == PanelTab::Episodes {
                if let Some(b) = &e.season_button {
                    let act = p.add(b.action.clone());
                    p.items.push(Item::Season {
                        text: format!("{} {}", words(&b.title), words(&b.value))
                            .replace("Staffel Staffel", "Staffel"),
                        act,
                    });
                }
                for (i, d) in panel.cards.iter().enumerate() {
                    let act = p.add(MenuAction::Open(MenuLevel::Episodes(PanelTab::Episodes)));
                    p.episode_of.push((act, i));
                    p.items.push(Item::Episode {
                        card: i,
                        title: d.header.clone(),
                        sub: d.sub.clone(),
                        progress: d.progress,
                        watched: d.watched,
                        current: Some(i) == panel.current,
                        act,
                    });
                }
            } else {
                for r in &panel.chapters.rows {
                    let act = p.add(MenuAction::Player(swiftly_vm::PlayerIntent::JumpToChapter(
                        r.index,
                    )));
                    let name = r.name.clone().unwrap_or_else(|| {
                        swiftly_l10n::t_args(
                            panel.chapters.number_title,
                            &[swiftly_l10n::Arg::Int(r.number)],
                        )
                    });
                    p.items.push(Item::Check {
                        label: name,
                        detail: Some((panel.time)(r.start)),
                        selected: r.current,
                        act,
                    });
                }
            }
        }
        MenuLevel::Seasons => {
            let e = &menus.episodes;
            title(&mut p, words(&e.seasons_title));
            for c in &e.seasons {
                let act = p.add(c.action.clone());
                p.items.push(Item::Check {
                    label: words(&c.label),
                    detail: None,
                    selected: c.selected,
                    act,
                });
            }
        }
        MenuLevel::Speed | MenuLevel::Picture => {
            let page = if level == MenuLevel::Speed {
                &menus.speed
            } else {
                &menus.picture
            };
            title(&mut p, words(&page.title));
            for c in &page.choices {
                let act = p.add(c.action.clone());
                p.items.push(Item::Check {
                    label: words(&c.label),
                    detail: c.detail.as_ref().map(words),
                    selected: c.selected,
                    act,
                });
            }
        }
        MenuLevel::Sleep => {
            title(&mut p, words(&menus.sleep.title));
            for c in &menus.sleep.choices {
                let act = p.add(c.action.clone());
                p.items.push(Item::Check {
                    label: words(&c.label),
                    detail: None,
                    selected: c.selected,
                    act,
                });
            }
            p.items
                .push(Item::Heading(words(&menus.sleep.minutes_title)));
            let caps = capsules(&mut p, &menus.sleep.minutes);
            p.items.push(caps);
        }
        MenuLevel::Quality => {
            title(&mut p, words(&menus.quality.title));
            if menus.quality.offered {
                let o = &menus.quality.original;
                let act = p.add(o.action.clone());
                p.items.push(Item::Check {
                    label: words(&o.label),
                    detail: o.detail.as_ref().map(words),
                    selected: o.selected,
                    act,
                });
                p.items
                    .push(Item::Heading(words(&menus.quality.bitrate_title)));
                let caps = capsules(&mut p, &menus.quality.bitrates);
                p.items.push(caps);
            }
            p.items.push(Item::Rule);
            let act = p.add(menus.quality.badge_action.clone());
            p.items.push(Item::Check {
                label: words(&menus.quality.badge_title),
                detail: None,
                selected: menus.quality.badge_on,
                act,
            });
        }
        MenuLevel::Together => {
            if let Some(t) = &menus.together {
                title(&mut p, words(&t.title));
                p.items.push(Item::Heading(t.group_name.clone()));
                for m in &t.members {
                    p.items
                        .push(Item::Note(format!("{} · {}", m.name, words(&m.status))));
                }
                p.items.push(Item::Rule);
                let act = p.add(t.leave.action.clone());
                p.items.push(Item::Press {
                    title: words(&t.leave.title),
                    act,
                    key: None,
                });
            }
        }
        MenuLevel::Tracks(tab) => {
            let t = &menus.tracks;
            if t.tabs.len() > 1 {
                let mut cells = Vec::new();
                for x in &t.tabs {
                    let act = p.add(MenuAction::Open(MenuLevel::Tracks(*x)));
                    let name = match x {
                        TrackTab::Subtitles => swiftly_l10n::t("Untertitel"),
                        TrackTab::Audio => swiftly_l10n::t("Ton"),
                    };
                    cells.push((name, *x == tab, act));
                }
                p.items.push(Item::Tabs(cells));
            }
            let page = if tab == TrackTab::Subtitles {
                &t.subtitles
            } else {
                &t.audio
            };
            for r in &page.rows {
                let act = p.add(r.action.clone());
                p.items.push(Item::Check {
                    label: track_label(r),
                    detail: None,
                    selected: r.selected,
                    act,
                });
            }
            // The bar is up before the stream answers, so this menu can open too: with no audio track known yet, a quiet
            // line says the rows are coming (the page is rebuilt when the tracks arrive).
            if t.audio.rows.is_empty() {
                p.items
                    .push(Item::Note(swiftly_l10n::t("Spuren werden geladen …")));
            }
            if let Some(search) = page.search.as_ref().filter(|_| search_offered) {
                let act = p.add(search.clone());
                p.items.push(Item::Press {
                    title: swiftly_l10n::t("Untertitel suchen …"),
                    act,
                    key: Some("search:open"),
                });
            }
            p.items.push(Item::Rule);
            if tab == TrackTab::Subtitles {
                let act = p.add(t.look.action.clone());
                p.items.push(Item::Nav {
                    title: words(&t.look.title),
                    value: words(&t.look.value),
                    act,
                });
            }
            let time = if tab == TrackTab::Subtitles {
                &t.subtitle_time
            } else {
                &t.audio_time
            };
            let act = p.add(time.action.clone());
            p.items.push(Item::Nav {
                title: words(&time.title),
                value: words(&time.value),
                act,
            });
        }
        MenuLevel::SubtitleLook => {
            title(&mut p, words(&menus.look.title));
            for g in &menus.look.groups {
                p.items.push(Item::Heading(words(&g.title)));
                let caps = capsules(&mut p, &g.choices);
                p.items.push(caps);
            }
        }
        MenuLevel::TimeAdjust(tab) => {
            title(&mut p, words(&menus.time.title));
            if let Some(t) = menus.time.tabs.iter().find(|t| t.tab == tab) {
                let e = p.add(t.earlier.action.clone());
                let l = p.add(t.later.action.clone());
                p.items.push(Item::Stepper {
                    earlier: (words(&t.earlier.title), e),
                    value: t.value.clone(),
                    later: (words(&t.later.title), l),
                });
                p.items.push(Item::Note(words(&t.meaning)));
                if let Some(r) = &t.reset {
                    let act = p.add(r.action.clone());
                    p.items.push(Item::Press {
                        title: words(&r.title),
                        act,
                        key: None,
                    });
                }
            }
        }
        MenuLevel::Handoff => {
            let h = &menus.handoff;
            title(&mut p, words(&h.title));
            match h.state {
                HandoffState::List => {
                    for d in &h.rows {
                        let act = p.add(d.action.clone());
                        p.items.push(Item::Check {
                            label: d.name.clone(),
                            detail: d.detail.clone(),
                            selected: false,
                            act,
                        });
                    }
                }
                _ => {
                    if let Some(t) = &h.text {
                        p.items.push(Item::Note(words(t)));
                    }
                }
            }
        }
    }
    // The title row's back chevron is an action too, but not a row the arrows stop on.
    p.walk = p.items.iter().filter_map(Item::act).collect();
    p
}

/// Where the capsule's buttons sit (window points): the circle X right of the capsule, then the capsule's halves from
/// right to left. `slots` is the number of halves.
pub struct Slots {
    #[cfg_attr(not(test), allow(dead_code))]
    pub capsule: Rect,
    pub halves: Vec<Rect>,
    #[cfg_attr(not(test), allow(dead_code))]
    pub close: Rect,
    /// Desktop only: the fullscreen half left of the close half (empty in the touch and tv forms).
    #[cfg_attr(not(test), allow(dead_code))]
    pub fullscreen: Rect,
}

/// Capsule geometry: halves of `half_w` x `h`, a gap of 8 to the X circle of `h`, the right edge at `right`, centred on
/// the rail line `mid`.
pub fn slots(right: f32, mid: f32, n: usize, half_w: f32, h: f32) -> Slots {
    let close = Rect::new(right - h, mid - h / 2.0, h, h);
    let w = half_w * n as f32;
    let capsule = Rect::new(close.x - 8.0 - w, mid - h / 2.0, w, h);
    let halves = (0..n)
        .map(|i| Rect::new(capsule.x + half_w * i as f32, capsule.y, half_w, h))
        .collect();
    Slots {
        capsule,
        halves,
        fullscreen: Rect::new(close.x, close.y, 0.0, 0.0),
        close,
    }
}

/// Desktop geometry: two capsules of one height on the rail line `mid`. The window capsule (fullscreen, close: two halves)
/// ends at `right`; the menu capsule (`n` halves, the speaker last) ends a gap of 8 left of it.
pub fn desktop_slots(right: f32, mid: f32, n: usize, half_w: f32, h: f32) -> Slots {
    let y = mid - h / 2.0;
    let close = Rect::new(right - half_w, y, half_w, h);
    let fullscreen = Rect::new(close.x - half_w, y, half_w, h);
    let w = half_w * n as f32;
    let capsule = Rect::new(fullscreen.x - 8.0 - w, y, w, h);
    let halves = (0..n)
        .map(|i| Rect::new(capsule.x + half_w * i as f32, y, half_w, h))
        .collect();
    Slots {
        capsule,
        halves,
        close,
        fullscreen,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slots_run_right_to_left_with_the_x_alone() {
        let s = slots(1000.0, 30.0, 3, 40.0, 36.0);
        assert_eq!(s.close.x + s.close.w, 1000.0);
        assert_eq!(s.capsule.x + s.capsule.w, s.close.x - 8.0);
        assert_eq!(s.halves.len(), 3);
        assert_eq!(s.halves[2].x + 40.0, s.capsule.x + s.capsule.w);
    }

    #[test]
    fn desktop_slots_put_fullscreen_and_close_in_one_capsule_and_the_speaker_last_in_the_menu_capsule()
     {
        let s = desktop_slots(1000.0, 30.0, 4, 40.0, 36.0);
        assert_eq!(s.close.x + s.close.w, 1000.0);
        assert_eq!(s.fullscreen.x + s.fullscreen.w, s.close.x);
        assert_eq!((s.close.y, s.close.h), (s.capsule.y, s.capsule.h));
        assert_eq!(s.capsule.x + s.capsule.w, s.fullscreen.x - 8.0);
        assert_eq!(s.halves.len(), 4);
        assert_eq!(s.halves[3].x + 40.0, s.capsule.x + s.capsule.w);
    }

    #[test]
    fn the_keyboard_walks_the_rows_and_wraps() {
        let mut p = Page::default();
        for i in 0..3 {
            let act = p.add(MenuAction::TechBadge(i == 0));
            p.items.push(Item::Press {
                title: i.to_string(),
                act,
                key: None,
            });
        }
        p.walk = p.items.iter().filter_map(Item::act).collect();
        assert_eq!(p.walk_from(None, 1), Some(0));
        assert_eq!(p.walk_from(Some(2), 1), Some(0));
        assert_eq!(p.walk_from(None, -1), Some(2));
        assert_eq!(p.walk_from(Some(0), -1), Some(2));
    }
}
