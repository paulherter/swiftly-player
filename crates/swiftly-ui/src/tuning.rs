//! Every feel number of the UI layer, with its source. `RF` is the research notes on feel, `D2` is the Tuning and
//! `press` design decision. "known" = stated by Apple or a primary source, "community" = third
//! party, "estimated" = our judgement that Gate G1 must fit against the real iPhone app. Scroll physics constants live
//! in `swiftly-motion::tuning` (deceleration 0.998, rubber band 0.55, snap spring).

// ---- Press feedback -------------------------------------------------------------------------------------------

/// Scale of a pressed control. Source: D2 `press` (0.97), estimated for the real app (RF 3: "no source found").
pub const PRESS_SCALE: f64 = 0.97;
/// Opacity of a pressed control. Source: D2 `press` (0.85), estimated.
pub const PRESS_OPACITY: f64 = 0.85;
/// Seconds of the release animation (ease-out). Source: D2 `press` ("release easeOut 0.12"), estimated.
pub const PRESS_RELEASE_SECONDS: f64 = 0.12;
/// Delay (ms) before a press shows inside a scroll view. Source: RF 3 (`delaysContentTouches`, ~150 ms in a 2010 Apple
/// mailing-list post), community + estimated.
pub const PRESS_DELAY_IN_SCROLL_MS: f64 = 150.0;
/// Press-in is applied on the first frame after touch-down outside scroll views. Source: RF checklist 10, estimated.
pub const PRESS_IN_SECONDS: f64 = 0.0;

// ---- Gestures -------------------------------------------------------------------------------------------------

/// Distance (pt) a touch may move before it stops being a tap and a pan may begin. Source: RF 1 (WWDC18/803: "usually
/// 10 points in iOS"), known.
pub const HYSTERESIS_PT: f32 = 10.0;
/// Hold time (ms) of a long press. Source: `UILongPressGestureRecognizer.minimumPressDuration` = 0.5 s, known.
pub const LONG_PRESS_MS: f64 = 500.0;
/// Width (pt) of the screen strip where an edge pan can begin. Source: estimated (UIKit does not publish it).
pub const EDGE_PAN_WIDTH_PT: f32 = 20.0;
/// A pan locks to its axis when the movement along it is at least this share of the movement across. Source: estimated.
pub const AXIS_LOCK_RATIO: f32 = 1.0;
/// Window (ms) of the finger velocity estimate for custom pans. Source: swiftly-motion `VELOCITY_WINDOW_MS`, estimated.
pub const PAN_VELOCITY_WINDOW_MS: f64 = 100.0;

// ---- Motion ---------------------------------------------------------------------------------------------------

/// Seconds of every curve under Reduce Motion (linear). Source: D2 Tuning ("every curve linear 0.14"), known as spec.
pub const REDUCE_MOTION_SECONDS: f64 = 0.14;
/// Control points of ease-out `(x1, y1, x2, y2)`. Source: `CAMediaTimingFunction(name: .easeOut)` = (0, 0, 0.58, 1), known.
pub const EASE_OUT: (f64, f64, f64, f64) = (0.0, 0.0, 0.58, 1.0);

// ---- Keyboard scrolling -----------------------------------------------------------------------------------------

/// A page key moves the viewport height less this overlap (pt) so the last line stays visible. Source: AppKit
/// `NSScrollView` page scroll keeps a few lines; 40 pt is estimated (measure with the Mac plan).
pub const PAGE_OVERLAP_PT: f32 = 40.0;
/// One arrow-key line of a scroll view (pt). Source: AppKit `lineScroll` default 10 pt, community; Windows uses 3 lines
/// of about 19 px, estimated here as 40 pt for a desktop of this density.
pub const KEY_LINE_PT: f32 = 40.0;

// ---- Lazy lists -----------------------------------------------------------------------------------------------

/// Points of items built beyond the viewport on each side of a lazy list. Source: estimated.
pub const LAZY_OVERSCAN_PT: f32 = 64.0;

// ---- Components -----------------------------------------------------------------------------------------------

/// Gap (pt) between poster and title in a tile. Source: estimated (from the touch tile layout; measure on the iPhone).
pub const TILE_TITLE_GAP: f32 = 8.0;
/// Title lines under a poster. Source: estimated.
pub const TILE_TITLE_LINES: usize = 2;
/// Gap (pt) between a rail header and its row. Source: estimated.
pub const RAIL_HEADER_GAP: f32 = 12.0;
/// Whether a poster rail snaps to item starts after a fling (checklist item 7). Source: RF checklist 7.
pub const RAIL_SNAPS: bool = true;
/// Horizontal padding (pt) of a button label inside the pill. Source: estimated.
pub const BUTTON_LABEL_PADDING: f32 = 24.0;

