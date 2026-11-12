//! Port of PlaybackTick.swift.
//!
//! One tick of playback observation: the rules both players need. The state stays with the
//! view; this module only computes. It receives the state, changes it and returns what is to
//! be done afterwards ([`WorkItem`]).
//!
//! Time values (`since_start`, `now`, [`Jump::since`]) are `f64` seconds on one consistent
//! clock instead of Swift's `Date`. The Swift `@MainActor` isolation has no counterpart; all
//! functions are plain and the state is passed in.

use std::time::Duration;

use crate::time_assumption;

/// Every half second. Nobody needs finer: the display shows seconds.
pub const TICK_LENGTH: Duration = Duration::from_millis(500);
/// How often the server learns the progress (seconds).
pub const REPORT_SPACING: f64 = 10.0;
/// The longest the display stays on a target VLC never reaches (seconds).
pub const JUMP_CEILING: f64 = 8.0;
/// How often the display follows VLC's time when the platform does so between two ticks.
pub const DISPLAY_TICK: Duration = Duration::from_millis(250);

/// The target of a jump, until VLC is there.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Jump {
    /// Target position, seconds.
    pub target: f64,
    /// When the jump was made.
    pub since: f64,
}

/// What the view shows and the tick updates.
#[derive(Debug, Clone, PartialEq)]
pub struct Snapshot {
    /// Displayed position, seconds.
    pub position: f64,
    /// Duration, seconds.
    pub duration: f64,
    /// Is it playing?
    pub running: bool,
    /// The first picture has been shown.
    pub first_image_present: bool,
    /// Tracks have been applied.
    pub tracks_set: bool,
    /// The server has been told once that playback started.
    pub start_reported: bool,
    /// Seconds since the last progress report.
    pub since_message: f64,
    /// The title arrived through an episode switch in the running player.
    pub after_change: bool,
    /// A jump VLC has not reached yet: until then the display shows the target.
    pub leap: Option<Jump>,
}

impl Default for Snapshot {
    /// The Swift defaults: `running` is true, everything else zero/false.
    fn default() -> Self {
        Self {
            position: 0.0,
            duration: 0.0,
            running: true,
            first_image_present: false,
            tracks_set: false,
            start_reported: false,
            since_message: 0.0,
            after_change: false,
            leap: None,
        }
    }
}

/// What is to be done after this tick. The view decides how.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WorkItem {
    /// Remove the loading screen.
    pub loading_screen_gone: bool,
    /// Apply the tracks.
    pub tracks_apply: bool,
    /// Report the start to the server.
    pub start_report: bool,
    /// Report the progress to the server.
    pub progress_report: bool,
}

/// What the drawing surface says in this tick.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Reading {
    /// Duration, seconds.
    pub duration: f64,
    /// VLC's position, seconds.
    pub position: f64,
    /// The last good position (used while restoring).
    pub good_point: f64,
    /// A picture is showing.
    pub shows_image: bool,
    /// VLC is still homing in on the start position.
    pub seeks_to_start: bool,
    /// Playing (not paused).
    pub running: bool,
    /// VLC knows audio tracks.
    pub has_audio_tracks: bool,
}

/// Jumped: the display stands on the target from now on. Limited to the duration once it is
/// known. (`PlaybackTick.swift:81-87`)
pub fn jumped(state: &mut Snapshot, target: f64, now: f64) {
    let mut spot = target.max(0.0);
    if state.duration > 0.0 {
        spot = spot.min(state.duration);
    }
    state.position = spot;
    state.leap = Some(Jump {
        target: spot,
        since: now,
    });
}

/// Where a jump **by** `seconds` leads: from the target of a jump still in progress,
/// otherwise from the displayed position (`target(um:state:)`).
pub fn target_by(seconds: f64, state: &Snapshot) -> f64 {
    state.leap.map_or(state.position, |l| l.target) + seconds
}

/// A new title runs in the same loop. (`PlaybackTick.swift:158-170`)
pub fn new_title(state: &mut Snapshot, start_reported: bool) {
    state.position = 0.0;
    // The picture too: the loading screen comes back.
    state.first_image_present = false;
    state.tracks_set = false;
    state.start_reported = start_reported;
    state.since_message = 0.0;
    state.after_change = true;
    state.leap = None;
}

/// The display shows VLC's time, exactly that, nothing extrapolated; the only exception is
/// after a jump (the target, until VLC is within `JUMP_ARRIVED` of it or `JUMP_CEILING`
/// passed). (`PlaybackTick.swift:190-212`)
pub fn time_adopt(state: &mut Snapshot, reported: f64, at_push: bool, since_start: f64, now: f64) {
    if at_push {
        return;
    }
    if let Some(leap) = state.leap {
        let arrived = (reported - leap.target).abs() < time_assumption::JUMP_ARRIVED;
        if arrived || now - leap.since >= JUMP_CEILING {
            state.leap = None;
            state.position = reported;
        } else {
            state.position = leap.target;
        }
        return;
    }
    // Before the first picture, adopt no time at all.
    if !state.first_image_present {
        return;
    }
    if let Some(adopted) = time_assumption::position(
        reported,
        state.position,
        since_start,
        state.after_change,
        now,
    ) {
        state.position = adopted;
        state.after_change = false;
    }
}

