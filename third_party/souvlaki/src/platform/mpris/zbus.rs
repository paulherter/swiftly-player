use std::collections::HashMap;
use std::convert::From;
use std::convert::TryFrom;
use std::convert::TryInto;
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use zbus::connection;
use zbus::interface;
use zbus::object_server::SignalEmitter;
use zvariant::{ObjectPath, Value};

use crate::{
    MediaControlEvent, MediaMetadata, MediaPlayback, MediaPosition, PlatformConfig, SeekDirection,
};

use super::Error;

/// A handle to OS media controls.
pub struct MediaControls {
    thread: Option<ServiceThreadHandle>,
    dbus_name: String,
    friendly_name: String,
}

struct ServiceThreadHandle {
    event_channel: mpsc::Sender<InternalEvent>,
    thread: JoinHandle<()>,
}

#[derive(Clone, PartialEq, Debug)]
enum InternalEvent {
    ChangeMetadata(OwnedMetadata),
    ChangePlayback(MediaPlayback),
    ChangeVolume(f64),
    ChangeRate(f64),
    ChangeRateRange(f64, f64),
    ChangeNavigation { next: bool, previous: bool },
    Kill,
}

#[derive(Clone, Debug)]
struct ServiceState {
    metadata: OwnedMetadata,
    playback_status: MediaPlayback,
    volume: f64,
    rate: f64,
    min_rate: f64,
    max_rate: f64,
    can_next: bool,
    can_previous: bool,
}

#[derive(Clone, PartialEq, Eq, Debug, Default)]
struct OwnedMetadata {
    pub title: Option<String>,
    pub album: Option<String>,
    pub artist: Option<String>,
    pub cover_url: Option<String>,
    pub duration: Option<i64>,
    pub track_id: Option<String>,
}

impl From<MediaMetadata<'_>> for OwnedMetadata {
    fn from(other: MediaMetadata) -> Self {
        OwnedMetadata {
            title: other.title.map(|s| s.to_string()),
            artist: other.artist.map(|s| s.to_string()),
            album: other.album.map(|s| s.to_string()),
            cover_url: other.cover_url.map(|s| s.to_string()),
            duration: other.duration.map(|d| d.as_micros().try_into().unwrap()),
            track_id: other.track_id.map(|s| s.to_string()),
        }
    }
}

impl MediaControls {
    /// Create media controls with the specified config.
    pub fn new(config: PlatformConfig) -> Result<Self, Error> {
        let PlatformConfig {
            dbus_name,
            display_name,
            ..
        } = config;

        Ok(Self {
            thread: None,
            dbus_name: dbus_name.to_string(),
            friendly_name: display_name.to_string(),
        })
    }

    /// Attach the media control events to a handler.
    pub fn attach<F>(&mut self, event_handler: F) -> Result<(), Error>
    where
        F: Fn(MediaControlEvent) + Send + 'static,
    {
        self.detach()?;

        let dbus_name = self.dbus_name.clone();
        let friendly_name = self.friendly_name.clone();
        let event_handler = Arc::new(Mutex::new(event_handler));
        let (event_channel, rx) = mpsc::channel();

        self.thread = Some(ServiceThreadHandle {
            event_channel,
            thread: thread::spawn(move || {
                pollster::block_on(run_service(dbus_name, friendly_name, event_handler, rx))
                    .unwrap();
            }),
        });
        Ok(())
    }
    /// Detach the event handler.
    pub fn detach(&mut self) -> Result<(), Error> {
        if let Some(ServiceThreadHandle {
            event_channel,
            thread,
        }) = self.thread.take()
        {
            event_channel.send(InternalEvent::Kill).ok();
            thread.join().map_err(|_| Error::ThreadPanicked)?;
        }
        Ok(())
    }

    /// Set the current playback status.
    pub fn set_playback(&mut self, playback: MediaPlayback) -> Result<(), Error> {
        self.send_internal_event(InternalEvent::ChangePlayback(playback))?;
        Ok(())
    }

    /// Set the metadata of the currently playing media item.
    pub fn set_metadata(&mut self, metadata: MediaMetadata) -> Result<(), Error> {
        self.send_internal_event(InternalEvent::ChangeMetadata(metadata.into()))?;
        Ok(())
    }

