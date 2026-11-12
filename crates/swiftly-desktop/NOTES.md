# swiftly-desktop notes

## What runs

- `swiftly-desktop --demo g1`: winit 0.30.13 window, wgpu 30.0.1 surface (FIFO, non-sRGB format, 2 frames of latency),
  `WgpuRenderer` from `swiftly-render`, `Shell` (input and frame core, no window types) over `Demo` (G1 screens) over
  `swiftly-ui` (`Ui`, `Nav`). Text only through `swiftly-text` (Cx). Inter is bundled; system fonts are scanned at start.
- Headless: `--frames N --png out.png` (software renderer, deterministic bundled font), `--gpu-bench` (real GPU, offscreen).
- Tests (`cargo test -p swiftly-desktop`, 16 tests, no window or GPU): wheel state machine, stats, CLI, art, and smoke
  tests through `Shell`: idle page asks for no frame, click opens detail (0.45 s of frames), back pops, wheel scrolls rail
  and page, only the items near the viewport are built, the autoplay round runs. `cargo test -p swiftly-ui --lib nav`: 12
  tests of the navigation (below).

## Navigation (`swiftly-ui/src/nav.rs`)

- One continuous position `pos` over the page stack; `Layers::at(pos)` names the two visible pages, `stack_view` places
  them. All pages stay in the tree (waiting pages sit just right of the window), so scroll offsets of the page below
  survive a push and a pop. Verified by the smoke tests (`rails` keep their offset) and `pages_stay_alive_off_screen`.
