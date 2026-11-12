//! The UI driver: owns the retained tree, runs `view` when its inputs change, turns touches into gestures and scroll
//! motion, and builds the draw list of a frame.

use crate::anim::Motion;
use crate::cx::Cx;
use crate::env::Env;
use crate::focus::{Focus, FocusId, FocusMap, Item, NavKey, Outcome};
use crate::interact::{Cursor, PressStyle};
use crate::tree::{
    FocusNode, Ghost, HitEntry, NodeState, PaintCx, Press, RNode, Rec, Win, Xf, apply, child_id,
    collect_ids, extract_exits, find_key, focus_nodes, frame_of_key, hit, materialize, mirror,
    paint, reconcile, scroll_nodes,
};
use crate::tree::{PEntry, bar_views, pointer_hit};
use crate::tuning;
use crate::view::{Action, Edge, Key, Node};
use std::collections::{HashMap, HashSet};
use swiftly_layout::{Alignment, Axis, Point, Rect};
use swiftly_motion::catalogue::Id;
use swiftly_motion::{Os, ScrollTuning};
use swiftly_render::{Color, DrawList, RgbaImage, SoftwareRenderer, Sources};

/// The phase of a continuous gesture.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// The gesture was recognised.
    Began,
    /// The finger moved.
    Changed,
    /// The finger lifted.
    Ended,
    /// The gesture was cancelled.
    Cancelled,
}

/// What the UI reports to the app.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum UiEvent {
    /// A tap on a node.
    Tap(Action),
    /// A long press fired.
    LongPress(Action),
    /// The pointer entered (`entered`) or left a node that declared `on_hover`.
    HoverChanged {
        /// The node's action.
        action: Action,
        /// True on enter, false on leave.
        entered: bool,
    },
    /// The pointer rested on a node that declared `on_hover_rest` for 150 ms (ask the server now).
    HoverRest(Action),
    /// A secondary (right) click on a node that declared `on_secondary`, at window point `(x, y)`.
    Secondary {
        /// The node's action.
        action: Action,
        /// X in window points.
        x: f32,
        /// Y in window points.
        y: f32,
    },
    /// A free or axis-locked pan.
    Pan {
        /// The node's action.
        action: Action,
        /// Phase.
        phase: Phase,
        /// Movement since the touch began.
        translation: (f32, f32),
        /// Finger velocity in pt/s.
        velocity: (f32, f32),
    },
    /// A pan that began at a screen edge.
    EdgePan {
        /// The node's action.
        action: Action,
        /// Phase.
        phase: Phase,
        /// Movement as a share of the window width (0 to 1, inwards).
        progress: f32,
        /// Movement since the touch began.
        translation: (f32, f32),
        /// Finger velocity in pt/s.
        velocity: (f32, f32),
    },
}

/// The retained values of a node, for tests and tools.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NodeValues {
    /// Scale about the centre (1 at rest, 0.97 pressed).
    pub scale: f64,
    /// Opacity (1 at rest, 0.85 pressed).
    pub opacity: f64,
    /// A touch is held on the node.
    pub pressed: bool,
}

#[derive(Clone, Copy, Debug)]
enum Mode {
    Undecided,
    Scroll {
        id: u64,
        axis: Axis,
        snap: Option<f32>,
    },
    Pan {
        action: Action,
    },
    EdgePan {
        action: Action,
        edge: Edge,
    },
    /// The thumb of an overlay scroll bar is held; `grab` is the press point's distance below the thumb top.
    Bar {
        id: u64,
        grab: f32,
    },
}

struct Arena {
    down: Point,
    down_t: f64,
    last: Point,
    entries: Vec<HitEntry>,
    press_node: Option<u64>,
    tap_failed: bool,
    long_fired: bool,
    suppress_tap: bool,
    mode: Mode,
    samples: Vec<(f64, f32, f32)>,
}

/// The pointer's current state: where it is, what it hovers, what is pending.
#[derive(Default)]
struct PointerState {
    pos: Option<Point>,
    hovered: Vec<u64>,
    cursor: Cursor,
    /// Node whose rest action is pending and since when.
    rest: Option<(u64, Action, f64)>,
    rest_fired: bool,
    /// Tooltip candidate: node, text, anchor rect, since when.
    tip: Option<(u64, String, swiftly_layout::Rect, f64)>,
    /// A click hides the tooltip of that node until the pointer leaves it.
    tip_dismissed: Option<u64>,
}

type ViewFn<P> = Box<dyn Fn(&P, &Env, &Cx) -> Node>;

