//! Desktop smoke and packaging on a Linux build host.
//! - `linux-smoke [--window]`: builds `swiftly-desktop` release (with libmpv) natively, renders the app headless at
//!   scale 2 and compares the PNG with the Home golden. With `--window` it also runs a real window, but only inside a
//!   private headless weston compositor (never on a real desktop session): frame dump vs golden, then `--stats`.
//! - `windows-smoke`: Windows is cross-compiled with `cargo xwin` (build + icon check); running it is parked until the
//!   Windows VM exists.
//! - `package-desktop`: `Werkzeuge/package-desktop.sh` on the build host (deb, rpm, tar.gz, Windows Setup.exe + portable zip).
//!
//! On a Linux host everything runs locally. From another machine the sources go to a Linux build host through a remote
//! runner: set `SWIFTLY_REMOTE_TOOL` (a command with the sub-commands `list`, `do` and `pull`) and `SWIFTLY_REMOTE_HOST`
//! (the host name that tool knows).

use std::path::Path;
use std::process::Command;

const REMOTE_DIR: &str = "swiftly-xtask";
const GOLDEN: &str = "crates/swiftly-ui/tests/golden/app_desktop_smoke.png";
const WINDOWS_PARKED: &str =
    "parked: Windows runs wait for the Windows VM (the exe is only cross-compiled)";

/// Result of one smoke: the one-line text and whether it failed.
pub struct Smoke {
    pub line: String,
    pub failed: bool,
}

fn out(cmd: &mut Command) -> Result<String, String> {
    let o = cmd.output().map_err(|e| format!("{cmd:?}: {e}"))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
    if o.status.success() {
        Ok(text)
    } else {
        let tail: Vec<&str> = text.lines().rev().take(12).collect();
        Err(tail.into_iter().rev().collect::<Vec<_>>().join(" / "))
    }
}

/// The remote runner from the environment: (tool, host), or `None` when it is not configured.
fn remote() -> Option<(String, String)> {
    let tool = std::env::var("SWIFTLY_REMOTE_TOOL")
        .ok()
        .filter(|t| !t.is_empty())?;
    let host = std::env::var("SWIFTLY_REMOTE_HOST")
        .ok()
        .filter(|h| !h.is_empty())?;
    Some((tool, host))
}

/// True on a Linux host (then everything runs here) or when the configured Linux build host is connected.
pub fn linux_machine_ready() -> bool {
    if cfg!(target_os = "linux") {
        return true;
    }
    let Some((tool, host)) = remote() else {
        return false;
    };
    Command::new(tool).arg("list").output().is_ok_and(|o| {
        String::from_utf8_lossy(&o.stdout).lines().any(|l| {
            let mut c = l.split_whitespace();
            c.next() == Some(host.as_str()) && c.next() == Some("verbunden")
        })
    })
}

/// Runs a bash `script` in the repo root on Linux (here, or on the build host through the remote runner); `back` are
/// files (relative to the root) that come back to the same place on this machine.
fn run_linux(root: &Path, script: &str, back: &[&str]) -> Result<String, String> {
    let prelude = "export PATH=$HOME/.cargo/bin:$PATH; set -e; ";
    if cfg!(target_os = "linux") {
        return out(Command::new("bash")
            .current_dir(root)
            .arg("-c")
            .arg(format!("{prelude}{script}")));
    }
    let b64 = base64(
        format!("export CARGO_BUILD_JOBS=10 RUSTC_WRAPPER=sccache; {prelude}{script}").as_bytes(),
    );
    let (tool, host) =
        remote().ok_or("no Linux build host: set SWIFTLY_REMOTE_TOOL and SWIFTLY_REMOTE_HOST")?;
    let mut cmd = Command::new(tool);
    cmd.current_dir(root)
        .args(["do", &host, "--dir", REMOTE_DIR]);
    for b in back {
        cmd.args(["--back", b]);
    }
    out(cmd.args(["--", &format!("echo {b64} | base64 -d | bash")]))
}

fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::new();
    for c in bytes.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= c.len() {
                s.push(T[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                s.push('=');
            }
        }
    }
    s
}

/// The window checks as one bash script: a private headless weston (own `XDG_RUNTIME_DIR`, so the real desktop session is never
/// touched), then the real frame the swapchain presents (`--dump-frame`) and the frame statistics. Prints marker lines.
fn window_script(exe: &str) -> String {
    format!(
        r#"R=$(mktemp -d); chmod 700 $R; export XDG_RUNTIME_DIR=$R
weston --backend=headless --socket=wl-swiftly-smoke --no-config >$R/weston.log 2>&1 & W=$!
for i in $(seq 100); do [ -S $R/wl-swiftly-smoke ] && break; sleep 0.1; done
export WAYLAND_DISPLAY=wl-swiftly-smoke
echo "DUMP: $({exe} --demo app --dump-frame target/linux-smoke/wdump.png --exit-after-dump --quit-after 30 2>&1 | tail -4 | tr '
' ' ')"
echo "STATS: $({exe} --demo app --stats --autoplay --quit-after 12 2>&1 | grep p50 | tail -1)"
kill $W 2>/dev/null; wait $W 2>/dev/null; true
"#
    )
}

fn linux_smoke(root: &Path, window: bool) -> Smoke {
    let fail = |m: String| Smoke {
        line: format!("smoke FAILED ({m})"),
        failed: true,
    };
    if !linux_machine_ready() {
        return Smoke {
            line: "smoke: not run (no Linux build host connected)".to_owned(),
            failed: false,
        };
    }
    let result = (|| -> Result<String, String> {
        let exe = "./target/release/swiftly-desktop";
        let mut script = format!(
            "cargo build -q --release -p swiftly-desktop --features mpv; mkdir -p target/linux-smoke; {exe} --demo app --size 1280x800 --frames 5 --scale 2 --png target/linux-smoke/smoke.png"
        );
        let mut back = vec!["target/linux-smoke/smoke.png"];
        if window {
            script.push_str(&format!(
                "; {exe} --demo app --frames 5 --scale 1 --png target/linux-smoke/wgold.png; {}",
                window_script(exe)
            ));
            back.extend([
                "target/linux-smoke/wdump.png",
                "target/linux-smoke/wgold.png",
            ]);
        }
        let text = run_linux(root, &script, &back)?;
        let dir = root.join("target/linux-smoke");
        let d = crate::smoke::compare(&dir.join("smoke.png"), &root.join(GOLDEN))?;
        let mut line = format!(
            "smoke: ok on the Linux build host (headless app demo vs golden: mean abs {:.3}/255, within 8 levels {:.2} %)",
            d.mean_abs,
            d.within8 * 100.0
        );
        if window {
            line.push_str(&window_report(&dir, &text));
        }
        Ok(line)
    })();
    match result {
        Ok(line) => Smoke {
            line,
            failed: false,
        },
        Err(e) => fail(e),
    }
}

/// Reads the marker lines of `window_script`: frame size/format from `dump-frame: WxH px, fmt`, the compare against
/// the headless golden at the window's scale (`wgold.png` was rendered at scale 1; sizes must match to compare), stats.
fn window_report(dir: &Path, text: &str) -> String {
    let dump = text
        .lines()
        .find(|l| l.starts_with("DUMP:"))
        .unwrap_or("DUMP: no output");
    let stats = text
        .lines()
        .find(|l| l.starts_with("STATS:"))
        .unwrap_or("STATS:")
        .trim_start_matches("STATS:")
        .trim();
    let Some(rest) = dump
        .find("dump-frame: ")
        .map(|i| &dump[i + "dump-frame: ".len()..])
    else {
        return format!(" | window dump FAILED ({})", dump.trim());
    };
    let size = rest.split(',').next().unwrap_or("?");
    let cmp = crate::smoke::compare(&dir.join("wdump.png"), &dir.join("wgold.png"))
        .map(|d| {
            format!(
                "mean abs {:.3}/255, within 8 levels {:.2} %",
                d.mean_abs,
                d.within8 * 100.0
            )
        })
        .unwrap_or_else(|e| format!("not compared ({e})"));
    format!(
        " | real window frame {size} in headless weston vs headless golden: {cmp} | stats: {}",
        if stats.is_empty() { "none" } else { stats }
    )
}

