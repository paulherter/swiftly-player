//! The control channel (`/socket`, `/embywebsocket` on Emby): remote commands, play orders,
//! takeover hints and SyncPlay messages over a WebSocket the host implements (URLSession on
//! Apple, OkHttp on Android; a tungstenite one lives in `swiftly-net` for the desktop).
//!
//! The channel keeps the link alive (a keep-alive every 30 s, or half of the limit a
//! `ForceKeepAlive` names; it answers that message at once), reconnects with the backoff of
//! `RemoteControl` (2, 4, 8, 16, 30 s) and tells SyncPlay about every drop and return.
//!
//! A link is dead when the host reports an error (a read or write failed, the server closed it)
//! or a send does not finish within `Timing::send_limit`. Silence is NOT a sign of death: a Jellyfin
//! server sends `ForceKeepAlive` on connect and again only after 45 s without a client frame, so a
//! client that reports every 30 s never hears from it again. A 90 s "no frame" watchdog used to drop
//! every healthy socket after the third keep-alive and reload the home screen on each return.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use swiftly_jellyfin::ServerKind;
use swiftly_sync::{
    KEEP_ALIVE, KEEP_ALIVE_INTERVAL, LinkError, PlayOrder, RemoteCommand, RemoteControl,
    RemoteOutput, SyncPlayPostDirection,
};
use swiftly_vm::{AccountRef, Host};
use tokio::sync::{Notify, mpsc};

/// Why a WebSocket ended or could not start.
#[derive(Debug, uniffi::Error)]
pub enum SocketFailure {
    /// This platform cannot do WebSocket on this line: use the fallback.
    NotSupported,
    /// The upgrade failed (HTTP status, 0 if unknown).
    SetupFailed {
        /// Status code.
        code: i32,
    },
    /// Anything else, including a closed link.
    Other {
        /// Developer-readable description.
        message: String,
    },
}

impl std::fmt::Display for SocketFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for SocketFailure {}

impl From<SocketFailure> for LinkError {
    fn from(f: SocketFailure) -> Self {
        match f {
            SocketFailure::NotSupported => Self::NotSupported,
            SocketFailure::SetupFailed { code } => Self::SetupFailed { code },
            SocketFailure::Other { message } => Self::Other(message),
        }
    }
}

/// The host's WebSocket. One object serves all reconnects: `connect` replaces the socket behind it.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait WebSocketLink: Send + Sync {
    /// Connects to `url` (`wss://host/socket?ApiKey=...&deviceId=...`), closing an older socket.
    async fn connect(&self, url: String) -> Result<(), SocketFailure>;
    /// The next text message; `None` for a frame to skip (binary, ping). An error ends the socket.
    async fn receive(&self) -> Result<Option<String>, SocketFailure>;
    /// Sends a text message.
    async fn send(&self, text: String) -> Result<(), SocketFailure>;
    /// Closes the socket; a pending `receive` must fail.
    fn close(&self);
}

/// A remote player command.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum RemoteCommandKind {
    /// Pause.
    Pause,
    /// Resume.
    Proceed,
    /// Toggle pause.
    Toggle,
    /// Stop.
    Stop,
    /// Seek to this many seconds.
    JumpOn {
        /// Target in seconds.
        seconds: f64,
    },
    /// Forward.
    Forward,
    /// Back.
    Back,
    /// Next track.
    Next,
    /// Previous track.
    Previous,
}

/// A "play on this device" order.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RemotePlayOrder {
    /// Item ids.
    pub item_ids: Vec<String>,
    /// Index to start at.
    pub start_index: u64,
    /// Start in seconds.
    pub start: f64,
    /// Media source.
    pub media_source_id: Option<String>,
    /// Audio stream index.
    pub audio_index: Option<i64>,
    /// Subtitle stream index.
    pub subtitle_index: Option<i64>,
}

/// What the channel tells the app.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum RemoteEvent {
    /// A player command.
    Command {
        /// The command.
        command: RemoteCommandKind,
    },
    /// A play order.
    Play {
        /// The order.
        order: RemotePlayOrder,
    },
    /// A takeover hint from another device (its name).
    Handoff {
        /// The device name.
        device: String,
    },
    /// A SyncPlay message, raw JSON as the server sent it.
    SyncPlay {
        /// The message text.
        text: String,
    },
    /// The channel dropped.
    ConnectionLost,
    /// Something arrived again after a drop.
    ConnectionAgain,
    /// A SyncPlay or play message that could not be read (first 300 characters, for the log).
    Unreadable {
        /// The start of the message.
        text: String,
    },
    /// The server will not take the upgrade on this line after repeated tries.
    GivenUp,
}

/// Receives the events. Called from the channel's task: do not block.
#[uniffi::export(with_foreign)]
pub trait RemoteListener: Send + Sync {
    /// One event.
    fn event(&self, event: RemoteEvent);
    /// The link is up: the host sends `POST Sessions/Capabilities/Full` now.
    fn connected(&self);
}

