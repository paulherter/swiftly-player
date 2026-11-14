//! A Jellyfin-like session registry for the fixture server: what `GET /Sessions` answers on a real server.
//!
//! Every authenticated request makes or touches the session of its device. `SupportsRemoteControl` is true only
//! while the device holds a `/socket`. The playing reports set and clear `NowPlayingItem` (a progress report sets
//! it again, as on the server), the capabilities report fills `PlayableMediaTypes`, and `GET /Sessions` honours
//! `controllableByUserId` and `activeWithinSeconds`. Commands to a session (`Playing/Stop`, `Message`, ...) go to
//! the device's socket the way the server forwards them.

use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

const TICKS: f64 = 10_000_000.0;

#[derive(Clone, Default)]
struct Session {
    device_id: String,
    device_name: String,
    client: String,
    version: String,
    playable: Vec<String>,
    item: Option<String>,
    ticks: i64,
    paused: bool,
    last: f64,
}

static SESSIONS: Mutex<Vec<Session>> = Mutex::new(Vec::new());

fn sessions() -> MutexGuard<'static, Vec<Session>> {
    SESSIONS.lock().unwrap_or_else(PoisonError::into_inner)
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

fn field(header: &str, key: &str) -> String {
    header
        .split_once(&format!("{key}=\""))
        .map(|(_, r)| r.split('"').next().unwrap_or("").to_owned())
        .unwrap_or_default()
}

fn entry<'a>(all: &'a mut Vec<Session>, device: &str) -> &'a mut Session {
    if let Some(i) = all.iter().position(|s| s.device_id == device) {
        return &mut all[i];
    }
    all.push(Session {
        device_id: device.to_owned(),
        ..Session::default()
    });
    let last = all.len() - 1;
    &mut all[last]
}

/// The raw text after `"key":` in a flat JSON body (no parser in the fixture): a string without its quotes, or a number or
/// boolean as written.
fn raw(body: &str, key: &str) -> Option<String> {
    let rest = body.split_once(&format!("\"{key}\":"))?.1.trim_start();
    if let Some(text) = rest.strip_prefix('"') {
        return Some(text.split('"').next()?.to_owned());
    }
    Some(rest.split([',', '}', ']']).next()?.trim().to_owned())
}

/// An authenticated request came in with this `Authorization` value: the session of its device is made or touched.
pub(crate) fn seen(header: &str) {
    let device = field(header, "DeviceId");
    if device.is_empty() {
        return;
    }
    let mut all = sessions();
    let s = entry(&mut all, &device);
    s.device_name = field(header, "Device");
    s.client = field(header, "Client");
    s.version = field(header, "Version");
    s.last = now();
}

/// The playing reports and the capabilities report, as the server applies them to the session of `device`.
pub(crate) fn observe(method: &str, path: &str, body: &str, device: &str) {
    if method != "POST" || device.is_empty() {
        return;
    }
    let mut all = sessions();
    let s = entry(&mut all, device);
    s.last = now();
    match path {
        "/Sessions/Capabilities/Full" | "/Sessions/Capabilities" => {
            s.playable = body
                .split_once("\"PlayableMediaTypes\":[")
                .and_then(|(_, r)| r.split(']').next())
                .map(|l| {
                    l.split(',')
                        .map(|t| t.trim().trim_matches('"').to_owned())
                        .filter(|t| !t.is_empty())
                        .collect()
                })
                .unwrap_or_default();
        }
        "/Sessions/Playing" | "/Sessions/Playing/Progress" => {
            if let Some(item) = raw(body, "ItemId").and_then(|i| crate::fixture_server::find(&i)) {
                s.item = Some(item);
                s.ticks = raw(body, "PositionTicks")
                    .and_then(|t| t.parse().ok())
                    .unwrap_or(0);
                s.paused = raw(body, "IsPaused").is_some_and(|p| p == "true");
            }
        }
        "/Sessions/Playing/Stopped" => {
            s.item = None;
            s.ticks = 0;
            s.paused = false;
        }
        _ => {}
    }
}