    /// Set the volume level (0.0 - 1.0) (Only available on MPRIS)
    pub fn set_volume(&mut self, volume: f64) -> Result<(), Error> {
        self.send_internal_event(InternalEvent::ChangeVolume(volume))?;
        Ok(())
    }

    /// Set the playback rate (1.0 is normal speed): the MPRIS `Rate` property. Out-of-range and non-finite values are
    /// ignored.
    pub fn set_rate(&mut self, rate: f64) -> Result<(), Error> {
        self.send_internal_event(InternalEvent::ChangeRate(rate))?;
        Ok(())
    }

    /// Set the rates the player accepts: the MPRIS `MinimumRate` and `MaximumRate` properties.
    pub fn set_rate_range(&mut self, min: f64, max: f64) -> Result<(), Error> {
        self.send_internal_event(InternalEvent::ChangeRateRange(min, max))?;
        Ok(())
    }

    /// Enable or disable the system's "next" and "previous" buttons (MPRIS `CanGoNext` and `CanGoPrevious`). They start disabled: a player that has
    /// no queue must not show buttons that do nothing.
    pub fn set_navigation(&mut self, next: bool, previous: bool) -> Result<(), Error> {
        self.send_internal_event(InternalEvent::ChangeNavigation { next, previous })?;
        Ok(())
    }

    fn send_internal_event(&mut self, event: InternalEvent) -> Result<(), Error> {
        let channel = &self
            .thread
            .as_ref()
            .ok_or(Error::ThreadNotRunning)?
            .event_channel;
        channel.send(event).map_err(|_| Error::ThreadPanicked)
    }
}

struct AppInterface {
    friendly_name: String,
    event_handler: Arc<Mutex<dyn Fn(MediaControlEvent) + Send + 'static>>,
}

#[interface(name = "org.mpris.MediaPlayer2")]
impl AppInterface {
    fn raise(&self) {
        self.send_event(MediaControlEvent::Raise);
    }
    fn quit(&self) {
        self.send_event(MediaControlEvent::Quit);
    }

