//! Crash-safe file writes for settings, download lists and caches.
//!
//! [`write`] puts the bytes into a temp file next to the target, flushes it to disk (`fsync`), renames
//! it over the target and flushes the folder, so after a crash or power loss the target holds either
//! the old or the new content, never half of one. A temp file left behind by a crash is removed by
//! the next write of the same target ([`temp_path`] is stable per target).
#![deny(missing_docs)]

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// The temp file used for `target` (same folder, so the rename stays on one volume).
pub fn temp_path(target: &Path) -> PathBuf {
    let mut name = target
        .file_name()
        .map(std::ffi::OsStr::to_os_string)
        .unwrap_or_default();
    name.push(".tmp");
    target.with_file_name(name)
}

/// Replaces `target` with `bytes` atomically; creates missing folders.
///
/// # Errors
/// Any I/O error; on error the old content of `target` is untouched and the temp file is removed.
pub fn write(target: &Path, bytes: &[u8]) -> io::Result<()> {
    write_with_mode(target, bytes, None)
}

/// Like [`write`], but the file is created readable by the owner only (mode 0600 on Unix, from the first byte on,
/// so no other user can read it between creation and a later `chmod`). For files that hold secrets.
///
/// # Errors
/// As [`write`].
pub fn write_private(target: &Path, bytes: &[u8]) -> io::Result<()> {
    write_with_mode(target, bytes, Some(0o600))
}

fn write_with_mode(target: &Path, bytes: &[u8], mode: Option<u32>) -> io::Result<()> {
    if let Some(dir) = target.parent().filter(|d| !d.as_os_str().is_empty()) {
        fs::create_dir_all(dir)?;
    }
    let tmp = temp_path(target);
    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        if let Some(mode) = mode {
            std::os::unix::fs::OpenOptionsExt::mode(&mut options, mode);
        }
        #[cfg(not(unix))]
        let _ = mode;
        let mut file = options.open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&tmp, target)?;
        sync_folder(target);
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// How many `<name>.broken-<time>` copies of one file are kept; older ones are removed.
pub const KEEP_BROKEN: usize = 5;

/// Moves a file that cannot be read aside, to `<name>.broken-<unix seconds>` in the same folder, so the app can start
/// with defaults and the user (or support) still has the damaged content. Only the newest [`KEEP_BROKEN`] copies of
/// that file stay. Returns the new path.
///
/// # Errors
/// Any I/O error of the move (the file then stays where it is).
pub fn set_aside(path: &Path) -> io::Result<PathBuf> {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no file name"))?;
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let prefix = format!("{name}.broken-");
    let mut target = path.with_file_name(format!("{prefix}{secs}"));
    let mut n = 1u32;
    while target.exists() {
        n += 1;
        target = path.with_file_name(format!("{prefix}{secs}-{n}"));
    }
    fs::rename(path, &target)?;
    prune_broken(path, &prefix, &target);
    Ok(target)
}

/// Removes the oldest `<prefix>*` siblings of `path` so that, with `newest`, [`KEEP_BROKEN`] stay (names sort by their
/// time stamp).
fn prune_broken(path: &Path, prefix: &str, newest: &Path) {
    let dir = path
        .parent()
        .filter(|d| !d.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut copies: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().starts_with(prefix))
        .map(|e| e.path())
        .filter(|p| p != newest)
        .collect();
    copies.sort_by(|a, b| {
        let key = |p: &PathBuf| {
            let name = p.file_name().map(|n| n.to_string_lossy().into_owned());
            let rest = name.unwrap_or_default().replacen(prefix, "", 1);
            let mut parts = rest.splitn(2, '-');
            let secs: u64 = parts.next().and_then(|t| t.parse().ok()).unwrap_or(0);
            let seq: u32 = parts.next().and_then(|t| t.parse().ok()).unwrap_or(1);
            (secs, seq)
        };
        key(a).cmp(&key(b))
    });
    // The copy just made always stays; the others are cut down to leave room for it.
    let excess = copies.len().saturating_sub(KEEP_BROKEN - 1);
    for old in copies.into_iter().take(excess) {
        let _ = fs::remove_file(old);
    }
}

/// Flushes the folder entry of the rename (Unix; other systems skip it, NTFS journals the rename).
fn sync_folder(target: &Path) {
    #[cfg(unix)]
    if let Some(dir) = target.parent().map(|d| {
        if d.as_os_str().is_empty() {
            Path::new(".")
        } else {
            d
        }
    }) && let Ok(handle) = fs::File::open(dir)
    {
        let _ = handle.sync_all();
    }
    #[cfg(not(unix))]
    let _ = target;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("swiftly-atomic-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn writes_replaces_and_leaves_no_temp() {
        let d = dir("basic");
        let f = d.join("sub/settings.json");
        write(&f, b"one").expect("write");
        write(&f, b"two").expect("rewrite");
        assert_eq!(fs::read(&f).expect("read"), b"two");
        assert!(!temp_path(&f).exists());
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn a_stale_temp_from_a_crash_does_not_matter() {
        let d = dir("stale");
        let f = d.join("list.json");
        fs::create_dir_all(&d).expect("dir");
        fs::write(&f, b"good").expect("seed");
        fs::write(temp_path(&f), b"half writt").expect("stale temp");
        assert_eq!(
            fs::read(&f).expect("read"),
            b"good",
            "the stale temp never replaces the target by itself"
        );
        write(&f, b"new").expect("write");
        assert_eq!(fs::read(&f).expect("read"), b"new");
        assert!(!temp_path(&f).exists());
        let _ = fs::remove_dir_all(&d);
    }

    #[cfg(unix)]
    #[test]
    fn private_files_are_owner_only_from_creation() {
        use std::os::unix::fs::PermissionsExt;
        let d = dir("private");
        let f = d.join("secrets.json");
        write_private(&f, b"{}").expect("write");
        assert_eq!(
            fs::metadata(&f).expect("meta").permissions().mode() & 0o777,
            0o600
        );
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn failure_keeps_the_old_content() {
        let d = dir("fail");
        let f = d.join("x.json");
        write(&f, b"keep").expect("seed");
        // A directory squatting on the temp name makes the write fail before the rename.
        let tmp = temp_path(&f);
        fs::create_dir_all(&tmp).expect("blocker");
        assert!(write(&f, b"lost").is_err());
        assert_eq!(fs::read(&f).expect("read"), b"keep");
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn a_broken_file_is_set_aside_and_only_the_newest_copies_stay() {
        let d = dir("aside");
        fs::create_dir_all(&d).expect("dir");
        let f = d.join("settings.json");
        let mut last = PathBuf::new();
        for i in 0..(KEEP_BROKEN + 3) {
            fs::write(&f, format!("broken {i}")).expect("write");
            last = set_aside(&f).expect("aside");
            assert!(!f.exists(), "the damaged file is gone from its place");
            assert!(
                last.file_name()
                    .is_some_and(|n| n.to_string_lossy().starts_with("settings.json.broken-"))
            );
        }
        let left = fs::read_dir(&d).expect("dir").count();
        assert_eq!(left, KEEP_BROKEN);
        // The newest copy stays and holds the damaged file's content.
        assert_eq!(
            fs::read_to_string(&last).expect("read"),
            format!("broken {}", KEEP_BROKEN + 2)
        );
        // A missing file is an error, nothing is invented.
        assert!(set_aside(&f).is_err());
        let _ = fs::remove_dir_all(&d);
    }
}
