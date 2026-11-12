//! `cargo xtask check-all`: the release checks that can run on this machine, one line per
//! target. Each check runs once and is shared by the targets that use it; smoke runs that need a device or a remote
//! PC are marked `not run`, never green. Exit code is non-zero when a check that ran failed.

use std::path::Path;
use std::process::{Command, Output};

/// A local check: a name and the cargo test arguments that run it.
struct Check {
    name: &'static str,
    args: &'static [&'static str],
}

const MODEL_VM: Check = Check {
    name: "model+vm",
    args: &["test", "-q", "-p", "swiftly-model", "-p", "swiftly-vm"],
};
/// Text input (gate G2): the editor state machine (graphemes, RTL, ja/zh/ko composition, paste, undo) and the field's
/// frame goldens, blink, candidate window and accessibility node.
const TEXT_INPUT: Check = Check {
    name: "text-input",
    args: &[
        "test",
        "-q",
        "-p",
        "swiftly-text",
        "--test",
        "edit",
        "-p",
        "swiftly-desktop",
        "--test",
        "text_field_golden",
    ],
};
/// Gesture tests of the shared UI (touch, scroll, press, edge pan) and of the desktop wheel/shell.
const GESTURES: Check = Check {
    name: "gestures",
    args: &[
        "test",
        "-q",
        "-p",
        "swiftly-ui",
        "-p",
        "swiftly-desktop",
        "--lib",
        "--test",
        "ui",
    ],
};
/// Focus-plan tests of the shared focus engine (pure plans over hand-built maps) and its use in the `Ui`
/// (keys over the laid-out tv scene, spring lift, scroll-into-view, long press). Run for every target with a D-pad or a
/// keyboard; the phones and tablets are touch only.
const FOCUS_PLAN: Check = Check {
    name: "focus-plan",
    args: &[
        "test",
        "-q",
        "-p",
        "swiftly-ui",
        "--test",
        "focus_plan",
        "-p",
        "swiftly-desktop",
        "--test",
        "focus",
    ],
};
macro_rules! golden {
    ($name:expr, $test:expr) => {
        Check {
            name: $name,
            args: &[
                "test",
                "-q",
                "-p",
                "swiftly-desktop",
                "--test",
                "golden",
                "--",
                $test,
                "--exact",
            ],
        }
    };
}
const GOLDEN_TOUCH: Check = golden!("goldens(touch)", "g1_frames_touch_phone");
const GOLDEN_DESKTOP: Check = golden!("goldens(desktop)", "g1_frames_desktop");
const GOLDEN_TV: Check = golden!("goldens(tv)", "g1_frames_tv");
const HOME_TOUCH: Check = golden!(
    "home goldens(touch)",
    "home_frames::home_frames_touch_phone"
);
const HOME_DESKTOP: Check = golden!("home goldens(desktop)", "home_frames::home_frames_desktop");
const HOME_TV: Check = golden!("home goldens(tv)", "home_frames::home_frames_tv");
macro_rules! browse {
    ($name:literal, $filter:literal) => {
        Check {
            name: $name,
            args: &[
                "test",
                "-q",
                "-p",
                "swiftly-desktop",
                "--test",
                "browse_golden",
                "--",
                $filter,
            ],
        }
    };
}
const BROWSE_TOUCH: Check = browse!("library+search goldens(touch)", "touch_phone");
const BROWSE_DESKTOP: Check = browse!("library+search goldens(desktop)", "desktop");
const BROWSE_TV: Check = browse!("library+search goldens(tv)", "tv");
macro_rules! forms {
    ($name:literal, $filter:literal) => {
        Check {
            name: $name,
            args: &[
                "test",
                "-q",
                "-p",
                "swiftly-desktop",
                "--test",
                "forms_golden",
                "--",
                $filter,
            ],
        }
    };
}
const FORMS_TOUCH: Check = forms!("settings+downloads+login goldens(touch)", "touch_phone");
const FORMS_DESKTOP: Check = forms!("settings+downloads+login goldens(desktop)", "desktop");
const FORMS_TV: Check = forms!("settings+downloads+login goldens+focus(tv)", "tv");
/// The forms check of the same form factor as the browse check.
fn forms_for(browse: &Check) -> &'static Check {
    if browse.name.contains("(tv)") {
        &FORMS_TV
    } else if browse.name.contains("(desktop)") {
        &FORMS_DESKTOP
    } else {
        &FORMS_TOUCH
    }
}
macro_rules! title_frames {
    ($name:expr, $test:expr) => {
        Check {
            name: $name,
            args: &[
                "test",
                "-q",
                "-p",
                "swiftly-desktop",
                "--test",
                "detail_frames",
                "--",
                $test,
                "--exact",
            ],
        }
    };
}
const TITLE_TOUCH: Check = title_frames!("detail+series goldens(touch)", "touch_phone");
const TITLE_DESKTOP: Check = title_frames!("detail+series goldens(desktop)", "desktop");
const TITLE_TV: Check = title_frames!("detail+series goldens(tv)", "tv");
macro_rules! app_flow {
    ($name:expr, $test:expr) => {
        Check {
            name: $name,
            args: &[
                "test",
                "-q",
                "-p",
                "swiftly-desktop",
                "--test",
                "app_flow",
                "--",
                $test,
                "--exact",
            ],
        }
    };
}
const APP_TOUCH: Check = app_flow!("app flow(touch)", "touch_flow");
const APP_DESKTOP: Check = app_flow!("app flow(desktop)", "desktop_flow");
const APP_TV: Check = app_flow!("app flow(tv)", "tv_flow");
macro_rules! player_checks {
    ($name:expr, $frames:expr, $flow:expr) => {
        Check {
            name: $name,
            args: &[
                "test",
                "-q",
                "-p",
                "swiftly-desktop",
                "--test",
                "player_frames",
                "--test",
                "player_flow",
                "--",
                $frames,
                $flow,
            ],
        }
    };
}
const PLAYER_TOUCH: Check = player_checks!(
    "player goldens+gestures(touch)",
    "touch_phone",
    "touch_player_flow"
);
const PLAYER_DESKTOP: Check = player_checks!(
    "player goldens+keys(desktop)",
    "desktop",
    "desktop_player_flow"
);
const PLAYER_TV: Check = player_checks!("player goldens+focus(tv)", "tv", "tv_player_flow");

