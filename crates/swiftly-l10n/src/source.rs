//! Parsers for the Apple localisation sources. Used by the generator, the checks and
//! the tests; the runtime lookup does not touch this module.

use crate::catalog::Origin;
use crate::plural::PluralCategory;
use std::collections::BTreeMap;
use std::path::Path;

/// Path of the app catalogue below the repository root.
pub const APP_XCSTRINGS: &str = "Sources/Shared/Localizable.xcstrings";
/// Path of the Info.plist catalogue.
pub const INFO_XCSTRINGS: &str = "Sources/Shared/InfoPlist.xcstrings";
/// Directory holding the package `.lproj` folders.
pub const PACKAGE_RESOURCES: &str = "Packages/JellyfinKit/Sources/JellyfinKit/Resources";
/// The package languages.
pub const PACKAGE_LANGS: [&str; 3] = ["de", "en", "ru"];

/// A parsed value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RawText {
    /// Plain string.
    Simple(String),
    /// Plural variations.
    Plural(BTreeMap<PluralCategory, String>),
}

impl RawText {
    /// The `other` (or only) form.
    pub fn other(&self) -> &str {
        match self {
            Self::Simple(s) => s,
            Self::Plural(m) => m
                .get(&PluralCategory::Other)
                .or_else(|| m.values().next())
                .map_or("", String::as_str),
        }
    }
}

/// One key with all its languages and where it came from.
#[derive(Clone, Debug)]
pub struct RawEntry {
    /// Which sources define it.
    pub origin: Origin,
    /// Language to value.
    pub langs: BTreeMap<String, RawText>,
}

/// A key defined by one source: language to value.
pub type SourceTable = BTreeMap<String, BTreeMap<String, RawText>>;

/// Everything read from the sources.
#[derive(Debug, Default)]
pub struct Parsed {
    /// App xcstrings.
    pub app: SourceTable,
    /// Package `.strings` (stringsdict entries replace plain ones of the same key).
    pub package_strings: SourceTable,
    /// Package `.stringsdict`.
    pub package_dict: SourceTable,
    /// InfoPlist.xcstrings.
    pub info: SourceTable,
    /// Merged table: app first; a plural beats a plain string of the same key.
    pub merged: BTreeMap<String, RawEntry>,
    /// Same key and language in two sources with different text.
    pub conflicts: Vec<String>,
}

/// Number of keys that have a value in `lang` in a source table.
pub fn count(table: &SourceTable, lang: &str) -> usize {
    table.values().filter(|l| l.contains_key(lang)).count()
}

fn plural_unit(map: &serde_json::Value, ctx: &str) -> Result<RawText, String> {
    let mut forms = BTreeMap::new();
    let plural = map
        .get("plural")
        .and_then(|p| p.as_object())
        .ok_or_else(|| format!("{ctx}: variations other than plural are not supported"))?;
    if map.as_object().is_some_and(|o| o.len() != 1) {
        return Err(format!("{ctx}: mixed variation kinds are not supported"));
    }
    for (cat, v) in plural {
        let c = PluralCategory::parse(cat)
            .ok_or_else(|| format!("{ctx}: unknown plural category {cat}"))?;
        let value = v
            .pointer("/stringUnit/value")
            .and_then(|s| s.as_str())
            .ok_or_else(|| format!("{ctx}: plural {cat} without stringUnit"))?;
        forms.insert(c, value.to_owned());
    }
    Ok(RawText::Plural(forms))
}

/// Parses an `.xcstrings` file (JSON).
pub fn parse_xcstrings(json: &str) -> Result<SourceTable, String> {
    let root: serde_json::Value =
        serde_json::from_str(json).map_err(|e| format!("xcstrings: {e}"))?;
    let strings = root
        .get("strings")
        .and_then(|s| s.as_object())
        .ok_or("xcstrings: no `strings`")?;
    let mut table = SourceTable::new();
    for (key, entry) in strings {
        let mut langs = BTreeMap::new();
        if let Some(locs) = entry.get("localizations").and_then(|l| l.as_object()) {
            for (lang, loc) in locs {
                let ctx = format!("{key:?}/{lang}");
                if let Some(v) = loc.pointer("/stringUnit/value").and_then(|v| v.as_str()) {
                    langs.insert(lang.clone(), RawText::Simple(v.to_owned()));
                } else if let Some(var) = loc.get("variations") {
                    langs.insert(lang.clone(), plural_unit(var, &ctx)?);
                } else {
                    return Err(format!("{ctx}: neither stringUnit nor variations"));
                }
            }
        }
        table.insert(key.clone(), langs);
    }
    Ok(table)
}

