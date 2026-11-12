//! The last log lines in memory, redacted on entry, and the "Share log" file text
//! (`LogRing.swift`, `Sources/Shared/LogShare.swift`, `Linux/.../Log.swift`).
//!
//! Sans-I/O: the clock and the local time zone (as an offset in seconds east of UTC) are passed in.

use std::sync::{Mutex, PoisonError};

use regex_lite::{Captures, Regex};

/// Names whose value is a secret (`LogRedaction.names`).
const NAMES: &str = "api_key|apikey|x-emby-token|x-mediabrowser-token|token|accesstoken|access_token|secret|pw|password";

/// ICU `\s` (`White_Space`) spelled out, because `regex-lite` knows ASCII only.
const WS: &str =
    r"\t\n\x0B\x0C\r \x{85}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}";

/// The mask character the Swift rules write: `…`.
const MASK: &str = "\u{2026}";

/// ICU's `\w` as far as `\b` needs it: letters, digits, marks, connector punctuation.
fn is_word(c: char) -> bool {
    c.is_alphanumeric()
        || c == '_'
        || matches!(
            c,
            '\u{200C}' | '\u{200D}' | '\u{0300}'..='\u{036F}' | '\u{203F}' | '\u{2040}'
        )
}

struct Rule {
    re: Regex,
    /// Needs a word boundary before the match (`\b`, ICU semantics, checked by hand).
    boundary: bool,
    /// Builds the replacement from the captures.
    build: fn(&Captures<'_>) -> String,
}

fn rules() -> &'static [Rule] {
    static RULES: std::sync::OnceLock<Vec<Rule>> = std::sync::OnceLock::new();
    RULES.get_or_init(|| {
        let rx = |p: String| Regex::new(&p).unwrap_or_else(|_| unreachable!("static pattern"));
        vec![
            // name="value": Jellyfin's Authorization header
            Rule {
                re: rx(format!(r#"(?i)({NAMES})([{WS}]*[=:][{WS}]*)"[^"]*""#)),
                boundary: true,
                build: |c| format!("{}{}\"{MASK}\"", &c[1], &c[2]),
            },
            // name=value: query values and header lines
            Rule {
                re: rx(format!(
                    r#"(?i)({NAMES})([{WS}]*[=:][{WS}]*)[^&{WS}"',;)]+"#
                )),
                boundary: true,
                build: |c| format!("{}{}{MASK}", &c[1], &c[2]),
            },
            // scheme://name:passwort@
            Rule {
                re: rx(format!(
                    r"(?i)([a-z][a-z0-9+.-]*://)[^/{WS}@:]+:[^/{WS}@]+@"
                )),
                boundary: false,
                build: |c| format!("{}{MASK}@", &c[1]),
            },
        ]
    })
}

fn apply(text: &str, rule: &Rule) -> String {
    let mut out = String::with_capacity(text.len());
    let (mut copied, mut pos) = (0, 0);
    while pos <= text.len() {
        let Some(c) = rule.re.captures_at(text, pos) else {
            break;
        };
        let Some(m) = c.get(0) else { break };
        if rule.boundary && text[..m.start()].chars().next_back().is_some_and(is_word) {
            // Not at a word start: look again one character further on.
            pos = m.start() + text[m.start()..].chars().next().map_or(1, char::len_utf8);
            continue;
        }
        out.push_str(&text[copied..m.start()]);
        out.push_str(&(rule.build)(&c));
        copied = m.end();
        pos = m.end().max(m.start() + 1);
    }
    out.push_str(&text[copied..]);
    out
}

/// Credentials in free text (`LogRedaction.text`): the secret names of the address rules, the
/// `Authorization` header and `scheme://name:passwort@`.
pub fn redact(raw: &str) -> String {
    let mut text = raw.to_owned();
    for rule in rules() {
        text = apply(&text, rule);
    }
    text
}

/// The in-memory ring (`LogRing`): the last `limit` lines with their time, redacted on entry.
#[derive(Debug)]
pub struct LogRing {
    limit: usize,
    rows: Mutex<Vec<(f64, String)>>,
}

impl Default for LogRing {
    fn default() -> Self {
        Self::new(4000)
    }
}

impl LogRing {
    /// A ring that keeps about `limit` lines.
    pub fn new(limit: usize) -> Self {
        Self {
            limit,
            rows: Mutex::new(Vec::new()),
        }
    }

    /// Adds a line. Redaction happens here, so a credential never sits in memory in plain text.
    pub fn append(&self, text: &str, now: f64) {
        let clean = redact(text);
        let mut rows = self.rows.lock().unwrap_or_else(PoisonError::into_inner);
        rows.push((now, clean));
        // Trim in batches, not by shifting one line at every entry.
        if rows.len() > self.limit + self.limit / 8 {
            let drop = rows.len() - self.limit;
            rows.drain(..drop);
        }
    }

    /// The lines of the last `seconds`, oldest first, each as `HH:mm:ss.SSS text` in the time zone
    /// `utc_offset` (seconds east of UTC).
    pub fn excerpt(&self, seconds: f64, now: f64, utc_offset: i64) -> Vec<String> {
        let cutoff = now - seconds;
        let rows = self.rows.lock().unwrap_or_else(PoisonError::into_inner);
        rows.iter()
            .filter(|(t, _)| *t >= cutoff)
            .map(|(t, s)| format!("{} {s}", clock_text(*t, utc_offset)))
            .collect()
    }

    /// Number of lines held.
    pub fn len(&self) -> usize {
        self.rows
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len()
    }

    /// Whether nothing is held.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The whole "Share log" file for the last hour.
    pub fn share_text(
        &self,
        version_line: &str,
        system: &str,
        now: f64,
        utc_offset: i64,
    ) -> String {
        share_text(
            version_line,
            system,
            &iso8601_utc(now),
            &self.excerpt(3600.0, now, utc_offset),
        )
    }
}

/// `HH:mm:ss.SSS` (`en_US_POSIX`) of a Unix time in the zone `utc_offset`; milliseconds are cut,
/// not rounded.
pub fn clock_text(unix: f64, utc_offset: i64) -> String {
    let whole = unix.floor();
    let ms = (((unix - whole) * 1000.0).floor() as i64).clamp(0, 999);
    let day_second = (whole as i64).saturating_add(utc_offset).rem_euclid(86_400);
    format!(
        "{:02}:{:02}:{:02}.{ms:03}",
        day_second / 3600,
        day_second % 3600 / 60,
        day_second % 60
    )
}

/// `ISO8601DateFormatter` default: `yyyy-MM-ddTHH:mm:ssZ` in UTC.
pub fn iso8601_utc(unix: f64) -> String {
    let secs = unix.floor() as i64;
    let (days, rest) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Civil date from days since 1970-01-01 (Howard Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

/// File name of the shared log (`Swiftly-Protokoll.txt`).
pub const SHARE_FILE_NAME: &str = "Swiftly-Protokoll.txt";

/// What the file says when nothing was logged in the last hour.
pub const SHARE_EMPTY_NOTE: &str = "(no lines in the last hour \u{2014} reproduce the problem first, then share without closing the app)";

/// The "Share log" file text: the version line, the system line, `Stand <ISO8601>`, an empty
/// line, then the excerpt or [`SHARE_EMPTY_NOTE`]; joined by `\n`, no trailing newline
/// (`LogFile.write`). `version_line` is `Swiftly <version>` on iOS and macOS and
/// `<full version> · libVLC <version>` on Linux and Windows.
pub fn share_text(version_line: &str, system: &str, stamp: &str, excerpt: &[String]) -> String {
    let mut rows = vec![
        version_line.to_owned(),
        system.to_owned(),
        format!("Stand {stamp}"),
        String::new(),
    ];
    if excerpt.is_empty() {
        rows.push(SHARE_EMPTY_NOTE.to_owned());
    } else {
        rows.extend(excerpt.iter().cloned());
    }
    rows.join("\n")
}

/// The Apple version line: `Swiftly <version>` (`Version.withBase`).
pub fn share_version_line_apple(version: &str) -> String {
    format!("Swiftly {version}")
}

/// The iOS system line: `iOS 18.1.0 · iPhone`.
pub fn share_system_ios(major: i64, minor: i64, patch: i64, model: &str) -> String {
    format!("iOS {major}.{minor}.{patch} \u{b7} {model}")
}

/// The macOS system line: `macOS 15.1.0`.
pub fn share_system_macos(major: i64, minor: i64, patch: i64) -> String {
    format!("macOS {major}.{minor}.{patch}")
}

/// The desktop version line: `<full version> · libVLC <version>`.
pub fn share_version_line_desktop(full_version: &str, vlc_version: &str) -> String {
    format!("{full_version} \u{b7} libVLC {vlc_version}")
}

/// The desktop system line: `Linux <os version string>` or `Windows <...>`.
pub fn share_system_desktop(windows: bool, os_version: &str) -> String {
    format!("{} {os_version}", if windows { "Windows" } else { "Linux" })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blacks_out_query_values_headers_and_address_data() {
        let raw = "http://10.0.0.5:8096/Videos/abc/stream?static=true&ApiKey=0123456789abcdef&mediaSourceId=x \
                   Authorization: MediaBrowser Client=\"Swiftly\", Token=\"geheim123\" \
                   X-Emby-Token: geheim456 https://nutzer:passwort@server.example/";
        let clean = redact(raw);
        for secret in [
            "0123456789abcdef",
            "geheim123",
            "geheim456",
            "passwort",
            "nutzer",
        ] {
            assert!(!clean.contains(secret), "{secret} still in {clean}");
        }
        assert!(clean.contains("http://10.0.0.5:8096/Videos/abc/stream"));
        assert!(clean.contains("mediaSourceId=x"));
        assert!(clean.contains("server.example"));
        // Exact result, read by hand from the three Swift patterns.
        assert_eq!(
            clean,
            "http://10.0.0.5:8096/Videos/abc/stream?static=true&ApiKey=\u{2026}&mediaSourceId=x \
             Authorization: MediaBrowser Client=\"Swiftly\", Token=\"\u{2026}\" \
             X-Emby-Token: \u{2026} https://\u{2026}@server.example/"
        );
    }

    #[test]
    fn word_boundary_and_case() {
        assert_eq!(redact("mytoken=abc"), "mytoken=abc");
        assert_eq!(redact("äpw=abc"), "äpw=abc");
        assert_eq!(redact("PW = abc;rest"), "PW = \u{2026};rest");
        assert_eq!(
            redact("x:y api_key=1 token:2"),
            "x:y api_key=\u{2026} token:\u{2026}"
        );
        assert_eq!(redact("Password=\"a b\" end"), "Password=\"\u{2026}\" end");
        assert_eq!(redact("ftp://a:b@h/p"), "ftp://\u{2026}@h/p");
        assert_eq!(redact("plain text"), "plain text");
    }

    #[test]
    fn gives_only_last_hour() {
        let ring = LogRing::default();
        let now = 1_000_000.0;
        ring.append("alt", now - 3700.0);
        ring.append("neu ApiKey=abc", now - 10.0);
        let excerpt = ring.excerpt(3600.0, now, 0);
        assert_eq!(excerpt.len(), 1);
        assert!(excerpt[0].ends_with("neu ApiKey=\u{2026}"));
        // 1_000_000 - 10 = 999_990 s = day 11 + 13 h 46 min 30 s.
        assert_eq!(excerpt[0], "13:46:30.000 neu ApiKey=\u{2026}");
    }

    #[test]
    fn holds_itself_at_the_limit() {
        let ring = LogRing::new(100);
        let now = 1_700_000_000.0;
        for i in 0..500 {
            ring.append(&format!("zeile {i}"), now);
        }
        let excerpt = ring.excerpt(3600.0, now, 0);
        assert!(excerpt.len() <= 100 + 100 / 8);
        assert!(excerpt.last().is_some_and(|l| l.ends_with("zeile 499")));
        assert_eq!(ring.len(), excerpt.len());
    }

    #[test]
    fn clock_uses_offset_and_cuts_milliseconds() {
        assert_eq!(clock_text(0.0, 0), "00:00:00.000");
        assert_eq!(clock_text(3661.9876, 3600), "02:01:01.987");
        assert_eq!(clock_text(10.0, -3600), "23:00:10.000");
    }

    #[test]
    fn iso_stamp() {
        assert_eq!(iso8601_utc(0.0), "1970-01-01T00:00:00Z");
        assert_eq!(
            iso8601_utc(1_709_164_800.0 + 86_399.5),
            "2024-02-29T23:59:59Z"
        );
        assert_eq!(iso8601_utc(1_000_000.0), "1970-01-12T13:46:40Z");
    }

    #[test]
    fn share_file_text() {
        let empty = share_text(
            &share_version_line_apple("1.2.3"),
            &share_system_macos(15, 1, 0),
            "2026-11-09T10:00:00Z",
            &[],
        );
        assert_eq!(
            empty,
            "Swiftly 1.2.3\nmacOS 15.1.0\nStand 2026-11-09T10:00:00Z\n\n(no lines in the last hour \u{2014} reproduce the problem first, then share without closing the app)"
        );
        let ring = LogRing::default();
        ring.append("a token=x", 100.0);
        ring.append("b", 101.0);
        let full = ring.share_text("Swiftly 1", &share_system_ios(18, 1, 0, "iPhone"), 160.0, 0);
        assert_eq!(
            full,
            "Swiftly 1\niOS 18.1.0 \u{b7} iPhone\nStand 1970-01-01T00:02:40Z\n\n00:01:40.000 a token=\u{2026}\n00:01:41.000 b"
        );
        assert_eq!(
            share_version_line_desktop("Swiftly 1.2 (3)", "3.0.21"),
            "Swiftly 1.2 (3) \u{b7} libVLC 3.0.21"
        );
        assert_eq!(
            share_system_desktop(true, "10.0.26100"),
            "Windows 10.0.26100"
        );
        assert_eq!(SHARE_FILE_NAME, "Swiftly-Protokoll.txt");
    }
}
