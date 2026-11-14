//! Watching together (SyncPlay), the Jellyfin remote control and "Übergeben an …" / "Weiterschauen auf anderem Gerät"
//! on the desktop, over the same shared core as the Mac, iOS and Android hosts (`SharedModel.swift`,
//! `TakeoverModel.swift`, `RemoteController`, `PlayOutputs`).
//!
//! The rules are not written here: the group session is `swiftly_sync::SyncPlaySession` behind the sheet model
//! `swiftly_vm::SharedVm`, the control channel is `swiftly_sync::RemoteControl`, the takeover rules are
//! `swiftly_playback::takeover`. This file is the host of those: one worker thread runs the server calls (over the
//! app's own `AppTransport`, like every other call), one socket thread keeps `/socket` up, and the UI thread reads
//! [`Hub::view`] and drains [`Hub::take_events`] once per frame. Nothing here blocks the UI thread but short locks.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use swiftly_jellyfin::{ForeignCommand, OwnHeaders, RemoteSession};
use swiftly_net::{ErrorKind, Url};
use swiftly_playback::handoff_flow::{SETTLE_STEP_MS, SETTLE_TRIES, TICK_SECONDS};
use swiftly_playback::takeover::{self, TakeoverEvent};
use swiftly_sync::{
    CallResult, Effect, KEEP_ALIVE, KEEP_ALIVE_INTERVAL, LinkError, PlayOrder, PlayerAction,
    PlayerView, RemoteCommand, RemoteControl, RemoteOutput, ServerCtx, SyncPlayCall,
    SyncPlayClient, SyncPlayPostDirection,
};
use swiftly_vm::{AccountRef, GroupHook, Shared, SharedIntent, SharedPart, SharedVm, TakeoverPart};

use crate::live::Core;
use crate::net::AppTransport;
use crate::together_socket::Link;

/// Seconds without a frame after which a link counts as dead (the Mac's channel does the same).
const SILENCE: Duration = Duration::from_secs(90);

/// What the UI thread has to act on.
#[derive(Debug, Clone, PartialEq)]
pub enum HubEvent {
    /// The group moves the player (`at`: the moment the step was due).
    Step {
        /// What to do.
        action: PlayerAction,
        /// When the step came up.
        at: Instant,
    },
    /// The group watches another title (episode): open it at `since`.
    LoadTitle {
        /// The title's id.
        title: String,
        /// Where to start.
        since: f64,
    },
    /// Another device controls this player over the socket.
    Command(RemoteCommand),
    /// A stop that belongs to a takeover (the hint came just before): the picture leaves as a card.
    TakenOver {
        /// The name of the device that takes over.
        device: String,
    },
    /// "Play on this device" from another Jellyfin client.
    Play(PlayOrder),
    /// A takeover on this device is through: play `item_id` from `since`.
    StartHere {
        /// The title.
        item_id: String,
        /// The position the other device had reached.
        since: f64,
    },
    /// The other device took the title over: this player leaves.
    HandedOver {
        /// The device's name.
        device: String,
    },
    /// Handing over did not work; the player goes on here.
    HandOverFailed {
        /// What to tell the user.
        message: String,
    },
}

/// One device a title can be sent to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    /// The device's id.
    pub device_id: String,
    /// What the menu calls it.
    pub name: String,
}

/// The line at the top of the player ("A ist dabei").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventLine {
    /// Grows with every event; the view restarts its fade on a new one.
    pub id: u64,
    /// The icon.
    pub symbol: &'static str,
    /// The words.
    pub text: String,
}

/// What the player and the shell draw of the group and the devices.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct View {
    /// Name of the group and "mit A und B", when in one.
    pub group: Option<(String, String)>,
    /// Everyone in the group as the server names them.
    pub participants: Vec<String>,
    /// The latest event of the group.
    pub event: Option<EventLine>,
    /// The error strip text and its number (a new number restarts the 4 s).
    pub error: Option<(u64, String)>,
    /// The devices a title can go to.
    pub targets: Vec<Target>,
}

/// What `Mac SharedModel.symbol` maps to, in the names of the desktop glyph set.
fn symbol(kind: &str) -> &'static str {
    match kind {
        "dabei" | "gegangen" => "users",
        "wartet" => "hourglass",
        "angehalten" => "pause",
        "weiter" => "play",
        "gesprungen" => "arrows-left-right",
        _ => "warning",
    }
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

struct WallClock;

impl swiftly_sync::Clock for WallClock {
    fn now(&self) -> f64 {
        now()
    }
}

