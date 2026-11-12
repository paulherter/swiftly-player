//! Media keys and the system media controls (the volume flyout and lock screen on Windows: SMTC; the desktop media
//! widgets on Linux: MPRIS). The app talks to a thin trait; the player state feeds it through [`MediaSync`], which only
//! calls the system when something changed. Real back ends live behind Cargo features (`system-media`), the in-memory
//! [`MemoryMedia`] serves tests.

use swiftly_vm::PlayerIntent;

/// What the system shows as the playback state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaybackState {
    /// Nothing plays.
    Stopped,
    /// A title is loaded and paused.
    Paused,
    /// A title plays.
    Playing,
}

/// The title card the system shows.
#[derive(Clone, Debug, PartialEq)]
pub struct Metadata {
    /// Title (a film name, or an episode name).
    pub title: String,
    /// Second line (series name, year); may be empty.
    pub subtitle: String,
    /// Length in seconds, when known.
    pub duration_s: Option<f64>,
    /// The poster as a `file://` address (the system reads it itself); `None` until it is on disk.
    pub cover_url: Option<String>,
}

/// A button on a keyboard, headset or the system flyout.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum MediaEvent {
    /// Play (only).
    Play,
    /// Pause (only).
    Pause,
    /// The combined play/pause key.
    Toggle,
    /// Next track: skip forward.
    Next,
    /// Previous track. The player has no "previous episode" (the Mac sets `previousTrackCommand` off), so it is dropped.
    Previous,
    /// Skip by the player's jump distance: `true` forward, `false` back.
    Skip(bool),
    /// Stop.
    Stop,
    /// The system asks for this position (seconds).
    SeekTo(f64),
}

/// The system media controls, as the app needs them.
pub trait SystemMedia {
    /// The title card.
    fn set_metadata(&mut self, meta: &Metadata);
    /// The state and the position (seconds) the system shows and extrapolates from.
    fn set_playback(&mut self, state: PlaybackState, position_s: f64);
    /// Nothing plays any more: the card goes away.
    fn clear(&mut self);
    /// The button presses since the last call.
    fn poll_events(&mut self) -> Vec<MediaEvent>;
}

/// What the player shows right now.
#[derive(Clone, Debug, PartialEq)]
pub struct NowPlaying {
    /// The card.
    pub meta: Metadata,
    /// Playing or paused.
    pub playing: bool,
    /// Position in seconds.
    pub position_s: f64,
    /// A next episode is queued (the system's "next" button works only then, like `nextTrackCommand.isEnabled` on the Mac).
    pub has_next: bool,
}

/// Feeds a [`SystemMedia`] from the player state and turns its button presses into player keys.
pub struct MediaSync<M: SystemMedia> {
    media: M,
    shown: Option<(Metadata, PlaybackState)>,
    has_next: bool,
    /// Position the system was last told and when (player clock, ms): the system extrapolates between updates.
    told: Option<(f64, f64)>,
}

/// A drift (s) between where the system thinks we are and where we are, past which the position is sent again.
const DRIFT_S: f64 = 2.0;

impl<M: SystemMedia> MediaSync<M> {
    /// Wraps a back end.
    pub fn new(media: M) -> MediaSync<M> {
        MediaSync {
            media,
            shown: None,
            has_next: false,
            told: None,
        }
    }

    /// The back end (tests).
    pub fn media(&self) -> &M {
        &self.media
    }

    /// Call once per frame with the player state (`None`: no player open) and the clock in ms.
    pub fn update(&mut self, now: Option<&NowPlaying>, clock_ms: f64) {
        let Some(n) = now else {
            if self.shown.take().is_some() {
                self.media.clear();
                self.told = None;
            }
            return;
        };
        self.has_next = n.has_next;
        let state = if n.playing {
            PlaybackState::Playing
        } else {
            PlaybackState::Paused
        };
        let changed_card = self.shown.as_ref().is_none_or(|(m, _)| *m != n.meta);
        let changed_state = self.shown.as_ref().is_none_or(|(_, s)| *s != state);
        if changed_card {
            self.media.set_metadata(&n.meta);
        }
        let drifted = self.told.is_none_or(|(pos, at)| {
            let expected = if state == PlaybackState::Playing {
                pos + (clock_ms - at) / 1000.0
            } else {
                pos
            };
            (expected - n.position_s).abs() > DRIFT_S
        });
        if changed_card || changed_state || drifted {
            self.media.set_playback(state, n.position_s);
            self.told = Some((n.position_s, clock_ms));
        }
        self.shown = Some((n.meta.clone(), state));
    }

