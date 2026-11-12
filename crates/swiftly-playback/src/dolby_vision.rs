//! **AV1 Dolby Vision profile 10.0** (IPT-PQ-c2, no HDR10 base layer under the picture).
//!
//! Only a player that applies the Dolby Vision metadata shows it right. AVPlayer on the
//! iPhone reads it as plain HDR10 (green picture, measured), ExoPlayer falls back to a plain AV1
//! decoder without a Dolby Vision one, and libmpv's render API (classic renderer, no
//! libplacebo reshaping) does not apply the metadata. Profiles 10.1 and 10.4 have a base layer
//! and are fine. So where the device cannot show it, the server is asked for a transcode of the
//! title instead (tone-mapped HEVC or H.264); the answer is read by [`crate::playback_plan`]
//! like any transcode. Mirrors `MediaSource.isAV1DolbyVisionWithoutBaseLayer` (Models.swift).

use swiftly_model::MediaSource;

use crate::device_profile::Flavour;

/// Whether the source is AV1 Dolby Vision profile 10 with base-layer compatibility id 0 (or
/// none given), the one variant with no HDR10 fallback picture.
pub fn is_av1_dolby_vision_without_base_layer(source: &MediaSource) -> bool {
    let Some(video) = source.video_track() else {
        return false;
    };
    video
        .codec
        .as_deref()
        .is_some_and(|c| c.eq_ignore_ascii_case("av1"))
        && video.dv_profile() == Some(10)
        && video.dv_bl_signal_compatibility_id().unwrap_or(0) == 0
}

/// Whether the engine of this flavour shows AV1 Dolby Vision 10.0 correctly.
///
/// Only the Apple engine (Aether) does, and only on a device with hardware AV1 decode (M3 and newer Mac, A17 Pro
/// and newer iPhone/iPad): without it (M1/M2, older phones) it decodes in software and refuses the title ("no
/// compatible base layer ... software playback path", measured by the playback bench on an M1 Max). AVPlayer
/// (AirPlay, PiP) reads it as HDR10 (green picture), Android (Media3 without a DV decoder) and the desktop (mpv
/// render API) show it wrong whatever the hardware. `hardware_av1` is what the host reports
/// (`VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` on Apple); a host that does not know says `false`.
pub fn device_shows_av1_dolby_vision_10(flavour: Flavour, hardware_av1: bool) -> bool {
    hardware_av1 && flavour == Flavour::Aether
}

/// What the host reports about the decoders of the device (a host that does not know leaves the default).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct HostDecoders {
    /// The device decodes AV1 in hardware (see [`device_shows_av1_dolby_vision_10`]).
    pub hardware_av1: bool,
    /// The device has no Dolby Vision decoder at all (an emulator, many TVs): profile 5 has no HDR10 base layer to fall
    /// back to, so the server must transcode it.
    pub no_dolby_vision: bool,
}

impl HostDecoders {
    /// Only the AV1 hardware answer is known.
    pub fn av1(hardware_av1: bool) -> Self {
        Self {
            hardware_av1,
            no_dolby_vision: false,
        }
    }
}

/// Whether the source is Dolby Vision profile 5 (IPT-PQ-c2 HEVC, no HDR10 base layer under the picture).
pub fn is_dolby_vision_5(source: &MediaSource) -> bool {
    source
        .video_track()
        .is_some_and(|v| v.dv_profile() == Some(5))
}

/// Whether this source must not be delivered untouched to this device: ask the server for a
/// transcode.
pub fn needs_server_transcode(source: &MediaSource, flavour: Flavour, host: HostDecoders) -> bool {
    (is_av1_dolby_vision_without_base_layer(source)
        && !device_shows_av1_dolby_vision_10(flavour, host.hardware_av1))
        || (host.no_dolby_vision && is_dolby_vision_5(source))
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_model::MediaStream;

    fn source(codec: &str, profile: Option<i64>, compat: Option<i64>) -> MediaSource {
        let mut stream = MediaStream::default().with_dolby_vision(profile, compat);
        stream.type_ = Some("Video".into());
        stream.codec = Some(codec.into());
        MediaSource {
            media_streams: Some(vec![stream]),
            ..MediaSource::default()
        }
    }

    #[test]
    fn only_av1_profile_10_without_base_layer() {
        assert!(is_av1_dolby_vision_without_base_layer(&source(
            "av1",
            Some(10),
            Some(0)
        )));
        assert!(is_av1_dolby_vision_without_base_layer(&source(
            "AV1",
            Some(10),
            None
        )));
        assert!(!is_av1_dolby_vision_without_base_layer(&source(
            "av1",
            Some(10),
            Some(1)
        )));
        assert!(!is_av1_dolby_vision_without_base_layer(&source(
            "av1",
            Some(10),
            Some(4)
        )));
        assert!(!is_av1_dolby_vision_without_base_layer(&source(
            "hevc",
            Some(5),
            Some(0)
        )));
        assert!(!is_av1_dolby_vision_without_base_layer(&source(
            "hevc",
            Some(8),
            Some(1)
        )));
        assert!(!is_av1_dolby_vision_without_base_layer(&source(
            "av1", None, None
        )));
        assert!(!is_av1_dolby_vision_without_base_layer(
            &MediaSource::default()
        ));
    }

    #[test]
    fn transcode_unless_the_apple_engine_has_hardware_av1() {
        let s = source("av1", Some(10), Some(0));
        // No hardware AV1 (M1/M2 Mac, older iPhone) or an unknown host: always transcode.
        for flavour in [
            Flavour::Aether,
            Flavour::Media3,
            Flavour::Mpv,
            Flavour::AirPlay { av1: true },
            Flavour::AirPlay { av1: false },
        ] {
            assert!(
                needs_server_transcode(&s, flavour, HostDecoders::av1(false)),
                "{flavour:?}"
            );
        }
        // Hardware AV1 (M3+, A17 Pro+): the Apple engine direct-plays it.
        assert!(!needs_server_transcode(
            &s,
            Flavour::Aether,
            HostDecoders::av1(true)
        ));
        // The other engines show it wrong whatever the hardware says.
        for flavour in [
            Flavour::Media3,
            Flavour::Mpv,
            Flavour::AirPlay { av1: true },
            Flavour::AirPlay { av1: false },
        ] {
            assert!(
                needs_server_transcode(&s, flavour, HostDecoders::av1(true)),
                "{flavour:?}"
            );
        }
        // Any other title is never touched.
        let other = source("hevc", Some(8), Some(1));
        assert!(!needs_server_transcode(
            &other,
            Flavour::Aether,
            HostDecoders::av1(false)
        ));
    }

    #[test]
    fn dolby_vision_5_is_transcoded_only_without_a_dolby_vision_decoder() {
        let five = source("hevc", Some(5), Some(0));
        let none = HostDecoders {
            hardware_av1: false,
            no_dolby_vision: true,
        };
        for flavour in [Flavour::Media3, Flavour::Aether, Flavour::Mpv] {
            assert!(needs_server_transcode(&five, flavour, none), "{flavour:?}");
            assert!(
                !needs_server_transcode(&five, flavour, HostDecoders::default()),
                "{flavour:?}"
            );
        }
        // The base layer of profile 8 is plain HEVC: it never needs a transcode for want of a decoder.
        assert!(!needs_server_transcode(
            &source("hevc", Some(8), Some(1)),
            Flavour::Media3,
            none
        ));
        assert!(!needs_server_transcode(
            &source("hevc", None, None),
            Flavour::Media3,
            none
        ));
    }
}
