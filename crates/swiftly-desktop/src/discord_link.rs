//! The Discord presence on Windows and Linux ("Discord" switch in Settings, off by default): what plays is shown in the
//! user's own profile through the local IPC socket (Linux/Unix: `discord-ipc-N` sockets, Windows: named pipes).
//!
//! The rules (what to show, when to send, the paused text, the frames, the paths) live in `swiftly_support::discord`;
//! this module is the I/O only. It never reports an error to the user: a missing Discord is simply nothing, and the
//! connection is tried again quietly, at most every [`RETRY`].
//!
//! The socket is served by a worker thread, so a slow or hung Discord never holds the UI frame. [`Presence`] is the
//! per-frame feed; [`Client`] is the worker's state machine over a [`Connector`] (a fake one in the tests).

use std::io::{self, Read, Write};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use swiftly_support::discord::{
    self, DiscordDisplay, DiscordEnv, DiscordPlatform, DiscordPresence, PresenceAction,
};

use crate::media_keys::NowPlaying;

/// Whether this build can show the presence at all (the Settings row is offered only then). The Mac app has its own
/// presence client and its sandbox cannot reach the socket.
pub const AVAILABLE: bool = cfg!(any(
    windows,
    all(
        unix,
        not(any(
            target_os = "macos",
            target_os = "ios",
            target_os = "android"
        ))
    )
));

/// The quiet pause between two attempts to reach Discord.
pub const RETRY: Duration = Duration::from_secs(30);

/// How long the worker waits for Discord's answer to the handshake.
const READY_WAIT: Duration = Duration::from_secs(3);

/// The biggest frame body read (Discord's answers are a few hundred bytes).
const MAX_BODY: usize = 1 << 20;

/// What the app asks of the worker.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// Show this.
    Show(DiscordDisplay),
    /// Show nothing.
    Clear,
}

/// One frame read from Discord.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Incoming {
    /// The opcode.
    pub op: u32,
    /// The body.
    pub body: Vec<u8>,
}

/// An open connection.
pub trait Wire: Send {
    /// Writes bytes (a whole frame).
    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()>;
    /// The next frame, waiting at most `wait`. `Ok(None)`: nothing arrived. `Err`: the connection is gone.
    fn next_frame(&mut self, wait: Duration) -> io::Result<Option<Incoming>>;
}

/// Where connections come from.
pub trait Connector {
    /// Tries the places in order; the first that opens is the connection.
    fn open(&mut self) -> Option<Box<dyn Wire>>;
}

impl Connector for Box<dyn Connector + Send> {
    fn open(&mut self) -> Option<Box<dyn Wire>> {
        (**self).open()
    }
}

/// The worker's link state.
enum Link {
    /// No connection; `retry_at` is the earliest next attempt (`None`: try at once).
    Down { retry_at: Option<Instant> },
    /// Handshake done.
    Up(Box<dyn Wire>),
}

/// The worker's state machine: wants a display, keeps a connection if it can, sends only what changed.
pub struct Client<C: Connector> {
    connector: C,
    link: Link,
    /// What the app wants shown (`None`: nothing).
    wanted: Option<DiscordDisplay>,
    /// What Discord was last told on this connection (`None`: nothing shown there).
    sent: Option<DiscordDisplay>,
    pid: i64,
    nonce: u64,
}

impl<C: Connector> Client<C> {
    /// A client without a connection.
    pub fn new(connector: C, pid: i64) -> Client<C> {
        Client {
            connector,
            link: Link::Down { retry_at: None },
            wanted: None,
            sent: None,
            pid,
            nonce: 0,
        }
    }

    /// Whether a connection is up (tests).
    pub fn is_up(&self) -> bool {
        matches!(self.link, Link::Up(_))
    }

    /// A command from the app.
    pub fn apply(&mut self, cmd: Command, now: Instant) {
        self.wanted = match cmd {
            Command::Show(d) => Some(d),
            Command::Clear => None,
        };
        self.settle(now);
    }

    /// A quiet moment: reconnects when due and notices a lost connection.
    pub fn tick(&mut self, now: Instant) {
        self.settle(now);
    }

    /// How long the worker may sleep before it has something to do.
    pub fn next_wake(&self, now: Instant) -> Duration {
        match &self.link {
            Link::Up(_) => Duration::from_secs(5),
            Link::Down { retry_at: Some(t) } if self.wanted.is_some() => t
                .saturating_duration_since(now)
                .max(Duration::from_millis(50)),
            Link::Down { .. } => Duration::from_secs(5),
        }
    }

