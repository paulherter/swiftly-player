//! The film's detail page starts a download in the live desktop app (Linux + Windows): the More list's "Laden" opens the
//! add sheet on the Downloads page from the live title, "Laden" in the sheet downloads the file and its subtitles, the
//! finished row opens the player offline (the fixture server is killed first), the subtitle rows are labelled
//! "Englisch · SRT · Datei" and the cue is measured on the frames. Needs `target/debug/xtask` (`cargo build -p xtask`);
//! without it the test says so and passes. Runs in a child process with a temporary `SWIFTLY_CONFIG_DIR`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};
use swiftly_desktop::deep_link::DeepLink;
use swiftly_desktop::live::Core;
use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const TEST: &str = "the_film_page_downloads_the_title_and_it_plays_offline_with_its_subtitle";

struct Fixture(Child);
impl Fixture {
    fn start(xtask: &std::path::Path, id: &str) -> (Fixture, String) {
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .expect("port")
            .local_addr()
            .expect("addr")
            .port();
        let child = Command::new(xtask)
            .args(["fixture-server", "--port", &port.to_string()])
            .env("SWIFTLY_FIXTURE_ID", id)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("fixture");
        std::thread::sleep(Duration::from_millis(800));
        (Fixture(child), format!("http://127.0.0.1:{port}"))
    }
    /// Kills the fixture by its PID and waits for it.
    fn stop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop();
    }
}

fn run_until(
    suite: &mut Suite,
    clock: &Instant,
    secs: f64,
    mut done: impl FnMut(&mut Suite) -> bool,
) -> bool {
    let until = clock.elapsed().as_secs_f64() + secs;
    while clock.elapsed().as_secs_f64() < until {
        let _ = suite.frame(clock.elapsed().as_secs_f64() * 1000.0);
        if done(suite) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(16));
    }
    false
}

fn tap(suite: &mut Suite, clock: &Instant, f: [f32; 4]) {
    let (x, y) = (f[0] + f[2] / 2.0, f[1] + f[3] / 2.0);
    let t = clock.elapsed().as_secs_f64() * 1000.0;
    suite.touch_down(x, y, t);
    suite.touch_up(x, y, t + 40.0);
}

