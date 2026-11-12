//! What `view(parts, env, cx)` returns: a declarative tree of nodes with layout, paint and behaviour.

use crate::anim::Motion;
use crate::cx::{Cx, ImageId};
use std::rc::Rc;
use swiftly_layout::{
    Align, Alignment, Axes, Axis, ContentMode, EdgeInsets, FlexFrame, Items, Kind, LazyStack,
    Proposal, Size,
};
use swiftly_render::{Color, ShadowStyle};
use swiftly_text::TextStyle;

/// Identity of a node among its siblings. Equal keys keep the node's retained state across rebuilds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Key(pub u64);

fn fnv(s: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h
}

impl From<&str> for Key {
    fn from(s: &str) -> Key {
        Key(fnv(s))
    }
}
impl From<u64> for Key {
    fn from(v: u64) -> Key {
        Key(v)
    }
}
impl From<usize> for Key {
    fn from(v: usize) -> Key {
        Key(v as u64)
    }
}

/// A name the view gives to a gesture; the UI reports it back in a [`UiEvent`](crate::UiEvent).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Action(pub u64);

impl From<&str> for Action {
    fn from(s: &str) -> Action {
        Action(fnv(s))
    }
}
impl From<u64> for Action {
    fn from(v: u64) -> Action {
        Action(v)
    }
}

/// Which screen edge an edge pan starts at.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Edge {
    /// Left edge (back swipe in left-to-right layouts).
    Left,
    /// Right edge.
    Right,
}

/// Gestures a node takes part in.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Gestures {
    /// A tap.
    pub tap: Option<Action>,
    /// A long press.
    pub long_press: Option<Action>,
    /// A free pan (`None` axis) or a pan locked to an axis.
    pub pan: Option<(Option<Axis>, Action)>,
    /// A pan starting at a screen edge.
    pub edge_pan: Option<(Edge, Action)>,
}

/// A scroll view's behaviour.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScrollSpec {
    /// Scroll axis.
    pub axis: Axis,
    /// Item pitch (item + gap) to snap to after a fling; `None` scrolls freely.
    pub snap_step: Option<f32>,
}

/// What a node draws, in its own frame, before its children.
#[derive(Clone, Debug)]
pub enum Paint {
    /// A filled rounded rectangle.
    Fill {
        /// Colour.
        color: Color,
        /// Corner radius.
        radius: f32,
    },
    /// A rounded rectangle filled with a linear gradient (the Swift `LinearGradient` strips of headers and heroes).
    Linear {
        /// Colours and the line in the unit square of the node.
        gradient: swiftly_render::LinearGradient,
        /// Corner radius.
        radius: f32,
    },
    /// A multi-stop gradient along one axis (the Mac header backdrop has 10 stops): `(position 0..1, colour)`.
    Stops {
        /// Stops sorted by position.
        stops: Vec<(f32, Color)>,
        /// Top to bottom when true, left to right otherwise.
        vertical: bool,
        /// Corner radius (outer ends only).
        radius: f32,
    },
    /// Frosted glass: blurs what is drawn behind the node by `blur` points under `tint` (Swift `Material` / `.blur`).
    /// The software renderer blurs; the GPU renderer draws the tint only.
    Blur {
        /// Blur radius in points.
        blur: f32,
        /// Colour laid over the blurred picture.
        tint: Color,
        /// Corner radius.
        radius: f32,
    },
    /// An inside border.
    Stroke {
        /// Colour.
        color: Color,
        /// Width.
        width: f32,
        /// Corner radius.
        radius: f32,
    },
    /// A progress arc inside the node's square (SwiftUI `Circle().trim(from: 0, to:)` rotated to start at the top, round caps).
    Arc {
        /// Colour.
        color: Color,
        /// Line width.
        width: f32,
        /// Start in turns from 12 o'clock (0..1).
        from: f32,
        /// End in turns (0..1).
        to: f32,
    },
    /// An analytic shadow of the node's rounded rectangle.
    Shadow {
        /// Shadow parameters.
        style: ShadowStyle,
        /// Corner radius of the casting shape.
        radius: f32,
    },
    /// A picture from the image page.
    Image {
        /// The picture.
        image: ImageId,
        /// Tint (white = unchanged).
        tint: Color,
        /// Corner radius.
        radius: f32,
    },
    /// A fill that fades in with the focus amount of the nearest focusable (its alpha is multiplied by it).
    FocusFill {
        /// Colour at full focus.
        color: Color,
        /// Corner radius.
        radius: f32,
    },
    /// A picture whose tint goes from `rest` to `focused` with the focus amount of the nearest focusable.
    FocusImage {
        /// The picture.
        image: ImageId,
        /// Tint at rest.
        rest: Color,
        /// Tint at full focus.
        focused: Color,
        /// Corner radius.
        radius: f32,
    },
    /// Text whose colour goes from `rest` to `focused` with the focus amount of the nearest focusable.
    FocusText {
        /// The string.
        text: String,
        /// Style.
        style: TextStyle,
        /// Colour at rest.
        rest: Color,
        /// Colour at full focus.
        focused: Color,
        /// Line limit.
        lines: Option<usize>,
        /// Alignment inside the width.
        align: swiftly_text::Align,
    },
    /// Text, laid out at the node's width.
    Text {
        /// The string.
        text: String,
        /// Style.
        style: TextStyle,
        /// Colour.
        color: Color,
        /// Line limit.
        lines: Option<usize>,
        /// Alignment inside the width.
        align: swiftly_text::Align,
    },
}

