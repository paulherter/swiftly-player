//! SyncPlay for `cargo xtask fixture-server`: groups (list, new, join, leave, set new queue, pause, unpause, seek,
//! ready, buffering, ping), `GET /GetUtcTime`, the account's right (`GET /Users/{id}`) and the websocket `/socket`
//! the control channel listens on (ForceKeepAlive on open, SyncPlayGroupUpdate / SyncPlayCommand frames).
//!
//! Additive: nothing answers here until a client calls `/fixture/syncplay/reset` (or a SyncPlay write), so every
//! answer the fixture gave before stays byte-identical. Test hooks: `GET /fixture/syncplay/reset`,
//! `GET /fixture/syncplay/calls` (SyncPlay calls and client websocket frames in arrival order),
//! `GET /fixture/syncplay/guest?join=Anna|leave=Anna` (a second participant without a socket, always ready).
//! One group state machine, deterministic ids (`grp1`, `pli1`); times are the server's wall clock.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

const USER: &str = "demo";
/// Seconds between the server's answer to an unpause and the moment it asks the clients to start.
const START_DELAY: f64 = 0.3;

enum Out {
    Text(String),
    Pong(Vec<u8>),
    Close,
}

struct Group {
    id: String,
    name: String,
    state: &'static str,
    members: Vec<(String, String)>,
    queue: Vec<(String, String)>,
    index: i64,
    position: f64,
    stamp: f64,
    playing: bool,
    resume: bool,
    ready: Vec<String>,
}

#[derive(Default)]
struct World {
    touched: bool,
    groups: Vec<Group>,
    sockets: Vec<(u64, String, Sender<Out>)>,
    calls: Vec<String>,
    next_group: u32,
    next_entry: u32,
    next_socket: u64,
}

static WORLD: Mutex<World> = Mutex::new(World {
    touched: false,
    groups: Vec::new(),
    sockets: Vec::new(),
    calls: Vec::new(),
    next_group: 0,
    next_entry: 0,
    next_socket: 0,
});

fn world() -> MutexGuard<'static, World> {
    WORLD.lock().unwrap_or_else(PoisonError::into_inner)
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

/// `2026-11-09T10:11:12.345Z`.
fn time_text(seconds: f64) -> String {
    let ms = (seconds * 1000.0).round() as i64;
    let (days, of_day) = (ms.div_euclid(86_400_000), ms.rem_euclid(86_400_000));
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{:03}Z",
        of_day / 3_600_000,
        of_day / 60_000 % 60,
        of_day / 1000 % 60,
        of_day % 1000
    )
}

fn ticks(seconds: f64) -> i64 {
    (seconds * 10_000_000.0).round() as i64
}

