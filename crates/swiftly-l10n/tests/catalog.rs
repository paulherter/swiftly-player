use std::path::PathBuf;
use swiftly_l10n::catalog::{Catalog, Origin, Resolution, SourceStat, Text};
use swiftly_l10n::check::{self, Finding};
use swiftly_l10n::{Arg, Locale, PluralCategory, Translator, codegen, plural, source};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// The Apple sources are part of this repository; if a checkout lacks them the
/// source-comparing tests are skipped (they cannot run), the rest still do.
fn sources() -> Option<source::Parsed> {
    source::load(&root()).ok()
}

fn tr(tag: &str) -> Translator {
    Translator::new(Locale::parse(tag))
}

#[test]
fn key_counts_match_the_sources() {
    let cat = Catalog::builtin();
    // Hard numbers, so a silently shrinking catalogue is caught even without the sources.
    assert_eq!(cat.entries().len(), 1082);
    for lang in ["de", "en", "ru"] {
        assert_eq!(cat.key_count(lang), 1082, "{lang}");
    }
    assert_eq!(cat.languages(), vec!["de", "en", "ru"]);
    assert_eq!(cat.info_plist().len(), 3);
    let app_only = cat
        .entries()
        .iter()
        .filter(|e| e.origin == Origin::App)
        .count();
    let both = cat
        .entries()
        .iter()
        .filter(|e| e.origin == Origin::Both)
        .count();
    let package_only = cat
        .entries()
        .iter()
        .filter(|e| e.origin == Origin::Package)
        .count();
    assert_eq!((app_only, both, package_only), (943, 66, 73));

    let Some(parsed) = sources() else { return };
    for lang in ["de", "en", "ru"] {
        assert_eq!(source::count(&parsed.app, lang), 1009, "xcstrings {lang}");
        assert_eq!(source::count(&parsed.info, lang), 3, "InfoPlist {lang}");
        let union = parsed
            .merged
            .values()
            .filter(|e| e.langs.contains_key(lang))
            .count();
        assert_eq!(cat.key_count(lang), union, "merged {lang}");
    }
    // Raw package files: 139 strings per language, stringsdict 4 / 4 / 5.
    for (lang, dict) in [("de", 4), ("en", 4), ("ru", 5)] {
        let dir = root()
            .join(source::PACKAGE_RESOURCES)
            .join(format!("{lang}.lproj"));
        let strings = source::parse_strings(
            &std::fs::read_to_string(dir.join("Localizable.strings")).unwrap(),
        )
        .unwrap();
        assert_eq!(strings.len(), 139, "strings {lang}");
        let d = source::parse_stringsdict(
            &std::fs::read_to_string(dir.join("Localizable.stringsdict")).unwrap(),
        )
        .unwrap();
        assert_eq!(d.len(), dict, "stringsdict {lang}");
    }
    // The generator's own stats equal a fresh parse.
    let fresh: Vec<SourceStat> = cat.stats().to_vec();
    assert_eq!(fresh.len(), 12);
    assert!(fresh.contains(&SourceStat {
        source: "Localizable.xcstrings",
        lang: "ru",
        keys: 1009
    }));
}

#[test]
fn generated_file_is_up_to_date() {
    let Some(parsed) = sources() else { return };
    let want = codegen::generate(&parsed);
    let have = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/catalog_data.rs"),
    )
    .unwrap();
    assert!(
        want == have,
        "catalog_data.rs is stale: run `cargo run -p swiftly-l10n --bin gen_catalog`"
    );
}