/// How a focused node looks: magnified, lifted by a shadow, optionally glowing. All three follow one spring.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FocusLook {
    /// Scale at full focus.
    pub scale: f32,
    /// Shadow at full focus (alpha is the maximum); `None` for no lift.
    pub shadow: Option<ShadowStyle>,
    /// Glow at full focus; `None` for none.
    pub glow: Option<ShadowStyle>,
    /// Corner radius of the shape that casts the shadow and the glow.
    pub radius: f32,
}

impl FocusLook {
    /// The tvOS tile/button look: scale 1.06, the one soft shadow of the Swift app, no glow.
    pub fn tile(radius: f32) -> FocusLook {
        FocusLook {
            scale: crate::tuning::FOCUS_SCALE,
            shadow: Some(ShadowStyle {
                color: Color::new(0.0, 0.0, 0.0, crate::tuning::FOCUS_SHADOW_ALPHA),
                dx: 0.0,
                dy: crate::tuning::FOCUS_SHADOW_DY,
                blur: crate::tuning::FOCUS_SHADOW_BLUR,
                spread: 0.0,
            }),
            glow: None,
            radius,
        }
    }
    /// The same look with another magnification.
    #[must_use]
    pub fn scaled(mut self, scale: f32) -> FocusLook {
        self.scale = scale;
        self
    }
    /// The same look with a glow of `color` (its alpha is scaled by the tuning glow alpha).
    #[must_use]
    pub fn with_glow(mut self, color: Color) -> FocusLook {
        self.glow = Some(ShadowStyle {
            color: Color::new(
                color.r,
                color.g,
                color.b,
                color.a * crate::tuning::FOCUS_GLOW_ALPHA,
            ),
            dx: 0.0,
            dy: 0.0,
            blur: crate::tuning::FOCUS_GLOW_BLUR,
            spread: 2.0,
        });
        self
    }
}

/// A node that can take focus: its identity and its look. The tap and long-press actions of the node are what
/// activation reports.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FocusItem {
    /// Identity.
    pub id: crate::focus::FocusId,
    /// Look while focused.
    pub look: Option<FocusLook>,
    /// Gets focus first.
    pub default: bool,
}

/// Builds the items of a lazy list on demand.
#[derive(Clone)]
pub struct LazyItems {
    /// Item `i` as a view. Called only for items near the viewport.
    pub build: Rc<dyn Fn(usize) -> Node>,
}