fn quoted(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

/// Reads `"Key":"value"` or `"Key":number` out of a flat JSON body.
fn field(body: &str, key: &str) -> Option<String> {
    let at = body.find(&format!("\"{key}\""))? + key.len() + 2;
    let rest = body[at..].trim_start().strip_prefix(':')?.trim_start();
    if let Some(s) = rest.strip_prefix('"') {
        Some(s[..s.find('"')?].to_owned())
    } else {
        Some(
            rest.chars()
                .take_while(|c| {
                    c.is_ascii_digit()
                        || matches!(c, '.' | '-' | 't' | 'r' | 'u' | 'e' | 'f' | 'a' | 'l' | 's')
                })
                .collect(),
        )
    }
}

impl Group {
    fn info(&self) -> String {
        let who: Vec<String> = self.members.iter().map(|(_, n)| quoted(n)).collect();
        format!(
            r#"{{"GroupId":{},"GroupName":{},"State":"{}","Participants":[{}],"LastUpdatedAt":"{}"}}"#,
            quoted(&self.id),
            quoted(&self.name),
            self.state,
            who.join(","),
            time_text(self.stamp)
        )
    }

    fn entry(&self) -> Option<&str> {
        self.queue
            .get(usize::try_from(self.index).ok()?)
            .map(|(_, e)| e.as_str())
    }

    fn position_now(&self, at: f64) -> f64 {
        if self.playing {
            self.position + (at - self.stamp).max(0.0)
        } else {
            self.position
        }
    }

    fn state_update(&self, reason: &str) -> String {
        format!(
            r#"{{"MessageType":"SyncPlayGroupUpdate","Data":{{"GroupId":{},"Type":"StateUpdate","Data":{{"State":"{}","Reason":"{reason}"}}}}}}"#,
            quoted(&self.id),
            self.state
        )
    }

    fn update(&self, kind: &str, data: &str) -> String {
        format!(
            r#"{{"MessageType":"SyncPlayGroupUpdate","Data":{{"GroupId":{},"Type":"{kind}","Data":{data}}}}}"#,
            quoted(&self.id)
        )
    }

    fn command(&self, command: &str, when: f64, position: f64) -> String {
        let entry = self
            .entry()
            .map(|e| format!(r#""PlaylistItemId":{},"#, quoted(e)))
            .unwrap_or_default();
        format!(
            r#"{{"MessageType":"SyncPlayCommand","Data":{{"GroupId":{},{entry}"When":"{}","PositionTicks":{},"Command":"{command}","EmittedAt":"{}"}}}}"#,
            quoted(&self.id),
            time_text(when),
            ticks(position),
            time_text(now())
        )
    }

    fn queue_message(&self, reason: &str) -> String {
        let list: Vec<String> = self
            .queue
            .iter()
            .map(|(i, e)| {
                format!(
                    r#"{{"ItemId":{},"PlaylistItemId":{}}}"#,
                    quoted(i),
                    quoted(e)
                )
            })
            .collect();
        self.update(
            "PlayQueue",
            &format!(
                r#"{{"Reason":"{reason}","LastUpdate":"{}","Playlist":[{}],"PlayingItemIndex":{},"StartPositionTicks":{},"IsPlaying":{},"ShuffleMode":"Sorted","RepeatMode":"RepeatNone"}}"#,
                time_text(self.stamp),
                list.join(","),
                self.index,
                ticks(self.position),
                self.resume
            ),
        )
    }

    fn real_devices(&self) -> impl Iterator<Item = &String> {
        self.members
            .iter()
            .map(|(d, _)| d)
            .filter(|d| !d.starts_with("guest:"))
    }
}

impl World {
    fn send_to(&self, device: &str, text: &str) {
        for (_, d, tx) in &self.sockets {
            if d == device {
                let _ = tx.send(Out::Text(text.to_owned()));
            }
        }
    }

    fn send_group(&self, group: usize, texts: &[String]) {
        for (device, _) in &self.groups[group].members {
            for t in texts {
                self.send_to(device, t);
            }
        }
    }

    fn group_of(&self, device: &str) -> Option<usize> {
        self.groups
            .iter()
            .position(|g| g.members.iter().any(|(d, _)| d == device))
    }

    fn leave(&mut self, device: &str) {
        let Some(at) = self.group_of(device) else {
            return;
        };
        let name = self.groups[at]
            .members
            .iter()
            .find(|(d, _)| d == device)
            .map(|(_, n)| n.clone())
            .unwrap_or_default();
        let left = self.groups[at].update("GroupLeft", &quoted(&self.groups[at].id));
        self.send_to(device, &left);
        self.groups[at].members.retain(|(d, _)| d != device);
        self.groups[at].ready.retain(|d| d != device);
        if self.groups[at].real_devices().next().is_none() {
            self.groups.remove(at);
            return;
        }
        let said = self.groups[at].update("UserLeft", &quoted(&name));
        self.send_group(at, &[said]);
        self.resolve(at, "Ready");
    }

    /// When everybody is ready the group goes on (Playing after an unpause intent, else Paused).
    fn resolve(&mut self, at: usize, reason: &str) {
        let g = &self.groups[at];
        if g.state != "Waiting" || g.real_devices().any(|d| !g.ready.contains(d)) {
            return;
        }
        let t = now();
        let g = &mut self.groups[at];
        let messages = if g.resume {
            g.state = "Playing";
            g.playing = true;
            g.stamp = t + START_DELAY;
            vec![
                g.command("Unpause", t + START_DELAY, g.position),
                g.state_update(reason),
            ]
        } else {
            g.state = "Paused";
            g.playing = false;
            g.stamp = t;
            vec![g.command("Pause", t, g.position), g.state_update(reason)]
        };
        self.send_group(at, &messages);
    }

    fn waiting(&mut self, at: usize, reason: &str) {
        let g = &mut self.groups[at];
        g.state = "Waiting";
        g.ready.clear();
        let message = g.state_update(reason);
        self.send_group(at, &[message]);
    }
}

fn reply(status: u16, body: String) -> crate::fixture_server::Reply {
    crate::fixture_server::Reply(status, "application/json", body.into_bytes())
}

/// The answer to a SyncPlay related request, or `None` when the old fixture answers it.
pub(crate) fn answer(
    method: &str,
    target: &str,
    body: &str,
    device: &str,
) -> Option<crate::fixture_server::Reply> {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let path = path.trim_end_matches('/');
    let param = |k: &str| {
        query.split('&').find_map(|p| {
            p.split_once('=')
                .filter(|(n, _)| *n == k)
                .map(|(_, v)| v.to_owned())
        })
    };
    let mut w = world();
    if let Some(hook) = path.strip_prefix("/fixture/syncplay/") {
        return Some(match hook {
            "reset" => {
                *w = World {
                    touched: true,
                    next_socket: w.next_socket,
                    sockets: std::mem::take(&mut w.sockets),
                    ..World::default()
                };
                reply(200, "{}".into())
            }
            "calls" => reply(
                200,
                format!(
                    "[{}]",
                    w.calls
                        .iter()
                        .map(|c| quoted(c))
                        .collect::<Vec<_>>()
                        .join(",")
                ),
            ),
            "guest" => {
                w.touched = true;
                if let Some(name) = param("join")
                    && let Some(at) = w.groups.len().checked_sub(1)
                {
                    w.groups[at]
                        .members
                        .push((format!("guest:{name}"), name.clone()));
                    let said = w.groups[at].update("UserJoined", &quoted(&name));
                    w.send_group(at, &[said]);
                }
                if let Some(name) = param("leave") {
                    for at in 0..w.groups.len() {
                        if w.groups[at]
                            .members
                            .iter()
                            .any(|(d, _)| *d == format!("guest:{name}"))
                        {
                            w.groups[at]
                                .members
                                .retain(|(d, _)| *d != format!("guest:{name}"));
                            let said = w.groups[at].update("UserLeft", &quoted(&name));
                            w.send_group(at, &[said]);
                            w.resolve(at, "Ready");
                        }
                    }
                }
                reply(200, "{}".into())
            }
            _ => crate::fixture_server::Reply(404, "text/plain", b"no such hook".to_vec()),
        });
    }
    let write = method == "POST" && path.starts_with("/SyncPlay/");
    if !w.touched && !write {
        return None;
    }
    w.touched = true;
    let last = path.rsplit('/').next().unwrap_or("");
    if method == "GET" && path == "/GetUtcTime" {
        let t = now();
        return Some(reply(
            200,
            format!(
                r#"{{"RequestReceptionTime":"{}","ResponseTransmissionTime":"{}"}}"#,
                time_text(t),
                time_text(t)
            ),
        ));
    }
    if method == "GET"
        && path.starts_with("/Users/")
        && path.matches('/').count() == 2
        && path != "/Users/Public"
    {
        return Some(reply(
            200,
            format!(
                r#"{{"Id":"u1","Name":"{USER}","Policy":{{"SyncPlayAccess":"CreateAndJoinGroups"}}}}"#
            ),
        ));
    }
    if !path.starts_with("/SyncPlay/") {
        return None;
    }
    w.calls
        .push(format!("{method} {}", path.trim_start_matches('/')));
    let t = now();
    let at = w.group_of(device);
    match (method, last) {
        ("GET", "List") => {
            let rows: Vec<String> = w.groups.iter().map(Group::info).collect();
            return Some(reply(200, format!("[{}]", rows.join(","))));
        }
        ("POST", "New") => {
            w.leave(device);
            w.next_group += 1;
            let name = field(body, "GroupName")
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| "Group".into());
            let id = format!("grp{}", w.next_group);
            w.groups.push(Group {
                id,
                name,
                state: "Idle",
                members: vec![(device.to_owned(), USER.into())],
                queue: Vec::new(),
                index: -1,
                position: 0.0,
                stamp: t,
                playing: false,
                resume: false,
                ready: Vec::new(),
            });
            let at = w.groups.len() - 1;
            let joined = w.groups[at].update("GroupJoined", &w.groups[at].info());
            w.send_group(at, &[joined]);
        }
        ("POST", "Join") => {
            let wanted = field(body, "GroupId").unwrap_or_default();
            if !w.groups.iter().any(|g| g.id == wanted) {
                let none = r#"{"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"","Type":"GroupDoesNotExist","Data":""}}"#;
                w.send_to(device, none);
                return Some(crate::fixture_server::Reply(204, "text/plain", Vec::new()));
            }
            w.leave(device);
            let Some(at) = w.groups.iter().position(|g| g.id == wanted) else {
                return Some(reply(204, String::new()));
            };
            w.groups[at].members.push((device.to_owned(), USER.into()));
            let g = &w.groups[at];
            let joined = g.update("GroupJoined", &g.info());
            let others = g.update("UserJoined", &quoted(USER));
            let mut mine = vec![joined];
            if !g.queue.is_empty() {
                mine.push(g.queue_message("NewPlaylist"));
                mine.push(g.state_update("Join"));
            }
            for m in &mine {
                w.send_to(device, m);
            }
            for (d, _) in w.groups[at].members.clone() {
                if d != device {
                    w.send_to(&d, &others);
                }
            }
        }
        ("POST", "Leave") => w.leave(device),
        ("POST", "SetNewQueue") => {
            let Some(at) = at else {
                return Some(reply(204, String::new()));
            };
            let items: Vec<String> = body
                .split_once("\"PlayingQueue\"")
                .and_then(|(_, r)| r.split_once('[')?.1.split_once(']'))
                .map(|(l, _)| {
                    l.split(',')
                        .map(|s| s.trim().trim_matches('"').to_owned())
                        .filter(|s| !s.is_empty())
                        .collect()
                })
                .unwrap_or_default();
            let start = field(body, "StartPositionTicks")
                .and_then(|s| s.parse::<f64>().ok())
                .unwrap_or(0.0)
                / 10_000_000.0;
            let mut queue = Vec::new();
            for item in items {
                w.next_entry += 1;
                queue.push((item, format!("pli{}", w.next_entry)));
            }
            let g = &mut w.groups[at];
            g.queue = queue;
            g.index = 0;
            g.position = start;
            g.stamp = t;
            g.playing = false;
            g.resume = true;
            let message = g.queue_message("NewPlaylist");
            w.send_group(at, &[message]);
            w.waiting(at, "NewPlaylist");
        }
        ("POST", "Pause") => {
            let Some(at) = at else {
                return Some(reply(204, String::new()));
            };
            let g = &mut w.groups[at];
            g.position = g.position_now(t);
            g.state = "Paused";
            g.playing = false;
            g.resume = false;
            g.stamp = t;
            let messages = [g.command("Pause", t, g.position), g.state_update("Pause")];
            w.send_group(at, &messages);
        }
        ("POST", "Unpause") => {
            let Some(at) = at else {
                return Some(reply(204, String::new()));
            };
            let g = &mut w.groups[at];
            g.state = "Playing";
            g.playing = true;
            g.resume = true;
            g.stamp = t + START_DELAY;
            let messages = [
                g.command("Unpause", t + START_DELAY, g.position),
                g.state_update("Unpause"),
            ];
            w.send_group(at, &messages);
        }
        ("POST", "Seek") => {
            let Some(at) = at else {
                return Some(reply(204, String::new()));
            };
            let to = field(body, "PositionTicks")
                .and_then(|s| s.parse::<f64>().ok())
                .unwrap_or(0.0)
                / 10_000_000.0;
            let g = &mut w.groups[at];
            g.resume = g.playing || g.resume && g.state == "Waiting";
            g.position = to;
            g.stamp = t;
            g.playing = false;
            let command = g.command("Seek", t, to);
            w.send_group(at, &[command]);
            w.waiting(at, "Seek");
        }
        ("POST", "Buffering") => {
            let Some(at) = at else {
                return Some(reply(204, String::new()));
            };
            let g = &mut w.groups[at];
            g.position = field(body, "PositionTicks")
                .and_then(|s| s.parse::<f64>().ok())
                .unwrap_or(0.0)
                / 10_000_000.0;
            g.resume = field(body, "IsPlaying").is_some_and(|v| v == "true");
            g.playing = false;
            g.stamp = t;
            w.waiting(at, "Buffer");
            let (device, g) = (device.to_owned(), at);
            w.groups[g].ready.retain(|d| *d != device);
        }
        ("POST", "Ready") => {
            let Some(at) = at else {
                return Some(reply(204, String::new()));
            };
            if w.groups[at].state == "Waiting" && !w.groups[at].ready.iter().any(|d| d == device) {
                w.groups[at].ready.push(device.to_owned());
            }
            w.resolve(at, "Ready");
        }
        ("POST", "Ping") => {}
        _ => {
            return Some(crate::fixture_server::Reply(
                404,
                "text/plain",
                b"no such SyncPlay call".to_vec(),
            ));
        }
    }
    Some(crate::fixture_server::Reply(204, "text/plain", Vec::new()))
}

// ---- websocket ----

fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [
        0x6745_2301,
        0xEFCD_AB89,
        0x98BA_DCFE,
        0x1032_5476,
        0xC3D2_E1F0,
    ];
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for block in msg.chunks(64) {
        let mut w = [0_u32; 80];
        for (i, c) in block.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes([c[0], c[1], c[2], c[3]]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | (!b & d), 0x5A82_7999),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6_u32),
            };
            let tmp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*wi);
            (e, d, c, b, a) = (d, c, b.rotate_left(30), a, tmp);
        }
        for (x, y) in h.iter_mut().zip([a, b, c, d, e]) {
            *x = x.wrapping_add(y);
        }
    }
    let mut out = [0; 20];
    for (i, x) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&x.to_be_bytes());
    }
    out
}

