//! The environment a view reads: window size, safe insets, scale, idiom, size classes, input mode, reduce motion.

use swiftly_layout::Size;

/// Space taken by system bars and cutouts.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Insets {
    /// Top.
    pub top: f32,
    /// Leading.
    pub leading: f32,
    /// Bottom.
    pub bottom: f32,
    /// Trailing.
    pub trailing: f32,
}

/// The kind of device.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Idiom {
    /// Phone.
    Phone,
    /// Tablet.
    Pad,
    /// Television.
    Tv,
    /// Desktop window.
    Desktop,
}

/// A coarse size class (SwiftUI `UserInterfaceSizeClass`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SizeClass {
    /// Narrow or short.
    Compact,
    /// Wide or tall.
    Regular,
}

/// How the user points at things.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputMode {
    /// Fingers.
    Touch,
    /// Mouse or trackpad and keyboard.
    Pointer,
    /// D-pad remote.
    Remote,
}

/// Everything a view may depend on besides its data. When it changes, the view runs again.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Env {
    /// Window size in points.
    pub size: Size,
    /// Safe-area insets.
    pub safe: Insets,
    /// Pixels per point.
    pub scale: f32,
    /// Device kind.
    pub idiom: Idiom,
    /// Horizontal size class.
    pub h_class: SizeClass,
    /// Vertical size class.
    pub v_class: SizeClass,
    /// Input mode.
    pub input: InputMode,
    /// Reduce Motion is on: every curve becomes linear 0.14 s.
    pub reduce_motion: bool,
}

/// Size classes by RF section 6: a phone is horizontally regular from 900 pt (only Plus/Max landscape, ~930; a plain iPhone landscape is ~852 and compact; the research text says "~700", which contradicts its own table) and
/// vertically compact below about 500 pt; a pad is horizontally compact below 0.4 of the screen width (a third split or
/// Slide Over). All thresholds are estimated and meant to be fitted against the real app.
pub fn classes(size: Size, idiom: Idiom, screen_w: f32) -> (SizeClass, SizeClass) {
    use SizeClass::{Compact, Regular};
    match idiom {
        Idiom::Phone => (
            if size.w >= 900.0 { Regular } else { Compact },
            if size.h < 500.0 { Compact } else { Regular },
        ),
        Idiom::Pad => (
            if size.w < 0.4 * screen_w {
                Compact
            } else {
                Regular
            },
            Regular,
        ),
        Idiom::Tv | Idiom::Desktop => (Regular, Regular),
    }
}

impl Env {
    /// An environment with classes derived from the size.
    pub fn new(size: Size, scale: f32, idiom: Idiom) -> Env {
        let (h_class, v_class) = classes(size, idiom, size.w);
        Env {
            size,
            safe: Insets::default(),
            scale,
            idiom,
            h_class,
            v_class,
            input: match idiom {
                Idiom::Phone | Idiom::Pad => InputMode::Touch,
                Idiom::Tv => InputMode::Remote,
                Idiom::Desktop => InputMode::Pointer,
            },
            reduce_motion: false,
        }
    }

    /// A phone window (portrait `390 x 844` is an iPhone 15).
    pub fn phone(w: f32, h: f32, scale: f32) -> Env {
        Env::new(Size::new(w, h), scale, Idiom::Phone)
    }
}
