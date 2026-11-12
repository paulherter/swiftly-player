//! The one-time take-over of the sign-ins of the old Windows/Linux GTK app (`Linux/Sources/SwiftlyLinux/Cache.swift`).
//!
//! The old app keeps plain files in the same folder the new one uses (`%APPDATA%\Swiftly`, `~/.config/swiftly`):
//! `konten.json` (Jellyfin bundle), `konten.emby.json`, `konten.plex.json`, `aktiveArt` (which kind is current),
//! `sitzung.json` (the single session from before bundles, German keys), `seerr.json` and `eigenkoepfe.json` (own
//! headers). The new app reads them once, on first start, into its own store (system vault, else the private file) and
//! then leaves a marker `legacy-import.done`. **The old files are only read, never changed or deleted**, so the old app
//! keeps working next to the new one.
//!
//! One decision function ([`decide`]) with a test table; the I/O around it is thin.

use crate::store::config_dir;
use std::path::Path;
use swiftly_accounts::{AccountBundle, SecretStore, ServerBundles, load_bundles, save_bundles};
use swiftly_seerr::SeerrAccess;
use swiftly_settings::{JsonFileStore, KeyValueStore, Value};

/// The marker a finished take-over leaves in the config folder (its text names what was taken over, no secrets).
pub const MARKER: &str = "legacy-import.done";

/// What the facts allow.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// The take-over ran before (marker there): never again, a sign-out in the new app must stay a sign-out.
    AlreadyDone,
    /// The new store has sign-ins of its own: keep them, write the marker.
    KeepNew,
    /// Nothing old to take over: leave no marker (an old store may still appear).
    NothingOld,
    /// Take the old sign-ins over.
    Import,
}

/// The facts of one start.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Facts {
    /// The marker file exists.
    pub marker: bool,
    /// The new store already holds an account bundle.
    pub new_has_accounts: bool,
    /// The old files hold a readable sign-in.
    pub old_has_accounts: bool,
}

/// The one place that decides.
pub fn decide(f: Facts) -> Step {
    match f {
        Facts { marker: true, .. } => Step::AlreadyDone,
        Facts {
            new_has_accounts: true,
            ..
        } => Step::KeepNew,
        Facts {
            old_has_accounts: false,
            ..
        } => Step::NothingOld,
        _ => Step::Import,
    }
}

/// What a run did (for the log and the tests).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    /// The step taken.
    pub step: Step,
    /// Account bundles taken over (kinds).
    pub kinds: usize,
    /// The Seerr sign-in was taken over.
    pub seerr: bool,
    /// The own-header table was taken over.
    pub headers: bool,
}

/// Reads the old bundles from `read` (a file name to its bytes). The single session `sitzung.json` stands in for a
/// missing Jellyfin bundle (older versions of the old app).
fn old_bundles(read: &dyn Fn(&str) -> Option<Vec<u8>>) -> ServerBundles {
    // `ServerBundles::load` asks for the keys `konten`, `konten.emby`, `konten.plex`, `aktiveArt`; on disk the
    // bundle files carry `.json`, the pointer does not.
    let mut all = ServerBundles::load(|key| {
        if key == swiftly_accounts::POINTER_KEY {
            read(key)
        } else {
            read(&format!("{key}.json"))
        }
    });
    if all.bundle(swiftly_jellyfin::ServerKind::Jellyfin).is_none()
        && let Some(account) =
            read("sitzung.json").and_then(|d| AccountBundle::from_old_gtk_store(&d))
    {
        let active = all.active_kind();
        all.set(
            Some(AccountBundle::new(account)),
            swiftly_jellyfin::ServerKind::Jellyfin,
        );
        if all.bundle(active).is_some() {
            all.switch_to(active);
        }
    }
    all
}