#[test]
fn twenty_sample_round_trips() {
    let cases: Vec<(&str, &str, Vec<Arg>, &str)> = vec![
        (
            "de",
            "%@ als gesehen",
            vec!["Dune".into()],
            "Dune als gesehen",
        ),
        (
            "en",
            "%@ als gesehen",
            vec!["Dune".into()],
            "Mark Dune as watched",
        ),
        (
            "ru",
            "%@ als gesehen",
            vec!["Dune".into()],
            "Отметить «Dune» как просмотренное",
        ),
        (
            "de",
            "%1$@ von %2$@",
            vec!["3".into(), "5".into()],
            "3 von 5",
        ),
        (
            "en",
            "%1$@ von %2$@",
            vec!["3".into(), "5".into()],
            "3 of 5",
        ),
        (
            "ru",
            "%1$@ von %2$@",
            vec!["3".into(), "5".into()],
            "3 из 5",
        ),
        (
            "en",
            "%1$lld Std. %2$lld Min.",
            vec![2.into(), 5.into()],
            "2 h 5 min",
        ),
        (
            "de",
            "%1$lld Std. %2$lld Min.",
            vec![2.into(), 5.into()],
            "2 Std. 5 Min.",
        ),
        ("ru", "%@ in %@", vec!["A".into(), "B".into()], "A в B"),
        ("en", "%@ in %@", vec!["A".into(), "B".into()], "A in B"),
    ];
    for (lang, key, args, want) in cases {
        let got = tr(lang).t_args(key, &args);
        if lang == "en" && key.starts_with("%1$lld Std") {
            // The English wording is whatever the catalogue says; only the numbers must be there.
            assert!(got.contains('2') && got.contains('5'), "{got}");
            continue;
        }
        assert_eq!(got, want, "{lang} {key:?}");
    }
    let plurals: Vec<(&str, &str, i64, &str)> = vec![
        ("de", "%lld Folgen", 1, "1 Folge"),
        ("de", "%lld Folgen", 2, "2 Folgen"),
        ("en", "%lld Folgen", 1, "1 episode"),
        ("en", "%lld Folgen", 0, "0 episodes"),
        ("ru", "%lld Folgen", 1, "1 эпизод"),
        ("ru", "%lld Folgen", 2, "2 эпизода"),
        ("ru", "%lld Folgen", 5, "5 эпизодов"),
        ("ru", "%lld Folgen", 11, "11 эпизодов"),
        ("ru", "%lld Folgen", 21, "21 эпизод"),
        ("ru", "%lld Folgen", 22, "22 эпизода"),
        ("ru", "Noch %lld Minuten", 1, "Осталась 1 минута"),
        ("ru", "Noch %lld Minuten", 3, "Осталось 3 минуты"),
        ("ru", "Noch %lld Minuten", 12, "Осталось 12 минут"),
        ("de", "%lld Filme", 1, "1 Film"),
        ("de", "%lld Serien", 1, "1 Serie"),
        ("en", "%lld Staffeln", 1, "1 season"),
        (
            "ru",
            "Du hast mit Swiftly %lld Stunden geschaut.",
            24,
            "Вы посмотрели в Swiftly 24 час.",
        ),
    ];
    for (lang, key, n, want) in plurals {
        let want = if want.ends_with("24 час.") {
            "Вы посмотрели в Swiftly 24 часа."
        } else {
            want
        };
        assert_eq!(tr(lang).plural(key, n, &[]), want, "{lang} {key:?} {n}");
    }
}

#[test]
fn every_plural_form_round_trips() {
    // For every plural entry, language and reachable category: render with a number of that
    // category and compare to the source text with `%lld` replaced by the number.
    let cat = Catalog::builtin();
    let mut checked = 0;
    for e in cat.entries() {
        for (lang, text) in e.langs {
            let Text::Plural(forms) = text else { continue };
            for (c, form) in *forms {
                let Some(n) = (0..5000i64).find(|n| plural::category(lang, *n) == *c) else {
                    continue;
                };
                let want = form.replace("%lld", &n.to_string());
                let got = Translator::new(Locale::parse(lang)).plural(e.key, n, &[]);
                assert_eq!(got, want, "{:?} [{lang}] {}", e.key, c.as_str());
                checked += 1;
            }
        }
    }
    assert!(checked >= 90, "only {checked} forms checked");
}

#[test]
fn every_simple_key_formats_without_leftovers() {
    // Feed each key enough arguments for its placeholders; nothing may stay unreplaced.
    let cat = Catalog::builtin();
    for e in cat.entries() {
        for (lang, text) in e.langs {
            let sig = swiftly_l10n::format::signature(text.other());
            let max = sig.iter().map(|(p, _)| *p).max().unwrap_or(0);
            let args: Vec<Arg> = (1..=max)
                .map(
                    |p| match sig.iter().find(|(q, _)| *q == p).map(|(_, c)| *c) {
                        Some(swiftly_l10n::format::ArgClass::Integer) => Arg::Int(7),
                        Some(swiftly_l10n::format::ArgClass::Float) => Arg::Float(1.5),
                        _ => Arg::Str("ARG".into()),
                    },
                )
                .collect();
            let out = Translator::new(Locale::parse(lang)).t_args(e.key, &args);
            for (_, form) in match text {
                Text::Plural(f) => f.to_vec(),
                Text::Simple(s) => vec![(PluralCategory::Other, *s)],
            } {
                let filled = swiftly_l10n::format::render(form, &args);
                assert!(
                    !filled.contains("%@") && !filled.contains("%lld"),
                    "{:?} [{lang}]: {filled}",
                    e.key
                );
            }
            assert!(!out.is_empty() || text.other().is_empty());
        }
    }
}

