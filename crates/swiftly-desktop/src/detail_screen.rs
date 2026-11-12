//! The Detail screen (movie, episode) of the shared Rust UI, drawn from `DetailVm` parts for `touch`, `desktop` and `tv`,
//! pushed from a poster tap with the navigation spring. Also the shared page kit (`Pushed`, hero, play button, action
//! row, rails, file excerpt) the Series screen builds on. Numbers come from `ItemDetailView` (iOS), the Mac `DetailHero`
//! and the tvOS `DetailHeader`; differences are noted in the code.

use crate::art;
use crate::home::{Form, glass_ground, ramp};
use crate::home_data::Scenario;
use crate::hub::{HubSlot, HubSlotExt};
use crate::net::AppTransport;
use crate::title_data;
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use swiftly_design::tokens::{colour, desktop, touch, tv};
use swiftly_layout::{Align, Alignment, Axis, EdgeInsets, FlexFrame, Size};
use swiftly_render::{Color, DrawList, LinearGradient, RgbaImage};
use swiftly_text::TextStyle;
use swiftly_ui::components::{color, focus_id};
use swiftly_ui::icons::Icons;
use swiftly_ui::interact::PressStyle;
use swiftly_ui::nav::{Layers, Nav, NavStyle, stack_view};
use swiftly_ui::popover::{self, Anchor, MenuController, MenuEntry as PopEntry, MenuItem};
use swiftly_ui::{Action, Cx, Env, FocusLook, ImageId, Node, Paint, Ui, UiEvent};
use swiftly_vm::{
    ActionsPart, BottomPart, CastTile, DetailIntent, DetailVm, DownloadState, HeroPart, MenuEntry,
    PlayAction, Tile,
};

/// The tv page edge (`TVSpec.edgePage`).
pub(crate) const TV_EDGE: f32 = 80.0;
/// Height of the hero picture on touch (`Theme.heroHeightValue`).
const HERO_TOUCH: f32 = 350.0;
/// Height of the Mac backdrop (`DetailPageMetric.heroImage`).
pub(crate) const HERO_DESKTOP: f32 = 454.0;

// ---- small helpers ---------------------------------------------------------------------------------------------------

pub(crate) fn ins(top: f32, leading: f32, bottom: f32, trailing: f32) -> EdgeInsets {
    EdgeInsets {
        top,
        leading,
        bottom,
        trailing,
    }
}

pub(crate) fn fill_frame(n: Node, align: Alignment) -> Node {
    n.flex_frame(FlexFrame {
        max_w: Some(f32::INFINITY),
        max_h: Some(f32::INFINITY),
        align: Some(align),
        ..FlexFrame::default()
    })
}

pub(crate) fn wide(n: Node, align: Alignment) -> Node {
    n.flex_frame(FlexFrame {
        max_w: Some(f32::INFINITY),
        align: Some(align),
        ..FlexFrame::default()
    })
}

pub(crate) fn txt(
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

pub(crate) fn txt_center(
    cx: &Cx,
    s: &str,
    st: swiftly_design::TextStyle,
    c: swiftly_design::Colour,
    lines: usize,
) -> Node {
    Node::text(
        cx,
        s,
        &TextStyle::from(st),
        color(c),
        Some(lines),
        swiftly_text::Align::Center,
    )
}

pub(crate) fn rgba(c: swiftly_design::Colour, a: f32) -> Color {
    Color::new(c.r, c.g, c.b, a)
}

pub(crate) fn weight(
    st: swiftly_design::TextStyle,
    size: f32,
    w: u16,
) -> swiftly_design::TextStyle {
    swiftly_design::TextStyle {
        size,
        weight: w,
        ..st
    }
}

/// The pictures the demo stands in for server images.
pub(crate) struct Art {
    posters: Vec<ImageId>,
    landscapes: Vec<ImageId>,
    /// The hues of each landscape picture (`ImageTone.audioOut`), for the mood-colour backdrop.
    tones: Vec<Vec<f64>>,
    /// The image hub, attached by `with_images`; without one every picture is demo art.
    pub(crate) hub: HubSlot,
    /// Pictures draw nothing (the parity fixture of the SwiftUI side has none seeded for the title).
    pub(crate) blank: std::cell::Cell<bool>,
}

impl Art {
    pub(crate) fn new(cx: &Cx) -> Art {
        Art {
            posters: art::posters(cx),
            landscapes: art::heroes(cx),
            tones: (0..art::HERO_VARIANTS)
                .map(|v| thumb_tones(&art::hero_pixels(v)))
                .collect(),
            hub: Rc::new(RefCell::new(None)),
            blank: std::cell::Cell::new(false),
        }
    }

    /// The hues of the landscape picture `id` shows (empty when none).
    pub(crate) fn tones(&self, id: &str) -> &[f64] {
        let h = id.bytes().fold(7_usize, |a, b| {
            a.wrapping_mul(31).wrapping_add(usize::from(b))
        });
        self.tones
            .get(h % self.landscapes.len().max(1))
            .map_or(&[], Vec::as_slice)
    }

    /// The picture of `image` through the hub when one is attached and the item has an address, else demo art.
    pub(crate) fn node_for(
        &self,
        image: Option<&swiftly_vm::ImageRef>,
        landscape: bool,
        id: &str,
        w: f32,
        h: f32,
        radius: f32,
    ) -> Node {
        if self.blank.get() {
            return Node::rect(Color::CLEAR, radius).frame(Some(w), Some(h), Alignment::CENTER);
        }
        let hub = self.hub.borrow().clone();
        match (hub, image) {
            (Some(hub), Some(_)) => hub.node(image, w, h, radius),
            _ => self.node(landscape, id, w, h, radius),
        }
    }

    /// Mood-colour hues: of the real picture when a hub is attached (empty until it is loaded), else of the demo art.
    pub(crate) fn tones_for(&self, image: Option<&swiftly_vm::ImageRef>, id: &str) -> Vec<f64> {
        if self.blank.get() {
            return Vec::new();
        }
        let hub = self.hub.borrow().clone();
        match (hub, image) {
            (Some(hub), Some(i)) => hub.tones(i).unwrap_or_default(),
            _ => self.tones(id).to_vec(),
        }
    }

    pub(crate) fn pick(&self, landscape: bool, id: &str) -> Option<ImageId> {
        let set = if landscape {
            &self.landscapes
        } else {
            &self.posters
        };
        let h = id.bytes().fold(7_usize, |a, b| {
            a.wrapping_mul(31).wrapping_add(usize::from(b))
        });
        set.get(h % set.len().max(1)).copied()
    }

    pub(crate) fn node(&self, landscape: bool, id: &str, w: f32, h: f32, radius: f32) -> Node {
        match self.pick(landscape, id) {
            Some(i) => Node::image(i, w, h, radius),
            None => {
                Node::rect(color(colour::AREA), radius).frame(Some(w), Some(h), Alignment::CENTER)
            }
        }
    }
}

/// Hues of a hero picture downscaled to at most 48 pixels on a side, as `ImageTone` does before counting.
fn thumb_tones(rgba: &[u8]) -> Vec<f64> {
    let (w, h) = art::HERO_SIZE;
    let (tw, th) = (48.min(w), (48 * h / w).max(1));
    let mut out = Vec::with_capacity(tw * th * 4);
    for y in 0..th {
        for x in 0..tw {
            let i = ((y * h / th) * w + x * w / tw) * 4;
            out.extend_from_slice(&rgba[i..i + 4]);
        }
    }
    swiftly_images::tone::tones_from_rgba(&out)
}

/// The mood-colour mesh of rows `y0..y1` (points from the top of the page), as stacked strips: a horizontal gradient per
/// column pair, rows blended linearly between the mesh rows (`MoodReason.network`; the Swift mesh interpolates smoother
/// in a perceptual space, and the 0.8 % noise against banding is not laid over it). `alpha(y)` multiplies the strip.
pub(crate) fn mood_strips(
    tones: &[f64],
    since: f32,
    (y0, y1): (f32, f32),
    origin: f32,
    w: f32,
    alpha: impl Fn(f32) -> f32,
) -> Node {
    let mesh = swiftly_images::mood::detail_mesh(tones, f64::from(since));
    let total = since + swiftly_images::mood::RUN_OUT as f32;
    let at = |r: usize, c: usize| mesh.points[r * mesh.columns + c].color;
    let mut strips = Vec::new();
    for r in 0..mesh.rows - 1 {
        let (ya, yb) = (
            mesh.points[r * mesh.columns].y * total,
            mesh.points[(r + 1) * mesh.columns].y * total,
        );
        let (lo, hi) = (ya.max(y0), yb.min(y1));
        if hi <= lo || yb <= ya {
            continue;
        }
        let step = if y1 - y0 <= 300.0 { 5.0 } else { 14.0 };
        let n = ((hi - lo) / step).ceil().max(1.0) as usize;
        for i in 0..n {
            let (sa, sb) = (
                lo + (hi - lo) * i as f32 / n as f32,
                lo + (hi - lo) * (i + 1) as f32 / n as f32,
            );
            let t = ((sa + sb) * 0.5 - ya) / (yb - ya);
            let a = alpha((sa + sb) * 0.5);
            let mix = |c: usize| {
                let (p, q) = (at(r, c), at(r + 1, c));
                let f = f64::from(t);
                Color::new(
                    (p.r + (q.r - p.r) * f) as f32,
                    (p.g + (q.g - p.g) * f) as f32,
                    (p.b + (q.b - p.b) * f) as f32,
                    a,
                )
            };
            let cells: Vec<Node> = (0..mesh.columns - 1)
                .map(|c| {
                    let (l, rr) = (mix(c), mix(c + 1));
                    Node::rect(l, 0.0)
                        .paint(Paint::Linear {
                            gradient: LinearGradient {
                                start: l,
                                end: rr,
                                from: [0.0, 0.5],
                                to: [1.0, 0.5],
                            },
                            radius: 0.0,
                        })
                        .frame(
                            Some(w / (mesh.columns - 1) as f32),
                            Some(sb - sa),
                            Alignment::CENTER,
                        )
                })
                .collect();
            strips.push(Node::hstack(Align::Start, Some(0.0), cells));
        }
    }
    Node::vstack(Align::Start, Some(0.0), strips).padding(ins(y0 - origin, 0.0, 0.0, 0.0))
}

/// Sizes that differ by form factor.
pub(crate) struct Look {
    pub form: Form,
    pub pad: bool,
    pub edge: f32,
    pub sections: f32,
    pub tile_gap: f32,
    pub poster: Size,
    pub corner: f32,
    pub rail: swiftly_design::TextStyle,
    pub tile: swiftly_design::TextStyle,
    pub small: swiftly_design::TextStyle,
    pub body: swiftly_design::TextStyle,
    pub row_height: f32,
}

pub(crate) fn look(env: &Env) -> Look {
    let form = Form::of(env.idiom);
    let pad = env.idiom == swiftly_ui::Idiom::Pad;
    match form {
        Form::Touch => Look {
            form,
            pad,
            edge: if pad {
                touch::EDGE_PAGE_WIDE
            } else {
                touch::EDGE_SPACING
            },
            sections: touch::RAILS_SPACING,
            tile_gap: touch::TILE_SPACING,
            poster: Size::new(touch::TILE_WIDTH, touch::TILE_HEIGHT),
            corner: touch::CORNER_TILE,
            rail: touch::text::RAIL,
            tile: touch::text::TILE,
            small: touch::text::SMALL,
            body: touch::text::BODY,
            row_height: 36.0,
        },
        Form::Desktop => Look {
            form,
            pad,
            edge: desktop::DETAIL_LEFT,
            sections: 26.0,
            tile_gap: desktop::TILE_SPACING,
            poster: Size::new(desktop::TILE_WIDTH, desktop::TILE_HEIGHT),
            corner: desktop::CORNER_TILE,
            rail: desktop::text::RAIL,
            tile: desktop::text::TILE,
            small: desktop::text::SMALL,
            body: desktop::text::BODY,
            row_height: 36.0,
        },
        Form::Tv => Look {
            form,
            pad,
            edge: TV_EDGE,
            sections: tv::RAILS_SPACING,
            tile_gap: tv::TILE_SPACING,
            poster: Size::new(tv::POSTER_WIDTH, tv::POSTER_HEIGHT),
            corner: 18.0,
            rail: tv::text::RAIL,
            tile: tv::text::TILE,
            small: swiftly_design::TextStyle {
                uppercase: false,
                tracking: 0.0,
                ..tv::text::GROUP
            },
            body: tv::text::BODY,
            row_height: 64.0,
        },
    }
}

// ---- the pushed-page host --------------------------------------------------------------------------------------------

/// The two pages of the stack: a tiny poster row ("the list") and the title page pushed from it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Route {
    Root,
    Page,
}

/// Small UI values the view reads besides the parts.
#[derive(Clone, Debug, PartialEq, Default)]
pub(crate) struct UiState {
    /// Header strength in eighths.
    pub header: u8,
    /// The overview is expanded.
    pub overview_open: bool,
    /// A sheet (more menu, version picker, season list) is open: 0 none, 1 more, 2 versions, 3 seasons.
    pub sheet: u8,
    /// Tab in front on the series page.
    pub tab: u8,
    /// Focused key on tv.
    pub focus: Option<u64>,
    /// The anchored panel of the Mac (More, season list, tile and episode menus).
    pub menu: MenuController,
}

#[derive(Clone, PartialEq)]
pub(crate) struct PageParts<D: Clone + PartialEq> {
    pos_bits: u64,
    pages: Vec<(u64, Route)>,
    pub data: D,
    pub sx: UiState,
    pictures: u64,
}

type PageFn<D> = dyn Fn(&D, &UiState, &Env, &Cx) -> Node;

/// A `Ui` with a navigation stack (root list -> title page) around a data value `D`.
pub(crate) struct Pushed<D: Clone + PartialEq + 'static> {
    ui: Ui<PageParts<D>>,
    nav: Nav<Route>,
    data: D,
    pub sx: UiState,
    pub now: f64,
    pub(crate) hub: HubSlot,
    /// Where the last right click happened (window points), for the menu it opens.
    pub(crate) pointer: (f32, f32),
    /// Actions chosen with the keyboard (a menu row), handled with the next taps.
    pub(crate) injected: Vec<Action>,
    /// Scroll views the root page owns before the title page's (1: the demo's poster row, 0: a bare root).
    root_scrolls: usize,
}

