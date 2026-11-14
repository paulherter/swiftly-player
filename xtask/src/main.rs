//! Build tasks for the Swiftly Rust workspace.
//!
//! `cargo run -p xtask -- apple` builds `swiftly-uniffi` as a staticlib for iOS, iOS simulator,
//! tvOS, tvOS simulator and macOS (arm64), generates the Swift bindings in library mode and
//! assembles `Packages/SwiftlyCore` with `SwiftlyCoreFFI.xcframework`.
//!
//! `apple-ui [ios|tvos]` builds the Rust UI comparison apps (`ios.rs`, bundle id de.paulherter.swiftly.rustui).
//! `android [--release]` builds the Rust UI shell for Android and Android TV into a debug APK (`android.rs`).
//!
//! `compare-png a b` prints the mean absolute difference of two PNGs; `android-smoke <tv|phone> [--start-emulator]`
//! builds, installs, launches and screenshots the Android shell and compares Home with the golden (`smoke.rs`).
//!
//! `windows-smoke [--window]`, `linux-smoke` and `package-desktop` run on a Linux build host (Linux natively; Windows is cross-compiled and its run is parked until the VM, see `desktop.rs`).
//!
//! `hardening [--quick] [--regen-oracle] [--perf]` runs the machine hardening pass (`hardening.rs`).
//!
//! `security` runs the supply-chain and safety checks (cargo-audit, cargo-deny, unsafe scan, lints, tests; see `security.rs`).
//!
//! `components [--isd <file>] [--quiet]` checks that every design component name exists in the Rust UI (see `components.rs`).
//!
//! `check-all [--remote] [--start-emulator]` runs the per-target checks of PLAN section 0 (see `check.rs`).
//!
//! Options: `--tvos-build-std <toolchain>` builds the two tvOS targets with
//! `cargo +<toolchain> -Zbuild-std` (for when the prebuilt std is missing); `--debug` skips
//! `--release`.

mod android;
mod check;
mod components;
mod desktop;
mod fixture_big;
mod fixture_hls;
mod fixture_media;
mod fixture_modes;
mod fixture_plex;
mod fixture_seerr;
mod fixture_server;
mod fixture_sessions;
mod fixture_syncplay;
mod hardening;
mod ios;
mod parity;
mod security;
mod smoke;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

const CRATE: &str = "swiftly-uniffi";
const LIB: &str = "libswiftly_uniffi.a";
const FFI_MODULE: &str = "SwiftlyCoreFFI";

/// One platform slice of the xcframework.
struct Slice {
    name: &'static str,
    triple: &'static str,
    tvos: bool,
}

const SLICES: [Slice; 5] = [
    Slice {
        name: "ios",
        triple: "aarch64-apple-ios",
        tvos: false,
    },
    Slice {
        name: "ios-sim",
        triple: "aarch64-apple-ios-sim",
        tvos: false,
    },
    Slice {
        name: "tvos",
        triple: "aarch64-apple-tvos",
        tvos: true,
    },
    Slice {
        name: "tvos-sim",
        triple: "aarch64-apple-tvos-sim",
        tvos: true,
    },
    Slice {
        name: "macos",
        triple: "aarch64-apple-darwin",
        tvos: false,
    },
];

/// The Intel half of the macOS slice. It is built like the others but never gets an xcframework entry of its
/// own: `apple` joins it with the arm64 macOS library into one fat library (`lipo`), because an
/// xcframework allows one library per platform variant.
const MACOS_X86: Slice = Slice {
    name: "macos-x86_64",
    triple: "x86_64-apple-darwin",
    tvos: false,
};

type Fail = String;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("apple") => apple(&args[1..]),
        Some("apple-ui") => root().and_then(|r| ios::run(&r, &args[1..])),
        Some("android") => root().and_then(|r| android::run(&r, &args[1..])),
        Some("swiftui-parity") => root().and_then(|r| parity::run(&r, &args[1..])),
        Some("compare-png") => smoke::compare_cmd(&args[1..]),
        Some("android-smoke") => root().and_then(|r| smoke::run(&r, &args[1..])),
        Some(w @ ("windows-smoke" | "linux-smoke")) => root().and_then(|r| desktop::smoke_cmd(&r, w, &args[1..])),
        Some("package-desktop") => root().and_then(|r| desktop::package_cmd(&r, &args[1..])),
        Some("fixture-server") => fixture_server::run(&args[1..]),
        Some("hardening") => root().and_then(|r| hardening::run(&r, &args[1..])),
        Some("components") => root().and_then(|r| components::run(&r, &args[1..])),
        Some("security") => root().and_then(|r| security::run(&r, &args[1..])),
        Some("check-all") => root().and_then(|r| check::check_all(&r, &args[1..])),
        _ => Err(
            "usage: cargo run -p xtask -- apple [--tvos-build-std <toolchain>] [--debug] [--bindings-only] | apple-ui [ios|tvos] | android [--release] | compare-png <a> <b> | swiftui-parity [--no-render] | android-smoke <tv|phone> [--start-emulator] | windows-smoke [--window] [--hidden] | linux-smoke [--window] | package-desktop | hardening [--quick] [--regen-oracle] [--perf] | security | check-all [--remote] [--start-emulator]"
                .to_owned(),
        ),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("xtask: {message}");
            ExitCode::FAILURE
        }
    }
}

