//! `EngineProbe`: a foreign trait shaped like the `PlaybackEngine` of ARCHITECTURE.md D4, and
//! `PlayerProbe`, the stand-in for `PlayerVm` that drives it from async code and receives the
//! engine's events.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use tokio::sync::mpsc;

use crate::core::Platform;
use crate::error::CoreError;

#[derive(uniffi::Record, Clone, Debug)]
pub struct EngineLoad {
    pub url: String,
    pub start_seconds: f64,
    pub audio_index: Option<i32>,
    pub subtitle_index: Option<i32>,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubtitleRoute {
    Cues,
    EngineDrawn,
    Unsupported,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum EngineState {
    Idle,
    Loading,
    Playing,
    Paused,
    Seeking,
    Ended,
    Error { message: String },
}

/// Driver -> core.
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum EngineEvent {
    State { state: EngineState },
    FirstFrame,
    Clock { position: f64 },
    Duration { seconds: f64 },
}

/// Core -> driver. Implemented in Swift (`AetherDriver`), Kotlin (`Media3Driver`).
#[uniffi::export(with_foreign)]
pub trait EngineProbe: Send + Sync {
    fn load(&self, request: EngineLoad);
    fn play(&self);
    fn pause(&self);
    fn seek(&self, seconds: f64);
    fn select_subtitle(&self, server_index: i32) -> SubtitleRoute;
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ProbeReport {
    /// Every event the script saw, in order, as short text.
    pub seen: Vec<String>,
    pub subtitle_route: SubtitleRoute,
    pub final_position: f64,
}

#[derive(uniffi::Object)]
pub struct PlayerProbe {
    engine: Arc<dyn EngineProbe>,
    platform: Arc<dyn Platform>,
    events: mpsc::UnboundedSender<EngineEvent>,
    inbox: Mutex<Option<mpsc::UnboundedReceiver<EngineEvent>>>,
}

impl PlayerProbe {
    pub(crate) fn new(engine: Arc<dyn EngineProbe>, platform: Arc<dyn Platform>) -> Arc<Self> {
        let (events, inbox) = mpsc::unbounded_channel();
        Arc::new(Self {
            engine,
            platform,
            events,
            inbox: Mutex::new(Some(inbox)),
        })
    }
}

/// Waits for an event the script needs. Longer than any test needs, short enough to fail.
const STEP_TIMEOUT: Duration = Duration::from_secs(5);

async fn wait_for(
    inbox: &mut mpsc::UnboundedReceiver<EngineEvent>,
    seen: &mut Vec<String>,
    mut done: impl FnMut(&EngineEvent) -> bool,
) -> bool {
    loop {
        match tokio::time::timeout(STEP_TIMEOUT, inbox.recv()).await {
            Ok(Some(event)) => {
                seen.push(format!("{event:?}"));
                if done(&event) {
                    return true;
                }
            }
            Ok(None) | Err(_) => return false,
        }
    }
}

#[uniffi::export]
impl PlayerProbe {
    /// Driver -> core. May be called from any thread, also from inside an engine call.
    pub fn engine_event(&self, event: EngineEvent) {
        // The receiver lives as long as this object; a closed channel only means "no script".
        let _ = self.events.send(event);
    }

    /// Plays a fixed script against the engine: load, play, seek, pick a subtitle, pause.
    /// The engine reports back through `engine_event`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn run_script(&self) -> Result<ProbeReport, CoreError> {
        let inbox = self
            .inbox
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        let Some(mut inbox) = inbox else {
            return Err(CoreError::Failed {
                message: "the script already ran".to_owned(),
            });
        };
        let mut seen = Vec::new();

        self.platform.log("probe: load".to_owned());
        self.engine.load(EngineLoad {
            url: "https://example.invalid/film.mkv".to_owned(),
            start_seconds: 0.0,
            audio_index: None,
            subtitle_index: Some(3),
        });
        let playing = EngineEvent::State {
            state: EngineState::Playing,
        };
        self.engine.play();
        wait_for(&mut inbox, &mut seen, |e| *e == playing).await;

        self.engine.seek(30.0);
        let mut final_position = 0.0;
        wait_for(&mut inbox, &mut seen, |e| match e {
            EngineEvent::Clock { position } if *position >= 30.0 => {
                final_position = *position;
                true
            }
            _ => false,
        })
        .await;

        let subtitle_route = self.engine.select_subtitle(3);
        self.engine.pause();
        let paused = EngineEvent::State {
            state: EngineState::Paused,
        };
        wait_for(&mut inbox, &mut seen, |e| *e == paused).await;
        self.platform.log("probe: done".to_owned());

        Ok(ProbeReport {
            seen,
            subtitle_route,
            final_position,
        })
    }
}
