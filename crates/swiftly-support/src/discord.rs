//! Discord Rich Presence without I/O: the activity JSON, the IPC frames, the socket path
//! candidates and the "what to show, when to send" decision (`DiscordBridge.swift`,
//! `Linux/.../DiscordState.swift`).
//!
//! The host owns the socket or named pipe and does the reading and writing; this module only says
//! what to write and where to try. JSON keys are written in alphabetical order (the Swift
//! `JSONSerialization` leaves the order open); the content is the same, only `/` is not escaped.

use serde_json::{Value, json};

/// The Discord application the status runs under (`DiscordState.bridge`).
pub const CLIENT_ID: &str = "1547651294335078534";

/// Handshake opcode.
pub const OP_HANDSHAKE: u32 = 0;
/// Frame opcode (`SET_ACTIVITY`).
pub const OP_FRAME: u32 = 1;
/// Close opcode.
pub const OP_CLOSE: u32 = 2;

/// The large image, as an address Discord fetches itself (`DiscordDisplay.symbolText`).
pub const SYMBOL_URL: &str = "https://raw.githubusercontent.com/paulherter/swiftly-player/main/Linux/Ressourcen/icons/hicolor/512x512/apps/de.paulherter.swiftly.png";

/// What is in the profile (`DiscordDisplay`). Times are Unix seconds.
#[derive(Debug, Clone)]
pub struct DiscordDisplay {
    /// The bold line: the movie, or a series' name.
    pub title: String,
    /// The line below, e.g. `S2:E1 · Episode name`.
    pub subline: Option<String>,
    /// Start of the current playback; Discord draws the bar from `from` and `until`.
    pub from: Option<f64>,
    /// End of the current playback.
    pub until: Option<f64>,
}

impl PartialEq for DiscordDisplay {
    /// To the second, not to the instant (`DiscordDisplay ==`): the timestamps drift by fractions
    /// between two ticks, and a plain comparison would resend every tick.
    fn eq(&self, other: &Self) -> bool {
        let second = |d: Option<f64>| d.map(|v| v as i64);
        self.title == other.title
            && self.subline == other.subline
            && second(self.from) == second(other.from)
            && second(self.until) == second(other.until)
    }
}

impl DiscordDisplay {
    /// A display with a title only.
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            subline: None,
            from: None,
            until: None,
        }
    }

    /// The activity object (`asWordsBook`): type 3 ("watching"), `details`, `state` unless the
    /// subline is missing or empty, the logo as `large_image`, `timestamps` in milliseconds when
    /// both ends are known.
    pub fn activity_json(&self) -> Value {
        let mut activity = json!({
            "type": 3,
            "details": self.title,
            "assets": {"large_image": SYMBOL_URL, "large_text": "Swiftly Player"},
        });
        if let Some(subline) = self.subline.as_deref().filter(|s| !s.is_empty()) {
            activity["state"] = json!(subline);
        }
        if let (Some(from), Some(until)) = (self.from, self.until) {
            activity["timestamps"] =
                json!({"start": (from * 1000.0) as i64, "end": (until * 1000.0) as i64});
        }
        activity
    }

    /// For the log (`shortVersion`): what goes out, in one line.
    pub fn short_version(&self) -> String {
        let span = match (self.from, self.until) {
            (Some(from), Some(until)) => format!("Balken {} s", (until - from) as i64),
            _ => "ohne Balken".to_owned(),
        };
        format!(
            "{} \u{b7} {} \u{b7} {span}",
            self.title,
            self.subline.as_deref().unwrap_or("\u{2014}")
        )
    }
}

/// One IPC frame: opcode and body length as four bytes each, little-endian, then the body.
pub fn frame(opcode: u32, body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + body.len());
    out.extend_from_slice(&opcode.to_le_bytes());
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend_from_slice(body);
    out
}

fn json_frame(opcode: u32, value: &Value) -> Vec<u8> {
    frame(opcode, value.to_string().as_bytes())
}

/// The handshake: opcode 0, `{"client_id": …, "v": 1}`.
pub fn handshake_frame(client_id: &str) -> Vec<u8> {
    json_frame(OP_HANDSHAKE, &json!({"v": 1, "client_id": client_id}))
}

/// `SET_ACTIVITY`: opcode 1, `{"args": {"activity": …, "pid": …}, "cmd": "SET_ACTIVITY", "nonce": …}`.
/// `None` clears the display (no `activity` key).
pub fn set_activity_frame(pid: i64, display: Option<&DiscordDisplay>, nonce: &str) -> Vec<u8> {
    let mut args = json!({"pid": pid});
    if let Some(display) = display {
        args["activity"] = display.activity_json();
    }
    json_frame(
        OP_FRAME,
        &json!({"cmd": "SET_ACTIVITY", "args": args, "nonce": nonce}),
    )
}

