//! The gate G1 demo: "Startseite" with three poster rails of 200 items; a tap pushes a detail page; back pops it.
//! All text goes through `swiftly-text`, all motion through `swiftly-ui` (`Nav` for the push).

use crate::art;
use std::rc::Rc;
use swiftly_design::tokens::{colour, touch};
use swiftly_layout::{Align, Alignment, Axis, EdgeInsets, FlexFrame};
use swiftly_render::{Color, DrawList, RgbaImage};
use swiftly_text::TextStyle;
use swiftly_ui::components::{ButtonStyle, color, poster_tile, press_button, rail};
use swiftly_ui::nav::{Layers, Nav, NavStyle, stack_view};
use swiftly_ui::{Action, Cx, Env, ImageId, Node, Ui, UiEvent};
use swiftly_ui::{BackOutcome, NavKey, Outcome as FocusOutcome};

/// Items in every rail.
pub const RAIL_ITEMS: usize = 200;
const TILE_BASE: u64 = 1 << 20;

/// A page of the demo.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    /// The "Startseite".
    Home,
    /// The detail page of one tile.
    Detail {
        /// Rail (0 to 2).
        rail: u8,
        /// Item in the rail.
        index: u16,
    },
}

#[derive(Clone, PartialEq)]
struct Parts {
    pos_bits: u64,
    pages: Vec<(u64, Route)>,
}

struct Art {
    posters: Vec<ImageId>,
    heroes: Vec<ImageId>,
}

fn tile_action(rail: usize, index: usize) -> Action {
    Action(TILE_BASE + (rail * 1000 + index) as u64)
}

fn decode_tile(a: Action) -> Option<(u8, u16)> {
    let v = a.0.checked_sub(TILE_BASE)?;
    (v < 3000).then_some(((v / 1000) as u8, (v % 1000) as u16))
}

fn back_action() -> Action {
    Action::from("detail.back")
}

fn text(
    cx: &Cx,
    s: &str,
    st: swiftly_design::TextStyle,
    c: swiftly_design::Colour,
    lines: Option<usize>,
) -> Node {
    Node::text(
        cx,
        s,
        &TextStyle::from(st),
        color(c),
        lines,
        swiftly_text::Align::Start,
    )
}

fn inset(n: Node) -> Node {
    n.padding(EdgeInsets {
        top: 0.0,
        leading: touch::EDGE_SPACING,
        bottom: 0.0,
        trailing: touch::EDGE_SPACING,
    })
}

/// The ground colour behind a page that fills the window.
fn ground(content: Node) -> Node {
    content
        .flex_frame(FlexFrame {
            max_w: Some(f32::INFINITY),
            max_h: Some(f32::INFINITY),
            align: Some(Alignment::TOP_LEADING),
            ..FlexFrame::default()
        })
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER)
}

fn home(cx: &Cx, env: &Env, art: &Rc<Art>) -> Node {
    let mut children = vec![inset(text(
        cx,
        "Zurück zur Startseite",
        touch::text::TITLE_LARGE,
        colour::FONT,
        Some(1),
    ))];
    for (r, title) in art::RAIL_TITLES.iter().enumerate() {
        let (c2, art2) = (cx.clone(), Rc::clone(art));
        children.push(rail(
            cx,
            format!("rail{r}").as_str(),
            title,
            RAIL_ITEMS,
            move |i| {
                let poster = art2.posters[(i * 5 + r * 11) % art2.posters.len()];
                poster_tile(&c2, i, &art::title_for(r, i), poster, tile_action(r, i))
            },
        ));
    }
    let column =
        Node::vstack(Align::Start, Some(touch::RAILS_SPACING), children).padding(EdgeInsets {
            top: env.safe.top + touch::HEADER_TOP,
            leading: 0.0,
            bottom: 48.0,
            trailing: 0.0,
        });
    ground(Node::scroll(Axis::Vertical, None, column).key("home-scroll"))
}

fn detail(cx: &Cx, env: &Env, art: &Rc<Art>, r: usize, i: usize) -> Node {
    let (meta, paras) = art::blurb(r, i);
    let hero_w = (env.size.w - 2.0 * touch::EDGE_SPACING).clamp(200.0, 960.0);
    let hero = Node::image(
        art.heroes[(i + r) % art.heroes.len()],
        hero_w,
        (hero_w * 0.34).clamp(80.0, 320.0),
        touch::CORNER_CARD,
    );
    let mut children = vec![
        inset(Node::hstack(
            Align::Start,
            Some(12.0),
            vec![
                press_button(
                    cx,
                    "back",
                    "Zurück zur Startseite",
                    ButtonStyle::Secondary,
                    back_action(),
                ),
                Node::spacer(),
            ],
        )),
        inset(hero),
        inset(text(
            cx,
            &art::title_for(r, i),
            touch::text::TITLE_LARGE,
            colour::FONT,
            Some(2),
        )),
        inset(text(
            cx,
            &meta,
            touch::text::BODY,
            colour::FONT_QUIET,
            Some(1),
        )),
    ];
    for p in paras {
        children.push(
            inset(text(cx, p, touch::text::BODY, colour::FONT, None)).frame(
                Some(hero_w + 2.0 * touch::EDGE_SPACING),
                None,
                Alignment::TOP_LEADING,
            ),
        );
    }
    children.push(inset(Node::hstack(
        Align::Start,
        Some(12.0),
        vec![
            press_button(cx, "play", "Abspielen", ButtonStyle::Primary, "detail.play"),
            press_button(
                cx,
                "list",
                "Zur Merkliste",
                ButtonStyle::Secondary,
                "detail.list",
            ),
        ],
    )));
    ground(
        Node::vstack(Align::Start, Some(touch::RAILS_SPACING), children).padding(EdgeInsets {
            top: env.safe.top + touch::HEADER_TOP,
            leading: 0.0,
            bottom: 24.0,
            trailing: 0.0,
        }),
    )
}

