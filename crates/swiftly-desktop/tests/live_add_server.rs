//! Settings > "Server hinzufügen" in the real app (Core over a socket, a stored account): the address field has the
//! keyboard on arrival, through the suite's pointer and text path.
#![allow(clippy::unwrap_used)]

use std::io::{Read, Write};
use std::sync::Arc;
use swiftly_accounts::{Account, AccountBundle, ServerBundles, save_bundles};
use swiftly_desktop::live::Core;
use swiftly_desktop::suite::Suite;
use swiftly_jellyfin::{ServerKind, Session};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;

fn serve() -> String {
    serve_logged().0
}

fn serve_logged() -> (String, Arc<std::sync::atomic::AtomicUsize>) {
    let count = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let hits = Arc::clone(&count);
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            let hits = Arc::clone(&hits);
            std::thread::spawn(move || {
                let mut s = s;
                let mut buf = [0u8; 8192];
                let n = s.read(&mut buf).unwrap_or(0);
                if String::from_utf8_lossy(&buf[..n]).contains("Items") {
                    hits.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                }
                let body = r#"{"Items":[],"TotalRecordCount":0}"#;
                let _ = write!(
                    s,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            });
        }
    });
    (format!("http://{addr}"), count)
}

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
}

fn tap(s: &mut Suite, now: &mut f64, key: &str) {
    let f = s
        .top_frame_of(key)
        .unwrap_or_else(|| panic!("no control {key}"));
    let (x, y) = (f[0] + f[2] * 0.5, f[1] + f[3] * 0.5);
    s.pointer_move(x, y, *now);
    s.touch_down(x, y, *now);
    *now += 60.0;
    s.touch_up(x, y, *now);
    run_for(s, now, 700.0);
}

