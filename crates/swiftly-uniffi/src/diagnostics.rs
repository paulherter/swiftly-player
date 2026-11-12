//! Support and diagnostics helpers the host calls instead of its own copies: the log ring with
//! credential redaction and the "Share log" file text, the Discord Rich Presence payload and socket
//! path logic, the brand paths and the title-logo metric. Pure logic; the host owns the clock, the
//! time zone, the socket and the files.

use std::sync::Arc;

use swiftly_rules::playback_levels::play_time_text;
use swiftly_rules::title_marks;
use swiftly_support::discord::{
    self, DiscordDisplay, DiscordEnv, DiscordPlatform, DiscordPresence, PresenceAction,
};
use swiftly_support::{log_ring, marks};

// MARK: Log ring and redaction

/// Credentials in free text blacked out (`LogRedaction.text`).
#[uniffi::export]
pub fn log_redact(text: String) -> String {
    log_ring::redact(&text)
}

/// The last log lines in memory (`LogRing`): redacted on entry, trimmed in batches. Times are Unix
/// seconds, `utc_offset` is the local time zone in seconds east of UTC.
#[derive(uniffi::Object)]
pub struct LogRingModel {
    inner: log_ring::LogRing,
}

#[uniffi::export]
impl LogRingModel {
    /// A ring of about `limit` lines (the app uses 4000).
    #[uniffi::constructor]
    pub fn new(limit: u32) -> Arc<Self> {
        Arc::new(Self {
            inner: log_ring::LogRing::new(limit as usize),
        })
    }

    /// A ring with the default limit of 4000 lines.
    #[uniffi::constructor]
    pub fn standard() -> Arc<Self> {
        Arc::new(Self {
            inner: log_ring::LogRing::default(),
        })
    }

    /// Adds a line; credentials are blacked out before it is stored.
    pub fn append(&self, text: String, now: f64) {
        self.inner.append(&text, now);
    }

    /// The lines of the last `seconds`, oldest first, as `HH:mm:ss.SSS text`.
    pub fn excerpt(&self, seconds: f64, now: f64, utc_offset: i64) -> Vec<String> {
        self.inner.excerpt(seconds, now, utc_offset)
    }

    /// Number of lines held.
    pub fn count(&self) -> u64 {
        self.inner.len() as u64
    }

    /// The whole "Share log" file for the last hour (`version_line` and `system` from the
    /// `log_share_*` helpers).
    pub fn share_text(
        &self,
        version_line: String,
        system: String,
        now: f64,
        utc_offset: i64,
    ) -> String {
        self.inner
            .share_text(&version_line, &system, now, utc_offset)
    }
}

/// The "Share log" file text from its parts: version line, system line, `Stand <stamp>`, an empty
/// line, then the excerpt or the "no lines in the last hour" note.
#[uniffi::export]
pub fn log_share_text(
    version_line: String,
    system: String,
    stamp: String,
    excerpt_lines: Vec<String>,
) -> String {
    log_ring::share_text(&version_line, &system, &stamp, &excerpt_lines)
}

/// `Swiftly-Protokoll.txt`.
#[uniffi::export]
pub fn log_share_file_name() -> String {
    log_ring::SHARE_FILE_NAME.to_owned()
}

/// The note the file carries when the last hour is empty.
#[uniffi::export]
pub fn log_share_empty_note() -> String {
    log_ring::SHARE_EMPTY_NOTE.to_owned()
}

/// `yyyy-MM-ddTHH:mm:ssZ` in UTC for the `Stand` line.
#[uniffi::export]
pub fn log_share_stamp(unix_seconds: f64) -> String {
    log_ring::iso8601_utc(unix_seconds)
}

/// `HH:mm:ss.SSS` of a Unix time in the time zone `utc_offset`.
#[uniffi::export]
pub fn log_clock_text(unix_seconds: f64, utc_offset: i64) -> String {
    log_ring::clock_text(unix_seconds, utc_offset)
}

/// iOS and macOS version line: `Swiftly <version>`.
#[uniffi::export]
pub fn log_share_version_line_apple(version: String) -> String {
    log_ring::share_version_line_apple(&version)
}

