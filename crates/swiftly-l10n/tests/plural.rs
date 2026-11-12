use swiftly_l10n::PluralCategory::{self, Few, Many, One, Other, Two, Zero};
use swiftly_l10n::plural::{categories, category};

fn check(tag: &str, cases: &[(i64, PluralCategory)]) {
    for (n, want) in cases {
        assert_eq!(category(tag, *n), *want, "{tag}: {n}");
    }
}

#[test]
fn russian_and_ukrainian_boundaries() {
    for tag in ["ru", "uk", "ru-RU"] {
        check(
            tag,
            &[
                (0, Many),
                (1, One),
                (2, Few),
                (3, Few),
                (4, Few),
                (5, Many),
                (10, Many),
                (11, Many),
                (12, Many),
                (13, Many),
                (14, Many),
                (15, Many),
                (20, Many),
                (21, One),
                (22, Few),
                (24, Few),
                (25, Many),
                (100, Many),
                (101, One),
                (102, Few),
                (111, Many),
                (112, Many),
                (121, One),
                (1001, One),
                (-21, One),
            ],
        );
    }
}

#[test]
fn german_english_turkish_one_other() {
    for tag in ["de", "en", "tr", "nl", "sv", "de_DE", "en-US"] {
        check(
            tag,
            &[(0, Other), (1, One), (2, Other), (21, Other), (-1, One)],
        );
    }
}

#[test]
fn french_portuguese_zero_is_one() {
    check(
        "fr",
        &[
            (0, One),
            (1, One),
            (2, Other),
            (1_000_000, Many),
            (2_000_000, Many),
            (1_000_001, Other),
        ],
    );
    check("pt", &[(0, One), (1, One), (2, Other), (1_000_000, Many)]);
    check("pt-BR", &[(0, One), (1, One), (2, Other)]);
    check("pt-PT", &[(0, Other), (1, One), (2, Other)]);
}

#[test]
fn spanish_italian_have_many_for_millions() {
    for tag in ["es", "it"] {
        check(
            tag,
            &[
                (0, Other),
                (1, One),
                (2, Other),
                (999_999, Other),
                (1_000_000, Many),
                (3_000_000, Many),
            ],
        );
    }
}

#[test]
fn polish() {
    check(
        "pl",
        &[
            (0, Many),
            (1, One),
            (2, Few),
            (4, Few),
            (5, Many),
            (12, Many),
            (14, Many),
            (21, Many),
            (22, Few),
            (24, Few),
            (25, Many),
            (101, Many),
            (102, Few),
            (112, Many),
        ],
    );
}

#[test]
fn arabic_has_all_six() {
    check(
        "ar",
        &[
            (0, Zero),
            (1, One),
            (2, Two),
            (3, Few),
            (10, Few),
            (11, Many),
            (99, Many),
            (100, Other),
            (101, Other),
            (102, Other),
            (103, Few),
            (110, Few),
            (111, Many),
            (199, Many),
            (200, Other),
        ],
    );
}

#[test]
fn east_asian_only_other() {
    for tag in ["ja", "zh", "zh-Hans", "ko", "vi", "th", "id"] {
        check(tag, &[(0, Other), (1, Other), (2, Other), (100, Other)]);
    }
}

#[test]
fn other_slavic_and_misc() {
    check(
        "cs",
        &[(1, One), (2, Few), (4, Few), (5, Other), (0, Other)],
    );
    check(
        "hr",
        &[
            (1, One),
            (2, Few),
            (5, Other),
            (11, Other),
            (21, One),
            (22, Few),
        ],
    );
    check(
        "sl",
        &[
            (1, One),
            (2, Two),
            (3, Few),
            (4, Few),
            (5, Other),
            (101, One),
        ],
    );
    check("he", &[(1, One), (2, Two), (3, Other)]);
    check(
        "lt",
        &[(1, One), (2, Few), (10, Other), (11, Other), (21, One)],
    );
    check(
        "lv",
        &[
            (0, Zero),
            (1, One),
            (2, Other),
            (10, Zero),
            (11, Zero),
            (21, One),
        ],
    );
    check(
        "ro",
        &[
            (1, One),
            (0, Few),
            (2, Few),
            (19, Few),
            (20, Other),
            (101, Other),
            (102, Few),
        ],
    );
}

#[test]
fn every_result_is_among_the_declared_categories() {
    let tags = [
        "de", "en", "ru", "fr", "es", "it", "pt", "pt-PT", "pl", "tr", "uk", "ar", "ja", "zh",
        "cs", "hr", "sl", "he", "lt", "lv", "ro", "hi",
    ];
    for tag in tags {
        let declared = categories(tag);
        assert!(declared.contains(&Other), "{tag} must declare other");
        let probes = (0..=1200).chain([1_000_000, 2_000_000, 5_000_000, 1_000_001]);
        for n in probes {
            let c = category(tag, n);
            assert!(
                declared.contains(&c),
                "{tag}: {n} -> {c:?} not in {declared:?}"
            );
        }
    }
}

#[test]
fn names_round_trip() {
    for c in [Zero, One, Two, Few, Many, Other] {
        assert_eq!(PluralCategory::parse(c.as_str()), Some(c));
    }
    assert_eq!(PluralCategory::parse("several"), None);
}
