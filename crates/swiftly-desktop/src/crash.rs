//! A crash is never silent: a panic on any thread is written, with its place and a backtrace, to `crash.log` in the
//! config directory and to stderr (a window started without a console loses stderr), and `main` turns an unwinding
//! panic into the exit code [`EXIT_CRASH`]. Fatal errors that are not panics (no GPU, no window) go to the same log.

use std::io::Write;
use std::path::{Path, PathBuf};

/// The exit code after a panic (the one Rust uses for an unhandled panic).
pub const EXIT_CRASH: u8 = 101;

/// The log is cut to nothing when it grows past this many bytes, so it never fills a disk.
const LIMIT: u64 = 256 * 1024;

/// `<config dir>/crash.log`.
pub fn log_path() -> PathBuf {
    crate::store::config_dir().join("crash.log")
}

fn stamp() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    format!("unix {secs}")
}

/// Appends one entry to `path` (created with its folder; cut when over the limit). Errors are ignored: there is
/// nowhere left to report them.
pub fn append(path: &Path, text: &str) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if std::fs::metadata(path).is_ok_and(|m| m.len() > LIMIT) {
        let _ = std::fs::remove_file(path);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(f, "{text}");
    }
}

/// Text of a panic: version, time, thread, place, message and the backtrace of the panicking thread (symbols only in
/// builds that keep them; a stripped release shows addresses, the message and place are always there).
pub fn describe(info: &std::panic::PanicHookInfo<'_>) -> String {
    let payload = info.payload();
    let message = payload
        .downcast_ref::<&str>()
        .map(|s| (*s).to_owned())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "(no message)".into());
    let place = info.location().map_or_else(
        || "unknown place".into(),
        |l| format!("{}:{}:{}", l.file(), l.line(), l.column()),
    );
    let thread = std::thread::current();
    let backtrace = std::backtrace::Backtrace::force_capture();
    format!(
        "--- swiftly-desktop {} panic ({}) ---\nthread '{}' panicked at {place}:\n{message}\nbacktrace:\n{backtrace}",
        env!("CARGO_PKG_VERSION"),
        stamp(),
        thread.name().unwrap_or("<unnamed>"),
    )
}

/// Installs the panic hook that writes [`describe`] to stderr and to `path`.
pub fn install_at(path: PathBuf) {
    std::panic::set_hook(Box::new(move |info| {
        let text = describe(info);
        eprintln!("{text}");
        append(&path, &text);
    }));
}

/// Installs the hook for the real log file.
pub fn install() {
    install_at(log_path());
}

/// Records a fatal error that is not a panic (the app is about to exit with it).
pub fn note_fatal(message: &str) {
    append(
        &log_path(),
        &format!(
            "--- swiftly-desktop {} fatal ({}) ---\n{message}",
            env!("CARGO_PKG_VERSION"),
            stamp()
        ),
    );
}

/// Records an error the app lives through (a GPU error, a lost device).
pub fn note_error(what: &str, message: &str) {
    append(
        &log_path(),
        &format!(
            "--- swiftly-desktop {} {what} ({}) ---\n{message}",
            env!("CARGO_PKG_VERSION"),
            stamp()
        ),
    );
}
