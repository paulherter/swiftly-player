//! Adding a second account and switching between two servers in the real app: the posters of the new account load and
//! the requests stop (no refetch loop). Two fixture servers (`SWIFTLY_FIXTURE_ID` makes the second one a different
//! server) on two ports; the app talks to them over the real network. Needs `target/debug/xtask`
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

const TEST: &str = "switching_accounts_keeps_posters_and_stops_requests";

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
    fn images(&self) -> usize {
        self.lines()
            .iter()
            .filter(|l| l.contains("/Images/"))
            .count()
    }
    fn items(&self) -> usize {
        self.lines()
            .iter()
            .filter(|l| l.contains("/Items") && !l.contains("/Images/"))
            .count()
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
fn switching_accounts_keeps_posters_and_stops_requests() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir = std::env::temp_dir().join(format!("swiftly-switch-live-{}", std::process::id()));
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
    let tmp = std::env::temp_dir().join(format!("swiftly-switch-logs-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&tmp);
    let (a, addr_a) = Fixture::start(&xtask, "fx-a", tmp.join("a.log"));
    let (b, addr_b) = Fixture::start(&xtask, "fx-b", tmp.join("b.log"));

    // Two stored accounts (the sign-in backend is what the sign-in screen uses; the second one becomes the active one).
    let core = Arc::new(Core::open().expect("core"));
    let backend = core.sign_in_backend();
    let wait = Duration::from_secs(30);
    for addr in [&addr_a, &addr_b] {
        backend
            .connect(addr)
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
    }
    let list = core.accounts_list();
    assert_eq!(list.len(), 2, "both accounts stored");
    let key_a = list
        .iter()
        .find(|e| e.server == addr_a)
        .expect("account a")
        .key
        .clone();
    let key_b = list
        .iter()
        .find(|e| e.server == addr_b)
        .expect("account b")
        .key
        .clone();

    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut suite = Suite::new_live(env, Cx::new(), Arc::clone(&core));
    let clock = Instant::now();

    // The active account (b) loads its pictures.
    let shown = run(&mut suite, &clock, 4.0);
    println!(
        "b start: pictures {shown}, images {}, items {}",
        b.images(),
        b.items()
    );
    assert!(shown > 0, "no pictures drawn for b");
    let (imgs_b, items_b) = (b.images(), b.items());
    run(&mut suite, &clock, 3.0);
    assert_eq!(
        (b.images(), b.items()),
        (imgs_b, items_b),
        "requests to b did not stop"
    );

    // Switch to a: its pictures show, its requests stop, b is left alone.
    let (b_images_before, b_items_before) = (b.images(), b.items());
    suite.begin_switch_stage(
        "demo",
        Some(key_a.clone()),
        clock.elapsed().as_secs_f64() * 1000.0,
    );
    let shown = run(&mut suite, &clock, 6.0);
    let (imgs_a, items_a) = (a.images(), a.items());
    println!("a after switch: pictures {shown}, images {imgs_a}, items {items_a}");
    assert!(
        shown > 0,
        "after the switch no pictures are drawn (a log: {:?})",
        a.lines()
    );
    run(&mut suite, &clock, 4.0);
    assert_eq!(
        (a.images(), a.items()),
        (imgs_a, items_a),
        "requests to a did not stop: {:?}",
        a.lines()
    );
    assert_eq!(
        (b.images(), b.items()),
        (b_images_before, b_items_before),
        "b kept being asked after the switch"
    );

    // And back to b.
    suite.begin_switch_stage("demo", Some(key_b), clock.elapsed().as_secs_f64() * 1000.0);
    let shown = run(&mut suite, &clock, 6.0);
    let (imgs_b2, items_b2) = (b.images(), b.items());
    println!("b after switching back: pictures {shown}, images {imgs_b2}, items {items_b2}");
    assert!(shown > 0, "after switching back no pictures are drawn");
    run(&mut suite, &clock, 4.0);
    assert_eq!(
        (b.images(), b.items()),
        (imgs_b2, items_b2),
        "requests to b did not stop after switching back"
    );
    assert_eq!(
        (a.images(), a.items()),
        (imgs_a, items_a),
        "a kept being asked after the switch back"
    );
    let _ = std::fs::remove_dir_all(&tmp);
    drop((a, b, key_a));
}
