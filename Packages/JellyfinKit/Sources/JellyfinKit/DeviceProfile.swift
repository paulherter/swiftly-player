import Foundation

/// The DeviceProfile is the most important data structure of the app.
///
/// Jellyfin decides solely from this profile whether it delivers a file
/// untouched (Direct Play), only repackages the container (Direct Stream) or
/// re-encodes the video (Transcode).
///
/// Swiftly aims for transcoding never to happen. To that end it declares the
/// full capabilities of libVLC, including the three points where other clients
/// typically slip into transcoding:
///
///  1. **Subtitles.** If a format is not declared as `Embed`/`External`, the
///     server burns it into the picture, which forces a video re-encode. That
///     is why every bitmap format (PGS, VOBSUB, DVB) is listed below.
///  2. **Bitrate.** A limit that is too low triggers transcoding although
///     codec and container fit. On a home network there is no sensible limit.
///  3. **Audio.** DTS, TrueHD and MLP are missing from AVPlayer profiles. VLC can play them.
public struct DeviceProfile: Codable, Sendable {

    public var name: String
    public var maxStreamingBitrate: Int
    public var maxStaticBitrate: Int
    public var directPlayProfiles: [DirectPlayProfile]
    public var transcodingProfiles: [TranscodingProfile]
    public var subtitleProfiles: [SubtitleProfile]
    public var codecProfiles: [CodecProfile]

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxStaticBitrate = "MaxStaticBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case subtitleProfiles = "SubtitleProfiles"
        case codecProfiles = "CodecProfiles"
    }

    public struct DirectPlayProfile: Codable, Sendable {
        public var container: String
        public var type: String
        public var videoCodec: String?
        public var audioCodec: String?

        enum CodingKeys: String, CodingKey {
            case container = "Container"
            case type = "Type"
            case videoCodec = "VideoCodec"
            case audioCodec = "AudioCodec"
        }
    }

    public struct TranscodingProfile: Codable, Sendable {
        public var container: String
        public var type: String
        public var videoCodec: String
        public var audioCodec: String
        public var context: String
        public var protocolName: String

        enum CodingKeys: String, CodingKey {
            case container = "Container"
            case type = "Type"
            case videoCodec = "VideoCodec"
            case audioCodec = "AudioCodec"
            case context = "Context"
            case protocolName = "Protocol"
        }
    }

    public struct SubtitleProfile: Codable, Sendable {
        public var format: String
        public var method: String

        enum CodingKeys: String, CodingKey {
            case format = "Format"
            case method = "Method"
        }
    }

    public struct CodecProfile: Codable, Sendable {
        public var type: String
        public var codec: String?
        public var conditions: [ProfileCondition]

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case codec = "Codec"
            case conditions = "Conditions"
        }
    }

    public struct ProfileCondition: Codable, Sendable {
        public var condition: String
        public var property: String
        public var value: String
        public var isRequired: Bool

        enum CodingKeys: String, CodingKey {
            case condition = "Condition"
            case property = "Property"
            case value = "Value"
            case isRequired = "IsRequired"
        }
    }
}

// MARK: - The VLC profile

public extension DeviceProfile {

    /// Containers that libVLC opens directly.
    static let vlcContainers = [
        "mkv", "mp4", "mov", "m4v", "avi", "flv", "webm", "asf", "wmv",
        "ts", "m2ts", "mts", "mpegts", "mpg", "mpeg", "vob", "3gp", "3g2",
        // `ogg`: Jellyfin calls a .ogv that, ffprobe only says "ogg". If it were
        // missing, Theora/Vorbis would be converted although libVLC 3 and 4 play
        // the file.
        "ogg", "ogv", "ogm", "rm", "rmvb", "divx", "f4v", "mk3d", "nsv", "dav", "wtv",
    ]

    /// Containers of pure audio files, in Jellyfin's spelling.
    static let vlcAudioContainers = [
        "mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "wma", "ape", "alac",
        "mkv", "mka", "webm", "wv", "aiff", "aif", "caf", "w64", "au", "tta",
        "mpc", "ac3", "eac3", "dts", "truehd", "mp2",
    ]

    /// Video codecs that libVLC decodes. On Apple silicon h264, hevc and av1
    /// (from A17 Pro / M3) run in hardware, the rest in software.
    static let vlcVideoCodecs = [
        "h264", "hevc", "h265", "av1", "vp8", "vp9", "mpeg4", "mpeg2video",
        "mpeg1video", "vc1", "wmv1", "wmv2", "wmv3", "msmpeg4v1", "msmpeg4v2",
        "msmpeg4v3", "h263", "theora", "dvvideo", "prores", "ffv1", "mjpeg",
    ]

