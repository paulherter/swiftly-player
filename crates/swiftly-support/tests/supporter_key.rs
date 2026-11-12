#![cfg(feature = "supporter-key")]
//! Test vectors copied by script from the Swift package tests (the Kotlin test reads the same files).
pub const V1: &[(&str, &str)] = &[
    (
        "vectorSequenceStudio",
        "SS1-AEAAEUIIAERUKZ4JVPG66WTPYOVSATJOII2WK2NMFNM37V6KE4X4YMOOISMZS6NKFSRIJOM6SYNN34YKVYCUQA4GWIHGKYC4YE7ZPGJT2QTAWYGPZTBZFW2X5537IMULGSYGUCQ",
    ),
    (
        "vectorTestNoName",
        "SS1-AEAQCUII73OLVGDWKQZBBJP7SXWSHCM5FD24Z52JS344LP2I7IDQ4BSWAUFQ5I5H37GMARLXTSJWOTHCWQ2MXYWXVVRELN7J2GVKWHFIR77CCPNHJTX2AELO3ECA",
    ),
    (
        "swiftlyNamed",
        "SS1-AEAACUIIAERUKZ4JVPG66WTPYOVSATJOHT74FE6ZQWPVOTNBNRAGYEYWF3FYDXEAILFQHKMFHXC4FJM6UR7GZE7RD5EXKJAWARVEV3WB7NO3QHNLW3RMZ6WG6FPGJE3G2D7CUDY",
    ),
    (
        "swiftlyNoName",
        "SS1-AEAACUII73OLVGDWKQZBADOQ45NZ2ZMFV5WXBR2ATF4RDQZ76ELHWKSRRBY27BTOXLHVLCVWCEUNKLWGMBXXY4FMHYY5EHMZZPGOAQ5PWEZNVV674XKP26UWMAGQ",
    ),
    (
        "swiftlyTest",
        "SS1-AEAQCUIIAAAAAAAAAAAP7PN7NFXJNTY6XH2E7HVUU7XJEG3RRKDN6LNYO64UY4XCPN5TDQCZUTACXRCVL6CFN4DCU3FRANOK6F2CGOOZKNLW6JCPTNHDG5EHX4DQ",
    ),
    (
        "swiftlyDayZero",
        "SS1-AEAACAAA7777777777776MIT5BJNB5POZ5EHNXMZ3LAXULVFU2OKWPOKCBAUKF4GIWONQ5GOEJ2SFUI6IEQ3U2LMWO2RF2XFIQYTNYZM5RVIMU62XHOAED44GAFQ",
    ),
    (
        "swiftlyLongName",
        "SS1-AEAACUIIAERUKZ4JVPG67Q5JYOU4HKODVHB2TQ5JYOU4HKODVHB2TQ5JYOU4HKODVHB2TQ5JYOU4HKODVHB2TQ5JYOU4HKODVFNMZCVNJTHY4HCU7GNHM7MRTRERWWGMPPLUCXFCC6KU77GGOPQ3RJZ5RGVQDBV3MFDGBT64VS5Z64BQDFAQP24NABENTXPFLWWK2MIB",
    ),
    (
        "sequenceStudio",
        "SS1-AEAAEUIIAERUKZ4JVPG66QLON36ICZIEVBI2ZSG3TWDIGAM3F674LN32XVPLS4MRXKV5UXT6D2Q2FECX4HSYBYPA6P6V6RXTUK2H4JYVQ3URDQU7YFJ5GOLO5HYDHVAI",
    ),
    (
        "version2",
        "SS1-AIAACUIIAERUKZ4JVPG67CYL7MW6SX7VV6TRTBETNXVADAWF44UDCB52ZBBGLCAIJ76Q6XI56RNDJSO5PZEIFTZUQGQFRIL4QGPKITIXSDZGCIH6SGFMMPNNEQDQ",
    ),
    (
        "unknownApp",
        "SS1-AEAASUIIAERUKZ4JVPG674UWNT3YOQTW4JWS7CFGIL5UMGAGXZ4PLARVXFTMTKDOZ3O4ST22H723L6PFH2WSZF6GNSXQV4GUO2P362YPUUAHAJ46E4CSJBYRNQAA",
    ),
    (
        "badUTF8Name",
        "SS1-AEAACUIIAERUKZ4JVPG67776AXSI4PE6Z6WO3I3QY2SGEU5JFHEB7X47MFJI3KIDULB6D426IGCN4ZJUM5Q43COCK2K2TIXG33U4H6GCV4TC5KAXDAMISBEE34GZSDI",
    ),
    (
        "nameTooLong",
        "SS1-AEAACUIIAERUKZ4JVPG666DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4HQ6DYPB4MQRXNEZYOIMXNBQFAXSZTTAVP2KHMJP3KENMS6QQUGOBSC6QQPSVJ6METPVH6GWQMDK7SLT2B7RZLSZTKCSCMRFXF3KLQ6D5MDXCRBY",
    ),
    (
        "headOnly",
        "SS1-AEAACUIIAERUKZ4JVPGTSS75FL3JWBFD2SXL7K3BU22X63RFUV7U55FYGQFFRG6GIPKX6KKFYJOVZHP6YFOL3HNGCKTSORJ7CQX6NXXRGN2S2BB3BVJUZS4LBM",
    ),
];
pub const V2: &[(&str, &str)] = &[
    (
        "monthly",
        "SS2-AIAACAKRBBISOAAREIZUIVLGO6EJTKV3ZTO65722N7B2WICNF3VXWHLLDQOVVU6UNFIEFEBC2EJZ7HTDYFTQ63RSH5W55ZLFZZL5AY2GQEBGUIFKT5DSDMC7WI4FHJSAAXDLBFOKR2DH2NC5565OHLIP",
    ),
    (
        "monthlyLater",
        "SS2-AIAACAKRBBIUMAAREIZUIVLGO6EJTKV3ZTO65722N7B2WICNFZQPX5RFPZNR7F2QXLFUGUIWZ4KDBFBREJNBTKLXJBIX35NN3C6RDKFN25MTNWSDRGPBAQ3INH2TIOGXKUOOR5WE7DUVKBQJ5G4YX6QB",
    ),
    (
        "lifetime",
        "SS2-AIAACASRBAAAB77O3XGLXKUZRB3WMVKEGMRBCAAHDD6WZNFCPGHPSRYLTY46EOCMCQPD7HWRLPQ2ALYGOGHETIIDG2WKJXHZOG6ZXT6CNFHISLXS5C7QNROB6W3CRGYQYTKLEVSSJ4UAS",
    ),
    (
        "lifetimeTest",
        "SS2-AIAQCASRBAAAB77O3XGLXKUZRB3WMVKEGMRBCAFEKIVZPSPBPNLQIYYZKR4IB6RODDCCFVB3P7NC5ARBF2ROUZ3TDJGNURUP2Z53XUZLXPD36X7BZL4JX5BJWM2G6JVBTYEZOWCASE5Q6",
    ),
    (
        "otherApp",
        "SS2-AIAAEASRBAAAAAAREIZUIVLGO6EJTKV3ZTO6574WLEGQ2BL33KQDBU5LMGRMF4S3TQO3TVNLLKZ6HEXJA3X66OUNIES53NNXBWBEEMK5JQZOKNXMYTHAT2CYEIDMPEXWJQVYGHESCVNQQ",
    ),
];

