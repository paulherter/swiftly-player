//! Progress reporting of the player: the message type, the `Reporter` seam and the client-backed
//! reporters (`AppModel.reportStart/Progress/Stopped`, AppModel.swift:2255-2480).
//!
//! * Messages go out strictly in order (the Swift `ReportQueue`): one drain task at a time. A
//!   progress that is the newest entry of its session is replaced by the next one (coalescing), a
//!   stop takes an unsent progress of its session with it, every report has a deadline (the
//!   host's [`Sleeper`]; without one a report may take as long as the transport lets it), and the
//!   stop can be awaited ([`ReportDesk::report_and_wait`]) because the pages reload after it.
//! * `StopLock` (swiftly-rules): after a stop of a play session its late progress is dropped and
//!   a second stop is discarded.
//! * A stop that did not get through is kept as a [`PendingReport`] through [`PendingSink`]
//!   (`reportLater`), so the position survives a flight; one that did get through makes a kept
//!   position of the same title obsolete ([`PendingSink::forget`]).
//! * Before every start the capabilities are reported again (AppModel.swift:2236-2262); a failure
//!   there does not stop the start.

use std::collections::VecDeque;
use std::future::Future;
use std::marker::PhantomData;
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll, Waker};

use futures_util::future::{Either, select};
use swiftly_jellyfin::{JellyfinClient, ReportPlan, TrackIndices};
use swiftly_model::ticks_from_seconds;
use swiftly_net::HttpTransport;
use swiftly_rules::episodes_switch::StopLock;

use crate::host::{Clock, Shared, Sleeper, Spawner};

pub use swiftly_jellyfin::PendingReport;

/// Which of the three reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReportKind {
    /// `Sessions/Playing`.
    Start,
    /// `Sessions/Playing/Progress`.
    Progress {
        /// The player is paused.
        paused: bool,
    },
    /// `Sessions/Playing/Stopped`.
    Stop,
}

/// One report, as the player produces it.
#[derive(Debug, Clone, PartialEq)]
pub struct ReportMessage {
    /// Which report.
    pub kind: ReportKind,
    /// Title id.
    pub item_id: String,
    /// Session ids and delivery method.
    pub plan: ReportPlan,
    /// Position in seconds.
    pub seconds: f64,
    /// Running tracks.
    pub tracks: TrackIndices,
    /// The title's length in milliseconds, for a server that wants it in every report (Plex);
    /// `None`: the reporter's own (`PlexReporter::new`'s `duration_ms`).
    pub runtime_ms: Option<i64>,
}

/// Where the player sends its reports. Never blocks.
pub trait Reporter: Send + Sync {
    /// Takes a report; ordering is the reporter's job.
    fn report(&self, message: ReportMessage);
}

/// Keeps positions the server did not get (the stored list of `reportLater`).
pub trait PendingSink: Send + Sync {
    /// Records a position for later.
    fn record(&self, report: PendingReport);
    /// A stop of this title and account did get through: a stored position for it is outdated and
    /// must never go out (`PostReportRules.overFetches`).
    fn forget(&self, _item_id: &str, _account: &str) {}
}

/// What became of one report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReportOutcome {
    /// The server took it.
    Sent,
    /// The request failed.
    Failed,
    /// The deadline passed; the request was dropped.
    TimedOut,
    /// Never sent: progress after the stop, a double stop, or a progress the stop took with it.
    Discarded,
}

/// Six seconds: a reachable server answers in a fraction of that (`ReportQueue.preGiftDeadline`).
pub const REPORT_DEADLINE: f64 = 6.0;

/// A result that several callers can wait for (a coalesced progress keeps all its waiters).
#[derive(Clone, Default)]
struct Slot(Arc<Mutex<SlotState>>);

#[derive(Default)]
struct SlotState {
    result: Option<ReportOutcome>,
    waker: Option<Waker>,
}

impl Slot {
    fn give(&self, outcome: ReportOutcome) {
        let waker = {
            let mut s = self.0.lock().unwrap_or_else(PoisonError::into_inner);
            if s.result.is_some() {
                return;
            }
            s.result = Some(outcome);
            s.waker.take()
        };
        if let Some(w) = waker {
            w.wake();
        }
    }
}