    fn settle(&mut self, now: Instant) {
        // Answers of Discord are read and dropped; a close frame or a read error means it went away.
        if let Link::Up(wire) = &mut self.link {
            loop {
                match wire.next_frame(Duration::ZERO) {
                    Ok(Some(f)) if f.op == discord::OP_CLOSE => {
                        self.lost(now);
                        break;
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => break,
                    Err(_) => {
                        self.lost(now);
                        break;
                    }
                }
            }
        }
        if self.wanted.is_none() && self.sent.is_none() {
            // Nothing shown and nothing wanted: keep an open connection, but never start one for nothing.
            return;
        }
        if let Link::Down { retry_at } = &self.link {
            if self.wanted.is_none() {
                // The connection that showed something is gone, and with it the display.
                self.sent = None;
                return;
            }
            if retry_at.is_some_and(|t| now < t) {
                return;
            }
            match self.connect() {
                Some(wire) => {
                    self.sent = None;
                    self.link = Link::Up(wire);
                }
                None => {
                    self.link = Link::Down {
                        retry_at: Some(now + RETRY),
                    };
                    return;
                }
            }
        }
        if self.wanted != self.sent {
            let frame = self.next_activity_frame();
            if let Link::Up(wire) = &mut self.link {
                if wire.write_all(&frame).is_err() {
                    self.lost(now);
                    return;
                }
                self.sent = self.wanted.clone();
            }
        }
    }

    fn next_activity_frame(&mut self) -> Vec<u8> {
        self.nonce += 1;
        let nonce = format!("{}-{}", self.pid, self.nonce);
        discord::set_activity_frame(self.pid, self.wanted.as_ref(), &nonce)
    }

    fn lost(&mut self, now: Instant) {
        self.sent = None;
        self.link = Link::Down {
            retry_at: Some(now + RETRY),
        };
    }

    /// Opens a connection and does the handshake; `None` when Discord is not there or does not answer.
    fn connect(&mut self) -> Option<Box<dyn Wire>> {
        let mut wire = self.connector.open()?;
        wire.write_all(&discord::handshake_frame(discord::CLIENT_ID))
            .ok()?;
        // Discord answers with READY (opcode 1); anything else (a close, an error) ends the attempt.
        match wire.next_frame(READY_WAIT) {
            Ok(Some(f)) if f.op != discord::OP_CLOSE => Some(wire),
            _ => None,
        }
    }
}

/// The real places: sockets or pipes from the environment.
pub struct RealConnector {
    paths: Vec<String>,
}

impl RealConnector {
    /// The candidate paths of this machine.
    pub fn from_env() -> RealConnector {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let env = DiscordEnv {
            xdg_runtime_dir: var("XDG_RUNTIME_DIR"),
            tmpdir: var("TMPDIR"),
            tmp: var("TMP"),
            temp: var("TEMP"),
            temporary_directory: None,
        };
        let platform = if cfg!(windows) {
            DiscordPlatform::Windows
        } else {
            DiscordPlatform::Unix
        };
        let mut paths = discord::candidate_paths(&env, platform);
        paths.retain(|p| cfg!(windows) || discord::path_fits(p));
        RealConnector { paths }
    }
}

impl Connector for RealConnector {
    fn open(&mut self) -> Option<Box<dyn Wire>> {
        self.paths.iter().find_map(|p| open_path(p))
    }
}

#[cfg(unix)]
fn open_path(path: &str) -> Option<Box<dyn Wire>> {
    let stream = std::os::unix::net::UnixStream::connect(path).ok()?;
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    let reader = stream.try_clone().ok()?;
    Some(Box::new(StreamWire::new(
        Box::new(reader),
        Box::new(stream),
    )))
}

#[cfg(windows)]
fn open_path(path: &str) -> Option<Box<dyn Wire>> {
    let pipe = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .ok()?;
    let reader = pipe.try_clone().ok()?;
    Some(Box::new(StreamWire::new(Box::new(reader), Box::new(pipe))))
}

#[cfg(not(any(unix, windows)))]
fn open_path(_path: &str) -> Option<Box<dyn Wire>> {
    None
}

/// A connection over any reader and writer: a reader thread parses the frames, so waiting for one has a timeout on
/// every platform (a named pipe has no read timeout of its own).
pub struct StreamWire {
    writer: Box<dyn Write + Send>,
    frames: Receiver<io::Result<Incoming>>,
}

impl StreamWire {
    /// Starts the reader thread; it ends when the stream closes.
    pub fn new(reader: Box<dyn Read + Send>, writer: Box<dyn Write + Send>) -> StreamWire {
        let (tx, frames) = mpsc::channel();
        std::thread::Builder::new()
            .name("discord-read".into())
            .spawn(move || read_frames(reader, tx))
            .ok();
        StreamWire { writer, frames }
    }
}

fn read_frames(mut reader: Box<dyn Read + Send>, tx: Sender<io::Result<Incoming>>) {
    loop {
        let mut head = [0u8; 8];
        if let Err(e) = reader.read_exact(&mut head) {
            let _ = tx.send(Err(e));
            return;
        }
        let op = u32::from_le_bytes([head[0], head[1], head[2], head[3]]);
        let len = u32::from_le_bytes([head[4], head[5], head[6], head[7]]) as usize;
        if len > MAX_BODY {
            let _ = tx.send(Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "frame too big",
            )));
            return;
        }
        let mut body = vec![0u8; len];
        if let Err(e) = reader.read_exact(&mut body) {
            let _ = tx.send(Err(e));
            return;
        }
        if tx.send(Ok(Incoming { op, body })).is_err() {
            return;
        }
    }
}

