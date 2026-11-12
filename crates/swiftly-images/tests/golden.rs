//! Golden tests: `tests/fixtures/golden.txt` is the output of the Swift functions themselves,
//! compiled with `swiftc` from `ImageAddress.swift`, `ImageStoreKey.swift`, `ImageSlab.swift`,
//! `AddressSecret.swift`, `AvComputation.swift` and `ColorSelection.swift` plus the two stubs and
//! the harness next to it (`golden_stubs.swift`, `golden_harness.swift`). One `name|value` per
//! line. The harness also copies the mesh and noise loops of `ImageTone.swift` verbatim.
//!
//! Rebuild: `swiftc -O -o h golden_harness.swift golden_stubs.swift <the six files> && ./h`.

#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::collections::HashMap;
use swiftly_images::color;
use swiftly_images::mood::{self, noise_tile};
use swiftly_images::tone::{av, grid, tones_from_rgba};
use swiftly_images::{ImageAddress, ImageKind, ImageMetric, file_name, image_key, name, store_key};
use swiftly_jellyfin::ServerKind;
use url::Url;

fn golden() -> HashMap<String, String> {
    include_str!("fixtures/golden.txt")
        .lines()
        .filter_map(|line| line.split_once('|'))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

fn get<'a>(g: &'a HashMap<String, String>, key: &str) -> &'a str {
    g.get(key)
        .unwrap_or_else(|| panic!("missing golden key {key}"))
}

fn nums(text: &str) -> Vec<f64> {
    text.split(',')
        .filter(|s| !s.is_empty())
        .map(|s| s.parse().expect("number"))
        .collect()
}

fn assert_close(actual: &[f64], expected: &str, what: &str) {
    let expected = nums(expected);
    assert_eq!(actual.len(), expected.len(), "{what}: length");
    for (a, e) in actual.iter().zip(&expected) {
        assert!((a - e).abs() < 1e-9, "{what}: {a} vs {e}");
    }
}

fn u(text: &str) -> Url {
    Url::parse(text).expect("url")
}

// MARK: Addresses

