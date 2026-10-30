# Changes to VLCKit

Swiftly ships a **modified** VLCKit. The LGPL requires the changes to be public, which is why the patches live here.

| | |
|---|---|
| Base | VLCKit **4.0.0-a23** |
| VLC revision | the `TESTEDHASH` pinned by VLCKit |
| Patches | `0028-mkv-…`, `0030-vout-clock-…`, `0031-ios-…`, `0032-input_clock-…`, `0033-avcodec-…`, `0034-input-…`, `0035-demux-mkv-…`, `0036-avsamplebuffer-…`, `0037-avsamplebuffer-…`, `0038-avsamplebuffer-…`, `VLCKit-pause-without-queue.patch` |

## 0028: seeking in Matroska over HTTP

A Matroska file whose cues cannot be parsed could not be seeked forward over HTTP: every seek landed at the start of the file and the demuxer read its way to the target. For a 718 MB file that took 30 to 90 seconds. VLC 3 plays the same file from the same source and seeks instantly.

**The two parts are independent, and only one is proven to matter.** Part 2 (`index_range()` without `b_fastseekable`) did the work. Part 1 (do not set `b_cues` when nothing was loaded) never triggers for the measured file: its cues break off at `EBMLCrc32`, but enough points are loaded before that, so the index is not empty. Part 1 is defensible on its own but fixes nothing that was measured.

An earlier version of this note claimed the parts only work together. That was wrong: the build used to test part 2 alone most likely did not contain it, because the build script resets the VLC tree on every run and the patch had been applied by hand. Timestamps only prove that a rebuild happened, not what went into it. With both parts the file seeks instantly, and the warning line from part 1 never appears in the log.

## Applying

Patches belong in VLCKit's own patch directory, not on the checked-out VLC tree. On **every** run the build script does

```sh
git reset --hard ${TESTEDHASH} && git am libvlc/patches/*.patch
```

so a patch applied by hand does not survive.

```sh
cp Werkzeuge/vlckit-patches/0028-*.patch <VLCKit>/libvlc/patches/
cd <VLCKit> && ./compileAndBuildVLCKit.sh -t -f    # tvOS
```

The build script does **not** cope with spaces in the path.

The patches should be submitted to VideoLAN. Once they are merged, the official builds can be used again.

## Pause takes effect immediately: three patches, all measured

Between pressing pause and the picture standing still, up to **125 ms** passed. At 120 Hz that is about fourteen frames, on every platform.

**Measure first, then patch.** The first suspect was `ControlPause` in `src/input/input.c`. Instrumentation showed that whole section takes **157 to 216 microseconds**: libvlc's pause path was never the problem.

| Stage | before | fix |
|---|---|---|
| VLCKit queues `pause` on a serial queue | 17-25 ms | `VLCKit-pause-without-queue.patch` |
| libvlc: command until clocks stop | 0.2 ms | nothing to do |
| Clock does not wake waiters on pause | up to 41 ms | `0030`, first half |
| Display loop waits `VOUT_REDISPLAY_DELAY` (80 ms) | up to 80 ms | `0030`, second half |

After that, pause and resume take effect after about one frame.

### The VLCKit patch is not a libvlc patch

`VLCKit-pause-without-queue.patch` touches `Sources/Playback/VLCMediaPlayer.m`, so it does **not** go into `libvlc/patches/`: the build script only resets the vlc tree, VLCKit's own sources survive. It has to be applied by hand. **Check before every build that it is in**, otherwise it is missing unnoticed.

`play` deliberately stays on the queue, **except** when resuming from pause: the first start opens the media and may touch the network, and must not block the caller.

## Build times

On a MacBook Pro (M1 Pro, 10 cores), contribs already built:

| Run | Duration |
|---|---|
| macOS, any further run | **4-5 min** |
| iOS + simulator, release | **7 min** |
| tvOS + simulator, release | **4.5 min** |

A full pass over all three platforms takes about a quarter of an hour.

A build without `-r` is a **debug** build, and in it the OpenGL output aborts with `Assertion failed: (!"GL_INVALID_OPERATION") … vout_helper.c:164`. The bug is also in the shipped version, where the assertion is merely compiled out. Always use `-r` for measuring.

## Known and not fixed: flicker while dragging the window edge

macOS only, only while dragging, and **older than these patches**: a build without them flickers identically. `reshape` in `modules/video_output/macosx.m` only updates the dimensions and does not trigger a redraw; until the next frame arrives, the window server shows the old, differently scaled buffer. When paused no frame ever arrives, so it is worst there.

VLC's own countermeasure sits in `renewGState`, and its comment says `disableScreenUpdatesUntilFlush` has been **a no-op since macOS 10.13**.

An attempt to redraw synchronously with `[self display]` in `reshape` during `inLiveResize` **was dropped**: the flicker went away, but dragging ran at about two frames per second. `reshape` fires dozens of times per second while dragging, and each call paints the whole frame and waits for the buffer swap. The right fix is to draw something **cheap** while dragging, which is what Apple's documentation advises for `inLiveResize`.

## Build once **without** `-r` before shipping

`-r` is required for measuring (see above), but a patch should be built and run exactly once **without** it before shipping, otherwise code ships whose assertions never ran. This has hidden problems twice:

- The OpenGL output aborts when the player opens, with the assertion above. It is not fixed, only unobserved.
- A first draft of `0031` removed the `WillResignActive` branch but left the **observer registration for that notification** in place. It fell into the `else` branch that ends in `assert(… DidBecomeActive …)`. In debug that aborts while the notification center is set up; in release it silently sets `_appActive = YES` when leaving the active state, which is backwards and invisible.

