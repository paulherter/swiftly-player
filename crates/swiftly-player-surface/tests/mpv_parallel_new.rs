//! Many processes create a libmpv engine and drop it at the same moment (`cargo nextest` runs every test in its own
//! process, and a second window does the same inside one). With libmpv's built-in Lua scripts on (stats, console,
//! select, ...) their threads were still starting while the engine was destroyed and crashed with SIGSEGV in roughly
//! one of three parallel runs. The engine now starts none of them. Skips when libmpv is not installed.
#![cfg(feature = "mpv")]

use std::process::Command;
use swiftly_player_surface::mpv::MpvEngine;

/// Child side: one engine, created and dropped at once.
#[test]
#[ignore = "run by creating_engines_in_parallel_processes_never_crashes"]
fn child_creates_and_drops_one_engine() {
    drop(MpvEngine::new().expect("libmpv"));
}

#[test]
fn creating_engines_in_parallel_processes_never_crashes() {
    if MpvEngine::new().is_err() {
        eprintln!("skipped: no libmpv");
        return;
    }
    let exe = std::env::current_exe().expect("test exe");
    for round in 0..8 {
        let kids: Vec<_> = (0..16)
            .map(|_| {
                Command::new(&exe)
                    .args([
                        "--ignored",
                        "--exact",
                        "child_creates_and_drops_one_engine",
                        "--test-threads",
                        "1",
                    ])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .expect("spawn")
            })
            .collect();
        for mut k in kids {
            let st = k.wait().expect("wait");
            assert!(
                st.code().is_some(),
                "round {round}: a child died by signal ({st})"
            );
        }
    }
}
