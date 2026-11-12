//! Watchdog: a core lock must never be held across a foreign (host) callback.
//!
//! The iPhone once froze because a lock was held while a Swift callback ran (and that callback
//! waited for the main thread, which was waiting for the lock). Here every foreign trait of the
//! core (HTTP, key-value store, secret store, platform, player engine) is a probe: one named
//! callback blocks for 300 ms while a "main thread" keeps calling the view model's read and send
//! functions. A call that does not come back within the budget while the callback still blocks
//! means a lock is held across it; the failure names the callback and the call that stalled.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Arc;
use std::time::{Duration, Instant};

use swiftly_hardening::soak::host::Control;
use swiftly_hardening::soak::workload::{library_spec, rig, wait_until};
use swiftly_uniffi::*;
use swiftly_vm::{HomeIntent, LibraryIntent, LibraryStatus, Status};

const BUDGET: Duration = Duration::from_millis(60);

struct Engine(Arc<Control>);

impl PlayerEngine for Engine {
    fn load(&self, _: PlayerLoad) {
        self.0.hit("engine.load")
    }
    fn play(&self) {
        self.0.hit("engine.play")
    }
    fn pause(&self) {
        self.0.hit("engine.pause")
    }
    fn seek(&self, _: f64) {
        self.0.hit("engine.seek")
    }
    fn set_rate(&self, _: f32) {
        self.0.hit("engine.set_rate")
    }
    fn set_volume(&self, _: u8) {
        self.0.hit("engine.set_volume")
    }
    fn set_audio_delay(&self, _: i32) {
        self.0.hit("engine.set_audio_delay")
    }
    fn set_subtitle_delay(&self, _: i32) {
        self.0.hit("engine.set_subtitle_delay")
    }
    fn select_audio(&self, _: i32) -> bool {
        self.0.hit("engine.select_audio");
        true
    }
    fn select_subtitle(&self, _: i32) -> PlayerSubtitleRoute {
        self.0.hit("engine.select_subtitle");
        PlayerSubtitleRoute::Cues
    }
    fn set_fill(&self, _: bool) {
        self.0.hit("engine.set_fill")
    }
    fn place(&self, _: PlayerRect) {
        self.0.hit("engine.place")
    }
    fn stop(&self, _: bool) {
        self.0.hit("engine.stop")
    }
    fn pip(&self, _: PlayerPip) {
        self.0.hit("engine.pip")
    }
}

type Probe = Box<dyn Fn() + Send + Sync>;

struct Outcome {
    scenario: &'static str,
    hook: String,
    fired: bool,
    stalls: Vec<String>,
}