fn root_page(cx: &Cx, env: &Env, art: &Art) -> Node {
    let lk = look(env);
    let posters: Vec<Node> = (0..6)
        .map(|i| {
            let id = format!("o{i}");
            let mut n = Node::vstack(
                Align::Start,
                Some(8.0),
                vec![
                    art.node(false, &id, lk.poster.w, lk.poster.h, lk.corner)
                        .paint(Paint::Stroke {
                            color: color(colour::TILE_BORDER),
                            width: 1.0,
                            radius: lk.corner,
                        }),
                    txt(cx, "Nordlicht", lk.tile, colour::FONT, Some(1)),
                ],
            )
            .key(format!("poster:{i}").as_str())
            .on_tap(Action::from("open"));
            if lk.form == Form::Tv {
                n = n.focusable(
                    focus_id(format!("poster:{i}").as_str()),
                    Some(FocusLook::tile(lk.corner)),
                );
            }
            n
        })
        .collect();
    let row = Node::hstack(Align::Start, Some(lk.tile_gap), posters)
        .padding(ins(0.0, lk.edge, 0.0, lk.edge));
    let top = if lk.form == Form::Touch {
        env.safe.top + 66.0
    } else {
        58.0
    };
    let col = Node::vstack(
        Align::Start,
        Some(12.0),
        vec![
            txt(cx, "Zuletzt hinzugefügt", lk.rail, colour::FONT, Some(1))
                .padding(ins(0.0, lk.edge, 0.0, 0.0)),
            Node::scroll(Axis::Horizontal, None, row).frame(
                None,
                Some(lk.poster.h + 40.0),
                Alignment::TOP_LEADING,
            ),
        ],
    )
    .padding(ins(top, 0.0, 0.0, 0.0));
    fill_frame(col, Alignment::TOP_LEADING)
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER)
}

impl<D: Clone + PartialEq + 'static> Pushed<D> {
    pub(crate) fn new(
        env: Env,
        cx: Cx,
        data: D,
        art: Rc<Art>,
        bare: bool,
        page: impl Fn(&D, &UiState, &Env, &Cx) -> Node + 'static,
    ) -> Self {
        let hub = Rc::clone(&art.hub);
        let hub_view = Rc::clone(&hub);
        let page: Rc<PageFn<D>> = Rc::new(page);
        let view = move |p: &PageParts<D>, env: &Env, cx: &Cx| {
            hub_view.begin_build();
            let layers = Layers::at(f64::from_bits(p.pos_bits), p.pages.len());
            let pages = p
                .pages
                .iter()
                .map(|&(serial, route)| {
                    let n = match route {
                        Route::Root if bare => Node::rect(Color::CLEAR, 0.0).key("bare-root"),
                        Route::Root => root_page(cx, env, &art),
                        Route::Page => page(&p.data, &p.sx, env, cx),
                    };
                    (serial, n)
                })
                .collect();
            stack_view(env, NavStyle::for_idiom(env.idiom), &layers, pages)
        };
        let nav = Nav::new(Route::Root, NavStyle::for_idiom(env.idiom));
        let sx = UiState::default();
        let parts = PageParts {
            pos_bits: 0.0_f64.to_bits(),
            pages: vec![(0, Route::Root)],
            data: data.clone(),
            sx: sx.clone(),
            pictures: 0,
        };
        let ui = Ui::new(view, parts, env, cx);
        let mut s = Pushed {
            ui,
            nav,
            data,
            sx,
            now: 0.0,
            hub,
            pointer: (0.0, 0.0),
            injected: Vec::new(),
            root_scrolls: usize::from(!bare),
        };
        s.sync();
        s
    }

    pub(crate) fn set_data(&mut self, d: D) {
        self.data = d;
    }

    pub(crate) fn sync(&mut self) {
        self.hub.frame(self.now);
        self.sx.focus = self.ui.focused().map(|f| f.0);
        let off = self.page_offset() as f32;
        // Touch: 30 pt to full strength; Mac `DetailHeader`: opacity = clamp((offset - 74) / 42).
        let t = if self.ui.env().idiom == swiftly_ui::Idiom::Desktop {
            (off - 74.0) / 42.0
        } else {
            off / 30.0
        };
        self.sx.header = if self.ui.env().idiom == swiftly_ui::Idiom::Desktop {
            (t.clamp(0.0, 1.0) * f32::from(crate::home::BAR_STEPS)).round() as u8
        } else {
            (t.clamp(0.0, 1.0) * 8.0).round() as u8
        };
        self.ui.set_parts(PageParts {
            pos_bits: self.nav.position().to_bits(),
            pages: self.nav.pages().map(|(s, r)| (s, *r)).collect(),
            data: self.data.clone(),
            sx: self.sx.clone(),
            pictures: self.hub.stamp(),
        });
    }

    /// The page offset of the title page (the scroll after the root list's; the demo root is a poster row with its own).
    pub(crate) fn page_offset(&self) -> f64 {
        if self.nav.depth() > 1 {
            self.ui
                .scroll_offsets()
                .get(self.root_scrolls)
                .copied()
                .unwrap_or(0.0)
        } else {
            0.0
        }
    }

    pub(crate) fn push(&mut self, now: f64) {
        if self.nav.depth() == 1 {
            self.nav.push(Route::Page, now);
        }
        self.sync();
    }

    pub(crate) fn pop(&mut self, now: f64) -> bool {
        let r = self.nav.pop(now);
        self.sync();
        r
    }

    /// The title page is fully in and nothing moves: the page below is hidden.
    pub(crate) fn covers(&self) -> bool {
        self.nav.depth() > 1 && !self.nav.is_animating()
    }

    /// While a title page slides in or out: how far the page below has moved back (points, negative) and its dim.
    pub(crate) fn below(&self) -> Option<(f32, f32)> {
        // Not `depth()`: that is already 1 while the page leaves, and the page behind must travel back into place then.
        if self.nav.pages().count() < 2 {
            return None;
        }
        let w = self.ui.env().size.w;
        let layers = Layers::at(self.nav.position(), self.nav.pages().count());
        (layers.below == Some(0)).then(|| {
            let at =
                swiftly_ui::nav::place(NavStyle::for_idiom(self.ui.env().idiom), &layers, 0, w);
            (at.x, at.dim)
        })
    }

    pub(crate) fn depth(&self) -> usize {
        self.nav.depth()
    }

    /// Takes the UI's events; the back swipe is handled here, taps are returned.
    pub(crate) fn drain(&mut self, now: f64) -> Vec<Action> {
        let width = self.ui.env().size.w;
        let mut taps = std::mem::take(&mut self.injected);
        for ev in self.ui.take_events() {
            if self.nav.handle(&ev, width, now) {
                continue;
            }
            if let UiEvent::Secondary { action, x, y } = &ev {
                self.pointer = (*x, *y);
                taps.push(*action);
            } else if let UiEvent::LongPress(a) = &ev {
                taps.push(*a);
            } else if let UiEvent::Tap(a) = ev {
                if a == Action::from("open") {
                    self.push(now);
                } else if a == Action::from("back") {
                    self.pop(now);
                } else {
                    taps.push(a);
                }
            }
        }
        taps
    }

    pub(crate) fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.ui.a11y_nodes()
    }

    pub(crate) fn ui(&mut self) -> &mut Ui<PageParts<D>> {
        &mut self.ui
    }

    pub(crate) fn frame_list(&mut self, now: f64) -> (DrawList, bool) {
        self.now = now;
        self.nav.update(now);
        self.sync();
        let mut list = self.ui.frame(now);
        self.hub.finish(&mut list);
        let wants = self.ui.needs_frame() || self.nav.is_animating() || self.hub.busy();
        (list, wants)
    }

    pub(crate) fn wants_frame(&self) -> bool {
        self.ui.needs_frame() || self.nav.is_animating() || self.hub.busy()
    }

    pub(crate) fn cx(&self) -> &Cx {
        self.ui.cx()
    }

    pub(crate) fn render(&self, list: &DrawList) -> RgbaImage {
        self.ui.render(list, Color::BLACK)
    }

    pub(crate) fn set_env(&mut self, env: Env) {
        self.ui.set_env(env);
    }
}

// ---- shared parts of a title page ------------------------------------------------------------------------------------

/// Direct Play flag, hint, rating text, age rating.
pub(crate) type Proof = (bool, Option<String>, Option<String>, Option<String>);

/// What the head of a title page shows; filled from `DetailVm` or `SeriesVm` parts.
#[derive(Clone, PartialEq, Default)]
pub(crate) struct Head {
    pub id: String,
    pub image: Option<swiftly_vm::ImageRef>,
    pub title: String,
    pub secondary: String,
    pub overview: Option<String>,
    pub directors: Vec<String>,
    pub label: String,
    pub enabled: bool,
    pub remaining: Option<String>,
    pub progress: Option<f32>,
    pub watched: bool,
    pub favorite: bool,
    pub fav_caption: String,
    pub download: Option<DownloadState>,
    pub proof: Option<Proof>,
    pub message: Option<String>,
    pub trailer: bool,
}

pub(crate) struct Kit<'a> {
    pub cx: &'a Cx,
    pub env: &'a Env,
    pub lk: Look,
    pub art: &'a Art,
    pub icons: &'a Icons,
}

/// A picture or text whose colour changes with the focus of the nearest focusable (tv buttons: white on the white pill).
fn focus_tint(mut n: Node, rest: Color, focused: Color) -> Node {
    n.paint = n
        .paint
        .into_iter()
        .map(|p| match p {
            Paint::Image { image, radius, .. } => Paint::FocusImage {
                image,
                rest,
                focused,
                radius,
            },
            Paint::Text {
                text,
                style,
                lines,
                align,
                ..
            } => Paint::FocusText {
                text,
                style,
                rest,
                focused,
                lines,
                align,
            },
            other => other,
        })
        .collect();
    n
}

/// A chip of the proof row. Mac `chip`: 26 high, 9 side, symbol 12 and text 12 semibold 5 apart, corner 8.
fn mark(
    k: &Kit,
    icon: Option<(&str, Color)>,
    s: &str,
    c: swiftly_design::Colour,
    w: u16,
    fill: Color,
) -> Node {
    let mac = k.lk.form == Form::Desktop;
    let mut kids = Vec::new();
    if let Some((i, tint)) = icon {
        kids.push(k.icons.node(i, if mac { 12.0 } else { 11.0 }, false, tint));
    }
    let w = if mac { 600 } else { w };
    kids.push(txt(
        k.cx,
        s,
        weight(k.lk.small, if mac { 12.0 } else { k.lk.small.size }, w),
        c,
        Some(1),
    ));
    let side = if mac { 9.0 } else { 8.0 };
    Node::hstack(Align::Center, Some(if mac { 5.0 } else { 4.0 }), kids)
        .padding(ins(0.0, side, 0.0, side))
        .frame(None, Some(26.0), Alignment::CENTER)
        .background(Node::rect(fill, 8.0), Alignment::CENTER)
}

/// The proof row (`ProofRow`): Direct Play mark or hint, rating, age rating; keeps its 26 pt even when empty.
pub(crate) fn proof_row(k: &Kit, h: &Head) -> Node {
    let mut kids = Vec::new();
    if let Some((direct, hint, rating, age)) = &h.proof {
        let mac = k.lk.form == Form::Desktop;
        let area = color(colour::AREA);
        // Mac: accent chip on a quiet accent surface, warning on 15 % warning, rating and age white on 8 % white.
        let quiet = |c: swiftly_design::Colour| if mac { rgba(c, 0.15) } else { area };
        let plain = if mac {
            Color::new(1.0, 1.0, 1.0, 0.08)
        } else {
            area
        };
        let (rate_c, rate_w) = if mac {
            (colour::FONT, 600)
        } else {
            (colour::FONT_QUIET, 600)
        };
        if *direct {
            kids.push(mark(
                k,
                Some(("check", color(colour::MARK_ACCENT))),
                "Direct Play",
                colour::MARK_ACCENT,
                600,
                quiet(colour::MARK_ACCENT),
            ));
        } else if let Some(hint) = hint {
            let hc = if mac {
                colour::ORIGINAL_WARNING
            } else {
                colour::FONT
            };
            kids.push(mark(
                k,
                Some(("warning.fill", color(colour::ORIGINAL_WARNING))),
                hint,
                hc,
                if mac { 600 } else { 400 },
                quiet(colour::ORIGINAL_WARNING),
            ));
        }
        if let Some(r) = rating {
            kids.push(mark(
                k,
                Some(("star.fill", color(rate_c))),
                r,
                rate_c,
                rate_w,
                plain,
            ));
        }
        if let Some(a) = age {
            kids.push(mark(k, None, a, rate_c, rate_w, plain));
        }
    }
    Node::hstack(Align::Center, Some(8.0), kids).frame(None, Some(26.0), Alignment::LEADING)
}