impl Future for Slot {
    type Output = ReportOutcome;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<ReportOutcome> {
        let mut s = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        match s.result {
            Some(r) => Poll::Ready(r),
            None => {
                s.waker = Some(cx.waker().clone());
                Poll::Pending
            }
        }
    }
}

type Sending = Pin<Box<dyn Future<Output = bool> + Send>>;

/// How one report reaches a server; `true`: it got through.
trait Wire: Send + Sync {
    fn send(&self, message: ReportMessage) -> Sending;
}

struct JellyfinWire<T: HttpTransport + 'static>(Arc<JellyfinClient<Shared<T>>>);

impl<T: HttpTransport + 'static> Wire for JellyfinWire<T> {
    fn send(&self, m: ReportMessage) -> Sending {
        let client = Arc::clone(&self.0);
        Box::pin(async move {
            let ticks = ticks_from_seconds(m.seconds);
            match m.kind {
                ReportKind::Start => {
                    let _ = client.report_capabilities().await;
                    client
                        .report_start(&m.item_id, &m.plan, ticks, m.tracks)
                        .await
                        .is_ok()
                }
                ReportKind::Progress { paused } => client
                    .report_progress(&m.item_id, &m.plan, ticks, paused, m.tracks)
                    .await
                    .is_ok(),
                ReportKind::Stop => client
                    .report_stopped(&m.item_id, &m.plan, ticks)
                    .await
                    .is_ok(),
            }
        })
    }
}

struct PlexWire<T: HttpTransport + 'static> {
    client: Arc<swiftly_plex::PlexClient<Shared<T>>>,
    duration_ms: Option<i64>,
}

impl<T: HttpTransport + 'static> Wire for PlexWire<T> {
    fn send(&self, m: ReportMessage) -> Sending {
        use swiftly_plex::TimelineState;
        let client = Arc::clone(&self.client);
        let duration_ms = m.runtime_ms.or(self.duration_ms);
        Box::pin(async move {
            let state = match m.kind {
                ReportKind::Start | ReportKind::Progress { paused: false } => {
                    TimelineState::Playing
                }
                ReportKind::Progress { paused: true } => TimelineState::Paused,
                ReportKind::Stop => TimelineState::Stopped,
            };
            client
                .report_timeline(
                    &m.item_id,
                    state,
                    ticks_from_seconds(m.seconds),
                    duration_ms,
                )
                .await
                .is_ok()
        })
    }
}

struct Record {
    message: ReportMessage,
    waiting: Vec<Slot>,
}

struct Queue {
    items: VecDeque<Record>,
    draining: bool,
}

fn key_of(m: &ReportMessage) -> String {
    StopLock::key(&m.item_id, m.plan.play_session_id.as_deref())
}

struct Desk {
    wire: Box<dyn Wire>,
    account: String,
    lock: StopLock,
    pending: Arc<dyn PendingSink>,
    clock: Arc<dyn Clock>,
    timer: Option<(Arc<dyn Sleeper>, f64)>,
    queue: Mutex<Queue>,
}

impl Desk {
    /// Puts the report into the rails (`ReportQueue.inRails`). Returns `(accepted, start a drain
    /// task)`; when not accepted, `waiting` was not kept.
    fn enqueue(&self, message: ReportMessage, waiting: Option<Slot>) -> (bool, bool) {
        let key = key_of(&message);
        let mut carried = Vec::new();
        let result = {
            let mut q = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
            let mut waiters: Vec<Slot> = waiting.into_iter().collect();
            let last = q.items.iter().rposition(|r| key_of(&r.message) == key);
            let last_is_progress = last
                .is_some_and(|i| matches!(q.items[i].message.kind, ReportKind::Progress { .. }));
            match message.kind {
                ReportKind::Start => self.lock.started(&key),
                ReportKind::Progress { .. } => {
                    if !self.lock.progress_allowed(&key) {
                        return (false, false);
                    }
                    if let (true, Some(i)) = (last_is_progress, last) {
                        let old = q.items.remove(i).map(|r| r.waiting).unwrap_or_default();
                        waiters = old.into_iter().chain(waiters).collect();
                    }
                }
                ReportKind::Stop => {
                    if !self.lock.stop_accept(&key) {
                        return (false, false);
                    }
                    if let (true, Some(i)) = (last_is_progress, last) {
                        carried = q.items.remove(i).map(|r| r.waiting).unwrap_or_default();
                    }
                }
            }
            q.items.push_back(Record {
                message,
                waiting: waiters,
            });
            (true, !std::mem::replace(&mut q.draining, true))
        };
        for slot in carried {
            slot.give(ReportOutcome::Discarded);
        }
        result
    }

