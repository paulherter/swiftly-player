//! Which runtime does reqwest need? Measured here, decided in README.md ("Runtime").
//!
//! * without any tokio context a reqwest request panics (no reactor);
//! * inside `async_compat::Compat` (what UniFFI wraps every exported async fn in) it works,
//!   also 12 requests at once;
//! * a task spawned on the handle of that runtime works without `Compat` (what `Core` does).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::io::{Read, Write};
use std::net::TcpListener;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::time::Instant;

use async_compat::Compat;
use futures_executor::block_on;
use futures_util::FutureExt;
use futures_util::future::join_all;
use swiftly_net::{HttpRequest, HttpTransport, Method, ReqwestTransport, Url};

/// A tiny blocking HTTP server on a thread: every connection gets `{"ok":true}`.
fn serve() -> Url {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            std::thread::spawn(move || {
                let mut buf = [0u8; 2048];
                let _ = stream.read(&mut buf);
                let body = r#"{"ok":true}"#;
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            });
        }
    });
    Url::parse(&format!("http://127.0.0.1:{port}/ping")).unwrap()
}

fn get(url: &Url) -> HttpRequest {
    HttpRequest::new(Method::Get, url.clone())
}

#[test]
fn reqwest_needs_a_tokio_context_and_async_compat_is_enough() {
    let url = serve();

    // 1. No runtime: building the client is fine, using it is not.
    let transport = ReqwestTransport::new().unwrap();
    let bare = catch_unwind(AssertUnwindSafe(|| {
        block_on(transport.send(get(&url))).map(|r| r.status)
    }));
    eprintln!(
        "runtime: without a tokio context -> {}",
        match &bare {
            Ok(r) => format!("{r:?}"),
            Err(_) => "panic (no reactor)".to_owned(),
        }
    );
    assert!(
        bare.is_err(),
        "reqwest is expected to panic without a reactor"
    );

    // 2. Inside Compat (the single async-compat thread): works.
    let started = Instant::now();
    let answer = block_on(Compat::new(transport.send(get(&url)))).unwrap();
    eprintln!("runtime: Compat, first request {:?}", started.elapsed());
    assert_eq!(
        (answer.status, answer.body.as_slice()),
        (200, br#"{"ok":true}"#.as_slice())
    );

    // 3. Twelve at once (a home load does about that many), still Compat only.
    let started = Instant::now();
    let all = block_on(Compat::new(join_all(
        (0..12).map(|_| transport.send(get(&url))),
    )));
    eprintln!(
        "runtime: Compat, 12 parallel requests {:?}",
        started.elapsed()
    );
    assert!(
        all.iter()
            .all(|r| r.as_ref().is_ok_and(|r| r.status == 200))
    );

    // 4. A task spawned on the async-compat runtime's handle needs no wrapper.
    let handle = Compat::new(async { tokio::runtime::Handle::current() })
        .now_or_never()
        .unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let t = std::sync::Arc::new(transport);
    handle.spawn(async move {
        let status = t.send(get(&url)).await.map(|r| r.status);
        let _ = tx.send(status);
    });
    assert_eq!(rx.recv().unwrap().unwrap(), 200);
}