#[test]
fn the_film_page_downloads_the_title_and_it_plays_offline_with_its_subtitle() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir =
            std::env::temp_dir().join(format!("swiftly-film-download-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let out = Command::new(std::env::current_exe().expect("exe"))
            .args(["--exact", TEST, "--nocapture", "--test-threads=1"])
            .env("SWIFTLY_CONFIG_DIR", &dir)
            .output()
            .expect("child");
        let _ = std::fs::remove_dir_all(&dir);
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        println!("{text}");
        assert!(out.status.success(), "{text}");
        return;
    }
    // `SWIFTLY_XTASK` points at the fixture server's binary when the test exe runs on another machine (the Windows VM).
    let xtask = std::env::var_os("SWIFTLY_XTASK").map_or_else(
        || {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../target/debug")
                .join(format!("xtask{}", std::env::consts::EXE_SUFFIX))
        },
        PathBuf::from,
    );
    if !xtask.exists() {
        println!("skipped: build xtask first (cargo build -p xtask)");
        return;
    }
    let (mut fx, addr) = Fixture::start(&xtask, "fx-film-dl");
    let core = Arc::new(Core::open().expect("core"));
    // Downloads are off until the user enables them (like the Mac): this test is that user.
    swiftly_settings::KeyValueStore::set(
        &*core.settings,
        "downloadsAn",
        swiftly_settings::Value::Bool(true),
    )
    .expect("settings");
    let backend = core.sign_in_backend();
    let wait = Duration::from_secs(30);
    backend
        .connect(&addr)
        .0
        .recv_timeout(wait)
        .expect("connect")
        .expect("address");
    backend
        .password("demo", "demo")
        .0
        .recv_timeout(wait)
        .expect("password")
        .expect("sign-in");
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut suite = Suite::new_live(env, Cx::new(), Arc::clone(&core));
    let clock = Instant::now();
    let now = |c: &Instant| c.elapsed().as_secs_f64() * 1000.0;
    run_until(&mut suite, &clock, 3.0, |_| false);

    // Detail page of the film "g1" (two audio tracks, an external SRT and VTT); More -> "Laden".
    suite.open_link(DeepLink::Title("g1".into()), now(&clock));
    assert!(
        run_until(&mut suite, &clock, 15.0, |s| s.title_open()
            && s.detail_frame_of("more").is_some()),
        "the film page did not open"
    );
    run_until(&mut suite, &clock, 1.0, |_| false);
    let more = suite.detail_frame_of("more").expect("More button");
    tap(&mut suite, &clock, more);
    run_until(&mut suite, &clock, 1.0, |_| false);
    // "Laden" is the last row of the list: Up from nothing wraps to it.
    suite.nav_key(
        swiftly_ui::NavKey::Arrow(swiftly_ui::Dir::Up),
        true,
        now(&clock),
    );
    suite.nav_key(swiftly_ui::NavKey::Enter, true, now(&clock) + 40.0);

    // The add sheet opens on the Downloads page from the live title.
    assert!(
        run_until(&mut suite, &clock, 15.0, |s| s.load_open()),
        "Laden on the film page did not open the add sheet"
    );
    suite
        .downloads()
        .expect("the sheet's screen")
        .press("load.go");
    // The sheet floated over the film page: it is still the page in front, and Downloads was never shown. Open the
    // Downloads page by the sidebar row to read the finished row.
    run_until(&mut suite, &clock, 1.0, |_| false);
    assert!(
        suite.title_open(),
        "the film page stays in front of the sheet"
    );
    suite.back(now(&clock));
    run_until(&mut suite, &clock, 1.0, |_| false);
    swiftly_desktop::desk::note_tap(&swiftly_ui::Action::from("go:downloads"));
    assert!(
        run_until(&mut suite, &clock, 5.0, |s| s.downloads().is_some()),
        "the Downloads page did not open"
    );

    // The file arrives.
    let done = run_until(&mut suite, &clock, 90.0, |s| {
        s.downloads().is_some_and(|d| {
            d.vm()
                .entries()
                .iter()
                .any(|e| e.id == "g1" && e.state == swiftly_downloads::DownloadState::Done)
        })
    });
    assert!(
        done,
        "the download did not finish: {:?}",
        suite.downloads().map(|d| d
            .vm()
            .entries()
            .iter()
            .map(|e| (e.id.clone(), e.state))
            .collect::<Vec<_>>())
    );

    // The subtitle files follow the file (their own requests): wait for the sidecar that is written after the last one.
    let item = suite
        .downloads()
        .and_then(|d| d.vm().entries().into_iter().find(|e| e.id == "g1"))
        .expect("the finished title");
    let sidecar = swiftly_desktop::live_downloads::downloads_dir()
        .join(item.subtitle_folder_name())
        .join("info.json");
    assert!(
        run_until(&mut suite, &clock, 30.0, |_| sidecar.is_file()),
        "the subtitle files were not stored: {}",
        sidecar.display()
    );

    // The sidecar keeps the language and format of each file (what the offline rows are labelled from).
    let facts: Vec<swiftly_vm::subtitle_sidecar::SubtitleMeta> =
        serde_json::from_str(&std::fs::read_to_string(&sidecar).expect("sidecar"))
            .expect("sidecar json");
    let stored: Vec<(i64, Option<&str>, Option<&str>)> = facts
        .iter()
        .map(|m| (m.index, m.language.as_deref(), m.codec.as_deref()))
        .collect();
    assert_eq!(
        stored,
        vec![
            (3, Some("eng"), Some("srt")),
            (4, Some("deu"), Some("webvtt"))
        ],
        "the stored subtitle facts"
    );

    // Offline: the server is gone before the downloaded copy plays.
    fx.stop();
    if !cfg!(feature = "mpv") {
        // Without the video engine the player only shows placeholder tracks, so the rows and the cue are not measurable.
        println!("skipped offline playback: this build has no video engine (feature mpv)");
        return;
    }
    suite.downloads().expect("Downloads page").press("row:g1");
    assert!(
        run_until(&mut suite, &clock, 30.0, |s| s.player_open()),
        "the player did not open from the Downloads row"
    );
    swiftly_desktop::live_play::probe_arm(true);
    let mut labels = Vec::new();
    run_until(&mut suite, &clock, 20.0, |s| {
        labels = s
            .player()
            .map(|p| p.vm().tracks().subtitles)
            .unwrap_or_default();
        !labels.is_empty()
    });
    let names: Vec<String> = labels.iter().map(|r| r.label.clone()).collect();
    let row = labels
        .iter()
        .find(|r| r.label == "Englisch · SRT · Datei")
        .unwrap_or_else(|| panic!("no 'Englisch · SRT · Datei' row in {names:?}"));
    let index = row.index;
    suite.player_intent(swiftly_vm::PlayerIntent::SelectSubtitle(index), now(&clock));

    // The cue (1-3 s): the band's white/ink share inside it differs from the same positions with the subtitle off.
    let window = |suite: &mut Suite, clock: &Instant| {
        let mut got: Vec<(f32, f32)> = Vec::new();
        run_until(suite, clock, 25.0, |s| {
            let pos = s.player().map_or(0.0, |p| p.vm().transport().position);
            if let Some(v) = swiftly_desktop::live_play::probe_take()
                && (1.4..2.6).contains(&pos)
            {
                got.push(v);
            }
            pos > 2.7
        });
        let n = got.len().max(1) as f32;
        (
            got.iter().map(|v| v.0).sum::<f32>() / n,
            got.iter().map(|v| v.1).sum::<f32>() / n,
            got.len(),
        )
    };
    let on = window(&mut suite, &clock);
    let t = now(&clock);
    suite.player_intent(swiftly_vm::PlayerIntent::SelectSubtitle(-1), t);
    suite.player_intent(swiftly_vm::PlayerIntent::SeekTo(1.0), t + 50.0);
    run_until(&mut suite, &clock, 1.0, |_| false);
    let off = window(&mut suite, &clock);
    println!(
        "labels {names:?}; cue window on (white {:.5}, ink {:.5}, {} frames), off (white {:.5}, ink {:.5}, {} frames)",
        on.0, on.1, on.2, off.0, off.1, off.2
    );
    assert!(on.2 > 3 && off.2 > 3, "too few frames measured");
    #[cfg(feature = "mpv")]
    assert!(
        (on.0 - off.0).abs().max((on.1 - off.1).abs()) > 0.0003,
        "no cue drawn offline"
    );
}
