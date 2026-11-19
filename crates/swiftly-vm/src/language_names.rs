//! Names of languages for track lists (`TrackLabel.language`, `MediaStream.languageName`).
//!
//! Swift asks the system (`Locale.localizedString(forLanguageCode:)`), so a German app says "Deutsch" and an
//! English one "German" for the same `ger` track. The core cannot ask the system, so the host may install a
//! [`NameSource`] (Apple: `Locale`, Android: `java.util.Locale`); without one, or when it answers `None`, the
//! built-in table answers: ISO 639-1/639-2 names in the app languages (de, en, ru), taken from the same CLDR
//! data the Apple system uses (`Tools/LanguageData/generate.swift`). Other interface languages get English.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock};

use swiftly_l10n::{Locale, Translator};
use swiftly_playback::track_label::LabelText;

use crate::language_data::NAMES;

/// The host's own language names.
pub trait NameSource: Send + Sync {
    /// The name of the language `code` (an ISO 639-1/-2 code or a tag such as `pt-br`, lower case) in the
    /// interface language `language` (`de`, `en`, `ru` ...), `None` if the host does not know it.
    fn name(&self, code: &str, language: &str) -> Option<String>;
    /// Whether the host knows the code at all (English probe, `TrackLabel.code(of:)`).
    fn knows(&self, code: &str) -> bool;
}

static HOST: RwLock<Option<Arc<dyn NameSource>>> = RwLock::new(None);

/// What the host answered, kept: a name depends only on the code and the interface language, and a track panel
/// is rebuilt after every clock event, so asking the host (a system call per name, on the main thread) each time
/// made a long film a long loop of identical questions. Cleared when the host's names change; bounded, since the
/// codes come from the server.
#[derive(Default)]
struct Answers {
    names: HashMap<(String, String), Option<String>>,
    knows: HashMap<String, bool>,
}

const ANSWERS_LIMIT: usize = 512;

static ANSWERS: Mutex<Option<Answers>> = Mutex::new(None);
/// How many times the host was really asked (a test reads it).
static HOST_CALLS: AtomicUsize = AtomicUsize::new(0);

/// How many questions reached the host's [`NameSource`] since the process started.
pub fn host_calls() -> usize {
    HOST_CALLS.load(Ordering::Relaxed)
}

fn answers() -> std::sync::MutexGuard<'static, Option<Answers>> {
    ANSWERS.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Installs (or, with `None`, removes) the host's language names for the whole process.
pub fn set_name_source(source: Option<Arc<dyn NameSource>>) {
    *HOST.write().unwrap_or_else(PoisonError::into_inner) = source;
    *answers() = None;
}

fn host() -> Option<Arc<dyn NameSource>> {
    HOST.read().unwrap_or_else(PoisonError::into_inner).clone()
}

/// The primary subtag, lower case: `pt-BR` is Portuguese (Foundation ignores the rest).
fn primary(code: &str) -> String {
    code.split(['-', '_']).next().unwrap_or("").to_lowercase()
}

fn row(code: &str) -> Option<&'static (&'static str, &'static str, &'static str, &'static str)> {
    let key = primary(code);
    NAMES
        .binary_search_by(|r| r.0.cmp(key.as_str()))
        .ok()
        .map(|i| &NAMES[i])
}

/// The built-in table alone: the name of `code` in `language`, `None` if CLDR has none.
pub fn table_name(code: &str, language: &str) -> Option<String> {
    let r = row(code)?;
    let name = match language {
        "de" => r.1,
        "ru" => r.3,
        _ => r.2,
    };
    (!name.is_empty()).then(|| name.to_owned())
}

/// The built-in table alone: whether English CLDR names the code.
pub fn table_knows(code: &str) -> bool {
    row(code).is_some_and(|r| !r.2.is_empty())
}

/// The name of a language code in the interface language: the host first, then the table.
pub fn language_name(code: &str, language: &str) -> Option<String> {
    let Some(h) = host() else {
        return table_name(code, language);
    };
    let key = (code.to_owned(), language.to_owned());
    if let Some(known) = answers().as_ref().and_then(|a| a.names.get(&key).cloned()) {
        return known;
    }
    // The host is asked without the lock: it may call back into the core.
    HOST_CALLS.fetch_add(1, Ordering::Relaxed);
    let name = h
        .name(code, language)
        .or_else(|| table_name(code, language));
    let mut guard = answers();
    let a = guard.get_or_insert_with(Answers::default);
    if a.names.len() >= ANSWERS_LIMIT {
        a.names.clear();
    }
    a.names.insert(key, name.clone());
    name
}

