//! The control channel (`/socket`, `/embywebsocket` on Emby): remote commands, play orders,
//! takeover hints and SyncPlay messages over a WebSocket the host implements (URLSession on
//! Apple, OkHttp on Android; a tungstenite one lives in `swiftly-net` for the desktop).
//!
//! The channel keeps the link alive (a keep-alive every 30 s, answers `ForceKeepAlive`), treats
//! 90 s without any frame as a dead link, reconnects with the backoff of `RemoteControl` (2, 4,
//! 8, 16, 30 s) and tells SyncPlay about every drop and return.

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
    pub silence: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            keep_alive: Duration::from_secs_f64(KEEP_ALIVE_INTERVAL),
            silence: Duration::from_secs(90),
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
            cache
                .entity_cache()
                .apply_event(&swiftly_vm::ViewCache::scope(&self.account), &event);
        }
    }

    fn refresh_cache(&self) {
        if let Some(cache) = &self.host.cache {
            cache
                .entity_cache()
                .lists_changed(&swiftly_vm::ViewCache::scope(&self.account));
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
            self.emit_all(vec![ctl.on_lost()], "");
            let wait = Duration::from_secs_f64(ctl.next_reconnect_wait());
            let _ = tokio::time::timeout(wait, self.wake.notified()).await;
        }
    }

    fn gives_up(&self, ctl: &mut RemoteControl, ended: &LinkError) -> bool {
        match ended {
            LinkError::NotSupported => true,
            LinkError::SetupFailed { code } => ctl.line_setup_gives_up(*code),
            LinkError::Other(_) => false,
        }
    }

    /// Reads one link until it ends; sends the keep-alive; a silent link is dead.
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
        let mut heard = tokio::time::Instant::now();
        let mut kept = tokio::time::Instant::now();
        loop {
            if self.stopped.load(Ordering::SeqCst) {
                link.close();
                return LinkError::Other("stopped".to_owned());
            }
            let next_keep = kept + self.timing.keep_alive;
            let dead_at = heard + self.timing.silence;
            let until = next_keep.min(dead_at);
            match tokio::time::timeout_at(until, rx.recv()).await {
                Ok(Some(Frame::Text(frame))) => {
                    heard = tokio::time::Instant::now();
                    if let Some(text) = frame {
                        self.feed_cache(&text);
                        for out in ctl.process(&text) {
                            if let RemoteOutput::Send(reply) = &out {
                                if let Err(e) = link.send(reply.clone()).await {
                                    return e.into();
                                }
                                continue;
                            }
                            self.emit_all(vec![out], &text);
                        }
                    }
                    if let Some(again) = ctl.on_received() {
                        // Events were missed while the link was down: refresh what is on screen.
                        self.refresh_cache();
                        self.emit_all(vec![again], "");
                    }
                }
                Ok(Some(Frame::Ended(e))) => return e,
                Ok(None) => return LinkError::Other("reader ended".to_owned()),
                Err(_) => {
                    if tokio::time::Instant::now() >= dead_at {
                        link.close();
                        return LinkError::Other("silent link".to_owned());
                    }
                    kept = tokio::time::Instant::now();
                    if let Err(e) = link.send(KEEP_ALIVE.to_owned()).await {
                        return e.into();
                    }
                }
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
    use swiftly_vm::{Spawner, SystemClock};
    use tokio::sync::Mutex as AsyncMutex;

    struct TokioSpawn;
    impl Spawner for TokioSpawn {
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
        let connector = Arc::new(Connector {
            links: Mutex::new(links),
            current: Mutex::new(None),
            urls: Mutex::new(Vec::new()),
        });
        let listener = Arc::new(Listener::default());
        let host = Host {
            spawner: Arc::new(TokioSpawn),
            clock: Arc::new(SystemClock),
            store: Arc::new(NoStore),
            locale: swiftly_l10n::Locale::parse("en"),
            device_name: "test".into(),
            client_version: "0".into(),
            cache: None,
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
        (c, connector, listener)
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

    #[tokio::test(start_paused = true)]
    async fn a_silent_link_is_dropped_and_reconnected_with_capabilities_again() {
        let (first, second) = (link(), link());
        let (c, conn, listener) = channel(
            ServerKind::Jellyfin,
            vec![Arc::clone(&first), Arc::clone(&second)],
        );
        Arc::clone(&c).start();
        pass(1).await;
        // 120 s of nothing: the 90 s watchdog fires, the backoff (2 s) passes, the second link opens.
        pass(120).await;
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
