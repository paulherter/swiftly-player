//! The propose/answer engine: a parent proposes a size, the child answers with the size it takes, the parent places it.
//!
//! Sources are named per rule. "Apple" is Apple's documentation, "objc.io" is the reverse-engineered behaviour
//! described in *Thinking in SwiftUI* / the objc.io layout series (community), "estimated" is our judgement. See `NOTES.md`.

use crate::geom::{Align, Alignment, Axes, Axis, Point, Proposal, Rect, Size};
use crate::lazy::LazyPlan;
use crate::node::{AdaptiveGrid, ContentMode, FlexFrame, Kind, LazyStack, Node};
use std::collections::HashMap;

/// Default gap between two stack children when `spacing` is `None` (Apple: "system-preferred spacing"; the adaptive
/// value depends on the view types, 8 pt is the common case). Estimated.
pub const DEFAULT_SPACING: f32 = 8.0;
/// Default `Spacer` minimum length (Apple: "the system default minimum"). Estimated as the default spacing.
pub const DEFAULT_SPACER_MIN: f32 = 8.0;

/// A node after layout. Frames are relative to the parent's origin.
#[derive(Clone, Debug)]
pub struct Placed {
    /// Where the node sits in its parent and how big it is.
    pub frame: Rect,
    /// Children in the order of [`Node::children`].
    pub children: Vec<Placed>,
    /// Scroll views: the size of the scrolled content (the child's frame starts at the origin).
    pub content: Option<Size>,
    /// Lazy stacks and grids: the plan that tells where each item is and which are visible.
    pub lazy: Option<LazyPlan>,
    /// `ViewThatFits`: this child was not chosen and takes no part.
    pub hidden: bool,
}

struct Arr {
    size: Size,
    kids: Vec<Rect>,
    hidden: Vec<bool>,
    content: Option<Size>,
    lazy: Option<LazyPlan>,
}

impl Arr {
    fn leaf(size: Size) -> Arr {
        Arr {
            size,
            kids: vec![],
            hidden: vec![],
            content: None,
            lazy: None,
        }
    }
    fn with_kids(size: Size, kids: Vec<Rect>) -> Arr {
        Arr {
            size,
            hidden: vec![false; kids.len()],
            kids,
            content: None,
            lazy: None,
        }
    }
}

type Key = (usize, u8, u64, u64);

fn bits(v: Option<f32>) -> u64 {
    v.map_or(u64::MAX, |x| u64::from(x.to_bits()))
}

fn ctx_code(c: Option<Axis>) -> u8 {
    match c {
        None => 0,
        Some(Axis::Horizontal) => 1,
        Some(Axis::Vertical) => 2,
    }
}

/// The layout engine. It memoises answers during one pass, so a tree can be asked many times (a stack asks each child
/// for its minimum, its maximum and its share) without blowing up with depth.
#[derive(Default)]
pub struct Engine {
    cache: HashMap<Key, Size>,
}

/// Lays out `root` in a container of `container` points and returns the placed tree. The root takes the size it
/// answers for the container and is centered in it (a hosting view centers its content).
pub fn layout(root: &Node, container: Size) -> Placed {
    layout_aligned(root, container, Alignment::CENTER)
}

/// Like [`layout`] with an explicit alignment of the root inside the container.
pub fn layout_aligned(root: &Node, container: Size, align: Alignment) -> Placed {
    let mut e = Engine::default();
    let size = e.size(root, Proposal::value(container), None);
    let at = align.place(container, size);
    e.place(root, Rect::from_size(at.x, at.y, size), None)
}

/// Asks `node` how big it wants to be for `proposal` (no placement).
pub fn size_that_fits(node: &Node, proposal: Proposal) -> Size {
    Engine::default().size(node, proposal, None)
}

fn finite(v: f32) -> f32 {
    if v.is_finite() { v } else { 0.0 }
}

fn is_spacer(n: &Node) -> bool {
    matches!(n.kind, Kind::Spacer { .. })
}

fn shrink(p: Option<f32>, by: f32) -> Option<f32> {
    p.map(|v| if v.is_finite() { (v - by).max(0.0) } else { v })
}

impl Engine {
    /// The size `node` answers for `p`. `ctx` is the axis of the stack that holds the node (spacers need it).
    pub fn size(&mut self, node: &Node, p: Proposal, ctx: Option<Axis>) -> Size {
        let key = (
            node as *const Node as usize,
            ctx_code(ctx),
            bits(p.w),
            bits(p.h),
        );
        if let Some(s) = self.cache.get(&key) {
            return *s;
        }
        let s = self.arrange(node, p, ctx).size;
        self.cache.insert(key, s);
        s
    }

