//! The Windows uninstaller's promises, checked on the script text (`makensis` only runs on the build machines): the lock
//! file always goes, the user's data and the stored sign-ins only on request, and the vault entries are found by the
//! service name the app writes them under.
#![allow(clippy::expect_used)]

const NSI: &str = include_str!("../../../Distribution/desktop/swiftly-player.nsi");
const STORE: &str = include_str!("../src/store.rs");

fn uninstall_section() -> &'static str {
    let from = NSI
        .find("Section \"Uninstall\"")
        .expect("uninstall section");
    &NSI[from..]
}

#[test]
fn the_lock_file_is_always_removed_and_the_data_only_on_request() {
    let sec = uninstall_section();
    let purge_at = sec.find("${If} $Purge == 1").expect("a purge branch");
    let lock_at = sec
        .find("Delete \"$LOCALAPPDATA\\Swiftly\\swiftly-desktop.lock\"")
        .expect("the lock file is deleted");
    assert!(lock_at < purge_at, "the lock goes whatever the box says");
    let branch = &sec[purge_at..];
    assert!(branch.contains("RMDir /r \"$APPDATA\\Swiftly\""));
    assert!(
        branch.contains("cmdkey /delete"),
        "the vault entries go with the data"
    );
    let before = &sec[..purge_at];
    assert!(!before.contains("$APPDATA"), "settings stay unless asked");
}

#[test]
fn the_choice_is_off_by_default_and_a_silent_uninstall_needs_the_flag() {
    assert!(NSI.contains("UninstPage custom un.PurgePage un.PurgeLeave"));
    assert!(NSI.contains("Auch Anmeldungen, Einstellungen und Downloads entfernen"));
    assert!(NSI.contains("\"/PURGE\""));
    let init = NSI.find("Function un.onInit").expect("un.onInit");
    assert!(
        NSI[init..].starts_with("Function un.onInit\n  StrCpy $Purge 0"),
        "off by default"
    );
}

#[test]
fn the_vault_entries_are_found_by_the_service_name_the_app_uses() {
    assert!(STORE.contains("const SERVICE: &str = \"de.swiftly.player\";"));
    assert!(uninstall_section().contains(r"\.de\.swiftly\.player"));
}
