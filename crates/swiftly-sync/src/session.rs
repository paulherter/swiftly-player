//! The SyncPlay session (`SyncPlaySession.swift`) as a sans-IO state machine.
//!
//! The Swift actor owned tasks, sleeps and a live player. Here every input is a method that takes
//! the current time (`f64`, seconds since 1970) and returns the [`Effect`]s the platform must
//! execute: server calls, player steps, title loading, status changes. The platform
//!
//! 1. feeds control-channel messages with [`SyncPlaySession::accept`],
//! 2. keeps the player snapshot fresh with [`SyncPlaySession::update_player`],
//! 3. calls [`SyncPlaySession::poll`] when [`SyncPlaySession::next_deadline`] is due (and
//!    [`SyncPlaySession::player_tick`] once per player tick),
//! 4. reports call results back (`call_done`, `call_failed`, `time_measured`, ...).

use swiftly_net::ErrorKind;

use crate::api::SyncPlayCall;
use crate::syncplay::{
    BufferGuard, BufferMessage, CommandArt, Phase, QueueRecord, Reading, Step, SyncPlayCommand,
    SyncPlayExecution, SyncPlayGroup, SyncPlayPostDirection, SyncPlayQueue, SyncPlayRight,
    TimeReconcile,
};

/// Timing constants (the Swift `patience` tuple and the fixed delays).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Patience {
    /// How long to wait for the channel to come back after a drop.
    pub conduit: f64,
    /// Rejoin attempts.
    pub attempts: u32,
    /// How long to wait for the join confirmation.
    pub answer: f64,
    /// Pause between attempts.
    pub pause: f64,
}

impl Default for Patience {
    fn default() -> Self {
        Self {
            conduit: 60.0,
            attempts: 3,
            answer: 5.0,
            pause: 2.0,
        }
    }
}

/// What the player provides: its current state (read when the platform ticks).
#[derive(Debug, Clone, PartialEq)]
pub struct PlayerView {
    /// Jellyfin id of the title playing right now.
    pub title: String,
    /// Is the picture up and no title being switched?
    pub ready: bool,
    /// Position in seconds.
    pub spot: f64,
}

/// A step for the player.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PlayerAction {
    /// Resume.
    Proceed,
    /// Pause.
    Halt,
    /// Seek (updates timeline and button right away).
    Jump(f64),
}

/// A short notice at the top of the player.
#[derive(Debug, Clone, PartialEq)]
pub enum EventArt {
    /// `{name} ist dabei`.
    Present(String),
    /// `{name} ist gegangen`.
    Gone(String),
    /// `Wartet auf alle`.
    WaitsOnAll,
    /// `Angehalten`.
    Halted,
    /// `Geht weiter`.
    GoesNext,
    /// `Gesprungen`.
    Jumped,
    /// Someone lacks the title.
    NoAccess,
    /// The title cannot be played here.
    NotPlayable,
}

/// An event with an id (new each time, so identical notices still re-trigger).
#[derive(Debug, Clone, PartialEq)]
pub struct SyncPlayEvent {
    /// Increasing id.
    pub id: u64,
    /// What happened.
    pub art: EventArt,
}

impl SyncPlayEvent {
    /// German wording (the l10n keys are the German text).
    pub fn text(&self) -> String {
        match &self.art {
            EventArt::Present(n) => format!("{n} ist dabei"),
            EventArt::Gone(n) => format!("{n} ist gegangen"),
            EventArt::WaitsOnAll => "Wartet auf alle".into(),
            EventArt::Halted => "Angehalten".into(),
            EventArt::GoesNext => "Geht weiter".into(),
            EventArt::Jumped => "Gesprungen".into(),
            EventArt::NoAccess => "Einem in der Gruppe fehlt dieser Titel.".into(),
            EventArt::NotPlayable => "Der Titel der Gruppe lässt sich hier nicht abspielen.".into(),
        }
    }
}

/// What went wrong, as a message for the view.
#[derive(Debug, Clone, PartialEq)]
pub enum SyncPlayError {
    /// 403: not enabled for this account.
    NotReleased,
    /// Nothing came back over the control channel.
    NoResponse,
    /// The group is gone.
    DoesNotExist,
    /// Dropped and rejoining failed.
    ConnectionLost,
    /// Anything else.
    Other(ErrorKind),
}

impl SyncPlayError {
    /// `SyncPlayError.from`.
    pub fn from_error(error: ErrorKind) -> Self {
        if matches!(error, ErrorKind::Http { status: 403, .. }) {
            Self::NotReleased
        } else {
            Self::Other(error)
        }
    }