/// A target and what runs for it.
struct Target {
    name: &'static str,
    golden: &'static Check,
    /// The Home screen frames of the same form factor.
    home: &'static Check,
    /// The Library and Search screen frames and focus plans of the same form factor.
    browse: &'static Check,
    /// The focus-plan check; `None` for touch-only targets.
    focus: Option<&'static Check>,
    /// What its smoke run needs; `None` for the remote machines (decided at run time).
    smoke_needs: Option<&'static str>,
    remote: Option<&'static str>,
}

const TARGETS: [Target; 8] = [
    Target {
        name: "iphone",
        golden: &GOLDEN_TOUCH,
        home: &HOME_TOUCH,
        browse: &BROWSE_TOUCH,
        focus: None,
        smoke_needs: Some("iPhone via devicectl"),
        remote: None,
    },
    Target {
        name: "ipad",
        golden: &GOLDEN_TOUCH,
        home: &HOME_TOUCH,
        browse: &BROWSE_TOUCH,
        focus: None,
        smoke_needs: Some("iPad via devicectl"),
        remote: None,
    },
    Target {
        name: "mac",
        golden: &GOLDEN_DESKTOP,
        home: &HOME_DESKTOP,
        browse: &BROWSE_DESKTOP,
        focus: Some(&FOCUS_PLAN),
        smoke_needs: Some("a window session on the Mac"),
        remote: None,
    },
    Target {
        name: "appletv",
        golden: &GOLDEN_TV,
        home: &HOME_TV,
        browse: &BROWSE_TV,
        focus: Some(&FOCUS_PLAN),
        smoke_needs: Some("Apple TV via devicectl"),
        remote: None,
    },
    Target {
        name: "android-phone",
        golden: &GOLDEN_TOUCH,
        home: &HOME_TOUCH,
        browse: &BROWSE_TOUCH,
        focus: None,
        smoke_needs: Some("a phone via ADB"),
        remote: None,
    },
    Target {
        name: "android-tv",
        golden: &GOLDEN_TV,
        home: &HOME_TV,
        browse: &BROWSE_TV,
        focus: Some(&FOCUS_PLAN),
        smoke_needs: Some("emulator-5556"),
        remote: None,
    },
    Target {
        name: "windows",
        golden: &GOLDEN_DESKTOP,
        home: &HOME_DESKTOP,
        browse: &BROWSE_DESKTOP,
        focus: Some(&FOCUS_PLAN),
        smoke_needs: None,
        remote: Some("windows"),
    },
    Target {
        name: "linux",
        golden: &GOLDEN_DESKTOP,
        home: &HOME_DESKTOP,
        browse: &BROWSE_DESKTOP,
        focus: Some(&FOCUS_PLAN),
        smoke_needs: None,
        remote: Some("linux"),
    },
];

