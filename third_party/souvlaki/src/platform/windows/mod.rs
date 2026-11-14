#![cfg(target_os = "windows")]

use std::sync::{Arc, Mutex};
use std::time::Duration;
use windows::Foundation::{TimeSpan, TypedEventHandler, Uri};
use windows::Media::*;
use windows::Storage::Streams::RandomAccessStreamReference;
use windows::Win32::Foundation::HWND;
use windows::Win32::System::WinRT::ISystemMediaTransportControlsInterop;
use windows::core::{Error as WindowsError, HSTRING};

use crate::{
    MediaControlEvent, MediaMetadata, MediaPlayback, MediaPosition, PlatformConfig, SeekDirection,
};

/// A handle to OS media controls.
pub struct MediaControls {
    controls: SystemMediaTransportControls,
    button_handler_token: Option<i64>,
    display_updater: SystemMediaTransportControlsDisplayUpdater,
    timeline_properties: SystemMediaTransportControlsTimelineProperties,
}

#[repr(i32)]
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
enum SmtcPlayback {
    Stopped = 2,
    Playing = 3,
    Paused = 4,
}

/// A platform-specific error.
#[derive(Debug)]
pub struct Error(WindowsError);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> Result<(), std::fmt::Error> {
        self.0.fmt(f)
    }
}

impl std::error::Error for Error {}

impl From<WindowsError> for Error {
    fn from(other: WindowsError) -> Error {
        Error(other)
    }
}

impl MediaControls {
    /// Create media controls with the specified config.
    pub fn new(config: PlatformConfig) -> Result<Self, Error> {
        let interop: ISystemMediaTransportControlsInterop = windows::core::factory::<
            SystemMediaTransportControls,
            ISystemMediaTransportControlsInterop,
        >()?;
        let hwnd = config
            .hwnd
            .expect("Windows media controls require an HWND in MediaControlsOptions.");

        let controls: SystemMediaTransportControls = unsafe { interop.GetForWindow(HWND(hwnd)) }?;
        let display_updater = controls.DisplayUpdater()?;
        let timeline_properties = SystemMediaTransportControlsTimelineProperties::new()?;

        Ok(Self {
            controls,
            display_updater,
            timeline_properties,
            button_handler_token: None,
        })
    }

    /// Attach the media control events to a handler.
    pub fn attach<F>(&mut self, event_handler: F) -> Result<(), Error>
    where
        F: Fn(MediaControlEvent) + Send + 'static,
    {
        self.controls.SetIsEnabled(true)?;
        self.controls.SetIsPlayEnabled(true)?;
        self.controls.SetIsPauseEnabled(true)?;
        self.controls.SetIsStopEnabled(true)?;
        // Next and Previous follow the queue (`set_navigation`); they start off.
        self.controls.SetIsNextEnabled(false)?;
        self.controls.SetIsPreviousEnabled(false)?;
        self.controls.SetIsFastForwardEnabled(true)?;
        self.controls.SetIsRewindEnabled(true)?;

        // TODO: allow changing this
        self.display_updater.SetType(MediaPlaybackType::Music)?;

        let event_handler = Arc::new(Mutex::new(event_handler));

        let button_handler = TypedEventHandler::new({
            let event_handler = event_handler.clone();

            move |_,
                  args: windows::core::Ref<
                '_,
                SystemMediaTransportControlsButtonPressedEventArgs,
            >| {
                let args = args.ok()?;
                let button = args.Button()?;

                let event = if button == SystemMediaTransportControlsButton::Play {
                    MediaControlEvent::Play
                } else if button == SystemMediaTransportControlsButton::Pause {
                    MediaControlEvent::Pause
                } else if button == SystemMediaTransportControlsButton::Stop {
                    MediaControlEvent::Stop
                } else if button == SystemMediaTransportControlsButton::Next {
                    MediaControlEvent::Next
                } else if button == SystemMediaTransportControlsButton::Previous {
                    MediaControlEvent::Previous
                } else if button == SystemMediaTransportControlsButton::FastForward {
                    MediaControlEvent::Seek(SeekDirection::Forward)
                } else if button == SystemMediaTransportControlsButton::Rewind {
                    MediaControlEvent::Seek(SeekDirection::Backward)
                } else {
                    // Ignore unknown events
                    return Ok(());
                };

                (event_handler.lock().unwrap())(event);
                Ok(())
            }
        });
        self.button_handler_token = Some(self.controls.ButtonPressed(&button_handler)?);

        let position_handler = TypedEventHandler::new({
            let event_handler = event_handler.clone();
            move |_, args: windows::core::Ref<'_, PlaybackPositionChangeRequestedEventArgs>| {
                let args = args.ok()?;
                let position = Duration::from(args.RequestedPlaybackPosition()?);

                (event_handler.lock().unwrap())(MediaControlEvent::SetPosition(MediaPosition(
                    position,
                )));
                Ok(())
            }
        });
        self.controls
            .PlaybackPositionChangeRequested(&position_handler)?;