    /// Places `node` in `frame` (its answered size) and recursively its children.
    pub fn place(&mut self, node: &Node, frame: Rect, ctx: Option<Axis>) -> Placed {
        let arr = self.arrange(node, Proposal::value(frame.size()), ctx);
        let child_ctx = child_ctx(node, ctx);
        let mut children = Vec::with_capacity(node.children.len());
        for (i, child) in node.children.iter().enumerate() {
            let r = arr.kids.get(i).copied().unwrap_or(Rect::ZERO);
            let hidden = arr.hidden.get(i).copied().unwrap_or(false);
            if hidden {
                children.push(Placed {
                    frame: Rect::ZERO,
                    children: vec![],
                    content: None,
                    lazy: None,
                    hidden: true,
                });
            } else {
                children.push(self.place(child, r, child_ctx));
            }
        }
        Placed {
            frame,
            children,
            content: arr.content,
            lazy: arr.lazy,
            hidden: false,
        }
    }

    fn arrange(&mut self, node: &Node, p: Proposal, ctx: Option<Axis>) -> Arr {
        match &node.kind {
            Kind::Fixed(s) => Arr::leaf(*s),
            Kind::Flexible { ideal } => Arr::leaf(Size::new(
                p.w.unwrap_or(ideal.w).max(0.0),
                p.h.unwrap_or(ideal.h).max(0.0),
            )),
            Kind::Measured(m) => {
                let s = (m.0)(p);
                Arr::leaf(Size::new(s.w.max(0.0), s.h.max(0.0)))
            }
            Kind::Spacer { min } => {
                Arr::leaf(spacer_size(min.unwrap_or(DEFAULT_SPACER_MIN), p, ctx))
            }
            Kind::Stack {
                axis,
                spacing,
                align,
            } => self.stack(node, p, *axis, *spacing, *align),
            Kind::ZStack(a) => self.zstack(node, p, *a),
            Kind::Frame { w, h, align } => self.frame(node, p, *w, *h, *align, ctx),
            Kind::FlexFrame(f) => self.flex_frame(node, p, f, ctx),
            Kind::Padding(i) => {
                let Some(child) = node.children.first() else {
                    return Arr::leaf(Size::new(i.horizontal(), i.vertical()));
                };
                let inner = Proposal::new(shrink(p.w, i.horizontal()), shrink(p.h, i.vertical()));
                let cs = self.size(child, inner, ctx);
                Arr::with_kids(
                    Size::new(cs.w + i.horizontal(), cs.h + i.vertical()),
                    vec![Rect::from_size(i.leading, i.top, cs)],
                )
            }
            Kind::Overlay(a) | Kind::Background(a) => self.layers(node, p, *a, ctx),
            Kind::Aspect { ratio, mode } => self.aspect(node, p, *ratio, *mode, ctx),
            Kind::FixedSize { h, v } => {
                let Some(child) = node.children.first() else {
                    return Arr::leaf(Size::ZERO);
                };
                let q = Proposal::new(if *h { None } else { p.w }, if *v { None } else { p.h });
                let cs = self.size(child, q, ctx);
                Arr::with_kids(cs, vec![Rect::from_size(0.0, 0.0, cs)])
            }
            Kind::ViewThatFits(axes) => self.view_that_fits(node, p, *axes, ctx),
            Kind::LazyStack(s) => self.lazy_stack(s, p),
            Kind::Grid(g) => self.grid(g, p),
            Kind::Scroll(axis) => self.scroll(node, p, *axis),
        }
    }

