//! A control channel against a server that behaves like Jellyfin's `SessionWebSocketListener`:
//! `ForceKeepAlive` (limit 60 s) on connect, and again only for a socket that has sent nothing for 45 s;
//! a socket without any client frame for 60 s is dropped. A healthy client that reports every 30 s therefore
//! never hears from the server again, and must still keep its socket for as long as it runs.
//!
//!   SOAK_SECS=660 cargo test -p swiftly-wslink --test idle_drop_soak -- --ignored --nocapture
//!
//! The same run against the real test server needs `JF_URL`, `JF_USER`, `JF_PASS` (see `live_socket_soak`).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use swiftly_hardening::soak::{host, workload};
use swiftly_uniffi::{RemoteEvent, RemoteListener};
use swiftly_wslink::TungsteniteLink;
use tungstenite::{Message, accept};

const LOST_AFTER: Duration = Duration::from_secs(60);
const FORCE_AFTER: Duration = Duration::from_secs(45);

#[derive(Default)]
struct Tally {
    sockets: AtomicUsize,
    dropped: AtomicUsize,
    keep_alives: AtomicUsize,
    lines: Mutex<Vec<String>>,
}

fn serve(tally: Arc<Tally>, t0: Instant) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        while let Ok((stream, _)) = listener.accept() {
            let tally = Arc::clone(&tally);
            std::thread::spawn(move || {
                let Ok(mut ws) = accept(stream) else { return };
                let n = tally.sockets.fetch_add(1, Ordering::SeqCst) + 1;
                tally.lines.lock().unwrap().push(format!(
                    "[{:6.1}s] server: socket #{n} open, ForceKeepAlive 60",
                    t0.elapsed().as_secs_f64()
                ));
                let _ = ws.send(Message::text(
                    r#"{"MessageType":"ForceKeepAlive","Data":60}"#,
                ));
                let _ = ws
                    .get_ref()
                    .set_read_timeout(Some(Duration::from_millis(500)));
                let (mut last, mut forced) = (Instant::now(), Instant::now());
                loop {
                    match ws.read() {
                        Ok(Message::Text(t)) => {
                            last = Instant::now();
                            if t.as_str().contains("KeepAlive") {
                                tally.keep_alives.fetch_add(1, Ordering::SeqCst);
                            }
                        }
                        Ok(Message::Close(_)) | Err(tungstenite::Error::ConnectionClosed) => return,
                        Ok(_) => last = Instant::now(),
                        Err(tungstenite::Error::Io(e))
                            if matches!(
                                e.kind(),
                                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                            ) => {}
                        Err(_) => return,
                    }
                    let idle = last.elapsed();
                    if idle >= LOST_AFTER {
                        tally.dropped.fetch_add(1, Ordering::SeqCst);
                        tally.lines.lock().unwrap().push(format!(
                            "[{:6.1}s] server: socket #{n} lost (no client frame for 60 s)",
                            t0.elapsed().as_secs_f64()
                        ));
                        return;
                    }
                    if idle > FORCE_AFTER && forced.elapsed() > Duration::from_secs(10) {
                        forced = Instant::now();
                        let _ = ws.send(Message::text(
                            r#"{"MessageType":"ForceKeepAlive","Data":60}"#,
                        ));
                    }
                }
            });
        }
    });
    port
}

struct Log(Instant, Arc<Mutex<Vec<String>>>);

impl RemoteListener for Log {
    fn event(&self, event: RemoteEvent) {
        self.1.lock().unwrap().push(format!(
            "[{:6.1}s] client: {event:?}",
            self.0.elapsed().as_secs_f64()
        ));
    }
    fn connected(&self) {
        self.1.lock().unwrap().push(format!(
            "[{:6.1}s] client: connected (capabilities would be reported)",
            self.0.elapsed().as_secs_f64()
        ));
    }
}

#[test]
#[ignore = "runs SOAK_SECS seconds (default 660)"]
fn the_socket_stays_up_against_a_jellyfin_like_idle_rule() {
    let secs: u64 = std::env::var("SOAK_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(660);
    let t0 = Instant::now();
    let tally = Arc::new(Tally::default());
    let port = serve(Arc::clone(&tally), t0);
    let ctl = host::Control::new();
    let core = swiftly_uniffi::Core::new(
        Arc::new(host::SoakPlatform(Arc::clone(&ctl))),
        Arc::new(host::SoakSecrets::new(Arc::clone(&ctl))),
        Arc::new(host::SoakKv::new(Arc::clone(&ctl))),
        Arc::new(host::SoakHttp::new(ctl)),
    );
    let log = Arc::new(Mutex::new(Vec::new()));
    let channel = core
        .remote_channel(
            workload::account(&format!("http://127.0.0.1:{port}"), "u1"),
            Arc::new(TungsteniteLink::default()),
            Arc::new(Log(t0, Arc::clone(&log))),
        )
        .unwrap();
    Arc::clone(&channel).start();
    std::thread::sleep(Duration::from_secs(secs));
    channel.stop();
    let mut all: Vec<String> = tally.lines.lock().unwrap().clone();
    all.extend(log.lock().unwrap().clone());
    all.sort();
    for l in &all {
        println!("{l}");
    }
    let (sockets, dropped, kept) = (
        tally.sockets.load(Ordering::SeqCst),
        tally.dropped.load(Ordering::SeqCst),
        tally.keep_alives.load(Ordering::SeqCst),
    );
    println!(
        "RESULT after {secs} s: {sockets} socket(s) opened, {dropped} dropped by the server, {kept} keep-alive frames received"
    );
    assert_eq!(
        sockets, 1,
        "the client reconnected: the socket did not stay up"
    );
}
