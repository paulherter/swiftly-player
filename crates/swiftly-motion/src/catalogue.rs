//! The single source of truth for every animation curve of the app: the table of the Mac app's curves, each with its
//! SwiftUI source text, its file:line in `Sources/`, and what moves. The UI layer animates only with these
//! ([`Id::curve`]); `swiftly-ui` records and the tests reject any curve that is not in this table.
//! The call sites are listed in the source.
//!
//! Named SwiftUI springs use the documented parameters: `.smooth` bounce 0, `.snappy` bounce 0.15, `.bouncy` bounce 0.3
//! (each with `duration`), `.spring(response:dampingFraction:)` with stiffness `(2 pi / response)^2` and damping
//! `4 pi zeta / response`, `.interpolatingSpring(mass: 1, stiffness: w^2, damping: 2 w)`.

use crate::curve::{Curve, Ease};
use crate::spring::Spring;

/// How a curve is built; the parameters are the ones written in the Swift source.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Spec {
    /// `.linear(duration:)`.
    Linear(f64),
    /// `.easeIn(duration:)`, bezier (0.42, 0, 1, 1).
    EaseIn(f64),
    /// `.easeOut(duration:)`, bezier (0, 0, 0.58, 1).
    EaseOut(f64),
    /// `.easeInOut(duration:)`, bezier (0.42, 0, 0.58, 1).
    EaseInOut(f64),
    /// `.smooth(duration:)`: spring of that duration, bounce 0.
    Smooth(f64),
    /// `.snappy(duration:)`: spring of that duration, bounce 0.15.
    Snappy(f64),
    /// `.bouncy(duration:)`: spring of that duration, bounce 0.3.
    Bouncy(f64),
    /// `.spring(response:dampingFraction:)`.
    Response(f64, f64),
    /// `.interpolatingSpring(mass: 1, stiffness: w * w, damping: 2 * w)` (critically damped).
    Interpolating(f64),
    /// A critically damped spring that settles in this many seconds (Rust-only: the Android page settle).
    SettlingIn(f64),
}

impl Spec {
    /// The curve of this spec (no delay).
    pub fn curve(self) -> Curve {
        match self {
            Spec::Linear(s) => Curve::tween(Ease::Linear, s),
            Spec::EaseIn(s) => Curve::tween(Ease::In, s),
            Spec::EaseOut(s) => Curve::tween(Ease::Out, s),
            Spec::EaseInOut(s) => Curve::tween(Ease::InOut, s),
            Spec::Smooth(d) => Curve::spring(Spring::smooth_d(d)),
            Spec::Snappy(d) => Curve::spring(Spring::snappy_d(d)),
            Spec::Bouncy(d) => Curve::spring(Spring::bouncy_d(d)),
            Spec::Response(r, z) => Curve::spring(Spring::from_response_damping(r, z)),
            Spec::Interpolating(w) => Curve::spring(Spring::critical_omega(w)),
            Spec::SettlingIn(s) => Curve::spring(Spring::critical_settling_in(s)),
        }
    }
}

/// Whether the animation runs once or for ever.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Repeat {
    /// Runs to its target and rests.
    Once,
    /// `.repeatForever(autoreverses: true)`: back and forth between two values.
    Pulse,
    /// `.repeatForever(autoreverses: false)`: starts over (a spinner).
    Loop,
}

/// One catalogued curve.
#[derive(Clone, Copy, Debug)]
pub struct Entry {
    /// Its id.
    pub id: Id,
    /// The Mac's name for it (`Theme.leap`) or what uses it.
    pub name: &'static str,
    /// The parameters.
    pub spec: Spec,
    /// `.delay(...)` in seconds.
    pub delay: f64,
    /// Once, pulsing or looping.
    pub repeat: Repeat,
    /// The SwiftUI expression as written in the Mac source (the tests parse it and check [`spec`](Self::spec) against it).
    pub swift: &'static str,
    /// Where it is defined or used on the Mac, `Sources/` relative, comma separated.
    pub mac: &'static str,
    /// What moves.
    pub moves: &'static str,
}

impl Entry {
    /// The evaluable curve including the delay.
    pub fn curve(&self) -> Curve {
        self.spec.curve().delayed(self.delay)
    }
}