    /// German wording; `Other` gives a developer-readable line (wording lives in l10n).
    pub fn text(&self) -> String {
        match self {
            Self::NotReleased => "Gemeinsam schauen ist für dein Konto auf dem Server nicht freigegeben.".into(),
            Self::NoResponse => "Die Gruppe kam nicht zustande: vom Server kam keine Antwort über die Verbindung. Versuch es gleich noch einmal.".into(),
            Self::DoesNotExist => "Diese Gruppe gibt es nicht mehr.".into(),
            Self::ConnectionLost => "Die Verbindung zur Gruppe ist abgerissen und ließ sich nicht wiederherstellen. Tritt der Gruppe bitte erneut bei.".into(),
            Self::Other(e) => format!("{e:?}"),
        }
    }
}

/// Everything the UI shows of the group.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SyncPlayStatus {
    /// The account's right (`None` until known).
    pub rights: Option<SyncPlayRight>,
    /// Groups you are not in.
    pub offerings: Vec<SyncPlayGroup>,
    /// The group you are in.
    pub group: Option<SyncPlayGroup>,
    /// Its state.
    pub condition: Option<Phase>,
    /// A notice, for three seconds.
    pub event: Option<SyncPlayEvent>,
    /// The group just left (for "Rejoin"), eight seconds.
    pub last_leave: Option<SyncPlayGroup>,
    /// Creating or joining is in progress.
    pub works: bool,
    /// What the group watches (item id).
    pub queue_title: Option<String>,
}

impl SyncPlayStatus {
    /// May create (true while unknown).
    pub fn may_create(&self) -> bool {
        self.rights.is_none_or(SyncPlayRight::may_create)
    }

    /// May join (true while unknown).
    pub fn may_join(&self) -> bool {
        self.rights.is_none_or(SyncPlayRight::may_join)
    }

    /// Does this title belong to what the group watches?
    pub fn belongs_group(&self, title: &str) -> bool {
        self.group.is_some()
            && self
                .queue_title
                .as_deref()
                .is_some_and(|q| crate::syncplay::same_name(q, title))
    }
}

/// Something for the platform to do.
#[derive(Debug, Clone, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum Effect {
    /// Execute a server call and report the result. `previous_account`: use the client of the
    /// account just left (leaving on logout / account switch).
    Api {
        /// The call.
        call: SyncPlayCall,
        /// Use the previous account's client.
        previous_account: bool,
    },
    /// A player step.
    Player(PlayerAction),
    /// Load a title (switch in the open player or open it); report `title_load_failed` if it
    /// cannot be played here.
    LoadTitle {
        /// Item id.
        title: String,
        /// Start in seconds.
        since: f64,
    },
    /// The status changed.
    Status(SyncPlayStatus),
    /// An error for the view.
    Error(SyncPlayError),
}

struct LoadWait {
    entry: String,
    until: f64,
    next: f64,
}

struct Planned {
    exec: SyncPlayExecution,
    at: f64,
}

struct JumpWait {
    target: f64,
    before: f64,
    deadline: f64,
    next: f64,
}

struct Reenter {
    target: SyncPlayGroup,
    attempt: u32,
    /// `Some(t)`: join answer awaited until `t`; `None`: a join must be sent at `resume_at`.
    answer_until: Option<f64>,
    resume_at: f64,
}

/// The session.
pub struct SyncPlaySession {
    status: SyncPlayStatus,
    emitted: Option<SyncPlayStatus>,
    out: Vec<Effect>,
    /// Timing knobs (shorter in tests).
    pub patience: Patience,
    self_name: Option<String>,
    reconcile: TimeReconcile,
    queue: Option<SyncPlayQueue>,
    last_command: Option<SyncPlayCommand>,
    buffer: BufferGuard,
    loaded_for: Option<String>,
    loaded_since: f64,
    last_jump_target: Option<f64>,
    last_requested: f64,
    view: Option<PlayerView>,
    attached: bool,
    command_number: u64,
    lost_out: Option<SyncPlayGroup>,
    line_deadline: Option<f64>,
    reenter: Option<Reenter>,
    planned: Option<Planned>,
    jump_wait: Option<JumpWait>,
    ready_at: Option<f64>,
    load_wait: Option<LoadWait>,
    channel_check_at: Option<f64>,
    event_until: Option<f64>,
    leave_until: Option<f64>,
    measure: Option<(f64, usize)>,
    measure_in_flight: bool,
    event_counter: u64,
    pending_join: Option<String>,
    last_now: f64,
}

