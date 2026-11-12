//! Navigation: a push/pop page stack with the Mac push (`desktop`) and the interactive edge-swipe back (`touch`).
//!
//! * [`Nav`] is the pure state machine: the pages, one continuous position `pos` (0 = root only, `n - 1` = the top page
//!   fully in) and what moves it (a timed ease, a spring, or the finger).
//! * [`Layers`] says which two pages are on screen for a position and how far the top one has come in.
//! * [`stack_view`] arranges the page nodes: the top page slides in from the right, the page below shifts left and
//!   dims, every other page waits off screen. All pages stay in the tree, so their scroll positions and press state
//!   survive ("regions stay alive").
//!
//! Sources: measurements of the Apple screens (Mac push: easeInOut 0.45, page below -30 %, ground dim
//! 28 %) and research notes on the interactive back swipe. The numbers are in [`tuning`].

use crate::env::{Env, Idiom};
use crate::ui::{Phase, UiEvent};
use crate::view::{Action, Edge, Key, Node, Paint};
use swiftly_layout::{Alignment, EdgeInsets};
use swiftly_motion::catalogue::Id;
use swiftly_motion::{Blend, Spring, SpringAnim, scroll::project};
use swiftly_render::{Color, ShadowStyle};

/// Feel numbers of the navigation. Same rules as `crate::tuning`: each has its source. (Merge into `tuning.rs` when
/// the xtask lint for literals lands.)
pub mod tuning {
    /// Seconds of the Mac push and pop: the catalogue's `pages_push` (`easeInOut(0.45)`, `Style.swift:403`).
    pub const DESKTOP_PUSH_SECONDS: f64 = crate::feel::PAGES_PUSH_SECONDS;
    /// Share of the width the page below moves left on the Mac. Source: `M/Style.swift:409` "-30 %", known.
    pub const DESKTOP_BELOW_SHIFT: f64 = 0.30;
    /// Opacity of the dim over the page below at the end of the Mac push. Source: `M/Style.swift:409` "28 %", known. The
    /// dim colour is `#101010` (`MainView.swift:565`), not black.
    pub const DESKTOP_DIM: f64 = 0.28;
    /// Width (pt) of the gradient strip outside the new page's left edge on the Mac push. Source: `MainView.swift:572-574`
    /// "28 pt wide gradient", known (a gradient, not `.shadow`, so no offscreen buffer).
    pub const DESKTOP_EDGE_WIDTH: f32 = 28.0;
    /// Alpha of that strip at the page edge (`#101010` 45 % to clear). Source: `MainView.swift:572-574`, known. It keeps
    /// full strength while the page is on screen; it only shows while the page is moving because it sits left of the page.
    pub const DESKTOP_EDGE_ALPHA: f32 = 0.45;
    /// Seconds a touch push, pop or released swipe takes to settle. Source: RF 3 (iOS 10 default transition 0.35 s,
    /// community recreation), estimated for the real app.
    pub const TOUCH_SETTLE_SECONDS: f64 = 0.35;
    /// Share of the width the page below moves left on touch. Source: RF 3 (community code: width / 4), estimated.
    pub const TOUCH_BELOW_SHIFT: f64 = 0.25;
    /// Dim over the page below at the end of a touch push. Source: RF 3 (black overlay alpha 0.1, community).
    pub const TOUCH_DIM: f64 = 0.10;
    /// Opacity of the shadow strip on the left edge of the incoming touch page. Source: RF 3 (6 pt strip), estimated.
    pub const TOUCH_EDGE_SHADOW: f64 = 0.30;
    /// A released swipe completes when the projected page edge passes this share of the width. Source: RF 3
    /// ("complete if x + project(v) > width / 2"), estimated.
    pub const COMPLETE_SHARE: f64 = 0.5;
    /// Deceleration rate for the release projection. Source: WWDC18 `project()` with `UIScrollView.DecelerationRate.normal`.
    pub const PROJECTION_RATE: f64 = swiftly_motion::tuning::DECELERATION_NORMAL;
}

/// The action an edge pan reports when it belongs to the back swipe. [`stack_view`] puts it on the top page.
pub const BACK_SWIPE: Action = Action(0x6e61_765f_6261_636b);

/// Which push animation a stack uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NavStyle {
    /// Windows and Linux (the Mac app's push): easeInOut 0.45 s, no swipe.
    Desktop,
    /// Android phones and tablets: spring, interactive edge-swipe back.
    Touch,
}

impl NavStyle {
    /// The style of a device kind: phones and pads are `Touch`, everything else `Desktop`.
    pub fn for_idiom(idiom: Idiom) -> NavStyle {
        match idiom {
            Idiom::Phone | Idiom::Pad => NavStyle::Touch,
            Idiom::Tv | Idiom::Desktop => NavStyle::Desktop,
        }
    }