/// The primary button: white surface, label left, play triangle right (`PrimaryButtonStyle`); tv uses the focus pill.
pub(crate) fn play_button(k: &Kit, h: &Head, action: &str) -> Node {
    let lk = &k.lk;
    let on = h.enabled;
    let (fg, bg) = if on {
        (colour::REASON, colour::FONT)
    } else {
        (colour::FONT_VERY_QUIET, colour::AREA)
    };
    if lk.form == Form::Tv {
        // `ThemedButtonStyle`: 76 high, 40 side, corner 16, white 10 % at rest, white and `reason` text when focused.
        let rest = if on {
            colour::FONT
        } else {
            colour::FONT_VERY_QUIET
        };
        let label = focus_tint(
            txt(k.cx, &h.label, tv::text::BUTTON, rest, Some(1)),
            color(rest),
            color(colour::REASON),
        );
        let tri = focus_tint(
            k.icons.node("play.fill", 30.0, false, color(rest)),
            color(rest),
            color(colour::REASON),
        );
        let row = Node::hstack(Align::Center, Some(10.0), vec![tri, label])
            .padding(ins(0.0, 40.0, 0.0, 40.0))
            .frame(None, Some(tv::BUTTON_HEIGHT), Alignment::CENTER);
        let surface = Node::rect(
            if on {
                Color::new(1.0, 1.0, 1.0, swiftly_ui::tuning::FOCUS_BUTTON_REST_ALPHA)
            } else {
                color(colour::AREA)
            },
            16.0,
        )
        .paint(Paint::FocusFill {
            color: Color::WHITE,
            radius: 16.0,
        });
        let n = row
            .background(surface, Alignment::CENTER)
            .key("play")
            .on_tap(Action::from(action));
        return n.focusable(focus_id("play"), Some(FocusLook::tile(16.0)));
    }
    if lk.form == Form::Desktop {
        // `DetailPlayButton`: 280 x 56, white, corner 10, play 18 then the label 17 semibold, 10 apart, centred.
        let tri = k.icons.node("play.fill", 18.0, false, color(fg));
        let label = txt(k.cx, &h.label, weight(lk.body, 17.0, 600), fg, Some(1));
        let row = Node::hstack(Align::Center, Some(10.0), vec![tri, label]).frame(
            Some(desktop::DETAIL_PRIMARY_WIDTH),
            Some(desktop::DETAIL_BUTTON_HEIGHT),
            Alignment::CENTER,
        );
        // Hover: white 88 % (a 12 % ground surface over the white); press 0.97 / 0.85; right click = the tile menu.
        let n = row
            .background(Node::rect(color(bg), 10.0), Alignment::CENTER)
            .key("play")
            .on_tap(Action::from(action))
            .on_secondary(Action::from("play-menu"));
        return if on {
            n.hover_surface(rgba(colour::REASON, 0.12), 10.0)
                .press_style(PressStyle::Button)
        } else {
            n.disabled(false).press_style(PressStyle::None)
        };
    }
    let (w, height, label_st): (Option<f32>, f32, _) =
        (None, touch::CONTROL_HEIGHT, weight(lk.body, 17.0, 600));
    let label = txt(k.cx, &h.label, label_st, fg, Some(1)).layout_priority(1.0);
    let tri = k.icons.node("play.fill", 12.0, false, color(fg));
    let row = Node::hstack(Align::Center, Some(12.0), vec![label, Node::spacer(), tri])
        .padding(ins(0.0, 20.0, 0.0, 18.0));
    let row = match w {
        Some(w) => row.frame(Some(w), Some(height), Alignment::CENTER),
        None => wide(
            row.frame(None, Some(height), Alignment::CENTER),
            Alignment::CENTER,
        ),
    };
    row.background(Node::rect(color(bg), 10.0), Alignment::CENTER)
        .key("play")
        .on_tap(Action::from(action))
}

/// Remaining time and the 4 pt progress bar under the button.
pub(crate) fn resume_info(k: &Kit, h: &Head, width: Option<f32>) -> Vec<Node> {
    let mut v = Vec::new();
    if let Some(rest) = &h.remaining {
        let c = if k.lk.form == Form::Desktop {
            colour::FONT_VERY_QUIET
        } else {
            colour::FONT_QUIET
        };
        v.push(txt(k.cx, rest, weight(k.lk.small, 12.0, 400), c, Some(1)));
    }
    if let Some(p) = h.progress.filter(|p| *p > 0.0) {
        let p = p.clamp(0.0, 1.0);
        let w = width.unwrap_or(k.env.size.w - 2.0 * k.lk.edge);
        let bar = Node::zstack(
            Alignment::LEADING,
            vec![
                Node::rect(Color::new(1.0, 1.0, 1.0, 0.18), 2.0).frame(
                    Some(w),
                    Some(4.0),
                    Alignment::CENTER,
                ),
                Node::rect(color(colour::MARK_ACCENT), 2.0).frame(
                    Some(w * p),
                    Some(4.0),
                    Alignment::CENTER,
                ),
            ],
        );
        v.push(bar);
    }
    v
}

fn action_button(k: &Kit, key: &str, icon: &str, caption: &str, active: bool) -> Node {
    let lk = &k.lk;
    let tint = if active {
        colour::MARK_ACCENT
    } else {
        colour::FONT
    };
    match lk.form {
        Form::Touch => {
            // Icon 22 over the caption, no surface; the row distributes the fields (`ActionButton`, stretches).
            let ic = k
                .icons
                .node(icon, 22.0, !icon.ends_with(".fill"), color(tint))
                .frame(None, Some(36.0), Alignment::CENTER);
            let cap = txt_center(
                k.cx,
                caption,
                weight(lk.small, 12.0, 400),
                if active {
                    colour::MARK_ACCENT
                } else {
                    colour::FONT_QUIET
                },
                1,
            );
            wide(
                Node::vstack(Align::Center, Some(2.0), vec![ic, cap]),
                Alignment::CENTER,
            )
            .key(key)
            .on_tap(Action::from(key))
        }
        Form::Desktop => {
            // `DetailIconButton`: 48 x 56, glyph only (no field), 85 % white at rest, accent when on.
            let c = if active {
                color(colour::MARK_ACCENT)
            } else {
                rgba(colour::FONT, 0.85)
            };
            k.icons
                .node(icon, 22.0, !icon.ends_with(".fill"), c)
                .frame(Some(48.0), Some(56.0), Alignment::CENTER)
                .a11y_label(swiftly_ui::a11y::Role::Button, caption)
                .key(key)
                .on_tap(Action::from(key))
                .tooltip(caption)
                .press_style(PressStyle::Button)
        }
        Form::Tv => {
            // `ThemedButtonStyle(onlySymbol)`: 76 square, corner 16, white 10 % at rest, `reason` glyph when focused.
            let ic = focus_tint(
                k.icons
                    .node(icon, 30.0, !icon.ends_with(".fill"), color(tint)),
                color(tint),
                color(colour::REASON),
            )
            .frame(Some(76.0), Some(76.0), Alignment::CENTER);
            let surface = Node::rect(
                Color::new(1.0, 1.0, 1.0, swiftly_ui::tuning::FOCUS_BUTTON_REST_ALPHA),
                16.0,
            )
            .paint(Paint::FocusFill {
                color: Color::WHITE,
                radius: 16.0,
            });
            ic.background(surface, Alignment::CENTER)
                .a11y_label(swiftly_ui::a11y::Role::Button, caption)
                .key(key)
                .on_tap(Action::from(key))
                .focusable(focus_id(key), Some(FocusLook::tile(16.0)))
        }
    }
}

/// The row of small actions: watchlist, download, trailer, watched, more.
pub(crate) fn action_rail(k: &Kit, h: &Head) -> Node {
    let mut kids = vec![action_button(
        k,
        "favorite",
        if h.favorite {
            "bookmark-simple.fill"
        } else {
            "bookmark-simple"
        },
        &h.fav_caption,
        h.favorite,
    )];
    // Mac and tv keep the download in the More list; only touch has the "Laden" field.
    let state = h.download.filter(|_| k.lk.form == Form::Touch);
    if let Some(state) = state {
        let (icon, active) = match state {
            DownloadState::Ready => ("arrow-circle-down.fill", true),
            _ => ("arrow-circle-down", false),
        };
        kids.push(action_button(k, "download", icon, "Laden", active));
    }
    if h.trailer && k.lk.form != Form::Tv {
        kids.push(action_button(
            k,
            "trailer",
            "monitor-play",
            "Trailer",
            false,
        ));
    }
    // tvOS: "Gesehen" sits in the action panel, not in the row.
    if k.lk.form != Form::Tv {
        kids.push(action_button(
            k,
            "watched",
            if h.watched {
                "check-circle.fill"
            } else {
                "check-circle"
            },
            "Gesehen",
            h.watched,
        ));
    }
    kids.push(action_button(k, "more", "dots-three", "Mehr", false));
    let gap = match k.lk.form {
        Form::Touch => 8.0,
        Form::Desktop => 4.0,
        Form::Tv => 24.0,
    };
    let row = Node::hstack(Align::Start, Some(gap), kids);
    if k.lk.form == Form::Touch {
        wide(row, Alignment::LEADING)
    } else {
        row
    }
}

/// The overview, collapsed to three lines until tapped, and the "Regie" line.
pub(crate) fn description(k: &Kit, h: &Head, open: bool) -> Option<Node> {
    let text = h.overview.as_ref()?;
    let mac = k.lk.form == Form::Desktop;
    let lines = if open || mac { None } else { Some(3) };
    let width = match k.lk.form {
        Form::Touch => k.env.size.w - 2.0 * k.lk.edge,
        Form::Desktop => 620.0,
        Form::Tv => 900.0,
    };
    // Mac `overview`: 14, line spacing 4.5 (pitch about 1.55 of the size), cut by characters at 150 with an accent "Mehr"
    // right behind the last word; one tap opens the whole text.
    let style = if mac {
        TextStyle {
            line_height: swiftly_text::LineHeight::Points(14.0 * 1.21 + 4.5),
            ..TextStyle::from(weight(k.lk.body, 14.0, 400))
        }
    } else {
        TextStyle::from(k.lk.body)
    };
    let long = mac && text.chars().count() > 170;
    let shown: String = if long && !open {
        let head: String = text.chars().take(150).collect();
        let clean = head.rfind(' ').map_or(head.as_str(), |i| &head[..i]);
        format!("{clean}\u{2026} ")
    } else {
        text.clone()
    };
    let mut body = Node::text(
        k.cx,
        &shown,
        &style,
        color(colour::FONT_QUIET),
        lines,
        swiftly_text::Align::Start,
    )
    .frame(Some(width), None, Alignment::LEADING);
    if long && !open {
        let l = k.cx.text.borrow_mut().layout(
            &shown,
            &style,
            Some(width),
            None,
            swiftly_text::Align::Start,
        );
        if let Some(last) = l.lines().last() {
            let more_style = TextStyle::from(weight(k.lk.body, 14.0, 600));
            let more = Node::text(
                k.cx,
                "Mehr",
                &more_style,
                color(colour::MARK_ACCENT),
                Some(1),
                swiftly_text::Align::Start,
            );
            // Swift sets "Mehr" as running text, so a word that does not fit on the last line wraps to a new one.
            let word =
                k.cx.text
                    .borrow_mut()
                    .layout("Mehr", &more_style, None, None, swiftly_text::Align::Start)
                    .lines()
                    .last()
                    .map_or(0.0, |w| w.width);
            if last.width + 4.0 + word > width {
                let pitch = 14.0 * 1.21 + 4.5;
                let rows = l.lines().len() as f32 + 1.0;
                body = body
                    .frame(Some(width), Some(rows * pitch), Alignment::TOP_LEADING)
                    .overlay(
                        more.padding(ins(last.top + pitch + 2.0, 0.0, 0.0, 0.0)),
                        Alignment::TOP_LEADING,
                    );
            } else {
                body = body.overlay(
                    more.padding(ins(last.top + 2.0, last.width + 4.0, 0.0, 0.0)),
                    Alignment::TOP_LEADING,
                );
            }
        }
    }
    let mut kids = vec![body.key("overview").on_tap(Action::from("overview"))];
    if !h.directors.is_empty() {
        let s = weight(k.lk.small, if mac { 13.0 } else { 12.0 }, 400);
        kids.push(Node::hstack(
            Align::Start,
            Some(if mac { 8.0 } else { 5.0 }),
            vec![
                txt(
                    k.cx,
                    "Regie",
                    s,
                    if mac {
                        colour::FONT_VERY_QUIET
                    } else {
                        colour::FONT_QUIET
                    },
                    Some(1),
                ),
                txt(k.cx, &h.directors.join(", "), s, colour::FONT, Some(1)),
            ],
        ));
    }
    Some(Node::vstack(Align::Start, Some(8.0), kids))
}

fn gradient(from: [f32; 2], to: [f32; 2], a: Color, b: Color, w: f32, h: f32) -> Node {
    Node::rect(a, 0.0)
        .paint(Paint::Linear {
            gradient: LinearGradient {
                start: a,
                end: b,
                from,
                to,
            },
            radius: 0.0,
        })
        .frame(Some(w), Some(h), Alignment::CENTER)
}

/// The horizontal backdrop mask of the Mac: alpha at x (fraction of the width), `Backdrop.swift:59-85`.
pub(crate) const BACKDROP_H: [(f32, f32); 8] = [
    (0.0, 0.0),
    (0.15, 0.05),
    (0.29, 0.22),
    (0.45, 0.50),
    (0.57, 0.75),
    (0.70, 0.90),
    (0.85, 0.98),
    (1.0, 1.0),
];
/// The vertical mask: opaque to half the height, then running out.
pub(crate) const BACKDROP_V: [(f32, f32); 8] = [
    (0.0, 1.0),
    (0.50, 1.0),
    (0.60, 0.88),
    (0.70, 0.62),
    (0.80, 0.34),
    (0.89, 0.14),
    (0.95, 0.04),
    (1.0, 0.0),
];

pub(crate) fn curve_at(c: &[(f32, f32)], t: f32) -> f32 {
    c.windows(2)
        .find(|p| t <= p[1].0)
        .map_or(c[c.len() - 1].1, |p| {
            p[0].1 + (p[1].1 - p[0].1) * ((t - p[0].0) / (p[1].0 - p[0].0)).clamp(0.0, 1.0)
        })
}

