//! When a frozen picture is a dropout, and when merely a sluggish stream
//! (`JK/PowerGuard.swift`, enum `StreamWatch`), and the mid-play check built on it
//! (`StreamCheck`, from the desktop `PlayerPage.streamCheck` / `audioCheck` / `streamTornDown` /
//! `woke`).
//!
//! **The numbers are measured, not chosen.** An earlier version of this rule tore down a
//! stream whose buffer was still growing; rebuilding cost ten seconds and the same stall began
//! again. Changing one constant changes behaviour; the reason is next to each one.
//!
//! Sans-I/O: every time is passed in (seconds on any consistent clock), nothing is read here.

/// How long a network change counts as an explanation for a stall (seconds). After that a frozen
/// picture is frozen for another reason.
pub const NETWORK_SWITCH_DEADLINE: f64 = 90.0;
/// Stall before intervening, **after** a network change: the cause is known, waiting achieves
/// nothing.
pub const STANDSTILL_AFTER_SWITCH: f64 = 2.0;
/// Stall before intervening, otherwise: with no known cause it may be a sluggish server, and
/// there patience beats a teardown.
pub const STANDSTILL_NORMAL: f64 = 6.0;
/// Quiet period after every seek command. While it runs, protection against real dropouts is
/// suspended.
pub const JUMP_IDLE: f64 = 20.0;
/// How fresh the last buffer growth must be for the guard to wait. A stream that buffers is
/// alive and must not be torn down.
pub const BUFFER_IDLE: f64 = 4.0;

/// What the guard advises. Four cases instead of a `bool`, so the log can say why it waits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Advice {
    /// Has not stood long enough yet.
    NotYet,
    /// A seek is in flight or was just commanded.
    JumpRunning,
    /// The buffer is growing, so the stream is alive.
    BufferGrows,
    /// Dropout. Rebuild the stream.
    NewConnect,
}

/// `StreamWatch.rat`.
///
/// - `standstill_since`: how long the picture has been frozen.
/// - `network_change_ago`: how long ago the last network change was, `None` if there was none.
/// - `jump_open`: whether a seek is in flight.
/// - `last_jump_ago`: how long ago the last seek command was.
/// - `buffer_grew_ago`: how long ago the buffer last grew.
pub fn advice(
    standstill_since: f64,
    network_change_ago: Option<f64>,
    jump_open: bool,
    last_jump_ago: f64,
    buffer_grew_ago: f64,
) -> Advice {
    let fresh = network_change_ago.is_some_and(|a| a < NETWORK_SWITCH_DEADLINE);
    let needed = if fresh {
        STANDSTILL_AFTER_SWITCH
    } else {
        STANDSTILL_NORMAL
    };
    if standstill_since < needed {
        return Advice::NotYet;
    }
    if jump_open || last_jump_ago < JUMP_IDLE {
        return Advice::JumpRunning;
    }
    if buffer_grew_ago < BUFFER_IDLE {
        return Advice::BufferGrows;
    }
    Advice::NewConnect
}

/// `StreamWatch.imagesState`: are the frames frozen while the clock runs? `None`: nothing to say,
/// either no previous value or this media has never shown a frame (a title without a video track
/// must not be rebuilt every few seconds).
pub fn images_state(before: Option<u64>, now: u64) -> Option<bool> {
    let before = before.filter(|b| *b > 0)?;
    Some(now == before)
}

/// `StreamWatch.growth`: new bytes since the last look. A new media counts from zero.
pub fn growth(now: u64, since: u64) -> u64 {
    now.saturating_sub(since)
}

// ----------------------------------------------------------------------------------------------
// StreamCheck: the mid-play stall check
// ----------------------------------------------------------------------------------------------

/// The position moved by more than this between two looks, so the clock runs
/// (`abs(now - streamLastPoint) > 0.05`).
pub const POSITION_MOVED: f64 = 0.05;
/// Audio loss that lasts this long counts as a broken output (`audioCheck`, seconds).
pub const AUDIO_LOSS_AFTER: f64 = 3.0;
/// The audio rebuild happens at most this often (seconds).
pub const AUDIO_REBUILD_EVERY: f64 = 30.0;
/// After a seek the audio check keeps quiet for this long (seconds).
pub const AUDIO_QUIET_AFTER_JUMP: f64 = 5.0;
/// A wake-up report within this many seconds of the last one does not count.
pub const WAKE_DEBOUNCE: f64 = 10.0;
/// A torn-down stream is rebuilt at most this often per title.
pub const MAX_TEARDOWNS: u32 = 3;
/// Within this many seconds of the end a torn-down stream is not rebuilt.
pub const END_MARGIN: f64 = 10.0;

