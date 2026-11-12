//! Every feel constant of this crate, in one place. Each line names its source: `RF` is the research notes on feel
//! (section given), "known" means stated by Apple or a primary source, "community" third-party code or measurement,
//! "estimated" our own judgement that must be fitted against a device (Gates G1, G4).

// ---- Springs (RF section 2) -------------------------------------------------------------------------------------

/// Duration (s) shared by the `.smooth`, `.snappy` and `.bouncy` presets. Source: RF 2, known (Apple Spring docs).
pub const PRESET_DURATION: f64 = 0.5;
/// Bounce of `.smooth`. Source: RF 2, known.
pub const SMOOTH_BOUNCE: f64 = 0.0;
/// Bounce of `.snappy`. Source: RF 2, known.
pub const SNAPPY_BOUNCE: f64 = 0.15;
/// Bounce of `.bouncy`. Source: RF 2, known.
pub const BOUNCY_BOUNCE: f64 = 0.3;
/// Response (s) of the legacy `.spring()`. Source: RF 2, known (Apple `Animation.spring(response:)` page).
pub const LEGACY_RESPONSE: f64 = 0.5;
/// Damping fraction of the legacy `.spring()`. Source: RF 2, known.
pub const LEGACY_DAMPING_FRACTION: f64 = 0.825;
/// Response (s) of `.interactiveSpring()`. Source: RF 2, known.
pub const INTERACTIVE_RESPONSE: f64 = 0.15;
/// Damping fraction of `.interactiveSpring()`. Source: RF 2, known.
pub const INTERACTIVE_DAMPING_FRACTION: f64 = 0.86;
/// Fraction of the travel under which a spring counts as settled (`settlingDuration`). Source: RF 2, known.
pub const SETTLE_EPSILON: f64 = 0.001;
/// A [`SpringAnim`](crate::spring::SpringAnim) is settled below this distance to its target (value units). Source: estimated.
pub const ANIM_SETTLE_DISTANCE: f64 = 0.001;
/// A [`SpringAnim`](crate::spring::SpringAnim) is settled below this speed (value units per second). Source: estimated.
pub const ANIM_SETTLE_SPEED: f64 = 0.01;
// ---- Scroll (RF section 1) ----------------------------------------------------------------------------------------

/// `UIScrollView.DecelerationRate.normal`, the factor velocity keeps per millisecond. Source: RF 1, known.
pub const DECELERATION_NORMAL: f64 = 0.998;
/// `UIScrollView.DecelerationRate.fast`. Source: RF 1, known.
pub const DECELERATION_FAST: f64 = 0.99;
/// Rubber band coefficient `c` in `b(x) = (1 - 1/(x*c/d + 1)) * d`. Source: RF 1, community (chpwn reverse engineering).
pub const RUBBER_COEFFICIENT: f64 = 0.55;
/// A deceleration ends when the remaining glide distance is below this (pt, half a pixel). Source: RF 1 (`eps = 0.5`), computed.
pub const STOP_REMAINING_PT: f64 = 0.5;
/// Time (s) in which the critically damped spring back to a bound settles (to [`SETTLE_EPSILON`]). Source: RF 1, estimated (0.4-0.5 s).
pub const BACK_SETTLE_SECONDS: f64 = 0.45;
/// Look-back window (ms) of the release velocity estimate. Source: RF 1, estimated (~100 ms).
pub const VELOCITY_WINDOW_MS: f64 = 100.0;
/// A finger that rested this long (ms) before lifting releases without velocity. Source: estimated (taken from the SQ scroll body).
pub const VELOCITY_STALE_MS: f64 = 150.0;
/// A release slower than this (pt/s) does not glide. Source: estimated (taken from the SQ scroll body).
pub const MIN_FLING_SPEED: f64 = 120.0;
/// A scroll spring is at rest below this distance to its bound (pt). Source: estimated.
pub const SPRING_SETTLE_DISTANCE: f64 = 0.05;
/// A scroll spring is at rest below this speed (pt/s). Source: estimated.
pub const SPRING_SETTLE_SPEED: f64 = 1.0;
/// Deceleration rate used to project the landing point for paging and snapping. Source: RF 1, estimated ("fast", 0.99).
pub const SNAP_PROJECTION_RATE: f64 = DECELERATION_FAST;
/// Duration (s) of the snap spring. Source: RF 1/2, estimated (`.smooth`-like).
pub const SNAP_DURATION: f64 = 0.5;
/// Bounce of the snap spring (0 = critically damped, no overshoot). Source: RF 1, known ("spring (bounce 0)").
pub const SNAP_BOUNCE: f64 = 0.0;
/// Paging moves at most this many pages from the page the drag started on. Source: RF 1, estimated.
pub const PAGING_MAX_PAGES: i64 = 1;