impl Default for SyncPlaySession {
    fn default() -> Self {
        Self::new()
    }
}

impl SyncPlaySession {
    /// A session without group.
    pub fn new() -> Self {
        Self {
            status: SyncPlayStatus::default(),
            emitted: None,
            out: Vec::new(),
            patience: Patience::default(),
            self_name: None,
            reconcile: TimeReconcile::new(),
            queue: None,
            last_command: None,
            buffer: BufferGuard::new(),
            loaded_for: None,
            loaded_since: f64::NEG_INFINITY,
            last_jump_target: None,
            last_requested: f64::NEG_INFINITY,
            view: None,
            attached: false,
            command_number: 0,
            lost_out: None,
            line_deadline: None,
            reenter: None,
            planned: None,
            jump_wait: None,
            ready_at: None,
            load_wait: None,
            channel_check_at: None,
            event_until: None,
            leave_until: None,
            measure: None,
            measure_in_flight: false,
            event_counter: 0,
            pending_join: None,
            last_now: 0.0,
        }
    }

    /// The current status.
    pub fn status(&self) -> &SyncPlayStatus {
        &self.status
    }

    /// The clock measurements.
    pub fn reconcile(&self) -> &TimeReconcile {
        &self.reconcile
    }

    /// The name of the signed-in user (to ignore one's own join/leave notices).
    pub fn set_self_name(&mut self, name: Option<&str>) {
        self.self_name = name.map(str::to_string);
    }

    /// Is the player running in the group?
    pub fn in_player(&self) -> bool {
        self.status.group.is_some() && self.attached
    }

    fn finish_effects(&mut self) -> Vec<Effect> {
        if self.emitted.as_ref() != Some(&self.status) {
            self.emitted = Some(self.status.clone());
            let s = self.status.clone();
            self.out.push(Effect::Status(s));
        }
        std::mem::take(&mut self.out)
    }

    fn api(&mut self, call: SyncPlayCall) {
        self.out.push(Effect::Api {
            call,
            previous_account: false,
        });
    }

    fn fail(&mut self, e: SyncPlayError) {
        self.out.push(Effect::Error(e));
    }

    fn report(&mut self, art: EventArt, now: f64) {
        self.event_counter += 1;
        self.status.event = Some(SyncPlayEvent {
            id: self.event_counter,
            art,
        });
        self.event_until = Some(now + 3.0);
    }

    // ---- start and end ----

    /// Ask for the account's right once after login.
    pub fn right_fetch(&mut self) -> Vec<Effect> {
        self.api(SyncPlayCall::Right);
        self.finish_effects()
    }

    /// Ask for groups (on the platform's tick, not while the player runs).
    pub fn offerings_ask(&mut self) -> Vec<Effect> {
        if self.status.may_join() {
            self.api(SyncPlayCall::List);
        }
        self.finish_effects()
    }

    /// Groups arrived.
    pub fn offerings_loaded(&mut self, all: Vec<SyncPlayGroup>) -> Vec<Effect> {
        let own = self.status.group.as_ref().map(|g| g.id.clone());
        self.status.offerings = all
            .into_iter()
            .filter(|g| Some(&g.id) != own.as_ref())
            .collect();
        self.finish_effects()
    }

    /// The group query failed: quiet, offerings are cleared.
    pub fn offerings_failed(&mut self) -> Vec<Effect> {
        self.status.offerings.clear();
        self.finish_effects()
    }

    /// The right arrived.
    pub fn right_loaded(&mut self, right: Option<SyncPlayRight>) -> Vec<Effect> {
        self.status.rights = right;
        self.finish_effects()
    }

    /// Logout / account switch: leave the group (with the previous account's client), forget
    /// everything.
    pub fn finish(&mut self, now: f64) -> Vec<Effect> {
        if self.status.group.is_some() {
            self.leave_inner(false, true, now);
        }
        self.measure = None;
        self.leave_until = None;
        self.event_until = None;
        self.status.last_leave = None;
        self.status.event = None;
        self.status.offerings.clear();
        self.status.rights = None;
        self.finish_effects()
    }