/// One node of the declarative tree.
#[derive(Clone)]
pub struct Node {
    /// Identity among siblings; default is the position.
    pub key: Option<Key>,
    /// Kind of node, part of the identity (so a different kind at a position starts fresh state).
    pub name: &'static str,
    /// Layout kind (children are the `children` below).
    pub kind: Kind,
    /// `layoutPriority`.
    pub priority: f32,
    /// Children.
    pub children: Vec<Node>,
    /// Drawing.
    pub paint: Vec<Paint>,
    /// Gestures.
    pub gestures: Gestures,
    /// Shows the press feedback (scale + opacity) while a tap on this node is held.
    pub press_feedback: bool,
    /// Makes this node a scroll view.
    pub scroll: Option<ScrollSpec>,
    /// Clips the children to the frame.
    pub clip: bool,
    /// Target opacity; changes animate with [`Node::motion`].
    pub opacity: f32,
    /// Target scale about the centre; changes animate with [`Node::motion`].
    pub scale: f32,
    /// How `opacity` and `scale` move to a new target.
    pub motion: Motion,
    /// Lazy list items.
    pub lazy: Option<LazyItems>,
    /// Makes this node focusable.
    pub focus: Option<FocusItem>,
    /// Makes this node a focus scope.
    pub scope: Option<crate::focus::ScopeSpec>,
    /// Hover, press style, surface, ring, cursor, tooltip, secondary click, disabled and selected.
    pub interact: crate::interact::Interact,
    /// Pivot of `scale` in the node's unit square; `None` is the centre. A panel grows out of the corner at its button.
    pub scale_anchor: Option<(f32, f32)>,
    /// Scale and opacity a node starts from when it first appears; it animates to its declared values with `motion`.
    pub appear: Option<(f32, f32)>,
    /// Scale and opacity a node animates to (with `motion`) when it is removed from the tree; it stays drawn until it has
    /// got there. SwiftUI's removal transition (`.expand(from:)` is the insert transition reversed).
    pub exit: Option<(f32, f32)>,
    /// The appear animation is skipped when the tree is built for the first time (content that is there from the start does
    /// not fade in; only content that replaces something later does).
    pub appear_skip_first: bool,
    /// Translation (points) the node rests at; changes animate with `motion` like scale and opacity.
    pub offset: (f32, f32),
    /// Translation a node starts from when it first appears (`.move(edge:)` insertion).
    pub appear_offset: Option<(f32, f32)>,
    /// Translation a node animates to when it is removed (`.move(edge:)` removal).
    pub exit_offset: Option<(f32, f32)>,
    /// Set on a frame wrapper whose width or height follows its target with this motion (`.frame(width: open ? 96 : 0)`
    /// inside `withAnimation`): the layout is redone every frame while it moves.
    pub frame_motion: Option<Motion>,
    /// What a screen reader gets for this node (role, name, value); without it the tree is inferred from text and taps.
    pub a11y: Option<Box<crate::a11y::A11yNode>>,
}

impl Node {
    fn base(name: &'static str, kind: Kind) -> Node {
        Node {
            key: None,
            name,
            kind,
            priority: 0.0,
            children: vec![],
            paint: vec![],
            gestures: Gestures::default(),
            press_feedback: false,
            scroll: None,
            clip: false,
            opacity: 1.0,
            scale: 1.0,
            motion: Motion::Instant,
            lazy: None,
            focus: None,
            scope: None,
            interact: crate::interact::Interact::default(),
            scale_anchor: None,
            appear: None,
            exit: None,
            appear_skip_first: false,
            offset: (0.0, 0.0),
            appear_offset: None,
            exit_offset: None,
            frame_motion: None,
            a11y: None,
        }
    }

    fn with_children(name: &'static str, kind: Kind, children: Vec<Node>) -> Node {
        Node {
            children,
            ..Node::base(name, kind)
        }
    }

    fn wrap(self, name: &'static str, kind: Kind) -> Node {
        let priority = self.priority;
        Node {
            priority,
            ..Node::with_children(name, kind, vec![self])
        }
    }

    /// A leaf of a fixed size.
    pub fn fixed(w: f32, h: f32) -> Node {
        Node::base("fixed", Kind::Fixed(Size::new(w, h)))
    }

    /// A flexible rounded rectangle (takes any proposal).
    pub fn rect(color: Color, radius: f32) -> Node {
        let mut n = Node::base(
            "rect",
            Kind::Flexible {
                ideal: Size::new(10.0, 10.0),
            },
        );
        n.paint.push(Paint::Fill { color, radius });
        n
    }

