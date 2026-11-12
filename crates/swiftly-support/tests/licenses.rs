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
    let vlckit = data.components.iter().find(|c| c.id == "vlckit").unwrap();
    assert_eq!(vlckit.spdx, "LGPL-2.1-or-later");
    assert_eq!(vlckit.platforms, ["ios", "ipados", "macos", "tvos"]);
    // VLCKit is an earlier-versions entry: kept for the written offer, not in the current lists.
    assert_eq!(vlckit.group, "frueher");
    assert!(
        data.for_platform("tvos")
            .any(|c| c.id == "aetherengine" && c.group == "player")
    );
    assert!(data.for_platform("windows").any(|c| c.id == "rust-core"));
    assert!(!data.for_platform("windows").any(|c| c.id == "vlckit"));
    assert!(LicenseData::parse(b"nope").is_none());
}
