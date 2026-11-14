//! `--quit-after SECONDS` must end the process even when the window loop is stuck (a frozen call into libmpv or the audio
//! stack below it): the loop checks the limit itself, and this guard ends the process a few seconds later when it did not.
#![allow(unsafe_code)]

use std::time::Duration;

/// How long after the limit the guard waits for the loop to end by itself.
const GRACE: Duration = Duration::from_secs(8);
/// The exit code of a process the guard had to end (the code `timeout` uses).
pub const STUCK_EXIT: i32 = 124;

/// Starts the guard for a run that quits after `seconds`.
pub fn arm(seconds: f64) {
    arm_with(seconds, GRACE);
}

/// [`arm`] with an explicit grace period.
pub fn arm_with(seconds: f64, grace: Duration) {
    let wait = Duration::from_secs_f64(seconds.max(0.0)) + grace;
    let _ = std::thread::Builder::new()
        .name("quit-guard".into())
        .spawn(move || {
            std::thread::sleep(wait);
            eprintln!(
                "swiftly-desktop: --quit-after: the window loop did not stop, ending the process"
            );
            end_now();
        });
}

/// Ends the process without exit handlers, which are what a stuck audio library would hang in.
#[cfg(unix)]
fn end_now() -> ! {
    // SAFETY: `_exit` takes an int and never returns; skipping the exit handlers is the point.
    unsafe { libc::_exit(STUCK_EXIT) }
}

/// Ends the process.
#[cfg(not(unix))]
fn end_now() -> ! {
    std::process::exit(STUCK_EXIT)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    /// Child side: a process whose "window loop" never ends.
    #[test]
    #[ignore = "run by a_stuck_loop_is_ended_after_the_limit"]
    fn child_never_stops() {
        arm_with(0.2, Duration::from_millis(300));
        loop {
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    #[test]
    fn a_stuck_loop_is_ended_after_the_limit() {
        let exe = std::env::current_exe().expect("test exe");
        let mut kid = std::process::Command::new(exe)
            .args([
                "--ignored",
                "--exact",
                "quit_guard::tests::child_never_stops",
                "--test-threads",
                "1",
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn");
        let t = std::time::Instant::now();
        let status = loop {
            if let Some(s) = kid.try_wait().expect("wait") {
                break s;
            }
            if t.elapsed() > Duration::from_secs(20) {
                let _ = kid.kill();
                panic!("the guard did not end the stuck process");
            }
            std::thread::sleep(Duration::from_millis(50));
        };
        assert_eq!(status.code(), Some(STUCK_EXIT));
    }
}