    fn below_shift(self) -> f64 {
        match self {
            NavStyle::Desktop => tuning::DESKTOP_BELOW_SHIFT,
            NavStyle::Touch => tuning::TOUCH_BELOW_SHIFT,
        }
    }

    fn dim(self) -> f64 {
        match self {
            NavStyle::Desktop => tuning::DESKTOP_DIM,
            NavStyle::Touch => tuning::TOUCH_DIM,
        }
    }
}

/// The Android page settle spring (catalogue `TouchSettle`).
fn touch_spring() -> Spring {
    Id::TouchSettle
        .curve()
        .as_spring()
        .unwrap_or_else(|| Spring::critical_settling_in(tuning::TOUCH_SETTLE_SECONDS))
}

#[derive(Clone, Copy, Debug)]
#[allow(clippy::large_enum_variant)] // one Nav per page stack; boxing would cost the Copy the drive relies on
enum Drive {
    Rest,
    /// Desktop push and pop: the catalogue's `PagesPush` (or `Reduced`), blended like SwiftUI when interrupted.
    Blend {
        blend: Blend,
    },
    Spring {
        anim: SpringAnim,
        last: f64,
    },
    /// The finger holds the top page. `start` is the position at the grab, `grab_dx` the pan translation at that moment.
    Drag {
        start: f64,
        grab_dx: f32,
    },
}

/// A stack of pages with one continuous position. `R` is the app's route type.
pub struct Nav<R> {
    style: NavStyle,
    pages: Vec<(u64, R)>,
    next_serial: u64,
    /// Index of the logical top page. Pages above it are still leaving.
    target: usize,
    pos: f64,
    vel: f64,
    drive: Drive,
    reduce_motion: bool,
}

impl<R> Nav<R> {
    /// A stack with only the root page.
    pub fn new(root: R, style: NavStyle) -> Nav<R> {
        Nav {
            style,
            pages: vec![(0, root)],
            next_serial: 1,
            target: 0,
            pos: 0.0,
            vel: 0.0,
            drive: Drive::Rest,
            reduce_motion: false,
        }
    }

    /// Under Reduce Motion every push and pop is linear 0.14 s (D2 Tuning).
    pub fn set_reduce_motion(&mut self, on: bool) {
        self.reduce_motion = on;
    }

    /// The style.
    pub fn style(&self) -> NavStyle {
        self.style
    }

    /// The pages that exist now (including a page that is still leaving), bottom first, with a serial that never repeats.
    pub fn pages(&self) -> impl Iterator<Item = (u64, &R)> {
        self.pages.iter().map(|(s, r)| (*s, r))
    }

    /// How many pages the stack will have when the motion is done (1 = only the root).
    pub fn depth(&self) -> usize {
        self.target + 1
    }

    /// The logical top page.
    pub fn top(&self) -> Option<&R> {
        self.pages.get(self.target).map(|(_, r)| r)
    }

    /// The continuous position: 0 = root only, `n - 1` = page `n - 1` fully in.
    pub fn position(&self) -> f64 {
        self.pos
    }

    /// The speed of the position in pages per second (the finger's while dragging).
    pub fn velocity(&self) -> f64 {
        self.vel
    }

    /// Something moves: a push, a pop, a spring or a finger.
    pub fn is_animating(&self) -> bool {
        !matches!(self.drive, Drive::Rest)
    }

    /// A finger holds the top page.
    pub fn is_swiping(&self) -> bool {
        matches!(self.drive, Drive::Drag { .. })
    }

    /// The pages on screen for the current position.
    pub fn layers(&self) -> Layers {
        Layers::at(self.pos, self.pages.len())
    }

    fn top_index(&self) -> usize {
        self.pages.len().saturating_sub(1)
    }

    /// Pushes `route` and animates to it. A page that was still leaving is replaced by the new one.
    pub fn push(&mut self, route: R, now: f64) {
        self.update(now);
        self.pages.truncate(self.target + 1);
        let serial = self.next_serial;
        self.next_serial += 1;
        self.pages.push((serial, route));
        self.target = self.top_index();
        self.pos = self.pos.min(self.target as f64);
        self.go(self.target as f64, now, false);
    }

    /// Pops the top page with its animation. `false` at the root.
    pub fn pop(&mut self, now: f64) -> bool {
        self.update(now);
        if self.target == 0 {
            return false;
        }
        self.target -= 1;
        self.go(self.target as f64, now, false);
        true
    }

