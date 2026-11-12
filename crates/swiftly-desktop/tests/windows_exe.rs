//! The Windows release exe is a GUI program (no console window next to the app) and carries its program icon.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;

#[test]
fn main_rs_asks_for_the_gui_subsystem_in_release() {
    let src =
        std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/main.rs"))
            .unwrap();
    assert!(
        src.contains("windows_subsystem = \"windows\"") && src.contains("not(debug_assertions)"),
        "release builds on Windows must use the GUI subsystem"
    );
}

/// PE optional header "Subsystem": 2 = Windows GUI, 3 = console.
fn subsystem(exe: &[u8]) -> u16 {
    let pe = u32::from_le_bytes(exe[0x3c..0x40].try_into().unwrap()) as usize;
    assert_eq!(&exe[pe..pe + 4], b"PE\0\0");
    // File header 20 bytes, then the optional header; Subsystem sits at offset 68 in both PE32 and PE32+.
    let o = pe + 24 + 68;
    u16::from_le_bytes(exe[o..o + 2].try_into().unwrap())
}

#[test]
fn a_built_windows_release_exe_has_no_console_subsystem() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/x86_64-pc-windows-msvc/release/swiftly-desktop.exe");
    let Ok(bytes) = std::fs::read(&root) else {
        eprintln!("no cross-built exe at {}, skipped", root.display());
        return;
    };
    assert_eq!(
        subsystem(&bytes),
        2,
        "the release exe must be a GUI program"
    );
}