    /// Open a group and set the title right away. After both calls succeeded, report
    /// [`Self::accepted`]; on failure [`Self::call_failed`].
    pub fn create(&mut self, name: &str, title: &str) -> Vec<Effect> {
        if self.status.works {
            return self.finish_effects();
        }
        self.status.works = true;
        let name = name.trim();
        let name = if name.is_empty() { "Filmabend" } else { name };
        self.api(SyncPlayCall::Create {
            name: name.to_string(),
        });
        self.api(SyncPlayCall::SetNewQueue {
            titles: vec![title.to_string()],
            since: 0.0,
        });
        self.finish_effects()
    }

    /// Join a group. Report [`Self::accepted`] when the server said yes.
    pub fn join(&mut self, target: &SyncPlayGroup) -> Vec<Effect> {
        if self.status.works {
            return self.finish_effects();
        }
        self.status.works = true;
        self.pending_join = Some(target.id.clone());
        self.api(SyncPlayCall::Join {
            group: target.id.clone(),
            rejoin: false,
        });
        self.finish_effects()
    }

    /// The server accepted create/join: now the control channel must answer within five seconds.
    pub fn accepted(&mut self, now: f64) -> Vec<Effect> {
        if let Some(id) = self.pending_join.take() {
            self.status.last_leave = None;
            self.leave_until = None;
            self.status.offerings.retain(|g| g.id != id);
        }
        self.channel_check_at = Some(now + 5.0);
        if self.status.group.is_some() {
            self.status.works = false;
            self.channel_check_at = None;
        }
        self.finish_effects()
    }

    /// Closing the player means leaving the group (remembered for "Rejoin").
    pub fn leave(&mut self, now: f64) -> Vec<Effect> {
        self.leave_inner(true, false, now);
        self.finish_effects()
    }

    fn leave_inner(&mut self, remember: bool, previous_account: bool, now: f64) {
        let Some(old) = self.status.group.clone() else {
            return;
        };
        self.all_back_set();
        if remember {
            self.status.last_leave = Some(old);
            self.leave_until = Some(now + 8.0);
        }
        self.out.push(Effect::Api {
            call: SyncPlayCall::Leave,
            previous_account,
        });
    }

    /// "Rejoin" from the strip.
    pub fn again_join(&mut self) -> Vec<Effect> {
        let Some(old) = self.status.last_leave.take() else {
            return self.finish_effects();
        };
        self.leave_until = None;
        self.join(&old)
    }

    fn all_back_set(&mut self) {
        self.lost_out = None;
        self.reenter = None;
        self.line_deadline = None;
        self.status.group = None;
        self.status.condition = None;
        self.status.queue_title = None;
        self.queue = None;
        self.last_command = None;
        self.loaded_for = None;
        self.planned = None;
        self.jump_wait = None;
        self.ready_at = None;
        self.load_wait = None;
        self.measure = None;
        self.measure_in_flight = false;
        self.reconcile = TimeReconcile::new();
        self.buffer.reset();
    }

    // ---- results of calls ----

    /// A call succeeded without a result to read here (results with data have their own method).
    pub fn call_done(&mut self, _call: &SyncPlayCall) -> Vec<Effect> {
        self.finish_effects()
    }

    /// A call failed.
    pub fn call_failed(&mut self, call: &SyncPlayCall, error: ErrorKind, now: f64) -> Vec<Effect> {
        self.last_now = now;
        match call {
            SyncPlayCall::Join { rejoin: true, .. } => {
                if let Some(r) = &mut self.reenter {
                    r.answer_until = None;
                    r.resume_at = now + self.patience.pause;
                    r.attempt += 1;
                }
            }
            SyncPlayCall::Create { .. }
            | SyncPlayCall::Join { .. }
            | SyncPlayCall::SetNewQueue { .. } => {
                self.status.works = false;
                self.pending_join = None;
                self.fail(SyncPlayError::from_error(error));
            }
            SyncPlayCall::Unpause | SyncPlayCall::Pause | SyncPlayCall::Seek { .. } => {
                self.fail(SyncPlayError::from_error(error));
            }
            SyncPlayCall::ServerTime => {
                self.measure_in_flight = false;
                let count = self.measure.map_or(0, |m| m.1);
                self.measure = Some((now + TimeReconcile::pause_to_measurements(count), count));
            }
            _ => {}
        }
        self.finish_effects()
    }

    /// A clock measurement arrived: record, ping, schedule the next one.
    pub fn time_measured(&mut self, m: Reading, now: f64) -> Vec<Effect> {
        self.last_now = now;
        self.measure_in_flight = false;
        let Some((_, count)) = self.measure else {
            return self.finish_effects();
        };
        self.reconcile.record(m);
        let new = count + 1;
        self.measure = Some((now + TimeReconcile::pause_to_measurements(new), new));
        let ms = self.reconcile.ping_milliseconds();
        self.api(SyncPlayCall::Ping { milliseconds: ms });
        self.finish_effects()
    }

