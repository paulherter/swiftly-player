//! The static catalogue and the lookup over it.

use crate::format::{self, Arg};
use crate::locale::Locale;
use crate::plural::{self, PluralCategory};

/// Where an entry came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    /// `Sources/Shared/Localizable.xcstrings` only.
    App,
    /// JellyfinKit `.lproj` (`Localizable.strings` / `.stringsdict`) only.
    Package,
    /// Both; the app value wins, see `NOTES.md` for differing ones.
    Both,
}

/// A translation: one text, or one text per plural category.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Text {
    /// Plain string.
    Simple(&'static str),
    /// Plural variations by CLDR category.
    Plural(&'static [(PluralCategory, &'static str)]),
}

impl Text {
    /// The text for a category; if the language did not translate it, `other`, then `one`,
    /// then whatever exists.
    pub fn form(&self, category: PluralCategory) -> &'static str {
        match self {
            Self::Simple(s) => s,
            Self::Plural(forms) => {
                let find = |c: PluralCategory| forms.iter().find(|(k, _)| *k == c).map(|(_, s)| *s);
                find(category)
                    .or_else(|| find(PluralCategory::Other))
                    .or_else(|| find(PluralCategory::One))
                    .or_else(|| forms.first().map(|(_, s)| *s))
                    .unwrap_or("")
            }
        }
    }

    /// The `other` form (the plain text for `Simple`).
    pub fn other(&self) -> &'static str {
        self.form(PluralCategory::Other)
    }

    /// Whether this is a plural variation set.
    pub fn is_plural(&self) -> bool {
        matches!(self, Self::Plural(_))
    }
}

/// One key with its translations.
#[derive(Debug)]
pub struct Entry {
    /// The German wording.
    pub key: &'static str,
    /// Which source it came from.
    pub origin: Origin,
    /// `(language, text)` pairs, sorted by language.
    pub langs: &'static [(&'static str, Text)],
}

impl Entry {
    /// The text for a language, if translated.
    pub fn text(&self, lang: &str) -> Option<&'static Text> {
        self.langs.iter().find(|(l, _)| *l == lang).map(|(_, t)| t)
    }
}

/// Number of keys one source file holds for one language.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SourceStat {
    /// File name of the source.
    pub source: &'static str,
    /// Language code.
    pub lang: &'static str,
    /// Number of keys with a value in this language.
    pub keys: usize,
}

/// How a lookup ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Resolution {
    /// Found in the requested language.
    Exact,
    /// The key exists but not in the requested language; this language was used instead.
    Fallback(&'static str),
    /// The key is not in the catalogue; the key itself (the German wording) is used.
    Missing,
}

/// The result of resolving a key for a locale.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Lookup {
    /// The text, `None` when the key is missing.
    pub text: Option<&'static Text>,
    /// The language the text is in (decides the plural rule).
    pub lang: &'static str,
    /// How it was found.
    pub resolution: Resolution,
}

/// The error of the strict lookups.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MissingKey(pub String);

impl std::fmt::Display for MissingKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "key not in catalog: {:?}", self.0)
    }
}

impl std::error::Error for MissingKey {}

/// A sorted table of entries.
#[derive(Debug)]
pub struct Catalog {
    entries: &'static [Entry],
    info_plist: &'static [Entry],
    stats: &'static [SourceStat],
}

impl Catalog {
    /// Builds a catalogue over sorted static data (the generated file).
    pub const fn new(
        entries: &'static [Entry],
        info_plist: &'static [Entry],
        stats: &'static [SourceStat],
    ) -> Self {
        Self {
            entries,
            info_plist,
            stats,
        }
    }

