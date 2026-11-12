//! Hardware or software decoder, and the audio output switches of the desktop player
//! (`Player.swift:179` `hwdec`, `Player.passthrough(spdif:exclusive:)`).
//!
//! The rule itself is [`crate::playback_plan::PlaybackPlan::software_decoder`] (XviD/DivX that
//! arrives unchanged); this module turns it into the engine option and holds the audio output
//! mode a host applies before a load ("prepared as switches, effective from the next title").

use crate::first_frame::software_from_start;
use swiftly_model::DeliveryMethod;

/// mpv option value for the hardware decoder when it is allowed (`auto-safe`).
pub const HWDEC_AUTO: &str = "auto-safe";
/// mpv option value for the software decoder (`no`).
pub const HWDEC_SOFTWARE: &str = "no";

/// The `hwdec` option for a load: software when the plan asks for it, else `auto-safe`.
pub fn hwdec_option(software_decoder: bool) -> &'static str {
    if software_decoder {
        HWDEC_SOFTWARE
    } else {
        HWDEC_AUTO
    }
}

/// The `hwdec` option for a source codec and delivery method, straight from the plan rule.
pub fn hwdec_for(video_codec: Option<&str>, method: DeliveryMethod) -> &'static str {
    hwdec_option(software_from_start(video_codec, method))
}

/// Audio output mode: S/PDIF passthrough codecs and exclusive device access (WASAPI). Off by
/// default; takes effect from the next title.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AudioOutputMode {
    /// Comma list of codecs sent as they are (`ac3,eac3,dts,dts-hd,truehd`), `None` for none.
    pub spdif_codecs: Option<String>,
    /// Open the device exclusively.
    pub exclusive: bool,
}

impl AudioOutputMode {
    /// The two engine options (`audio-spdif`, `audio-exclusive`) in the order the Swift sets them.
    pub fn options(&self) -> [(&'static str, String); 2] {
        [
            ("audio-spdif", self.spdif_codecs.clone().unwrap_or_default()),
            (
                "audio-exclusive",
                if self.exclusive { "yes" } else { "no" }.to_owned(),
            ),
        ]
    }

    /// Passthrough is on.
    pub fn passes_through(&self) -> bool {
        self.spdif_codecs.as_deref().is_some_and(|c| !c.is_empty())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hardware_decoding_is_the_default() {
        assert_eq!(hwdec_option(false), "auto-safe");
        assert_eq!(
            hwdec_for(Some("hevc"), DeliveryMethod::DirectPlay),
            "auto-safe"
        );
        assert_eq!(hwdec_for(None, DeliveryMethod::DirectPlay), "auto-safe");
    }

    #[test]
    fn mpeg4_part_two_in_a_plain_stream_decodes_in_software() {
        assert_eq!(hwdec_for(Some("mpeg4"), DeliveryMethod::DirectPlay), "no");
        assert_eq!(hwdec_for(Some("MPEG4"), DeliveryMethod::DirectStream), "no");
    }

    #[test]
    fn a_transcode_comes_as_h264_and_stays_on_the_hardware_decoder() {
        assert_eq!(
            hwdec_for(Some("mpeg4"), DeliveryMethod::Transcode),
            "auto-safe"
        );
    }

    #[test]
    fn audio_output_is_off_by_default_and_options_follow_the_swift_order() {
        let off = AudioOutputMode::default();
        assert!(!off.passes_through());
        assert_eq!(
            off.options(),
            [
                ("audio-spdif", String::new()),
                ("audio-exclusive", "no".to_owned())
            ]
        );
        let on = AudioOutputMode {
            spdif_codecs: Some("ac3,eac3".into()),
            exclusive: true,
        };
        assert!(on.passes_through());
        assert_eq!(
            on.options(),
            [
                ("audio-spdif", "ac3,eac3".to_owned()),
                ("audio-exclusive", "yes".to_owned())
            ]
        );
    }
}
