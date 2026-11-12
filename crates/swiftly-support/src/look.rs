//! Looks: a thank-you for supporters, a few colours and nothing more
//! (`Packages/JellyfinKit/Sources/JellyfinKit/Look.swift`). The data lives here so every
//! platform reads the same values; each turns them into its own colour type.

use serde::{Deserialize, Serialize};

use crate::season::LookSeason;

/// One sRGB colour as `0xRRGGBB` (`LookColor`, `Look.swift:15-27`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct LookColor {
    /// `0xRRGGBB`.
    pub hex: u32,
}

impl LookColor {
    /// A colour; the top byte is dropped.
    pub const fn new(hex: u32) -> Self {
        Self {
            hex: hex & 0xFF_FFFF,
        }
    }
    /// Red, 0 to 1.
    pub fn red(self) -> f64 {
        f64::from((self.hex >> 16) & 0xFF) / 255.0
    }
    /// Green, 0 to 1.
    pub fn green(self) -> f64 {
        f64::from((self.hex >> 8) & 0xFF) / 255.0
    }
    /// Blue, 0 to 1.
    pub fn blue(self) -> f64 {
        f64::from(self.hex & 0xFF) / 255.0
    }
    /// `#RRGGBB`, for logs and platforms that take CSS colours.
    pub fn css(self) -> String {
        format!("#{:06X}", self.hex)
    }
}

const fn c(hex: u32) -> LookColor {
    LookColor::new(hex)
}

/// An accent and the three tones that go with it (`LookAccent`, `Look.swift:34-93`). The tones
/// are written out, not computed. `id` is stored in the selection; never rename one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LookAccent {
    /// Stored id.
    pub id: &'static str,
    /// Selection, progress, symbols.
    pub main: LookColor,
    /// The focused switch on TV.
    pub light: LookColor,
    /// The surface under accent text.
    pub quiet: LookColor,
    /// Text and glyphs on an accent surface.
    pub on: LookColor,
    /// The warning colour under this accent; `None` keeps the app's `#E8833A`. Only an accent
    /// that is itself orange sets one.
    pub warning: Option<LookColor>,
}

const AMBER: LookColor = c(0xF2C14E);

impl LookAccent {
    /// Today's turquoise, unchanged.
    pub const TEAL: LookAccent = LookAccent {
        id: "teal",
        main: c(0x50D5DA),
        light: c(0x7AE6EA),
        quiet: c(0x113435),
        on: c(0x061212),
        warning: None,
    };
    /// Violet.
    pub const VIOLET: LookAccent = LookAccent {
        id: "violet",
        main: c(0xB08CFF),
        light: c(0xC7AEFF),
        quiet: c(0x2B2240),
        on: c(0x0B0716),
        warning: None,
    };
    /// Coral.
    pub const CORAL: LookAccent = LookAccent {
        id: "coral",
        main: c(0xFF8C6B),
        light: c(0xFFAE95),
        quiet: c(0x3F2219),
        on: c(0x1A0905),
        warning: None,
    };
    /// Gold.
    pub const GOLD: LookAccent = LookAccent {
        id: "gold",
        main: c(0xEEC377),
        light: c(0xF5D8A0),
        quiet: c(0x3A301D),
        on: c(0x1A1205),
        warning: None,
    };
    /// Emerald.
    pub const EMERALD: LookAccent = LookAccent {
        id: "emerald",
        main: c(0x3EDCA6),
        light: c(0x72E8C0),
        quiet: c(0x0F3628),
        on: c(0x03140D),
        warning: None,
    };
    /// Halloween's pumpkin orange; its warning turns amber.
    pub const PUMPKIN: LookAccent = LookAccent {
        id: "pumpkin",
        main: c(0xFF8A2B),
        light: c(0xFFAA66),
        quiet: c(0x3D2410),
        on: c(0x1A0C02),
        warning: Some(AMBER),
    };
    /// Aurora's cyan.
    pub const AURORA: LookAccent = LookAccent {
        id: "aurora",
        main: c(0x5AD3E8),
        light: c(0x8AE3F1),
        quiet: c(0x0F2E35),
        on: c(0x04141A),
        warning: None,
    };
    /// Ice's pale blue.
    pub const ICE: LookAccent = LookAccent {
        id: "ice",
        main: c(0xA9DCFF),
        light: c(0xCBEBFF),
        quiet: c(0x1A2B3A),
        on: c(0x06121C),
        warning: None,
    };
    /// Ember's red-orange; its warning turns amber.
    pub const EMBER: LookAccent = LookAccent {
        id: "ember",
        main: c(0xFF4D4F),
        light: c(0xFF8082),
        quiet: c(0x3F1416),
        on: c(0x1A0404),
        warning: Some(AMBER),
    };
    /// Sunset's pink.
    pub const ROSE: LookAccent = LookAccent {
        id: "rose",
        main: c(0xFF7DB0),
        light: c(0xFFA5C9),
        quiet: c(0x40192E),
        on: c(0x1A0612),
        warning: None,
    };

