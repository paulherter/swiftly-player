//! The very first sign-in of the real app: no account exists, the sign-in page is the whole window, the user types a
//! server and a name, and Start must load its rows. (The Mac once left Start empty here: its first load ran while the
//! sign-in transition was still on and nothing loaded afterwards.) One fixture server over the real network; needs
//! `target/debug/xtask` (`cargo build -p xtask`), without it the test says so and passes. Runs in a child process with a
//! temporary `SWIFTLY_CONFIG_DIR` (file secrets, no keychain).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::Duration;
use swiftly_desktop::live::Core;
use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const TEST: &str = "start_loads_after_the_very_first_sign_in";
const STEP: f64 = 1000.0 / 60.0;

struct Fixture {
    child: Child,
    log: PathBuf,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
impl Fixture {
    fn start(xtask: &std::path::Path, log: PathBuf) -> (Fixture, String) {
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .expect("port")
            .local_addr()
            .expect("addr")
            .port();
        let file = std::fs::File::create(&log).expect("log");
        let child = Command::new(xtask)
            .args(["fixture-server", "--port", &port.to_string()])
            .stdout(Stdio::null())
            .stderr(file)
            .spawn()
            .expect("fixture");
        std::thread::sleep(Duration::from_millis(800));
        (Fixture { child, log }, format!("http://127.0.0.1:{port}"))
    }
    fn lines(&self) -> Vec<String> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }
    /// Requests of the Continue watching row (what a Start load asks first).
    fn resumes(&self) -> usize {
        self.lines().iter().filter(|l| l.contains("Resume")).count()
    }
}

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// Runs frames until the control `key` is on the page (up to ten seconds).
fn until(s: &mut Suite, now: &mut f64, key: &str) {
    let began = std::time::Instant::now();
    while s.top_frame_of(key).is_none() {
        if began.elapsed() >= Duration::from_secs(10) {
            let (_, nodes) = s.a11y_nodes();
            let built = swiftly_desktop::a11y_bridge::build("", &nodes, 1.0);
            let labels: Vec<String> = built
                .update
                .nodes
                .iter()
                .filter_map(|(_, x)| x.label().map(str::to_owned))
                .collect();
            panic!("control {key} never appeared; the page shows {labels:?}");
        }
        run_for(s, now, 100.0);
    }
}

fn tap(s: &mut Suite, now: &mut f64, key: &str, settle: f64) {
    until(s, now, key);
    let f = s
        .top_frame_of(key)
        .unwrap_or_else(|| panic!("no control {key}"));
    let (x, y) = (f[0] + f[2] * 0.5, f[1] + f[3] * 0.5);
    s.pointer_move(x, y, *now);
    s.touch_down(x, y, *now);
    *now += 60.0;
    s.touch_up(x, y, *now);
    run_for(s, now, settle);
}

#[test]
fn start_loads_after_the_very_first_sign_in() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir =
            std::env::temp_dir().join(format!("swiftly-first-sign-in-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let out = Command::new(std::env::current_exe().expect("exe"))
            .args(["--exact", TEST, "--nocapture", "--test-threads=1"])
            .env("SWIFTLY_CONFIG_DIR", &dir)
            .output()
            .expect("child");
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
    let xtask = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../target/debug/xtask");
    if !xtask.exists() {
        println!("skipped: build xtask first (cargo build -p xtask)");
        return;
    }
    let tmp =
        std::env::temp_dir().join(format!("swiftly-first-sign-in-logs-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&tmp);
    let (fx, addr) = Fixture::start(&xtask, tmp.join("fx.log"));
    let core = Arc::new(Core::open().expect("core"));
    assert!(core.account().is_none(), "a fresh config has no account");
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = Suite::new_live(env, Cx::deterministic(), Arc::clone(&core));
    let mut now = 0.0;
    run_for(&mut s, &mut now, 2500.0);
    assert_eq!(
        s.form_open(),
        Some("login"),
        "the first run opens the sign-in"
    );
    assert_eq!(fx.resumes(), 0);

    // Kind, address, user and password, by pointer and text like a person.
    tap(&mut s, &mut now, "kind:0", 600.0);
    tap(&mut s, &mut now, "field:addr", 200.0);
    s.type_text(&addr);
    run_for(&mut s, &mut now, 200.0);
    tap(&mut s, &mut now, "connect", 2500.0);
    tap(&mut s, &mut now, "field:user", 200.0);
    s.type_text("demo");
    tap(&mut s, &mut now, "field:pass", 200.0);
    s.type_text("demo");
    run_for(&mut s, &mut now, 200.0);
    tap(&mut s, &mut now, "signin", 300.0);

    // The account is there and Start asks the server for its rows, without any further action.
    run_for(&mut s, &mut now, 5000.0);
    assert!(core.account().is_some(), "signed in: {:?}", fx.lines());
    assert!(s.sidebar_shown(), "the app is in front after the sign-in");
    assert!(
        fx.resumes() > 0,
        "Start never loaded after the first sign-in: {:?}",
        fx.lines()
    );
    assert!(
        s.pictures_placed() > 0 || fx.lines().iter().any(|l| l.contains("Items")),
        "Start shows no rows"
    );
}