/// What the worker thread does.
enum Job {
    /// Server calls and steps of the session.
    Effects(Vec<Effect>),
    /// `POST Sessions/Capabilities/Full` (the socket came up).
    Capabilities,
    /// Take over the session with this id.
    Adopt(String),
    /// Send the running title to this device.
    HandOver(HandOver),
    /// Start a title on another device (tile menu "Abspielen auf …").
    PlayOn {
        item_id: String,
        device_id: String,
        position: Option<f64>,
    },
    /// Ask for the sessions once now.
    Poll,
    Stop,
}

/// The running title as the other device must start it (`PlayOrder` of the Mac).
#[derive(Debug, Clone, PartialEq)]
pub struct HandOver {
    /// The device to send it to.
    pub device_id: String,
    /// The title.
    pub item_id: String,
    /// The position to start at.
    pub position: f64,
    /// The version that plays here.
    pub source_id: Option<String>,
    /// The audio track that plays here (server index).
    pub audio: Option<i64>,
    /// The subtitle track that plays here (server index, `-1` off).
    pub subtitle: Option<i64>,
}

struct Inner {
    core: Arc<Core>,
    account: AccountRef,
    vm: Mutex<SharedVm>,
    client: SyncPlayClient<Shared<AppTransport>, WallClock>,
    jobs: Sender<Job>,
    events: Mutex<VecDeque<HubEvent>>,
    targets: Mutex<Vec<RemoteSession>>,
    error: Mutex<Option<(u64, String)>>,
    seen_errors: Mutex<u64>,
    hint: Mutex<Option<(String, Instant)>>,
    player_open: AtomicBool,
    stopped: AtomicBool,
    log: Mutex<Vec<String>>,
    /// Wakes the clock thread when the session may have set a new deadline.
    wake: (Mutex<()>, Condvar),
}

/// The hub of one signed-in account.
pub struct Hub {
    inner: Arc<Inner>,
}

impl Hub {
    /// A hub for `account`; nothing connects before [`Hub::start`].
    ///
    /// # Errors
    /// The address of the account is not one.
    pub fn new(
        core: &Arc<Core>,
        account: &AccountRef,
        self_name: Option<&str>,
    ) -> Result<Hub, ErrorKind> {
        let client = core.client_for(account)?;
        let base = Url::parse(&account.base_url).ok();
        let mut headers: Vec<(String, String)> = base
            .as_ref()
            .map(|u| {
                OwnHeaders::of(u)
                    .into_iter()
                    .map(|h| (h.name, h.value))
                    .collect()
            })
            .unwrap_or_default();
        headers.push(("Authorization".into(), client.authorization_header()));
        headers.push(("Accept".into(), "application/json".into()));
        let ctx = ServerCtx {
            base: account.base_url.clone(),
            user_id: account.user_id.clone(),
            headers,
        };
        let vm = SharedVm::new(
            core.host().locale,
            self_name,
            &account.device_id,
            &account.user_id,
        );
        let (jobs, queue) = channel();
        let inner = Arc::new(Inner {
            core: Arc::clone(core),
            account: account.clone(),
            vm: Mutex::new(vm),
            client: SyncPlayClient::new(Shared(Arc::clone(&core.net)), WallClock, ctx),
            jobs,
            events: Mutex::new(VecDeque::new()),
            targets: Mutex::new(Vec::new()),
            error: Mutex::new(None),
            seen_errors: Mutex::new(0),
            hint: Mutex::new(None),
            player_open: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            log: Mutex::new(Vec::new()),
            wake: (Mutex::new(()), Condvar::new()),
        });
        let clock = Arc::downgrade(&inner);
        std::thread::Builder::new()
            .name("swiftly-together-clock".into())
            .spawn(move || Inner::clock(&clock))
            .map_err(|e| ErrorKind::Decoding(e.to_string()))?;
        let worker = Arc::clone(&inner);
        std::thread::Builder::new()
            .name("swiftly-together".into())
            .spawn(move || worker.work(&queue))
            .map_err(|e| ErrorKind::Decoding(e.to_string()))?;
        Ok(Hub { inner })
    }

    /// Opens the control channel and starts asking for the other devices. Calling it twice does nothing more.
    pub fn start(&self) {
        let me = Arc::clone(&self.inner);
        if me.stopped.swap(false, Ordering::SeqCst) {
            // a restart after `stop`: the worker ended, so there is nothing to join; callers build a new hub instead
            return;
        }
        let _ = self.inner.jobs.send(Job::Poll);
        let _ = self.inner.jobs.send(Job::Effects({
            let mut vm = lock(&self.inner.vm);
            vm.session_mut().right_fetch()
        }));
        let socket = Arc::clone(&self.inner);
        let _ = std::thread::Builder::new()
            .name("swiftly-socket".into())
            .spawn(move || socket.socket());
    }

