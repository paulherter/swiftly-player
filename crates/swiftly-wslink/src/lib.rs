//! The desktop WebSocket: a `WebSocketLink` over tungstenite for the control channel
//! (`/socket`) and SyncPlay. One object serves all reconnects; `connect` replaces the socket behind
//! it. A worker thread owns the socket (short read timeouts so it can also send and stop); the
//! async side talks to it through channels.

use std::io::ErrorKind as IoKind;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

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
#[derive(Default)]
pub struct TungsteniteLink {
    live: Mutex<Option<Live>>,
    incoming: tokio::sync::Mutex<Option<UnboundedReceiver<Incoming>>>,
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

fn set_timeout(socket: &WebSocket<MaybeTlsStream<TcpStream>>, t: Option<Duration>) {
    let tcp = match socket.get_ref() {
        MaybeTlsStream::Plain(s) => Some(s),
        MaybeTlsStream::Rustls(s) => Some(s.get_ref()),
        _ => None,
    };
    if let Some(tcp) = tcp {
        let _ = tcp.set_read_timeout(t);
    }
}

fn work(
    mut socket: WebSocket<MaybeTlsStream<TcpStream>>,
    out: &mpsc::Receiver<String>,
    incoming: &UnboundedSender<Incoming>,
    stop: &AtomicBool,
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
            Ok(_) => {
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
        std::thread::spawn(move || work(socket, &out_rx, &tx, &flag));
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

    #[tokio::test]
    async fn a_refused_connection_is_an_error_not_a_hang() {
        let link = TungsteniteLink::default();
        let r = link.connect("ws://127.0.0.1:1/socket".into()).await;
        assert!(matches!(r, Err(SocketFailure::Other { .. })), "{r:?}");
    }
}
