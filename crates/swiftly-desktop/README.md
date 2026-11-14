# swiftly-desktop

The Windows and Linux app (and a Mac window for development): the shared Swiftly Rust UI in a winit window, with video
through libmpv. Release builds start the real app; `--demo g1` starts the gate G1 demo ("Startseite": three poster rails of
200 items, a tap opens a detail page, Esc / back button goes back).

## Build and run

```sh
cargo build -p swiftly-desktop --release --features mpv   # without `mpv` the app has no video
cargo run -p swiftly-desktop --release --features mpv     # the real app: sign in, browse, play
```

libmpv is loaded at run time: `libmpv.so.2` on Linux, `libmpv-2.dll` next to the `.exe` on Windows, or the path in
`SWIFTLY_LIBMPV`. For a server to sign in to during development, run `cargo xtask fixture-server --port 8096 --real-shapes`
(user `demo`, password `demo`). Packages: `Werkzeuge/package-desktop.sh`, see `Documentation/Building.md`.

winit 0.30.13 (pinned) + wgpu 30 surface through `swiftly-render`, FIFO present, a frame is drawn only when something asked
for one. Notes, estimates and measurements: [NOTES.md](NOTES.md).

## Run the demo (Mac)

```sh
cd <repository root>
export PATH=$HOME/.cargo/bin:$PATH
cargo run -p swiftly-desktop --release -- --demo g1 --stats
```

`--stats` prints frame time (p50 / p99 / max), the interval between frames and dropped frames to the terminal every 5 s.
An untouched window prints `frames=0 (idle ...)`: nothing is redrawn while nothing moves.

Without anybody at the mouse, the built-in script scrolls a rail, opens a detail page, goes back and scrolls the page
(for 10 s, then the window closes):

```sh
cargo run -p swiftly-desktop --release -- --demo g1 --stats --autoplay --quit-after 10
```

## Run the demo (Windows)

Build in the repo folder on the Windows machine with `cargo build -p swiftly-desktop --release --features mpv`
(or cross-compile with `cargo xwin build --release --target x86_64-pc-windows-msvc -p swiftly-desktop --features mpv`). Then in PowerShell:

```powershell
.\swiftly-desktop.exe --demo g1 --stats
```

## What to try

- Mouse wheel or touchpad over a rail scrolls it sideways, over the page up and down; the fling, the rubber band at the
  ends and the snap to a poster are the touch-screen physics.
- Click a poster: the detail page pushes in (easeInOut 0.45 s, the page below moves 30 % left and dims 28 %). Esc,
  Backspace, Alt+Left, Cmd+[, the mouse back button or the "Zurück zur Startseite" button pops it.
- Pressing the left button and dragging scrolls like a finger. On a touch screen (Windows) a finger does the same.
- Resize the window and move it between screens of different scale: the layout follows, the text stays sharp.
- Ctrl+Q / Cmd+Q / Ctrl+W / Cmd+W quits.

## Options

```
--demo g1            the gate G1 demo (the default of debug builds)
--app                the real app (the default of release builds)
--help               every option
--stats              frame statistics to stderr every 5 s
--autoplay           scripted run inside the process (no OS input)
--quit-after N       close after N seconds
--size WxH           window size in points (default 1280x800)
--frames N --png F   no window: N frames at 60 Hz, software renderer, last frame to F.png (smoke test)
--open-detail        with --frames: start on the detail page
--gpu-bench          no window: real GPU renderer into an offscreen texture at 120 Hz (with --autoplay --quit-after)
```

## Tests

```sh
cargo test -p swiftly-desktop      # no window, no GPU: runs on CI machines
cargo test -p swiftly-ui --lib nav # push, interactive back swipe
```
