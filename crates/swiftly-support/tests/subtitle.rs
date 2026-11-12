//! Translation of SubtitleLookTests (JellyfinKit) plus the mpv mapping.

use swiftly_support::SubtitleLook;
use swiftly_support::subtitle::{Colour, Engine, FontChoice, Outline, Position, Size, base_scale};

fn opts(look: SubtitleLook, base: f64, height: i64, engine: Engine) -> Vec<String> {
    look.vlc_options(base, height, engine)
}
fn std_opts(look: SubtitleLook) -> Vec<String> {
    opts(look, 0.82, 1080, Engine::Vlc4Apple)
}
fn has(v: &[String], s: &str) -> bool {
    v.iter().any(|x| x == s)
}
fn look() -> SubtitleLook {
    SubtitleLook::STANDARD
}

#[test]
fn standard_matches_the_former_fixed_style() {
    assert_eq!(
        std_opts(look()),
        [
            "--freetype-color=16777215",
            "--freetype-outline-thickness=3",
            "--freetype-outline-opacity=230",
            "--freetype-outline-color=0",
            "--freetype-shadow-opacity=0",
            "--freetype-background-opacity=1",
            "--sub-margin=16",
        ]
    );
    assert!(SubtitleLook::STANDARD.is_standard());
    assert_eq!(SubtitleLook::default(), SubtitleLook::STANDARD);
}

#[test]
fn size_percent_per_device() {
    for (base, expected) in [
        (0.82, [66, 82, 98, 119]),
        (0.78, [62, 78, 94, 113]),
        (0.88, [70, 88, 106, 128]),
    ] {
        let got = Size::ALL.map(|s| SubtitleLook { size: s, ..look() }.text_scale_percent(base));
        assert_eq!(got, expected);
    }
    assert_eq!(base_scale::IPHONE, 0.82);
    assert_eq!(base_scale::TV, 0.88);
    // Preview points: height x 6.25 % x base x step.
    let points = look().preview_points(1080.0, 0.88);
    assert!((points - 1080.0 * 0.0625 * 0.88).abs() < 1e-9);
}

#[test]
fn size_option_only_on_vlc3() {
    let large = SubtitleLook {
        size: Size::Large,
        ..look()
    };
    assert_eq!(
        opts(large, 0.82, 1080, Engine::Vlc3)
            .first()
            .map(String::as_str),
        Some("--sub-text-scale=98")
    );
    assert!(
        !std_opts(large)
            .iter()
            .any(|o| o.starts_with("--sub-text-scale"))
    );
}

#[test]
fn colour_outline_shadow_background() {
    for (c, v) in [
        (Colour::White, "16777215"),
        (Colour::Yellow, "16770140"),
        (Colour::Grey, "13421772"),
    ] {
        assert!(has(
            &std_opts(SubtitleLook {
                colour: c,
                ..look()
            }),
            &format!("--freetype-color={v}")
        ));
    }
    for (o, v) in [
        (Outline::Off, "0"),
        (Outline::Thin, "2"),
        (Outline::Normal, "3"),
    ] {
        let got = std_opts(SubtitleLook {
            outline: o,
            ..look()
        });
        assert!(has(&got, &format!("--freetype-outline-thickness={v}")));
        assert!(has(&got, "--freetype-outline-opacity=230"));
        assert!(has(&got, "--freetype-outline-color=0"));
    }
    let on = std_opts(SubtitleLook {
        shadow: true,
        ..look()
    });
    for s in [
        "--freetype-shadow-opacity=160",
        "--freetype-shadow-angle=-90",
        "--freetype-shadow-distance=0.04",
        "--freetype-shadow-color=0",
    ] {
        assert!(has(&on, s));
    }
    let off = std_opts(look());
    assert!(has(&off, "--freetype-shadow-opacity=0"));
    assert!(!off.iter().any(|o| o.starts_with("--freetype-shadow-angle")));

    for engine in [Engine::Vlc4Apple, Engine::Vlc3] {
        let got = opts(
            SubtitleLook {
                background: true,
                ..look()
            },
            0.82,
            1080,
            engine,
        );
        assert!(has(&got, "--freetype-background-opacity=160"));
        assert!(has(&got, "--freetype-background-color=0"));
    }
    assert!(has(&std_opts(look()), "--freetype-background-opacity=1"));
    assert!(has(
        &opts(look(), 0.82, 1080, Engine::Vlc3),
        "--freetype-background-opacity=0"
    ));
    for l in [
        look(),
        SubtitleLook {
            shadow: true,
            ..look()
        },
        SubtitleLook {
            background: true,
            ..look()
        },
        SubtitleLook {
            outline: Outline::Off,
            ..look()
        },
    ] {
        let value = std_opts(l).iter().find_map(|o| {
            o.strip_prefix("--freetype-background-opacity=")
                .and_then(|v| v.parse::<i32>().ok())
        });
        assert!(value.unwrap_or(0) >= 1);
    }
}

#[test]
fn position_margins() {
    assert!(has(&std_opts(look()), "--sub-margin=16"));
    assert!(
        !opts(look(), 0.82, 1080, Engine::Vlc3)
            .iter()
            .any(|o| o.starts_with("--sub-margin"))
    );
    let raised = SubtitleLook {
        position: Position::Raised,
        ..look()
    };
    assert_eq!(SubtitleLook::raised_margin(1080), 76);
    assert_eq!(SubtitleLook::raised_margin(2160), 151);
    assert!(has(
        &opts(raised, 0.82, 1080, Engine::Vlc4Apple),
        "--sub-margin=92"
    ));
    assert!(has(
        &opts(raised, 0.82, 2160, Engine::Vlc4Apple),
        "--sub-margin=167"
    ));
    assert!(has(
        &opts(raised, 0.82, 1080, Engine::Vlc3),
        "--sub-margin=76"
    ));
}

