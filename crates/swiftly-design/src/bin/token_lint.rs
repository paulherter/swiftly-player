//! Token lint: finds raw colours, corner radii, spacing and font sizes in UI code that should use a design token.
//!
//! ```text
//! cargo run -p swiftly-design --bin token_lint -- [--enforce | --write-baseline] [--summary] [--top N]
//!     [--repo <dir>] [--tokens <tokens.json>] [--baseline <lint-baseline.json>]
//! ```
//!
//! Scans Swift (`Sources/`, UI files of `Packages/*/Sources`), Kotlin (`Android/**/src/main`) and the Rust UI crates
//! (`crates/swiftly-{desktop,ui,ios,android}/src`). Every finding names the allowed token: when the raw value equals a
//! token value the token itself ("use radius.card (16)"), else the token family.
//!
//! Modes: default = warn (print findings, exit 0). `--enforce` exits 1 only for findings beyond the baseline
//! (`design/lint-baseline.json`, counts per file and rule, so moving a line never trips it). `--write-baseline`
//! records the current counts; a baseline change is its own reviewed commit.
//!
//! Exemptions: the token and style files in [`EXEMPT_FILES`], tests, previews, build output, and any line that has
//! (or follows a line that has) `token-lint: allow <reason>`. The rest of a file after `#Preview`, `PreviewProvider`,
//! `@Preview` or `#[cfg(test)]` is skipped.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use serde::{Deserialize, Serialize};
use serde_json::Value;

// ---------------------------------------------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------------------------------------------

/// Files that define or generate the tokens; raw values are their job.
const EXEMPT_FILES: &[&str] = &[
    "Sources/Shared/Style.swift",
    "Sources/macOS/Style.swift",
    "Sources/tvOS/Style.swift",
    "Sources/Shared/Colors.swift",
    "Sources/Shared/Tokens.generated.swift",
    "Android/shared/src/main/java/de/paulherter/swiftly/shared/Style.kt",
    "Android/shared/src/main/java/de/paulherter/swiftly/shared/Tokens.kt",
    "Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt",
    "Android/phone/src/main/java/de/paulherter/swiftly/tv/TvSpec.kt",
];

/// Directory names that are never scanned (tests, build output, vendored code).
const SKIP_DIRS: &[&str] = &[
    "Tests",
    "tests",
    "test",
    "androidTest",
    "build",
    ".build",
    "target",
    "Vendor",
    "DerivedData",
    ".git",
    "node_modules",
    "generated",
    "examples",
    "benches",
];

/// Rust crates that contain UI code (not core or logic crates).
const RUST_UI_CRATES: &[&str] = &[
    "swiftly-desktop",
    "swiftly-ui",
    "swiftly-ios",
    "swiftly-android",
];

const ALLOW_MARKER: &str = "token-lint: allow";

// ---------------------------------------------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum Platform {
    Swift,
    Kotlin,
    Rust,
}

impl Platform {
    fn name(self) -> &'static str {
        match self {
            Platform::Swift => "swift",
            Platform::Kotlin => "kotlin",
            Platform::Rust => "rust",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum Rule {
    Color,
    Radius,
    Spacing,
    Font,
    /// A Kotlin `RoundedCornerShape(` that is not a capsule: rounded rectangles use `smoothRoundedShape`.
    Shape,
}

impl Rule {
    const ALL: [Rule; 5] = [
        Rule::Color,
        Rule::Radius,
        Rule::Spacing,
        Rule::Font,
        Rule::Shape,
    ];

    fn key(self) -> &'static str {
        match self {
            Rule::Color => "color",
            Rule::Radius => "radius",
            Rule::Spacing => "spacing",
            Rule::Font => "font",
            Rule::Shape => "shape",
        }
    }
}

#[derive(Clone, Debug)]
struct Finding {
    platform: Platform,
    file: String,
    line: usize,
    rule: Rule,
    text: String,
    hint: String,
}

/// One raw value found on a line, before file and line are known.
struct Hit {
    rule: Rule,
    hint: String,
}

type Result<T> = std::result::Result<T, String>;

// ---------------------------------------------------------------------------------------------------------------
// Tokens (read from design/tokens.json)
// ---------------------------------------------------------------------------------------------------------------

struct Colour {
    name: String,
    rgb: u32,
    alpha: f32,
}

/// value (in hundredths) -> token names
type ValueMap = BTreeMap<i32, Vec<String>>;

struct Tokens {
    colours: Vec<Colour>,
    radius: ValueMap,
    spacing: ValueMap,
    font: ValueMap,
}

fn vkey(v: f32) -> i32 {
    (v * 100.0).round() as i32
}

fn add(map: &mut ValueMap, v: f32, name: &str) {
    let names = map.entry(vkey(v)).or_default();
    if !names.iter().any(|n| n == name) {
        names.push(name.to_owned());
    }
}

fn num(e: &Value, key: &str) -> Option<f32> {
    e.get(key).and_then(Value::as_f64).map(|v| v as f32)
}

fn hex_rgb(hex: &str) -> Option<u32> {
    let h = hex.strip_prefix('#')?;
    if h.len() != 6 {
        return None;
    }
    u32::from_str_radix(h, 16).ok()
}

fn load_tokens(root: &Value) -> Result<Tokens> {
    let list = |key: &str| -> Result<&Vec<Value>> {
        root.get(key)
            .and_then(Value::as_array)
            .ok_or_else(|| format!("tokens.json: `{key}` must be a list"))
    };
    let mut t = Tokens {
        colours: Vec::new(),
        radius: ValueMap::new(),
        spacing: ValueMap::new(),
        font: ValueMap::new(),
    };
    for e in list("colors")? {
        let name = e.get("name").and_then(Value::as_str).unwrap_or_default();
        let rgb = e
            .get("dark")
            .and_then(Value::as_str)
            .and_then(hex_rgb)
            .ok_or_else(|| format!("tokens.json: colour `{name}` has no #RRGGBB `dark` value"))?;
        t.colours.push(Colour {
            name: name.to_owned(),
            rgb,
            alpha: num(e, "alpha").unwrap_or(1.0),
        });
    }
    if let Some(map) = root.get("radius").and_then(Value::as_object) {
        for (k, v) in map {
            if let Some(v) = v.as_f64() {
                add(&mut t.radius, v as f32, &format!("radius.{k}"));
            }
        }
    }
    if let Some(map) = root.get("spacing").and_then(Value::as_object) {
        for (k, v) in map {
            if let Some(v) = v.as_f64() {
                add(&mut t.spacing, v as f32, &format!("spacing.{k}"));
            }
        }
    }
    for e in list("layout")? {
        let name = e.get("name").and_then(Value::as_str).unwrap_or_default();
        let target = if name.starts_with("radius.") {
            &mut t.radius
        } else if name.starts_with("space.") {
            &mut t.spacing
        } else {
            continue;
        };
        for key in ["value", "desktop", "tv"] {
            if let Some(v) = num(e, key) {
                add(target, v, name);
            }
        }
    }
    for e in list("type")? {
        let name = e.get("name").and_then(Value::as_str).unwrap_or_default();
        if let Some(v) = num(e, "size") {
            add(&mut t.font, v, name);
        }
        for set in ["desktop", "tv"] {
            if let Some(v) = e.get(set).and_then(|o| num(o, "size")) {
                add(&mut t.font, v, name);
            }
        }
    }
    Ok(t)
}

fn fmt_num(v: f32) -> String {
    if (v - v.round()).abs() < 0.005 {
        format!("{}", v.round() as i64)
    } else {
        format!("{v}")
    }
}

impl Tokens {
    fn value_hint(&self, map: &ValueMap, v: Option<f32>, family: &str) -> String {
        match v.and_then(|v| map.get(&vkey(v)).map(|n| (v, n))) {
            Some((v, names)) => {
                let shown: Vec<&str> = names.iter().take(3).map(String::as_str).collect();
                format!("use {} ({})", shown.join(" or "), fmt_num(v))
            }
            None => format!("use a {family} token from design/tokens.json"),
        }
    }