/// Runs the take-over for the folder `dir` into `secrets` and `settings`. Reads from `dir`, writes only the marker
/// there.
pub fn run_in(dir: &Path, secrets: &dyn SecretStore, settings: &JsonFileStore) -> Report {
    // A file saved by a Windows editor may start with a UTF-8 byte order mark, which JSON parsing rejects.
    let read = |name: &str| {
        std::fs::read(dir.join(name)).ok().map(|d| {
            d.strip_prefix(b"\xEF\xBB\xBF")
                .map(<[u8]>::to_vec)
                .unwrap_or(d)
        })
    };
    let old = old_bundles(&read);
    let facts = Facts {
        marker: dir.join(MARKER).exists(),
        new_has_accounts: !load_bundles(secrets).is_empty(),
        old_has_accounts: !old.is_empty(),
    };
    let step = decide(facts);
    let mut report = Report {
        step,
        kinds: 0,
        seerr: false,
        headers: false,
    };
    match step {
        Step::AlreadyDone | Step::NothingOld => return report,
        Step::KeepNew => {
            let _ = std::fs::write(dir.join(MARKER), "kept: the new store had accounts\n");
            return report;
        }
        Step::Import => {}
    }
    save_bundles(secrets, &old);
    report.kinds = old.kinds().len();
    // Seerr: the same JSON the new app keeps (`{"adresse","keks"}`), checked before it is taken.
    if settings.get("seerr").is_none()
        && let Some(raw) = read("seerr.json")
        && serde_json::from_slice::<SeerrAccess>(&raw).is_ok()
    {
        report.seerr = settings.set("seerr", Value::Data(raw)).is_ok();
    }
    // Own headers: the table text of `OwnHeaders.store()`; valid JSON object only.
    if settings.get("net.ownHeaders").is_none()
        && let Some(raw) = read("eigenkoepfe.json")
        && serde_json::from_slice::<serde_json::Map<String, serde_json::Value>>(&raw)
            .is_ok_and(|m| !m.is_empty())
        && let Ok(text) = String::from_utf8(raw)
    {
        report.headers = settings.set("net.ownHeaders", Value::Str(text)).is_ok();
    }
    let note = format!(
        "imported: {} account kinds, seerr {}, headers {}\n",
        report.kinds, report.seerr, report.headers
    );
    let _ = std::fs::write(dir.join(MARKER), note);
    report
}

