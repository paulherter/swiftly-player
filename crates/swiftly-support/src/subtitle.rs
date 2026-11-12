//! How text subtitles look: one value that travels with the profile settings (`utAussehen`,
//! synced). Port of `Packages/JellyfinKit/Sources/JellyfinKit/SubtitleLook.swift`, the words of
//! `Sources/Shared/SubtitlePreview.swift` and the mpv mapping of
//! `Linux/Sources/SwiftlyLinux/Player.swift:551-573`.
//!
//! Seven fields, all steps and switches. Raw values are part of the stored format; an unknown
//! word reads as the default instead of failing.

use serde::{Deserialize, Serialize};

/// Size step.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Size {
    /// 0.8.
    Small,
    /// 1.0.
    Normal,
    /// 1.2.
    Large,
    /// 1.45.
    Huge,
}

impl Size {
    /// Every step, in order.
    pub const ALL: [Size; 4] = [Self::Small, Self::Normal, Self::Large, Self::Huge];

    /// Factor on the base scale.
    pub fn factor(self) -> f64 {
        match self {
            Self::Small => 0.8,
            Self::Normal => 1.0,
            Self::Large => 1.2,
            Self::Huge => 1.45,
        }
    }

    /// German name, also the catalogue key.
    pub fn name_key(self) -> &'static str {
        match self {
            Self::Small => "Klein",
            Self::Normal => "Normal",
            Self::Large => "Groß",
            Self::Huge => "Sehr groß",
        }
    }

    /// The "A" of the segment, growing with the step (points).
    pub fn glyph_size(self) -> f64 {
        match self {
            Self::Small => 12.0,
            Self::Normal => 15.0,
            Self::Large => 17.0,
            Self::Huge => 20.0,
        }
    }
}

/// Text colour.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Colour {
    /// White.
    White,
    /// Yellow.
    Yellow,
    /// Grey.
    Grey,
}

impl Colour {
    /// Every colour, in order.
    pub const ALL: [Colour; 3] = [Self::White, Self::Yellow, Self::Grey];

    /// `0xRRGGBB`.
    pub fn rgb(self) -> u32 {
        match self {
            Self::White => 0xFFFFFF,
            Self::Yellow => 0xFFE45C,
            Self::Grey => 0xCCCCCC,
        }
    }

    /// German name, also the catalogue key.
    pub fn name_key(self) -> &'static str {
        match self {
            Self::White => "Weiß",
            Self::Yellow => "Gelb",
            Self::Grey => "Grau",
        }
    }
}

/// Outline step.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Outline {
    /// None.
    Off,
    /// 2 percent.
    Thin,
    /// 3 percent.
    Normal,
}

impl Outline {
    /// Every step, in order.
    pub const ALL: [Outline; 3] = [Self::Off, Self::Thin, Self::Normal];

    /// Percent of the font height.
    pub fn thickness(self) -> i64 {
        match self {
            Self::Off => 0,
            Self::Thin => 2,
            Self::Normal => 3,
        }
    }

    /// German name, also the catalogue key.
    pub fn name_key(self) -> &'static str {
        match self {
            Self::Off => "Aus",
            Self::Thin => "Dünn",
            Self::Normal => "Normal",
        }
    }
}

/// Vertical position.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Position {
    /// At the bottom.
    Bottom,
    /// Lifted by 7 percent of the picture height.
    Raised,
}

impl Position {
    /// German name, also the catalogue key.
    pub fn name_key(self) -> &'static str {
        match self {
            Self::Bottom => "Unten",
            Self::Raised => "Höher",
        }
    }
}

/// Which VLC the options are for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Engine {
    /// VLC 4 (VLCKit on Apple): background opacity at least 1, the size goes to the player.
    Vlc4Apple,
    /// VLC 3 (Android, Linux, Windows): the size goes in as `--sub-text-scale`.
    Vlc3,
}