    fn radius_hint(&self, v: Option<f32>) -> String {
        self.value_hint(&self.radius, v, "radius.*")
    }

    fn spacing_hint(&self, v: Option<f32>) -> String {
        self.value_hint(&self.spacing, v, "spacing.* or space.*")
    }

    fn font_hint(&self, v: Option<f32>) -> String {
        self.value_hint(&self.font, v, "type.*")
    }

    /// `colour` is (rgb, alpha) when the raw value could be read.
    fn colour_hint(&self, colour: Option<(u32, f32)>) -> String {
        if let Some((rgb, alpha)) = colour {
            let names: Vec<&str> = self
                .colours
                .iter()
                .filter(|c| c.rgb == rgb && (c.alpha - alpha).abs() < 0.006)
                .take(3)
                .map(|c| c.name.as_str())
                .collect();
            if !names.is_empty() {
                let pct = (alpha * 100.0).round() as i32;
                let at = if pct == 100 {
                    String::new()
                } else {
                    format!(" at {pct}%")
                };
                return format!("use {} (#{rgb:06X}{at})", names.join(" or "));
            }
        }
        "use a color.* token from design/tokens.json".to_owned()
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Line helpers (no regex: a few string scans are enough)
// ---------------------------------------------------------------------------------------------------------------

/// Number at the start of `s` (digits and dots) and the rest after it.
fn leading_num(s: &str) -> Option<(f32, &str)> {
    let s = s.trim_start();
    let end = s
        .find(|c: char| !(c.is_ascii_digit() || c == '.'))
        .unwrap_or(s.len());
    if end == 0 {
        return None;
    }
    let n = s[..end].trim_end_matches('.').parse::<f32>().ok()?;
    Some((n, &s[end..]))
}

/// A number that stands alone as a value: `14`, `15.0,`, `8)`, not `15.0 * scale`.
fn pure_num(s: &str) -> Option<f32> {
    let (n, rest) = leading_num(s)?;
    let rest = rest.trim_start();
    let rest = rest.strip_prefix('f').unwrap_or(rest).trim_start();
    (rest.is_empty() || rest.starts_with([',', ')', '}', ']'])).then_some(n)
}

fn is_ident(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// True when the match at byte `i` is not the tail of a longer identifier.
fn boundary(line: &str, i: usize) -> bool {
    line[..i].chars().next_back().is_none_or(|c| !is_ident(c))
}

/// Arguments (text between the parentheses) of every call that starts with `needle` (which ends in `(`).
/// When `word` is set the needle must start at an identifier boundary.
fn call_args<'a>(line: &'a str, needle: &str, word: bool) -> Vec<&'a str> {
    let mut out = Vec::new();
    for (i, _) in line.match_indices(needle) {
        if word && !boundary(line, i) {
            continue;
        }
        let start = i + needle.len();
        let mut depth = 1;
        let mut end = line.len();
        for (j, c) in line[start..].char_indices() {
            match c {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        end = start + j;
                        break;
                    }
                }
                _ => {}
            }
        }
        out.push(&line[start..end]);
    }
    out
}

fn split_args(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut from = 0;
    for (i, c) in s.char_indices() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            ',' if depth == 0 => {
                out.push(&s[from..i]);
                from = i + 1;
            }
            _ => {}
        }
    }
    out.push(&s[from..]);
    out
}

/// `RoundedCornerShape(50)`, `(50.percent)`, `(percent = 50)` and `(CornerSize(50))`: a capsule or circle.
fn is_capsule_arg(arg: &str) -> bool {
    let a: String = arg.chars().filter(|c| !c.is_whitespace()).collect();
    let a = a.strip_prefix("percent=").unwrap_or(&a);
    let a = a
        .strip_prefix("CornerSize(")
        .and_then(|r| r.strip_suffix(')'))
        .unwrap_or(a);
    let a = a.strip_suffix(".percent").unwrap_or(a);
    matches!(a, "50" | "50f" | "50.0f" | "50.0")
}

/// Numbers written as `12.dp` / `14.sp` (unit without a space) inside `s`.
fn unit_nums(s: &str, unit: &str) -> Vec<f32> {
    let needle = format!(".{unit}");
    let mut out = Vec::new();
    for (i, _) in s.match_indices(&needle) {
        let after = &s[i + needle.len()..];
        if after.chars().next().is_some_and(is_ident) {
            continue;
        }
        let head = &s[..i];
        let start = head
            .rfind(|c: char| !(c.is_ascii_digit() || c == '.'))
            .map_or(0, |p| p + 1);
        if head[..start].chars().next_back().is_some_and(is_ident) {
            continue;
        }
        if let Ok(n) = head[start..].parse::<f32>() {
            out.push(n);
        }
    }
    out
}