    /// Starts moving to `to`. `spring` forces the spring (a released swipe); otherwise the style decides.
    fn go(&mut self, to: f64, now: f64, spring: bool) {
        if (self.pos - to).abs() < 1e-9 && self.vel.abs() < 1e-9 {
            self.pos = to;
            self.drive = Drive::Rest;
            return;
        }
        let use_spring = spring || self.style == NavStyle::Touch;
        if use_spring && !self.reduce_motion {
            let mut anim = SpringAnim::new(touch_spring(), self.pos);
            anim.velocity = self.vel;
            anim.target = to;
            self.drive = Drive::Spring { anim, last: now };
        } else {
            // `withAnimation(motionReduced ? fadeReduced : timePagesPush)`; an animation that is interrupted by another
            // keeps running and the new step is added to it (`swiftly_motion::Blend`).
            let curve = if self.reduce_motion {
                Id::Reduced.curve()
            } else {
                Id::PagesPush.curve()
            };
            let mut blend = match self.drive {
                Drive::Blend { blend } => blend,
                _ => Blend::new(self.pos),
            };
            blend.retarget(now / 1000.0, to, curve);
            self.drive = Drive::Blend { blend };
        }
    }

    /// Advances to `now` (ms). Drops a page that has left. Returns whether something still moves.
    pub fn update(&mut self, now: f64) -> bool {
        match self.drive {
            Drive::Rest | Drive::Drag { .. } => {}
            Drive::Blend { mut blend } => {
                let t = now / 1000.0;
                if blend.settle(t) {
                    self.pos = blend.value(t);
                    self.vel = blend.velocity(t);
                    self.drive = Drive::Blend { blend };
                } else {
                    self.pos = blend.target();
                    self.vel = 0.0;
                    self.drive = Drive::Rest;
                }
            }
            Drive::Spring { mut anim, last } => {
                anim.step(((now - last) / 1000.0).max(0.0));
                self.pos = anim.value;
                self.vel = anim.velocity;
                if anim.is_settled() {
                    self.pos = anim.target;
                    self.vel = 0.0;
                    self.drive = Drive::Rest;
                } else {
                    self.drive = Drive::Spring { anim, last: now };
                }
            }
        }
        if matches!(self.drive, Drive::Rest) && self.top_index() > self.target {
            self.pages.truncate(self.target + 1);
            self.pos = self.pos.min(self.target as f64);
        }
        self.pos = self.pos.clamp(0.0, self.top_index() as f64);
        self.is_animating()
    }

    // ---- interactive back swipe (touch) ------------------------------------------------------------------------

    /// The finger grabbed the top page (also while it is still moving: it is caught where it is). `grab_dx` is the pan
    /// translation at that moment, so the page does not jump by the pan hysteresis. `false` at the root.
    pub fn swipe_begin(&mut self, grab_dx: f32, now: f64) -> bool {
        self.update(now);
        if self.pages.len() < 2 {
            return false;
        }
        self.target = self.top_index();
        self.drive = Drive::Drag {
            start: self.pos,
            grab_dx,
        };
        true
    }

    /// The finger moved: the top page follows it 1:1. `dx` is the pan translation, `vx` the finger velocity in pt/s.
    pub fn swipe_move(&mut self, dx: f32, vx: f32, width: f32) {
        if let Drive::Drag { start, grab_dx } = self.drive {
            let top = self.top_index() as f64;
            let moved = f64::from(dx - grab_dx) / f64::from(width.max(1.0));
            self.pos = (start - moved).clamp((top - 1.0).max(0.0), top);
            self.vel = -f64::from(vx) / f64::from(width.max(1.0));
        }
    }

    /// The finger lifted. The page completes (pops) or comes back, decided by the projected position (where the page
    /// edge would stop with the release velocity); a spring carries on from the current position and velocity.
    pub fn swipe_end(&mut self, dx: f32, vx: f32, width: f32, now: f64) {
        if !self.is_swiping() {
            return;
        }
        self.swipe_move(dx, vx, width);
        let top = self.top_index();
        let w = f64::from(width.max(1.0));
        let projected = self.pos - project(f64::from(vx), tuning::PROJECTION_RATE) / w;
        let complete = top > 0 && projected < top as f64 - tuning::COMPLETE_SHARE;
        self.target = if complete { top - 1 } else { top };
        self.go(self.target as f64, now, true);
    }

    /// The system cancelled the touch: the page comes back.
    pub fn swipe_cancel(&mut self, now: f64) {
        if self.is_swiping() {
            self.target = self.top_index();
            self.go(self.target as f64, now, true);
        }
    }