fn command_of(c: RemoteCommand) -> RemoteCommandKind {
    match c {
        RemoteCommand::Pause => RemoteCommandKind::Pause,
        RemoteCommand::Proceed => RemoteCommandKind::Proceed,
        RemoteCommand::Toggle => RemoteCommandKind::Toggle,
        RemoteCommand::Stop => RemoteCommandKind::Stop,
        RemoteCommand::JumpOn(seconds) => RemoteCommandKind::JumpOn { seconds },
        RemoteCommand::Forward => RemoteCommandKind::Forward,
        RemoteCommand::Back => RemoteCommandKind::Back,
        RemoteCommand::Next => RemoteCommandKind::Next,
        RemoteCommand::Previous => RemoteCommandKind::Previous,
    }
}

fn order_of(o: PlayOrder) -> RemotePlayOrder {
    RemotePlayOrder {
        item_ids: o.item_ids,
        start_index: o.start_index as u64,
        start: o.start,
        media_source_id: o.media_source_id,
        audio_index: o.audio_index,
        subtitle_index: o.subtitle_index,
    }
}

/// Times of the channel; tests shrink them.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Timing {
    pub keep_alive: Duration,
    /// A link that was down for less than this was not down long enough to have missed an event worth a refresh: the
    /// screens on show keep their pages (a flaky network flapping every few seconds must not reload every page each time).
    pub refresh_after_outage: Duration,
    /// A send that has not finished after this long means the link is stuck.
    pub send_limit: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            keep_alive: Duration::from_secs_f64(KEEP_ALIVE_INTERVAL),
            refresh_after_outage: Duration::from_secs(5),
            send_limit: Duration::from_secs(20),
        }
    }
}

/// What the reader task hands to the supervisor.
enum Frame {
    Text(Option<String>),
    Ended(LinkError),
}

/// The control channel of one account.
#[derive(uniffi::Object)]
pub struct RemoteChannel {
    link: Arc<dyn WebSocketLink>,
    listener: Arc<dyn RemoteListener>,
    host: Host,
    account: AccountRef,
    timing: Timing,
    stopped: Arc<AtomicBool>,
    wake: Arc<Notify>,
    running: AtomicBool,
    /// When the link went down, while it is down (the first loss of a series of failed reconnects), on the runtime's
    /// clock. On Apple that clock does not count the time the device sleeps, and a dead link is only noticed at wake,
    /// so this alone measures a night in the background as a couple of seconds.
    lost_since: std::sync::Mutex<Option<tokio::time::Instant>>,
    /// When the link was last known to be alive, on the host's clock (wall time: it counts sleep): the last frame that
    /// came in, or a keep-alive of ours that went out on time ([`Self::kept_up`]).
    alive_at: std::sync::Mutex<Option<f64>>,
}

impl RemoteChannel {
    pub(crate) fn build(
        link: Arc<dyn WebSocketLink>,
        listener: Arc<dyn RemoteListener>,
        host: Host,
        account: AccountRef,
        timing: Timing,
    ) -> Arc<Self> {
        Arc::new(Self {
            link,
            listener,
            host,
            account,
            timing,
            stopped: Arc::new(AtomicBool::new(false)),
            wake: Arc::new(Notify::new()),
            running: AtomicBool::new(false),
            lost_since: std::sync::Mutex::new(None),
            alive_at: std::sync::Mutex::new(None),
        })
    }

    /// The socket address of the account: `/socket`, `/embywebsocket` on Emby.
    pub(crate) fn url(&self) -> Option<String> {
        let url = RemoteControl::socket_url(
            &self.account.base_url,
            &self.account.token,
            &self.account.device_id,
        )?;
        Some(if self.account.server_kind == ServerKind::Emby {
            url.replacen("/socket?", "/embywebsocket?", 1)
        } else {
            url
        })
    }

    /// `LibraryChanged` / `UserDataChanged` invalidate the cached lists and titles of the account.
    fn feed_cache(&self, raw: &str) {
        if let (Some(cache), Some(event)) = (&self.host.cache, swiftly_cache::parse_ws(raw)) {
            cache.apply_event(&self.account, &event);
        }
    }

    /// The channel is back after a REAL drop that lasted at least `Timing::refresh_after_outage` (the link ended:
    /// closed, a failed read or write, a send that hung, a Ping nobody answered). Events may have been missed
    /// meanwhile, so every list is stale and the screens on show refresh in the background: each keeps its standing page and patches it with the fresh answer (no blanking, no
    /// spinner), and a burst counts once. A plain keep-alive cycle never gets here: it keeps the link up.
    fn refresh_after_drop(&self) {
        if let Some(cache) = &self.host.cache {
            cache.lists_changed(&self.account);
            cache.link_came_back();
        }
    }

    fn emit_all(&self, outs: Vec<RemoteOutput>, raw: &str) {
        for out in outs {
            let event = match out {
                RemoteOutput::Command(c) => RemoteEvent::Command {
                    command: command_of(c),
                },
                RemoteOutput::SyncPlay(SyncPlayPostDirection::ConnectionLost) => {
                    RemoteEvent::ConnectionLost
                }
                RemoteOutput::SyncPlay(SyncPlayPostDirection::ConnectionAgain) => {
                    RemoteEvent::ConnectionAgain
                }
                RemoteOutput::SyncPlay(_) => RemoteEvent::SyncPlay {
                    text: raw.to_owned(),
                },
                RemoteOutput::Handoff(device) => RemoteEvent::Handoff { device },
                RemoteOutput::Play(order) => RemoteEvent::Play {
                    order: order_of(order),
                },
                RemoteOutput::Unreadable(text) => RemoteEvent::Unreadable { text },
                RemoteOutput::Send(_) => continue,
            };
            self.listener.event(event);
        }
    }