/// The base scale (1 = 6.25 % of the picture height) per device class (`VLCPlayer.swift:19-30`).
pub mod base_scale {
    /// iPhone.
    pub const IPHONE: f64 = 0.82;
    /// iPad and Mac.
    pub const IPAD_MAC: f64 = 0.78;
    /// Apple TV.
    pub const TV: f64 = 0.88;
    /// Linux and Windows (`SubtitleStyle.swift:23`).
    pub const DESKTOP: f64 = 0.78;
    /// The text height is this share of the picture height at scale 1.
    pub const PICTURE_SHARE: f64 = 0.0625;
}

/// The font the subtitles are drawn with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FontChoice {
    /// Apple: the PostScript name of the bundled Inter (`SubtitleStyle.fontName`).
    AppleInter,
    /// Linux with the bundled Inter found by fontconfig.
    LinuxInter,
    /// Linux without it.
    LinuxFallback,
    /// Windows: the system's closest relative.
    Windows,
}

impl FontChoice {
    /// The family name handed to the player.
    pub fn family(self) -> &'static str {
        match self {
            Self::AppleInter => "Inter18pt-SemiBold",
            Self::LinuxInter => "Inter 18pt SemiBold",
            Self::LinuxFallback => "Sans",
            Self::Windows => "Segoe UI Semibold",
        }
    }
}

/// Everything about how a subtitle looks.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(from = "Lenient")]
pub struct SubtitleLook {
    /// Box behind the text.
    pub background: bool,
    /// Text colour.
    pub colour: Colour,
    /// On: ASS and SSA are drawn by their own file. Off: the server's SRT version is loaded and
    /// this look applies.
    #[serde(rename = "keepFileStyle")]
    pub keep_file_style: bool,
    /// Outline step.
    pub outline: Outline,
    /// Position.
    pub position: Position,
    /// Hard shadow.
    pub shadow: bool,
    /// Size step.
    pub size: Size,
}

impl Default for SubtitleLook {
    fn default() -> Self {
        Self::STANDARD
    }
}

/// Tolerant reading: a missing or unreadable field falls back to its default.
#[derive(Deserialize)]
struct Lenient {
    #[serde(default)]
    background: Option<serde_json::Value>,
    #[serde(default)]
    colour: Option<serde_json::Value>,
    #[serde(default, rename = "keepFileStyle")]
    keep_file_style: Option<serde_json::Value>,
    #[serde(default)]
    outline: Option<serde_json::Value>,
    #[serde(default)]
    position: Option<serde_json::Value>,
    #[serde(default)]
    shadow: Option<serde_json::Value>,
    #[serde(default)]
    size: Option<serde_json::Value>,
}

fn field<T: serde::de::DeserializeOwned>(v: Option<serde_json::Value>, default: T) -> T {
    v.and_then(|v| serde_json::from_value(v).ok())
        .unwrap_or(default)
}

impl From<Lenient> for SubtitleLook {
    fn from(l: Lenient) -> Self {
        let d = Self::STANDARD;
        Self {
            background: field(l.background, d.background),
            colour: field(l.colour, d.colour),
            keep_file_style: field(l.keep_file_style, d.keep_file_style),
            outline: field(l.outline, d.outline),
            position: field(l.position, d.position),
            shadow: field(l.shadow, d.shadow),
            size: field(l.size, d.size),
        }
    }
}

impl<'de> Deserialize<'de> for SubtitleLook {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Lenient::deserialize(d).map(Self::from)
    }
}

impl SubtitleLook {
    /// The built-in look: normal, white, normal outline, no shadow, no background, bottom, the
    /// file keeps its own style.
    pub const STANDARD: SubtitleLook = SubtitleLook {
        background: false,
        colour: Colour::White,
        keep_file_style: true,
        outline: Outline::Normal,
        position: Position::Bottom,
        shadow: false,
        size: Size::Normal,
    };

    /// Everything on its default, including the file-style switch.
    pub fn is_standard(&self) -> bool {
        *self == Self::STANDARD
    }

    /// Stable JSON (sorted keys), so equal looks give equal text. This is the value of the
    /// synced `utAussehen` setting.
    pub fn encoded(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_else(|_| b"{}".to_vec())
    }