macro_rules! table {
    ($($id:ident, $name:literal, $spec:expr, $delay:expr, $rep:expr, $swift:literal, $mac:literal, $moves:literal;)*) => {
        /// The id of a catalogued curve; indexes [`ALL`].
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        #[allow(missing_docs)]
        pub enum Id { $($id),* }

        /// Every catalogued curve, in the order of [`Id`].
        pub const ALL: &[Entry] = &[
            $(Entry { id: Id::$id, name: $name, spec: $spec, delay: $delay, repeat: $rep, swift: $swift, mac: $mac, moves: $moves }),*
        ];
    };
}

table! {
    // ---- The Mac's curve vocabulary (`Sources/macOS/Style.swift`, `Sources/Shared/Motion.swift`) ----
    Float, "Theme.timeFloat", Spec::EaseOut(0.12), 0.0, Repeat::Once,
        ".easeOut(duration: 0.12)", "macOS/Style.swift:336",
        "hover and keyboard-focus surface, tile image scale 1.04, label colour, primary button fill (46 sites)";
    PressRelease, "Theme.pressCurve (release)", Spec::EaseOut(0.12), 0.0, Repeat::Once,
        ".easeOut(duration: 0.12)", "macOS/Style.swift:103-105,51,82",
        "press release: scale 0.97 and opacity 0.85 back to 1, row surface out; press-in is instant";
    Toggle, "Theme.toggle", Spec::EaseOut(0.10), 0.0, Repeat::Once,
        ".easeOut(duration: 0.10)", "macOS/Style.swift:108-110",
        "switch, check and active states (9 sites)";
    Leap, "Theme.leap", Spec::Snappy(0.22), 0.0, Repeat::Once,
        ".snappy(duration: 0.22)", "macOS/Style.swift:113-115",
        "every panel, dropdown, expanding section, edit bar (42 sites): scale 0.94 about the button corner + opacity";
    Reveal, "Theme.reveal", Spec::EaseInOut(0.28), 0.0, Repeat::Once,
        ".easeInOut(duration: 0.28)", "macOS/Style.swift:362-364",
        "content and image arrival, rail paging scroll, player episode strip scroll (49 sites)";
    Arrow, "Theme.timeArrow", Spec::EaseInOut(0.18), 0.0, Repeat::Once,
        ".easeInOut(duration: FadeTimes.arrows)", "macOS/Style.swift:340, JellyfinKit/FadeTimes.swift:41",
        "paging arrows of a rail and the player episode strip fade in and out";
    Page, "Theme.timePage", Spec::EaseOut(0.18), 0.0, Repeat::Once,
        ".easeOut(duration: 0.18)", "macOS/Style.swift:388, RootView.swift:53",
        "model.phase change (sign-in to library)";
    PagesPush, "Theme.timePagesPush", Spec::EaseInOut(0.45), 0.0, Repeat::Once,
        ".easeInOut(duration: durationPagesPush)", "macOS/Style.swift:403,412, Navigator.swift:87,128,150,164,178,188, MainView.swift:458,606",
        "push and pop of a detail page: x offset, page below -0.3 width, scrim";
    SectionOut, "Theme.timeSectionToOut", Spec::EaseIn(0.12), 0.0, Repeat::Once,
        ".easeIn(duration: FadeTimes.pageToOut)", "macOS/Style.swift:376, JellyfinKit/FadeTimes.swift:19",
        "sidebar section switch: the old section fades out";
    SectionIn, "Theme.timeSectionFromIn", Spec::EaseOut(0.22), 0.12, Repeat::Once,
        ".easeOut(duration: FadeTimes.pageFromIn).delay(FadeTimes.pageToOut)", "macOS/Style.swift:378, JellyfinKit/FadeTimes.swift:22",
        "sidebar section switch: the new section fades in after the old one left";
    AccountPicker, "Theme.spring", Spec::Response(0.35, 0.9), 0.0, Repeat::Once,
        ".spring(response: 0.35, dampingFraction: 0.9)", "Shared/Transitions.swift:15, macOS/MainView.swift:251, macOS/MacShared.swift:217",
        "the account picker grows out of the badge: scale 0.12 to 1, opacity";
    Sheet, "Motion.sheet", Spec::Response(0.35, 0.86), 0.0, Repeat::Once,
        ".spring(response: 0.35, dampingFraction: 0.86)", "Shared/Motion.swift:22, Shared/LookGiftSheet.swift:401",
        "supporter, gift and look sheets";
    Change, "Motion.change", Spec::Smooth(0.28), 0.0, Repeat::Once,
        ".smooth(duration: 0.28)", "Shared/Motion.swift:28, macOS/MacSubtitleLook.swift:66,173,181,188",
        "look colours, subtitle look, the undo toast";
    Select, "Motion.select", Spec::Smooth(0.25), 0.0, Repeat::Once,
        ".smooth(duration: 0.25)", "Shared/Motion.swift:33, macOS/LibraryView.swift:301, macOS/MacSubtitleLook.swift:271, Shared/AlphabetRail.swift:58",
        "segment selection, alphabet jump scroll";
    Land, "Motion.land", Spec::Response(0.45, 0.86), 0.0, Repeat::Once,
        ".spring(response: 0.45, dampingFraction: 0.86)", "Shared/Motion.swift:39, Shared/LookGiftSheet.swift:184,575",
        "gift icon landing";
    Recolor, "Motion.recolor (CATransition)", Spec::EaseInOut(0.28), 0.0, Repeat::Once,
        "CATransition fade 0.28, .easeInEaseOut", "Shared/Motion.swift:57-60",
        "look switch: cross-fade of the whole window layer";
    Mood, "ImageMood.reveal", Spec::Smooth(0.55), 0.0, Repeat::Once,
        ".smooth(duration: 0.55)", "Shared/ImageMood.swift:24,48",
        "tone behind detail pages";
    ImageColor, "ImageColor", Spec::EaseInOut(0.40), 0.0, Repeat::Once,
        ".easeInOut(duration: 0.40)", "macOS/ImageColor.swift:54",
        "tone behind detail pages (Mac)";
    Default, "SwiftUI .default", Spec::Response(0.55, 1.0), 0.0, Repeat::Once,
        ".default", "macOS/MainView.swift:449, macOS/DetailView.swift:818, macOS/PlayerScreen.swift:1606",
        "bare withAnimation {} (hint dismissal) and the root id change";
    Reduced, "Theme.fadeReduced", Spec::Linear(0.14), 0.0, Repeat::Once,
        ".linear(duration: 0.14)", "macOS/Style.swift:26,99-100",
        "every curve under Reduce Motion";
    Pulse, "placeholder pulse", Spec::EaseInOut(0.9), 0.0, Repeat::Pulse,
        ".easeInOut(duration: 0.9).repeatForever(autoreverses: true)", "macOS/MacComponents.swift:519,674-676, Shared/SignInParts.swift:15",
        "placeholder opacity 0.5 to 1";
    Spinner, "spinner", Spec::Linear(0.7), 0.0, Repeat::Loop,
        ".linear(duration: 0.7).repeatForever(autoreverses: false)", "Shared/Components.swift:124-125",
        "spinner rotation";

    // ---- Player ----
    ControlsIn, "player controls in", Spec::EaseOut(0.18), 0.0, Repeat::Once,
        ".easeOut(duration: 0.18)", "macOS/PlayerScreen.swift:341,361-362,382,410,412,776,1331",
        "scrim, controls, button and skip chrome fade in";
    ControlsOut, "player controls out", Spec::EaseInOut(0.34), 0.0, Repeat::Once,
        ".easeInOut(duration: 0.34)", "macOS/PlayerScreen.swift:341,362,382,410,413,776,1322,1348",
        "scrim, controls, button fade out";
    PlayerLayer, "player layer change", Spec::EaseInOut(0.2), 0.0, Repeat::Once,
        ".easeInOut(duration: 0.2)", "macOS/PlayerScreen.swift:427",
        "a layer (tracks, speed, episodes) opens or closes";
    SkipDisplay, "skip display", Spec::EaseInOut(0.15), 0.0, Repeat::Once,
        ".easeInOut(duration: 0.15)", "macOS/PlayerScreen.swift:1018,1024",
        "the +10 / -10 s indicator";
    Fullscreen, "fullscreen target", Spec::EaseInOut(0.5), 0.0, Repeat::Once,
        ".easeInOut(duration: 0.5)", "macOS/PlayerScreen.swift:191",
        "fullscreen state of the window chrome";
    Curtain, "launch curtain", Spec::EaseOut(0.35), 0.0, Repeat::Once,
        ".easeOut(duration: 0.35)", "macOS/RootView.swift:44",
        "the launch curtain fades out";
    ScreenDistance, "screen distance", Spec::EaseOut(0.3), 0.0, Repeat::Once,
        ".easeOut(duration: 0.3)", "macOS/PlayerScreen.swift:1664",
        "screen-distance flag of the player";
    TrafficLights, "traffic lights", Spec::EaseOut(0.18), 0.0, Repeat::Once,
        "NSAnimationContext 0.18, CAMediaTimingFunction(name: .easeOut)", "macOS/PlayerScreen.swift:2281-2283",
        "window buttons fade with the controls";
    CardAppear, "next-episode card appear", Spec::Interpolating(9.0), 0.0, Repeat::Once,
        ".interpolatingSpring(mass: 1, stiffness: 81, damping: 18)", "macOS/PlayerScreen.swift:1159-1160,1184, JellyfinKit/EpisodesCard.swift:27",
        "card enters: offset 40 pt, scale 0.94";
    CardZoom, "next-episode card zoom", Spec::Interpolating(10.0), 0.0, Repeat::Once,
        ".interpolatingSpring(mass: 1, stiffness: 100, damping: 20)", "macOS/PlayerScreen.swift:1425, JellyfinKit/EpisodesCard.swift:32",
        "card grows to the swap";
    CardDistance, "next-episode card dismiss", Spec::Interpolating(12.0), 0.0, Repeat::Once,
        ".interpolatingSpring(mass: 1, stiffness: 144, damping: 24)", "macOS/PlayerScreen.swift:1186,1496, macOS/EpisodeCardsView.swift:135-137, JellyfinKit/EpisodesCard.swift:30",
        "card leaves, distance spring";
    CardDetailsOut, "card details out", Spec::EaseOut(0.15), 0.0, Repeat::Once,
        ".easeOut(duration: EpisodeCard.detailsOut)", "macOS/EpisodeCardsView.swift:166, JellyfinKit/EpisodesCard.swift:47",
        "card details fade";
    CardImage, "card thumbnail", Spec::EaseInOut(0.4), 0.0, Repeat::Once,
        ".easeInOut(duration: EpisodeCard.imageFade)", "macOS/PlayerScreen.swift:1485-1486, JellyfinKit/EpisodesCard.swift:53",
        "card thumbnail swap";
    VolumeThumb, "volume thumb", Spec::EaseOut(0.12), 0.0, Repeat::Once,
        ".easeOut(duration: 0.12)", "macOS/VolumeSlider.swift:54",
        "volume thumb and track";
    VolumeOpen, "volume open", Spec::EaseOut(0.18), 0.0, Repeat::Once,
        ".easeOut(duration: 0.18)", "macOS/VolumeSlider.swift:64",
        "volume slider expands";

    SheetNative, "AppKit sheet and alert", Spec::EaseInOut(0.2), 0.0, Repeat::Once,
        "NSWindow sheet (system): NSWindowResizeTime 0.2 s, NSAnimation default ease-in-out", "macOS/MacSupport.swift:213, macOS/SettingsView.swift:124, Shared/LookGiftSheet.swift:354",
        "sheets and confirmation dialogs slide down from the top of the window and back up";
    NativeFade, "AppKit menu, popover and help-tag fade", Spec::EaseInOut(0.35), 0.0, Repeat::Once,
        "NSMenu / NSPopover / help tag (system, private); SwiftUI default easeInOut 0.35", "macOS/TileMenuMac.swift:46,107, macOS/PlayerScreen.swift:706, macOS/SeriesView.swift:1013, macOS/MacDownloads.swift:935,1539,1614, macOS/MacComponents.swift:164",
        "native context and pull-down menus fade out after a choice (they open at once); help tags fade in and out";
    SymbolReplace, "play/pause symbol replace", Spec::EaseOut(0.2), 0.0, Repeat::Once,
        "SymbolEffect.replace (system, timing private; 0.2 s easeOut is our estimate)", "macOS/PlayerScreen.swift:1826",
        "play and pause glyphs replace each other";

    // ---- Other one-offs on the Mac ----
    DetailPlan, "detail plan", Spec::EaseOut(0.2), 0.0, Repeat::Once,
        ".easeOut(duration: 0.2)", "macOS/DetailView.swift:618",
        "the load plan row of the detail page";
    SubtitleKeep, "subtitle keep-file style", Spec::EaseInOut(0.10), 0.0, Repeat::Once,
        ".easeInOut(duration: 0.10)", "macOS/MacSubtitleLook.swift:115",
        "subtitle look option dims";
    CopiedIn, "copied in", Spec::EaseOut(0.15), 0.0, Repeat::Once,
        ".easeOut(duration: 0.15)", "Shared/Components.swift:462",
        "copy button confirmation appears";
    CopiedOut, "copied out", Spec::EaseIn(0.25), 0.0, Repeat::Once,
        ".easeIn(duration: 0.25)", "Shared/Components.swift:494",
        "copy button confirmation leaves";
    PressFast, "play button press", Spec::EaseOut(0.15), 0.0, Repeat::Once,
        ".easeOut(duration: 0.15)", "Shared/PlayButton.swift:40, Shared/LookGiftSheet.swift:999",
        "play and gift button press";
    AccountRows, "account switch rows", Spec::Response(0.55, 0.82), 0.0, Repeat::Once,
        ".spring(response: 0.55, dampingFraction: 0.82).delay(lag)", "Shared/AccountTransition.swift:311,341",
        "rows of the account switch, staggered by lag (0.08 s per row)";
    AccountRowsOut, "account switch rows out", Spec::EaseOut(0.12), 0.0, Repeat::Once,
        ".easeOut(duration: 0.12)", "Shared/AccountTransition.swift:312,315",
        "rows leave";
    AccountRailsFade, "account switch rails fade", Spec::Linear(0.22), 0.0, Repeat::Once,
        ".linear(duration: AccountSwitchCurve.railsFade).delay(lag)", "Shared/AccountTransition.swift:315, JellyfinKit/AccountSwitchCurve.swift:117",
        "rails fade during the account switch";
    AccountLift, "account lift", Spec::Linear(0.2), 0.08, Repeat::Once,
        ".linear(duration: 0.2).delay(0.08)", "Shared/AccountTransition.swift:84",
        "profile rows lift";
    SupportPop, "support pop", Spec::Response(0.38, 0.62), 0.0, Repeat::Once,
        ".spring(response: 0.38, dampingFraction: 0.62)", "Shared/SupportGrowSheet.swift:276,356",
        "supporter heart pops in";
    SupportRing, "support ring", Spec::EaseOut(0.6), 0.0, Repeat::Once,
        ".easeOut(duration: 0.6)", "Shared/LookGiftSheet.swift:582",
        "gift ring";
    SupportBreath, "support breath", Spec::EaseInOut(0.8), 0.0, Repeat::Pulse,
        ".easeInOut(duration: 0.8).repeatForever(autoreverses: true)", "Shared/SupportGrowSheet.swift:396",
        "supporter sheet dimming";
    SupportHug, "support hug", Spec::EaseInOut(1.7), 0.0, Repeat::Pulse,
        ".easeInOut(duration: 1.7).repeatForever(autoreverses: true)", "Shared/SupportGrowSheet.swift:665",
        "supporter sheet hug";
    SupportBob, "support bob", Spec::EaseInOut(1.6), 0.0, Repeat::Pulse,
        ".easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(delay)", "Shared/SupportProfileParts.swift:121",
        "supporter profile icon bob";

    // ---- tvOS (the Android TV look of the Rust UI follows the Apple TV app, not the Mac) ----
    TvFocus, "tvOS focus", Spec::EaseOut(0.14), 0.0, Repeat::Once,
        ".easeOut(duration: TVSpec.focusDuration)", "tvOS/Style.swift:441-443, tvOS/TVSpec.swift:157",
        "focus scale 1.06, lift shadow and fill on Android TV";
    TvFocusReduced, "tvOS focus reduced", Spec::Linear(0.1), 0.0, Repeat::Once,
        ".linear(duration: TVSpec.reducedDuration)", "tvOS/Style.swift:441-443, tvOS/TVSpec.swift:163",
        "focus change under Reduce Motion on Android TV";

    // ---- Rust-only motion with no Mac counterpart (kept apart so the test knows them) ----
    TouchSettle, "touch page settle", Spec::SettlingIn(0.35), 0.0, Repeat::Once,
        "(none: iPhone UINavigationController feel, Android back swipe)", "n/a",
        "Android push, pop and released back swipe";
}