fn root() -> Result<PathBuf, Fail> {
    // xtask/ sits directly under the workspace root.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| "cannot find the workspace root".to_owned())
}

fn run(cmd: &mut Command) -> Result<(), Fail> {
    let shown = format!("{cmd:?}");
    let status = cmd.status().map_err(|e| format!("{shown}: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("failed ({status}): {shown}"))
    }
}

fn apple(args: &[String]) -> Result<(), Fail> {
    let mut build_std: Option<String> = None;
    let mut release = true;
    // Only the macOS arm64 slice and the Swift bindings (`Generated.swift`), no other slice and no xcframework: the
    // quick way to refresh the generated file after an export changed (the full run stays the check of the whole).
    let mut bindings_only = false;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--tvos-build-std" => {
                build_std = Some(
                    it.next()
                        .ok_or("--tvos-build-std needs a toolchain")?
                        .clone(),
                )
            }
            "--debug" => release = false,
            "--bindings-only" => bindings_only = true,
            other => return Err(format!("unknown option {other}")),
        }
    }
    let root = root()?;
    let profile = if release { "release" } else { "debug" };
    // `SWIFTLY_SLICES=ios,macos` builds only these slices (names: ios, ios-sim, tvos, tvos-sim, macos,
    // macos-x86_64; `macos` arm64 is always built, the Swift bindings come from it). A quick development
    // framework for the iPhone/Mac; the default (unset) is the full set that ships.
    let only: Option<Vec<String>> = std::env::var("SWIFTLY_SLICES")
        .ok()
        .map(|v| v.split(',').map(|n| n.trim().to_owned()).collect());
    let wanted = |name: &str| {
        name == "macos"
            || only
                .as_ref()
                .is_none_or(|list| list.iter().any(|n| n == name))
    };

    for slice in SLICES.iter().chain(std::iter::once(&MACOS_X86)) {
        if (bindings_only && slice.name != "macos") || !wanted(slice.name) {
            continue;
        }
        let mut cmd = Command::new("cargo");
        if slice.tvos
            && let Some(toolchain) = &build_std
        {
            cmd.arg(format!("+{toolchain}"))
                .args(["build", "-Zbuild-std=std,panic_abort"]);
        } else {
            cmd.arg("build");
        }
        // The C parts (aws-lc) take the SDK's newest version otherwise and the linker warns
        // for every object file; these are the package's minimum versions (Package.swift).
        cmd.args(["-q", "-p", CRATE, "--target", slice.triple])
            .env("MACOSX_DEPLOYMENT_TARGET", "15.0")
            .env("IPHONEOS_DEPLOYMENT_TARGET", "18.0")
            .env("TVOS_DEPLOYMENT_TARGET", "18.0")
            .current_dir(&root);
        if release {
            cmd.arg("--release");
        }
        eprintln!("xtask: building {} ({})", slice.name, slice.triple);
        run(&mut cmd)?;
    }
    let lib = |slice: &Slice| {
        root.join("target")
            .join(slice.triple)
            .join(profile)
            .join(LIB)
    };

    // Swift bindings, library mode, from the macOS slice (the metadata is the same in all).
    let package = root.join("Packages/SwiftlyCore");
    let generated = root.join("target/uniffi-swift");
    let _ = fs::remove_dir_all(&generated);
    fs::create_dir_all(&generated).map_err(|e| e.to_string())?;
    let macos = SLICES
        .iter()
        .find(|s| s.name == "macos")
        .ok_or("no macos slice")?;
    run(Command::new("cargo")
        .args([
            "run",
            "-q",
            "-p",
            "xtask",
            "--bin",
            "uniffi-bindgen",
            "--",
            "generate",
        ])
        .arg(lib(macos))
        .args(["--language", "swift", "--no-format"])
        .arg("--out-dir")
        .arg(&generated)
        .current_dir(&root))?;

    // Sources/SwiftlyCore gets the Swift file; the headers and the modulemap go into the xcframework.
    let sources = package.join("Sources/SwiftlyCore");
    fs::create_dir_all(&sources).map_err(|e| e.to_string())?;
    // In a folder named like the module: Xcode flattens every static xcframework's headers into one
    // `include/`, and two plain `module.modulemap` files there (LibDovi has one) are a build error.
    // Clang finds `<include>/SwiftlyCoreFFI/module.modulemap` by the module name.
    let _ = fs::remove_dir_all(generated.join("headers"));
    let headers = generated.join("headers").join(FFI_MODULE);
    fs::create_dir_all(&headers).map_err(|e| e.to_string())?;
    for entry in fs::read_dir(&generated).map_err(|e| e.to_string())? {
        let path = entry.map_err(|e| e.to_string())?.path();
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or_default()
            .to_owned();
        if name.ends_with(".swift") {
            let text = fs::read_to_string(&path).map_err(|e| e.to_string())?;
            fs::write(
                sources.join("Generated.swift"),
                patch_foreign_futures(&patch_async_cancellation(&text)?),
            )
            .map_err(|e| e.to_string())?;
        } else if name.ends_with(".h") {
            fs::copy(&path, headers.join(&name)).map_err(|e| e.to_string())?;
        } else if name.ends_with(".modulemap") {
            fs::copy(&path, headers.join("module.modulemap")).map_err(|e| e.to_string())?;
        }
    }

    if bindings_only {
        eprintln!("xtask: wrote {}", sources.join("Generated.swift").display());
        return Ok(());
    }
    let xcframework = package.join(format!("{FFI_MODULE}.xcframework"));
    let _ = fs::remove_dir_all(&xcframework);
    let mut cmd = Command::new("xcodebuild");
    cmd.arg("-create-xcframework");
    for slice in &SLICES {
        if !wanted(slice.name) {
            continue;
        }
        // LibDovi (inside AetherEngine) links a second copy of Rust's std into the Mac app.
        let library = if slice.name == "macos" {
            // Apple Silicon and Intel, each patched, in one fat library (arm64 alone in a development framework).
            let arm = hide_eh_personality(&lib(slice), "arm64")?;
            let fat = root.join("target/macos-universal").join(LIB);
            fs::create_dir_all(fat.parent().unwrap_or(&root)).map_err(|e| e.to_string())?;
            if wanted("macos-x86_64") {
                let intel = hide_eh_personality(&lib(&MACOS_X86), "x86_64")?;
                run(Command::new("lipo")
                    .arg("-create")
                    .arg(&arm)
                    .arg(&intel)
                    .arg("-output")
                    .arg(&fat))?;
            } else {
                fs::copy(&arm, &fat).map_err(|e| e.to_string())?;
            }
            fat
        } else {
            lib(slice)
        };
        cmd.arg("-library")
            .arg(library)
            .arg("-headers")
            .arg(headers.parent().unwrap_or(&headers));
    }
    cmd.arg("-output").arg(&xcframework);
    run(&mut cmd)?;

    for slice in SLICES
        .iter()
        .chain(std::iter::once(&MACOS_X86))
        .filter(|s| wanted(s.name))
    {
        let size = fs::metadata(lib(slice)).map(|m| m.len()).unwrap_or(0);
        eprintln!("xtask: {:<9} {:>8} KiB", slice.name, size / 1024);
    }
    eprintln!("xtask: wrote {}", xcframework.display());
    Ok(())
}