// ---- Mac-like scrolling on Windows and Linux (from the Mac motion spec) -------------

/// Per-step decay of the momentum of a fast flick on the Mac. Source: WebKit `MomentumEventDispatcher.cpp:576-590`, which
/// re-creates "the system curve": the delta is multiplied by `alpha^(dt / 8 ms)`. Community-grade, not an Apple spec.
pub const MAC_MOMENTUM_DECAY_FAST: f64 = 0.975;
/// Per-step decay at zero speed (the slow end of the same curve). Source: same WebKit file.
pub const MAC_MOMENTUM_DECAY_SLOW: f64 = 0.91;
/// Below this speed (pt/s) the decay moves linearly from fast to slow. Source: same WebKit file.
pub const MAC_MOMENTUM_SLOW_BELOW: f64 = 250.0;
/// The step (ms) the decay is defined for. Source: same WebKit file.
pub const MAC_MOMENTUM_STEP_MS: f64 = 8.0;
/// Momentum ends below this speed (pt/s). Source: estimated (one point per second is invisible).
pub const MAC_MOMENTUM_STOP_SPEED: f64 = 1.0;
/// A pointer release slower than this (pt/s) does not glide. Source: estimated (same as the touch value).
pub const MAC_MIN_FLING_SPEED: f64 = 120.0;
/// A finger that stood still this long (ms) releases without velocity. Source: WebKit `ScrollElasticityController.mm:62`
/// (velocity zeroed after 100 ms without events), community.
pub const MAC_VELOCITY_STALE_MS: f64 = 100.0;
/// Points per notch of a discrete wheel on Windows (3 lines of 100/3 px). Source: Chromium `web_input_event_builders_win.cc:331-335`.
pub const WHEEL_NOTCH_PX_WINDOWS: f64 = 100.0;
/// Time (ms) one discrete wheel notch takes to land, ease-out `(0.23, 1, 0.32, 1)`, retargeted per notch. Chromium takes
/// 150 ms with an ease-in-out (`cc/animation/scroll_offset_animation_curve.cc:17-18`); the ease-in-out starts slowly and
/// was felt as lag, so it is an ease-out of 140 ms here (ui-gefuehl: enter/exit ease-out, UI under 300 ms).
pub const WHEEL_SMOOTH_MS: f64 = 140.0;
/// Friction (per second) of GTK 4 kinetic scrolling: `v = v0 * e^(-4 t)`. Source: `gtkscrolledwindow.c:181-183`, known.
pub const GTK_KINETIC_FRICTION: f64 = 4.0;
/// Exponent of the GTK notch step: `page_size^(2/3)`. Source: `gtkscrolledwindow.c:1226`, known.
pub const GTK_NOTCH_EXPONENT: f64 = 2.0 / 3.0;
/// Gain of touchpad pixels in GTK (`MAGIC_SCROLL_FACTOR`). The Mac-like default is 1.0; GTK itself uses 2.5. Source: GTK, known.
pub const GTK_TOUCHPAD_GAIN: f64 = 2.5;

/// A precision-touchpad stream that is quiet this long (ms) has ended: a stretched edge springs back. Windows delivers the
/// finger and the OS inertia as events 8 to 16 ms apart, so 60 ms is a few missed frames. Source: estimated, measured gaps.
pub const WHEEL_IDLE_MS: f64 = 60.0;
/// The most a wheel notch may stretch a scroller past its end (points); a quarter of the excess is shown.
pub const NOTCH_BOUNCE_CAP_PT: f64 = 28.0;
