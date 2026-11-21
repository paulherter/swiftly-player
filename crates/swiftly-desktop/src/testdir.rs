//! A scratch directory for tests that removes itself when dropped, also when the test fails, so
//! nothing piles up in the system temp folder.

use std::ops::Deref;
use std::path::{Path, PathBuf};

pub struct TestDir(PathBuf);

impl TestDir {
    /// A fresh, empty `<temp>/<prefix>-<pid>` folder.
    pub fn new(prefix: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("{prefix}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::create_dir_all(&dir);
        Self(dir)
    }

    /// The path only: a test that wants the folder created by the code under test.
    pub fn path_only(prefix: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("{prefix}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Self(dir)
    }
}

impl Deref for TestDir {
    type Target = PathBuf;
    fn deref(&self) -> &PathBuf {
        &self.0
    }
}

impl AsRef<Path> for TestDir {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