    async fn run(self: Arc<Self>) {
        let mut ctl = RemoteControl::new();
        while !self.stopped.load(Ordering::SeqCst) {
            let Some(url) = self.url() else { break };
            match self.link.connect(url).await {
                Ok(()) => {
                    self.listener.connected();
                    let ended = self.session(&mut ctl, Arc::clone(&self.link)).await;
                    // Ends the reader of this session before `connect` starts the next one.
                    self.link.close();
                    if self.stopped.load(Ordering::SeqCst) {
                        break;
                    }
                    if self.gives_up(&mut ctl, &ended) {
                        self.listener.event(RemoteEvent::GivenUp);
                        break;
                    }
                }
                Err(failure) => {
                    let ended = LinkError::from(failure);
                    if self.gives_up(&mut ctl, &ended) {
                        self.listener.event(RemoteEvent::GivenUp);
                        break;
                    }
                }
            }
            self.lost_since
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get_or_insert_with(tokio::time::Instant::now);
            self.emit_all(vec![ctl.on_lost()], "");
            let wait = Duration::from_secs_f64(ctl.next_reconnect_wait());
            let _ = tokio::time::timeout(wait, self.wake.notified()).await;
        }
    }

    /// A frame came in: remembers when, and returns when the link was alive before it (`None` for the first of all).
    fn heard_now(&self) -> Option<f64> {
        self.alive_at
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .replace(self.host.clock.now())
    }

    /// A keep-alive of ours went out. A quiet link carries nothing else (Jellyfin does not answer a client that
    /// reports on time, and the pongs of the socket do not reach `receive` on every platform), so without this a
    /// link that was quiet for ten minutes would measure ten minutes of outage at its first flap.
    ///
    /// It counts only when it went out on time, that is when the link was alive about one interval ago. After a
    /// longer gap the device slept (the runtime's timers do not count sleep on Apple): the send may have gone into a
    /// socket that died meanwhile, so it proves nothing, and only a frame of the server revives the mark.
    fn kept_up(&self) {
        let now = self.host.clock.now();
        let on_time = (self.timing.keep_alive + self.timing.send_limit).as_secs_f64();
        let mut alive = self
            .alive_at
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if alive.is_some_and(|before| now - before <= on_time) {
            *alive = Some(now);
        }
    }

    /// How long the link that is back was gone, `None` when that is unknown (so a refresh is the safe answer).
    /// Two measures, the longer counts: the time since the loss was noticed (the runtime's clock, awake time only),
    /// and the silence since the link was last alive on the host's clock, which also counts the time the device
    /// slept. The link was alive at the last frame or at the last keep-alive that went out on time, so on a quiet
    /// link that silence includes the stretch before the drop, up to one keep-alive interval, which was no outage:
    /// that much is taken off (a flaky link must not refresh every page each time).
    fn outage(&self, heard_before: Option<f64>) -> Option<Duration> {
        let noticed = self
            .lost_since
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
            .map(|since| since.elapsed());
        let silent = heard_before.map(|before| {
            Duration::from_secs_f64((self.host.clock.now() - before).max(0.0))
                .saturating_sub(self.timing.keep_alive)
        });
        match (noticed, silent) {
            (None, None) => None,
            (a, b) => Some(a.unwrap_or_default().max(b.unwrap_or_default())),
        }
    }

    fn gives_up(&self, ctl: &mut RemoteControl, ended: &LinkError) -> bool {
        match ended {
            LinkError::NotSupported => true,
            LinkError::SetupFailed { code } => ctl.line_setup_gives_up(*code),
            LinkError::Other(_) => false,
        }
    }

    /// Reads one link until it ends; sends the keep-alive. Only a failed read or write, or a send that
    /// hangs, ends it; a quiet server is normal.
    async fn session(&self, ctl: &mut RemoteControl, link: Arc<dyn WebSocketLink>) -> LinkError {
        let (tx, mut rx) = mpsc::unbounded_channel::<Frame>();
        let reader = Arc::clone(&link);
        self.host.spawner.spawn(Box::pin(async move {
            loop {
                match reader.receive().await {
                    Ok(frame) => {
                        if tx.send(Frame::Text(frame)).is_err() {
                            return;
                        }
                    }
                    Err(failure) => {
                        let _ = tx.send(Frame::Ended(failure.into()));
                        return;
                    }
                }
            }
        }));
        let mut keep_every = self.timing.keep_alive;
        let mut kept = tokio::time::Instant::now();
        loop {
            if self.stopped.load(Ordering::SeqCst) {
                link.close();
                return LinkError::Other("stopped".to_owned());
            }
            match tokio::time::timeout_at(kept + keep_every, rx.recv()).await {
                Ok(Some(Frame::Text(frame))) => {
                    let heard_before = self.heard_now();
                    if let Some(text) = frame {
                        if let Some(secs) = RemoteControl::force_keep_alive_interval(&text) {
                            // The server names its limit; report at half of it, never slower than the default.
                            keep_every = Duration::from_secs_f64(secs).min(self.timing.keep_alive);
                            kept = tokio::time::Instant::now();
                        }
                        self.feed_cache(&text);
                        for out in ctl.process(&text) {
                            if let RemoteOutput::Send(reply) = out {
                                if let Err(e) = self.send_checked(&link, reply).await {
                                    return e;
                                }
                                continue;
                            }
                            self.emit_all(vec![out], &text);
                        }
                    }
                    if let Some(again) = ctl.on_received() {
                        // Events may have been missed while the link was down: the screens on show refresh, but only
                        // after a real outage (the reconnect backoff keeps running either way).
                        let outage = self.outage(heard_before);
                        if outage.is_none_or(|o| o >= self.timing.refresh_after_outage) {
                            self.refresh_after_drop();
                        }
                        self.emit_all(vec![again], "");
                    }
                }
                Ok(Some(Frame::Ended(e))) => return e,
                Ok(None) => return LinkError::Other("reader ended".to_owned()),
                Err(_) => {
                    kept = tokio::time::Instant::now();
                    if let Err(e) = self.send_checked(&link, KEEP_ALIVE.to_owned()).await {
                        return e;
                    }
                    self.kept_up();
                }
            }
        }
    }