    /// The pressed buttons as player intents (the player only knows a play/pause toggle, so a Play while playing and a
    /// Pause while paused are dropped).
    pub fn intents(&mut self) -> Vec<PlayerIntent> {
        let playing = self
            .shown
            .as_ref()
            .is_some_and(|(_, s)| *s == PlaybackState::Playing);
        let has_next = self.has_next;
        self.media
            .poll_events()
            .into_iter()
            .filter_map(|e| intent_for(e, playing, has_next))
            .collect()
    }
}

/// The player intent a media event stands for. `playing` is the state the player is in now, `has_next` whether a next
/// episode is queued.
pub fn intent_for(e: MediaEvent, playing: bool, has_next: bool) -> Option<PlayerIntent> {
    match e {
        MediaEvent::Toggle => Some(PlayerIntent::TogglePlay),
        MediaEvent::Play if !playing => Some(PlayerIntent::TogglePlay),
        MediaEvent::Pause | MediaEvent::Stop if playing => Some(PlayerIntent::TogglePlay),
        MediaEvent::Next if has_next => Some(PlayerIntent::NextEpisode),
        MediaEvent::Skip(true) => Some(PlayerIntent::Forward),
        MediaEvent::Skip(false) => Some(PlayerIntent::Back),
        MediaEvent::SeekTo(s) if s.is_finite() && s >= 0.0 => Some(PlayerIntent::SeekTo(s)),
        _ => None,
    }
}

