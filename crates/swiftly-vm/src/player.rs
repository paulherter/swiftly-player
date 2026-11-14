//! `PlayerVm`: the player as a view model (the state and rules of `Sources/iOS/PlayerScreen.swift`,
//! `PlaybackTick`, `SectionLogic`, `OfferingLayer`, `EpisodeEnd` and the reporting of
//! `AppModel`; the engine facade state is `swiftly_playback::player_state::PlayerState`).
//!
//! Sans-I/O in the sense of `swiftly-sync`: every call that depends on time takes `now`
//! (seconds on any consistent clock). The host
//! * feeds [`EngineEvent`]s through [`PlayerVm::engine_event`],
//! * calls [`PlayerVm::tick`] every 500 ms and [`PlayerVm::display_tick`] on the 250 ms in
//!   between (Swift `PlaybackTick.displayTick`; the half tick only moves the shown time),
//! * sends [`PlayerIntent`]s, and
//! * drains [`PlayerVm::take_effects`] (close the screen, switch the episode, fetch the next
//!   plan, prebuffer).
//!
//! Engine commands go out through the [`PlaybackEngine`] trait (all return `()`, results come
//! back as events). Reports go to a [`Reporter`] on the Swift cadence: start once the first
//! picture shows, progress every 10 s and at once on a pause/resume or a seek, stop when the
//! player closes or switches the episode. SyncPlay hooks in through [`GroupHook`]: in a group the
//! user's play/pause and seeks are requests to the group; what the group decides arrives as
//! `EnginePlay`/`EnginePause`/`EngineSeek`.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use std::collections::HashMap;

use swiftly_jellyfin::{PlayMethod, ReportPlan, TrackIndices};
use swiftly_playback::decoder_choice::AudioOutputMode;
use swiftly_playback::engine::{
    EngineEvent, EngineLoad, EngineState, PipCmd, PlaybackEngine, Rect, SubtitleRoute,
};
use swiftly_playback::offering_layer::{OfferingLayer, OfferingPresentation, Opening};
use swiftly_playback::player_state::{Command, EngineRequest, Intent, PlayerState};
use swiftly_playback::sections::{ButtonOffering, SectionLogic, Segment};
use swiftly_playback::track_label::{self, LabelText};
use swiftly_playback::track_mapping::TrackImprint;
use swiftly_playback::track_rule::{self, Choice};
use swiftly_playback::trickplay::{Tile, Trickplay};
use swiftly_playback::{pause_jump_back, prebuffer};
use swiftly_rules::chapter::{Chapter, ChapterBar};
use swiftly_rules::delay::Delay;
use swiftly_rules::playback_tick::{self as tick, Reading, Snapshot};
use swiftly_rules::{episodes_card, episodes_end};

use crate::bell::{Bell, Changed};
use crate::next_card::{NextCard, NextCardEvent};
use crate::player_controls::{ChainEvent, Controls, ControlsEvent, SeekChain, Side};
use crate::player_extra::{
    AfterPlay, Failure, Nudge, ORIGINAL_QUALITY_HINT, Quality, TrackMemoryStore,
};
use crate::player_more::{PlayerExtra, SMALL_WINDOW_TEXT, StreamReading};
use crate::player_report::{ReportKind, ReportMessage, Reporter};
use crate::player_stage::{PlayerStage, StageEvent, Surface, SurfaceEvent};
use swiftly_playback::stream_watch::Rebuild;

/// Seconds the controls stay up while playing (PlayerScreen.swift:736).
pub const CONTROLS_HIDE: f64 = 4.0;
/// Seconds the "+10 s" indicator of repeated skips stays (PlayerScreen.swift:1603).
pub const JUMP_DISPLAY: f64 = 0.7;
/// Seconds without a move after which a stuck scrubber lets go (PlayerScreen.swift:2071).
pub const PUSH_SAFETY: f64 = 3.0;
const FULL_TICK: f64 = 0.5;

/// Settings the player reads.
#[derive(Debug, Clone, PartialEq)]
pub struct PlayerPrefs {
    /// `backSeconds`.
    pub back_seconds: i64,
    /// `forwardSeconds`.
    pub forward_seconds: i64,
    /// Skip intro and outro automatically (`introAbspannAuto`).
    pub auto_skip: bool,
    /// Next episode automatically (`nextAutomatic`).
    pub next_automatic: bool,
    /// The network is fit to prepare the next episode (`preparation.networkFavorable`).
    pub network_favorable: bool,
    /// Always Direct Play (`alwaysDirectPlay`).
    pub direct_play: bool,
    /// Bitrate cap in Mbit/s while Direct Play is off (`bitratesLimit`).
    pub bitrate_limit: i64,
    /// The server may convert (`convertAllowed`); without it there is no quality choice.
    pub convert_allowed: bool,
}

impl Default for PlayerPrefs {
    fn default() -> Self {
        Self {
            back_seconds: 10,
            forward_seconds: 10,
            auto_skip: false,
            next_automatic: true,
            network_favorable: true,
            direct_play: true,
            bitrate_limit: 0,
            convert_allowed: true,
        }
    }
}

/// The next episode, as far as the player needs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NextEpisode {
    /// Item id.
    pub id: String,
    /// Title for the card.
    pub title: String,
}

/// What a title needs to play.
#[derive(Debug, Clone)]
pub struct PlayerSpec {
    /// Item id.
    pub item_id: String,
    /// Title shown in the header.
    pub title: String,
    /// Ids and delivery method for the reports.
    pub plan: ReportPlan,
    /// What the engine opens.
    pub request: EngineRequest,
    /// Start position in seconds.
    pub start_at: f64,
    /// Audio track chosen by the track rules (server index).
    pub audio_index: Option<i64>,
    /// Subtitle track chosen by the track rules; `-1` none.
    pub subtitle_index: i64,
    /// The next episode, if there is one.
    pub next: Option<NextEpisode>,
    /// Series id, so a delay survives the next episode of the same series.
    pub series_id: Option<String>,
    /// Key of the track memory (`TrackMemory.title`); `None` remembers nothing.
    pub track_title: Option<String>,
    /// The file is a download: no quality choice.
    pub downloaded: bool,
}

/// The panels over the picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayerLayer {
    /// Audio and subtitles.
    Tracks,
    /// Episodes of the season.
    Episodes,
    /// Settings.
    Settings,
}

/// What the user or the host wants.
#[derive(Debug, Clone, PartialEq)]
pub enum PlayerIntent {
    /// The play/pause button; in a group a request to the group.
    TogglePlay,
    /// Seek to a position (timeline, remote `jumpOn`); in a group a request.
    SeekTo(f64),
    /// Skip by the configured seconds forward (`scrub(forwardSeconds)`).
    Forward,
    /// Skip by the configured seconds back.
    Back,
    /// The finger went down on the scrubber.
    ScrubStart,
    /// The finger moved to this position.
    ScrubMove(f64),
    /// The finger lifted at this position (seeks).
    ScrubEnd(f64),
    /// Tap on the picture.
    ToggleControls,
    /// Any activity that keeps the controls up (click, key, button): it cancels a running "Next episode" card.
    WakeControls,
    /// Pointer movement that brings the controls up (`controlsShow(through: .beside)`): the card keeps running.
    WakeControlsBeside,
    /// Opens or closes a panel.
    Layer(Option<PlayerLayer>),
    /// Audio track by server index.
    SelectAudio(i64),
    /// Subtitle track by server index, `-1` off.
    SelectSubtitle(i64),
    /// Subtitle delay.
    SubtitleDelay(Delay),
    /// Audio delay.
    AudioDelay(Delay),
    /// Playback speed.
    Tempo(f32),
    /// Volume 0...100. A value above zero ends a mute.
    Volume(i32),
    /// The speaker button / the M key: mute, or back to the level before.
    Mute,
    /// Arrow up/down or the wheel: a step in shares (0.05 is 5 %).
    VolumeStep(f64),
    /// Fill the frame.
    Fill(bool),
    /// Sleep timer in minutes; `None` off.
    Sleep(Option<u32>),
    /// The press on the skip button / next-episode card.
    PressOffering,
    /// The click on the next-episode card: starts the next episode from the card (it zooms over the switch).
    PressCard,
    /// Back (Esc/Menu): closes the card, then a layer, then the controls, then the player.
    Back2,
    /// Next episode now.
    NextEpisode,
    /// Picture in picture.
    Pip(PipCmd),
    /// Close the player (reports the stop).
    Close,
    /// Quality: `None` Direct Play, `Some(n)` a cap of n Mbit/s. Reloads at the same position.
    Quality(Option<i64>),
    /// "Erneut versuchen" on the failed start.
    Retry,
    /// The group (SyncPlay) decided: play.
    EnginePlay,
    /// The group decided: pause.
    EnginePause,
    /// The group decided: seek here.
    EngineSeek(f64),
    /// The once-a-second look at the engine's counters (`streamCheck`, `audioCheck`). Rebuilds
    /// a stalled stream through [`PlayerEffect::StreamRebuilt`].
    StreamLook(StreamReading),
    /// The engine stopped mid-film by itself (`streamTornDown`); rebuilds at most three times.
    StreamTornDown,
    /// A rebuild after a network change is in progress (`onRestoration`): the last good position
    /// applies, not the engine's clock (which sits at the end of the file on a dead stream).
    Restoring(bool),
    /// The machine is going to sleep (`idleStateStart`): pause so the position is reported.
    Sleeping,
    /// The machine woke (`woke`): re-sync, reopen the stream and the audio output at the same
    /// position. A second report within ten seconds is ignored.
    Woke,
}

