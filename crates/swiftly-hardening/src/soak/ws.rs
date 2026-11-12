//! A WebSocket server for the soak: greets, sends a KeepAlive, then drops the connection after a short random time
//! (or at once), so the core's channel has to reconnect again and again.

use std::net::TcpListener;
use std::time::Duration;

use tungstenite::Message;

use crate::Rng;

/// Starts the server on a free local port; returns its HTTP base URL (the core turns it into `ws://`).
pub fn start(seed: u64) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    std::thread::spawn(move || {
        let mut rng = Rng::new(seed);
        for stream in listener.incoming().flatten() {
            let (immediate, life) = (rng.chance(30), 20 + rng.below(280));
            std::thread::spawn(move || {
                let Ok(mut ws) = tungstenite::accept(stream) else {
                    return;
                };
                if immediate {
                    return;
                }
                let _ = ws.send(Message::text(r#"{"MessageType":"KeepAlive"}"#));
                let _ = ws.send(Message::text(
                    r#"{"MessageType":"LibraryChanged","Data":{"ItemsAdded":[],"ItemsUpdated":[],"ItemsRemoved":[]}}"#,
                ));
                std::thread::sleep(Duration::from_millis(life));
                let _ = ws.close(None);
            });
        }
    });
    format!("http://127.0.0.1:{port}")
}
