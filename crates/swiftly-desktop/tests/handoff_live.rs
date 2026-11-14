//! The takeover offering between two desktop clients against the fixture server's Jellyfin-like session registry
//! (`cargo xtask fixture-server`, real sockets): a device that plays is offered to the other one, the offering goes
//! when the playback ends and also when the other device was busy with its own player meanwhile. Needs
//! `target/debug/xtask` (`cargo build -p xtask`); without it the test says so and passes.
#![allow(clippy::unwrap_used, clippy::expect_used, unsafe_code)]

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use swiftly_desktop::live::Core;
use swiftly_desktop::together::Hub;
use swiftly_jellyfin::{PlayMethod, ReportPlan, TrackIndices};
use swiftly_vm::{AccountRef, TakeoverPart};

struct Fixture(Child);
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn wait_for(what: &str, secs: u64, mut ok: impl FnMut() -> bool) {
    let began = Instant::now();
    while !ok() {
        assert!(
            began.elapsed() < Duration::from_secs(secs),
            "timed out: {what}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn client(dir: &std::path::Path, addr: &str) -> Arc<Core> {
    let _ = std::fs::remove_dir_all(dir);
    unsafe { std::env::set_var("SWIFTLY_CONFIG_DIR", dir) };
    let core = Arc::new(Core::open().expect("core"));
    let backend = core.sign_in_backend();
    let wait = Duration::from_secs(30);
    backend
        .connect(addr)
        .0
        .recv_timeout(wait)
        .expect("connect")
        .expect("server");
    backend
        .password("demo", "demo")
        .0
        .recv_timeout(wait)
        .expect("sign in")
        .expect("password");
    core
}

struct Device {
    core: Arc<Core>,
    account: AccountRef,
    hub: Hub,
}

impl Device {
    fn new(dir: &std::path::Path, addr: &str, name: &str) -> Device {
        let core = client(dir, addr);
        let account = core.account().expect("account");
        let hub = Hub::new(&core, &account, Some(name)).expect("hub");
        hub.start();
        Device { core, account, hub }
    }

    /// What the player's report desk sends when a title starts (capabilities first, then `Sessions/Playing`).
    fn start_playing(&self, item: &str, seconds: f64) {
        let c = self.core.client_for(&self.account).expect("client");
        futures_executor::block_on(c.report_capabilities()).expect("capabilities");
        futures_executor::block_on(c.report_start(
            item,
            &plan(),
            (seconds * 1e7) as i64,
            TrackIndices::default(),
        ))
        .expect("start");
    }

    fn stop_playing(&self, item: &str, seconds: f64) {
        let c = self.core.client_for(&self.account).expect("client");
        futures_executor::block_on(c.report_stopped(item, &plan(), (seconds * 1e7) as i64))
            .expect("stop");
    }

    /// Asks for the other devices, at most every 300 ms, and lets the answer arrive.
    fn ask(&self) {
        self.hub.poll_now();
        std::thread::sleep(Duration::from_millis(300));
    }

    fn offered(&self) -> Vec<String> {
        match self.hub.takeover().1 {
            TakeoverPart::Badge { rows } | TakeoverPart::Choosing { rows } => {
                rows.into_iter().map(|r| r.device).collect()
            }
            _ => Vec::new(),
        }
    }
}

fn plan() -> ReportPlan {
    ReportPlan {
        play_session_id: Some("ps-1".into()),
        media_source_id: Some("m1".into()),
        method: PlayMethod::DirectPlay,
    }
}

struct Rig {
    _fx: Fixture,
    tmp: PathBuf,
    linux: Device,
    mac: Device,
}

impl Drop for Rig {
    fn drop(&mut self) {
        self.linux.hub.stop();
        self.mac.hub.stop();
        let _ = std::fs::remove_dir_all(&self.tmp);
    }
}

fn rig() -> Option<Rig> {
    let xtask = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../target/debug/xtask");
    if !xtask.exists() {
        println!("skipped: build xtask first (cargo build -p xtask)");
        return None;
    }
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let fx = Fixture(
        Command::new(&xtask)
            .args(["fixture-server", "--port", &port.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("fixture"),
    );
    std::thread::sleep(Duration::from_millis(800));
    let addr = format!("http://127.0.0.1:{port}");
    let tmp = std::env::temp_dir().join(format!("swiftly-handoff-{}", std::process::id()));
    let linux = Device::new(&tmp.join("linux"), &addr, "Linux");
    let mac = Device::new(&tmp.join("mac"), &addr, "Mac");
    assert_ne!(linux.account.device_id, mac.account.device_id);
    Some(Rig {
        _fx: fx,
        tmp,
        linux,
        mac,
    })
}

/// Something plays on the Linux desktop: the other device is offered it, and the offering ends with the playback.
#[test]
fn a_playing_desktop_is_offered_to_the_other_device_until_it_stops() {
    let Some(r) = rig() else { return };
    // Nothing plays: nothing is offered.
    r.mac.hub.poll_now();
    std::thread::sleep(Duration::from_millis(1500));
    assert!(r.mac.offered().is_empty());

    r.linux.start_playing("m1", 25.0);
    wait_for("the Mac is offered the Linux desktop", 15, || {
        r.mac.ask();
        !r.mac.offered().is_empty()
    });
    // It never offers the device itself.
    r.linux.hub.poll_now();
    std::thread::sleep(Duration::from_millis(1500));
    assert!(r.linux.offered().is_empty());

    r.linux.stop_playing("m1", 40.0);
    wait_for("the offering goes after the stop", 15, || {
        r.mac.ask();
        r.mac.offered().is_empty()
    });
}

/// The other device stops while this one has its own player open (no questions are asked then): once the player is
/// closed, the old offering must not come back.
#[test]
fn an_offering_that_ended_during_the_own_player_does_not_come_back() {
    let Some(r) = rig() else { return };
    r.mac.start_playing("m1", 10.0);
    wait_for("Linux is offered the Mac", 15, || {
        r.linux.ask();
        !r.linux.offered().is_empty()
    });
    // Let the polls that are still queued run out, so only the player's own silence is tested.
    std::thread::sleep(Duration::from_millis(1500));
    // Linux opens its own player (no polls from now on) and the Mac stops meanwhile.
    r.linux.hub.player_open(true);
    r.mac.stop_playing("m1", 12.0);
    std::thread::sleep(Duration::from_secs(7));
    // The player closes: at once nothing is offered, because nothing plays anywhere.
    r.linux.hub.player_detached();
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        r.linux.offered().is_empty(),
        "stale offering after the player closed: {:?}",
        r.linux.offered()
    );
}
