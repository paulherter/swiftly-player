//! The language an app starts in comes from the device, and is English when the device names none of ours.

use swiftly_l10n::{Locale, Translator};

fn sign_in(tag: Option<&str>) -> String {
    Translator::new(Locale::for_device(tag)).t("Anmelden")
}

#[test]
fn starts_in_english_with_an_english_system_locale() {
    for tag in ["en-US", "en_US.UTF-8", "en_GB", "en"] {
        assert_eq!(sign_in(Some(tag)), "Sign in", "{tag}");
    }
}

#[test]
fn starts_in_german_with_a_german_system_locale() {
    for tag in ["de-DE", "de_DE.UTF-8", "de_AT@euro", "de"] {
        assert_eq!(sign_in(Some(tag)), "Anmelden", "{tag}");
    }
}

#[test]
fn starts_in_russian_with_a_russian_system_locale() {
    assert_eq!(sign_in(Some("ru-RU")), "Войти");
}

#[test]
fn a_device_that_names_no_language_of_ours_reads_english() {
    // No tag, an empty or broken tag, "C"/"POSIX" (no language), and a language without a catalogue.
    for tag in [
        None,
        Some(""),
        Some("  "),
        Some("C"),
        Some("POSIX"),
        Some("1234"),
        Some("fr-FR"),
        Some("ja_JP.UTF-8"),
    ] {
        assert_eq!(sign_in(tag), "Sign in", "{tag:?}");
    }
}

#[test]
fn the_device_language_sets_the_process_wide_locale() {
    // The one test here that touches the process-wide locale.
    assert_eq!(
        swiftly_l10n::t("Anmelden"),
        "Anmelden",
        "German until an app sets it"
    );
    let started = swiftly_l10n::set_device_locale(Some("en-US"));
    assert_eq!(started.language(), "en");
    assert_eq!(swiftly_l10n::t("Anmelden"), "Sign in");
    swiftly_l10n::set_device_locale(Some("de-DE"));
    assert_eq!(swiftly_l10n::t("Anmelden"), "Anmelden");
    swiftly_l10n::set_device_locale(None);
    assert_eq!(swiftly_l10n::t("Anmelden"), "Sign in");
    swiftly_l10n::set_locale(Locale::default());
}