/// Why the stream is rebuilt (the log line and the cause the host may tell).
#[derive(Debug, Clone, PartialEq)]
pub enum RebuildReason {
    /// The clock stands and nothing arrives (`Bild steht`).
    PictureStands,
    /// The clock runs but no new picture for this many seconds.
    NoNewPicture(u32),
    /// The audio output discards every block (the count of lost blocks).
    AudioDiscards(u64),
    /// The player stopped by itself mid-film; the attempt number.
    TornDown(u32),
    /// The machine woke up from sleep.
    WokeUp,
}

impl RebuildReason {
    /// The log wording of the desktop player (`[Strom] neu aufgebaut (...)`).
    pub fn log_text(&self) -> String {
        match self {
            Self::PictureStands => "Bild steht".to_owned(),
            Self::NoNewPicture(s) => format!("kein neues Bild seit {s} s, Uhr laeuft weiter"),
            Self::AudioDiscards(n) => format!("Tonausgabe verwirft seit 3 s alles, {n} Bloecke"),
            Self::TornDown(n) => format!("Strom abgerissen, Versuch {n}"),
            Self::WokeUp => "aufgewacht".to_owned(),
        }
    }
}

/// The order to rebuild the stream at the same position (`streamNewBuildUp`). The host reopens
/// the plan's URL at `position`, keeps controls, badge and tick running, re-applies the fill
/// choice and re-selects tracks (the track mapping starts anew for the new media).
#[derive(Debug, Clone, PartialEq)]
pub struct Rebuild {
    /// Resume here (seconds).
    pub position: f64,
    /// Open paused (used after wake-up while the film was paused).
    pub paused: bool,
    /// Why.
    pub reason: RebuildReason,
}

/// What the host reads from the player at each look (every second or so).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sample {
    /// The clock on the host side (seconds, any consistent clock).
    pub now: f64,
    /// The player's position (seconds).
    pub position: f64,
    /// The play state says it runs (not paused).
    pub running: bool,
    /// The start was reported (the first picture came).
    pub start_reported: bool,
    /// Whether the title is a local file (file URLs are never rebuilt).
    pub is_file: bool,
    /// A seek is in flight.
    pub jump_open: bool,
    /// Pictures shown so far for this media; `None` when the engine cannot tell.
    pub pictures_shown: Option<u64>,
    /// Bytes read so far for this media; `None` when the engine cannot tell.
    pub bytes_read: Option<u64>,
    /// Audio blocks lost so far; `None` when the engine cannot tell.
    pub audio_lost: Option<u64>,
}

/// The mid-play stall check: pure state, fed by [`StreamCheck::look`] once a second.
#[derive(Debug, Clone, PartialEq)]
pub struct StreamCheck {
    last_point: f64,
    stands_since: Option<f64>,
    last_pictures: Option<u64>,
    no_picture_since: Option<f64>,
    bytes_read: u64,
    buffer_grew: f64,
    last_jump: f64,
    audio_loss_since: Option<f64>,
    audio_lost_last: Option<u64>,
    audio_tried: f64,
    last_woke: f64,
    teardowns: u32,
}

impl Default for StreamCheck {
    fn default() -> Self {
        Self::new()
    }
}

impl StreamCheck {
    /// A fresh check for a new title.
    pub fn new() -> Self {
        Self {
            last_point: 0.0,
            stands_since: None,
            last_pictures: None,
            no_picture_since: None,
            bytes_read: 0,
            buffer_grew: f64::NEG_INFINITY,
            last_jump: f64::NEG_INFINITY,
            audio_loss_since: None,
            audio_lost_last: None,
            audio_tried: f64::NEG_INFINITY,
            last_woke: f64::NEG_INFINITY,
            teardowns: 0,
        }
    }

    /// A seek command was sent at `now` (opens the quiet period).
    pub fn jumped(&mut self, now: f64) {
        self.last_jump = now;
    }

    /// How often a torn-down stream was rebuilt for this title.
    pub fn teardowns(&self) -> u32 {
        self.teardowns
    }

