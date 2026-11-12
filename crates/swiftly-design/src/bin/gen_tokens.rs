//! Design-token generator.
//!
//! Reads the variables of the design file (`Swiftly Player.isd`, a zip with `document.json`) and the kit snapshot
//! `data/system.json`, and writes `src/tokens.rs` (Rust) and `generated/Tokens.swift` (Swift) with identical values.
//!
//! ```text
//! cargo run -p swiftly-design --bin gen_tokens -- --isd <file.isd> [--system <system.json>] \
//!     [--out-rs <tokens.rs>] [--out-swift <Tokens.swift>] [--out-components <components.tsv>] [--check]
//! ```
//!
//! `--check` regenerates in memory and exits with status 1 when a committed file differs.
//! The input is treated as untrusted data: only two keys of one zip entry are read, nothing is extracted.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use serde::Deserialize;
use serde_json::Value;

/// Upper bound for `document.json` after decompression (the real file is about 58 MB).
const MAX_DOCUMENT_BYTES: u64 = 1 << 30;

type Result<T> = std::result::Result<T, String>;

// ---------------------------------------------------------------------------------------------------------------
// Input: the design file
// ---------------------------------------------------------------------------------------------------------------

#[derive(Deserialize)]
struct Document {
    variables: BTreeMap<String, RawVariable>,
    variable_collections: BTreeMap<String, RawCollection>,
    #[serde(default)]
    nodes: BTreeMap<String, RawNode>,
    #[serde(default)]
    pages: Vec<u64>,
}

/// The few fields of a design node that the component list needs.
#[derive(Deserialize)]
struct RawNode {
    name: String,
    kind: Value,
    #[serde(default)]
    children: Vec<u64>,
}

#[derive(Deserialize)]
struct RawVariable {
    name: String,
    collection: String,
    kind: String,
    values: BTreeMap<String, Value>,
}

#[derive(Deserialize)]
struct RawCollection {
    name: String,
    modes: Vec<RawMode>,
    default_mode: String,
}

#[derive(Deserialize)]
struct RawMode {
    id: String,
}

/// A colour variable: straight RGBA, 0.0 to 1.0.
struct ColourVar {
    name: String,
    rgba: [f32; 4],
}

/// A number variable, `size/<Group>/<name>`.
struct NumberVar {
    group: String,
    name: String,
    value: f32,
}

struct Isd {
    colours: Vec<ColourVar>,
    numbers: Vec<NumberVar>,
    /// Text of `data/components.tsv` (see [`components_tsv`]).
    components: String,
}

fn read_isd(path: &Path) -> Result<Isd> {
    let file = File::open(path).map_err(|e| format!("cannot open {}: {e}", path.display()))?;
    let mut zip = zip::ZipArchive::new(BufReader::new(file))
        .map_err(|e| format!("{} is not a zip file: {e}", path.display()))?;
    let entry = zip
        .by_name("document.json")
        .map_err(|e| format!("no document.json in {}: {e}", path.display()))?;
    if entry.size() > MAX_DOCUMENT_BYTES {
        return Err(format!(
            "document.json is larger than {MAX_DOCUMENT_BYTES} bytes"
        ));
    }
    let doc: Document = serde_json::from_reader(BufReader::new(entry.take(MAX_DOCUMENT_BYTES)))
        .map_err(|e| format!("document.json: {e}"))?;
    let mut isd = parse_document(&doc)?;
    isd.components = components_tsv(&doc);
    Ok(isd)
}

/// Canonical name of a design component family: the first `" / "` segment without spaces and underscores;
/// `TabBar_Filme` is the variant `Filme` of `TabBar`. Returns the name and an optional variant.
fn component_family(first: &str) -> (String, Option<String>) {
    let first = first.trim();
    if let Some((base, rest)) = first.split_once('_')
        && base == "TabBar"
    {
        return (base.to_owned(), Some(rest.to_owned()));
    }
    (
        first.chars().filter(|c| *c != ' ' && *c != '_').collect(),
        None,
    )
}

