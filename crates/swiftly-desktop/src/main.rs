//! `swiftly-desktop`: the desktop shell and the gate G1 demo of the shared Swiftly Rust UI.

// A release exe on Windows is a GUI program: no console window next to the app. Debug builds keep the console.
#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

use std::process::ExitCode;
use swiftly_desktop::{app, cli, headless};

fn main() -> ExitCode {
    swiftly_desktop::win_shell::attach_parent_console();
    // A panic is written to `<config dir>/crash.log` and stderr, and ends the process with a defined exit code.
    swiftly_desktop::crash::install();
    match std::panic::catch_unwind(run) {
        Ok(code) => code,
        Err(_) => {
            eprintln!(
                "swiftly-desktop: crashed, details in {}",
                swiftly_desktop::crash::log_path().display()
            );
            ExitCode::from(swiftly_desktop::crash::EXIT_CRASH)
        }
    }
}

fn run() -> ExitCode {
    let opts = match cli::parse(std::env::args().skip(1)) {
        Ok(Some(o)) => o,
        Ok(None) => {
            println!("{}", cli::USAGE);
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("swiftly-desktop: {e}\n\n{}", cli::USAGE);
            return ExitCode::from(2);
        }
    };
    let mut opts = opts;
    // A release build starts the real app unless a demo or a headless run was asked for.
    let asked = opts.app
        || opts.player
        || opts.home.is_some()
        || opts.gpu_bench
        || opts.frames.is_some()
        || opts.autoplay
        || opts.smoke_play.is_some();
    if !cfg!(debug_assertions) && !asked && opts.smoke.is_none() {
        opts.live = true;
    }
    // The real app runs once per user; a second launch hands its links and files to the first.
    if opts.live {
        opts.single_instance = true;
    }
    if let Some((address, user, password)) = &opts.smoke_play {
        return match swiftly_desktop::live_play::smoke_play(
            address,
            user,
            password,
            opts.quit_after.unwrap_or(10.0),
        ) {
            Ok(lines) => {
                println!("{lines}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("swiftly-desktop: smoke-play failed: {e}");
                ExitCode::FAILURE
            }
        };
    }
    if let Some((address, user, password)) = &opts.smoke {
        return match swiftly_desktop::live::smoke(address, user, password) {
            Ok(lines) => {
                println!("{lines}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("swiftly-desktop: smoke failed: {e}");
                ExitCode::FAILURE
            }
        };
    }
    if opts.player {
        #[cfg(feature = "mpv")]
        let r = swiftly_desktop::video_demo::run(&opts);
        #[cfg(not(feature = "mpv"))]
        let r: Result<String, String> =
            Err("this build has no video: rebuild with --features mpv".into());
        return match r {
            Ok(line) => {
                eprintln!("{line}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("swiftly-desktop: {e}");
                ExitCode::FAILURE
            }
        };
    }
    let result = if opts.gpu_bench {
        headless::gpu_bench(&opts)
    } else if opts.frames.is_some() {
        headless::run(&opts).map(|r| {
            eprintln!(
                "headless: {} frames, {} quads, {}x{} px, {:.2} ms/frame, ink {:.1} %, still moving: {}",
                r.frames, r.quads, r.size_px.0, r.size_px.1, r.avg_frame_ms, r.ink * 100.0, r.still_moving
            );
        })
    } else {
        app::run(opts)
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("swiftly-desktop: {e}");
            swiftly_desktop::crash::note_fatal(&e);
            ExitCode::FAILURE
        }
    }
}
