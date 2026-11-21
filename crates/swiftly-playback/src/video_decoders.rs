//! Which video the device can decode, as the host reports it.
//!
//! The engine profile ([`crate::device_profile`]) declares everything the engine can play, so
//! the server hands out the file untouched. That holds for the Apple engine (it decodes in
//! software when the chip cannot), not for Media3 on Android: it can only use the decoders
//! `MediaCodecList` knows, and a phone or an emulator without an AV1 or HEVC Main 10 decoder
//! fails at the first frame ("exceeds the codec's capabilities") and the player closes.
//!
//! The Android host asks `MediaCodecList` once and reports one entry per codec and bit depth
//! with the largest picture that decoder takes. [`VideoDecoders::lacks_decoder`] then says,
//! per source, that the device has no decoder for it; the plan
//! ([`crate::dolby_vision::needs_server_transcode`]) asks the server for a transcode instead of
//! the original, the same way it does for AV1 Dolby Vision 10.0. A host that reports nothing
//! ([`VideoDecoders::default`]) restricts nothing.

use swiftly_model::{MediaSource, MediaStream};

/// A codec the host reports decoders for (the ones whose decoders phones commonly lack).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Codec {
    Avc,
    Hevc,
    Av1,
    Vp9,
}

impl Codec {
    /// The codec of a server's codec name; `None` for every codec the host does not report.
    fn of(name: &str) -> Option<Self> {
        match name.to_ascii_lowercase().as_str() {
            "h264" | "avc" | "avc1" => Some(Self::Avc),
            "hevc" | "h265" | "hvc1" | "hev1" => Some(Self::Hevc),
            "av1" => Some(Self::Av1),
            "vp9" => Some(Self::Vp9),
            _ => None,
        }
    }

    fn slot(self, ten_bit: bool) -> usize {
        let codec = match self {
            Self::Avc => 0,
            Self::Hevc => 1,
            Self::Av1 => 2,
            Self::Vp9 => 3,
        };
        codec * 2 + usize::from(ten_bit)
    }
}

/// The largest picture a decoder takes (`0` x `0`: no decoder).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct Limit {
    width: u32,
    height: u32,
}

impl Limit {
    /// A decoder exists and takes the picture, whichever way round the limits are given.
    fn takes(self, width: i64, height: i64) -> bool {
        if self.width == 0 || self.height == 0 {
            return false;
        }
        let (long, short) = (width.max(height), width.min(height));
        long <= i64::from(self.width.max(self.height))
            && short <= i64::from(self.width.min(self.height))
    }
}

/// What the device decodes (see the module text). `Default`: the host does not know.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct VideoDecoders {
    known: bool,
    table: [Limit; 8],
}

impl VideoDecoders {
    /// A host that has asked its decoder list: nothing is decodable until [`Self::with`] adds it.
    pub fn probed() -> Self {
        Self {
            known: true,
            table: [Limit::default(); 8],
        }
    }

    /// Adds a decoder for `codec` (`h264`, `hevc`, `av1`, `vp9`; others are ignored) at 8 or 10
    /// bits that takes pictures up to `width` x `height`. A decoder for 10 bits takes 8 bits too.
    #[must_use]
    pub fn with(mut self, codec: &str, ten_bit: bool, width: u32, height: u32) -> Self {
        let Some(codec) = Codec::of(codec) else {
            return self;
        };
        let depths: &[bool] = if ten_bit { &[true, false] } else { &[false] };
        for &depth in depths {
            let slot = &mut self.table[codec.slot(depth)];
            slot.width = slot.width.max(width);
            slot.height = slot.height.max(height);
        }
        self
    }

    /// The host has reported its decoders.
    pub fn is_known(&self) -> bool {
        self.known
    }

    /// Whether the device has no decoder for the source's video: the codec at this bit depth is
    /// missing, or the picture is larger than the largest the decoder takes. `false` when the
    /// host did not report, for a source without video, and for a codec the host does not report.
    pub fn lacks_decoder(&self, source: &MediaSource) -> bool {
        if !self.known {
            return false;
        }
        let Some(video) = source.video_track() else {
            return false;
        };
        let Some(codec) = video.codec.as_deref().and_then(Codec::of) else {
            return false;
        };
        !self.table[codec.slot(is_ten_bit(video))]
            .takes(video.width.unwrap_or(0), video.height.unwrap_or(0))
    }
}

