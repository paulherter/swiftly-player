//! Port of EpisodesSwitch.swift (`EpisodeSwitch`, `StopLock`).
//!
//! The switch to the next episode in the running player: **one** flow for all platforms. This
//! module is the order of steps, not the presentation:
//!
//! 1. Latch: one switch at a time; a second trigger returns [`Outcome::Locked`].
//! 2. Stop the old session and fetch the new plan **side by side**; from here on
//!    `messages_allowed()` is false.
//! 3. No plan: [`Outcome::Failed`], the old episode keeps running.
//! 4. Closed while step 2 ran: [`Outcome::Cancelled`], nothing is applied.
//! 5. `apply` resets the platform's episode state and starts the stream, then `start` reports.
//! 6. Closed while the start was in flight: the stop for the new episode is sent **after** the
//!    start.
//!
//! # Differences to Swift (runtime model)
//!
//! * Swift's `execute` runs on the caller's actor (`#isolation`); here it is a plain `async fn`
//!   that does not spawn anything and is `Send` if the steps are. The "side by side" part uses
//!   `futures_util::future::join`, so no executor is required.
//! * `close` cannot spawn a `Task`; when the stop is to run immediately it is **returned** and
//!   the caller must run (spawn or await) it. When the start is still in flight it is stored and
//!   run by `execute` after the start, as in Swift.
//! * The `NSLock` is a `std::sync::Mutex`; a poisoned lock is recovered (the state is plain
//!   data), never unwrapped.

use std::collections::HashSet;
use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;

/// A boxed future.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// A stop that is run once: what to report as the end of the running session.
pub type StopFn = Box<dyn FnOnce() -> BoxFuture<'static, ()> + Send>;

/// Where the switch is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// Idle (`rests`).
    Rests,
    /// The old session is being stopped, the new plan fetched (`stopAndPlant`).
    StopAndPlant,
    /// The new episode is applied, its start in flight (`starts`).
    Starts,
    /// The player is closed. Final (`closed`).
    Closed,
}

/// What a switch came to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Switched.
    Switched,
    /// A switch was already running (or the player is closed).
    Locked,
    /// The player was closed.
    Cancelled,
    /// No plan for the new episode.
    Failed,
}

/// What the platform contributes.
pub struct Steps<'a, Plan> {
    /// End the old session (the stop guard, [`StopLock`], sits behind it).
    pub stop_now: Box<dyn FnOnce() -> BoxFuture<'a, ()> + Send + 'a>,
    /// Fetch the new plan; `None` means there is none.
    pub plan_out: Box<dyn FnOnce() -> BoxFuture<'a, Option<Plan>> + Send + 'a>,
    /// Set title and plan, reset episode state, play.
    pub apply: Box<dyn FnOnce(&Plan) + Send + 'a>,
    /// Report the start of the new episode.
    pub start: Box<dyn FnOnce(Plan) -> BoxFuture<'a, ()> + Send + 'a>,
    /// Show the notice that no plan came.
    pub failed: Box<dyn FnOnce() + Send + 'a>,
}

struct State {
    phase: Phase,
    /// Counts every switch begun; a lookup applies only to the switch after which it was fetched.
    counter: u64,
    deferred_stop: Option<StopFn>,
}

/// The episode switch state machine.
pub struct EpisodeSwitch {
    state: Mutex<State>,
}

impl Default for EpisodeSwitch {
    fn default() -> Self {
        Self::new()
    }
}

impl EpisodeSwitch {
    /// An idle switch.
    pub fn new() -> Self {
        Self {
            state: Mutex::new(State {
                phase: Phase::Rests,
                counter: 0,
                deferred_stop: None,
            }),
        }
    }

    fn with_lock<T>(&self, f: impl FnOnce(&mut State) -> T) -> T {
        let mut guard = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        f(&mut guard)
    }

    /// Where the switch is.
    pub fn phase(&self) -> Phase {
        self.with_lock(|s| s.phase)
    }

    /// The latch is held.
    pub fn running(&self) -> bool {
        self.with_lock(|s| matches!(s.phase, Phase::StopAndPlant | Phase::Starts))
    }

    /// May the tick loop report start and progress? Only when idle.
    pub fn messages_allowed(&self) -> bool {
        self.with_lock(|s| s.phase == Phase::Rests)
    }

