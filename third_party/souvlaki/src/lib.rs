

mod config;
mod platform;

use std::{fmt::Debug, time::Duration};

pub use config::*;
pub use platform::{Error, MediaControls};

/// The local path a `file://` cover address stands for, in the form the Windows storage API takes (`C:\\dir\\name`):
/// the address of a drive path is `file:///C:/dir/name`, and the characters outside the plain set are percent-encoded.
#[cfg(any(windows, test))]
pub(crate) fn file_url_to_windows_path(url: &str) -> String {
    let rest = url.strip_prefix("file://").unwrap_or(url);
    let bytes = rest.as_bytes();
    let drive = bytes.len() > 2 && bytes[0] == b'/' && bytes[2] == b':';
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = usize::from(drive);
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2]))
        {
            out.push((h * 16 + l) as u8);
            i += 3;
            continue;
        }
        out.push(if bytes[i] == b'/' { b'\\' } else { bytes[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod file_url_tests {
    use super::file_url_to_windows_path as path;

    #[test]
    fn a_drive_address_becomes_a_windows_path() {
        assert_eq!(
            path("file:///C:/Users/Alex%20X/AppData/nowplaying-a_1.img"),
            "C:\\Users\\Alex X\\AppData\\nowplaying-a_1.img"
        );
    }

    #[test]
    fn a_share_address_keeps_its_host() {
        assert_eq!(path("file://server/share/a.img"), "server\\share\\a.img");
    }
}

/// The status of media playback.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum MediaPlayback {
    Stopped,
    Paused { progress: Option<MediaPosition> },
    Playing { progress: Option<MediaPosition> },
}

/// The metadata of a media item.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct MediaMetadata<'a> {
    pub title: Option<&'a str>,
    pub album: Option<&'a str>,
    pub artist: Option<&'a str>,
    /// Very platform specific. As of now, Souvlaki leaves it up to the user to change the URL depending on the platform.
    ///
    /// For Linux, we follow the MPRIS specification, which actually doesn't say much cover art apart from what's in [here](https://www.freedesktop.org/wiki/Specifications/mpris-spec/metadata/#mpris:arturl). It only says that local files should start with `file://` and that it should be an UTF-8 string, which is enforced by Rust. Maybe you can look in the source code of desktop managers such as GNOME or KDE, since these read the field to display it on their media player controls.
    ///
    /// For Windows, we use the _SystemMediaTransportControlsDisplayUpdater_, which has [a thumbnail property](https://learn.microsoft.com/en-us/uwp/api/windows.media.systemmediatransportcontrolsdisplayupdater.thumbnail?view=winrt-22621#windows-media-systemmediatransportcontrolsdisplayupdater-thumbnail). It accepts multiple formats, but we choose to create it using an URI. If setting an URL starting with `file://`, the file is automatically loaded by souvlaki.
    ///
    /// For MacOS, you can look into [these lines](https://github.com/Sinono3/souvlaki/blob/384539fe83e8bf5c966192ba28e9405e3253619b/src/platform/macos/mod.rs#L131-L137) of the implementation. These lines refer to creating an [MPMediaItemArtwork](https://developer.apple.com/documentation/mediaplayer/mpmediaitemartwork) object.
    pub cover_url: Option<&'a str>,
    pub duration: Option<Duration>,
    /// MPRIS only: the D-Bus object path that names this track (`mpris:trackid`), for example
    /// `/org/example/player/track/42`. Anything that is not a valid object path falls back to the spec's "no track" path.
    pub track_id: Option<&'a str>,
}

/// Events sent by the OS media controls.
#[derive(Clone, PartialEq, Debug)]
#[non_exhaustive]
pub enum MediaControlEvent {
    Play,
    Pause,
    Toggle,
    Next,
    Previous,
    Stop,

    /// Seek forward or backward by an undetermined amount.
    Seek(SeekDirection),
    /// Seek forward or backward by a certain amount.
    SeekBy(SeekDirection, Duration),
    /// Set the position/progress of the currently playing media item.
    SetPosition(MediaPosition),
    /// Sets the volume. The value is intended to be from 0.0 to 1.0.
    /// But other values are also accepted. **It is up to the user to
    /// set constraints on this value.**
    /// **NOTE**: If the volume event was received and correctly handled,
    /// the user must call [`MediaControls::set_volume`]. Note that
    /// this must be done only with the MPRIS backend.
    SetVolume(f64),
    /// The system asks for this playback rate (1.0 is normal speed).
    ///
    /// Publish the resulting rate with `MediaControls::set_rate` after handling the request.
    ///
    /// **NOTE**: emitted by the MPRIS (`Rate` property) and Windows (SMTC `PlaybackRateChangeRequested`) back ends.
    SetRate(f64),
    /// Turn shuffle on or off.
    ///
    /// Publish the resulting state with `MediaControls::set_shuffle`
    /// after handling the request.
    ///
    /// **NOTE**: currently only emitted on macOS/iOS
    SetShuffle(bool),
    /// Open the URI in the media player.
    OpenUri(String),

    /// Bring the media player's user interface to the front using any appropriate mechanism available.
    Raise,
    /// Shut down the media player.
    Quit,
}

/// An instant in a media item.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct MediaPosition(pub Duration);

/// The direction to seek in.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum SeekDirection {
    Forward,
    Backward,
}

impl Drop for MediaControls {
    fn drop(&mut self) {
        // Ignores errors if there are any.
        self.detach().ok();
    }
}

impl Debug for MediaControls {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("MediaControls")?;
        Ok(())
    }
}