/// One tick. `restoring`: a rebuild after a network change is in progress, then the last
/// good position applies. `at_push`: the finger is on the slider. (`PlaybackTick.swift:233-278`)
pub fn compute(
    state: &mut Snapshot,
    measurement: &Reading,
    restoring: bool,
    at_push: bool,
    since_start: f64,
    now: f64,
) -> WorkItem {
    let mut job = WorkItem::default();

    state.duration = measurement.duration;

    // The loading screen may go.
    if !state.first_image_present
        && time_assumption::image_present(
            measurement.shows_image,
            measurement.seeks_to_start,
            since_start,
            now,
        )
    {
        state.first_image_present = true;
        job.loading_screen_gone = true;
    }

    // The time: VLC's, except right after a jump.
    time_adopt(
        state,
        if restoring {
            measurement.good_point
        } else {
            measurement.position
        },
        at_push,
        since_start,
        now,
    );

    // Tracks only once VLC knows them; before that the lists are empty.
    if !state.tracks_set && state.first_image_present && measurement.has_audio_tracks {
        state.tracks_set = true;
        job.tracks_apply = true;
        // After an episode switch the start has already gone out without track indices; the
        // next report carries them and comes right away.
        if state.start_reported {
            state.since_message = REPORT_SPACING;
        }
    }

    if state.first_image_present {
        state.running = measurement.running;
    }

    // From here on it is only about the server.
    if !(state.first_image_present && state.duration > 0.0) {
        return job;
    }

    // Report only once a picture is actually showing.
    if !state.start_reported {
        state.start_reported = true;
        job.start_report = true;
        return job;
    }

    state.since_message += TICK_LENGTH.as_secs_f64();
    if state.since_message >= REPORT_SPACING {
        state.since_message = 0.0;
        job.progress_report = true;
    }
    job
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time_assumption::image_belongs_medium;

    const NOW: f64 = 1_000_000.0;

    fn measurement(position: f64) -> Reading {
        Reading {
            duration: 3600.0,
            position,
            good_point: 0.0,
            shows_image: true,
            seeks_to_start: false,
            running: true,
            has_audio_tracks: true,
        }
    }

    /// Swift test helper `tick(...)` with its defaults (`sinceStart` and `now` are "now").
    fn tick(state: &mut Snapshot, m: &Reading) -> WorkItem {
        compute(state, m, false, false, NOW, NOW)
    }

    fn tick_at(state: &mut Snapshot, m: &Reading, since_start: f64, now: f64) -> WorkItem {
        compute(state, m, false, false, since_start, now)
    }

    /// A running title, one minute after opening.
    fn ongoing(spot: f64) -> (Snapshot, f64) {
        let mut s = Snapshot::default();
        let start = NOW - 60.0;
        tick_at(&mut s, &measurement(spot), start, NOW);
        (s, start)
    }

    fn running_state(position: f64) -> Snapshot {
        Snapshot {
            position,
            first_image_present: true,
            tracks_set: true,
            start_reported: true,
            ..Snapshot::default()
        }
    }

    // Swift: jumpImmediate
    #[test]
    fn jump_immediate() {
        let (mut s, _) = ongoing(300.0);
        let t = target_by(30.0, &s);
        jumped(&mut s, t, NOW);
        assert_eq!(s.position, 330.0);
    }

    // Swift: jumpHolds
    #[test]
    fn jump_holds() {
        let (mut s, start) = ongoing(300.0);
        jumped(&mut s, 330.0, NOW);
        for i in 1..=8 {
            tick_at(
                &mut s,
                &measurement(300.0 + f64::from(i) * 0.5),
                start,
                NOW + f64::from(i) * 0.5,
            );
            assert_eq!(s.position, 330.0);
        }
    }

    // Swift: jumpHandoff
    #[test]
    fn jump_handoff() {
        let (mut s, start) = ongoing(300.0);
        jumped(&mut s, 330.0, NOW);
        tick_at(&mut s, &measurement(329.0), start, NOW + 0.5);
        assert_eq!(s.position, 329.0);
        assert!(s.leap.is_none());
        tick_at(&mut s, &measurement(329.5), start, NOW + 1.0);
        assert_eq!(s.position, 329.5);
    }

    // Swift: timeEpisode
    #[test]
    fn time_episode() {
        let (mut s, start) = ongoing(100.0);
        let now = std::cell::Cell::new(NOW);
        let step = |s: &mut Snapshot, vlc: f64| {
            now.set(now.get() + 0.25);
            time_adopt(s, vlc, false, start, now.get());
            s.position
        };
        // Playing: every report appears as it arrives.
        let play = [100.0, 100.25, 100.5, 100.75, 101.0, 101.25];
        let got: Vec<f64> = play.iter().map(|v| step(&mut s, *v)).collect();
        assert_eq!(got, play);
        // Jump forward: the target while VLC still has the old time, then VLC.
        jumped(&mut s, 131.25, now.get());
        let post: Vec<f64> = [101.25, 101.25, 130.9, 131.1, 131.35, 131.6]
            .iter()
            .map(|v| step(&mut s, *v))
            .collect();
        assert_eq!(post, [131.25, 131.25, 130.9, 131.1, 131.35, 131.6]);
        // Pause: VLC stands still, and so does the display.
        let pause: Vec<f64> = [131.7, 131.7, 131.7, 131.7]
            .iter()
            .map(|v| step(&mut s, *v))
            .collect();
        assert_eq!(pause, [131.7, 131.7, 131.7, 131.7]);
    }

    // Swift: jumpSeries
    #[test]
    fn jump_series() {
        let (mut s, start) = ongoing(300.0);
        let t = target_by(30.0, &s);
        jumped(&mut s, t, NOW);
        tick_at(&mut s, &measurement(300.5), start, NOW + 0.5);
        let t = target_by(30.0, &s);
        jumped(&mut s, t, NOW);
        assert_eq!(s.position, 360.0);
    }

    // Swift: jumpPostSkip
    #[test]
    fn jump_post_skip() {
        let (mut s, start) = ongoing(60.0);
        jumped(&mut s, 551.0, NOW);
        // VLC still reports the old position, then right away the second jump.
        tick_at(&mut s, &measurement(60.2), start, NOW + 0.25);
        let t = target_by(30.0, &s);
        jumped(&mut s, t, NOW + 0.3);
        assert_eq!(s.position, 581.0);
        tick_at(&mut s, &measurement(60.4), start, NOW + 0.5);
        assert_eq!(s.position, 581.0, "not back to the target of the skip");
        tick_at(&mut s, &measurement(551.1), start, NOW + 0.75);
        assert_eq!(s.position, 581.0, "not even when VLC passes there briefly");
        tick_at(&mut s, &measurement(580.6), start, NOW + 1.0);
        assert_eq!(s.position, 580.6);
        assert!(s.leap.is_none());
    }

    // Swift: jumpCap
    #[test]
    fn jump_cap() {
        let (mut s, start) = ongoing(300.0);
        jumped(&mut s, 900.0, NOW);
        tick_at(&mut s, &measurement(305.0), start, NOW + JUMP_CEILING - 0.5);
        assert_eq!(s.position, 900.0);
        tick_at(&mut s, &measurement(306.0), start, NOW + JUMP_CEILING);
        assert_eq!(s.position, 306.0);
    }

    // Swift: jumpLimits
    #[test]
    fn jump_limits() {
        let (mut s, _) = ongoing(3590.0);
        jumped(&mut s, 3620.0, NOW);
        assert_eq!(s.position, 3600.0);
        jumped(&mut s, -10.0, NOW);
        assert_eq!(s.position, 0.0);
    }

    // Swift: jumpSwitch
    #[test]
    fn jump_switch() {
        let (mut s, _) = ongoing(300.0);
        jumped(&mut s, 330.0, NOW);
        new_title(&mut s, true);
        assert!(s.leap.is_none());
    }

    // Swift: seeksToStart
    #[test]
    fn seeks_to_start() {
        let mut s = Snapshot::default();
        let m = Reading {
            seeks_to_start: true,
            ..measurement(900.0)
        };
        let a = tick(&mut s, &m);
        assert!(!s.first_image_present);
        assert_eq!(s.position, 0.0);
        assert!(!a.start_report);
    }

    // Swift: firstImage
    #[test]
    fn first_image() {
        let mut s = Snapshot::default();
        let a = tick(&mut s, &measurement(900.0));
        assert!(a.loading_screen_gone);
        assert!(s.first_image_present);
        assert!(a.tracks_apply);
        assert!(a.start_report);
    }

    // Swift: onlyInTimes
    #[test]
    fn only_in_times() {
        let mut s = Snapshot::default();
        tick(&mut s, &measurement(900.0));
        let second = tick(&mut s, &measurement(901.0));
        assert!(!second.start_report);
        assert!(!second.tracks_apply);
    }

    // Swift: reportSpacing
    #[test]
    fn report_spacing() {
        let mut s = running_state(0.0);
        let mut messages = 0;
        for i in 1..=40 {
            if tick(&mut s, &measurement(f64::from(i))).progress_report {
                messages += 1;
            }
        }
        assert_eq!(messages, 2);
    }

    // Swift: atSlider
    #[test]
    fn at_slider() {
        let mut s = running_state(1200.0);
        compute(&mut s, &measurement(30.0), false, true, NOW, NOW);
        assert_eq!(s.position, 1200.0);
    }

    // Swift: againLayout
    #[test]
    fn again_layout() {
        let mut s = running_state(1200.0);
        let m = Reading {
            good_point: 1210.0,
            ..measurement(3599.0)
        };
        compute(&mut s, &m, true, false, NOW, NOW);
        assert_eq!(s.position, 1210.0);
    }

    // Swift: buildTwitch
    #[test]
    fn build_twitch() {
        let mut s = running_state(1200.0);
        tick(&mut s, &measurement(3.0));
        assert_eq!(s.position, 1200.0);
    }

    // Swift: switchLoopReport
    #[test]
    fn switch_loop_report() {
        let mut s = Snapshot {
            since_message: 4.0,
            ..running_state(1200.0)
        };
        new_title(&mut s, false);
        assert_eq!(s.position, 0.0);
        // The loading screen comes back.
        assert!(!s.first_image_present);
        assert!(!s.tracks_set);
        assert_eq!(s.since_message, 0.0);
        assert!(tick(&mut s, &measurement(2.0)).start_report);
    }

    // Swift: switchReportSelf
    #[test]
    fn switch_report_self() {
        let mut s = running_state(1200.0);
        new_title(&mut s, true);
        assert!(!tick(&mut s, &measurement(2.0)).start_report);
    }

    // Swift: switchOldClock
    #[test]
    fn switch_old_clock() {
        let mut s = Snapshot {
            since_message: 6.0,
            ..running_state(75.0)
        };
        new_title(&mut s, true);
        let since_start = NOW;
        // VLC: old clock, old video output, no picture yet from the new media.
        let old = image_belongs_medium(true, 0, true);
        assert!(!old);
        for _ in 0..8 {
            let m = Reading {
                shows_image: old,
                ..measurement(75.4)
            };
            let a = tick_at(&mut s, &m, since_start, NOW);
            assert!(!a.progress_report);
            assert!(!a.loading_screen_gone);
        }
        assert_eq!(s.position, 0.0);
        // First frame of the new episode: its time counts immediately.
        let new = image_belongs_medium(true, 3, true);
        let m = Reading {
            shows_image: new,
            ..measurement(2.0)
        };
        tick_at(&mut s, &m, since_start, NOW);
        assert_eq!(s.position, 2.0);
    }

    // Swift: switchNonsenseTime
    #[test]
    fn switch_nonsense_time() {
        let mut s = running_state(75.0);
        new_title(&mut s, true);
        let since_start = NOW - 2.0;
        let a = tick_at(&mut s, &measurement(6130.0), since_start, NOW);
        assert_eq!(s.position, 0.0);
        assert!(a.progress_report); // report tracks again, with 0, not 6130
        tick_at(&mut s, &measurement(76.0), since_start, NOW);
        assert_eq!(s.position, 0.0);
        tick_at(&mut s, &measurement(2.5), since_start, NOW);
        assert_eq!(s.position, 2.5);
        // Once arrived, every jump counts again.
        tick_at(&mut s, &measurement(900.0), since_start, NOW);
        assert_eq!(s.position, 900.0);
    }

    // Swift: openWithoutSwitchLock
    #[test]
    fn open_without_switch_lock() {
        let mut s = Snapshot {
            position: 1200.0,
            ..Snapshot::default()
        };
        tick(&mut s, &measurement(1201.0));
        assert_eq!(s.position, 1201.0);
    }

    // Swift: firstOpenImageOutput
    #[test]
    fn first_open_image_output() {
        assert!(image_belongs_medium(true, 0, false));
        assert!(!image_belongs_medium(false, 9, true));
    }

    // Swift: switchTracksImmediate
    #[test]
    fn switch_tracks_immediate() {
        let mut s = running_state(75.0);
        new_title(&mut s, true);
        let a = tick(&mut s, &measurement(1.0));
        assert!(a.tracks_apply);
        assert!(a.progress_report);
        assert!(!a.start_report);
        // After that, at the usual interval again.
        let b = tick(&mut s, &measurement(1.5));
        assert!(!b.progress_report);
    }

    // Swift: openNoExtraProgress
    #[test]
    fn open_no_extra_progress() {
        let mut s = Snapshot::default();
        let a = tick(&mut s, &measurement(1.0));
        assert!(a.start_report);
        assert!(!a.progress_report);
        assert!(!tick(&mut s, &measurement(1.5)).progress_report);
    }
}