#[test]
fn addresses_match_swift() {
    let g = golden();
    let jf = ImageAddress::new(
        u("https://tv.example.de"),
        Some("abc".into()),
        ServerKind::Jellyfin,
    );
    let jf_sub = ImageAddress::new(
        u("https://tv.example.de/jf/"),
        Some("a b+c&d".into()),
        ServerKind::Jellyfin,
    );
    let jf_no = ImageAddress::new(u("http://192.168.1.5:8096"), None, ServerKind::Jellyfin);
    let emby = ImageAddress::new(
        u("https://emby.example.de:8920"),
        Some("T".into()),
        ServerKind::Emby,
    );
    let plex = ImageAddress::new(
        u("https://plex.example.de:32400"),
        Some("TOK".into()),
        ServerKind::Plex,
    );
    let plex_no = ImageAddress::new(u("https://plex.example.de:32400"), None, ServerKind::Plex);
    use ImageKind::{Background, Logo, Poster, Preview};
    use ImageMetric::{AtMostHigh, AtMostWide, Filling};
    #[allow(clippy::type_complexity)]
    let cases: Vec<(
        &ImageAddress,
        &str,
        ImageKind,
        Option<&str>,
        ImageMetric,
        Option<i64>,
        i64,
    )> = vec![
        (&jf, "abc123", Poster, Some("t1"), AtMostHigh(450), None, 90),
        (
            &jf,
            "abc123",
            Background,
            Some("t1"),
            AtMostWide(1200),
            None,
            90,
        ),
        (
            &jf,
            "abc123",
            Preview,
            Some("t1"),
            AtMostWide(600),
            None,
            90,
        ),
        (&jf, "abc123", Logo, Some("t1"), AtMostHigh(240), None, 90),
        (
            &jf,
            "abc123",
            Poster,
            None,
            Filling { wide: 100, up: 150 },
            None,
            90,
        ),
        (
            &jf,
            "abc123",
            Background,
            Some("t1"),
            AtMostWide(1200),
            Some(2),
            85,
        ),
        (
            &jf_sub,
            "a b",
            Poster,
            Some("tag é+ü"),
            AtMostHigh(300),
            None,
            90,
        ),
        (&jf_no, "x", Poster, Some("t"), AtMostHigh(300), None, 90),
        (&emby, "x", Poster, Some("t"), AtMostHigh(300), None, 90),
        (
            &plex,
            "5",
            Poster,
            Some("/library/metadata/5/thumb/1700"),
            AtMostHigh(450),
            None,
            90,
        ),
        (
            &plex,
            "5",
            Background,
            Some("/library/metadata/5/art/9"),
            AtMostWide(1280),
            None,
            90,
        ),
        (
            &plex,
            "5",
            Poster,
            Some("/library/metadata/5/thumb/1"),
            Filling { wide: 640, up: 360 },
            None,
            80,
        ),
        (&plex, "5", Poster, None, AtMostHigh(300), None, 90),
        (&plex, "5", Preview, None, AtMostHigh(300), None, 90),
        (&plex, "5", Background, None, AtMostWide(300), None, 90),
        (&plex, "5", Logo, None, AtMostWide(300), None, 90),
        (
            &plex,
            "5",
            Poster,
            Some("https://metadata-static.plex.tv/a.jpg"),
            AtMostHigh(300),
            None,
            90,
        ),
        (
            &plex,
            "5",
            Poster,
            Some("/a b/c+d?x=1&y=é"),
            AtMostHigh(300),
            None,
            90,
        ),
        (
            &plex_no,
            "5",
            Poster,
            Some("/library/metadata/5/thumb/1"),
            AtMostHigh(300),
            None,
            90,
        ),
    ];
    for (i, (address, id, art, mark, mass, index, quality)) in cases.into_iter().enumerate() {
        let want = get(&g, &format!("addr{}.url", i + 1));
        let got = address
            .construct_with(id, art, mark, mass, index, quality)
            .map_or("nil".to_string(), |u| u.to_string());
        assert_eq!(got, want, "address case {}", i + 1);
    }
    let show = |u: Option<Url>| u.map_or("nil".to_string(), |u| u.to_string());
    assert_eq!(show(jf.user("u1", Some("m"), 64)), get(&g, "user1"));
    assert_eq!(show(jf_no.user("u1", None, 64)), get(&g, "user2"));
    assert_eq!(show(emby.user("u1", Some("m"), 64)), get(&g, "user3"));
    assert_eq!(show(plex.user("u1", None, 64)), get(&g, "user4"));
}

// MARK: Keys: byte-identical to Swift, so existing disk caches stay valid

#[test]
fn keys_and_file_names_match_swift() {
    let g = golden();
    let mut checked = 0;
    for i in 0.. {
        let Some(text) = g.get(&format!("key{i}")) else {
            break;
        };
        let url = u(text);
        assert_eq!(
            image_key(&url),
            get(&g, &format!("key{i}.image")),
            "image key {i}: {text}"
        );
        assert_eq!(
            store_key(&url).unwrap_or_else(|| "nil".into()),
            get(&g, &format!("key{i}.store")),
            "store key {i}: {text}"
        );
        assert_eq!(
            name(&url).unwrap_or_else(|| "nil".into()),
            get(&g, &format!("key{i}.name")),
            "file name {i}: {text}"
        );
        checked += 1;
    }
    assert_eq!(checked, 12);
    for (i, text) in [
        "",
        "a",
        "b",
        "hello",
        "/Items/abc/Images/Primary?fillHeight=600&tag=f00",
        "é€😀",
    ]
    .iter()
    .enumerate()
    {
        assert_eq!(
            file_name(text),
            get(&g, &format!("fnv{i}.name")),
            "fnv {text}"
        );
    }
}

/// A key that existing Swift caches hold on disk, spelled out so it never moves silently.
#[test]
fn a_known_disk_key() {
    let url =
        u("http://192.168.1.5:8096/Items/abc/Images/Primary?fillHeight=600&tag=f00&ApiKey=geheim");
    assert_eq!(
        store_key(&url).as_deref(),
        Some("/Items/abc/Images/Primary?fillHeight=600&tag=f00")
    );
    assert_eq!(name(&url).as_deref(), Some("704a6685d9e01d56"));
}

