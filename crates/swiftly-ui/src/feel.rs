//! The Mac app's motion vocabulary and interaction numbers, by their Swift names, so screens use tokens and never
//! literals. Sources: the Mac motion measurements (`Sources/macOS/Style.swift`), the
//! generated motion tokens of `swiftly-design` (`desktop::motion`), and the A/B/C specs for hover, tooltips and menus.
//!
//! Every function returns a [`Motion`]; Reduce Motion is applied where the motion is used (`Motion::resolved`).

use crate::anim::Motion;
use swiftly_design::types::Curve;
use swiftly_motion::Spring;

/// Maps a design-token curve to the engine's [`Motion`]: `Smooth(d)` and `Snappy(d)` are springs of duration `d`
/// (`from_duration_bounce`, bounce 0 and 0.15), `Spring` is `from_response_damping`, the rest are bezier tweens.
pub fn from_curve(c: Curve) -> Motion {
    // The tokens hold f32; 0.12_f32 is 0.11999999..., so round to the six digits the design file wrote.
    let r = |x: f32| (f64::from(x) * 1e6).round() / 1e6;
    match c {
        Curve::Linear(d) => Motion::Linear(r(d)),
        Curve::EaseOut(d) => Motion::EaseOut(r(d)),
        Curve::EaseIn(d) => Motion::EaseIn(r(d)),
        Curve::EaseInOut(d) => Motion::EaseInOut(r(d)),
        Curve::Smooth(d) => Motion::Spring(Spring::smooth_d(r(d))),
        Curve::Snappy(d) => Motion::Spring(Spring::snappy_d(r(d))),
        Curve::Spring { response, damping } => {
            Motion::Spring(Spring::from_response_damping(r(response), r(damping)))
        }
    }
}

use swiftly_motion::catalogue::Id;

/// `Theme.timeFloat` / `motion.hover.macos`: hover and keyboard-focus changes, `easeOut(0.12)`.
pub fn hover() -> Motion {
    Motion::of(Id::Float)
}
/// `Theme.pressCurve` (release): the press feedback going back, `easeOut(0.12)`; press-in is instant.
pub fn press_release() -> Motion {
    Motion::of(Id::PressRelease)
}
/// `Theme.toggle` / `motion.toggle.all`: switch, check and active states, `easeOut(0.10)`.
pub fn toggle() -> Motion {
    Motion::of(Id::Toggle)
}
/// `Theme.leap` / `motion.leap.all`: every panel and expanding section, `.snappy(duration: 0.22)`.
pub fn leap() -> Motion {
    Motion::of(Id::Leap)
}
/// `Motion.change` / `motion.change.all`: `smooth(0.28)` (look colours).
pub fn change() -> Motion {
    Motion::of(Id::Change)
}
/// `Motion.select` / `motion.select.all`: `smooth(0.25)` (segments, alphabet jump).
pub fn select() -> Motion {
    Motion::of(Id::Select)
}
/// `Motion.sheet` / `motion.sheet.all`: `spring(0.35, 0.86)`.
pub fn sheet() -> Motion {
    Motion::of(Id::Sheet)
}
/// `Motion.land` / `motion.land.all`: `spring(0.45, 0.86)`.
pub fn land() -> Motion {
    Motion::of(Id::Land)
}
/// `Theme.spring`: the account picker growing out of the badge, `spring(0.35, 0.9)`.
pub fn account_picker() -> Motion {
    Motion::of(Id::AccountPicker)
}
/// `Theme.timePage` / `motion.page.macos`: `easeOut(0.18)` (sign-in to library).
pub fn page() -> Motion {
    Motion::of(Id::Page)
}
/// `Theme.reveal`: content and images arriving, `easeInOut(0.28)` (49 Mac sites). Not a token: the Mac code only.
pub fn reveal() -> Motion {
    Motion::of(Id::Reveal)
}
/// `Theme.timeArrow`: the paging arrows of a row, `easeInOut(0.18)`.
pub fn arrow() -> Motion {
    Motion::of(Id::Arrow)
}
/// `Theme.timePagesPush`: push and pop of detail pages, `easeInOut(0.45)`.
pub fn pages_push() -> Motion {
    Motion::of(Id::PagesPush)
}
/// `timeSectionToOut`: the old section leaves, `easeIn(0.12)`.
pub fn section_out() -> Motion {
    Motion::of(Id::SectionOut)
}
/// `timeSectionFromIn`: the new section arrives, `easeOut(0.22)` after 0.12 s, so both are never visible.
pub fn section_in() -> Motion {
    Motion::of(Id::SectionIn)
}
/// The placeholder pulse: opacity 0.5 to 1, `easeInOut(0.9)` forever, off under Reduce Motion.
pub fn pulse() -> Motion {
    Motion::of(Id::Pulse)
}
/// `SwiftUI .default` (bare `withAnimation {}`): spring response 0.55, damping 1.0.
pub fn default_spring() -> Motion {
    Motion::of(Id::Default)
}
/// Player controls fading in: `easeOut(0.18)` (`PlayerScreen.swift:341`).
pub fn controls_in() -> Motion {
    Motion::of(Id::ControlsIn)
}
/// Player controls fading out: `easeInOut(0.34)` (`PlayerScreen.swift:362,382`).
pub fn controls_out() -> Motion {
    Motion::of(Id::ControlsOut)
}
/// A player layer opening or closing: `easeInOut(0.2)` (`PlayerScreen.swift:427`).
pub fn player_layer() -> Motion {
    Motion::of(Id::PlayerLayer)
}
/// The press of a play or gift button: `easeOut(0.15)`.
pub fn press_fast() -> Motion {
    Motion::of(Id::PressFast)
}
/// The motion of any catalogue entry (screens that need a one-off Mac curve by id).
pub fn of(id: Id) -> Motion {
    Motion::of(id)
}
/// A catalogue entry with a start lag (the staggered rows of the account switch use the curve of the entry, delayed per row).
pub fn of_delayed(id: Id, lag: f64) -> Motion {
    Motion::Curve(id.curve().delayed(lag))
}
/// Placeholder pulse low end of the opacity.
pub const PULSE_LOW: f32 = 0.5;