use swiftly_support::supporter_key::*;

const ISSUED: i64 = 1_792_281_600_000; // 2026-10-18
const EXPIRES: i64 = 1_794_960_000_000; // 2026-11-18

fn v1(name: &str) -> &'static str {
    V1.iter().find(|(k, _)| *k == name).unwrap().1
}
fn v2(name: &str) -> &'static str {
    V2.iter().find(|(k, _)| *k == name).unwrap().1
}
fn test_key() -> [u8; 32] {
    decode_public_key(TEST_PUBLIC_KEY_BASE64).unwrap()
}
fn check(text: &str, app: u8, allow_test: bool) -> Result<License, Failure> {
    verify(text, &test_key(), app, allow_test, ISSUED)
}
fn fail(text: &str) -> Failure {
    check(text, 1, false).unwrap_err()
}

#[test]
fn valid_keys_read_like_kotlin() {
    let l = check(v1("swiftlyNamed"), 1, false).unwrap();
    assert_eq!(
        (l.issued_at_ms, l.id.as_str(), l.name.as_deref()),
        (ISSUED, "0123456789abcdef", Some("Zoë M."))
    );
    assert!(l.is_legacy && l.plan == "lifetime" && l.expires_at_ms.is_none());
    let l = check(v1("swiftlyNoName"), 1, false).unwrap();
    assert_eq!((l.id.as_str(), l.name), ("fedcba9876543210", None));
    assert_eq!(
        check(v1("swiftlyDayZero"), 1, false).unwrap().issued_at_ms,
        0
    );
    assert_eq!(
        check(v1("swiftlyLongName"), 1, false)
            .unwrap()
            .name
            .unwrap(),
        "é".repeat(24)
    );
}