        let rate_handler = TypedEventHandler::new({
            let event_handler = event_handler.clone();
            move |_, args: windows::core::Ref<'_, PlaybackRateChangeRequestedEventArgs>| {
                let args = args.ok()?;
                (event_handler.lock().unwrap())(MediaControlEvent::SetRate(
                    args.RequestedPlaybackRate()?,
                ));
                Ok(())
            }
        });
        self.controls.PlaybackRateChangeRequested(&rate_handler)?;

        Ok(())
    }

    /// Detach the event handler.
    pub fn detach(&mut self) -> Result<(), Error> {
        self.controls.SetIsEnabled(false)?;
        if let Some(button_handler_token) = self.button_handler_token {
            self.controls.RemoveButtonPressed(button_handler_token)?;
        }
        Ok(())
    }

    /// Set the current playback status.
    pub fn set_playback(&mut self, playback: MediaPlayback) -> Result<(), Error> {
        let status = match playback {
            MediaPlayback::Playing { .. } => SmtcPlayback::Playing as i32,
            MediaPlayback::Paused { .. } => SmtcPlayback::Paused as i32,
            MediaPlayback::Stopped => SmtcPlayback::Stopped as i32,
        };
        self.controls
            .SetPlaybackStatus(MediaPlaybackStatus(status))?;

        let progress = match playback {
            MediaPlayback::Playing {
                progress: Some(progress),
            }
            | MediaPlayback::Paused {
                progress: Some(progress),
            } => TimeSpan::from(progress.0),
            _ => TimeSpan::default(),
        };
        self.timeline_properties.SetPosition(progress)?;

        self.controls
            .UpdateTimelineProperties(&self.timeline_properties)?;
        Ok(())
    }

    /// Set the playback rate (1.0 is normal speed): SMTC `PlaybackRate`.
    pub fn set_rate(&mut self, rate: f64) -> Result<(), Error> {
        if rate.is_finite() && rate > 0.0 {
            self.controls.SetPlaybackRate(rate)?;
        }
        Ok(())
    }

    /// Enable or disable the system's "next" and "previous" buttons (SMTC `IsNextEnabled` and `IsPreviousEnabled`). They start disabled: a player that has
    /// no queue must not show buttons that do nothing.
    pub fn set_navigation(&mut self, next: bool, previous: bool) -> Result<(), Error> {
        self.controls.SetIsNextEnabled(next)?;
        self.controls.SetIsPreviousEnabled(previous)?;
        Ok(())
    }

    /// The rates the player accepts. SMTC has no range property: nothing to do on Windows.
    pub fn set_rate_range(&mut self, _min: f64, _max: f64) -> Result<(), Error> {
        Ok(())
    }

    /// Set the metadata of the currently playing media item.
    pub fn set_metadata(&mut self, metadata: MediaMetadata) -> Result<(), Error> {
        // The card is replaced as a whole: a field the new title has not got (the episode code of a film, the cover)
        // must not keep the previous title's value, and "no metadata at all" (nothing plays) clears the card.
        self.display_updater.ClearAll()?;
        self.display_updater.SetType(MediaPlaybackType::Music)?;
        let properties = self.display_updater.MusicProperties()?;

        if let Some(title) = metadata.title {
            properties.SetTitle(&HSTRING::from(title))?;
        }
        if let Some(artist) = metadata.artist {
            properties.SetArtist(&HSTRING::from(artist))?;
        }
        if let Some(album) = metadata.album {
            properties.SetAlbumTitle(&HSTRING::from(album))?;
        }
        if let Some(url) = metadata.cover_url {
            // A cover that cannot be read leaves the card without a picture; it does not drop the rest of the card.
            let stream = if url.starts_with("file://") {
                // url is a file, load it manually; the storage API wants `C:\dir\name`, not the address.
                let path = crate::file_url_to_windows_path(&url);
                windows::Storage::StorageFile::GetFileFromPathAsync(&HSTRING::from(path))
                    .and_then(|loader| {
                        let results = loader.join();
                        let _ = loader.Close();
                        results
                    })
                    .and_then(|file| RandomAccessStreamReference::CreateFromFile(&file))
            } else {
                Uri::CreateUri(&HSTRING::from(url)).and_then(|u| RandomAccessStreamReference::CreateFromUri(&u))
            };
            if let Ok(stream) = stream {
                self.display_updater.SetThumbnail(&stream)?;
            }
        }
        let duration = metadata.duration.unwrap_or_default();
        self.timeline_properties.SetStartTime(TimeSpan::default())?;
        self.timeline_properties
            .SetMinSeekTime(TimeSpan::default())?;
        self.timeline_properties
            .SetEndTime(TimeSpan::from(duration))?;
        self.timeline_properties
            .SetMaxSeekTime(TimeSpan::from(duration))?;

        self.controls
            .UpdateTimelineProperties(&self.timeline_properties)?;
        self.display_updater.Update()?;
        Ok(())
    }
}
