//! The retained tree: reconciliation by path and key, layout application, lazy windows, hit-testing and painting.

use crate::anim::{Animated, Motion};
use crate::cx::TextSystem;
use crate::interact::{Interact, PressStyle};
use crate::tuning;
use crate::view::{FocusItem, Gestures, Key, LazyItems, Node, Paint, ScrollSpec};
use std::collections::{HashMap, HashSet};
use std::ops::Range;
use swiftly_layout::{Alignment, Axis, Kind, LazyPlan, Placed, Point, Rect, Size};
use swiftly_motion::{ScrollBody, ScrollMetrics};
use swiftly_render::{Color, DrawList};

/// Press tracking of one node.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Press {
    Idle,
    /// Touched at `since` ms; `shown` once the feedback is visible; `in_scroll` delays it.
    Armed {
        since: f64,
        shown: bool,
        in_scroll: bool,
    },
}

/// State that survives rebuilds, keyed by the node's path identity.
pub(crate) struct NodeState {
    pub press: Press,
    pub decl_scale: Animated,
    pub decl_opacity: Animated,
    pub decl_dx: Animated,
    pub decl_dy: Animated,
    /// The animated width and height of a frame wrapper (`Node::animated_frame`).
    pub frame_w: Animated,
    pub frame_h: Animated,
    pub press_scale: Animated,
    pub press_opacity: Animated,
    pub scroll: Option<ScrollBody>,
    pub scroll_pos: f64,
    /// The overlay scroll bar of a vertical scroll view.
    pub bar: crate::scrollbar::Bar,
    /// 0 unfocused, 1 focused (a spring: it may overshoot).
    pub focus_t: Animated,
    /// Scale gained at full focus (`look.scale - 1`).
    pub focus_gain: f64,
    /// 0 pointer away, 1 pointer on the node (or a descendant).
    pub hover_t: Animated,
    /// Scale gained at full hover (`hover_scale - 1`).
    pub hover_gain: f64,
    /// 0 to 1 while a `PressRow` is held.
    pub press_surface: Animated,
    /// 1 while the node is selected (toggle curve).
    pub sel_t: Animated,
    /// How this node shows a press.
    pub press_style: PressStyle,
    /// Greyed out.
    pub disabled: bool,
    offset_seen: bool,
    frame_seen: bool,
}

impl NodeState {
    fn new(scale: f64, opacity: f64) -> NodeState {
        NodeState {
            press: Press::Idle,
            decl_scale: Animated::new(scale),
            decl_opacity: Animated::new(opacity),
            decl_dx: Animated::new(0.0),
            decl_dy: Animated::new(0.0),
            frame_w: Animated::new(0.0),
            frame_h: Animated::new(0.0),
            press_scale: Animated::new(1.0),
            press_opacity: Animated::new(1.0),
            scroll: None,
            scroll_pos: 0.0,
            bar: crate::scrollbar::Bar::default(),
            focus_t: Animated::new(0.0),
            focus_gain: 0.0,
            hover_t: Animated::new(0.0),
            hover_gain: 0.0,
            press_surface: Animated::new(0.0),
            sel_t: Animated::new(0.0),
            press_style: PressStyle::Button,
            disabled: false,
            offset_seen: false,
            frame_seen: false,
        }
    }
    /// The strongest of hover, keyboard focus, held row and selected: how much of the node's surface shows.
    pub fn highlight(&self) -> f32 {
        self.focus_t
            .value()
            .max(self.hover_t.value())
            .max(self.press_surface.value())
            .max(self.sel_t.value())
            .clamp(0.0, 1.0) as f32
    }
    pub fn busy(&self) -> bool {
        self.press != Press::Idle
            || self.decl_scale.is_active()
            || self.decl_opacity.is_active()
            || self.decl_dx.is_active()
            || self.decl_dy.is_active()
            || self.frame_w.is_active()
            || self.frame_h.is_active()
            || self.press_scale.is_active()
            || self.press_opacity.is_active()
            || self.focus_t.is_active()
            || self.hover_t.is_active()
            || self.press_surface.is_active()
            || self.sel_t.is_active()
            || self.scroll.as_ref().is_some_and(|s| s.needs_frames())
    }
    pub fn scale(&self) -> f64 {
        self.decl_scale.value()
            * self.press_scale.value()
            * (1.0 + self.focus_gain * self.focus_t.value())
            * (1.0 + self.hover_gain * self.hover_t.value())
    }
    pub fn opacity(&self) -> f64 {
        let dim = if self.disabled {
            crate::feel::DISABLED_OPACITY
        } else {
            1.0
        };
        self.decl_opacity.value() * self.press_opacity.value() * dim
    }
}

pub(crate) struct LazyRt {
    pub build: LazyItems,
    pub plan: Option<LazyPlan>,
    pub range: Range<usize>,
    pub items: Vec<RNode>,
}