/// A `file://` address of a local path (the system's media widgets read the poster themselves). Windows paths become
/// `file:///C:/…`; everything outside letters, digits and `-._~/:` is percent-encoded.
pub fn file_url(path: &std::path::Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    let mut out = String::from(if text.starts_with('/') {
        "file://"
    } else {
        "file:///"
    });
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/:".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

enum PosterState {
    Idle,
    Loading,
    Ready(String),
    Failed,
}

/// The poster of the playing title as a file on disk: fetched once on a worker thread (`source` blocks), written next
/// to the caches, then handed out as a `file://` address. One enum, `Idle → Loading → Ready | Failed`.
pub struct Poster {
    source: crate::player_card::StillSource,
    dir: std::path::PathBuf,
    name: String,
    state: std::sync::Arc<std::sync::Mutex<PosterState>>,
}

impl Poster {
    /// For a source; nothing is fetched before the first [`url`](Self::url). `name` is the file name (one per title).
    pub fn new(
        source: crate::player_card::StillSource,
        dir: std::path::PathBuf,
        name: &str,
    ) -> Poster {
        Poster {
            source,
            dir,
            name: name.to_owned(),
            state: std::sync::Arc::new(std::sync::Mutex::new(PosterState::Idle)),
        }
    }

    /// The address once the file is on disk; starts the fetch on the first call.
    pub fn url(&self) -> Option<String> {
        let mut g = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match &*g {
            PosterState::Ready(u) => return Some(u.clone()),
            PosterState::Loading | PosterState::Failed => return None,
            PosterState::Idle => *g = PosterState::Loading,
        }
        drop(g);
        let (state, source, dir, name) = (
            std::sync::Arc::clone(&self.state),
            std::sync::Arc::clone(&self.source),
            self.dir.clone(),
            self.name.clone(),
        );
        std::thread::spawn(move || {
            let done = source()
                .filter(|b| !b.is_empty())
                .and_then(|bytes| {
                    // Only the poster of the playing title stays on disk.
                    if let Ok(old) = std::fs::read_dir(&dir) {
                        for e in old
                            .flatten()
                            .filter(|e| e.file_name().to_string_lossy().starts_with("nowplaying-"))
                        {
                            let _ = std::fs::remove_file(e.path());
                        }
                    }
                    std::fs::create_dir_all(&dir).ok()?;
                    let path = dir.join(&name);
                    swiftly_atomic::write(&path, &bytes).ok()?;
                    Some(file_url(&path))
                })
                .map_or(PosterState::Failed, PosterState::Ready);
            *state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = done;
        });
        None
    }
}

/// A back end in memory: records what the app set, and lets a test press buttons.
#[derive(Debug, Default)]
pub struct MemoryMedia {
    /// The card now shown.
    pub metadata: Option<Metadata>,
    /// The last state and position set.
    pub playback: Option<(PlaybackState, f64)>,
    /// How many times each setter was called: metadata, playback, clear.
    pub calls: (u32, u32, u32),
    queued: Vec<MediaEvent>,
}

impl MemoryMedia {
    /// A button press to be returned by the next `poll_events`.
    pub fn press(&mut self, e: MediaEvent) {
        self.queued.push(e);
    }
}

impl SystemMedia for MemoryMedia {
    fn set_metadata(&mut self, meta: &Metadata) {
        self.metadata = Some(meta.clone());
        self.calls.0 += 1;
    }
    fn set_playback(&mut self, state: PlaybackState, position_s: f64) {
        self.playback = Some((state, position_s));
        self.calls.1 += 1;
    }
    fn clear(&mut self) {
        self.metadata = None;
        self.playback = None;
        self.calls.2 += 1;
    }
    fn poll_events(&mut self) -> Vec<MediaEvent> {
        std::mem::take(&mut self.queued)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now(playing: bool, pos: f64) -> NowPlaying {
        NowPlaying {
            meta: Metadata {
                title: "Pilot".into(),
                subtitle: "The Lighthouse".into(),
                duration_s: Some(2600.0),
                cover_url: None,
            },
            playing,
            position_s: pos,
            has_next: false,
        }
    }

    #[test]
    fn the_system_is_told_only_what_changed() {
        let mut s = MediaSync::new(MemoryMedia::default());
        s.update(Some(&now(true, 0.0)), 0.0);
        assert_eq!(s.media().calls, (1, 1, 0));
        // One second of normal play: nothing new to say.
        s.update(Some(&now(true, 1.0)), 1000.0);
        s.update(Some(&now(true, 2.0)), 2000.0);
        assert_eq!(s.media().calls, (1, 1, 0));
        // Pause: the state changes.
        s.update(Some(&now(false, 2.0)), 2100.0);
        assert_eq!(s.media().playback, Some((PlaybackState::Paused, 2.0)));
        assert_eq!(s.media().calls, (1, 2, 0));
        // A seek jumps the position.
        s.update(Some(&now(false, 600.0)), 2200.0);
        assert_eq!(s.media().calls, (1, 3, 0));
        // Closing the player clears the card, once.
        s.update(None, 2300.0);
        s.update(None, 2400.0);
        assert_eq!(s.media().calls, (1, 3, 1));
        assert_eq!(s.media().metadata, None);
    }

    #[test]
    fn buttons_become_player_intents() {
        let mut s = MediaSync::new(MemoryMedia::default());
        s.update(Some(&now(true, 0.0)), 0.0);
        for e in [
            MediaEvent::Play,
            MediaEvent::Pause,
            MediaEvent::Toggle,
            MediaEvent::Next,
            MediaEvent::Previous,
            MediaEvent::Skip(true),
            MediaEvent::Skip(false),
            MediaEvent::SeekTo(5.0),
            MediaEvent::SeekTo(-1.0),
        ] {
            s.media.press(e);
        }
        // Playing: Play is dropped, Pause toggles; no next episode: Next is dropped; Previous never exists.
        assert_eq!(
            s.intents(),
            vec![
                PlayerIntent::TogglePlay,
                PlayerIntent::TogglePlay,
                PlayerIntent::Forward,
                PlayerIntent::Back,
                PlayerIntent::SeekTo(5.0)
            ]
        );
        assert!(s.intents().is_empty());
        // With a next episode queued the system's Next works.
        let mut with_next = now(true, 0.0);
        with_next.has_next = true;
        s.update(Some(&with_next), 100.0);
        s.media.press(MediaEvent::Next);
        assert_eq!(s.intents(), vec![PlayerIntent::NextEpisode]);
    }

    #[test]
    fn local_paths_become_file_addresses() {
        assert_eq!(
            file_url(std::path::Path::new("C:\\Users\\Paul Herter\\a.jpg")),
            "file:///C:/Users/Paul%20Herter/a.jpg"
        );
        assert_eq!(
            file_url(std::path::Path::new("/data/app/swiftly/x.jpg")),
            "file:///data/app/swiftly/x.jpg"
        );
    }

    #[test]
    fn the_poster_is_fetched_once_and_written_to_disk() {
        let dir = std::env::temp_dir().join(format!("swiftly-poster-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
        let c = std::sync::Arc::clone(&calls);
        let source: crate::player_card::StillSource = std::sync::Arc::new(move || {
            c.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Some(vec![1, 2, 3])
        });
        let p = Poster::new(source, dir.clone(), "nowplaying-a.jpg");
        let mut url = p.url();
        for _ in 0..200 {
            if url.is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
            url = p.url();
        }
        assert!(url.is_some_and(|u| u.starts_with("file://") && u.ends_with("nowplaying-a.jpg")));
        assert_eq!(
            std::fs::read(dir.join("nowplaying-a.jpg")).unwrap(),
            vec![1, 2, 3]
        );
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn intent_for_respects_the_state() {
        assert_eq!(
            intent_for(MediaEvent::Play, false, false),
            Some(PlayerIntent::TogglePlay)
        );
        assert_eq!(intent_for(MediaEvent::Play, true, false), None);
        assert_eq!(
            intent_for(MediaEvent::Stop, true, false),
            Some(PlayerIntent::TogglePlay)
        );
        assert_eq!(intent_for(MediaEvent::Stop, false, false), None);
        assert_eq!(intent_for(MediaEvent::SeekTo(f64::NAN), true, false), None);
    }
}
