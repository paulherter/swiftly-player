# swiftly-motion

Pure-math feel module of the Swiftly Rust UI: SwiftUI-style springs, `UIScrollView`-style one-axis scroll physics and every
feel constant in one file. `std` only, `f64`, no unsafe, no clock inside (time is passed in), fully deterministic.
Formulas and numbers: see the source comments in `src/tuning.rs`.

## API in 10 lines

```rust
use swiftly_motion::{Spring, SpringAnim, ScrollBody, ScrollMetrics, scroll, tuning};
let s = Spring::from_duration_bounce(0.5, 0.3);          // or smooth()/snappy()/bouncy()/spring_default()/interactive()
let x = s.value(-1.0, 0.0, 0.2);                         // displacement from target after 0.2 s; s.velocity(..), s.settling_duration(0.001)
let mut a = SpringAnim::new(Spring::smooth(), 0.0);      // stateful: a.retarget(1.0); a.step(dt); a.is_settled()
let mut b = ScrollBody::new(ScrollMetrics::new(5000.0, 852.0), 0.0);
b.touch_down(t_ms); b.touch_move(dy, t_ms);              // 1:1 inside, rubber band past the ends
b.touch_up(t_ms);                                        // fling (0.998/ms), spring back, spring at the crossing
b.touch_up_snap(t_ms, |p| scroll::nearest_start(&starts, p)); // paging / poster rows (scroll::page_target)
let y = b.offset(t_ms);                                  // per frame; b.state(), b.needs_frames(), b.velocity(t_ms)
scroll::project(v, tuning::DECELERATION_NORMAL);         // Apple's projection; project_exact, glide_distance, rubber_band
```

Offsets are points, times milliseconds, velocities points per second. Every number lives in `src/tuning.rs` with its source.

## Test

```sh
cargo test -p swiftly-motion
cargo clippy -p swiftly-motion --all-targets -- -D warnings
```

Tests encode the research numbers (2000 pt/s flick: ~999 pt / 3.8 s at 0.998, ~199 pt / 0.60 s at 0.99; rubber band 100 -> 51.7,
200 -> 97.4 at d = 852; Apple spring examples; `.smooth` settles in ~0.735 s) plus property loops with a tiny built-in PRNG.
See `NOTES.md` for the places where the code deliberately differs from the research text.
