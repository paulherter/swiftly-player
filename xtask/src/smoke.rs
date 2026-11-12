//! `compare-png` and `android-smoke`: the numbers behind "identical on every OS" for the Android shell.
//! A screenshot of the running shell is compared per pixel with the golden of the same form.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Mean absolute difference per channel (0..255) and the share of pixels whose channels all differ by at most 8.
pub struct Diff {
    pub mean_abs: f64,
    pub within8: f64,
}

pub(crate) fn decode(path: &Path) -> Result<(u32, u32, Vec<u8>), String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut dec = png::Decoder::new(std::io::BufReader::new(file));
    dec.set_transformations(png::Transformations::EXPAND);
    let mut reader = dec
        .read_info()
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let mut buf = vec![0; reader.output_buffer_size().ok_or("png too large")?];
    let info = reader
        .next_frame(&mut buf)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    buf.truncate(info.buffer_size());
    let ch = info.color_type.samples();
    let mut rgb = Vec::with_capacity(buf.len() / ch * 3);
    for px in buf.chunks_exact(ch) {
        match ch {
            1 | 2 => rgb.extend([px[0]; 3]),
            _ => rgb.extend(&px[..3]),
        }
    }
    Ok((info.width, info.height, rgb))
}

/// Compares two PNGs of the same size (alpha ignored).
pub fn compare(a: &Path, b: &Path) -> Result<Diff, String> {
    let (wa, ha, pa) = decode(a)?;
    let (wb, hb, pb) = decode(b)?;
    if (wa, ha) != (wb, hb) {
        return Err(format!("size differs: {wa}x{ha} vs {wb}x{hb}"));
    }
    let mut sum = 0u64;
    let mut close = 0u64;
    for (x, y) in pa.as_chunks::<3>().0.iter().zip(pb.as_chunks::<3>().0) {
        let d = [0, 1, 2].map(|i| u64::from(x[i].abs_diff(y[i])));
        sum += d.iter().sum::<u64>();
        close += u64::from(d.iter().all(|v| *v <= 8));
    }
    let px = (u64::from(wa) * u64::from(ha)).max(1);
    Ok(Diff {
        mean_abs: sum as f64 / (px * 3) as f64,
        within8: close as f64 / px as f64,
    })
}

/// `compare-png a b`.
pub fn compare_cmd(args: &[String]) -> Result<(), String> {
    let [a, b] = args else {
        return Err("usage: compare-png <a.png> <b.png>".to_owned());
    };
    let d = compare(Path::new(a), Path::new(b))?;
    println!(
        "mean abs diff {:.3} / 255, within 8 levels {:.2} %",
        d.mean_abs,
        d.within8 * 100.0
    );
    Ok(())
}

struct Form {
    serial: &'static str,
    avd: &'static str,
    golden: &'static str,
    /// `wm size` / `wm density` to apply for the measurement.
    size: &'static str,
    density: &'static str,
}

fn form(name: &str) -> Result<Form, String> {
    match name {
        "tv" => Ok(Form {
            serial: "emulator-5556",
            avd: "swiftly-tv",
            golden: "home_tv_initial.png",
            size: "1920x1080",
            density: "320",
        }),
        "phone" => Ok(Form {
            serial: "emulator-5554",
            avd: "swiftly-handy",
            golden: "home_touch_initial.png",
            size: "1170x2532",
            density: "480",
        }),
        other => Err(format!("unknown form {other:?} (tv or phone)")),
    }
}

fn sdk() -> PathBuf {
    std::env::var("ANDROID_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_default()).join("Library/Android/sdk")
        })
}

fn adb(serial: &str, args: &[&str]) -> Result<Vec<u8>, String> {
    let o = Command::new(sdk().join("platform-tools/adb"))
        .args(["-s", serial])
        .args(args)
        .output()
        .map_err(|e| format!("adb: {e}"))?;
    if o.status.success() {
        Ok(o.stdout)
    } else {
        Err(format!(
            "adb {args:?}: {}",
            String::from_utf8_lossy(&o.stderr).trim()
        ))
    }
}

fn running(serial: &str) -> bool {
    adb(serial, &["get-state"]).is_ok_and(|o| String::from_utf8_lossy(&o).trim() == "device")
}

/// Result of one smoke run: the line for `check-all`, and whether it failed.
pub struct Smoke {
    pub line: String,
    pub failed: bool,
}