    fn stack(
        &mut self,
        node: &Node,
        p: Proposal,
        axis: Axis,
        spacing: Option<f32>,
        align: Align,
    ) -> Arr {
        let kids = &node.children;
        let n = kids.len();
        if n == 0 {
            return Arr::leaf(Size::ZERO);
        }
        let gaps: Vec<f32> = (0..n - 1)
            .map(|i| match spacing {
                Some(s) => s,
                None if is_spacer(&kids[i]) || is_spacer(&kids[i + 1]) => 0.0,
                None => DEFAULT_SPACING,
            })
            .collect();
        let gap_total: f32 = gaps.iter().sum();
        let cross_p = p.along(axis.cross());
        let main = |s: Size| s.along(axis);
        let mut sizes = vec![Size::ZERO; n];
        match p.along(axis) {
            // Apple: a `nil` proposal asks every child for its ideal size; the stack is as big as they are together.
            None => {
                for (i, k) in kids.iter().enumerate() {
                    sizes[i] = self.size(k, Proposal::from_axis(axis, None, cross_p), Some(axis));
                }
            }
            Some(total) => {
                // objc.io: ask every child for its minimum and maximum along the axis, offer space to the least
                // flexible first (higher layout priority before that), each gets remaining / children left.
                let mins: Vec<f32> = kids
                    .iter()
                    .map(|k| {
                        main(self.size(
                            k,
                            Proposal::from_axis(axis, Some(0.0), cross_p),
                            Some(axis),
                        ))
                    })
                    .collect();
                let maxs: Vec<f32> = kids
                    .iter()
                    .map(|k| {
                        main(self.size(
                            k,
                            Proposal::from_axis(axis, Some(f32::INFINITY), cross_p),
                            Some(axis),
                        ))
                    })
                    .collect();
                let mut order: Vec<usize> = (0..n).collect();
                order.sort_by(|&a, &b| {
                    kids[b]
                        .priority
                        .total_cmp(&kids[a].priority)
                        .then((maxs[a] - mins[a]).total_cmp(&(maxs[b] - mins[b])))
                        .then(a.cmp(&b))
                });
                let mut remaining = total - gap_total;
                let mut done = vec![false; n];
                for &i in &order {
                    let pri = kids[i].priority;
                    let reserved: f32 = (0..n)
                        .filter(|&j| !done[j] && j != i && kids[j].priority < pri)
                        .map(|j| mins[j])
                        .sum();
                    let group = (0..n)
                        .filter(|&j| !done[j] && kids[j].priority == pri)
                        .count()
                        .max(1) as f32;
                    let offered = (remaining - reserved).max(0.0) / group;
                    let s = self.size(
                        &kids[i],
                        Proposal::from_axis(axis, Some(offered), cross_p),
                        Some(axis),
                    );
                    sizes[i] = s;
                    if remaining.is_finite() {
                        remaining -= main(s);
                    }
                    done[i] = true;
                }
            }
        }
        let main_total: f32 = sizes.iter().map(|s| main(*s)).sum::<f32>() + gap_total;
        let cross_total = sizes
            .iter()
            .map(|s| s.along(axis.cross()))
            .fold(0.0, f32::max);
        let size = Size::from_axis(axis, main_total, cross_total);
        let mut at = 0.0;
        let rects = sizes
            .iter()
            .enumerate()
            .map(|(i, s)| {
                let c = align.offset(cross_total, s.along(axis.cross()));
                let r = match axis {
                    Axis::Horizontal => Rect::new(at, c, s.w, s.h),
                    Axis::Vertical => Rect::new(c, at, s.w, s.h),
                };
                at += main(*s) + gaps.get(i).copied().unwrap_or(0.0);
                r
            })
            .collect();
        Arr::with_kids(size, rects)
    }

    fn zstack(&mut self, node: &Node, p: Proposal, a: Alignment) -> Arr {
        // Apple: a ZStack is as big as its biggest child; every child gets the same proposal and is aligned inside.
        let sizes: Vec<Size> = node
            .children
            .iter()
            .map(|k| self.size(k, p, None))
            .collect();
        let size = Size::new(
            sizes.iter().map(|s| s.w).fold(0.0, f32::max),
            sizes.iter().map(|s| s.h).fold(0.0, f32::max),
        );
        let rects = sizes
            .iter()
            .map(|s| {
                let at = a.place(size, *s);
                Rect::from_size(at.x, at.y, *s)
            })
            .collect();
        Arr::with_kids(size, rects)
    }

    fn frame(
        &mut self,
        node: &Node,
        p: Proposal,
        w: Option<f32>,
        h: Option<f32>,
        a: Alignment,
        ctx: Option<Axis>,
    ) -> Arr {
        // Apple: `frame(width:height:)` proposes the fixed length to its child and reports it, whatever the child does.
        let q = Proposal::new(w.or(p.w), h.or(p.h));
        let cs = node
            .children
            .first()
            .map_or(Size::ZERO, |c| self.size(c, q, ctx));
        let size = Size::new(w.unwrap_or(cs.w), h.unwrap_or(cs.h));
        let at = a.place(size, cs);
        Arr::with_kids(size, vec![Rect::from_size(at.x, at.y, cs)])
    }