/// The number after `label` (for example `red:` or `fontSize =`), if it is a plain literal.
fn after_label(s: &str, label: &str) -> Option<f32> {
    let i = s.find(label)?;
    leading_num(&s[i + label.len()..]).map(|(n, _)| n)
}

fn hex_digits(s: &str) -> Option<(u32, usize)> {
    let s = s.trim_start();
    let body = s
        .strip_prefix("0x")
        .or_else(|| s.strip_prefix("0X"))
        .or_else(|| s.strip_prefix("\"#"))
        .or_else(|| s.strip_prefix('#'))?;
    let digits: String = body
        .chars()
        .take_while(|c| c.is_ascii_hexdigit() || *c == '_')
        .filter(|c| *c != '_')
        .collect();
    let n = u32::from_str_radix(&digits, 16).ok()?;
    Some((n, digits.len()))
}

fn channel(v: f32) -> u32 {
    (v.clamp(0.0, 1.0) * 255.0).round() as u32
}

fn unit_rgb(r: f32, g: f32, b: f32) -> u32 {
    (channel(r) << 16) | (channel(g) << 8) | channel(b)
}

/// Raw colour from the arguments of a Swift `Color(…)`, `UIColor(…)` or `NSColor(…)` call.
/// `None` when the call does not build a colour from numbers (`Color("name")`, `Color(uiColor:)`).
/// `Some(None)` when it does but the numbers are not plain literals.
fn swift_colour_args(a: &str) -> Option<Option<(u32, f32)>> {
    let alpha = after_label(a, "opacity:")
        .or_else(|| after_label(a, "alpha:"))
        .unwrap_or(1.0);
    if a.contains("red:") {
        let rgb = match (
            after_label(a, "red:"),
            after_label(a, "green:"),
            after_label(a, "blue:"),
        ) {
            (Some(r), Some(g), Some(b)) => Some((unit_rgb(r, g, b), alpha)),
            _ => None,
        };
        return Some(rgb);
    }
    if a.contains("white:") {
        return Some(after_label(a, "white:").map(|w| (unit_rgb(w, w, w), alpha)));
    }
    if a.contains("hue:") {
        return Some(None);
    }
    let hex_part = a.find("hex:").map(|i| &a[i + 4..]).unwrap_or(a);
    if let Some((n, len)) = hex_digits(hex_part) {
        if len == 6 {
            return Some(Some((n, alpha)));
        }
        if len == 8 {
            return Some(Some((n & 0xFF_FFFF, (n >> 24) as f32 / 255.0)));
        }
        return Some(None);
    }
    if a.contains("hex") {
        return Some(None);
    }
    None
}

// ---------------------------------------------------------------------------------------------------------------
// Rules per platform
// ---------------------------------------------------------------------------------------------------------------

fn swift_line(t: &Tokens, l: &str, out: &mut Vec<Hit>) {
    let mut colour = |c: Option<(u32, f32)>| {
        out.push(Hit {
            rule: Rule::Color,
            hint: t.colour_hint(c),
        })
    };
    for needle in ["Color(", "UIColor(", "NSColor("] {
        for a in call_args(l, needle, true) {
            if let Some(c) = swift_colour_args(a) {
                colour(c);
            }
        }
    }
    // `Color.white`, `.white.opacity(0.1)`, `.black.opacity(…)`
    for (name, rgb) in [("white", 0xFF_FFFFu32), ("black", 0x00_0000)] {
        let dotted = format!(".{name}");
        for (i, _) in l.match_indices(&dotted) {
            let rest = &l[i + dotted.len()..];
            if rest.chars().next().is_some_and(is_ident) {
                continue;
            }
            let prefix = &l[..i];
            let explicit = prefix.ends_with("Color");
            let opacity = rest
                .strip_prefix(".opacity(")
                .map(|r| leading_num(r).map(|(n, _)| n));
            match opacity {
                Some(a) => colour(a.map(|a| (rgb, a))),
                None if explicit
                    && !prefix.ends_with("UIColor")
                    && !prefix.ends_with("NSColor") =>
                {
                    colour(Some((rgb, 1.0)))
                }
                None => {}
            }
        }
    }
    for needle in ["cornerRadius:", "cornerRadius("] {
        for (i, _) in l.match_indices(needle) {
            if let Some(n) = leading_num(&l[i + needle.len()..])
                .map(|(n, _)| n)
                .filter(|n| *n > 0.0)
            {
                out.push(Hit {
                    rule: Rule::Radius,
                    hint: t.radius_hint(Some(n)),
                });
            }
        }
    }
    for a in call_args(l, ".padding(", false) {
        if let Some(n) = split_args(a)
            .last()
            .and_then(|x| pure_num(x))
            .filter(|n| *n > 0.0)
        {
            out.push(Hit {
                rule: Rule::Spacing,
                hint: t.spacing_hint(Some(n)),
            });
        }
    }
    for (i, _) in l.match_indices("spacing:") {
        if !boundary(l, i) {
            continue;
        }
        if let Some(n) = pure_num(&l[i + 8..]).filter(|n| *n > 0.0) {
            out.push(Hit {
                rule: Rule::Spacing,
                hint: t.spacing_hint(Some(n)),
            });
        }
    }
    let mut font = |n: f32| {
        out.push(Hit {
            rule: Rule::Font,
            hint: t.font_hint(Some(n)),
        })
    };
    for needle in [".system(", ".app(", ".custom(", "ofSize:"] {
        if needle.ends_with('(') {
            for a in call_args(l, needle, false) {
                if let Some(n) = after_label(a, "size:") {
                    font(n);
                }
            }
        } else {
            for (i, _) in l.match_indices(needle) {
                if let Some((n, _)) = leading_num(&l[i + needle.len()..]) {
                    font(n);
                }
            }
        }
    }
}