    /// Feeds a UI event to the swipe. Returns whether the event was the back swipe's.
    pub fn handle(&mut self, ev: &UiEvent, width: f32, now: f64) -> bool {
        let UiEvent::EdgePan {
            action,
            phase,
            translation,
            velocity,
            ..
        } = *ev
        else {
            return false;
        };
        if action != BACK_SWIPE {
            return false;
        }
        match phase {
            Phase::Began => {
                self.swipe_begin(translation.0, now);
            }
            Phase::Changed => self.swipe_move(translation.0, velocity.0, width),
            Phase::Ended => self.swipe_end(translation.0, velocity.0, width, now),
            Phase::Cancelled => self.swipe_cancel(now),
        }
        true
    }
}

/// Which pages are on screen, and how far the top one has come in.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Layers {
    /// Index of the page on top.
    pub top: usize,
    /// Index of the page under it, while the top page is not fully in.
    pub below: Option<usize>,
    /// How far the top page has come in: 0 = still off screen right, 1 = in place.
    pub fraction: f32,
}

impl Layers {
    /// The layers of position `pos` in a stack of `count` pages.
    pub fn at(pos: f64, count: usize) -> Layers {
        let last = count.saturating_sub(1);
        let pos = pos.clamp(0.0, last as f64);
        let top = ((pos - 1e-6).ceil().max(0.0) as usize).min(last);
        if top == 0 {
            return Layers {
                top,
                below: None,
                fraction: 1.0,
            };
        }
        let f = (pos - (top as f64 - 1.0)).clamp(0.0, 1.0);
        Layers {
            top,
            below: (f < 1.0 - 1e-6).then_some(top - 1),
            fraction: f as f32,
        }
    }
}

/// Where one page sits: offset of its left edge in points, the dim over it (0 to 1) and the edge shadow (0 to 1).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PagePlace {
    /// Left edge relative to the window's left edge.
    pub x: f32,
    /// Opacity of the black dim.
    pub dim: f32,
    /// Opacity of the shadow on the left edge.
    pub shadow: f32,
}

/// The place of page `index` for `layers` in a window of `width` points.
pub fn place(style: NavStyle, layers: &Layers, index: usize, width: f32) -> PagePlace {
    let f = f64::from(layers.fraction);
    if index == layers.top {
        let moving = layers.below.is_some();
        return PagePlace {
            x: width * (1.0 - layers.fraction),
            dim: 0.0,
            shadow: if moving && style == NavStyle::Touch {
                (tuning::TOUCH_EDGE_SHADOW * f) as f32
            } else {
                0.0
            },
        };
    }
    if layers.below == Some(index) {
        return PagePlace {
            x: -(style.below_shift() * f) as f32 * width,
            dim: (style.dim() * f) as f32,
            shadow: 0.0,
        };
    }
    // Waiting pages sit just right of the window: nothing is drawn, nothing is hit, scroll state stays.
    PagePlace {
        x: width,
        dim: 0.0,
        shadow: 0.0,
    }
}