impl Wire for StreamWire {
    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.writer.write_all(bytes)?;
        self.writer.flush()
    }

    fn next_frame(&mut self, wait: Duration) -> io::Result<Option<Incoming>> {
        let got = if wait.is_zero() {
            self.frames.try_recv().map_err(|e| match e {
                mpsc::TryRecvError::Empty => RecvTimeoutError::Timeout,
                mpsc::TryRecvError::Disconnected => RecvTimeoutError::Disconnected,
            })
        } else {
            self.frames.recv_timeout(wait)
        };
        match got {
            Ok(Ok(f)) => Ok(Some(f)),
            Ok(Err(e)) => Err(e),
            Err(RecvTimeoutError::Timeout) => Ok(None),
            Err(RecvTimeoutError::Disconnected) => Err(io::ErrorKind::BrokenPipe.into()),
        }
    }
}

/// The worker: owns a [`Client`] and serves the commands of the app.
fn serve<C: Connector>(mut client: Client<C>, rx: Receiver<Command>) {
    loop {
        let now = Instant::now();
        match rx.recv_timeout(client.next_wake(now)) {
            Ok(mut cmd) => {
                // Only the latest wish counts.
                while let Ok(newer) = rx.try_recv() {
                    cmd = newer;
                }
                client.apply(cmd, Instant::now());
            }
            Err(RecvTimeoutError::Timeout) => client.tick(Instant::now()),
            Err(RecvTimeoutError::Disconnected) => {
                // The app is closing: clear what is shown.
                client.apply(Command::Clear, Instant::now());
                return;
            }
        }
    }
}

/// The per-frame feed from the player to the presence: the shared rules decide, the worker sends.
pub struct Presence {
    rules: DiscordPresence,
    tx: Option<Sender<Command>>,
    worker: Option<std::thread::JoinHandle<()>>,
    connector: Option<Box<dyn FnOnce() -> Box<dyn Connector + Send> + Send>>,
}

impl Presence {
    /// A feed that serves the real socket (the worker starts with the first title shown, not before).
    pub fn real() -> Presence {
        Presence {
            rules: DiscordPresence::new(),
            tx: None,
            worker: None,
            connector: Some(Box::new(|| Box::new(RealConnector::from_env()))),
        }
    }

    /// A feed over another connector (the tests of the whole path).
    pub fn with_connector(
        make: impl FnOnce() -> Box<dyn Connector + Send> + Send + 'static,
    ) -> Presence {
        Presence {
            rules: DiscordPresence::new(),
            tx: None,
            worker: None,
            connector: Some(Box::new(make)),
        }
    }