    /// A raw SyncPlay message of the control channel (the channel itself feeds this; tests do too).
    pub fn feed(&self, text: &str) {
        if let Some(msg) = SyncPlayPostDirection::read(text) {
            self.inner.session_accept(msg);
        }
    }

    /// Leaves the group, closes the channel and ends the threads.
    pub fn stop(&self) {
        {
            let mut vm = lock(&self.inner.vm);
            let effects = vm.session_mut().finish(now());
            drop(vm);
            self.inner.handle(effects);
        }
        self.inner.stopped.store(true, Ordering::SeqCst);
        let _ = self.inner.jobs.send(Job::Stop);
    }

    /// What the sheet draws (the groups to join, the right, the error).
    pub fn part(&self) -> SharedPart {
        lock(&self.inner.vm).part().clone()
    }

    /// What the takeover card draws, with its version.
    pub fn takeover(&self) -> (u64, TakeoverPart) {
        lock(&self.inner.vm).takeover()
    }

    /// The devices a title can go to as (device id, name), and nothing else of the view: a menu asks for them every frame.
    pub fn play_targets(&self) -> Vec<(String, String)> {
        lock(&self.inner.targets)
            .iter()
            .filter_map(|s| {
                let device_id = s.device_id.clone().filter(|d| !d.is_empty())?;
                Some((device_id, takeover::target_name(s)))
            })
            .collect()
    }

    /// Whether this account may start watching together (what the menus offer "Gemeinsam schauen" for).
    pub fn may_create(&self) -> bool {
        lock(&self.inner.vm).part().may_create
    }

    /// What the player and the shell draw.
    pub fn view(&self) -> View {
        let vm = lock(&self.inner.vm);
        let p = vm.part();
        let group = p
            .current
            .as_ref()
            .map(|c| (c.name.clone(), c.with_whom.clone()));
        let event = p
            .detail
            .notice_kind
            .as_deref()
            .zip(p.detail.notice_id)
            .and_then(|(kind, id)| {
                p.notice.clone().map(|text| EventLine {
                    id,
                    symbol: symbol(kind),
                    text,
                })
            });
        let participants = p
            .detail
            .group
            .as_ref()
            .map(|g| g.participants.clone())
            .unwrap_or_default();
        drop(vm);
        let targets = lock(&self.inner.targets)
            .iter()
            .filter_map(|s| {
                let device_id = s.device_id.clone().filter(|d| !d.is_empty())?;
                Some(Target {
                    device_id,
                    name: takeover::target_name(s),
                })
            })
            .collect();
        View {
            group,
            participants,
            event,
            error: lock(&self.inner.error).clone(),
            targets,
        }
    }

    /// Everything the UI thread has to act on, oldest first.
    pub fn take_events(&self) -> Vec<HubEvent> {
        lock(&self.inner.events).drain(..).collect()
    }

    /// Lines for the log (what the Mac prints with `print`).
    pub fn take_log(&self) -> Vec<String> {
        std::mem::take(&mut *lock(&self.inner.log))
    }

    // ---- the sheet ----

    /// Loads the right and the list of groups.
    pub fn refresh(&self) {
        self.intent(SharedIntent::Refresh);
    }

    /// Opens a group for the title (an empty name becomes "Filmabend").
    pub fn create(&self, name: &str, title_id: &str) {
        self.intent(SharedIntent::Create {
            name: name.to_owned(),
            title_id: title_id.to_owned(),
        });
    }

    /// Joins a group of the list.
    pub fn join(&self, group_id: &str) {
        self.intent(SharedIntent::Join(group_id.to_owned()));
    }

    /// Leaves the group ("Gruppe verlassen").
    pub fn leave(&self) {
        self.intent(SharedIntent::Leave);
    }

    /// Joins the group last left.
    pub fn rejoin(&self) {
        let effects = lock(&self.inner.vm).session_mut().again_join();
        self.inner.handle(effects);
    }

    /// Hides the error strip.
    pub fn dismiss_error(&self) {
        *lock(&self.inner.error) = None;
        self.intent(SharedIntent::DismissError);
    }

    fn intent(&self, intent: SharedIntent) {
        let effects = lock(&self.inner.vm).handle(intent, now());
        self.inner.handle(effects);
    }

    // ---- the player ----

    /// The player opened `title`; is it the group's title, it joins in.
    pub fn player_attached(&self, view: PlayerView) {
        self.inner.player_open.store(true, Ordering::SeqCst);
        let effects = lock(&self.inner.vm).session_mut().plug_in(view);
        self.inner.handle(effects);
    }

