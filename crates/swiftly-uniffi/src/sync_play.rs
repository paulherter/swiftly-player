//! Watching together (SyncPlay): the session of `swiftly-sync` behind the sheet model
//! (`SharedVm`). The control channel (`RemoteChannel`) hands the raw messages over; the host
//! forwards `RemoteEvent::SyncPlay` to [`SyncPlayModel::feed`], `ConnectionLost` to
//! [`SyncPlayModel::link_lost`] and `ConnectionAgain` to [`SyncPlayModel::link_again`]. Server
//! calls, clock measurements, the five-second channel check, rejoin after a drop and the
//! buffering guard run inside; the host only moves the player when [`SyncPlayHost`] says so.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use swiftly_jellyfin::OwnHeaders;
use swiftly_net::Url;
use swiftly_sync::{
    CallResult, Effect, PlayerAction, PlayerView, ServerCtx, SyncPlayCall, SyncPlayClient,
    SyncPlayPostDirection,
};
use swiftly_vm::{AccountRef, Host, SharedIntent, SharedVm};
use tokio::sync::{Notify, watch};

use crate::error::CoreError;
use crate::transport::CoreTransport;

/// A step for the player.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum SyncPlayStep {
    /// Resume.
    Proceed,
    /// Pause.
    Halt,
    /// Seek (updates the timeline and the button right away).
    Jump {
        /// Target in seconds.
        seconds: f64,
    },
}

/// What the host does for the group. Called from the core's threads, never under a lock.
#[uniffi::export(with_foreign)]
pub trait SyncPlayHost: Send + Sync {
    /// Move the player.
    fn player_step(&self, step: SyncPlayStep);
    /// Open (or switch to) this title at `since` seconds; report `title_load_failed` if it
    /// cannot be played here.
    fn load_title(&self, title: String, since: f64);
}

/// The player, as the session reads it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncPlayPlayer {
    /// Jellyfin id of the title playing right now.
    pub title: String,
    /// Picture is up and no title is being switched.
    pub ready: bool,
    /// Position in seconds.
    pub spot: f64,
}

impl From<SyncPlayPlayer> for PlayerView {
    fn from(p: SyncPlayPlayer) -> Self {
        Self {
            title: p.title,
            ready: p.ready,
            spot: p.spot,
        }
    }
}

/// A group in the list.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncPlayGroupRow {
    /// Group id.
    pub id: String,
    /// Group name.
    pub name: String,
    /// "A und B schauen gerade".
    pub who: String,
    /// The phase in words.
    pub state_text: Option<String>,
}

/// The group the user is in.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncPlayCurrent {
    /// Group id.
    pub id: String,
    /// Group name.
    pub name: String,
    /// "mit A" or "noch niemand dabei".
    pub with_whom: String,
    /// The phase in words.
    pub state_text: Option<String>,
}

/// A group with the structured facts beside the words.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncPlayGroupDetail {
    /// Group id.
    pub id: String,
    /// Group name.
    pub name: String,
    /// All participants as the server names them.
    pub participants: Vec<String>,
    /// Each name once.
    pub names: Vec<String>,
    /// The phase as a code: `laeuft`, `angehalten`, `wartet`; none for an empty group.
    pub phase: Option<String>,
}

/// The structured facts the old Android JSON carried beside the words.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncPlayDetail {
    /// All groups on offer, also while in a group.
    pub offerings: Vec<SyncPlayGroupDetail>,
    /// The group the user is in.
    pub group: Option<SyncPlayGroupDetail>,
    /// Everyone else in the group, once each.
    pub other: Vec<String>,
    /// `dabei`, `gegangen`, `wartet`, `angehalten`, `weiter`, `gesprungen` or `warnung`.
    pub notice_kind: Option<String>,
    /// Id of the latest event.
    pub notice_id: Option<u64>,
    /// The latest error text; it stays until the next error.
    pub error_last: Option<String>,
    /// Counts the errors.
    pub error_count: u64,
    /// Counts the creates and joins the server accepted.
    pub accepted: u64,
}