- `desktop`: tween easeInOut(0.42, 0, 0.58, 1) over 0.45 s; page below -30 % of the width, dim 28 %. Known (AS section 2).
  Interrupting a push by a pop restarts the ease from rest over the remaining share of the distance: the velocity is not
  carried (the Mac app's behaviour under interruption is not known).
- `touch`: spring `Spring::critical_settling_in(0.35)` (estimated from the 0.35 s of RF 3), page below -25 % and dim 10 %
  (RF 3, community code), 6 pt-ish edge shadow (estimated). Edge swipe: the top page follows the finger 1:1 (the 10 pt
  hysteresis of the pan is subtracted at the grab, so there is no jump); release: complete when
  `pos - project(v, 0.998) / width < top - 0.5` (RF 3 estimated rule), then the spring starts from the current position and the
  release velocity. Tests: complete, cancel, reverse mid-swipe (no jump in position per sample), release keeps position and
  velocity, catching a moving page, geometry by pixels.
- Cost: the nav animates by re-running `view` every frame (`Ui::set_parts`). The demo's view builds both pages; measured
  below as part of the frame cost. A per-node offset in `swiftly-ui` would avoid that rebuild (open).

## Estimated (no source)

- Wheel: 48 pt per mouse-wheel notch, 70 ms smoothing, session ends after 90 ms of silence, OS momentum recognised as a
  `Started` within 60 ms after an `Ended` and swallowed until the next `Ended` or 250 ms of silence.
- Hit area and tile positions of `--autoplay` (rail row at 30 % of the window height, first poster at x = 76).
- Frame statistics: a frame is "dropped" when it starts more than 1.5 refresh periods after the previous continuous frame.
- Touch nav numbers (above). Desktop nav numbers are from the Mac app (known).

## What winit 0.30.13 does not give

- No event timestamps: every event is stamped with `Instant::now()` at delivery, so a finger velocity has the jitter of
  the event loop (about a frame). The touch screen path on Windows has the same limit.
- Wheel phases: macOS has them for a touchpad but folds finger and OS momentum into one `TouchPhase` (momentum begin =
  `Started`, momentum end = `Ended`); we tell them apart by timing (above), this is a heuristic. Windows: `LineDelta`
  only, always `Moved`, no phases and no way to tell a touchpad from a wheel. X11/Wayland: no phases. The OS momentum is not
  used: the scroll bodies glide by their own physics (so a flick feels the same as on a touch screen).
- The shell has no `Ui::wheel`: a session is emulated as a finger (down after the movement passes the 10 pt hysteresis, so a
  nudge never taps), which reuses the touch scroll physics. A native wheel API in `Ui` is open.
- Presentation feedback: no vsync timestamp, no "frame was shown at" time. The refresh period comes from
  `MonitorHandle::refresh_rate_millihertz()` (may be `None`; then 60 Hz is assumed). Dropped frames are inferred from
  the interval between frames, measured after the vsync-blocking acquire.
- No native back swipe (macOS two-finger swipe, Windows 11 touch back gesture) and no system "reduce motion" query.
- IME: `WindowEvent::Ime` is received and forwarded to `Shell::ime` (stub, returns false); `set_ime_allowed(false)` until a
  text field exists (gate G2). Cursor area (`set_ime_cursor_area`) is not set.
- Hover: `CursorMoved` exists, `swiftly-ui` has no hover state yet, so a moving pointer redraws nothing.

## Surface path of swiftly-render

`render_to_surface` was not used: it maps every non-success `CurrentSurfaceTexture` (Timeout, Occluded, Outdated, Lost)
to one `RenderError::Surface(String)`, which a shell cannot answer. The shell calls `get_current_texture` itself and uses the
public `WgpuRenderer::draw` + `Queue::present`: Outdated reconfigures, Lost recreates the surface, Occluded skips the frame until
winit says `Occluded(false)`, Timeout retries. No change to `swiftly-render` was needed. wgpu needs the display handle at
instance creation on Wayland/X11/GL: the instance is made with `InstanceDescriptor::new_with_display_handle(event_loop
.owned_display_handle())`. `unsafe` is not used anywhere in this crate.

## Measured

Mac, Apple M1 Max, macOS 27, release build, load average 10 to 17 from other builds during all runs (so upper bounds).

- Window (`--demo g1 --stats`, 2560x1600 px at 2x, Metal, FIFO, refresh period 8.33 ms): the Mac's screen was locked during
  the runs (`CGSSessionScreenIsLocked = true`, 03:51 at night), so macOS kept the window occluded (wgpu-hal skips
  `nextDrawable` then; also tried as a proper `.app` through `open`, same) and **no frame was presented: there are no window
  frame times yet**. 10 s untouched run: `stats 5.0s frames=0 (idle: nothing was redrawn)` twice, exit 0, process gone after.
  That the loop stays quiet while occluded and idle is the only window result. Window frame stats must be taken with an
  unlocked screen (README commands).
- `--gpu-bench --autoplay --quit-after 10` (real wgpu renderer, offscreen 2560x1600, shell + draw + wait for the GPU, paced
  at 120 Hz by a timer, scripted rail flings, a tile click with push and pop, page scroll):
  `frames=550 cpu_ms p50=4.22 p99=13.18 max=28.30 | interval_ms p50=8.74 p99=14.13 max=28.31 (period 8.33) | dropped=14`
  (the intervals are the benchmark's own timer, not a vsync). Without autoplay: one frame (15 ms, cold atlas), then idle.
- Headless software draw of one 1000x700 frame: about 0.2 ms for the draw list (`--frames`, ms/frame in the output).

## Findings in other crates (not changed)

- A button whose label is a single short word run like "Zurück" or "Zur Startseite" is cut to "Zurü..." / "Zur..." when it is
  the first child of the page column, while "Abspielen" and "Zurück zur Startseite" are fine. `swiftly-text` measures the string
  correctly in isolation (56.8 pt, not truncated at width + 0.5), so the node gets less width than it measured. Probably in
  `swiftly-ui`/`swiftly-layout` (a min-width probe of a stack). The demo uses the longer label. Not investigated further.
- `Ui` has no wheel/trackpad scroll and no per-node offset (the nav composes by padding/frame offsets and rebuilds per frame).
- `swiftly-render::GpuContext::surface_config` works (Metal, Bgra8Unorm); Vulkan and DX12 surfaces are not run yet (the Windows
  PC was only used to build).

## Open

- Window frame stats on the Mac with a visible window, and on a Windows machine.
- Windows and Linux: DX12/Vulkan/GL surface, scale-factor change between monitors, touch screen path.
- Pinch, hover, keyboard focus (`focus` module), `a11y` (accesskit_winit), cursor icons.