/// Parses a `.strings` file: `"key" = "value";` with comments and escapes.
pub fn parse_strings(text: &str) -> Result<BTreeMap<String, String>, String> {
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    let mut out = BTreeMap::new();
    let skip = |i: &mut usize| -> Result<(), String> {
        loop {
            while chars.get(*i).is_some_and(|c| c.is_whitespace()) {
                *i += 1;
            }
            if chars.get(*i) == Some(&'/') && chars.get(*i + 1) == Some(&'*') {
                *i += 2;
                while *i + 1 < chars.len() && !(chars[*i] == '*' && chars[*i + 1] == '/') {
                    *i += 1;
                }
                if *i + 1 >= chars.len() {
                    return Err("unterminated comment".into());
                }
                *i += 2;
            } else if chars.get(*i) == Some(&'/') && chars.get(*i + 1) == Some(&'/') {
                while chars.get(*i).is_some_and(|c| *c != '\n') {
                    *i += 1;
                }
            } else {
                return Ok(());
            }
        }
    };
    let quoted = |i: &mut usize| -> Result<String, String> {
        if chars.get(*i) != Some(&'"') {
            return Err(format!("expected quote at char {}", *i));
        }
        *i += 1;
        let mut s = String::new();
        loop {
            match chars.get(*i) {
                None => return Err("unterminated string".into()),
                Some('"') => {
                    *i += 1;
                    return Ok(s);
                }
                Some('\\') => {
                    *i += 1;
                    match chars.get(*i) {
                        Some('n') => s.push('\n'),
                        Some('t') => s.push('\t'),
                        Some('r') => s.push('\r'),
                        Some('U') => {
                            let hex: String =
                                chars[*i + 1..(*i + 5).min(chars.len())].iter().collect();
                            let c = u32::from_str_radix(&hex, 16)
                                .ok()
                                .and_then(char::from_u32)
                                .ok_or("bad \\U escape")?;
                            s.push(c);
                            *i += 4;
                        }
                        Some(c) => s.push(*c),
                        None => return Err("dangling backslash".into()),
                    }
                    *i += 1;
                }
                Some(c) => {
                    s.push(*c);
                    *i += 1;
                }
            }
        }
    };
    loop {
        skip(&mut i)?;
        if i >= chars.len() {
            return Ok(out);
        }
        let key = quoted(&mut i)?;
        skip(&mut i)?;
        if chars.get(i) != Some(&'=') {
            return Err(format!("expected `=` after {key:?}"));
        }
        i += 1;
        skip(&mut i)?;
        let value = quoted(&mut i)?;
        skip(&mut i)?;
        if chars.get(i) != Some(&';') {
            return Err(format!("expected `;` after {key:?}"));
        }
        i += 1;
        out.insert(key, value);
    }
}

#[derive(Debug)]
enum Plist {
    Dict(Vec<(String, Plist)>),
    Str(String),
}

fn unescape_xml(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

struct PlistReader<'a> {
    s: &'a str,
    i: usize,
}

impl PlistReader<'_> {
    fn rest(&self) -> &str {
        &self.s[self.i..]
    }

    fn skip_ws(&mut self) {
        loop {
            let trimmed = self.rest().trim_start();
            self.i = self.s.len() - trimmed.len();
            if self.rest().starts_with("<!--") {
                match self.rest().find("-->") {
                    Some(p) => self.i += p + 3,
                    None => self.i = self.s.len(),
                }
            } else {
                return;
            }
        }
    }

    fn eat(&mut self, tag: &str) -> bool {
        self.skip_ws();
        if self.rest().starts_with(tag) {
            self.i += tag.len();
            true
        } else {
            false
        }
    }

    fn text_until(&mut self, close: &str) -> Result<String, String> {
        let p = self
            .rest()
            .find(close)
            .ok_or_else(|| format!("missing {close}"))?;
        let t = unescape_xml(&self.rest()[..p]);
        self.i += p + close.len();
        Ok(t)
    }

    fn element(&mut self) -> Result<Plist, String> {
        if self.eat("<string/>") {
            return Ok(Plist::Str(String::new()));
        }
        if self.eat("<string>") {
            return Ok(Plist::Str(self.text_until("</string>")?));
        }
        if self.eat("<dict>") {
            let mut items = Vec::new();
            while !self.eat("</dict>") {
                if !self.eat("<key>") {
                    return Err(format!(
                        "expected <key> near {:?}",
                        self.rest().chars().take(30).collect::<String>()
                    ));
                }
                let key = self.text_until("</key>")?;
                items.push((key, self.element()?));
            }
            return Ok(Plist::Dict(items));
        }
        Err(format!(
            "unsupported plist element near {:?}",
            self.rest().chars().take(30).collect::<String>()
        ))
    }
}

