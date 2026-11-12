//! Consistency checks over the catalogue. Violations are reported, never hidden.

use crate::catalog::{Catalog, Text};
use crate::format::{self, ArgClass};
use crate::plural::{self, PluralCategory};

/// A problem found in the translations.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Finding {
    /// A language uses different placeholders than German.
    Placeholders {
        /// The key.
        key: &'static str,
        /// The language that differs.
        lang: &'static str,
        /// German signature `(position, class)`.
        de: Vec<(usize, ArgClass)>,
        /// The other language's signature.
        other: Vec<(usize, ArgClass)>,
    },
    /// German has plural forms but the language has a plain string, or the reverse.
    Shape {
        /// The key.
        key: &'static str,
        /// The language that differs.
        lang: &'static str,
        /// Whether German is the plural one.
        de_is_plural: bool,
    },
    /// A plural translation lacks categories the language needs.
    MissingCategories {
        /// The key.
        key: &'static str,
        /// The language.
        lang: &'static str,
        /// What is missing.
        missing: Vec<PluralCategory>,
    },
}

impl std::fmt::Display for Finding {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Placeholders {
                key,
                lang,
                de,
                other,
            } => {
                write!(f, "placeholders {key:?} [{lang}]: de {de:?} vs {other:?}")
            }
            Self::Shape {
                key,
                lang,
                de_is_plural,
            } => {
                write!(
                    f,
                    "shape {key:?} [{lang}]: de is {}, {lang} is not",
                    if *de_is_plural { "plural" } else { "plain" }
                )
            }
            Self::MissingCategories { key, lang, missing } => {
                let names: Vec<_> = missing.iter().map(|c| c.as_str()).collect();
                write!(
                    f,
                    "categories {key:?} [{lang}]: missing {}",
                    names.join(",")
                )
            }
        }
    }
}

/// Runs all checks over the catalogue.
pub fn findings(catalog: &Catalog) -> Vec<Finding> {
    let mut out = Vec::new();
    for e in catalog.entries() {
        let Some(de) = e.text("de") else { continue };
        let de_sig = format::signature(de.other());
        for (lang, t) in e.langs {
            if *lang != "de" {
                let sig = format::signature(t.other());
                if sig != de_sig {
                    out.push(Finding::Placeholders {
                        key: e.key,
                        lang,
                        de: de_sig.clone(),
                        other: sig,
                    });
                }
                if de.is_plural() != t.is_plural() {
                    out.push(Finding::Shape {
                        key: e.key,
                        lang,
                        de_is_plural: de.is_plural(),
                    });
                }
            }
            if let Text::Plural(forms) = t {
                let missing: Vec<_> = plural::categories(lang)
                    .iter()
                    .copied()
                    .filter(|c| !forms.iter().any(|(k, _)| k == c))
                    .collect();
                if !missing.is_empty() {
                    out.push(Finding::MissingCategories {
                        key: e.key,
                        lang,
                        missing,
                    });
                }
            }
        }
    }
    out
}
