//! A small in-process Jellyfin-shaped HTTP server for the soak: the same item shape as
//! `cargo xtask fixture-server`, but `/Items` honours `StartIndex`/`Limit` over a library of
//! `big` movies. Ids starting with `x` have no picture (404), to churn the loader's failure path.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::OnceLock;

const NAMES: [&str; 6] = [
    "Nordlicht",
    "Sommerregen",
    "Die Brücke",
    "Stilles Wasser",
    "Papierschiffe",
    "Nachtzug",
];

pub fn movie(i: usize) -> String {
    let resume = if i.is_multiple_of(2) {
        r#""PlaybackPositionTicks":3000000000,"PlayedPercentage":25.0,"Played":false"#
    } else {
        r#""Played":false"#
    };
    format!(
        r#"{{"Id":"m{i}","Name":"{} {i}","Type":"Movie","ProductionYear":{},"RunTimeTicks":120000000,"Overview":"Ein ruhiger Testfilm vom Fixture-Server.","Genres":["Drama"],"CommunityRating":7.5,"ImageTags":{{"Primary":"p{i}"}},"BackdropImageTags":["b{i}"],"UserData":{{{resume}}}}}"#,
        NAMES[i % NAMES.len()],
        1950 + i % 75
    )
}

/// The lean list entry the client asks for first (`EnableImages=false`, only the sort fields).
fn lean_movie(i: usize) -> String {
    format!(
        r#"{{"Id":"m{i}","Name":"{} {i}","Type":"Movie","SortName":"{} {i:06}","DateCreated":"2023-02-03T12:00:00.0000000Z"}}"#,
        NAMES[i % NAMES.len()],
        NAMES[i % NAMES.len()].to_lowercase()
    )
}

/// The JSON body of a library of `n` movies (one file for the benchmarks).
pub fn library_json(n: usize) -> String {
    let items: Vec<String> = (0..n).map(movie).collect();
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{n}}}"#,
        items.join(",")
    )
}

fn png_for(seed: usize) -> &'static [u8] {
    static PNGS: OnceLock<Vec<Vec<u8>>> = OnceLock::new();
    let all = PNGS.get_or_init(|| {
        (0..16_u32)
            .map(|seed| {
                let (w, h) = (120_u32, 180_u32);
                let mut out = Vec::new();
                let mut enc = png::Encoder::new(&mut out, w, h);
                enc.set_color(png::ColorType::Rgb);
                enc.set_depth(png::BitDepth::Eight);
                let mut data = Vec::with_capacity((w * h * 3) as usize);
                for y in 0..h {
                    for x in 0..w {
                        data.extend([
                            ((x * 255 / w) + seed * 37) as u8,
                            (y * 255 / h) as u8,
                            (seed * 61 % 256) as u8,
                        ]);
                    }
                }
                if let Ok(mut wr) = enc.write_header() {
                    let _ = wr.write_image_data(&data);
                }
                out
            })
            .collect()
    });
    &all[seed % all.len()]
}

fn list(items: &[String], total: usize) -> Vec<u8> {
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{total}}}"#,
        items.join(",")
    )
    .into_bytes()
}

fn query(q: &str, key: &str) -> Option<usize> {
    q.split('&')
        .find_map(|p| p.strip_prefix(key)?.strip_prefix('=')?.parse().ok())
}