#[test]
fn app_test_and_malformed_rules() {
    assert_eq!(fail(v1("vectorSequenceStudio")), Failure::WrongApp);
    assert_eq!(check(v1("vectorSequenceStudio"), 2, false).unwrap().app, 2);
    assert_eq!(fail(v1("sequenceStudio")), Failure::WrongApp);
    assert_eq!(fail(v1("swiftlyTest")), Failure::TestKey);
    assert_eq!(fail(v1("vectorTestNoName")), Failure::TestKey);
    assert!(check(v1("swiftlyTest"), 1, true).unwrap().is_test);
    assert_eq!(fail(v1("version2")), Failure::UnsupportedVersion);
    assert_eq!(fail(v1("unknownApp")), Failure::UnknownApp);
    assert_eq!(fail(v1("badUTF8Name")), Failure::BadName);
    assert_eq!(fail(v1("nameTooLong")), Failure::BadName);
    assert_eq!(fail(v1("headOnly")), Failure::TooShort);
}

#[test]
fn forgiving_paste() {
    let key = v1("swiftlyNamed");
    let expected = check(key, 1, false).unwrap();
    let groups: Vec<String> = key[4..]
        .as_bytes()
        .chunks(5)
        .map(|c| String::from_utf8(c.to_vec()).unwrap())
        .collect();
    assert_eq!(
        check(
            &format!("  ss1-{}\n", groups.join("-").to_lowercase()),
            1,
            false
        )
        .unwrap(),
        expected
    );
    assert_eq!(
        check(&format!("\tSS1-{}  ", groups.join(" ")), 1, false).unwrap(),
        expected
    );
    assert_eq!(
        check(&format!("Ss1-{}", groups.join("\n")), 1, false).unwrap(),
        expected
    );
    assert_eq!(check(&key.to_lowercase(), 1, false).unwrap(), expected);
    assert_eq!(check(&format!("{key}\0"), 1, false).unwrap(), expected);
    assert_eq!(check(&format!("{key} "), 1, false).unwrap(), expected); // trim() removes spaces
}

#[test]
fn tampering_and_truncation_fail() {
    let key = v1("swiftlyNamed");
    let mut chars: Vec<char> = key.chars().collect();
    for i in (4..chars.len() - 1).step_by(23) {
        let old = chars[i];
        chars[i] = if old == 'A' { 'B' } else { 'A' };
        assert!(
            check(&chars.iter().collect::<String>(), 1, false).is_err(),
            "position {i}"
        );
        chars[i] = old;
    }
    for bad in [&key[..key.len() - 1], &key[..key.len() - 8], &key[..40]] {
        assert!(check(bad, 1, false).is_err());
    }
    assert!(check(&format!("{key}A"), 1, false).is_err());
    assert!(check(&format!("{key}AAAAAAAA"), 1, false).is_err());
    assert_eq!(fail(""), Failure::Empty);
    assert_eq!(fail("   \n "), Failure::Empty);
    assert_eq!(fail("SS1-"), Failure::TooShort);
    assert_eq!(fail("SS1-AAAA"), Failure::TooShort);
    assert!(check(&format!("SS2-{}", &key[4..]), 1, false).is_err());
    assert_eq!(fail(&format!("SS1{}", &key[4..])), Failure::WrongPrefix);
    assert_eq!(fail(&format!("SS1-{}0", &key[4..])), Failure::BadEncoding);
    assert_eq!(fail(&format!("SS1-{}!", &key[4..])), Failure::BadEncoding);
    assert_eq!(fail(&format!("SS1-{}", "A".repeat(500))), Failure::TooLong);
    assert_eq!(fail(&format!("ſs1-{}", &key[4..])), Failure::WrongPrefix);
    assert_eq!(
        fail(&format!("SS1-{}", key[4..].replace('A', "Ａ"))),
        Failure::BadEncoding
    );
}