/// A resolved node: identity, behaviour and the frame from the last layout.
pub(crate) struct RNode {
    pub id: u64,
    pub key: Option<Key>,
    pub kind: Kind,
    pub priority: f32,
    pub paint: Vec<Paint>,
    pub gestures: Gestures,
    pub press_feedback: bool,
    pub snap_pixels: bool,
    pub scroll: Option<ScrollSpec>,
    pub clip: bool,
    pub clip_radius: f32,
    pub children: Vec<RNode>,
    pub frame: Rect,
    pub content: Option<Size>,
    pub hidden: bool,
    pub lazy: Option<LazyRt>,
    pub focus: Option<FocusItem>,
    pub scope: Option<crate::focus::ScopeSpec>,
    pub interact: Interact,
    pub scale_anchor: Option<(f32, f32)>,
    pub a11y: Option<Box<crate::a11y::A11yNode>>,
    /// Where the node animates to when it is removed, and how.
    pub exit: Option<(f32, f32)>,
    pub exit_offset: Option<(f32, f32)>,
    pub motion: Motion,
}

impl RNode {
    /// A node that reacts to nothing: its empty area lets touches through to what lies beneath.
    pub fn is_inert(&self) -> bool {
        self.gestures == Gestures::default()
            && !self.press_feedback
            && self.scroll.is_none()
            && self.focus.is_none()
            && self.scope.is_none()
            && !self.interact.tracks_hover()
            && self.interact.cursor.is_none()
            && self.interact.tooltip.is_none()
            && self.interact.secondary.is_none()
    }
}

/// Mutable context of a reconcile or layout pass.
pub(crate) struct Rec<'a> {
    pub states: &'a mut HashMap<u64, NodeState>,
    pub seen: &'a mut HashSet<u64>,
    pub now: f64,
    pub reduce: bool,
    pub scroll: swiftly_motion::ScrollTuning,
    /// The first build of the tree: `appear_skip_first` nodes do not animate in.
    pub first: bool,
}

fn mix(a: u64, b: u64) -> u64 {
    let mut h = a ^ 0x9E37_79B9_7F4A_7C15;
    h = (h ^ b).wrapping_mul(0x0100_0000_01b3);
    h ^= h >> 29;
    h.wrapping_mul(0xBF58_476D_1CE4_E5B9)
}

fn name_hash(s: &str) -> u64 {
    Key::from(s).0
}

/// Path identity: parent identity, key (or position) and kind.
pub(crate) fn child_id(parent: u64, key: Option<Key>, index: usize, name: &str) -> u64 {
    let k = match key {
        Some(k) => k.0 ^ 0xA5A5_A5A5_0000_0000,
        None => index as u64,
    };
    mix(mix(parent, k), name_hash(name))
}

/// Turns a declarative node into a resolved one, keeping (or creating) the retained state for every id.
pub(crate) fn reconcile(rec: &mut Rec, mut n: Node, id: u64) -> RNode {
    rec.seen.insert(id);
    if n.interact.disabled {
        // A disabled node takes no taps, no focus and no hover.
        n.gestures = Gestures::default();
        n.press_feedback = false;
        n.focus = None;
        n.interact.hover_scale = None;
        n.interact.hover_action = None;
        n.interact.rest_action = None;
        n.interact.secondary = None;
        n.interact.tooltip = None;
        n.interact.hoverable = false;
        n.interact.ring = None;
    }
    n.press_feedback = n.press_feedback && n.interact.press != PressStyle::None;
    let motion = n.motion.resolved(rec.reduce);
    let st = rec.states.entry(id).or_insert_with(|| {
        // Under Reduce Motion only the fade remains (the Mac's `expand` is plain `.opacity` then).
        let (s0, o0) = n
            .appear
            .filter(|_| !(rec.first && n.appear_skip_first))
            .map_or((n.scale, n.opacity), |(s, o)| {
                (if rec.reduce { n.scale } else { s }, o)
            });
        NodeState::new(f64::from(s0), f64::from(o0))
    });
    if !st.offset_seen {
        st.offset_seen = true;
        let skip = rec.first && n.appear_skip_first;
        let (ox, oy) = if rec.reduce || skip {
            n.offset
        } else {
            n.appear_offset.unwrap_or(n.offset)
        };
        st.decl_dx = Animated::new(f64::from(ox));
        st.decl_dy = Animated::new(f64::from(oy));
    }
    st.decl_dx
        .set_target(f64::from(n.offset.0), rec.now, motion);
    st.decl_dy
        .set_target(f64::from(n.offset.1), rec.now, motion);
    if let (Some(fm), Kind::Frame { w, h, align }) = (n.frame_motion, &n.kind) {
        let fm = fm.resolved(rec.reduce);
        let (w, h, align) = (*w, *h, *align);
        if !st.frame_seen {
            st.frame_seen = true;
            st.frame_w = Animated::new(f64::from(w.unwrap_or(0.0)));
            st.frame_h = Animated::new(f64::from(h.unwrap_or(0.0)));
        }
        if let Some(w) = w {
            st.frame_w.set_target(f64::from(w), rec.now, fm);
        }
        if let Some(h) = h {
            st.frame_h.set_target(f64::from(h), rec.now, fm);
        }
        n.kind = Kind::Frame {
            w: w.map(|_| st.frame_w.value() as f32),
            h: h.map(|_| st.frame_h.value() as f32),
            align,
        };
    }
    st.decl_scale
        .set_target(f64::from(n.scale), rec.now, motion);
    st.decl_opacity
        .set_target(f64::from(n.opacity), rec.now, motion);
    st.focus_gain = n
        .focus
        .and_then(|f| f.look)
        .map_or(0.0, |l| f64::from(l.scale) - 1.0);
    st.hover_gain = n.interact.hover_scale.map_or(0.0, |s| f64::from(s) - 1.0);
    st.press_style = n.interact.press;
    st.disabled = n.interact.disabled;
    let toggle = crate::feel::toggle().resolved(rec.reduce);
    st.sel_t
        .set_target(if n.interact.selected { 1.0 } else { 0.0 }, rec.now, toggle);
    let children = n
        .children
        .into_iter()
        .enumerate()
        .map(|(i, c)| {
            let cid = child_id(id, c.key, i, c.name);
            reconcile(rec, c, cid)
        })
        .collect();
    RNode {
        id,
        key: n.key,
        kind: n.kind,
        priority: n.priority,
        paint: n.paint,
        gestures: n.gestures,
        press_feedback: n.press_feedback,
        snap_pixels: n.snap_pixels,
        scroll: n.scroll,
        clip: n.clip,
        clip_radius: n.clip_radius,
        children,
        frame: Rect::ZERO,
        content: None,
        hidden: false,
        focus: n.focus,
        scope: n.scope,
        interact: n.interact,
        scale_anchor: n.scale_anchor,
        a11y: n.a11y,
        exit: n.exit,
        exit_offset: n.exit_offset,
        motion: n.motion,
        lazy: n.lazy.map(|build| LazyRt {
            build,
            plan: None,
            range: 0..0,
            items: vec![],
        }),
    }
}