/// **The Mac link clash with LibDovi.** The macOS app already links LibDovi, a Rust static library with its own
/// copy of `std`; both copies define `_rust_eh_personality`, and the Mac linker stops with "duplicate symbol"
/// (iOS and tvOS drop the unused copy and are fine). This returns a patched copy of our macOS library whose
/// `std` object defines `_rust_eh_personalitX` instead (same length, one string-table entry): our other
/// objects keep asking for `_rust_eh_personality` and get LibDovi's copy, which is the same function from
/// the same `std` source. A weak `_rust_eh_personality` that jumps to the renamed copy is added as well, so the
/// package links alone too (`swift test`). The original library is not touched. Fails loudly when the library has changed
/// shape, instead of linking something else.
fn hide_eh_personality(lib: &Path, arch: &str) -> Result<PathBuf, Fail> {
    const SYMBOL: &[u8] = b"_rust_eh_personality\0";
    const HIDDEN: &[u8] = b"_rust_eh_personalitX\0";
    let dir = lib.with_file_name("macos-link-fix");
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let patched = dir.join(LIB);
    fs::copy(lib, &patched).map_err(|e| e.to_string())?;
    let names = Command::new("ar")
        .arg("t")
        .arg(&patched)
        .output()
        .map_err(|e| format!("ar: {e}"))?;
    let names = String::from_utf8_lossy(&names.stdout).into_owned();
    let mut done = 0;
    for member in names
        .lines()
        .filter(|m| m.starts_with("std-") && m.ends_with(".o"))
    {
        let out = Command::new("ar")
            .arg("p")
            .arg(&patched)
            .arg(member)
            .output()
            .map_err(|e| format!("ar: {e}"))?;
        let found: Vec<usize> = out
            .stdout
            .windows(SYMBOL.len())
            .enumerate()
            .filter(|(_, w)| *w == SYMBOL)
            .map(|(i, _)| i)
            .collect();
        if found.len() != 1 {
            continue;
        }
        let mut bytes = out.stdout;
        bytes[found[0]..found[0] + HIDDEN.len()].copy_from_slice(HIDDEN);
        let file = dir.join(member);
        fs::write(&file, bytes).map_err(|e| e.to_string())?;
        run(Command::new("ar")
            .arg("r")
            .arg(&patched)
            .arg(&file)
            .current_dir(&dir))?;
        done += 1;
    }
    // Without LibDovi (the package's own `swift test`) the symbol must still exist: a weak stand-in that
    // jumps to our renamed copy. Next to LibDovi's strong definition it simply loses.
    let jump = if arch == "x86_64" { "jmp" } else { "b" };
    let asm = dir.join("eh_personality_fallback.s");
    fs::write(
        &asm,
        format!(".globl _rust_eh_personality\n.weak_definition _rust_eh_personality\n.p2align 2\n_rust_eh_personality:\n    {jump} _rust_eh_personalitX\n"),
    )
    .map_err(|e| e.to_string())?;
    let object = dir.join("eh_personality_fallback.o");
    run(Command::new("xcrun")
        .args([
            "clang",
            "-c",
            "-target",
            &format!("{arch}-apple-macos15.0"),
            "-x",
            "assembler",
        ])
        .arg(&asm)
        .arg("-o")
        .arg(&object))?;
    run(Command::new("ar")
        .arg("r")
        .arg(&patched)
        .arg(&object)
        .current_dir(&dir))?;
    if done != 1 {
        return Err(format!(
            "macOS link fix: expected one std object with _rust_eh_personality in {}, patched {done}",
            lib.display()
        ));
    }
    run(Command::new("ranlib").arg(&patched))?;
    Ok(patched)
}