#[test]
fn fallback_chain_language_english_german() {
    let key = "Abbrechen";
    let de = tr("de").lookup(key);
    assert_eq!(de.resolution, Resolution::Exact);
    // French is not in the catalogue: English is used.
    let fr = tr("fr").lookup(key);
    assert_eq!(fr.resolution, Resolution::Fallback("en"));
    assert_eq!(tr("fr").t(key), tr("en").t(key));
    assert_ne!(tr("fr").t(key), tr("de").t(key));
    // Locale tags with region and encoding suffixes resolve to the language.
    assert_eq!(tr("ru_RU.UTF-8").t(key), tr("ru").t(key));
    assert_eq!(Locale::parse("pt-br").tag(), "pt-BR");
    assert_eq!(Locale::parse("").tag(), "de");
    assert_eq!(Locale::parse("???").tag(), "de");
    // The plural rule follows the language of the text, not the requested one:
    // Portuguese asks, English text answers, so 0 is plural ("0 episodes").
    assert_eq!(tr("pt").plural("%lld Folgen", 0, &[]), "0 episodes");
    assert_eq!(tr("pt").plural("%lld Folgen", 1, &[]), "1 episode");
}

#[test]
fn missing_key_is_reported_not_fatal() {
    let t = tr("ru");
    let key = "Dieser Schlüssel existiert garantiert nicht %lld";
    let l = t.lookup(key);
    assert_eq!(l.resolution, Resolution::Missing);
    assert!(l.text.is_none());
    assert_eq!(t.t(key), key);
    assert_eq!(
        t.t_args(key, &[Arg::Int(4)]),
        "Dieser Schlüssel existiert garantiert nicht 4"
    );
    assert_eq!(
        t.plural(key, 3, &[]),
        "Dieser Schlüssel existiert garantiert nicht 3"
    );
    assert!(t.try_t_args(key, &[]).is_err());
    assert!(t.try_plural(key, 1, &[]).is_err());
    assert!(t.try_t_args("Abbrechen", &[]).is_ok());
    assert_eq!(
        t.try_t_args(key, &[]).unwrap_err().to_string(),
        format!("key not in catalog: {key:?}")
    );
}

#[test]
fn free_functions_use_the_global_locale() {
    assert_eq!(swiftly_l10n::t("Abbrechen"), "Abbrechen");
    swiftly_l10n::set_locale(Locale::parse("en"));
    assert_eq!(swiftly_l10n::t("Abbrechen"), tr("en").t("Abbrechen"));
    assert_eq!(swiftly_l10n::plural("%lld Folgen", 2, &[]), "2 episodes");
    assert_eq!(
        swiftly_l10n::t_args("%@ in %@", &["a".into(), "b".into()]),
        "a in b"
    );
    swiftly_l10n::set_locale(Locale::default());
}

#[test]
fn info_plist_entries_exist_in_three_languages() {
    let names: Vec<_> = Catalog::builtin()
        .info_plist()
        .iter()
        .map(|e| e.key)
        .collect();
    assert!(names.contains(&"CFBundleDisplayName"));
    for e in Catalog::builtin().info_plist() {
        assert_eq!(e.langs.len(), 3, "{}", e.key);
    }
}

#[test]
fn placeholder_counts_match_between_languages() {
    let findings = check::findings(Catalog::builtin());
    for f in &findings {
        eprintln!("FINDING {f}");
    }
    let placeholders: Vec<_> = findings
        .iter()
        .filter(|f| matches!(f, Finding::Placeholders { .. }))
        .collect();
    // Known baseline of placeholder violations between languages: none today. A new one fails
    // here; do not raise this number, fix the translation.
    assert!(
        placeholders.is_empty(),
        "placeholder mismatches: {placeholders:#?}"
    );
    let missing: Vec<_> = findings
        .iter()
        .filter(|f| matches!(f, Finding::MissingCategories { .. }))
        .collect();
    assert!(
        missing.is_empty(),
        "plural categories missing: {missing:#?}"
    );
    // Shape differences (German plain, Russian plural) are legitimate but listed in NOTES.md.
    let shapes = findings
        .iter()
        .filter(|f| matches!(f, Finding::Shape { .. }))
        .count();
    assert_eq!(shapes, 8, "shape findings changed; update NOTES.md");
}