fn kotlin_line(t: &Tokens, l: &str, out: &mut Vec<Hit>) {
    let mut colour = |c: Option<(u32, f32)>| {
        out.push(Hit {
            rule: Rule::Color,
            hint: t.colour_hint(c),
        })
    };
    for a in call_args(l, "Color(", true) {
        let parsed = if let Some((n, len)) = hex_digits(a) {
            match len {
                6 => Some((n, 1.0)),
                8 => Some((n & 0xFF_FFFF, (n >> 24) as f32 / 255.0)),
                _ => None,
            }
        } else if a.contains("red") {
            match (
                after_label(a, "red ="),
                after_label(a, "green ="),
                after_label(a, "blue ="),
            ) {
                (Some(r), Some(g), Some(b)) => {
                    Some((unit_rgb(r, g, b), after_label(a, "alpha =").unwrap_or(1.0)))
                }
                _ => None,
            }
        } else {
            None
        };
        // `Color(someValue)` and `Color(Theme.x)` build nothing raw.
        if parsed.is_some() || hex_digits(a).is_some() || a.contains("red") {
            colour(parsed);
        }
    }
    for (name, rgb) in [("White", 0xFF_FFFFu32), ("Black", 0x00_0000)] {
        let needle = format!("Color.{name}");
        for (i, _) in l.match_indices(&needle) {
            if !boundary(l, i) {
                continue;
            }
            let rest = &l[i + needle.len()..];
            if rest.chars().next().is_some_and(is_ident) {
                continue;
            }
            let alpha = rest
                .strip_prefix(".copy(")
                .and_then(|r| after_label(r, "alpha ="));
            colour(Some((rgb, alpha.unwrap_or(1.0))));
        }
    }
    if l.contains("Color.parseColor(") || l.contains("Color.rgb(") {
        colour(None);
    }
    // `smoothRoundedShape(` is the allowed shape (60 % corner smoothing); its radius must still be a token.
    for needle in ["RoundedCornerShape(", "smoothRoundedShape("] {
        for a in call_args(l, needle, false) {
            if let Some(n) = unit_nums(a, "dp").into_iter().find(|n| *n > 0.0) {
                out.push(Hit {
                    rule: Rule::Radius,
                    hint: t.radius_hint(Some(n)),
                });
            }
        }
    }
    // Handwriting decision (19.11.): every rounded rectangle has smoothed corners. Only a capsule (50 %) or a
    // circle may stay a plain `RoundedCornerShape`; a radius of half the side or more is marked `token-lint: allow`.
    for a in call_args(l, "RoundedCornerShape(", false) {
        if !is_capsule_arg(a) {
            out.push(Hit {
                rule: Rule::Shape,
                hint: "use smoothRoundedShape(<radius token>) from de.paulherter.swiftly.shared (60 % corner smoothing); \
                       only capsules (RoundedCornerShape(50)) and CircleShape stay plain"
                    .to_string(),
            });
        }
    }
    for (i, _) in l.match_indices("cornerRadius =") {
        if let Some(n) = unit_nums(&l[i + 14..], "dp")
            .first()
            .copied()
            .filter(|n| *n > 0.0)
        {
            out.push(Hit {
                rule: Rule::Radius,
                hint: t.radius_hint(Some(n)),
            });
        }
    }
    for needle in ["adding(", "spacedBy("] {
        for a in call_args(l, needle, false) {
            for n in unit_nums(a, "dp").into_iter().filter(|n| *n > 0.0) {
                out.push(Hit {
                    rule: Rule::Spacing,
                    hint: t.spacing_hint(Some(n)),
                });
            }
        }
    }
    for (i, _) in l.match_indices("fontSize") {
        let rest = l[i + 8..].trim_start().strip_prefix('=').unwrap_or("");
        if let Some(n) = unit_nums(rest.split([',', ')']).next().unwrap_or(""), "sp")
            .first()
            .copied()
        {
            out.push(Hit {
                rule: Rule::Font,
                hint: t.font_hint(Some(n)),
            });
        }
    }
}

