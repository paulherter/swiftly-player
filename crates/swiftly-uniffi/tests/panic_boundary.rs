//! Panic safety at the foreign boundary (security gate G7).
//!
//! UniFFI wraps every exported call in `rust_call`, which uses `catch_unwind`: a Rust panic becomes a status code
//! the Swift/Kotlin binding throws as an error. That only works while panics unwind, so the build profiles must
//! never set `panic = "abort"`. These tests pin both facts, and that the core's own exports survive hostile hosts.

use uniffi::{RustCallStatus, RustCallStatusCode, rust_call};

#[test]
fn a_panic_inside_an_export_becomes_a_status_code_not_an_unwind_into_the_host() {
    let mut status = RustCallStatus::default();
    let out: u32 = rust_call(&mut status, || -> Result<u32, uniffi::RustCallError> {
        let v: Vec<u32> = Vec::new();
        let i = v.len() + 3;
        // A real out-of-range index, the typical parser bug.
        Ok(*v.get(i).unwrap_or_else(|| panic!("index out of range")))
    });
    assert_eq!(out, 0, "the call returns the default value");
    assert_eq!(status.code, RustCallStatusCode::UnexpectedError);
}

#[test]
fn no_build_profile_aborts_on_panic() {
    // `panic = "abort"` would make catch_unwind useless: the first parser bug would kill the app.
    let manifest =
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../Cargo.toml"))
            .unwrap_or_default();
    assert!(
        manifest.contains("[profile.release]"),
        "workspace manifest not found"
    );
    let code: String = manifest
        .lines()
        .filter(|l| !l.trim_start().starts_with('#'))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        !code.replace(' ', "").contains("panic=\"abort\""),
        "panic = \"abort\" in a workspace profile"
    );
    for krate in std::fs::read_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/.."))
        .into_iter()
        .flatten()
        .flatten()
    {
        let text = std::fs::read_to_string(krate.path().join("Cargo.toml")).unwrap_or_default();
        assert!(
            !text.replace(' ', "").contains("panic=\"abort\""),
            "{:?} sets panic = abort",
            krate.path()
        );
    }
}
