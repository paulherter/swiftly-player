//! The reqwest transport against a throw-away server on 127.0.0.1 (no real server involved).
#![cfg(feature = "reqwest")]
#![allow(clippy::expect_used, clippy::unwrap_used)] // test helpers outside #[test] fns

use std::sync::{Arc, Mutex};
use std::time::Duration;

use swiftly_net::{
    ErrorKind, HttpRequest, HttpTransport, Method, ReqwestTransport, TransportConfig, Url,
    url_error,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Serves every connection with `handler(raw_request) -> raw_response`.
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

fn ok(body: &str) -> String {
    format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn get(port: u16, path: &str) -> HttpRequest {
    let url = Url::parse(&format!("http://127.0.0.1:{port}{path}")).expect("url");
    let mut r = HttpRequest::new(Method::Get, url);
    r.set_header("Authorization", "MediaBrowser Client=\"t\"");
    r.set_header("Accept", "application/json");
    r
}

#[tokio::test]
async fn plain_get_returns_status_headers_body() {
    let (port, seen) = serve(|_| Some(ok(r#"{"a":1}"#))).await;
    let t = ReqwestTransport::new().expect("transport");
    let r = t
        .send(get(port, "/System/Info/Public?x=1"))
        .await
        .expect("answer");
    assert_eq!(r.status, 200);
    assert_eq!(r.body, br#"{"a":1}"#);
    assert_eq!(r.header("content-type"), Some("application/json"));
    let raw = seen.lock().expect("lock")[0].to_lowercase();
    assert!(raw.starts_with("get /system/info/public?x=1 http/1.1"));
    assert!(raw.contains("authorization: mediabrowser client="));
}

#[tokio::test]
async fn error_status_is_an_answer_not_an_error() {
    let (port, _) = serve(|_| {
        Some("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into())
    })
    .await;
    let t = ReqwestTransport::new().expect("transport");
    assert_eq!(t.send(get(port, "/")).await.expect("answer").status, 401);
}

#[tokio::test]
async fn redirect_to_other_origin_drops_the_token() {
    let (target, seen_target) = serve(|_| Some(ok("{}"))).await;
    // `localhost` is another host name than 127.0.0.1, so this is another origin.
    let location = format!("http://localhost:{target}/final");
    let (port, _) = serve(move |_| {
        Some(format!(
            "HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        ))
    })
    .await;
    let t = ReqwestTransport::new().expect("transport");
    let r = t.send(get(port, "/start")).await.expect("answer");
    assert_eq!(r.status, 200);
    let raw = seen_target.lock().expect("lock")[0].to_lowercase();
    assert!(raw.starts_with("get /final"));
    assert!(
        !raw.contains("authorization"),
        "token leaked to another origin: {raw}"
    );
    assert!(raw.contains("accept: application/json"));
}

#[tokio::test]
async fn redirect_loop_ends_with_the_redirect_code() {
    let (port, _) = serve(|_| {
        Some("HTTP/1.1 302 Found\r\nLocation: /again\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into())
    })
    .await;
    let t = ReqwestTransport::new().expect("transport");
    let e = t.send(get(port, "/")).await.expect_err("loop");
    assert_eq!(
        e,
        ErrorKind::Network {
            code: url_error::TOO_MANY_REDIRECTS
        }
    );
}

#[tokio::test]
async fn cookies_are_kept_between_requests() {
    let (port, seen) = serve(|raw| {
        if raw.to_lowercase().contains("cookie: sid=abc") {
            Some(ok("{}"))
        } else {
            Some("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc; Path=/\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".into())
        }
    })
    .await;
    let t = ReqwestTransport::new().expect("transport");
    t.send(get(port, "/login")).await.expect("first");
    t.send(get(port, "/next")).await.expect("second");
    let second = seen.lock().expect("lock")[1].to_lowercase();
    assert!(second.contains("cookie: sid=abc"), "{second}");
}

#[tokio::test]
async fn silence_ends_in_timed_out() {
    let (port, _) = serve(|_| {
        std::thread::sleep(Duration::from_millis(900));
        None
    })
    .await;
    let t = ReqwestTransport::with_config(TransportConfig {
        request_timeout: Duration::from_millis(250),
        resource_timeout: Duration::from_millis(500),
        cookies: false,
        ..TransportConfig::default()
    })
    .expect("transport");
    let e = t.send(get(port, "/")).await.expect_err("timeout");
    assert_eq!(
        e,
        ErrorKind::Network {
            code: url_error::TIMED_OUT
        }
    );
}

#[tokio::test]
async fn per_request_timeout_wins() {
    let (port, _) = serve(|_| {
        std::thread::sleep(Duration::from_millis(900));
        None
    })
    .await;
    let t = ReqwestTransport::new().expect("transport");
    let mut r = get(port, "/");
    r.timeout = Some(Duration::from_millis(200));
    let e = t.send(r).await.expect_err("timeout");
    assert_eq!(e.url_error_code(), Some(url_error::TIMED_OUT));
}

#[tokio::test]
async fn refused_connection_is_cannot_connect() {
    let port = {
        let l = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        l.local_addr().expect("addr").port()
    };
    let t = ReqwestTransport::new().expect("transport");
    let e = t.send(get(port, "/")).await.expect_err("refused");
    assert_eq!(e.url_error_code(), Some(url_error::CANNOT_CONNECT_TO_HOST));
}

#[tokio::test]
async fn unknown_name_is_cannot_find_host() {
    let t = ReqwestTransport::new().expect("transport");
    let url = Url::parse("http://gibtsnicht-swiftly-pruefung.invalid/").expect("url");
    let e = t
        .send(HttpRequest::new(Method::Get, url))
        .await
        .expect_err("dns");
    assert!(
        matches!(
            e.url_error_code(),
            Some(url_error::CANNOT_FIND_HOST | url_error::NOT_CONNECTED_TO_INTERNET)
        ),
        "{e:?}"
    );
}

/// A server that keeps the connection open but drops it after `idle` without a request, like
/// Plex does after about 20 s. A pooled socket kept longer than that would fail the next call.
async fn serve_dropping_idle(idle: Duration) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                loop {
                    match tokio::time::timeout(idle, socket.read(&mut buf)).await {
                        Ok(Ok(n)) if n > 0 => {
                            let body = "{}";
                            let answer = format!(
                                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nKeep-Alive: timeout=20\r\n\r\n{body}",
                                body.len()
                            );
                            if socket.write_all(answer.as_bytes()).await.is_err() {
                                return;
                            }
                        }
                        // Idle for too long (or closed): the server resets without a word.
                        _ => return,
                    }
                }
            });
        }
    });
    port
}

#[tokio::test]
async fn pooled_socket_is_dropped_before_the_server_drops_it() {
    let port = serve_dropping_idle(Duration::from_millis(600)).await;
    let t = ReqwestTransport::with_config(TransportConfig {
        pool_idle_timeout: Duration::from_millis(200),
        cookies: false,
        ..TransportConfig::default()
    })
    .expect("transport");
    assert_eq!(t.send(get(port, "/a")).await.expect("first").status, 200);
    tokio::time::sleep(Duration::from_millis(900)).await;
    assert_eq!(
        t.send(get(port, "/b"))
            .await
            .expect("after the lull")
            .status,
        200
    );
}

#[test]
fn default_pool_idle_time_is_below_plex_keep_alive() {
    assert!(TransportConfig::default().pool_idle_timeout < Duration::from_secs(20));
}

fn post_with_body(port: u16, path: &str, keep_method: bool) -> HttpRequest {
    let url = Url::parse(&format!("http://127.0.0.1:{port}{path}")).expect("url");
    let mut r = HttpRequest::new(Method::Post, url);
    r.set_header("Content-Type", "application/json");
    r.body = Some(b"{}".to_vec());
    r.keep_method = keep_method;
    r
}

fn redirect_with(code: &str, location: &str) -> String {
    format!(
        "HTTP/1.1 {code}\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    )
}

#[tokio::test]
async fn keep_method_returns_the_redirect_instead_of_turning_post_into_get() {
    for code in ["301 Moved Permanently", "302 Found", "303 See Other"] {
        let (port, seen) = serve(move |_| Some(redirect_with(code, "/signin"))).await;
        let t = ReqwestTransport::new().expect("transport");
        let r = t
            .send(post_with_body(port, "/auth", true))
            .await
            .expect("answer");
        assert_eq!(
            r.status,
            code[..3].parse::<u16>().expect("code"),
            "the 3xx is the result"
        );
        assert_eq!(
            seen.lock().expect("lock").len(),
            1,
            "no second request after {code}"
        );
    }
}

#[tokio::test]
async fn without_keep_method_the_post_follows_as_a_get() {
    let (port, seen) = serve(|raw| {
        if raw.starts_with("GET /signin") {
            Some(ok("{}"))
        } else {
            Some(redirect_with("302 Found", "/signin"))
        }
    })
    .await;
    let t = ReqwestTransport::new().expect("transport");
    let r = t
        .send(post_with_body(port, "/auth", false))
        .await
        .expect("answer");
    assert_eq!(r.status, 200);
    assert_eq!(seen.lock().expect("lock").len(), 2);
}

#[tokio::test]
async fn keep_method_still_follows_a_redirect_that_keeps_the_method() {
    let (port, seen) = serve(|raw| {
        if raw.starts_with("POST /signin") {
            Some(ok("{}"))
        } else {
            Some(redirect_with("307 Temporary Redirect", "/signin"))
        }
    })
    .await;
    let t = ReqwestTransport::new().expect("transport");
    let r = t
        .send(post_with_body(port, "/auth", true))
        .await
        .expect("answer");
    assert_eq!(r.status, 200);
    assert!(seen.lock().expect("lock")[1].starts_with("POST /signin"));
}
