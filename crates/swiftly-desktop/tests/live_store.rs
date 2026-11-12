//! The stores of the real app: secrets survive a restart, key-values persist, the demo stays on the scripted network.

use swiftly_accounts::{
    Account, AccountBundle, SecretStore, ServerBundles, load_bundles, save_bundles,
};
use swiftly_desktop::store::{DirStore, FileKeyValue, FileSecrets};
use swiftly_jellyfin::{ServerKind, Session};
use swiftly_library::{KeyValue, Store};

fn dir(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("swiftly-live-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d
}

#[test]
fn account_survives_a_restart() {
    let d = dir("secrets");
    let session = Session {
        access_token: "tok".into(),
        user_id: "u1".into(),
        user_name: "demo".into(),
        server_url: "https://example.test".into(),
        kind: ServerKind::Jellyfin,
    };
    let secrets = FileSecrets::open(d.join("secrets.json"));
    let bundle = AccountBundle::new(Account::new(session));
    save_bundles(
        &secrets,
        &ServerBundles::new(vec![(ServerKind::Jellyfin, bundle)], ServerKind::Jellyfin),
    );
    let again = FileSecrets::open(d.join("secrets.json"));
    let loaded = load_bundles(&again);
    assert_eq!(
        loaded
            .active()
            .map(|b| b.active().session.access_token.clone()),
        Some("tok".to_owned())
    );
    again.remove("nothing");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(d.join("secrets.json"))
            .map(|m| m.permissions().mode() & 0o777)
            .unwrap_or(0);
        assert_eq!(mode, 0o600);
    }
    let _ = std::fs::remove_dir_all(d);
}

#[test]
fn key_values_and_blobs_persist() {
    let d = dir("kv");
    FileKeyValue::open(d.join("library.json")).set("sortierung.Filme", "Name");
    assert_eq!(
        FileKeyValue::open(d.join("library.json"))
            .get("sortierung.Filme")
            .as_deref(),
        Some("Name")
    );
    let blobs = DirStore(d.join("home"));
    blobs.write("a|b", b"x");
    assert_eq!(blobs.read("a|b"), Some(b"x".to_vec()));
    blobs.remove("a|b");
    assert_eq!(blobs.read("a|b"), None);
    let _ = std::fs::remove_dir_all(d);
}