/// Linux and Windows version line: `<full version> · libVLC <version>`.
#[uniffi::export]
pub fn log_share_version_line_desktop(full_version: String, vlc_version: String) -> String {
    log_ring::share_version_line_desktop(&full_version, &vlc_version)
}

/// iOS system line: `iOS 18.1.0 · iPhone`.
#[uniffi::export]
pub fn log_share_system_ios(major: i64, minor: i64, patch: i64, model: String) -> String {
    log_ring::share_system_ios(major, minor, patch, &model)
}

/// macOS system line: `macOS 15.1.0`.
#[uniffi::export]
pub fn log_share_system_macos(major: i64, minor: i64, patch: i64) -> String {
    log_ring::share_system_macos(major, minor, patch)
}

/// Linux or Windows system line: `Linux <os version string>` / `Windows <...>`.
#[uniffi::export]
pub fn log_share_system_desktop(windows: bool, os_version: String) -> String {
    log_ring::share_system_desktop(windows, &os_version)
}

// MARK: Discord

/// What is in the Discord profile (`DiscordDisplay`). Times are Unix seconds.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DiscordDisplayInfo {
    /// The bold line.
    pub title: String,
    /// The line below.
    pub subline: Option<String>,
    /// Start of the playback (the bar is drawn from start and end).
    pub from_unix: Option<f64>,
    /// End of the playback.
    pub until_unix: Option<f64>,
}

impl From<DiscordDisplay> for DiscordDisplayInfo {
    fn from(d: DiscordDisplay) -> Self {
        Self {
            title: d.title,
            subline: d.subline,
            from_unix: d.from,
            until_unix: d.until,
        }
    }
}

impl From<&DiscordDisplayInfo> for DiscordDisplay {
    fn from(d: &DiscordDisplayInfo) -> Self {
        Self {
            title: d.title.clone(),
            subline: d.subline.clone(),
            from: d.from_unix,
            until: d.until_unix,
        }
    }
}

/// The environment the socket search reads.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct DiscordSocketEnv {
    /// `XDG_RUNTIME_DIR`.
    pub xdg_runtime_dir: Option<String>,
    /// `TMPDIR`.
    pub tmpdir: Option<String>,
    /// `TMP`.
    pub tmp: Option<String>,
    /// `TEMP`.
    pub temp: Option<String>,
    /// `NSTemporaryDirectory()` (Mac fallback when `TMPDIR` is not set).
    pub temporary_directory: Option<String>,
}

/// Where the search runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DiscordSocketPlatform {
    /// macOS.
    Mac,
    /// Linux and other Unix.
    Unix,
    /// Windows named pipes.
    Windows,
}

/// The Discord application id the status runs under.
#[uniffi::export]
pub fn discord_client_id() -> String {
    discord::CLIENT_ID.to_owned()
}

/// The activity object as JSON text (type 3, `details`, `state`, assets, timestamps in ms).
#[uniffi::export]
pub fn discord_activity_json(display: DiscordDisplayInfo) -> String {
    DiscordDisplay::from(&display).activity_json().to_string()
}

/// For the log: what goes out, in one line.
#[uniffi::export]
pub fn discord_short_version(display: DiscordDisplayInfo) -> String {
    DiscordDisplay::from(&display).short_version()
}

/// Whether two displays are the same to the second (the guard against needless sending).
#[uniffi::export]
pub fn discord_displays_equal(a: DiscordDisplayInfo, b: DiscordDisplayInfo) -> bool {
    DiscordDisplay::from(&a) == DiscordDisplay::from(&b)
}

/// The handshake frame (opcode 0, `{"client_id", "v": 1}`), ready to write.
#[uniffi::export]
pub fn discord_handshake_frame(client_id: String) -> Vec<u8> {
    discord::handshake_frame(&client_id)
}