/// Cross-compiles the Windows exe on Linux and checks that the icon/version resource ("Swiftly Player") is inside.
fn windows_build(root: &Path) -> Result<String, String> {
    if !linux_machine_ready() {
        return Err("no Linux build host connected".to_owned());
    }
    let script = r#"cargo xwin build -q --release --target x86_64-pc-windows-msvc -p swiftly-desktop --features mpv
E=target/x86_64-pc-windows-msvc/release/swiftly-desktop.exe
echo "size: $(stat -c %s $E)"
echo "icon/version resource: $(LC_ALL=C grep -c -a -P 'S\x00w\x00i\x00f\x00t\x00l\x00y\x00 \x00P\x00l\x00a\x00y\x00e\x00r' $E) hit(s) for the UTF-16 name""#;
    run_linux(root, script, &[])
}

/// `windows-smoke`: cross-compile only; the run is parked until the Windows VM exists. `linux-smoke [--window]`.
pub fn smoke_cmd(root: &Path, which: &str, args: &[String]) -> Result<(), String> {
    if which == "windows-smoke" {
        let built = windows_build(root).map(|t| {
            t.lines()
                .filter(|l| l.starts_with("size") || l.starts_with("icon"))
                .collect::<Vec<_>>()
                .join(", ")
        });
        match built {
            Ok(t) => println!("windows-smoke {WINDOWS_PARKED}; cross-compile ok ({t})"),
            Err(e) => {
                return Err(format!(
                    "windows cross-compile FAILED ({e}); run itself is {WINDOWS_PARKED}"
                ));
            }
        }
        return Ok(());
    }
    let s = linux_smoke(root, args.iter().any(|a| a == "--window"));
    println!("{}", s.line);
    if s.failed {
        Err("smoke failed".to_owned())
    } else {
        Ok(())
    }
}

/// `check-all` entry: same run, no window. Windows is parked.
pub fn smoke_for_check(root: &Path, os: &str) -> Smoke {
    if os == "windows" {
        return Smoke {
            line: format!("smoke: {WINDOWS_PARKED}"),
            failed: false,
        };
    }
    linux_smoke(root, false)
}

/// `package-desktop`: runs `Werkzeuge/package-desktop.sh` on the Linux build host and pulls the results into
/// `target/desktop-dist` (Linux: tar.gz, deb, rpm; Windows: Setup.exe and the portable zip with libmpv-2.dll).
pub fn package_cmd(root: &Path, _args: &[String]) -> Result<(), String> {
    if !linux_machine_ready() {
        return Err("no Linux build host connected".to_owned());
    }
    let listing = run_linux(
        root,
        "Werkzeuge/package-desktop.sh >/dev/null && ls -1 target/desktop-dist",
        &[],
    )?;
    let dist = root.join("target/desktop-dist");
    std::fs::create_dir_all(&dist).map_err(|e| e.to_string())?;
    for f in listing
        .lines()
        .map(str::trim)
        .filter(|f| f.starts_with("swiftly-player") || f.starts_with("Swiftly-Player"))
    {
        if !cfg!(target_os = "linux") {
            let (tool, host) = remote()
                .ok_or("no Linux build host: set SWIFTLY_REMOTE_TOOL and SWIFTLY_REMOTE_HOST")?;
            out(Command::new(tool)
                .args([
                    "pull",
                    &host,
                    &format!("{REMOTE_DIR}/target/desktop-dist/{f}"),
                ])
                .arg(&dist))?;
        }
        let kib = std::fs::metadata(dist.join(f))
            .map(|m| m.len() / 1024)
            .unwrap_or(0);
        println!("{}: {kib} KiB", dist.join(f).display());
    }
    println!("MSIX: not produced (needs the Windows SDK and a signing certificate)");
    Ok(())
}