/// Seconds of `reveal`.
pub const REVEAL_SECONDS: f64 = 0.28;
/// Seconds of `timeArrow`.
pub const ARROW_SECONDS: f64 = 0.18;
/// Seconds of `timePagesPush`.
pub const PAGES_PUSH_SECONDS: f64 = 0.45;
/// Seconds of the placeholder pulse.
pub const PULSE_SECONDS: f64 = 0.9;

// ---- Hover, press, focus -------------------------------------------------------------------------------------------

/// Image scale of a hovered tile (episode strip, search tile, Seerr tile). Source: `MacComponents.swift:319,393`, known.
pub const HOVER_TILE_SCALE: f32 = 1.04;
/// Scale of the hovered next-episode card and player round buttons. Source: `EpisodeCardsView.swift:182`, `PlayerScreen.swift:1844`.
pub const HOVER_CARD_SCALE: f32 = 1.06;
/// Alpha of the white hover/pressed-row/focus surface (`Theme.hoverArea`). Source: `colour/hoverArea`, known.
pub const HOVER_SURFACE_ALPHA: f32 = 0.06;
/// Corner radius of the hover surface of rows and buttons; sidebar rows use [`SIDEBAR_HOVER_RADIUS`]. Source: D section 5.
pub const HOVER_SURFACE_RADIUS: f32 = 10.0;
/// Corner radius of the sidebar row hover surface. Source: D section 5, known.
pub const SIDEBAR_HOVER_RADIUS: f32 = 8.0;
/// Fill alpha of a hovered primary button (white 100 % to 88 %). Source: `colour/primaryButtonHovers`, known.
pub const PRIMARY_HOVER_ALPHA: f32 = 0.88;
/// Milliseconds the pointer rests on a tile before it asks the server (prefetch hint). Source: `MacComponents.swift:441-446`, known.
pub const HOVER_REST_MS: f64 = 150.0;
/// Scale of a `PressButton` while pressed. Source: `macOS/Style.swift:67-68`, known.
pub const PRESS_BUTTON_SCALE: f64 = 0.97;
/// Opacity of a `PressButton` while pressed. Source: `macOS/Style.swift:67-68`, known.
pub const PRESS_BUTTON_OPACITY: f64 = 0.85;
/// Opacity of a `PressText` while pressed. Source: `Shared/Style.swift:105-112`, known.
pub const PRESS_TEXT_OPACITY: f64 = 0.6;
/// Alpha of a pressed `PressRow` surface (same white 6 %). Source: `macOS/Style.swift:48`, known.
pub const PRESS_ROW_ALPHA: f32 = 0.06;
/// Seconds of the press-release ease-out (press-in is instant). Source: `macOS/Style.swift:103-105`, known.
pub const PRESS_RELEASE_SECONDS: f64 = 0.12;
/// Opacity of a disabled control. Source: estimated (the Mac code dims per control; measure and split when known).
pub const DISABLED_OPACITY: f64 = 0.4;
/// Width (pt) of the keyboard focus ring. Source: estimated (the Mac replaces the ring by the hover surface; Windows and
/// Linux need a visible ring for keyboard users).
pub const FOCUS_RING_WIDTH: f32 = 2.0;

