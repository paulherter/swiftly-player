//! The desktop WebSocket: a `WebSocketLink` over tungstenite for the control channel
//! (`/socket`) and SyncPlay. One object serves all reconnects; `connect` replaces the socket behind
//! it. A worker thread owns the socket (short read timeouts so it can also send and stop); the
//! async side talks to it through channels.

use std::io::ErrorKind as IoKind;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use swiftly_sync::{LinkPulse, PulseStep};
use swiftly_uniffi::{SocketFailure, WebSocketLink};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Error, Message, WebSocket};

type Incoming = Result<Option<String>, SocketFailure>;

struct Live {
    out: mpsc::Sender<String>,
    stop: Arc<AtomicBool>,
}

/// The link. Create one per account and hand it to `Core::remote_channel`.
pub struct TungsteniteLink {
    live: Mutex<Option<Live>>,
    incoming: tokio::sync::Mutex<Option<UnboundedReceiver<Incoming>>>,
    /// Silence before a Ping, and the wait for its answer.
    limits: (Duration, Duration),
}

impl Default for TungsteniteLink {
    fn default() -> Self {
        Self::with_limits(
            Duration::from_secs_f64(swiftly_sync::PING_AFTER),
            Duration::from_secs_f64(swiftly_sync::PONG_WITHIN),
        )
    }
}