/// Parses a `.stringsdict`: every entry must be `%#@var@` with plural categories in
/// `var`; the result maps the key to its plural forms.
pub fn parse_stringsdict(xml: &str) -> Result<BTreeMap<String, RawText>, String> {
    let start = xml.find("<plist").ok_or("no <plist>")?;
    let after = &xml[start..];
    let body = after
        .find('>')
        .map(|p| &after[p + 1..])
        .ok_or("broken <plist>")?;
    let mut reader = PlistReader { s: body, i: 0 };
    let Plist::Dict(entries) = reader.element()? else {
        return Err("root is not a dict".into());
    };
    let mut out = BTreeMap::new();
    for (key, value) in entries {
        let Plist::Dict(fields) = value else {
            return Err(format!("{key:?}: not a dict"));
        };
        let format = fields
            .iter()
            .find_map(|(k, v)| match (k.as_str(), v) {
                ("NSStringLocalizedFormatKey", Plist::Str(s)) => Some(s.clone()),
                _ => None,
            })
            .ok_or_else(|| format!("{key:?}: no NSStringLocalizedFormatKey"))?;
        let var = format
            .strip_prefix("%#@")
            .and_then(|r| r.strip_suffix('@'))
            .ok_or_else(|| format!("{key:?}: format {format:?} is not a single %#@var@"))?;
        let Some(Plist::Dict(forms)) = fields.iter().find(|(k, _)| k == var).map(|(_, v)| v) else {
            return Err(format!("{key:?}: variable {var} missing"));
        };
        let mut map = BTreeMap::new();
        for (k, v) in forms {
            if let (Some(c), Plist::Str(s)) = (PluralCategory::parse(k), v) {
                map.insert(c, s.clone());
            }
        }
        if map.is_empty() {
            return Err(format!("{key:?}: no plural forms"));
        }
        out.insert(key, RawText::Plural(map));
    }
    Ok(out)
}

fn read(root: &Path, rel: &str) -> Result<String, String> {
    std::fs::read_to_string(root.join(rel)).map_err(|e| format!("{rel}: {e}"))
}

fn merge(parsed: &mut Parsed) {
    let sources: [(&SourceTable, Origin); 3] = [
        (&parsed.app, Origin::App),
        (&parsed.package_strings, Origin::Package),
        (&parsed.package_dict, Origin::Package),
    ];
    let mut merged: BTreeMap<String, RawEntry> = BTreeMap::new();
    let mut conflicts = Vec::new();
    for (table, origin) in sources {
        for (key, langs) in table {
            let entry = merged.entry(key.clone()).or_insert_with(|| RawEntry {
                origin,
                langs: BTreeMap::new(),
            });
            if entry.origin != origin {
                entry.origin = Origin::Both;
            }
            for (lang, text) in langs {
                match entry.langs.get(lang) {
                    None => {
                        entry.langs.insert(lang.clone(), text.clone());
                    }
                    Some(old) if old != text => {
                        // Plural variations beat a plain string of the same key: the plain one
                        // would print "1 Filme". Otherwise the earlier source (app) wins.
                        let take_new =
                            matches!(old, RawText::Simple(_)) && matches!(text, RawText::Plural(_));
                        let (kept, dropped) = if take_new { (text, old) } else { (old, text) };
                        conflicts.push(format!(
                            "{key:?} [{lang}]: kept {kept:?}, dropped {dropped:?}"
                        ));
                        if take_new {
                            entry.langs.insert(lang.clone(), text.clone());
                        }
                    }
                    Some(_) => {}
                }
            }
        }
    }
    parsed.merged = merged;
    parsed.conflicts = conflicts;
}

/// Reads all sources below the repository `root` and merges them.
pub fn load(root: &Path) -> Result<Parsed, String> {
    let mut parsed = Parsed {
        app: parse_xcstrings(&read(root, APP_XCSTRINGS)?)?,
        info: parse_xcstrings(&read(root, INFO_XCSTRINGS)?)?,
        ..Parsed::default()
    };
    for lang in PACKAGE_LANGS {
        let dir = format!("{PACKAGE_RESOURCES}/{lang}.lproj");
        let strings = parse_strings(&read(root, &format!("{dir}/Localizable.strings"))?)?;
        for (k, v) in strings {
            parsed
                .package_strings
                .entry(k)
                .or_default()
                .insert(lang.to_owned(), RawText::Simple(v));
        }
        for (k, v) in parse_stringsdict(&read(root, &format!("{dir}/Localizable.stringsdict"))?)? {
            parsed
                .package_dict
                .entry(k)
                .or_default()
                .insert(lang.to_owned(), v);
        }
    }
    // A stringsdict entry replaces a plain string of the same key (as on Apple).
    for (key, langs) in &parsed.package_dict {
        if let Some(plain) = parsed.package_strings.get_mut(key) {
            for lang in langs.keys() {
                plain.remove(lang);
            }
            if plain.is_empty() {
                parsed.package_strings.remove(key);
            }
        }
    }
    merge(&mut parsed);
    Ok(parsed)
}
