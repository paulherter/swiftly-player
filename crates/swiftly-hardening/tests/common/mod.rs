//! Helpers shared by the `props_*` and `fuzz_*` suites (not a test target itself).
#![allow(dead_code)]

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;
use std::time::Duration;

/// Iteration count: `HARDENING_ITERS` if set, else `default` (small, so default runs stay fast).
pub fn iters(default: u64) -> u64 {
    std::env::var("HARDENING_ITERS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "non-string panic".to_string()
    }
}

/// Runs `case(seed)` for seeds `0..iters(default)` (or only `HARDENING_SEED=<n>`). The first
/// failing seed is reported with the replay command.
pub fn for_seeds(name: &str, default: u64, case: impl Fn(u64)) {
    let seeds: Vec<u64> = match std::env::var("HARDENING_SEED")
        .ok()
        .and_then(|v| v.parse().ok())
    {
        Some(s) => vec![s],
        None => (0..iters(default)).collect(),
    };
    for seed in seeds {
        if let Err(p) = catch_unwind(AssertUnwindSafe(|| case(seed))) {
            panic!(
                "{name}: FAILED at seed {seed} (replay: HARDENING_SEED={seed} cargo test -p swiftly-hardening --test {name}): {}",
                message(&*p)
            );
        }
    }
}

/// Runs `f` on its own thread with a time budget; a panic or a timeout is returned as an error.
pub fn guarded<T: Send + 'static>(
    budget: Duration,
    f: impl FnOnce() -> T + Send + 'static,
) -> Result<T, String> {
    let (tx, rx) = mpsc::channel();
    let handle = std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(move || {
            let r = catch_unwind(AssertUnwindSafe(f));
            let _ = tx.send(r.map_err(|p| message(&*p)));
        })
        .map_err(|e| format!("spawn: {e}"))?;
    match rx.recv_timeout(budget) {
        Ok(Ok(v)) => {
            let _ = handle.join();
            Ok(v)
        }
        Ok(Err(m)) => {
            let _ = handle.join();
            Err(format!("panic: {m}"))
        }
        Err(_) => Err(format!("HANG: no result within {budget:?}")),
    }
}
