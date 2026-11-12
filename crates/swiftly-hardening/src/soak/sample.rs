//! Process samples (RSS, threads, open fds, live tokio tasks) and the verdict over a run.

use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy)]
pub struct Sample {
    pub t: f64,
    pub rss_kb: u64,
    pub threads: u64,
    pub fds: u64,
    pub tasks: u64,
}

fn thread_lines() -> usize {
    let pid = std::process::id().to_string();
    std::process::Command::new("ps")
        .args(["-M", "-p", &pid])
        .output()
        .map_or(0, |o| String::from_utf8_lossy(&o.stdout).lines().count())
}

pub fn rss_kb() -> u64 {
    let pid = std::process::id().to_string();
    std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &pid])
        .output()
        .ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
        .unwrap_or(0)
}

pub fn thread_count() -> u64 {
    #[cfg(target_os = "linux")]
    {
        return std::fs::read_dir("/proc/self/task").map_or(0, |d| d.count() as u64);
    }
    #[allow(unreachable_code)]
    {
        // macOS: `ps -M` prints one line per thread after a header line.
        thread_lines().saturating_sub(1) as u64
    }
}

pub fn fd_count() -> u64 {
    std::fs::read_dir(if cfg!(target_os = "linux") {
        "/proc/self/fd"
    } else {
        "/dev/fd"
    })
    .map_or(0, |d| d.count() as u64)
}

/// (rss KB, threads, open fds / handles) of this process. Windows has no `ps` or `/proc`: one PowerShell call.
fn process_stats() -> (u64, u64, u64) {
    if cfg!(windows) {
        let script = format!(
            "$p = Get-Process -Id {}; \"$([int64]($p.PrivateMemorySize64 / 1024)) $($p.Threads.Count) $($p.HandleCount)\"",
            std::process::id()
        );
        let out = std::process::Command::new("powershell")
            .args(["-NoProfile", "-Command", &script])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        let n: Vec<u64> = out
            .split_whitespace()
            .filter_map(|w| w.parse().ok())
            .collect();
        return (
            n.first().copied().unwrap_or(0),
            n.get(1).copied().unwrap_or(0),
            n.get(2).copied().unwrap_or(0),
        );
    }
    (rss_kb(), thread_count(), fd_count())
}

pub fn take(started: Instant, handle: &tokio::runtime::Handle) -> Sample {
    let stats = process_stats();
    Sample {
        t: started.elapsed().as_secs_f64(),
        rss_kb: stats.0,
        threads: stats.1,
        fds: stats.2,
        tasks: handle.metrics().num_alive_tasks() as u64,
    }
}

/// Samples on a thread until `stop` is set.
pub fn sampler(
    started: Instant,
    handle: tokio::runtime::Handle,
    every: Duration,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
) -> std::thread::JoinHandle<Vec<Sample>> {
    std::thread::spawn(move || {
        let mut all = vec![take(started, &handle)];
        while !stop.load(std::sync::atomic::Ordering::SeqCst) {
            std::thread::sleep(every);
            all.push(take(started, &handle));
        }
        all
    })
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    v.get(v.len() / 2).copied().unwrap_or(0.0)
}

/// What the run found. Empty `problems` means pass.
#[derive(Debug, Default)]
pub struct Verdict {
    pub problems: Vec<String>,
    pub summary: String,
}

/// Samples after the warm-up that a run needs before its memory trend is judged (50 s at 250 ms).
pub const MIN_HOLD_SAMPLES: usize = 200;

/// `samples` are taken during the run, `idle` after everything was dropped and settled.
/// Memory is judged only when the run is long enough to have a warm-up ([`MIN_HOLD_SAMPLES`] samples after it): a
/// library view model parses the whole title list, and the allocator keeps its pages (RSS) until the working set of
/// all workers has been reached; a short run only sees that climb (`leaks` finds no unreachable block after it):
/// the median of the last quarter must not exceed the median of the first post-warm-up quarter
/// by more than `rss_mb` while the quarter medians also rise step by step.
pub fn judge(samples: &[Sample], idle: Sample, rss_mb: f64) -> Verdict {
    let mut v = Verdict::default();
    let n = samples.len();
    let warm = n / 3;
    let hold = &samples[warm.min(n.saturating_sub(1))..];
    let (peak_threads, peak_tasks, peak_fds) = (
        samples.iter().map(|s| s.threads).max().unwrap_or(0),
        samples.iter().map(|s| s.tasks).max().unwrap_or(0),
        samples.iter().map(|s| s.fds).max().unwrap_or(0),
    );
    let base = hold.first().copied().unwrap_or(idle);
    v.summary = format!(
        "samples={n} rss_kb first={} last={} peak={} | threads base={} peak={peak_threads} idle={} | tasks peak={peak_tasks} idle={} | fds base={} peak={peak_fds} idle={}",
        samples.first().map_or(0, |s| s.rss_kb),
        samples.last().map_or(0, |s| s.rss_kb),
        samples.iter().map(|s| s.rss_kb).max().unwrap_or(0),
        base.threads,
        idle.threads,
        idle.tasks,
        base.fds,
        idle.fds,
    );
    if idle.threads > base.threads + 8 {
        v.problems.push(format!(
            "threads leaked: {} after warm-up, {} idle at the end",
            base.threads, idle.threads
        ));
    }
    if idle.tasks > 4 {
        v.problems.push(format!(
            "tasks leaked: {} alive after every session was dropped",
            idle.tasks
        ));
    }
    if idle.fds > base.fds + 32 {
        v.problems.push(format!(
            "fds leaked: {} after warm-up, {} idle at the end",
            base.fds, idle.fds
        ));
    }
    if hold.len() >= MIN_HOLD_SAMPLES {
        let q = hold.len() / 4;
        let med = |s: &[Sample]| median(s.iter().map(|x| x.rss_kb as f64 / 1024.0).collect());
        let quarters: Vec<f64> = (0..4).map(|i| med(&hold[i * q..(i + 1) * q])).collect();
        let rising = quarters.windows(2).all(|w| w[1] >= w[0] - 1.0);
        let grown = quarters[3] - quarters[0];
        v.summary += &format!(
            " | rss quarters MB {:.0}/{:.0}/{:.0}/{:.0}",
            quarters[0], quarters[1], quarters[2], quarters[3]
        );
        if rising && grown > rss_mb {
            v.problems.push(format!("memory grows monotonically: +{grown:.0} MB after warm-up (limit {rss_mb:.0} MB), quarters {quarters:.0?}"));
        }
    }
    v
}