thread_local! {
    /// Set by the shell around a precision-touchpad event (see [`set_precise_wheel`]).
    static PRECISE_WHEEL: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Marks the `wheel_scroll` calls that follow as a precision touchpad's (1:1, rubber band) instead of a wheel notch's
/// (clamped). The screens forward `wheel_scroll` unchanged, so the mode travels beside the call. Clear it after the call.
pub fn set_precise_wheel(on: bool) {
    PRECISE_WHEEL.with(|c| c.set(on));
}

/// The shared UI: a `view` function, its inputs and the retained tree.
pub struct Ui<P> {
    view: ViewFn<P>,
    parts: P,
    env: Env,
    cx: Cx,
    root: Option<RNode>,
    states: HashMap<u64, NodeState>,
    seen: HashSet<u64>,
    arena: Option<Arena>,
    events: Vec<UiEvent>,
    now: f64,
    view_runs: usize,
    focus: Focus,
    fmap: FocusMap,
    fnodes: Vec<FocusNode>,
    focus_visible: bool,
    pointer: PointerState,
    hover_actions: HashMap<u64, Action>,
    scroll_tuning: ScrollTuning,
    tap_cursor: Option<Cursor>,
    /// Nodes that left the tree and play their exit transition.
    ghosts: Vec<Ghost>,
}

impl<P: PartialEq + Clone> Ui<P> {
    /// Builds the first tree from `view(&parts, &env, &cx)`.
    pub fn new(
        view: impl Fn(&P, &Env, &Cx) -> Node + 'static,
        parts: P,
        env: Env,
        cx: Cx,
    ) -> Ui<P> {
        let mut ui = Ui {
            view: Box::new(view),
            parts,
            env,
            cx,
            root: None,
            states: HashMap::new(),
            seen: HashSet::new(),
            arena: None,
            events: Vec::new(),
            now: 0.0,
            view_runs: 0,
            focus: Focus::new(),
            fmap: FocusMap::new(),
            fnodes: vec![],
            focus_visible: false,
            pointer: PointerState::default(),
            hover_actions: HashMap::new(),
            scroll_tuning: ScrollTuning::touch(),
            tap_cursor: None,
            ghosts: Vec::new(),
        };
        ui.scroll_tuning = match ui.env.idiom {
            crate::env::Idiom::Desktop => ScrollTuning::for_os(Os::current()),
            _ => ScrollTuning::touch(),
        };
        ui.focus_visible = ui.env.idiom == crate::env::Idiom::Tv;
        ui.rebuild();
        ui
    }

    /// New inputs from the core. Runs `view` only when they differ. Returns whether it ran.
    pub fn set_parts(&mut self, parts: P) -> bool {
        if parts == self.parts {
            return false;
        }
        self.parts = parts;
        self.rebuild();
        true
    }

    /// A new environment (resize, rotation, size class, Reduce Motion). Runs `view` only when it differs.
    pub fn set_env(&mut self, env: Env) -> bool {
        if env == self.env {
            return false;
        }
        self.env = env;
        self.rebuild();
        true
    }

    /// The environment.
    pub fn env(&self) -> &Env {
        &self.env
    }

    /// The shared services (fonts, images).
    pub fn cx(&self) -> &Cx {
        &self.cx
    }

    /// How many times `view` has run.
    pub fn view_runs(&self) -> usize {
        self.view_runs
    }

    fn rebuild(&mut self) {
        self.view_runs += 1;
        let win = self.window();
        let node = (self.view)(&self.parts, &self.env, &self.cx);
        let old = self.root.take();
        self.seen.clear();
        let mut rec = Rec {
            states: &mut self.states,
            seen: &mut self.seen,
            now: self.now,
            reduce: self.env.reduce_motion,
            scroll: self.scroll_tuning,
            first: self.view_runs == 1,
        };
        let id = child_id(0, node.key, 0, node.name);
        let mut root = reconcile(&mut rec, node, id);
        let placed =
            swiftly_layout::layout_aligned(&mirror(&root), self.env.size, Alignment::TOP_LEADING);
        apply(&mut root, &placed, &mut rec);
        materialize(&mut root, Point::new(0.0, 0.0), win, &mut rec);
        // A node with an exit transition that is gone now stays as a ghost; one that came back takes its state over.
        let seen = &self.seen;
        self.ghosts.retain(|g| !seen.contains(&g.node.id));
        let mut gone = Vec::new();
        if let Some(mut old) = old {
            extract_exits(
                &mut old,
                Point::new(0.0, 0.0),
                &self.states,
                seen,
                &mut gone,
            );
        }
        for g in &gone {
            let (scale, opacity) = g.node.exit.unwrap_or((1.0, 0.0));
            let reduce = self.env.reduce_motion;
            let motion = g.node.motion.resolved(reduce);
            if let Some(st) = self.states.get_mut(&g.node.id) {
                let to_scale = if reduce {
                    st.decl_scale.target()
                } else {
                    f64::from(scale)
                };
                st.decl_scale.set_target(to_scale, self.now, motion);
                st.decl_opacity
                    .set_target(f64::from(opacity), self.now, motion);
                if let (Some((dx, dy)), false) = (g.node.exit_offset, reduce) {
                    st.decl_dx.set_target(f64::from(dx), self.now, motion);
                    st.decl_dy.set_target(f64::from(dy), self.now, motion);
                }
            }
        }
        self.ghosts.extend(gone);
        let mut keep = HashSet::new();
        for g in &self.ghosts {
            collect_ids(&g.node, &mut keep);
        }
        self.states
            .retain(|k, _| seen.contains(k) || keep.contains(k));
        self.root = Some(root);
        self.refresh_focus();
        if self.pointer.pos.is_some() {
            self.refresh_pointer(self.now);
        }
    }

    fn window(&self) -> Win {
        Win {
            x0: 0.0,
            x1: self.env.size.w,
            y0: 0.0,
            y1: self.env.size.h,
        }
    }

    /// Builds the lazy items near the scrolled windows (after offsets changed).
    fn sync_windows(&mut self) {
        let win = self.window();
        let Some(root) = self.root.as_mut() else {
            return;
        };
        let mut rec = Rec {
            states: &mut self.states,
            seen: &mut self.seen,
            now: self.now,
            reduce: self.env.reduce_motion,
            scroll: self.scroll_tuning,
            first: false,
        };
        materialize(root, Point::new(0.0, 0.0), win, &mut rec);
        self.refresh_focus();
    }

    // ---- frame loop ------------------------------------------------------------------------------------------

    /// Advances animations, scroll bodies, press delays and the long-press timer to `now_ms`, then emits the quads.
    pub fn frame(&mut self, now_ms: f64) -> DrawList {
        self.tick(now_ms);
        let mut list = DrawList::new(self.env.size.w, self.env.size.h, self.env.scale);
        let mut ts = self.cx.text.borrow_mut();
        ts.atlas.begin_frame();
        if let Some(root) = &self.root {
            let mut pc = PaintCx {
                list: &mut list,
                text: &mut ts,
                states: &self.states,
            };
            paint(root, Point::new(0.0, 0.0), Xf::ID, &mut pc, true, 0.0);
            for g in &self.ghosts {
                paint(&g.node, g.origin, Xf::ID, &mut pc, false, 0.0);
            }
        }
        if let Some((text, anchor)) = self.visible_tooltip(now_ms) {
            // The Mac's own tooltip (`PlayerLayers.swift:97-100`) fades in with `timeFloat` once its 0.5 s have passed.
            let alpha = self.tooltip_alpha(now_ms);
            if alpha < 0.999 {
                list.push_opacity(alpha);
            }
            draw_tooltip(&mut list, &mut ts, &text, anchor);
            if alpha < 0.999 {
                list.pop_opacity();
            }
        }
        list
    }

    /// Whether another frame is needed (an animation, a glide, a delayed press or a held touch is running).
    pub fn needs_frame(&self) -> bool {
        self.arena.is_some()
            || self.focus.is_held()
            || self.pointer_timers_pending()
            || self.states.values().any(NodeState::busy)
            || self
                .states
                .values()
                .any(|s| s.scroll.is_some() && s.bar.pending(self.now))
    }

    fn tick(&mut self, now: f64) {
        self.now = now;
        let mut scrolled = false;
        let mut relayout = false;
        let reduce = self.env.reduce_motion;
        let desktop = self.env.idiom == crate::env::Idiom::Desktop;
        for st in self.states.values_mut() {
            if let Press::Armed {
                since,
                shown: false,
                in_scroll: true,
            } = st.press
                && now - since >= tuning::PRESS_DELAY_IN_SCROLL_MS
            {
                show_press(st, now);
            }
            st.decl_scale.advance(now);
            st.decl_opacity.advance(now);
            st.decl_dx.advance(now);
            st.decl_dy.advance(now);
            let (w0, h0) = (st.frame_w.value(), st.frame_h.value());
            st.frame_w.advance(now);
            st.frame_h.advance(now);
            relayout |= st.frame_w.value() != w0 || st.frame_h.value() != h0;
            st.press_scale.advance(now);
            st.press_opacity.advance(now);
            st.focus_t.advance(now);
            st.hover_t.advance(now);
            st.press_surface.advance(now);
            st.sel_t.advance(now);
            if st.scroll.is_some() {
                if st.scroll_pos != st.bar.seen {
                    st.bar.seen = st.scroll_pos;
                    st.bar.active_at = now;
                }
                st.bar.alpha = if desktop {
                    st.bar.alpha_at(now, reduce)
                } else {
                    0.0
                };
            }
            if let Some(b) = st.scroll.as_mut()
                && b.needs_frames()
            {
                let pos = b.offset(now);
                if pos != st.scroll_pos {
                    st.scroll_pos = pos;
                    scrolled = true;
                }
            }
        }
        // A ghost goes when its exit transition has run out.
        if !self.ghosts.is_empty() {
            let states = &self.states;
            let (done, alive): (Vec<Ghost>, Vec<Ghost>) =
                std::mem::take(&mut self.ghosts).into_iter().partition(|g| {
                    states.get(&g.node.id).is_none_or(|s| {
                        !s.decl_scale.is_active()
                            && !s.decl_opacity.is_active()
                            && !s.decl_dx.is_active()
                            && !s.decl_dy.is_active()
                    })
                });
            self.ghosts = alive;
            for g in &done {
                let mut ids = HashSet::new();
                collect_ids(&g.node, &mut ids);
                self.states.retain(|k, _| !ids.contains(k));
            }
        }
        if let Some(a) = self.arena.as_mut()
            && matches!(a.mode, Mode::Undecided)
            && !a.tap_failed
            && !a.long_fired
            && now - a.down_t >= tuning::LONG_PRESS_MS
            && let Some(action) = a.entries.iter().rev().find_map(|e| e.gestures.long_press)
        {
            a.long_fired = true;
            self.events.push(UiEvent::LongPress(action));
        }
        if let Outcome::LongPressed(_, Some(action)) = self.focus.tick(&self.fmap, now) {
            self.events.push(UiEvent::LongPress(action));
        }
        if let Some((_, action, since)) = self.pointer.rest
            && !self.pointer.rest_fired
            && now - since >= crate::feel::HOVER_REST_MS
        {
            self.pointer.rest_fired = true;
            self.events.push(UiEvent::HoverRest(action));
        }
        if relayout {
            // An animated frame size changed: the tree is laid out again with the new size (an animated frame is rare and small).
            self.rebuild();
        }
        if scrolled {
            self.sync_windows();
            if self.pointer.pos.is_some() {
                self.refresh_pointer(now);
            }
        }
    }

    /// Takes the events produced since the last call.
    pub fn take_events(&mut self) -> Vec<UiEvent> {
        std::mem::take(&mut self.events)
    }

    // ---- touch input -----------------------------------------------------------------------------------------

    /// A finger touches down at `(x, y)` points at `now_ms`.
    pub fn touch_down(&mut self, x: f32, y: f32, now_ms: f64) {
        if self.env.idiom != crate::env::Idiom::Tv && self.focus_visible {
            self.focus_visible = false;
            self.apply_focus_visuals(now_ms);
        }
        if self.arena.is_some() {
            self.touch_cancel(now_ms);
        }
        self.tick(now_ms);
        if self.bar_press(x, y, now_ms) {
            return;
        }
        if let Some((id, ..)) = &self.pointer.tip {
            self.pointer.tip_dismissed = Some(*id);
        }
        let mut entries = Vec::new();
        if let Some(root) = &self.root {
            hit(root, Point::new(x, y), &self.states, &mut entries);
        }
        let mut mode = Mode::Undecided;
        let mut suppress_tap = false;
        for e in entries.iter().rev() {
            let Some(spec) = e.scroll else { continue };
            let Some(st) = self.states.get_mut(&e.id) else {
                continue;
            };
            if let Some(b) = st.scroll.as_mut()
                && b.needs_frames()
            {
                b.touch_down(now_ms);
                st.scroll_pos = b.position();
                suppress_tap = true;
                mode = Mode::Scroll {
                    id: e.id,
                    axis: spec.axis,
                    snap: spec.snap_step,
                };
                break;
            }
        }
        let press_idx = entries
            .iter()
            .rposition(|e| e.press && e.gestures.tap.is_some());
        let mut press_node = None;
        if let (Some(i), false) = (press_idx, suppress_tap) {
            let id = entries[i].id;
            let in_scroll = self.env.input != crate::env::InputMode::Pointer
                && entries[..i].iter().any(|e| e.scroll.is_some());
            if let Some(st) = self.states.get_mut(&id) {
                st.press = Press::Armed {
                    since: now_ms,
                    shown: false,
                    in_scroll,
                };
                if !in_scroll {
                    show_press(st, now_ms);
                }
                press_node = Some(id);
            }
        }
        self.arena = Some(Arena {
            down: Point::new(x, y),
            down_t: now_ms,
            last: Point::new(x, y),
            entries,
            press_node,
            tap_failed: false,
            long_fired: false,
            suppress_tap,
            mode,
            samples: vec![(now_ms, x, y)],
        });
    }

    /// The finger moved to `(x, y)`.
    pub fn touch_move(&mut self, x: f32, y: f32, now_ms: f64) {
        let Some(mut a) = self.arena.take() else {
            return;
        };
        a.samples.push((now_ms, x, y));
        a.samples
            .retain(|s| now_ms - s.0 <= tuning::PAN_VELOCITY_WINDOW_MS * 2.0);
        let (dx, dy) = (x - a.down.x, y - a.down.y);
        let dist = dx.hypot(dy);
        match a.mode {
            Mode::Undecided => self.decide(&mut a, x, y, (dx, dy), dist, now_ms),
            Mode::Scroll { id, axis, .. } => {
                let delta = match axis {
                    Axis::Horizontal => a.last.x - x,
                    Axis::Vertical => a.last.y - y,
                };
                if let Some(st) = self.states.get_mut(&id)
                    && let Some(b) = st.scroll.as_mut()
                {
                    b.touch_move(f64::from(delta), now_ms);
                    st.scroll_pos = b.position();
                }
                a.last = Point::new(x, y);
                self.sync_windows();
            }
            Mode::Bar { id, grab } => self.bar_drag(id, grab, y, now_ms),
            Mode::Pan { action } => {
                let velocity = velocity_of(&a.samples, now_ms);
                self.events.push(UiEvent::Pan {
                    action,
                    phase: Phase::Changed,
                    translation: (dx, dy),
                    velocity,
                });
            }
            Mode::EdgePan { action, edge } => {
                let velocity = velocity_of(&a.samples, now_ms);
                self.events.push(UiEvent::EdgePan {
                    action,
                    phase: Phase::Changed,
                    progress: self.edge_progress(edge, a.down.x, x),
                    translation: (dx, dy),
                    velocity,
                });
            }
        }
        self.arena = Some(a);
    }

    // ---- overlay scroll bar ----------------------------------------------------------------------------------

    fn bar_list(&self) -> Vec<(u64, Rect)> {
        let mut v = Vec::new();
        if let Some(root) = &self.root {
            bar_views(root, Point::new(0.0, 0.0), &self.states, &mut v);
        }
        v
    }

    /// The innermost bar whose edge strip holds `(x, y)`.
    fn bar_under(&self, x: f32, y: f32) -> Option<(u64, Rect)> {
        self.bar_list().into_iter().rev().find(|(_, v)| {
            x >= v.x + v.w - crate::scrollbar::ZONE
                && x <= v.x + v.w
                && y >= v.y
                && y <= v.y + v.h
                && v.h >= 2.0 * crate::scrollbar::MIN_THUMB
        })
    }

    /// The pointer (no button) moved: the bar under it wakes; one it left starts to fade.
    fn bars_hot(&mut self, at: Option<Point>, now: f64) {
        let under = at.and_then(|p| self.bar_under(p.x, p.y)).map(|(id, _)| id);
        for (id, st) in &mut self.states {
            let hot = under == Some(*id);
            if st.bar.hot && !hot {
                st.bar.active_at = now;
            }
            st.bar.hot = hot;
        }
    }

    /// A press in the edge strip of a visible bar: the thumb is grabbed, the track pages. True when it took the press.
    fn bar_press(&mut self, x: f32, y: f32, now: f64) -> bool {
        let Some((id, v)) = self.bar_under(x, y) else {
            return false;
        };
        let Some(st) = self.states.get(&id) else {
            return false;
        };
        if st.bar.alpha < 0.05 && !st.bar.hot {
            return false;
        }
        let Some(b) = st.scroll.as_ref() else {
            return false;
        };
        let t = crate::scrollbar::track(v, crate::scrollbar::WIDTH_HOT);
        let Some(th) = crate::scrollbar::thumb(t, st.scroll_pos, b.metrics) else {
            return false;
        };
        if y >= th.y && y <= th.y + th.h {
            if let Some(st) = self.states.get_mut(&id) {
                st.bar.dragging = true;
                st.bar.active_at = now;
                if let Some(b) = st.scroll.as_mut() {
                    b.jump_to(st.scroll_pos);
                }
            }
            self.arena = Some(Arena {
                down: Point::new(x, y),
                down_t: now,
                last: Point::new(x, y),
                entries: Vec::new(),
                press_node: None,
                tap_failed: true,
                long_fired: false,
                suppress_tap: true,
                mode: Mode::Bar { id, grab: y - th.y },
                samples: Vec::new(),
            });
        } else if self.pointer.pos.is_none() {
            // A finger on the track beside the thumb scrolls the page like anywhere else; only a pointer pages.
            return false;
        } else {
            // A click in the track pages by nearly one view height, towards the click.
            let dir = if y < th.y { -1.0 } else { 1.0 };
            let delta = dir * b.metrics.viewport * 0.9;
            let reduce = self.env.reduce_motion;
            if let Some(st) = self.states.get_mut(&id)
                && let Some(b) = st.scroll.as_mut()
            {
                let at = b.position();
                let target = b.metrics.clamp(at + delta);
                if reduce {
                    b.jump_to(target);
                } else {
                    b.animate_curve(target, Id::Reveal.curve(), now);
                }
                st.scroll_pos = b.position();
                st.bar.active_at = now;
            }
            self.sync_windows();
        }
        true
    }

    /// The held thumb follows the pointer: the offset it stands for, 1:1.
    fn bar_drag(&mut self, id: u64, grab: f32, y: f32, now: f64) {
        let Some(v) = self
            .bar_list()
            .into_iter()
            .find(|(i, _)| *i == id)
            .map(|(_, v)| v)
        else {
            return;
        };
        let Some(st) = self.states.get_mut(&id) else {
            return;
        };
        let Some(b) = st.scroll.as_mut() else { return };
        let t = crate::scrollbar::track(v, crate::scrollbar::WIDTH_HOT);
        let Some(th) = crate::scrollbar::thumb(t, st.scroll_pos, b.metrics) else {
            return;
        };
        b.jump_to(crate::scrollbar::offset_for(t, th.h, y - grab, b.metrics));
        st.scroll_pos = b.position();
        st.bar.active_at = now;
        self.sync_windows();
    }

    fn bar_release(&mut self, id: u64, now: f64) {
        if let Some(st) = self.states.get_mut(&id) {
            st.bar.dragging = false;
            st.bar.active_at = now;
        }
    }

    /// `(thumb rect in window points, opacity)` of the first vertical bar that has a thumb (tests, measuring).
    pub fn scroll_bar(&self) -> Option<(swiftly_layout::Rect, f32)> {
        let (id, v) = self.bar_list().into_iter().next()?;
        let st = self.states.get(&id)?;
        let t = crate::scrollbar::track(v, crate::scrollbar::WIDTH);
        Some((
            crate::scrollbar::thumb(t, st.scroll_pos, st.scroll.as_ref()?.metrics)?,
            st.bar.alpha,
        ))
    }

    fn edge_progress(&self, edge: Edge, down_x: f32, x: f32) -> f32 {
        let w = self.env.size.w.max(1.0);
        match edge {
            Edge::Left => (x - down_x) / w,
            Edge::Right => (down_x - x) / w,
        }
    }

    fn decide(&mut self, a: &mut Arena, x: f32, y: f32, d: (f32, f32), dist: f32, now: f64) {
        let h = tuning::HYSTERESIS_PT;
        // Edge pan wins over everything under it when the touch began in the edge strip.
        for e in a.entries.iter().rev() {
            let Some((edge, action)) = e.gestures.edge_pan else {
                continue;
            };
            let in_strip = match edge {
                Edge::Left => a.down.x <= tuning::EDGE_PAN_WIDTH_PT,
                Edge::Right => a.down.x >= self.env.size.w - tuning::EDGE_PAN_WIDTH_PT,
            };
            let inward = match edge {
                Edge::Left => d.0,
                Edge::Right => -d.0,
            };
            if in_strip && inward >= h && d.0.abs() >= d.1.abs() * tuning::AXIS_LOCK_RATIO {
                a.mode = Mode::EdgePan { action, edge };
                self.fail_tap(a, now);
                self.events.push(UiEvent::EdgePan {
                    action,
                    phase: Phase::Began,
                    progress: self.edge_progress(edge, a.down.x, x),
                    translation: d,
                    velocity: (0.0, 0.0),
                });
                return;
            }
        }
        if dist <= h {
            return;
        }
        self.fail_tap(a, now);
        let locked = |axis: Axis| {
            let (along, across) = match axis {
                Axis::Horizontal => (d.0.abs(), d.1.abs()),
                Axis::Vertical => (d.1.abs(), d.0.abs()),
            };
            along >= h && along >= across * tuning::AXIS_LOCK_RATIO
        };
        for e in a.entries.iter().rev() {
            if let Some(spec) = e.scroll
                && locked(spec.axis)
            {
                if let Some(st) = self.states.get_mut(&e.id)
                    && let Some(b) = st.scroll.as_mut()
                {
                    b.touch_down(now);
                    st.scroll_pos = b.position();
                }
                a.mode = Mode::Scroll {
                    id: e.id,
                    axis: spec.axis,
                    snap: spec.snap_step,
                };
                a.last = Point::new(x, y);
                return;
            }
            if let Some((axis, action)) = e.gestures.pan
                && axis.is_none_or(locked)
            {
                a.mode = Mode::Pan { action };
                self.events.push(UiEvent::Pan {
                    action,
                    phase: Phase::Began,
                    translation: d,
                    velocity: (0.0, 0.0),
                });
                return;
            }
        }
    }

    /// The touch is no longer a tap: cancel the press feedback and the long press.
    fn fail_tap(&mut self, a: &mut Arena, now: f64) {
        a.tap_failed = true;
        if let Some(id) = a.press_node.take() {
            self.release_press(id, now);
        }
    }

    fn release_press(&mut self, id: u64, now: f64) {
        let reduce = self.env.reduce_motion;
        if let Some(st) = self.states.get_mut(&id) {
            st.press = Press::Idle;
            let m = crate::feel::press_release().resolved(reduce);
            st.press_scale.set_target(1.0, now, m);
            st.press_opacity.set_target(1.0, now, m);
            st.press_surface.set_target(0.0, now, m);
        }
    }

    /// The finger lifts at `(x, y)`.
    pub fn touch_up(&mut self, x: f32, y: f32, now_ms: f64) {
        let Some(a) = self.arena.take() else { return };
        self.tick(now_ms);
        let mut tapped = false;
        match a.mode {
            Mode::Scroll { id, snap, .. } => {
                if let Some(st) = self.states.get_mut(&id)
                    && let Some(b) = st.scroll.as_mut()
                {
                    match snap.filter(|_| self.scroll_tuning.rail_snaps) {
                        Some(step) => {
                            let m = b.metrics;
                            let step = f64::from(step);
                            b.touch_up_snap(now_ms, |p| {
                                ((p / step).round() * step).clamp(m.min, m.max)
                            });
                        }
                        None => b.touch_up(now_ms),
                    }
                    if self.env.reduce_motion {
                        // Reduce Motion: no fling and no spring-back bounce. The view settles at the nearest rest
                        // position (inside the bounds, on the snap step) in a short linear move, not nothing.
                        let m = b.metrics;
                        let rest = m.clamp(b.position());
                        let target = match snap.filter(|_| self.scroll_tuning.rail_snaps) {
                            Some(step) => {
                                let step = f64::from(step);
                                ((rest / step).round() * step).clamp(m.min, m.max)
                            }
                            None => rest,
                        };
                        b.animate_curve(target, Id::Reduced.curve(), now_ms);
                    }
                    st.scroll_pos = b.position();
                }
            }
            Mode::Bar { id, .. } => self.bar_release(id, now_ms),
            Mode::Pan { action } => {
                let velocity = velocity_of(&a.samples, now_ms);
                self.events.push(UiEvent::Pan {
                    action,
                    phase: Phase::Ended,
                    translation: (x - a.down.x, y - a.down.y),
                    velocity,
                });
            }
            Mode::EdgePan { action, edge } => {
                let velocity = velocity_of(&a.samples, now_ms);
                self.events.push(UiEvent::EdgePan {
                    action,
                    phase: Phase::Ended,
                    progress: self.edge_progress(edge, a.down.x, x),
                    translation: (x - a.down.x, y - a.down.y),
                    velocity,
                });
            }
            Mode::Undecided => {
                if !a.tap_failed
                    && !a.long_fired
                    && !a.suppress_tap
                    && let Some(action) = a.entries.iter().rev().find_map(|e| e.gestures.tap)
                {
                    self.events.push(UiEvent::Tap(action));
                    tapped = true;
                }
            }
        }
        if let Some(id) = a.press_node {
            if tapped {
                // A tap inside a scroll view releases before the delayed press showed: flash it, then release.
                if let Some(st) = self.states.get_mut(&id) {
                    show_press(st, now_ms);
                }
            }
            self.release_press(id, now_ms);
        }
        self.sync_windows();
    }

    /// The system cancelled the touch.
    pub fn touch_cancel(&mut self, now_ms: f64) {
        let Some(a) = self.arena.take() else { return };
        match a.mode {
            Mode::Scroll { id, .. } => {
                if let Some(st) = self.states.get_mut(&id)
                    && let Some(b) = st.scroll.as_mut()
                {
                    b.touch_up(now_ms);
                    st.scroll_pos = b.position();
                }
            }
            Mode::Bar { id, .. } => self.bar_release(id, now_ms),
            Mode::Pan { action } => self.events.push(UiEvent::Pan {
                action,
                phase: Phase::Cancelled,
                translation: (0.0, 0.0),
                velocity: (0.0, 0.0),
            }),
            Mode::EdgePan { action, .. } => self.events.push(UiEvent::EdgePan {
                action,
                phase: Phase::Cancelled,
                progress: 0.0,
                translation: (0.0, 0.0),
                velocity: (0.0, 0.0),
            }),
            Mode::Undecided => {}
        }
        if let Some(id) = a.press_node {
            self.release_press(id, now_ms);
        }
    }

    // ---- pointer ---------------------------------------------------------------------------------------------

    /// The scroll feel of this UI (glide shape, notch size, rails snapping). Desktop idiom: the table of the OS.
    pub fn scroll_tuning(&self) -> &ScrollTuning {
        &self.scroll_tuning
    }

    /// Replaces the scroll feel table; scroll bodies created from now on use it.
    pub fn set_scroll_tuning(&mut self, t: ScrollTuning) {
        self.scroll_tuning = t;
        for st in self.states.values_mut() {
            if let Some(b) = st.scroll.as_mut() {
                b.apply_tuning(&t);
            }
        }
    }

    /// Cursor shown over tappable nodes that name none (the Mac never sets one: `None`, the default).
    pub fn set_tap_cursor(&mut self, cursor: Option<Cursor>) {
        self.tap_cursor = cursor;
    }

    /// The pointer moved to window point `(x, y)` with no button held. Updates hover, cursor, tooltip and rest timers.
    pub fn pointer_move(&mut self, x: f32, y: f32, now_ms: f64) {
        self.now = now_ms;
        self.pointer.pos = Some(Point::new(x, y));
        self.bars_hot(Some(Point::new(x, y)), now_ms);
        self.refresh_pointer(now_ms);
    }

    /// The pointer left the window: nothing is hovered any more.
    pub fn pointer_leave(&mut self, now_ms: f64) {
        self.now = now_ms;
        self.pointer.pos = None;
        self.bars_hot(None, now_ms);
        self.refresh_pointer(now_ms);
    }

    /// A secondary (right) click at `(x, y)`: reports `UiEvent::Secondary` for the deepest node that declared one.
    pub fn secondary_click(&mut self, x: f32, y: f32, now_ms: f64) -> bool {
        self.tick(now_ms);
        let mut found = Vec::new();
        if let Some(root) = &self.root {
            pointer_hit(
                root,
                Point::new(x, y),
                Point::new(0.0, 0.0),
                &self.states,
                &mut found,
            );
        }
        self.pointer.tip = None;
        let Some(action) = found.iter().rev().find_map(|e| e.interact.secondary) else {
            return false;
        };
        self.events.push(UiEvent::Secondary { action, x, y });
        true
    }

    /// The cursor the node under the pointer asks for.
    pub fn cursor(&self) -> Cursor {
        self.pointer.cursor
    }

    /// The tooltip to draw at `now` (text and anchor), once the pointer has rested long enough.
    pub fn visible_tooltip(&self, now: f64) -> Option<(String, swiftly_layout::Rect)> {
        let (id, text, anchor, since) = self.pointer.tip.as_ref()?;
        (self.pointer.tip_dismissed != Some(*id) && now - since >= crate::feel::TOOLTIP_DELAY_MS)
            .then(|| (text.clone(), *anchor))
    }

    /// Opacity of the visible tooltip: `Float` (`easeOut(0.12)`) from the moment the delay has passed; 1 under Reduce Motion.
    fn tooltip_alpha(&self, now: f64) -> f32 {
        let Some((_, _, _, since)) = self.pointer.tip.as_ref() else {
            return 1.0;
        };
        if self.env.reduce_motion {
            return 1.0;
        }
        let age = (now - since - crate::feel::TOOLTIP_DELAY_MS) / 1000.0;
        swiftly_motion::catalogue::Id::Float
            .curve()
            .progress(age)
            .clamp(0.0, 1.0) as f32
    }

    fn pointer_timers_pending(&self) -> bool {
        let tip_waiting = self.pointer.tip.as_ref().is_some_and(|(id, _, _, since)| {
            self.pointer.tip_dismissed != Some(*id)
                && self.now - since < crate::feel::TOOLTIP_DELAY_MS + 120.0
        });
        tip_waiting || (self.pointer.rest.is_some() && !self.pointer.rest_fired)
    }

    fn refresh_pointer(&mut self, now: f64) {
        let mut found: Vec<PEntry> = Vec::new();
        if let (Some(p), Some(root)) = (self.pointer.pos, &self.root) {
            pointer_hit(root, p, Point::new(0.0, 0.0), &self.states, &mut found);
        }
        let reduce = self.env.reduce_motion;
        let hovered: Vec<u64> = found
            .iter()
            .filter(|e| e.interact.tracks_hover())
            .map(|e| e.id)
            .collect();
        let old = std::mem::take(&mut self.pointer.hovered);
        for e in found.iter().filter(|e| e.interact.tracks_hover()) {
            if !old.contains(&e.id) {
                let motion = e.interact.hover_motion.unwrap_or_else(crate::feel::hover);
                if let Some(st) = self.states.get_mut(&e.id) {
                    st.hover_t.set_target(1.0, now, motion.resolved(reduce));
                }
                if let Some(action) = e.interact.hover_action {
                    self.events.push(UiEvent::HoverChanged {
                        action,
                        entered: true,
                    });
                }
            }
        }
        for id in old.iter().filter(|id| !hovered.contains(id)) {
            if let Some(st) = self.states.get_mut(id) {
                st.hover_t
                    .set_target(0.0, now, crate::feel::hover().resolved(reduce));
            }
        }
        // Leave events need the node's action, which only a live node still has: look it up among the old ids.
        for id in old.iter().filter(|id| !hovered.contains(id)) {
            if let Some(&action) = self.hover_actions.get(id) {
                self.events.push(UiEvent::HoverChanged {
                    action,
                    entered: false,
                });
            }
        }
        self.hover_actions = found
            .iter()
            .filter_map(|e| e.interact.hover_action.map(|a| (e.id, a)))
            .collect();
        self.pointer.hovered = hovered;
        self.pointer.cursor = found
            .iter()
            .rev()
            .find_map(|e| e.interact.cursor)
            .or_else(|| self.tap_cursor.filter(|_| self.pointer_over_tap()))
            .unwrap_or_default();
        // Rest hint: the deepest node with a rest action; a new node restarts the 150 ms.
        let rest = found
            .iter()
            .rev()
            .find_map(|e| e.interact.rest_action.map(|a| (e.id, a)));
        match (rest, self.pointer.rest) {
            (Some((id, a)), Some((old_id, _, _))) if id == old_id => {
                let _ = a;
            }
            (Some((id, a)), _) => {
                self.pointer.rest = Some((id, a, now));
                self.pointer.rest_fired = false;
            }
            (None, _) => {
                self.pointer.rest = None;
                self.pointer.rest_fired = true;
            }
        }
        // Tooltip: the deepest node with text; a different node restarts the delay.
        let tip = found
            .iter()
            .rev()
            .find_map(|e| e.interact.tooltip.clone().map(|t| (e.id, t, e.rect)));
        match (tip, self.pointer.tip.take()) {
            (Some((id, text, rect)), Some((old, _, _, since))) if id == old => {
                self.pointer.tip = Some((id, text, rect, since));
            }
            (Some((id, text, rect)), _) => self.pointer.tip = Some((id, text, rect, now)),
            (None, _) => {
                self.pointer.tip = None;
                self.pointer.tip_dismissed = None;
            }
        }
    }

    fn pointer_over_tap(&self) -> bool {
        let Some(p) = self.pointer.pos else {
            return false;
        };
        let mut entries = Vec::new();
        if let Some(root) = &self.root {
            hit(root, p, &self.states, &mut entries);
        }
        entries.iter().any(|e| e.gestures.tap.is_some())
    }

    /// A discrete wheel notch (or a touchpad delta) of `(dx, dy)` points at window point `(x, y)`: scrolls the innermost
    /// scroll view under the pointer that can move that way, clamped (the outermost one of the axis gives a soft stop of at
    /// most 28 pt at its end, see `ScrollBody::notch_by`; a precision touchpad has the rubber band). Returns
    /// whether anything moved.
    pub fn wheel_scroll(&mut self, x: f32, y: f32, dx: f32, dy: f32, now_ms: f64) -> bool {
        let precise = PRECISE_WHEEL.with(std::cell::Cell::get);
        self.tick(now_ms);
        let mut entries = Vec::new();
        if let Some(root) = &self.root {
            hit(root, Point::new(x, y), &self.states, &mut entries);
        }
        let (axis, delta) = if dy.abs() >= dx.abs() {
            (Axis::Vertical, f64::from(dy))
        } else {
            (Axis::Horizontal, f64::from(dx))
        };
        // The content moves with the fingers: wheel down (negative dy on most systems) scrolls later content into view.
        // Only the outermost scroller of the axis gives at its end (the soft stop); inner ones chain outward first.
        let outermost = entries.iter().find_map(|e| {
            let spec = e.scroll?;
            let b = self.states.get(&e.id)?.scroll.as_ref()?;
            (spec.axis == axis && b.metrics.scrollable()).then_some(e.id)
        });
        for e in entries.iter().rev() {
            let Some(spec) = e.scroll else { continue };
            if spec.axis != axis {
                continue;
            }
            let Some(st) = self.states.get_mut(&e.id) else {
                continue;
            };
            let Some(b) = st.scroll.as_mut() else {
                continue;
            };
            // A precision touchpad (the OS already shapes its stream) moves the content 1:1 with the rubber band at the ends;
            // a wheel notch is clamped.
            let moved = if precise && b.metrics.scrollable() {
                let before = b.position();
                b.wheel_by(delta, now_ms);
                (b.position() - before).abs().max(delta.abs())
            } else if Some(e.id) == outermost {
                b.notch_by(delta, now_ms)
            } else {
                b.scroll_by_clamped(delta)
            };
            st.scroll_pos = b.position();
            if moved.abs() > 1e-9 {
                self.sync_windows();
                if self.pointer.pos.is_some() {
                    self.refresh_pointer(now_ms);
                }
                return true;
            }
        }
        false
    }

    /// Home, End, Page up and down and the line keys on the first vertical scroll view: animated with the `select` spring
    /// (smooth 0.25 s), a page being the viewport less [`tuning::PAGE_OVERLAP_PT`]. Returns whether it moved.
    pub fn scroll_key(&mut self, key: crate::shortcuts::ScrollKey, now: f64) -> bool {
        use crate::shortcuts::ScrollKey as K;
        let mut nodes = Vec::new();
        if let Some(r) = &self.root {
            scroll_nodes(r, &mut nodes);
        }
        let Some((id, _)) = nodes.iter().find(|(_, s)| s.axis == Axis::Vertical) else {
            return false;
        };
        let Some(b) = self.states.get_mut(id).and_then(|st| st.scroll.as_mut()) else {
            return false;
        };
        let (m, pos) = (b.metrics, b.position());
        let page = (m.viewport - f64::from(tuning::PAGE_OVERLAP_PT)).max(1.0);
        let to = match key {
            K::Home => m.min,
            K::End => m.max,
            K::PageUp => pos - page,
            K::PageDown => pos + page,
            K::LineUp => pos - f64::from(tuning::KEY_LINE_PT),
            K::LineDown => pos + f64::from(tuning::KEY_LINE_PT),
        };
        let to = m.clamp(to);
        if (to - pos).abs() < 0.5 {
            return false;
        }
        self.scroll_first_to(Axis::Vertical, to, true, now)
    }

    // ---- focus -----------------------------------------------------------------------------------------------

    /// The focusable items and scopes of the current tree, in tree order.
    pub fn focus_map(&self) -> &FocusMap {
        &self.fmap
    }

    /// The screen-reader nodes of the current picture: explicit descriptions plus inferred buttons and text, frames
    /// in window points, focus on the node that has it. The top-level nodes are in reading order.
    pub fn a11y_nodes(&self) -> Vec<crate::a11y::A11yNode> {
        let mut out = Vec::new();
        if let Some(root) = &self.root {
            crate::tree::a11y_nodes(
                root,
                Point::new(0.0, 0.0),
                &self.states,
                self.focus.current(),
                &mut out,
            );
        }
        out
    }

    /// The focused item.
    pub fn focused(&self) -> Option<FocusId> {
        self.focus.current()
    }

    /// Whether focus is drawn: always on `tv`, on the other idioms after the first key and until the next touch.
    pub fn focus_visible(&self) -> bool {
        self.focus_visible
    }

    /// Puts focus on an item (scrolls it into view). Returns whether it took.
    pub fn set_focus(&mut self, id: impl Into<FocusId>, now_ms: f64) -> bool {
        let id = id.into();
        let ok = self.focus.set(&self.fmap, id);
        if ok {
            self.reveal(id, now_ms);
            self.apply_focus_visuals(now_ms);
        }
        ok
    }

    /// The focus amount of an item: 0 unfocused, 1 focused, a spring in between (tests, tools).
    pub fn focus_amount(&self, id: impl Into<FocusId>) -> Option<f64> {
        let id = id.into();
        let n = self
            .fnodes
            .iter()
            .find(|n| n.item.is_some_and(|i| i.id == id))?;
        self.states.get(&n.node).map(|s| s.focus_t.value())
    }

    /// One key from the keyboard or the D-pad, at `now_ms`. Taps and long presses also arrive as [`UiEvent`]s. On the
    /// idioms other than `tv` the first key only shows focus.
    pub fn nav_key(&mut self, key: NavKey, down: bool, now_ms: f64) -> Outcome {
        self.tick(now_ms);
        if !self.focus_visible && down && key != NavKey::Escape {
            self.focus_visible = true;
            self.apply_focus_visuals(now_ms);
            if let Some(id) = self.focus.current() {
                self.reveal(id, now_ms);
                return Outcome::Shown(id);
            }
        }
        let out = self.focus.key(&self.fmap, key, down, now_ms);
        match out {
            Outcome::Activated(_, Some(a)) => self.events.push(UiEvent::Tap(a)),
            Outcome::LongPressed(_, Some(a)) => self.events.push(UiEvent::LongPress(a)),
            Outcome::Moved { to, .. } => self.reveal(to, now_ms),
            Outcome::Back(crate::focus::BackOutcome::ToBar(to)) => self.reveal(to, now_ms),
            _ => {}
        }
        self.apply_focus_visuals(now_ms);
        out
    }

    /// Rebuilds the focus map from the tree and repairs the focus.
    fn refresh_focus(&mut self) {
        let mut nodes = vec![];
        if let Some(root) = &self.root {
            focus_nodes(
                root,
                Point::new(0.0, 0.0),
                &self.states,
                &mut vec![],
                None,
                &mut nodes,
            );
        }
        let mut map = FocusMap::new();
        for n in &nodes {
            if let Some(s) = n.scope {
                map.add_scope(s, n.parent_scope);
            }
        }
        for n in &nodes {
            if let Some(f) = n.item {
                let mut it = Item::new(f.id, n.rect);
                it.scope = n.parent_scope;
                it.default = f.default;
                it.tap = n.tap;
                it.long = n.long;
                map.add_item(it);
            }
        }
        self.fmap = map;
        self.fnodes = nodes;
        self.focus.sync(&self.fmap);
        self.apply_focus_visuals(self.now);
    }

    /// Springs every focusable toward 1 (the focused one, when focus is visible) or 0.
    fn apply_focus_visuals(&mut self, now: f64) {
        let current = if self.focus_visible {
            self.focus.current()
        } else {
            None
        };
        // The Mac moves the focus surface with `timeFloat`; tvOS has its own `focusAnimation`.
        let motion = if self.env.idiom == crate::env::Idiom::Tv {
            if self.env.reduce_motion {
                Motion::of(Id::TvFocusReduced)
            } else {
                Motion::of(Id::TvFocus)
            }
        } else {
            crate::feel::hover().resolved(self.env.reduce_motion)
        };
        for n in &self.fnodes {
            let Some(f) = n.item else { continue };
            if let Some(st) = self.states.get_mut(&n.node) {
                let target = if Some(f.id) == current { 1.0 } else { 0.0 };
                st.focus_t.set_target(target, now, motion);
            }
        }
    }

    /// Scrolls the enclosing scroll views (innermost first) so the item sits inside their edges.
    fn reveal(&mut self, id: FocusId, now: f64) {
        let Some(n) = self
            .fnodes
            .iter()
            .find(|n| n.item.is_some_and(|i| i.id == id))
        else {
            return;
        };
        let mut rect = n.rect;
        let mut jumps = vec![];
        for &(node, axis, vp) in n.scrolls.iter().rev() {
            let (lo, hi, len, vlo, vhi, vlen) = match axis {
                Axis::Horizontal => (rect.x, rect.x + rect.w, rect.w, vp.x, vp.x + vp.w, vp.w),
                Axis::Vertical => (rect.y, rect.y + rect.h, rect.h, vp.y, vp.y + vp.h, vp.h),
            };
            let m = tuning::FOCUS_REVEAL_MARGIN_PT.min(((vlen - len) / 2.0).max(0.0));
            let delta = (hi - (vhi - m)).max(0.0) - ((vlo + m) - lo).max(0.0);
            if delta != 0.0 {
                jumps.push((node, delta));
                match axis {
                    Axis::Horizontal => rect.x -= delta,
                    Axis::Vertical => rect.y -= delta,
                }
            }
        }
        if jumps.is_empty() {
            return;
        }
        let reduce = self.env.reduce_motion;
        for (node, delta) in jumps {
            if let Some(st) = self.states.get_mut(&node)
                && let Some(b) = st.scroll.as_mut()
            {
                let at = b.position();
                let target = b.metrics.clamp(at + f64::from(delta));
                if reduce {
                    b.jump_to(target);
                } else {
                    b.animate_curve(target, Id::Select.curve(), now);
                }
                st.scroll_pos = b.position();
            }
        }
        self.sync_windows();
    }

    // ---- queries (tests, tools) ------------------------------------------------------------------------------

    /// Jumps the first scroll view with an `axis` to `offset` (clamped), unanimated; false when it has no state yet
    /// (before its first frame).
    pub fn jump_first_scroll(&mut self, axis: Axis, offset: f64) -> bool {
        let mut nodes = Vec::new();
        if let Some(r) = &self.root {
            scroll_nodes(r, &mut nodes);
        }
        let Some((id, _)) = nodes.iter().find(|(_, s)| s.axis == axis) else {
            return false;
        };
        let Some(st) = self.states.get_mut(id) else {
            return false;
        };
        let Some(b) = st.scroll.as_mut() else {
            return false;
        };
        let target = b.metrics.clamp(offset);
        b.jump_to(target);
        st.scroll_pos = b.position();
        self.sync_windows();
        true
    }

    /// Scrolls the first scroll view with an `axis` to `offset` (clamped). `animated` uses the smooth 0.25 s of Swift's
    /// `Motion.select` (the library grid's alphabet jump) unless Reduce Motion is on; false when the view has no state yet.
    pub fn scroll_first_to(&mut self, axis: Axis, offset: f64, animated: bool, now: f64) -> bool {
        if !animated || self.env.reduce_motion {
            return self.jump_first_scroll(axis, offset);
        }
        let mut nodes = Vec::new();
        if let Some(r) = &self.root {
            scroll_nodes(r, &mut nodes);
        }
        let Some((id, _)) = nodes.iter().find(|(_, s)| s.axis == axis) else {
            return false;
        };
        let Some(st) = self.states.get_mut(id) else {
            return false;
        };
        let Some(b) = st.scroll.as_mut() else {
            return false;
        };
        let target = b.metrics.clamp(offset);
        b.animate_curve(target, Id::Select.curve(), now);
        st.scroll_pos = b.position();
        self.sync_windows();
        true
    }

    /// `(offset, largest offset, viewport)` of the scroll view with `key` in the current picture (rail paging arrows).
    pub fn scroll_of(&self, key: impl Into<Key>) -> Option<(f64, f64, f64)> {
        let id = find_key(self.root.as_ref()?, key.into())?;
        let st = self.states.get(&id)?;
        let b = st.scroll.as_ref()?;
        Some((st.scroll_pos, b.metrics.max, b.metrics.viewport))
    }

    /// Scrolls the scroll view with `key` by `delta` points (clamped) with the Mac's `reveal` curve (easeInOut 0.28 s,
    /// the paging arrows of a rail); a new call restarts from the current position. False when it has no state yet.
    pub fn scroll_key_by(&mut self, key: impl Into<Key>, delta: f64, now: f64) -> bool {
        let Some(id) = self.root.as_ref().and_then(|r| find_key(r, key.into())) else {
            return false;
        };
        let reduce = self.env.reduce_motion;
        let Some(st) = self.states.get_mut(&id) else {
            return false;
        };
        let Some(b) = st.scroll.as_mut() else {
            return false;
        };
        let at = b.position();
        let target = b.metrics.clamp(at + delta);
        if reduce {
            b.jump_to(target);
        } else {
            b.animate_curve(target, Id::Reveal.curve(), now);
        }
        st.scroll_pos = b.position();
        self.sync_windows();
        true
    }

    /// Scroll offsets of all scroll views in tree order.
    pub fn scroll_offsets(&self) -> Vec<f64> {
        let mut nodes = Vec::new();
        if let Some(r) = &self.root {
            scroll_nodes(r, &mut nodes);
        }
        nodes
            .iter()
            .map(|(id, _)| self.states.get(id).map_or(0.0, |s| s.scroll_pos))
            .collect()
    }

    /// The frame `(x, y, w, h)` in window points of the first node with `key` in the current picture.
    pub fn frame_of(&self, key: impl Into<Key>) -> Option<[f32; 4]> {
        frame_of_key(
            self.root.as_ref()?,
            Point::new(0.0, 0.0),
            &self.states,
            key.into(),
        )
    }

    /// The retained scale, opacity and press state of the first node with `key`.
    pub fn node_values(&self, key: impl Into<Key>) -> Option<NodeValues> {
        let id = find_key(self.root.as_ref()?, key.into())?;
        let st = self.states.get(&id)?;
        Some(NodeValues {
            scale: st.scale(),
            opacity: st.opacity(),
            pressed: st.press != Press::Idle,
        })
    }

    /// Number of retained node states (shrinks when nodes disappear).
    pub fn state_count(&self) -> usize {
        self.states.len()
    }

    /// How many items of lazy lists are currently built.
    pub fn built_items(&self) -> usize {
        fn count(n: &RNode) -> usize {
            n.lazy.as_ref().map_or(0, |l| l.items.len())
                + n.children.iter().map(count).sum::<usize>()
        }
        self.root.as_ref().map_or(0, count)
    }

    /// Renders a list of this UI with the software renderer (the oracle of the goldens).
    pub fn render(&self, list: &DrawList, clear: Color) -> RgbaImage {
        let ts = self.cx.text.borrow();
        let im = self.cx.images.borrow();
        SoftwareRenderer::render(
            list,
            clear,
            &Sources {
                glyphs: Some(&ts.atlas),
                images: Some(&im.page),
            },
        )
    }
}

fn show_press(st: &mut NodeState, now: f64) {
    st.press = Press::Armed {
        since: match st.press {
            Press::Armed { since, .. } => since,
            Press::Idle => now,
        },
        shown: true,
        in_scroll: false,
    };
    let m = Motion::Instant;
    match st.press_style {
        PressStyle::None => {}
        PressStyle::Row => st.press_surface.set_target(1.0, now, m),
        PressStyle::Button => {
            st.press_scale
                .set_target(crate::feel::PRESS_BUTTON_SCALE, now, m);
            st.press_opacity
                .set_target(crate::feel::PRESS_BUTTON_OPACITY, now, m);
        }
        PressStyle::Text => st
            .press_opacity
            .set_target(crate::feel::PRESS_TEXT_OPACITY, now, m),
    }
}

/// Least-recent-window velocity of a finger in pt/s.
fn velocity_of(samples: &[(f64, f32, f32)], now: f64) -> (f32, f32) {
    let recent: Vec<&(f64, f32, f32)> = samples
        .iter()
        .filter(|s| now - s.0 <= tuning::PAN_VELOCITY_WINDOW_MS)
        .collect();
    let (Some(first), Some(last)) = (recent.first(), recent.last()) else {
        return (0.0, 0.0);
    };
    let dt = (last.0 - first.0) / 1000.0;
    if dt <= 0.0 {
        return (0.0, 0.0);
    }
    (
        ((f64::from(last.1) - f64::from(first.1)) / dt) as f32,
        ((f64::from(last.2) - f64::from(first.2)) / dt) as f32,
    )
}

/// Draws a tooltip for `anchor`: raised panel, hairline, one 12 pt medium line, placed like the Mac's (4 pt in, near the
/// anchor's bottom edge) and kept inside the window.
fn draw_tooltip(
    list: &mut DrawList,
    ts: &mut crate::cx::TextSystem,
    text: &str,
    anchor: swiftly_layout::Rect,
) {
    use crate::components::color;
    use swiftly_design::tokens::colour;
    let (size, weight) = crate::feel::TOOLTIP_FONT;
    let style = swiftly_text::TextStyle::new(size, weight);
    let l = ts.layout(text, &style, None, Some(1), swiftly_text::Align::Start);
    let (tw, th) = (l.width(), l.height());
    let (px, py) = crate::feel::TOOLTIP_PAD;
    let (w, h) = (tw + 2.0 * px, th + 2.0 * py);
    let (win_w, win_h) = (list.width(), list.height());
    let mut x = anchor.x + crate::feel::TOOLTIP_OFFSET.0;
    let mut y = anchor.y + anchor.h + crate::feel::TOOLTIP_OFFSET.1;
    if y + h > win_h - 4.0 {
        y = (anchor.y - h - 4.0).max(4.0);
    }
    x = x.min(win_w - w - 4.0).max(4.0);
    let r = swiftly_render::Rect::new(x, y, w, h);
    let (a, blur, dy) = crate::feel::PANEL_SHADOW;
    list.shadow(
        r,
        swiftly_render::ShadowStyle {
            color: Color::new(0.0, 0.0, 0.0, a),
            dx: 0.0,
            dy,
            blur,
            spread: 0.0,
        },
        crate::feel::TOOLTIP_RADIUS,
    );
    list.fill(r, color(colour::RAISED), crate::feel::TOOLTIP_RADIUS);
    list.stroke(r, color(colour::MARGIN), 1.0, crate::feel::TOOLTIP_RADIUS);
    ts.atlas.draw(&l, list, x + px, y + py, color(colour::FONT));
}