/// The layout tree of a resolved subtree.
pub(crate) fn mirror(n: &RNode) -> swiftly_layout::Node {
    let mut l = swiftly_layout::Node::new(n.kind.clone(), n.children.iter().map(mirror).collect());
    l.priority = n.priority;
    l
}

/// Writes the frames of a layout pass into the tree and updates scroll metrics.
pub(crate) fn apply(n: &mut RNode, p: &Placed, rec: &mut Rec) {
    n.frame = p.frame;
    n.content = p.content;
    n.hidden = p.hidden;
    if let Some(l) = n.lazy.as_mut() {
        l.plan = p.lazy.clone();
    }
    if let (Some(spec), Some(content)) = (n.scroll, p.content) {
        let (c, v) = (
            f64::from(content.along(spec.axis)),
            f64::from(p.frame.size().along(spec.axis)),
        );
        let metrics = ScrollMetrics::new(c, v);
        if let Some(st) = rec.states.get_mut(&n.id) {
            match st.scroll.as_mut() {
                Some(b) => b.metrics = metrics,
                None => {
                    let mut body = ScrollBody::new(metrics, 0.0);
                    body.apply_tuning(&rec.scroll);
                    st.scroll = Some(body);
                }
            }
        }
    }
    for (c, pc) in n.children.iter_mut().zip(&p.children) {
        apply(c, pc, rec);
    }
}

/// A window in content coordinates: the part of the content that is on screen.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Win {
    pub x0: f32,
    pub x1: f32,
    pub y0: f32,
    pub y1: f32,
}

/// Builds the items of lazy lists that are near the visible window, keeps those still inside, drops the others.
pub(crate) fn materialize(n: &mut RNode, origin: Point, win: Win, rec: &mut Rec) {
    if n.hidden {
        return;
    }
    let at = Point::new(origin.x + n.frame.x, origin.y + n.frame.y);
    let (child_origin, child_win) = match n.scroll {
        Some(spec) => {
            let off = rec.states.get(&n.id).map_or(0.0, |s| s.scroll_pos as f32);
            let (w, h) = (n.frame.w, n.frame.h);
            let win = match spec.axis {
                Axis::Horizontal => Win {
                    x0: off,
                    x1: off + w,
                    y0: 0.0,
                    y1: h,
                },
                Axis::Vertical => Win {
                    x0: 0.0,
                    x1: w,
                    y0: off,
                    y1: off + h,
                },
            };
            (Point::new(0.0, 0.0), win)
        }
        None => (at, win),
    };
    if let Some(axis) = lazy_axis(&n.kind)
        && n.lazy.is_some()
    {
        sync_items(n, axis, at, win, rec);
    }
    for c in &mut n.children {
        materialize(c, child_origin, child_win, rec);
    }
    if let Some(l) = n.lazy.as_mut() {
        for it in &mut l.items {
            materialize(it, at, win, rec);
        }
    }
}

fn lazy_axis(k: &Kind) -> Option<Axis> {
    match k {
        Kind::LazyStack(s) => Some(s.axis),
        Kind::Grid(_) => Some(Axis::Vertical),
        _ => None,
    }
}

fn sync_items(n: &mut RNode, axis: Axis, at: Point, win: Win, rec: &mut Rec) {
    let id = n.id;
    let Some(lazy) = n.lazy.as_mut() else { return };
    let Some(plan) = lazy.plan.clone() else {
        return;
    };
    let (a0, a1) = match axis {
        Axis::Horizontal => (win.x0 - at.x, win.x1 - at.x),
        Axis::Vertical => (win.y0 - at.y, win.y1 - at.y),
    };
    let range = plan.visible(a0 - tuning::LAZY_OVERSCAN_PT, a1 + tuning::LAZY_OVERSCAN_PT);
    if range == lazy.range && lazy.items.len() == range.len() {
        return;
    }
    let start = lazy.range.start;
    let mut old: HashMap<usize, RNode> = std::mem::take(&mut lazy.items)
        .into_iter()
        .enumerate()
        .map(|(k, r)| (start + k, r))
        .collect();
    let mut items = Vec::with_capacity(range.len());
    for i in range.clone() {
        let r = match old.remove(&i) {
            Some(r) => r,
            None => build_item(&lazy.build, &plan, id, i, rec),
        };
        items.push(r);
    }
    for r in old.values() {
        release(r, rec);
    }
    lazy.range = range;
    lazy.items = items;
}