/// The close frame: opcode 2, `{}`.
pub fn close_frame() -> Vec<u8> {
    frame(OP_CLOSE, b"{}")
}

/// The environment the socket search reads. The host fills what it has.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DiscordEnv {
    /// `XDG_RUNTIME_DIR`.
    pub xdg_runtime_dir: Option<String>,
    /// `TMPDIR`.
    pub tmpdir: Option<String>,
    /// `TMP`.
    pub tmp: Option<String>,
    /// `TEMP`.
    pub temp: Option<String>,
    /// `NSTemporaryDirectory()`, used on the Mac when `TMPDIR` is not set.
    pub temporary_directory: Option<String>,
}

/// Where the search runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscordPlatform {
    /// macOS: the session's temporary folder only.
    Mac,
    /// Linux and other Unix: runtime dir, temp dirs, `/tmp`, Flatpak and Snap folders.
    Unix,
    /// Windows: named pipes.
    Windows,
}

/// Sockets Discord numbers, `discord-ipc-0` to `-9`.
pub const SLOTS: usize = 10;

/// The ten named pipes (`\\.\pipe\discord-ipc-0` to `-9`).
pub fn pipe_names() -> Vec<String> {
    (0..SLOTS)
        .map(|n| format!(r"\\.\pipe\discord-ipc-{n}"))
        .collect()
}

/// The places to try, in order (`set()`): ten numbered sockets under every root. A root with a
/// trailing `/` loses that one slash.
pub fn candidate_paths(env: &DiscordEnv, platform: DiscordPlatform) -> Vec<String> {
    let roots: Vec<String> = match platform {
        DiscordPlatform::Windows => return pipe_names(),
        DiscordPlatform::Mac => env
            .tmpdir
            .clone()
            .or_else(|| env.temporary_directory.clone())
            .into_iter()
            .collect(),
        DiscordPlatform::Unix => {
            let mut roots = Vec::new();
            if let Some(x) = &env.xdg_runtime_dir {
                roots.push(x.clone());
            }
            roots.extend(
                [
                    env.tmpdir.clone(),
                    env.tmp.clone(),
                    env.temp.clone(),
                    Some("/tmp".to_owned()),
                ]
                .into_iter()
                .flatten(),
            );
            if let Some(x) = &env.xdg_runtime_dir {
                roots.push(format!("{x}/app/com.discordapp.Discord")); // Flatpak
                roots.push(format!("{x}/snap.discord")); // Snap
            }
            roots
        }
    };
    let mut routes = Vec::with_capacity(roots.len() * SLOTS);
    for root in roots {
        let clean = root.strip_suffix('/').unwrap_or(&root);
        routes.extend((0..SLOTS).map(|n| format!("{clean}/discord-ipc-{n}")));
    }
    routes
}

/// Whether a Unix socket path fits `sockaddr_un` (fewer than 104 bytes; longer would be silently
/// truncated and connect to something else).
pub fn path_fits(path: &str) -> bool {
    path.len() < 104
}

/// `Int(duration)`-style truncation for the log lines.
fn whole(v: f64) -> i64 {
    v as i64
}

/// What the host does after a report.
#[derive(Debug, Clone, PartialEq)]
pub enum PresenceAction {
    /// Nothing changed or nothing to show.
    Nothing,
    /// Send this display (connect first if needed).
    Show(DiscordDisplay),
    /// Clear the display.
    Clear,
}

/// The outcome of one tick: an optional log line plus the action.
#[derive(Debug, Clone, PartialEq)]
pub struct PresenceStep {
    /// `[Discord] Stand: …`, only when the state text changed.
    pub log: Option<String>,
    /// What to send.
    pub action: PresenceAction,
}

/// The "send only when something changes" state (`DiscordState`): the last logged state text,
/// the last display sent and whether anything was shown at all.
#[derive(Debug, Clone, Default)]
pub struct DiscordPresence {
    last_state: String,
    recent: Option<DiscordDisplay>,
    ran: bool,
}

impl DiscordPresence {
    /// A fresh state.
    pub fn new() -> Self {
        Self::default()
    }