/// The page ground (mood colour) at `(x fraction of the page, y points)`; the plain ground without hues.
pub(crate) fn mood_sampler(tones: &[f64], since: f32) -> impl Fn(f32, f32) -> Color {
    let ground = color(colour::REASON);
    let mesh =
        (!tones.is_empty()).then(|| swiftly_images::mood::detail_mesh(tones, f64::from(since)));
    let total = since + swiftly_images::mood::RUN_OUT as f32;
    move |xf: f32, y: f32| {
        let Some(mesh) = &mesh else { return ground };
        let (rows, cols) = (mesh.rows, mesh.columns);
        let at = |r: usize, c: usize| mesh.points[r * cols + c].color;
        let r = (0..rows - 1)
            .find(|&r| y <= mesh.points[(r + 1) * cols].y * total)
            .unwrap_or(rows - 2);
        let (ya, yb) = (
            mesh.points[r * cols].y * total,
            mesh.points[(r + 1) * cols].y * total,
        );
        let t = if yb > ya {
            f64::from(((y - ya) / (yb - ya)).clamp(0.0, 1.0))
        } else {
            0.0
        };
        let cf = (xf.clamp(0.0, 1.0) * (cols - 1) as f32).min((cols - 1) as f32 - 0.001);
        let (c, u) = (cf.floor() as usize, f64::from(cf.fract()));
        let mix = |a: f64, b: f64, f: f64| a + (b - a) * f;
        let pick = |c: usize| {
            let (p, q) = (at(r, c), at(r + 1, c));
            (mix(p.r, q.r, t), mix(p.g, q.g, t), mix(p.b, q.b, t))
        };
        let (l, rr) = (pick(c), pick(c + 1));
        Color::new(
            mix(l.0, rr.0, u) as f32,
            mix(l.1, rr.1, u) as f32,
            mix(l.2, rr.2, u) as f32,
            1.0,
        )
    }
}

/// The Mac backdrop: the picture right aligned and 454 high, covered by the page colour with alpha `1 - h(x) * v(y)`.
fn desktop_backdrop(k: &Kit, h: &Head, w: f32) -> Node {
    let bw = (w * 0.62).max(520.0).min(w);
    let img = k
        .art
        .node_for(h.image.as_ref(), true, &h.id, bw, HERO_DESKTOP, 0.0);
    let tones = k.art.tones_for(h.image.as_ref(), &h.id);
    let sample = mood_sampler(&tones, HERO_DESKTOP);
    let band = 6.0_f32;
    let n = (HERO_DESKTOP / band).ceil() as usize;
    let bands: Vec<Node> = (0..n)
        .map(|i| {
            let (y0, y1) = (i as f32 * band, ((i + 1) as f32 * band).min(HERO_DESKTOP));
            let ym = (y0 + y1) * 0.5;
            let v = curve_at(&BACKDROP_V, ym / HERO_DESKTOP);
            let stops: Vec<(f32, Color)> = BACKDROP_H
                .iter()
                .map(|&(x, a)| {
                    let c = sample((w - bw + x * bw) / w, ym);
                    (x, Color::new(c.r, c.g, c.b, 1.0 - a * v))
                })
                .collect();
            Node::rect(Color::CLEAR, 0.0)
                .paint(Paint::Stops {
                    stops,
                    vertical: false,
                    radius: 0.0,
                })
                .frame(Some(bw), Some(y1 - y0), Alignment::CENTER)
        })
        .collect();
    let covered = img.overlay(
        Node::vstack(Align::Start, Some(0.0), bands),
        Alignment::TOP_LEADING,
    );
    Node::hstack(Align::Start, Some(0.0), vec![Node::spacer(), covered]).frame(
        Some(w),
        Some(HERO_DESKTOP),
        Alignment::TOP_LEADING,
    )
}

/// The hero: picture with the page's ground running out at the foot, title and the quiet line on it (touch, desktop);
/// the tv hero is the backdrop on the trailing side with the text block on the left.
/// Design name: DetailHero
pub(crate) fn hero(k: &Kit, h: &Head, buttons: Vec<Node>) -> Node {
    let lk = &k.lk;
    let ground = colour::REASON;
    let clear = rgba(ground, 0.0);
    let w = k.env.size.w;
    match lk.form {
        Form::Touch => {
            let height = if lk.pad { 420.0 } else { HERO_TOUCH };
            // `HeroRunOut`: the ground with the coverage steps, and the mood mesh of the rows above the foot laid over it
            // with the same coverage.
            let cover = [
                (0.0_f32, 0.0_f32),
                (0.32, 0.28),
                (0.56, 0.58),
                (0.78, 0.85),
                (1.0, 1.0),
            ];
            let coverage = move |f: f32| -> f32 {
                cover.windows(2).find(|p| f <= p[1].0).map_or(1.0, |p| {
                    p[0].1 + (p[1].1 - p[0].1) * (f - p[0].0) / (p[1].0 - p[0].0)
                })
            };
            let stops: Vec<(f32, f32)> = cover.iter().map(|&(loc, op)| (loc, op)).collect();
            let mut run = ramp(ground, &stops, 1.0, w, 240.0);
            let tones = k.art.tones_for(h.image.as_ref(), &h.id);
            if !tones.is_empty() {
                let since = height;
                let mood = mood_strips(
                    &tones,
                    since,
                    (since - 240.0, since),
                    since - 240.0,
                    w,
                    move |y| coverage((y - (since - 240.0)) / 240.0),
                );
                run = run.overlay(mood, Alignment::TOP_LEADING);
            }
            let info = Node::vstack(
                Align::Start,
                Some(4.0),
                vec![
                    txt(
                        k.cx,
                        &h.title,
                        weight(touch::text::TITLE_LARGE, 30.0, 700),
                        colour::FONT,
                        Some(2),
                    ),
                    txt(
                        k.cx,
                        &h.secondary,
                        weight(lk.small, 12.0, 400),
                        colour::FONT_QUIET,
                        Some(1),
                    ),
                ],
            )
            .padding(ins(0.0, lk.edge, 16.0, lk.edge));
            let img = k
                .art
                .node_for(h.image.as_ref(), true, &h.id, w, height, 0.0);
            img.overlay(run, Alignment::BOTTOM)
                .overlay(info, Alignment::BOTTOM_LEADING)
        }
        Form::Desktop => {
            // `DetailHero`: the block sits at 36 / 172; the backdrop is right aligned, `max(62 % page, 520)` wide and 454 high,
            // faded by two multiplied masks (`Backdrop.swift:59-85`), over the mood colour of the page.
            let backdrop = desktop_backdrop(k, h, w);
            let mut col = vec![
                txt(
                    k.cx,
                    &h.title,
                    weight(desktop::text::DETAIL_TITLE, 44.0, 800),
                    colour::FONT,
                    Some(1),
                )
                .frame(Some(700.0), Some(44.0), Alignment::LEADING),
                txt(
                    k.cx,
                    &h.secondary,
                    weight(lk.small, 14.0, 400),
                    colour::FONT_QUIET,
                    Some(1),
                )
                .padding(ins(12.0, 0.0, 0.0, 0.0)),
            ];
            col.extend(buttons);
            let block = Node::vstack(Align::Start, Some(0.0), col)
                .frame(Some(700.0), None, Alignment::TOP_LEADING)
                .padding(ins(desktop::DETAIL_TOP, lk.edge, 0.0, 0.0));
            block
                .frame(Some(w), None, Alignment::TOP_LEADING)
                .background(backdrop, Alignment::TOP_LEADING)
        }
        Form::Tv => {
            let bw = 1280.0;
            let img = k
                .art
                .node_for(h.image.as_ref(), true, &h.id, bw, tv::HERO_HEIGHT, 0.0);
            let side = gradient(
                [0.0, 0.5],
                [0.45, 0.5],
                color(ground),
                clear,
                bw,
                tv::HERO_HEIGHT,
            );
            let foot = gradient(
                [0.5, 0.55],
                [0.5, 1.0],
                clear,
                color(ground),
                bw,
                tv::HERO_HEIGHT,
            );
            let back = img
                .overlay(side, Alignment::TOP_LEADING)
                .overlay(foot, Alignment::TOP_LEADING);
            let right = Node::hstack(Align::Start, Some(0.0), vec![Node::spacer(), back]).frame(
                None,
                Some(tv::HERO_HEIGHT),
                Alignment::TOP_LEADING,
            );
            let mut col = vec![
                txt(
                    k.cx,
                    &h.title,
                    tv::text::PLAYER_TITLE,
                    colour::FONT,
                    Some(1),
                ),
                txt(
                    k.cx,
                    &h.secondary,
                    tv::text::BODY,
                    colour::FONT_QUIET,
                    Some(1),
                )
                .padding(ins(8.0, 0.0, 0.0, 0.0)),
            ];
            col.extend(buttons);
            let info = Node::vstack(Align::Start, Some(0.0), col)
                .frame(Some(1000.0), None, Alignment::TOP_LEADING)
                .padding(ins(tv::CONTENT_TOP, lk.edge, 0.0, 0.0));
            fill_frame(right, Alignment::TOP_LEADING)
                .frame(None, Some(tv::HERO_HEIGHT + 120.0), Alignment::TOP_LEADING)
                .overlay(info, Alignment::TOP_LEADING)
        }
    }
}

/// The body under the hero on touch: proof row, button + action row, description (`ItemDetailView.body`).
pub(crate) fn body_touch(k: &Kit, h: &Head, open: bool) -> Node {
    let mut btn = vec![wide(play_button(k, h, "play"), Alignment::CENTER)];
    btn.extend(resume_info(k, h, None));
    let mut block = vec![
        proof_row(k, h),
        Node::vstack(
            Align::Start,
            Some(touch::ACTION_GAP),
            vec![
                Node::vstack(Align::Start, Some(8.0), btn),
                action_rail(k, h),
            ],
        )
        .padding(ins(0.0, 0.0, 8.0, 0.0)),
    ];
    if let Some(d) = description(k, h, open) {
        block.push(d);
    }
    Node::vstack(Align::Start, Some(touch::BLOCK_GAP), block)
        .padding(ins(4.0, k.lk.edge, 0.0, k.lk.edge))
}

/// The button blocks inside the Mac / tv hero (chips, button row, progress, overview).
pub(crate) fn hero_buttons(k: &Kit, h: &Head, open: bool) -> Vec<Node> {
    let lk = &k.lk;
    let tvf = lk.form == Form::Tv;
    let primary_w = if tvf {
        None
    } else {
        Some(desktop::DETAIL_PRIMARY_WIDTH)
    };
    let mut v = vec![
        proof_row(k, h).padding(ins(if tvf { 24.0 } else { 14.0 }, 0.0, 0.0, 0.0)),
        // Mac: play, an 8 pt spacer, then the icons, 4 apart (`DetailPageMetric` button rail).
        Node::hstack(
            Align::Center,
            Some(if tvf { 24.0 } else { 4.0 }),
            if tvf {
                vec![play_button(k, h, "play"), action_rail(k, h)]
            } else {
                vec![
                    play_button(k, h, "play"),
                    Node::fixed(8.0, 1.0),
                    action_rail(k, h),
                ]
            },
        )
        .padding(ins(if tvf { 32.0 } else { 20.0 }, 0.0, 0.0, 0.0)),
    ];
    let info = resume_info(k, h, primary_w.or(Some(420.0)));
    if !info.is_empty() {
        v.push(
            Node::vstack(Align::Start, Some(6.0), info.into_iter().rev().collect())
                .padding(ins(16.0, 0.0, 0.0, 0.0)),
        );
    }
    if !tvf && let Some(m) = &h.message {
        // `HintStrip`: a capsule 34 high on `raised` with a 1 px `margin` border; the screen withdraws it after 3 s.
        let strip = txt(k.cx, m, weight(k.lk.body, 15.0, 400), colour::FONT, Some(1))
            .padding(ins(0.0, 14.0, 0.0, 14.0))
            .frame(None, Some(34.0), Alignment::CENTER)
            .background(
                Node::rect(color(colour::RAISED), 17.0).paint(Paint::Stroke {
                    color: color(colour::MARGIN),
                    width: 1.0,
                    radius: 17.0,
                }),
                Alignment::CENTER,
            )
            .key("message")
            .on_tap(Action::from("dismiss"))
            .appear_from(0.97, 0.0)
            .exit_to(0.97, 0.0);
        v.push(strip.padding(ins(12.0, 0.0, 0.0, 0.0)));
    }
    if !tvf && let Some(d) = description(k, h, open) {
        v.push(d.padding(ins(36.0, 0.0, 0.0, 0.0)));
    }
    v
}

// ---- rails -----------------------------------------------------------------------------------------------------------

pub(crate) fn rail_title(k: &Kit, s: &str) -> Node {
    txt(k.cx, s, k.lk.rail, colour::FONT, Some(1))
        .a11y(swiftly_ui::a11y::A11yNode::new("", swiftly_ui::a11y::Role::Heading, s).with_level(2))
}

fn h_scroll(k: &Kit, kids: Vec<Node>, spacing: f32, height: f32) -> Node {
    let headroom = if k.lk.form == Form::Tv {
        swiftly_ui::tuning::FOCUS_HEADROOM_PT
    } else {
        0.0
    };
    let strip =
        Node::hstack(Align::Start, Some(spacing), kids).padding(ins(headroom, 0.0, headroom, 0.0));
    Node::scroll(
        Axis::Horizontal,
        None,
        strip.padding(ins(0.0, 0.0, 0.0, 0.0)),
    )
    .frame(None, Some(height + 2.0 * headroom), Alignment::TOP_LEADING)
}

fn focus_section(n: Node, k: &Kit, key: &str) -> Node {
    if k.lk.form == Form::Tv {
        n.focus_scope(swiftly_ui::ScopeSpec::section(focus_id(key)))
    } else {
        n
    }
}

/// A section: heading over a horizontal row, both inset by the page edge.
pub(crate) fn segment(
    k: &Kit,
    key: &str,
    title: &str,
    kids: Vec<Node>,
    spacing: f32,
    height: f32,
) -> Node {
    let edge = k.lk.edge;
    let row = Node::hstack(Align::Start, Some(spacing), kids).padding(ins(0.0, edge, 0.0, edge));
    let headroom = if k.lk.form == Form::Tv {
        swiftly_ui::tuning::FOCUS_HEADROOM_PT
    } else {
        0.0
    };
    let scroll = Node::scroll(
        Axis::Horizontal,
        None,
        row.padding(ins(headroom, 0.0, headroom, 0.0)),
    )
    .frame(None, Some(height + 2.0 * headroom), Alignment::TOP_LEADING);
    let _ = h_scroll;
    let n = Node::vstack(
        Align::Start,
        Some(if k.lk.form == Form::Tv { 20.0 } else { 12.0 }),
        vec![
            rail_title(k, title)
                .frame(
                    Some((k.env.size.w - 2.0 * edge).max(40.0)),
                    None,
                    Alignment::LEADING,
                )
                .padding(ins(0.0, edge, 0.0, edge)),
            scroll,
        ],
    )
    .frame(Some(k.env.size.w), None, Alignment::TOP_LEADING)
    .key(key);
    focus_section(n, k, key)
}