    /// An empty flexible leaf.
    pub fn flexible() -> Node {
        Node::base(
            "flex",
            Kind::Flexible {
                ideal: Size::new(10.0, 10.0),
            },
        )
    }

    /// A text leaf measured with swiftly-text.
    pub fn text(
        cx: &Cx,
        text: &str,
        style: &TextStyle,
        color: Color,
        lines: Option<usize>,
        align: swiftly_text::Align,
    ) -> Node {
        let (cx2, s, st) = (cx.clone(), text.to_owned(), *style);
        let measure = move |p: Proposal| cx2.measure_text(&s, &st, lines, p);
        let mut n = Node::base("text", Kind::Fixed(Size::ZERO));
        n.kind = swiftly_layout::Node::measured(measure).kind;
        n.paint.push(Paint::Text {
            text: text.to_owned(),
            style: *style,
            color,
            lines,
            align,
        });
        n
    }

    /// A picture of a fixed size with rounded corners.
    pub fn image(image: ImageId, w: f32, h: f32, radius: f32) -> Node {
        let mut n = Node::fixed(w, h);
        n.name = "image";
        n.paint.push(Paint::Image {
            image,
            tint: Color::WHITE,
            radius,
        });
        n
    }

    /// `Spacer()`.
    pub fn spacer() -> Node {
        Node::base("spacer", Kind::Spacer { min: None })
    }

    /// `Spacer(minLength:)`.
    pub fn spacer_min(min: f32) -> Node {
        Node::base("spacer", Kind::Spacer { min: Some(min) })
    }

    /// `HStack`; `align` is vertical.
    pub fn hstack(align: Align, spacing: Option<f32>, children: Vec<Node>) -> Node {
        Node::with_children(
            "hstack",
            Kind::Stack {
                axis: Axis::Horizontal,
                spacing,
                align,
            },
            children,
        )
    }

    /// `VStack`; `align` is horizontal.
    pub fn vstack(align: Align, spacing: Option<f32>, children: Vec<Node>) -> Node {
        Node::with_children(
            "vstack",
            Kind::Stack {
                axis: Axis::Vertical,
                spacing,
                align,
            },
            children,
        )
    }

    /// `ZStack`.
    pub fn zstack(align: Alignment, children: Vec<Node>) -> Node {
        Node::with_children("zstack", Kind::ZStack(align), children)
    }

    /// `ViewThatFits`.
    pub fn view_that_fits(axes: Axes, children: Vec<Node>) -> Node {
        Node::with_children("fits", Kind::ViewThatFits(axes), children)
    }

    /// A scroll view on `content`, driven by `swiftly-motion`'s `ScrollBody`.
    pub fn scroll(axis: Axis, snap_step: Option<f32>, content: Node) -> Node {
        let mut n = Node::with_children("scroll", Kind::Scroll(axis), vec![content]);
        n.scroll = Some(ScrollSpec { axis, snap_step });
        n.clip = true;
        n
    }

    /// A lazy stack of `count` items of one size; `build(i)` makes item `i` when it comes near the viewport.
    #[allow(clippy::too_many_arguments)]
    pub fn lazy_stack(
        axis: Axis,
        spacing: f32,
        count: usize,
        item: Size,
        inset_start: f32,
        inset_end: f32,
        build: impl Fn(usize) -> Node + 'static,
    ) -> Node {
        let mut n = Node::base(
            "lazy",
            Kind::LazyStack(LazyStack {
                axis,
                spacing,
                items: Items::Uniform { count, size: item },
                inset_start,
                inset_end,
                align: Align::Start,
            }),
        );
        n.lazy = Some(LazyItems {
            build: Rc::new(build),
        });
        n
    }