    /// Call once per frame. `allowed` is the Settings switch; `now_unix` the wall clock in seconds. With the switch off
    /// or no player open, a shown display is cleared.
    pub fn update(&mut self, now: Option<&NowPlaying>, allowed: bool, now_unix: f64) {
        let action = match now {
            Some(n) if allowed => {
                let (title, subline) = lines_of(n);
                self.rules
                    .report(
                        &title,
                        subline.as_deref(),
                        n.position_s,
                        n.meta.duration_s.unwrap_or(0.0),
                        n.playing,
                        true,
                        now_unix,
                        &|v| crate::player_screen::play_time(v),
                    )
                    .action
            }
            _ => self.rules.tidy_away(),
        };
        match action {
            PresenceAction::Nothing => {}
            PresenceAction::Show(d) => self.send(Command::Show(d)),
            PresenceAction::Clear => self.send(Command::Clear),
        }
    }

    /// Whether something is shown in the profile now (see `DiscordPresence::is_showing`).
    pub fn is_showing(&self) -> bool {
        self.rules.is_showing()
    }

    fn send(&mut self, cmd: Command) {
        if self.tx.is_none() {
            let Some(make) = self.connector.take() else {
                return;
            };
            let (tx, rx) = mpsc::channel();
            let client = Client::new(make(), i64::from(std::process::id()));
            let Ok(handle) = std::thread::Builder::new()
                .name("discord-link".into())
                .spawn(move || serve(client, rx))
            else {
                return;
            };
            self.worker = Some(handle);
            self.tx = Some(tx);
        }
        if let Some(tx) = &self.tx {
            let _ = tx.send(cmd);
        }
    }
}

impl Drop for Presence {
    /// Closing the feed ends the worker, which clears the display on its way out.
    fn drop(&mut self) {
        // The worker clears the display when its channel closes; wait for it so the clear goes out before the exit.
        self.tx = None;
        if let Some(h) = self.worker.take() {
            let _ = h.join();
        }
    }
}

