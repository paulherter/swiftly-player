//! Dropping the app core never waits for the runtime's workers: at process exit Windows has already killed them, and a
//! waiting drop hung the app (unkillable) after the window's close button.
use std::time::{Duration, Instant};
use swiftly_desktop::live::Core;

#[test]
fn dropping_the_core_does_not_wait_for_a_busy_worker() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir = std::env::temp_dir().join(format!("swiftly-core-drop-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let me = std::env::current_exe().unwrap();
        let out = std::process::Command::new(me)
            .args([
                "--exact",
                "dropping_the_core_does_not_wait_for_a_busy_worker",
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
    let core = Core::open().unwrap();
    core.spawn(async { std::thread::sleep(Duration::from_secs(20)) });
    std::thread::sleep(Duration::from_millis(200));
    let t = Instant::now();
    drop(core);
    assert!(
        t.elapsed() < Duration::from_secs(3),
        "dropping the core took {:?}",
        t.elapsed()
    );
}
