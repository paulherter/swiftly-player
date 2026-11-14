//! A series downloaded from the season sheet saves its pictures along, like the Mac (`SeriesView.loadImages`): the series
//! poster, its wide header and the still of every chosen episode, so the rows and the series page show pictures offline.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use swiftly_desktop::downloads_screen::{DownloadsScreen, LoadRequest, Pictures};
use swiftly_desktop::live_downloads;
use swiftly_downloads::DownloadItem;
use swiftly_layout::Size;
use swiftly_model::{Item, MediaSource};
use swiftly_ui::{Cx, Env, Idiom};

/// A server that answers every request with a few bytes and remembers the paths asked for.
fn serve() -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let asked = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&asked);
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let log = Arc::clone(&log);
            std::thread::spawn(move || {
                let mut s = stream;
                let mut buf = [0u8; 2048];
                let n = s.read(&mut buf).unwrap_or(0);
                let head = String::from_utf8_lossy(&buf[..n]).to_string();
                if let Some(path) = head.split_whitespace().nth(1) {
                    log.lock().unwrap().push(path.to_owned());
                }
                let body = b"image-bytes";
                let _ = write!(
                    s,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = s.write_all(body);
            });
        }
    });
    (base, asked)
}

fn episode(id: &str, season: i64, number: i64) -> Item {
    Item {
        id: id.into(),
        name: format!("Folge {number}"),
        index_number: Some(number),
        parent_index_number: Some(season),
        media_sources: Some(vec![MediaSource {
            size: Some(1000),
            container: Some("mkv".into()),
            ..MediaSource::default()
        }]),
        ..Item::default()
    }
}

#[test]
fn a_series_download_saves_poster_header_and_episode_stills() {
    let (base, asked) = serve();
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let dir = std::env::temp_dir().join(format!("swiftly-series-covers-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let media = format!("{base}/media.mkv");
    let vm = live_downloads::build(
        dir.clone(),
        "u1",
        rt.handle().clone(),
        Arc::new(move |_, _, _, _| Ok(media.clone())),
    );
    let env = Env::new(Size::new(1280.0, 800.0), 2.0, Idiom::Desktop);
    let mut d = DownloadsScreen::over(env, Cx::deterministic(), vm);
    let address = base.clone();
    d.request_load(LoadRequest::Season {
        account: "u1".into(),
        series: Box::new(Item {
            id: "s9".into(),
            name: "Die Nachbarn".into(),
            ..Item::default()
        }),
        seasons: vec![Item {
            id: "se1".into(),
            name: "Staffel 1".into(),
            ..Item::default()
        }],
        episodes: HashMap::from([(
            "se1".to_owned(),
            (1..=4).map(|n| episode(&format!("a{n}"), 1, n)).collect(),
        )]),
        quality_select: false,
        anchor: None,
        pictures: Pictures::new(move |item, look| {
            Some(format!("{address}/img/{}/{look:?}", item.id))
        }),
    });
    d.press("sel.all");
    d.press("sel.go");
    let want: Vec<String> = ["a1", "a2", "a3", "a4", "s9", "s9-kopf"]
        .iter()
        .map(|id| DownloadItem::image_name("u1", id))
        .collect();
    let t = Instant::now();
    while want.iter().any(|n| !dir.join(n).exists()) {
        assert!(
            t.elapsed() < Duration::from_secs(20),
            "pictures missing: {:?}; asked for {:?}",
            want.iter()
                .filter(|n| !dir.join(n).exists())
                .collect::<Vec<_>>(),
            asked.lock().unwrap()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let asked = asked.lock().unwrap().clone();
    assert!(asked.contains(&"/img/s9/Poster".to_owned()), "{asked:?}");
    assert!(asked.contains(&"/img/s9/Header".to_owned()), "{asked:?}");
    assert!(asked.contains(&"/img/a3/Still".to_owned()), "{asked:?}");
    let _ = std::fs::remove_dir_all(&dir);
}