    /// Any player is open here: no question about other devices is asked meanwhile.
    pub fn player_open(&self, on: bool) {
        self.inner.player_open.store(on, Ordering::SeqCst);
        if !on {
            lock(&self.inner.vm).takeover_event(TakeoverEvent::Polled(Vec::new()));
            let _ = self.inner.jobs.send(Job::Poll);
        }
    }

    /// The player's state, before every tick.
    pub fn player_update(&self, view: PlayerView) {
        lock(&self.inner.vm).session_mut().update_player(view);
    }

    /// Once per player tick: reports buffering and ready to the group.
    pub fn player_tick(&self) {
        let effects = lock(&self.inner.vm).session_mut().player_tick(now());
        self.inner.handle(effects);
    }

    /// The player closed (that is leaving the group).
    pub fn player_detached(&self) {
        self.inner.player_open.store(false, Ordering::SeqCst);
        // No question about the other devices was asked while the player was open, so whatever was offered before it
        // opened may be long over: nothing is offered until a fresh answer says so.
        lock(&self.inner.vm).takeover_event(TakeoverEvent::Polled(Vec::new()));
        let _ = self.inner.jobs.send(Job::Poll);
        let effects = lock(&self.inner.vm).session_mut().detach(now());
        self.inner.handle(effects);
    }

    /// The group's title could not be opened here.
    pub fn title_load_failed(&self) {
        let effects = lock(&self.inner.vm).session_mut().title_load_failed(now());
        self.inner.handle(effects);
    }

    /// A different episode for everyone.
    pub fn request_title(&self, title: &str, since: f64) {
        let effects = lock(&self.inner.vm)
            .session_mut()
            .bit_title(title, since, now());
        self.inner.handle(effects);
    }

    /// Is the player in a group right now (then its buttons are requests)?
    pub fn in_group(&self) -> bool {
        lock(&self.inner.vm).part().current.is_some()
    }

    /// The title the group watches.
    pub fn group_title(&self) -> Option<String> {
        lock(&self.inner.vm).part().queue_title.clone()
    }

    /// Estimated offset of the server clock, in seconds (for the log and the tests).
    pub fn offset_seconds(&self) -> f64 {
        lock(&self.inner.vm).session_mut().reconcile().offset()
    }

    // ---- the other devices ----

    /// The badge was tapped (the only session is taken, several open the choice).
    pub fn badge_tapped(&self) {
        self.takeover_event(TakeoverEvent::Tapped);
        if let TakeoverPart::Taking { row } = self.takeover().1 {
            let _ = self.inner.jobs.send(Job::Adopt(row.id));
        }
    }

    /// What the arriving card says while a takeover runs: the title, its episode line and the device it comes from.
    pub fn taking_texts(&self) -> Option<(String, String, String)> {
        let TakeoverPart::Taking { row } = self.takeover().1 else {
            return None;
        };
        let session = lock(&self.inner.vm).takeover_session(&row.id)?;
        let (title, line) = session.running.as_ref().map_or_else(
            || (row.title.clone(), String::new()),
            crate::together_ui::receive_lines,
        );
        Some((title, line, row.device))
    }

    /// A row of the choice was picked.
    pub fn takeover_pick(&self, session_id: &str) {
        self.takeover_event(TakeoverEvent::Selected(session_id.to_owned()));
        if let TakeoverPart::Taking { row } = self.takeover().1 {
            let _ = self.inner.jobs.send(Job::Adopt(row.id));
        }
    }

    /// Scrim, "Abbrechen" or the failure message was dismissed.
    pub fn takeover_cancel(&self) {
        self.takeover_event(TakeoverEvent::Cancelled);
    }

    fn takeover_event(&self, event: TakeoverEvent) {
        lock(&self.inner.vm).takeover_event(event);
    }

    /// Sends the running title to another device; the answer arrives as [`HubEvent::HandedOver`] or
    /// [`HubEvent::HandOverFailed`].
    pub fn hand_over(&self, order: HandOver) {
        let _ = self.inner.jobs.send(Job::HandOver(order));
    }

    /// "Abspielen auf …": starts a title on another device (`position` `None`: where the server last saw the viewer).
    pub fn play_on(&self, item_id: &str, device_id: &str, position: Option<f64>) {
        let _ = self.inner.jobs.send(Job::PlayOn {
            item_id: item_id.to_owned(),
            device_id: device_id.to_owned(),
            position,
        });
    }

    /// Asks for the other devices right now (a menu is about to open).
    pub fn poll_now(&self) {
        let _ = self.inner.jobs.send(Job::Poll);
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.inner.stopped.store(true, Ordering::SeqCst);
        let _ = self.inner.jobs.send(Job::Stop);
    }
}