fn build_item(build: &LazyItems, plan: &LazyPlan, lazy_id: u64, i: usize, rec: &mut Rec) -> RNode {
    let node = (build.build)(i);
    let id = mix(lazy_id, 0x1_0000 + i as u64);
    let mut r = reconcile(rec, node, id);
    let slot = plan.item_frame(i);
    let placed = swiftly_layout::layout_aligned(&mirror(&r), slot.size(), Alignment::TOP_LEADING);
    apply(&mut r, &placed, rec);
    r.frame = Rect::new(
        slot.x + placed.frame.x,
        slot.y + placed.frame.y,
        placed.frame.w,
        placed.frame.h,
    );
    r
}

/// Drops the retained state of a subtree that left the window, unless something is still moving in it.
fn release(r: &RNode, rec: &mut Rec) {
    if rec.states.get(&r.id).is_some_and(|s| !s.busy()) {
        rec.states.remove(&r.id);
    }
    for c in &r.children {
        release(c, rec);
    }
}

/// One node under a touch.
#[derive(Clone, Copy, Debug)]
pub(crate) struct HitEntry {
    pub id: u64,
    pub gestures: Gestures,
    pub press: bool,
    pub scroll: Option<ScrollSpec>,
}

fn paint_order(n: &RNode) -> Vec<usize> {
    let c = n.children.len();
    if matches!(n.kind, Kind::Background(_)) && c == 2 {
        vec![1, 0]
    } else {
        (0..c).collect()
    }
}

/// Collects the nodes under `p` (given in the parent's coordinates), root first.
pub(crate) fn hit(
    n: &RNode,
    p: Point,
    states: &HashMap<u64, NodeState>,
    out: &mut Vec<HitEntry>,
) -> bool {
    if n.hidden || !n.frame.contains(p) {
        return false;
    }
    let mark = out.len();
    out.push(HitEntry {
        id: n.id,
        gestures: n.gestures,
        press: n.press_feedback,
        scroll: n.scroll,
    });
    let mut local = Point::new(p.x - n.frame.x, p.y - n.frame.y);
    if let Some(spec) = n.scroll {
        let off = states.get(&n.id).map_or(0.0, |s| s.scroll_pos as f32);
        match spec.axis {
            Axis::Horizontal => local.x += off,
            Axis::Vertical => local.y += off,
        }
    }
    if let Some(l) = &n.lazy {
        for it in l.items.iter().rev() {
            if hit(it, local, states, out) {
                return true;
            }
        }
    }
    for &i in paint_order(n).iter().rev() {
        if hit(&n.children[i], local, states, out) {
            return true;
        }
    }
    if n.is_inert() {
        // Empty space of a container takes nothing: the nodes beneath it (an overlay's catcher) get the touch.
        out.truncate(mark);
        return false;
    }
    true
}

/// A node under the pointer that cares about it: hover, cursor, tooltip or secondary click. Root first.
#[derive(Clone, Debug)]
pub(crate) struct PEntry {
    pub id: u64,
    pub interact: Interact,
    /// Frame in window points (scroll offsets applied, animated scale ignored).
    pub rect: Rect,
}

/// Collects the pointer-relevant nodes under `p` (in the parent's coordinates); `origin` is where the parent's content
/// starts in window points.
pub(crate) fn pointer_hit(
    n: &RNode,
    p: Point,
    origin: Point,
    states: &HashMap<u64, NodeState>,
    out: &mut Vec<PEntry>,
) -> bool {
    if n.hidden || !n.frame.contains(p) {
        return false;
    }
    let rect = Rect::new(
        origin.x + n.frame.x,
        origin.y + n.frame.y,
        n.frame.w,
        n.frame.h,
    );
    let mark = out.len();
    let i = &n.interact;
    if i.tracks_hover() || i.cursor.is_some() || i.tooltip.is_some() || i.secondary.is_some() {
        out.push(PEntry {
            id: n.id,
            interact: i.clone(),
            rect,
        });
    }
    let mut local = Point::new(p.x - n.frame.x, p.y - n.frame.y);
    let mut child_origin = Point::new(rect.x, rect.y);
    if let Some(spec) = n.scroll {
        let off = states.get(&n.id).map_or(0.0, |s| s.scroll_pos as f32);
        match spec.axis {
            Axis::Horizontal => {
                local.x += off;
                child_origin.x -= off;
            }
            Axis::Vertical => {
                local.y += off;
                child_origin.y -= off;
            }
        }
    }
    if let Some(l) = &n.lazy {
        for it in l.items.iter().rev() {
            if pointer_hit(it, local, child_origin, states, out) {
                return true;
            }
        }
    }
    for &c in paint_order(n).iter().rev() {
        if pointer_hit(&n.children[c], local, child_origin, states, out) {
            return true;
        }
    }
    if n.is_inert() {
        out.truncate(mark);
        return false;
    }
    true
}

