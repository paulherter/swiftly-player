//! One running app per user. The first process holds an exclusive lock on a file (`File::try_lock`: LockFileEx on
//! Windows, flock on Linux and macOS; the OS drops it when the process dies, so a crash never leaves a stale lock).
//! A second launch finds the lock held, appends its arguments to an inbox file next to it, and exits; the first
//! process drains the inbox a few times a second, raises its window and opens what came in. No socket, no named pipe,
//! no new service: only two small files in the per-user data directory.

use std::fs::{File, OpenOptions, TryLockError};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

const LOCK_NAME: &str = "swiftly-desktop.lock";
const INBOX_NAME: &str = "swiftly-desktop.inbox";
/// Separates the arguments of one launch in an inbox line (the ASCII unit separator cannot be typed in a path).
const SEP: char = '\u{1f}';

/// The directory of the two files: per-user and writable (`%LOCALAPPDATA%\Swiftly`, `$XDG_RUNTIME_DIR`, the temp dir).
pub fn default_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .or_else(|| std::env::var_os("XDG_RUNTIME_DIR"))
        .map_or_else(std::env::temp_dir, PathBuf::from);
    if std::env::var_os("LOCALAPPDATA").is_some() {
        base.join("Swiftly")
    } else {
        base
    }
}

/// The first process: holds the lock for as long as it lives.
#[derive(Debug)]
pub struct Primary {
    _lock: File,
    dir: PathBuf,
}

/// The outcome of [`acquire`].
#[derive(Debug)]
pub enum Role {
    /// Nobody else runs: keep this value alive and call [`Primary::drain`] now and then.
    Primary(Primary),
    /// Another process holds the lock: [`forward`] the arguments and exit.
    Secondary,
}

/// Tries to become the one running instance, using the files in `dir` (created when missing).
pub fn acquire(dir: &Path) -> io::Result<Role> {
    std::fs::create_dir_all(dir)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join(LOCK_NAME))?;
    match lock.try_lock() {
        Ok(()) => Ok(Role::Primary(Primary {
            _lock: lock,
            dir: dir.to_path_buf(),
        })),
        Err(TryLockError::WouldBlock) => Ok(Role::Secondary),
        Err(TryLockError::Error(e)) => Err(e),
    }
}

/// How a second launch ended up after handing over its arguments.
#[derive(Debug)]
pub enum HandOver {
    /// The running instance took the line from its inbox: exit.
    Delivered,
    /// The holder died (or was killed) while we waited and the lock came free: this process is the app now. Its own
    /// arguments were taken back out of the inbox (the caller opens them itself).
    TakeOver(Primary),
    /// The holder still holds the lock but did not read the inbox in time (a slow start): the line stays there for it.
    Waiting,
}

/// How often a second launch looks whether the first has taken its line.
const HAND_OVER_POLL: std::time::Duration = std::time::Duration::from_millis(5);

/// How often the running instance looks into its inbox (one `stat` per look). A second launch waits for this, and a
/// launch that hands over must be gone within 200 ms, so the look is frequent; it costs no measurable CPU.
pub const INBOX_POLL: std::time::Duration = std::time::Duration::from_millis(40);

/// Hands `args` to the running instance and waits up to `wait` for it to take them. A holder that is dying (killed a
/// moment ago, the OS still tearing it down) never takes them: when the lock comes free in the meantime, this process
/// takes over instead of leaving the user with no app.
///
/// # Errors
/// The inbox cannot be written.
pub fn hand_over(dir: &Path, args: &[String], wait: std::time::Duration) -> io::Result<HandOver> {
    forward(dir, args)?;
    let inbox = dir.join(INBOX_NAME);
    let deadline = std::time::Instant::now() + wait;
    loop {
        if !inbox.exists() {
            return Ok(HandOver::Delivered);
        }
        if let Ok(Role::Primary(p)) = acquire(dir) {
            // Our line is still there: nobody read it. Take it back out, keep any other launch's lines.
            let mine = args.join(&SEP.to_string());
            let mut dropped = false;
            for line in p.drain() {
                if !dropped && line.join(&SEP.to_string()) == mine {
                    dropped = true;
                } else {
                    let _ = forward(dir, &line);
                }
            }
            return Ok(HandOver::TakeOver(p));
        }
        if std::time::Instant::now() >= deadline {
            return Ok(HandOver::Waiting);
        }
        std::thread::sleep(HAND_OVER_POLL);
    }
}

/// Hands the arguments of this launch to the running instance (one line in its inbox).
pub fn forward(dir: &Path, args: &[String]) -> io::Result<()> {
    let line = args.join(&SEP.to_string());
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join(INBOX_NAME))?;
    // One write call so two launches at once do not interleave.
    f.write_all(format!("{line}\n").as_bytes())
}