pub(crate) fn poster_tile(k: &Kit, t: &Tile, key: &str, landscape: bool) -> Node {
    let lk = &k.lk;
    let size = if landscape {
        Size::new(lk.poster.h * 16.0 / 9.0, lk.poster.h * 0.72)
    } else {
        lk.poster
    };
    let img = k
        .art
        .node_for(
            t.image.as_ref(),
            landscape,
            &t.id,
            size.w,
            size.h,
            lk.corner,
        )
        .paint(Paint::Stroke {
            color: color(colour::TILE_BORDER),
            width: 1.0,
            radius: lk.corner,
        });
    let mut lines = vec![txt(k.cx, &t.title, lk.tile, colour::FONT, Some(1)).frame(
        Some(size.w),
        None,
        Alignment::LEADING,
    )];
    if let Some(s) = &t.subtitle {
        lines.push(
            txt(k.cx, s, lk.small, colour::FONT_VERY_QUIET, Some(1)).frame(
                Some(size.w),
                None,
                Alignment::LEADING,
            ),
        );
    }
    let mut n = Node::vstack(
        Align::Start,
        Some(8.0),
        vec![img, Node::vstack(Align::Start, Some(2.0), lines)],
    )
    .key(key)
    .on_tap(Action::from(format!("tile:{}", t.id).as_str()))
    .on_long_press(Action::from(format!("tilemenu:{}", t.id).as_str()));
    if lk.form == Form::Desktop {
        // Mac `PosterCell`: hover grows the picture 1.04 (`timeFloat`), a right click opens the tile menu.
        n = n
            .hover_scale(swiftly_ui::feel::HOVER_TILE_SCALE)
            .on_secondary(Action::from(format!("tilemenu:{}", t.id).as_str()));
    }
    if lk.form == Form::Tv {
        n = n.focusable(focus_id(key), Some(FocusLook::tile(lk.corner)));
    }
    n
}

fn tile_row_height(k: &Kit, landscape: bool) -> f32 {
    let h = if landscape {
        k.lk.poster.h * 0.72
    } else {
        k.lk.poster.h
    };
    h + 8.0 + 36.0
}

pub(crate) fn tile_rail(k: &Kit, key: &str, title: &str, tiles: &[Tile], landscape: bool) -> Node {
    let kids = tiles
        .iter()
        .enumerate()
        .map(|(i, t)| poster_tile(k, t, &format!("{key}:{i}"), landscape))
        .collect();
    segment(
        k,
        key,
        title,
        kids,
        k.lk.tile_gap,
        tile_row_height(k, landscape),
    )
}

pub(crate) fn cast_rail(k: &Kit, cast: &[CastTile]) -> Node {
    if k.lk.form == Form::Desktop {
        // Mac `HeaderImage`: 84 circle, name 13 semibold (2 lines) and role 12 very quiet under it, left aligned, 22 apart.
        let kids = cast
            .iter()
            .enumerate()
            .map(|(i, c)| {
                let key = format!("cast:{i}");
                let mut lines = vec![txt(
                    k.cx,
                    &c.name,
                    weight(k.lk.small, 13.0, 600),
                    colour::FONT,
                    Some(2),
                )];
                if let Some(r) = c.role.as_ref().filter(|r| !r.is_empty()) {
                    lines.push(txt(
                        k.cx,
                        r,
                        weight(k.lk.small, 12.0, 400),
                        colour::FONT_VERY_QUIET,
                        Some(1),
                    ));
                }
                Node::vstack(
                    Align::Start,
                    Some(7.0),
                    vec![
                        k.art
                            .node_for(c.image.as_ref(), false, &c.id, 84.0, 84.0, 42.0),
                        Node::vstack(Align::Start, Some(1.0), lines),
                    ],
                )
                .frame(Some(84.0), None, Alignment::TOP_LEADING)
                .key(key.as_str())
                .on_tap(Action::from(format!("person:{}", c.id).as_str()))
            })
            .collect();
        return segment(
            k,
            "cast",
            "Besetzung",
            kids,
            22.0,
            84.0 + 7.0 + 15.0 * 2.0 + 14.0,
        );
    }
    let size = if k.lk.form == Form::Tv {
        150.0
    } else {
        touch::CAST_SIZE
    };
    let kids = cast
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let key = format!("cast:{i}");
            let mut lines = vec![txt_center(k.cx, &c.name, k.lk.tile, colour::FONT, 2)];
            if let Some(r) = c.role.as_ref().filter(|r| !r.is_empty()) {
                lines.push(txt_center(k.cx, r, k.lk.small, colour::FONT_QUIET, 1));
            }
            let mut n = Node::vstack(
                Align::Center,
                Some(8.0),
                vec![
                    k.art
                        .node_for(c.image.as_ref(), false, &c.id, size, size, size / 2.0),
                    Node::vstack(Align::Center, Some(2.0), lines),
                ],
            )
            .frame(
                Some(size + if k.lk.form == Form::Tv { 30.0 } else { 0.0 }),
                None,
                Alignment::TOP,
            )
            .key(key.as_str())
            .on_tap(Action::from(format!("person:{}", c.id).as_str()));
            if k.lk.form == Form::Tv {
                n = n.focusable(focus_id(key.as_str()), Some(FocusLook::tile(size / 2.0)));
            }
            n
        })
        .collect();
    segment(
        k,
        "cast",
        "Besetzung",
        kids,
        if k.lk.form == Form::Tv { 30.0 } else { 14.0 },
        size + 8.0 + 70.0,
    )
}

/// "Datei": hairline-separated rows, label left, value right (`FileRow`, min height 36).
/// Design name: FileRow
pub(crate) fn file_excerpt(k: &Kit, b: &BottomPart) -> Option<Node> {
    let f = b.file.as_ref()?;
    if k.lk.form == Form::Desktop {
        // Mac `FileRow`: the values in one line, 22 apart, small very quiet under a hairline, 14 below it.
        let vals: Vec<Node> = f
            .rows
            .iter()
            .map(|r| txt(k.cx, &r.value, k.lk.small, colour::FONT_VERY_QUIET, Some(1)))
            .collect();
        let row = Node::hstack(Align::Start, Some(22.0), vals).padding(ins(14.0, 0.0, 0.0, 0.0));
        let line = Node::rect(color(colour::LINE), 0.0).frame(None, Some(1.0), Alignment::CENTER);
        return Some(
            wide(row, Alignment::LEADING)
                .overlay(wide(line, Alignment::CENTER), Alignment::TOP)
                .padding(ins(0.0, k.lk.edge, 0.0, k.lk.edge)),
        );
    }
    let line = || Node::rect(color(colour::LINE), 0.0).frame(None, Some(1.0), Alignment::CENTER);
    let st = weight(
        k.lk.small,
        if k.lk.form == Form::Tv { 26.0 } else { 13.0 },
        400,
    );
    let mut kids = vec![
        rail_title(k, &f.title).padding(ins(0.0, 0.0, 8.0, 0.0)),
        wide(line(), Alignment::CENTER),
    ];
    for r in &f.rows {
        let row = Node::hstack(
            Align::Center,
            Some(14.0),
            vec![
                txt(k.cx, &r.label, st, colour::FONT_QUIET, Some(1)),
                Node::spacer(),
                txt(k.cx, &r.value, st, colour::FONT, Some(1)),
            ],
        )
        .frame(None, Some(k.lk.row_height), Alignment::CENTER);
        kids.push(wide(row, Alignment::CENTER));
        kids.push(wide(line(), Alignment::CENTER));
    }
    Some(Node::vstack(Align::Start, Some(0.0), kids).padding(ins(0.0, k.lk.edge, 0.0, k.lk.edge)))
}

/// "Ähnliche Titel" failed: heading and the retry hint (`DisturbHint`).
/// Design name: DisturbHint
fn disturbed(k: &Kit, title: &str, retry: &str) -> Node {
    let edge = k.lk.edge;
    let hint = Node::vstack(
        Align::Start,
        Some(8.0),
        vec![
            txt(
                k.cx,
                "Das ging schief. Der Server antwortet nicht.",
                k.lk.body,
                colour::FONT_QUIET,
                Some(2),
            ),
            txt(
                k.cx,
                "Erneut versuchen",
                weight(k.lk.body, k.lk.body.size, 600),
                colour::MARK_ACCENT,
                Some(1),
            )
            .key("retry")
            .on_tap(Action::from(retry)),
        ],
    );
    Node::vstack(Align::Start, Some(12.0), vec![rail_title(k, title), hint])
        .padding(ins(0.0, edge, 0.0, edge))
}

/// "Gesehen von" on Mac and tv (`WatcherAvatar`, `WatcherTile`): avatar with a ring track (white 18 %), initial 0.42 of the
/// inner disc semibold; Mac 60 with a 3 pt ring, 22 apart, tv 150 with a 5 pt ring and the name under it.
/// The accent arc runs from 12 o'clock clockwise (`Paint::Arc`, round caps). On tv name and caption fade in with the focus
/// (`opacity(focus ? 1 : 0)`, the 70 pt is reserved) and the tile grows with it.
/// Design name: WatcherAvatar
fn watchers_rail(k: &Kit, ws: &[swiftly_vm::WatcherTile]) -> Node {
    let tvf = k.lk.form == Form::Tv;
    let (size, line) = if tvf { (150.0, 5.0) } else { (60.0, 3.0) };
    let inner = if tvf {
        size - 2.0 * (line + 4.0)
    } else {
        size - 10.0
    };
    let items = ws
        .iter()
        .enumerate()
        .map(|(i, w)| {
            let arc = w.ring.clamp(0.0, 1.0) as f32;
            let disc = txt_center(
                k.cx,
                &w.initial,
                weight(k.lk.rail, inner * 0.42, 600),
                colour::FONT,
                1,
            )
            .frame(Some(inner), Some(inner), Alignment::CENTER)
            .background(
                Node::rect(color(colour::RAISED), inner / 2.0),
                Alignment::CENTER,
            );
            let av = disc
                .frame(Some(size), Some(size), Alignment::CENTER)
                .paint(Paint::Stroke {
                    color: Color::new(1.0, 1.0, 1.0, 0.18),
                    width: line,
                    radius: size / 2.0,
                })
                .paint(Paint::Arc {
                    color: color(colour::MARK_ACCENT),
                    width: line,
                    from: 0.0,
                    to: arc,
                });
            if tvf {
                let key = format!("watcher:{i}");
                let mut parts = Vec::new();
                if w.play_count > 1 {
                    parts.push(format!("{} ×", w.play_count));
                }
                if let (Some(done), Some(all)) = (w.watched_count, w.total_count)
                    && all > 0
                    && done < all
                {
                    parts.push(format!("{done} von {all} Folgen"));
                } else if w.ring > 0.0 && w.ring < 1.0 {
                    parts.push(format!("{} %", (w.ring * 100.0).round() as i64));
                }
                if let Some(t) = &w.last_watched {
                    parts.push(t.clone());
                }
                let hidden = |c: swiftly_design::Colour| rgba(c, 0.0);
                let name = focus_tint(
                    txt_center(k.cx, &w.name, k.lk.tile, colour::FONT, 1),
                    hidden(colour::FONT),
                    color(colour::FONT),
                );
                let cap = focus_tint(
                    txt_center(k.cx, &parts.join(" · "), k.lk.small, colour::FONT_QUIET, 1),
                    hidden(colour::FONT_QUIET),
                    color(colour::FONT_QUIET),
                );
                let label = Node::vstack(Align::Center, Some(2.0), vec![name, cap])
                    .padding(ins(14.0, 0.0, 0.0, 0.0))
                    .frame(Some(260.0), Some(70.0), Alignment::TOP);
                let mut look = FocusLook::tile(size / 2.0);
                look.shadow = None;
                return Node::vstack(Align::Center, Some(0.0), vec![av, label])
                    .frame(Some(260.0), None, Alignment::TOP)
                    .key(key.as_str())
                    .focusable(focus_id(key.as_str()), Some(look));
            }
            av
        })
        .collect();
    segment(
        k,
        "watchers",
        "Gesehen von",
        items,
        if tvf { 0.0 } else { 22.0 },
        if tvf { size + 70.0 } else { size },
    )
}

/// Everything below the head of a movie page, in the Swift order: watchers, cast, extras, collections, similar, file.
pub(crate) fn bottom(k: &Kit, b: &BottomPart, pad_top: f32) -> Node {
    let mut kids = Vec::new();
    if !b.watchers.is_empty() && k.lk.form != Form::Touch {
        kids.push(watchers_rail(k, &b.watchers));
    } else if !b.watchers.is_empty() {
        let av = 44.0;
        let items = b
            .watchers
            .iter()
            .map(|w| {
                let disc = txt_center(
                    k.cx,
                    &w.initial,
                    weight(k.lk.rail, 18.0, 600),
                    colour::FONT,
                    1,
                )
                .frame(Some(av), Some(av), Alignment::CENTER)
                .background(
                    Node::rect(color(colour::RAISED), av / 2.0),
                    Alignment::CENTER,
                );
                Node::vstack(
                    Align::Center,
                    Some(4.0),
                    vec![
                        disc,
                        txt_center(k.cx, &w.name, k.lk.small, colour::FONT_QUIET, 1),
                    ],
                )
                .frame(Some(64.0), None, Alignment::TOP)
            })
            .collect();
        kids.push(segment(k, "watchers", "Gesehen von", items, 12.0, 80.0));
    }
    if !b.cast.is_empty() {
        kids.push(cast_rail(k, &b.cast));
    }
    if !b.extras.is_empty() {
        kids.push(tile_rail(k, "extras", "Extras", &b.extras, true));
    }
    for c in &b.collections {
        kids.push(tile_rail(
            k,
            &format!("collection:{}", c.id),
            &c.title,
            &c.tiles,
            false,
        ));
    }
    if !b.similar.is_empty() {
        let title = if k.lk.form == Form::Desktop {
            "Ähnliches"
        } else {
            "Ähnliche Titel"
        };
        kids.push(tile_rail(k, "similar", title, &b.similar, false));
    } else if b.similar_failed {
        kids.push(disturbed(k, "Ähnliche Titel", "retry-similar"));
    }
    if let Some(f) = file_excerpt(k, b) {
        kids.push(f);
    }
    Node::vstack(Align::Start, Some(k.lk.sections), kids).padding(ins(pad_top, 0.0, 0.0, 0.0))
}