    async fn send_timed(&self, m: ReportMessage) -> ReportOutcome {
        let work = self.wire.send(m);
        let verdict = |ok: bool| {
            if ok {
                ReportOutcome::Sent
            } else {
                ReportOutcome::Failed
            }
        };
        match &self.timer {
            None => verdict(work.await),
            Some((sleeper, seconds)) => match select(work, sleeper.sleep(*seconds)).await {
                Either::Left((ok, _)) => verdict(ok),
                Either::Right(_) => ReportOutcome::TimedOut,
            },
        }
    }

    async fn drain(self: Arc<Self>) {
        loop {
            let next = {
                let mut q = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
                let next = q.items.pop_front();
                if next.is_none() {
                    q.draining = false;
                }
                next
            };
            let Some(record) = next else { return };
            let m = record.message;
            let (kind, item, key) = (m.kind, m.item_id.clone(), key_of(&m));
            let ticks = ticks_from_seconds(m.seconds);
            let outcome = self.send_timed(m).await;
            if kind == ReportKind::Stop {
                if outcome == ReportOutcome::Sent {
                    self.pending.forget(&item, &self.account);
                } else {
                    // Release, so that a later stop tries again; the position survives a flight.
                    self.lock.stop_failed(&key);
                    self.pending.record(PendingReport::new(
                        &item,
                        &self.account,
                        ticks,
                        self.clock.now(),
                    ));
                }
            }
            for slot in record.waiting {
                slot.give(outcome);
            }
        }
    }
}

/// The queue every player report goes through, for any server kind.
pub struct ReportDesk {
    desk: Arc<Desk>,
    spawner: Arc<dyn Spawner>,
}

impl ReportDesk {
    fn make(
        wire: Box<dyn Wire>,
        account: &str,
        spawner: Arc<dyn Spawner>,
        clock: Arc<dyn Clock>,
        pending: Arc<dyn PendingSink>,
    ) -> Self {
        Self {
            desk: Arc::new(Desk {
                wire,
                account: account.to_owned(),
                lock: StopLock::new(),
                pending,
                clock,
                timer: None,
                queue: Mutex::new(Queue {
                    items: VecDeque::new(),
                    draining: false,
                }),
            }),
            spawner,
        }
    }

    /// The queue of a Jellyfin or Emby account.
    pub fn jellyfin<T: HttpTransport + 'static>(
        client: Arc<JellyfinClient<Shared<T>>>,
        account: &str,
        spawner: Arc<dyn Spawner>,
        clock: Arc<dyn Clock>,
        pending: Arc<dyn PendingSink>,
    ) -> Self {
        Self::make(
            Box::new(JellyfinWire(client)),
            account,
            spawner,
            clock,
            pending,
        )
    }

    /// The queue of a Plex account; `duration_ms` is the title's length, if known.
    pub fn plex<T: HttpTransport + 'static>(
        client: Arc<swiftly_plex::PlexClient<Shared<T>>>,
        account: &str,
        duration_ms: Option<i64>,
        spawner: Arc<dyn Spawner>,
        clock: Arc<dyn Clock>,
        pending: Arc<dyn PendingSink>,
    ) -> Self {
        let wire = PlexWire {
            client,
            duration_ms,
        };
        Self::make(Box::new(wire), account, spawner, clock, pending)
    }

    /// Every report gets `seconds` ([`REPORT_DEADLINE`], the old `preGiftDeadline`) before it is
    /// dropped and the next one goes.
    #[must_use]
    pub fn with_deadline(mut self, sleeper: Arc<dyn Sleeper>, seconds: f64) -> Self {
        if let Some(desk) = Arc::get_mut(&mut self.desk) {
            desk.timer = Some((sleeper, seconds));
        }
        self
    }

    fn start_drain(&self, trigger: bool) {
        if trigger {
            self.spawner.spawn(Box::pin(Arc::clone(&self.desk).drain()));
        }
    }

    /// Enqueues and returns at once. `false`: discarded.
    pub fn enqueue(&self, message: ReportMessage) -> bool {
        let (accepted, trigger) = self.desk.enqueue(message, None);
        self.start_drain(trigger);
        accepted
    }

    /// Enqueues and waits until exactly this report is through or its deadline has passed. A
    /// progress replaced by a newer one gets the newer one's result.
    pub async fn report_and_wait(&self, message: ReportMessage) -> ReportOutcome {
        let slot = Slot::default();
        let (accepted, trigger) = self.desk.enqueue(message, Some(slot.clone()));
        if !accepted {
            return ReportOutcome::Discarded;
        }
        self.start_drain(trigger);
        slot.await
    }

    /// May progress still be reported for this session (`StopLock::key`)?
    pub fn progress_allowed(&self, key: &str) -> bool {
        self.desk.lock.progress_allowed(key)
    }
}