impl Primary {
    /// Watches the inbox on a thread of its own and calls `on_launch` for every launch that arrives; the thread ends
    /// when `on_launch` returns `false` (the app is gone).
    pub fn watch(self, on_launch: impl Fn(Vec<String>) -> bool + Send + 'static) {
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(INBOX_POLL);
                // `drain` looks for the file first, so an empty inbox costs one `stat`.
                for args in self.drain() {
                    if !on_launch(args) {
                        return;
                    }
                }
            }
        });
    }

    /// The launches that arrived since the last call, oldest first (each is the argument list of one second launch).
    pub fn drain(&self) -> Vec<Vec<String>> {
        let inbox = self.dir.join(INBOX_NAME);
        if !inbox.exists() {
            return Vec::new();
        }
        let taken = self.dir.join(format!("{INBOX_NAME}.taken"));
        if std::fs::rename(&inbox, &taken).is_err() {
            return Vec::new();
        }
        let text = std::fs::read_to_string(&taken).unwrap_or_default();
        let _ = std::fs::remove_file(&taken);
        text.lines()
            .map(|l| l.split(SEP).map(str::to_owned).collect())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("swiftly-single-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn the_second_launch_is_secondary_and_forwards_its_arguments() {
        let dir = temp("two");
        let Role::Primary(first) = acquire(&dir).unwrap() else {
            panic!("first must be primary")
        };
        assert!(matches!(acquire(&dir).unwrap(), Role::Secondary));
        forward(&dir, &["swiftly://titel/1".to_owned()]).unwrap();
        forward(&dir, &["a b.mkv".to_owned(), "--x".to_owned()]).unwrap();
        assert_eq!(
            first.drain(),
            vec![
                vec!["swiftly://titel/1".to_owned()],
                vec!["a b.mkv".to_owned(), "--x".to_owned()]
            ]
        );
        assert!(first.drain().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_lock_is_free_again_when_the_first_one_ends() {
        let dir = temp("again");
        let Role::Primary(first) = acquire(&dir).unwrap() else {
            panic!()
        };
        drop(first);
        assert!(matches!(acquire(&dir).unwrap(), Role::Primary(_)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_live_holder_takes_the_line_and_stays_the_app() {
        use std::time::Duration;
        let dir = temp("live");
        let Role::Primary(first) = acquire(&dir).unwrap() else {
            panic!()
        };
        let reader = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(120));
            let got = first.drain();
            (first, got)
        });
        let r = hand_over(
            &dir,
            &["swiftly://titel/1".to_owned()],
            Duration::from_secs(3),
        )
        .unwrap();
        assert!(matches!(r, HandOver::Delivered), "{r:?}");
        let (first, got) = reader.join().unwrap();
        assert_eq!(got, vec![vec!["swiftly://titel/1".to_owned()]]);
        assert!(matches!(acquire(&dir).unwrap(), Role::Secondary));
        drop(first);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_dying_holder_that_never_reads_is_taken_over() {
        use std::time::Duration;
        let dir = temp("dying");
        let Role::Primary(first) = acquire(&dir).unwrap() else {
            panic!()
        };
        // The old instance is being killed: it lets go of the lock a moment later and never reads its inbox.
        let dying = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(250));
            drop(first);
        });
        let r = hand_over(
            &dir,
            &["swiftly://abspielen/9".to_owned()],
            Duration::from_secs(3),
        )
        .unwrap();
        dying.join().unwrap();
        let HandOver::TakeOver(me) = r else {
            panic!("{r:?}")
        };
        // Our own line is gone again (the caller opens the link itself), so it is not opened twice.
        assert!(me.drain().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_takeover_keeps_the_lines_of_other_launches() {
        use std::time::Duration;
        let dir = temp("keep");
        let Role::Primary(first) = acquire(&dir).unwrap() else {
            panic!()
        };
        forward(&dir, &["other".to_owned()]).unwrap();
        let dying = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(150));
            drop(first);
        });
        let r = hand_over(&dir, &["mine".to_owned()], Duration::from_secs(3)).unwrap();
        dying.join().unwrap();
        let HandOver::TakeOver(me) = r else {
            panic!("{r:?}")
        };
        assert_eq!(me.drain(), vec![vec!["other".to_owned()]]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_holder_that_lives_but_is_slow_keeps_the_line_for_later() {
        use std::time::Duration;
        let dir = temp("slow");
        let Role::Primary(first) = acquire(&dir).unwrap() else {
            panic!()
        };
        let r = hand_over(&dir, &["x".to_owned()], Duration::from_millis(150)).unwrap();
        assert!(matches!(r, HandOver::Waiting), "{r:?}");
        assert_eq!(first.drain(), vec![vec!["x".to_owned()]]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_inbox_drains_to_nothing() {
        let dir = temp("empty");
        let Role::Primary(p) = acquire(&dir).unwrap() else {
            panic!()
        };
        assert!(p.drain().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Functional: a second launch reaches the running instance. Event based, no clock: `hand_over` returns
    /// `Delivered` once the first one took the line, and the first one's callback (its acknowledgement) delivers the
    /// very arguments, in order. The only bound is a hang guard that fails a stuck hand-over instead of hanging the run;
    /// it says nothing about speed (see `a_second_launch_is_handed_over_within_200_ms` for that).
    #[test]
    fn a_second_launch_is_handed_over_to_the_watching_first_one() {
        use std::time::Duration;
        const HANG_GUARD: Duration = Duration::from_secs(10);
        let dir = temp("handed");
        let Role::Primary(first) = acquire(&dir).unwrap() else {
            panic!()
        };
        let (tx, rx) = std::sync::mpsc::channel();
        first.watch(move |args| tx.send(args).is_ok());
        for n in 0..5 {
            let args = vec![format!("swiftly://titel/{n}"), "a b.mkv".to_owned()];
            let r = hand_over(&dir, &args, HANG_GUARD).unwrap();
            assert!(matches!(r, HandOver::Delivered), "launch {n}: {r:?}");
            assert_eq!(rx.recv_timeout(HANG_GUARD).unwrap(), args, "launch {n}");
        }
        // The first one is still the app: the lock stayed with it.
        assert!(matches!(acquire(&dir).unwrap(), Role::Secondary));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The promise of `windows-desktop.md`: a second launch hands over and is gone within 200 ms. It was broken once
    /// because the first instance looked into its inbox only every 300 ms.
    ///
    /// The time is taken at the events themselves, not around a process start: when the second launch sends (the
    /// inbox write, the first step of `hand_over`), when the first one receives (inside its `watch` callback), and when
    /// the second one is free again (`hand_over` returned). No sleep, no retry: every round starts right after the
    /// previous line was taken, which is the worst moment of the watcher's period, so each round measures the longest
    /// wait the design allows.
    ///
    /// Budget: the promise itself (200 ms) on a machine that runs nothing else (a developer's Mac, also in `ci-local.sh
    /// --macos-tests`). Where `CI` is set (GitHub Actions and shared build machines) it is `CI_TOLERANCE`: the design
    /// needs at most 45 ms
    /// (`INBOX_POLL` + `HAND_OVER_POLL`), yet the public macos-15 runner (3 vCPUs shared with the other test threads and
    /// other VMs) once measured 208 ms, a scheduling stall of the watcher thread of about 160 ms that the code does not
    /// cause. Waiting 1 s there still catches a hand-over that took a slow path; the poll periods themselves are
    /// pinned without any clock by the first assertion, so a return to a 300 ms poll fails on CI too.
    #[test]
    fn a_second_launch_is_handed_over_within_200_ms() {
        use std::time::{Duration, Instant};
        const PROMISE: Duration = Duration::from_millis(200);
        const CI_TOLERANCE: Duration = Duration::from_secs(1);
        const HANG_GUARD: Duration = Duration::from_secs(10);
        // The design bound, no clock: both polls added still leave a fourfold margin to the promise.
        assert!(
            (INBOX_POLL + HAND_OVER_POLL) * 4 <= PROMISE,
            "polls {INBOX_POLL:?} + {HAND_OVER_POLL:?} leave no margin to {PROMISE:?}"
        );
        let on_ci = std::env::var_os("CI").is_some();
        let budget = if on_ci { CI_TOLERANCE } else { PROMISE };

        let dir = temp("fast");
        let Role::Primary(first) = acquire(&dir).unwrap() else {
            panic!()
        };
        let (tx, rx) = std::sync::mpsc::channel();
        first.watch(move |args| tx.send((Instant::now(), args)).is_ok());
        // Round 0 is not judged: the running instance has been up for a long time when a second launch comes, but the
        // watcher thread of this test may not have been scheduled yet right after `watch`.
        for round in 0..=8 {
            let args = vec![format!("swiftly://titel/{round}")];
            let sent = Instant::now();
            let r = hand_over(&dir, &args, HANG_GUARD).unwrap();
            let gone = Instant::now();
            assert!(matches!(r, HandOver::Delivered), "round {round}: {r:?}");
            let (received, got) = rx.recv_timeout(HANG_GUARD).unwrap();
            assert_eq!(got, args, "round {round}");
            let to_first = received.saturating_duration_since(sent);
            let to_gone = gone.saturating_duration_since(sent);
            eprintln!(
                "round {round}: first one received after {to_first:?}, second one gone after {to_gone:?} (budget {budget:?})"
            );
            if round > 0 {
                assert!(
                    to_first < budget && to_gone < budget,
                    "round {round}: received after {to_first:?}, gone after {to_gone:?}, budget {budget:?} (CI: {on_ci})"
                );
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