/// Arranges the page nodes of a stack (bottom first, each with its serial from [`Nav::pages`]) for `layers`.
///
/// The result fills the window and clips. On `Touch` the top page takes the back swipe ([`BACK_SWIPE`]) when there is a
/// page below it.
pub fn stack_view(env: &Env, style: NavStyle, layers: &Layers, pages: Vec<(u64, Node)>) -> Node {
    let (w, h) = (env.size.w, env.size.h);
    let count = pages.len();
    let dim_colour = match style {
        NavStyle::Desktop => crate::components::color(swiftly_design::tokens::colour::REASON),
        NavStyle::Touch => Color::new(0.0, 0.0, 0.0, 1.0),
    };
    let top_x = place(style, layers, layers.top, w).x;
    let mut children: Vec<Node> = pages
        .into_iter()
        .enumerate()
        .map(|(i, (serial, content))| {
            let at = place(style, layers, i, w);
            let mut page = content.frame(Some(w), Some(h), Alignment::TOP_LEADING);
            if at.dim > 0.0 {
                page = page.overlay(
                    Node::rect(
                        Color::new(dim_colour.r, dim_colour.g, dim_colour.b, at.dim),
                        0.0,
                    )
                    .key("nav-dim"),
                    Alignment::CENTER,
                );
            }
            // Same wrapper shape in every role, so the page keeps its retained state when its role changes.
            let mut wrapper = page
                .frame(Some(w + at.x.min(0.0)), Some(h), Alignment::TOP_TRAILING)
                .padding(EdgeInsets {
                    top: 0.0,
                    leading: at.x.max(0.0),
                    bottom: 0.0,
                    trailing: 0.0,
                })
                .key(serial);
            if at.shadow > 0.0 {
                wrapper = wrapper.paint(Paint::Shadow {
                    style: ShadowStyle {
                        color: Color::new(0.0, 0.0, 0.0, at.shadow),
                        dx: -3.0,
                        dy: 0.0,
                        blur: 12.0,
                        spread: 0.0,
                    },
                    radius: 0.0,
                });
            }
            if style == NavStyle::Touch && i == layers.top && count > 1 {
                wrapper = wrapper.on_edge_pan(Edge::Left, BACK_SWIPE);
            }
            wrapper
        })
        .collect();
    if style == NavStyle::Desktop && layers.below.is_some() && top_x > 0.0 {
        let sw = tuning::DESKTOP_EDGE_WIDTH.min(top_x);
        let clear = Color::new(dim_colour.r, dim_colour.g, dim_colour.b, 0.0);
        let edge = Color::new(
            dim_colour.r,
            dim_colour.g,
            dim_colour.b,
            tuning::DESKTOP_EDGE_ALPHA,
        );
        // The visible part of the strip is its right end: the gradient is cut off by the window, not squeezed.
        let full = tuning::DESKTOP_EDGE_WIDTH;
        let g = Node::flexible()
            .paint(Paint::Linear {
                gradient: swiftly_render::LinearGradient::horizontal(clear, edge),
                radius: 0.0,
            })
            .frame(Some(full), Some(h), Alignment::TOP_LEADING)
            .frame(Some(sw), Some(h), Alignment::TOP_TRAILING)
            .clipped()
            .padding(EdgeInsets {
                top: 0.0,
                leading: top_x - sw,
                bottom: 0.0,
                trailing: 0.0,
            })
            .key("nav-edge");
        children.push(g);
    }
    Node::zstack(Alignment::TOP_LEADING, children)
        .frame(Some(w), Some(h), Alignment::TOP_LEADING)
        .clipped()
        .key(Key(0x6e61_7673))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cx::Cx;
    use crate::ui::Ui;
    use swiftly_layout::Align;
    use swiftly_render::Color;

    const W: f32 = 390.0;
    const H: f32 = 600.0;

    #[derive(Clone, PartialEq)]
    struct Parts {
        pos_bits: u64,
        count: usize,
    }

    /// Solid colour pages: page 0 is left green / right blue, page 1 red.
    fn page_node(i: usize) -> Node {
        match i {
            0 => Node::hstack(
                Align::Start,
                Some(0.0),
                vec![
                    Node::rect(Color::new(0.0, 1.0, 0.0, 1.0), 0.0),
                    Node::rect(Color::new(0.0, 0.0, 1.0, 1.0), 0.0),
                ],
            ),
            _ => Node::rect(Color::new(1.0, 0.0, 0.0, 1.0), 0.0),
        }
    }

    struct Rig {
        ui: Ui<Parts>,
        nav: Nav<usize>,
        now: f64,
    }

    impl Rig {
        fn new(style: NavStyle, depth: usize) -> Rig {
            let mut nav = Nav::new(0_usize, style);
            for i in 1..depth {
                nav.push(i, 0.0);
            }
            nav.update(10_000.0);
            let env = Env::phone(W, H, 1.0);
            let view = move |p: &Parts, env: &Env, _cx: &Cx| {
                let layers = Layers::at(f64::from_bits(p.pos_bits), p.count);
                let pages = (0..p.count).map(|i| (i as u64, page_node(i))).collect();
                stack_view(env, style, &layers, pages)
            };
            let parts = Parts {
                pos_bits: nav.position().to_bits(),
                count: nav.pages().count(),
            };
            let ui = Ui::new(view, parts, env, Cx::deterministic());
            Rig {
                ui,
                nav,
                now: 10_000.0,
            }
        }

        fn sync(&mut self) {
            self.ui.set_parts(Parts {
                pos_bits: self.nav.position().to_bits(),
                count: self.nav.pages().count(),
            });
        }

        /// One frame at `now`: nav, view, events.
        fn frame(&mut self, now: f64) {
            self.now = now;
            self.nav.update(now);
            self.sync();
            let _ = self.ui.frame(now);
            for ev in self.ui.take_events() {
                self.nav.handle(&ev, W, now);
            }
            self.sync();
        }

        fn run_to(&mut self, t: f64) {
            while self.now + 8.0 < t {
                self.frame(self.now + 8.0);
            }
            self.frame(t);
        }

        fn pixel(&mut self, x: usize, y: usize) -> [u8; 4] {
            let list = self.ui.frame(self.now);
            self.ui.render(&list, Color::BLACK).pixel(x, y)
        }
    }

    fn near(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol
    }

    #[test]
    fn layers_follow_the_position() {
        assert_eq!(Layers::at(0.0, 3).below, None);
        let l = Layers::at(1.0, 3);
        assert_eq!(
            (l.top, l.below),
            (1, None),
            "fully in: the page below is covered"
        );
        let l = Layers::at(1.5, 3);
        assert_eq!((l.top, l.below), (2, Some(1)));
        assert!(near(f64::from(l.fraction), 0.5, 1e-6));
        let l = Layers::at(0.25, 2);
        assert_eq!((l.top, l.below), (1, Some(0)));
    }

    #[test]
    fn desktop_push_is_ease_in_out_over_045_seconds_and_pop_returns() {
        let mut nav = Nav::new("home", NavStyle::Desktop);
        nav.push("detail", 1000.0);
        assert_eq!(nav.depth(), 2);
        nav.update(1000.0);
        assert!(nav.position().abs() < 1e-9);
        nav.update(1000.0 + 225.0);
        assert!(
            near(nav.position(), 0.5, 0.01),
            "easeInOut is 0.5 at half time"
        );
        let early = {
            nav.update(1000.0 + 90.0);
            nav.position()
        };
        assert!(early < 0.2, "slow start: {early}");
        assert!(nav.update(1000.0 + 440.0), "still moving at 440 ms");
        assert!(!nav.update(1000.0 + 450.0), "done at 450 ms");
        assert_eq!(nav.position(), 1.0);
        assert!(nav.pop(2000.0));
        assert_eq!(nav.depth(), 1);
        assert_eq!(nav.pages().count(), 2, "the page stays until it has left");
        nav.update(2000.0 + 450.0);
        assert_eq!(nav.pages().count(), 1);
        assert!(nav.position().abs() < 1e-9);
        assert!(!nav.pop(3000.0), "no pop at the root");
    }

    #[test]
    fn desktop_geometry_page_below_moves_30_percent_and_dims_28() {
        let l = Layers::at(0.5, 2);
        let top = place(NavStyle::Desktop, &l, 1, 1000.0);
        let below = place(NavStyle::Desktop, &l, 0, 1000.0);
        assert!(near(f64::from(top.x), 500.0, 0.01));
        assert!(near(f64::from(below.x), -150.0, 0.01));
        assert!(near(f64::from(below.dim), 0.14, 1e-6));
        let l = Layers::at(0.999_999_9, 2);
        let below = place(NavStyle::Desktop, &l, 0, 1000.0);
        assert!(near(f64::from(below.x), -300.0, 0.01) || l.below.is_none());
    }

    #[test]
    fn stack_view_puts_the_pages_where_place_says() {
        let mut rig = Rig::new(NavStyle::Desktop, 2);
        rig.nav = {
            let mut n = Nav::new(0_usize, NavStyle::Desktop);
            n.push(1, 0.0);
            n.update(225.0);
            n
        };
        rig.frame(225.0);
        let (px, py) = (|f: f32| (W * f) as usize, 100);
        // Top page (red) starts at 0.5 W. Page below (green | blue) is shifted by -0.15 W and dimmed 14 %.
        assert_eq!(rig.pixel(px(0.75), py), [255, 0, 0, 255]);
        let green = rig.pixel(px(0.30), py);
        let blue = rig.pixel(px(0.40), py); // left of the 28 pt edge strip
        assert!(
            green[1] > 200 && green[1] < 240 && green[0] <= 3, // dimmed with #101010, not black
            "{green:?}"
        );
        assert!(blue[2] > 200 && blue[2] < 240 && blue[1] <= 3, "{blue:?}");
    }

    #[test]
    fn pages_stay_alive_off_screen() {
        let mut rig = Rig::new(NavStyle::Desktop, 3);
        let before = rig.ui.state_count();
        rig.nav.pop(rig.now);
        rig.run_to(rig.now + 600.0);
        assert_eq!(rig.nav.depth(), 2);
        assert!(before >= rig.ui.state_count());
        let p = rig.pixel(10, 10);
        assert_eq!(p, [255, 0, 0, 255], "page 1 is on top, red");
    }

    /// A drag from the edge: down at x = 5, then moves with the given x values at 8 ms steps.
    fn swipe(rig: &mut Rig, xs: &[f32], up_after_ms: f64) -> f64 {
        let t0 = rig.now + 8.0;
        rig.run_to(t0);
        rig.ui.touch_down(5.0, 300.0, t0);
        let mut t = t0;
        for &x in xs {
            t += 8.0;
            rig.run_to(t - 4.0);
            rig.ui.touch_move(x, 300.0, t);
            rig.frame(t);
        }
        t += up_after_ms;
        rig.run_to(t);
        rig.ui.touch_up(*xs.last().unwrap_or(&5.0), 300.0, t);
        rig.frame(t);
        t
    }

    #[test]
    fn swipe_follows_the_finger_one_to_one_and_completes_with_speed() {
        let mut rig = Rig::new(NavStyle::Touch, 2);
        assert_eq!(rig.nav.position(), 1.0);
        // 25 px every 8 ms = 3125 pt/s, ending at 205.
        let xs: Vec<f32> = (1..=8).map(|i| 5.0 + 25.0 * i as f32).collect();
        let t = swipe(&mut rig, &xs, 0.0);
        assert_eq!(rig.nav.depth(), 1, "projected past the middle: pops");
        rig.run_to(t + 1000.0);
        assert_eq!(rig.nav.pages().count(), 1);
        assert_eq!(rig.nav.position(), 0.0);
    }

    #[test]
    fn while_the_finger_is_down_the_page_edge_is_the_finger() {
        let mut rig = Rig::new(NavStyle::Touch, 2);
        let t0 = rig.now + 8.0;
        rig.run_to(t0);
        rig.ui.touch_down(5.0, 300.0, t0);
        let mut grab = None;
        for i in 1..=12 {
            let t = t0 + 8.0 * f64::from(i);
            let x = 5.0 + 12.0 * i as f32;
            rig.ui.touch_move(x, 300.0, t);
            rig.frame(t);
            if rig.nav.is_swiping() && grab.is_none() {
                grab = Some(x);
            }
            if let Some(g) = grab {
                let edge = f64::from(W) * (1.0 - rig.nav.position());
                assert!(
                    near(edge, f64::from(x - g), 0.01),
                    "edge {edge} vs finger {}",
                    x - g
                );
            }
        }
        assert!(grab.is_some(), "the edge pan began");
        // And the real page really is there: red from the edge on, the page below to its left.
        let edge = (f64::from(W) * (1.0 - rig.nav.position())) as usize;
        assert_eq!(rig.pixel(edge + 3, 300), [255, 0, 0, 255]);
        assert_ne!(rig.pixel(edge.saturating_sub(5), 300)[0], 255);
    }

    #[test]
    fn slow_short_swipe_cancels_and_the_page_returns() {
        let mut rig = Rig::new(NavStyle::Touch, 2);
        // 2 px per 8 ms = 250 pt/s, ending at x = 85 after 40 steps; then a pause before lifting.
        let xs: Vec<f32> = (1..=40).map(|i| 5.0 + 2.0 * i as f32).collect();
        let t = swipe(&mut rig, &xs, 200.0);
        assert_eq!(rig.nav.depth(), 2, "cancelled");
        rig.run_to(t + 1000.0);
        assert_eq!(rig.nav.position(), 1.0);
        assert_eq!(rig.nav.pages().count(), 2);
    }

    #[test]
    fn reversing_mid_swipe_never_jumps_and_the_release_keeps_position_and_velocity() {
        let mut rig = Rig::new(NavStyle::Touch, 2);
        let t0 = rig.now + 8.0;
        rig.run_to(t0);
        rig.ui.touch_down(5.0, 300.0, t0);
        // Right to 200, back left to 60, right again to 180, all at 8 ms steps and ~12 pt per step.
        let mut path: Vec<f32> = vec![];
        path.extend((1..=16).map(|i| 5.0 + 12.0 * i as f32));
        path.extend((1..=12).map(|i| 197.0 - 12.0 * i as f32));
        path.extend((1..=10).map(|i| 53.0 + 12.0 * i as f32));
        let mut last_pos = rig.nav.position();
        let mut last_x = 5.0_f32;
        let mut t = t0;
        for &x in &path {
            t += 8.0;
            rig.ui.touch_move(x, 300.0, t);
            rig.frame(t);
            let pos = rig.nav.position();
            let step_pages = f64::from((x - last_x).abs()) / f64::from(W);
            assert!(
                (pos - last_pos).abs() <= step_pages + 1e-9,
                "position jumped by {} for a finger step of {}",
                (pos - last_pos).abs(),
                step_pages
            );
            last_pos = pos;
            last_x = x;
        }
        assert!(rig.nav.is_swiping());
        let (pos_before, vel_before) = (rig.nav.position(), rig.nav.velocity());
        assert!(
            vel_before < 0.0,
            "moving back towards the page being in: pos falls with the finger: {vel_before}"
        );
        // Lift at the last sample's time.
        rig.ui.touch_up(last_x, 300.0, t);
        let events = rig.ui.take_events();
        for ev in &events {
            rig.nav.handle(ev, W, t);
        }
        assert!(!rig.nav.is_swiping());
        assert!(
            near(rig.nav.position(), pos_before, 1e-9),
            "no jump in position at release"
        );
        let vel_after = rig.nav.velocity();
        assert!(
            near(vel_after, vel_before, 0.15 * vel_before.abs() + 0.05),
            "velocity before {vel_before}, after {vel_after}"
        );
        // The spring carries the velocity on: half a millisecond later position and speed have hardly moved.
        rig.nav.update(t + 0.5);
        let v1 = rig.nav.velocity();
        assert!(
            (v1 - vel_after).abs() < 0.05 * vel_after.abs() + 0.05,
            "v {vel_after} -> {v1}"
        );
        assert!((rig.nav.position() - pos_before).abs() < 0.002);
    }

    #[test]
    fn catching_a_moving_page_does_not_jump() {
        let mut rig = Rig::new(NavStyle::Touch, 2);
        rig.nav.pop(rig.now);
        rig.run_to(rig.now + 100.0);
        let mid = rig.nav.position();
        assert!(mid > 0.0 && mid < 1.0);
        assert!(rig.nav.swipe_begin(10.0, rig.now));
        assert_eq!(rig.nav.position(), mid, "caught where it is");
        rig.nav.swipe_move(10.0, 0.0, W);
        assert_eq!(rig.nav.position(), mid, "no jump by the grab offset");
        assert_eq!(
            rig.nav.depth(),
            2,
            "caught: the pop is undone until the finger decides"
        );
    }

    #[test]
    fn touch_push_springs_in_and_back_button_pop_springs_out() {
        let mut nav = Nav::new('a', NavStyle::Touch);
        nav.push('b', 0.0);
        nav.update(175.0);
        let mid = nav.position();
        assert!(mid > 0.3 && mid < 1.0, "{mid}");
        nav.update(1000.0);
        assert_eq!(nav.position(), 1.0);
        assert!(!nav.is_animating());
    }

    #[test]
    fn reduce_motion_makes_the_push_linear_014() {
        let mut nav = Nav::new('a', NavStyle::Desktop);
        nav.set_reduce_motion(true);
        nav.push('b', 0.0);
        nav.update(70.0);
        assert!(near(nav.position(), 0.5, 0.01));
        nav.update(141.0);
        assert_eq!(nav.position(), 1.0);
    }

    #[test]
    fn desktop_push_draws_the_28_pt_edge_gradient_left_of_the_page_and_dims_with_101010() {
        let mut rig = Rig::new(NavStyle::Desktop, 2);
        let t0 = rig.now;
        assert!(rig.nav.pop(t0));
        rig.run_to(t0 + 225.0);
        let blue = |p: [u8; 4]| i32::from(p[2]);
        let far = blue(rig.pixel(150, 300));
        let near_edge = blue(rig.pixel(193, 300));
        assert!(far > 150, "the page below shows blue: {far}");
        assert!(
            near_edge < far - 60,
            "the strip darkens next to the edge: {near_edge} vs {far}"
        );
        let at_edge = blue(rig.pixel(194, 300));
        assert!(
            at_edge < near_edge || at_edge < 120,
            "strongest at the page edge: {at_edge}"
        );
        assert!(rig.ui.node_values("nav-edge").is_some());
        rig.run_to(t0 + 600.0);
        assert!(
            rig.ui.node_values("nav-edge").is_none(),
            "no strip once the page has left"
        );
        let mut touch = Rig::new(NavStyle::Touch, 2);
        let t1 = touch.now;
        touch.nav.pop(t1);
        touch.run_to(t1 + 150.0);
        assert!(
            touch.ui.node_values("nav-edge").is_none(),
            "touch keeps its own shadow"
        );
    }

    #[test]
    fn an_interrupted_desktop_push_blends_additively_like_swiftui() {
        use swiftly_motion::Ease;
        let mut nav = Nav::new("home", NavStyle::Desktop);
        nav.push("detail", 0.0);
        nav.update(225.0);
        let mid = nav.position();
        assert!(near(mid, 0.5, 0.01));
        assert!(nav.pop(225.0));
        nav.update(225.0);
        assert!(
            near(nav.position(), mid, 1e-9),
            "no jump at the interruption"
        );
        // `shouldMerge` is false for a bezier: both run on and their vectors add: e1(t + 225) - e2(t).
        let mut peak: f64 = 0.0;
        for t in (8..=450).step_by(8) {
            nav.update(225.0 + f64::from(t));
            let want = Ease::InOut.at((225.0 + f64::from(t)) / 450.0)
                - Ease::InOut.at(f64::from(t) / 450.0);
            assert!(
                near(nav.position(), want, 0.005),
                "{t} ms: {} vs {want}",
                nav.position()
            );
            peak = peak.max(nav.position());
        }
        assert!(
            peak > mid + 0.05,
            "the page carries on before it turns back: {peak}"
        );
        nav.update(225.0 + 451.0);
        assert!(nav.position().abs() < 1e-9);
    }
}