    /// Reads a stored look; anything unreadable gives the default.
    pub fn read(data: Option<&[u8]>) -> SubtitleLook {
        data.and_then(|d| serde_json::from_slice(d).ok())
            .unwrap_or(Self::STANDARD)
    }

    /// The value of the entry row ("Untertitel-Stil"): German catalogue key.
    pub fn entry_value(&self) -> &'static str {
        if self.is_standard() {
            "Standard"
        } else {
            "Eigenes"
        }
    }

    /// The whole setting as one sentence, for VoiceOver on the preview. Parts are German
    /// catalogue keys; join them with ", ".
    pub fn sentence_keys(&self) -> [&'static str; 6] {
        [
            self.size.name_key(),
            self.colour.name_key(),
            match self.outline {
                Outline::Off => "ohne Rand",
                Outline::Thin => "Rand dünn",
                Outline::Normal => "Rand normal",
            },
            if self.shadow {
                "mit Schatten"
            } else {
                "ohne Schatten"
            },
            if self.background {
                "mit Hintergrund"
            } else {
                "ohne Hintergrund"
            },
            if self.position == Position::Bottom {
                "unten"
            } else {
                "höher"
            },
        ]
    }

    /// The line under the file switch: what applies now (German catalogue key).
    pub fn file_style_line(&self) -> &'static str {
        if self.keep_file_style {
            "Bei ASS und SSA bestimmt die Datei Schrift, Farbe und Position. Schilder und Karaoke bleiben im Bild."
        } else {
            "Auch ASS und SSA sehen dann aus wie oben. Schilder rutschen als Zeile nach unten."
        }
    }

    /// Percent for the text scale: base scale times step times 100, rounded (iPhone 66 / 82 /
    /// 98 / 119, iPad and Mac 62 / 78 / 94 / 113, TV 70 / 88 / 106 / 128).
    pub fn text_scale_percent(&self, base_scale: f64) -> i64 {
        (base_scale * self.size.factor() * 100.0).round() as i64
    }

    /// Point size of the preview text: picture height x 6.25 % x base x step.
    pub fn preview_points(&self, picture_height: f64, base_scale: f64) -> f64 {
        picture_height * base_scale::PICTURE_SHARE * self.text_scale_percent(base_scale) as f64
            / 100.0
    }

    /// Extra margin of "raised": 7 % of the output height in pixels (1080 gives 76, 2160 gives 151).
    pub fn raised_margin(output_height: i64) -> i64 {
        (output_height as f64 * 0.07).round() as i64
    }

    /// The VLC library options for a look, without the font (platform specific).
    ///
    /// Background off is 1 on Apple and 0 elsewhere (VLC 4 pads the picture above 0, which
    /// avoids a crash in the glyph blend); `sub-margin` is 16 on Apple, 0 elsewhere, plus the
    /// raised margin.
    pub fn vlc_options(&self, base_scale: f64, output_height: i64, engine: Engine) -> Vec<String> {
        let mut options = Vec::new();
        if engine == Engine::Vlc3 {
            options.push(format!(
                "--sub-text-scale={}",
                self.text_scale_percent(base_scale)
            ));
        }
        options.push(format!("--freetype-color={}", self.colour.rgb()));
        options.push(format!(
            "--freetype-outline-thickness={}",
            self.outline.thickness()
        ));
        options.push("--freetype-outline-opacity=230".to_owned());
        options.push("--freetype-outline-color=0".to_owned());
        if self.shadow {
            options.extend(
                [
                    "--freetype-shadow-opacity=160",
                    "--freetype-shadow-angle=-90",
                    "--freetype-shadow-distance=0.04",
                    "--freetype-shadow-color=0",
                ]
                .map(str::to_owned),
            );
        } else {
            options.push("--freetype-shadow-opacity=0".to_owned());
        }
        if self.background {
            options.extend(
                [
                    "--freetype-background-opacity=160",
                    "--freetype-background-color=0",
                ]
                .map(str::to_owned),
            );
        } else {
            options.push(format!(
                "--freetype-background-opacity={}",
                i32::from(engine == Engine::Vlc4Apple)
            ));
        }
        let base = if engine == Engine::Vlc4Apple { 16 } else { 0 };
        let raised = if self.position == Position::Raised {
            Self::raised_margin(output_height)
        } else {
            0
        };
        let margin = base + raised;
        if margin > 0 || engine == Engine::Vlc4Apple {
            options.push(format!("--sub-margin={margin}"));
        }
        options
    }

    /// The pure mapping to mpv's subtitle style.
    pub fn mpv_style(&self, output_height: i64, font: &str) -> MpvSubtitleStyle {
        const FONT_SIZE: f64 = 55.0;
        let margin = 22.0
            + if self.position == Position::Raised {
                Self::raised_margin(output_height) as f64 * 720.0 / output_height.max(1) as f64
            } else {
                0.0
            };
        MpvSubtitleStyle {
            font: font.to_owned(),
            font_size: FONT_SIZE,
            scale: self.size.factor(),
            color: format!("#{:06X}", self.colour.rgb()),
            border_color: "#E6000000".to_owned(),
            border_size: FONT_SIZE * self.outline.thickness() as f64 / 100.0 * 2.0,
            shadow: self
                .shadow
                .then(|| ("#A0000000".to_owned(), FONT_SIZE * 0.04)),
            back_color: if self.background {
                "#A0000000"
            } else {
                "#00000000"
            }
            .to_owned(),
            margin_y: margin.round() as i64,
            keep_file_style: self.keep_file_style,
        }
    }
}