    /// The dots under "Accent", in picker order. Only these are a user choice.
    pub const ALL: [LookAccent; 5] = [
        Self::VIOLET,
        Self::TEAL,
        Self::CORAL,
        Self::GOLD,
        Self::EMERALD,
    ];

    /// The accent with an id, including the ones that belong to a look (`Look.swift:96-98`).
    pub fn with_id(id: &str) -> Option<LookAccent> {
        [
            Self::VIOLET,
            Self::TEAL,
            Self::CORAL,
            Self::GOLD,
            Self::EMERALD,
            Self::PUMPKIN,
            Self::AURORA,
            Self::ICE,
            Self::EMBER,
            Self::ROSE,
        ]
        .into_iter()
        .find(|a| a.id == id)
    }

    /// The German name of the dot, for VoiceOver (`LookAccentDots.swift:43-51`); every accent
    /// that is not one of the four named ones reads "Türkis", as in Swift.
    pub fn name_key(&self) -> &'static str {
        match self.id {
            "violet" => "Violett",
            "coral" => "Koralle",
            "gold" => "Gold",
            "emerald" => "Smaragd",
            _ => "Türkis",
        }
    }
}

/// How strong the glow at the top of the home page is. The raw values are stored.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LookGlow {
    /// No glow.
    Off,
    /// 20 percent at its centre.
    Soft,
    /// 32 percent at its centre.
    Bright,
}

impl LookGlow {
    /// Opacity of the one tone at its centre.
    pub fn opacity(self) -> f64 {
        match self {
            Self::Off => 0.0,
            Self::Soft => 0.20,
            Self::Bright => 0.32,
        }
    }
}

/// A look: everything it changes, in one value (`Look`, `Look.swift:106-240`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Look {
    /// Stored id; never rename one.
    pub id: &'static str,
    /// The German name, also the catalogue key.
    pub name_key: &'static str,
    /// The accent.
    pub accent: LookAccent,
    /// The one tone of the home glow.
    pub glow_color: LookColor,
    /// What the glow starts at when the look is chosen.
    pub default_glow: LookGlow,
    /// The page background.
    pub background: LookColor,
    /// The play mark, top left to bottom right. One colour is a flat fill.
    pub logo_gradient: &'static [LookColor],
    /// The alternate app icon in the bundle; `None` is the regular icon.
    pub icon_name: Option<&'static str>,
    /// A gift: free for everyone who picks it up, kept for good.
    pub is_gift: bool,
    /// The days of the year the look is offered; `None`: always.
    pub availability: Option<LookSeason>,
}

const GROUND: LookColor = c(0x101010);

impl Look {
    /// The second tone of the glow: the last colour of a gradient mark, `None` for a flat one.
    pub fn glow_tint(&self) -> Option<LookColor> {
        if self.logo_gradient.len() > 1 {
            self.logo_gradient.last().copied()
        } else {
            None
        }
    }

