//! A short soak (default 8 s, `HARDENING_SOAK_SECS` for more). Leaks of threads, tasks and fds
//! are always judged; the memory trend only when the run is long enough for a warm-up.
#![allow(clippy::unwrap_used, clippy::expect_used)]
use swiftly_hardening::soak::{Config, workload};

#[test]
fn soak_short() {
    let cfg = Config::from_env(8);
    let report = workload::run(&cfg);
    println!("problems: {:#?}", report.verdict.problems);
    assert!(
        report.verdict.problems.is_empty(),
        "soak seed={}: {:#?}",
        cfg.seed,
        report.verdict.problems
    );
    assert!(
        report
            .stats
            .max_tiles
            .load(std::sync::atomic::Ordering::Relaxed)
            > 60,
        "paging never went beyond the first page"
    );
}