    /// Sets the identity key.
    #[must_use]
    pub fn key(mut self, key: impl Into<Key>) -> Node {
        self.key = Some(key.into());
        self
    }
    /// `.padding`.
    #[must_use]
    pub fn padding(self, insets: EdgeInsets) -> Node {
        self.wrap("padding", Kind::Padding(insets))
    }
    /// `.frame(width:height:alignment:)`.
    #[must_use]
    pub fn frame(self, w: Option<f32>, h: Option<f32>, align: Alignment) -> Node {
        self.wrap("frame", Kind::Frame { w, h, align })
    }
    /// The flexible frame.
    #[must_use]
    pub fn flex_frame(self, f: FlexFrame) -> Node {
        self.wrap("flexframe", Kind::FlexFrame(f))
    }
    /// `.background(view)`.
    #[must_use]
    pub fn background(self, back: Node, align: Alignment) -> Node {
        let priority = self.priority;
        Node {
            priority,
            ..Node::with_children("background", Kind::Background(align), vec![self, back])
        }
    }
    /// `.overlay(view)`.
    #[must_use]
    pub fn overlay(self, over: Node, align: Alignment) -> Node {
        let priority = self.priority;
        Node {
            priority,
            ..Node::with_children("overlay", Kind::Overlay(align), vec![self, over])
        }
    }
    /// `.aspectRatio`.
    #[must_use]
    pub fn aspect_ratio(self, ratio: Option<f32>, mode: ContentMode) -> Node {
        self.wrap("aspect", Kind::Aspect { ratio, mode })
    }
    /// `.fixedSize`.
    #[must_use]
    pub fn fixed_size(self, h: bool, v: bool) -> Node {
        self.wrap("fixedsize", Kind::FixedSize { h, v })
    }
    /// `.layoutPriority`.
    #[must_use]
    pub fn layout_priority(mut self, p: f32) -> Node {
        self.priority = p;
        self
    }
    /// Adds a paint operation drawn before the children.
    #[must_use]
    pub fn paint(mut self, p: Paint) -> Node {
        self.paint.push(p);
        self
    }
    /// Takes taps and shows the press feedback.
    #[must_use]
    pub fn on_tap(mut self, action: impl Into<Action>) -> Node {
        self.gestures.tap = Some(action.into());
        self.press_feedback = true;
        self
    }
    /// Takes taps without press feedback.
    #[must_use]
    pub fn on_tap_silent(mut self, action: impl Into<Action>) -> Node {
        self.gestures.tap = Some(action.into());
        self
    }
    /// Takes long presses.
    #[must_use]
    pub fn on_long_press(mut self, action: impl Into<Action>) -> Node {
        self.gestures.long_press = Some(action.into());
        self
    }
    /// Takes a pan (`None` axis = free).
    #[must_use]
    pub fn on_pan(mut self, axis: Option<Axis>, action: impl Into<Action>) -> Node {
        self.gestures.pan = Some((axis, action.into()));
        self
    }
    /// Takes a pan that starts at a screen edge.
    #[must_use]
    pub fn on_edge_pan(mut self, edge: Edge, action: impl Into<Action>) -> Node {
        self.gestures.edge_pan = Some((edge, action.into()));
        self
    }
    /// Makes the node focusable with `look`; its tap and long-press actions are what activation reports.
    pub fn focusable(
        mut self,
        id: impl Into<crate::focus::FocusId>,
        look: Option<FocusLook>,
    ) -> Node {
        self.focus = Some(FocusItem {
            id: id.into(),
            look,
            default: false,
        });
        self
    }
    /// Marks a focusable as the one that gets focus first.
    pub fn default_focus(mut self) -> Node {
        if let Some(f) = self.focus.as_mut() {
            f.default = true;
        }
        self
    }
    /// Makes the node a focus scope (rail, bar, sheet).
    pub fn focus_scope(mut self, spec: crate::focus::ScopeSpec) -> Node {
        self.scope = Some(spec);
        self
    }
    /// Describes the node to screen readers (the bridge adds identity, frame and focus).
    #[must_use]
    pub fn a11y(mut self, node: crate::a11y::A11yNode) -> Node {
        self.a11y = Some(Box::new(node));
        self
    }
    /// Names the node for screen readers; the role is a button when the node takes taps, else a group.
    #[must_use]
    pub fn a11y_label(self, role: crate::a11y::Role, label: impl Into<String>) -> Node {
        self.a11y(crate::a11y::A11yNode::new("", role, label))
    }
    /// Hides the node and everything under it from screen readers (decoration).
    #[must_use]
    pub fn a11y_hidden(self) -> Node {
        self.a11y(crate::a11y::A11yNode::new(
            "",
            crate::a11y::Role::Decorative,
            "",
        ))
    }
    /// Clips children to the frame.
    #[must_use]
    pub fn clipped(mut self) -> Node {
        self.clip = true;
        self
    }
    /// Target opacity, animated with `motion` when it changes between rebuilds.
    #[must_use]
    pub fn opacity(mut self, o: f32, motion: Motion) -> Node {
        self.opacity = o;
        self.motion = motion;
        self
    }
    /// Target scale about the centre, animated with `motion` when it changes between rebuilds.
    #[must_use]
    pub fn scaled(mut self, s: f32, motion: Motion) -> Node {
        self.scale = s;
        self.motion = motion;
        self
    }