/// One line per component family of the `Components` page, tab separated:
/// `Family`, platforms (`Mobile`, `Desktop`, `TV`), variants (`;`), sections (`,`), instances on the screen pages.
/// The family is the first segment of the node name; `Desktop` and `TV` segments are platforms, the rest variants.
fn components_tsv(doc: &Document) -> String {
    use std::collections::BTreeSet;
    let node = |id: u64| doc.nodes.get(&id.to_string());
    let Some(page) = doc
        .pages
        .iter()
        .filter_map(|id| node(*id))
        .find(|n| n.name == "Components")
    else {
        return String::new();
    };
    // Everything below the Components page, so instances elsewhere can be told apart.
    let mut inside: BTreeSet<u64> = BTreeSet::new();
    let mut stack: Vec<u64> = page.children.clone();
    while let Some(id) = stack.pop() {
        if inside.insert(id)
            && let Some(n) = node(id)
        {
            stack.extend(n.children.iter().copied());
        }
    }
    let kind_of = |n: &RawNode, key: &str| n.kind.get(key).is_some();
    // Instances per component node id, screens only.
    let mut uses: BTreeMap<u64, usize> = BTreeMap::new();
    for (id, n) in &doc.nodes {
        let Ok(id) = id.parse::<u64>() else { continue };
        if inside.contains(&id) {
            continue;
        }
        if let Some(c) = n
            .kind
            .get("Instance")
            .and_then(|i| i.get("component"))
            .and_then(Value::as_u64)
        {
            *uses.entry(c).or_default() += 1;
        }
    }
    struct Fam {
        platforms: BTreeSet<String>,
        variants: Vec<String>,
        sections: Vec<String>,
        instances: usize,
    }
    let mut fams: Vec<(String, Fam)> = Vec::new();
    let mut section = String::new();
    // Page -> frame(s) -> sections (text nodes named `Section ...`) and rows of component nodes.
    let rows: Vec<&RawNode> = page
        .children
        .iter()
        .filter_map(|id| node(*id))
        .flat_map(|f| f.children.iter().filter_map(|id| node(*id)))
        .collect();
    for row in rows {
        if let Some(rest) = row.name.strip_prefix("Section ") {
            section = rest.to_owned();
            continue;
        }
        for cid in &row.children {
            let Some(c) = node(*cid) else { continue };
            if !kind_of(c, "Component") {
                continue;
            }
            let segs: Vec<&str> = c.name.split(" / ").map(str::trim).collect();
            let (family, extra) = component_family(segs[0]);
            let mut rest: Vec<String> = extra.into_iter().collect();
            rest.extend(segs[1..].iter().map(|s| (*s).to_owned()));
            let platform = rest
                .iter()
                .find(|s| *s == "Desktop" || *s == "TV")
                .cloned()
                .unwrap_or_else(|| "Mobile".to_owned());
            let variant = rest
                .iter()
                .filter(|s| *s != "Desktop" && *s != "TV")
                .cloned()
                .collect::<Vec<_>>()
                .join(" / ");
            let tag = if variant.is_empty() {
                String::new()
            } else if platform == "Mobile" {
                variant
            } else {
                format!("{platform}: {variant}")
            };
            let idx = match fams.iter().position(|(n, _)| *n == family) {
                Some(i) => i,
                None => {
                    fams.push((
                        family,
                        Fam {
                            platforms: BTreeSet::new(),
                            variants: Vec::new(),
                            sections: Vec::new(),
                            instances: 0,
                        },
                    ));
                    fams.len() - 1
                }
            };
            let f = &mut fams[idx].1;
            f.platforms.insert(platform);
            if !tag.is_empty() && !f.variants.contains(&tag) {
                f.variants.push(tag);
            }
            if !f.sections.contains(&section) {
                f.sections.push(section.clone());
            }
            f.instances += uses.get(cid).copied().unwrap_or(0);
        }
    }
    let mut out = String::new();
    for (name, f) in &fams {
        let _ = writeln!(
            out,
            "{name}\t{}\t{}\t{}\t{}",
            f.platforms.iter().cloned().collect::<Vec<_>>().join(","),
            f.variants.join(";"),
            f.sections.join(","),
            f.instances
        );
    }
    out
}

/// Value of a variable in the default mode of its collection. A collection with several modes is rejected on
/// purpose: the real file has one mode per collection, and per-mode layout values would need a decision.
fn default_mode_value<'a>(doc: &'a Document, var: &'a RawVariable) -> Result<&'a Value> {
    let coll = doc
        .variable_collections
        .get(&var.collection)
        .ok_or_else(|| format!("{}: unknown collection {}", var.name, var.collection))?;
    if coll.modes.len() != 1 {
        return Err(format!(
            "collection {} has {} modes; the generator maps layout sets by variable group and supports one mode",
            coll.name,
            coll.modes.len()
        ));
    }
    if !coll.modes.iter().any(|m| m.id == coll.default_mode) {
        return Err(format!(
            "collection {}: default mode is not in modes",
            coll.name
        ));
    }
    if var.values.len() != 1 {
        return Err(format!(
            "{}: expected one mode value, found {}",
            var.name,
            var.values.len()
        ));
    }
    var.values
        .get(&coll.default_mode)
        .ok_or_else(|| format!("{}: no value for the default mode", var.name))
}

fn parse_document(doc: &Document) -> Result<Isd> {
    let mut colours = Vec::new();
    let mut numbers = Vec::new();
    for var in doc.variables.values() {
        let value = default_mode_value(doc, var)?;
        let parts: Vec<&str> = var.name.split('/').collect();
        match (var.kind.as_str(), parts.as_slice()) {
            ("Color", ["colour", name]) => {
                let c = value
                    .get("Color")
                    .ok_or_else(|| format!("{}: not a Color value", var.name))?;
                let ch = |k: &str| -> Result<f32> {
                    let v = c
                        .get(k)
                        .and_then(Value::as_f64)
                        .ok_or_else(|| format!("{}: missing {k}", var.name))?;
                    if !(0.0..=1.0).contains(&v) {
                        return Err(format!("{}: channel {k} = {v} is outside 0..1", var.name));
                    }
                    Ok(v as f32)
                };
                colours.push(ColourVar {
                    name: (*name).to_owned(),
                    rgba: [ch("r")?, ch("g")?, ch("b")?, ch("a")?],
                });
            }
            ("Number", ["size", group, name]) => {
                let v = value
                    .get("Number")
                    .and_then(Value::as_f64)
                    .filter(|v| v.is_finite())
                    .ok_or_else(|| format!("{}: not a finite Number value", var.name))?;
                numbers.push(NumberVar {
                    group: (*group).to_owned(),
                    name: (*name).to_owned(),
                    value: v as f32,
                });
            }
            _ => {
                return Err(format!(
                    "unexpected variable `{}` of kind {}",
                    var.name, var.kind
                ));
            }
        }
    }
    Ok(Isd {
        colours,
        numbers,
        components: String::new(),
    })
}

// ---------------------------------------------------------------------------------------------------------------
// Mapping of variable groups to layout sets
// ---------------------------------------------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum Set {
    Common,
    Touch,
    Desktop,
    Tv,
}

impl Set {
    const ALL: [Set; 4] = [Set::Common, Set::Touch, Set::Desktop, Set::Tv];
    const LAYOUTS: [Set; 3] = [Set::Touch, Set::Desktop, Set::Tv];