/// In a group the buttons of the player are requests (`gemeinsam.bitToggle`, `bitJump`).
impl GroupHook for Hub {
    fn toggle(&self, running: bool) {
        let effects = lock(&self.inner.vm)
            .session_mut()
            .bit_toggle(running, now());
        self.inner.handle(effects);
    }

    fn jump(&self, to: f64) {
        let effects = lock(&self.inner.vm).session_mut().bit_jump(to, now());
        self.inner.handle(effects);
    }
}

impl Inner {
    fn push(&self, e: HubEvent) {
        lock(&self.events).push_back(e);
    }

    fn note(&self, line: String) {
        lock(&self.log).push(line);
    }

    /// Takes the effects of the session: parts are refreshed in the model, the rest goes to the worker.
    fn handle(&self, effects: Vec<Effect>) {
        let host_effects = lock(&self.vm).apply(effects);
        self.after_apply();
        // Steps and titles go out at once, on this thread: they are due now and must not queue behind a server call.
        let mut calls = Vec::new();
        for e in host_effects {
            match e {
                Effect::Player(action) => self.push(HubEvent::Step {
                    action,
                    at: Instant::now(),
                }),
                Effect::LoadTitle { title, since } => {
                    self.push(HubEvent::LoadTitle { title, since })
                }
                other => calls.push(other),
            }
        }
        if !calls.is_empty() {
            let _ = self.jobs.send(Job::Effects(calls));
        }
        // The session may have set a new deadline: the clock thread sleeps until the old one.
        self.wake.1.notify_all();
    }

    /// A new error text from the core shows on the strip once per error (`SharedModel` line 217).
    fn after_apply(&self) {
        let vm = lock(&self.vm);
        let count = vm.part().detail.error_count;
        let text = vm.part().error.clone();
        drop(vm);
        let mut seen = lock(&self.seen_errors);
        if count != *seen {
            *seen = count;
            *lock(&self.error) = text.map(|t| (count, t));
        }
    }