fn base64(data: &[u8]) -> String {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in data.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= c.len() {
                out.push(char::from(A[(n >> (18 - 6 * i) & 63) as usize]))
            } else {
                out.push('=')
            }
        }
    }
    out
}

fn frame(opcode: u8, payload: &[u8]) -> Vec<u8> {
    let mut f = vec![0x80 | opcode];
    match payload.len() {
        n if n < 126 => f.push(n as u8),
        n if n < 65_536 => {
            f.push(126);
            f.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            f.push(127);
            f.extend_from_slice(&(n as u64).to_be_bytes());
        }
    }
    f.extend_from_slice(payload);
    f
}

fn read_frame(stream: &mut TcpStream) -> Option<(u8, Vec<u8>)> {
    let mut head = [0_u8; 2];
    stream.read_exact(&mut head).ok()?;
    let mut len = u64::from(head[1] & 0x7F);
    if len == 126 {
        let mut b = [0_u8; 2];
        stream.read_exact(&mut b).ok()?;
        len = u64::from(u16::from_be_bytes(b));
    } else if len == 127 {
        let mut b = [0_u8; 8];
        stream.read_exact(&mut b).ok()?;
        len = u64::from_be_bytes(b);
    }
    let mut mask = [0_u8; 4];
    if head[1] & 0x80 != 0 {
        stream.read_exact(&mut mask).ok()?;
    }
    let mut payload = vec![0_u8; usize::try_from(len).ok()?];
    stream.read_exact(&mut payload).ok()?;
    for (i, b) in payload.iter_mut().enumerate() {
        *b ^= mask[i % 4];
    }
    Some((head[0] & 0x0F, payload))
}

