//! The real app through the iOS host core, headless: login screen and Home of the fixture server against goldens.
//! Needs `target/debug/xtask` (`cargo build -p xtask`); without it the test says so and passes. Runs in a child process
//! with a temporary `SWIFTLY_CONFIG_DIR` (file secrets, no keychain). `UPDATE_GOLDENS=1` rewrites the PNGs.

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_desktop::live::Core;
use swiftly_ios::host::{Form, Host};
use swiftly_render::RgbaImage;

const TEST: &str = "login_and_home_of_the_real_app";

struct Fixture(Child);
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

// The goldens come from macOS; the software renderer rounds a little differently on other systems (seen: up to 10 levels).
const TOLERANCE: u8 = if cfg!(target_os = "macos") { 2 } else { 12 };

fn golden(name: &str, img: &RgbaImage) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_GOLDENS").is_some() || !path.exists() {
        img.write_png(&path)
            .unwrap_or_else(|e| panic!("{name}: {e}"));
        println!("golden {name}: written");
        return;
    }
    let want = RgbaImage::read_png(&path).unwrap_or_else(|e| panic!("{name}: {e}"));
    assert_eq!(
        (img.width, img.height),
        (want.width, want.height),
        "{name}: size"
    );
    let (max, share) = img.diff(&want);
    println!(
        "golden {name}: max diff {max}, differing {:.4} %",
        share * 100.0
    );
    assert!(max <= TOLERANCE, "golden {name} differs by {max}");
}

/// Draws frames until the picture stops changing for 1.5 s (network answers and pictures arrive on their own).
fn settled(host: &mut Host, limit: Duration) -> RgbaImage {
    let start = Instant::now();
    let mut last: Option<RgbaImage> = None;
    let mut still_since = Instant::now();
    loop {
        let (list, _) = host.frame(start.elapsed().as_secs_f64());
        let img = host.shell().render_software(&list);
        if last.as_ref().is_some_and(|l| l.diff(&img).0 == 0) {
            if still_since.elapsed() > Duration::from_millis(1500) {
                return img;
            }
        } else {
            still_since = Instant::now();
        }
        last = Some(img);
        assert!(start.elapsed() < limit, "the picture never settled");
        std::thread::sleep(Duration::from_millis(40));
    }
}

#[test]
fn login_and_home_of_the_real_app() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir = std::env::temp_dir().join(format!("swiftly-ios-live-{}", std::process::id()));
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
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .expect("port")
        .local_addr()
        .expect("addr")
        .port();
    let _server = Fixture(
        Command::new(&xtask)
            .args(["fixture-server", "--port", &port.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("fixture"),
    );
    std::thread::sleep(Duration::from_millis(800));
    let address = format!("http://127.0.0.1:{port}");
    let px = (1170, 2532);

    // No account yet: the sign-in flow opens first.
    let core = Arc::new(Core::open().expect("core"));
    assert!(core.account().is_none());
    let mut host = Host::new_live(Form::Phone, px, 3.0, core);
    golden(
        "live-login-phone",
        &settled(&mut host, Duration::from_secs(20)),
    );
    drop(host);

    // Sign in over the network (reqwest on the Mac; the phone uses URLSession through the same seam), then Home.
    let found = swiftly_desktop::live::autologin(&address, "demo", "demo").expect("sign-in");
    println!("signed in: {found}");
    let core = Arc::new(Core::open().expect("core"));
    assert!(core.account().is_some(), "the account was stored");
    let mut host = Host::new_live(Form::Phone, px, 3.0, core);
    golden(
        "live-home-phone",
        &settled(&mut host, Duration::from_secs(40)),
    );
}