    #[zbus(property)]
    fn can_quit(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_raise(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn has_tracklist(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn identity(&self) -> &str {
        &self.friendly_name
    }

    #[zbus(property)]
    fn supported_uri_schemes(&self) -> &[&str] {
        &[]
    }

    #[zbus(property)]
    fn supported_mime_types(&self) -> &[&str] {
        &[]
    }
}

impl AppInterface {
    fn send_event(&self, event: MediaControlEvent) {
        (self.event_handler.lock().unwrap())(event);
    }
}

struct PlayerInterface {
    state: ServiceState,
    event_handler: Arc<Mutex<dyn Fn(MediaControlEvent) + Send + 'static>>,
}

impl PlayerInterface {
    fn send_event(&self, event: MediaControlEvent) {
        (self.event_handler.lock().unwrap())(event);
    }
}

#[interface(name = "org.mpris.MediaPlayer2.Player")]
impl PlayerInterface {
    fn next(&self) {
        self.send_event(MediaControlEvent::Next);
    }
    fn previous(&self) {
        self.send_event(MediaControlEvent::Previous);
    }
    fn pause(&self) {
        self.send_event(MediaControlEvent::Pause);
    }
    fn play_pause(&self) {
        self.send_event(MediaControlEvent::Toggle);
    }
    fn stop(&self) {
        self.send_event(MediaControlEvent::Stop);
    }
    fn play(&self) {
        self.send_event(MediaControlEvent::Play);
    }

    fn seek(&self, offset: i64) {
        let abs_offset = offset.unsigned_abs();
        let direction = if offset > 0 {
            SeekDirection::Forward
        } else {
            SeekDirection::Backward
        };

        self.send_event(MediaControlEvent::SeekBy(
            direction,
            Duration::from_micros(abs_offset),
        ));

        // NOTE: Should the `Seeked` signal be called when calling this method?
    }

    fn set_position(&self, _track_id: zvariant::ObjectPath, position: i64) {
        if let Ok(micros) = position.try_into() {
            if let Some(duration) = self.state.metadata.duration {
                // If the Position argument is greater than the track length, do nothing.
                if position > duration {
                    return;
                }
            }

            let position = Duration::from_micros(micros);
            self.send_event(MediaControlEvent::SetPosition(MediaPosition(position)));
        }
    }

    fn open_uri(&self, uri: String) {
        // NOTE: we should check if the URI is in the `SupportedUriSchemes` list.
        self.send_event(MediaControlEvent::OpenUri(uri));
    }

    #[zbus(property)]
    fn playback_status(&self) -> &'static str {
        match self.state.playback_status {
            MediaPlayback::Playing { .. } => "Playing",
            MediaPlayback::Paused { .. } => "Paused",
            MediaPlayback::Stopped => "Stopped",
        }
    }

    #[zbus(property)]
    fn rate(&self) -> f64 {
        self.state.rate
    }

    #[zbus(property)]
    fn set_rate(&mut self, rate: f64) {
        // The clients ask; the player answers with `MediaControls::set_rate`, which publishes the new value.
        if rate.is_finite() {
            self.send_event(MediaControlEvent::SetRate(rate));
        }
    }

    #[zbus(property)]
    fn metadata(&self) -> HashMap<&str, Value<'_>> {
        // TODO: this should be stored in a cache inside the state.
        let mut dict = HashMap::<&str, Value>::new();

        let OwnedMetadata {
            ref title,
            ref album,
            ref artist,
            ref cover_url,
            ref duration,
            ref track_id,
        } = self.state.metadata;

        // MPRIS
        dict.insert(
            "mpris:trackid",
            // A real object path per track (the spec forbids "/"); the app names it, else the spec's "no track" path.
            Value::new(
                track_id
                    .as_deref()
                    .and_then(|p| ObjectPath::try_from(p.to_owned()).ok())
                    .unwrap_or_else(|| {
                        ObjectPath::try_from("/org/mpris/MediaPlayer2/TrackList/NoTrack").unwrap()
                    }),
            ),
        );

        if let Some(length) = duration {
            dict.insert("mpris:length", Value::new(*length));
        }

        if let Some(cover_url) = cover_url {
            dict.insert("mpris:artUrl", Value::new(cover_url.clone()));
        }

        // Xesam
        if let Some(title) = title {
            dict.insert("xesam:title", Value::new(title.clone()));
        }
        if let Some(artist) = artist {
            dict.insert("xesam:artist", Value::new(vec![artist.clone()]));
        }
        if let Some(album) = album {
            dict.insert("xesam:album", Value::new(album.clone()));
        }
        dict
    }

    #[zbus(property)]
    fn volume(&self) -> f64 {
        self.state.volume
    }

    #[zbus(property)]
    fn set_volume(&mut self, volume: f64) {
        self.state.volume = volume;
        self.send_event(MediaControlEvent::SetVolume(volume));
    }

    #[zbus(property)]
    fn position(&self) -> i64 {
        let position = match self.state.playback_status {
            MediaPlayback::Playing {
                progress: Some(pos),
            }
            | MediaPlayback::Paused {
                progress: Some(pos),
            } => pos.0.as_micros(),
            _ => 0,
        };

        position.try_into().unwrap_or(0)
    }

    #[zbus(property)]
    fn minimum_rate(&self) -> f64 {
        self.state.min_rate
    }

    #[zbus(property)]
    fn maximum_rate(&self) -> f64 {
        self.state.max_rate
    }

    #[zbus(property)]
    fn can_go_next(&self) -> bool {
        self.state.can_next
    }

    #[zbus(property)]
    fn can_go_previous(&self) -> bool {
        self.state.can_previous
    }

    #[zbus(property)]
    fn can_play(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_pause(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_seek(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_control(&self) -> bool {
        true
    }
}

async fn run_service(
    dbus_name: String,
    friendly_name: String,
    event_handler: Arc<Mutex<dyn Fn(MediaControlEvent) + Send + 'static>>,
    event_channel: mpsc::Receiver<InternalEvent>,
) -> zbus::Result<()> {
    let app = AppInterface {
        friendly_name,
        event_handler: event_handler.clone(),
    };

    let player = PlayerInterface {
        state: ServiceState {
            metadata: OwnedMetadata::default(),
            playback_status: MediaPlayback::Stopped,
            volume: 1.0,
            rate: 1.0,
            min_rate: 1.0,
            max_rate: 1.0,
            can_next: false,
            can_previous: false,
        },
        event_handler,
    };

    let name = format!("org.mpris.MediaPlayer2.{dbus_name}");
    let path = ObjectPath::try_from("/org/mpris/MediaPlayer2")?;
    let connection = connection::Builder::session()?
        .serve_at(&path, app)?
        .serve_at(&path, player)?
        .name(name.as_str())?
        .build()
        .await?;

    loop {
        if let Ok(event) = event_channel.recv_timeout(Duration::from_millis(10)) {
            if event == InternalEvent::Kill {
                break;
            }

            let interface_ref = connection
                .object_server()
                .interface::<_, PlayerInterface>(&path)
                .await?;
            let mut interface = interface_ref.get_mut().await;
            let ctxt = SignalEmitter::new(&connection, &path)?;

            match event {
                InternalEvent::ChangeMetadata(metadata) => {
                    interface.state.metadata = metadata;
                    interface.metadata_changed(&ctxt).await?;
                }
                InternalEvent::ChangePlayback(playback) => {
                    interface.state.playback_status = playback;
                    interface.playback_status_changed(&ctxt).await?;
                }
                InternalEvent::ChangeVolume(volume) => {
                    interface.state.volume = volume;
                    interface.volume_changed(&ctxt).await?;
                }
                InternalEvent::ChangeRate(rate) => {
                    if rate.is_finite() && rate > 0.0 {
                        interface.state.rate = rate;
                        interface.rate_changed(&ctxt).await?;
                    }
                }
                InternalEvent::ChangeRateRange(min, max) => {
                    if min.is_finite() && max.is_finite() && 0.0 < min && min <= max {
                        interface.state.min_rate = min;
                        interface.state.max_rate = max;
                        interface.minimum_rate_changed(&ctxt).await?;
                        interface.maximum_rate_changed(&ctxt).await?;
                    }
                }
                InternalEvent::ChangeNavigation { next, previous } => {
                    interface.state.can_next = next;
                    interface.state.can_previous = previous;
                    interface.can_go_next_changed(&ctxt).await?;
                    interface.can_go_previous_changed(&ctxt).await?;
                }
                InternalEvent::Kill => (),
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn player() -> PlayerInterface {
        PlayerInterface {
            state: ServiceState {
                metadata: OwnedMetadata::default(),
                playback_status: MediaPlayback::Stopped,
                volume: 1.0,
                rate: 1.0,
                min_rate: 1.0,
                max_rate: 1.0,
                can_next: false,
                can_previous: false,
            },
            event_handler: Arc::new(Mutex::new(|_| {})),
        }
    }

    #[test]
    fn the_navigation_properties_start_off_and_follow_the_state() {
        let mut p = player();
        assert!(!p.can_go_next() && !p.can_go_previous());
        p.state.can_next = true;
        assert!(p.can_go_next() && !p.can_go_previous());
    }

    #[test]
    fn the_rate_properties_report_the_state_and_a_client_write_becomes_an_event() {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&seen);
        let mut p = player();
        p.event_handler = Arc::new(Mutex::new(move |e| log.lock().unwrap().push(e)));
        assert_eq!((p.rate(), p.minimum_rate(), p.maximum_rate()), (1.0, 1.0, 1.0));
        p.state.rate = 1.5;
        p.state.min_rate = 0.75;
        p.state.max_rate = 2.0;
        assert_eq!((p.rate(), p.minimum_rate(), p.maximum_rate()), (1.5, 0.75, 2.0));
        // A client write does not change the reported rate by itself: the app answers with `set_rate`.
        p.set_rate(2.0);
        p.set_rate(f64::NAN);
        assert_eq!(p.rate(), 1.5);
        assert_eq!(*seen.lock().unwrap(), vec![MediaControlEvent::SetRate(2.0)]);
    }
}