/// Whether the device holds a `/socket` right now (what makes a session take remote control).
pub(crate) fn has_socket(device: &str) -> bool {
    world().sockets.iter().any(|(_, d, _)| d == device)
}

/// A text message for the device's socket; `false` when it holds none.
pub(crate) fn send_text(device: &str, text: &str) -> bool {
    world()
        .sockets
        .iter()
        .filter(|(_, d, _)| d == device)
        .fold(false, |sent, (_, _, tx)| {
            tx.send(Out::Text(text.to_owned())).is_ok() || sent
        })
}

/// A play order for the device's socket, as the server forwards `POST /Sessions/{id}/Playing` (`Play` message).
/// `false` when the device holds no socket.
pub(crate) fn send_play(device: &str, item_ids: &str, ticks: i64) -> bool {
    let ids: Vec<String> = item_ids.split(',').map(|i| format!("\"{i}\"")).collect();
    let text = format!(
        r#"{{"MessageType":"Play","Data":{{"PlayCommand":"PlayNow","ItemIds":[{}],"StartPositionTicks":{ticks},"StartIndex":0}}}}"#,
        ids.join(",")
    );
    let w = world();
    w.sockets
        .iter()
        .filter(|(_, d, _)| d == device)
        .fold(false, |sent, (_, _, tx)| {
            tx.send(Out::Text(text.clone())).is_ok() || sent
        })
}