    /// Audio codecs. DTS, TrueHD and MLP are why a pure AVPlayer profile regularly
    /// transcodes movie rips.
    static let vlcAudioCodecs = [
        "aac", "aac_latm", "ac3", "eac3", "dts", "dca", "dtshd", "truehd", "mlp",
        "mp3", "mp2", "mp1", "flac", "alac", "vorbis", "opus", "wmav1", "wmav2",
        "wmapro", "wmalossless",
        // Blu-ray, DVD and camera material carries PCM in several widths.
        "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s32le", "pcm_f32le",
        "pcm_alaw", "pcm_mulaw", "pcm_bluray", "pcm_dvd",
        // Belongs to the containers rm and rmvb declared below.
        "cook", "sipr", "ra_144", "ra_288",
        "ape", "wavpack", "tta", "musepack",
        "amr_nb", "amr_wb", "nellymoser", "speex", "adpcm_ima_wav", "adpcm_ms",
    ]

    /// Subtitle formats. `Embed` means: delivered inside the container, the client
    /// renders it itself. `External` means: loaded as a separate file.
    /// Both avoid burning in, and therefore transcoding.
    static let vlcSubtitleProfiles: [SubtitleProfile] = {
        let embedded = [
            "srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text",
            // `stpp` is Timed Text in MP4. If it is missing, the server burns the
            // subtitle into the picture and has to re-encode the video for it.
            // This is the most expensive case: the video has to be re-encoded.
            "stpp", "ttml", "dfxp",
            "sami", "smi", "microdvd", "teletext", "dvbsub", "dvb_subtitle",
            "pgssub", "pgs", "hdmv_pgs_subtitle",
            "dvdsub", "dvd_subtitle", "vobsub", "idx",
            "cc_dec", "eia_608", "subviewer", "mpl2", "pjs", "jacosub", "realtext",
        ]
        // `pgssub` is a .sup file next to the movie. Jellyfin calls it that and
        // delivers it **raw** when a client accepts exactly this format as
        // `External` (`SubtitleEncoder.GetReadableFile`). If it were missing, the
        // server found no profile for the chosen subtitle and answered with
        // `Encode`: burn-in, i.e. re-encoding the picture. libVLC 3 and 4 load the
        // file as a side track through the avformat demuxer, also under the name
        // `Stream.pgssub`. External VobSub (`dvdsub`) is deliberately **not** listed
        // here: Jellyfin cannot deliver it raw, it would try to convert it to text
        // and fail.
        let external = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "sub", "idx", "smi", "pgssub"]
        return embedded.map { SubtitleProfile(format: $0, method: "Embed") }
             + external.map { SubtitleProfile(format: $0, method: "External") }
    }()

    /// The profile Swiftly presents to the server.
    ///
    /// - Parameter maxBitrate: Practically unlimited by default. Only worth
    ///   lowering when on the road over a thin connection; the server then
    ///   transcodes deliberately.
    static func vlc(maxBitrate: Int = 1_000_000_000) -> DeviceProfile {
        var direct: [DirectPlayProfile] = []

        // One entry per container **without** a codec restriction: for Jellyfin a
        // missing `VideoCodec`/`AudioCodec` means any codec is allowed in this
        // container.
        //
        // This used to be the two lists above, concatenated. That silently
        // contradicted the goal of this app: an allow list can only be too short, and
        // anything not in it makes the server convert, even if libVLC would play it
        // without complaint. The lists stay anyway; they now only feed the diagnosis
        // in `PlaybackPlan.diagnose`, where they answer "what was the cause", not
        // "what is allowed".
        for container in vlcContainers {
            direct.append(
                DirectPlayProfile(
                    container: container,
                    type: "Video",
                    videoCodec: nil,
                    audioCodec: nil
                )
            )
        }

        // Pure audio files: everything libVLC 3 and 4 play (checked with one
        // generated file each). The name is the one Jellyfin derives from ffprobe's
        // `format_name`: `.mka` is `mkv` there, `.mp2` is `mp3`, raw TrueHD is
        // `truehd`. If a container is missing, the server converts the music although
        // nothing speaks against it.
        for container in vlcAudioContainers {
            direct.append(DirectPlayProfile(container: container, type: "Audio",
                                            videoCodec: nil, audioCodec: nil))
        }

        // Fallback in case transcoding is ever needed. Deliberately HLS + h264/aac,
        // because it plays everywhere.
        let transcoding = [
            TranscodingProfile(container: "ts", type: "Video", videoCodec: "h264",
                               audioCodec: "aac", context: "Streaming", protocolName: "hls")
        ]

        return DeviceProfile(
            name: "Swiftly (VLC)",
            maxStreamingBitrate: maxBitrate,
            maxStaticBitrate: maxBitrate,
            directPlayProfiles: direct,
            transcodingProfiles: transcoding,
            subtitleProfiles: vlcSubtitleProfiles,
            codecProfiles: []
        )
    }

}

// MARK: - The AirPlay profile

public extension DeviceProfile {

