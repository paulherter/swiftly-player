//! The real back end of [`SystemMedia`]: Windows SMTC (volume flyout, lock screen, headset keys) and Linux MPRIS
//! (desktop media widgets, `playerctl`, keyboard media keys) through `souvlaki`. Elsewhere there is no back end and
//! [`OsMedia::open`] answers `None`.
//!
//! The system calls this thread's callbacks from another thread: they only queue a [`MediaEvent`] and ask the window
//! to wake (`wake`), the app drains them on its own thread in [`SystemMedia::poll_events`].

use crate::media_keys::{MediaEvent, Metadata, PlaybackState, SystemMedia};

#[cfg(any(
    windows,
    all(
        unix,
        not(any(target_os = "macos", target_os = "ios", target_os = "android"))
    )
))]
mod real {
    use super::*;
    use souvlaki::{
        MediaControlEvent, MediaControls, MediaMetadata, MediaPlayback, MediaPosition,
        PlatformConfig, SeekDirection,
    };
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    /// The system controls of this process.
    pub struct OsMedia {
        controls: MediaControls,
        queue: Arc<Mutex<Vec<MediaEvent>>>,
        /// The last card, to resend it with the position (`set_playback` does not keep the metadata on every platform).
        shown: bool,
    }

    /// The event the system sent, as the app's own; the ones the player has no use for (volume, raise) are dropped.
    pub fn event_of(e: &MediaControlEvent) -> Option<MediaEvent> {
        Some(match e {
            MediaControlEvent::Play => MediaEvent::Play,
            MediaControlEvent::Pause => MediaEvent::Pause,
            MediaControlEvent::Toggle => MediaEvent::Toggle,
            MediaControlEvent::Next => MediaEvent::Next,
            MediaControlEvent::Previous => MediaEvent::Previous,
            MediaControlEvent::Stop => MediaEvent::Stop,
            MediaControlEvent::Seek(d) | MediaControlEvent::SeekBy(d, _) => {
                MediaEvent::Skip(*d == SeekDirection::Forward)
            }
            MediaControlEvent::SetPosition(MediaPosition(p)) => MediaEvent::SeekTo(p.as_secs_f64()),
            MediaControlEvent::SetRate(r) => MediaEvent::SetRate(*r),
            _ => return None,
        })
    }

    impl OsMedia {
        /// Registers with the system. `hwnd` is the window handle on Windows (ignored on Linux). `wake` is called from the
        /// system's thread whenever a button was pressed. `None` when the system refuses (no session bus, no SMTC).
        pub fn open(
            hwnd: Option<*mut std::ffi::c_void>,
            wake: impl Fn() + Send + 'static,
        ) -> Option<OsMedia> {
            let mut controls = MediaControls::new(PlatformConfig {
                dbus_name: "de.swiftly.player",
                display_name: "Swiftly",
                hwnd,
            })
            .ok()?;
            let queue: Arc<Mutex<Vec<MediaEvent>>> = Arc::default();
            let q = Arc::clone(&queue);
            controls
                .attach(move |e| {
                    if let Some(e) = event_of(&e) {
                        if let Ok(mut g) = q.lock() {
                            g.push(e);
                        }
                        wake();
                    }
                })
                .ok()?;
            // The speeds the player offers (MPRIS `MinimumRate`/`MaximumRate`).
            let (lo, hi) = crate::media_keys::tempo_range();
            let _ = controls.set_rate_range(lo, hi);
            Some(OsMedia {
                controls,
                queue,
                shown: false,
            })
        }
    }