    fn module(self) -> &'static str {
        match self {
            Set::Common => "common",
            Set::Touch => "touch",
            Set::Desktop => "desktop",
            Set::Tv => "tv",
        }
    }

    fn swift(self) -> &'static str {
        match self {
            Set::Common => "Common",
            Set::Touch => "Touch",
            Set::Desktop => "Desktop",
            Set::Tv => "Tv",
        }
    }

    fn doc(self) -> &'static str {
        match self {
            Set::Common => "Values that do not differ by layout set.",
            Set::Touch => "Touch layout set (finger on phone or tablet).",
            Set::Desktop => "Desktop layout set (pointer and keyboard in a window).",
            Set::Tv => "TV layout set (remote control, about 3 m).",
        }
    }
}

/// How a `size/<Group>/...` group lands in the output: the set and an optional name prefix. The design file has
/// one mode per collection, so the layout set is only visible in the group name (checked against the values of
/// `system.json`: tile 116x174 / 150x225 / 208x312, page margin 18 / 36, title tracking -0.7 / -0.5 / -1.176).
/// An unknown group is an error so that a new group in the design file is placed on purpose.
fn group_target(group: &str) -> Option<(Set, Option<&'static str>)> {
    Some(match group {
        "JerkKind" | "of" => (Set::Touch, None),
        "BodyShell" => (Set::Desktop, None),
        "PressButton" => (Set::Tv, None),
        "DetailPageMetric" => (Set::Desktop, Some("detail")),
        "PlayerMetric" => (Set::Tv, Some("player")),
        "SearchLayout" => (Set::Tv, Some("search")),
        "HeroRunOut" | "TabStillTimesKey" | "Theme" | "TimeSlider" => {
            (Set::Common, Some(group_prefix(group)))
        }
        _ => return None,
    })
}

fn group_prefix(group: &str) -> &'static str {
    match group {
        "HeroRunOut" => "heroRunOut",
        "TabStillTimesKey" => "tabStillTimesKey",
        "Theme" => "theme",
        _ => "timeSlider",
    }
}