    /// The loader could not open the group's title here.
    pub fn title_load_failed(&mut self, now: f64) -> Vec<Effect> {
        self.load_wait = None;
        self.report(EventArt::NotPlayable, now);
        self.finish_effects()
    }

    // ---- what comes from the server ----

    /// One control-channel message, in the order they arrive.
    pub fn accept(&mut self, msg: SyncPlayPostDirection, now: f64) -> Vec<Effect> {
        self.last_now = now;
        match msg {
            SyncPlayPostDirection::Joined(g) => {
                let new = self.status.group.as_ref().map(|x| &x.id) != Some(&g.id);
                self.status.condition = g.condition;
                self.status.offerings.retain(|o| o.id != g.id);
                if self.lost_out.as_ref().is_some_and(|l| l.id == g.id) {
                    self.lost_out = None;
                }
                self.status.group = Some(g);
                self.status.works = false;
                self.channel_check_at = None;
                if new {
                    self.measure = Some((now, 0));
                }
            }
            SyncPlayPostDirection::Leave | SyncPlayPostDirection::NotInGroup => {
                if self.status.group.is_some() {
                    self.all_back_set();
                }
            }
            SyncPlayPostDirection::DoesNotExist => {
                self.all_back_set();
                self.fail(SyncPlayError::DoesNotExist);
            }
            SyncPlayPostDirection::NoAccess => self.report(EventArt::NoAccess, now),
            SyncPlayPostDirection::SomeoneJoined(name) => {
                if let Some(g) = self.status.group.clone() {
                    let mut participant = g.participant.clone();
                    participant.push(name.clone());
                    self.status.group = Some(SyncPlayGroup {
                        condition: self.status.condition,
                        participant,
                        ..g
                    });
                    if !self
                        .self_name
                        .as_deref()
                        .is_some_and(|me| crate::syncplay::same_name(&name, me))
                    {
                        self.report(EventArt::Present(name), now);
                    }
                }
            }
            SyncPlayPostDirection::SomeoneLeft(name) => {
                if let Some(g) = self.status.group.clone() {
                    let mut participant = g.participant.clone();
                    if let Some(i) = participant
                        .iter()
                        .position(|p| crate::syncplay::same_name(p, &name))
                    {
                        participant.remove(i);
                    }
                    self.status.group = Some(SyncPlayGroup {
                        condition: self.status.condition,
                        participant,
                        ..g
                    });
                    if !self
                        .self_name
                        .as_deref()
                        .is_some_and(|me| crate::syncplay::same_name(&name, me))
                    {
                        self.report(EventArt::Gone(name), now);
                    }
                }
            }
            SyncPlayPostDirection::ConnectionLost => {
                if let (Some(g), None) = (self.status.group.clone(), &self.lost_out) {
                    self.lost_out = Some(g);
                    self.line_deadline = Some(now + self.patience.conduit);
                }
            }
            SyncPlayPostDirection::ConnectionAgain => {
                if let Some(target) = self.lost_out.clone() {
                    self.line_deadline = None;
                    self.reenter = Some(Reenter {
                        target,
                        attempt: 1,
                        answer_until: None,
                        resume_at: now,
                    });
                }
            }
            SyncPlayPostDirection::Condition(new, reason) => {
                let before = self.status.condition;
                self.status.condition = Some(new);
                if new == Phase::Waits
                    && before == Some(Phase::Running)
                    && reason.as_deref() == Some("Buffer")
                {
                    self.report(EventArt::WaitsOnAll, now);
                }
            }
            SyncPlayPostDirection::Queue(w) => self.accept_queue(w, now),
            SyncPlayPostDirection::Command(b) => self.command_accept(b, now),
        }
        self.finish_effects()
    }