/// UniFFI 0.32's Swift template does not cancel the Rust future when the Swift `Task` is
/// cancelled (`CALL_CANCELLED` is a `fatalError`), although the FFI offers `rust_future_cancel_*`.
/// This wraps the poll loop in `withTaskCancellationHandler`, passes the matching cancel
/// function at every call site and throws `CancellationError` instead of completing. Calls
/// that cannot throw (`try!`) would trap, so every async export must return a `Result`; the
/// patch refuses to run when one does not.
fn patch_async_cancellation(source: &str) -> Result<String, Fail> {
    const FREE_PREFIX: &str = "freeFunc: ffi_swiftly_uniffi_rust_future_free_";
    const OLD_PARAM: &str = "    freeFunc: (UInt64) -> (),\n    liftFunc:";
    const NEW_PARAM: &str = "    freeFunc: (UInt64) -> (),\n    cancelFunc: @escaping @Sendable (UInt64) -> (),\n    liftFunc:";
    const OLD_LOOP: &str = "    var pollResult: Int8;\n    repeat {\n        pollResult = await withUnsafeContinuation {\n            pollFunc(\n                rustFuture,\n                { handle, pollResult in\n                    uniffiFutureContinuationCallback(handle: handle, pollResult: pollResult)\n                },\n                uniffiContinuationHandleMap.insert(obj: $0)\n            )\n        }\n    } while pollResult != UNIFFI_RUST_FUTURE_POLL_READY\n";
    const NEW_LOOP: &str = "    await withTaskCancellationHandler {\n        var pollResult: Int8\n        repeat {\n            pollResult = await withUnsafeContinuation {\n                pollFunc(\n                    rustFuture,\n                    { handle, pollResult in\n                        uniffiFutureContinuationCallback(handle: handle, pollResult: pollResult)\n                    },\n                    uniffiContinuationHandleMap.insert(obj: $0)\n                )\n            }\n        } while pollResult != UNIFFI_RUST_FUTURE_POLL_READY\n    } onCancel: {\n        cancelFunc(rustFuture)\n    }\n    // A cancelled future must not be completed; the free above drops it.\n    try Task.checkCancellation()\n";

    // The Android-only objects (`Legacy*`, `TakeoverCalls`) have async methods that cannot throw; the Swift apps
    // never call them, so a cancelled Task cannot reach the `try!` there. Anything else must return a Result.
    for (at, _) in source.match_indices("try!  await uniffiRustCallAsync") {
        let owner = source[..at]
            .rfind("open class ")
            .map(|c| &source[c + "open class ".len()..]);
        if !owner
            .is_some_and(|name| name.starts_with("Legacy") || name.starts_with("TakeoverCalls"))
        {
            return Err("an async export cannot throw: return Result<_, CoreError> so a cancelled Task does not trap".to_owned());
        }
    }
    if !source.contains(OLD_PARAM) || !source.contains(OLD_LOOP) {
        return Err(
            "the generated uniffiRustCallAsync changed: update patch_async_cancellation".to_owned(),
        );
    }
    let mut out = String::with_capacity(source.len() + 1024);
    for line in source
        .replace(OLD_PARAM, NEW_PARAM)
        .replace(OLD_LOOP, NEW_LOOP)
        .split_inclusive('\n')
    {
        out.push_str(line);
        if let Some(at) = line.find(FREE_PREFIX) {
            let indent = &line[..at];
            let suffix = line[at + FREE_PREFIX.len()..].trim_end();
            out.push_str(&format!(
                "{indent}cancelFunc: ffi_swiftly_uniffi_rust_future_cancel_{suffix}\n"
            ));
        }
    }
    Ok(out)
}