/// The start hook: Windows and Linux only (the old app never ran on a Mac).
pub fn run_at_start(secrets: &dyn SecretStore, settings: &JsonFileStore) {
    if cfg!(target_os = "macos") {
        return;
    }
    let r = run_in(&config_dir(), secrets, settings);
    if r.step == Step::Import {
        eprintln!(
            "swiftly-desktop: took over {} sign-in kind(s) of the old app (old files untouched)",
            r.kinds
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_accounts::MemorySecretStore;
    use swiftly_jellyfin::ServerKind;

    /// A recorded store of the old app (field names as `Cache.swift` writes them).
    const KONTEN: &str = r#"{"konten":[{"accessToken":"tok-a","userID":"u1","userName":"paul","serverURL":"https://jf.example.com"},{"accessToken":"tok-b","userID":"u2","userName":"eltern","serverURL":"https://jf.example.com"}],"aktiveKennung":"u2"}"#;
    const SITZUNG: &str = r#"{"serverURL":"https://old.example.com","token":"tok-old","benutzerID":"u9","benutzername":"anna","servername":"Alt"}"#;
    const SEERR: &str = r#"{"adresse":"https://seerr.example","keks":"connect.sid=abc"}"#;
    const HEADERS: &str =
        r#"{"https://jf.example.com":[{"name":"CF-Access-Client-Id","value":"x"}]}"#;

    fn tmp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("swiftly-legacy-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn snapshot(dir: &Path) -> Vec<(String, Vec<u8>)> {
        let mut v: Vec<_> = std::fs::read_dir(dir)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name() != MARKER && e.file_name() != "settings.json")
            .map(|e| {
                (
                    e.file_name().to_string_lossy().into_owned(),
                    std::fs::read(e.path()).unwrap(),
                )
            })
            .collect();
        v.sort();
        v
    }

    #[test]
    fn the_decision_table() {
        let f = |marker, new_has_accounts, old_has_accounts| {
            decide(Facts {
                marker,
                new_has_accounts,
                old_has_accounts,
            })
        };
        assert_eq!(f(true, false, true), Step::AlreadyDone);
        assert_eq!(f(true, true, true), Step::AlreadyDone);
        assert_eq!(f(false, true, true), Step::KeepNew);
        assert_eq!(f(false, true, false), Step::KeepNew);
        assert_eq!(f(false, false, false), Step::NothingOld);
        assert_eq!(f(false, false, true), Step::Import);
    }

    #[test]
    fn a_recorded_old_store_is_taken_over_and_left_untouched() {
        let dir = tmp("full");
        std::fs::write(dir.join("konten.json"), KONTEN).unwrap();
        std::fs::write(dir.join("aktiveArt"), "jellyfin").unwrap();
        std::fs::write(dir.join("sitzung.json"), SITZUNG).unwrap();
        std::fs::write(dir.join("seerr.json"), SEERR).unwrap();
        std::fs::write(dir.join("eigenkoepfe.json"), HEADERS).unwrap();
        let before = snapshot(&dir);
        let secrets = MemorySecretStore::new();
        let settings = JsonFileStore::open(dir.join("settings.json")).unwrap();
        let r = run_in(&dir, &secrets, &settings);
        assert_eq!(
            r,
            Report {
                step: Step::Import,
                kinds: 1,
                seerr: true,
                headers: true
            }
        );
        let got = load_bundles(&secrets);
        let bundle = got.bundle(ServerKind::Jellyfin).unwrap();
        assert_eq!(bundle.accounts().len(), 2);
        assert_eq!(bundle.active().session.user_id, "u2");
        assert_eq!(bundle.active().session.access_token, "tok-b");
        assert!(matches!(settings.get("seerr"), Some(Value::Data(d)) if d == SEERR.as_bytes()));
        assert!(matches!(settings.get("net.ownHeaders"), Some(Value::Str(s)) if s == HEADERS));
        assert!(dir.join(MARKER).exists());
        assert_eq!(
            snapshot(&dir),
            before,
            "the old files are byte for byte the same"
        );
        // Second start: nothing happens, even after a sign-out in the new app.
        for k in [ServerKind::Jellyfin, ServerKind::Emby, ServerKind::Plex] {
            secrets.remove(swiftly_accounts::bundle_storage_key(k));
        }
        assert_eq!(run_in(&dir, &secrets, &settings).step, Step::AlreadyDone);
        assert!(load_bundles(&secrets).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_single_session_of_an_old_version_is_mapped() {
        let dir = tmp("single");
        std::fs::write(dir.join("sitzung.json"), SITZUNG).unwrap();
        let secrets = MemorySecretStore::new();
        let settings = JsonFileStore::open(dir.join("settings.json")).unwrap();
        assert_eq!(run_in(&dir, &secrets, &settings).step, Step::Import);
        let got = load_bundles(&secrets);
        let a = got.bundle(ServerKind::Jellyfin).unwrap().active();
        assert_eq!(
            (
                a.session.access_token.as_str(),
                a.session.user_name.as_str()
            ),
            ("tok-old", "anna")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_byte_order_mark_does_not_hide_the_old_accounts() {
        let dir = tmp("bom");
        let mut data = b"\xEF\xBB\xBF".to_vec();
        data.extend_from_slice(KONTEN.as_bytes());
        std::fs::write(dir.join("konten.json"), data).unwrap();
        let secrets = MemorySecretStore::new();
        let settings = JsonFileStore::open(dir.join("settings.json")).unwrap();
        assert_eq!(run_in(&dir, &secrets, &settings).kinds, 1);
    }

    #[test]
    fn new_sign_ins_win_and_junk_or_nothing_imports_nothing() {
        let dir = tmp("keep");
        std::fs::write(dir.join("konten.json"), KONTEN).unwrap();
        let secrets = MemorySecretStore::new();
        secrets.set("konten", KONTEN.replace("tok-a", "tok-new").as_str());
        let settings = JsonFileStore::open(dir.join("settings.json")).unwrap();
        assert_eq!(run_in(&dir, &secrets, &settings).step, Step::KeepNew);
        assert!(secrets.get("konten").unwrap().contains("tok-new"));
        let _ = std::fs::remove_dir_all(&dir);

        let dir = tmp("junk");
        std::fs::write(dir.join("konten.json"), "not json").unwrap();
        let secrets = MemorySecretStore::new();
        let settings = JsonFileStore::open(dir.join("settings.json")).unwrap();
        assert_eq!(run_in(&dir, &secrets, &settings).step, Step::NothingOld);
        assert!(!dir.join(MARKER).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