    /// The switch. (`EpisodesSwitch.swift:126-175`)
    pub async fn execute<Plan: Send>(&self, steps: Steps<'_, Plan>) -> Outcome {
        let begun = self.with_lock(|s| {
            if s.phase != Phase::Rests {
                return false;
            }
            s.phase = Phase::StopAndPlant;
            s.counter += 1;
            true
        });
        if !begun {
            return Outcome::Locked;
        }

        let Steps {
            stop_now,
            plan_out,
            apply,
            start,
            failed,
        } = steps;
        // Stop and plan run side by side; the start happens only below.
        let ((), plan) = futures_util::future::join(stop_now(), plan_out()).await;

        let proceed = self.with_lock(|s| {
            if s.phase != Phase::StopAndPlant {
                return None;
            }
            s.phase = if plan.is_none() {
                Phase::Rests
            } else {
                Phase::Starts
            };
            Some(plan.is_some())
        });
        let Some(proceed) = proceed else {
            return Outcome::Cancelled;
        };
        let Some(plan) = plan.filter(|_| proceed) else {
            failed();
            return Outcome::Failed;
        };

        apply(&plan);
        start(plan).await;

        let caught_up = self.with_lock(|s| {
            if s.phase == Phase::Starts {
                s.phase = Phase::Rests;
            }
            s.deferred_stop.take()
        });
        if let Some(caught_up) = caught_up {
            caught_up().await;
            return Outcome::Cancelled;
        }
        Outcome::Switched
    }

    /// The player closes. Only the first call counts. Returns the stop to run **now** (the
    /// caller spawns or awaits it) unless the start is still in flight, in which case the stop
    /// is kept and `execute` runs it after the start. (`EpisodesSwitch.swift:182-195`)
    #[must_use = "the returned stop has to be run by the caller"]
    pub fn close(&self, stop_now: StopFn) -> Option<StopFn> {
        self.with_lock(|s| {
            let before = s.phase;
            if before == Phase::Closed {
                return None;
            }
            s.phase = Phase::Closed;
            if before == Phase::Starts {
                s.deferred_stop = Some(stop_now);
                return None;
            }
            Some(stop_now)
        })
    }

    /// Fetches something for the running episode afterwards (next episode, sections) and
    /// applies it only if no switch has begun since and the player is open.
    /// (`EpisodesSwitch.swift:203-212`)
    pub async fn look_up<Amount>(
        &self,
        fetch: impl Future<Output = Amount>,
        adopt: impl FnOnce(Amount),
    ) {
        let mark = self.with_lock(|s| s.counter);
        let value = fetch.await;
        let applies = self.with_lock(|s| s.counter == mark && s.phase != Phase::Closed);
        if applies {
            adopt(value);
        }
    }
}

/// Stop guard per PlaySession: `Sessions/Playing/Stopped` exactly once. A start releases the
/// session again, a failed stop releases it so that a later one can try again, and after the
/// stop progress is discarded.
#[derive(Default)]
pub struct StopLock {
    stopped: Mutex<HashSet<String>>,
}

impl StopLock {
    /// A fresh lock.
    pub fn new() -> Self {
        Self::default()
    }

    fn with_set<T>(&self, f: impl FnOnce(&mut HashSet<String>) -> T) -> T {
        let mut guard = self
            .stopped
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        f(&mut guard)
    }

    /// Without a PlaySession (from disk), the title stands in for the session. The prefixes
    /// are the Swift strings.
    pub fn key(item_id: &str, play_session_id: Option<&str>) -> String {
        match play_session_id {
            Some(id) => format!("sitzung:{id}"),
            None => format!("titel:{item_id}"),
        }
    }

    /// A start releases the session.
    pub fn started(&self, key: &str) {
        self.with_set(|s| s.remove(key));
    }

    /// `true`: this call reports the stop. `false`: already reported or in flight.
    pub fn stop_accept(&self, key: &str) -> bool {
        self.with_set(|s| s.insert(key.to_owned()))
    }

    /// A failed stop releases the session.
    pub fn stop_failed(&self, key: &str) {
        self.with_set(|s| s.remove(key));
    }

