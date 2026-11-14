//! Command line of `swiftly-desktop`.

use std::path::PathBuf;

/// The text printed by `--help`.
pub const USAGE: &str = "swiftly-desktop [--app] [--smoke ADDRESS USER PASSWORD] [--demo g1|home|app [--form touch|desktop|tv] [--state ready|loading|offline|empty]] [--stats] [--offscreen] [--autoplay] [--quit-after SECONDS]
                [--size WxH] [--scale S] [--frames N --png OUT.png [--open-detail]] [--gpu-bench] [--latency] [--single-instance]
                [swiftly://... | VIDEOFILE]...

  --script FILE       scripted pointer steps (move, click, wheel, fullscreen, resize WxH, shot, mark) for live checks in a nested compositor; SWIFTLY_TRACE=1 prints timestamped trace lines
  --touch-script S    scripted finger events F:P:X:Y;... (frame, d/m/u, physical px) through the window's touch path
  --latency           scripted wheel run through the event loop (use with --quit-after): prints input-to-present p50/p95/p99 and a histogram, and the frame statistics
  --single-instance   one running instance: a second launch hands its arguments (links, files) to the first and exits. On in the real app
  --app               the real app: stored account or sign-in, real network, libmpv (feature mpv). Default of release builds
  --smoke-play A U P  no window: sign in, play the first title with libmpv for --quit-after seconds (local fixture: checks progress reports; other servers: plan only, nothing is reported)
  --smoke A U P       no window: sign in at address A, load Home, open the first title, load a picture; prints one line per step
  --demo g1           the gate G1 demo (the default in debug builds)
  --demo app          the whole app: tabs, library, search, detail and series pages over the demo server
  --form F            with --demo app: touch, desktop (default) or tv layout
  --demo player       the player screen over a real video (build with --features mpv): --video FILE [--quit-after N] [--size WxH] [--scale S] [--software] [--video-px WxH]
  --demo home         the Home screen, driven by HomeVm over a scripted server (no network)
  --offscreen         open the real window at -12000,-12000 without taking focus (window checks without a user session)
  --state S           with --demo home or app: ready (default), loading, offline or empty
  --stats             print frame time p50/p99/max and dropped frames to stderr every 5 s
  --autoplay          scripted wheel flings, a tile click and back, without any OS input (for --stats runs)
  --quit-after N      close the window after N seconds
  --size WxH          window size in points (default 1440x900)
  --frames N          headless: render N frames at 60 Hz with the software renderer, no window
  --png OUT.png       headless: write the last frame
  --open-detail       headless: start with the first detail page pushed
  --gpu-bench         no window: the real GPU renderer into an offscreen texture at 120 Hz, with --autoplay and --quit-after
  --scale S           headless: pixels per point (default 1)
  --dump-frame P.png  window: write the frame the swapchain presents (GPU readback, not an OS screenshot) after --after-frames N (default 5)
  --exit-after-dump   window: close right after the dump (exit code 1 when the dump failed)";

/// Parsed options.
#[derive(Clone, Debug, PartialEq)]
pub struct Options {
    /// Print frame statistics.
    pub stats: bool,
    /// `--latency`: a scripted wheel run through the event loop; prints input-to-present percentiles and a histogram.
    pub latency: bool,
    /// One running instance: a second launch forwards its arguments to the first and exits (default for the real app).
    pub single_instance: bool,
    /// What the command line asks to open: `swiftly://` links and video files.
    pub launch: Vec<crate::deep_link::Launch>,
    /// Run the built-in script.
    pub autoplay: bool,
    /// Close after this many seconds.
    pub quit_after: Option<f64>,
    /// Window size in points.
    pub size: (u32, u32),
    /// Headless frame count (`Some` = headless run).
    pub frames: Option<u32>,
    /// Headless PNG path.
    pub png: Option<PathBuf>,
    /// Headless: open a detail page first.
    pub open_detail: bool,
    /// Offscreen GPU benchmark (no window).
    pub gpu_bench: bool,
    /// Headless scale.
    pub scale: f32,
    /// `--demo home`: the Home screen over a scripted server instead of the G1 demo.
    pub home: Option<crate::home_data::Scenario>,
    /// `--demo app`: the whole app, all tabs and title pages.
    pub app: bool,
    /// `--offscreen`: a real window far outside every monitor, shown without activation (checks without a session).
    pub offscreen: bool,
    /// `--demo app --state S`: the scripted server state every screen of the whole app starts in.
    pub app_state: Option<crate::home_data::Scenario>,
    /// `--demo player`: the player screen over a real video (needs the `mpv` feature and `--video`).
    pub player: bool,
    /// `--video FILE`: the file `--demo player` plays.
    pub video: Option<PathBuf>,
    /// `--software`: `--demo player` draws with the CPU renderer instead of wgpu.
    pub software: bool,
    /// `--video-px WxH`: the largest video frame libmpv renders (default: the window in pixels).
    pub video_px: Option<(u32, u32)>,
    /// `--dump-frame`: write the presented swapchain frame to this PNG.
    pub dump_frame: Option<PathBuf>,
    /// `--after-frames`: presented frames before the dump.
    pub after_frames: u32,
    /// `--touch-script F:P:X:Y;...`: scripted finger events through the window's touch path, fired once `F` frames
    /// are presented (`P` is d, m or u for down, move, up; `X`, `Y` physical pixels). For automated window checks.
    pub touch_script: Vec<(u32, u8, f64, f64)>,
    /// `--script FILE`: scripted pointer steps for live checks (see `script.rs`).
    pub script: Option<PathBuf>,
    /// `--exit-after-dump`: close the window once the dump is written.
    pub exit_after_dump: bool,
    /// `--form`: the layout (idiom) of `--demo app`.
    pub form: swiftly_ui::Idiom,
    /// `--app`: the real app (stored account or sign-in, real network). The default of release builds.
    pub live: bool,
    /// `--smoke ADDRESS USER PASSWORD`: no window; sign in, load Home, open a title, load a picture, print the result.
    pub smoke: Option<(String, String, String)>,
    /// `--smoke-play ADDRESS USER PASSWORD [--quit-after S]`: no window; sign in and play the first title for S seconds.
    pub smoke_play: Option<(String, String, String)>,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            stats: false,
            latency: false,
            single_instance: false,
            launch: Vec::new(),
            autoplay: false,
            quit_after: None,
            size: (1440, 900),
            frames: None,
            png: None,
            open_detail: false,
            gpu_bench: false,
            scale: 1.0,
            home: None,
            app: false,
            app_state: None,
            offscreen: false,
            player: false,
            video: None,
            software: false,
            video_px: None,
            dump_frame: None,
            touch_script: Vec::new(),
            script: None,
            after_frames: 5,
            exit_after_dump: false,
            form: swiftly_ui::Idiom::Desktop,
            live: false,
            smoke: None,
            smoke_play: None,
        }
    }
}