/// Builds (unless `apk` is given), installs, launches, screenshots and compares. `Smoke` with "not run (needs ...)"
/// when the emulator is not up and `start` is false.
pub fn smoke(root: &Path, name: &str, start: bool, apk: Option<PathBuf>) -> Smoke {
    let fail = |m: String| Smoke {
        line: format!("smoke FAILED ({m})"),
        failed: true,
    };
    let f = match form(name) {
        Ok(f) => f,
        Err(e) => return fail(e),
    };
    let mut started: Option<std::process::Child> = None;
    if !running(f.serial) {
        if !start {
            return Smoke {
                line: format!(
                    "smoke: not run (needs {} running, or --start-emulator)",
                    f.serial
                ),
                failed: false,
            };
        }
        let port = f.serial.trim_start_matches("emulator-");
        let child = Command::new(sdk().join("emulator/emulator"))
            .args([
                "-avd",
                f.avd,
                "-port",
                port,
                "-no-audio",
                "-no-boot-anim",
                "-gpu",
                "swiftshader_indirect",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        started = match child {
            Ok(c) => Some(c),
            Err(e) => return fail(format!("emulator: {e}")),
        };
    }
    let result = measure(root, &f, started.is_some(), apk);
    if let Some(mut child) = started {
        let _ = adb(f.serial, &["emu", "kill"]);
        let _ = child.wait();
    }
    match result {
        Ok(s) => s,
        Err(e) => fail(e),
    }
}

fn measure(
    root: &Path,
    f: &Form,
    booted_here: bool,
    apk: Option<PathBuf>,
) -> Result<Smoke, String> {
    if booted_here {
        let t = Instant::now();
        while !(running(f.serial)
            && adb(f.serial, &["shell", "getprop", "sys.boot_completed"])
                .is_ok_and(|o| String::from_utf8_lossy(&o).trim() == "1"))
        {
            if t.elapsed() > Duration::from_secs(240) {
                return Err("emulator did not boot in 240 s".to_owned());
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    }
    if booted_here {
        // A fresh boot starts the first-run wizards (Device Lock, Google TV setup) on top of any app.
        for (ns, key) in [
            ("global", "device_provisioned"),
            ("secure", "user_setup_complete"),
            ("secure", "tv_user_setup_complete"),
        ] {
            let _ = adb(f.serial, &["shell", "settings", "put", ns, key, "1"]);
        }
        std::thread::sleep(Duration::from_secs(15));
    }
    let apk = match apk {
        Some(a) => a,
        None => match crate::android::build(root, false)? {
            crate::android::Built::Ok(a) => a,
            crate::android::Built::Missing(need) => {
                return Ok(Smoke {
                    line: format!("smoke: not run (needs {need})"),
                    failed: false,
                });
            }
        },
    };
    let t0 = Instant::now();
    let old_size = adb(f.serial, &["shell", "wm", "size"])
        .map(|o| String::from_utf8_lossy(&o).into_owned())
        .unwrap_or_default();
    let changed = !old_size.contains(f.size);
    let go = || -> Result<Diff, String> {
        if changed {
            adb(f.serial, &["shell", "wm", "size", f.size])?;
            adb(f.serial, &["shell", "wm", "density", f.density])?;
        }
        adb(f.serial, &["install", "-r", &apk.to_string_lossy()])?;
        adb(
            f.serial,
            &["shell", "am", "force-stop", "app.swiftly.rustshell"],
        )?;
        adb(
            f.serial,
            &[
                "shell",
                "am",
                "start",
                "-n",
                "app.swiftly.rustshell/.ShellActivity",
                "--ez",
                "bare",
                "true",
                "--ez",
                "demo",
                "true",
            ],
        )?;
        std::thread::sleep(Duration::from_secs(8));
        let shot = adb(f.serial, &["exec-out", "screencap", "-p"])?;
        let dir = root.join("target/android-smoke");
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let out = dir.join(format!("{}.png", f.golden.trim_end_matches(".png")));
        std::fs::write(&out, shot).map_err(|e| e.to_string())?;
        let _ = adb(
            f.serial,
            &["shell", "am", "force-stop", "app.swiftly.rustshell"],
        );
        compare(
            &out,
            &root.join("crates/swiftly-ui/tests/golden").join(f.golden),
        )
    };
    let res = go();
    if changed {
        let _ = adb(f.serial, &["shell", "wm", "size", "reset"]);
        let _ = adb(f.serial, &["shell", "wm", "density", "reset"]);
    }
    let d = res?;
    // Same renderer and fonts; the focus ring and the clock-driven motion may differ a little.
    let ok = d.mean_abs <= 3.0 && d.within8 >= 0.97;
    Ok(Smoke {
        line: format!(
            "smoke {} on {}: diff {:.3}/255, {:.2} % within 8 ({:.0} s)",
            if ok { "ok" } else { "FAILED" },
            f.serial,
            d.mean_abs,
            d.within8 * 100.0,
            t0.elapsed().as_secs_f64()
        ),
        failed: !ok,
    })
}

/// The live run on a booted emulator: the real app signs in on `address` (the fixture server through `10.0.2.2`, or a
/// public server), the 15 s play smoke runs through Media3, and the log must show `SMOKE-PLAY ok`, rendered video frames
/// and, for the fixture, start, progress and stop reports at the server (`GET /fixture/reports` on the Mac side).
fn live(serial: &str, address: &str, fixture_port: Option<u16>) -> Result<String, String> {
    let app = "app.swiftly.rustshell";
    let t0 = Instant::now();
    adb(serial, &["shell", "pm", "clear", app])?;
    adb(serial, &["logcat", "-c"])?;
    let extra = format!(
        "{address},demo,{}",
        if fixture_port.is_some() { "demo" } else { "" }
    );
    let play = format!("{extra},15");
    let mut args = vec![
        "shell",
        "am",
        "start",
        "-n",
        "app.swiftly.rustshell/.ShellActivity",
        "--es",
        "autologin",
        &extra,
    ];
    if fixture_port.is_some() {
        args.extend(["--es", "smokeplay", &play]);
    }
    adb(serial, &args)?;
    std::thread::sleep(Duration::from_secs(if fixture_port.is_some() {
        36
    } else {
        20
    }));
    let log = String::from_utf8_lossy(&adb(serial, &["logcat", "-d"])?).into_owned();
    let shot = adb(serial, &["exec-out", "screencap", "-p"])?;
    let _ = adb(serial, &["shell", "am", "force-stop", app]);
    let mut lines = vec![format!(
        "live {serial}: autologin {}",
        if log.contains("autologin: ") {
            "ok"
        } else {
            "MISSING"
        }
    )];
    if !log.contains("autologin: ") {
        return Err(format!("{}\nno sign-in line in the log", lines.join("\n")));
    }
    if let Some(port) = fixture_port {
        let rendered = log
            .lines()
            .rev()
            .find_map(|l| l.split("rendered=").nth(1))
            .and_then(|r| r.split(' ').next())
            .and_then(|n| n.parse::<u32>().ok())
            .unwrap_or(0);
        let reports = Command::new("curl")
            .args(["-s", &format!("http://127.0.0.1:{port}/fixture/reports")])
            .output()
            .map_err(|e| e.to_string())?;
        let reports = String::from_utf8_lossy(&reports.stdout).into_owned();
        lines.push(format!(
            "play: SMOKE-PLAY ok {}, frames rendered {rendered}, reports {reports}",
            log.contains("SMOKE-PLAY ok")
        ));
        if !log.contains("SMOKE-PLAY ok") || rendered == 0 || !reports.contains("Progress") {
            return Err(lines.join("\n"));
        }
    }
    let dir = Path::new("target/android-smoke");
    let _ = std::fs::create_dir_all(dir);
    let _ = std::fs::write(dir.join(format!("live-{serial}.png")), &shot);
    lines.push(format!(
        "home screencap {} bytes ({:.0} s)",
        shot.len(),
        t0.elapsed().as_secs_f64()
    ));
    Ok(lines.join("\n"))
}

/// `android-smoke <tv|phone> [--start-emulator] [--live ADDRESS [--fixture-port N]]`.
pub fn run(root: &Path, args: &[String]) -> Result<(), String> {
    let name = args
        .iter()
        .find(|a| !a.starts_with("--"))
        .ok_or("usage: android-smoke <tv|phone> [--start-emulator]")?;
    let s = smoke(
        root,
        name,
        args.iter().any(|a| a == "--start-emulator"),
        None,
    );
    println!("{}", s.line);
    if let Some(i) = args.iter().position(|a| a == "--live") {
        let address = args.get(i + 1).ok_or("--live needs an address")?;
        let port = args
            .iter()
            .position(|a| a == "--fixture-port")
            .and_then(|j| args.get(j + 1))
            .and_then(|p| p.parse().ok());
        let serial = if name == "tv" {
            "emulator-5556"
        } else {
            "emulator-5554"
        };
        println!("{}", live(serial, address, port)?);
    }
    if s.failed {
        Err("android smoke failed".to_owned())
    } else {
        Ok(())
    }
}