/// Whether the (English) system knows the code.
pub fn knows_code(code: &str) -> bool {
    let Some(h) = host() else {
        return table_knows(code);
    };
    if let Some(known) = answers().as_ref().and_then(|a| a.knows.get(code).copied()) {
        return known;
    }
    HOST_CALLS.fetch_add(1, Ordering::Relaxed);
    let known = h.knows(code) || table_knows(code);
    let mut guard = answers();
    let a = guard.get_or_insert_with(Answers::default);
    if a.knows.len() >= ANSWERS_LIMIT {
        a.knows.clear();
    }
    a.knows.insert(code.to_owned(), known);
    known
}

/// The interface-language text the track label rules need (`LabelText`): language names as above, the
/// catalog words in the language of the locale.
#[derive(Clone)]
pub struct LabelWords {
    translator: Arc<Translator>,
}

impl LabelWords {
    /// Words of the interface language `locale`.
    pub fn new(locale: Locale) -> Self {
        Self {
            translator: Arc::new(Translator::new(locale)),
        }
    }
}

impl LabelText for LabelWords {
    fn language_name(&self, code: &str) -> Option<String> {
        language_name(code, self.translator.locale().language())
    }
    fn knows_code(&self, code: &str) -> bool {
        knows_code(code)
    }
    fn unknown(&self) -> String {
        self.translator.t_package("unbekannt")
    }
    fn forced(&self) -> String {
        self.translator.t_package("Erzwungen")
    }
    fn hearing_impaired(&self) -> String {
        self.translator.t_package("Hörgeschädigt")
    }
    fn file(&self) -> String {
        self.translator.t_package("Datei")
    }
    fn original_suffix(&self) -> String {
        self.translator.t_package("(Original)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_is_sorted_and_named_in_every_language() {
        assert!(NAMES.windows(2).all(|w| w[0].0 < w[1].0));
        assert_eq!(table_name("ger", "de").as_deref(), Some("Deutsch"));
        assert_eq!(table_name("ger", "en").as_deref(), Some("German"));
        assert_eq!(table_name("DE-at", "ru").as_deref(), Some("немецкий"));
        assert_eq!(table_name("fr", "xx").as_deref(), Some("French"));
        assert_eq!(table_name("qaa", "en"), None);
        assert!(table_knows("fre") && !table_knows("qaa"));
    }

    /// A host that names only one made-up code (so tests running next to it keep seeing the table).
    struct Host;
    impl NameSource for Host {
        fn name(&self, code: &str, language: &str) -> Option<String> {
            (code == "xqx").then(|| format!("Xqx in {language}"))
        }
        fn knows(&self, code: &str) -> bool {
            code == "xqx"
        }
    }

    #[test]
    fn the_host_answers_first_and_the_table_when_it_has_nothing() {
        set_name_source(Some(Arc::new(Host)));
        assert_eq!(language_name("xqx", "en").as_deref(), Some("Xqx in en"));
        assert!(knows_code("xqx"));
        // The host has no answer: the built-in table.
        assert_eq!(language_name("ger", "en").as_deref(), Some("German"));
        let words = LabelWords::new(Locale::parse("ru"));
        assert_eq!(
            swiftly_playback::track_label::language(Some("xqx"), &words).as_deref(),
            Some("Xqx in ru")
        );
        set_name_source(None);
        assert_eq!(language_name("xqx", "en"), None);
        assert!(!knows_code("xqx"));
    }

    #[test]
    fn labels_follow_the_interface_language() {
        let en = LabelWords::new(Locale::parse("en"));
        assert_eq!(
            swiftly_playback::track_label::language(Some("ger"), &en).as_deref(),
            Some("German")
        );
        assert_eq!(
            swiftly_playback::track_label::language(Some("rus"), &en).as_deref(),
            Some("Russian")
        );
        let ru = LabelWords::new(Locale::parse("ru"));
        assert_eq!(
            swiftly_playback::track_label::language(Some("ger"), &ru).as_deref(),
            Some("Немецкий")
        );
        assert_eq!(
            swiftly_playback::track_label::language(Some("qaa"), &ru).as_deref(),
            Some("QAA")
        );
        assert_eq!(
            swiftly_playback::track_label::language(Some("und"), &ru).as_deref(),
            Some("Неизвестно")
        );
    }
}
