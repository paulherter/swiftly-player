//! Plex in the live app, round 4: the version question, preview pictures from the BIF, the picture of the next-episode
//! card, a download of the original file with `Range` resume and the offline start from the stored entry. The server is
//! a scripted Plex (mock transport for the API) plus a small file server for the part.

#![allow(clippy::expect_used)]

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use swiftly_accounts::{Account, AccountBundle, ServerBundles, save_bundles};
use swiftly_desktop::downloads_screen::Dyn;
use swiftly_desktop::live::Core;
use swiftly_desktop::live_downloads::{self, Resolver};
use swiftly_desktop::live_play::PlayRequest;
use swiftly_downloads::{Art, DownloadItem, DownloadQuality};
use swiftly_jellyfin::ServerKind;
use swiftly_net::{HttpResponse, MockTransport};
use swiftly_vm::{DownloadsIntent, DownloadsVm, RowState, ServerClient};

const MOVIE: &str = include_str!("../../swiftly-plex/tests/fixtures/movie.json");

fn jpeg(tag: u8) -> Vec<u8> {
    vec![
        0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x24, 0x00, 0x40, 0x03, 0x01, 0x22, 0x00,
        0x02, 0x11, 0x01, 0x03, 0x11, 0x01, tag, 0xFF, 0xD9,
    ]
}

fn bif(frames: &[Vec<u8>]) -> Vec<u8> {
    let mut out = vec![0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A];
    out.extend(0u32.to_le_bytes());
    out.extend((frames.len() as u32).to_le_bytes());
    out.extend(1000u32.to_le_bytes());
    out.resize(64, 0);
    let mut offset = 64 + (frames.len() as u32 + 1) * 8;
    let mut table = Vec::new();
    for (i, f) in frames.iter().enumerate() {
        table.extend((i as u32 * 10).to_le_bytes());
        table.extend(offset.to_le_bytes());
        offset += f.len() as u32;
    }
    table.extend(u32::MAX.to_le_bytes());
    table.extend(offset.to_le_bytes());
    out.extend(table);
    for f in frames {
        out.extend(f);
    }
    out
}

/// The part server: every request head is kept; `Range: bytes=N-` answers 206 from N.
fn serve(body: Vec<u8>) -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let heads = Arc::new(Mutex::new(Vec::new()));
    let seen = Arc::clone(&heads);
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let (body, seen) = (body.clone(), Arc::clone(&seen));
            std::thread::spawn(move || {
                let mut s = stream;
                let mut buf = [0u8; 4096];
                let n = s.read(&mut buf).unwrap_or(0);
                let head = String::from_utf8_lossy(&buf[..n]).to_string();
                let from = head.lines().find_map(|l| {
                    l.to_ascii_lowercase()
                        .strip_prefix("range: bytes=")
                        .and_then(|r| r.trim_end_matches('-').parse::<usize>().ok())
                });
                seen.lock().expect("heads").push(head);
                let (code, slice) = match from {
                    Some(f) if f < body.len() => ("206 Partial Content", &body[f..]),
                    _ => ("200 OK", &body[..]),
                };
                let _ = write!(
                    s,
                    "HTTP/1.1 {code}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    slice.len()
                );
                let _ = s.write_all(slice);
            });
        }
    });
    (format!("http://{addr}"), heads)
}

fn account(address: &str) -> Account {
    let mut a = Account::new(swiftly_jellyfin::Session {
        access_token: "SERVER-TOKEN".into(),
        user_id: "u1".into(),
        user_name: "Anna".into(),
        server_url: address.into(),
        kind: ServerKind::Plex,
    });
    a.plex = Some(serde_json::from_value(serde_json::json!({ "machineIdentifier": "machine-1", "serverName": "Home", "accountToken": "ACCOUNT-TOKEN" })).expect("plex block"));
    a
}