fn rust_line(t: &Tokens, l: &str, prev: &str, out: &mut Vec<Hit>) {
    let mut colour = |c: Option<(u32, f32)>| {
        out.push(Hit {
            rule: Rule::Color,
            hint: t.colour_hint(c),
        })
    };
    for needle in ["Color::new(", "Color::rgb("] {
        for a in call_args(l, needle, true) {
            let nums: Vec<Option<f32>> = split_args(a).iter().map(|x| pure_num(x)).collect();
            if nums.len() >= 3 && nums.iter().all(Option::is_some) {
                let v: Vec<f32> = nums.into_iter().flatten().collect();
                // A fully transparent rectangle (a hit area) has no colour to tokenise.
                if v.get(3).is_some_and(|a| *a < 0.01) {
                    continue;
                }
                colour(Some((
                    unit_rgb(v[0], v[1], v[2]),
                    v.get(3).copied().unwrap_or(1.0),
                )));
            }
        }
    }
    let lower = l.to_ascii_lowercase();
    // "backdrop": the colour a window shows before its first frame (`win_backdrop::set(&window, 0x10_10_10)` stayed behind
    // at the old ground for months because no colour word stood on that line).
    if ["colo", "rgb", "tone", "tint", "accent", "hue", "backdrop"]
        .iter()
        .any(|w| lower.contains(w))
    {
        for (i, _) in l.match_indices("0x") {
            if !boundary(l, i) {
                continue;
            }
            if let Some((n, len)) = hex_digits(&l[i..]) {
                if len == 6 {
                    colour(Some((n, 1.0)));
                } else if len == 8 {
                    colour(Some((n >> 8, (n & 0xFF) as f32 / 255.0)));
                }
            }
        }
    }
    let key_value = |key: &str| -> Vec<f32> {
        l.match_indices(key)
            .filter(|(i, _)| {
                l[..*i]
                    .chars()
                    .next_back()
                    .is_none_or(|c| !c.is_alphanumeric())
            })
            .filter_map(|(i, _)| pure_num(&l[i + key.len()..]))
            .filter(|n| *n > 0.0)
            .collect()
    };
    for n in key_value("radius:") {
        out.push(Hit {
            rule: Rule::Radius,
            hint: t.radius_hint(Some(n)),
        });
    }
    for key in ["gap:", "margin_px:", "padding:", "spacing:"] {
        for n in key_value(key) {
            out.push(Hit {
                rule: Rule::Spacing,
                hint: t.spacing_hint(Some(n)),
            });
        }
    }
    for needle in [".padding(", ".gap("] {
        for a in call_args(l, needle, false) {
            if let Some(n) = split_args(a)
                .last()
                .and_then(|x| pure_num(x))
                .filter(|n| *n > 0.0)
            {
                out.push(Hit {
                    rule: Rule::Spacing,
                    hint: t.spacing_hint(Some(n)),
                });
            }
        }
    }
    let in_text_style = l.contains("TextStyle") || prev.contains("TextStyle");
    let mut sizes = key_value("font_size:");
    if in_text_style {
        sizes.extend(key_value("size:"));
    }
    for n in sizes {
        out.push(Hit {
            rule: Rule::Font,
            hint: t.font_hint(Some(n)),
        });
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------------------------------------------

fn strip_comment(l: &str) -> &str {
    let mut from = 0;
    while let Some(p) = l[from..].find("//") {
        let i = from + p;
        if i > 0 && l.as_bytes()[i - 1] == b':' {
            from = i + 2;
            continue;
        }
        return &l[..i];
    }
    l
}

fn stops_scan(platform: Platform, l: &str) -> bool {
    let t = l.trim_start();
    match platform {
        Platform::Swift => t.starts_with("#Preview") || t.contains("PreviewProvider"),
        Platform::Kotlin => t.starts_with("@Preview"),
        Platform::Rust => t.starts_with("#[cfg(test)]"),
    }
}

fn scan_text(platform: Platform, file: &str, text: &str, t: &Tokens) -> Vec<Finding> {
    let mut found = Vec::new();
    let mut allow_next = false;
    let mut prev = String::new();
    for (idx, raw) in text.lines().enumerate() {
        if stops_scan(platform, raw) {
            break;
        }
        let allowed = allow_next || raw.contains(ALLOW_MARKER);
        let trimmed = raw.trim_start();
        let comment_only =
            trimmed.starts_with("//") || trimmed.starts_with('*') || trimmed.starts_with("/*");
        allow_next = comment_only && raw.contains(ALLOW_MARKER);
        let code = strip_comment(raw);
        if !comment_only && !allowed {
            let mut hits = Vec::new();
            match platform {
                Platform::Swift => swift_line(t, code, &mut hits),
                Platform::Kotlin => kotlin_line(t, code, &mut hits),
                Platform::Rust => rust_line(t, code, &prev, &mut hits),
            }
            let mut snippet: String = code.trim().chars().take(100).collect();
            if code.trim().chars().count() > 100 {
                snippet.push_str("...");
            }
            for h in hits {
                found.push(Finding {
                    platform,
                    file: file.to_owned(),
                    line: idx + 1,
                    rule: h.rule,
                    text: snippet.clone(),
                    hint: h.hint,
                });
            }
        }
        if !comment_only {
            prev = code.to_owned();
        }
    }
    found
}

fn exempt(rel: &str) -> bool {
    if EXEMPT_FILES.contains(&rel) {
        return true;
    }
    let name = rel.rsplit('/').next().unwrap_or(rel);
    name.ends_with("Tests.swift")
        || name.contains("Preview")
        || name.contains(".generated.")
        || name.ends_with("_tests.rs")
        || name == "tests.rs"
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<_> = rd.filter_map(std::result::Result::ok).collect();
    entries.sort_by_key(std::fs::DirEntry::file_name);
    for e in entries {
        let path = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        if path.is_dir() {
            if !SKIP_DIRS.contains(&name.as_str()) {
                walk(&path, out);
            }
        } else {
            out.push(path);
        }
    }
}

fn rel_path(repo: &Path, p: &Path) -> String {
    p.strip_prefix(repo)
        .unwrap_or(p)
        .to_string_lossy()
        .replace('\\', "/")
}

/// All files to scan: (platform, repo-relative path).
fn discover(repo: &Path) -> Vec<(Platform, PathBuf)> {
    let mut found = Vec::new();
    let mut swift_roots = vec![repo.join("Sources")];
    if let Ok(rd) = std::fs::read_dir(repo.join("Packages")) {
        let mut pk: Vec<_> = rd.filter_map(std::result::Result::ok).collect();
        pk.sort_by_key(std::fs::DirEntry::file_name);
        swift_roots.extend(pk.into_iter().map(|e| e.path().join("Sources")));
    }
    for root in swift_roots {
        let in_package = root.to_string_lossy().contains("/Packages/");
        let mut files = Vec::new();
        walk(&root, &mut files);
        for f in files {
            if f.extension().is_some_and(|e| e == "swift") {
                // Packages hold logic too: scan only files that import a UI framework.
                if in_package {
                    let Ok(text) = std::fs::read_to_string(&f) else {
                        continue;
                    };
                    if !["import SwiftUI", "import UIKit", "import AppKit"]
                        .iter()
                        .any(|i| text.contains(i))
                    {
                        continue;
                    }
                }
                found.push((Platform::Swift, f));
            }
        }
    }
    let mut files = Vec::new();
    walk(&repo.join("Android"), &mut files);
    for f in files {
        let rel = rel_path(repo, &f);
        if f.extension().is_some_and(|e| e == "kt") && rel.contains("/src/main/") {
            found.push((Platform::Kotlin, f));
        }
    }
    for c in RUST_UI_CRATES {
        let mut files = Vec::new();
        walk(&repo.join("crates").join(c).join("src"), &mut files);
        for f in files {
            if f.extension().is_some_and(|e| e == "rs") {
                found.push((Platform::Rust, f));
            }
        }
    }
    found
}

fn scan_repo(repo: &Path, t: &Tokens) -> Vec<Finding> {
    let mut all = Vec::new();
    for (platform, path) in discover(repo) {
        let rel = rel_path(repo, &path);
        if exempt(&rel) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        all.extend(scan_text(platform, &rel, &text, t));
    }
    all.sort_by(|a, b| (a.platform, &a.file, a.line).cmp(&(b.platform, &b.file, b.line)));
    all
}

// ---------------------------------------------------------------------------------------------------------------
// Baseline
// ---------------------------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Default)]
struct Baseline {
    version: u32,
    total: u32,
    /// file -> rule -> count
    files: BTreeMap<String, BTreeMap<String, u32>>,
}

fn counts(findings: &[Finding]) -> Baseline {
    let mut b = Baseline {
        version: 1,
        ..Baseline::default()
    };
    for f in findings {
        *b.files
            .entry(f.file.clone())
            .or_default()
            .entry(f.rule.key().to_owned())
            .or_default() += 1;
        b.total += 1;
    }
    b
}

/// Findings beyond the baseline: per file and rule the last `count - allowed` findings (new code is mostly appended).
fn beyond<'a>(findings: &'a [Finding], base: &Baseline) -> Vec<(&'a Finding, u32, u32)> {
    let mut groups: BTreeMap<(&str, Rule), Vec<&Finding>> = BTreeMap::new();
    for f in findings {
        groups.entry((f.file.as_str(), f.rule)).or_default().push(f);
    }
    let mut out = Vec::new();
    for ((file, rule), list) in groups {
        let allowed = base
            .files
            .get(file)
            .and_then(|m| m.get(rule.key()))
            .copied()
            .unwrap_or(0);
        let now = list.len() as u32;
        if now > allowed {
            let skip = list.len() - (now - allowed) as usize;
            out.extend(list.into_iter().skip(skip).map(|f| (f, allowed, now)));
        }
    }
    out.sort_by(|a, b| {
        (a.0.platform, &a.0.file, a.0.line).cmp(&(b.0.platform, &b.0.file, b.0.line))
    });
    out
}

// ---------------------------------------------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------------------------------------------

struct Opts {
    repo: PathBuf,
    tokens: PathBuf,
    baseline: PathBuf,
    enforce: bool,
    write_baseline: bool,
    summary: bool,
    top: usize,
}

fn parse_args(argv: &[String]) -> Result<Opts> {
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut o = Opts {
        tokens: repo.join("design/tokens.json"),
        baseline: repo.join("design/lint-baseline.json"),
        repo,
        enforce: false,
        write_baseline: false,
        summary: false,
        top: 0,
    };
    let mut it = argv.iter();
    while let Some(arg) = it.next() {
        let mut value = |n: &str| {
            it.next()
                .map(PathBuf::from)
                .ok_or_else(|| format!("{n} needs a value"))
        };
        match arg.as_str() {
            "--enforce" => o.enforce = true,
            "--write-baseline" => o.write_baseline = true,
            "--summary" => o.summary = true,
            "--top" => {
                o.top = value("--top")?
                    .to_string_lossy()
                    .parse()
                    .map_err(|_| "--top needs a number".to_owned())?
            }
            "--repo" => {
                let r = value("--repo")?;
                o.tokens = r.join("design/tokens.json");
                o.baseline = r.join("design/lint-baseline.json");
                o.repo = r;
            }
            "--tokens" => o.tokens = value("--tokens")?,
            "--baseline" => o.baseline = value("--baseline")?,
            other => return Err(format!("unknown argument `{other}`")),
        }
    }
    Ok(o)
}

fn line_of(f: &Finding) -> String {
    format!(
        "{}:{}: [{}/{}] {}  ->  {}",
        f.file,
        f.line,
        f.platform.name(),
        f.rule.key(),
        f.text,
        f.hint
    )
}

fn print_summary(findings: &[Finding], top: usize) {
    for p in [Platform::Swift, Platform::Kotlin, Platform::Rust] {
        let of_p: Vec<&Finding> = findings.iter().filter(|f| f.platform == p).collect();
        let parts: Vec<String> = Rule::ALL
            .iter()
            .map(|r| {
                format!(
                    "{}={}",
                    r.key(),
                    of_p.iter().filter(|f| f.rule == *r).count()
                )
            })
            .collect();
        println!(
            "token-lint {:<6} total={} {}",
            p.name(),
            of_p.len(),
            parts.join(" ")
        );
    }
    println!("token-lint total={}", findings.len());
    if top > 0 {
        let mut per_file: BTreeMap<&str, u32> = BTreeMap::new();
        for f in findings {
            *per_file.entry(f.file.as_str()).or_default() += 1;
        }
        let mut v: Vec<_> = per_file.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
        println!("top {top} files:");
        for (file, n) in v.into_iter().take(top) {
            println!("  {n:5}  {file}");
        }
    }
}

fn run(o: &Opts) -> Result<bool> {
    let text = std::fs::read_to_string(&o.tokens)
        .map_err(|e| format!("cannot read {}: {e}", o.tokens.display()))?;
    let root: Value =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", o.tokens.display()))?;
    let tokens = load_tokens(&root)?;
    let findings = scan_repo(&o.repo, &tokens);

    if o.write_baseline {
        let json = serde_json::to_string_pretty(&counts(&findings)).map_err(|e| e.to_string())?;
        std::fs::write(&o.baseline, format!("{json}\n"))
            .map_err(|e| format!("cannot write {}: {e}", o.baseline.display()))?;
        println!(
            "wrote {} ({} findings)",
            o.baseline.display(),
            findings.len()
        );
        print_summary(&findings, o.top);
        return Ok(true);
    }

    if !o.enforce {
        if !o.summary {
            for f in &findings {
                println!("{}", line_of(f));
            }
        }
        print_summary(&findings, o.top);
        println!("token-lint: warn mode, exit 0 (use --enforce to fail on new misuse)");
        return Ok(true);
    }

    let base_text = std::fs::read_to_string(&o.baseline)
        .map_err(|e| format!("cannot read {}: {e}", o.baseline.display()))?;
    let base: Baseline =
        serde_json::from_str(&base_text).map_err(|e| format!("{}: {e}", o.baseline.display()))?;
    let new = beyond(&findings, &base);
    if new.is_empty() {
        println!(
            "token-lint: no new misuse ({} findings, all within the baseline of {})",
            findings.len(),
            base.total
        );
        return Ok(true);
    }
    eprintln!(
        "token-lint: {} NEW misuse beyond design/lint-baseline.json",
        new.len()
    );
    for (f, allowed, now) in &new {
        eprintln!("{}   (baseline {allowed}, now {now})", line_of(f));
    }
    eprintln!(
        "Use the named token, or add `// token-lint: allow <reason>` on the line. \
         Never raise the baseline to make this pass."
    );
    Ok(false)
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    match parse_args(&argv).and_then(|o| run(&o)) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::from(1),
        Err(e) => {
            eprintln!("token_lint: {e}");
            ExitCode::from(2)
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------------------

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    fn tokens() -> Tokens {
        let root: Value = serde_json::from_str(
            r##"{
              "colors": [
                {"name": "surface.base", "dark": "#101010", "light": "#101010"},
                {"name": "border.hairline", "dark": "#FFFFFF", "light": "#FFFFFF", "alpha": 0.07},
                {"name": "surface.hover", "dark": "#FFFFFF", "light": "#FFFFFF", "alpha": 0.06},
                {"name": "state.warning", "dark": "#E8833A", "light": "#E8833A"}
              ],
              "spacing": {"sm": 8, "lg": 16},
              "radius": {"card": 16},
              "layout": [
                {"name": "radius.card", "value": 16, "desktop": 14},
                {"name": "radius.control", "value": 10, "tv": 18},
                {"name": "space.page", "value": 18, "desktop": 36}
              ],
              "type": [{"name": "title.large", "size": 34, "tv": {"size": 56}}]
            }"##,
        )
        .unwrap();
        load_tokens(&root).unwrap()
    }

    fn scan(p: Platform, text: &str) -> Vec<Finding> {
        scan_text(p, "x", text, &tokens())
    }

    fn only(p: Platform, text: &str, rule: Rule) -> String {
        let f = scan(p, text);
        assert_eq!(f.len(), 1, "{f:?}");
        assert_eq!(f[0].rule, rule);
        f[0].hint.clone()
    }

    #[test]
    fn value_maps_to_the_token_name() {
        let t = tokens();
        assert_eq!(t.radius_hint(Some(16.0)), "use radius.card (16)");
        assert_eq!(t.radius_hint(Some(14.0)), "use radius.card (14)");
        assert_eq!(t.spacing_hint(Some(8.0)), "use spacing.sm (8)");
        assert_eq!(t.spacing_hint(Some(36.0)), "use space.page (36)");
        assert_eq!(t.font_hint(Some(56.0)), "use title.large (56)");
        assert_eq!(
            t.colour_hint(Some((0x101010, 1.0))),
            "use surface.base (#101010)"
        );
        assert_eq!(
            t.colour_hint(Some((0xFFFFFF, 0.07))),
            "use border.hairline (#FFFFFF at 7%)"
        );
    }

    #[test]
    fn unknown_value_names_the_family() {
        let t = tokens();
        assert_eq!(
            t.radius_hint(Some(13.0)),
            "use a radius.* token from design/tokens.json"
        );
        assert_eq!(
            t.colour_hint(Some((0x123456, 1.0))),
            "use a color.* token from design/tokens.json"
        );
        assert!(t.colour_hint(None).contains("color.*"));
    }

    #[test]
    fn swift_rules() {
        let h = only(
            Platform::Swift,
            "Color(red: 0.0627, green: 0.0627, blue: 0.0627)",
            Rule::Color,
        );
        assert_eq!(h, "use surface.base (#101010)");
        let h = only(
            Platform::Swift,
            "x.foregroundStyle(Color.white.opacity(0.07))",
            Rule::Color,
        );
        assert_eq!(h, "use border.hairline (#FFFFFF at 7%)");
        only(Platform::Swift, "let c = Color(hex: 0xE8833A)", Rule::Color);
        only(
            Platform::Swift,
            "UIColor(white: 0.5, alpha: 1)",
            Rule::Color,
        );
        let h = only(
            Platform::Swift,
            ".clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))",
            Rule::Radius,
        );
        assert_eq!(h, "use radius.card (16)");
        only(Platform::Swift, "v.cornerRadius(13)", Rule::Radius);
        let h = only(Platform::Swift, "v.padding(.horizontal, 8)", Rule::Spacing);
        assert_eq!(h, "use spacing.sm (8)");
        only(
            Platform::Swift,
            "HStack(alignment: .top, spacing: 14) {",
            Rule::Spacing,
        );
        let h = only(
            Platform::Swift,
            ".font(.system(size: 34, weight: .bold))",
            Rule::Font,
        );
        assert_eq!(h, "use title.large (34)");
        only(
            Platform::Swift,
            ".font(.app(size: 17, weight: .semibold))",
            Rule::Font,
        );
    }

    #[test]
    fn swift_tokens_and_zero_are_clean() {
        let text = "v.padding(0)\nv.padding(Theme.edge)\nColor(\"Accent\")\nVStack(spacing: Theme.gap)\n\
                    RoundedRectangle(cornerRadius: Theme.cornerCard)\nv.foregroundStyle(.white)\n\
                    v.cornerRadius(0)\nlet lineSpacing: 4\n";
        assert!(scan(Platform::Swift, text).is_empty());
    }

    #[test]
    fn kotlin_rules() {
        let h = only(Platform::Kotlin, "val c = Color(0xFFE8833A)", Rule::Color);
        assert_eq!(h, "use state.warning (#E8833A)");
        let h = only(
            Platform::Kotlin,
            "Modifier.background(Color.White.copy(alpha = 0.06f))",
            Rule::Color,
        );
        assert_eq!(h, "use surface.hover (#FFFFFF at 6%)");
        let h = only(
            Platform::Kotlin,
            "clip(smoothRoundedShape(16.dp))",
            Rule::Radius,
        );
        assert_eq!(h, "use radius.card (16)");
        let h = only(
            Platform::Kotlin,
            "Modifier.padding(top = 8.dp)",
            Rule::Spacing,
        );
        assert_eq!(h, "use spacing.sm (8)");
        only(
            Platform::Kotlin,
            "Arrangement.spacedBy(12.dp)",
            Rule::Spacing,
        );
        let h = only(
            Platform::Kotlin,
            "TextStyle(fontSize = 34.sp, color = x)",
            Rule::Font,
        );
        assert_eq!(h, "use title.large (34)");
        let clean = "Modifier.padding(Theme.edge)\nModifier.padding(0.dp)\nColor(Theme.x)\nsmoothRoundedShape(Theme.card)\nclip(RoundedCornerShape(50))\n";
        assert!(scan(Platform::Kotlin, clean).is_empty());
    }

    #[test]
    fn kotlin_shape_rule_wants_the_smoothed_shape() {
        // A token radius in a plain RoundedCornerShape is no radius finding, but it is a shape finding.
        let h = only(
            Platform::Kotlin,
            "clip(RoundedCornerShape(Theme.cornerCard))",
            Rule::Shape,
        );
        assert!(h.contains("smoothRoundedShape"), "{h}");
        // A raw dp radius is both: the token family and the shape.
        let f = scan(Platform::Kotlin, "shape = RoundedCornerShape(16.dp)");
        let rules: Vec<Rule> = f.iter().map(|x| x.rule).collect();
        assert!(
            rules.contains(&Rule::Radius) && rules.contains(&Rule::Shape),
            "{f:?}"
        );
        // Per-corner sheets and the fully qualified name are caught too.
        only(
            Platform::Kotlin,
            "val top = RoundedCornerShape(topStart = Theme.cornerSheet, topEnd = Theme.cornerSheet)",
            Rule::Shape,
        );
        only(
            Platform::Kotlin,
            "shape = androidx.compose.foundation.shape.RoundedCornerShape(liftCorner)",
            Rule::Shape,
        );
        // Capsules and circles stay allowed, in every spelling.
        for ok in [
            "RoundedCornerShape(50)",
            "RoundedCornerShape(50.percent)",
            "RoundedCornerShape(percent = 50)",
            "RoundedCornerShape(CornerSize(50))",
            "smoothRoundedShape(Theme.cornerCard)",
            "CircleShape",
        ] {
            assert!(scan(Platform::Kotlin, ok).is_empty(), "{ok}");
        }
        // The allowed shape still needs a token radius, and a justified exception can be marked.
        only(Platform::Kotlin, "smoothRoundedShape(12.dp)", Rule::Radius);
        let marked = "// token-lint: allow radius of half the side, a capsule by value\nRoundedCornerShape(Theme.cornerCard)\n";
        assert!(scan(Platform::Kotlin, marked).is_empty());
    }

    #[test]
    fn rust_rules() {
        let h = only(
            Platform::Rust,
            "let c = Color::new(0.0627, 0.0627, 0.0627, 1.0);",
            Rule::Color,
        );
        assert_eq!(h, "use surface.base (#101010)");
        only(
            Platform::Rust,
            "static ACCENT: Cell<u32> = Cell::new(0x50D5DA);",
            Rule::Color,
        );
        // The colour a window shows before its first frame is a token too, even with digit separators.
        only(
            Platform::Rust,
            "crate::win_backdrop::set(&window, 0x10_10_10);",
            Rule::Color,
        );
        let h = only(Platform::Rust, "    radius: 16.0,", Rule::Radius);
        assert_eq!(h, "use radius.card (16)");
        let h = only(Platform::Rust, "    gap: 8.0,", Rule::Spacing);
        assert_eq!(h, "use spacing.sm (8)");
        let h = only(
            Platform::Rust,
            "TextStyle { size: 34.0, weight: 700 }",
            Rule::Font,
        );
        assert_eq!(h, "use title.large (34)");
        let multi = scan(Platform::Rust, "let s = TextStyle {\n    size: 15.0,\n};");
        assert_eq!(multi.len(), 1);
        assert_eq!(multi[0].line, 2);
        let clean = "Color::new(r, g, b, 1.0)\nradius: size * 0.23,\nradius: 0.0,\nrgba(colour::REASON, 0.62)\nlet n = Size { size: 4.0 };\n";
        assert!(scan(Platform::Rust, clean).is_empty());
    }

    #[test]
    fn allow_comment_exempts_the_line_or_the_next_one() {
        let text = "v.cornerRadius(13) // token-lint: allow matches the system sheet\n\
                    // token-lint: allow artwork mask\nv.cornerRadius(13)\nv.cornerRadius(13)\n";
        let f = scan(Platform::Swift, text);
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].line, 4);
    }

    #[test]
    fn previews_tests_and_comments_are_skipped() {
        assert!(scan(Platform::Swift, "// v.cornerRadius(13)\n").is_empty());
        let after_preview = "v.cornerRadius(13)\n#Preview {\n    v.cornerRadius(13)\n}\n";
        assert_eq!(scan(Platform::Swift, after_preview).len(), 1);
        let after_test_mod = "radius: 13.0,\n#[cfg(test)]\nmod t { radius: 13.0, }\n";
        assert_eq!(scan(Platform::Rust, after_test_mod).len(), 1);
        assert!(exempt("Sources/Shared/Style.swift"));
        assert!(exempt(
            "Android/phone/src/main/java/de/paulherter/swiftly/tv/TvStyle.kt"
        ));
        assert!(exempt("Sources/Shared/FooTests.swift"));
        assert!(!exempt("Sources/Shared/Picture.swift"));
    }

    fn finding(file: &str, line: usize, rule: Rule) -> Finding {
        Finding {
            platform: Platform::Swift,
            file: file.to_owned(),
            line,
            rule,
            text: String::new(),
            hint: String::new(),
        }
    }

    #[test]
    fn baseline_counts_beyond_and_survives_line_moves() {
        let old = vec![
            finding("a.swift", 10, Rule::Radius),
            finding("a.swift", 20, Rule::Radius),
        ];
        let base = counts(&old);
        assert_eq!(base.total, 2);
        assert_eq!(base.files["a.swift"]["radius"], 2);
        // Same two findings on other lines: nothing new.
        let moved = vec![
            finding("a.swift", 15, Rule::Radius),
            finding("a.swift", 90, Rule::Radius),
        ];
        assert!(beyond(&moved, &base).is_empty());
        // A third one in the same file and rule, one in another rule and another file: all three are new.
        let more = vec![
            finding("a.swift", 15, Rule::Radius),
            finding("a.swift", 40, Rule::Radius),
            finding("a.swift", 90, Rule::Radius),
            finding("a.swift", 91, Rule::Color),
            finding("b.swift", 1, Rule::Radius),
        ];
        let new = beyond(&more, &base);
        assert_eq!(new.len(), 3);
        assert_eq!((new[0].0.line, new[0].1, new[0].2), (90, 2, 3));
        // Fewer findings than the baseline is fine.
        assert!(beyond(&old[..1], &base).is_empty());
    }
}