/// What the SyncPlay sheet draws.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncPlayPage {
    /// Grows with every change.
    pub version: u64,
    /// The groups to join; empty while in a group.
    pub groups: Vec<SyncPlayGroupRow>,
    /// The account may create a group.
    pub may_create: bool,
    /// The account may join one.
    pub may_join: bool,
    /// The current group.
    pub current: Option<SyncPlayCurrent>,
    /// The short notice of the latest event.
    pub notice: Option<String>,
    /// The error, readable.
    pub error: Option<String>,
    /// Creating or joining is under way.
    pub works: bool,
    /// The title the group watches (item id).
    pub queue_title: Option<String>,
    /// The group last left, for "Rejoin".
    pub last_leave: Option<String>,
    /// The structured facts beside the words.
    pub detail: SyncPlayDetail,
}

struct WallClock;

impl swiftly_sync::Clock for WallClock {
    fn now(&self) -> f64 {
        now()
    }
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

struct Inner {
    vm: Mutex<SharedVm>,
    client: SyncPlayClient<CoreTransport, WallClock>,
    listener: Arc<dyn SyncPlayHost>,
    host: Host,
    wake: Arc<Notify>,
    version: watch::Sender<u64>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Inner {
    /// Takes the effects the session produced: the sheet parts are refreshed, the server calls
    /// run one after the other in a task, player steps go to the host.
    fn handle(self: &Arc<Self>, effects: Vec<Effect>) {
        let host_effects = lock(&self.vm).apply(effects);
        self.bump();
        self.wake.notify_one();
        if host_effects.is_empty() {
            return;
        }
        let me = Arc::clone(self);
        self.host
            .spawner
            .spawn(Box::pin(async move { me.run(host_effects).await }));
    }

    fn bump(&self) {
        let v = lock(&self.vm).part().version;
        self.version.send_replace(v);
    }

    async fn run(self: Arc<Self>, effects: Vec<Effect>) {
        let mut queue: VecDeque<Effect> = effects.into();
        let mut created = false;
        let mut accepted = false;
        while let Some(effect) = queue.pop_front() {
            let more = match effect {
                Effect::Player(action) => {
                    self.listener.player_step(match action {
                        PlayerAction::Proceed => SyncPlayStep::Proceed,
                        PlayerAction::Halt => SyncPlayStep::Halt,
                        PlayerAction::Jump(seconds) => SyncPlayStep::Jump { seconds },
                    });
                    Vec::new()
                }
                Effect::LoadTitle { title, since } => {
                    self.listener.load_title(title, since);
                    Vec::new()
                }
                Effect::Api { call, .. } => {
                    let result = self.client.execute(&call).await;
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
                    drop(vm);
                    let mut vm = lock(&self.vm);
                    if std::mem::take(&mut accepted) {
                        vm.accepted_mark();
                    }
                    let host_effects = vm.apply(effects);
                    drop(vm);
                    self.bump();
                    self.wake.notify_one();
                    host_effects
                }
                Effect::Status(_) | Effect::Error(_) => Vec::new(),
            };
            queue.extend(more);
        }
    }
}

/// Runs what is due, when it is due. Holds the model only weakly, so dropping it ends the task.
async fn timer(weak: std::sync::Weak<Inner>) {
    loop {
        let Some(inner) = weak.upgrade() else { return };
        let deadline = lock(&inner.vm).session_mut().next_deadline();
        let wake = Arc::clone(&inner.wake);
        drop(inner);
        match deadline {
            None => wake.notified().await,
            Some(at) => {
                let wait = (at - now()).max(0.0);
                tokio::select! {
                    () = tokio::time::sleep(crate::support::wait_duration(wait)) => {
                        let Some(inner) = weak.upgrade() else { return };
                        let effects = lock(&inner.vm).session_mut().poll(now());
                        inner.handle(effects);
                    }
                    () = wake.notified() => {}
                }
            }
        }
    }
}

/// The group the user watches in.
#[derive(uniffi::Object)]
pub struct SyncPlayModel {
    inner: Arc<Inner>,
}

impl SyncPlayModel {
    pub(crate) fn build(
        transport: CoreTransport,
        host: Host,
        account: &AccountRef,
        self_name: Option<String>,
        listener: Arc<dyn SyncPlayHost>,
    ) -> Result<Arc<Self>, CoreError> {
        let client = swiftly_vm::account_client(&Arc::new(transport.clone()), &host, account)?;
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
            host.locale.clone(),
            self_name.as_deref(),
            &account.device_id,
            &account.user_id,
        );
        let (version, _) = watch::channel(0);
        let inner = Arc::new(Inner {
            vm: Mutex::new(vm),
            client: SyncPlayClient::new(transport, WallClock, ctx),
            listener,
            host: host.clone(),
            wake: Arc::new(Notify::new()),
            version,
        });
        let me = Arc::new(Self {
            inner: Arc::clone(&inner),
        });
        let weak = Arc::downgrade(&inner);
        host.spawner.spawn(Box::pin(timer(weak)));
        Ok(me)
    }
}

#[uniffi::export]
impl SyncPlayModel {
    /// What the sheet draws.
    pub fn page(&self) -> SyncPlayPage {
        let vm = lock(&self.inner.vm);
        let p = vm.part();
        SyncPlayPage {
            version: p.version,
            groups: p
                .groups
                .iter()
                .map(|g| SyncPlayGroupRow {
                    id: g.id.clone(),
                    name: g.name.clone(),
                    who: g.who.clone(),
                    state_text: g.state_text.clone(),
                })
                .collect(),
            may_create: p.may_create,
            may_join: p.may_join,
            current: p.current.as_ref().map(|c| SyncPlayCurrent {
                id: c.id.clone(),
                name: c.name.clone(),
                with_whom: c.with_whom.clone(),
                state_text: c.state_text.clone(),
            }),
            notice: p.notice.clone(),
            error: p.error.clone(),
            works: p.works,
            queue_title: p.queue_title.clone(),
            last_leave: p.last_leave.clone(),
            detail: {
                let d = &p.detail;
                let group = |g: &swiftly_vm::GroupDetail| SyncPlayGroupDetail {
                    id: g.id.clone(),
                    name: g.name.clone(),
                    participants: g.participants.clone(),
                    names: g.names.clone(),
                    phase: g.phase.clone(),
                };
                SyncPlayDetail {
                    offerings: d.offerings.iter().map(group).collect(),
                    group: d.group.as_ref().map(group),
                    other: d.other.clone(),
                    notice_kind: d.notice_kind.clone(),
                    notice_id: d.notice_id,
                    error_last: d.error_last.clone(),
                    error_count: d.error_count,
                    accepted: d.accepted,
                }
            },
        }
    }

