//! Deterministic harness: fake clock, manual worker pool, drain step by step. No real sleeping.
use crate::{FakeClock, UiExecutor, WorkerPool};
use std::sync::Arc;
use std::time::Duration;

pub struct Rt {
    pub ex: UiExecutor,
    pub clock: FakeClock,
    pub pool: Arc<WorkerPool>,
}
impl Rt {
    /// Manual pool: jobs run only when the harness steps them, in FIFO order.
    pub fn manual() -> Self {
        let clock = FakeClock::new();
        Rt {
            ex: UiExecutor::new(Arc::new(clock.clone())),
            clock,
            pool: Arc::new(WorkerPool::manual()),
        }
    }
    /// Real worker threads (completion order of different jobs is up to the OS; use `wait_until`).
    pub fn threaded(n: usize) -> Self {
        let clock = FakeClock::new();
        Rt {
            ex: UiExecutor::new(Arc::new(clock.clone())),
            clock,
            pool: Arc::new(WorkerPool::threads(n)),
        }
    }
    /// Polls and runs manual jobs until nothing is ready. Time does not move.
    pub fn run_until_stalled(&self) {
        loop {
            self.ex.poll_frame();
            if self.ex.has_ready() {
                continue;
            }
            if self.pool.step() {
                continue;
            }
            break;
        }
    }
    pub fn advance(&self, d: Duration) {
        self.clock.advance(d);
        self.run_until_stalled();
    }
    /// Jumps to the next timer and runs. False if no timer is pending.
    pub fn advance_to_next_timer(&self) -> bool {
        match self.ex.next_deadline() {
            Some(t) => {
                if t > self.clock_now() {
                    self.clock.set(t);
                }
                self.run_until_stalled();
                true
            }
            None => false,
        }
    }
    pub fn clock_now(&self) -> Duration {
        use crate::Clock;
        self.clock.now()
    }
    /// Threaded pools: poll frames until `cond`, parking on the wake condvar (a watchdog turns a lost wakeup into a failure).
    pub fn wait_until(&self, mut cond: impl FnMut() -> bool) {
        for _ in 0..2_000 {
            self.ex.poll_frame();
            if cond() {
                return;
            }
            self.ex.park(Duration::from_millis(5));
        }
        panic!("wait_until: condition never became true (deadlock or lost wakeup)");
    }
}