    /// The profile for **real AirPlay**: deliberately narrow, and that is not
    /// negligence.
    ///
    /// **Purpose.** On Apple platforms AirPlay for video only works through
    /// `AVPlayer`. It knows neither Matroska nor DTS, and the Apple TV at the other
    /// end does not accept DTS anyway. Anyone offering AirPlay must therefore show
    /// the server a profile that describes *AVPlayer's* limits, not libVLC's. This
    /// is the only place in the app that deliberately declares less than it
    /// can do.
    ///
    /// **And it does not break the app's promise.** Checked against the server
    /// (Jellyfin 10.11.11): with this profile it answers `SupportsDirectPlay: false`,
    /// `SupportsDirectStream: false`, `SupportsTranscoding: true`, but
    /// **`TranscodeReasons: None`**. Nothing is re-encoded, only the container is
    /// repackaged from Matroska to fragmented MP4. The overview still calls that
    /// "Transcoding"; that is Jellyfin's label, not the operation.
    ///
    /// What is listed here follows Apple's HLS requirements: video H.264 and HEVC,
    /// audio AAC, AC-3, E-AC-3, ALAC and FLAC. ``AirPlaySuitability`` checks the same
    /// list **before** the button, so nobody presses AirPlay and gets picture
    /// without sound.
    /// - Parameter maxBitrate: Practically unlimited, as with the VLC profile,
    ///   **and that was a measurement, not an assumption.**
    ///
    ///   A limit such as 120 Mbit/s looks plausible: Jellyfin passes this number
    ///   to ffmpeg as the *target rate*, and nobody can deliver a target of
    ///   1 Gbit/s. Measured against the server with a forced re-encode:
    ///
    ///   ```
    ///   target 1 Gbit/s     stalls, -12889 "No response for map in 3s"
    ///   target 120 Mbit/s   stalls, same message
    ///   picture is copied   plays immediately
    ///   ```
    ///
    ///   So the target rate was never the problem. **A real re-encode does not
    ///   work for AirPlay at all**, and a limit only does harm: a file above it
    ///   would be turned into a re-encode when it would otherwise simply have
    ///   been copied.
    ///
    ///   The re-encode is therefore prevented differently: by ``AirPlaySuitability``
    ///   before switching and by `SubtitleStreamIndex: -1` when asking, so no
    ///   subtitle is burned in. If it happens anyway, the player falls back to the
    ///   phone after twelve seconds.
    static func airplay(maxBitrate: Int = 1_000_000_000) -> DeviceProfile {
        // If the file already fits, the server does nothing. The case is rarer than
        // it sounds, but allowing it costs nothing.
        let direct = ["mp4", "m4v", "mov"].map { container in
            DirectPlayProfile(container: container, type: "Video",
                              videoCodec: "h264,hevc",
                              audioCodec: "aac,ac3,eac3,alac,flac,mp3")
        }

        // **The actual path.** `videoCodec` names both allowed codecs so Jellyfin may
        // copy the video track instead of computing it; with only `h264` there, every
        // HEVC movie is re-encoded.
        let transcoding = [
            TranscodingProfile(container: "mp4", type: "Video",
                               videoCodec: "h264,hevc",
                               audioCodec: "aac,ac3,eac3",
                               context: "Streaming", protocolName: "hls")
        ]

        // Text formats only, and `External` instead of `Embed`.
        //
        // **A bitmap subtitle would be the only real transcode reason in the whole
        // app.** AVPlayer cannot draw PGS or VOBSUB, so the server would burn them
        // into the picture and have to re-encode the video for it. They are
        // deliberately *not* listed: if the format is missing, Jellyfin delivers the
        // stream without subtitles instead of burning them in. No subtitle is better
        // than a re-encode.
        let subtitle = ["vtt", "webvtt", "srt", "subrip"]
            .map { SubtitleProfile(format: $0, method: "External") }

        // **HEVC only with the tag AVFoundation accepts.**
        //
        // HEVC in MP4 is tagged either `hvc1` or `hev1` in the file. AVPlayer, and
        // with it the Apple TV at the other end, only plays `hvc1` (Dolby Vision:
        // `dvh1`); with `hev1` you get sound and no picture. Without this condition
        // the server would pass such an MP4 through as Direct Play.
        // With it, the server rejects Direct Play (`VideoCodecTagNotSupported`, a
        // reason that still allows copying) and repackages through the HLS profile
        // below, setting `-tag:v:0 hvc1` itself (DynamicHlsController, Jellyfin
        // 10.11). The picture is copied, not re-encoded. Matroska carries no tag
        // (`CodecTag` empty) and is therefore unaffected with `IsRequired: false`; it
        // is repackaged anyway. jellyfin-web uses the same list for Safari.
        let hevcId = CodecProfile(
            type: "Video", codec: "hevc",
            conditions: [ProfileCondition(condition: "EqualsAny", property: "VideoCodecTag",
                                          value: "hvc1|dvh1", isRequired: false)]
        )

        return DeviceProfile(
            name: "Swiftly (AirPlay)",
            maxStreamingBitrate: maxBitrate,
            maxStaticBitrate: maxBitrate,
            directPlayProfiles: direct,
            transcodingProfiles: transcoding,
            subtitleProfiles: subtitle,
            codecProfiles: [hevcId]
        )
    }

}