fn mode_target(mode: &str) -> Option<&'static [Set]> {
    match mode {
        "all" => Some(&Set::LAYOUTS),
        "ios" => Some(&[Set::Touch]),
        "macos" => Some(&[Set::Desktop]),
        "tvos" => Some(&[Set::Tv]),
        _ => None,
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------------------------------------------

/// Split `tileWidth` / `TileWidth` into lower-case words.
fn words(s: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut prev_lower = false;
    for ch in s.chars() {
        if ch.is_ascii_uppercase() && prev_lower && !cur.is_empty() {
            out.push(std::mem::take(&mut cur));
        }
        prev_lower = ch.is_ascii_lowercase() || ch.is_ascii_digit();
        cur.push(ch.to_ascii_lowercase());
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

const RUST_KEYWORDS: &[&str] = &[
    "as", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn", "for",
    "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
    "self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where",
    "while", "async", "await", "dyn",
];

const SWIFT_KEYWORDS: &[&str] = &[
    "associatedtype",
    "break",
    "case",
    "catch",
    "class",
    "continue",
    "default",
    "defer",
    "do",
    "else",
    "enum",
    "extension",
    "fallthrough",
    "false",
    "for",
    "func",
    "guard",
    "if",
    "import",
    "in",
    "init",
    "inout",
    "internal",
    "is",
    "let",
    "nil",
    "operator",
    "private",
    "protocol",
    "public",
    "repeat",
    "return",
    "self",
    "static",
    "struct",
    "subscript",
    "super",
    "switch",
    "throw",
    "throws",
    "true",
    "try",
    "typealias",
    "var",
    "where",
    "while",
];

/// A token name as words; renders to `UPPER_SNAKE` (Rust const) or `lowerCamel` (Swift static let).
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Debug)]
struct Ident(Vec<String>);

impl Ident {
    fn new(prefix: Option<&str>, name: &str) -> Ident {
        let mut w = prefix.map(words).unwrap_or_default();
        w.extend(words(name));
        Ident(w)
    }

    fn rust(&self) -> String {
        let s = self.0.join("_").to_ascii_uppercase();
        if RUST_KEYWORDS.contains(&s.to_ascii_lowercase().as_str()) {
            format!("{s}_")
        } else {
            s
        }
    }

    fn swift(&self) -> String {
        let mut s = String::new();
        for (i, w) in self.0.iter().enumerate() {
            if i == 0 {
                s.push_str(w);
            } else {
                let mut cs = w.chars();
                if let Some(first) = cs.next() {
                    s.push(first.to_ascii_uppercase());
                    s.push_str(cs.as_str());
                }
            }
        }
        if SWIFT_KEYWORDS.contains(&s.as_str()) {
            format!("`{s}`")
        } else {
            s
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Model of the output
// ---------------------------------------------------------------------------------------------------------------

#[derive(Clone)]
struct Colour {
    rgba: [f32; 4],
}

impl Colour {
    fn rgba8(&self) -> u32 {
        let c = |v: f32| (v * 255.0).round() as u32;
        (c(self.rgba[0]) << 24) | (c(self.rgba[1]) << 16) | (c(self.rgba[2]) << 8) | c(self.rgba[3])
    }

    fn hex_doc(&self) -> String {
        format!(
            "#{:06X}, alpha {}%",
            self.rgba8() >> 8,
            (self.rgba[3] * 100.0).round()
        )
    }
}

struct Number {
    value: f32,
    source: String,
}

struct Text {
    size: f32,
    weight: u16,
    tracking: f32,
    uppercase: bool,
    source: String,
}

struct Shadow {
    colour: Colour,
    blur: f32,
    y: f32,
    scales: bool,
    source: String,
}

#[derive(Clone, Copy)]
enum Curve {
    Linear(f32),
    EaseOut(f32),
    EaseIn(f32),
    EaseInOut(f32),
    Smooth(f32),
    Snappy(f32),
    Spring { response: f32, damping: f32 },
}

struct Motion {
    curve: Curve,
    source: String,
}

#[derive(Default)]
struct SetData {
    numbers: BTreeMap<Ident, Number>,
    text: BTreeMap<Ident, Text>,
    shadows: BTreeMap<Ident, Shadow>,
    motion: BTreeMap<Ident, Motion>,
}

struct Tokens {
    colours: BTreeMap<Ident, (Colour, String)>,
    sets: BTreeMap<Set, SetData>,
    /// System.json entries that are not machine-readable and therefore not generated: `(path, text)`.
    skipped: Vec<(String, String)>,
    isd_colours: usize,
    isd_numbers: usize,
}

fn insert<V>(map: &mut BTreeMap<Ident, V>, key: Ident, value: V, what: &str) -> Result<()> {
    if map.contains_key(&key) {
        return Err(format!("duplicate token name {} in {what}", key.rust()));
    }
    map.insert(key, value);
    Ok(())
}

fn build(isd: &Isd, system: &Value) -> Result<Tokens> {
    let mut colours = BTreeMap::new();
    for c in &isd.colours {
        insert(
            &mut colours,
            Ident::new(None, &c.name),
            (Colour { rgba: c.rgba }, format!("colour/{}", c.name)),
            "colour",
        )?;
    }
    let mut sets: BTreeMap<Set, SetData> =
        Set::ALL.iter().map(|s| (*s, SetData::default())).collect();
    for n in &isd.numbers {
        let (set, prefix) = group_target(&n.group).ok_or_else(|| {
            format!(
                "size group `{}` is not mapped to a layout set (see group_target in gen_tokens.rs)",
                n.group
            )
        })?;
        let data = sets.get_mut(&set).ok_or("internal: set missing")?;
        insert(
            &mut data.numbers,
            Ident::new(prefix, &n.name),
            Number {
                value: n.value,
                source: format!("size/{}/{}", n.group, n.name),
            },
            set.module(),
        )?;
    }
    let mut skipped = Vec::new();
    read_type(system, &mut sets)?;
    read_motion(system, &mut sets, &mut skipped)?;
    let ground = colours
        .get(&Ident::new(None, "reason"))
        .map(|(c, _)| c.clone())
        .ok_or("colour/reason (ground) is missing; shadows with ground colour need it")?;
    read_shadow(system, &mut sets, &ground, &mut skipped)?;
    Ok(Tokens {
        colours,
        sets,
        skipped,
        isd_colours: isd.colours.len(),
        isd_numbers: isd.numbers.len(),
    })
}

// ---------------------------------------------------------------------------------------------------------------
// Input: system.json (type ladder, motion, shadow)
// ---------------------------------------------------------------------------------------------------------------

fn section<'a>(system: &'a Value, key: &str) -> Result<&'a serde_json::Map<String, Value>> {
    system
        .get(key)
        .and_then(Value::as_object)
        .ok_or_else(|| format!("system.json: `{key}` is missing or not an object"))
}

fn num(v: &Value, what: &str) -> Result<f32> {
    v.as_f64()
        .filter(|x| x.is_finite())
        .map(|x| x as f32)
        .ok_or_else(|| format!("system.json: {what} is not a number"))
}

/// The entries of a token object with `all` first, so that a platform value replaces the shared one.
fn modes_all_first(entry: &serde_json::Map<String, Value>) -> Vec<(&String, &Value)> {
    let mut v: Vec<(&String, &Value)> = entry.iter().collect();
    v.sort_by_key(|(k, _)| k.as_str() != "all");
    v
}

fn read_type(system: &Value, sets: &mut BTreeMap<Set, SetData>) -> Result<()> {
    for (name, entry) in section(system, "type")? {
        let Some(entry) = entry.as_object() else {
            continue;
        };
        for (mode, body) in modes_all_first(entry) {
            let Some(targets) = mode_target(mode) else {
                continue;
            };
            let what = format!("type.{name}.{mode}");
            let size = num(
                body.get("size").ok_or_else(|| format!("{what}: no size"))?,
                &what,
            )?;
            let weight = body
                .get("weight")
                .and_then(Value::as_u64)
                .and_then(|w| u16::try_from(w).ok())
                .ok_or_else(|| format!("{what}: no weight"))?;
            let tracking = match body.get("tracking") {
                Some(t) => num(t, &what)?,
                None => 0.0,
            };
            let uppercase = body.get("case").and_then(Value::as_str) == Some("upper");
            for set in targets {
                let data = sets.get_mut(set).ok_or("internal: set missing")?;
                data.text.insert(
                    Ident::new(None, name),
                    Text {
                        size,
                        weight,
                        tracking,
                        uppercase,
                        source: what.clone(),
                    },
                );
            }
        }
    }
    Ok(())
}

/// `easeOut 0.12`, `smooth 0.25`, `spring response 0.35 damping 0.86`; anything else is not generated.
fn parse_curve(s: &str) -> Option<Curve> {
    let p: Vec<&str> = s.split_whitespace().collect();
    let f = |t: &str| t.parse::<f32>().ok().filter(|v| v.is_finite() && *v >= 0.0);
    match p.as_slice() {
        ["linear", d] => Some(Curve::Linear(f(d)?)),
        ["easeOut", d] => Some(Curve::EaseOut(f(d)?)),
        ["easeIn", d] => Some(Curve::EaseIn(f(d)?)),
        ["easeInOut", d] => Some(Curve::EaseInOut(f(d)?)),
        ["smooth", d] => Some(Curve::Smooth(f(d)?)),
        ["snappy", d] => Some(Curve::Snappy(f(d)?)),
        ["spring", "response", r, "damping", d] => Some(Curve::Spring {
            response: f(r)?,
            damping: f(d)?,
        }),
        _ => None,
    }
}

fn read_motion(
    system: &Value,
    sets: &mut BTreeMap<Set, SetData>,
    skipped: &mut Vec<(String, String)>,
) -> Result<()> {
    for (name, entry) in section(system, "motion")? {
        let Some(entry) = entry.as_object() else {
            continue;
        };
        for (mode, body) in modes_all_first(entry) {
            let (Some(targets), Some(text)) = (mode_target(mode), body.as_str()) else {
                continue;
            };
            let path = format!("motion.{name}.{mode}");
            let Some(curve) = parse_curve(text) else {
                skipped.push((path, text.to_owned()));
                continue;
            };
            for set in targets {
                let data = sets.get_mut(set).ok_or("internal: set missing")?;
                data.motion.insert(
                    Ident::new(None, name),
                    Motion {
                        curve,
                        source: path.clone(),
                    },
                );
            }
        }
    }
    Ok(())
}

/// `black 50%`, `ground 50%`, `black 60% x rest`: base colour, alpha in percent, scaled flag.
fn parse_shadow_colour(s: &str, ground: &Colour) -> Option<(Colour, bool)> {
    let p: Vec<&str> = s.split_whitespace().collect();
    let (base, pct, scaled) = match p.as_slice() {
        [b, pct] => (*b, *pct, false),
        [b, pct, "x", "rest"] => (*b, *pct, true),
        _ => return None,
    };
    let alpha = pct.strip_suffix('%')?.parse::<f32>().ok()? / 100.0;
    let rgb = match base {
        "black" => [0.0, 0.0, 0.0],
        "ground" => [ground.rgba[0], ground.rgba[1], ground.rgba[2]],
        _ => return None,
    };
    Some((
        Colour {
            rgba: [rgb[0], rgb[1], rgb[2], alpha],
        },
        scaled,
    ))
}

/// `9` or `17 x rest`.
fn parse_shadow_length(v: &Value) -> Option<(f32, bool)> {
    if let Some(x) = v.as_f64() {
        return Some((x as f32, false));
    }
    let s = v.as_str()?;
    let p: Vec<&str> = s.split_whitespace().collect();
    match p.as_slice() {
        [n, "x", "rest"] => Some((n.parse().ok()?, true)),
        _ => None,
    }
}

fn read_shadow_body(body: &Value, ground: &Colour) -> Option<Shadow> {
    let (colour, scaled_c) = parse_shadow_colour(body.get("color")?.as_str()?, ground)?;
    let (blur, scaled_b) = parse_shadow_length(body.get("blur")?)?;
    let (y, scaled_y) = parse_shadow_length(body.get("y")?)?;
    Some(Shadow {
        colour,
        blur,
        y,
        scales: scaled_c || scaled_b || scaled_y,
        source: String::new(),
    })
}

fn read_shadow(
    system: &Value,
    sets: &mut BTreeMap<Set, SetData>,
    ground: &Colour,
    skipped: &mut Vec<(String, String)>,
) -> Result<()> {
    for (name, entry) in section(system, "shadow")? {
        let Some(entry) = entry.as_object() else {
            continue;
        };
        // Either a flat shadow (all layout sets) or one body per mode (`lift.tvos`).
        let bodies: Vec<(&'static [Set], String, &Value)> = if entry.contains_key("color") {
            vec![(
                &[Set::Common][..],
                format!("shadow.{name}"),
                &section(system, "shadow")?[name],
            )]
        } else {
            entry
                .iter()
                .filter_map(|(mode, body)| {
                    Some((mode_target(mode)?, format!("shadow.{name}.{mode}"), body))
                })
                .collect()
        };
        for (targets, path, body) in bodies {
            let Some(mut sh) = read_shadow_body(body, ground) else {
                skipped.push((path, body.to_string()));
                continue;
            };
            sh.source = path;
            for set in targets {
                let data = sets.get_mut(set).ok_or("internal: set missing")?;
                insert(
                    &mut data.shadows,
                    Ident::new(None, name),
                    Shadow {
                        colour: sh.colour.clone(),
                        blur: sh.blur,
                        y: sh.y,
                        scales: sh.scales,
                        source: sh.source.clone(),
                    },
                    set.module(),
                )?;
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------------------------
// Output: Rust
// ---------------------------------------------------------------------------------------------------------------

fn f(v: f32) -> String {
    format!("{v:?}")
}

const MODE_EXPLANATION: &[&str] = &[
    "How the layout sets map to the design file:",
    "- The design file has two variable collections, `Color` (31) and `Size` (201), each with ONE mode (`Mode 1`).",
    "  There are no per-mode values; no `Mobile` mode exists.",
    "- The three layout sets are encoded in the name of the size variables: group `JerkKind` (and `of`) is the",
    "  touch set (iPhone values: poster 116x174, page margin 18), `BodyShell` is desktop (Mac: poster 150x225,",
    "  margin 36), `PressButton` is tv (Apple TV: poster 208x312). The mapping was checked against `system.json`.",
    "- Groups that belong to one set but are named by feature are prefixed: `DetailPageMetric` -> desktop `detail_*`,",
    "  `PlayerMetric` -> tv `player_*`, `SearchLayout` -> tv `search_*`.",
    "- `TimeSlider`, `Theme`, `HeroRunOut`, `TabStillTimesKey` have one value for all sets: `common::*`.",
    "- All colours are in `colour` (one value for every set).",
    "- Type ladder, shadows and motion are not variables in the design file; they come from `data/system.json`",
    "  (`ios` -> touch, `macos` -> desktop, `tvos` -> tv, `all` -> every set; shadows without a mode -> common).",
];

fn rust_header(t: &Tokens, out: &mut String) {
    out.push_str(
        "// @generated by `cargo run -p swiftly-design --bin gen_tokens`. Do not edit by hand.\n",
    );
    out.push_str("//! Design tokens, generated.\n//!\n");
    out.push_str("//! Sources: the variables of `App/design/Swiftly Player.isd` (document.json) and `data/system.json`.\n");
    let _ = writeln!(
        out,
        "//! Counts: {} colours and {} sizes from the design file.",
        t.isd_colours, t.isd_numbers
    );
    out.push_str("//!\n");
    for line in MODE_EXPLANATION {
        let _ = writeln!(out, "//! {line}");
    }
    if !t.skipped.is_empty() {
        out.push_str(
            "//!\n//! Entries of `system.json` that are free text and therefore not generated:\n",
        );
        for (path, text) in &t.skipped {
            let _ = writeln!(out, "//! - `{path}`: {}", text.replace('\n', " "));
        }
    }
    out.push('\n');
}

fn rust_colour(c: &Colour) -> String {
    format!(
        "crate::types::Colour {{ r: {}, g: {}, b: {}, a: {}, rgba8: 0x{:08X} }}",
        f(c.rgba[0]),
        f(c.rgba[1]),
        f(c.rgba[2]),
        f(c.rgba[3]),
        c.rgba8()
    )
}

fn rust_curve(c: Curve) -> String {
    match c {
        Curve::Linear(d) => format!("crate::types::Curve::Linear({})", f(d)),
        Curve::EaseOut(d) => format!("crate::types::Curve::EaseOut({})", f(d)),
        Curve::EaseIn(d) => format!("crate::types::Curve::EaseIn({})", f(d)),
        Curve::EaseInOut(d) => format!("crate::types::Curve::EaseInOut({})", f(d)),
        Curve::Smooth(d) => format!("crate::types::Curve::Smooth({})", f(d)),
        Curve::Snappy(d) => format!("crate::types::Curve::Snappy({})", f(d)),
        Curve::Spring { response, damping } => format!(
            "crate::types::Curve::Spring {{ response: {}, damping: {} }}",
            f(response),
            f(damping)
        ),
    }
}

fn render_rust(t: &Tokens) -> String {
    let mut o = String::new();
    rust_header(t, &mut o);
    o.push_str("/// Colours (one value for every layout set).\npub mod colour {\n");
    for (id, (c, src)) in &t.colours {
        let _ = writeln!(o, "    /// `{src}`, {}.", c.hex_doc());
        let _ = writeln!(
            o,
            "    pub const {}: crate::types::Colour = {};",
            id.rust(),
            rust_colour(c)
        );
    }
    o.push_str("}\n");
    for set in Set::ALL {
        let Some(d) = t.sets.get(&set) else { continue };
        let _ = writeln!(o, "\n/// {}\npub mod {} {{", set.doc(), set.module());
        for (id, n) in &d.numbers {
            let _ = writeln!(o, "    /// `{}`.", n.source);
            let _ = writeln!(o, "    pub const {}: f32 = {};", id.rust(), f(n.value));
        }
        if !d.text.is_empty() {
            o.push_str("\n    /// Type ladder (`data/system.json`, `type`).\n    pub mod text {\n");
            for (id, x) in &d.text {
                let _ = writeln!(o, "        /// `{}`.", x.source);
                let _ = writeln!(
                    o,
                    "        pub const {}: crate::types::TextStyle = crate::types::TextStyle {{ size: {}, weight: {}, tracking: {}, uppercase: {} }};",
                    id.rust(),
                    f(x.size),
                    x.weight,
                    f(x.tracking),
                    x.uppercase
                );
            }
            o.push_str("    }\n");
        }
        if !d.shadows.is_empty() {
            o.push_str("\n    /// Shadows (`data/system.json`, `shadow`).\n    pub mod shadow {\n");
            for (id, x) in &d.shadows {
                let _ = writeln!(o, "        /// `{}`.", x.source);
                let _ = writeln!(
                    o,
                    "        pub const {}: crate::types::Shadow = crate::types::Shadow {{ colour: {}, blur: {}, y: {}, scales_with_rest: {} }};",
                    id.rust(),
                    rust_colour(&x.colour),
                    f(x.blur),
                    f(x.y),
                    x.scales
                );
            }
            o.push_str("    }\n");
        }
        if !d.motion.is_empty() {
            o.push_str(
                "\n    /// Motion curves (`data/system.json`, `motion`).\n    pub mod motion {\n",
            );
            for (id, x) in &d.motion {
                let _ = writeln!(o, "        /// `{}`.", x.source);
                let _ = writeln!(
                    o,
                    "        pub const {}: crate::types::Curve = {};",
                    id.rust(),
                    rust_curve(x.curve)
                );
            }
            o.push_str("    }\n");
        }
        o.push_str("}\n");
    }
    o
}

// ---------------------------------------------------------------------------------------------------------------
// Output: Swift
// ---------------------------------------------------------------------------------------------------------------

fn swift_colour(c: &Colour) -> String {
    format!(
        "TokenColour(r: {}, g: {}, b: {}, a: {}, rgba8: 0x{:08X})",
        f(c.rgba[0]),
        f(c.rgba[1]),
        f(c.rgba[2]),
        f(c.rgba[3]),
        c.rgba8()
    )
}

fn swift_curve(c: Curve) -> String {
    match c {
        Curve::Linear(d) => format!(".linear({})", f(d)),
        Curve::EaseOut(d) => format!(".easeOut({})", f(d)),
        Curve::EaseIn(d) => format!(".easeIn({})", f(d)),
        Curve::EaseInOut(d) => format!(".easeInOut({})", f(d)),
        Curve::Smooth(d) => format!(".smooth({})", f(d)),
        Curve::Snappy(d) => format!(".snappy({})", f(d)),
        Curve::Spring { response, damping } => {
            format!(
                ".spring(response: {}, damping: {})",
                f(response),
                f(damping)
            )
        }
    }
}

const SWIFT_TYPES: &str = r"/// A colour in sRGB with straight alpha. `rgba8` is `0xRRGGBBAA`.
public struct TokenColour: Sendable, Equatable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double
    public let rgba8: UInt32
}

/// One step of the type ladder.
public struct TokenTextStyle: Sendable, Equatable {
    public let size: Double
    public let weight: Int
    public let tracking: Double
    public let uppercase: Bool
}

/// A drop shadow; `scalesWithRest` means colour alpha, blur and offset are multiplied by how far the element rests.
public struct TokenShadow: Sendable, Equatable {
    public let colour: TokenColour
    public let blur: Double
    public let y: Double
    public let scalesWithRest: Bool
}

/// An animation curve; durations in seconds.
public enum TokenCurve: Sendable, Equatable {
    case linear(Double)
    case easeOut(Double)
    case easeIn(Double)
    case easeInOut(Double)
    case smooth(Double)
    case snappy(Double)
    case spring(response: Double, damping: Double)
}
";

fn render_swift(t: &Tokens) -> String {
    let mut o = String::new();
    o.push_str("// @generated by `cargo run -p swiftly-design --bin gen_tokens`. Do not edit by hand.\n//\n");
    o.push_str("// Design tokens, same values as crates/swiftly-design/src/tokens.rs.\n//\n");
    let _ = writeln!(
        o,
        "// Counts: {} colours and {} sizes from the design file.\n//",
        t.isd_colours, t.isd_numbers
    );
    for line in MODE_EXPLANATION {
        let _ = writeln!(o, "// {line}");
    }
    if !t.skipped.is_empty() {
        o.push_str(
            "//\n// Entries of system.json that are free text and therefore not generated:\n",
        );
        for (path, text) in &t.skipped {
            let _ = writeln!(o, "// - {path}: {}", text.replace('\n', " "));
        }
    }
    o.push_str("\nimport Foundation\n\n");
    o.push_str(SWIFT_TYPES);
    o.push_str("\n/// Namespace for all design tokens.\npublic enum Tokens {\n");
    o.push_str("    /// Colours (one value for every layout set).\n    public enum Colour {\n");
    for (id, (c, src)) in &t.colours {
        let _ = writeln!(o, "        /// `{src}`, {}.", c.hex_doc());
        let _ = writeln!(
            o,
            "        public static let {} = {}",
            id.swift(),
            swift_colour(c)
        );
    }
    o.push_str("    }\n");
    for set in Set::ALL {
        let Some(d) = t.sets.get(&set) else { continue };
        let _ = writeln!(
            o,
            "\n    /// {}\n    public enum {} {{",
            set.doc(),
            set.swift()
        );
        for (id, n) in &d.numbers {
            let _ = writeln!(o, "        /// `{}`.", n.source);
            let _ = writeln!(
                o,
                "        public static let {}: Double = {}",
                id.swift(),
                f(n.value)
            );
        }
        if !d.text.is_empty() {
            o.push_str("\n        /// Type ladder (data/system.json, type).\n        public enum TextStyles {\n");
            for (id, x) in &d.text {
                let _ = writeln!(o, "            /// `{}`.", x.source);
                let _ = writeln!(
                    o,
                    "            public static let {} = TokenTextStyle(size: {}, weight: {}, tracking: {}, uppercase: {})",
                    id.swift(),
                    f(x.size),
                    x.weight,
                    f(x.tracking),
                    x.uppercase
                );
            }
            o.push_str("        }\n");
        }
        if !d.shadows.is_empty() {
            o.push_str("\n        /// Shadows (data/system.json, shadow).\n        public enum Shadows {\n");
            for (id, x) in &d.shadows {
                let _ = writeln!(o, "            /// `{}`.", x.source);
                let _ = writeln!(
                    o,
                    "            public static let {} = TokenShadow(colour: {}, blur: {}, y: {}, scalesWithRest: {})",
                    id.swift(),
                    swift_colour(&x.colour),
                    f(x.blur),
                    f(x.y),
                    x.scales
                );
            }
            o.push_str("        }\n");
        }
        if !d.motion.is_empty() {
            o.push_str("\n        /// Motion curves (data/system.json, motion).\n        public enum Curves {\n");
            for (id, x) in &d.motion {
                let _ = writeln!(o, "            /// `{}`.", x.source);
                let _ = writeln!(
                    o,
                    "            public static let {}: TokenCurve = {}",
                    id.swift(),
                    swift_curve(x.curve)
                );
            }
            o.push_str("        }\n");
        }
        o.push_str("    }\n");
    }
    o.push_str("}\n");
    o
}

// ---------------------------------------------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------------------------------------------

struct Args {
    isd: PathBuf,
    system: PathBuf,
    out_rs: PathBuf,
    out_swift: PathBuf,
    out_components: PathBuf,
    check: bool,
}

fn parse_args(argv: &[String]) -> Result<Args> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let mut isd = std::env::var_os("SWIFTLY_ISD").map(PathBuf::from);
    let mut system = root.join("data/system.json");
    let mut out_rs = root.join("src/tokens.rs");
    let mut out_swift = root.join("generated/Tokens.swift");
    let mut out_components = root.join("data/components.tsv");
    let mut check = false;
    let mut it = argv.iter();
    while let Some(a) = it.next() {
        let mut value = |name: &str| -> Result<PathBuf> {
            it.next()
                .map(PathBuf::from)
                .ok_or_else(|| format!("{name} needs a value"))
        };
        match a.as_str() {
            "--isd" => isd = Some(value("--isd")?),
            "--system" => system = value("--system")?,
            "--out-rs" => out_rs = value("--out-rs")?,
            "--out-swift" => out_swift = value("--out-swift")?,
            "--out-components" => out_components = value("--out-components")?,
            "--check" => check = true,
            "-h" | "--help" => return Err(USAGE.to_owned()),
            other => return Err(format!("unknown argument `{other}`\n{USAGE}")),
        }
    }
    let isd =
        isd.ok_or_else(|| format!("--isd <file> is required (or env SWIFTLY_ISD)\n{USAGE}"))?;
    Ok(Args {
        isd,
        system,
        out_rs,
        out_swift,
        out_components,
        check,
    })
}

const USAGE: &str = "usage: gen_tokens --isd <Swiftly Player.isd> [--system <system.json>] [--out-rs <tokens.rs>] \
[--out-swift <Tokens.swift>] [--check]";

fn generate(isd_path: &Path, system_path: &Path) -> Result<(String, String, String, Tokens)> {
    let isd = read_isd(isd_path)?;
    let system_text = std::fs::read_to_string(system_path)
        .map_err(|e| format!("cannot read {}: {e}", system_path.display()))?;
    let system: Value = serde_json::from_str(&system_text)
        .map_err(|e| format!("{}: {e}", system_path.display()))?;
    let tokens = build(&isd, &system)?;
    Ok((
        render_rust(&tokens),
        render_swift(&tokens),
        isd.components,
        tokens,
    ))
}

fn run() -> Result<bool> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let args = parse_args(&argv)?;
    let (rs, swift, components, tokens) = generate(&args.isd, &args.system)?;
    if args.check {
        let mut ok = true;
        for (path, fresh) in [
            (&args.out_rs, &rs),
            (&args.out_swift, &swift),
            (&args.out_components, &components),
        ] {
            match std::fs::read_to_string(path) {
                Ok(old) if old == *fresh => {}
                Ok(_) => {
                    eprintln!("out of date: {}", path.display());
                    ok = false;
                }
                Err(e) => {
                    eprintln!("cannot read {}: {e}", path.display());
                    ok = false;
                }
            }
        }
        if ok {
            println!("tokens up to date");
        } else {
            eprintln!("run: cargo run -p swiftly-design --bin gen_tokens -- --isd <file.isd>");
        }
        return Ok(ok);
    }
    for (path, text) in [
        (&args.out_rs, &rs),
        (&args.out_swift, &swift),
        (&args.out_components, &components),
    ] {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        std::fs::write(path, text).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    }
    let count = |f: fn(&SetData) -> usize| tokens.sets.values().map(f).sum::<usize>();
    println!(
        "wrote {} and {}: {} colours, {} sizes, {} text styles, {} shadows, {} motion curves",
        args.out_rs.display(),
        args.out_swift.display(),
        tokens.colours.len(),
        count(|d| d.numbers.len()),
        count(|d| d.text.len()),
        count(|d| d.shadows.len()),
        count(|d| d.motion.len()),
    );
    Ok(true)
}

fn main() -> ExitCode {
    match run() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("gen_tokens: {e}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_camel_case() {
        assert_eq!(words("tileWidth"), ["tile", "width"]);
        assert_eq!(words("BodyShell"), ["body", "shell"]);
        assert_eq!(words("of"), ["of"]);
    }

    #[test]
    fn renders_names() {
        let id = Ident::new(Some("player"), "buttonSpacing");
        assert_eq!(id.rust(), "PLAYER_BUTTON_SPACING");
        assert_eq!(id.swift(), "playerButtonSpacing");
        assert_eq!(Ident::new(None, "default").swift(), "`default`");
    }

    #[test]
    fn rounds_hex() {
        let c = Colour {
            rgba: [0.14901961, 0.14901961, 0.14901961, 1.0],
        };
        assert_eq!(c.rgba8(), 0x262626FF);
        let t = Colour {
            rgba: [1.0, 1.0, 1.0, 0.07058824],
        };
        assert_eq!(t.rgba8(), 0xFFFFFF12);
    }

    #[test]
    fn parses_curves() {
        assert!(matches!(
            parse_curve("easeOut 0.12"),
            Some(Curve::EaseOut(_))
        ));
        assert!(matches!(
            parse_curve("spring response 0.35 damping 0.86"),
            Some(Curve::Spring { .. })
        ));
        assert!(parse_curve("none on press, easeOut 0.12 on release").is_none());
        assert!(parse_curve("0.15").is_none());
    }

    #[test]
    fn parses_shadows() {
        let ground = Colour {
            rgba: [0.0627451, 0.0627451, 0.0627451, 1.0],
        };
        let (c, scaled) = parse_shadow_colour("black 60% x rest", &ground).unwrap();
        assert!(scaled && (c.rgba[3] - 0.6).abs() < 1e-6);
        let (g, _) = parse_shadow_colour("ground 50%", &ground).unwrap();
        assert_eq!(g.rgba8() >> 8, 0x101010);
        assert!(parse_shadow_colour("red 50%", &ground).is_none());
        assert_eq!(
            parse_shadow_length(&Value::String("17 x rest".into())),
            Some((17.0, true))
        );
        assert_eq!(
            parse_shadow_length(&serde_json::json!(9)),
            Some((9.0, false))
        );
    }

    #[test]
    fn unknown_group_is_an_error() {
        let isd = Isd {
            colours: vec![ColourVar {
                name: "reason".into(),
                rgba: [0.0, 0.0, 0.0, 1.0],
            }],
            numbers: vec![NumberVar {
                group: "Nope".into(),
                name: "x".into(),
                value: 1.0,
            }],
            components: String::new(),
        };
        let system = serde_json::json!({"type": {}, "motion": {}, "shadow": {}});
        assert!(build(&isd, &system).is_err());
    }
}
