//! The Merkliste on the real server path (Core over a socket, a stored account, favourites on the server): pressing it
//! must show the favourites only, as its own page, never the movie grid or a title page.
#![allow(clippy::unwrap_used)]

use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use swiftly_accounts::{Account, AccountBundle, ServerBundles, save_bundles};
use swiftly_desktop::a11y_bridge;
use swiftly_desktop::live::Core;
use swiftly_desktop::suite::Suite;
use swiftly_jellyfin::{ServerKind, Session};
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;

fn movie(i: u32) -> String {
    let fav = i.is_multiple_of(3);
    format!(
        r#"{{"Id":"m{i}","Name":"Film {i}","Type":"Movie","ProductionYear":2000,"ImageTags":{{}},"UserData":{{"IsFavorite":{fav},"Played":false}}}}"#
    )
}

fn series() -> String {
    r#"{"Id":"s1","Name":"Serie 1","Type":"Series","ProductionYear":2000,"ImageTags":{},"UserData":{"IsFavorite":true,"Played":false}}"#.to_owned()
}

fn list(ids: impl Iterator<Item = u32>) -> String {
    let v: Vec<String> = ids.map(movie).collect();
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{}}}"#,
        v.join(","),
        v.len()
    )
}

/// A Jellyfin-shaped server: ten movies, every third one a favourite; `IsFavorite` in the query filters.
fn serve() -> (String, Arc<Mutex<Vec<String>>>) {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            let log = Arc::clone(&log);
            std::thread::spawn(move || {
                let mut s = s;
                let mut buf = [0u8; 8192];
                let n = s.read(&mut buf).unwrap_or(0);
                let head = String::from_utf8_lossy(&buf[..n]).to_string();
                let target = head.split_whitespace().nth(1).unwrap_or("/").to_owned();
                log.lock().unwrap().push(target.clone());
                let types = target
                    .split("IncludeItemTypes=")
                    .nth(1)
                    .unwrap_or("")
                    .split('&')
                    .next()
                    .unwrap_or("")
                    .to_owned();
                let body = if target.contains("IsFavorite") {
                    let mut v: Vec<String> = Vec::new();
                    if types.contains("Movie") {
                        v.extend((1..=10).filter(|i| i % 3 == 0).map(movie));
                    }
                    if types.contains("Series") {
                        v.push(series());
                    }
                    format!(
                        r#"{{"Items":[{}],"TotalRecordCount":{}}}"#,
                        v.join(","),
                        v.len()
                    )
                } else if target.contains("/Items") && !target.contains("/Images/") {
                    match target
                        .split("Ids=")
                        .nth(1)
                        .map(|t| t.split('&').next().unwrap_or("").to_owned())
                    {
                        Some(ids) => {
                            let mut v: Vec<String> = (1..=10)
                                .filter(|i| ids.split(',').any(|x| x == format!("m{i}")))
                                .map(movie)
                                .collect();
                            if ids.split(',').any(|x| x == "s1") {
                                v.push(series());
                            }
                            format!(
                                r#"{{"Items":[{}],"TotalRecordCount":{}}}"#,
                                v.join(","),
                                v.len()
                            )
                        }
                        None => list(1..=10),
                    }
                } else {
                    r#"{"Items":[],"TotalRecordCount":0}"#.to_owned()
                };
                let _ = write!(
                    s,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            });
        }
    });
    (format!("http://{addr}"), seen)
}