The rule that came out of it: **do not subscribe to a notification you do not handle.** The debug build is where this shows up.

## Clock jumps: the app died on a file with wide timestamps (`0032`)

`0032-input_clock-raise-CR_MAX_GAP-back-to-60-seconds.patch`

One episode on a test server killed the app on Apple TV after about two minutes. Not a crash (the device had no report) but burnt CPU.

**Measured in the device log:**

```
clock gap, unexpected stream discontinuity: system_diff: 34 stream_diff: 320666
feeding synchro with a new reference point trying to recover from clock gap
new clock context(1) … (2642)
```

5276 of these in 72 seconds, 35 to 70 new clock contexts per second. Over 2638 samples, `stream_diff` was min 303 ms, median 490 ms, max 1001 ms: **every single value just above the 300 ms threshold**.

It was not the file alone. Nine titles in the log, six of them for hours: zero clock jumps. Only this one. And the same file plays in Swiftfin on the same Apple TV, which runs on VLCKit **3**.

That was the hint. In VLC 4, `input_clock: finer discontinuity handling` lowered `CR_MAX_GAP` from **60 seconds to 300 ms**, together with a better comparison: a large `stream_diff` is fine as long as `system_diff` grows with it.

The comparison only holds when the source sets its own pace. When **we** set it (a file over HTTP), the demuxer reads as fast as it can, `system_diff` is practically zero, and every timestamp gap above 300 ms counts as a break. The clock then resets its reference point on every update.

The patch raises the threshold back to 60 seconds. The improved comparison stays, and `stream_diff < 0` still catches real backward jumps regardless of this value.

**Should be reported to VideoLAN**: any client that plays files over HTTP is affected.

## Anamorphic Matroska is squeezed: `0035`, taken from VideoLAN

ffmpeg (and so everything on libavformat, such as HandBrake) writes anamorphic MKV with `DisplayUnit = 3` (aspect ratio, e.g. 16/9). The pinned VLC tree computes the pixel aspect ratio the wrong way round from it: 720x576 in 16:9 gives `sar 45:64` instead of 64:45, and VLC asks for a 506x576 window instead of 1024x576 (measured with VLCKit a23 on macOS). libVLC 3 computes it correctly.

The patch is VideoLAN's own commit `74a3aae62e` ("demux: mkv: fix the Display Aspect Ratio to Sample Aspect Ratio conversion"), unchanged. **Not in any build yet.** Until then the app compensates (`Seitenverhaeltnis` in the package, `seitenverhaeltnisPruefen` in `VLCPlayer`), and that only works as long as VLC reports the ratio exactly inverted. With the patch in the build the compensation becomes a no-op by itself.

## Stutter after start on iPhone and Apple TV: `0036` to `0038`

When resuming playback, the picture ran for about half a second, stalled once, then ran normally; audio stayed smooth. macOS never showed it, nor did Swiftfin with the same file.

**The difference is in the audio output.** On iOS and tvOS VLC picks `avsamplebuffer` (priority 100), on macOS `auhal` (101). `auhal` reports the audio position to the clock on the second render call. `avsamplebuffer` only reported through a one-second observer that skips time zero, and on rate changes. Until the first report the picture runs on the clock's fallback reference (`clock.c`, `vlc_clock_monotonic_to_system`); when it then switches to audio, one frame is late and `AVSampleBufferDisplayLayer` drops it. The output also started the synchronizer at rate 1 even when paused in the meantime, which is exactly the case when resuming playback that opens paused.

**Confirmed on a device:** with `--aout=audiounit_ios` (the same reporting path as `auhal`) the stutter was gone. That output was ruled out anyway: audio stayed silent after some starts, and surround sound only exists through `avsamplebuffer`.

- `0036` keeps the pause state independent of the timeline, starts the synchronizer at rate 0 when paused, drops reports while paused, and reports the position immediately after start and after resume. The model is SwiftVLC's rework of the same output.
- `0037`: `0036` alone was not enough. The output's start deadline was "date of the last received block minus everything already queued", and once everything is queued the last block counts itself, so audio started exactly one block early (about 32 ms for 5.1 E-AC-3). The first timing report pulled the whole clock forward by that amount and the next picture was late ("picture displayed late (missing 27 ms)"). `coreaudio_common.c` (macOS, `audiounit_ios`) computes it correctly: date of a block minus what came *before* it. `0037` adopts that and writes every timing report and the actual start offset to the debug log.
- `0038`: the log lines from `0037` showed that the synchronizer's timebase stays stopped after setting the rate until the renderer has brought its audio path up (about 200 ms). The immediate report from `0036` was therefore an estimate, and the first real one pulled the clock back by 0.2 s, which was the stutter. `0038` only reports from a running timebase: after start and resume it polls every 5 ms until it moves. If it came up later than planned, the position is advanced by the delay (the renderer skips that much audio) so it matches the date the core planned and the clock does not jump.

**`0036` to `0038` are not in the shipped build.** With them, every seek stuttered on iPhone ("30 s forward", "10 s back", "skip episode", scrubbing): the picture stopped briefly and then ran out of sync. The log shows three `resetting master clock: decreasing ts` and one "clock running but no new picture" per run. The framework without the three patches does not show any of this. The patches stay here for a later, correct fix. The stutter on resume that they were meant to fix is back until then.

## 0039: clip subtitle glyphs to the picture

A glyph can reach past the box the subtitle region was sized from, and the blend functions do not clip. Its top row was read and written above the picture, which corrupts the heap and crashes in `BlendGlyphToARGB` when the picture sits at the start of a malloc region. Not part of a shipped build yet: until then the app avoids the overflow with `--freetype-background-opacity=1` (see `SubtitleStyle` in `VLCPlayer.swift`).
