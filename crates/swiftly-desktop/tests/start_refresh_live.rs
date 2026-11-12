//! Start fetches its rows again when it comes to the front after the 30 s grace period of the Mac (a change made on
//! another device shows up), and does not while the rows are fresh. One fixture server; the app talks to it over the
//! real network. Needs `target/debug/xtask`
//! (`cargo build -p xtask`); without it the test says so and passes. Runs in a child process with a temporary
//! `SWIFTLY_CONFIG_DIR` (file secrets, no keychain).

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_desktop::live::Core;
use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const TEST: &str = "start_refetches_after_the_grace_period_when_it_comes_back";

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
    fn start(xtask: &std::path::Path, id: &str, log: PathBuf) -> (Fixture, String) {
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .expect("port")
            .local_addr()
            .expect("addr")
            .port();
        let file = std::fs::File::create(&log).expect("log");
        let child = Command::new(xtask)
            .args(["fixture-server", "--port", &port.to_string()])
            .env("SWIFTLY_FIXTURE_ID", id)
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

/// Runs frames for `secs` seconds of wall time; returns how many opaque picture quads the last frame drew.
fn run(suite: &mut Suite, start: &Instant, secs: f64) -> usize {
    let until = start.elapsed().as_secs_f64() + secs;
    let mut shown = 0;
    while start.elapsed().as_secs_f64() < until {
        let (list, _) = suite.frame(start.elapsed().as_secs_f64() * 1000.0);
        let _ = &list;
        shown = suite.pictures_placed();
        std::thread::sleep(Duration::from_millis(16));
    }
    shown
}

#[test]
fn start_refetches_after_the_grace_period_when_it_comes_back() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir =
            std::env::temp_dir().join(format!("swiftly-start-refresh-{}", std::process::id()));
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
        std::env::temp_dir().join(format!("swiftly-start-refresh-logs-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&tmp);
    let (fx, addr) = Fixture::start(&xtask, "fx-r", tmp.join("r.log"));
    let core = Arc::new(Core::open().expect("core"));
    let backend = core.sign_in_backend();
    let wait = Duration::from_secs(30);
    backend
        .connect(&addr)
        .0
        .recv_timeout(wait)
        .expect("connect")
        .expect("address");
    backend
        .password("demo", "demo")
        .0
        .recv_timeout(wait)
        .expect("password")
        .expect("sign-in");
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut suite = Suite::new_live(env, Cx::new(), Arc::clone(&core));
    let clock = Instant::now();
    let now = |c: &Instant| c.elapsed().as_secs_f64() * 1000.0;

    run(&mut suite, &clock, 4.0);
    let first = fx.resumes();
    assert!(first > 0, "Start did not load");

    // Within the grace period: Filme and back does not ask again.
    assert!(suite.goto_tab(1, now(&clock)));
    run(&mut suite, &clock, 1.5);
    assert!(suite.goto_tab(0, now(&clock)));
    run(&mut suite, &clock, 2.0);
    assert_eq!(fx.resumes(), first, "fresh rows were fetched again");

    // After 30 s: coming back to Start asks the server again.
    assert!(suite.goto_tab(1, now(&clock)));
    run(&mut suite, &clock, 28.0);
    assert!(suite.goto_tab(0, now(&clock)));
    run(&mut suite, &clock, 4.0);
    assert!(
        fx.resumes() > first,
        "stale rows were not fetched again: {:?}",
        fx.lines()
    );
}