    fn accept_queue(&mut self, w: SyncPlayQueue, now: f64) {
        if let (Some(old), Some(new)) = (self.queue.as_ref().and_then(|q| q.state), w.state)
            && new < old
        {
            return;
        }
        let before: Option<QueueRecord> = self.queue.as_ref().and_then(|q| q.current().cloned());
        self.status.queue_title = w.current().map(|c| c.title.clone());
        let current = w.current().cloned();
        let switches = w.switches_title();
        let (start_point, running, state, reason) =
            (w.start_point, w.running, w.state, w.reason.clone());
        self.queue = Some(w);
        let (true, Some(current)) = (switches, current) else {
            return;
        };
        if Some(&current) == before.as_ref()
            && self.loaded_for.as_deref() == Some(current.entry_record.as_str())
        {
            return;
        }
        self.loaded_for = None;
        self.buffer.reset();
        let mut since = start_point;
        let last = self.last_command.clone();
        if let Some(b) = last.filter(|b| {
            b.spot.is_some()
                && b.entry_record.as_deref() == Some(current.entry_record.as_str())
                && b.emitted.unwrap_or(b.moment) >= state.unwrap_or(f64::NEG_INFINITY)
        }) {
            let spot = b.spot.unwrap_or(0.0);
            since = if b.art == CommandArt::Proceed {
                SyncPlayExecution::estimated_point(spot, b.moment, now, &self.reconcile)
            } else {
                spot
            };
        } else if let (true, Some(state)) = (running, state) {
            since = SyncPlayExecution::estimated_point(start_point, state, now, &self.reconcile);
        }
        let _ = reason;
        self.planned = None;
        // titleOpen: same title in the open player seeks, otherwise the platform loads it.
        let same = self.attached && self.view.as_ref().is_some_and(|v| v.title == current.title);
        if same {
            self.out.push(Effect::Player(PlayerAction::Jump(since)));
        } else {
            self.out.push(Effect::LoadTitle {
                title: current.title.clone(),
                since,
            });
        }
        self.load_wait = Some(LoadWait {
            entry: current.entry_record,
            until: now + 120.0,
            next: now,
        });
    }

    fn command_accept(&mut self, b: SyncPlayCommand, now: f64) {
        if self.status.group.is_none() {
            return;
        }
        self.last_command = Some(b.clone());
        let ok = self.attached
            && self.loaded_for.is_some()
            && (b.entry_record.is_none()
                || b.entry_record == self.loaded_for
                || b.art == CommandArt::Stop);
        if ok {
            self.command_start(&b, now);
        }
    }

    /// A command replaces the previous one, even if that still waits for its time.
    fn command_start(&mut self, b: &SyncPlayCommand, now: f64) {
        self.command_number += 1;
        self.planned = None;
        self.jump_wait = None;
        let Some(view) = self.view.clone() else {
            return;
        };
        let x = SyncPlayExecution::of(b, now, &self.reconcile, view.spot);
        if now - self.last_requested > 3.0 && now - self.loaded_since > 3.0 {
            match b.art {
                CommandArt::Pause => self.report(EventArt::Halted, now),
                CommandArt::Proceed => self.report(EventArt::GoesNext, now),
                CommandArt::Jump => self.report(EventArt::Jumped, now),
                CommandArt::Stop => {}
            }
        }
        // The time is fixed before seeking, since the seek itself takes time.
        if x.step == Step::Proceed
            && x.wait > 0.0
            && let Some(s) = x.spot
        {
            self.out.push(Effect::Player(PlayerAction::Jump(s)));
        }
        if x.wait > 0.0 {
            self.planned = Some(Planned {
                exec: x,
                at: now + x.wait,
            });
        } else {
            self.step_do(x, now);
        }
    }

    fn step_do(&mut self, x: SyncPlayExecution, now: f64) {
        let was_buffering = self.buffer.buffers();
        self.buffer.reset();
        let spot_now = self.view.as_ref().map_or(0.0, |v| v.spot);
        match x.step {
            Step::Proceed => {
                if x.wait == 0.0
                    && let Some(s) = x.spot
                {
                    self.out.push(Effect::Player(PlayerAction::Jump(s)));
                }
                self.out.push(Effect::Player(PlayerAction::Proceed));
            }
            Step::Pause => {
                self.out.push(Effect::Player(PlayerAction::Halt));
                if let Some(s) = x.spot {
                    self.out.push(Effect::Player(PlayerAction::Jump(s)));
                }
                // If "buffering" was reported, "ready" must follow.
                if was_buffering {
                    self.ready_at = Some(now + 0.5);
                }
            }
            Step::Jump => {
                if let Some(s) = x.spot {
                    self.out.push(Effect::Player(PlayerAction::Jump(s)));
                    self.out.push(Effect::Player(PlayerAction::Proceed));
                    self.jump_wait = Some(JumpWait {
                        target: s,
                        before: spot_now,
                        deadline: now + 10.0,
                        next: now + 0.1,
                    });
                } else {
                    self.out.push(Effect::Player(PlayerAction::Halt));
                    self.report_status(true, false, None);
                }
            }
            Step::Stop => self.out.push(Effect::Player(PlayerAction::Halt)),
        }
    }