fn run_for(s: &mut Suite, now: &mut f64, ms: f64) {
    let end = *now + ms;
    while *now < end {
        *now += STEP;
        let _ = s.frame(*now);
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
}

fn tap_label(s: &mut Suite, now: &mut f64, label: &str) -> bool {
    let (title, tree) = s.a11y_nodes();
    let built = a11y_bridge::build(title, &tree, 1.0);
    let id = built
        .update
        .nodes
        .iter()
        .find(|(_, x)| x.label() == Some(label))
        .map(|(i, _)| i.0);
    let Some(&(x, y)) = id.and_then(|i| built.centres.get(&i)) else {
        return false;
    };
    s.touch_down(x, y, *now);
    s.touch_up(x, y, *now + 40.0);
    *now += 80.0;
    true
}

#[test]
fn the_merkliste_shows_the_favourites_on_the_real_server_path() {
    if std::env::var_os("SWIFTLY_CONFIG_DIR").is_none() {
        let dir = std::env::temp_dir().join(format!("swiftly-live-wl-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let me = std::env::current_exe().unwrap();
        let out = std::process::Command::new(me)
            .args([
                "--exact",
                "the_merkliste_shows_the_favourites_on_the_real_server_path",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("SWIFTLY_CONFIG_DIR", &dir)
            .output()
            .unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(
            out.status.success(),
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let (address, seen) = serve();
    let core = Arc::new(Core::open().unwrap());
    let address_host = address.trim_start_matches("http://").to_owned();
    let session = Session {
        access_token: "tok".into(),
        user_id: "u1".into(),
        user_name: "demo".into(),
        server_url: address,
        kind: ServerKind::Jellyfin,
    };
    save_bundles(
        &*core.secrets,
        &ServerBundles::new(
            vec![(
                ServerKind::Jellyfin,
                AccountBundle::new(Account::new(session)),
            )],
            ServerKind::Jellyfin,
        ),
    );
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    let mut s = Suite::new_live(env, Cx::deterministic(), core);
    let mut now = 0.0;
    run_for(&mut s, &mut now, 1500.0);
    // The sidebar's account card shows the stored account (name and host), never the demo's "Swiftly / tv.example.test".
    let host = address_host.clone();
    assert_eq!(
        swiftly_desktop::desk::card(),
        swiftly_desktop::desk::Card::Account {
            name: "demo".into(),
            server: host
        }
    );

    // From a title page: the Merkliste leaves the title page and shows its own grid (the title stays parked on "Filme").
    assert!(tap_label(&mut s, &mut now, "Filme"));
    run_for(&mut s, &mut now, 1200.0);
    let before = s.pushes();
    'scan: for yi in 0..14 {
        for xi in 0..14 {
            let (x, y) = (
                1280.0 * (0.30 + 0.05 * xi as f32),
                800.0 * (0.25 + 0.05 * yi as f32),
            );
            s.touch_down(x, y, now);
            s.touch_up(x, y, now + 40.0);
            now += 80.0;
            if s.pushes() > before {
                break 'scan;
            }
        }
    }
    run_for(&mut s, &mut now, 1000.0);
    assert!(s.title_open(), "a title page is open on Filme");
    assert!(tap_label(&mut s, &mut now, "Merkliste"), "Merkliste");
    run_for(&mut s, &mut now, 1500.0);
    let ids: Vec<String> = s
        .watch()
        .vm()
        .grid()
        .tiles
        .iter()
        .map(|t| t.id.clone())
        .collect();
    let report = format!(
        "from a title: tab {} top {:?} watch ids {ids:?}\nrequests: {:#?}",
        s.tab(),
        s.top_kind(),
        seen.lock().unwrap()
    );
    assert_eq!(
        (s.tab(), s.top_kind(), s.title_open()),
        (4, None, false),
        "{report}"
    );
    assert_eq!(ids, ["m3", "m6", "m9", "s1"], "{report}");

    for round in 0..3 {
        assert!(tap_label(&mut s, &mut now, "Filme"), "Filme");
        run_for(&mut s, &mut now, 1200.0);
        assert!(tap_label(&mut s, &mut now, "Merkliste"), "Merkliste");
        run_for(&mut s, &mut now, 1500.0);
        let ids: Vec<String> = s
            .watch()
            .vm()
            .grid()
            .tiles
            .iter()
            .map(|t| t.id.clone())
            .collect();
        let report = format!(
            "round {round}: tab {} top {:?} title_open {} watch ids {ids:?}\nrequests: {:#?}",
            s.tab(),
            s.top_kind(),
            s.title_open(),
            seen.lock().unwrap()
        );
        assert_eq!(
            (s.tab(), s.top_kind(), s.title_open()),
            (4, None, false),
            "{report}"
        );
        assert_eq!(ids, ["m3", "m6", "m9", "s1"], "{report}");
    }

    // The kind pill (Mac: Alle / Filme / Serien): Serien keeps the series only, Filme the movies only, Alle both.
    for (pick, want) in [
        ("Serien", vec!["s1"]),
        ("Filme", vec!["m3", "m6", "m9"]),
        ("Alle", vec!["m3", "m6", "m9", "s1"]),
    ] {
        assert!(tap_label(&mut s, &mut now, "Merkliste"), "Merkliste");
        run_for(&mut s, &mut now, 800.0);
        assert!(
            open_kind_pill(&mut s, &mut now),
            "the kind pill is on the Merkliste page"
        );
        run_for(&mut s, &mut now, 400.0);
        assert!(
            tap_label_pill(&mut s, &mut now, pick),
            "{pick} in the kind menu"
        );
        run_for(&mut s, &mut now, 1500.0);
        let ids: Vec<String> = s
            .watch()
            .vm()
            .grid()
            .tiles
            .iter()
            .map(|t| t.id.clone())
            .collect();
        assert_eq!(ids, want, "{pick}: {:#?}", seen.lock().unwrap());
    }
}

/// The pill shows the current kind; tap whichever of its three values is on screen.
fn open_kind_pill(s: &mut Suite, now: &mut f64) -> bool {
    ["Alle", "Filme", "Serien"]
        .iter()
        .any(|l| tap_label_pill(s, now, l))
}

/// Like `tap_label` but only a node that has the value text and is NOT the sidebar row of the same name (the pill sits
/// right of the sidebar).
fn tap_label_pill(s: &mut Suite, now: &mut f64, label: &str) -> bool {
    let (title, tree) = s.a11y_nodes();
    let built = a11y_bridge::build(title, &tree, 1.0);
    let found = built
        .update
        .nodes
        .iter()
        .filter(|(_, x)| x.label() == Some(label))
        .filter_map(|(i, _)| built.centres.get(&i.0).copied())
        .find(|&(x, y)| x > 200.0 && y < 400.0);
    let Some((x, y)) = found else { return false };
    s.touch_down(x, y, *now);
    s.touch_up(x, y, *now + 40.0);
    *now += 80.0;
    true
}