    /// Returns at once when the page is newer than `seen`, else waits; answers the version.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<u64, CoreError> {
        let mut rx = self.inner.version.subscribe();
        loop {
            let current = *rx.borrow_and_update();
            if current > seen || rx.changed().await.is_err() {
                return Ok(current);
            }
        }
    }

    /// Asks for the account's right and the groups on offer.
    pub fn refresh(&self) {
        let effects = lock(&self.inner.vm).handle(SharedIntent::Refresh, now());
        self.inner.handle(effects);
    }

    /// Asks for the groups on offer only (the "continue here" tick; `refresh` also asks for the right).
    pub fn offerings_ask(&self) {
        let effects = lock(&self.inner.vm).session_mut().offerings_ask();
        self.inner.handle(effects);
    }

    /// Asks for the account's right only (once, when the control channel starts).
    pub fn right_fetch(&self) {
        let effects = lock(&self.inner.vm).session_mut().right_fetch();
        self.inner.handle(effects);
    }

    /// Opens a group and sets the title (an empty name becomes "Filmabend").
    pub fn create(&self, name: String, title_id: String) {
        let effects = lock(&self.inner.vm).handle(SharedIntent::Create { name, title_id }, now());
        self.inner.handle(effects);
    }

    /// Joins a group of the list.
    pub fn join(&self, group_id: String) {
        let effects = lock(&self.inner.vm).handle(SharedIntent::Join(group_id), now());
        self.inner.handle(effects);
    }

    /// Joins the group last left (the "Rejoin" button).
    pub fn rejoin(&self) {
        let effects = lock(&self.inner.vm).session_mut().again_join();
        self.inner.handle(effects);
    }

    /// Leaves the group.
    pub fn leave(&self) {
        let effects = lock(&self.inner.vm).handle(SharedIntent::Leave, now());
        self.inner.handle(effects);
    }

    /// Hides the error strip.
    pub fn dismiss_error(&self) {
        let effects = lock(&self.inner.vm).handle(SharedIntent::DismissError, now());
        self.inner.handle(effects);
    }

    /// Logout or account switch: leaves the group and forgets everything.
    pub fn finish(&self) {
        let effects = lock(&self.inner.vm).session_mut().finish(now());
        self.inner.handle(effects);
    }

    /// A raw control-channel message (`RemoteEvent::SyncPlay`). Anything unreadable is ignored.
    pub fn feed(&self, text: String) {
        if let Some(msg) = SyncPlayPostDirection::read(&text) {
            let effects = lock(&self.inner.vm).session_mut().accept(msg, now());
            self.inner.handle(effects);
        }
    }