    fn report_status(&mut self, ready: bool, running: bool, spot: Option<f64>) {
        let Some(view) = &self.view else { return };
        if !self.attached {
            return;
        }
        let Some(entry) = self.loaded_for.clone().or_else(|| {
            self.queue
                .as_ref()
                .and_then(|q| q.current())
                .map(|c| c.entry_record.clone())
        }) else {
            return;
        };
        let here = spot.unwrap_or(view.spot);
        let moment = self.reconcile.server(self.last_now);
        self.api(SyncPlayCall::State {
            ready,
            moment,
            spot: here,
            running,
            entry_record: entry,
        });
    }

    // ---- from the player ----

    /// The player is open and belongs to the group.
    pub fn plug_in(&mut self, view: PlayerView) -> Vec<Effect> {
        self.attached = true;
        self.view = Some(view);
        self.finish_effects()
    }

    /// The current player state (before `poll`, `player_tick` and `accept`).
    pub fn update_player(&mut self, view: PlayerView) {
        self.view = Some(view);
    }

    /// The player closes. That is leaving.
    pub fn detach(&mut self, now: f64) -> Vec<Effect> {
        self.attached = false;
        self.view = None;
        self.leave(now)
    }

    /// Pause or resume as a request; the button flips when the command comes back.
    pub fn bit_toggle(&mut self, running_currently: bool, now: f64) -> Vec<Effect> {
        self.last_requested = now;
        self.api(if running_currently {
            SyncPlayCall::Pause
        } else {
            SyncPlayCall::Unpause
        });
        self.finish_effects()
    }

    /// Seek as a request.
    pub fn bit_jump(&mut self, seconds: f64, now: f64) -> Vec<Effect> {
        self.last_requested = now;
        self.api(SyncPlayCall::Seek { seconds });
        self.finish_effects()
    }

    /// A different title (episode) for everyone.
    pub fn bit_title(&mut self, title: &str, since: f64, now: f64) -> Vec<Effect> {
        self.last_requested = now;
        self.api(SyncPlayCall::SetNewQueue {
            titles: vec![title.to_string()],
            since,
        });
        self.finish_effects()
    }

    /// Once per player tick: report buffering. (No drift correction while running, like
    /// jellyfin-web: it looped with the buffering report.)
    pub fn player_tick(&mut self, now: f64) -> Vec<Effect> {
        self.last_now = now;
        if let (true, Some(view), Some(_), Some(_)) = (
            self.attached,
            self.view.clone(),
            self.loaded_for.as_ref(),
            self.status.group.as_ref(),
        ) {
            let should = self.last_command.as_ref().is_some_and(|c| {
                c.art == CommandArt::Proceed && self.reconcile.local_only(c.moment) <= now
            });
            if let Some(message) = self.buffer.tick(view.spot, should, now) {
                self.report_status(message == BufferMessage::Ready, true, None);
            }
        }
        self.finish_effects()
    }

    // ---- time ----

    /// When `poll` next has something to do.
    pub fn next_deadline(&self) -> Option<f64> {
        let mut c: Vec<f64> = Vec::new();
        c.extend(self.channel_check_at);
        c.extend(self.event_until);
        c.extend(self.leave_until);
        c.extend(self.line_deadline);
        if !self.measure_in_flight {
            c.extend(self.measure.map(|m| m.0));
        }
        if let Some(r) = &self.reenter {
            c.push(r.answer_until.unwrap_or(r.resume_at));
        }
        c.extend(self.load_wait.as_ref().map(|l| l.next));
        c.extend(self.planned.as_ref().map(|p| p.at));
        c.extend(self.jump_wait.as_ref().map(|j| j.next));
        c.extend(self.ready_at);
        c.into_iter().reduce(f64::min)
    }