    /// The catalogue generated from the Apple sources.
    pub fn builtin() -> &'static Self {
        &crate::catalog_data::CATALOG
    }

    /// All entries, sorted by key.
    pub fn entries(&self) -> &'static [Entry] {
        self.entries
    }

    /// The `InfoPlist.xcstrings` entries (keys like `CFBundleDisplayName`).
    pub fn info_plist(&self) -> &'static [Entry] {
        self.info_plist
    }

    /// Per-source key counts recorded by the generator.
    pub fn stats(&self) -> &'static [SourceStat] {
        self.stats
    }

    /// The entry for a key.
    pub fn get(&self, key: &str) -> Option<&'static Entry> {
        self.entries
            .binary_search_by(|e| e.key.cmp(key))
            .ok()
            .map(|i| &self.entries[i])
    }

    /// Number of keys that have a value in `lang`.
    pub fn key_count(&self, lang: &str) -> usize {
        self.entries
            .iter()
            .filter(|e| e.text(lang).is_some())
            .count()
    }

    /// The languages that occur in the catalogue, sorted.
    pub fn languages(&self) -> Vec<&'static str> {
        let mut langs: Vec<&'static str> = self
            .entries
            .iter()
            .flat_map(|e| e.langs.iter().map(|(l, _)| *l))
            .collect();
        langs.sort_unstable();
        langs.dedup();
        langs
    }

    /// Resolves a key: own language, then English, then German; a key that is not in
    /// the catalogue yields `Resolution::Missing`. Never panics.
    pub fn lookup(&self, locale: &Locale, key: &str) -> Lookup {
        let Some(entry) = self.get(key) else {
            return Lookup {
                text: None,
                lang: Locale::SOURCE_LANGUAGE,
                resolution: Resolution::Missing,
            };
        };
        for (i, lang) in locale.fallback_chain().into_iter().enumerate() {
            if let Some((l, text)) = entry.langs.iter().find(|(l, _)| *l == lang) {
                let resolution = if i == 0 {
                    Resolution::Exact
                } else {
                    Resolution::Fallback(l)
                };
                return Lookup {
                    text: Some(text),
                    lang: l,
                    resolution,
                };
            }
        }
        match entry.langs.first() {
            Some((l, text)) => Lookup {
                text: Some(text),
                lang: l,
                resolution: Resolution::Fallback(l),
            },
            None => Lookup {
                text: None,
                lang: Locale::SOURCE_LANGUAGE,
                resolution: Resolution::Missing,
            },
        }
    }

    /// Translates a key without arguments. A missing key returns the key itself.
    pub fn t(&self, locale: &Locale, key: &str) -> String {
        self.t_args(locale, key, &[])
    }

    /// Translates and fills placeholders. A missing key is formatted as if it were its
    /// own German text.
    pub fn t_args(&self, locale: &Locale, key: &str, args: &[Arg]) -> String {
        let l = self.lookup(locale, key);
        format::render(l.text.map_or(key, |t| t.other()), args)
    }

    /// Strict variant of [`Catalog::t_args`]: a missing key is an error.
    pub fn try_t_args(
        &self,
        locale: &Locale,
        key: &str,
        args: &[Arg],
    ) -> Result<String, MissingKey> {
        match self.lookup(locale, key).text {
            Some(text) => Ok(format::render(text.other(), args)),
            None => Err(MissingKey(key.to_owned())),
        }
    }

    /// Translates a counted phrase. The category of `n` is chosen with the plural rule of
    /// the language the text is actually in. **`n` is argument 1**; `args` follow as
    /// arguments 2 and up (so `plural("%lld Folgen", 3, &[])` gives "3 Folgen").
    pub fn plural(&self, locale: &Locale, key: &str, n: i64, args: &[Arg]) -> String {
        let l = self.lookup(locale, key);
        let mut all = Vec::with_capacity(args.len() + 1);
        all.push(Arg::Int(n));
        all.extend_from_slice(args);
        let lang_tag = if l.lang == locale.language() {
            locale.tag()
        } else {
            l.lang.to_owned()
        };
        match l.text {
            Some(text) => format::render(text.form(plural::category(&lang_tag, n)), &all),
            None => format::render(key, &all),
        }
    }

    /// Strict variant of [`Catalog::plural`].
    pub fn try_plural(
        &self,
        locale: &Locale,
        key: &str,
        n: i64,
        args: &[Arg],
    ) -> Result<String, MissingKey> {
        if self.get(key).is_none() {
            return Err(MissingKey(key.to_owned()));
        }
        Ok(self.plural(locale, key, n, args))
    }
}