/// Arms `hook`, runs `driver` on its own thread and probes from this one until the driver ends.
fn watch(
    scenario: &'static str,
    hook: &str,
    ctl: &Control,
    driver: impl FnOnce() + Send + 'static,
    probes: &[(&'static str, Probe)],
) -> Outcome {
    ctl.arm(hook);
    let handle = std::thread::spawn(driver);
    let end = Instant::now() + Duration::from_secs(8);
    let mut stalls = Vec::new();
    while !handle.is_finished() && Instant::now() < end {
        for (name, probe) in probes {
            // Take the time first: a callback that begins between the two reads is then seen by one of them
            // (blocking now, or fired after t0); the other order left a gap that missed a stall under load.
            let t0 = Instant::now();
            let was_blocking = ctl.blocking().is_some();
            probe();
            let end = Instant::now();
            // A call that was inside while the callback blocked (it started during the block, or the callback began
            // under it) and still needed more than the budget after the block began waited for the callback.
            if let Some(fired) = ctl.last_fire()
                && fired <= end
                && (was_blocking || fired >= t0)
            {
                let waited = end.duration_since(fired.max(t0));
                if waited > BUDGET {
                    stalls.push(format!("{name} stalled {} ms", waited.as_millis()));
                }
            }
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    let fired = ctl.fired();
    ctl.disarm();
    let _ = handle.join();
    Outcome {
        scenario,
        hook: hook.to_owned(),
        fired,
        stalls,
    }
}

fn start() -> PlayerStart {
    PlayerStart {
        item_id: "m1".into(),
        title: "Nordlicht".into(),
        play_session_id: Some("ps".into()),
        media_source_id: Some("src".into()),
        method: PlayerMethod::DirectPlay,
        url: "http://127.0.0.1:1/stream".into(),
        headers: Vec::new(),
        streams: vec![
            PlayerStream {
                index: 0,
                kind: "Video".into(),
                language: None,
                codec: Some("h264".into()),
                channels: None,
                title: None,
                is_default: true,
                is_forced: false,
                is_external: false,
                is_hearing_impaired: false,
            },
            PlayerStream {
                index: 1,
                kind: "Audio".into(),
                language: Some("deu".into()),
                codec: Some("aac".into()),
                channels: Some(2),
                title: None,
                is_default: true,
                is_forced: false,
                is_external: false,
                is_hearing_impaired: false,
            },
            PlayerStream {
                index: 2,
                kind: "Audio".into(),
                language: Some("eng".into()),
                codec: Some("aac".into()),
                channels: Some(2),
                title: None,
                is_default: false,
                is_forced: false,
                is_external: false,
                is_hearing_impaired: false,
            },
        ],
        runtime: 7200.0,
        start_at: 0.0,
        audio_index: Some(1),
        subtitle_index: -1,
        next: None,
        series_id: None,
        track_title: Some("Nordlicht".into()),
        downloaded: false,
        software_decode: false,
        frame_rate_match: false,
        buffer_level: PlayerBuffer::Normal,
        subtitle_files: Vec::new(),
        external_track_id_base: 100,
        source_json: None,
    }
}

fn home_scenario(hook: &str) -> Outcome {
    let r = rig(100);
    let vm = r.core.home_vm(r.acct.clone(), "de".into()).unwrap();
    let (v1, v2, v3) = (Arc::clone(&vm), Arc::clone(&vm), Arc::clone(&vm));
    let driver = {
        let vm = Arc::clone(&vm);
        move || {
            vm.send(HomeIntent::Load);
            wait_until(4000, || !matches!(vm.status().status, Status::Loading));
            vm.send(HomeIntent::Refresh);
            std::thread::sleep(Duration::from_millis(600));
        }
    };
    let probes: Vec<(&'static str, Probe)> = vec![
        (
            "HomeVm.status",
            Box::new(move || {
                let _ = v1.status();
            }),
        ),
        (
            "HomeVm.rails",
            Box::new(move || {
                let _ = v2.rails();
            }),
        ),
        (
            "HomeVm.send(Visible)",
            Box::new(move || v3.send(HomeIntent::Visible { rail: "x".into() })),
        ),
    ];
    watch("home", hook, &r.ctl, driver, &probes)
}

fn library_scenario(hook: &str) -> Outcome {
    let r = rig(500);
    let vm = r
        .core
        .library_vm(r.acct.clone(), "de".into(), library_spec())
        .unwrap();
    vm.send(LibraryIntent::Load);
    assert!(wait_until(5000, || matches!(
        vm.status().status,
        LibraryStatus::Ready
    )));
    let (v1, v2, v3) = (Arc::clone(&vm), Arc::clone(&vm), Arc::clone(&vm));
    let acct2 = r.acct2.clone();
    let driver = {
        let vm = Arc::clone(&vm);
        move || {
            vm.send(LibraryIntent::SetSorting {
                sorting: swiftly_library::library_filter::Sorting::Latest,
            });
            wait_until(3000, || matches!(vm.status().status, LibraryStatus::Ready));
            vm.send(LibraryIntent::SetFilter {
                filter: swiftly_library::LibraryFilter::Unwatched,
            });
            wait_until(3000, || matches!(vm.status().status, LibraryStatus::Ready));
            vm.send(LibraryIntent::AccountSwitched {
                account: Some(acct2),
            });
            std::thread::sleep(Duration::from_millis(700));
        }
    };
    let probes: Vec<(&'static str, Probe)> = vec![
        (
            "LibraryVm.status",
            Box::new(move || {
                let _ = v1.status();
            }),
        ),
        (
            "LibraryVm.grid",
            Box::new(move || {
                let _ = v2.grid();
            }),
        ),
        (
            "LibraryVm.send(Visible)",
            Box::new(move || {
                v3.send(LibraryIntent::Visible {
                    id: "m1".into(),
                    columns: 3,
                })
            }),
        ),
    ];
    watch("library", hook, &r.ctl, driver, &probes)
}

fn settings_scenario(hook: &str) -> Outcome {
    let r = rig(10);
    let facts = SettingsFacts {
        platform: SettingsPlatform::Phone,
        seerr: false,
        settings_sync: false,
        downloads: false,
        server: String::new(),
        can_convert: false,
        watchers_plugin: false,
        landscape_lock_possible: false,
        seerr_connected: false,
        own_headers: 0,
        subtitle_look_summary: String::new(),
        stored_downloads: 0,
        stored_bytes: 0,
        account_next_auto: None,
    };
    let vm = r.core.settings_vm("de".into(), facts);
    let (v1, v2) = (Arc::clone(&vm), Arc::clone(&vm));
    let driver = {
        let vm = Arc::clone(&vm);
        move || {
            let _ = vm.send(SettingsIntent::SetSwitch {
                key: "naechsteAuto".into(),
                on: true,
            });
            let _ = vm.send(SettingsIntent::SetSwitch {
                key: "naechsteAuto".into(),
                on: false,
            });
        }
    };
    let probes: Vec<(&'static str, Probe)> = vec![
        (
            "SettingsVm.status",
            Box::new(move || {
                let _ = v1.status();
            }),
        ),
        (
            "SettingsVm.sections",
            Box::new(move || {
                let _ = v2.sections();
            }),
        ),
    ];
    watch("settings", hook, &r.ctl, driver, &probes)
}

fn player_scenario(hook: &str) -> Outcome {
    let r = rig(10);
    let engine = Arc::new(Engine(Arc::clone(&r.ctl)));
    let vm = r
        .core
        .player_vm(
            r.acct.clone(),
            "de".into(),
            start(),
            swiftly_vm::PlayerPrefs::default(),
            engine,
        )
        .unwrap();
    vm.start();
    vm.engine_event(PlayerEngineEvent::State {
        state: PlayerEngineState::Playing,
    });
    let (v1, v2, v3, v4) = (
        Arc::clone(&vm),
        Arc::clone(&vm),
        Arc::clone(&vm),
        Arc::clone(&vm),
    );
    let driver = {
        let vm = Arc::clone(&vm);
        move || {
            vm.send(PlayerIntent::TogglePlay);
            vm.send(PlayerIntent::SeekTo { seconds: 120.0 });
            vm.send(PlayerIntent::SelectAudio { index: 2 });
            vm.send(PlayerIntent::Tempo { tempo: 1.5 });
            vm.send(PlayerIntent::Volume { percent: 50 });
            vm.send(PlayerIntent::TogglePlay);
            vm.send(PlayerIntent::Close);
            std::thread::sleep(Duration::from_millis(700));
        }
    };
    let probes: Vec<(&'static str, Probe)> = vec![
        (
            "PlayerVm.transport",
            Box::new(move || {
                let _ = v1.transport();
            }),
        ),
        (
            "PlayerVm.controls",
            Box::new(move || {
                let _ = v2.controls();
            }),
        ),
        (
            "PlayerVm.version",
            Box::new(move || {
                let _ = v3.version();
            }),
        ),
        (
            "PlayerVm.engine_event(Clock)",
            Box::new(move || {
                v4.engine_event(PlayerEngineEvent::Clock {
                    position: 3.0,
                    source_time: 3.0,
                })
            }),
        ),
    ];
    watch("player", hook, &r.ctl, driver, &probes)
}

#[test]
fn no_core_lock_is_held_across_a_foreign_callback() {
    let mut all: Vec<Outcome> = Vec::new();
    for h in [
        "kv.get",
        "kv.set",
        "http.send",
        "platform.log",
        "platform.device_name",
    ] {
        all.push(home_scenario(h));
    }
    for h in ["kv.get", "kv.set", "http.send"] {
        all.push(library_scenario(h));
    }
    for h in ["kv.get", "kv.set"] {
        all.push(settings_scenario(h));
    }
    for h in [
        "engine.load",
        "engine.play",
        "engine.pause",
        "engine.seek",
        "engine.set_rate",
        "engine.set_volume",
        "engine.select_audio",
        "engine.stop",
        "kv.get",
        "kv.set",
        "http.send",
        "platform.log",
    ] {
        all.push(player_scenario(h));
    }
    let mut failures = Vec::new();
    for o in &all {
        println!(
            "watchdog: {:<9} {:<22} {} {}",
            o.scenario,
            o.hook,
            if o.fired { "reached" } else { "not reached" },
            if o.stalls.is_empty() {
                "ok".to_owned()
            } else {
                format!("STALL {}", o.stalls[0])
            }
        );
        if !o.stalls.is_empty() {
            failures.push(format!(
                "lock held across foreign callback `{}` in the {} view model: {}",
                o.hook, o.scenario, o.stalls[0]
            ));
        }
    }
    assert!(
        all.iter().filter(|o| o.fired).count() >= 12,
        "too few callbacks were reached; the scenarios no longer exercise the core"
    );
    assert!(failures.is_empty(), "{failures:#?}");
}

/// The detector itself: a fake view model that holds its lock across a callback must be caught.
#[test]
fn detector_catches_a_lock_held_across_a_callback() {
    let ctl = Control::new();
    // A long block: on a loaded machine the probing thread may be scheduled late and must still see it.
    ctl.block_ms
        .store(1500, std::sync::atomic::Ordering::SeqCst);
    let lock = Arc::new(std::sync::Mutex::new(0_u32));
    let (l1, c1) = (Arc::clone(&lock), Arc::clone(&ctl));
    let driver = move || {
        let _guard = l1.lock().unwrap();
        c1.hit("fake.callback"); // the bug: a foreign call under a lock
    };
    let l2 = Arc::clone(&lock);
    let probes: Vec<(&'static str, Probe)> =
        vec![("FakeVm.status", Box::new(move || drop(l2.lock().unwrap())))];
    let o = watch("fake", "fake.callback", &ctl, driver, &probes);
    assert!(
        o.fired && !o.stalls.is_empty(),
        "the held lock was not detected"
    );
}