// ---- Tooltips and menus ---------------------------------------------------------------------------------------------

/// Seconds of hover before a tooltip shows. Source: `PlayerLayers.swift:97` "tooltip after 0.5 hover" (C section C3), known.
pub const TOOLTIP_DELAY_MS: f64 = 500.0;
/// Seconds of rest before a native `.help` tag shows on the Mac: `NSInitialToolTipDelay`, 1000 ms by default (Macworld, "Make tooltips
/// appear faster"; community source, other posts say 1500 or 2000). The player's own tooltip uses [`TOOLTIP_DELAY_MS`].
pub const NATIVE_TOOLTIP_DELAY_MS: f64 = 1000.0;
/// Tooltip font size and weight: 12 medium. Source: C spec `IconButton`, known.
pub const TOOLTIP_FONT: (f32, u16) = (12.0, 500);
/// Tooltip padding (horizontal, vertical). Source: C spec, known.
pub const TOOLTIP_PAD: (f32, f32) = (9.0, 5.0);
/// Tooltip corner radius. Source: C spec, known.
pub const TOOLTIP_RADIUS: f32 = 7.0;
/// Tooltip offset from the top left of its anchor: x 4, and 10 pt above the anchor's bottom edge (the Mac's `y 46` on a
/// 56 pt button). Source: C spec `offset (4,46)`, generalised.
pub const TOOLTIP_OFFSET: (f32, f32) = (4.0, -10.0);
/// Shadow of a raised panel: black 0.5, radius 9, y 6. Source: `PlayerLayers.swift:114`, known.
pub const PANEL_SHADOW: (f32, f32, f32) = (0.5, 9.0, 6.0);
/// Scale a panel grows from about the corner that touches its button. Source: `MacComponents.swift:1745-1750`, known.
pub const PANEL_EXPAND_SCALE: f32 = 0.94;
/// Width of the choice dropdown (season, filter, sort). Source: `MacComponents.swift:1375-1470`, known.
pub const DROPDOWN_WIDTH: f32 = 190.0;
/// Corner radius of a menu or dropdown panel. Source: estimated (Mac `leap` panels use 12; native menus 10).
pub const MENU_RADIUS: f32 = 12.0;
/// Height of one menu row. Source: estimated from the native menu (AppKit rows are 22 pt, ours 28 for pointer + touch).
pub const MENU_ROW_HEIGHT: f32 = 28.0;
/// Gap between a menu and its button. Source: `MacComponents.swift:1375` "y 38" on a 34 pt chip, so 4 pt.
pub const MENU_GAP: f32 = 4.0;
/// Margin kept between a menu and the window edge. Source: estimated.
pub const MENU_EDGE_MARGIN: f32 = 8.0;