    fn flex_frame(&mut self, node: &Node, p: Proposal, f: &FlexFrame, ctx: Option<Axis>) -> Arr {
        // Apple: `frame(minWidth:idealWidth:maxWidth:...)`. The proposal is clamped to [min, max] (`nil` becomes the
        // ideal), the child answers inside it, and the frame takes the clamped proposal when a maximum is set
        // (objc.io: `maxWidth: .infinity` makes the frame as wide as the proposal), else the child's size clamped.
        let axis_rule =
            |prop: Option<f32>, min: Option<f32>, ideal: Option<f32>, max: Option<f32>| {
                let lo = min.unwrap_or(0.0);
                let hi = max.unwrap_or(f32::INFINITY);
                let child_prop = match prop {
                    Some(v) => Some(v.clamp(lo, hi.max(lo))),
                    None => ideal.map(|i| i.clamp(lo, hi.max(lo))),
                };
                (child_prop, lo, hi, max.is_some())
            };
        let (pw, lo_w, hi_w, has_max_w) = axis_rule(p.w, f.min_w, f.ideal_w, f.max_w);
        let (ph, lo_h, hi_h, has_max_h) = axis_rule(p.h, f.min_h, f.ideal_h, f.max_h);
        let cs = node
            .children
            .first()
            .map_or(Size::ZERO, |c| self.size(c, Proposal::new(pw, ph), ctx));
        let fin = |child: f32, prop: Option<f32>, lo: f32, hi: f32, has_max: bool| {
            let base = if has_max {
                child.max(prop.filter(|v| v.is_finite()).unwrap_or(0.0))
            } else {
                child
            };
            base.clamp(lo, hi.max(lo))
        };
        let size = Size::new(
            fin(cs.w, pw, lo_w, hi_w, has_max_w),
            fin(cs.h, ph, lo_h, hi_h, has_max_h),
        );
        let a = f.align.unwrap_or(Alignment::CENTER);
        let at = a.place(Size::new(finite(size.w), finite(size.h)), cs);
        Arr::with_kids(size, vec![Rect::from_size(at.x, at.y, cs)])
    }

    fn layers(&mut self, node: &Node, p: Proposal, a: Alignment, ctx: Option<Axis>) -> Arr {
        // Apple: `overlay` / `background` take the size of the primary view; the secondary view is proposed that size.
        let (Some(primary), Some(second)) = (node.children.first(), node.children.get(1)) else {
            return match node.children.first() {
                Some(c) => {
                    let s = self.size(c, p, ctx);
                    Arr::with_kids(s, vec![Rect::from_size(0.0, 0.0, s)])
                }
                None => Arr::leaf(Size::ZERO),
            };
        };
        let ps = self.size(primary, p, ctx);
        let ss = self.size(second, Proposal::value(ps), None);
        let at = a.place(ps, ss);
        Arr::with_kids(
            ps,
            vec![
                Rect::from_size(0.0, 0.0, ps),
                Rect::from_size(at.x, at.y, ss),
            ],
        )
    }

    fn aspect(
        &mut self,
        node: &Node,
        p: Proposal,
        ratio: Option<f32>,
        mode: ContentMode,
        ctx: Option<Axis>,
    ) -> Arr {
        let Some(child) = node.children.first() else {
            return Arr::leaf(Size::ZERO);
        };
        // Apple: `aspectRatio(_:contentMode:)` without a ratio uses the aspect ratio of the child's ideal size.
        let ratio = match ratio {
            Some(r) if r > 0.0 => r,
            _ => {
                let ideal = self.size(child, Proposal::NIL, ctx);
                if ideal.h > 0.0 && ideal.w > 0.0 {
                    ideal.w / ideal.h
                } else {
                    1.0
                }
            }
        };
        let size = match (p.w, p.h) {
            (Some(w), Some(h)) => fit_ratio(ratio, w, h, mode),
            (Some(w), None) => Size::new(w, w / ratio),
            (None, Some(h)) => Size::new(h * ratio, h),
            (None, None) => self.size(child, Proposal::NIL, ctx),
        };
        let cs = self.size(child, Proposal::value(size), ctx);
        let at = Alignment::CENTER.place(size, cs);
        Arr::with_kids(size, vec![Rect::from_size(at.x, at.y, cs)])
    }

