//! A damaged settings, secrets or download-list file never stops the app: the file is kept as `<name>.broken-<time>`,
//! the app starts with defaults, one line goes to `crash.log`, and what lives elsewhere (the accounts) stays.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use swiftly_accounts::{Account, AccountBundle, ServerBundles, save_bundles};
use swiftly_desktop::live::Core;
use swiftly_jellyfin::{ServerKind, Session};
use swiftly_settings::{JsonFileStore, KeyValueStore, Value};

fn broken_copies(dir: &std::path::Path, name: &str) -> Vec<std::path::PathBuf> {
    std::fs::read_dir(dir)
        .expect("dir")
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .is_some_and(|n| n.to_string_lossy().starts_with(&format!("{name}.broken-")))
        })
        .collect()
}

/// Runs the body in a child process whose environment points at a temporary config directory.
#[test]
fn a_damaged_file_does_not_stop_the_start() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir =
            std::env::temp_dir().join(format!("swiftly-damaged-files-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let me = std::env::current_exe().expect("exe");
        let out = std::process::Command::new(me)
            .args([
                "--exact",
                "a_damaged_file_does_not_stop_the_start",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("SWIFTLY_CONFIG_DIR", &dir)
            .output()
            .expect("child");
        let _ = std::fs::remove_dir_all(&dir);
        assert!(
            out.status.success(),
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let dir = std::path::PathBuf::from(std::env::var_os("SWIFTLY_CONFIG_DIR").expect("dir"));

    // A first run: one account and one setting.
    {
        let core = Core::open().expect("core");
        let bundle = AccountBundle::new(Account::new(Session {
            access_token: "tok".into(),
            user_id: "id".into(),
            user_name: "anna".into(),
            server_url: "https://a.example".into(),
            kind: ServerKind::Jellyfin,
        }));
        save_bundles(
            &*core.secrets,
            &ServerBundles::new(vec![(ServerKind::Jellyfin, bundle)], ServerKind::Jellyfin),
        );
    }
    let accounts_before = {
        let core = Core::open().expect("core");
        core.accounts_list().len()
    };
    assert_eq!(accounts_before, 1);

    // Damaged settings (the shape that stopped the Windows app: a key without quotes) and a damaged download list.
    let bad = r#"{technikschild:true}"#;
    std::fs::write(dir.join("settings.json"), bad).expect("write");
    std::fs::write(dir.join("liste.json"), "[{\"id\":").expect("write");
    let core = Core::open().expect("the app starts with defaults");
    assert_eq!(core.accounts_list().len(), accounts_before, "accounts stay");
    let kept = broken_copies(&dir, "settings.json");
    assert_eq!(kept.len(), 1, "{kept:?}");
    assert_eq!(std::fs::read_to_string(&kept[0]).expect("copy"), bad);
    let log = std::fs::read_to_string(dir.join("crash.log")).unwrap_or_default();
    assert_eq!(log.matches("settings recovered").count(), 1, "{log}");
    assert!(log.contains("kept as"), "{log}");
    // The new file is good and takes writes; a second start finds nothing to recover.
    let store = JsonFileStore::open(dir.join("settings.json")).expect("a good file again");
    assert!(store.get("technikschild").is_none());
    store.set("x", Value::Bool(true)).expect("set");
    drop(store);
    drop(core);
    let _again = Core::open().expect("core");
    assert_eq!(broken_copies(&dir, "settings.json").len(), 1);
    drop(_again);

    // A damaged secrets file: kept aside, the app starts without accounts instead of replacing the only copy.
    std::fs::write(dir.join("secrets.json"), "{\"a\":").expect("write");
    let core = Core::open().expect("core");
    assert!(core.accounts_list().is_empty());
    assert_eq!(broken_copies(&dir, "secrets.json").len(), 1);
    drop(core);

    // The download list is set aside when something reads it.
    assert!(!swiftly_desktop::live_downloads::on_device(&dir, "a", "b"));
    assert_eq!(broken_copies(&dir, "liste.json").len(), 1);
}
