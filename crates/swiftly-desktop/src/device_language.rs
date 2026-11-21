//! The language of the device, for the start language rule (`track_rule`): which audio and subtitle track a title
//! starts with when the settings name none. The player asks it once per start; the core turns the tag into a language.
//!
//! Linux reads the locale variables in the order of POSIX (`LC_ALL`, `LC_MESSAGES`, `LANG`; `LANGUAGE` first, a list),
//! Windows the display languages of the user (`GetUserPreferredUILanguages`), not the regional format. "C" and
//! "POSIX" name no language: they give `None`, not English.
#![allow(unsafe_code)]

/// The first language of the device as a tag (`de-DE`, `de_DE.UTF-8`), `None` when it names none.
#[must_use]
pub fn device_language() -> Option<String> {
    imp::device_language()
}

/// Starts the process in the language of the device: the process-wide locale (`swiftly_l10n::set_locale`) every text of the
/// app reads becomes the device's language, English when the device names none of ours. Called once, first thing in `main`;
/// the German default of the l10n core is the key language of the catalogue, not a start language.
pub fn start_in_device_language() -> swiftly_l10n::Locale {
    swiftly_l10n::set_device_locale(device_language().as_deref())
}

/// The first language the variables name, `get` being the environment. Pure, so it is tested without one.
#[cfg_attr(windows, allow(dead_code))]
fn from_variables(get: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    let usable = |tag: &str| -> Option<String> {
        let tag = tag.trim();
        // `de_DE.UTF-8@euro` -> `de_DE`
        let tag = tag.split(['.', '@']).next().unwrap_or("");
        let language = tag.split(['_', '-']).next().unwrap_or("");
        let named = language.len() >= 2 && language.chars().all(|c| c.is_ascii_alphabetic());
        (named && !tag.eq_ignore_ascii_case("c") && !tag.eq_ignore_ascii_case("posix"))
            .then(|| tag.to_owned())
    };
    // GNU's `LANGUAGE` is a colon list and counts only where the locale itself is not "C".
    let locale = ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .filter_map(|k| get(k))
        .find(|v| !v.trim().is_empty());
    if let Some(l) = &locale
        && usable(l).is_none()
    {
        return None;
    }
    get("LANGUAGE")
        .and_then(|list| list.split(':').find_map(usable))
        .or_else(|| locale.as_deref().and_then(usable))
}

#[cfg(unix)]
mod imp {
    pub fn device_language() -> Option<String> {
        super::from_variables(&|key| std::env::var(key).ok())
    }
}

#[cfg(windows)]
mod imp {
    pub fn device_language() -> Option<String> {
        use windows_sys::Win32::Globalization::{GetUserPreferredUILanguages, MUI_LANGUAGE_NAME};
        let (mut count, mut length) = (0u32, 0u32);
        // SAFETY: a null buffer asks only for the length; both counters outlive the call.
        let asked = unsafe {
            GetUserPreferredUILanguages(
                MUI_LANGUAGE_NAME,
                &mut count,
                std::ptr::null_mut(),
                &mut length,
            )
        };
        if asked == 0 || length == 0 {
            return None;
        }
        let mut buffer = vec![0u16; length as usize];
        // SAFETY: `buffer` holds `length` UTF-16 units, as the first call said; the counters outlive the call.
        let filled = unsafe {
            GetUserPreferredUILanguages(
                MUI_LANGUAGE_NAME,
                &mut count,
                buffer.as_mut_ptr(),
                &mut length,
            )
        };
        if filled == 0 {
            return None;
        }
        // A list of NUL-terminated names; the first is the one the user ranks highest.
        let first: Vec<u16> = buffer.iter().copied().take_while(|c| *c != 0).collect();
        let tag = String::from_utf16_lossy(&first);
        (!tag.is_empty()).then_some(tag)
    }
}

#[cfg(test)]
mod tests {
    use super::from_variables;

    fn env(pairs: &[(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        let pairs = pairs.to_vec();
        move |key: &str| {
            pairs
                .iter()
                .find(|(k, _)| *k == key)
                .map(|(_, v)| (*v).to_owned())
        }
    }

    #[test]
    fn reads_the_locale_variables_in_the_posix_order() {
        assert_eq!(
            from_variables(&env(&[("LANG", "de_DE.UTF-8")])).as_deref(),
            Some("de_DE")
        );
        assert_eq!(
            from_variables(&env(&[("LANG", "en_US.UTF-8"), ("LC_ALL", "de_AT.UTF-8")])).as_deref(),
            Some("de_AT")
        );
        assert_eq!(
            from_variables(&env(&[
                ("LANG", "en_US.UTF-8"),
                ("LC_MESSAGES", "fr_FR@euro")
            ]))
            .as_deref(),
            Some("fr_FR")
        );
    }

    #[test]
    fn the_language_list_wins_where_the_locale_names_a_language() {
        assert_eq!(
            from_variables(&env(&[("LANG", "en_US.UTF-8"), ("LANGUAGE", "de:en")])).as_deref(),
            Some("de")
        );
    }

    /// The start language of the app: what the device's variables say, English when they name none.
    fn start_text(pairs: &[(&'static str, &'static str)]) -> String {
        let locale = swiftly_l10n::Locale::for_device(from_variables(&env(pairs)).as_deref());
        swiftly_l10n::Translator::new(locale).t("Anmelden")
    }

    #[test]
    fn starts_in_english_with_an_english_system_locale() {
        assert_eq!(start_text(&[("LANG", "en_US.UTF-8")]), "Sign in");
        assert_eq!(
            start_text(&[("LANG", "de_DE.UTF-8"), ("LANGUAGE", "en_US:de")]),
            "Sign in"
        );
        assert_eq!(start_text(&[("LC_ALL", "en_GB.UTF-8")]), "Sign in");
    }

    #[test]
    fn starts_in_german_with_a_german_system_locale() {
        assert_eq!(start_text(&[("LANG", "de_DE.UTF-8")]), "Anmelden");
        assert_eq!(
            start_text(&[("LANG", "en_US.UTF-8"), ("LC_ALL", "de_AT.UTF-8")]),
            "Anmelden"
        );
    }

    #[test]
    fn a_device_without_a_language_starts_in_english() {
        assert_eq!(start_text(&[]), "Sign in");
        assert_eq!(start_text(&[("LANG", "C.UTF-8")]), "Sign in");
        assert_eq!(start_text(&[("LANG", "POSIX")]), "Sign in");
    }

    #[test]
    fn c_and_posix_name_no_language() {
        assert_eq!(from_variables(&env(&[("LANG", "C")])), None);
        assert_eq!(from_variables(&env(&[("LANG", "C.UTF-8")])), None);
        assert_eq!(
            from_variables(&env(&[("LC_ALL", "POSIX"), ("LANG", "de_DE.UTF-8")])),
            None
        );
        // `LANGUAGE` counts only where the locale is not "C".
        assert_eq!(
            from_variables(&env(&[("LANG", "C"), ("LANGUAGE", "de")])),
            None
        );
        assert_eq!(from_variables(&env(&[])), None);
        assert_eq!(from_variables(&env(&[("LANG", "")])), None);
    }
}
