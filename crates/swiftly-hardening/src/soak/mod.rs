//! Soak and watchdog pieces: an in-process Jellyfin-shaped server with a big library, host
//! implementations of the foreign traits (with a blocking probe), process samples and the workload
//! that drives the real core (`swiftly-uniffi::Core`).
//!
//! Environment: `HARDENING_SOAK_SECS` (run length), `HARDENING_SOAK_SEED`, `HARDENING_SOAK_WORKERS`,
//! `HARDENING_SOAK_RSS_MB` (allowed growth after warm-up).

pub mod host;
pub mod sample;
pub mod server;
pub mod workload;
pub mod ws;

/// Run parameters; printed at the start so a failure can be repeated.
#[derive(Debug, Clone)]
pub struct Config {
    pub secs: u64,
    pub seed: u64,
    pub workers: usize,
    pub big: usize,
    pub sample_ms: u64,
    pub rss_mb: f64,
    /// Longest allowed stall of the heartbeat (stand-in for the main thread), ms.
    pub stall_ms: u64,
}

fn env_u64(name: &str) -> Option<u64> {
    std::env::var(name).ok()?.trim().parse().ok()
}

impl Config {
    /// Reads the environment; `default_secs` is used when `HARDENING_SOAK_SECS` is not set.
    pub fn from_env(default_secs: u64) -> Self {
        let seed = env_u64("HARDENING_SOAK_SEED").unwrap_or_else(|| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(1, |d| d.as_nanos() as u64)
        });
        Self {
            secs: env_u64("HARDENING_SOAK_SECS").unwrap_or(default_secs),
            seed,
            workers: env_u64("HARDENING_SOAK_WORKERS").map_or(4, |n| n.max(1) as usize),
            big: 10_000,
            sample_ms: if env_u64("HARDENING_SOAK_SECS").is_some_and(|s| s > 120) {
                1000
            } else {
                250
            },
            rss_mb: env_u64("HARDENING_SOAK_RSS_MB").map_or(64.0, |n| n as f64),
            stall_ms: env_u64("HARDENING_SOAK_STALL_MS").unwrap_or(250),
        }
    }
}