// MARK: Tone and colour

fn images() -> Vec<(&'static str, Vec<u8>)> {
    fn area(r: u8, g: u8, b: u8, points: usize) -> Vec<u8> {
        (0..points).flat_map(|_| [r, g, b, 255]).collect()
    }
    let cat = |parts: Vec<Vec<u8>>| parts.concat();
    let mut seed: u64 = 0x2545_F491_4F6C_DD1D;
    let mut noisy = Vec::new();
    for _ in 0..2304 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        noisy.extend([
            (seed >> 8) as u8,
            (seed >> 16) as u8,
            (seed >> 24) as u8,
            255,
        ]);
    }
    let mut odd = area(200, 30, 30, 3);
    odd.extend([1, 2, 3]);
    vec![
        ("red", area(200, 30, 30, 256)),
        ("gray", area(120, 120, 120, 256)),
        (
            "two",
            cat(vec![area(20, 60, 200, 300), area(220, 140, 20, 100)]),
        ),
        (
            "five",
            cat(vec![
                area(220, 30, 30, 100),
                area(30, 220, 30, 90),
                area(30, 30, 220, 80),
                area(220, 220, 30, 70),
                area(30, 220, 220, 60),
                area(220, 30, 220, 50),
            ]),
        ),
        ("noise48", noisy),
        ("dark", area(20, 10, 5, 100)),
        ("empty", Vec::new()),
        ("odd", odd),
    ]
}

#[test]
fn tones_match_swift() {
    let g = golden();
    for (name, pixels) in images() {
        assert_close(
            &tones_from_rgba(&pixels),
            get(&g, &format!("tones.{name}")),
            name,
        );
    }
}

fn tone_sets() -> Vec<(&'static str, Vec<f64>)> {
    vec![
        ("one", vec![200.0]),
        ("two", vec![30.0, 200.0]),
        ("three", vec![350.0, 10.0, 120.0]),
        ("none", vec![]),
    ]
}

#[test]
fn hsb_color_points_decay_match_swift() {
    let g = golden();
    for (name, t) in tone_sets() {
        for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.5, 0.5), (0.0, 1.0), (0.3, 0.8)] {
            let h = av::hsb(&t, x, y);
            assert_close(
                &[h.audio, h.saturation, h.brightness],
                get(&g, &format!("hsb.{name}.{x:?}.{y:?}")),
                "hsb",
            );
            for f in [1.0, 0.5, 0.0] {
                let c = av::color(&t, x, y, f);
                assert_close(
                    &[c.r, c.g, c.b],
                    get(&g, &format!("color.{name}.{x:?}.{y:?}.{f:?}")),
                    "color",
                );
            }
        }
        let p = av::points(&t, 5, 8, 1000.0, 900.0, 300.0, 600.0);
        let got: Vec<String> = p.iter().map(|v| format!("{:x}", *v as u32)).collect();
        assert_eq!(
            got.join(","),
            get(&g, &format!("points.{name}")),
            "points {name}"
        );
    }
    for y in [0.0, 100.0, 300.0, 301.0, 600.0, 900.0, 1600.0, 2000.0] {
        assert_close(
            &[av::decay(y, 300.0, 1300.0)],
            get(&g, &format!("decay.{y:?}")),
            "decay",
        );
    }
    assert_close(
        &[av::decay(10.0, 300.0, 0.0)],
        get(&g, "decay.zero.a"),
        "decay zero",
    );
    assert_close(
        &[av::decay(400.0, 300.0, 0.0)],
        get(&g, "decay.zero.b"),
        "decay zero",
    );
}