/// Something only the host can do.
#[derive(Debug, Clone, PartialEq)]
pub enum PlayerEffect {
    /// Leave the screen.
    Close,
    /// Switch to this episode: fetch its plan, then call [`PlayerVm::load_title`]. The stop of
    /// the old title is reported already.
    StartEpisode {
        /// Item id.
        id: String,
        /// The countdown card started it.
        from_card: bool,
        /// Start position; not zero for a quality switch of the same title.
        since: f64,
    },
    /// A subtitle was picked (or dropped) while a transcoded stream plays, and the server can only deliver it
    /// in the picture: ask the plan again with this subtitle (`play_plan_only(..., subtitle)`), then
    /// [`PlayerVm::load_title`] at `since`, starting on `subtitle`. The stop of the old stream is reported
    /// already. A direct play never gets this: the engine switches by itself.
    ReloadForSubtitle {
        /// Item id (the same title).
        id: String,
        /// Server subtitle index to start on, `-1` off.
        subtitle: i64,
        /// Resume position in seconds.
        since: f64,
    },
    /// The user chose another quality: write `alwaysDirectPlay` / `bitratesLimit`.
    QualityChosen(Quality),
    /// A prepared plan for the next episode carries the old quality: drop it.
    ForgetPrepared,
    /// Rating or Discord prompt is due; show it once the player is closed.
    Nudge(Nudge),
    /// Prepare the next episode (plan and first bytes) while this one still plays; once per title.
    PrepareNext(String),
    /// The stream was reopened at the same position (`streamNewBuildUp`); the engine got its
    /// load already. The host re-applies what lives outside the view model and logs `reason`.
    StreamRebuilt {
        /// Resume position in seconds.
        position: f64,
        /// Opened paused.
        paused: bool,
        /// Why, for the log.
        reason: String,
    },
    /// A wanted subtitle is not in the engine: hand over to the fallback engine.
    HandOver {
        /// Server subtitle index.
        subtitle: i64,
        /// Why.
        reason: String,
    },
}

/// The coarse state the controls draw.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// Until the first picture.
    Loading,
    /// Playing.
    Playing,
    /// Paused.
    Paused,
    /// The film is over.
    Ended,
    /// The start or the stream failed.
    Failed,
}

/// Position, duration and what the picture area shows.
#[derive(Debug, Clone, PartialEq)]
pub struct TransportPart {
    /// Coarse state.
    pub phase: Phase,
    /// Position shown (a seek target until it lands).
    pub position: f64,
    /// The engine plays (the screen's `running`): true while playing, also before it ended.
    pub running: bool,
    /// The target of a jump the engine has not reached yet (the display stands on it).
    pub leap: Option<f64>,
    /// Duration in seconds.
    pub duration: f64,
    /// A spinner is up: no picture yet, or the engine is seeking.
    pub buffering: bool,
    /// Playback speed.
    pub tempo: f32,
    /// The first picture is there (the loading screen may go).
    pub picture_shown: bool,
    /// Name of the chapter at the position.
    pub chapter: Option<String>,
    /// A short notice ("Schlafzeit abgelaufen.").
    pub hint: Option<String>,
    /// Error text of a failed start or stream.
    pub error: Option<String>,
    /// The screen of a failed start with its two buttons.
    pub failure: Option<Failure>,
    /// Subtitle text on screen, `\N` already a line break.
    pub subtitle: Option<String>,
    /// Picture in picture (possible, active).
    pub pip: (bool, bool),
    /// The notice over the empty picture while it plays in the small window
    /// ("Läuft im kleinen Fenster"); `None` otherwise.
    pub small_window: Option<&'static str>,
}

/// Controls visibility and the transient indicators.
#[derive(Debug, Clone, PartialEq)]
pub struct ControlsPart {
    /// The controls are up.
    pub visible: bool,
    /// The open panel.
    pub layer: Option<PlayerLayer>,
    /// The finger is on the scrubber.
    pub scrubbing: bool,
    /// "+20 s" indicator: bearing (-1/1) and the summed seconds.
    pub jump_display: Option<(i32, i64)>,
    /// The preview image under the scrubber (trickplay).
    pub preview: Option<Tile>,
    /// Sleep timer minutes, if set.
    pub sleep_minutes: Option<u32>,
    /// Button seconds back / forward.
    pub jump_seconds: (i64, i64),
    /// The quality choice, `None` when not offered (download, no conversion, in a group).
    pub quality: Option<Quality>,
    /// Volume in percent 0...100.
    pub volume: u8,
    /// Silent (volume zero): the speaker button shows the muted symbol.
    pub muted: bool,
}

/// A track in the panel.
#[derive(Debug, Clone, PartialEq)]
pub struct TrackRow {
    /// Server index.
    pub index: i64,
    /// Display label ("Russian · AC-3 · 5.1").
    pub label: String,
    /// Chosen now.
    pub selected: bool,
    /// A forced subtitle (the stream's flag); always `false` for audio.
    pub forced: bool,
    /// A subtitle from a file next to the video (`IsExternal`); always `false` for audio.
    pub file: bool,
    /// A subtitle for the hard of hearing; always `false` for audio.
    pub hearing_impaired: bool,
}

/// The track panel.
#[derive(Debug, Clone, PartialEq)]
pub struct TracksPart {
    /// Audio tracks.
    pub audio: Vec<TrackRow>,
    /// Subtitle tracks (off is `-1`, drawn by the view as the first row).
    pub subtitles: Vec<TrackRow>,
    /// No subtitle chosen.
    pub subtitles_off: bool,
    /// Audio delay in ms.
    pub audio_delay_ms: i64,
    /// Subtitle delay in ms.
    pub subtitle_delay_ms: i64,
}

/// What the bottom-right button or the card shows.
#[derive(Debug, Clone, PartialEq)]
pub enum OfferView {
    /// Nothing.
    Hidden,
    /// A button.
    Button {
        /// German catalog key of the label ("Intro überspringen", "Nächste Folge").
        label: &'static str,
        /// Next episode rather than a skip.
        next_episode: bool,
        /// With auto-skip on: how far the skip countdown has run, 0...1 (the button's fill).
        countdown: Option<f64>,
    },
    /// The countdown card of the next episode.
    Card {
        /// Title of the episode.
        title: String,
        /// 0...1 filled.
        share: f64,
        /// Whole seconds left ("Startet in {n} Sekunden").
        seconds_left: i64,
    },
}

/// The offering part.
#[derive(Debug, Clone, PartialEq)]
pub struct OfferPart {
    /// What shows.
    pub view: OfferView,
}