    /// The app as it is today.
    pub const ORIGINAL: Look = Look {
        id: "original",
        name_key: "Original",
        accent: LookAccent::TEAL,
        glow_color: c(0x50D5DA),
        default_glow: LookGlow::Off,
        background: GROUND,
        logo_gradient: &[c(0x50D5DA)],
        icon_name: None,
        is_gift: false,
        availability: None,
    };
    /// Violet on the same dark ground.
    pub const NEON_NIGHT: Look = Look {
        id: "neonNight",
        name_key: "Neon-Nacht",
        accent: LookAccent::VIOLET,
        glow_color: c(0x8B5CF6),
        default_glow: LookGlow::Soft,
        background: GROUND,
        logo_gradient: &[c(0x5B7CFF), c(0xC24BFF)],
        icon_name: Some("AppIcon-NeonNight"),
        is_gift: false,
        availability: None,
    };
    /// Halloween, a gift for everyone (24 Oct to 2 Nov).
    pub const HALLOWEEN: Look = Look {
        id: "halloween",
        name_key: "Halloween",
        accent: LookAccent::PUMPKIN,
        glow_color: c(0xFF8A2B),
        default_glow: LookGlow::Soft,
        background: GROUND,
        logo_gradient: &[c(0xFF8A2B)],
        icon_name: Some("AppIcon-Halloween"),
        is_gift: true,
        availability: Some(LookSeason::HALLOWEEN),
    };
    /// Sunset.
    pub const SUNSET: Look = Look {
        id: "sunset",
        name_key: "Sunset",
        accent: LookAccent::ROSE,
        glow_color: c(0xFF5A9E),
        default_glow: LookGlow::Soft,
        background: GROUND,
        logo_gradient: &[c(0xFFCB57), c(0xFF6E7F), c(0xB83FD0)],
        icon_name: Some("AppIcon-LookSunset"),
        is_gift: false,
        availability: None,
    };
    /// Aurora.
    pub const AURORA: Look = Look {
        id: "aurora",
        name_key: "Aurora",
        accent: LookAccent::AURORA,
        glow_color: c(0x3F7BFF),
        default_glow: LookGlow::Soft,
        background: GROUND,
        logo_gradient: &[c(0x46DCD8), c(0x3F7BFF), c(0x9B5CFF)],
        icon_name: Some("AppIcon-LookAurora"),
        is_gift: false,
        availability: None,
    };
    /// Ice.
    pub const ICE: Look = Look {
        id: "ice",
        name_key: "Eis",
        accent: LookAccent::ICE,
        glow_color: c(0x6FB6FF),
        default_glow: LookGlow::Soft,
        background: GROUND,
        logo_gradient: &[c(0xF2FAFF), c(0x6FB6FF)],
        icon_name: Some("AppIcon-LookIce"),
        is_gift: false,
        availability: None,
    };
    /// Ember.
    pub const EMBER: Look = Look {
        id: "ember",
        name_key: "Glut",
        accent: LookAccent::EMBER,
        glow_color: c(0xF02F45),
        default_glow: LookGlow::Soft,
        background: GROUND,
        logo_gradient: &[c(0xFFB13B), c(0xB3122B)],
        icon_name: Some("AppIcon-LookEmber"),
        is_gift: false,
        availability: None,
    };
    /// Gold.
    pub const GOLD: Look = Look {
        id: "gold",
        name_key: "Gold",
        accent: LookAccent::GOLD,
        glow_color: c(0xE0B050),
        default_glow: LookGlow::Soft,
        background: GROUND,
        logo_gradient: &[c(0xFFF0C2), c(0xF1CB76), c(0xD19B3C), c(0x9C6B1E)],
        icon_name: Some("AppIcon-LookGold"),
        is_gift: false,
        availability: None,
    };
    /// Emerald.
    pub const EMERALD: Look = Look {
        id: "emerald",
        name_key: "Smaragd",
        accent: LookAccent::EMERALD,
        glow_color: c(0x19C58F),
        default_glow: LookGlow::Soft,
        background: GROUND,
        logo_gradient: &[c(0x5BE6C9), c(0x0E9E6E)],
        icon_name: Some("AppIcon-LookEmerald"),
        is_gift: false,
        availability: None,
    };

    /// In the order of the looks sheet.
    pub const ALL: [Look; 9] = [
        Self::ORIGINAL,
        Self::HALLOWEEN,
        Self::NEON_NIGHT,
        Self::SUNSET,
        Self::AURORA,
        Self::ICE,
        Self::EMBER,
        Self::GOLD,
        Self::EMERALD,
    ];

    /// The looks everyone may use: the original and the gifts.
    pub fn free() -> Vec<Look> {
        Self::ALL
            .into_iter()
            .filter(|l| *l == Self::ORIGINAL || l.is_gift)
            .collect()
    }

    /// An unknown id (a look removed in a later version) is the original.
    pub fn with_id(id: &str) -> Look {
        Self::ALL
            .into_iter()
            .find(|l| l.id == id)
            .unwrap_or(Self::ORIGINAL)
    }
}