    fn note_bytes(&mut self, now: f64, read: Option<u64>) {
        if let Some(read) = read
            && read > self.bytes_read
        {
            self.bytes_read = read;
            self.buffer_grew = now;
        }
    }

    /// The counters belong to the media; a rebuilt stream starts from zero.
    fn forget_media(&mut self) {
        self.stands_since = None;
        self.last_pictures = None;
        self.no_picture_since = None;
        self.audio_loss_since = None;
        self.audio_lost_last = None;
        self.bytes_read = 0;
    }

    fn rebuild(&mut self, position: f64, paused: bool, reason: RebuildReason) -> Rebuild {
        self.forget_media();
        Rebuild {
            position,
            paused,
            reason,
        }
    }

    /// One look. Returns the order to rebuild, if the picture is stuck or the audio output is
    /// dead (`streamCheck` then `audioCheck`).
    pub fn look(&mut self, s: &Sample) -> Option<Rebuild> {
        if let Some(r) = self.look_stream(s) {
            return Some(r);
        }
        self.look_audio(s)
    }

    fn look_stream(&mut self, s: &Sample) -> Option<Rebuild> {
        if s.is_file || !s.running || !s.start_reported {
            self.stands_since = None;
            return None;
        }
        if (s.position - self.last_point).abs() > POSITION_MOVED {
            self.last_point = s.position;
            self.stands_since = None;
            // The clock runs, but does a picture come? A stream whose clock keeps running used
            // to count as healthy forever while the picture stood.
            let before = self.last_pictures;
            if let Some(shown) = s.pictures_shown {
                self.last_pictures = Some(shown);
            }
            let Some(shown) = s.pictures_shown else {
                self.no_picture_since = None;
                return None;
            };
            if images_state(before, shown) != Some(true) {
                self.no_picture_since = None;
                return None;
            }
            let since = *self.no_picture_since.get_or_insert(s.now);
            self.note_bytes(s.now, s.bytes_read);
            let duration = s.now - since;
            if advice(
                duration,
                None,
                s.jump_open,
                s.now - self.last_jump,
                s.now - self.buffer_grew,
            ) == Advice::NewConnect
            {
                let secs = duration.max(0.0) as u32;
                return Some(self.rebuild(s.position, false, RebuildReason::NoNewPicture(secs)));
            }
            return None;
        }
        // A growing buffer means the stream is alive; then the server is just slow.
        self.note_bytes(s.now, s.bytes_read);
        let since = *self.stands_since.get_or_insert(s.now);
        let rat = advice(
            s.now - since,
            None,
            s.jump_open,
            s.now - self.last_jump,
            s.now - self.buffer_grew,
        );
        (rat == Advice::NewConnect)
            .then(|| self.rebuild(s.position, false, RebuildReason::PictureStands))
    }

    /// `audioCheck`: three seconds of uninterrupted loss, at most every 30 s, quiet for five
    /// seconds after a seek.
    fn look_audio(&mut self, s: &Sample) -> Option<Rebuild> {
        let lost = match s.audio_lost {
            Some(lost)
                if !s.is_file
                    && s.running
                    && s.start_reported
                    && s.now - self.last_jump > AUDIO_QUIET_AFTER_JUMP =>
            {
                lost
            }
            _ => {
                self.audio_loss_since = None;
                self.audio_lost_last = None;
                return None;
            }
        };
        let before = self.audio_lost_last.replace(lost);
        match before {
            Some(b) if lost > b => {}
            _ => {
                self.audio_loss_since = None;
                return None;
            }
        }
        let since = *self.audio_loss_since.get_or_insert(s.now);
        if s.now - since < AUDIO_LOSS_AFTER || s.now - self.audio_tried <= AUDIO_REBUILD_EVERY {
            return None;
        }
        self.audio_tried = s.now;
        Some(self.rebuild(s.position, false, RebuildReason::AudioDiscards(lost)))
    }

    /// `streamTornDown`: the player stopped mid-film without anyone closing. Rebuilds only when
    /// the title was not at the end (more than ten seconds before it), at most three times per
    /// title. `error` before the first picture is a failed start and returns `None` here (the
    /// caller shows its failure text).
    pub fn torn_down(
        &mut self,
        position: f64,
        duration: f64,
        pictures_ever: bool,
    ) -> Option<Rebuild> {
        if position <= 1.0 || !pictures_ever {
            return None;
        }
        if duration <= 0.0 || position >= duration - END_MARGIN || self.teardowns >= MAX_TEARDOWNS {
            return None;
        }
        self.teardowns += 1;
        let attempt = self.teardowns;
        Some(self.rebuild(position, false, RebuildReason::TornDown(attempt)))
    }