/// `screen = s * layout + t`.
#[derive(Clone, Copy)]
pub(crate) struct Xf {
    pub s: f32,
    pub tx: f32,
    pub ty: f32,
}

impl Xf {
    pub const ID: Xf = Xf {
        s: 1.0,
        tx: 0.0,
        ty: 0.0,
    };
    fn rect(self, r: Rect) -> swiftly_render::Rect {
        swiftly_render::Rect::new(
            r.x * self.s + self.tx,
            r.y * self.s + self.ty,
            r.w * self.s,
            r.h * self.s,
        )
    }
}

/// Painting context of one frame.
pub(crate) struct PaintCx<'a> {
    pub list: &'a mut DrawList,
    pub text: &'a mut TextSystem,
    pub states: &'a HashMap<u64, NodeState>,
}

/// Emits the quads of `n` and its children, in painter's order.
pub(crate) fn paint(n: &RNode, origin: Point, xf: Xf, pc: &mut PaintCx, root: bool, fk: f32) {
    if n.hidden {
        return;
    }
    let r = Rect::new(
        origin.x + n.frame.x,
        origin.y + n.frame.y,
        n.frame.w,
        n.frame.h,
    );
    let st = pc.states.get(&n.id);
    let (sc, op) = st.map_or((1.0_f32, 1.0_f32), |s| {
        (s.scale() as f32, s.opacity() as f32)
    });
    let mut xf2 = xf;
    if (sc - 1.0).abs() > 1e-4 {
        let (ax, ay) = n.scale_anchor.unwrap_or((0.5, 0.5));
        let (cx, cy) = (r.x + r.w * ax, r.y + r.h * ay);
        xf2 = Xf {
            s: xf.s * sc,
            tx: xf.tx + xf.s * cx * (1.0 - sc),
            ty: xf.ty + xf.s * cy * (1.0 - sc),
        };
    }
    if let Some(s) = st {
        let (dx, dy) = (s.decl_dx.value() as f32, s.decl_dy.value() as f32);
        if dx != 0.0 || dy != 0.0 {
            xf2.tx += xf.s * dx;
            xf2.ty += xf.s * dy;
        }
    }
    let screen = xf2.rect(r);
    if !root && pc.list.clip().intersection(screen).w <= 0.0 {
        return;
    }
    if !root && pc.list.clip().intersection(screen).h <= 0.0 {
        return;
    }
    let faded = op < 0.999;
    if faded {
        pc.list.push_opacity(op);
    }
    if n.clip {
        if n.clip_radius > 0.0 {
            pc.list.push_round_clip(screen, n.clip_radius * xf2.s);
        } else {
            pc.list.push_clip(screen);
        }
    }
    let interactive = n.focus.is_some()
        || n.interact.tracks_hover()
        || n.interact.selected
        || (n.interact.press == PressStyle::Row && n.press_feedback);
    let fk = if interactive {
        st.map_or(0.0, |s| s.highlight())
    } else {
        fk
    };
    if let Some(sf) = n.interact.surface
        && fk > 0.0
    {
        let c = Color::new(sf.color.r, sf.color.g, sf.color.b, sf.color.a * fk);
        pc.list.fill(screen, c, sf.radius * xf2.s);
    }
    let look = n.focus.and_then(|f| f.look).zip(st);
    if let Some((look, s)) = look {
        let k = s.focus_t.value().clamp(0.0, 1.0) as f32;
        if k > 0.0 {
            for style in [look.glow, look.shadow].into_iter().flatten() {
                paint_one(&focus_shadow(style, k, look.radius), r, screen, xf2, pc, k);
            }
        }
    }
    // A node that holds a picture's ground and border paints on the picture's own pixels.
    let has_picture = n
        .paint
        .iter()
        .any(|p| matches!(p, Paint::Image { .. } | Paint::FocusImage { .. }));
    let paint_rect = if n.snap_pixels || has_picture {
        pc.list.snapped_picture(screen)
    } else {
        screen
    };
    for p in &n.paint {
        paint_one(p, r, paint_rect, xf2, pc, fk);
    }
    let mut child_origin = Point::new(r.x, r.y);
    if let (Some(spec), Some(s)) = (n.scroll, st) {
        match spec.axis {
            Axis::Horizontal => child_origin.x -= s.scroll_pos as f32,
            Axis::Vertical => child_origin.y -= s.scroll_pos as f32,
        }
    }
    if let Some(l) = &n.lazy {
        for it in &l.items {
            paint(it, child_origin, xf2, pc, false, fk);
        }
    }
    for i in paint_order(n) {
        paint(&n.children[i], child_origin, xf2, pc, false, fk);
    }
    // The ring comes after the children: a picture inside the node would otherwise cover it.
    if let (Some(ring), Some(s)) = (n.interact.ring, st) {
        let k = s.focus_t.value().clamp(0.0, 1.0) as f32;
        if k > 0.0 {
            let c = Color::new(ring.color.r, ring.color.g, ring.color.b, ring.color.a * k);
            if ring.fill.is_some() {
                pc.list.fill(screen, c, ring.radius * xf2.s);
            } else {
                pc.list
                    .stroke(screen, c, ring.width * xf2.s, ring.radius * xf2.s);
            }
        }
    }
    if let (Some(spec), Some(s)) = (n.scroll, st)
        && spec.axis == Axis::Vertical
        && let Some(b) = &s.scroll
    {
        let v = Rect::new(screen.x, screen.y, screen.w, screen.h);
        crate::scrollbar::paint(pc.list, v, s.scroll_pos, b.metrics, &s.bar, xf2.s);
    }
    if n.clip {
        pc.list.pop_clip();
    }
    if faded {
        pc.list.pop_opacity();
    }
}