/// Result of one check run.
enum Outcome {
    Ok,
    Failed(String),
}

fn cargo(root: &Path, args: &[&str]) -> Result<Output, String> {
    Command::new("cargo")
        .args(args)
        .current_dir(root)
        .output()
        .map_err(|e| format!("cargo: {e}"))
}

fn run_check(root: &Path, check: &Check) -> Outcome {
    eprintln!("xtask: {} ...", check.name);
    match cargo(root, check.args) {
        Ok(o) if o.status.success() => Outcome::Ok,
        Ok(o) => {
            let text = format!(
                "{}{}",
                String::from_utf8_lossy(&o.stdout),
                String::from_utf8_lossy(&o.stderr)
            );
            let tail: Vec<&str> = text.lines().rev().take(25).collect();
            Outcome::Failed(tail.into_iter().rev().collect::<Vec<_>>().join("\n"))
        }
        Err(e) => Outcome::Failed(e),
    }
}

/// Smoke text for a remote target: `windows` or `linux`. With `--remote` and a machine that is on, the golden test
/// runs on it (so the frames are also proven byte-equal on another host).
fn remote_smoke(root: &Path, os: &str, allow_remote: bool, failed: &mut bool) -> String {
    // Windows is parked until the Windows VM exists; Linux runs natively on a Linux build host.
    if os == "windows" {
        return "smoke: parked (Windows runs wait for the Windows VM; cross-compile only)"
            .to_owned();
    }
    if !crate::desktop::linux_machine_ready() {
        return "smoke: not run (no Linux build host connected)".to_owned();
    }
    if !allow_remote {
        return "smoke: not run (a Linux build host is on; pass --remote)".to_owned();
    }
    let sm = crate::desktop::smoke_for_check(root, os);
    *failed |= sm.failed;
    sm.line
}