struct Live {
    spec: PlayerSpec,
    state: PlayerState,
    snap: Snapshot,
    layer: OfferingLayer,
    prefs: PlayerPrefs,
    sections: Vec<Segment>,
    chapters: Vec<Chapter>,
    trickplay: Option<Trickplay>,
    group: Option<Arc<dyn GroupHook>>,
    opened: f64,
    ended: bool,
    has_audio_tracks: bool,
    at_push: bool,
    restoring: bool,
    stage: PlayerStage,
    next_card: NextCard,
    surface: Surface,
    last_pushed: f64,
    preview: Option<Tile>,
    controls: bool,
    hide_at: Option<f64>,
    open_layer: Option<PlayerLayer>,
    chain: SeekChain,
    controls_state: Controls,
    sleep: Option<(u32, f64)>,
    watchdog: Option<(u32, f64)>,
    paused_since: Option<f64>,
    reported_paused: bool,
    tracks: TrackIndices,
    hint: Option<String>,
    error: Option<String>,
    prepared: bool,
    switching: bool,
    closed: bool,
    effects: Vec<PlayerEffect>,
    parts: Option<Parts>,
    audio_delay: Delay,
    sub_delay: Delay,
    memory: Option<Arc<dyn TrackMemoryStore>>,
    after: Option<Arc<AfterPlay>>,
    quality_switched: bool,
    extra: PlayerExtra,
}

#[derive(Clone, PartialEq)]
struct Parts {
    transport: TransportPart,
    controls: ControlsPart,
    tracks: TracksPart,
    offer: OfferPart,
}

/// SyncPlay seam: what the user's input means in a group (`gemeinsam.bitToggle/bitJump`).
pub trait GroupHook: Send + Sync {
    /// Play/pause was pressed; `running` is the state before.
    fn toggle(&self, running: bool);
    /// A seek was asked for.
    fn jump(&self, to: f64);
}

/// One engine command that waits until the view model's lock is released.
enum Op {
    Load(EngineLoad),
    Play,
    Pause,
    Seek(f64),
    Rate(f32),
    Volume(u8),
    AudioDelay(i32),
    SubtitleDelay(i32),
    SelectAudio(i32),
    SelectSubtitle(i32),
    Fill(bool),
    Place(Rect),
    Stop(bool),
    Pip(PipCmd),
    AudioOutput(AudioOutputMode),
    /// Host store work (track memory), run after the lock is released.
    Later(Box<dyn FnOnce() + Send>),
}

/// The engine as the state machine sees it while the view model's lock is held. The host engine
/// is foreign code (a Swift callback that may hop to the main thread), so a command that returns
/// nothing is only queued here and handed over by [`Outbox::flush`] after the lock is dropped.
/// Order is kept. `select_audio` and `select_subtitle` return a value, but the state machine
/// (`Command::run`) drops it, so they are queued too and nothing foreign runs under the lock.
struct Outbox<E: PlaybackEngine> {
    engine: Arc<E>,
    ops: Mutex<Vec<Op>>,
}

impl<E: PlaybackEngine> Outbox<E> {
    fn push(&self, op: Op) {
        self.ops
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(op);
    }

    /// Hands the queued commands to the host engine, in order. Call without any lock held.
    fn flush(&self) {
        let ops = std::mem::take(&mut *self.ops.lock().unwrap_or_else(PoisonError::into_inner));
        for op in ops {
            match op {
                Op::Load(r) => self.engine.load(r),
                Op::Play => self.engine.play(),
                Op::Pause => self.engine.pause(),
                Op::Seek(s) => self.engine.seek(s),
                Op::Rate(t) => self.engine.set_rate(t),
                Op::Volume(v) => self.engine.set_volume(v),
                Op::AudioDelay(d) => self.engine.set_audio_delay(d),
                Op::SubtitleDelay(d) => self.engine.set_subtitle_delay(d),
                Op::SelectAudio(i) => {
                    self.engine.select_audio(i);
                }
                Op::SelectSubtitle(i) => {
                    self.engine.select_subtitle(i);
                }
                Op::Fill(on) => self.engine.set_fill(on),
                Op::Place(r) => self.engine.place(r),
                Op::Stop(reset) => self.engine.stop(reset),
                Op::Pip(c) => self.engine.pip(c),
                Op::AudioOutput(m) => self.engine.set_audio_output(&m),
                Op::Later(work) => work(),
            }
        }
    }
}

impl<E: PlaybackEngine> PlaybackEngine for Outbox<E> {
    fn load(&self, request: EngineLoad) {
        self.push(Op::Load(request));
    }
    fn play(&self) {
        self.push(Op::Play);
    }
    fn pause(&self) {
        self.push(Op::Pause);
    }
    fn seek(&self, seconds: f64) {
        self.push(Op::Seek(seconds));
    }
    fn set_rate(&self, tempo: f32) {
        self.push(Op::Rate(tempo));
    }
    fn set_volume(&self, percent: u8) {
        self.push(Op::Volume(percent));
    }
    fn set_audio_delay(&self, milliseconds: i32) {
        self.push(Op::AudioDelay(milliseconds));
    }
    fn set_subtitle_delay(&self, milliseconds: i32) {
        self.push(Op::SubtitleDelay(milliseconds));
    }
    fn select_audio(&self, server_index: i32) -> bool {
        // The state machine drops the answer, so the call is queued like the others and made
        // after the lock is released; the host's reply is not needed here.
        self.push(Op::SelectAudio(server_index));
        true
    }
    fn select_subtitle(&self, server_index: i32) -> SubtitleRoute {
        self.push(Op::SelectSubtitle(server_index));
        SubtitleRoute::Cues
    }
    fn set_fill(&self, on: bool) {
        self.push(Op::Fill(on));
    }
    fn place(&self, rect: Rect) {
        self.push(Op::Place(rect));
    }
    fn stop(&self, reset_display: bool) {
        self.push(Op::Stop(reset_display));
    }
    fn pip(&self, command: PipCmd) {
        self.push(Op::Pip(command));
    }
    fn set_audio_output(&self, mode: &AudioOutputMode) {
        self.push(Op::AudioOutput(mode.clone()));
    }
}

/// The core's answer to "the audio went to an AirPlay device".
#[derive(Debug, Clone, PartialEq)]
pub enum AirPlayStart {
    /// Not now (not live, already in PiP or on the TV): the host does nothing.
    Ignore,
    /// Ask the server for the narrow AirPlay plan with this audio track.
    Go {
        /// The server's audio `Index` that gets through.
        audio_track: Option<i64>,
    },
    /// The file cannot go over AirPlay.
    Refused(swiftly_playback::airplay_suitability::AirPlaySuitability),
}

/// The player view model.
pub struct PlayerVm<E: PlaybackEngine, R: Reporter> {
    engine: Outbox<E>,
    reporter: Arc<R>,
    labels: Arc<dyn LabelText + Send + Sync>,
    bell: Arc<Bell>,
    live: Mutex<Live>,
}

fn new_state(spec: &PlayerSpec) -> PlayerState {
    PlayerState::new(spec.request.clone(), spec.audio_index, spec.subtitle_index)
}