impl TungsteniteLink {
    /// A link with other sign-of-life limits (tests): `ping_after` of silence sends a Ping, `pong_within` later
    /// without any frame the link counts as dead.
    #[must_use]
    pub fn with_limits(ping_after: Duration, pong_within: Duration) -> Self {
        Self {
            live: Mutex::new(None),
            incoming: tokio::sync::Mutex::new(None),
            limits: (ping_after, pong_within),
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn failure(e: &Error) -> SocketFailure {
    match e {
        Error::Http(r) => SocketFailure::SetupFailed {
            code: i32::from(r.status().as_u16()),
        },
        other => SocketFailure::Other {
            message: other.to_string(),
        },
    }
}

/// A write that cannot finish within this long ends the link: on a vanished peer the buffer fills and a blocking
/// write would hang for good.
const WRITE_LIMIT: Duration = Duration::from_secs(10);

fn set_timeout(socket: &WebSocket<MaybeTlsStream<TcpStream>>, t: Option<Duration>) {
    let tcp = match socket.get_ref() {
        MaybeTlsStream::Plain(s) => Some(s),
        MaybeTlsStream::Rustls(s) => Some(s.get_ref()),
        _ => None,
    };
    if let Some(tcp) = tcp {
        let _ = tcp.set_read_timeout(t);
        let _ = tcp.set_write_timeout(Some(WRITE_LIMIT));
    }
}

fn work(
    mut socket: WebSocket<MaybeTlsStream<TcpStream>>,
    out: &mpsc::Receiver<String>,
    incoming: &UnboundedSender<Incoming>,
    stop: &AtomicBool,
    mut pulse: LinkPulse,
) {
    loop {
        if stop.load(Ordering::Relaxed) {
            let _ = socket.close(None);
            let _ = socket.flush();
            return;
        }
        while let Ok(text) = out.try_recv() {
            if let Err(e) = socket.send(Message::text(text)) {
                let _ = incoming.send(Err(failure(&e)));
                return;
            }
        }
        match socket.read() {
            Ok(Message::Text(t)) => {
                pulse.heard(Instant::now());
                if incoming.send(Ok(Some(t.as_str().to_owned()))).is_err() {
                    return;
                }
            }
            Ok(Message::Close(_)) => {
                let _ = incoming.send(Err(SocketFailure::Other {
                    message: "closed".into(),
                }));
                return;
            }
            // The answer to our Ping (or the server's own Ping): proof of life, nothing to tell the channel.
            Ok(Message::Pong(_) | Message::Ping(_)) => pulse.heard(Instant::now()),
            Ok(_) => {
                pulse.heard(Instant::now());
                if incoming.send(Ok(None)).is_err() {
                    return;
                }
            }
            Err(Error::Io(e)) if matches!(e.kind(), IoKind::WouldBlock | IoKind::TimedOut) => {}
            Err(e) => {
                let _ = incoming.send(Err(failure(&e)));
                return;
            }
        }
        match pulse.step(Instant::now()) {
            PulseStep::Wait => {}
            PulseStep::SendPing => {
                if let Err(e) = socket.send(Message::Ping(Vec::new().into())) {
                    let _ = incoming.send(Err(failure(&e)));
                    return;
                }
            }
            PulseStep::Dead => {
                // A vanished peer (sleep, Wi-Fi switch) sends no close: only the missing answer shows it.
                let _ = incoming.send(Err(SocketFailure::Other {
                    message: "no answer to ping".into(),
                }));
                return;
            }
        }
    }
}

#[async_trait::async_trait]
impl WebSocketLink for TungsteniteLink {
    async fn connect(&self, url: String) -> Result<(), SocketFailure> {
        self.close();
        let socket = tokio::task::spawn_blocking(move || tungstenite::connect(url.as_str()))
            .await
            .map_err(|e| SocketFailure::Other {
                message: e.to_string(),
            })?
            .map_err(|e| failure(&e))?
            .0;
        set_timeout(&socket, Some(Duration::from_millis(100)));
        let (out, out_rx) = mpsc::channel();
        let (tx, rx) = unbounded_channel();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        let pulse = LinkPulse::with_limits(self.limits.0, self.limits.1, Instant::now());
        std::thread::spawn(move || work(socket, &out_rx, &tx, &flag, pulse));
        *lock(&self.live) = Some(Live { out, stop });
        *self.incoming.lock().await = Some(rx);
        Ok(())
    }

    async fn receive(&self) -> Incoming {
        let mut guard = self.incoming.lock().await;
        let Some(rx) = guard.as_mut() else {
            return Err(SocketFailure::Other {
                message: "not open".into(),
            });
        };
        rx.recv().await.unwrap_or(Err(SocketFailure::Other {
            message: "closed".into(),
        }))
    }

    async fn send(&self, text: String) -> Result<(), SocketFailure> {
        let live = lock(&self.live);
        let live = live.as_ref().ok_or(SocketFailure::Other {
            message: "not open".into(),
        })?;
        live.out.send(text).map_err(|_| SocketFailure::Other {
            message: "closed".into(),
        })
    }

    fn close(&self) {
        if let Some(live) = lock(&self.live).take() {
            live.stop.store(true, Ordering::Relaxed);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    /// A WebSocket server on localhost: greets, binary frame, then answers every text with an echo.
    fn fixture() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            while let Ok((stream, _)) = listener.accept() {
                std::thread::spawn(move || {
                    let Ok(mut ws) = tungstenite::accept(stream) else {
                        return;
                    };
                    let _ = ws.send(Message::text("hello"));
                    let _ = ws.send(Message::binary(vec![1, 2, 3]));
                    while let Ok(m) = ws.read() {
                        if let Message::Text(t) = m {
                            let _ = ws.send(Message::text(format!("echo:{}", t.as_str())));
                        }
                    }
                });
            }
        });
        format!("ws://127.0.0.1:{port}/socket?ApiKey=k&deviceId=d")
    }

    #[tokio::test]
    async fn open_receive_skip_send_close_and_reopen() {
        let url = fixture();
        let link = TungsteniteLink::default();
        assert!(link.send("x".into()).await.is_err(), "not open yet");
        link.connect(url.clone()).await.unwrap();
        assert_eq!(link.receive().await.unwrap(), Some("hello".into()));
        assert_eq!(
            link.receive().await.unwrap(),
            None,
            "binary frames are skipped"
        );
        link.send("ping".into()).await.unwrap();
        assert_eq!(link.receive().await.unwrap(), Some("echo:ping".into()));
        link.close();
        assert!(
            link.receive().await.is_err(),
            "a closed socket fails the pending receive"
        );
        // The same object opens again (reconnect).
        link.connect(url).await.unwrap();
        assert_eq!(link.receive().await.unwrap(), Some("hello".into()));
        link.close();
    }

    /// A server that completes the handshake and then never reads or answers again, like a peer that vanished
    /// after the machine slept or the Wi-Fi changed: the TCP connection stays open, nothing comes back.
    fn half_open() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            let mut keep = Vec::new();
            while let Ok((stream, _)) = listener.accept() {
                if let Ok(ws) = tungstenite::accept(stream) {
                    keep.push(ws); // held open, never read: no Pong, no close
                }
            }
        });
        format!("ws://127.0.0.1:{port}/socket?ApiKey=k&deviceId=d")
    }

    #[tokio::test]
    async fn a_peer_that_stops_answering_ends_the_link_with_a_failed_receive() {
        let link =
            TungsteniteLink::with_limits(Duration::from_millis(200), Duration::from_millis(300));
        link.connect(half_open()).await.unwrap();
        let began = Instant::now();
        let ended = tokio::time::timeout(Duration::from_secs(5), link.receive())
            .await
            .expect("a dead link must end the receive, not hang");
        assert!(
            matches!(&ended, Err(SocketFailure::Other { message }) if message.contains("ping")),
            "{ended:?}"
        );
        let waited = began.elapsed();
        assert!(
            waited >= Duration::from_millis(450) && waited < Duration::from_secs(2),
            "ended after {waited:?}: one ping window, not instantly and not never"
        );
    }

    #[tokio::test]
    async fn a_quiet_but_answering_server_keeps_the_link_up() {
        // The echo server reads (so it answers pings by itself); the link stays silent far longer than the limits.
        let link =
            TungsteniteLink::with_limits(Duration::from_millis(150), Duration::from_millis(250));
        link.connect(fixture()).await.unwrap();
        assert_eq!(link.receive().await.unwrap(), Some("hello".into()));
        assert_eq!(link.receive().await.unwrap(), None);
        let quiet = tokio::time::timeout(Duration::from_millis(1500), link.receive()).await;
        assert!(quiet.is_err(), "still up and quiet, got {quiet:?}");
        link.send("again".into()).await.unwrap();
        assert_eq!(link.receive().await.unwrap(), Some("echo:again".into()));
        link.close();
    }

    #[tokio::test]
    async fn a_refused_connection_is_an_error_not_a_hang() {
        let link = TungsteniteLink::default();
        let r = link.connect("ws://127.0.0.1:1/socket".into()).await;
        assert!(matches!(r, Err(SocketFailure::Other { .. })), "{r:?}");
    }
}