/// The title and subline of what plays (`PlaybackHub.report`): the player card carries an episode's own name as the
/// title, the series as the album and the episode code as the artist.
fn lines_of(n: &NowPlaying) -> (String, Option<String>) {
    discord::lines_for(
        n.meta.album.as_deref(),
        &n.meta.title,
        n.meta.artist.as_deref(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_keys::Metadata;
    use std::sync::{Arc, Mutex};

    /// What the fake Discord saw and what it will answer.
    #[derive(Default)]
    struct Fake {
        written: Vec<Vec<u8>>,
        answers: Vec<io::Result<Incoming>>,
        opens: usize,
        reachable: bool,
    }

    struct FakeConnector(Arc<Mutex<Fake>>);
    struct FakeWire(Arc<Mutex<Fake>>);

    impl Connector for FakeConnector {
        fn open(&mut self) -> Option<Box<dyn Wire>> {
            let mut f = self.0.lock().unwrap();
            f.opens += 1;
            if !f.reachable {
                return None;
            }
            // READY answers the handshake.
            f.answers.push(Ok(Incoming {
                op: discord::OP_FRAME,
                body: br#"{"evt":"READY"}"#.to_vec(),
            }));
            Some(Box::new(FakeWire(Arc::clone(&self.0))))
        }
    }

    impl Wire for FakeWire {
        fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
            self.0.lock().unwrap().written.push(bytes.to_vec());
            Ok(())
        }
        fn next_frame(&mut self, _wait: Duration) -> io::Result<Option<Incoming>> {
            let mut f = self.0.lock().unwrap();
            if f.answers.is_empty() {
                return Ok(None);
            }
            f.answers.remove(0).map(Some)
        }
    }

    fn client(reachable: bool) -> (Client<FakeConnector>, Arc<Mutex<Fake>>) {
        let fake = Arc::new(Mutex::new(Fake {
            reachable,
            ..Fake::default()
        }));
        (Client::new(FakeConnector(Arc::clone(&fake)), 7), fake)
    }

    fn display(title: &str) -> DiscordDisplay {
        DiscordDisplay {
            title: title.into(),
            subline: None,
            from: Some(100.0),
            until: Some(200.0),
        }
    }

    fn body_of(frame: &[u8]) -> serde_json::Value {
        let len = u32::from_le_bytes([frame[4], frame[5], frame[6], frame[7]]) as usize;
        assert_eq!(frame.len(), 8 + len, "the length field matches the body");
        serde_json::from_slice(&frame[8..]).unwrap()
    }

    #[test]
    fn a_show_connects_with_the_handshake_and_then_sends_the_activity() {
        let (mut c, fake) = client(true);
        let t0 = Instant::now();
        c.apply(Command::Show(display("Film")), t0);
        assert!(c.is_up());
        let f = fake.lock().unwrap();
        assert_eq!(f.written.len(), 2);
        assert_eq!(f.written[0], discord::handshake_frame(discord::CLIENT_ID));
        assert_eq!(u32::from_le_bytes(f.written[1][..4].try_into().unwrap()), 1);
        let v = body_of(&f.written[1]);
        assert_eq!(v["cmd"], "SET_ACTIVITY");
        assert_eq!(v["args"]["pid"], 7);
        assert_eq!(v["args"]["activity"]["details"], "Film");
        assert_eq!(v["args"]["activity"]["timestamps"]["start"], 100_000);
    }

    #[test]
    fn the_same_display_is_not_sent_twice_and_a_clear_has_no_activity() {
        let (mut c, fake) = client(true);
        let t0 = Instant::now();
        c.apply(Command::Show(display("Film")), t0);
        c.apply(Command::Show(display("Film")), t0);
        c.tick(t0);
        assert_eq!(
            fake.lock().unwrap().written.len(),
            2,
            "handshake + one show"
        );
        c.apply(Command::Clear, t0);
        let f = fake.lock().unwrap();
        assert_eq!(f.written.len(), 3);
        let v = body_of(&f.written[2]);
        assert_eq!(v["cmd"], "SET_ACTIVITY");
        assert!(v["args"].get("activity").is_none());
    }

    #[test]
    fn a_clear_without_a_connection_does_nothing() {
        let (mut c, fake) = client(true);
        c.apply(Command::Clear, Instant::now());
        assert!(!c.is_up());
        assert_eq!(fake.lock().unwrap().opens, 0, "no connection for nothing");
    }

    #[test]
    fn a_missing_discord_is_tried_again_at_most_every_thirty_seconds() {
        let (mut c, fake) = client(false);
        let t0 = Instant::now();
        c.apply(Command::Show(display("Film")), t0);
        assert_eq!(fake.lock().unwrap().opens, 1);
        for s in [1, 5, 29] {
            c.tick(t0 + Duration::from_secs(s));
        }
        assert_eq!(fake.lock().unwrap().opens, 1, "quiet inside the pause");
        // Discord starts later: the next attempt after the pause connects and shows what is wanted.
        fake.lock().unwrap().reachable = true;
        c.tick(t0 + RETRY);
        assert!(c.is_up());
        assert_eq!(fake.lock().unwrap().opens, 2);
        let n = fake.lock().unwrap().written.len();
        assert_eq!(n, 2, "handshake and the wanted display");
    }

    #[test]
    fn a_lost_connection_reconnects_after_the_pause_and_sends_again() {
        let (mut c, fake) = client(true);
        let t0 = Instant::now();
        c.apply(Command::Show(display("Film")), t0);
        fake.lock()
            .unwrap()
            .answers
            .push(Err(io::ErrorKind::BrokenPipe.into()));
        c.tick(t0 + Duration::from_secs(1));
        assert!(!c.is_up());
        c.tick(t0 + Duration::from_secs(10));
        assert_eq!(fake.lock().unwrap().opens, 1, "not before the pause");
        c.tick(t0 + Duration::from_secs(32));
        assert!(c.is_up());
        let f = fake.lock().unwrap();
        assert_eq!(f.opens, 2);
        assert_eq!(f.written.len(), 4, "two handshakes, two shows");
    }

    #[test]
    fn a_close_frame_from_discord_ends_the_connection() {
        let (mut c, fake) = client(true);
        let t0 = Instant::now();
        c.apply(Command::Show(display("Film")), t0);
        fake.lock().unwrap().answers.push(Ok(Incoming {
            op: discord::OP_CLOSE,
            body: Vec::new(),
        }));
        c.tick(t0);
        assert!(!c.is_up());
    }

    #[test]
    fn a_refused_handshake_is_a_quiet_failure() {
        let (mut c, fake) = client(true);
        // The close frame is read first: Discord refuses the application.
        struct Refusing(FakeConnector);
        impl Connector for Refusing {
            fn open(&mut self) -> Option<Box<dyn Wire>> {
                let w = self.0.open()?;
                self.0.0.lock().unwrap().answers.clear();
                self.0.0.lock().unwrap().answers.push(Ok(Incoming {
                    op: discord::OP_CLOSE,
                    body: Vec::new(),
                }));
                Some(w)
            }
        }
        let _ = &mut c;
        let mut r = Client::new(Refusing(FakeConnector(Arc::clone(&fake))), 1);
        r.apply(Command::Show(display("Film")), Instant::now());
        assert!(!r.is_up());
        assert_eq!(fake.lock().unwrap().written.len(), 1, "the handshake only");
    }

    #[test]
    fn frames_cross_a_real_stream_in_both_directions() {
        // A reader over bytes: READY, then a close.
        let mut bytes = discord::frame(1, br#"{"evt":"READY"}"#);
        bytes.extend(discord::close_frame());
        let sink = Arc::new(Mutex::new(Vec::<u8>::new()));
        struct Shared(Arc<Mutex<Vec<u8>>>);
        impl Write for Shared {
            fn write(&mut self, b: &[u8]) -> io::Result<usize> {
                self.0.lock().unwrap().extend_from_slice(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let mut w = StreamWire::new(
            Box::new(io::Cursor::new(bytes)),
            Box::new(Shared(Arc::clone(&sink))),
        );
        let first = w.next_frame(Duration::from_secs(2)).unwrap().unwrap();
        assert_eq!(
            (first.op, first.body.as_slice()),
            (1, &br#"{"evt":"READY"}"#[..])
        );
        let second = w.next_frame(Duration::from_secs(2)).unwrap().unwrap();
        assert_eq!(second.op, discord::OP_CLOSE);
        // The end of the stream is a gone connection.
        assert!(w.next_frame(Duration::from_secs(2)).is_err());
        w.write_all(&discord::frame(1, b"x")).unwrap();
        assert_eq!(
            sink.lock().unwrap().as_slice(),
            &[1, 0, 0, 0, 1, 0, 0, 0, b'x']
        );
    }

    fn playing(title: &str, album: Option<&str>, playing: bool, pos: f64) -> NowPlaying {
        NowPlaying {
            meta: Metadata {
                item_id: "i".into(),
                title: title.into(),
                album: album.map(str::to_owned),
                artist: album.map(|_| "S2:E1".to_owned()),
                duration_s: Some(600.0),
                cover_url: None,
            },
            playing,
            position_s: pos,
            rate: 1.0,
            has_next: false,
        }
    }

    /// A connector the feed tests share with the test body.
    struct Shared2(Arc<Mutex<Fake>>);
    impl Connector for Shared2 {
        fn open(&mut self) -> Option<Box<dyn Wire>> {
            FakeConnector(Arc::clone(&self.0)).open()
        }
    }

    fn wait_for(fake: &Arc<Mutex<Fake>>, n: usize) {
        for _ in 0..200 {
            if fake.lock().unwrap().written.len() >= n {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("only {} frames", fake.lock().unwrap().written.len());
    }

    #[test]
    fn the_feed_follows_the_switch_pause_and_close() {
        let fake = Arc::new(Mutex::new(Fake {
            reachable: true,
            ..Fake::default()
        }));
        let f2 = Arc::clone(&fake);
        let mut p = Presence::with_connector(move || Box::new(Shared2(f2)));
        let ep = playing("Pilot", Some("Show"), true, 30.0);
        // Switch off: nothing, not even a worker.
        p.update(Some(&ep), false, 1000.0);
        assert!(fake.lock().unwrap().written.is_empty());
        // On: handshake + activity with the series as title and the bar.
        p.update(Some(&ep), true, 1000.0);
        wait_for(&fake, 2);
        {
            let f = fake.lock().unwrap();
            let v = body_of(&f.written[1]);
            assert_eq!(v["args"]["activity"]["details"], "Show");
            assert_eq!(v["args"]["activity"]["state"], "S2:E1 \u{b7} Pilot");
            assert_eq!(v["args"]["activity"]["timestamps"]["start"], 970_000);
            assert_eq!(v["args"]["activity"]["timestamps"]["end"], 1_570_000);
        }
        // Paused: no timestamps, the position in the text.
        p.update(
            Some(&playing("Pilot", Some("Show"), false, 45.0)),
            true,
            1015.0,
        );
        wait_for(&fake, 3);
        {
            let f = fake.lock().unwrap();
            let v = body_of(&f.written[2]);
            assert!(v["args"]["activity"].get("timestamps").is_none());
            assert_eq!(
                v["args"]["activity"]["state"],
                "S2:E1 \u{b7} Pilot \u{b7} 0:45 / 10:00"
            );
        }
        // The player closes: cleared.
        p.update(None, true, 1016.0);
        wait_for(&fake, 4);
        let f = fake.lock().unwrap();
        assert!(body_of(&f.written[3])["args"].get("activity").is_none());
    }

    #[test]
    fn an_unknown_runtime_shows_nothing() {
        let fake = Arc::new(Mutex::new(Fake {
            reachable: true,
            ..Fake::default()
        }));
        let f2 = Arc::clone(&fake);
        let mut p = Presence::with_connector(move || Box::new(Shared2(f2)));
        let mut n = playing("Film", None, true, 0.0);
        n.meta.duration_s = None;
        p.update(Some(&n), true, 1000.0);
        std::thread::sleep(Duration::from_millis(100));
        assert!(fake.lock().unwrap().written.is_empty());
    }

    fn now_of(playing: bool, position_s: f64, duration_s: Option<f64>) -> NowPlaying {
        NowPlaying {
            meta: Metadata {
                item_id: "i1".into(),
                title: "Pilot".into(),
                album: Some("Show".into()),
                artist: Some("S1:E1".into()),
                duration_s,
                cover_url: None,
            },
            playing,
            position_s,
            rate: 1.0,
            has_next: false,
        }
    }

    /// Waits (bounded) until the worker has written `n` frames; the worker is a thread, so the test polls its result.
    fn wait_for_frames(fake: &Arc<Mutex<Fake>>, n: usize) -> Vec<Vec<u8>> {
        for _ in 0..400 {
            let f = fake.lock().unwrap();
            if f.written.len() >= n {
                return f.written.clone();
            }
            drop(f);
            std::thread::yield_now();
            std::thread::sleep(Duration::from_millis(5));
        }
        fake.lock().unwrap().written.clone()
    }

    #[test]
    fn the_feed_shows_pauses_without_a_bar_and_clears_when_switched_off() {
        let fake = Arc::new(Mutex::new(Fake {
            reachable: true,
            ..Fake::default()
        }));
        let for_worker = Arc::clone(&fake);
        let mut p = Presence::with_connector(move || Box::new(FakeConnector(for_worker)));
        // Switched off: nothing is sent and no connection is made.
        p.update(Some(&now_of(true, 10.0, Some(100.0))), false, 1000.0);
        // Unknown runtime: nothing yet.
        p.update(Some(&now_of(true, 10.0, None)), true, 1000.0);
        assert_eq!(fake.lock().unwrap().opens, 0);
        // Playing: the series is the bold line, the episode below, a bar from start to end.
        p.update(Some(&now_of(true, 10.0, Some(100.0))), true, 1000.0);
        let w = wait_for_frames(&fake, 2);
        assert_eq!(w.len(), 2, "handshake + show");
        let a = &body_of(&w[1])["args"]["activity"];
        assert_eq!(a["details"], "Show");
        assert_eq!(a["state"], "S1:E1 \u{b7} Pilot");
        assert_eq!(a["timestamps"]["start"], 990_000);
        assert_eq!(a["timestamps"]["end"], 1_090_000);
        // A later tick of the same state sends nothing; pausing drops the bar and puts the position in the text.
        p.update(Some(&now_of(true, 10.4, Some(100.0))), true, 1000.4);
        p.update(Some(&now_of(false, 12.0, Some(100.0))), true, 1002.0);
        let w = wait_for_frames(&fake, 3);
        assert_eq!(w.len(), 3);
        let a = &body_of(&w[2])["args"]["activity"];
        assert!(a.get("timestamps").is_none());
        assert!(
            a["state"]
                .as_str()
                .unwrap()
                .starts_with("S1:E1 \u{b7} Pilot \u{b7} ")
        );
        // Switching it off clears.
        p.update(Some(&now_of(false, 12.0, Some(100.0))), false, 1003.0);
        let w = wait_for_frames(&fake, 4);
        assert_eq!(w.len(), 4);
        assert!(body_of(&w[3])["args"].get("activity").is_none());
        // Stopping with nothing shown sends nothing more.
        p.update(None, true, 1004.0);
        drop(p);
        assert_eq!(fake.lock().unwrap().written.len(), 4);
    }
}
