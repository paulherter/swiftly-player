//! Settings > Wiedergabe in the real app (Core with the settings file, a stored account, the suite's pointer path): every
//! playback switch flips at once. The Mac froze here once because the settings feed waited on a write queue on the main
//! thread; the desktop writes the file itself, and this keeps a blocking wait out of that path: each tap, with the
//! frames it causes, must return fast, and the flip must be in the settings file.
#![allow(clippy::unwrap_used)]

use std::io::{Read, Write};
use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_accounts::{Account, AccountBundle, ServerBundles, save_bundles};
use swiftly_desktop::live::Core;
use swiftly_desktop::settings_screen::SettingsScreen;
use swiftly_desktop::suite::Suite;
use swiftly_jellyfin::{ServerKind, Session};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};
use swiftly_vm::RowControl;

const STEP: f64 = 1000.0 / 60.0;
/// A flip is a file write and a few frames; anything near a second would be a wait on something else.
const LIMIT: Duration = Duration::from_millis(400);

fn serve() -> String {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            std::thread::spawn(move || {
                let mut s = s;
                let mut buf = [0u8; 8192];
                let _ = s.read(&mut buf);
                let body = r#"{"Items":[],"TotalRecordCount":0}"#;
                let _ = write!(
                    s,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            });
        }
    });
    format!("http://{addr}")
}

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// The state of the switch `key` as a page built now reads it from the settings file.
fn is_on(core: &Core, env: Env, key: &str) -> Option<bool> {
    let mut page = SettingsScreen::live(env, Cx::deterministic(), core, true);
    page.open_page("playback");
    page.vm()
        .sections()
        .sections
        .iter()
        .flat_map(|s| s.rows.iter())
        .find(|r| r.key == key)
        .and_then(|r| match r.control {
            RowControl::Switch { on } => Some(on),
            _ => None,
        })
}

/// Taps the control `key`; returns how long the press, the release and the next frames took (the sleeps excluded).
fn tap(s: &mut Suite, now: &mut f64, key: &str) -> Duration {
    let f = s
        .top_frame_of(key)
        .unwrap_or_else(|| panic!("no control {key}"));
    let (x, y) = (f[0] + f[2] * 0.5, f[1] + f[3] * 0.5);
    s.pointer_move(x, y, *now);
    let t = Instant::now();
    s.touch_down(x, y, *now);
    *now += 60.0;
    s.touch_up(x, y, *now);
    for _ in 0..3 {
        *now += STEP;
        let _ = s.frame(*now);
    }
    t.elapsed()
}

#[test]
fn every_playback_switch_flips_without_a_wait() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir =
            std::env::temp_dir().join(format!("swiftly-live-switches-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "every_playback_switch_flips_without_a_wait",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("SWIFTLY_CONFIG_DIR", &dir)
            .output()
            .unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        println!("{text}");
        assert!(out.status.success(), "{text}");
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
    // A tall window, so every row of the page is on screen and needs no scrolling.
    let env = Env::new(Size::new(1280.0, 2600.0), 1.0, Idiom::Desktop);

    // The switch rows of the page, as the page itself lists them.
    let mut page = SettingsScreen::live(env, Cx::deterministic(), &core, true);
    page.open_page("playback");
    let keys: Vec<&'static str> = page
        .vm()
        .sections()
        .sections
        .iter()
        .filter(|s| {
            ["Ablauf", "Im Player", "Verhalten", "Qualität", "Sprache"].contains(&s.title_key)
        })
        .flat_map(|s| s.rows.iter())
        .filter(|r| r.enabled && matches!(r.control, RowControl::Switch { .. }))
        .map(|r| r.key)
        .collect();
    assert!(
        keys.len() >= 4,
        "the Wiedergabe page lists its switches: {keys:?}"
    );

    let mut s = Suite::new_live(env, Cx::deterministic(), Arc::clone(&core));
    let mut now = 0.0;
    run_for(&mut s, &mut now, 1500.0);
    assert!(s.open_settings(now));
    run_for(&mut s, &mut now, 1200.0);
    tap(&mut s, &mut now, "go:playback");
    run_for(&mut s, &mut now, 800.0);

    let mut slowest = Duration::ZERO;
    for key in &keys {
        let row = format!("row:{key}");
        let before = is_on(&core, env, key);
        let took = tap(&mut s, &mut now, &row);
        slowest = slowest.max(took);
        let after = is_on(&core, env, key);
        assert_ne!(before, after, "{key}: the flip is not in the settings file");
        assert!(took < LIMIT, "{key}: flipping took {took:?}");
        // And back: the page still answers and the file follows.
        let took = tap(&mut s, &mut now, &row);
        slowest = slowest.max(took);
        assert!(took < LIMIT, "{key}: flipping back took {took:?}");
        let again = is_on(&core, env, key);
        assert_ne!(
            after, again,
            "{key}: the second flip did not reach the settings file"
        );
    }
    println!(
        "flipped {} switches twice, slowest tap {slowest:?}: {keys:?}",
        keys.len()
    );
}