/// Screen frames (window points, scroll offsets of the parents applied) of the vertical scroll views in tree order.
pub(crate) fn bar_views(
    n: &RNode,
    origin: Point,
    states: &HashMap<u64, NodeState>,
    out: &mut Vec<(u64, Rect)>,
) {
    if n.hidden {
        return;
    }
    let r = Rect::new(
        origin.x + n.frame.x,
        origin.y + n.frame.y,
        n.frame.w,
        n.frame.h,
    );
    let mut child_origin = Point::new(r.x, r.y);
    if let Some(spec) = n.scroll {
        let off = states.get(&n.id).map_or(0.0, |s| s.scroll_pos as f32);
        match spec.axis {
            Axis::Horizontal => child_origin.x -= off,
            Axis::Vertical => {
                child_origin.y -= off;
                if states
                    .get(&n.id)
                    .and_then(|s| s.scroll.as_ref())
                    .is_some_and(|b| b.metrics.scrollable())
                {
                    out.push((n.id, r));
                }
            }
        }
    }
    for c in &n.children {
        bar_views(c, child_origin, states, out);
    }
}

/// The shadow of a focus look with its alpha scaled by the focus amount `k`.
fn focus_shadow(style: swiftly_render::ShadowStyle, k: f32, radius: f32) -> Paint {
    let mut style = style;
    style.color.a *= k;
    Paint::Shadow { style, radius }
}

fn paint_one(p: &Paint, r: Rect, screen: swiftly_render::Rect, xf: Xf, pc: &mut PaintCx, fk: f32) {
    match p {
        Paint::FocusFill { color, radius } => {
            let c = Color::new(color.r, color.g, color.b, color.a * fk);
            pc.list.fill(screen, c, radius * xf.s);
        }
        Paint::FocusImage {
            image,
            rest,
            focused,
            radius,
        } => {
            let mix = |a: f32, b: f32| a + (b - a) * fk;
            let tint = Color::new(
                mix(rest.r, focused.r),
                mix(rest.g, focused.g),
                mix(rest.b, focused.b),
                mix(rest.a, focused.a),
            );
            pc.list.image(screen, image.uv, tint, radius * xf.s);
        }
        Paint::FocusText {
            text,
            style,
            rest,
            focused,
            lines,
            align,
        } => {
            let mix = |a: f32, b: f32| a + (b - a) * fk;
            let color = Color::new(
                mix(rest.r, focused.r),
                mix(rest.g, focused.g),
                mix(rest.b, focused.b),
                mix(rest.a, focused.a),
            );
            let plain = Paint::Text {
                text: text.clone(),
                style: *style,
                color,
                lines: *lines,
                align: *align,
            };
            paint_one(&plain, r, screen, xf, pc, fk);
        }
        Paint::Fill { color, radius } => pc.list.fill(screen, *color, radius * xf.s),
        Paint::Linear { gradient, radius } => pc.list.fill(screen, *gradient, radius * xf.s),
        Paint::Stops {
            stops,
            vertical,
            radius,
        } => pc.list.fill_stops(screen, *vertical, stops, radius * xf.s),
        Paint::Radial {
            center,
            radii,
            stops,
        } => pc.list.radial_stops(
            screen,
            [
                screen.x + center[0] * screen.w,
                screen.y + center[1] * screen.h,
            ],
            [radii[0] * screen.w, radii[1] * screen.h],
            stops,
        ),
        Paint::Blur { blur, tint, radius } => {
            pc.list
                .backdrop_blur(screen, blur * xf.s, *tint, radius * xf.s)
        }
        Paint::Stroke {
            color,
            width,
            radius,
        } => pc.list.stroke(screen, *color, *width, radius * xf.s),
        Paint::Arc {
            color,
            width,
            from,
            to,
        } => pc.list.arc(screen, *color, width * xf.s, *from, *to),
        Paint::Shadow { style, radius } => {
            let mut s = *style;
            s.dx *= xf.s;
            s.dy *= xf.s;
            s.blur *= xf.s;
            pc.list.shadow(screen, s, radius * xf.s);
        }
        Paint::Image {
            image,
            tint,
            radius,
            dither,
        } => {
            if *dither {
                pc.list
                    .image_dithered(screen, image.uv, *tint, radius * xf.s);
            } else {
                pc.list.image(screen, image.uv, *tint, radius * xf.s);
            }
        }
        Paint::Text {
            text,
            style,
            color,
            lines,
            align,
        } => {
            let l = pc.text.layout(text, style, Some(r.w + 0.5), *lines, *align);
            let (x, y) = (screen.x, screen.y);
            pc.text.atlas.draw(&l, pc.list, x, y, *color);
        }
    }
}