    /// The channel dropped (`RemoteEvent::ConnectionLost`).
    pub fn link_lost(&self) {
        let effects = lock(&self.inner.vm)
            .session_mut()
            .accept(SyncPlayPostDirection::ConnectionLost, now());
        self.inner.handle(effects);
    }

    /// The channel is back (`RemoteEvent::ConnectionAgain`).
    pub fn link_again(&self) {
        let effects = lock(&self.inner.vm)
            .session_mut()
            .accept(SyncPlayPostDirection::ConnectionAgain, now());
        self.inner.handle(effects);
    }

    /// The player opened.
    pub fn player_attached(&self, player: SyncPlayPlayer) {
        let effects = lock(&self.inner.vm).session_mut().plug_in(player.into());
        self.inner.handle(effects);
    }

    /// The player state, before every tick and message.
    pub fn player_update(&self, player: SyncPlayPlayer) {
        lock(&self.inner.vm)
            .session_mut()
            .update_player(player.into());
    }

    /// The player closed: that is leaving the group.
    pub fn player_detached(&self) {
        let effects = lock(&self.inner.vm).session_mut().detach(now());
        self.inner.handle(effects);
    }

    /// Once per player tick: reports buffering and ready to the group.
    pub fn player_tick(&self) {
        let effects = lock(&self.inner.vm).session_mut().player_tick(now());
        self.inner.handle(effects);
    }

    /// Pause or resume as a request; the button flips when the command comes back.
    pub fn request_toggle(&self, running_now: bool) {
        let effects = lock(&self.inner.vm)
            .session_mut()
            .bit_toggle(running_now, now());
        self.inner.handle(effects);
    }

    /// Seek as a request.
    pub fn request_jump(&self, seconds: f64) {
        let effects = lock(&self.inner.vm).session_mut().bit_jump(seconds, now());
        self.inner.handle(effects);
    }

    /// A different title (episode) for everyone.
    pub fn request_title(&self, title: String, since: f64) {
        let effects = lock(&self.inner.vm)
            .session_mut()
            .bit_title(&title, since, now());
        self.inner.handle(effects);
    }

    /// The host could not open the group's title.
    pub fn title_load_failed(&self) {
        let effects = lock(&self.inner.vm).session_mut().title_load_failed(now());
        self.inner.handle(effects);
    }

    /// Estimated offset of the server clock to this device, in seconds.
    pub fn offset_seconds(&self) -> f64 {
        lock(&self.inner.vm).session_mut().reconcile().offset()
    }

    /// Estimated round trip to the server, in milliseconds.
    pub fn ping_milliseconds(&self) -> i64 {
        lock(&self.inner.vm)
            .session_mut()
            .reconcile()
            .ping_milliseconds()
    }
}