/// How well a catalogued curve is known.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Basis {
    /// Written in the Mac source (the SwiftUI text and file:line of the row).
    MacSource,
    /// A system behaviour with a published or community-measured number (the row says which).
    Documented,
    /// A system behaviour whose timing is private: our value is the SwiftUI default that fits (marked "estimated").
    Estimated,
    /// Not from the Mac.
    Rust,
}

impl Id {
    /// How well this curve is known.
    pub fn basis(self) -> Basis {
        match self {
            Id::SheetNative => Basis::Documented,
            Id::NativeFade | Id::SymbolReplace => Basis::Estimated,
            Id::TouchSettle => Basis::Rust,
            _ => Basis::MacSource,
        }
    }

    /// The table row of this id.
    pub fn entry(self) -> &'static Entry {
        &ALL[self as usize]
    }

    /// The curve of this id including its delay.
    pub fn curve(self) -> Curve {
        self.entry().curve()
    }
}

/// The id whose curve equals `curve` (parameters compared to 1e-9), or `None` when the curve is not in the catalogue.
/// A curve that is the same as several entries gives the first.
pub fn find(curve: &Curve) -> Option<Id> {
    ALL.iter().find(|e| same_entry(e, curve)).map(|e| e.id)
}

/// Curves whose Swift text ends in `.delay(lag)` with a lag chosen at the call site (the staggered rows of the account
/// switch): any non-negative delay is the same catalogue curve.
fn lagged(id: Id) -> bool {
    matches!(id, Id::AccountRows | Id::AccountRailsFade)
}