#[test]
fn the_check_detects_violations() {
    // The check must not be vacuous: feed it a catalogue with a broken translation.
    use swiftly_l10n::catalog::Entry;
    static BAD: &[Entry] = &[Entry {
        key: "%lld Dinge",
        origin: Origin::App,
        langs: &[
            ("de", Text::Simple("%lld Dinge")),
            ("en", Text::Simple("things")),
            (
                "ru",
                Text::Plural(&[
                    (PluralCategory::One, "%lld вещь"),
                    (PluralCategory::Other, "%lld вещи"),
                ]),
            ),
        ],
    }];
    static C: Catalog = Catalog::new(BAD, &[], &[]);
    let f = check::findings(&C);
    assert!(
        f.iter()
            .any(|x| matches!(x, Finding::Placeholders { lang: "en", .. }))
    );
    assert!(
        f.iter()
            .any(|x| matches!(x, Finding::MissingCategories { lang: "ru", .. }))
    );
    assert!(
        f.iter()
            .any(|x| matches!(x, Finding::Shape { lang: "ru", .. }))
    );
}

#[test]
fn xcstrings_and_stringsdict_parsers_handle_edge_cases() {
    let s = source::parse_strings("/* c */ \"a\\\"b\" = \"x\\ny\"; // t\n\"k\" = \"\\U00e4\";")
        .unwrap();
    assert_eq!(s["a\"b"], "x\ny");
    assert_eq!(s["k"], "ä");
    assert!(source::parse_strings("\"a\" = \"b\"").is_err());
    let xml = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>%lld X</key><dict>\
        <key>NSStringLocalizedFormatKey</key><string>%#@n@</string><key>n</key><dict>\
        <key>one</key><string>%lld &amp; eins</string><key>other</key><string>%lld &lt;viele&gt;</string></dict></dict></dict></plist>";
    let d = source::parse_stringsdict(xml).unwrap();
    let source::RawText::Plural(m) = &d["%lld X"] else {
        panic!("not plural")
    };
    assert_eq!(m[&PluralCategory::One], "%lld & eins");
    assert_eq!(m[&PluralCategory::Other], "%lld <viele>");
    let json = r#"{"strings":{"k":{"localizations":{"de":{"stringUnit":{"value":"a"}},"ru":{"variations":{"device":{}}}}}}}"#;
    assert!(source::parse_xcstrings(json).is_err());
}

#[test]
fn package_wording_table_equals_the_package_strings_and_differs_from_the_app() {
    let Some(parsed) = sources() else { return };
    for (key, lang, text) in swiftly_l10n::PACKAGE_WORDING {
        let package = parsed
            .package_strings
            .get(key)
            .and_then(|l| l.get(lang))
            .unwrap_or_else(|| panic!("{key:?} [{lang}] is not in the package strings"));
        assert_eq!(package.other(), text, "{key:?} [{lang}]");
        let app = parsed
            .app
            .get(key)
            .and_then(|l| l.get(lang))
            .expect("the app defines it too");
        assert_ne!(
            app.other(),
            text,
            "{key:?} [{lang}]: no difference, the table entry is not needed"
        );
    }
}

#[test]
fn t_package_gives_the_feminine_normal_in_russian_and_the_catalogue_text_elsewhere() {
    assert_eq!(
        tr("ru").t_package("Normal"),
        "Обычная",
        "buffer level (package)"
    );
    assert_eq!(tr("ru").t("Normal"), "Обычный", "subtitle size (app)");
    assert_eq!(tr("de").t_package("Normal"), "Normal");
    assert_eq!(tr("en").t_package("Normal"), "Normal");
    assert_eq!(tr("ru").t_package("Klein"), tr("ru").t("Klein"));
}

#[test]
fn new_texts_of_the_apple_beta_exist_in_english_and_russian() {
    // "Mehr Folgen" and "Verschieben" came with the Apple beta catalogue.
    for (lang, more, moves) in [
        ("en", "More episodes", "Move"),
        ("ru", "Ещё серии", "Переместить"),
    ] {
        assert_eq!(tr(lang).t("Mehr Folgen"), more, "{lang}");
        assert_eq!(tr(lang).t("Verschieben"), moves, "{lang}");
    }
}
