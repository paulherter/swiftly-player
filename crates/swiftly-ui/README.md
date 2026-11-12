# swiftly-ui

Retained UI of the shared Swiftly Rust UI (Android, Windows, Linux): a SwiftUI-style declarative tree with keyed, retained
node state, gestures, scrolling and a frame loop that emits `swiftly-render` quads.

```rust
let mut ui = Ui::new(|parts: &Parts, env, cx| page(env, vec![rail(cx, "rail", "Weiterschauen", parts.n, item)]),
                     parts, Env::phone(390.0, 844.0, 3.0), Cx::new());
ui.set_parts(new_parts);            // runs `view` only if the parts differ
ui.touch_down(x, y, now_ms); ui.touch_move(..); ui.touch_up(..);   // gesture arena -> ui.take_events()
let list = ui.frame(now_ms);        // advances springs, scrolls, press; returns a DrawList; ui.needs_frame() says if more are needed
```

| Piece | What |
|---|---|
| `Node` (view.rs) | layout kind + paint + gestures + scroll/lazy behaviour; modifiers `.padding .frame .background .overlay .key .on_tap ...` |
| tree (tree.rs) | identity = parent path + key + kind; `Animated` springs/eases, `ScrollBody`, press state live in a map keyed by that identity and survive rebuilds; lazy lists build only the window |
| `Ui` (ui.rs) | `view` re-run on parts or `Env` change; hit-test; arena: tap, long press (0.5 s), pan (10 pt hysteresis, axis lock), edge pan; press 0.97 / 0.85 (inside scroll views after 150 ms, cancelled by > 10 pt) |
| `Env` | size, safe insets, scale, idiom, h/v size class, input mode, reduce motion |
| `components` | `tile` (poster 116 x 174, radius 10, 1 pt edge, title), `rail` (header + lazy snapping row), `press_button`, `page` |
| `tuning` | the only home of feel numbers, each with its source |
| `harness` | synthetic touch traces with timestamps, 120 Hz frame stepping, software-renderer PNGs |

## Tests

```sh
cargo test -p swiftly-ui                         # behaviour with touch traces, goldens in tests/golden/
UPDATE_GOLDENS=1 cargo test -p swiftly-ui        # rewrite rail_rest / rail_mid_drag / rail_mid_fling
cargo test -p swiftly-ui --release -- --ignored --nocapture bench
```

Goldens use the bundled Inter only. What is estimated and what a human must still compare with the iPhone app: `NOTES.md`.
