//! The administrator side of `cargo xtask fixture-server --admin` (or `SWIFTLY_FIXTURE_ADMIN` set): what the server
//! page and the log screen read, for the real-app runs. Opt-in; with the switch off nothing here runs and every other
//! answer stays byte-identical.
//!
//! | What | Value |
//! |---|---|
//! | Administrator | user `demo` (id `u1`, password `demo` or empty), `Policy.IsAdministrator` true |
//! | Not an administrator | user `gast` (id `u2`, token `fixture-token-gast`, password `demo` or empty): every admin route answers 403 |
//! | Server | "Fixture" 10.11.2, 1204 films, 86 series, 9421 episodes; 12 UHD, 28 HD, 8 SD after the filters |
//! | Tasks | "Optimize database" running at 42 %, "Scan Media Library" idle until `POST /Library/Refresh` |
//! | Streams | Anna: film "Nordlicht", Direct Play, 4K HEVC Dolby Vision; Ben: episode of "Hafenlichter", transcoding the audio; one idle app |
//! | Drives | `/` (config, cache; 47 % free), `/media` (Filme, Serien; 30 % free), `/usb` (Archiv; 4 % free, nearly full) |
//! | Load plugin | `/JellyTwiggy/*` answers 404 (none installed) |
//! | Logs | two server logs and one transcode log; the file answer is a deterministic text |
//!
//! State: `POST /System/Restart` ends a pending restart (`SWIFTLY_FIXTURE_ADMIN=pending` starts with one), `DELETE
//! ScheduledTasks/Running/{id}` ends that task, `POST Library/Refresh` starts the scan task, `POST
//! Sessions/{id}/Playing/Stop` removes that stream. `GET /fixture/admin-calls` lists every changing call in arrival
//! order (`METHOD path body`); `POST /fixture/admin-reset` puts everything back.

use std::cell::RefCell;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::fixture_server::{NAMES, Reply};

static ON: AtomicBool = AtomicBool::new(false);
static WORLD: Mutex<Option<World>> = Mutex::new(None);

thread_local! {
    /// The `Authorization` header of the request this thread answers (one thread per connection).
    static CALLER: RefCell<String> = const { RefCell::new(String::new()) };
}

/// `--admin`.
pub(crate) fn enable() {
    ON.store(true, Ordering::Relaxed);
}

fn enabled() -> bool {
    ON.load(Ordering::Relaxed) || std::env::var_os("SWIFTLY_FIXTURE_ADMIN").is_some()
}

/// Remembers who asks (called by the server before it routes a request).
pub(crate) fn note_caller(authorization: &str) {
    CALLER.with(|c| authorization.clone_into(&mut c.borrow_mut()));
}

fn caller_is_guest() -> bool {
    CALLER.with(|c| c.borrow().contains("fixture-token-gast"))
}

struct World {
    restart_pending: bool,
    optimize_running: bool,
    scan_running: bool,
    stopped: Vec<String>,
    calls: Vec<String>,
}

impl World {
    fn new() -> Self {
        Self {
            restart_pending: std::env::var("SWIFTLY_FIXTURE_ADMIN").is_ok_and(|v| v == "pending"),
            optimize_running: true,
            scan_running: false,
            stopped: Vec::new(),
            calls: Vec::new(),
        }
    }
}

/// Does this module own the request? `None`: the server goes on with its other routes.
pub(crate) fn answer(method: &str, path: &str, query: &str, body: &str) -> Option<Reply> {
    if !enabled() {
        return None;
    }
    let guest = caller_is_guest();
    let mut guard = WORLD.lock().ok()?;
    let world = guard.get_or_insert_with(World::new);
    answer_with(world, guest, method, path, query, body)
}

fn json(body: String) -> Reply {
    Reply(200, "application/json", body.into_bytes())
}

fn nothing() -> Reply {
    Reply(204, "text/plain", Vec::new())
}

fn user(id: &str, name: &str, admin: bool) -> String {
    format!(
        r#"{{"Id":"{id}","Name":"{name}","ServerId":"{sid}","HasPassword":true,"Configuration":{{}},"Policy":{{"IsAdministrator":{admin},"EnableContentDownloading":true}}}}"#,
        sid = crate::fixture_server::server_id()
    )
}

fn known_user(name: &str) -> Option<(&'static str, &'static str, bool, &'static str)> {
    match name {
        "demo" => Some(("u1", "demo", true, "fixture-token")),
        "gast" => Some(("u2", "gast", false, "fixture-token-gast")),
        _ => None,
    }
}