/// Finds the first node with `key` (paint order, lazy items included).
pub(crate) fn find_key(n: &RNode, key: Key) -> Option<u64> {
    if n.key == Some(key) {
        return Some(n.id);
    }
    if let Some(l) = &n.lazy {
        for it in &l.items {
            if let Some(f) = find_key(it, key) {
                return Some(f);
            }
        }
    }
    n.children.iter().find_map(|c| find_key(c, key))
}

/// The frame `(x, y, w, h)` in window points of the first node with `key`, scroll offsets included.
pub(crate) fn frame_of_key(
    n: &RNode,
    origin: Point,
    states: &HashMap<u64, NodeState>,
    key: Key,
) -> Option<[f32; 4]> {
    let r = Rect::new(
        origin.x + n.frame.x,
        origin.y + n.frame.y,
        n.frame.w,
        n.frame.h,
    );
    if n.key == Some(key) {
        return Some([r.x, r.y, r.w, r.h]);
    }
    let mut child_origin = Point::new(r.x, r.y);
    if let Some(spec) = n.scroll {
        let off = states.get(&n.id).map_or(0.0, |s| s.scroll_pos as f32);
        match spec.axis {
            Axis::Horizontal => child_origin.x -= off,
            Axis::Vertical => child_origin.y -= off,
        }
    }
    if let Some(l) = &n.lazy
        && let Some(f) = l
            .items
            .iter()
            .find_map(|it| frame_of_key(it, child_origin, states, key))
    {
        return Some(f);
    }
    n.children
        .iter()
        .find_map(|c| frame_of_key(c, child_origin, states, key))
}

/// Scroll nodes in tree order: `(id, spec)`.
pub(crate) fn scroll_nodes(n: &RNode, out: &mut Vec<(u64, ScrollSpec)>) {
    if let Some(s) = n.scroll {
        out.push((n.id, s));
    }
    for c in &n.children {
        scroll_nodes(c, out);
    }
}

/// What the focus engine needs of a node: its frame in screen points and the scroll views around it.
pub(crate) struct FocusNode {
    pub node: u64,
    pub item: Option<FocusItem>,
    pub scope: Option<crate::focus::ScopeSpec>,
    pub rect: Rect,
    pub tap: Option<crate::view::Action>,
    pub long: Option<crate::view::Action>,
    /// Enclosing scroll views, innermost last: node id, axis and viewport in screen points.
    pub scrolls: Vec<(u64, Axis, Rect)>,
    pub parent_scope: Option<crate::focus::FocusId>,
}

/// Collects the focusable nodes and scopes in tree order with screen frames (scroll offsets applied; lazy items
/// included).
pub(crate) fn focus_nodes(
    n: &RNode,
    origin: Point,
    states: &HashMap<u64, NodeState>,
    scrolls: &mut Vec<(u64, Axis, Rect)>,
    scope: Option<crate::focus::FocusId>,
    out: &mut Vec<FocusNode>,
) {
    if n.hidden {
        return;
    }
    let r = Rect::new(
        origin.x + n.frame.x,
        origin.y + n.frame.y,
        n.frame.w,
        n.frame.h,
    );
    let mut inner = scope;
    if let Some(s) = n.scope {
        out.push(FocusNode {
            node: n.id,
            item: None,
            scope: Some(s),
            rect: r,
            tap: None,
            long: None,
            scrolls: scrolls.clone(),
            parent_scope: scope,
        });
        inner = Some(s.id);
    }
    if n.focus.is_some() {
        out.push(FocusNode {
            node: n.id,
            item: n.focus,
            scope: None,
            rect: r,
            tap: n.gestures.tap,
            long: n.gestures.long_press,
            scrolls: scrolls.clone(),
            parent_scope: inner,
        });
    }
    let mut child_origin = Point::new(r.x, r.y);
    let pushed = n.scroll.is_some();
    if let Some(spec) = n.scroll {
        let off = states.get(&n.id).map_or(0.0, |s| s.scroll_pos as f32);
        match spec.axis {
            Axis::Horizontal => child_origin.x -= off,
            Axis::Vertical => child_origin.y -= off,
        }
        scrolls.push((n.id, spec.axis, r));
    }
    if let Some(l) = &n.lazy {
        for it in &l.items {
            focus_nodes(it, child_origin, states, scrolls, inner, out);
        }
    }
    for c in &n.children {
        focus_nodes(c, child_origin, states, scrolls, inner, out);
    }
    if pushed {
        scrolls.pop();
    }
}

/// All text a node paints, in tree order (the name of a tile or button that has no explicit label).
fn texts_of(n: &RNode, out: &mut Vec<String>) {
    if n.hidden {
        return;
    }
    if let Some(a) = &n.a11y {
        if a.role == crate::a11y::Role::Decorative {
            return;
        }
        if !a.label.is_empty() {
            out.push(a.label.clone());
            return;
        }
    }
    for p in &n.paint {
        match p {
            Paint::Text { text, .. } | Paint::FocusText { text, .. } if !text.trim().is_empty() => {
                out.push(text.clone())
            }
            _ => {}
        }
    }
    if let Some(l) = &n.lazy {
        for it in &l.items {
            texts_of(it, out);
        }
    }
    for c in &n.children {
        texts_of(c, out);
    }
}

fn leaf_role(r: crate::a11y::Role) -> bool {
    use crate::a11y::Role as R;
    !matches!(
        r,
        R::Group | R::List | R::TabList | R::Dialog | R::Status | R::Decorative
    )
}

