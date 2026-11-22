//! The settings pages hold the same sections and rows in every language. A section is found by its German key
//! (`Section::title_key`), the title a screen draws is the translated one: build 52 looked the sections up by the drawn
//! title, so under English the Playback page came out empty. This test lives in its own file because the process-wide
//! language is global state.

use swiftly_desktop::settings_screen::SettingsScreen;
use swiftly_l10n::Locale;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

/// The tests of this file set the process-wide language one after the other.
static ONE_AT_A_TIME: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// The accessibility nodes of one page in the given language (their count does not depend on the wording).
fn nodes(language: &str, page: &str) -> usize {
    swiftly_l10n::set_locale(Locale::parse(language));
    let env = Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop);
    let mut s = SettingsScreen::new(env, Cx::deterministic(), false);
    let _ = s.frame(0.0);
    s.open_page(page);
    let _ = s.frame(400.0);
    s.a11y_nodes().len()
}

#[test]
fn every_page_has_its_sections_in_every_language() {
    let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    for page in ["playback", "presentation", "general"] {
        let german = nodes("de", page);
        assert!(german > 8, "{page}: the German page is empty ({german})");
        for language in ["en", "ru"] {
            assert_eq!(
                nodes(language, page),
                german,
                "{page} in {language} differs from the German page: a section was not found"
            );
        }
    }
}

/// The home rows on the Appearance page carry the catalogue key as their name (`StartRail::lists_name`); the page draws
/// them in the language of the process.
#[test]
fn the_home_rows_are_named_in_the_language_of_the_process() {
    let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    swiftly_l10n::set_locale(Locale::parse("en"));
    let env = Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop);
    let mut s = SettingsScreen::new(env, Cx::deterministic(), false);
    let _ = s.frame(0.0);
    s.open_page("presentation");
    let _ = s.frame(400.0);
    let labels: Vec<String> = s.a11y_nodes().into_iter().map(|n| n.label).collect();
    assert!(
        labels.iter().any(|l| l.contains("Continue watching")),
        "{labels:?}"
    );
    assert!(
        !labels.iter().any(|l| l.contains("Weiterschauen")),
        "{labels:?}"
    );
}