    /// The pivot of the scale, in the node's unit square (0, 0 is the top left corner).
    #[must_use]
    pub fn scale_about(mut self, ax: f32, ay: f32) -> Node {
        self.scale_anchor = Some((ax, ay));
        self
    }
    /// Starts at `scale` and `opacity` when the node first appears and animates to the declared values with its
    /// motion: SwiftUI's insert transition (`.expand(from:)` is 0.94 about the button's corner).
    #[must_use]
    pub fn appear_from(mut self, scale: f32, opacity: f32) -> Node {
        self.appear = Some((scale, opacity));
        self
    }

    /// When the node leaves the tree it animates to `scale` and `opacity` with its motion and is removed once it has got
    /// there: the Mac's `.transition(.expand(from:))` closing, and `.opacity` for fades. Taps and focus no longer reach it.
    #[must_use]
    pub fn exit_to(mut self, scale: f32, opacity: f32) -> Node {
        self.exit = Some((scale, opacity));
        self
    }

    /// Content that arrives in place of a placeholder (`Theme.reveal`, the Mac's `.transition(.opacity)` with
    /// `.animation(Theme.reveal, value: loaded)`): fades in with `reveal` when it appears after the first build and out when
    /// it goes. `key` tells it apart from what it replaces. Content of the first build is simply there.
    #[must_use]
    pub fn reveal_as(mut self, key: &str) -> Node {
        self.appear_skip_first = true;
        self.appear_from(1.0, 0.0)
            .exit_to(1.0, 0.0)
            .opacity(1.0, crate::feel::reveal())
            .key(key)
    }

    /// An appear animation (`appear_from`, `appear_offset`) that is skipped when the tree is built for the first time.
    #[must_use]
    pub fn appear_after_first_build(mut self) -> Node {
        self.appear_skip_first = true;
        self
    }

    /// Translation the node rests at; a change animates with the node's motion.
    #[must_use]
    pub fn offset(mut self, dx: f32, dy: f32, motion: Motion) -> Node {
        self.offset = (dx, dy);
        self.motion = motion;
        self
    }

    /// The node slides in from this offset (points) when it first appears: `.transition(.move(edge:))` insertion.
    #[must_use]
    pub fn appear_offset(mut self, dx: f32, dy: f32) -> Node {
        self.appear_offset = Some((dx, dy));
        self
    }

    /// The node slides to this offset (points) when it is removed: `.transition(.move(edge:))` removal.
    #[must_use]
    pub fn exit_offset(mut self, dx: f32, dy: f32) -> Node {
        self.exit_offset = Some((dx, dy));
        self
    }

    /// `.frame(width:height:)` whose size follows its target with `motion` when it changes between rebuilds (`withAnimation`
    /// around a frame that depends on state). The page is laid out again every frame while it moves.
    #[must_use]
    pub fn animated_frame(
        self,
        w: Option<f32>,
        h: Option<f32>,
        align: Alignment,
        motion: Motion,
    ) -> Node {
        let mut n = self.frame(w, h, align);
        n.frame_motion = Some(motion);
        n
    }

    // ---- pointer interaction (see `crate::interact`) -----------------------------------------------------------------

