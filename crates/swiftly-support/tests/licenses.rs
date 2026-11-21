use swiftly_support::licenses::LicenseData;

#[test]
fn the_shipped_components_file_reads() {
    let json = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../LICENSES/components.json"
    ))
    .unwrap();
    let data = LicenseData::parse(&json).expect("components.json parses");
    assert_eq!(data.schema, 1);
    assert!(
        data.offering
            .title
            .starts_with("AetherEngine, FFmpeg and libmpv")
    );
    assert_eq!(data.offering.contact, "info@swiftlyplayer.com");
    assert!(!data.offering.sections.is_empty());
    assert!(data.components.len() > 5);
    // VLC is named only in the earlier-versions parts (groups "frueher*" and the offer sections
    // titled "Earlier versions ..."): no current release ships it, but the written offer for the
    // earlier ones stays. The current groups, platforms and offer sections never name it.
    let names_vlc = |s: &str| s.to_lowercase().contains("vlc");
    let is_earlier = |group: &str| group.starts_with("frueher");
    for c in &data.components {
        let text = format!(
            "{} {} {} {} {} {}",
            c.id,
            c.name,
            c.version,
            c.source,
            c.author,
            c.note.as_deref().unwrap_or("")
        );
        assert!(
            is_earlier(&c.group) || !names_vlc(&text),
            "{} names VLC outside the earlier-versions groups",
            c.id
        );
    }
    assert!(!names_vlc(&data.offering.title) && !names_vlc(&data.offering.short));
    for s in &data.offering.sections {
        let text = format!("{} {}", s.title, s.paragraphs.join(" "));
        assert!(
            s.title.starts_with("Earlier versions") || !names_vlc(&text),
            "offer section {:?} names VLC outside the earlier-versions sections",
            s.title
        );
    }
    // The earlier-versions offer is complete: the entries, the four sections, the written offer.
    let vlckit = data.components.iter().find(|c| c.id == "vlckit").unwrap();
    assert_eq!(vlckit.spdx, "LGPL-2.1-or-later");
    assert_eq!(vlckit.platforms, ["ios", "ipados", "macos", "tvos"]);
    assert_eq!(vlckit.group, "frueher");
    assert!(
        data.components
            .iter()
            .any(|c| c.id == "libvlc" && c.group == "frueher")
    );
    assert!(
        data.components
            .iter()
            .any(|c| c.group == "frueher-in-vlckit")
    );
    let earlier = data
        .offering
        .sections
        .iter()
        .filter(|s| s.title.starts_with("Earlier versions"))
        .count();
    assert_eq!(earlier, 4);
    assert!(
        data.offering
            .sections
            .iter()
            .any(|s| s.title.starts_with("Earlier versions") && s.title.ends_with("written offer"))
    );
    // Every licence text a component names is in LICENSES/.
    for c in &data.components {
        for text in &c.texts {
            let file = format!("{}/../../LICENSES/{text}", env!("CARGO_MANIFEST_DIR"));
            assert!(
                std::path::Path::new(&file).is_file(),
                "{} names {text}",
                c.id
            );
        }
    }
    // The earlier-versions entries are Apple-only and never in the other platforms' lists.
    for platform in ["android", "linux", "windows"] {
        assert!(!data.for_platform(platform).any(|c| is_earlier(&c.group)));
    }
    assert!(
        data.for_platform("tvos")
            .any(|c| c.id == "aetherengine" && c.group == "player")
    );
    assert!(data.for_platform("windows").any(|c| c.id == "rust-core"));
    assert!(!data.for_platform("windows").any(|c| c.id == "vlckit"));
    assert!(LicenseData::parse(b"nope").is_none());
}