impl<E: PlaybackEngine, R: Reporter> PlayerVm<E, R> {
    /// A player for a title; call [`Self::start`] to load.
    pub fn new(
        engine: Arc<E>,
        reporter: Arc<R>,
        labels: Arc<dyn LabelText + Send + Sync>,
        prefs: PlayerPrefs,
        spec: PlayerSpec,
        now: f64,
    ) -> Self {
        let live = Live::new(spec, prefs, now);
        Self {
            engine: Outbox {
                engine,
                ops: Mutex::new(Vec::new()),
            },
            reporter,
            labels,
            bell: Bell::new(),
            live: Mutex::new(live),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Live> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Resolves when a part changed after `seen`.
    pub fn changed(&self, seen: u64) -> Changed {
        self.bell.changed(seen)
    }

    /// The current version.
    pub fn version(&self) -> u64 {
        self.bell.version()
    }

    /// Position, state, notices.
    pub fn transport(&self) -> TransportPart {
        self.parts().transport
    }

    /// The finer lifecycle state (start, restore, switch, hand-over, failure); `transport().phase` is
    /// its coarse form.
    pub fn stage(&self) -> PlayerStage {
        self.lock().stage
    }

    /// The next-episode card's state (hidden, offered, zooming, switching, dismissed).
    pub fn next_card(&self) -> NextCard {
        self.lock().next_card
    }

    /// Feed the next-episode card an event; an illegal one leaves it alone. Returns the new state.
    pub fn feed_next_card(&self, event: NextCardEvent) -> NextCard {
        let mut l = self.lock();
        l.next_card = l.next_card.reduce(event);
        l.next_card
    }

    /// Where the picture goes (this screen, small window, AirPlay).
    pub fn surface(&self) -> Surface {
        self.lock().surface
    }

    /// The host reports a surface change (the small window opened or closed, AirPlay took over or went back).
    pub fn surface_event(&self, event: SurfaceEvent) -> Surface {
        let mut l = self.lock();
        l.surface = l.surface.reduce(event);
        l.surface
    }

    /// The audio route went to an AirPlay device: may the TV take the picture? The core checks the
    /// stage and the surface, then the file (`AirPlaySuitability`); only on `Go` does the surface move
    /// to `AirPlayAsking` and the host asks the server for a plan with that audio track.
    pub fn airplay_start(&self, source: &swiftly_model::MediaSource) -> AirPlayStart {
        let mut l = self.lock();
        if !l.surface.allows_airplay(l.stage) {
            return AirPlayStart::Ignore;
        }
        let verdict = swiftly_playback::airplay_suitability::AirPlaySuitability::check(source);
        if verdict.fitting() {
            l.surface = l.surface.reduce(SurfaceEvent::AirPlayAsk);
            AirPlayStart::Go {
                audio_track: verdict.audio_track,
            }
        } else {
            AirPlayStart::Refused(verdict)
        }
    }

    /// The control bar's lifecycle (hidden, fading in, visible, fading out) at `now`; the
    /// exported `controls().visible` stays the flag the hosts read today.
    pub fn controls_stage(&self, now: f64) -> Controls {
        self.lock().controls_state.reduce(ControlsEvent::Tick {
            now,
            may_hide: false,
        })
    }

    /// The seek chain (none, taps adding up, finger on the bar) at `now`; `controls().jump_display`
    /// is its overlay form.
    pub fn seek_chain(&self, now: f64) -> SeekChain {
        self.lock().chain.reduce(ChainEvent::Tick { now })
    }

    /// Controls and indicators.
    pub fn controls(&self) -> ControlsPart {
        self.parts().controls
    }

    /// Track panel.
    pub fn tracks(&self) -> TracksPart {
        self.parts().tracks
    }

    /// Skip button / card.
    pub fn offer(&self) -> OfferPart {
        self.parts().offer
    }

    fn parts(&self) -> Parts {
        let l = self.lock();
        self.build(&l)
    }

    /// The title that plays (or is being replaced): its item id, version and plan, for the host's plan request.
    pub fn spec(&self) -> PlayerSpec {
        self.lock().spec.clone()
    }

    /// Everything the host must do; empties the list.
    pub fn take_effects(&self) -> Vec<PlayerEffect> {
        std::mem::take(&mut self.lock().effects)
    }

    /// New settings (skip seconds, auto-skip, next episode automatically).
    pub fn set_prefs(&self, prefs: PlayerPrefs) {
        self.update(|_, l| l.prefs = prefs);
    }

    /// The segments of the title (intro, outro) arrived.
    pub fn set_sections(&self, sections: Vec<Segment>) {
        self.update(|_, l| l.sections = sections);
    }

    /// The chapters arrived.
    pub fn set_chapters(&self, chapters: Vec<Chapter>) {
        self.update(|_, l| l.chapters = chapters);
    }

    /// The trickplay offer arrived.
    pub fn set_trickplay(&self, trickplay: Option<Trickplay>) {
        self.update(|_, l| l.trickplay = trickplay);
    }

    /// The next episode became known (or none).
    pub fn set_next(&self, next: Option<NextEpisode>) {
        self.update(|_, l| l.spec.next = next);
    }

    /// Joins or leaves a SyncPlay group.
    pub fn set_group(&self, group: Option<Arc<dyn GroupHook>>) {
        self.update(|_, l| l.group = group);
    }

    /// Where hand-chosen tracks are remembered (`TrackMemory`).
    pub fn set_memory(&self, memory: Option<Arc<dyn TrackMemoryStore>>) {
        self.update(|_, l| l.memory = memory);
    }

    /// Counts finished titles for the rating and Discord prompts (`AppModel.doneWatch`).
    pub fn set_after_play(&self, after: Option<Arc<AfterPlay>>) {
        self.update(|_, l| l.after = after);
    }

    /// Loads the title at its start position.
    pub fn start(&self, now: f64) {
        self.update(|vm, l| {
            let start = l.spec.start_at;
            let cmds = l.state.intent(Intent::Start(start));
            vm.run(l, cmds, now);
            l.hide_at = Some(now + CONTROLS_HIDE);
            l.controls_state = l.controls_state.reduce(ControlsEvent::Activity { now });
        });
    }

    /// A limit was chosen but the original plays: say so instead of staying silent.
    fn original_quality_hint(l: &mut Live) {
        if l.quality_switched
            && !l.prefs.direct_play
            && l.spec.plan.method == PlayMethod::DirectPlay
        {
            l.hint = Some(ORIGINAL_QUALITY_HINT.to_owned());
        }
    }

    /// The host reloaded this title after a quality choice by building a new model (before [`Self::start`]):
    /// the model then knows the plan came from that choice and says when the original plays.
    pub fn after_quality_switch(&self) {
        self.update(|_, l| {
            l.quality_switched = true;
            Self::original_quality_hint(l);
        });
    }

    /// Replaces the title by the next episode (after [`PlayerEffect::StartEpisode`]); everything
    /// of the old one is forgotten, as `episodeApply` does.
    pub fn load_title(&self, spec: PlayerSpec, now: f64) {
        self.update(|vm, l| {
            let prefs = l.prefs.clone();
            let group = l.group.clone();
            let controls = (l.controls, l.hide_at);
            let layer_card_waits = l.layer.card_waits_controls;
            let (memory, after, switched) = (l.memory.clone(), l.after.clone(), l.quality_switched);
            // `delayForNewTitle`: the same title and the same series keep the delay.
            let (old_id, old_series) = (l.spec.item_id.clone(), l.spec.series_id.clone());
            let (sub_delay, audio_delay) = (l.sub_delay, l.audio_delay);
            let volume = l.extra.volume;
            *l = Live::new(spec, prefs, now);
            l.extra.volume = volume;
            l.memory = memory;
            l.after = after;
            let (id, series) = (l.spec.item_id.clone(), l.spec.series_id.clone());
            l.sub_delay = Delay::for_new_title(
                sub_delay,
                &old_id,
                old_series.as_deref(),
                &id,
                series.as_deref(),
            );
            l.audio_delay = Delay::for_new_title(
                audio_delay,
                &old_id,
                old_series.as_deref(),
                &id,
                series.as_deref(),
            );
            l.quality_switched = switched;
            Self::original_quality_hint(l);
            l.group = group;
            l.controls = controls.0;
            l.hide_at = controls.1;
            l.layer.card_waits_controls = layer_card_waits;
            tick::new_title(&mut l.snap, false);
            let start = l.spec.start_at;
            if start > tick::DISPLAY_TICK.as_secs_f64() {
                l.snap.after_change = false;
                l.snap.position = start;
                l.snap.leap = Some(tick::Jump {
                    target: start,
                    since: now,
                });
            }
            let cmds = l.state.intent(Intent::Start(start));
            vm.run(l, cmds, now);
            if l.sub_delay != Delay::from_milliseconds(0) {
                let cmds = l.state.intent(Intent::SetSubtitleDelay(l.sub_delay));
                vm.run(l, cmds, now);
            }
            if l.audio_delay != Delay::from_milliseconds(0) {
                let cmds = l.state.intent(Intent::SetAudioDelay(l.audio_delay));
                vm.run(l, cmds, now);
            }
        });
    }

    /// An event from the engine.
    pub fn engine_event(&self, event: EngineEvent, now: f64) {
        self.update(|vm, l| {
            match &event {
                EngineEvent::State(EngineState::Ended) => {
                    l.ended = true;
                    l.stage = l.stage.reduce(StageEvent::Ended);
                    // The last title stays open on its last frame, so its bar must be there to replay or close (the bar
                    // may have faded while it played; it never fades again once the engine is not running).
                    if l.spec.next.is_none() && !l.controls {
                        Self::set_controls(l, true, now, Opening::Beside);
                    }
                }
                EngineEvent::Tracks { audio, .. } if !audio.is_empty() => {
                    l.has_audio_tracks = true;
                }
                _ => {}
            }
            let loaded = matches!(event, EngineEvent::LoadFinished { .. });
            let cmds = l.state.apply(event);
            vm.run(l, cmds, now);
            // A stream rebuilt after wake-up stays paused if it was paused.
            if loaded && std::mem::take(&mut l.extra.pause_after_load) {
                let cmds = l.state.intent(Intent::Pause);
                vm.run(l, cmds, now);
            }
        });
    }

    /// The half tick (250 ms): only the shown time moves.
    pub fn display_tick(&self, now: f64) {
        self.update(|_, l| {
            if l.switching || l.closed {
                return;
            }
            l.expire(now);
            let reported = if l.restoring {
                l.state.last_good()
            } else {
                l.state.position()
            };
            tick::time_adopt(&mut l.snap, reported, l.at_push, l.opened, now);
        });
    }

    /// The full tick (500 ms): time, start/progress report, offering, auto-skip, advance.
    pub fn tick(&self, now: f64) {
        self.update(|vm, l| vm.full_tick(l, now));
    }

    /// The title's `OriginalLanguage` (item field): the audio track in that language is listed
    /// with the "(Original)" tag.
    pub fn set_original_language(&self, language: Option<String>) {
        self.update(|_, l| l.extra.original_language = language);
    }

    /// Audio passthrough and exclusive mode (`Player.passthrough(spdif:exclusive:)`): handed to
    /// the engine now, effective from the next load.
    pub fn set_audio_output(&self, mode: &AudioOutputMode) {
        self.update(|vm, _| vm.engine.set_audio_output(mode));
    }

    /// An intent.
    pub fn send(&self, intent: PlayerIntent, now: f64) {
        self.update(|vm, l| vm.intent(l, intent, now));
    }

    fn update(&self, f: impl FnOnce(&Self, &mut Live)) {
        let mut l = self.lock();
        f(self, &mut l);
        let new = self.build(&l);
        let old = l.parts.replace(new.clone());
        drop(l);
        // The host engine is called without the lock (a Swift callback may wait for the main thread).
        self.engine.flush();
        let mut changed = Vec::new();
        match old {
            Some(o) => {
                if o.transport != new.transport {
                    changed.push(0);
                }
                if o.controls != new.controls {
                    changed.push(1);
                }
                if o.tracks != new.tracks {
                    changed.push(2);
                }
                if o.offer != new.offer {
                    changed.push(3);
                }
            }
            None => changed.extend([0, 1, 2, 3]),
        }
        if !changed.is_empty() {
            self.bell.bump(&changed);
        }
    }

    // MARK: Commands from the state machine

    fn run(&self, l: &mut Live, cmds: Vec<Command>, now: f64) {
        for c in cmds {
            if c.run(&self.engine) {
                continue;
            }
            match c {
                Command::Running(go) => {
                    // The button follows the engine's own report (the Mac's `runsDisplay`), not the next tick.
                    if l.snap.first_image_present {
                        l.snap.running = go;
                    }
                    if go {
                        l.paused_since = None;
                    } else {
                        l.paused_since = Some(now);
                    }
                    l.hide_at = Some(now + CONTROLS_HIDE);
                    l.controls_state = l.controls_state.reduce(ControlsEvent::Activity { now });
                    // `runStateReported`: a changed state goes out at once, if the start is out.
                    if l.snap.start_reported && l.reported_paused == go {
                        l.reported_paused = !go;
                        self.report(l, ReportKind::Progress { paused: !go }, l.snap.position);
                    }
                }
                Command::Failed(text) => {
                    l.error = Some(text);
                    l.stage = l.stage.reduce(StageEvent::Failed);
                }
                Command::HandOver { subtitle, reason } => {
                    l.stage = l.stage.reduce(StageEvent::HandOver);
                    l.effects.push(PlayerEffect::HandOver { subtitle, reason });
                }
                Command::ReportTracks(t) => l.tracks = t,
                Command::ArmStartWatchdog { attempt, seconds } => {
                    l.watchdog = Some((attempt, now + seconds));
                }
                Command::CancelStartWatchdog => l.watchdog = None,
                _ => {}
            }
        }
    }

    fn report(&self, l: &Live, kind: ReportKind, seconds: f64) {
        let tracks = TrackIndices {
            audio: l.state.audio_index().or(l.tracks.audio),
            subtitle: Some(l.state.subtitle_index()),
        };
        self.reporter.report(ReportMessage {
            kind,
            item_id: l.spec.item_id.clone(),
            plan: l.spec.plan.clone(),
            seconds,
            tracks,
            // Plex timelines carry the title's length in every report (`PlexClient.milliseconds(of: plan)`).
            runtime_ms: (l.spec.request.runtime > 0.0)
                .then_some((l.spec.request.runtime * 1000.0) as i64),
        });
    }

    // MARK: Tick

    fn full_tick(&self, l: &mut Live, now: f64) {
        if l.closed {
            return;
        }
        if let Some((attempt, at)) = l.watchdog
            && now >= at
        {
            l.watchdog = None;
            let cmds = l.state.apply(EngineEvent::StartWatchdog { attempt });
            self.run(l, cmds, now);
        }
        if l.switching {
            return;
        }
        l.expire(now);
        if l.at_push && now - l.last_pushed > PUSH_SAFETY {
            l.at_push = false;
            l.chain = l.chain.reduce(ChainEvent::ScrubEnded);
        }
        let reading = Reading {
            duration: l.state.duration_seconds(),
            position: l.state.position(),
            good_point: l.state.last_good(),
            shows_image: l.state.picture_shown(),
            seeks_to_start: !l.state.start_settled(),
            running: l.state.is_playing(),
            has_audio_tracks: l.has_audio_tracks,
        };
        let job = tick::compute(&mut l.snap, &reading, l.restoring, l.at_push, l.opened, now);
        if l.snap.first_image_present {
            let go = l.snap.running;
            l.stage = l
                .stage
                .reduce(StageEvent::PictureShown { running: go })
                .reduce(StageEvent::Running(go));
        }
        if job.loading_screen_gone {
            l.hide_at = Some(now + CONTROLS_HIDE);
            l.controls_state = l.controls_state.reduce(ControlsEvent::Activity { now });
        }
        if job.start_report {
            l.reported_paused = false;
            self.report(l, ReportKind::Start, l.snap.position);
        }
        if job.progress_report {
            self.report(
                l,
                ReportKind::Progress {
                    paused: !l.snap.running,
                },
                l.snap.position,
            );
            l.reported_paused = !l.snap.running;
        }
        let card_before = matches!(l.layer.display(), OfferingPresentation::Card { .. });
        let expired = self.offering_catch_up(l, FULL_TICK);
        // Auto-skip: the offer was shown and its countdown ran out; now do what a press does.
        if l.layer.take_auto_skip() {
            self.press_offering(l, now);
            return;
        }
        if expired && l.spec.next.is_some() {
            self.start_episode(l, card_before, now);
            return;
        }
        // Prepare the next episode while this one plays (not in a group).
        if let Some(next) = l.spec.next.clone()
            && l.group.is_none()
            && !l.prepared
            && prebuffer::now(
                l.snap.position,
                l.snap.duration,
                l.sections
                    .iter()
                    .find(|s| s.art == swiftly_playback::sections::Art::Credits)
                    .map(|s| s.from),
                l.prefs.network_favorable,
            )
        {
            l.prepared = true;
            l.effects.push(PlayerEffect::PrepareNext(next.id));
        }
        // Advance by itself at the end, only through the card path.
        if l.layer.next_at_end()
            && l.spec.next.is_some()
            && episodes_end::advance(
                l.snap.position,
                l.snap.duration,
                now - l.opened,
                l.layer.card_counts(),
            )
        {
            self.start_episode(l, false, now);
            return;
        }
        // Sleep timer.
        if let Some((_, at)) = l.sleep
            && now >= at
        {
            l.sleep = None;
            let cmds = l.state.intent(Intent::Pause);
            self.run(l, cmds, now);
            l.controls = true;
            l.controls_state = l.controls_state.reduce(ControlsEvent::Show { now });
            l.hint = Some("Schlafzeit abgelaufen.".to_owned());
        }
        if matches!(
            l.controls_state,
            Controls::Showing { .. } | Controls::Hiding { .. }
        ) {
            l.controls_state = l.controls_state.reduce(ControlsEvent::Tick {
                now,
                may_hide: false,
            });
        }
        // Controls fade out: only while playing, not while scrubbing or with a panel open.
        if l.controls
            && let Some(at) = l.hide_at
            && now >= at
            && l.snap.running
            && !l.at_push
            && l.open_layer.is_none()
        {
            l.controls = false;
            l.hide_at = None;
            l.controls_state = l.controls_state.reduce(ControlsEvent::Hide { now });
            l.layer.controls(false, Opening::Deliberate);
        }
    }

    /// Only from the server, only when it may convert, not in a group (a switch would bypass it).
    fn quality_offered(l: &Live) -> bool {
        !l.spec.downloaded && l.prefs.convert_allowed && l.group.is_none()
    }

    fn offering(l: &Live) -> ButtonOffering {
        if l.switching {
            return ButtonOffering::Nobody;
        }
        SectionLogic::offering(
            l.snap.position,
            l.snap.duration,
            &l.sections,
            l.spec.next.is_some(),
        )
    }

    fn offering_catch_up(&self, l: &mut Live, elapsed: f64) -> bool {
        if l.switching {
            return false;
        }
        let (p, d) = (l.snap.position, l.snap.duration);
        let has_next = l.spec.next.is_some();
        let window = Some(episodes_card::REMAINING_WINDOW);
        // "Skip intro and outro automatically" also lets the outro's card count down and
        // advance, but only inside the outro section.
        l.layer.auto_skip = l.prefs.auto_skip;
        let auto_next =
            l.prefs.auto_skip && SectionLogic::automatic(p, d, &l.sections, has_next).is_some();
        let card_due = (l.prefs.next_automatic || auto_next)
            && SectionLogic::card_due(p, d, &l.sections, has_next, window);
        let running = l.snap.running && l.snap.first_image_present && !l.at_push;
        let countdown = SectionLogic::countdown_with_sections(p, d, &l.sections, window);
        // A clip under a minute is no "end of file" for the long-file rules, but once the engine reports the end
        // the card must finish its countdown all the same, or it would stay on screen forever.
        let ended_short = l.ended && d > 0.0 && p >= d - 1.0;
        let at_end = (episodes_end::at_end(p, d) || ended_short) && !l.at_push;
        let offering = Self::offering(l);
        l.layer
            .tick(offering, card_due, running, elapsed, countdown, at_end)
    }

    fn press_offering(&self, l: &mut Live, now: f64) {
        l.layer.pressed();
        match Self::offering(l) {
            ButtonOffering::Nobody => {}
            ButtonOffering::Skip { to, .. } => {
                self.seek(l, to, now);
                l.hide_at = Some(now + CONTROLS_HIDE);
                l.controls_state = l.controls_state.reduce(ControlsEvent::Activity { now });
            }
            ButtonOffering::NextEpisode => {
                if l.spec.next.is_some() {
                    self.start_episode(l, false, now);
                }
            }
        }
    }

    fn start_episode(&self, l: &mut Live, from_card: bool, now: f64) {
        let Some(next) = l.spec.next.clone() else {
            return;
        };
        if l.switching || l.group.is_some() {
            return;
        }
        self.switch_to(l, next.id, from_card, 0.0, now);
    }

    /// Stops the running title and asks the host for the plan of `id` (next episode, or the same
    /// title again for a quality switch, then with `since`).
    fn switch_to(&self, l: &mut Live, id: String, from_card: bool, since: f64, now: f64) {
        if l.switching || l.group.is_some() {
            return;
        }
        l.switching = true;
        l.stage = l.stage.reduce(StageEvent::SwitchBegan);
        self.count_finished(l);
        // The old title's end goes out now, exactly once (`StopLock` in the reporter).
        let seconds = l.snap.position;
        self.report(l, ReportKind::Stop, seconds);
        let cmds = l.state.intent(Intent::Stop {
            reset_display: false,
        });
        self.run(l, cmds, now);
        l.effects.push(PlayerEffect::StartEpisode {
            id,
            from_card,
            since,
        });
    }

    /// Whether choosing subtitle `i` on this stream needs a new plan and a reload
    /// ([`swiftly_playback::transcode_subtitle::delivery`]); never for a download or inside a group.
    fn subtitle_needs_reload(l: &Live, i: i64) -> bool {
        !l.spec.downloaded
            && l.group.is_none()
            && !l.switching
            && swiftly_playback::transcode_subtitle::delivery(
                l.spec.plan.method == PlayMethod::Transcode,
                &l.spec.request.url,
                &l.spec.request.streams,
                i,
            ) == swiftly_playback::transcode_subtitle::SubtitleDelivery::Replan
    }

    /// `AppModel.doneWatch`: a title watched to the end counts for the prompts.
    fn count_finished(&self, l: &mut Live) {
        if let Some(n) = l
            .after
            .as_ref()
            .and_then(|a| a.done_watch(l.snap.position, l.snap.duration))
        {
            l.effects.push(PlayerEffect::Nudge(n));
        }
    }

    /// A hand choice goes into the track memory of the series (`avAudioChosen`/`avSubtitleChosen`).
    fn remember_track(&self, l: &Live, audio: bool, index: i64) {
        let (Some(store), Some(title)) = (&l.memory, &l.spec.track_title) else {
            return;
        };
        let streams = l.state.streams();
        let choice = if index < 0 {
            Choice::Off
        } else {
            let Some(feed) = streams.iter().find(|s| s.index == Some(index)) else {
                return;
            };
            let labels: &dyn LabelText = &*self.labels;
            let name = if audio {
                track_label::audio(
                    feed.language.as_deref(),
                    feed.codec.as_deref(),
                    feed.channels,
                    labels,
                )
            } else {
                track_label::subtitle(feed, labels)
            };
            Choice::Track(TrackImprint::from_feed(feed, streams, name.as_deref()))
        };
        let key = if audio {
            track_rule::AUDIO_KEY
        } else {
            track_rule::SUBTITLE_KEY
        };
        // The store is foreign code: read and write it after the lock is released.
        let (store, title) = (Arc::clone(store), title.clone());
        self.engine.push(Op::Later(Box::new(move || {
            let mut all: HashMap<String, String> = store.load(key);
            track_rule::write_choice(&mut all, &title, &choice);
            store.save(key, &all);
        })));
    }

    // MARK: Seeking

    /// Every seek: timeline stands on the target at once; the group is asked instead when in one.
    fn seek(&self, l: &mut Live, target: f64, now: f64) {
        let target = target.max(0.0);
        if let Some(g) = &l.group {
            g.jump(target);
        } else {
            let cmds = l.state.intent(Intent::Seek(target));
            self.run(l, cmds, now);
        }
        self.jumped(l, target, now);
    }

    fn jumped(&self, l: &mut Live, target: f64, now: f64) {
        l.extra.check.jumped(now);
        tick::jumped(&mut l.snap, target, now);
        l.layer.jumped();
        self.offering_catch_up(l, 0.0);
        // `jumpReported`: the target goes out at once, if the start is out.
        if l.snap.start_reported {
            let paused = l.reported_paused;
            self.report(l, ReportKind::Progress { paused }, l.snap.position);
        }
    }

    fn scrub(&self, l: &mut Live, seconds: i64, now: f64) {
        let target = tick::target_by(seconds as f64, &l.snap);
        let mut target = target.max(0.0);
        if l.snap.duration > 0.0 {
            target = target.min(l.snap.duration);
        }
        self.seek(l, target, now);
        let side = if seconds < 0 {
            Side::Back
        } else {
            Side::Forward
        };
        l.chain = l.chain.reduce(ChainEvent::Tap { side, seconds, now });
        if l.controls {
            l.hide_at = Some(now + CONTROLS_HIDE);
            l.controls_state = l.controls_state.reduce(ControlsEvent::Activity { now });
        }
    }

    // MARK: Intents

    fn set_controls(l: &mut Live, visible: bool, now: f64, through: Opening) {
        l.controls = visible;
        l.hide_at = visible.then_some(now + CONTROLS_HIDE);
        l.controls_state = l.controls_state.reduce(if visible {
            ControlsEvent::Show { now }
        } else {
            ControlsEvent::Hide { now }
        });
        l.layer.controls(visible, through);
    }

    fn resume(&self, l: &mut Live, now: f64) {
        let jump = pause_jump_back::target(l.snap.position, l.paused_since, now, l.group.is_some());
        let cmds = l.state.intent(Intent::Resume);
        self.run(l, cmds, now);
        if let Some(t) = jump {
            self.seek(l, t, now);
        }
    }

    fn intent(&self, l: &mut Live, intent: PlayerIntent, now: f64) {
        if l.closed {
            return;
        }
        match intent {
            PlayerIntent::TogglePlay => {
                if let Some(g) = &l.group {
                    g.toggle(l.state.is_playing());
                } else if l.state.is_playing() {
                    let cmds = l.state.intent(Intent::Pause);
                    self.run(l, cmds, now);
                } else {
                    self.resume(l, now);
                }
                l.controls = true;
                l.controls_state = l.controls_state.reduce(ControlsEvent::Show { now });
                l.hide_at = Some(now + CONTROLS_HIDE);
                l.controls_state = l.controls_state.reduce(ControlsEvent::Activity { now });
            }
            PlayerIntent::EnginePlay => {
                let cmds = l.state.intent(Intent::Resume);
                self.run(l, cmds, now);
            }
            PlayerIntent::EnginePause => {
                let cmds = l.state.intent(Intent::Pause);
                self.run(l, cmds, now);
            }
            PlayerIntent::EngineSeek(t) => {
                let cmds = l.state.intent(Intent::Seek(t.max(0.0)));
                self.run(l, cmds, now);
                self.jumped(l, t, now);
            }
            PlayerIntent::SeekTo(t) => self.seek(l, t, now),
            PlayerIntent::Forward => {
                let s = l.prefs.forward_seconds;
                self.scrub(l, s, now);
            }
            PlayerIntent::Back => {
                let s = l.prefs.back_seconds;
                self.scrub(l, -s, now);
            }
            PlayerIntent::ScrubStart => {
                l.at_push = true;
                l.chain = l.chain.reduce(ChainEvent::ScrubBegan);
                l.last_pushed = now;
            }
            PlayerIntent::ScrubMove(t) => {
                l.at_push = true;
                l.chain = l.chain.reduce(ChainEvent::ScrubBegan);
                l.last_pushed = now;
                l.snap.position = t;
                l.preview = l.trickplay.as_ref().and_then(|tp| tp.tile(t));
                l.hide_at = Some(now + CONTROLS_HIDE);
                l.controls_state = l.controls_state.reduce(ControlsEvent::Activity { now });
            }
            PlayerIntent::ScrubEnd(t) => {
                l.at_push = false;
                l.chain = l.chain.reduce(ChainEvent::ScrubEnded);
                l.preview = None;
                self.seek(l, t, now);
            }
            PlayerIntent::ToggleControls => {
                let v = !l.controls;
                Self::set_controls(l, v, now, Opening::Deliberate);
            }
            PlayerIntent::WakeControls => Self::set_controls(l, true, now, Opening::Deliberate),
            PlayerIntent::WakeControlsBeside => Self::set_controls(l, true, now, Opening::Beside),
            PlayerIntent::Layer(layer) => {
                l.open_layer = layer;
                if layer.is_none() {
                    l.hide_at = Some(now + CONTROLS_HIDE);
                    l.controls_state = l.controls_state.reduce(ControlsEvent::Activity { now });
                }
            }
            PlayerIntent::SelectAudio(i) => {
                let cmds = l.state.intent(Intent::SwitchAudio(i));
                self.run(l, cmds, now);
                l.tracks.audio = Some(i);
                self.remember_track(l, true, i);
            }
            PlayerIntent::SelectSubtitle(i) => {
                if Self::subtitle_needs_reload(l, i) {
                    // A transcoded stream: the track is part of the picture (or has to leave it).
                    self.remember_track(l, false, i);
                    let (id, since) = (l.spec.item_id.clone(), l.snap.position);
                    self.switch_to(l, id, false, since, now);
                    // `switch_to` pushed the plain restart: the host needs the subtitle with it.
                    if let Some(PlayerEffect::StartEpisode { id, since, .. }) = l.effects.pop() {
                        l.effects.push(PlayerEffect::ReloadForSubtitle {
                            id,
                            subtitle: i,
                            since,
                        });
                    }
                } else {
                    let cmds = l.state.intent(Intent::SelectSubtitle(i));
                    self.run(l, cmds, now);
                    self.remember_track(l, false, i);
                }
            }
            PlayerIntent::Retry => {
                l.error = None;
                l.stage = l.stage.reduce(StageEvent::Begin);
                let start = l.spec.start_at;
                let cmds = l.state.intent(Intent::Start(start));
                self.run(l, cmds, now);
            }
            PlayerIntent::Quality(value) => {
                if !Self::quality_offered(l) {
                    return;
                }
                let before = (l.prefs.direct_play, l.prefs.bitrate_limit);
                match value {
                    Some(limit) => {
                        l.prefs.direct_play = false;
                        l.prefs.bitrate_limit = limit;
                    }
                    None => l.prefs.direct_play = true,
                }
                if before == (l.prefs.direct_play, l.prefs.bitrate_limit) {
                    return;
                }
                l.open_layer = None;
                l.effects.push(PlayerEffect::QualityChosen(Quality {
                    direct_play: l.prefs.direct_play,
                    limit: l.prefs.bitrate_limit,
                }));
                // A prepared plan for the next episode carries the old choice.
                l.effects.push(PlayerEffect::ForgetPrepared);
                l.quality_switched = true;
                let (id, since) = (l.spec.item_id.clone(), l.snap.position);
                self.switch_to(l, id, false, since, now);
            }
            PlayerIntent::SubtitleDelay(d) => {
                let cmds = l.state.intent(Intent::SetSubtitleDelay(d));
                self.run(l, cmds, now);
                l.sub_delay = d;
            }
            PlayerIntent::AudioDelay(d) => {
                let cmds = l.state.intent(Intent::SetAudioDelay(d));
                self.run(l, cmds, now);
                l.audio_delay = d;
            }
            PlayerIntent::Tempo(t) => {
                let cmds = l.state.intent(Intent::SetTempo(t));
                self.run(l, cmds, now);
            }
            PlayerIntent::Volume(v) => {
                let p = l.extra.volume.set_percent(v);
                self.set_volume(l, p, now);
            }
            PlayerIntent::Mute => {
                let p = l.extra.volume.toggle_mute();
                self.set_volume(l, p, now);
                Self::set_controls(l, true, now, Opening::Deliberate);
            }
            PlayerIntent::VolumeStep(step) => {
                let p = l.extra.volume.step(step);
                self.set_volume(l, p, now);
                Self::set_controls(l, true, now, Opening::Deliberate);
            }
            PlayerIntent::StreamLook(reading) => {
                let sample = PlayerExtra::sample(
                    reading,
                    now,
                    l.snap.position,
                    l.snap.running,
                    l.snap.start_reported,
                    l.snap.leap.is_some(),
                );
                if let Some(r) = l.extra.check.look(&sample) {
                    self.rebuild(l, r, now);
                }
            }
            PlayerIntent::StreamTornDown => {
                let (position, duration) = (l.snap.position, l.snap.duration);
                let shown = l.snap.first_image_present;
                if let Some(r) = l.extra.check.torn_down(position, duration, shown) {
                    self.rebuild(l, r, now);
                }
            }
            PlayerIntent::Restoring(on) => {
                l.restoring = on;
                l.stage = l.stage.reduce(StageEvent::Restore(on));
            }
            PlayerIntent::Sleeping => {
                if l.state.is_playing() {
                    let cmds = l.state.intent(Intent::Pause);
                    self.run(l, cmds, now);
                }
            }
            PlayerIntent::Woke => {
                let (position, running) = (l.snap.position, l.state.is_playing());
                if let Some(r) = l.extra.check.woke(now, position, running) {
                    self.rebuild(l, r, now);
                }
            }
            PlayerIntent::Fill(on) => {
                let cmds = l.state.intent(Intent::SetFill(on));
                self.run(l, cmds, now);
            }
            PlayerIntent::Sleep(m) => {
                l.sleep = m.map(|m| (m, now + f64::from(m) * 60.0));
            }
            PlayerIntent::PressOffering => self.press_offering(l, now),
            PlayerIntent::PressCard => {
                l.layer.pressed();
                if l.group.is_none() && l.spec.next.is_some() {
                    self.start_episode(l, true, now);
                }
            }
            PlayerIntent::Back2 => {
                if l.layer.close() {
                } else if l.open_layer.is_some() {
                    l.open_layer = None;
                } else if l.controls {
                    Self::set_controls(l, false, now, Opening::Deliberate);
                } else {
                    self.close(l, now);
                }
            }
            PlayerIntent::NextEpisode => {
                if l.group.is_none() {
                    self.start_episode(l, false, now);
                }
            }
            PlayerIntent::Pip(c) => self.engine.pip(c),
            PlayerIntent::Close => self.close(l, now),
        }
    }

    fn set_volume(&self, l: &mut Live, percent: u8, now: f64) {
        let cmds = l.state.intent(Intent::SetVolume(i32::from(percent)));
        self.run(l, cmds, now);
    }

    /// `streamNewBuildUp`: reopen the stream at the same position without touching the screen.
    /// The track mapping, the fill choice and the volume are applied again by the load.
    fn rebuild(&self, l: &mut Live, r: Rebuild, now: f64) {
        l.error = None;
        l.stage = l.stage.reduce(StageEvent::Begin);
        l.snap.position = r.position;
        let cmds = l.state.intent(Intent::Start(r.position));
        self.run(l, cmds, now);
        l.extra.pause_after_load = r.paused;
        let p = l.extra.volume.percent();
        self.set_volume(l, p, now);
        l.effects.push(PlayerEffect::StreamRebuilt {
            position: r.position,
            paused: r.paused,
            reason: r.reason.log_text(),
        });
    }

    fn close(&self, l: &mut Live, now: f64) {
        if l.closed {
            return;
        }
        l.closed = true;
        l.stage = l.stage.reduce(StageEvent::Closed);
        l.surface = l.surface.reduce(SurfaceEvent::Closed);
        self.count_finished(l);
        if !l.switching {
            let seconds = l.snap.position;
            self.report(l, ReportKind::Stop, seconds);
            let cmds = l.state.intent(Intent::Stop {
                reset_display: true,
            });
            self.run(l, cmds, now);
        }
        l.effects.push(PlayerEffect::Close);
    }

    // MARK: Parts

    fn build(&self, l: &Live) -> Parts {
        let phase = if l.error.is_some() {
            Phase::Failed
        } else if l.ended {
            Phase::Ended
        } else if !l.snap.first_image_present {
            Phase::Loading
        } else if l.snap.running {
            Phase::Playing
        } else {
            Phase::Paused
        };
        let cues = l.state.active_cues();
        let transport = TransportPart {
            phase,
            position: l.snap.position,
            running: l.snap.running,
            leap: l.snap.leap.map(|j| j.target),
            duration: l.snap.duration,
            buffering: !l.snap.first_image_present && l.error.is_none(),
            tempo: l.state.tempo(),
            picture_shown: l.snap.first_image_present,
            chapter: ChapterBar::chapter_at(l.snap.position, &l.chapters).map(|c| c.name.clone()),
            hint: l.hint.clone(),
            error: l.error.clone(),
            failure: l.error.is_some().then_some(Failure::START),
            subtitle: cues.text,
            pip: l.state.pip(),
            small_window: l.state.pip().1.then_some(SMALL_WINDOW_TEXT),
        };
        let controls = ControlsPart {
            // In the small window the controls stay away (`!smallWindow` in the Swift screen).
            visible: l.controls && !l.state.pip().1,
            layer: l.open_layer,
            scrubbing: l.at_push,
            jump_display: l.chain.display(),
            preview: l.preview,
            sleep_minutes: l.sleep.map(|(m, _)| m),
            jump_seconds: (l.prefs.back_seconds, l.prefs.forward_seconds),
            quality: Self::quality_offered(l).then_some(Quality {
                direct_play: l.prefs.direct_play,
                limit: l.prefs.bitrate_limit,
            }),
            volume: l.extra.volume.percent(),
            muted: l.extra.volume.is_muted(),
        };
        let audio_index = l.state.audio_index();
        let sub_index = l.state.subtitle_index();
        let labels: &dyn LabelText = &*self.labels;
        let mut audio = Vec::new();
        let mut subtitles = Vec::new();
        for s in l.state.streams() {
            let Some(index) = s.index else { continue };
            match s.type_.as_deref() {
                Some("Audio") => audio.push(TrackRow {
                    index,
                    label: swiftly_playback::original_audio::label(
                        &track_label::audio(
                            s.language.as_deref(),
                            s.codec.as_deref(),
                            s.channels,
                            labels,
                        )
                        .unwrap_or_else(|| labels.unknown()),
                        s.language.as_deref(),
                        Some(s),
                        l.extra.original_language.as_deref(),
                        &labels.original_suffix(),
                    ),
                    selected: audio_index == Some(index),
                    forced: false,
                    file: false,
                    hearing_impaired: false,
                }),
                Some("Subtitle") => subtitles.push(TrackRow {
                    index,
                    label: track_label::subtitle(s, labels).unwrap_or_else(|| labels.unknown()),
                    selected: sub_index == index,
                    forced: s.is_forced == Some(true),
                    file: s.is_external == Some(true),
                    hearing_impaired: s.is_hearing_impaired == Some(true),
                }),
                _ => {}
            }
        }
        let tracks = TracksPart {
            audio,
            subtitles,
            subtitles_off: sub_index < 0,
            audio_delay_ms: l.audio_delay.milliseconds(),
            subtitle_delay_ms: l.sub_delay.milliseconds(),
        };
        let view = match l.layer.display() {
            // Nothing is offered over the small window (`offering.visible ... !smallWindow`).
            _ if l.state.pip().1 => OfferView::Hidden,
            OfferingPresentation::Nothing => OfferView::Hidden,
            OfferingPresentation::Button(b) => OfferView::Button {
                label: b.label(),
                next_episode: b == ButtonOffering::NextEpisode,
                countdown: l.layer.skip_share(),
            },
            OfferingPresentation::Card { share } => OfferView::Card {
                title: l
                    .spec
                    .next
                    .as_ref()
                    .map(|n| n.title.clone())
                    .unwrap_or_default(),
                share,
                seconds_left: l.layer.countdown_rest(),
            },
        };
        Parts {
            transport,
            controls,
            tracks,
            offer: OfferPart { view },
        }
    }
}

impl Live {
    fn new(spec: PlayerSpec, prefs: PlayerPrefs, now: f64) -> Self {
        let state = new_state(&spec);
        Self {
            tracks: TrackIndices {
                audio: spec.audio_index,
                subtitle: Some(spec.subtitle_index),
            },
            spec,
            state,
            snap: Snapshot::default(),
            layer: OfferingLayer::new(),
            prefs,
            sections: Vec::new(),
            chapters: Vec::new(),
            trickplay: None,
            group: None,
            opened: now,
            ended: false,
            has_audio_tracks: false,
            at_push: false,
            restoring: false,
            stage: PlayerStage::Opening,
            next_card: NextCard::Hidden,
            surface: Surface::Inline,
            last_pushed: 0.0,
            preview: None,
            controls: true,
            hide_at: None,
            open_layer: None,
            chain: SeekChain::None,
            controls_state: Controls::Hidden,
            sleep: None,
            watchdog: None,
            paused_since: None,
            reported_paused: false,
            hint: None,
            error: None,
            prepared: false,
            switching: false,
            closed: false,
            effects: Vec::new(),
            parts: None,
            audio_delay: Delay::from_milliseconds(0),
            sub_delay: Delay::from_milliseconds(0),
            memory: None,
            after: None,
            quality_switched: false,
            extra: PlayerExtra::default(),
        }
    }

    fn expire(&mut self, now: f64) {
        self.chain = self.chain.reduce(ChainEvent::Tick { now });
    }
}
