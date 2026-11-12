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
}