/// Takes over the connection: handshake, a writer for what the groups send, a reader for the client's frames.
pub(crate) fn websocket(mut stream: TcpStream, key: &str, device: &str) {
    let accept = base64(&sha1(
        format!("{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11").as_bytes(),
    ));
    let head = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
    );
    if stream.write_all(head.as_bytes()).is_err() {
        return;
    }
    let (tx, rx): (Sender<Out>, Receiver<Out>) = channel();
    let id = {
        let mut w = world();
        w.next_socket += 1;
        let id = w.next_socket;
        // A device may hold several sockets (the control channel and the group channel); a real server forwards a
        // message to every one of them, and a socket leaves the list when it closes.
        w.sockets.push((id, device.to_owned(), tx.clone()));
        id
    };
    eprintln!("fixture-server: websocket open for {device}");
    let _ = tx.send(Out::Text(
        r#"{"MessageType":"ForceKeepAlive","Data":60}"#.into(),
    ));
    let Ok(mut writer) = stream.try_clone() else {
        return;
    };
    std::thread::spawn(move || {
        while let Ok(out) = rx.recv() {
            let bytes = match out {
                Out::Text(t) => frame(1, t.as_bytes()),
                Out::Pong(p) => frame(10, &p),
                Out::Close => {
                    let _ = writer.write_all(&frame(8, &[]));
                    return;
                }
            };
            if writer.write_all(&bytes).is_err() {
                return;
            }
        }
    });
    while let Some((opcode, payload)) = read_frame(&mut stream) {
        match opcode {
            1 => {
                let text = String::from_utf8_lossy(&payload).into_owned();
                let mut w = world();
                if w.touched {
                    w.calls.push(format!("ws {text}"));
                }
            }
            9 => {
                let _ = tx.send(Out::Pong(payload));
            }
            8 => break,
            _ => {}
        }
    }
    let _ = tx.send(Out::Close);
    world().sockets.retain(|(i, _, _)| *i != id);
    eprintln!("fixture-server: websocket closed for {device}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_play_order_for_a_device_without_a_socket_goes_nowhere() {
        assert!(!send_play("no-such-device", "m1", 0));
    }

    #[test]
    fn handshake_key_matches_rfc_6455() {
        assert_eq!(
            base64(&sha1(
                b"dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            )),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        );
    }

    #[test]
    fn a_message_reaches_every_socket_of_a_device() {
        let (a, ra) = channel();
        let (b, rb) = channel();
        {
            let mut w = world();
            w.sockets.push((901, "two-sockets".into(), a));
            w.sockets.push((902, "two-sockets".into(), b));
        }
        assert!(send_text("two-sockets", "hello"));
        world().sockets.retain(|(i, _, _)| *i != 901 && *i != 902);
        for rx in [ra, rb] {
            assert!(matches!(rx.try_recv(), Ok(Out::Text(t)) if t == "hello"));
        }
    }

    fn call(method: &str, path: &str, body: &str, device: &str) -> (u16, String) {
        let r = answer(method, path, body, device).expect("answered");
        (r.0, String::from_utf8(r.2).expect("utf-8"))
    }

    /// The only test that touches the global state.
    #[test]
    fn group_flow_lists_joins_queues_and_leaves() {
        assert!(
            answer("GET", "/SyncPlay/List", "", "d1").is_none() || world().touched,
            "old answer until a client opts in"
        );
        call("GET", "/fixture/syncplay/reset", "", "");
        assert_eq!(call("GET", "/SyncPlay/List", "", "d1").1, "[]");
        assert!(
            call("GET", "/Users/u1", "", "d1")
                .1
                .contains("CreateAndJoinGroups")
        );
        let (tx, rx) = channel();
        world().sockets.push((99, "d1".into(), tx));
        assert_eq!(
            call("POST", "/SyncPlay/New", r#"{"GroupName":"Abend"}"#, "d1").0,
            204
        );
        assert!(
            call("GET", "/SyncPlay/List", "", "d1")
                .1
                .contains(r#""GroupId":"grp1","GroupName":"Abend","State":"Idle""#)
        );
        call(
            "POST",
            "/SyncPlay/SetNewQueue",
            r#"{"PlayingQueue":["m1","m2"],"PlayingItemPosition":0,"StartPositionTicks":50000000}"#,
            "d1",
        );
        call(
            "POST",
            "/SyncPlay/Ready",
            r#"{"PlaylistItemId":"pli1"}"#,
            "d1",
        );
        let seen: Vec<String> = std::iter::from_fn(|| rx.try_recv().ok())
            .filter_map(|o| if let Out::Text(t) = o { Some(t) } else { None })
            .collect();
        let all = seen.join("\n");
        for part in [
            "GroupJoined",
            "PlayQueue",
            r#""Playlist":[{"ItemId":"m1","PlaylistItemId":"pli1"},{"ItemId":"m2","PlaylistItemId":"pli2"}]"#,
            r#""State":"Waiting","Reason":"NewPlaylist""#,
            r#""Command":"Unpause""#,
            r#""State":"Playing""#,
        ] {
            assert!(all.contains(part), "missing {part} in {all}");
        }
        call("POST", "/SyncPlay/Leave", "", "d1");
        assert_eq!(call("GET", "/SyncPlay/List", "", "d1").1, "[]");
    }

    #[test]
    fn times_use_milliseconds_and_utc() {
        assert_eq!(time_text(0.0), "1970-01-01T00:00:00.000Z");
        assert_eq!(time_text(1_700_000_000.5), "2023-11-14T22:13:20.500Z");
    }
}