    /// Runs everything that is due at `now`.
    pub fn poll(&mut self, now: f64) -> Vec<Effect> {
        self.last_now = now;
        if self.channel_check_at.is_some_and(|t| now >= t) {
            self.channel_check_at = None;
            if self.status.group.is_none() {
                // No GroupJoined within 5 s: the channel is mute. Leave right away and say so.
                self.api(SyncPlayCall::Leave);
                self.fail(SyncPlayError::NoResponse);
            }
            self.status.works = false;
        }
        if self.event_until.is_some_and(|t| now >= t) {
            self.event_until = None;
            self.status.event = None;
        }
        if self.leave_until.is_some_and(|t| now >= t) {
            self.leave_until = None;
            self.status.last_leave = None;
        }
        if let (false, Some((at, _))) = (self.measure_in_flight, self.measure)
            && now >= at
            && self.status.group.is_some()
        {
            self.measure_in_flight = true;
            self.api(SyncPlayCall::ServerTime);
        }
        if self.line_deadline.is_some_and(|t| now >= t) {
            self.line_deadline = None;
            self.again_entry_failed();
        }
        self.poll_reenter(now);
        self.poll_load_wait(now);
        if self.planned.as_ref().is_some_and(|p| now >= p.at)
            && let Some(p) = self.planned.take()
        {
            self.step_do(
                SyncPlayExecution {
                    wait: 0.0,
                    ..p.exec
                },
                now,
            );
        }
        self.poll_jump_wait(now);
        if self.ready_at.is_some_and(|t| now >= t) {
            self.ready_at = None;
            self.report_status(true, false, None);
        }
        self.finish_effects()
    }

    fn again_entry_failed(&mut self) {
        if self.lost_out.is_none() {
            return;
        }
        self.all_back_set();
        self.fail(SyncPlayError::ConnectionLost);
    }

    fn poll_reenter(&mut self, now: f64) {
        let Some((answer_until, resume_at, attempt, target)) = self
            .reenter
            .as_ref()
            .map(|r| (r.answer_until, r.resume_at, r.attempt, r.target.id.clone()))
        else {
            return;
        };
        if self.lost_out.is_none() {
            // Joined again: report the state if a player is loaded.
            let had_player = self.attached && self.loaded_for.is_some();
            self.reenter = None;
            if had_player {
                let running = self.status.condition == Some(Phase::Running);
                self.report_status(true, running, None);
            }
            return;
        }
        match answer_until {
            None if now >= resume_at => {
                if attempt > self.patience.attempts.max(1) {
                    self.reenter = None;
                    self.again_entry_failed();
                    return;
                }
                if let Some(r) = &mut self.reenter {
                    r.answer_until = Some(now + self.patience.answer);
                }
                self.api(SyncPlayCall::Join {
                    group: target,
                    rejoin: true,
                });
            }
            Some(t) if now >= t => {
                // No confirmation: next attempt.
                if let Some(r) = &mut self.reenter {
                    r.attempt += 1;
                    r.answer_until = None;
                    r.resume_at = now;
                }
                self.poll_reenter(now);
            }
            _ => {}
        }
    }

    fn poll_load_wait(&mut self, now: f64) {
        let Some(l) = &mut self.load_wait else { return };
        if now < l.next {
            return;
        }
        if now >= l.until {
            self.load_wait = None;
            return;
        }
        l.next = now + 0.2;
        let entry = l.entry.clone();
        if self.attached && self.view.as_ref().is_some_and(|v| v.ready) {
            self.load_wait = None;
            self.out.push(Effect::Player(PlayerAction::Halt));
            self.loaded_for = Some(entry.clone());
            self.loaded_since = now;
            self.report_status(true, false, None);
            // A command that already came while still loading.
            if let Some(b) = self
                .last_command
                .clone()
                .filter(|b| b.entry_record.as_deref() == Some(entry.as_str()))
            {
                self.command_start(&b, now);
            }
        }
    }

    fn poll_jump_wait(&mut self, now: f64) {
        let Some(j) = &mut self.jump_wait else { return };
        if now < j.next {
            return;
        }
        let cur = self.view.as_ref().map_or(0.0, |v| v.spot);
        let runs = cur > j.before + 0.02 && (cur - j.target).abs() < 3.0;
        j.before = cur;
        j.next = now + 0.1;
        if !(runs || now >= j.deadline) {
            return;
        }
        let target = j.target;
        self.jump_wait = None;
        self.out.push(Effect::Player(PlayerAction::Halt));
        // If the same seek arrives a second time, the server already rejected the measured
        // position once; then use the target, otherwise it would go in circles.
        let repeated = self
            .last_jump_target
            .is_some_and(|t| (t - target).abs() < 0.01);
        self.last_jump_target = Some(target);
        let message = if repeated {
            target
        } else {
            SyncPlayExecution::ready_point(target, cur)
        };
        self.report_status(true, false, Some(message));
    }
}
