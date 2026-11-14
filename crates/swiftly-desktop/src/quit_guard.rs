//! `--quit-after SECONDS` must end the process even when the window loop is stuck (a frozen call into libmpv or the audio
//! stack below it): the loop checks the limit itself, and this guard ends the process a few seconds later when it did not.
//! A quit that was asked for ([`quit_asked`]) must end with code 0 whatever keeps the loop from returning (the system's own
//! move/size loop, a closing audio stack): that guard ends the process cleanly after a grace period.
#![allow(unsafe_code)]

use std::time::Duration;

/// How long after the limit the guard waits for the loop to end by itself.
const GRACE: Duration = Duration::from_secs(8);
/// The exit code of a process the guard had to end (the code `timeout` uses).
pub const STUCK_EXIT: i32 = 124;

/// How long a quit that was asked for may take before the process is ended.
const QUIT_GRACE: Duration = Duration::from_secs(6);

/// The window loop was asked to stop: when the process is still there after [`QUIT_GRACE`] it is ended with code 0, the
/// quit that was wanted. Only the first call counts.
pub fn quit_asked() {
    quit_asked_with(QUIT_GRACE);
}

/// [`quit_asked`] with an explicit grace period.
pub fn quit_asked_with(grace: Duration) {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let _ = std::thread::Builder::new()
            .name("quit-grace".into())
            .spawn(move || {
                std::thread::sleep(grace);
                eprintln!(
                    "swiftly-desktop: quit: the window loop did not return in {} s, ending the process",
                    grace.as_secs_f32()
                );
                end_with(0);
            });
    });
}

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
            end_with(STUCK_EXIT);
        });
}

/// Ends the process with `code` without exit handlers, which are what a stuck audio library would hang in.
#[cfg(unix)]
fn end_with(code: i32) -> ! {
    // SAFETY: `_exit` takes an int and never returns; skipping the exit handlers is the point.
    unsafe { libc::_exit(code) }
}

/// Ends the process.
#[cfg(not(unix))]
fn end_with(code: i32) -> ! {
    std::process::exit(code)
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

    /// Child side: a quit was asked for and the "window loop" never returns.
    #[test]
    #[ignore = "run by a_quit_that_does_not_finish_ends_with_code_zero"]
    fn child_quits_but_never_returns() {
        quit_asked_with(Duration::from_millis(300));
        loop {
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    #[test]
    fn a_quit_that_does_not_finish_ends_with_code_zero() {
        let exe = std::env::current_exe().expect("test exe");
        let mut kid = std::process::Command::new(exe)
            .args([
                "--ignored",
                "--exact",
                "quit_guard::tests::child_quits_but_never_returns",
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
                panic!("the quit grace did not end the process");
            }
            std::thread::sleep(Duration::from_millis(50));
        };
        assert_eq!(status.code(), Some(0), "a wanted quit is a clean exit");
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