    /// The press look of a tapped node (`PressRow`, `PressButton`, `PressText` or none).
    #[must_use]
    pub fn press_style(mut self, style: crate::interact::PressStyle) -> Node {
        self.interact.press = style;
        if style == crate::interact::PressStyle::None {
            self.press_feedback = false;
        }
        self
    }
    /// A surface behind the node that fades in with hover, keyboard focus, a pressed `Row` and the selected state: the
    /// Mac's white 6 % `hoverArea`.
    #[must_use]
    pub fn hover_surface(mut self, color: Color, radius: f32) -> Node {
        self.interact.surface = Some(crate::interact::Surface { color, radius });
        self
    }
    /// The standard Mac hover surface (white 6 %, radius 10).
    #[must_use]
    pub fn hover_area(self) -> Node {
        let c = Color::new(1.0, 1.0, 1.0, crate::feel::HOVER_SURFACE_ALPHA);
        self.hover_surface(c, crate::feel::HOVER_SURFACE_RADIUS)
    }
    /// Scales the node about its centre while hovered (tiles 1.04).
    #[must_use]
    pub fn hover_scale(mut self, scale: f32) -> Node {
        self.interact.hover_scale = Some(scale);
        self
    }
    /// Tracks the pointer so `FocusFill`, `FocusImage` and `FocusText` paints inside follow the hover amount.
    #[must_use]
    pub fn hoverable(mut self) -> Node {
        self.interact.hoverable = true;
        self
    }
    /// Animates the hover amount with `motion` instead of `feel::hover()`.
    #[must_use]
    pub fn hover_motion(mut self, motion: Motion) -> Node {
        self.interact.hover_motion = Some(motion);
        self.interact.hoverable = true;
        self
    }
    /// Reports `UiEvent::HoverChanged` when the pointer enters or leaves.
    #[must_use]
    pub fn on_hover(mut self, action: impl Into<Action>) -> Node {
        self.interact.hover_action = Some(action.into());
        self
    }
    /// Reports `UiEvent::HoverRest` once after the pointer rested on the node for 150 ms (the prefetch hint).
    #[must_use]
    pub fn on_hover_rest(mut self, action: impl Into<Action>) -> Node {
        self.interact.rest_action = Some(action.into());
        self
    }
    /// The cursor while the pointer is over the node.
    #[must_use]
    pub fn cursor(mut self, cursor: crate::interact::Cursor) -> Node {
        self.interact.cursor = Some(cursor);
        self
    }
    /// A tooltip shown after the Mac delay (0.5 s) of hover.
    #[must_use]
    pub fn tooltip(mut self, text: impl Into<String>) -> Node {
        self.interact.tooltip = Some(text.into());
        self.interact.hoverable = true;
        self
    }
    /// Reports `UiEvent::Secondary` on a right click (or Ctrl-click on the Mac).
    #[must_use]
    pub fn on_secondary(mut self, action: impl Into<Action>) -> Node {
        self.interact.secondary = Some(action.into());
        self
    }
    /// A ring around the node while it has keyboard focus (`FocusLook` decides scale and shadow, the ring is separate).
    #[must_use]
    pub fn focus_ring(mut self, color: Color, radius: f32) -> Node {
        self.interact.ring = Some(crate::interact::Ring {
            color,
            width: crate::feel::FOCUS_RING_WIDTH,
            radius,
            fill: None,
        });
        self
    }
    /// A surface behind the node while it has keyboard focus, and only then (no ring, no hover): the Mac's `Dim` button
    /// style marks keyboard focus with `hoverArea` and shows nothing on hover.
    #[must_use]
    pub fn focus_fill(mut self, color: Color, radius: f32) -> Node {
        self.interact.ring = Some(crate::interact::Ring {
            color,
            width: 0.0,
            radius,
            fill: Some(color),
        });
        self
    }
    /// Greyed out: dimmed, no gestures, no focus, no hover.
    #[must_use]
    pub fn disabled(mut self, disabled: bool) -> Node {
        self.interact.disabled = disabled;
        self
    }
    /// The selected look: the hover surface stays on.
    #[must_use]
    pub fn selected(mut self, selected: bool) -> Node {
        self.interact.selected = selected;
        self
    }
}