    fn view_that_fits(&mut self, node: &Node, p: Proposal, axes: Axes, ctx: Option<Axis>) -> Arr {
        let n = node.children.len();
        if n == 0 {
            return Arr::leaf(Size::ZERO);
        }
        // Apple: ViewThatFits evaluates its children in order and picks the first whose ideal size fits the proposal
        // on the given axes; if none fits, the last one.
        let ideal_p = Proposal::new(
            if axes.horizontal { None } else { p.w },
            if axes.vertical { None } else { p.h },
        );
        let fits = |s: Size| {
            let w_ok = !axes.horizontal || p.w.is_none_or(|w| s.w <= w + 0.001);
            let h_ok = !axes.vertical || p.h.is_none_or(|h| s.h <= h + 0.001);
            w_ok && h_ok
        };
        let mut chosen = n - 1;
        for (i, k) in node.children.iter().enumerate() {
            if fits(self.size(k, ideal_p, ctx)) {
                chosen = i;
                break;
            }
        }
        let s = self.size(&node.children[chosen], p, ctx);
        let mut arr = Arr::with_kids(s, vec![Rect::ZERO; n]);
        arr.kids[chosen] = Rect::from_size(0.0, 0.0, s);
        arr.hidden = (0..n).map(|i| i != chosen).collect();
        arr
    }

    fn lazy_stack(&mut self, s: &LazyStack, p: Proposal) -> Arr {
        // Apple: lazy stacks take the whole cross-axis proposal; the main axis is the length of all items.
        let plan = LazyPlan::stack(s, p.along(s.axis.cross()));
        let mut a = Arr::leaf(plan.content_size());
        a.lazy = Some(plan);
        a
    }

    fn grid(&mut self, g: &AdaptiveGrid, p: Proposal) -> Arr {
        let width =
            p.w.filter(|w| w.is_finite())
                .unwrap_or(2.0 * g.margin + g.item.w);
        let plan = LazyPlan::grid(g, width);
        let mut a = Arr::leaf(plan.content_size());
        a.lazy = Some(plan);
        a
    }

    fn scroll(&mut self, node: &Node, p: Proposal, axis: Axis) -> Arr {
        let Some(child) = node.children.first() else {
            return Arr::leaf(p.or(Size::ZERO));
        };
        // Apple: a ScrollView offers its content the viewport on the cross axis and an unspecified length on the
        // scrolled axis; it takes the space it is offered (its content size when it is offered none).
        let cross_len = p.along(axis.cross());
        let q = Proposal::from_axis(axis, None, cross_len);
        let content = self.size(child, q, Some(axis));
        let viewport = Size::new(
            p.w.filter(|v| v.is_finite()).unwrap_or(content.w),
            p.h.filter(|v| v.is_finite()).unwrap_or(content.h),
        );
        let mut a = Arr::with_kids(viewport, vec![Rect::from_size(0.0, 0.0, content)]);
        a.content = Some(content);
        a
    }
}

fn child_ctx(node: &Node, ctx: Option<Axis>) -> Option<Axis> {
    match &node.kind {
        Kind::Stack { axis, .. } => Some(*axis),
        Kind::Scroll(axis) => Some(*axis),
        Kind::Frame { .. }
        | Kind::FlexFrame(_)
        | Kind::Padding(_)
        | Kind::FixedSize { .. }
        | Kind::Aspect { .. }
        | Kind::ViewThatFits(_)
        | Kind::Overlay(_)
        | Kind::Background(_) => ctx,
        _ => None,
    }
}

fn spacer_size(min: f32, p: Proposal, ctx: Option<Axis>) -> Size {
    let along = |v: Option<f32>| v.map_or(min, |x| x.max(min));
    match ctx {
        Some(Axis::Horizontal) => Size::new(along(p.w), 0.0),
        Some(Axis::Vertical) => Size::new(0.0, along(p.h)),
        None => Size::new(along(p.w), along(p.h)),
    }
}

fn fit_ratio(ratio: f32, w: f32, h: f32, mode: ContentMode) -> Size {
    match (w.is_finite(), h.is_finite()) {
        (false, false) => Size::new(f32::INFINITY, f32::INFINITY),
        (false, true) => Size::new(h * ratio, h),
        (true, false) => Size::new(w, w / ratio),
        (true, true) => {
            let wide = w / h.max(f32::MIN_POSITIVE) > ratio;
            let by_height = match mode {
                ContentMode::Fit => wide,
                ContentMode::Fill => !wide,
            };
            if by_height {
                Size::new(h * ratio, h)
            } else {
                Size::new(w, w / ratio)
            }
        }
    }
}

impl Placed {
    /// The absolute frame of the node reached by following `path` (child indices) from this root placed at `origin`.
    pub fn absolute(&self, origin: Point, path: &[usize]) -> Option<Rect> {
        let mut at = Point::new(origin.x + self.frame.x, origin.y + self.frame.y);
        let mut node = self;
        for &i in path {
            node = node.children.get(i)?;
            at = Point::new(at.x + node.frame.x, at.y + node.frame.y);
        }
        Some(Rect::new(at.x, at.y, node.frame.w, node.frame.h))
    }
}