/// A `SET_ACTIVITY` frame (opcode 1); `None` clears the display.
#[uniffi::export]
pub fn discord_set_activity_frame(
    pid: i64,
    display: Option<DiscordDisplayInfo>,
    nonce: String,
) -> Vec<u8> {
    discord::set_activity_frame(
        pid,
        display.as_ref().map(DiscordDisplay::from).as_ref(),
        &nonce,
    )
}

/// The close frame (opcode 2, `{}`).
#[uniffi::export]
pub fn discord_close_frame() -> Vec<u8> {
    discord::close_frame()
}

/// The socket paths (or pipe names on Windows) to try, in order.
#[uniffi::export]
pub fn discord_candidate_paths(
    env: DiscordSocketEnv,
    platform: DiscordSocketPlatform,
) -> Vec<String> {
    let env = DiscordEnv {
        xdg_runtime_dir: env.xdg_runtime_dir,
        tmpdir: env.tmpdir,
        tmp: env.tmp,
        temp: env.temp,
        temporary_directory: env.temporary_directory,
    };
    let platform = match platform {
        DiscordSocketPlatform::Mac => DiscordPlatform::Mac,
        DiscordSocketPlatform::Unix => DiscordPlatform::Unix,
        DiscordSocketPlatform::Windows => DiscordPlatform::Windows,
    };
    discord::candidate_paths(&env, platform)
}

/// The ten Windows pipe names.
#[uniffi::export]
pub fn discord_pipe_names() -> Vec<String> {
    discord::pipe_names()
}

/// Whether a Unix socket path fits `sockaddr_un` (under 104 bytes).
#[uniffi::export]
pub fn discord_path_fits(path: String) -> bool {
    discord::path_fits(&path)
}

/// What the host does after a player tick.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum DiscordAction {
    /// Nothing to send.
    Nothing,
    /// Connect if needed and send this display.
    Show { display: DiscordDisplayInfo },
    /// Clear the display.
    Clear,
}

impl From<PresenceAction> for DiscordAction {
    fn from(a: PresenceAction) -> Self {
        match a {
            PresenceAction::Nothing => Self::Nothing,
            PresenceAction::Show(d) => Self::Show { display: d.into() },
            PresenceAction::Clear => Self::Clear,
        }
    }
}

/// The outcome of one tick.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DiscordStep {
    /// A line for the log, only when the state text changed.
    pub log: Option<String>,
    /// What to send.
    pub action: DiscordAction,
}

/// The "send only when something changes" decision of the player ticks (`DiscordState`).
#[derive(uniffi::Object)]
pub struct DiscordPresenceModel {
    inner: std::sync::Mutex<DiscordPresence>,
}

#[uniffi::export]
impl DiscordPresenceModel {
    /// A fresh state.
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: std::sync::Mutex::new(DiscordPresence::new()),
        })
    }

    /// One tick: what to show (and the log line) from the title, the optional subline, the position,
    /// the runtime, whether it runs, whether the user allows the status, and the Unix time now.
    #[allow(clippy::too_many_arguments)]
    pub fn report(
        &self,
        title: String,
        subline: Option<String>,
        spot: f64,
        duration: f64,
        running: bool,
        allowed: bool,
        now: f64,
    ) -> DiscordStep {
        let step = self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .report(
                &title,
                subline.as_deref(),
                spot,
                duration,
                running,
                allowed,
                now,
                &play_time_text,
            );
        DiscordStep {
            log: step.log,
            action: step.action.into(),
        }
    }

    /// Clears the display if one was shown.
    pub fn tidy_away(&self) -> DiscordAction {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .tidy_away()
            .into()
    }
}

// MARK: Brand paths

/// The frame the brand paths are drawn in.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct MarksFrame {
    /// Left (SVG origin, may be negative).
    pub x: f64,
    /// Top (negative in the SVG source).
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

/// The "swiftly" wordmark as an SVG path (`MarksPaths.wordmark`).
#[uniffi::export]
pub fn marks_wordmark() -> String {
    marks::WORDMARK.to_owned()
}

/// The play arrow above the "i" (`MarksPaths.wordmarkAccent`).
#[uniffi::export]
pub fn marks_wordmark_accent() -> String {
    marks::WORDMARK_ACCENT.to_owned()
}