/// Parses the arguments after the program name. `Ok(None)` means `--help` was asked for.
pub fn parse<I: IntoIterator<Item = String>>(args: I) -> Result<Option<Options>, String> {
    let mut o = Options::default();
    let mut it = args.into_iter();
    let (mut home, mut state) = (None, None);
    let mut size_given = false;
    while let Some(a) = it.next() {
        let mut value = |name: &str| it.next().ok_or_else(|| format!("{name} needs a value"));
        match a.as_str() {
            "-h" | "--help" => return Ok(None),
            "--demo" => {
                let v = value("--demo")?;
                match v.as_str() {
                    "g1" => home = None,
                    "home" => home = Some(crate::home_data::Scenario::Ready),
                    "app" => o.app = true,
                    "player" => o.player = true,
                    _ => return Err(format!("unknown demo {v:?} (g1, home, app or player)")),
                }
            }
            "--state" => {
                use crate::home_data::Scenario;
                let v = value("--state")?;
                state = Some(match v.as_str() {
                    "ready" => Scenario::Ready,
                    "loading" => Scenario::Loading,
                    "offline" => Scenario::Offline,
                    "empty" => Scenario::Empty,
                    _ => {
                        return Err(format!(
                            "unknown state {v:?} (ready, loading, offline, empty)"
                        ));
                    }
                });
            }
            "--app" => o.live = true,
            "--smoke" => {
                let (a, u) = (value("--smoke")?, value("--smoke")?);
                o.smoke = Some((a, u, value("--smoke")?));
            }
            "--smoke-play" => {
                let (a, u) = (value("--smoke-play")?, value("--smoke-play")?);
                o.smoke_play = Some((a, u, value("--smoke-play")?));
            }
            "--form" => {
                let v = value("--form")?;
                o.form = match v.as_str() {
                    "touch" => swiftly_ui::Idiom::Phone,
                    "desktop" => swiftly_ui::Idiom::Desktop,
                    "tv" => swiftly_ui::Idiom::Tv,
                    _ => return Err(format!("unknown form {v:?} (touch, desktop or tv)")),
                };
            }
            "--stats" => o.stats = true,
            "--offscreen" => o.offscreen = true,
            "--latency" => {
                o.latency = true;
                o.stats = true;
            }
            "--single-instance" => o.single_instance = true,
            // `swiftly://` links and video files (protocol handler, "Open with", drag onto the exe).
            other
                if !other.starts_with('-')
                    && !crate::deep_link::parse_args([other.to_owned()]).is_empty() =>
            {
                o.launch
                    .extend(crate::deep_link::parse_args([other.to_owned()]));
            }
            "--autoplay" => o.autoplay = true,
            "--open-detail" => o.open_detail = true,
            "--gpu-bench" => o.gpu_bench = true,
            "--quit-after" => {
                let v = value("--quit-after")?;
                o.quit_after = Some(v.parse().map_err(|_| format!("bad seconds {v:?}"))?);
            }
            "--frames" => {
                let v = value("--frames")?;
                o.frames = Some(v.parse().map_err(|_| format!("bad frame count {v:?}"))?);
            }
            "--software" => o.software = true,
            "--video-px" => {
                let v = value("--video-px")?;
                let (w, h) = v
                    .split_once('x')
                    .ok_or_else(|| format!("video-px must look like 3840x2160, got {v:?}"))?;
                o.video_px = Some((
                    w.parse().map_err(|_| format!("bad width {w:?}"))?,
                    h.parse().map_err(|_| format!("bad height {h:?}"))?,
                ));
            }
            "--dump-frame" => o.dump_frame = Some(PathBuf::from(value("--dump-frame")?)),
            "--touch-script" => {
                for step in value("--touch-script")?
                    .split(';')
                    .filter(|p| !p.is_empty())
                {
                    let f: Vec<&str> = step.split(':').collect();
                    let bad = || format!("bad touch step {step:?}");
                    let [frame, phase, x, y] = f[..] else {
                        return Err(bad());
                    };
                    let code = match phase {
                        "d" => 0,
                        "m" => 1,
                        "u" => 2,
                        _ => return Err(bad()),
                    };
                    o.touch_script.push((
                        frame.parse().map_err(|_| bad())?,
                        code,
                        x.parse().map_err(|_| bad())?,
                        y.parse().map_err(|_| bad())?,
                    ));
                }
            }
            "--script" => o.script = Some(PathBuf::from(value("--script")?)),
            "--exit-after-dump" => o.exit_after_dump = true,
            "--after-frames" => {
                let v = value("--after-frames")?;
                o.after_frames = v.parse().map_err(|_| format!("bad frame count {v:?}"))?;
            }
            "--video" => o.video = Some(PathBuf::from(value("--video")?)),
            "--png" => o.png = Some(PathBuf::from(value("--png")?)),
            "--scale" => {
                let v = value("--scale")?;
                o.scale = v.parse().map_err(|_| format!("bad scale {v:?}"))?;
            }
            "--size" => {
                size_given = true;
                let v = value("--size")?;
                let (w, h) = v
                    .split_once('x')
                    .ok_or_else(|| format!("size must look like 1280x800, got {v:?}"))?;
                o.size = (
                    w.parse().map_err(|_| format!("bad width {w:?}"))?,
                    h.parse().map_err(|_| format!("bad height {h:?}"))?,
                );
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    if o.app && !size_given {
        o.size = match o.form {
            swiftly_ui::Idiom::Phone | swiftly_ui::Idiom::Pad => (430, 900),
            swiftly_ui::Idiom::Desktop => (1440, 900),
            swiftly_ui::Idiom::Tv => (1280, 720),
        };
    }
    o.home = home.map(|h| state.unwrap_or(h));
    if o.app {
        o.app_state = state;
    }
    if o.png.is_some() && o.frames.is_none() {
        return Err("--png needs --frames N".to_owned());
    }
    Ok(Some(o))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Result<Option<Options>, String> {
        parse(s.split_whitespace().map(str::to_owned))
    }

    #[test]
    fn parses_the_documented_flags() {
        let o = p("--demo g1 --stats --autoplay --quit-after 10 --size 900x600")
            .ok()
            .flatten()
            .unwrap_or_default();
        assert!(o.stats && o.autoplay);
        assert!(
            p("--offscreen")
                .ok()
                .flatten()
                .unwrap_or_default()
                .offscreen
        );
        assert_eq!(o.quit_after, Some(10.0));
        assert_eq!(o.size, (900, 600));
        let o = p("--frames 30 --png out.png")
            .ok()
            .flatten()
            .unwrap_or_default();
        assert_eq!(o.frames, Some(30));
        assert_eq!(o.png, Some(PathBuf::from("out.png")));
        assert!(p("--png out.png").is_err());
        let o = p("--dump-frame w.png --after-frames 9 --exit-after-dump")
            .ok()
            .flatten()
            .unwrap_or_default();
        assert_eq!(o.dump_frame, Some(PathBuf::from("w.png")));
        assert_eq!((o.after_frames, o.exit_after_dump), (9, true));
        assert!(p("--demo x").is_err());
        use crate::home_data::Scenario;
        for (word, want) in [
            ("empty", Scenario::Empty),
            ("offline", Scenario::Offline),
            ("loading", Scenario::Loading),
        ] {
            let o = p(&format!("--demo app --state {word}"))
                .ok()
                .flatten()
                .unwrap_or_default();
            assert!(o.app);
            assert_eq!(o.app_state, Some(want));
            let o = p(&format!("--state {word} --demo app"))
                .ok()
                .flatten()
                .unwrap_or_default();
            assert_eq!(o.app_state, Some(want));
        }
        assert_eq!(
            p("--demo app").ok().flatten().unwrap_or_default().app_state,
            None
        );
        let o = p("--latency --single-instance swiftly://titel/7 /tmp/a.mkv")
            .ok()
            .flatten()
            .unwrap_or_default();
        assert!(o.latency && o.stats && o.single_instance);
        assert_eq!(o.launch.len(), 2);
        assert!(p("notes.txt").is_err());
        assert!(p("--bogus").is_err());
        assert_eq!(p("--help"), Ok(None));
    }
}