#[test]
fn ss2_plans_and_expiry() {
    let monthly = read(v2("monthly"), &test_key(), 1, false).unwrap();
    assert_eq!(
        (monthly.plan, monthly.issued_at_ms, monthly.expires_at_ms),
        ("monthly", ISSUED, Some(EXPIRES))
    );
    assert_eq!(
        (monthly.id.as_str(), monthly.name.as_deref()),
        ("00112233445566778899aabbccddeeff", Some("Zoë M."))
    );
    assert!(monthly.is_active(EXPIRES - 1) && !monthly.is_active(EXPIRES));
    assert!(verify(v2("monthly"), &test_key(), 1, false, EXPIRES - 60_000).is_ok());
    assert_eq!(
        verify(v2("monthly"), &test_key(), 1, false, EXPIRES),
        Err(Failure::Expired)
    );
    let life = read(v2("lifetime"), &test_key(), 1, false).unwrap();
    assert!(life.plan == "lifetime" && life.expires_at_ms.is_none() && life.name.is_none());
    assert_eq!(life.id, "ffeeddccbbaa99887766554433221100");
    assert!(verify(v2("lifetime"), &test_key(), 1, false, i64::MAX / 2).is_ok());
    assert_eq!(
        read(v2("lifetimeTest"), &test_key(), 1, false),
        Err(Failure::TestKey)
    );
    assert!(
        read(v2("lifetimeTest"), &test_key(), 1, true)
            .unwrap()
            .is_test
    );
    assert_eq!(
        read(v2("otherApp"), &test_key(), 1, false),
        Err(Failure::WrongApp)
    );
    assert!(
        read(
            &format!("SS1-{}", &v2("monthly")[4..]),
            &test_key(),
            1,
            false
        )
        .is_err()
    );
    // Production key refuses a key signed by the test pair.
    assert!(verify_now(v2("monthly"), ISSUED).is_err());
    assert_eq!(
        read(
            &format!("  {}\n", v2("lifetime").to_lowercase()),
            &test_key(),
            1,
            false
        )
        .unwrap()
        .id,
        life.id
    );
    let mut chars: Vec<char> = v2("monthly").chars().collect();
    for i in (4..chars.len() - 1).step_by(17) {
        let old = chars[i];
        chars[i] = if old == 'A' { 'B' } else { 'A' };
        assert!(
            check(&chars.iter().collect::<String>(), 1, false).is_err(),
            "position {i}"
        );
        chars[i] = old;
    }
}

#[test]
fn keys_and_base32() {
    assert!(verify(v1("swiftlyNamed"), &[7; 32], 1, false, 0).is_err());
    assert_eq!(
        read(v1("swiftlyNamed"), &[], 1, false),
        Err(Failure::BadPublicKey)
    );
    assert!(decode_public_key("broken").is_none());
    assert!(decode_public_key("AAAA").is_none());
    assert_eq!(public_key().len(), 32);
    assert_eq!(base32_decode(b"MY"), Some(vec![0x66]));
    assert_eq!(base32_decode(b"MZ"), None);
    assert_eq!(base32_decode(b"M"), None);
    assert_eq!(base32_decode(b"my-"), Some(vec![0x66]));
}