fn wait(what: &str, mut ok: impl FnMut() -> bool) {
    let t = Instant::now();
    while !ok() {
        assert!(
            t.elapsed() < Duration::from_secs(20),
            "{what} did not happen"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn state(vm: &DownloadsVm<Dyn>) -> Option<RowState> {
    vm.list()
        .rows
        .first()
        .and_then(|r| r.items.first())
        .map(|i| i.state)
}

fn start(vm: &DownloadsVm<Dyn>, account: &str, bytes: i64) -> DownloadItem {
    let mut item = DownloadItem::new("1", account, Art::Film, "Testfilm", bytes, 1.0);
    item.container = Some("mkv".into());
    item.source = Some("1".into());
    vm.send(DownloadsIntent::Start {
        items: vec![item.clone()],
        images: Default::default(),
        check_space: false,
    })
    .expect("start");
    item
}

#[test]
fn plex_versions_previews_card_picture_download_and_offline() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir = std::env::temp_dir().join(format!("swiftly-live-plex4-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let me = std::env::current_exe().expect("exe");
        let out = std::process::Command::new(me)
            .args([
                "--exact",
                "plex_versions_previews_card_picture_download_and_offline",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("SWIFTLY_CONFIG_DIR", &dir)
            .output()
            .expect("child");
        let _ = std::fs::remove_dir_all(&dir);
        assert!(
            out.status.success(),
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let file: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    let (address, heads) = serve(file.clone());
    let mock = MockTransport::new()
        .route("/library/metadata/1", 200, MOVIE)
        .route_response(
            "/library/parts/1/indexes/sd",
            HttpResponse::new(200, bif(&[jpeg(1), jpeg(2), jpeg(3)])),
        )
        .route_response("/photo/:/transcode", HttpResponse::new(200, jpeg(9)));
    let core = Arc::new(Core::open_with(Some(mock)).expect("core"));
    save_bundles(
        &*core.secrets,
        &ServerBundles::new(
            vec![(ServerKind::Plex, AccountBundle::new(account(&address)))],
            ServerKind::Plex,
        ),
    );
    let account = core.account().expect("stored account");
    let prepare = |req: PlayRequest| {
        core.prepare_play(&account, req)
            .0
            .recv_timeout(Duration::from_secs(10))
            .expect("answer")
            .expect("prepared")
    };

    // Versions: without a pick the two files of the movie come back as a question; with a pick the title is ready.
    let asked = prepare(PlayRequest {
        item_id: "1".into(),
        since: 0.0,
        source_id: None,
    });
    let ask = asked.ask().expect("a version question");
    assert_eq!(ask.item_id, "1");
    assert_eq!(
        ask.versions
            .iter()
            .map(|v| v.id.as_str())
            .collect::<Vec<_>>(),
        ["1", "2"]
    );
    let second = prepare(PlayRequest {
        item_id: "1".into(),
        since: ask.since,
        source_id: Some("2".into()),
    });
    let ready = second.ready().expect("ready");
    assert!(ready.url().contains("/library/parts/2/"), "{}", ready.url());
    assert!(
        ready.trickplay().is_none(),
        "version 2 has no preview index"
    );

    // Previews: the first version has a BIF; one picture per sheet number, nothing past the end.
    let first = prepare(PlayRequest {
        item_id: "1".into(),
        since: 0.0,
        source_id: Some("1".into()),
    });
    let ready = first.ready().expect("ready");
    assert!(
        ready.url().contains("/library/parts/1/")
            && ready.url().contains("X-Plex-Token=SERVER-TOKEN"),
        "{}",
        ready.url()
    );
    let (tp, fetch) = core.preview_source(ready).expect("preview offer");
    assert_eq!(
        (
            tp.count,
            tp.interval,
            tp.tiles_wide,
            tp.tiles_up,
            tp.width,
            tp.height
        ),
        (3, 10_000, 1, 1, 64, 36)
    );
    assert_eq!(tp.tile(25.0).map(|t| t.sheet), Some(2));
    assert_eq!(fetch(2), Some(jpeg(3)));
    assert_eq!(fetch(7), None);

    // The picture of the next episode: the Plex entry names the path, the address carries the token.
    let server = core.server_for(&account).expect("plex client");
    assert!(matches!(server, ServerClient::Plex(_)));
    let still = core.card_still_source(&server, "1");
    assert_eq!(
        std::thread::spawn(move || still()).join().expect("thread"),
        Some(jpeg(9))
    );

    // Download: the original file through the resolver of the account, then again from a partial file with Range.
    let resolver: Resolver = live_downloads::resolver_for(&core, &account);
    let url = resolver("1", Some("1"), DownloadQuality::Original, None).expect("address");
    assert!(
        url.starts_with(&address)
            && url.contains("/library/parts/1/")
            && url.contains("X-Plex-Token=SERVER-TOKEN"),
        "{url}"
    );
    let key = account.key();
    let dir = live_downloads::downloads_dir();
    let vm = live_downloads::build(dir.clone(), &key, core.handle(), Arc::clone(&resolver));
    let item = start(&vm, &key, file.len() as i64);
    wait("download done", || state(&vm) == Some(RowState::Done));
    let path = dir.join(item.file_name());
    assert_eq!(std::fs::read(&path).expect("file"), file);
    assert!(
        heads
            .lock()
            .expect("heads")
            .iter()
            .all(|h| !h.to_ascii_lowercase().contains("range:")),
        "a fresh download asks for the whole file"
    );

    // Offline: the finished entry plays from the file; the stop report goes to the Plex server.
    // The list file is written a moment after the row reads Done.
    wait("the finished entry is stored", || {
        live_downloads::finished(&dir, &key, "1").is_some()
    });
    let offline =
        swiftly_desktop::live_offline::prepare_offline(&core, &account, "1").expect("offline");
    let r = offline.ready().expect("ready");
    assert!(r.url().starts_with("file://") && matches!(r.server(), ServerClient::Plex(_)));

    // Resume: a partial file next to a fresh list continues with `Range: bytes=1000-`.
    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_file(dir.join("liste.json"));
    std::fs::write(
        dir.join(format!("{}.part", item.file_name())),
        &file[..1000],
    )
    .expect("part");
    heads.lock().expect("heads").clear();
    let vm = live_downloads::build(dir.clone(), &key, core.handle(), resolver);
    start(&vm, &key, file.len() as i64);
    wait("resumed download done", || {
        state(&vm) == Some(RowState::Done)
    });
    assert_eq!(std::fs::read(&path).expect("file"), file);
    assert!(
        heads
            .lock()
            .expect("heads")
            .iter()
            .any(|h| h.to_ascii_lowercase().contains("range: bytes=1000-")),
        "{:?}",
        heads.lock().expect("heads")
    );
}