    /// The clock: runs what the session has due (a command's moment, the channel check, an event's end) when it is
    /// due, on its own thread so no server call can hold a step back. Ends with the hub.
    fn clock(weak: &std::sync::Weak<Inner>) {
        loop {
            let Some(inner) = weak.upgrade() else { return };
            if inner.stopped.load(Ordering::SeqCst) {
                return;
            }
            let deadline = lock(&inner.vm).session_mut().next_deadline();
            let wait = match deadline {
                Some(at) => Duration::from_secs_f64((at - now()).clamp(0.0, 0.25)),
                None => Duration::from_millis(250),
            };
            if wait.is_zero() {
                let effects = lock(&inner.vm).session_mut().poll(now());
                inner.handle(effects);
                continue;
            }
            let guard = lock(&inner.wake.0);
            let _ = inner
                .wake
                .1
                .wait_timeout(guard, wait)
                .unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// The worker: serial server calls and the poll of the other devices.
    fn work(self: &Arc<Self>, queue: &Receiver<Job>) {
        let mut next_poll = Instant::now() + Duration::from_secs(1);
        loop {
            let wait =
                Duration::from_millis(500).min(next_poll.saturating_duration_since(Instant::now()));
            match queue.recv_timeout(wait) {
                Ok(Job::Stop) | Err(RecvTimeoutError::Disconnected) => return,
                Ok(Job::Effects(e)) => self.run(e),
                Ok(Job::Capabilities) => self.capabilities(),
                Ok(Job::Adopt(id)) => self.adopt(&id),
                Ok(Job::HandOver(order)) => self.hand_over(&order),
                Ok(Job::PlayOn {
                    item_id,
                    device_id,
                    position,
                }) => self.play_on(&item_id, &device_id, position),
                Ok(Job::Poll) => {
                    self.poll_sessions();
                    next_poll = Instant::now() + Duration::from_secs_f64(TICK_SECONDS);
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
            if self.stopped.load(Ordering::SeqCst) {
                return;
            }
            if Instant::now() >= next_poll {
                if !self.player_open.load(Ordering::SeqCst) {
                    self.poll_sessions();
                }
                next_poll = Instant::now() + Duration::from_secs_f64(TICK_SECONDS);
            }
        }
    }

    /// Runs the host effects one after the other: player steps, titles and server calls.
    fn run(&self, effects: Vec<Effect>) {
        let mut queue: VecDeque<Effect> = effects.into();
        let mut created = false;
        let mut accepted = false;
        while let Some(effect) = queue.pop_front() {
            let more = match effect {
                Effect::Player(action) => {
                    self.push(HubEvent::Step {
                        action,
                        at: Instant::now(),
                    });
                    Vec::new()
                }
                Effect::LoadTitle { title, since } => {
                    self.push(HubEvent::LoadTitle { title, since });
                    Vec::new()
                }
                Effect::Api { call, .. } => {
                    let result = futures_executor::block_on(self.client.execute(&call));
                    let t = now();
                    let mut vm = lock(&self.vm);
                    let s = vm.session_mut();
                    let effects = match result {
                        Ok(CallResult::Right(r)) => s.right_loaded(r),
                        Ok(CallResult::Groups(g)) => s.offerings_loaded(g),
                        Ok(CallResult::Time(r)) => s.time_measured(r, t),
                        Ok(CallResult::Done) => match &call {
                            SyncPlayCall::Create { .. } => {
                                created = true;
                                s.call_done(&call)
                            }
                            SyncPlayCall::SetNewQueue { .. } if created => {
                                created = false;
                                accepted = true;
                                s.accepted(t)
                            }
                            SyncPlayCall::Join { rejoin: false, .. } => {
                                accepted = true;
                                s.accepted(t)
                            }
                            _ => s.call_done(&call),
                        },
                        Err(e) => {
                            if matches!(call, SyncPlayCall::List) {
                                s.offerings_failed()
                            } else {
                                if matches!(call, SyncPlayCall::Create { .. }) {
                                    // The title is not set into a group that was not made.
                                    queue.retain(|q| {
                                        !matches!(
                                            q,
                                            Effect::Api {
                                                call: SyncPlayCall::SetNewQueue { .. },
                                                ..
                                            }
                                        )
                                    });
                                }
                                s.call_failed(&call, e, t)
                            }
                        }
                    };
                    if std::mem::take(&mut accepted) {
                        vm.accepted_mark();
                    }
                    let host = vm.apply(effects);
                    drop(vm);
                    self.after_apply();
                    host
                }
                Effect::Status(_) | Effect::Error(_) => Vec::new(),
            };
            queue.extend(more);
        }
    }

    // ---- the socket ----

    /// The control channel: connect, read, keep alive, reconnect with the core's back-off, until stopped.
    fn socket(self: &Arc<Self>) {
        let mut ctl = RemoteControl::new();
        while !self.stopped.load(Ordering::SeqCst) {
            let Some(url) = RemoteControl::socket_url(
                &self.account.base_url,
                &self.account.token,
                &self.account.device_id,
            ) else {
                return;
            };
            // The same certificate options as every other call: an added authority, a self-signed server the user accepted.
            let tls = crate::live::tls_options(&self.core.settings);
            let url = if self.account.server_kind == swiftly_jellyfin::ServerKind::Emby {
                url.replacen("/socket?", "/embywebsocket?", 1)
            } else {
                url
            };
            let ended = match Link::connect(&url, &tls) {
                Ok(mut link) => {
                    let _ = self.jobs.send(Job::Capabilities);
                    let ended = self.read(&mut ctl, &mut link);
                    link.close();
                    ended
                }
                Err(e) => e,
            };
            if self.stopped.load(Ordering::SeqCst) {
                return;
            }
            let gives_up = match &ended {
                LinkError::NotSupported => true,
                LinkError::SetupFailed { code } => ctl.line_setup_gives_up(*code),
                LinkError::Other(_) => false,
            };
            if gives_up {
                self.note("socket: the server takes no upgrade on this line, giving up".into());
                return;
            }
            self.output(
                RemoteOutput::SyncPlay(SyncPlayPostDirection::ConnectionLost),
                "",
            );
            let _ = ctl.on_lost();
            let wait = Duration::from_secs_f64(ctl.next_reconnect_wait());
            let until = Instant::now() + wait;
            while Instant::now() < until && !self.stopped.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }

    /// Reads one link until it ends; sends the keep-alive; a silent link is dead.
    fn read(&self, ctl: &mut RemoteControl, link: &mut Link) -> LinkError {
        let mut heard = Instant::now();
        let mut kept = Instant::now();
        loop {
            if self.stopped.load(Ordering::SeqCst) {
                return LinkError::Other("stopped".into());
            }
            match link.read() {
                Ok(Some(text)) => {
                    heard = Instant::now();
                    for out in ctl.process(&text) {
                        if let RemoteOutput::Send(reply) = &out {
                            if let Err(e) = link.send(reply) {
                                return e;
                            }
                            continue;
                        }
                        self.output(out, &text);
                    }
                    if let Some(again) = ctl.on_received() {
                        self.output(again, "");
                    }
                }
                Ok(None) => {
                    heard = heard.max(Instant::now().checked_sub(SILENCE).unwrap_or(heard));
                }
                Err(e) => return e,
            }
            if heard.elapsed() >= SILENCE {
                return LinkError::Other("silent link".into());
            }
            if kept.elapsed() >= Duration::from_secs_f64(KEEP_ALIVE_INTERVAL) {
                kept = Instant::now();
                if let Err(e) = link.send(KEEP_ALIVE) {
                    return e;
                }
            }
        }
    }

    /// One thing the channel heard.
    fn output(&self, out: RemoteOutput, raw: &str) {
        match out {
            RemoteOutput::Command(RemoteCommand::Stop) => {
                // A stop that follows the takeover hint closes the player as a handoff, any other one just closes it.
                let hint = lock(&self.hint).take();
                match hint {
                    Some((device, at))
                        if takeover::is_handoff(Some(at.elapsed().as_secs_f64())) =>
                    {
                        self.push(HubEvent::TakenOver { device });
                    }
                    _ => self.push(HubEvent::Command(RemoteCommand::Stop)),
                }
            }
            RemoteOutput::Command(c) => self.push(HubEvent::Command(c)),
            RemoteOutput::SyncPlay(SyncPlayPostDirection::ConnectionLost) => {
                self.session_accept(SyncPlayPostDirection::ConnectionLost);
            }
            RemoteOutput::SyncPlay(SyncPlayPostDirection::ConnectionAgain) => {
                self.session_accept(SyncPlayPostDirection::ConnectionAgain);
            }
            RemoteOutput::SyncPlay(msg) => {
                let _ = raw;
                self.session_accept(msg);
            }
            RemoteOutput::Handoff(device) => *lock(&self.hint) = Some((device, Instant::now())),
            RemoteOutput::Play(order) => self.push(HubEvent::Play(order)),
            RemoteOutput::Unreadable(text) => {
                self.note(format!("socket: unreadable message: {text}"))
            }
            RemoteOutput::Send(_) => {}
        }
    }

    fn session_accept(&self, msg: SyncPlayPostDirection) {
        let effects = lock(&self.vm).session_mut().accept(msg, now());
        self.handle(effects);
    }

    // ---- the other devices ----

    fn capabilities(&self) {
        match self.core.client_for(&self.account) {
            Ok(c) => {
                if let Err(e) = futures_executor::block_on(c.report_capabilities()) {
                    self.note(format!("capabilities: {e:?}"));
                }
            }
            Err(e) => self.note(format!("capabilities: {e:?}")),
        }
    }

    fn poll_sessions(&self) {
        let Ok(c) = self.core.client_for(&self.account) else {
            return;
        };
        let Ok(all) = futures_executor::block_on(c.remote_sessions()) else {
            // An unanswered question offers nothing (the Mac clears its offering on a failed ask as well).
            lock(&self.vm).sessions_polled(&[], now());
            return;
        };
        if takeover::must_report(&all, &self.account.device_id) {
            let _ = futures_executor::block_on(c.report_capabilities());
        }
        let t = now();
        *lock(&self.targets) =
            takeover::play_targets(&all, &self.account.device_id, &self.account.user_id, t);
        lock(&self.vm).sessions_polled(&all, t);
    }

    fn text(&self, e: &ErrorKind) -> String {
        let t = swiftly_l10n::Translator::new(self.core.host().locale);
        swiftly_l10n::error_text::readable_error(&t, e)
    }

    /// Takes the title over from another device: hint, stop, then the saved position settles (`handed_over`).
    fn adopt(&self, session_id: &str) {
        let failed = |message: String| {
            lock(&self.vm).takeover_event(TakeoverEvent::Failed(message));
        };
        let Ok(c) = self.core.client_for(&self.account) else {
            return failed("Du bist gerade nicht mit dem Server verbunden.".into());
        };
        let Some(chosen) = lock(&self.vm).takeover_session(session_id) else {
            return failed("Das Gerät spielt nichts mehr.".into());
        };
        let Some(item_id) = chosen
            .running
            .as_ref()
            .map(|i| i.id.clone())
            .filter(|i| !i.is_empty())
        else {
            return failed("Das Gerät spielt nichts mehr.".into());
        };
        // The plan first (`handed_over`, `TakeoverModel.wish`): if this device cannot play the title, the other one is
        // not stopped, otherwise the film would be gone from both.
        let planned = self.core.prepare_play(
            &self.account,
            crate::live_play::PlayRequest {
                item_id: item_id.clone(),
                since: -1.0,
                source_id: None,
            },
        );
        match planned.0.recv_timeout(Duration::from_secs(30)) {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                return failed(if e.starts_with("Der Server") {
                    e
                } else {
                    "Der Titel lässt sich hier gerade nicht abspielen.".to_owned()
                });
            }
            Err(_) => return failed("Der Titel lässt sich hier gerade nicht abspielen.".into()),
        }
        let spot = chosen.state.as_ref().map_or(0.0, |s| s.spot());
        let (saved, fresh) = futures_executor::block_on(futures_util::future::join(
            c.item(&item_id),
            c.remote_sessions(),
        ));
        let before = saved
            .ok()
            .and_then(|i| i.user_data)
            .and_then(|d| d.playback_position_ticks);
        let fresh = fresh
            .ok()
            .and_then(|all| all.into_iter().find(|s| s.id == session_id));
        let session_point = fresh
            .as_ref()
            .and_then(|s| s.state.as_ref())
            .map_or(spot, |s| s.spot());
        if let Some(f) = &fresh
            && takeover::takes_hint(f)
        {
            let own = self.core.host().device_name;
            let _ = futures_executor::block_on(c.handoff_hint(session_id, &own));
        }
        if let Err(e) =
            futures_executor::block_on(c.foreign_command(ForeignCommand::Finish, session_id))
        {
            return failed(self.text(&e));
        }
        let mut afterwards = None;
        for _ in 0..SETTLE_TRIES {
            std::thread::sleep(Duration::from_millis(u64::from(SETTLE_STEP_MS)));
            let at = futures_executor::block_on(c.item(&item_id))
                .ok()
                .and_then(|i| i.user_data)
                .and_then(|d| d.playback_position_ticks);
            if at != before {
                afterwards = at;
                break;
            }
        }
        let since = takeover::start_point(session_point, before, afterwards);
        lock(&self.vm).takeover_event(TakeoverEvent::Succeeded);
        self.push(HubEvent::StartHere { item_id, since });
    }

    /// The current session of a chosen device, from a fresh list.
    fn target_session(
        &self,
        c: &crate::live::Client,
        device_id: &str,
    ) -> Result<RemoteSession, String> {
        let all = futures_executor::block_on(c.remote_sessions()).map_err(|e| self.text(&e))?;
        let targets =
            takeover::play_targets(&all, &self.account.device_id, &self.account.user_id, now());
        *lock(&self.targets) = targets.clone();
        targets
            .into_iter()
            .find(|s| s.device_id.as_deref() == Some(device_id))
            .ok_or_else(|| "Das Gerät ist nicht mehr erreichbar.".to_owned())
    }

    fn deliver(
        &self,
        c: &crate::live::Client,
        session: &RemoteSession,
        item_ids: &[String],
        start: f64,
        order: (Option<&str>, Option<i64>, Option<i64>),
    ) -> Result<(), String> {
        futures_executor::block_on(c.play_now(
            &session.id,
            item_ids,
            0,
            start,
            order.0,
            order.1,
            order.2,
        ))
        .map_err(|e| self.text(&e))
    }

    /// The running title to another device (`PlayOutputs.handOver`): the same position, version and tracks.
    fn hand_over(&self, order: &HandOver) {
        let name_of = |s: &RemoteSession| takeover::target_name(s);
        let result = self
            .core
            .client_for(&self.account)
            .map_err(|e| self.text(&e))
            .and_then(|c| {
                let session = self.target_session(&c, &order.device_id)?;
                let name = name_of(&session);
                self.deliver(
                    &c,
                    &session,
                    std::slice::from_ref(&order.item_id),
                    order.position,
                    (order.source_id.as_deref(), order.audio, order.subtitle),
                )
                .map(|()| name)
            });
        match result {
            Ok(device) => self.push(HubEvent::HandedOver { device }),
            Err(message) => {
                *lock(&self.error) = Some((now() as u64, message.clone()));
                self.push(HubEvent::HandOverFailed { message });
            }
        }
    }

    fn play_on(&self, item_id: &str, device_id: &str, position: Option<f64>) {
        let result = self
            .core
            .client_for(&self.account)
            .map_err(|e| self.text(&e))
            .and_then(|c| {
                let session = self.target_session(&c, device_id)?;
                let start = position.unwrap_or_else(|| {
                    futures_executor::block_on(c.item(item_id))
                        .ok()
                        .and_then(|i| i.user_data)
                        .and_then(|d| d.playback_position_ticks)
                        .map_or(0.0, |t| t as f64 / 10_000_000.0)
                });
                self.deliver(
                    &c,
                    &session,
                    &[item_id.to_owned()],
                    start,
                    (None, None, None),
                )
            });
        if let Err(message) = result {
            *lock(&self.error) = Some((now() as u64, message));
        }
    }
}
