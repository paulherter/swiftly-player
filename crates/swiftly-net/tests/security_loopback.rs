//! Security checks of the reqwest transport against throw-away servers on the loopback interface:
//! response size cap, header stripping on cross-origin redirects, refused redirect schemes,
//! and no secrets in `Debug` output.
#![cfg(feature = "reqwest")]
#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::sync::{Arc, Mutex};

use swiftly_net::{
    ErrorKind, HttpRequest, HttpTransport, Method, ReqwestTransport, TransportConfig, Url,
    url_error,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

const TOKEN: &str = "PLANTED-TOKEN-9f3a";
const COOKIE: &str = "PLANTED-COOKIE-77b1";

async fn serve(
    handler: impl Fn(String) -> Option<String> + Send + Sync + 'static,
) -> (u16, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    let handler = Arc::new(handler);
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            let handler = Arc::clone(&handler);
            let log = Arc::clone(&log);
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let n = socket.read(&mut buf).await.unwrap_or(0);
                let raw = String::from_utf8_lossy(&buf[..n]).to_string();
                log.lock().expect("lock").push(raw.clone());
                if let Some(answer) = handler(raw) {
                    let _ = socket.write_all(answer.as_bytes()).await;
                }
                let _ = socket.shutdown().await;
            });
        }
    });
    (port, seen)
}

fn request(url: &str) -> HttpRequest {
    let mut r = HttpRequest::new(Method::Get, Url::parse(url).expect("url"));
    r.set_header("Authorization", &format!("MediaBrowser Token=\"{TOKEN}\""));
    r.set_header("X-Plex-Token", TOKEN);
    r.set_header("Cookie", COOKIE);
    r.set_header("CF-Access-Client-Secret", TOKEN);
    r.set_header("Accept", "application/json");
    r
}

fn redirect_to(location: &str) -> String {
    format!(
        "HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    )
}

#[tokio::test]
async fn cross_origin_redirect_never_carries_credentials() {
    let (target, seen) = serve(|_| {
        Some("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".into())
    })
    .await;
    // Same host name, other port: a different origin, so every secret header must go.
    let location = format!("http://127.0.0.1:{target}/landing");
    let (origin, _) = serve(move |_| Some(redirect_to(&location))).await;
    let t = ReqwestTransport::new().expect("transport");
    let answer = t
        .send(request(&format!(
            "http://localhost:{origin}/start?api_key={TOKEN}"
        )))
        .await
        .expect("send");
    assert_eq!(answer.status, 200);
    let raw = seen.lock().expect("lock").join("\n");
    assert!(
        !raw.contains(TOKEN),
        "token leaked to the other origin: {raw}"
    );
    assert!(
        !raw.contains(COOKIE),
        "cookie leaked to the other origin: {raw}"
    );
    assert!(
        !raw.to_lowercase().contains("authorization"),
        "authorization leaked: {raw}"
    );
    assert!(
        !raw.to_lowercase().contains("cf-access"),
        "gateway header leaked: {raw}"
    );
}

#[tokio::test]
async fn redirect_to_other_schemes_is_refused() {
    for scheme in [
        "ftp://127.0.0.1/x",
        "file:///etc/passwd",
        "gopher://127.0.0.1/",
        "javascript:alert(1)",
    ] {
        let location = scheme.to_owned();
        let (origin, _) = serve(move |_| Some(redirect_to(&location))).await;
        let t = ReqwestTransport::new().expect("transport");
        let err = t
            .send(request(&format!("http://127.0.0.1:{origin}/")))
            .await
            .expect_err("refused");
        assert_eq!(err, ErrorKind::InvalidServerUrl, "{scheme}");
    }
}

#[tokio::test]
async fn body_over_the_cap_fails_instead_of_filling_memory() {
    let big = "x".repeat(10_000);
    let (port, _) = serve(move |_| {
        Some(format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{big}",
            big.len()
        ))
    })
    .await;
    let t = ReqwestTransport::with_config(TransportConfig {
        max_response_bytes: 1_000,
        ..TransportConfig::default()
    })
    .expect("transport");
    let err = t
        .send(request(&format!("http://127.0.0.1:{port}/")))
        .await
        .expect_err("too big");
    assert_eq!(
        err,
        ErrorKind::Network {
            code: url_error::CANNOT_PARSE_RESPONSE
        }
    );
    // Without a declared length (close-delimited body) the cap holds as well.
    let (port, _) = serve(|_| {
        Some(format!(
            "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{}",
            "y".repeat(10_000)
        ))
    })
    .await;
    let err = t
        .send(request(&format!("http://127.0.0.1:{port}/")))
        .await
        .expect_err("too big");
    assert_eq!(
        err,
        ErrorKind::Network {
            code: url_error::CANNOT_PARSE_RESPONSE
        }
    );
    // And a body under the cap still works.
    let (port, _) = serve(|_| {
        Some("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".into())
    })
    .await;
    assert_eq!(
        t.send(request(&format!("http://127.0.0.1:{port}/")))
            .await
            .expect("small")
            .body,
        b"ok"
    );
}

#[test]
fn debug_output_hides_every_planted_secret() {
    let mut r = request(&format!(
        "https://user:{TOKEN}@h.test/Items?ApiKey={TOKEN}&X-Plex-Token={TOKEN}&limit=5"
    ));
    r.body = Some(format!("{{\"Pw\":\"{TOKEN}\"}}").into_bytes());
    let shown = format!("{r:?}");
    assert!(!shown.contains(TOKEN) && !shown.contains(COOKIE), "{shown}");
    assert!(
        shown.contains("limit=5"),
        "non-secret parts stay readable: {shown}"
    );
    let response = swiftly_net::HttpResponse::new(200, format!("{{\"AccessToken\":\"{TOKEN}\"}}"))
        .with_header("Set-Cookie", COOKIE);
    let shown = format!("{response:?}");
    assert!(!shown.contains(TOKEN) && !shown.contains(COOKIE), "{shown}");
}
