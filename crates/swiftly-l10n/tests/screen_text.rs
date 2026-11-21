//! `tr`: a fixed screen text of the source in the process-wide language (the desktop screens draw their texts with it).

use swiftly_l10n::{Locale, set_device_locale, set_locale, tr};

#[test]
fn tr_follows_the_process_language() {
    // One test owns the process-wide locale of this binary.
    set_locale(Locale::default());
    assert_eq!(
        tr("Was läuft bei dir?"),
        "Was läuft bei dir?",
        "German is the key language"
    );

    set_locale(Locale::parse("en"));
    assert_eq!(tr("Was läuft bei dir?"), "What do you run?");
    assert_eq!(
        tr("kein solcher Schlüssel im Katalog"),
        "kein solcher Schlüssel im Katalog"
    );

    // The start language of a device that names English, and one that names a language the app has no text for.
    set_device_locale(Some("en_US.UTF-8"));
    assert_eq!(tr("Was läuft bei dir?"), "What do you run?");
    set_device_locale(Some("de_DE.UTF-8"));
    assert_eq!(tr("Was läuft bei dir?"), "Was läuft bei dir?");
    set_device_locale(Some("xx_XX"));
    assert_eq!(
        tr("Was läuft bei dir?"),
        "What do you run?",
        "an unknown language starts in English"
    );
    set_locale(Locale::default());
}