fn route(big: usize, method: &str, target: &str, body: &str) -> (u16, &'static str, Vec<u8>) {
    let (path, q) = target.split_once('?').unwrap_or((target, ""));
    let path = path.trim_end_matches('/');
    let ok = |b: Vec<u8>| (200, "application/json", b);
    match (method, path) {
        (_, "/System/Info/Public") => ok(br#"{"ServerName":"Soak","Version":"10.10.0","Id":"fx","ProductName":"Jellyfin Server"}"#.to_vec()),
        ("POST", "/Users/AuthenticateByName") => {
            if body.contains("demo") {
                ok(br#"{"User":{"Id":"u1","Name":"demo","ServerId":"fx"},"AccessToken":"fixture-token","ServerId":"fx"}"#.to_vec())
            } else {
                (401, "text/plain", b"bad".to_vec())
            }
        }
        (_, p) if p.ends_with("/UserViews") || p.ends_with("/Views") => ok(list(
            &[
                r#"{"Id":"lib-movies","Name":"Filme","Type":"CollectionFolder","CollectionType":"movies"}"#.to_owned(),
                r#"{"Id":"lib-shows","Name":"Serien","Type":"CollectionFolder","CollectionType":"tvshows"}"#.to_owned(),
            ],
            2,
        )),
        (_, p) if p.ends_with("/Resume") => ok(list(&[movie(0), movie(2)], 2)),
        (_, p) if p.ends_with("/Items/Latest") => ok(format!("[{}]", (0..6).map(movie).collect::<Vec<_>>().join(",")).into_bytes()),
        (_, p) if p.contains("/Images/") => {
            let id = p.split('/').rev().nth(2).unwrap_or("x");
            if id.starts_with('x') {
                return (404, "text/plain", Vec::new());
            }
            let seed: usize = id.bytes().map(usize::from).sum();
            (200, "image/png", png_for(seed).to_vec())
        }
        (_, p) if p.ends_with("/Items") && q.split('&').any(|part| part.starts_with("Ids=")) => {
            // Pages of a library the client already listed (lean list first, then the titles of the page by id).
            let ids = q.split('&').find_map(|part| part.strip_prefix("Ids=")).unwrap_or("");
            let items: Vec<String> = ids.split(',').filter_map(|id| id.strip_prefix('m')?.parse().ok()).map(movie).collect();
            ok(list(&items, items.len()))
        }
        (_, p) if p.ends_with("/Items") => {
            let total = big.max(6);
            let start = query(q, "StartIndex").unwrap_or(0).min(total);
            let limit = query(q, "Limit").unwrap_or(total).min(total - start);
            let lean = q.contains("EnableImages=false");
            let items: Vec<String> = (start..start + limit).map(if lean { lean_movie } else { movie }).collect();
            ok(list(&items, total))
        }
        (_, p) if p.rsplit('/').nth(1) == Some("Items") => {
            let n: usize = p.rsplit('/').next().and_then(|id| id.get(1..)?.parse().ok()).unwrap_or(0);
            ok(movie(n).into_bytes())
        }
        ("POST", _) => (204, "text/plain", Vec::new()),
        _ => ok(list(&[], 0)),
    }
}

fn serve(big: usize, mut stream: TcpStream) {
    let Ok(clone) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(clone);
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        let mut parts = line.split_whitespace();
        let (method, target) = (
            parts.next().unwrap_or("GET").to_owned(),
            parts.next().unwrap_or("/").to_owned(),
        );
        let (mut length, mut close) = (0_usize, false);
        loop {
            let mut h = String::new();
            if reader.read_line(&mut h).unwrap_or(0) == 0 || h.trim().is_empty() {
                break;
            }
            let lower = h.to_ascii_lowercase();
            if let Some(v) = lower.strip_prefix("content-length:") {
                length = v.trim().parse().unwrap_or(0);
            }
            close |= lower.starts_with("connection:") && lower.contains("close");
        }
        let mut body = vec![0; length];
        if reader.read_exact(&mut body).is_err() {
            return;
        }
        let (status, kind, data) = route(big, &method, &target, &String::from_utf8_lossy(&body));
        let head = format!(
            "HTTP/1.1 {status} X\r\nContent-Type: {kind}\r\nContent-Length: {}\r\n\r\n",
            data.len()
        );
        if stream.write_all(head.as_bytes()).is_err() || stream.write_all(&data).is_err() || close {
            return;
        }
    }
}

/// Starts the server on a free local port (it lives as long as the process); returns its base URL.
/// `HARDENING_FIXTURE_URL` points the run at an external server (for example `cargo xtask
/// fixture-server`) instead.
pub fn start(big: usize) -> String {
    if let Ok(url) = std::env::var("HARDENING_FIXTURE_URL") {
        return url;
    }
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            std::thread::spawn(move || serve(big, stream));
        }
    });
    format!("http://127.0.0.1:{port}")
}
