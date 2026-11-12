//! Plain value types used by the generated tokens.

use core::fmt;

/// The three layout sets of the design: input device and viewing distance decide, not the operating system.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LayoutSet {
    /// Finger on a phone or tablet (Swiftly iOS values, `JerkKind` group in the design file).
    Touch,
    /// Pointer and keyboard in a window (Swiftly macOS values, `BodyShell` group).
    Desktop,
    /// Remote control at about 3 m (Swiftly tvOS values, `PressButton` group).
    Tv,
}

impl LayoutSet {
    /// All sets in a fixed order.
    pub const ALL: [LayoutSet; 3] = [LayoutSet::Touch, LayoutSet::Desktop, LayoutSet::Tv];

    /// Lower-case name, the same as the module name in `tokens`.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            LayoutSet::Touch => "touch",
            LayoutSet::Desktop => "desktop",
            LayoutSet::Tv => "tv",
        }
    }
}

impl fmt::Display for LayoutSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// A colour in the sRGB space, straight (not premultiplied) alpha.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Colour {
    /// Red, 0.0 to 1.0.
    pub r: f32,
    /// Green, 0.0 to 1.0.
    pub g: f32,
    /// Blue, 0.0 to 1.0.
    pub b: f32,
    /// Alpha, 0.0 to 1.0.
    pub a: f32,
    /// The same colour as `0xRRGGBBAA`, each channel rounded to 8 bit.
    pub rgba8: u32,
}

impl Colour {
    /// The four channels as `[r, g, b, a]`.
    #[must_use]
    pub const fn rgba(self) -> [f32; 4] {
        [self.r, self.g, self.b, self.a]
    }

    /// The same colour with another alpha (channels rounded to 8 bit like the generated values).
    #[must_use]
    pub fn with_alpha(self, a: f32) -> Colour {
        let a = a.clamp(0.0, 1.0);
        let a8 = (a * 255.0).round() as u32;
        Colour {
            a,
            rgba8: (self.rgba8 & 0xFFFF_FF00) | a8,
            ..self
        }
    }
}

/// One step of the type ladder.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextStyle {
    /// Font size in points.
    pub size: f32,
    /// CSS-style weight, 400 regular to 800 extra bold.
    pub weight: u16,
    /// Letter spacing in points; 0.0 when the kit gives none.
    pub tracking: f32,
    /// Set in capitals.
    pub uppercase: bool,
}

/// A drop shadow. Colour carries its own alpha.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Shadow {
    /// Shadow colour including alpha.
    pub colour: Colour,
    /// Blur radius in points.
    pub blur: f32,
    /// Vertical offset in points.
    pub y: f32,
    /// Colour alpha, blur and offset are the given values multiplied by how far the element rests (0.0 to 1.0).
    pub scales_with_rest: bool,
}

/// An animation curve with its duration in seconds (or the spring parameters).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Curve {
    /// Constant speed.
    Linear(f32),
    /// Fast start, slow end.
    EaseOut(f32),
    /// Slow start, fast end.
    EaseIn(f32),
    /// Slow start and end.
    EaseInOut(f32),
    /// SwiftUI `.smooth`.
    Smooth(f32),
    /// SwiftUI `.snappy`.
    Snappy(f32),
    /// Spring with response (seconds) and damping fraction.
    Spring {
        /// Time of one period in seconds.
        response: f32,
        /// Damping fraction, 1.0 is critically damped.
        damping: f32,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn with_alpha_rounds_like_the_generator() {
        let white = Colour {
            r: 1.0,
            g: 1.0,
            b: 1.0,
            a: 1.0,
            rgba8: 0xFFFF_FFFF,
        };
        assert_eq!(white.with_alpha(0.5).rgba8, 0xFFFF_FF80);
        assert_eq!(white.with_alpha(2.0).rgba8, 0xFFFF_FFFF);
    }

    #[test]
    fn layout_set_names() {
        let names: Vec<&str> = LayoutSet::ALL.iter().map(|s| s.name()).collect();
        assert_eq!(names, ["touch", "desktop", "tv"]);
    }
}