    /// One tick of the player (`DiscordState.report`). `time_text` is `PlayTime.text`; `now` is
    /// Unix seconds.
    #[allow(clippy::too_many_arguments)]
    pub fn report(
        &mut self,
        title: &str,
        subline: Option<&str>,
        spot: f64,
        duration: f64,
        running: bool,
        allowed: bool,
        now: f64,
        time_text: &dyn Fn(f64) -> String,
    ) -> PresenceStep {
        // Log only when the state changes, not every second.
        let state = format!(
            "erlaubt={allowed} dauer={} laeuft={running} titel={title}",
            whole(duration)
        );
        let log = (state != self.last_state).then(|| {
            let line = format!("[Discord] Stand: {state} stelle={}", whole(spot));
            self.last_state = state;
            line
        });
        if !allowed {
            return PresenceStep {
                log,
                action: self.tidy_away(),
            };
        }
        // Without a known runtime Discord would show its own counter: send nothing yet.
        if duration <= 0.0 {
            return PresenceStep {
                log,
                action: PresenceAction::Nothing,
            };
        }
        // Paused: no bar, but the position in the text, so nothing claims anything false.
        let addition = (!running).then(|| format!("{} / {}", time_text(spot), time_text(duration)));
        let row = [subline.map(str::to_owned), addition]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" \u{b7} ");
        let display = DiscordDisplay {
            title: title.to_owned(),
            subline: (!row.is_empty()).then_some(row),
            from: running.then_some(now - spot),
            until: running.then_some(now + (duration - spot)),
        };
        if self.recent.as_ref() == Some(&display) {
            return PresenceStep {
                log,
                action: PresenceAction::Nothing,
            };
        }
        self.recent = Some(display.clone());
        self.ran = true;
        PresenceStep {
            log,
            action: PresenceAction::Show(display),
        }
    }

    /// Clears the display if one was shown (`DiscordState.tidyAway`).
    pub fn tidy_away(&mut self) -> PresenceAction {
        if !self.ran {
            return PresenceAction::Nothing;
        }
        self.ran = false;
        self.recent = None;
        PresenceAction::Clear
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(v: f64) -> String {
        format!("t{}", v as i64)
    }

    #[test]
    fn activity_with_everything() {
        let d = DiscordDisplay {
            title: "Film".into(),
            subline: Some("S2:E1 \u{b7} Pilot".into()),
            from: Some(1000.5),
            until: Some(4600.25),
        };
        assert_eq!(
            d.activity_json().to_string(),
            format!(
                "{{\"assets\":{{\"large_image\":\"{SYMBOL_URL}\",\"large_text\":\"Swiftly Player\"}},\"details\":\"Film\",\"state\":\"S2:E1 \u{b7} Pilot\",\"timestamps\":{{\"end\":4600250,\"start\":1000500}},\"type\":3}}"
            )
        );
        assert_eq!(
            d.short_version(),
            "Film \u{b7} S2:E1 \u{b7} Pilot \u{b7} Balken 3599 s"
        );
    }

    #[test]
    fn activity_without_optionals() {
        let mut d = DiscordDisplay::new("Film");
        d.subline = Some(String::new());
        d.from = Some(5.0);
        let v = d.activity_json();
        assert!(v.get("state").is_none() && v.get("timestamps").is_none());
        assert_eq!(v["type"], 3);
        // An empty (not missing) subline stays empty in the log line, as in Swift.
        assert_eq!(d.short_version(), "Film \u{b7}  \u{b7} ohne Balken");
        d.subline = None;
        assert_eq!(d.short_version(), "Film \u{b7} \u{2014} \u{b7} ohne Balken");
    }

    #[test]
    fn equality_is_to_the_second() {
        let a = DiscordDisplay {
            title: "A".into(),
            subline: None,
            from: Some(100.1),
            until: Some(200.2),
        };
        let b = DiscordDisplay {
            from: Some(100.9),
            until: Some(200.9),
            ..a.clone()
        };
        let c = DiscordDisplay {
            from: Some(101.0),
            ..a.clone()
        };
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_ne!(a, DiscordDisplay::new("A"));
    }

    #[test]
    fn frames_are_exact_bytes() {
        assert_eq!(frame(1, b"ab"), vec![1, 0, 0, 0, 2, 0, 0, 0, b'a', b'b']);
        let hs = handshake_frame("123");
        let body = br#"{"client_id":"123","v":1}"#;
        assert_eq!(&hs[..4], &[0, 0, 0, 0]);
        assert_eq!(&hs[4..8], &(body.len() as u32).to_le_bytes());
        assert_eq!(&hs[8..], body);
        assert_eq!(close_frame(), vec![2, 0, 0, 0, 2, 0, 0, 0, b'{', b'}']);
        let clear = set_activity_frame(42, None, "n-1");
        assert_eq!(&clear[..4], &[1, 0, 0, 0]);
        assert_eq!(
            &clear[8..],
            br#"{"args":{"pid":42},"cmd":"SET_ACTIVITY","nonce":"n-1"}"#
        );
        let shown = set_activity_frame(42, Some(&DiscordDisplay::new("X")), "n");
        let value: Value = serde_json::from_slice(&shown[8..]).unwrap_or(Value::Null);
        assert_eq!(value["args"]["activity"]["details"], "X");
        assert_eq!(value["args"]["pid"], 42);
        assert_eq!(
            u32::from_le_bytes([shown[4], shown[5], shown[6], shown[7]]) as usize,
            shown.len() - 8
        );
    }

    #[test]
    fn candidates_unix_in_swift_order() {
        let env = DiscordEnv {
            xdg_runtime_dir: Some("/run/user/1000".into()),
            tmpdir: Some("/var/tmp/".into()),
            tmp: None,
            temp: Some("/t".into()),
            temporary_directory: None,
        };
        let paths = candidate_paths(&env, DiscordPlatform::Unix);
        assert_eq!(paths.len(), 60);
        let root_of = |i: usize| paths[i * 10].trim_end_matches("/discord-ipc-0").to_owned();
        assert_eq!(
            (0..6).map(root_of).collect::<Vec<_>>(),
            [
                "/run/user/1000",
                "/var/tmp",
                "/t",
                "/tmp",
                "/run/user/1000/app/com.discordapp.Discord",
                "/run/user/1000/snap.discord"
            ]
        );
        assert_eq!(paths[9], "/run/user/1000/discord-ipc-9");
        assert_eq!(paths[59], "/run/user/1000/snap.discord/discord-ipc-9");
        let bare = candidate_paths(&DiscordEnv::default(), DiscordPlatform::Unix);
        assert_eq!((bare.len(), bare[0].as_str()), (10, "/tmp/discord-ipc-0"));
    }

    #[test]
    fn candidates_mac_and_windows() {
        let mac = DiscordEnv {
            tmpdir: None,
            temporary_directory: Some("/var/folders/x/T/".into()),
            ..DiscordEnv::default()
        };
        let paths = candidate_paths(&mac, DiscordPlatform::Mac);
        assert_eq!(
            (paths.len(), paths[0].as_str()),
            (10, "/var/folders/x/T/discord-ipc-0")
        );
        let pipes = candidate_paths(&mac, DiscordPlatform::Windows);
        assert_eq!(
            (pipes.len(), pipes[0].as_str(), pipes[9].as_str()),
            (10, r"\\.\pipe\discord-ipc-0", r"\\.\pipe\discord-ipc-9")
        );
        assert!(path_fits(&"a".repeat(103)) && !path_fits(&"a".repeat(104)));
    }

    #[test]
    fn presence_sends_on_change_only() {
        let mut p = DiscordPresence::new();
        // Duration unknown: log, send nothing.
        let s = p.report("T", Some("sub"), 5.0, 0.0, true, true, 1000.0, &text);
        assert_eq!(
            s.log.as_deref(),
            Some("[Discord] Stand: erlaubt=true dauer=0 laeuft=true titel=T stelle=5")
        );
        assert_eq!(s.action, PresenceAction::Nothing);
        // Known: show with bar.
        let s = p.report("T", Some("sub"), 5.0, 100.0, true, true, 1000.0, &text);
        let PresenceAction::Show(d) = s.action else {
            panic!("expected show")
        };
        assert_eq!(
            (d.from, d.until, d.subline.as_deref()),
            (Some(995.0), Some(1095.0), Some("sub"))
        );
        // Same second, fractions drift: no resend, and no second log line for the same state.
        let s = p.report("T", Some("sub"), 5.0, 100.0, true, true, 1000.4, &text);
        assert_eq!((s.log, s.action), (None, PresenceAction::Nothing));
        // Paused: no bar, position in the text.
        let s = p.report("T", Some("sub"), 5.0, 100.0, false, true, 1001.0, &text);
        let PresenceAction::Show(d) = s.action else {
            panic!("expected show")
        };
        assert_eq!(
            (d.from, d.until, d.subline.as_deref()),
            (None, None, Some("sub \u{b7} t5 / t100"))
        );
        let s = p.report("T", None, 5.0, 100.0, false, true, 1001.0, &text);
        let PresenceAction::Show(d) = s.action else {
            panic!("expected show")
        };
        assert_eq!(d.subline.as_deref(), Some("t5 / t100"));
        // Not allowed: clear once.
        assert_eq!(
            p.report("T", None, 5.0, 100.0, false, false, 1002.0, &text)
                .action,
            PresenceAction::Clear
        );
        assert_eq!(
            p.report("T", None, 5.0, 100.0, false, false, 1003.0, &text)
                .action,
            PresenceAction::Nothing
        );
    }
}