impl Drop for SyncPlayModel {
    fn drop(&mut self) {
        self.inner.wake.notify_one();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::{HttpClient, HttpFailure, NetRequest, NetResponse};
    use std::time::Duration;
    use swiftly_jellyfin::ServerKind;
    use swiftly_l10n::Locale;
    use swiftly_vm::{Spawner, SystemClock};

    struct Spawn;
    impl Spawner for Spawn {
        fn spawn(&self, task: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>) {
            drop(tokio::spawn(task));
        }
    }

    struct NoStore;
    impl swiftly_library::Store for NoStore {
        fn read(&self, _: &str) -> Option<Vec<u8>> {
            None
        }
        fn write(&self, _: &str, _: &[u8]) {}
        fn remove(&self, _: &str) {}
    }

    /// A server that answers the SyncPlay calls and records them.
    #[derive(Default)]
    struct Server(Mutex<Vec<String>>);
    #[async_trait::async_trait]
    impl HttpClient for Server {
        async fn send(&self, r: NetRequest) -> Result<NetResponse, HttpFailure> {
            let path = r.url.split("example").nth(1).unwrap_or("").to_owned();
            let auth = r
                .headers
                .iter()
                .any(|h| h.name == "Authorization" && h.value.contains("Token=\"tok\""));
            self.0.lock().unwrap().push(format!("{path} auth={auth}"));
            let body = if path.starts_with("/Users/") {
                r#"{"Policy":{"SyncPlayAccess":"CreateAndJoinGroups"}}"#
            } else if path.starts_with("/SyncPlay/List") {
                r#"[{"GroupId":"g1","GroupName":"Abend","Participants":["Anna"],"State":"Idle"}]"#
            } else {
                ""
            };
            Ok(NetResponse {
                status: 200,
                headers: vec![],
                body: body.as_bytes().to_vec(),
                url: None,
            })
        }
    }

    #[derive(Default)]
    struct Player(Mutex<Vec<String>>);
    impl SyncPlayHost for Player {
        fn player_step(&self, step: SyncPlayStep) {
            self.0.lock().unwrap().push(format!("{step:?}"));
        }
        fn load_title(&self, title: String, since: f64) {
            self.0.lock().unwrap().push(format!("load {title} {since}"));
        }
    }

    fn model(server: Arc<Server>, player: Arc<Player>) -> Arc<SyncPlayModel> {
        let host = Host {
            spawner: Arc::new(Spawn),
            clock: Arc::new(SystemClock),
            store: Arc::new(NoStore),
            locale: Locale::parse("en"),
            device_name: "test".into(),
            client_version: "1".into(),
            cache: None,
        };
        let account = AccountRef {
            base_url: "https://sp.example".into(),
            user_id: "u1".into(),
            token: "tok".into(),
            server_kind: ServerKind::Jellyfin,
            device_id: "dev".into(),
            plex_machine_id: None,
            plex_account_token: None,
        };
        let transport = CoreTransport::new(server as Arc<dyn crate::transport::HttpClient>);
        SyncPlayModel::build(transport, host, &account, Some("Paul".into()), player).unwrap()
    }

    async fn until(m: &SyncPlayModel, ok: impl Fn(&SyncPlayPage) -> bool) -> SyncPlayPage {
        let mut seen = 0;
        for _ in 0..50 {
            let p = m.page();
            if ok(&p) {
                return p;
            }
            seen = tokio::time::timeout(Duration::from_millis(200), m.changed(seen))
                .await
                .map_or(seen, |c| c.unwrap_or(seen));
        }
        panic!("page never got there: {:?}", m.page());
    }

    fn calls(server: &Server) -> Vec<String> {
        server.0.lock().unwrap().clone()
    }

    #[tokio::test]
    async fn refresh_lists_the_groups_join_runs_the_call_and_the_channel_answers() {
        let server = Arc::new(Server::default());
        let m = model(Arc::clone(&server), Arc::new(Player::default()));
        m.refresh();
        let p = until(&m, |p| p.groups.len() == 1).await;
        assert_eq!(p.groups[0].name, "Abend");
        assert!(p.may_create && p.may_join);
        m.join("g1".into());
        until(&m, |_| {
            calls(&server)
                .iter()
                .any(|l| l.starts_with("/SyncPlay/Join"))
        })
        .await;
        let joined = r#"{"MessageType":"SyncPlayGroupUpdate","Data":{"Type":"GroupJoined","GroupId":"g1","Data":{"GroupId":"g1","GroupName":"Abend","Participants":["Anna","Paul"],"State":"Idle"}}}"#;
        m.feed(joined.into());
        let p = until(&m, |p| p.current.is_some()).await;
        assert_eq!(p.current.unwrap().id, "g1");
        assert!(p.groups.is_empty());
        m.leave();
        until(&m, |p| p.current.is_none()).await;
        until(&m, |_| {
            calls(&server)
                .iter()
                .any(|l| l.starts_with("/SyncPlay/Leave"))
        })
        .await;
        assert!(
            calls(&server).iter().all(|l| l.ends_with("auth=true")),
            "{:?}",
            calls(&server)
        );
    }

    #[tokio::test]
    async fn create_sets_the_queue_after_the_group_and_waits_for_the_channel() {
        let server = Arc::new(Server::default());
        let m = model(Arc::clone(&server), Arc::new(Player::default()));
        m.create("  ".into(), "title-1".into());
        until(&m, |_| {
            calls(&server)
                .iter()
                .any(|l| l.starts_with("/SyncPlay/SetNewQueue"))
        })
        .await;
        let c = calls(&server);
        let new = c
            .iter()
            .position(|l| l.starts_with("/SyncPlay/New"))
            .unwrap();
        let queue = c
            .iter()
            .position(|l| l.starts_with("/SyncPlay/SetNewQueue"))
            .unwrap();
        assert!(new < queue, "{c:?}");
        assert!(m.page().works, "waits for the channel's answer");
    }
}