/// A sheet over the page: scrim and a list of rows (the More panel, the version picker, the season list).
pub(crate) fn sheet(k: &Kit, title: &str, rows: &[(String, bool)], prefix: &str) -> Node {
    let lk = &k.lk;
    let w = if lk.form == Form::Touch {
        k.env.size.w
    } else if lk.form == Form::Tv {
        760.0
    } else {
        360.0
    };
    let mut kids = vec![
        txt(
            k.cx,
            title,
            weight(lk.body, lk.body.size + 2.0, 600),
            colour::FONT,
            Some(1),
        )
        .padding(ins(0.0, 4.0, 8.0, 4.0)),
    ];
    for (i, (s, on)) in rows.iter().enumerate() {
        let key = format!("{prefix}:{i}");
        let c = if *on {
            colour::MARK_ACCENT
        } else {
            colour::FONT
        };
        let mut r = wide(
            txt(k.cx, s, weight(lk.body, lk.body.size, 600), c, Some(1))
                .padding(ins(0.0, 16.0, 0.0, 16.0))
                .frame(None, Some(lk.row_height + 8.0), Alignment::LEADING),
            Alignment::LEADING,
        )
        .key(key.as_str())
        .on_tap(Action::from(key.as_str()));
        if lk.form == Form::Tv {
            r = r.focusable(focus_id(key.as_str()), Some(FocusLook::tile(16.0)));
        }
        kids.push(r);
    }
    if lk.form == Form::Touch {
        // `SheetModifier`: the grab handle, 36 x 5, white 18 %.
        kids.insert(
            0,
            wide(
                Node::rect(Color::new(1.0, 1.0, 1.0, 0.18), 2.5)
                    .frame(Some(36.0), Some(5.0), Alignment::CENTER)
                    .padding(ins(0.0, 0.0, 6.0, 0.0)),
                Alignment::TOP,
            ),
        );
    }
    // `SheetModifier`: an opaque `Theme.area` card with a hairline (not a material) under a black 55 % dimmer; measured in
    // `Style.swift`, so the shared blur is not used here.
    let panel = Node::vstack(Align::Start, Some(0.0), kids)
        .padding(ins(
            8.0,
            12.0,
            16.0 + if lk.form == Form::Touch {
                k.env.safe.bottom
            } else {
                0.0
            },
            12.0,
        ))
        .frame(Some(w), None, Alignment::TOP_LEADING)
        .background(
            Node::rect(color(colour::AREA), 28.0).paint(Paint::Stroke {
                color: color(colour::LINE),
                width: 1.0,
                radius: 28.0,
            }),
            Alignment::CENTER,
        )
        .on_tap_silent(Action::from("sheet-inside"));
    let scrim = fill_frame(
        Node::rect(Color::new(0.0, 0.0, 0.0, 0.55), 0.0),
        Alignment::CENTER,
    )
    .key("scrim")
    .on_tap(Action::from("close-sheet"));
    let place = if lk.form == Form::Touch {
        Alignment::BOTTOM
    } else {
        Alignment::CENTER
    };
    fill_frame(panel, place).background(scrim, Alignment::CENTER)
}

/// The back button and the title that fades in with the scroll (`DetailHeaderReader`); on tv there is none (Menu goes back).
/// Design name: DetailHeader
pub(crate) fn top_bar(k: &Kit, title: &str, strength: u8) -> Node {
    let lk = &k.lk;
    if lk.form == Form::Tv {
        return Node::fixed(0.0, 0.0);
    }
    let s = f32::from(strength) / 8.0;
    let top = if lk.form == Form::Touch {
        k.env.safe.top
    } else {
        0.0
    };
    let h = top + 44.0;
    if lk.form == Form::Touch {
        // `DetailHeader`: blur + ground; the bar rests at 70 % of the history and fills up with the scroll.
        let back = k
            .icons
            .node("caret-left", 18.0, true, color(colour::FONT))
            .frame(Some(36.0), Some(36.0), Alignment::CENTER)
            .background(
                Node::rect(color(colour::SCRIM_BUTTON), 18.0),
                Alignment::CENTER,
            )
            .a11y_label(swiftly_ui::a11y::Role::Button, "Zurück")
            .key("back-button")
            .on_tap(Action::from("back"))
            .padding(ins(top + 4.0, lk.edge.min(16.0), 0.0, 0.0));
        let name = Node::text(
            k.cx,
            title,
            &TextStyle::from(weight(lk.body, 17.0, 600)),
            rgba(colour::FONT, s),
            Some(1),
            swiftly_text::Align::Center,
        )
        .frame(Some(k.env.size.w - 120.0), Some(36.0), Alignment::CENTER)
        .padding(ins(top + 4.0, 0.0, 0.0, 0.0));
        let glass = glass_ground(k.env.size.w, h, strength, 0.7);
        return glass
            .overlay(wide(name, Alignment::TOP), Alignment::TOP)
            .overlay(back, Alignment::TOP_LEADING);
    }
    if lk.form == Form::Desktop {
        // `DetailHeader`: 52 high, the chevron 30 x 28 at 20 (the arrows' column is 62 wide), the title 14 semibold fading in
        // with the scroll; the bar's ground is the page ground.
        let s = f32::from(strength) / f32::from(crate::home::BAR_STEPS);
        let back = k
            .icons
            .node("caret-left", 16.0, true, color(colour::FONT))
            .frame(Some(30.0), Some(28.0), Alignment::CENTER)
            .a11y_label(swiftly_ui::a11y::Role::Button, "Zurück")
            .key("back-button")
            .on_tap(Action::from("back"))
            .tooltip("Zurück")
            .padding(ins(12.0, 20.0, 0.0, 0.0));
        // The title sits left, after the arrows' 62 pt column (20 + 62 + 12), like `StateBar`.
        let name = Node::text(
            k.cx,
            title,
            &TextStyle::from(weight(lk.body, 14.0, 600)),
            rgba(colour::FONT, s),
            Some(1),
            swiftly_text::Align::Start,
        )
        .padding(ins(0.0, 94.0, 0.0, 16.0))
        .frame(None, Some(52.0), Alignment::LEADING);
        let name = wide(name, Alignment::LEADING);
        return crate::home::header_backdrop(s)
            .overlay(name, Alignment::TOP)
            .overlay(back, Alignment::TOP_LEADING);
    }
    let ground = Node::rect(rgba(colour::REASON, s), 0.0).frame(None, Some(h), Alignment::CENTER);
    let ground = wide(ground, Alignment::CENTER).overlay(
        Node::rect(rgba(colour::LINE, 0.0), 0.0).frame(None, Some(1.0), Alignment::CENTER),
        Alignment::BOTTOM,
    );
    let back = k
        .icons
        .node("caret-left", 18.0, true, color(colour::FONT))
        .frame(Some(36.0), Some(36.0), Alignment::CENTER)
        .background(
            Node::rect(color(colour::SCRIM_BUTTON), 18.0),
            Alignment::CENTER,
        )
        .a11y_label(swiftly_ui::a11y::Role::Button, "Zurück")
        .key("back-button")
        .on_tap(Action::from("back"))
        .padding(ins(top + 4.0, lk.edge.min(16.0), 0.0, 0.0));
    let name = Node::text(
        k.cx,
        title,
        &TextStyle::from(weight(lk.body, 17.0, 600)),
        rgba(colour::FONT, s),
        Some(1),
        swiftly_text::Align::Center,
    )
    .frame(Some(k.env.size.w - 120.0), Some(36.0), Alignment::CENTER)
    .padding(ins(top + 4.0, 0.0, 0.0, 0.0));
    wide(ground, Alignment::TOP)
        .overlay(wide(name, Alignment::TOP), Alignment::TOP)
        .overlay(back, Alignment::TOP_LEADING)
}

/// The page ground colour.
pub(crate) fn ground(n: Node) -> Node {
    fill_frame(n, Alignment::TOP_LEADING)
        .background(Node::rect(color(colour::REASON), 0.0), Alignment::CENTER)
}

pub(crate) fn status_card(
    k: &Kit,
    icon: &str,
    title: &str,
    text: &str,
    button: &str,
    action: &str,
) -> Node {
    let col = Node::vstack(
        Align::Center,
        Some(12.0),
        vec![
            k.icons.node(icon, 44.0, true, color(colour::FONT_QUIET)),
            txt_center(
                k.cx,
                title,
                weight(k.lk.rail, k.lk.rail.size, 600),
                colour::FONT,
                2,
            ),
            txt_center(k.cx, text, k.lk.body, colour::FONT_QUIET, 3).frame(
                Some(300.0),
                None,
                Alignment::CENTER,
            ),
            txt_center(
                k.cx,
                button,
                weight(k.lk.body, k.lk.body.size, 600),
                colour::REASON,
                1,
            )
            .padding(ins(0.0, 24.0, 0.0, 24.0))
            .frame(None, Some(44.0), Alignment::CENTER)
            .background(Node::rect(color(colour::FONT), 22.0), Alignment::CENTER)
            .key("retry")
            .on_tap(Action::from(action)),
        ],
    );
    fill_frame(col, Alignment::CENTER)
}

// ---- the Detail screen -----------------------------------------------------------------------------------------------

#[derive(Clone, PartialEq)]
struct Data {
    hero: Arc<HeroPart>,
    actions: Arc<ActionsPart>,
    bottom: Arc<BottomPart>,
    menu: Vec<String>,
    versions: Vec<String>,
    /// Title and rows of the tile menu on a rail, the device names and the download sheet (sheets 3, 4 and 5).
    tile_title: String,
    tile_rows: Vec<String>,
    devices: Vec<String>,
    load: crate::load_panel::LoadSpec,
    head: Head,
    loading: bool,
    failed: bool,
    /// Late data waits for the push to settle (`InTravel.waitFor()`): what was not there at the first build.
    hold_bottom: bool,
    hold_mood: bool,
    /// `ImageMood.reveal`: the tone arriving after the first build fades in with `Mood` (smooth 0.55 s); 1 when it was there.
    mood_alpha: f32,
    /// `Theme.reveal` on the rails arriving after the first build (`withAnimation(Theme.reveal) { bottomPresent = true }`).
    bottom_alpha: f32,
}

fn head_of(h: &HeroPart, a: &ActionsPart, trailer: bool) -> Head {
    Head {
        id: h.id.clone(),
        image: h.image.clone(),
        title: h.title.clone(),
        secondary: h.secondary_line.clone(),
        overview: h.overview.clone(),
        directors: h.directors.clone(),
        label: a.play.label.clone(),
        enabled: a.play.enabled,
        remaining: a.play.remaining.clone(),
        progress: a.play.progress,
        watched: a.watched,
        favorite: a.favorite,
        fav_caption: a.favorite_caption.clone(),
        download: a.download.as_ref().map(|d| d.state),
        proof: a.proof.visible.then(|| {
            (
                a.proof.direct_play,
                a.proof.hint.clone(),
                a.proof.rating.clone(),
                a.proof.age_rating.clone(),
            )
        }),
        message: a.message.clone(),
        trailer,
    }
}