// ---- Focus (RF 4 and the Swift tvOS app) -------------------------------------------------------------------------

/// A candidate may start this far (pt) behind the facing edge of the focused item and still count as ahead. Source: estimated.
pub const FOCUS_AHEAD_TOLERANCE_PT: f32 = 1.0;
/// Weight of the distance to the remembered column among candidates that overlap the focused item across the axis.
/// Source: estimated (overlap is preferred; the nearest row still wins over a far one).
pub const FOCUS_OVERLAP_CENTRE_WEIGHT: f32 = 0.25;
/// Weight of the missed distance (pt) across the axis for candidates that do not overlap. Source: estimated.
pub const FOCUS_MISS_WEIGHT: f32 = 2.0;
/// Added to the score of a candidate that does not overlap the focused item across the axis, so any overlapping
/// candidate wins (tvOS looks at the strip in front of the item first). Source: estimated.
pub const FOCUS_NO_OVERLAP_PENALTY: f32 = 100_000.0;
/// Seconds of the focus ease-out curve. Source: Swift `TVSpec.focusDuration` (`Theme.focusAnimation`, easeOut 0.14), known.
pub const FOCUS_EASE_SECONDS: f64 = 0.14;
/// Duration (s) of the optional focus spring (UNUSED: the app animates with ease-out, see DECISIONS). Source: RF 4, estimated ("spring with bounce ~0.15-0.3 over 0.4-0.5 s"; G4 fits it).
pub const FOCUS_SPRING_DURATION: f64 = 0.4;
/// Bounce of the optional focus spring (UNUSED, see DECISIONS). Source: RF 4, estimated (the low end of 0.15-0.3).
pub const FOCUS_SPRING_BOUNCE: f64 = 0.15;
/// Seconds of the linear focus curve under Reduce Motion. Source: Swift `TVSpec.reducedDuration` (0.1), known.
pub const FOCUS_REDUCE_SECONDS: f64 = 0.10;
/// Magnification of a focused poster tile and button. Source: Swift `TVSpec.focusMagnifier`, known.
pub const FOCUS_SCALE: f32 = 1.06;
/// Magnification of small controls (chips, round buttons). Source: Swift `TVSpec.focusMagnifierSmall`, known.
pub const FOCUS_SCALE_SMALL: f32 = 1.1;
/// Magnification of wide items. Source: Swift `TVSpec.focusMagnifierWide`, known.
pub const FOCUS_SCALE_WIDE: f32 = 1.03;
/// Alpha of the lift shadow at full focus. Source: Swift `lift()` (black .12), known.
pub const FOCUS_SHADOW_ALPHA: f32 = 0.12;
/// Blur (pt) of the lift shadow. Source: Swift `lift()` (radius 6), known.
pub const FOCUS_SHADOW_BLUR: f32 = 6.0;
/// Vertical offset (pt) of the lift shadow. Source: Swift `lift()` (y 2), known.
pub const FOCUS_SHADOW_DY: f32 = 2.0;
/// Alpha of the optional accent glow at full focus. Source: estimated (the Swift app has no glow).
pub const FOCUS_GLOW_ALPHA: f32 = 0.35;
/// Blur (pt) of the optional glow. Source: estimated.
pub const FOCUS_GLOW_BLUR: f32 = 14.0;
/// The focused item is kept this far (pt) inside the edges of the scroll views it sits in. Source: estimated.
pub const FOCUS_REVEAL_MARGIN_PT: f32 = 48.0;
/// Room (pt) above and below the tiles of a tv rail so the lifted tile is not cut by the scroll view's clip. Source: estimated (6 % of 312 pt is 9.4 pt per side, plus the shadow).
pub const FOCUS_HEADROOM_PT: f32 = 16.0;
/// Duration (s) of the animated scroll that brings the focused item into view. Source: Swift `Motion.select`
/// (`.smooth(duration: 0.25)`, used by the library grid's `scrollTo`), known; the home rails are scrolled by the system focus engine, unpublished.
pub const FOCUS_SCROLL_SECONDS: f64 = 0.25;
/// Alpha of a focused button's resting fill before focus turns it white. Source: Swift `ButtonLabel.background` (white .10), known.
pub const FOCUS_BUTTON_REST_ALPHA: f32 = 0.10;