/// What the person picked: a look, and what they changed on it (`LookSelection`,
/// `Look.swift:242-285`). Stored by id; `None` overrides mean "as the look has it". The JSON
/// keys are `look`, `accent`, `glow`, `icon`, written in sorted order like Swift's
/// `.sortedKeys`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct LookSelection {
    /// An override of the accent.
    #[serde(rename = "accent", default, skip_serializing_if = "Option::is_none")]
    pub accent_id: Option<String>,
    /// An override of the glow.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub glow: Option<LookGlow>,
    /// `Some(false)` keeps the regular icon.
    #[serde(rename = "icon", default, skip_serializing_if = "Option::is_none")]
    pub uses_look_icon: Option<bool>,
    /// The look id.
    #[serde(rename = "look")]
    pub look_id: String,
}

impl Default for LookSelection {
    fn default() -> Self {
        Self::original()
    }
}

impl LookSelection {
    /// The look with this id and no overrides.
    pub fn of(look_id: &str) -> Self {
        Self {
            accent_id: None,
            glow: None,
            uses_look_icon: None,
            look_id: look_id.to_owned(),
        }
    }

    /// The original.
    pub fn original() -> Self {
        Self::of(Look::ORIGINAL.id)
    }

    /// The look this selection names.
    pub fn look(&self) -> Look {
        Look::with_id(&self.look_id)
    }

    /// The selection with all overrides applied.
    pub fn palette(&self) -> LookPalette {
        let look = self.look();
        let accent = self
            .accent_id
            .as_deref()
            .and_then(LookAccent::with_id)
            .unwrap_or(look.accent);
        let glow = self.glow.unwrap_or(look.default_glow);
        let icon_name = if self.uses_look_icon == Some(false) {
            None
        } else {
            look.icon_name
        };
        LookPalette {
            look,
            accent,
            glow,
            icon_name,
        }
    }

    /// A different look starts clean: the overrides belonged to the old one.
    pub fn switching(&self, look: &Look) -> Self {
        Self::of(look.id)
    }

    /// Reads a stored selection; anything unreadable is the original.
    pub fn decoded(data: Option<&[u8]>) -> Self {
        data.and_then(|d| serde_json::from_slice(d).ok())
            .unwrap_or_else(Self::original)
    }

    /// The stored JSON.
    pub fn encoded(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }
}

/// The finished values one screen draws with (`LookPalette`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LookPalette {
    /// The look.
    pub look: Look,
    /// The accent after overrides.
    pub accent: LookAccent,
    /// The glow after overrides.
    pub glow: LookGlow,
    /// The alternate icon, if any.
    pub icon_name: Option<&'static str>,
}

impl LookPalette {
    /// The palette of the original look.
    pub fn original() -> Self {
        LookSelection::original().palette()
    }

    /// The glow colour.
    pub fn glow_color(&self) -> LookColor {
        self.look.glow_color
    }

    /// The second, faint tone of the glow.
    pub fn glow_tint(&self) -> Option<LookColor> {
        self.look.glow_tint()
    }

    /// The play mark as one colour, for places that cannot draw a gradient: the look's colour,
    /// or the middle of its first and last.
    pub fn mark_color(&self) -> LookColor {
        let gradient = self.look.logo_gradient;
        let Some(first) = gradient.first() else {
            return self.look.accent.main;
        };
        let Some(last) = gradient.last().filter(|_| gradient.len() > 1) else {
            return *first;
        };
        let mid = |shift: u32| {
            ((((first.hex >> shift) & 0xFF) + ((last.hex >> shift) & 0xFF)) / 2) << shift
        };
        LookColor::new(mid(16) | mid(8) | mid(0))
    }
}

/// The fixed storage keys (`LookStorageKey`, `Look.swift:307-314`). Changing one loses what
/// devices have stored.
pub mod storage_key {
    /// The selection, JSON `LookSelection`.
    pub const SELECTION: &str = "look.selection";
    /// The gifts picked up, a list of look ids.
    pub const OWNED: &str = "look.owned";
    /// The gift pop-ups already shown, `<look>-<year>` ids.
    pub const GIFT_OFFERED: &str = "look.gift.offered";
    /// "Bats and details"; default on.
    pub const EFFECTS: &str = "look.effects";
}