fn iso(secs: f64) -> String {
    let whole = secs.floor() as i64;
    let (days, rest) = (whole.div_euclid(86_400), whole.rem_euclid(86_400));
    // Civil date from days since 1970 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    let frac = ((secs - secs.floor()) * 1e7) as i64;
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{frac:07}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

/// `GET /Sessions`: with `controllableByUserId` only the sessions that take remote control (a held socket), with
/// `activeWithinSeconds` only the recently active ones.
pub(crate) fn list(query: &str) -> String {
    let param = |k: &str| {
        query.split('&').find_map(|p| {
            p.split_once('=')
                .filter(|(n, _)| *n == k)
                .map(|(_, v)| v.to_owned())
        })
    };
    let controllable = param("controllableByUserId").is_some();
    let within: Option<f64> = param("activeWithinSeconds").and_then(|v| v.parse().ok());
    let t = now();
    let rows: Vec<String> = sessions()
        .iter()
        .filter(|s| !controllable || crate::fixture_syncplay::has_socket(&s.device_id))
        .filter(|s| within.is_none_or(|w| t - s.last <= w))
        .map(|s| {
            let remote = crate::fixture_syncplay::has_socket(&s.device_id);
            let playing = s
                .item
                .as_ref()
                .map(|i| format!(r#","NowPlayingItem":{i}"#))
                .unwrap_or_default();
            let position = if s.item.is_some() {
                format!(r#","PositionTicks":{}"#, s.ticks)
            } else {
                String::new()
            };
            let types: Vec<String> = s.playable.iter().map(|t| format!("\"{t}\"")).collect();
            format!(
                r#"{{"Id":"{d}","UserId":"u1","UserName":"demo","Client":"{c}","DeviceName":"{n}","DeviceId":"{d}","ApplicationVersion":"{v}","LastActivityDate":"{a}","SupportsRemoteControl":{remote},"PlayableMediaTypes":[{t}],"PlayState":{{"CanSeek":{seek},"IsPaused":{p}{position}}}{playing}}}"#,
                d = s.device_id,
                c = s.client,
                n = s.device_name,
                v = s.version,
                a = iso(s.last),
                t = types.join(","),
                seek = s.item.is_some(),
                p = s.paused,
            )
        })
        .collect();
    format!("[{}]", rows.join(","))
}

/// `POST /Sessions/{id}/...` to a device: forwarded to its socket. `None` for a path this does not know.
pub(crate) fn command(path: &str, query: &str, body: &str) -> Option<crate::fixture_server::Reply> {
    let rest = path.strip_prefix("/Sessions/")?;
    let (device, what) = rest.split_once('/')?;
    let param = |k: &str| {
        query.split('&').find_map(|p| {
            p.split_once('=')
                .filter(|(n, _)| *n == k)
                .map(|(_, v)| v.to_owned())
        })
    };
    let text = match what {
        "Playing/Stop" | "Playing/Pause" | "Playing/Unpause" => format!(
            r#"{{"MessageType":"Playstate","Data":{{"Command":"{}"}}}}"#,
            what.trim_start_matches("Playing/")
        ),
        "Message" => {
            format!(
                r#"{{"MessageType":"GeneralCommand","Data":{{"Name":"DisplayMessage","Arguments":{{"Header":"{}","Text":"{}","TimeoutMs":"{}"}}}}}}"#,
                raw(body, "Header").unwrap_or_default(),
                raw(body, "Text").unwrap_or_default(),
                raw(body, "TimeoutMs").unwrap_or_default()
            )
        }
        "Playing" => {
            let ticks: i64 = param("startPositionTicks")
                .and_then(|t| t.parse().ok())
                .unwrap_or(0);
            crate::fixture_syncplay::send_play(
                device,
                &param("itemIds").unwrap_or_default(),
                ticks,
            );
            return Some(crate::fixture_server::Reply(204, "text/plain", Vec::new()));
        }
        _ => return None,
    };
    let sent = crate::fixture_syncplay::send_text(device, &text);
    Some(crate::fixture_server::Reply(
        if sent { 204 } else { 404 },
        "text/plain",
        Vec::new(),
    ))
}

/// The ticks of a position in seconds (tests of the fixture itself).
#[allow(dead_code)]
pub(crate) fn seconds(ticks: i64) -> f64 {
    ticks as f64 / TICKS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_writes_the_server_shape() {
        assert_eq!(iso(0.0), "1970-01-01T00:00:00.0000000Z");
        assert_eq!(iso(1_700_000_000.5), "2023-11-14T22:13:20.5000000Z");
    }
}