    /// Progress is allowed until the stop was accepted.
    pub fn progress_allowed(&self, key: &str) -> bool {
        self.with_set(|s| !s.contains(key))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_executor::block_on;
    use futures_util::future::join;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::task::Poll;

    /// `Task.yield()`: pending once, then ready.
    async fn yield_now() {
        let mut yielded = false;
        std::future::poll_fn(|cx| {
            if yielded {
                Poll::Ready(())
            } else {
                yielded = true;
                cx.waker().wake_by_ref();
                Poll::Pending
            }
        })
        .await;
    }

    /// Holds a request until the test releases it (Swift `Tor`).
    #[derive(Clone, Default)]
    struct Gate(Arc<AtomicBool>);

    impl Gate {
        async fn wait(&self) {
            while !self.0.load(Ordering::SeqCst) {
                yield_now().await;
            }
        }
        fn open(&self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    /// What went to the "server", in order (Swift `Book`).
    #[derive(Clone, Default)]
    struct Book(Arc<Mutex<Vec<String>>>);

    impl Book {
        fn write(&self, s: &str) {
            self.0.lock().unwrap().push(s.to_owned());
        }
        fn count(&self, s: &str) -> usize {
            self.0.lock().unwrap().iter().filter(|e| *e == s).count()
        }
        fn entries(&self) -> Vec<String> {
            self.0.lock().unwrap().clone()
        }
    }

    #[derive(Clone, Default)]
    struct HostView {
        applied: Arc<Mutex<Vec<String>>>,
        failed: Arc<Mutex<u32>>,
    }

    fn steps(
        book: &Book,
        view: &HostView,
        plan: Option<&str>,
        plan_gate: Option<Gate>,
        start_gate: Option<Gate>,
    ) -> Steps<'static, String> {
        let plan = plan.map(str::to_owned);
        let (b1, b2, b3) = (book.clone(), book.clone(), book.clone());
        let (v1, v2) = (view.clone(), view.clone());
        Steps {
            stop_now: Box::new(move || {
                Box::pin(async move {
                    b1.write("stopp-1");
                })
            }),
            plan_out: Box::new(move || {
                Box::pin(async move {
                    b2.write("plant");
                    if let Some(g) = plan_gate {
                        g.wait().await;
                    }
                    plan
                })
            }),
            apply: Box::new(move |p: &String| v1.applied.lock().unwrap().push(p.clone())),
            start: Box::new(move |p: String| {
                Box::pin(async move {
                    b3.write(&format!("start-{p}"));
                    if let Some(g) = start_gate {
                        g.wait().await;
                    }
                    b3.write("gestartet");
                })
            }),
            failed: Box::new(move || *v2.failed.lock().unwrap() += 1),
        }
    }

    async fn until(mut requirement: impl FnMut() -> bool) {
        for _ in 0..10_000 {
            if requirement() {
                return;
            }
            yield_now().await;
        }
        panic!("condition never reached");
    }

    fn stop_writing(book: &Book, text: &'static str) -> StopFn {
        let book = book.clone();
        Box::new(move || {
            Box::pin(async move {
                book.write(text);
            })
        })
    }

    // Swift: doubleTrigger
    #[test]
    fn double_trigger() {
        let (w, book, view, gate) = (
            EpisodeSwitch::new(),
            Book::default(),
            HostView::default(),
            Gate::default(),
        );
        block_on(async {
            let first = w.execute(steps(
                &book,
                &view,
                Some("plan-2"),
                Some(gate.clone()),
                None,
            ));
            let driver = async {
                until(|| book.count("plant") == 1).await;
                assert!(w.running());
                assert!(!w.messages_allowed());
                let second = w
                    .execute(steps(&book, &view, Some("plan-2"), None, None))
                    .await;
                assert_eq!(second, Outcome::Locked);
                gate.open();
            };
            let (outcome, ()) = join(first, driver).await;
            assert_eq!(outcome, Outcome::Switched);
        });
        assert_eq!(book.count("stopp-1"), 1);
        assert_eq!(book.count("start-plan-2"), 1);
        assert_eq!(*view.applied.lock().unwrap(), ["plan-2"]);
        assert!(!w.running());
        assert!(w.messages_allowed());
    }

    // Swift: closePlan
    #[test]
    fn close_plan() {
        let (w, book, view, gate) = (
            EpisodeSwitch::new(),
            Book::default(),
            HostView::default(),
            Gate::default(),
        );
        block_on(async {
            let run = w.execute(steps(
                &book,
                &view,
                Some("plan-2"),
                Some(gate.clone()),
                None,
            ));
            let driver = async {
                until(|| book.count("plant") == 1).await;
                if let Some(stop) = w.close(stop_writing(&book, "stopp-schliessen")) {
                    stop().await;
                }
                gate.open();
            };
            let (outcome, ()) = join(run, driver).await;
            assert_eq!(outcome, Outcome::Cancelled);
            assert!(view.applied.lock().unwrap().is_empty());
            assert_eq!(book.count("start-plan-2"), 0);
            assert_eq!(book.count("stopp-schliessen"), 1);
            assert_eq!(w.phase(), Phase::Closed);
            // After closing, no new switch starts.
            assert_eq!(
                w.execute(steps(&book, &view, Some("plan-2"), None, None))
                    .await,
                Outcome::Locked
            );
        });
    }

    // Swift: closeStart
    #[test]
    fn close_start() {
        let (w, book, view, gate) = (
            EpisodeSwitch::new(),
            Book::default(),
            HostView::default(),
            Gate::default(),
        );
        block_on(async {
            let run = w.execute(steps(
                &book,
                &view,
                Some("plan-2"),
                None,
                Some(gate.clone()),
            ));
            let driver = async {
                until(|| book.count("start-plan-2") == 1).await;
                // The start is in flight: the stop is kept, not returned.
                assert!(w.close(stop_writing(&book, "stopp-2")).is_none());
                // Not yet: the start has not returned.
                for _ in 0..50 {
                    yield_now().await;
                }
                assert_eq!(book.count("stopp-2"), 0);
                gate.open();
            };
            let (outcome, ()) = join(run, driver).await;
            assert_eq!(outcome, Outcome::Cancelled);
        });
        // Stopping the old episode and fetching the plan run side by side; their order is
        // open, the rest is not.
        let entries = book.entries();
        assert_eq!(
            entries[entries.len() - 3..],
            ["start-plan-2", "gestartet", "stopp-2"]
        );
        let mut head: Vec<&str> = entries[..2].iter().map(String::as_str).collect();
        head.sort_unstable();
        assert_eq!(head, ["plant", "stopp-1"]);
    }

    // Swift: planMissing
    #[test]
    fn plan_missing() {
        let (w, book, view) = (EpisodeSwitch::new(), Book::default(), HostView::default());
        block_on(async {
            assert_eq!(
                w.execute(steps(&book, &view, None, None, None)).await,
                Outcome::Failed
            );
            assert_eq!(*view.failed.lock().unwrap(), 1);
            assert!(view.applied.lock().unwrap().is_empty());
            assert_eq!(book.count("start-plan-2"), 0);
            assert!(!w.running());
            assert_eq!(
                w.execute(steps(&book, &view, Some("plan-2"), None, None))
                    .await,
                Outcome::Switched
            );
        });
    }

    // Swift: twoTimesClose
    #[test]
    fn two_times_close() {
        let (w, book) = (EpisodeSwitch::new(), Book::default());
        block_on(async {
            if let Some(stop) = w.close(stop_writing(&book, "stopp")) {
                stop().await;
            }
            // The second close does nothing.
            assert!(w.close(stop_writing(&book, "stopp")).is_none());
            for _ in 0..50 {
                yield_now().await;
            }
            assert_eq!(book.count("stopp"), 1);
        });
    }

    // Swift: lookupAgain
    #[test]
    fn lookup_again() {
        let (w, book, view, gate) = (
            EpisodeSwitch::new(),
            Book::default(),
            HostView::default(),
            Gate::default(),
        );
        let adopted: Mutex<Vec<String>> = Mutex::new(Vec::new());
        block_on(async {
            w.look_up(async { "folge-3".to_owned() }, |v| {
                adopted.lock().unwrap().push(v)
            })
            .await;
            assert_eq!(*adopted.lock().unwrap(), ["folge-3"]);

            // A lookup in flight while a new switch runs is dropped.
            let old = w.look_up(
                async {
                    gate.wait().await;
                    "alt".to_owned()
                },
                |v| adopted.lock().unwrap().push(v),
            );
            let driver = async {
                for _ in 0..50 {
                    yield_now().await;
                }
                assert_eq!(
                    w.execute(steps(&book, &view, Some("plan-2"), None, None))
                        .await,
                    Outcome::Switched
                );
                gate.open();
            };
            join(old, driver).await;
            assert_eq!(*adopted.lock().unwrap(), ["folge-3"]);

            if let Some(stop) = w.close(Box::new(|| Box::pin(async {}))) {
                stop().await;
            }
            w.look_up(async { "zu".to_owned() }, |v| {
                adopted.lock().unwrap().push(v)
            })
            .await;
            assert_eq!(*adopted.lock().unwrap(), ["folge-3"]);
        });
    }

    // Swift: StopLockTests.inTimes
    #[test]
    fn stop_lock_in_times() {
        let s = StopLock::new();
        let k = StopLock::key("a", Some("p1"));
        assert!(s.progress_allowed(&k));
        assert!(s.stop_accept(&k));
        assert!(!s.stop_accept(&k));
        assert!(!s.progress_allowed(&k));
        // Another session of the same title is free.
        assert!(s.stop_accept(&StopLock::key("a", Some("p2"))));
    }

    // Swift: StopLockTests.share
    #[test]
    fn stop_lock_share() {
        let s = StopLock::new();
        let k = StopLock::key("a", None);
        assert!(s.stop_accept(&k));
        s.stop_failed(&k);
        assert!(s.stop_accept(&k));
        s.started(&k);
        assert!(s.progress_allowed(&k));
        assert!(s.stop_accept(&k));
        assert_eq!(StopLock::key("a", None), "titel:a");
        assert_eq!(StopLock::key("a", Some("p")), "sitzung:p");
    }
}