/// Runs everything and prints one line per target. `Err` when a check that ran failed.
pub fn check_all(root: &Path, args: &[String]) -> Result<(), String> {
    let allow_remote = args.iter().any(|a| a == "--remote");
    let start_emulator = args.iter().any(|a| a == "--start-emulator");
    if let Some(bad) = args
        .iter()
        .find(|a| *a != "--remote" && *a != "--start-emulator")
    {
        return Err(format!("unknown option {bad}"));
    }
    let mut results: Vec<(&'static str, Outcome)> = vec![];
    let mut run_once = |check: &'static Check| -> bool {
        if !results.iter().any(|(n, _)| *n == check.name) {
            results.push((check.name, run_check(root, check)));
        }
        matches!(
            results.iter().find(|(n, _)| *n == check.name),
            Some((_, Outcome::Ok))
        )
    };
    let mut any_failed = false;
    let mut lines = vec![];
    let mut android_build: Option<String> = None;
    let mut android_apk: Option<std::path::PathBuf> = None;
    for t in &TARGETS {
        let mut parts = vec![];
        let titles = if t.home.name.ends_with("(tv)") {
            &TITLE_TV
        } else if t.home.name.ends_with("(desktop)") {
            &TITLE_DESKTOP
        } else {
            &TITLE_TOUCH
        };
        let app = if t.home.name.ends_with("(tv)") {
            &APP_TV
        } else if t.home.name.ends_with("(desktop)") {
            &APP_DESKTOP
        } else {
            &APP_TOUCH
        };
        let player = if t.home.name.ends_with("(tv)") {
            &PLAYER_TV
        } else if t.home.name.ends_with("(desktop)") {
            &PLAYER_DESKTOP
        } else {
            &PLAYER_TOUCH
        };
        for check in [
            &MODEL_VM,
            t.golden,
            t.home,
            t.browse,
            forms_for(t.browse),
            titles,
            app,
            &GESTURES,
            player,
            &TEXT_INPUT,
        ] {
            let ok = run_once(check);
            any_failed |= !ok;
            parts.push(format!(
                "{} {}",
                check.name,
                if ok { "ok" } else { "FAILED" }
            ));
        }
        parts.push(match t.focus {
            Some(check) => {
                let ok = run_once(check);
                any_failed |= !ok;
                format!("{} {}", check.name, if ok { "ok" } else { "FAILED" })
            }
            None => "focus-plan: n/a (touch only)".to_owned(),
        });
        if t.name.starts_with("android") {
            let build =
                android_build.get_or_insert_with(|| match crate::android::build(root, false) {
                    Ok(crate::android::Built::Ok(apk)) => {
                        android_apk = Some(apk);
                        "build ok (arm64-v8a + x86_64 APK)".to_owned()
                    }
                    Ok(crate::android::Built::Missing(need)) => {
                        format!("build: not run (needs {need})")
                    }
                    Err(e) => {
                        eprintln!("--- android build failed ---\n{e}");
                        "build FAILED".to_owned()
                    }
                });
            any_failed |= build.ends_with("FAILED");
            parts.push(build.clone());
        }
        if let Some(which) = match t.name {
            "iphone" => Some("ios"),
            "appletv" => Some("tvos"),
            _ => None,
        } {
            parts.push(match crate::ios::build(root, which) {
                Ok(crate::ios::Built::Ok(_, size)) => format!("build ok (comparison app, {size})"),
                Ok(crate::ios::Built::Missing(need)) => format!("build: not run (needs {need})"),
                Err(e) => {
                    eprintln!("--- {which} build failed ---\n{e}");
                    any_failed = true;
                    "build FAILED".to_owned()
                }
            });
        }
        parts.push(match (t.smoke_needs, t.remote) {
            (Some(_), _) if t.name.starts_with("android") && android_apk.is_some() => {
                let form = if t.name == "android-tv" {
                    "tv"
                } else {
                    "phone"
                };
                let sm = crate::smoke::smoke(root, form, start_emulator, android_apk.clone());
                any_failed |= sm.failed;
                sm.line
            }
            (Some(needs), _) => format!("smoke: not run (needs {needs})"),
            (None, Some(os)) => remote_smoke(root, os, allow_remote, &mut any_failed),
            (None, None) => "smoke: not run".to_owned(),
        });
        lines.push(format!("{:<14} {}", t.name, parts.join(" | ")));
    }
    for (name, outcome) in &results {
        if let Outcome::Failed(tail) = outcome {
            eprintln!("--- {name} failed, last lines ---\n{tail}");
        }
    }
    // Extra column: the machine hardening pass (oracle, properties, fuzz in quick mode).
    let (hardening_ok, hardening_line) = crate::hardening::column(root);
    any_failed |= !hardening_ok;
    let (security_ok, security_line) = crate::security::column(root);
    any_failed |= !security_ok;
    for l in lines {
        println!("{l}");
    }
    println!("{hardening_line}");
    println!("{security_line}");
    println!("{}", crate::parity::summary(root));
    let (components_ok, components_line) = crate::components::summary(root);
    any_failed |= !components_ok;
    println!("{components_line}");
    if any_failed {
        Err("at least one check failed".to_owned())
    } else {
        Ok(())
    }
}