fn page(d: &Data, sx: &UiState, env: &Env, cx: &Cx, art: &Art, icons: &Icons) -> Node {
    let k = Kit {
        cx,
        env,
        lk: look(env),
        art,
        icons,
    };
    let h = &d.head;
    let lk = &k.lk;
    let bottom_pad = match lk.form {
        Form::Touch => 32.0 + env.safe.bottom,
        Form::Desktop => 40.0,
        Form::Tv => 48.0,
    };
    let content = match lk.form {
        Form::Touch => {
            let mut kids = vec![hero(&k, h, vec![]), body_touch(&k, h, sx.overview_open)];
            if d.bottom.ready && !d.hold_bottom {
                kids.push(
                    bottom(&k, &d.bottom, 0.0)
                        .padding(ins(touch::RAILS_SPACING - touch::BLOCK_GAP, 0.0, 0.0, 0.0))
                        .opacity(d.bottom_alpha, swiftly_ui::Motion::Instant),
                );
            }
            let since = if lk.pad { 420.0 } else { HERO_TOUCH };
            let tones = if d.hold_mood {
                Vec::new()
            } else {
                art.tones_for(h.image.as_ref(), &h.id)
            };
            let stack = wide(
                Node::vstack(Align::Start, Some(0.0), kids),
                Alignment::TOP_LEADING,
            );
            if tones.is_empty() {
                stack
            } else {
                let total = since + swiftly_images::mood::RUN_OUT as f32;
                stack.background(
                    mood_strips(&tones, since, (0.0, total), 0.0, env.size.w, |_| {
                        d.mood_alpha
                    }),
                    Alignment::TOP_LEADING,
                )
            }
        }
        Form::Desktop => {
            let top = hero(&k, h, hero_buttons(&k, h, sx.overview_open));
            let mut kids = vec![top];
            if d.bottom.ready && !d.hold_bottom {
                kids.push(
                    bottom(&k, &d.bottom, 36.0)
                        .padding(ins(0.0, 0.0, 0.0, 0.0))
                        .opacity(d.bottom_alpha, swiftly_ui::Motion::Instant),
                );
            }
            let stack = wide(
                Node::vstack(Align::Start, Some(0.0), kids),
                Alignment::TOP_LEADING,
            );
            // The mood colour scrolls with the page (`DetailView.swift:182`): the mesh under hero and rails.
            let tones = if d.hold_mood {
                Vec::new()
            } else {
                art.tones_for(h.image.as_ref(), &h.id)
            };
            if tones.is_empty() {
                stack
            } else {
                let total = HERO_DESKTOP + swiftly_images::mood::RUN_OUT as f32;
                stack.background(
                    mood_strips(&tones, HERO_DESKTOP, (0.0, total), 0.0, env.size.w, |_| {
                        d.mood_alpha
                    }),
                    Alignment::TOP_LEADING,
                )
            }
        }
        Form::Tv => {
            let mut kids = vec![hero(&k, h, hero_buttons(&k, h, false))];
            if d.bottom.ready {
                kids.push(bottom(&k, &d.bottom, 0.0));
            }
            wide(
                Node::vstack(Align::Start, Some(0.0), kids),
                Alignment::TOP_LEADING,
            )
        }
    };
    let content = content.padding(ins(0.0, 0.0, bottom_pad, 0.0));
    let scroll = Node::scroll(Axis::Vertical, None, content).key("detail-scroll");
    let mut page = fill_frame(scroll, Alignment::TOP_LEADING);
    page = page.overlay(top_bar(&k, &h.title, sx.header), Alignment::TOP);
    if d.failed
        && d.bottom.ready
        && d.bottom.similar.is_empty()
        && !d.bottom.similar_failed
        && h.proof.is_none()
    {
        // The fresh title never came: the list entry stays; nothing more to say here.
    }
    if let Some(m) = h.message.as_ref().filter(|_| lk.form != Form::Desktop) {
        let strip = txt(cx, m, lk.small, colour::FONT, Some(2))
            .padding(ins(12.0, 16.0, 12.0, 16.0))
            .background(Node::rect(color(colour::RAISED), 12.0), Alignment::CENTER)
            .key("message")
            .on_tap(Action::from("dismiss"));
        page = page.overlay(
            strip.padding(ins(env.safe.top + 56.0, 16.0, 0.0, 16.0)),
            Alignment::TOP,
        );
    }
    if lk.form == Form::Desktop
        && let Some(menu) = sx.menu.overlay(cx, env)
    {
        page = page.overlay(menu, Alignment::TOP_LEADING);
    }
    match sx.sheet {
        1 => {
            let rows: Vec<(String, bool)> = d.menu.iter().map(|s| (s.clone(), false)).collect();
            page = page.overlay(sheet(&k, &h.title, &rows, "menu"), Alignment::CENTER);
        }
        2 => {
            let rows: Vec<(String, bool)> = d.versions.iter().map(|s| (s.clone(), false)).collect();
            page = page.overlay(
                sheet(&k, "Fassung wählen", &rows, "version"),
                Alignment::CENTER,
            );
        }
        3 => {
            let rows: Vec<(String, bool)> =
                d.tile_rows.iter().map(|s| (s.clone(), false)).collect();
            page = page.overlay(sheet(&k, &d.tile_title, &rows, "tmenu"), Alignment::CENTER);
        }
        4 => {
            let rows: Vec<(String, bool)> = d.devices.iter().map(|s| (s.clone(), false)).collect();
            page = page.overlay(
                sheet(&k, "Abspielen auf \u{2026}", &rows, "tdev"),
                Alignment::CENTER,
            );
        }
        5 => {
            page = page.overlay(
                crate::load_panel::load_sheet(cx, icons, env, &d.load),
                Alignment::CENTER,
            )
        }
        _ => {}
    }
    ground(page)
}

/// The popover key of a focus-engine key.
pub(crate) fn menu_key(key: swiftly_ui::NavKey) -> Option<popover::MenuKey> {
    use swiftly_ui::{Dir, NavKey};
    Some(match key {
        NavKey::Arrow(Dir::Up) => popover::MenuKey::Up,
        NavKey::Arrow(Dir::Down) => popover::MenuKey::Down,
        NavKey::Enter => popover::MenuKey::Enter,
        NavKey::Escape => popover::MenuKey::Escape,
        _ => return None,
    })
}

/// The Detail screen: a UI over a `DetailVm`, pushed from a poster of a list.
pub struct DetailScreen {
    host: Pushed<Data>,
    /// What was there at the first refresh: (rails, tone).
    first_ready: Option<(bool, bool)>,
    /// The push has settled once: later data is never held again (the pop must not pull rails out).
    settled_once: bool,
    /// When the tone became visible after the first build, and whether it still fades.
    mood_since: Option<f64>,
    mood_busy: bool,
    bottom_since: Option<f64>,
    alphas: (f32, f32),
    art: Rc<Art>,
    vm: DetailVm<AppTransport>,
    menu: Vec<MenuEntry>,
    versions: Vec<swiftly_vm::VersionOption>,
    log: Vec<String>,
    tile_id: Option<String>,
    load: crate::load_panel::LoadSpec,
    requests: Vec<swiftly_vm::TileRequest>,
    /// Play asked for by the last press (the real app starts the player from it).
    play_req: Option<crate::live_play::PlayRequest>,
    /// "Laden" asked for in the live app (once): the button the add sheet grows out of.
    download_req: Option<Option<swiftly_layout::Rect>>,
    /// Title and start second of the open version sheet.
    choose: Option<(String, f64)>,
    /// When the message strip appeared (ms); it withdraws itself after 3 s (`HintStrip`).
    message_since: Option<f64>,
}

impl DetailScreen {
    /// What a screen reader gets for this screen: the nodes of the current picture.
    pub fn a11y_nodes(&self) -> Vec<swiftly_ui::a11y::A11yNode> {
        self.host.ui.a11y_nodes()
    }

    /// A detail screen for `env` over a scripted server in `scenario`; the list is in front until [`Self::open`].
    pub fn new(env: Env, cx: Cx, scenario: Scenario) -> DetailScreen {
        Self::with_root(env, cx, scenario, false, None)
    }

    /// A detail screen for the app: the root page is transparent, so the page below shows through while the title page
    /// slides in over it.
    pub fn overlay(env: Env, cx: Cx, scenario: Scenario) -> DetailScreen {
        Self::with_root(env, cx, scenario, true, None)
    }

    /// As `overlay`, for the tapped tile `(id, title)`.
    pub fn overlay_for(env: Env, cx: Cx, scenario: Scenario, tile: (&str, &str)) -> DetailScreen {
        Self::with_root(env, cx, scenario, true, Some(tile))
    }

    fn with_root(
        env: Env,
        cx: Cx,
        scenario: Scenario,
        bare: bool,
        tile: Option<(&str, &str)>,
    ) -> DetailScreen {
        let vm = match tile {
            Some((id, name)) => title_data::detail_vm_for(scenario, id, name),
            None => title_data::detail_vm(scenario),
        };
        let art = Rc::new(Art::new(&cx));
        let icons = Icons::new(&cx, env.scale);
        let art2 = Rc::clone(&art);
        let data = Self::data(&vm, &[]);
        let art3 = Rc::clone(&art);
        let host = Pushed::new(env, cx, data, art, bare, move |d, sx, env, cx| {
            page(d, sx, env, cx, &art2, &icons)
        });
        let mut s = DetailScreen {
            host,
            first_ready: None,
            settled_once: false,
            mood_since: None,
            mood_busy: false,
            bottom_since: None,
            alphas: (1.0, 1.0),
            art: art3,
            menu: vm.more_menu(),
            vm,
            versions: Vec::new(),
            log: Vec::new(),
            tile_id: None,
            load: crate::load_panel::LoadSpec::demo(""),
            requests: Vec::new(),
            play_req: None,
            download_req: None,
            choose: None,
            message_since: None,
        };
        s.refresh();
        s
    }

    fn data(vm: &DetailVm<AppTransport>, versions: &[swiftly_vm::VersionOption]) -> Data {
        let (hero, actions, bottom) = (vm.hero(), vm.actions(), vm.bottom());
        let head = head_of(&hero, &actions, true);
        let loading = !bottom.ready && !actions.play.enabled;
        Data {
            menu: vm.more_menu().into_iter().map(|e| e.text).collect(),
            tile_title: String::new(),
            tile_rows: Vec::new(),
            devices: Vec::new(),
            load: crate::load_panel::LoadSpec::demo(""),
            versions: versions
                .iter()
                .map(|v| {
                    if v.name.is_empty() {
                        "Fassung".into()
                    } else {
                        v.name.clone()
                    }
                })
                .collect(),
            failed: bottom.ready && !actions.proof.visible,
            hero,
            actions,
            bottom,
            head,
            loading,
            hold_bottom: false,
            hold_mood: false,
            mood_alpha: 1.0,
            bottom_alpha: 1.0,
        }
    }

    fn refresh(&mut self) {
        self.menu = self.vm.more_menu();
        let mut d = Self::data(&self.vm, &self.versions);
        let mcx = crate::tile_menu::demo_cx(false);
        let tile = self.tile_id.as_ref().and_then(|id| self.rail_tile(id));
        let form = Form::of(self.host.ui().env().idiom);
        d.tile_title = tile.as_ref().map(|t| t.title.clone()).unwrap_or_default();
        d.tile_rows = crate::tile_menu::rows(form, &mcx, tile.as_ref())
            .into_iter()
            .map(|r| r.label)
            .collect();
        d.devices = crate::tile_menu::device_rows(&mcx)
            .into_iter()
            .map(|r| r.label)
            .collect();
        d.load = self.load.clone();
        // `InTravel`: the Mac sets late data (the fetched title, the rails, the tone) only when the push has settled.
        if self.host.depth() > 1 && self.host.covers() {
            self.settled_once = true;
        }
        let travelling = self.host.depth() > 1 && !self.host.covers() && !self.settled_once;
        let tones = !self
            .art
            .tones_for(d.head.image.as_ref(), &d.head.id)
            .is_empty();
        let first = *self.first_ready.get_or_insert((d.bottom.ready, tones));
        d.hold_bottom = travelling && !first.0;
        d.hold_mood = travelling && !first.1;
        d.mood_alpha = 1.0;
        if tones && !d.hold_mood && !first.1 {
            let now = self.host.now;
            let t0 = *self.mood_since.get_or_insert(now);
            let p = swiftly_motion::catalogue::Id::Mood
                .curve()
                .progress((now - t0) / 1000.0) as f32;
            // Quantised: the page is rebuilt when the value changes, not every frame of the last decimals.
            d.mood_alpha = if self.host.ui().env().reduce_motion {
                1.0
            } else {
                (p.clamp(0.0, 1.0) * 64.0).round() / 64.0
            };
            self.mood_busy = d.mood_alpha < 1.0;
        } else {
            self.mood_busy = false;
        }
        d.bottom_alpha = 1.0;
        if d.bottom.ready && !d.hold_bottom && !first.0 {
            let now = self.host.now;
            let t0 = *self.bottom_since.get_or_insert(now);
            let p = swiftly_motion::catalogue::Id::Reveal
                .curve()
                .progress((now - t0) / 1000.0) as f32;
            d.bottom_alpha = if self.host.ui().env().reduce_motion {
                1.0
            } else {
                (p.clamp(0.0, 1.0) * 64.0).round() / 64.0
            };
            self.mood_busy |= d.bottom_alpha < 1.0;
        }
        self.alphas = (d.mood_alpha, d.bottom_alpha);
        self.host.set_data(d);
        self.host.sync();
    }

    /// Opacity of the tone behind the page and of the rails in the last frame (tests; 1 at rest).
    pub fn arrival_alphas(&self) -> (f32, f32) {
        self.alphas
    }

    /// The view model (tests send intents through it).
    pub fn vm(&self) -> &DetailVm<AppTransport> {
        &self.vm
    }

    /// What the UI did that the screen cannot do itself (player start, person, tile): readable lines for tests.
    pub fn log(&self) -> &[String] {
        &self.log
    }

    /// Whether the title page is pushed (or being pushed).
    pub fn is_open(&self) -> bool {
        self.host.depth() > 1
    }

    /// The title page is fully in and nothing moves (the app then skips drawing the page below).
    pub fn below(&self) -> Option<(f32, f32)> {
        self.host.below()
    }

    /// Whether the page is fully in.
    pub fn covers(&self) -> bool {
        self.host.covers()
    }

    /// Pushes the title page as a tap on a poster does.
    pub fn open(&mut self, now: f64) {
        self.host.push(now);
    }

    /// Back: pops the page.
    pub fn back(&mut self, now: f64) -> bool {
        self.host.pop(now)
    }

    /// The server answered a start with several versions (Plex): opens the version sheet for the title.
    pub fn offer_versions(
        &mut self,
        item_id: String,
        since: f64,
        versions: Vec<swiftly_vm::VersionOption>,
    ) {
        self.choose = Some((item_id, since));
        self.versions = versions;
        self.log.push("play choose".into());
        self.host.sx.sheet = 2;
    }

    /// The play request of the last press, once.
    pub fn take_play(&mut self) -> Option<crate::live_play::PlayRequest> {
        self.play_req.take()
    }

    /// The "Laden" request of the last press, once: the rect of the More button the add sheet grows out of (`None`
    /// when the page has not been laid out). The host builds a `LoadRequest::Add` from the live title.
    pub fn take_download(&mut self) -> Option<Option<swiftly_layout::Rect>> {
        self.download_req.take()
    }