/// The demo: a UI and its navigation stack.
pub struct Demo {
    ui: Ui<Parts>,
    nav: Nav<Route>,
}

impl Demo {
    /// What a screen reader gets for this screen: the nodes of the current picture.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    /// Builds the demo for `env` (generates the posters and heroes into the image page).
    pub fn new(env: Env, cx: Cx) -> Demo {
        let style = NavStyle::for_idiom(env.idiom);
        let art = Rc::new(Art {
            posters: art::posters(&cx),
            heroes: art::heroes(&cx),
        });
        let nav = Nav::new(Route::Home, style);
        let view = move |p: &Parts, env: &Env, cx: &Cx| {
            let layers = Layers::at(f64::from_bits(p.pos_bits), p.pages.len());
            let pages = p
                .pages
                .iter()
                .map(|&(serial, route)| {
                    let node = match route {
                        Route::Home => home(cx, env, &art),
                        Route::Detail { rail, index } => {
                            detail(cx, env, &art, usize::from(rail), usize::from(index))
                        }
                    };
                    (serial, node)
                })
                .collect();
            stack_view(env, NavStyle::for_idiom(env.idiom), &layers, pages)
        };
        let parts = Parts {
            pos_bits: 0.0_f64.to_bits(),
            pages: vec![(0, Route::Home)],
        };
        let ui = Ui::new(view, parts, env, cx);
        let mut demo = Demo { ui, nav };
        demo.sync();
        demo
    }

    fn sync(&mut self) {
        self.ui.set_parts(Parts {
            pos_bits: self.nav.position().to_bits(),
            pages: self.nav.pages().map(|(s, r)| (s, *r)).collect(),
        });
    }

    /// Scroll offsets of all scroll views in tree order (the page first, then the rails).
    pub fn scroll_offsets(&self) -> Vec<f64> {
        self.ui.scroll_offsets()
    }

    /// How many lazy items are built right now.
    pub fn built_items(&self) -> usize {
        self.ui.built_items()
    }

    /// How many times the view has run.
    pub fn view_runs(&self) -> usize {
        self.ui.view_runs()
    }

    /// The navigation stack.
    pub fn nav(&self) -> &Nav<Route> {
        &self.nav
    }

    /// A new window size or scale.
    pub fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }

    /// Scrolling by this table instead of the running OS's (goldens that must not depend on the platform).
    pub fn set_scroll_tuning(&mut self, t: swiftly_motion::ScrollTuning) {
        self.ui.set_scroll_tuning(t);
    }

    /// Opens the detail page of an item (as a tap on its tile does).
    pub fn open_detail(&mut self, rail: u8, index: u16, now: f64) {
        self.nav.push(Route::Detail { rail, index }, now);
        self.sync();
    }

    /// Back: pops one page. `false` at the root.
    pub fn back(&mut self, now: f64) -> bool {
        let popped = self.nav.pop(now);
        self.sync();
        popped
    }

    /// Takes the UI's events: taps open details or go back, the edge pan moves the swipe.
    fn drain(&mut self, now: f64) {
        let width = self.ui.env().size.w;
        for ev in self.ui.take_events() {
            if self.nav.handle(&ev, width, now) {
                continue;
            }
            if let UiEvent::Tap(action) = ev {
                if action == back_action() {
                    self.nav.pop(now);
                } else if let Some((rail, index)) = decode_tile(action)
                    && self.nav.depth() == 1
                {
                    self.nav.push(Route::Detail { rail, index }, now);
                }
            }
        }
        self.sync();
    }

    /// A key on the shared focus engine (arrows, Tab, Enter, Esc). Enter and a tap on the focused tile are the same
    /// event. `Back` from the engine pops the page; the first key only shows the focus ring.
    pub fn nav_key(&mut self, key: NavKey, down: bool, now: f64) -> FocusOutcome {
        let out = self.ui.nav_key(key, down, now);
        if out == FocusOutcome::Back(BackOutcome::Pop) {
            self.nav.pop(now);
        }
        self.drain(now);
        out
    }

    /// A finger or button goes down at a point.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        self.ui.touch_down(x, y, now);
        self.drain(now);
    }

    /// The finger moves.
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        self.ui.touch_move(x, y, now);
        self.drain(now);
    }

    /// The finger lifts.
    pub fn touch_up(&mut self, x: f32, y: f32, now: f64) {
        self.ui.touch_up(x, y, now);
        self.drain(now);
    }

    /// The touch is cancelled.
    pub fn touch_cancel(&mut self, now: f64) {
        self.ui.touch_cancel(now);
        self.drain(now);
    }

    /// One frame: navigation and animations advance to `now`; returns the quads and whether another frame is wanted.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.nav.update(now);
        self.sync();
        let list = self.ui.frame(now);
        self.drain(now);
        let wants = self.ui.needs_frame() || self.nav.is_animating();
        (list, wants)
    }

    /// Another frame is needed without a new event (an animation, a glide, a held touch).
    pub fn wants_frame(&self) -> bool {
        self.ui.needs_frame() || self.nav.is_animating()
    }

    /// The services (atlas pages) the renderers read.
    pub fn cx(&self) -> &Cx {
        self.ui.cx()
    }

    /// Renders a list with the software renderer.
    pub fn render_software(&self, list: &DrawList) -> RgbaImage {
        self.ui.render(list, Color::BLACK)
    }
}