#[test]
fn storage_json_is_swift_compatible_and_tolerant() {
    let all = SubtitleLook {
        size: Size::Huge,
        colour: Colour::Yellow,
        outline: Outline::Thin,
        shadow: true,
        background: true,
        position: Position::Raised,
        keep_file_style: false,
    };
    assert_eq!(SubtitleLook::read(Some(&all.encoded())), all);
    assert_eq!(SubtitleLook::read(None), SubtitleLook::STANDARD);
    assert_eq!(SubtitleLook::read(Some(b"kaputt")), SubtitleLook::STANDARD);
    assert_eq!(
        SubtitleLook::read(Some(br#"{"size":"gigantic","shadow":true}"#)),
        SubtitleLook {
            shadow: true,
            ..look()
        }
    );
    assert_eq!(all.encoded(), all.encoded());
    // The exact bytes Swift's sorted-key encoder writes for the synced `utAussehen` value.
    assert_eq!(
        String::from_utf8(look().encoded()).unwrap(),
        r#"{"background":false,"colour":"white","keepFileStyle":true,"outline":"normal","position":"bottom","shadow":false,"size":"normal"}"#
    );
    assert_eq!(
        String::from_utf8(all.encoded()).unwrap(),
        r#"{"background":true,"colour":"yellow","keepFileStyle":false,"outline":"thin","position":"raised","shadow":true,"size":"huge"}"#
    );
    // An empty object and a wrongly typed field read as defaults.
    assert_eq!(SubtitleLook::read(Some(b"{}")), SubtitleLook::STANDARD);
    assert_eq!(
        SubtitleLook::read(Some(br#"{"shadow":"yes"}"#)),
        SubtitleLook::STANDARD
    );
}

#[test]
fn custom_check_includes_the_file_switch() {
    assert!(
        !SubtitleLook {
            keep_file_style: false,
            ..look()
        }
        .is_standard()
    );
    assert!(
        !SubtitleLook {
            position: Position::Raised,
            ..look()
        }
        .is_standard()
    );
    assert_eq!(look().entry_value(), "Standard");
    assert_eq!(
        SubtitleLook {
            shadow: true,
            ..look()
        }
        .entry_value(),
        "Eigenes"
    );
}

#[test]
fn words() {
    assert_eq!(
        Size::ALL.map(Size::name_key),
        ["Klein", "Normal", "Groß", "Sehr groß"]
    );
    assert_eq!(Colour::ALL.map(Colour::name_key), ["Weiß", "Gelb", "Grau"]);
    assert_eq!(
        Outline::ALL.map(Outline::name_key),
        ["Aus", "Dünn", "Normal"]
    );
    assert_eq!(Position::Raised.name_key(), "Höher");
    assert_eq!(
        look().sentence_keys().join(", "),
        "Normal, Weiß, Rand normal, ohne Schatten, ohne Hintergrund, unten"
    );
    assert!(
        look()
            .file_style_line()
            .starts_with("Bei ASS und SSA bestimmt die Datei")
    );
    assert!(
        SubtitleLook {
            keep_file_style: false,
            ..look()
        }
        .file_style_line()
        .starts_with("Auch ASS und SSA")
    );
    assert_eq!(FontChoice::AppleInter.family(), "Inter18pt-SemiBold");
    assert_eq!(FontChoice::Windows.family(), "Segoe UI Semibold");
}

#[test]
fn mpv_mapping_matches_the_desktop_player() {
    let style = look().mpv_style(1080, FontChoice::LinuxInter.family());
    let o: Vec<(String, String)> = style.options();
    let get = |k: &str| o.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str());
    assert_eq!(get("sub-font"), Some("Inter 18pt SemiBold"));
    assert_eq!(get("sub-font-size"), Some("55"));
    assert_eq!(get("sub-scale"), Some("1.0"));
    assert_eq!(get("sub-color"), Some("#FFFFFF"));
    assert_eq!(get("sub-border-color"), Some("#E6000000"));
    assert_eq!(get("sub-border-size"), Some("3.3"));
    assert_eq!(get("sub-ass-override"), Some("no"));
    assert_eq!(get("sub-shadow-offset"), Some("0"));
    assert_eq!(get("sub-shadow-color"), None);
    assert_eq!(get("sub-back-color"), Some("#00000000"));
    assert_eq!(get("sub-margin-y"), Some("22"));

    let full = SubtitleLook {
        size: Size::Huge,
        colour: Colour::Yellow,
        outline: Outline::Thin,
        shadow: true,
        background: true,
        position: Position::Raised,
        keep_file_style: false,
    };
    let o = full.mpv_style(1080, "Sans").options();
    let get = |k: &str| o.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str());
    assert_eq!(get("sub-scale"), Some("1.45"));
    assert_eq!(get("sub-color"), Some("#FFE45C"));
    assert_eq!(get("sub-border-size"), Some("2.2"));
    assert_eq!(get("sub-ass-override"), Some("force"));
    assert_eq!(get("sub-shadow-color"), Some("#A0000000"));
    assert_eq!(get("sub-shadow-offset"), Some("2.2"));
    assert_eq!(get("sub-back-color"), Some("#A0000000"));
    // 22 + 76 * 720 / 1080 = 72.67 -> 73
    assert_eq!(get("sub-margin-y"), Some("73"));
    // Zero outline.
    let none = SubtitleLook {
        outline: Outline::Off,
        ..look()
    }
    .mpv_style(0, "Sans");
    assert_eq!(
        none.options()
            .iter()
            .find(|(n, _)| n == "sub-border-size")
            .unwrap()
            .1,
        "0.0"
    );
}