    fn drain(&mut self, now: f64) {
        for a in self.host.drain(now) {
            let is = |s: &str| a == Action::from(s);
            let pressed = self
                .rail_ids()
                .into_iter()
                .find(|id| is(&format!("tilemenu:{id}")));
            let desktop = self.host.ui().env().idiom == swiftly_ui::Idiom::Desktop;
            if a == popover::DISMISS {
                self.host.sx.menu.close();
            } else if desktop && is("more") {
                self.open_more_menu();
            } else if desktop && is("play-menu") {
                let p = self.host.pointer;
                self.open_more_menu_at(Anchor::Pointer(swiftly_layout::Point::new(p.0, p.1)));
            } else if desktop && let Some(id) = pressed.clone() {
                // Right click on a rail tile: the menu at the pointer, same entries as the sheet.
                self.tile_id = Some(id);
                let mcx = crate::tile_menu::demo_cx(false);
                let tile = self.tile_id.as_ref().and_then(|id| self.rail_tile(id));
                let form = Form::of(self.host.ui().env().idiom);
                let items: Vec<PopEntry> = crate::tile_menu::rows(form, &mcx, tile.as_ref())
                    .into_iter()
                    .enumerate()
                    .map(|(i, r)| {
                        PopEntry::Item(MenuItem::new(
                            Action::from(format!("tmenu:{i}").as_str()),
                            r.label,
                        ))
                    })
                    .collect();
                if !items.is_empty() {
                    let p = self.host.pointer;
                    self.host.sx.menu.open(
                        items,
                        Anchor::Pointer(swiftly_layout::Point::new(p.0, p.1)),
                        swiftly_ui::feel::DROPDOWN_WIDTH,
                        false,
                    );
                }
            } else if let Some(id) = self
                .vm
                .bottom()
                .extras
                .iter()
                .map(|t| t.id.clone())
                .find(|id| is(&format!("tile:{id}")))
            {
                // Mac: an extra plays from the start instead of opening a page (`DV:157,282`).
                self.play_req = Some(crate::live_play::PlayRequest {
                    item_id: id.clone(),
                    since: 0.0,
                    source_id: None,
                });
                self.log.push(format!("play extra {id}"));
            } else if is("play") {
                match self.vm.play(None) {
                    PlayAction::Choose {
                        versions,
                        item_id,
                        since,
                    } => {
                        self.choose = Some((item_id, since));
                        self.versions = versions;
                        self.log.push("play choose".into());
                        self.host.sx.sheet = 2;
                    }
                    other => {
                        self.play_req = crate::live_play::request_of(&other);
                        self.log.push(format!("play {other:?}"));
                    }
                }
            } else if is("favorite") {
                self.vm.send(DetailIntent::SetWatchlist {
                    on: !self.vm.actions().favorite,
                });
                crate::desk::note_list_change();
            } else if is("watched") {
                self.vm.send(DetailIntent::SetWatched {
                    on: !self.vm.actions().watched,
                });
                crate::desk::note_list_change();
            } else if is("download") && crate::live::current().is_some() {
                // The live app: the view model answers with `OpenDownload`, the host opens the add sheet (as on the Mac).
                let at = self
                    .host
                    .ui()
                    .frame_of("more")
                    .map(|f| swiftly_layout::Rect::new(f[0], f[1], f[2], f[3]));
                self.vm.send(DetailIntent::DownloadPressed);
                if self
                    .vm
                    .take_effects()
                    .contains(&swiftly_vm::DetailEffect::OpenDownload)
                {
                    self.download_req = Some(at);
                }
            } else if is("download") {
                // Touch: the "Laden" field opens the download sheet (`LoadSheet`) before anything is fetched.
                self.load = crate::load_panel::LoadSpec::demo(&self.vm.hero().title);
                self.host.sx.sheet = 5;
            } else if is("load.go") || is("load.queue") || is("load.cell") || is("load.clean") {
                self.host.sx.sheet = 0;
                self.vm.send(DetailIntent::DownloadPressed);
            } else if is("load.close") {
                self.host.sx.sheet = 0;
            } else if let Some(id) = pressed {
                self.tile_id = Some(id);
                self.host.sx.sheet = 3;
            } else if is("trailer") {
                self.vm.send(DetailIntent::Trailer);
            } else if is("more") {
                self.host.sx.sheet = 1;
            } else if is("overview") {
                self.host.sx.overview_open = !self.host.sx.overview_open;
            } else if is("close-sheet") {
                self.host.sx.sheet = 0;
            } else if is("dismiss") {
                self.message_since = None;
                self.vm.send(DetailIntent::DismissMessage);
            } else if is("retry-similar") || is("retry") {
                self.vm.send(DetailIntent::RetrySimilar);
                self.vm.send(DetailIntent::Load);
            } else {
                self.tile_menu_taps(&a);
                if desktop {
                    self.host.sx.menu.close();
                }
                for i in 0..self.menu.len() {
                    if is(&format!("menu:{i}")) {
                        self.host.sx.sheet = 0;
                        self.vm.send(DetailIntent::Menu(self.menu[i].kind.clone()));
                    }
                }
                for i in 0..self.versions.len() {
                    if is(&format!("version:{i}")) {
                        self.host.sx.sheet = 0;
                        self.play_req = self.choose.clone().map(|(item_id, since)| {
                            crate::live_play::PlayRequest {
                                item_id,
                                since,
                                source_id: Some(self.versions[i].id.clone()),
                            }
                        });
                        self.log
                            .push(format!("start version {}", self.versions[i].id));
                    }
                }
                self.log.push(format!("tap {}", a.0));
            }
        }
        self.refresh();
    }

    fn rail_ids(&self) -> Vec<String> {
        let b = self.vm.bottom();
        b.similar
            .iter()
            .chain(b.extras.iter())
            .chain(b.collections.iter().flat_map(|c| c.tiles.iter()))
            .map(|t| t.id.clone())
            .collect()
    }

    /// The tile of a rail by id.
    fn rail_tile(&self, id: &str) -> Option<Tile> {
        let b = self.vm.bottom();
        b.similar
            .iter()
            .chain(b.extras.iter())
            .chain(b.collections.iter().flat_map(|c| c.tiles.iter()))
            .find(|t| t.id == id)
            .cloned()
    }

    /// Host requests of the tile menu ("Laden", "Abspielen auf ...", "Gemeinsam schauen") since the last call.
    pub fn take_requests(&mut self) -> Vec<swiftly_vm::TileRequest> {
        std::mem::take(&mut self.requests)
    }

    /// Picks of the tile menu on a rail (sheet 3) and of its device list (sheet 4); same entries as Library and Home.
    fn tile_menu_taps(&mut self, a: &Action) {
        use crate::tile_menu::Entry;
        let Some(id) = self.tile_id.clone() else {
            return;
        };
        let mcx = crate::tile_menu::demo_cx(false);
        let tile = self.rail_tile(&id);
        let form = Form::of(self.host.ui().env().idiom);
        for (i, e) in crate::tile_menu::entries(form, &mcx, tile.as_ref())
            .into_iter()
            .enumerate()
        {
            if *a != Action::from(format!("tmenu:{i}").as_str()) {
                continue;
            }
            self.host.sx.sheet = 0;
            match e {
                Entry::Load => {
                    self.load = crate::load_panel::LoadSpec::demo(
                        tile.as_ref().map_or("", |t| t.title.as_str()),
                    );
                    self.host.sx.sheet = 5;
                }
                Entry::PlayOn => self.host.sx.sheet = 4,
                Entry::Together => self
                    .requests
                    .push(swiftly_vm::TileRequest::Together { id: id.clone() }),
                Entry::Play
                | Entry::FromStart
                | Entry::Info
                | Entry::Overview
                | Entry::ToSeries => self.log.push(format!("open {id}")),
                Entry::Watched | Entry::Unwatched | Entry::Remember | Entry::Remove => {
                    self.log.push(format!("menu {e:?} {id}"))
                }
            }
        }
        for (i, (device, _)) in mcx.host.play_on.iter().enumerate() {
            if *a == Action::from(format!("tdev:{i}").as_str()) {
                self.host.sx.sheet = 0;
                self.requests.push(swiftly_vm::TileRequest::PlayOn {
                    id: id.clone(),
                    device: device.clone(),
                });
            }
        }
    }

    /// Arrow, Tab, Enter or Esc on the focus engine; Esc goes back.
    pub fn nav_key(
        &mut self,
        key: swiftly_ui::NavKey,
        down: bool,
        now: f64,
    ) -> swiftly_ui::Outcome {
        if self.host.sx.menu.is_open() {
            if down && let Some(k) = menu_key(key) {
                if let popover::MenuOutcome::Activate(a) = self.host.sx.menu.key(k, now) {
                    self.host.injected.push(a);
                }
                self.drain(now);
            }
            return swiftly_ui::Outcome::None;
        }
        if self.host.sx.sheet != 0 && key == swiftly_ui::NavKey::Escape && down {
            self.host.sx.sheet = 0;
            self.refresh();
            return swiftly_ui::Outcome::None;
        }
        let out = self.host.ui().nav_key(key, down, now);
        if out == swiftly_ui::Outcome::Back(swiftly_ui::BackOutcome::Pop) {
            self.host.pop(now);
        }
        self.drain(now);
        out
    }

    /// A finger goes down.
    pub fn touch_down(&mut self, x: f32, y: f32, now: f64) {
        self.host.ui().touch_down(x, y, now);
        self.drain(now);
    }

    /// The finger moves.
    pub fn touch_move(&mut self, x: f32, y: f32, now: f64) {
        self.host.ui().touch_move(x, y, now);
        self.drain(now);
    }

    /// The finger lifts.
    pub fn touch_up(&mut self, x: f32, y: f32, now: f64) {
        self.host.ui().touch_up(x, y, now);
        self.drain(now);
    }

    /// The touch is cancelled.
    pub fn touch_cancel(&mut self, now: f64) {
        self.host.ui().touch_cancel(now);
        self.drain(now);
    }

    /// Shows the real pictures of the server through `hub` (without it the demo art stays).
    #[must_use]
    pub fn with_images(self, hub: Rc<crate::hub::ImageHub>) -> Self {
        self.host.hub.attach(hub);
        self
    }

    /// Waits for every picture and applies it (headless goldens).
    pub fn settle_images(&mut self, now: f64) {
        self.host.hub.settle(now);
    }

    /// One frame at `now` ms: the vm's newest parts, then the UI and the push animation.
    pub fn frame(&mut self, now: f64) -> (DrawList, bool) {
        self.host.now = now;
        self.refresh();
        if self.vm.actions().message.is_some() {
            let since = *self.message_since.get_or_insert(now);
            if now - since >= 3000.0 {
                self.message_since = None;
                self.vm.send(DetailIntent::DismissMessage);
            }
        } else {
            self.message_since = None;
        }
        let mut r = self.host.frame_list(now);
        r.1 |= self.mood_busy;
        self.drain(now);
        r
    }

    /// The frame `(x, y, w, h)` of a keyed node in window points (tests click and hover by it).
    pub fn frame_of(&mut self, key: &str) -> Option<[f32; 4]> {
        self.host.ui().frame_of(key)
    }

    /// Pictures draw nothing: the layout-only render the SwiftUI parity check compares (its fixture has no picture).
    pub fn blank_pictures(&mut self) {
        self.art.blank.set(true);
        self.refresh();
    }

    /// The pointer moved to `(x, y)` (hover, tooltips, cursor).
    pub fn pointer_move(&mut self, x: f32, y: f32, now: f64) {
        self.host.ui().pointer_move(x, y, now);
    }

    /// The pointer left the window.
    pub fn pointer_leave(&mut self, now: f64) {
        self.host.ui().pointer_leave(now);
    }

    /// A right click at `(x, y)`: opens the menu of the node under it. True when a node took it.
    pub fn secondary_click(&mut self, x: f32, y: f32, now: f64) -> bool {
        let took = self.host.ui().secondary_click(x, y, now);
        self.drain(now);
        took
    }

    /// A mouse wheel step scrolls the page under the pointer.
    pub fn wheel_scroll(&mut self, x: f32, y: f32, dx: f32, dy: f32, now: f64) -> bool {
        self.host.ui().wheel_scroll(x, y, dx, dy, now)
    }

    /// The cursor the node under the pointer asks for.
    pub fn cursor(&mut self) -> swiftly_ui::Cursor {
        self.host.ui().cursor()
    }

    /// The tooltip to draw at `now`.
    pub fn visible_tooltip(&mut self, now: f64) -> Option<(String, swiftly_layout::Rect)> {
        self.host.ui().visible_tooltip(now)
    }

    /// The anchored panel (More, tile menu) is open.
    pub fn menu_open(&mut self) -> bool {
        self.host.sx.menu.is_open()
    }

    /// Opens the More panel under its button (Mac): entries of the view model plus "Laden".
    fn open_more_menu(&mut self) {
        let rect = self
            .host
            .ui()
            .frame_of("more")
            .map_or(swiftly_layout::Rect::new(0.0, 0.0, 48.0, 56.0), |f| {
                swiftly_layout::Rect::new(f[0], f[1], f[2], f[3])
            });
        self.open_more_menu_at(Anchor::Button(rect));
    }

    fn open_more_menu_at(&mut self, anchor: Anchor) {
        let mut items: Vec<PopEntry> = self
            .menu
            .iter()
            .enumerate()
            .map(|(i, e)| {
                PopEntry::Item(MenuItem::new(
                    Action::from(format!("menu:{i}").as_str()),
                    e.text.clone(),
                ))
            })
            .collect();
        if self.vm.actions().download.is_some() {
            items.push(PopEntry::Item(MenuItem::new(
                Action::from("download"),
                "Laden",
            )));
        }
        // The Mac panel is 260 wide, right aligned under the button.
        self.host.sx.menu.open(items, anchor, 260.0, false);
    }

    /// An animation or a glide needs another frame.
    pub fn wants_frame(&self) -> bool {
        self.host.wants_frame() || self.mood_busy
    }

    /// A new window size or scale.
    pub fn set_env(&mut self, env: Env) {
        self.host.set_env(env);
    }

    /// The services (atlas pages) the renderers read.
    pub fn cx(&self) -> &Cx {
        self.host.cx()
    }

    /// Renders a list with the software renderer.
    pub fn render_software(&self, list: &DrawList) -> RgbaImage {
        self.host.render(list)
    }

    /// Scroll offsets of all scroll views in tree order.
    pub fn scroll_offsets(&mut self) -> Vec<f64> {
        self.host.ui().scroll_offsets()
    }

    /// The focused key on tv.
    pub fn focused(&mut self) -> Option<swiftly_ui::FocusId> {
        self.host.ui().focused()
    }

    /// Opens the More panel (tests).
    /// Opens the tile menu of the first tile on the rails (tests); false when no rail has a tile.
    pub fn open_tile_menu(&mut self) -> bool {
        let Some(id) = self.rail_ids().into_iter().next() else {
            return false;
        };
        self.tile_id = Some(id);
        self.open_sheet(3);
        true
    }

    /// Opens the download sheet (tests): the "Laden" field of the touch Detail page.
    pub fn open_load(&mut self) {
        self.load = crate::load_panel::LoadSpec::demo(&self.vm.hero().title);
        self.open_sheet(5);
    }

    /// The sheet in front: 0 none, 1 More, 2 versions, 3 tile menu, 4 devices, 5 download.
    pub fn sheet_kind(&self) -> u8 {
        self.host.sx.sheet
    }

    /// Opens a sheet by number (tests).
    pub fn open_sheet(&mut self, which: u8) {
        self.host.sx.sheet = which;
        self.refresh();
    }
}