fn same_entry(e: &Entry, curve: &Curve) -> bool {
    let table = e.curve();
    if lagged(e.id) {
        let mut undelayed = *curve;
        undelayed.delay = table.delay;
        return curve.delay >= 0.0 && same(&table, &undelayed);
    }
    same(&table, curve)
}

/// Whether `curve` is one of the catalogued curves.
pub fn contains(curve: &Curve) -> bool {
    find(curve).is_some()
}

fn near(a: f64, b: f64) -> bool {
    (a - b).abs() <= 1e-9 * (1.0 + a.abs().max(b.abs()))
}

fn same(a: &Curve, b: &Curve) -> bool {
    use crate::curve::Kind;
    if !near(a.delay, b.delay) {
        return false;
    }
    match (a.kind, b.kind) {
        (
            Kind::Tween {
                ease: e1,
                seconds: s1,
            },
            Kind::Tween {
                ease: e2,
                seconds: s2,
            },
        ) => e1 == e2 && near(s1, s2),
        (Kind::Spring(x), Kind::Spring(y)) => {
            near(x.mass, y.mass) && near(x.stiffness, y.stiffness) && near(x.damping, y.damping)
        }
        _ => false,
    }
}

thread_local! {
    /// Curves the UI engine ran on this thread that are not in the catalogue (see [`record`]).
    static OFF_CATALOGUE: std::cell::RefCell<Vec<String>> = const { std::cell::RefCell::new(Vec::new()) };
    /// Whether [`record`] panics on an off-catalogue curve (set by the test harnesses of the screens).
    static STRICT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// The catalogued curves the engine started on this thread (see [`used`]).
    static USED: std::cell::RefCell<Vec<Id>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// Notes a curve the engine is about to run. An off-catalogue curve is remembered by its `Debug` text (list them with
/// [`off_catalogue`]) and, in strict mode ([`set_strict`]), panics so a test fails at the screen that used it.
/// Catalogued curves cost one table scan. The state is per thread, so parallel tests do not see each other.
pub fn record(curve: &Curve) {
    let ids: Vec<Id> = ALL
        .iter()
        .filter(|e| same_entry(e, curve))
        .map(|e| e.id)
        .collect();
    if !ids.is_empty() {
        USED.with(|u| {
            let mut u = u.borrow_mut();
            for id in ids {
                if !u.contains(&id) {
                    u.push(id);
                }
            }
        });
        return;
    }
    let text = format!("{curve:?}");
    OFF_CATALOGUE.with(|v| {
        let mut v = v.borrow_mut();
        if !v.contains(&text) {
            v.push(text.clone());
        }
    });
    assert!(
        !STRICT.with(std::cell::Cell::get),
        "animation curve not in the catalogue: {text}"
    );
}

/// Makes [`record`] panic on an off-catalogue curve on this thread (screens' tests turn this on).
pub fn set_strict(on: bool) {
    STRICT.with(|s| s.set(on));
}

/// The off-catalogue curves recorded on this thread (empty when every animation came from the table).
pub fn off_catalogue() -> Vec<String> {
    OFF_CATALOGUE.with(|v| v.borrow().clone())
}

/// The catalogued curves started on this thread since [`clear_off_catalogue`], first use first. Rows with the same numbers
/// (`Float`, `PressRelease`, `VolumeThumb`) all count as used when one of them runs.
pub fn used() -> Vec<Id> {
    USED.with(|u| u.borrow().clone())
}

/// Forgets the recorded off-catalogue curves (and the used list) of this thread.
pub fn clear_off_catalogue() {
    OFF_CATALOGUE.with(|v| v.borrow_mut().clear());
    USED.with(|u| u.borrow_mut().clear());
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A number after `key` in `text`, e.g. `num("duration: ", ".snappy(duration: 0.22)") == Some(0.22)`; `None` when the
    /// value there is a name (`FadeTimes.arrows`).
    fn num(key: &str, text: &str) -> Option<f64> {
        let at = text.find(key)? + key.len();
        let rest = &text[at..];
        let end = rest
            .find(|c: char| !(c.is_ascii_digit() || c == '.'))
            .unwrap_or(rest.len());
        rest[..end].parse().ok()
    }

    /// The curve the Swift expression means, derived here from the documented SwiftUI numbers (an independent path from
    /// [`Spec::curve`]): returns `(ease control points or spring (k, c), seconds, delay)`.
    enum Meaning {
        Bezier((f64, f64, f64, f64), Option<f64>),
        Spring { k: f64, c: f64 },
    }

    fn meaning(text: &str) -> Option<Meaning> {
        let pi2 = std::f64::consts::TAU;
        let tween = |name: &str, pts| {
            text.contains(name)
                .then(|| Meaning::Bezier(pts, num("duration: ", text)))
        };
        let preset = |name: &str, bounce: f64| {
            text.contains(name).then(|| {
                let d = num("duration: ", text).unwrap_or(f64::NAN);
                Meaning::Spring {
                    k: (pi2 / d).powi(2),
                    c: 2.0 * pi2 / d * (1.0 - bounce),
                }
            })
        };
        tween(".easeInOut(", (0.42, 0.0, 0.58, 1.0))
            .or_else(|| tween(".easeIn(", (0.42, 0.0, 1.0, 1.0)))
            .or_else(|| tween(".easeOut(", (0.0, 0.0, 0.58, 1.0)))
            .or_else(|| tween(".linear(", (0.0, 0.0, 1.0, 1.0)))
            .or_else(|| preset(".smooth(", 0.0))
            .or_else(|| preset(".snappy(", 0.15))
            .or_else(|| preset(".bouncy(", 0.3))
            .or_else(|| {
                text.contains(".spring(response:").then(|| {
                    let (r, z) = (
                        num("response: ", text).unwrap_or(f64::NAN),
                        num("dampingFraction: ", text).unwrap_or(f64::NAN),
                    );
                    Meaning::Spring {
                        k: (pi2 / r).powi(2),
                        c: 2.0 * pi2 / r * z,
                    }
                })
            })
            .or_else(|| {
                text.contains(".interpolatingSpring(")
                    .then(|| Meaning::Spring {
                        k: num("stiffness: ", text).unwrap_or(f64::NAN),
                        c: num("damping: ", text).unwrap_or(f64::NAN),
                    })
            })
            .or_else(|| {
                text.contains(".default").then(|| {
                    let r = 0.55;
                    Meaning::Spring {
                        k: (pi2 / r).powi(2),
                        c: 2.0 * pi2 / r,
                    }
                })
            })
    }

    #[test]
    fn ids_index_the_table() {
        for (i, e) in ALL.iter().enumerate() {
            assert_eq!(e.id as usize, i, "{} out of order", e.name);
        }
        assert!(ALL.len() >= 50, "{}", ALL.len());
    }

    #[test]
    fn every_entry_has_a_source_and_a_distinct_name() {
        let mut names = std::collections::HashSet::new();
        for e in ALL {
            assert!(
                !e.mac.is_empty() && !e.swift.is_empty() && !e.moves.is_empty(),
                "{}",
                e.name
            );
            assert!(names.insert(e.name), "duplicate {}", e.name);
            if e.mac != "n/a" {
                assert!(e.mac.contains(".swift:"), "{}: {}", e.name, e.mac);
            }
        }
    }

    #[test]
    fn each_curve_equals_what_its_swift_text_means() {
        for e in ALL {
            let Some(m) = meaning(e.swift) else {
                assert!(
                    e.swift.starts_with("CATransition")
                        || e.swift.starts_with("NSWindow sheet")
                        || e.swift.starts_with("NSMenu")
                        || e.swift.starts_with("NSAnimationContext")
                        || e.swift.starts_with("SymbolEffect")
                        || e.swift.starts_with("(none"),
                    "unparsed Swift text for {}: {}",
                    e.name,
                    e.swift
                );
                continue;
            };
            let c = e.spec.curve();
            match (m, c.kind) {
                (Meaning::Bezier(pts, d), crate::curve::Kind::Tween { ease, seconds }) => {
                    assert_eq!(ease.points(), pts, "{}", e.name);
                    if let Some(d) = d {
                        assert!((seconds - d).abs() < 1e-12, "{}: {seconds} vs {d}", e.name);
                    }
                }
                (Meaning::Spring { k, c: damp }, crate::curve::Kind::Spring(s)) => {
                    assert!(
                        k.is_finite() && damp.is_finite(),
                        "{}: unreadable numbers in {}",
                        e.name,
                        e.swift
                    );
                    assert!(
                        (s.stiffness - k).abs() < 1e-6 * k,
                        "{}: k {} vs {k}",
                        e.name,
                        s.stiffness
                    );
                    assert!(
                        (s.damping - damp).abs() < 1e-6 * damp,
                        "{}: c {} vs {damp}",
                        e.name,
                        s.damping
                    );
                    assert_eq!(s.mass, 1.0);
                }
                _ => panic!(
                    "{}: the Swift text and the spec disagree on spring vs tween",
                    e.name
                ),
            }
            if let Some(at) = e.swift.find(".delay(") {
                let n: f64 = e.swift[at + 7..]
                    .chars()
                    .take_while(|c| c.is_ascii_digit() || *c == '.')
                    .collect::<String>()
                    .parse()
                    .unwrap_or(e.delay);
                assert!((n - e.delay).abs() < 1e-12, "{}", e.name);
            }
        }
    }

    #[test]
    fn named_spring_parameters_are_the_documented_ones() {
        // .snappy(duration: 0.22): response 0.22, zeta 0.85 -> k 815.7, c 48.55 (D section 2.2)
        let Some(s) = Id::Leap.curve().as_spring() else {
            panic!("spring")
        };
        assert!((s.stiffness - 815.7).abs() < 0.1 && (s.damping - 48.55).abs() < 0.05);
        // .spring(response 0.35, damping 0.86): k 322.3, c 30.88
        let Some(s) = Id::Sheet.curve().as_spring() else {
            panic!("spring")
        };
        assert!((s.stiffness - 322.3).abs() < 0.1 && (s.damping - 30.88).abs() < 0.05);
        // .default: response 0.55 damping 1: k 130.5 c 22.85
        let Some(s) = Id::Default.curve().as_spring() else {
            panic!("spring")
        };
        assert!((s.stiffness - 130.5).abs() < 0.1 && (s.damping - 22.85).abs() < 0.05);
        // the card springs: stiffness w^2, damping 2w
        for (id, w) in [
            (Id::CardAppear, 9.0),
            (Id::CardZoom, 10.0),
            (Id::CardDistance, 12.0),
        ] {
            let Some(s) = id.curve().as_spring() else {
                panic!("spring")
            };
            assert_eq!((s.stiffness, s.damping, s.mass), (w * w, 2.0 * w, 1.0));
        }
    }

    #[test]
    fn find_and_record_know_the_table() {
        assert_eq!(find(&Id::Leap.curve()), Some(Id::Leap));
        assert!(contains(&Curve::tween(Ease::InOut, 0.45)));
        assert!(!contains(&Curve::tween(Ease::InOut, 0.451)));
        assert!(!contains(&Curve::tween(Ease::Linear, 0.9)));
        record(&Curve::tween(Ease::Out, 0.12));
        assert!(!off_catalogue().iter().any(|t| t.contains("0.12")));
        record(&Curve::tween(Ease::Linear, 0.777));
        assert!(off_catalogue().iter().any(|t| t.contains("0.777")));
    }
}
