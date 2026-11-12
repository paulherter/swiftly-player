//! Frame cost of the rail scene on this machine (ignored by default):
//! `cargo test -p swiftly-ui --release -- --ignored --nocapture bench`

mod common;

use common::{ROW_Y_FOR_BENCH, rail_harness};
use std::time::Instant;
use swiftly_ui::harness::Trace;

#[test]
#[ignore = "timing, run by hand"]
fn bench_frame_cost_at_rest_and_while_flinging() {
    let mut h = rail_harness(100_000);
    let _ = h.frame_at(0.0);
    let n = 2000;
    let t = Instant::now();
    for i in 0..n {
        let _ = h.ui.frame(f64::from(i));
    }
    let rest = t.elapsed().as_secs_f64() * 1000.0 / f64::from(n);
    h.play(
        &Trace::new()
            .drag(
                3000.0,
                100.0,
                8.0,
                (380.0, ROW_Y_FOR_BENCH),
                (20.0, ROW_Y_FOR_BENCH),
            )
            .up(3100.0, 20.0, ROW_Y_FOR_BENCH),
    );
    let t = Instant::now();
    let mut frames = 0;
    let mut now = 3100.0;
    while h.ui.needs_frame() && frames < 2000 {
        now += 1000.0 / 120.0;
        let _ = h.ui.frame(now);
        frames += 1;
    }
    let fling = t.elapsed().as_secs_f64() * 1000.0 / f64::from(frames.max(1));
    println!(
        "frame(now) at rest: {rest:.3} ms; while flinging ({frames} frames): {fling:.3} ms; built items {}",
        h.ui.built_items()
    );
}