fn answer_with(
    w: &mut World,
    guest: bool,
    method: &str,
    path: &str,
    query: &str,
    body: &str,
) -> Option<Reply> {
    let has = |k: &str, v: &str| query.split('&').any(|p| p == format!("{k}={v}"));
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    // ---- the two users
    match (method, parts.as_slice()) {
        ("POST", ["Users", "AuthenticateByName"]) => {
            let name = ["demo", "gast"]
                .into_iter()
                .find(|n| body.contains(&format!(r#""Username":"{n}""#)))?;
            let ok = body.contains(r#""Pw":"demo""#) || body.contains(r#""Pw":"""#);
            let (id, name, admin, token) = known_user(name)?;
            if !ok {
                return Some(Reply(401, "text/plain", b"bad".to_vec()));
            }
            let sid = crate::fixture_server::server_id();
            return Some(json(format!(
                r#"{{"User":{},"AccessToken":"{token}","ServerId":"{sid}"}}"#,
                user(id, name, admin)
            )));
        }
        ("GET", ["Users", "Public"]) => {
            return Some(json(
                r#"[{"Id":"u1","Name":"demo"},{"Id":"u2","Name":"gast"}]"#.to_string(),
            ));
        }
        ("GET", ["Users", id @ ("u1" | "u2" | "Me")]) => {
            // `Me` is whoever asks.
            let (id, name, admin, _) = if *id == "u1" || (*id == "Me" && !guest) {
                known_user("demo")?
            } else {
                known_user("gast")?
            };
            return Some(json(user(id, name, admin)));
        }
        ("GET", ["fixture", "admin-calls"]) => {
            let rows: Vec<String> = w.calls.iter().map(|c| format!("{c:?}")).collect();
            return Some(json(format!("[{}]", rows.join(","))));
        }
        ("POST", ["fixture", "admin-reset"]) => {
            *w = World::new();
            return Some(nothing());
        }
        _ => {}
    }
    // ---- the admin routes
    let admin_route = match (method, parts.as_slice()) {
        (
            "GET",
            ["System", "Info"]
            | ["Items", "Counts"]
            | ["ScheduledTasks"]
            | ["System", "Info", "Storage"],
        ) => true,
        ("GET", ["System", "Logs"] | ["System", "Logs", "Log"]) => true,
        ("GET", ["Sessions"]) => query.contains("activeWithinSeconds"),
        ("GET", ["Items"]) => {
            query.contains("Limit=0") && (query.contains("Is4K=") || query.contains("IsHd="))
        }
        ("GET", ["JellyTwiggy", ..]) => true,
        ("POST", ["System", "Restart"] | ["Library", "Refresh"]) => true,
        ("DELETE", ["ScheduledTasks", "Running", _]) => true,
        ("POST", ["Sessions", _, "Playing", "Stop"] | ["Sessions", _, "Message"]) => true,
        _ => false,
    };
    if !admin_route {
        return None;
    }
    if guest {
        return Some(Reply(403, "text/plain", b"Forbidden".to_vec()));
    }
    if method != "GET" {
        let line = if body.is_empty() {
            format!("{method} {path}")
        } else {
            format!("{method} {path} {body}")
        };
        w.calls.push(line);
    }
    Some(match (method, parts.as_slice()) {
        ("GET", ["System", "Info"]) => json(format!(
            r#"{{"ServerName":"Fixture","Version":"10.11.2","Id":"{}","HasPendingRestart":{},"OperatingSystem":"Linux"}}"#,
            crate::fixture_server::server_id(),
            w.restart_pending
        )),
        ("GET", ["Items", "Counts"]) => {
            json(r#"{"MovieCount":1204,"SeriesCount":86,"EpisodeCount":9421}"#.into())
        }
        ("GET", ["Items"]) => {
            let total = if has("Is4K", "true") {
                12
            } else if has("IsHd", "true") {
                40
            } else {
                8
            };
            json(format!(r#"{{"Items":[],"TotalRecordCount":{total}}}"#))
        }
        ("GET", ["JellyTwiggy", ..]) => Reply(404, "text/plain", b"no plugin".to_vec()),
        ("GET", ["ScheduledTasks"]) => json(tasks(w)),
        ("GET", ["System", "Info", "Storage"]) => json(STORAGE.into()),
        ("GET", ["Sessions"]) => json(sessions(w)),
        ("GET", ["System", "Logs"]) => json(LOGS.into()),
        ("GET", ["System", "Logs", "Log"]) => Reply(200, "text/plain", log_text().into_bytes()),
        ("POST", ["System", "Restart"]) => {
            w.restart_pending = false;
            nothing()
        }
        ("POST", ["Library", "Refresh"]) => {
            // This route answers before the Seerr one does, so the Seerr side of the call runs here: its log, a failure
            // a test asked for (`/__seerr/fail?step=jellyfin`), and the rescan that makes a deleted title leave the
            // library. A refused scan is this answer too.
            match crate::fixture_seerr::answer(method, path, query, body) {
                Some(refused) if refused.0 != 204 => refused,
                _ => {
                    w.scan_running = true;
                    nothing()
                }
            }
        }
        ("DELETE", ["ScheduledTasks", "Running", id]) => {
            match *id {
                "optimize" => w.optimize_running = false,
                "scan" => w.scan_running = false,
                _ => return Some(Reply(404, "text/plain", b"no such task".to_vec())),
            }
            nothing()
        }
        ("POST", ["Sessions", id, "Playing", "Stop"]) => {
            w.stopped.push((*id).to_owned());
            nothing()
        }
        ("POST", ["Sessions", _, "Message"]) => nothing(),
        _ => return None,
    })
}

fn tasks(w: &World) -> String {
    let task = |id: &str, name: &str, running: bool, percent: f64| {
        if running {
            format!(
                r#"{{"Id":"{id}","Name":"{name}","State":"Running","CurrentProgressPercentage":{percent},"Category":"Maintenance"}}"#
            )
        } else {
            format!(r#"{{"Id":"{id}","Name":"{name}","State":"Idle","Category":"Library"}}"#)
        }
    };
    format!(
        "[{},{},{}]",
        task("optimize", "Optimize database", w.optimize_running, 42.4),
        task("scan", "Scan Media Library", w.scan_running, 17.0),
        task("clean", "Clean Cache Directory", false, 0.0)
    )
}

fn sessions(w: &World) -> String {
    let movie = format!(
        r#"{{"Id":"sess-anna","UserId":"u-anna","UserName":"Anna","UserPrimaryImageTag":"ua","Client":"Swiftly","DeviceName":"iPhone","RemoteEndPoint":"192.168.1.20",
 "NowPlayingItem":{{"Id":"m0","Name":"{name}","Type":"Movie","ProductionYear":2026,"RunTimeTicks":75330000000,"ImageTags":{{"Primary":"p0"}},
  "MediaStreams":[{{"Type":"Video","Codec":"hevc","Width":3840,"Height":1600,"VideoRangeType":"DOVIWithHDR10","BitRate":25000000,"Index":0}},
                  {{"Type":"Audio","Codec":"eac3","Channels":6,"BitRate":640000,"Index":1}}]}},
 "PlayState":{{"PositionTicks":18000000000,"IsPaused":false,"PlayMethod":"DirectPlay","AudioStreamIndex":1}}}}"#,
        name = NAMES[0]
    );
    let episode = r#"{"Id":"sess-ben","UserId":"u-ben","UserName":"Ben","Client":"Jellyfin Web","DeviceName":"Firefox","RemoteEndPoint":"192.168.1.31",
 "NowPlayingItem":{"Id":"e2","Name":"Folge 2","Type":"Episode","SeriesId":"s1","SeriesName":"Hafenlichter","ParentIndexNumber":1,"IndexNumber":2,"RunTimeTicks":27000000000,"ImageTags":{"Primary":"pe2"},"SeriesPrimaryImageTag":"ps1",
  "MediaStreams":[{"Type":"Video","Codec":"h264","Width":1920,"Height":1080,"VideoRangeType":"SDR","BitRate":8000000,"Index":0},
                  {"Type":"Audio","Codec":"dts","Channels":6,"BitRate":1536000,"Index":1}]},
 "PlayState":{"PositionTicks":6000000000,"IsPaused":true,"PlayMethod":"Transcode","AudioStreamIndex":1},
 "TranscodingInfo":{"IsVideoDirect":true,"IsAudioDirect":false,"Bitrate":8400000}}"#;
    let idle = r#"{"Id":"sess-idle","UserId":"u1","UserName":"demo","Client":"Swiftly","DeviceName":"iPad"}"#;
    let mut rows = Vec::new();
    for (id, row) in [
        ("sess-anna", movie.as_str()),
        ("sess-ben", episode),
        ("sess-idle", idle),
    ] {
        if !w.stopped.iter().any(|s| s == id) {
            rows.push(row);
        }
    }
    format!("[{}]", rows.join(","))
}

const STORAGE: &str = r#"{
 "ProgramDataFolder":{"Path":"/config","FreeSpace":120000000000,"UsedSpace":136000000000,"DeviceId":"/"},
 "CacheFolder":{"Path":"/cache","FreeSpace":120000000000,"UsedSpace":136000000000,"DeviceId":"/"},
 "TranscodingTempFolder":{"Path":"/tmp/transcodes","FreeSpace":-1,"UsedSpace":-1},
 "Libraries":[
  {"Id":"lib-movies","Name":"Filme","Folders":[{"Path":"/media/movies","FreeSpace":1200000000000,"UsedSpace":2800000000000,"DeviceId":"/media"}]},
  {"Id":"lib-shows","Name":"Serien","Folders":[{"Path":"/media/tv","FreeSpace":1200000000000,"UsedSpace":2800000000000,"DeviceId":"/media"}]},
  {"Id":"lib-archive","Name":"Archiv","Folders":[{"Path":"/usb/archive","FreeSpace":40000000000,"UsedSpace":960000000000,"DeviceId":"/usb"}]}
 ]}"#;

const LOGS: &str = r#"[
 {"Name":"log_20261117.log","Size":1468006,"DateModified":"2026-11-17T10:00:00.0000000Z","DateCreated":"2026-11-17T00:00:01.0000000Z"},
 {"Name":"log_20261116.log","Size":2411724,"DateModified":"2026-11-16T23:59:58.0000000Z","DateCreated":"2026-11-16T00:00:01.0000000Z"},
 {"Name":"FFmpeg.Transcode-2026-11-17_09-30-00_abcdef.log","Size":38912,"DateModified":"2026-11-17T09:41:12.0000000Z","DateCreated":"2026-11-17T09:30:00.0000000Z"}
]"#;

fn log_text() -> String {
    let mut out = String::new();
    for n in 0..240 {
        let level = if n % 40 == 39 { "WRN" } else { "INF" };
        out.push_str(&format!(
            "[2026-11-17 {:02}:{:02}:{:02}.{:03}] [{level}] [{}] Fixture log line {n}\n",
            9 + n / 120,
            (n / 2) % 60,
            (n * 7) % 60,
            (n * 13) % 1000,
            n % 9
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(r: Option<Reply>) -> (u16, String) {
        let Reply(status, _, body) = r.expect("answered");
        (status, String::from_utf8_lossy(&body).into_owned())
    }

    fn get(w: &mut World, guest: bool, path: &str, query: &str) -> (u16, String) {
        text(answer_with(w, guest, "GET", path, query, ""))
    }

    #[test]
    fn two_users_one_is_an_administrator() {
        let mut w = World::new();
        assert!(
            get(&mut w, false, "/Users/u1", "")
                .1
                .contains(r#""IsAdministrator":true"#)
        );
        assert!(
            get(&mut w, false, "/Users/u2", "")
                .1
                .contains(r#""IsAdministrator":false"#)
        );
        assert!(
            get(&mut w, false, "/Users/Me", "")
                .1
                .contains(r#""IsAdministrator":true"#)
        );
        assert!(
            get(&mut w, true, "/Users/Me", "")
                .1
                .contains(r#""IsAdministrator":false"#)
        );
        let auth = text(answer_with(
            &mut w,
            false,
            "POST",
            "/Users/AuthenticateByName",
            "",
            r#"{"Username":"gast","Pw":"demo"}"#,
        ));
        assert!(
            auth.1.contains(r#""AccessToken":"fixture-token-gast""#)
                && auth.1.contains(r#""Id":"u2""#),
            "{auth:?}"
        );
        let bad = answer_with(
            &mut w,
            false,
            "POST",
            "/Users/AuthenticateByName",
            "",
            r#"{"Username":"gast","Pw":"x"}"#,
        );
        assert_eq!(text(bad).0, 401);
        assert!(
            answer_with(
                &mut w,
                false,
                "POST",
                "/Users/AuthenticateByName",
                "",
                r#"{"Username":"nobody","Pw":"demo"}"#
            )
            .is_none()
        );
    }

    #[test]
    fn the_admin_reads_answer_and_the_guest_gets_403() {
        let mut w = World::new();
        assert!(
            get(&mut w, false, "/System/Info", "")
                .1
                .contains(r#""Version":"10.11.2""#)
        );
        assert!(
            get(&mut w, false, "/Items/Counts", "")
                .1
                .contains(r#""MovieCount":1204"#)
        );
        assert!(
            get(&mut w, false, "/Items", "Limit=0&Is4K=true&Recursive=true")
                .1
                .contains(r#""TotalRecordCount":12"#)
        );
        assert!(
            get(&mut w, false, "/System/Info/Storage", "")
                .1
                .contains("/usb/archive")
        );
        assert_eq!(get(&mut w, false, "/JellyTwiggy/SystemMetrics", "").0, 404);
        assert!(
            get(&mut w, false, "/System/Logs/Log", "name=log_20261117.log")
                .1
                .starts_with("[2026-11-17 09:00:00")
        );
        for path in [
            "/System/Info",
            "/ScheduledTasks",
            "/System/Logs",
            "/System/Info/Storage",
        ] {
            assert_eq!(get(&mut w, true, path, "").0, 403, "{path}");
        }
        assert_eq!(
            get(&mut w, true, "/Sessions", "activeWithinSeconds=60").0,
            403
        );
        // A plain item listing and the device registry are not this module's.
        assert!(answer_with(&mut w, false, "GET", "/Items", "Recursive=true", "").is_none());
        assert!(
            answer_with(
                &mut w,
                false,
                "GET",
                "/Sessions",
                "controllableByUserId=u1",
                ""
            )
            .is_none()
        );
    }

    #[test]
    fn restart_scan_stop_task_and_stop_stream_change_what_is_read_next() {
        let mut w = World::new();
        w.restart_pending = true;
        assert!(
            get(&mut w, false, "/System/Info", "")
                .1
                .contains(r#""HasPendingRestart":true"#)
        );
        assert_eq!(
            text(answer_with(
                &mut w,
                false,
                "POST",
                "/System/Restart",
                "",
                ""
            ))
            .0,
            204
        );
        assert!(
            get(&mut w, false, "/System/Info", "")
                .1
                .contains(r#""HasPendingRestart":false"#)
        );

        let idle = get(&mut w, false, "/ScheduledTasks", "").1;
        assert!(idle.contains(r#""Id":"optimize","Name":"Optimize database","State":"Running""#));
        assert!(idle.contains(r#""Id":"scan","Name":"Scan Media Library","State":"Idle""#));
        answer_with(&mut w, false, "POST", "/Library/Refresh", "", "");
        assert!(
            get(&mut w, false, "/ScheduledTasks", "")
                .1
                .contains(r#""Id":"scan","Name":"Scan Media Library","State":"Running""#)
        );
        assert_eq!(
            text(answer_with(
                &mut w,
                false,
                "DELETE",
                "/ScheduledTasks/Running/optimize",
                "",
                ""
            ))
            .0,
            204
        );
        assert!(
            get(&mut w, false, "/ScheduledTasks", "")
                .1
                .contains(r#""Id":"optimize","Name":"Optimize database","State":"Idle""#)
        );
        assert_eq!(
            text(answer_with(
                &mut w,
                false,
                "DELETE",
                "/ScheduledTasks/Running/nope",
                "",
                ""
            ))
            .0,
            404
        );

        let both = get(&mut w, false, "/Sessions", "activeWithinSeconds=60").1;
        assert!(both.contains("sess-anna") && both.contains("sess-ben"));
        answer_with(
            &mut w,
            false,
            "POST",
            "/Sessions/sess-ben/Message",
            "",
            r#"{"Header":"x","Text":"y"}"#,
        );
        answer_with(
            &mut w,
            false,
            "POST",
            "/Sessions/sess-ben/Playing/Stop",
            "",
            "",
        );
        let one = get(&mut w, false, "/Sessions", "activeWithinSeconds=60").1;
        assert!(one.contains("sess-anna") && !one.contains("sess-ben"));
        assert_eq!(
            w.calls,
            [
                "POST /System/Restart",
                "POST /Library/Refresh",
                "DELETE /ScheduledTasks/Running/optimize",
                "DELETE /ScheduledTasks/Running/nope",
                r#"POST /Sessions/sess-ben/Message {"Header":"x","Text":"y"}"#,
                "POST /Sessions/sess-ben/Playing/Stop",
            ]
        );
        assert!(
            text(answer_with(
                &mut w,
                false,
                "GET",
                "/fixture/admin-calls",
                "",
                ""
            ))
            .1
            .contains("Playing/Stop")
        );
        answer_with(&mut w, false, "POST", "/fixture/admin-reset", "", "");
        assert!(w.calls.is_empty() && w.optimize_running);
    }
}
