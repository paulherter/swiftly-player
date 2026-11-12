//! Localisation for Swiftly. **German wording is the key**, exactly as with Swift's
//! `String(localized:)`. The catalogue in `catalog_data.rs` is generated from the Apple
//! sources (`cargo run -p swiftly-l10n --bin gen_catalog`, `--check` in CI) so
//! `Localizable.xcstrings` stays the single source of truth.
//!
//! ```
//! use swiftly_l10n::{Locale, Translator};
//! let ru = Translator::new(Locale::parse("ru"));
//! assert_eq!(ru.plural("%lld Folgen", 5, &[]), "5 эпизодов");
//! ```

pub mod catalog;
#[rustfmt::skip]
mod catalog_data;
pub mod check;
pub mod codegen;
pub mod error_text;
pub mod format;
pub mod locale;
pub mod plural;
pub mod source;
pub mod update;
pub mod version_number;
pub mod whats_new;

pub use catalog::{Catalog, Entry, Lookup, MissingKey, Origin, Resolution, Text};
pub use format::Arg;
pub use locale::Locale;
pub use plural::PluralCategory;

use std::sync::RwLock;

/// Package wording that differs from the merged catalogue's (app) wording: `(key, language, text)`. A test compares it
/// with `Localizable.strings` of the package, so it cannot go stale.
pub const PACKAGE_WORDING: [(&str, &str, &str); 1] = [("Normal", "ru", "Обычная")];

/// A catalogue bound to a locale.
#[derive(Clone, Debug)]
pub struct Translator {
    locale: Locale,
    catalog: &'static Catalog,
}

impl Translator {
    /// A translator over the built-in catalogue.
    pub fn new(locale: Locale) -> Self {
        Self {
            locale,
            catalog: Catalog::builtin(),
        }
    }

    /// The locale in use.
    pub fn locale(&self) -> &Locale {
        &self.locale
    }

    /// How the key resolves; use it to report missing keys.
    pub fn lookup(&self, key: &str) -> Lookup {
        self.catalog.lookup(&self.locale, key)
    }

    /// Translates a key. A missing key returns the key (its German wording).
    pub fn t(&self, key: &str) -> String {
        self.catalog.t(&self.locale, key)
    }

    /// Translates a key the way the JellyfinKit package (`translated(...)`, the `.lproj` files) shows it.
    /// The merged catalogue keeps the app wording where app and package disagree on one key; the package wording
    /// differs today only for "Normal" in Russian (buffer level, feminine "Обычная", against the subtitle size,
    /// masculine "Обычный"). See [`PACKAGE_WORDING`].
    pub fn t_package(&self, key: &str) -> String {
        let lang = self.catalog.lookup(&self.locale, key).lang;
        PACKAGE_WORDING
            .iter()
            .find(|(k, l, _)| *k == key && *l == lang)
            .map_or_else(|| self.t(key), |(_, _, text)| (*text).to_owned())
    }

    /// Translates and substitutes `%@`/`%lld`/`%1$@` placeholders from `args`.
    pub fn t_args(&self, key: &str, args: &[Arg]) -> String {
        self.catalog.t_args(&self.locale, key, args)
    }

    /// Like [`Translator::t_args`] but a missing key is an error.
    pub fn try_t_args(&self, key: &str, args: &[Arg]) -> Result<String, MissingKey> {
        self.catalog.try_t_args(&self.locale, key, args)
    }

    /// Counted phrase; `n` selects the CLDR category and is argument 1, `args` are 2 and up.
    pub fn plural(&self, key: &str, n: i64, args: &[Arg]) -> String {
        self.catalog.plural(&self.locale, key, n, args)
    }

    /// Like [`Translator::plural`] but a missing key is an error.
    pub fn try_plural(&self, key: &str, n: i64, args: &[Arg]) -> Result<String, MissingKey> {
        self.catalog.try_plural(&self.locale, key, n, args)
    }
}

static CURRENT: RwLock<Option<Locale>> = RwLock::new(None);

/// Sets the process-wide locale used by the free functions [`t`], [`t_args`], [`plural`].
pub fn set_locale(locale: Locale) {
    let mut guard = CURRENT
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    *guard = Some(locale);
}

/// The process-wide locale; German until set.
pub fn current_locale() -> Locale {
    CURRENT
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
        .unwrap_or_default()
}

/// Translates with the process-wide locale.
pub fn t(key: &str) -> String {
    Translator::new(current_locale()).t(key)
}

/// Translates with arguments using the process-wide locale.
pub fn t_args(key: &str, args: &[Arg]) -> String {
    Translator::new(current_locale()).t_args(key, args)
}

/// Counted phrase with the process-wide locale.
pub fn plural(key: &str, n: i64, args: &[Arg]) -> String {
    Translator::new(current_locale()).plural(key, n, args)
}