#[test]
fn add_server_address_field_has_the_keyboard_on_arrival_in_the_real_app() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir = std::env::temp_dir().join(format!("swiftly-live-add-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let me = std::env::current_exe().unwrap();
        let out = std::process::Command::new(me)
            .args([
                "--exact",
                "add_server_address_field_has_the_keyboard_on_arrival_in_the_real_app",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("SWIFTLY_CONFIG_DIR", &dir)
            .output()
            .unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(
            out.status.success(),
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let core = Arc::new(Core::open().unwrap());
    let session = Session {
        access_token: "tok".into(),
        user_id: "u1".into(),
        user_name: "demo".into(),
        server_url: serve(),
        kind: ServerKind::Jellyfin,
    };
    save_bundles(
        &*core.secrets,
        &ServerBundles::new(
            vec![(
                ServerKind::Jellyfin,
                AccountBundle::new(Account::new(session)),
            )],
            ServerKind::Jellyfin,
        ),
    );
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = Suite::new_live(env, Cx::deterministic(), core);
    let mut now = 0.0;
    run_for(&mut s, &mut now, 1500.0);
    assert!(s.open_settings(now));
    run_for(&mut s, &mut now, 1500.0);
    tap(&mut s, &mut now, "go:server");
    assert_eq!(s.form_open(), Some("login"));
    tap(&mut s, &mut now, "kind:0");
    assert!(s.wants_text(), "the address step takes text");
    assert_eq!(
        s.login_address().map(|a| a.1),
        Some(true),
        "the address field shows the keyboard"
    );
    s.type_text("jelly.example.org");
    run_for(&mut s, &mut now, 100.0);
    assert_eq!(
        s.login_address().map(|a| a.0).as_deref(),
        Some("jelly.example.org")
    );
}

/// Runs `name` again in a child process with a temporary config directory (no keychain, no stored account).
fn in_child(name: &str) -> bool {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_some() {
        return false;
    }
    let dir = std::env::temp_dir().join(format!("swiftly-live-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", name, "--nocapture", "--test-threads=1"])
        .env("SWIFTLY_CONFIG_DIR", &dir)
        .output()
        .unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        out.status.success(),
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    true
}

fn labels(s: &Suite) -> Vec<String> {
    let (_, nodes) = s.a11y_nodes();
    let built = swiftly_desktop::a11y_bridge::build("", &nodes, 1.0);
    built
        .update
        .nodes
        .iter()
        .filter_map(|(_, x)| x.label().map(str::to_owned))
        .collect()
}

#[test]
fn first_run_sign_in_has_no_sidebar_until_signed_in() {
    if in_child("first_run_sign_in_has_no_sidebar_until_signed_in") {
        return;
    }
    let core = Arc::new(Core::open().unwrap());
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = Suite::new_live(env, Cx::deterministic(), Arc::clone(&core));
    let mut now = 0.0;
    run_for(&mut s, &mut now, 800.0);
    assert_eq!(s.form_open(), Some("login"), "first run opens the sign-in");
    assert!(!s.sidebar_shown(), "no sidebar before an account exists");
    let l = labels(&s);
    assert!(
        !l.iter()
            .any(|x| x == "Filme" || x == "Serien" || x == "Merkliste"),
        "no sidebar rows for a screen reader: {l:?}"
    );
    // The sign-in page uses the whole window: its first card sits left of where the sidebar would end.
    let f = s.top_frame_of("kind:0").expect("kind card");
    assert!(f[0] + f[2] > 0.0 && f[0] >= 0.0);
    // With a stored account the sidebar is there.
    let session = Session {
        access_token: "tok".into(),
        user_id: "u1".into(),
        user_name: "demo".into(),
        server_url: serve(),
        kind: ServerKind::Jellyfin,
    };
    save_bundles(
        &*core.secrets,
        &ServerBundles::new(
            vec![(
                ServerKind::Jellyfin,
                AccountBundle::new(Account::new(session)),
            )],
            ServerKind::Jellyfin,
        ),
    );
    let mut s = Suite::new_live(env, Cx::deterministic(), core);
    run_for(&mut s, &mut now, 1500.0);
    assert!(s.sidebar_shown(), "the sidebar is there once signed in");
}

#[test]
fn start_loads_again_after_a_list_change_once_it_is_in_front() {
    if in_child("start_loads_again_after_a_list_change_once_it_is_in_front") {
        return;
    }
    let core = Arc::new(Core::open().unwrap());
    let (url, hits) = serve_logged();
    let session = Session {
        access_token: "tok".into(),
        user_id: "u1".into(),
        user_name: "demo".into(),
        server_url: url,
        kind: ServerKind::Jellyfin,
    };
    save_bundles(
        &*core.secrets,
        &ServerBundles::new(
            vec![(
                ServerKind::Jellyfin,
                AccountBundle::new(Account::new(session)),
            )],
            ServerKind::Jellyfin,
        ),
    );
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = Suite::new_live(env, Cx::deterministic(), core);
    let mut now = 0.0;
    run_for(&mut s, &mut now, 2000.0);
    let count = || hits.load(std::sync::atomic::Ordering::SeqCst);
    let base = count();
    assert!(base > 0, "Start loaded once at the start");
    run_for(&mut s, &mut now, 1000.0);
    assert_eq!(count(), base, "nothing reloads on its own");

    // A page is in front: the change waits.
    assert!(s.open_settings(now));
    run_for(&mut s, &mut now, 1500.0);
    swiftly_desktop::desk::note_list_change();
    run_for(&mut s, &mut now, 1000.0);
    assert_eq!(count(), base, "Start does not load while a page covers it");
    s.back(now);
    run_for(&mut s, &mut now, 2000.0);
    let after = count();
    assert!(
        after > base,
        "back on Start the list is fetched again ({base} -> {after})"
    );
    run_for(&mut s, &mut now, 1000.0);
    assert_eq!(count(), after, "one load per change");

    // Start is in front: it loads at once.
    swiftly_desktop::desk::note_list_change();
    run_for(&mut s, &mut now, 1500.0);
    assert!(
        count() > after,
        "a change with Start in front loads at once"
    );
}
