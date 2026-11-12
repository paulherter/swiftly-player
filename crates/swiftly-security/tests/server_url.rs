//! Server addresses typed by the user: odd schemes, userinfo and control characters are rejected;
//! local network addresses stay allowed (that is the point of the app).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use swiftly_jellyfin::normalize_server_url_string as normalize;

#[test]
fn rejects_odd_schemes() {
    for bad in [
        "file:///etc/passwd",
        "ftp://h.test",
        "javascript:alert(1)",
        "data:text/html,x",
        "gopher://h.test",
        "ws://h.test",
        "FILE://h/x",
    ] {
        let out = normalize(bad);
        assert!(
            out.as_deref()
                .is_none_or(|u| u.starts_with("http://") || u.starts_with("https://")),
            "{bad} -> {out:?}"
        );
        assert!(
            out.as_deref()
                .is_none_or(|u| !u.contains("file:") && !u.contains("javascript:")),
            "{bad} -> {out:?}"
        );
    }
}

#[test]
fn rejects_userinfo_and_control_characters() {
    for bad in [
        "https://user:pw@h.test",
        "https://user@h.test:8096/",
        "http://h.test\r\nHost: evil",
        "http://h.test/\u{0}",
        "http://h.test/\n",
        "http://h .test",
        "https://h.test\t",
        "http://[::1",
        "http://h.test:99999",
        "http://",
        "http://:8096",
    ] {
        let out = normalize(bad);
        match out {
            None => {}
            Some(u) => {
                assert!(!u.contains('@'), "userinfo kept: {bad} -> {u}");
                assert!(
                    !u.chars().any(char::is_control),
                    "control char kept: {bad:?} -> {u:?}"
                );
            }
        }
    }
}

#[test]
fn local_network_addresses_are_allowed() {
    for ok in [
        "http://192.168.1.10:8096",
        "http://10.0.0.5",
        "http://localhost:8096",
        "http://[fe80::1]:8096",
        "https://nas.local:8920/jellyfin",
        "192.168.1.10:8096",
        "jellyfin.example.com",
    ] {
        assert!(normalize(ok).is_some(), "{ok} must stay allowed");
    }
}