/// Whether the track carries more than 8 bits per channel: the server's bit depth, else its
/// profile name (`Main 10`, `High 10`), else an HDR range (which is 10 bits or more).
fn is_ten_bit(video: &MediaStream) -> bool {
    if let Some(depth) = video.bit_depth {
        return depth > 8;
    }
    if video.profile.as_deref().is_some_and(|p| p.contains("10")) {
        return true;
    }
    video.video_range_type().is_some_and(|r| r.is_hdr())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source(codec: &str, bit_depth: Option<i64>, width: i64, height: i64) -> MediaSource {
        let video = MediaStream {
            type_: Some("Video".into()),
            codec: Some(codec.into()),
            bit_depth,
            width: Some(width),
            height: Some(height),
            ..MediaStream::default()
        };
        let audio = MediaStream {
            type_: Some("Audio".into()),
            codec: Some("aac".into()),
            ..MediaStream::default()
        };
        MediaSource {
            media_streams: Some(vec![audio, video]),
            ..MediaSource::default()
        }
    }

    /// An emulator or a budget phone: H.264 and HEVC Main, no AV1, no Main 10.
    fn plain_device() -> VideoDecoders {
        VideoDecoders::probed()
            .with("h264", false, 4096, 2304)
            .with("hevc", false, 4096, 2304)
            .with("vp9", false, 4096, 2176)
    }

    /// A recent phone: everything in hardware.
    fn modern_device() -> VideoDecoders {
        VideoDecoders::probed()
            .with("h264", false, 4096, 2304)
            .with("hevc", true, 8192, 4320)
            .with("av1", true, 8192, 4320)
            .with("vp9", true, 4096, 2176)
    }

    #[test]
    fn a_host_that_reports_nothing_restricts_nothing() {
        let none = VideoDecoders::default();
        assert!(!none.is_known());
        for codec in ["h264", "hevc", "av1", "vp9", "mpeg4"] {
            assert!(!none.lacks_decoder(&source(codec, Some(10), 3840, 2160)));
        }
    }

    #[test]
    fn av1_needs_an_av1_decoder() {
        let av1 = source("av1", Some(8), 1920, 1080);
        assert!(plain_device().lacks_decoder(&av1));
        assert!(!modern_device().lacks_decoder(&av1));
    }

    #[test]
    fn hevc_main_10_needs_a_ten_bit_decoder_but_main_does_not() {
        let main10 = source("hevc", Some(10), 1920, 1080);
        let main = source("hevc", Some(8), 1920, 1080);
        assert!(plain_device().lacks_decoder(&main10));
        assert!(!plain_device().lacks_decoder(&main));
        assert!(!modern_device().lacks_decoder(&main10));
        assert!(!modern_device().lacks_decoder(&main));
    }

    #[test]
    fn h264_stays_direct_play_everywhere_it_is_reported() {
        let h264 = source("h264", Some(8), 1920, 1080);
        assert!(!plain_device().lacks_decoder(&h264));
        assert!(!modern_device().lacks_decoder(&h264));
        // A device that reports no decoder at all cannot play it either.
        assert!(VideoDecoders::probed().lacks_decoder(&h264));
    }

    #[test]
    fn a_ten_bit_decoder_takes_eight_bit_too() {
        let device = VideoDecoders::probed().with("hevc", true, 4096, 2160);
        assert!(!device.lacks_decoder(&source("hevc", Some(8), 1920, 1080)));
    }

    #[test]
    fn a_picture_larger_than_the_decoder_takes_is_missing_a_decoder() {
        let device = VideoDecoders::probed().with("hevc", true, 1920, 1088);
        assert!(!device.lacks_decoder(&source("hevc", Some(10), 1920, 1080)));
        assert!(device.lacks_decoder(&source("hevc", Some(10), 3840, 2160)));
        // The limit is read whichever way round the decoder reports width and height.
        let portrait = VideoDecoders::probed().with("h264", false, 1088, 1920);
        assert!(!portrait.lacks_decoder(&source("h264", Some(8), 1920, 1080)));
    }

    #[test]
    fn without_a_bit_depth_the_profile_or_an_hdr_range_says_ten_bits() {
        let mut main10 = source("hevc", None, 1920, 1080);
        if let Some(streams) = main10.media_streams.as_mut() {
            streams[1].profile = Some("Main 10".into());
        }
        assert!(plain_device().lacks_decoder(&main10));
        let mut hdr = source("hevc", None, 1920, 1080);
        if let Some(streams) = hdr.media_streams.as_mut() {
            streams[1].video_range_type_raw = Some("HDR10".into());
        }
        assert!(plain_device().lacks_decoder(&hdr));
        // Nothing says 10 bits: eight.
        assert!(!plain_device().lacks_decoder(&source("hevc", None, 1920, 1080)));
    }

    #[test]
    fn codecs_the_host_does_not_report_and_titles_without_video_pass() {
        assert!(!plain_device().lacks_decoder(&source("mpeg4", Some(8), 720, 576)));
        assert!(!plain_device().lacks_decoder(&MediaSource::default()));
    }
}