    /// `woke`: the machine woke from sleep. Rebuilds stream and audio output at the same
    /// position, paused if it was paused. A second report within ten seconds does not count
    /// (Windows often reports twice).
    pub fn woke(&mut self, now: f64, position: f64, was_running: bool) -> Option<Rebuild> {
        if now - self.last_woke <= WAKE_DEBOUNCE {
            return None;
        }
        self.last_woke = now;
        Some(self.rebuild(position, !was_running, RebuildReason::WokeUp))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rat(
        standstill: f64,
        change: Option<f64>,
        jump_open: bool,
        jump: f64,
        buffer: f64,
    ) -> Advice {
        advice(standstill, change, jump_open, jump, buffer)
    }
    fn plain(standstill: f64) -> Advice {
        rat(standstill, None, false, 999.0, 999.0)
    }

    #[test]
    fn six_seconds_without_a_network_change() {
        assert_eq!(plain(5.9), Advice::NotYet);
        assert_eq!(plain(6.0), Advice::NewConnect);
    }

    #[test]
    fn after_a_network_change_only_two() {
        assert_eq!(rat(1.9, Some(3.0), false, 999.0, 999.0), Advice::NotYet);
        assert_eq!(rat(2.0, Some(3.0), false, 999.0, 999.0), Advice::NewConnect);
    }

    #[test]
    fn an_old_network_change_explains_nothing() {
        assert_eq!(rat(3.0, Some(91.0), false, 999.0, 999.0), Advice::NotYet);
        assert_eq!(
            rat(3.0, Some(89.0), false, 999.0, 999.0),
            Advice::NewConnect
        );
    }

    #[test]
    fn an_open_jump_is_no_teardown() {
        assert_eq!(rat(30.0, None, true, 999.0, 999.0), Advice::JumpRunning);
    }

    #[test]
    fn twenty_seconds_after_the_command_neither() {
        assert_eq!(rat(30.0, None, false, 19.9, 999.0), Advice::JumpRunning);
        assert_eq!(rat(30.0, None, false, 20.0, 999.0), Advice::NewConnect);
    }

    #[test]
    fn a_growing_buffer_beats_the_teardown() {
        assert_eq!(rat(60.0, None, false, 999.0, 3.9), Advice::BufferGrows);
        assert_eq!(rat(60.0, None, false, 999.0, 4.0), Advice::NewConnect);
    }

    #[test]
    fn the_jump_beats_the_buffer() {
        assert_eq!(rat(60.0, None, false, 1.0, 1.0), Advice::JumpRunning);
    }

    #[test]
    fn without_standstill_nothing_happens() {
        assert_eq!(plain(0.0), Advice::NotYet);
        assert_eq!(rat(0.0, Some(1.0), false, 999.0, 999.0), Advice::NotYet);
    }

    #[test]
    fn without_a_picture_ever_there_is_no_picture_standstill() {
        assert_eq!(images_state(None, 0), None);
        assert_eq!(images_state(Some(0), 0), None);
        assert_eq!(images_state(Some(120), 120), Some(true));
        assert_eq!(images_state(Some(120), 121), Some(false));
    }

    #[test]
    fn byte_growth_never_runs_below_zero() {
        assert_eq!(growth(500, 200), 300);
        assert_eq!(growth(100, 90_000), 0);
    }

    // ---- StreamCheck ----

    fn sample(now: f64, position: f64) -> Sample {
        Sample {
            now,
            position,
            running: true,
            start_reported: true,
            is_file: false,
            jump_open: false,
            pictures_shown: Some(100),
            bytes_read: Some(1000),
            audio_lost: None,
        }
    }

    #[test]
    fn a_stuck_clock_with_a_dead_buffer_rebuilds_after_six_seconds() {
        let mut c = StreamCheck::new();
        c.look(&sample(100.0, 50.0));
        for t in 101..=105 {
            assert_eq!(c.look(&sample(f64::from(t), 50.0)), None, "t={t}");
        }
        // First look at 101 started the standstill; 107 is six seconds on.
        assert_eq!(c.look(&sample(106.0, 50.0)), None);
        let r = c.look(&sample(107.0, 50.0)).expect("rebuild");
        assert_eq!(r.reason, RebuildReason::PictureStands);
        assert_eq!(r.position, 50.0);
        assert!(!r.paused);
    }

    #[test]
    fn a_growing_buffer_keeps_a_stalled_stream_alive() {
        let mut c = StreamCheck::new();
        c.look(&sample(100.0, 50.0));
        for t in 101..=140 {
            let mut s = sample(f64::from(t), 50.0);
            s.bytes_read = Some(1000 + u64::from(t as u32) * 10);
            assert_eq!(c.look(&s), None, "t={t}");
        }
    }

    #[test]
    fn a_seek_in_flight_and_its_quiet_period_hold_the_brake() {
        let mut c = StreamCheck::new();
        c.look(&sample(100.0, 50.0));
        c.jumped(101.0);
        for t in 101..=120 {
            assert_eq!(c.look(&sample(f64::from(t), 50.0)), None, "t={t}");
        }
        assert!(c.look(&sample(121.5, 50.0)).is_some());
    }

    #[test]
    fn a_running_clock_without_new_pictures_is_a_dropout_too() {
        let mut c = StreamCheck::new();
        let mut out = None;
        for t in 0..20 {
            let mut s = sample(100.0 + f64::from(t), 50.0 + f64::from(t));
            s.pictures_shown = Some(500);
            if let Some(r) = c.look(&s) {
                out = Some((t, r));
                break;
            }
        }
        let (t, r) = out.expect("rebuild");
        assert!(matches!(r.reason, RebuildReason::NoNewPicture(_)));
        assert!(t >= 6);
    }

    #[test]
    fn a_title_without_pictures_is_never_rebuilt() {
        let mut c = StreamCheck::new();
        for t in 0..60 {
            let mut s = sample(100.0 + f64::from(t), 50.0 + f64::from(t));
            s.pictures_shown = Some(0);
            assert_eq!(c.look(&s), None);
        }
    }

    #[test]
    fn local_files_and_paused_playback_are_left_alone() {
        let mut c = StreamCheck::new();
        for t in 0..30 {
            let mut s = sample(f64::from(t), 50.0);
            s.is_file = true;
            assert_eq!(c.look(&s), None);
            let mut s = sample(f64::from(t), 50.0);
            s.running = false;
            assert_eq!(c.look(&s), None);
        }
    }

    #[test]
    fn dead_audio_output_rebuilds_after_three_seconds_and_at_most_every_thirty() {
        let mut c = StreamCheck::new();
        let mut rebuilds = Vec::new();
        for t in 0..80 {
            let mut s = sample(100.0 + f64::from(t), 50.0 + f64::from(t));
            s.pictures_shown = Some(1000 + t as u64);
            s.audio_lost = Some(10 * t as u64);
            if let Some(r) = c.look(&s) {
                rebuilds.push((t, r));
            }
        }
        assert!(matches!(
            rebuilds[0].1.reason,
            RebuildReason::AudioDiscards(_)
        ));
        assert_eq!(rebuilds[0].0, 4);
        assert!(rebuilds.len() >= 2);
        assert!(rebuilds[1].0 - rebuilds[0].0 > 30);
    }

    #[test]
    fn a_torn_down_stream_is_rebuilt_three_times_and_not_near_the_end() {
        let mut c = StreamCheck::new();
        assert_eq!(c.torn_down(0.5, 3600.0, true), None);
        assert_eq!(c.torn_down(500.0, 3600.0, false), None);
        assert_eq!(c.torn_down(3595.0, 3600.0, true), None);
        for attempt in 1..=3 {
            let r = c.torn_down(500.0, 3600.0, true).expect("rebuild");
            assert_eq!(r.reason, RebuildReason::TornDown(attempt));
        }
        assert_eq!(c.torn_down(500.0, 3600.0, true), None);
    }

    #[test]
    fn waking_rebuilds_once_and_keeps_a_pause() {
        let mut c = StreamCheck::new();
        let r = c.woke(1000.0, 321.0, false).expect("rebuild");
        assert_eq!(r.reason, RebuildReason::WokeUp);
        assert!(r.paused);
        assert_eq!(r.position, 321.0);
        // The second report within ten seconds does not count.
        assert_eq!(c.woke(1009.0, 321.0, true), None);
        let again = c.woke(1011.0, 330.0, true).expect("rebuild");
        assert!(!again.paused);
    }
}