/// The frame the paths are drawn in (`MarksPaths.wordmarkFrame`).
#[uniffi::export]
pub fn marks_wordmark_frame() -> MarksFrame {
    let [x, y, width, height] = marks::WORDMARK_FRAME;
    MarksFrame {
        x,
        y,
        width,
        height,
    }
}

/// `#50D5DA`.
#[uniffi::export]
pub fn marks_accent_hex() -> String {
    marks::ACCENT_HEX.to_owned()
}

/// `#17181B`.
#[uniffi::export]
pub fn marks_area_hex() -> String {
    marks::AREA_HEX.to_owned()
}

// MARK: Title logo metric

/// What measuring a title logo yields (`TitleMarksMetric.LogoMeasurement`).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct LogoMeasurement {
    /// Crop in pixels, without the transparent border.
    pub x: i64,
    /// Crop top.
    pub y: i64,
    /// Crop width.
    pub width: i64,
    /// Crop height.
    pub height: i64,
    /// Share of opaque pixels in the crop, 0...1.
    pub density: f64,
    /// Mean relative luminance of the opaque pixels, 0...1.
    pub luminance: f64,
    /// Width over height (`pagesRatio`).
    pub pages_ratio: f64,
}

/// A logo's size in points.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct LogoSize {
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

/// Measures a premultiplied 8-bit RGBA image (`width * 4` bytes per row); `None` if nothing is
/// opaque or the buffer is too short.
#[uniffi::export]
pub fn title_marks_measure(rgba: Vec<u8>, width: i64, height: i64) -> Option<LogoMeasurement> {
    title_marks::measure(&rgba, width, height).map(|m| LogoMeasurement {
        x: m.x,
        y: m.y,
        width: m.width,
        height: m.height,
        density: m.density,
        luminance: m.luminance,
        pages_ratio: m.pages_ratio(),
    })
}

/// Below this luminance a logo is drawn as a light silhouette.
#[uniffi::export]
pub fn title_marks_is_dark(luminance: f64) -> bool {
    title_marks::is_dark(luminance)
}

/// Gentle size compensation for very full or very thin logos, 0.85...1.15.
#[uniffi::export]
pub fn title_marks_density_factor(density: f64) -> f64 {
    title_marks::density_factor(density)
}

/// Size for equal visual weight; `row` is one title line in points.
#[uniffi::export]
pub fn title_marks_size(
    pages_ratio: f64,
    density: f64,
    row: f64,
    max_width: f64,
    max_height: Option<f64>,
) -> LogoSize {
    let (width, height) = title_marks::size(pages_ratio, density, row, max_width, max_height);
    LogoSize { width, height }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exports_agree_with_the_pure_code() {
        assert_eq!(log_redact("pw=abc".into()), "pw=\u{2026}");
        let ring = LogRingModel::new(10);
        ring.append("x token=1".into(), 100.0);
        assert_eq!(
            ring.excerpt(3600.0, 100.0, 0),
            vec!["00:01:40.000 x token=\u{2026}".to_owned()]
        );
        assert_eq!(ring.count(), 1);
        let frame = discord_handshake_frame(discord_client_id());
        assert_eq!(
            &frame[8..],
            format!("{{\"client_id\":\"{}\",\"v\":1}}", discord::CLIENT_ID).as_bytes()
        );
        assert_eq!(discord_pipe_names().len(), 10);
        let step =
            DiscordPresenceModel::new().report("T".into(), None, 0.0, 60.0, true, true, 1000.0);
        assert!(matches!(step.action, DiscordAction::Show { .. }));
        assert_eq!(marks_wordmark().len(), 2981);
        assert_eq!(marks_wordmark_frame().width, 3005.0);
        assert!(title_marks_measure(vec![0; 16], 2, 2).is_none());
        let m = title_marks_measure(vec![255; 16], 2, 2);
        assert_eq!(
            m.map(|m| (m.width, m.height, m.pages_ratio)),
            Some((2, 2, 1.0))
        );
        assert!(title_marks_is_dark(0.1) && !title_marks_is_dark(0.5));
    }
}