    /// A send that fails, or does not finish within the limit, ends the link.
    async fn send_checked(
        &self,
        link: &Arc<dyn WebSocketLink>,
        text: String,
    ) -> Result<(), LinkError> {
        match tokio::time::timeout(self.timing.send_limit, link.send(text)).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(e.into()),
            Err(_) => {
                link.close();
                Err(LinkError::Other("send stuck".to_owned()))
            }
        }
    }
}

#[uniffi::export]
impl RemoteChannel {
    /// Connects and keeps the channel up (reconnect with backoff) until `stop`. Calling it
    /// twice does nothing.
    pub fn start(self: Arc<Self>) {
        if self.running.swap(true, Ordering::SeqCst) {
            return;
        }
        self.stopped.store(false, Ordering::SeqCst);
        let me = Arc::clone(&self);
        self.host.spawner.spawn(Box::pin(async move {
            Arc::clone(&me).run().await;
            me.running.store(false, Ordering::SeqCst);
        }));
    }

    /// Closes the link and ends the loop.
    pub fn stop(&self) {
        self.stopped.store(true, Ordering::SeqCst);
        self.link.close();
        self.wake.notify_one();
    }

    /// The address the channel connects to (without the token it is not usable; for logs the
    /// host should not print it).
    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use swiftly_vm::{Clock, Spawner, SystemClock};
    use tokio::sync::Mutex as AsyncMutex;

    struct TokioSpawn;
    impl Spawner for TokioSpawn {
        fn spawn(&self, task: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>) {
            drop(tokio::spawn(task));
        }
    }

    /// The host's clock in a test: it follows the runtime's (paused) time and can jump ahead, like the wall clock of a
    /// phone that slept while the runtime's own clock stood still.
    struct TestClock {
        start: tokio::time::Instant,
        slept: Mutex<f64>,
    }

