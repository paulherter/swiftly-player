//! Settings and accounts of the real app over a temporary `SWIFTLY_CONFIG_DIR` (no keychain): the Settings screen reads
//! and writes `settings.json`, the account list/switch/sign-out go through the bundles in the secret store.

use swiftly_accounts::{Account, AccountBundle, ServerBundles, load_bundles, save_bundles};
use swiftly_desktop::live::Core;
use swiftly_desktop::settings_screen::SettingsScreen;
use swiftly_jellyfin::{ServerKind, Session};
use swiftly_layout::Size;
use swiftly_settings::{JsonFileStore, KeyValueStore, Value};
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::{RowControl, SettingsIntent};

fn session(user: &str, server: &str, kind: ServerKind) -> Session {
    Session {
        access_token: format!("tok-{user}"),
        user_id: format!("id-{user}"),
        user_name: user.into(),
        server_url: server.into(),
        kind,
    }
}

fn has_row(s: &SettingsScreen, key: &str) -> bool {
    s.vm()
        .sections()
        .sections
        .iter()
        .flat_map(|x| &x.rows)
        .any(|r| r.key == key)
}

/// Runs the body in a child process whose environment points at a temporary config directory (setting the variable in
/// this process would need `unsafe`).
#[test]
fn settings_and_accounts_are_real() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir =
            std::env::temp_dir().join(format!("swiftly-live-accounts-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let me = std::env::current_exe().expect("exe");
        let out = std::process::Command::new(me)
            .args([
                "--exact",
                "settings_and_accounts_are_real",
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
    let core = Core::open().expect("core");
    assert!(core.accounts_list().is_empty());

    let mut jf = AccountBundle::new(Account::new(session(
        "anna",
        "https://a.example",
        ServerKind::Jellyfin,
    )));
    jf.record(Account::new(session(
        "ben",
        "https://b.example",
        ServerKind::Jellyfin,
    )));
    let emby = AccountBundle::new(Account::new(session(
        "cleo",
        "https://c.example",
        ServerKind::Emby,
    )));
    save_bundles(
        &*core.secrets,
        &ServerBundles::new(
            vec![(ServerKind::Jellyfin, jf), (ServerKind::Emby, emby)],
            ServerKind::Jellyfin,
        ),
    );

    let list = core.accounts_list();
    assert_eq!(
        list.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
        ["anna", "ben", "cleo"]
    );
    assert_eq!(core.active_entry().map(|e| e.name), Some("ben".to_owned()));
    assert_eq!(core.account().map(|a| a.user_id), Some("id-ben".to_owned()));

    // Switching moves the active account (also across kinds) and is stored.
    assert!(core.switch_account(&list[0].key));
    assert_eq!(
        core.account().map(|a| a.user_id),
        Some("id-anna".to_owned())
    );
    assert!(core.switch_account(&list[2].key));
    assert_eq!(
        core.account().map(|a| a.server_kind),
        Some(ServerKind::Emby)
    );
    assert!(!core.switch_account("nobody|x"));

    // Settings: real file, server-dependent rows follow the active kind.
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let emby_screen = SettingsScreen::live(env, Cx::deterministic(), &core, true);
    assert!(!has_row(&emby_screen, "seerr") && !has_row(&emby_screen, "einstellungenSync"));
    assert!(core.switch_account(&list[1].key));
    let screen = SettingsScreen::live(env, Cx::deterministic(), &core, true);
    assert!(has_row(&screen, "seerr"));
    let row = screen
        .vm()
        .sections()
        .sections
        .iter()
        .flat_map(|x| &x.rows)
        .find(|r| r.key == "alphabetAn")
        .cloned()
        .expect("row");
    assert!(matches!(row.control, RowControl::Switch { on: true }));
    screen
        .vm()
        .send(SettingsIntent::SetSwitch {
            key: "alphabetAn".into(),
            on: false,
        })
        .expect("set");
    let file = JsonFileStore::open(dir.join("settings.json")).expect("file");
    assert!(
        file.keys().iter().any(|k| k.starts_with("alphabetAn")),
        "keys: {:?}",
        file.keys()
    );
    assert!(
        file.keys()
            .iter()
            .filter(|k| k.starts_with("alphabetAn"))
            .all(|k| file.get(k) == Some(Value::Bool(false)))
    );

    // Sign-out removes one account; the next one takes over; the last one leaves none.
    core.sign_out_account(&list[1].key);
    assert_eq!(core.accounts_list().len(), 2);
    assert!(core.active_entry().is_some());
    assert!(
        load_bundles(&*core.secrets)
            .bundle(ServerKind::Jellyfin)
            .is_some_and(|b| b.accounts().len() == 1)
    );
    for e in core.accounts_list() {
        core.sign_out_account(&e.key);
    }
    assert!(core.accounts_list().is_empty() && core.account().is_none());
}