#[test]
fn oklab_matches_swift() {
    let g = golden();
    let g16 = 16.0 / 255.0;
    for (r, gr, b) in [
        (0.6, 0.13, 0.11),
        (g16, g16, g16),
        (0.0, 0.0, 0.0),
        (1.0, 1.0, 1.0),
        (0.02, 0.5, 0.9),
    ] {
        let (l, a, bb) = color::oklab(r, gr, b);
        assert_close(
            &[l, a, bb],
            get(&g, &format!("oklab.{r:?}.{gr:?}.{b:?}")),
            "oklab",
        );
        if let Some(s) = color::srgb_from_lab(l, a, bb) {
            assert_close(
                &[s.0, s.1, s.2],
                get(&g, &format!("srgb.{r:?}.{gr:?}.{b:?}")),
                "srgb",
            );
        }
    }
    assert!(color::srgb_from_lab(0.25, 0.4, 0.4).is_none());
    for (l, c, h) in [
        (0.25, 0.4, 29.0),
        (0.5, 0.1, 200.0),
        (0.9, 0.3, 120.0),
        (0.1, 0.0, 0.0),
    ] {
        let f = color::srgb_lch(l, c, h);
        assert_close(
            &[f.0, f.1, f.2],
            get(&g, &format!("lch.{l:?}.{c:?}.{h:?}")),
            "lch",
        );
    }
    assert_close(
        &[
            color::spacing(350.0, 10.0),
            color::spacing(10.0, 350.0),
            color::spacing(90.0, 270.0),
            color::spacing(29.0, 33.0),
        ],
        get(&g, "spacing"),
        "spacing",
    );
    for (h, s, v) in [
        (0.0, 1.0, 1.0),
        (60.0, 0.5, 0.5),
        (200.0, 0.38, 0.2),
        (359.0, 0.9, 0.9),
        (120.0, 0.0, 0.5),
    ] {
        let c = av::hsb_post_rgb(h, s, v);
        assert_close(
            &[c.r, c.g, c.b],
            get(&g, &format!("hsbrgb.{h:?}.{s:?}.{v:?}")),
            "hsb to rgb",
        );
    }
}

// MARK: Mood

#[test]
fn mesh_matches_swift() {
    let g = golden();
    for (label, tones) in [("tones", vec![30.0, 200.0]), ("empty", vec![])] {
        let m = mood::mesh(&tones, 2000.0, 1100.0, 200.0, 1300.0);
        let want = get(&g, &format!("mesh.200.{label}"));
        let (rows, body) = want.split_once('|').expect("rows");
        assert_eq!(m.rows.to_string(), rows);
        assert_eq!(m.columns * m.rows, m.points.len());
        for (p, line) in m.points.iter().zip(body.split(';')) {
            assert_close(
                &[
                    f64::from(p.x),
                    f64::from(p.y),
                    p.color.r,
                    p.color.g,
                    p.color.b,
                ],
                line,
                "mesh point",
            );
        }
    }
    assert_eq!(mood::detail_mesh(&[200.0], 400.0).rows, 14);
    assert_eq!((mood::COLOR_HEIGHT, mood::RUN_OUT), (900.0, 1300.0));
}

#[test]
fn grid_matches_swift() {
    let g = golden();
    for (name, tones) in tone_sets() {
        let points = grid(&tones);
        assert_eq!(points.len(), 25);
        if tones.is_empty() {
            assert!(points.iter().all(|p| p.color.is_none()));
            continue;
        }
        let want = get(&g, &format!("grid.{name}"));
        for (p, line) in points.iter().zip(want.split(';')) {
            let c = p.color.expect("colour");
            assert_close(&[c.audio, c.saturation, c.brightness], line, "grid point");
        }
    }
}

#[test]
fn noise_tile_matches_swift() {
    let g = golden();
    let tile = noise_tile();
    assert_eq!(tile.len(), 96 * 96 * 4);
    let head: Vec<String> = tile.iter().take(32).map(u8::to_string).collect();
    assert_eq!(head.join(","), get(&g, "noise.head"));
    let sum: usize = tile.iter().map(|b| usize::from(*b)).sum();
    assert_eq!(sum.to_string(), get(&g, "noise.sum"));
    let letters: String = tile
        .iter()
        .map(|b| {
            if *b == 0 {
                '0'
            } else {
                char::from(b'a' + b % 26)
            }
        })
        .collect();
    assert_eq!(file_name(&letters), get(&g, "noise.hash"));
}