impl Reporter for ReportDesk {
    fn report(&self, m: ReportMessage) {
        self.enqueue(m);
    }
}

/// The reporter that talks to a Jellyfin client.
pub struct ClientReporter<T: HttpTransport + 'static> {
    desk: ReportDesk,
    _transport: PhantomData<fn() -> T>,
}

impl<T: HttpTransport + 'static> ClientReporter<T> {
    /// A reporter for one account.
    pub fn new(
        client: Arc<JellyfinClient<Shared<T>>>,
        account: &str,
        spawner: Arc<dyn Spawner>,
        clock: Arc<dyn Clock>,
        pending: Arc<dyn PendingSink>,
    ) -> Self {
        Self {
            desk: ReportDesk::make(
                Box::new(JellyfinWire(client)),
                account,
                spawner,
                clock,
                pending,
            ),
            _transport: PhantomData,
        }
    }

    /// See [`ReportDesk::with_deadline`].
    #[must_use]
    pub fn with_deadline(mut self, sleeper: Arc<dyn Sleeper>, seconds: f64) -> Self {
        self.desk = self.desk.with_deadline(sleeper, seconds);
        self
    }

    /// The queue itself (waiting for a stop, asking the stop lock).
    pub fn desk(&self) -> &ReportDesk {
        &self.desk
    }
}

impl<T: HttpTransport + 'static> Reporter for ClientReporter<T> {
    fn report(&self, m: ReportMessage) {
        self.desk.enqueue(m);
    }
}

/// The reporter that talks to a Plex server (`POST /:/timeline`): same order, coalescing, deadline,
/// stop lock and kept stops as [`ClientReporter`]; Plex has no capabilities report.
pub struct PlexReporter<T: HttpTransport + 'static> {
    desk: ReportDesk,
    _transport: PhantomData<fn() -> T>,
}

impl<T: HttpTransport + 'static> PlexReporter<T> {
    /// A reporter for one account; `duration_ms` is the title's length, if known.
    pub fn new(
        client: Arc<swiftly_plex::PlexClient<Shared<T>>>,
        account: &str,
        duration_ms: Option<i64>,
        spawner: Arc<dyn Spawner>,
        clock: Arc<dyn Clock>,
        pending: Arc<dyn PendingSink>,
    ) -> Self {
        Self {
            desk: ReportDesk::make(
                Box::new(PlexWire {
                    client,
                    duration_ms,
                }),
                account,
                spawner,
                clock,
                pending,
            ),
            _transport: PhantomData,
        }
    }

    /// See [`ReportDesk::with_deadline`].
    #[must_use]
    pub fn with_deadline(mut self, sleeper: Arc<dyn Sleeper>, seconds: f64) -> Self {
        self.desk = self.desk.with_deadline(sleeper, seconds);
        self
    }

    /// The queue itself.
    pub fn desk(&self) -> &ReportDesk {
        &self.desk
    }
}

impl<T: HttpTransport + 'static> Reporter for PlexReporter<T> {
    fn report(&self, m: ReportMessage) {
        self.desk.enqueue(m);
    }
}