/// mpv's counterpart of the VLC options: font, size, colour, outline, shadow, background and
/// margin. mpv draws subtitles on a 720-line scale (`sub-font-size` 55 by default).
#[derive(Clone, Debug, PartialEq)]
pub struct MpvSubtitleStyle {
    /// `sub-font`.
    pub font: String,
    /// `sub-font-size`.
    pub font_size: f64,
    /// `sub-scale`, the size step.
    pub scale: f64,
    /// `sub-color`, `#RRGGBB`.
    pub color: String,
    /// `sub-border-color`, `#AARRGGBB`.
    pub border_color: String,
    /// `sub-border-size`.
    pub border_size: f64,
    /// `sub-shadow-color` and `sub-shadow-offset` when the shadow is on.
    pub shadow: Option<(String, f64)>,
    /// `sub-back-color`, `#AARRGGBB`.
    pub back_color: String,
    /// `sub-margin-y`.
    pub margin_y: i64,
    /// `sub-ass-override`: `no` keeps the file's style, `force` applies this look.
    pub keep_file_style: bool,
}

impl MpvSubtitleStyle {
    /// The option name/value pairs in the order the desktop player sets them.
    pub fn options(&self) -> Vec<(String, String)> {
        let mut o = vec![
            ("sub-font".to_owned(), self.font.clone()),
            ("sub-font-size".to_owned(), "55".to_owned()),
            ("sub-scale".to_owned(), format!("{:?}", self.scale)),
            ("sub-color".to_owned(), self.color.clone()),
            ("sub-border-color".to_owned(), self.border_color.clone()),
            (
                "sub-border-size".to_owned(),
                format!("{:?}", self.border_size),
            ),
            (
                "sub-ass-override".to_owned(),
                if self.keep_file_style { "no" } else { "force" }.to_owned(),
            ),
        ];
        match &self.shadow {
            Some((color, offset)) => {
                o.push(("sub-shadow-color".to_owned(), color.clone()));
                o.push(("sub-shadow-offset".to_owned(), format!("{offset:?}")));
            }
            None => o.push(("sub-shadow-offset".to_owned(), "0".to_owned())),
        }
        o.push(("sub-back-color".to_owned(), self.back_color.clone()));
        o.push(("sub-margin-y".to_owned(), self.margin_y.to_string()));
        o
    }
}