    impl SystemMedia for OsMedia {
        fn set_metadata(&mut self, meta: &Metadata) {
            let track = crate::media_keys::track_path(&meta.item_id);
            let _ = self.controls.set_metadata(MediaMetadata {
                track_id: Some(&track),
                title: Some(&meta.title),
                album: meta.album.as_deref(),
                artist: meta.artist.as_deref(),
                cover_url: meta.cover_url.as_deref(),
                duration: meta
                    .duration_s
                    .filter(|d| d.is_finite() && *d > 0.0)
                    .map(Duration::from_secs_f64),
            });
            self.shown = true;
        }
        fn set_playback(&mut self, state: PlaybackState, position_s: f64) {
            let progress = Some(MediaPosition(Duration::from_secs_f64(position_s.max(0.0))));
            let _ = self.controls.set_playback(match state {
                PlaybackState::Stopped => MediaPlayback::Stopped,
                PlaybackState::Paused => MediaPlayback::Paused { progress },
                PlaybackState::Playing => MediaPlayback::Playing { progress },
            });
        }
        fn set_rate(&mut self, rate: f64) {
            let _ = self.controls.set_rate(rate);
        }
        fn set_navigation(&mut self, next: bool, previous: bool) {
            let _ = self.controls.set_navigation(next, previous);
        }
        fn clear(&mut self) {
            let _ = self.controls.set_playback(MediaPlayback::Stopped);
            let _ = self.controls.set_metadata(MediaMetadata::default());
            self.shown = false;
        }
        fn poll_events(&mut self) -> Vec<MediaEvent> {
            self.queue
                .lock()
                .map(|mut g| std::mem::take(&mut *g))
                .unwrap_or_default()
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn system_events_map_to_the_apps() {
            let ms = |s| Duration::from_secs(s);
            assert_eq!(
                event_of(&MediaControlEvent::Toggle),
                Some(MediaEvent::Toggle)
            );
            assert_eq!(event_of(&MediaControlEvent::Next), Some(MediaEvent::Next));
            assert_eq!(
                event_of(&MediaControlEvent::Seek(SeekDirection::Backward)),
                Some(MediaEvent::Skip(false))
            );
            assert_eq!(
                event_of(&MediaControlEvent::SeekBy(SeekDirection::Forward, ms(10))),
                Some(MediaEvent::Skip(true))
            );
            assert_eq!(
                event_of(&MediaControlEvent::SetPosition(MediaPosition(ms(90)))),
                Some(MediaEvent::SeekTo(90.0))
            );
            assert_eq!(
                event_of(&MediaControlEvent::SetRate(1.5)),
                Some(MediaEvent::SetRate(1.5))
            );
            assert_eq!(event_of(&MediaControlEvent::SetVolume(0.5)), None);
            assert_eq!(event_of(&MediaControlEvent::Raise), None);
        }
    }
}

#[cfg(any(
    windows,
    all(
        unix,
        not(any(target_os = "macos", target_os = "ios", target_os = "android"))
    )
))]
pub use real::OsMedia;

/// Where there is no back end (macOS has its own now-playing path in the Swift app; iOS, Android).
#[cfg(not(any(
    windows,
    all(
        unix,
        not(any(target_os = "macos", target_os = "ios", target_os = "android"))
    )
)))]
pub struct OsMedia;

#[cfg(not(any(
    windows,
    all(
        unix,
        not(any(target_os = "macos", target_os = "ios", target_os = "android"))
    )
)))]
impl OsMedia {
    /// No back end on this platform.
    pub fn open(
        _hwnd: Option<*mut std::ffi::c_void>,
        _wake: impl Fn() + Send + 'static,
    ) -> Option<OsMedia> {
        None
    }
}

#[cfg(not(any(
    windows,
    all(
        unix,
        not(any(target_os = "macos", target_os = "ios", target_os = "android"))
    )
)))]
impl SystemMedia for OsMedia {
    fn set_metadata(&mut self, _meta: &Metadata) {}
    fn set_playback(&mut self, _state: PlaybackState, _position_s: f64) {}
    fn set_rate(&mut self, _rate: f64) {}
    fn set_navigation(&mut self, _next: bool, _previous: bool) {}
    fn clear(&mut self) {}
    fn poll_events(&mut self) -> Vec<MediaEvent> {
        Vec::new()
    }
}