/// Builds the screen-reader nodes of `n` (explicit descriptions where a view gave them; otherwise buttons for
/// everything that takes a tap or focus and static text for the rest) with frames in window points. Plain layout
/// nodes disappear: their children are hoisted into `out`.
pub(crate) fn a11y_nodes(
    n: &RNode,
    origin: Point,
    states: &HashMap<u64, NodeState>,
    focused: Option<crate::focus::FocusId>,
    out: &mut Vec<crate::a11y::A11yNode>,
) {
    use crate::a11y::{A11yNode, Role};
    if n.hidden {
        return;
    }
    let r = Rect::new(
        origin.x + n.frame.x,
        origin.y + n.frame.y,
        n.frame.w,
        n.frame.h,
    );
    let mut child_origin = Point::new(r.x, r.y);
    if let Some(spec) = n.scroll {
        let off = states.get(&n.id).map_or(0.0, |s| s.scroll_pos as f32);
        match spec.axis {
            Axis::Horizontal => child_origin.x -= off,
            Axis::Vertical => child_origin.y -= off,
        }
    }
    let interactive =
        n.gestures.tap.is_some() || n.gestures.long_press.is_some() || n.focus.is_some();
    let mut node = match n.a11y.as_deref() {
        Some(t) if t.role == Role::Decorative => return,
        Some(t) => t.clone(),
        None if interactive => {
            let mut a = A11yNode::new("", Role::Button, "");
            a.merge = true;
            a
        }
        None => {
            let mut text = None;
            for p in &n.paint {
                if let Paint::Text { text: t, .. } | Paint::FocusText { text: t, .. } = p
                    && !t.trim().is_empty()
                {
                    text = Some(t.clone());
                }
            }
            if let Some(t) = text {
                let mut a = A11yNode::new(format!("n{:x}", n.id), Role::Text, t);
                a.id = n.id;
                a.bounds = Some([r.x, r.y, r.w, r.h]);
                out.push(a);
            } else {
                if let Some(l) = &n.lazy {
                    for it in &l.items {
                        a11y_nodes(it, child_origin, states, focused, out);
                    }
                }
                for c in &n.children {
                    a11y_nodes(c, child_origin, states, focused, out);
                }
            }
            return;
        }
    };
    node.id = n.id;
    node.bounds = Some([r.x, r.y, r.w, r.h]);
    node.activatable = n.gestures.tap.is_some();
    node.focused |= n.focus.is_some_and(|f| Some(f.id) == focused);
    if node.key.is_empty() {
        node.key = format!("n{:x}", n.id);
    }
    if node.merge || leaf_role(node.role) {
        if node.label.is_empty() {
            let mut t = Vec::new();
            for p in &n.paint {
                if let Paint::Text { text, .. } | Paint::FocusText { text, .. } = p {
                    t.push(text.clone());
                }
            }
            for c in &n.children {
                texts_of(c, &mut t);
            }
            if let Some(l) = &n.lazy {
                for it in &l.items {
                    texts_of(it, &mut t);
                }
            }
            node.label = t.join(", ");
        }
    } else {
        if let Some(l) = &n.lazy {
            for it in &l.items {
                a11y_nodes(it, child_origin, states, focused, &mut node.children);
            }
        }
        for c in &n.children {
            a11y_nodes(c, child_origin, states, focused, &mut node.children);
        }
    }
    out.push(node);
}

/// A node that left the tree and plays its exit transition (`Node::exit_to`) before it disappears. It keeps the frames of
/// its last layout and is drawn over the rest; taps, focus and hover no longer reach it.
pub(crate) struct Ghost {
    pub node: RNode,
    /// Window position of the parent's content origin (where `node.frame` is relative to).
    pub origin: Point,
}

/// Moves every node with an exit transition that is not in `seen` out of `old` (the previous tree). Nodes inside an
/// extracted node are not looked at.
pub(crate) fn extract_exits(
    old: &mut RNode,
    origin: Point,
    states: &HashMap<u64, NodeState>,
    seen: &HashSet<u64>,
    out: &mut Vec<Ghost>,
) {
    let mut child_origin = Point::new(origin.x + old.frame.x, origin.y + old.frame.y);
    if let Some(spec) = old.scroll {
        let off = states.get(&old.id).map_or(0.0, |s| s.scroll_pos as f32);
        match spec.axis {
            Axis::Horizontal => child_origin.x -= off,
            Axis::Vertical => child_origin.y -= off,
        }
    }
    let mut i = 0;
    while i < old.children.len() {
        let c = &old.children[i];
        if c.exit.is_some() && !seen.contains(&c.id) {
            out.push(Ghost {
                node: old.children.remove(i),
                origin: child_origin,
            });
        } else {
            extract_exits(&mut old.children[i], child_origin, states, seen, out);
            i += 1;
        }
    }
    if let Some(l) = old.lazy.as_mut() {
        for it in &mut l.items {
            extract_exits(it, child_origin, states, seen, out);
        }
    }
}

/// Every node id in the subtree of `n`.
pub(crate) fn collect_ids(n: &RNode, out: &mut HashSet<u64>) {
    out.insert(n.id);
    for c in &n.children {
        collect_ids(c, out);
    }
    if let Some(l) = &n.lazy {
        for it in &l.items {
            collect_ids(it, out);
        }
    }
}