    impl TestClock {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                start: tokio::time::Instant::now(),
                slept: Mutex::new(0.0),
            })
        }

        /// The device sleeps for this long without the runtime's clock noticing.
        fn sleep_through(&self, seconds: f64) {
            *self.slept.lock().unwrap() += seconds;
        }
    }

    impl Clock for TestClock {
        fn now(&self) -> f64 {
            self.start.elapsed().as_secs_f64() + *self.slept.lock().unwrap()
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

    type Frame = Result<Option<String>, SocketFailure>;

    /// One scripted connection.
    struct Conn {
        rx: AsyncMutex<mpsc::UnboundedReceiver<Frame>>,
        tx: mpsc::UnboundedSender<Frame>,
        sent: Mutex<Vec<String>>,
    }

    fn link() -> Arc<Conn> {
        let (tx, rx) = mpsc::unbounded_channel();
        Arc::new(Conn {
            rx: AsyncMutex::new(rx),
            tx,
            sent: Mutex::new(Vec::new()),
        })
    }

    /// The host's socket object: every `connect` takes the next scripted connection.
    struct Connector {
        links: Mutex<Vec<Arc<Conn>>>,
        current: Mutex<Option<Arc<Conn>>>,
        urls: Mutex<Vec<String>>,
        /// A send never finishes (a link that accepts nothing more).
        stuck: std::sync::atomic::AtomicBool,
    }

    impl Connector {
        fn conn(&self) -> Arc<Conn> {
            self.current.lock().unwrap().clone().expect("opened")
        }
    }

    #[async_trait::async_trait]
    impl WebSocketLink for Connector {
        async fn connect(&self, url: String) -> Result<(), SocketFailure> {
            self.urls.lock().unwrap().push(url);
            let mut links = self.links.lock().unwrap();
            if links.is_empty() {
                return Err(SocketFailure::Other {
                    message: "no more links".into(),
                });
            }
            *self.current.lock().unwrap() = Some(links.remove(0));
            Ok(())
        }
        async fn receive(&self) -> Result<Option<String>, SocketFailure> {
            let conn = self.conn();
            let frame = conn.rx.lock().await.recv().await;
            frame.unwrap_or_else(|| {
                Err(SocketFailure::Other {
                    message: "gone".into(),
                })
            })
        }
        async fn send(&self, text: String) -> Result<(), SocketFailure> {
            if self.stuck.load(Ordering::SeqCst) {
                std::future::pending::<()>().await;
            }
            self.conn().sent.lock().unwrap().push(text);
            Ok(())
        }
        fn close(&self) {
            if let Some(c) = self.current.lock().unwrap().as_ref() {
                let _ = c.tx.send(Err(SocketFailure::Other {
                    message: "closed".into(),
                }));
            }
        }
    }

    #[derive(Default)]
    struct Listener {
        events: Mutex<Vec<RemoteEvent>>,
        connected: Mutex<u32>,
    }

    impl RemoteListener for Listener {
        fn event(&self, event: RemoteEvent) {
            self.events.lock().unwrap().push(event);
        }
        fn connected(&self) {
            *self.connected.lock().unwrap() += 1;
        }
    }

    fn channel(
        kind: ServerKind,
        links: Vec<Arc<Conn>>,
    ) -> (Arc<RemoteChannel>, Arc<Connector>, Arc<Listener>) {
        channel_with(kind, links, None)
    }

    fn channel_with(
        kind: ServerKind,
        links: Vec<Arc<Conn>>,
        cache: Option<swiftly_cache::EntityCache>,
    ) -> (Arc<RemoteChannel>, Arc<Connector>, Arc<Listener>) {
        let (c, connector, listener, _clock) = channel_clocked(kind, links, cache);
        (c, connector, listener)
    }

    fn channel_clocked(
        kind: ServerKind,
        links: Vec<Arc<Conn>>,
        cache: Option<swiftly_cache::EntityCache>,
    ) -> (
        Arc<RemoteChannel>,
        Arc<Connector>,
        Arc<Listener>,
        Arc<TestClock>,
    ) {
        let clock = TestClock::new();
        let connector = Arc::new(Connector {
            links: Mutex::new(links),
            current: Mutex::new(None),
            urls: Mutex::new(Vec::new()),
            stuck: std::sync::atomic::AtomicBool::new(false),
        });
        let listener = Arc::new(Listener::default());
        let host = Host {
            spawner: Arc::new(TokioSpawn),
            clock: Arc::clone(&clock) as _,
            store: Arc::new(NoStore),
            locale: swiftly_l10n::Locale::parse("en"),
            device_name: "test".into(),
            client_version: "0".into(),
            cache: cache.map(swiftly_vm::ViewCache::new),
        };
        let account = AccountRef {
            base_url: "https://jf.example".into(),
            user_id: "u1".into(),
            token: "tok en".into(),
            server_kind: kind,
            device_id: "dev".into(),
            plex_machine_id: None,
            plex_account_token: None,
        };
        let c = RemoteChannel::build(
            Arc::clone(&connector) as _,
            Arc::clone(&listener) as _,
            host,
            account,
            Timing::default(),
        );
        (c, connector, listener, clock)
    }

    async fn pass(seconds: u64) {
        tokio::time::sleep(Duration::from_secs(seconds)).await;
    }

    #[tokio::test(start_paused = true)]
    async fn emby_uses_its_own_socket_path_and_jellyfin_the_plain_one() {
        let (jf, ..) = channel(ServerKind::Jellyfin, vec![]);
        let (em, ..) = channel(ServerKind::Emby, vec![]);
        assert_eq!(
            jf.url().unwrap(),
            "wss://jf.example/socket?ApiKey=tok%20en&deviceId=dev"
        );
        assert_eq!(
            em.url().unwrap(),
            "wss://jf.example/embywebsocket?ApiKey=tok%20en&deviceId=dev"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn commands_orders_and_syncplay_reach_the_listener() {
        let l = link();
        let (c, _conn, listener) = channel(ServerKind::Jellyfin, vec![Arc::clone(&l)]);
        Arc::clone(&c).start();
        pass(1).await;
        assert_eq!(*listener.connected.lock().unwrap(), 1);
        let pause = r#"{"MessageType":"Playstate","Data":{"Command":"Pause"}}"#;
        let force = r#"{"MessageType":"ForceKeepAlive","Data":60}"#;
        let group = r#"{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"g","Type":"GroupLeft","Data":"g"}}"#;
        for text in [pause, force, group] {
            l.tx.send(Ok(Some(text.to_owned()))).unwrap();
        }
        pass(1).await;
        let events = listener.events.lock().unwrap().clone();
        assert_eq!(
            events[0],
            RemoteEvent::Command {
                command: RemoteCommandKind::Pause
            }
        );
        assert!(
            matches!(&events[1], RemoteEvent::SyncPlay { text } if text == group),
            "{events:?}"
        );
        // ForceKeepAlive is answered on the link, not handed to the app.
        assert_eq!(l.sent.lock().unwrap().as_slice(), [KEEP_ALIVE]);
        c.stop();
    }

    #[tokio::test(start_paused = true)]
    async fn a_keep_alive_goes_out_every_thirty_seconds() {
        let l = link();
        let (c, ..) = channel(ServerKind::Jellyfin, vec![Arc::clone(&l)]);
        Arc::clone(&c).start();
        pass(1).await;
        for _ in 0..2 {
            pass(30).await;
            l.tx.send(Ok(None)).unwrap(); // a skipped frame still counts as life
        }
        assert!(
            l.sent.lock().unwrap().len() >= 2,
            "{:?}",
            l.sent.lock().unwrap()
        );
        assert!(l.sent.lock().unwrap().iter().all(|s| s == KEEP_ALIVE));
        c.stop();
    }

    const FORCE: &str = r#"{"MessageType":"ForceKeepAlive","Data":60}"#;

    /// What a Jellyfin server does: `ForceKeepAlive` on connect, then nothing while the client reports.
    #[tokio::test(start_paused = true)]
    async fn a_link_that_only_gets_quiet_stays_up_for_eleven_minutes() {
        let l = link();
        let (c, conn, listener) = channel(ServerKind::Jellyfin, vec![Arc::clone(&l), link()]);
        Arc::clone(&c).start();
        pass(1).await;
        l.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(11 * 60).await;
        assert_eq!(conn.urls.lock().unwrap().len(), 1, "no reconnect");
        assert_eq!(*listener.connected.lock().unwrap(), 1);
        assert!(listener.events.lock().unwrap().is_empty());
        // The answer to the force message plus a keep-alive every 30 s.
        assert!(
            l.sent.lock().unwrap().len() >= 22,
            "{}",
            l.sent.lock().unwrap().len()
        );
        assert!(l.sent.lock().unwrap().iter().all(|s| s == KEEP_ALIVE));
        c.stop();
    }

    #[tokio::test(start_paused = true)]
    async fn the_limit_in_force_keep_alive_sets_the_interval() {
        let l = link();
        let (c, ..) = channel(ServerKind::Jellyfin, vec![Arc::clone(&l)]);
        Arc::clone(&c).start();
        pass(1).await;
        l.tx.send(Ok(Some(
            r#"{"MessageType":"ForceKeepAlive","Data":20}"#.to_owned(),
        )))
        .unwrap();
        pass(1).await;
        let before = l.sent.lock().unwrap().len(); // the answer
        pass(35).await; // 10 s apart: three keep-alives
        assert_eq!(l.sent.lock().unwrap().len() - before, 3);
        c.stop();
    }

    #[tokio::test(start_paused = true)]
    async fn a_failed_read_reconnects_with_capabilities_again() {
        let (first, second) = (link(), link());
        let (c, conn, listener) = channel(
            ServerKind::Jellyfin,
            vec![Arc::clone(&first), Arc::clone(&second)],
        );
        Arc::clone(&c).start();
        pass(1).await;
        first
            .tx
            .send(Err(SocketFailure::Other {
                message: "Software caused connection abort".into(),
            }))
            .unwrap();
        // The backoff (2 s) passes, the second link opens.
        pass(5).await;
        assert_eq!(conn.urls.lock().unwrap().len(), 2);
        assert_eq!(*listener.connected.lock().unwrap(), 2);
        assert!(
            listener
                .events
                .lock()
                .unwrap()
                .contains(&RemoteEvent::ConnectionLost)
        );
        // Something arrives on the new link: SyncPlay hears that the channel is back.
        second.tx.send(Ok(None)).unwrap();
        pass(1).await;
        assert!(
            listener
                .events
                .lock()
                .unwrap()
                .contains(&RemoteEvent::ConnectionAgain)
        );
        c.stop();
    }

    #[tokio::test(start_paused = true)]
    async fn a_send_that_never_finishes_drops_the_link() {
        let (first, second) = (link(), link());
        let (c, conn, _listener) = channel(
            ServerKind::Jellyfin,
            vec![Arc::clone(&first), Arc::clone(&second)],
        );
        Arc::clone(&c).start();
        pass(1).await;
        conn.stuck.store(true, Ordering::SeqCst);
        // The keep-alive at 30 s hangs, the 20 s limit passes, the 2 s backoff passes.
        pass(30 + 20 + 5).await;
        conn.stuck.store(false, Ordering::SeqCst);
        assert_eq!(conn.urls.lock().unwrap().len(), 2);
        c.stop();
    }

    fn cache_and_scope() -> (swiftly_cache::EntityCache, swiftly_cache::Scope) {
        use swiftly_cache::{CacheConfig, EntityCache};
        let cache = EntityCache::in_memory(CacheConfig::default()).unwrap();
        let scope = swiftly_vm::ViewCache::scope(&AccountRef {
            base_url: "https://jf.example".into(),
            user_id: "u1".into(),
            token: "tok en".into(),
            server_kind: ServerKind::Jellyfin,
            device_id: "dev".into(),
            plex_machine_id: None,
            plex_account_token: None,
        });
        let t = cache.ticket(&scope);
        cache
            .put_list(&t, "home", &["a".to_owned()], Some(1))
            .unwrap();
        (cache, scope)
    }

    /// How often the channel told the open titles that the link was back (the count of its host's cache).
    fn links_back(c: &RemoteChannel) -> u64 {
        c.host.cache.as_ref().unwrap().links_back()
    }

    fn stale_heard(heard: &Mutex<Vec<swiftly_cache::CacheChange>>) -> usize {
        heard
            .lock()
            .unwrap()
            .iter()
            .filter(|c| matches!(c, swiftly_cache::CacheChange::ListsStale(_)))
            .count()
    }

    /// After a REAL drop the screens on show are told (once) to refresh in the background: events may have been
    /// missed, and without this the open home/library/detail page stayed stale until it was visited again.
    #[tokio::test(start_paused = true)]
    async fn a_reconnect_after_a_real_drop_tells_the_screens_to_refresh_once() {
        use swiftly_cache::CacheChange;
        let (cache, scope) = cache_and_scope();
        let heard = Arc::new(Mutex::new(Vec::new()));
        let h = Arc::clone(&heard);
        cache.subscribe(move |ch: &CacheChange| h.lock().unwrap().push(ch.clone()));
        let (first, second) = (link(), link());
        let (c, ..) = channel_with(
            ServerKind::Jellyfin,
            vec![Arc::clone(&first), Arc::clone(&second)],
            Some(cache.clone()),
        );
        Arc::clone(&c).start();
        pass(1).await;
        first.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(1).await;
        assert_eq!(stale_heard(&heard), 0, "the first connect tells no screen");
        first
            .tx
            .send(Err(SocketFailure::Other {
                message: "gone".into(),
            }))
            .unwrap();
        pass(10).await;
        assert_eq!(
            stale_heard(&heard),
            0,
            "nothing until the new link is heard"
        );
        second.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(1).await;
        // More frames on the new link do not tell the screens again.
        second.tx.send(Ok(None)).unwrap();
        pass(1).await;
        assert!(cache.get_list(&scope, "home").unwrap().stale);
        assert_eq!(stale_heard(&heard), 1, "{:?}", heard.lock().unwrap());
        // An open title that gave up on advancing is told as well: the failure may have been the outage's.
        assert_eq!(links_back(&c), 1, "the playback is told once");
        c.stop();
    }

    /// A link that comes back within a few seconds (a flaky network, a roaming phone) has missed nothing worth a reload
    /// of every open page: the app still hears that the connection is back, the pages keep standing.
    #[tokio::test(start_paused = true)]
    async fn a_reconnect_within_seconds_does_not_refresh_the_pages() {
        use swiftly_cache::CacheChange;
        let (cache, scope) = cache_and_scope();
        let heard = Arc::new(Mutex::new(Vec::new()));
        let h = Arc::clone(&heard);
        cache.subscribe(move |ch: &CacheChange| h.lock().unwrap().push(ch.clone()));
        let (first, second) = (link(), link());
        let (c, _conn, listener) = channel_with(
            ServerKind::Jellyfin,
            vec![Arc::clone(&first), Arc::clone(&second)],
            Some(cache.clone()),
        );
        Arc::clone(&c).start();
        pass(1).await;
        first.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(1).await;
        first
            .tx
            .send(Err(SocketFailure::Other {
                message: "gone".into(),
            }))
            .unwrap();
        pass(2).await;
        second.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(1).await;
        assert_eq!(stale_heard(&heard), 0, "{:?}", heard.lock().unwrap());
        assert!(!cache.get_list(&scope, "home").unwrap().stale);
        assert_eq!(links_back(&c), 0, "a short flap tells no title");
        assert!(
            listener
                .events
                .lock()
                .unwrap()
                .contains(&RemoteEvent::ConnectionAgain),
            "the app still hears that the connection is back"
        );
        c.stop();
    }

    /// A phone that slept for an hour: the runtime's clock did not count it, so the drop is only noticed when the
    /// device wakes and the new link is up ~2 s later by that clock. The outage still was an hour long: the screens on
    /// show refresh, because events were missed.
    #[tokio::test(start_paused = true)]
    async fn a_reconnect_after_the_device_slept_refreshes_the_pages() {
        use swiftly_cache::CacheChange;
        let (cache, scope) = cache_and_scope();
        let heard = Arc::new(Mutex::new(Vec::new()));
        let h = Arc::clone(&heard);
        cache.subscribe(move |ch: &CacheChange| h.lock().unwrap().push(ch.clone()));
        let (first, second) = (link(), link());
        let (c, _conn, _listener, clock) = channel_clocked(
            ServerKind::Jellyfin,
            vec![Arc::clone(&first), Arc::clone(&second)],
            Some(cache.clone()),
        );
        Arc::clone(&c).start();
        pass(1).await;
        first.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(1).await;
        // The device sleeps; at wake the dead link is noticed and the new one is up two seconds later.
        clock.sleep_through(3600.0);
        first
            .tx
            .send(Err(SocketFailure::Other {
                message: "gone".into(),
            }))
            .unwrap();
        pass(2).await;
        second.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(1).await;
        assert_eq!(stale_heard(&heard), 1, "{:?}", heard.lock().unwrap());
        assert!(cache.get_list(&scope, "home").unwrap().stale);
        c.stop();
    }

    /// A link that stayed quiet for `quiet` seconds (the server does not answer a client that reports on time, so
    /// only our own keep-alives went over it), then flapped for two seconds: how many screens were told to refresh.
    async fn flap_after_quiet(quiet: u64) -> (usize, bool) {
        use swiftly_cache::CacheChange;
        let (cache, scope) = cache_and_scope();
        let heard = Arc::new(Mutex::new(Vec::new()));
        let h = Arc::clone(&heard);
        cache.subscribe(move |ch: &CacheChange| h.lock().unwrap().push(ch.clone()));
        let (first, second) = (link(), link());
        let (c, ..) = channel_with(
            ServerKind::Jellyfin,
            vec![Arc::clone(&first), Arc::clone(&second)],
            Some(cache.clone()),
        );
        Arc::clone(&c).start();
        pass(1).await;
        first.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(quiet).await;
        first
            .tx
            .send(Err(SocketFailure::Other {
                message: "gone".into(),
            }))
            .unwrap();
        pass(2).await;
        second.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(1).await;
        c.stop();
        let told = stale_heard(&heard);
        (told, cache.get_list(&scope, "home").unwrap().stale)
    }

    /// The other way round: a flap after a quiet stretch (the last frame came up to one keep-alive interval before
    /// the drop) was not an outage of that length.
    #[tokio::test(start_paused = true)]
    async fn a_flap_after_a_quiet_stretch_does_not_refresh_the_pages() {
        assert_eq!(flap_after_quiet(25).await, (0, false));
    }

    /// The same after ten quiet minutes: Jellyfin does not answer a client that reports on time, so the server sent
    /// nothing for that long. Our own keep-alives that went out are what the quiet stretch is measured against.
    #[tokio::test(start_paused = true)]
    async fn a_flap_after_ten_quiet_minutes_does_not_refresh_the_pages() {
        assert_eq!(flap_after_quiet(600).await, (0, false));
    }

    /// A keep-alive that goes out when the device wakes from a sleep proves nothing about the link (the send may
    /// land in a dead socket): the sleep still counts as the outage when the link then drops.
    #[tokio::test(start_paused = true)]
    async fn a_keep_alive_sent_after_a_sleep_does_not_hide_the_sleep() {
        use swiftly_cache::CacheChange;
        let (cache, scope) = cache_and_scope();
        let heard = Arc::new(Mutex::new(Vec::new()));
        let h = Arc::clone(&heard);
        cache.subscribe(move |ch: &CacheChange| h.lock().unwrap().push(ch.clone()));
        let (first, second) = (link(), link());
        let (c, conn, _listener, clock) = channel_clocked(
            ServerKind::Jellyfin,
            vec![Arc::clone(&first), Arc::clone(&second)],
            Some(cache.clone()),
        );
        Arc::clone(&c).start();
        pass(1).await;
        first.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(100).await;
        clock.sleep_through(3600.0);
        let sent = conn.conn().sent.lock().unwrap().len();
        pass(31).await;
        assert!(
            conn.conn().sent.lock().unwrap().len() > sent,
            "a keep-alive went out at wake"
        );
        first
            .tx
            .send(Err(SocketFailure::Other {
                message: "gone".into(),
            }))
            .unwrap();
        pass(2).await;
        second.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(1).await;
        assert_eq!(stale_heard(&heard), 1, "{:?}", heard.lock().unwrap());
        assert!(cache.get_list(&scope, "home").unwrap().stale);
        c.stop();
    }

    /// A plain keep-alive cycle (a quiet server, the client reporting every 30 s) tells no screen and marks nothing.
    #[tokio::test(start_paused = true)]
    async fn a_quiet_link_with_keep_alives_tells_no_screen() {
        use swiftly_cache::CacheChange;
        let (cache, scope) = cache_and_scope();
        let heard = Arc::new(Mutex::new(Vec::new()));
        let h = Arc::clone(&heard);
        cache.subscribe(move |ch: &CacheChange| h.lock().unwrap().push(ch.clone()));
        let l = link();
        let (c, conn, _listener) = channel_with(
            ServerKind::Jellyfin,
            vec![Arc::clone(&l)],
            Some(cache.clone()),
        );
        Arc::clone(&c).start();
        pass(1).await;
        l.tx.send(Ok(Some(FORCE.to_owned()))).unwrap();
        pass(300).await; // five minutes: ten keep-alives, no frame from the server
        assert_eq!(conn.urls.lock().unwrap().len(), 1, "the link stayed up");
        assert_eq!(stale_heard(&heard), 0);
        assert!(!cache.get_list(&scope, "home").unwrap().stale);
        c.stop();
    }

    #[tokio::test(start_paused = true)]
    async fn a_platform_without_websocket_gives_up_at_once() {
        struct No;
        #[async_trait::async_trait]
        impl WebSocketLink for No {
            async fn connect(&self, _: String) -> Result<(), SocketFailure> {
                Err(SocketFailure::NotSupported)
            }
            async fn receive(&self) -> Result<Option<String>, SocketFailure> {
                Ok(None)
            }
            async fn send(&self, _: String) -> Result<(), SocketFailure> {
                Ok(())
            }
            fn close(&self) {}
        }
        let (c, _, listener) = channel(ServerKind::Jellyfin, vec![]);
        let c = RemoteChannel::build(
            Arc::new(No),
            Arc::clone(&listener) as _,
            Host {
                spawner: Arc::new(TokioSpawn),
                clock: Arc::new(SystemClock),
                store: Arc::new(NoStore),
                locale: swiftly_l10n::Locale::parse("en"),
                device_name: "t".into(),
                client_version: "0".into(),
                cache: None,
            },
            c.account.clone(),
            Timing::default(),
        );
        Arc::clone(&c).start();
        pass(1).await;
        assert_eq!(
            listener.events.lock().unwrap().as_slice(),
            [RemoteEvent::GivenUp]
        );
    }
}