/// Swift 6 rejects the generated helpers that run a Swift implementation of an async foreign
/// trait (`Task { ... makeCall() }` captures non-`Sendable` closures). The closures are called
/// once, from that one task, so they are marked `nonisolated(unsafe)` and used under new names.
fn patch_foreign_futures(source: &str) -> String {
    const START: &str = "private func uniffiTraitInterfaceCallAsync<T>(";
    const END: &str = "// Borrow the callback handle map implementation";
    let (Some(a), Some(b)) = (source.find(START), source.find(END)) else {
        return source.to_owned();
    };
    let mut section = source[a..b].to_owned();
    for name in ["makeCall", "handleSuccess", "handleError", "lowerError"] {
        let new = format!("unsafe_{name}");
        section = section
            .replace(
                &format!("try await {name}()"),
                &format!("try await {new}()"),
            )
            .replace(&format!("        {name}("), &format!("        {new}("))
            .replace(
                &format!("{name}(callResult)"),
                &format!("{new}(callResult)"),
            )
            .replace(&format!("{name}(CALL_"), &format!("{new}(CALL_"))
            .replace(&format!("{name}(error)"), &format!("{new}(error)"));
    }
    section = section.replace("unsafe_unsafe_", "unsafe_");
    section = section.replace(
        "    let task = Task {\n",
        "    nonisolated(unsafe) let unsafe_makeCall = makeCall\n    nonisolated(unsafe) let unsafe_handleSuccess = handleSuccess\n    nonisolated(unsafe) let unsafe_handleError = handleError\n    let task = Task {\n",
    );
    // `lowerError` exists only in the second helper.
    section = section.replace(
        "    nonisolated(unsafe) let unsafe_handleError = handleError\n    let task = Task {\n        // See the note",
        "    nonisolated(unsafe) let unsafe_handleError = handleError\n    nonisolated(unsafe) let unsafe_lowerError = lowerError\n    let task = Task {\n        // See the note",
    );
    format!("{}{}{}", &source[..a], section, &source[b..])
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Runs on the macOS library when `cargo xtask apple` has built it; skips otherwise.
    #[test]
    fn link_fix_hides_exactly_one_definition() {
        let (triple, arch) = if cfg!(target_arch = "x86_64") {
            ("x86_64-apple-darwin", "x86_64")
        } else {
            ("aarch64-apple-darwin", "arm64")
        };
        let lib = root()
            .unwrap()
            .join("target")
            .join(triple)
            .join("release")
            .join(LIB);
        if !lib.exists() {
            return;
        }
        let fixed = hide_eh_personality(&lib, arch).unwrap();
        let out = Command::new("ar").arg("t").arg(&fixed).output().unwrap();
        let before = Command::new("ar").arg("t").arg(&lib).output().unwrap();
        // One member more: the weak fallback.
        assert_eq!(
            String::from_utf8_lossy(&out.stdout).lines().count(),
            String::from_utf8_lossy(&before.stdout).lines().count() + 1
        );
    }
}
