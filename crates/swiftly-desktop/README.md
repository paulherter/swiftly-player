# swiftly-desktop

The Windows, Linux and Mac window of the shared Swiftly Rust UI, with the gate G1 demo ("Startseite": three poster rails of
200 items, a tap opens a detail page, Esc / back button goes back).

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

Build in the repo folder on the Windows machine with `cargo build -p swiftly-desktop --release`
(or cross-compile with `cargo xwin build --target x86_64-pc-windows-msvc`). Then in PowerShell:

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
--demo g1            the gate G1 demo (default, only one)
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
