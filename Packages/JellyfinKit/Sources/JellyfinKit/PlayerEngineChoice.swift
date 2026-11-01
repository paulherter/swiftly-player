import Foundation

/// **Which engine opens a title on Apple: VLC or AVPlayer?** Pure, so the rule can be
/// tested without a device. Same shape and setting names as Android's `EngineChoice`
/// (`dolbyVision`, `exoplayer`, `vlc`), so a synced value means the same thing everywhere.
///
/// **Why a second engine.** libVLC 4 shows Dolby Vision only as its HDR10 base layer
/// (profile 5 has none: wrong colors) and decodes AV1 in software. AVPlayer hands both to
/// the system: Dolby Vision, HDR10 and HLG with display matching, AV1 on the hardware
/// decoder where the chip has one.
///
/// **What AVPlayer cannot do, and so decides for VLC:**
/// - Matroska, DTS, TrueHD and Opus. The server repackages the container (Direct Stream,
///   HLS with fragmented MP4, picture and sound copied) but never re-encodes, so a codec
///   AVPlayer does not know is a VLC title. The sets are those of ``AirPlaySuitability``:
///   the same HLS rules apply.
/// - Image subtitles (PGS, VOBSUB). AVPlayer cannot draw them and the server must not burn
///   them in.
/// - Dolby Vision profile 7 (dual layer with enhancement layer): not playable as a copy.
public enum PlayerEngine: String, Sendable, Equatable {
    case vlc
    case avPlayer
}

/// The setting. The raw values are Android's, `exoplayer` included: it is the same
/// synced value, only the engine behind it is a different one per platform.
public enum PlayerEngineSetting: String, CaseIterable, Sendable, Codable, Identifiable {
    /// VLC, but Dolby Vision, HDR and AV1 titles go to AVPlayer. The default.
    case dolbyVision
    /// Everything that AVPlayer can play goes to AVPlayer.
    case avPlayer = "exoplayer"
    /// Everything on VLC.
    case vlc

    public var id: String { rawValue }

    public static let storageKey = "playerEngine"
    public static let standard: PlayerEngineSetting = .dolbyVision

    /// Anything unknown counts as the default, like on Android.
    public init(stored: String?) {
        self = stored.flatMap(PlayerEngineSetting.init(rawValue:)) ?? .standard
    }

    /// Wording as on Android, with AVPlayer in place of ExoPlayer.
    public var name: String {
        switch self {
        case .dolbyVision: translated("VLC, Dolby Vision und HDR mit AVPlayer")
        case .avPlayer:    translated("Immer AVPlayer")
        case .vlc:         translated("Immer VLC")
        }
    }
}

/// What the device in hand can show. The package has no AVFoundation, the app fills it in.
public struct EngineDevice: Sendable, Equatable {
    /// The device decodes Dolby Vision and the display reports it.
    public var dolbyVision: Bool
    /// The display shows an extended range at all (HDR10, HLG).
    public var hdr: Bool
    /// The chip has a hardware AV1 decoder.
    public var av1: Bool

    public init(dolbyVision: Bool, hdr: Bool, av1: Bool) {
        self.dolbyVision = dolbyVision
        self.hdr = hdr
        self.av1 = av1
    }
}

/// The answer, with the reason for the log line.
public struct EngineDecision: Sendable, Equatable {
    public let engine: PlayerEngine
    /// Short German reason, the same style as Android's log.
    public let reason: String

    public init(engine: PlayerEngine, reason: String) {
        self.engine = engine
        self.reason = reason
    }

    /// `[Engine] AVPlayer: Dolby Vision 8 (Ton ac3)`
    public var logLine: String {
        "[Engine] \(engine == .avPlayer ? "AVPlayer" : "VLC"): \(reason)"
    }
}

public enum PlayerEngineChoice {

    // MARK: - Decision

    /// - Parameters:
    ///   - setting: the user's choice.
    ///   - softwareDecoder: the title needs the software decoder (rescue stage, MPEG-4
    ///     Part 2): VLC.
    ///   - avFailed: AVPlayer already failed for this title: VLC, for good.
    ///   - source: the unchanged file, as the server describes it.
    ///   - audioIndex: the audio track that will play (server `Index`); `nil` takes the
    ///     source's default track.
    ///   - subtitleIndex: the subtitle track that will show; `nil` or negative for none.
    ///   - device: what the device can show.
    public static func decide(setting: PlayerEngineSetting, softwareDecoder: Bool,
                              avFailed: Bool, source: MediaSource, audioIndex: Int? = nil,
                              subtitleIndex: Int? = nil, device: EngineDevice) -> EngineDecision {
        if softwareDecoder { return vlc("Software-Dekoder") }
        if avFailed { return vlc("AVPlayer gescheitert") }
        if setting == .vlc { return vlc("Einstellung VLC") }

        let facts = Facts(source: source)
        guard let video = facts.video else { return vlc("Bild unbekannt") }
        if let obstacle = facts.pictureObstacle(device: device) { return vlc(obstacle) }
        if let obstacle = facts.soundObstacle(index: audioIndex) { return vlc(obstacle) }
        if let obstacle = facts.subtitleObstacle(index: subtitleIndex) { return vlc(obstacle) }

        let sound = facts.audio(index: audioIndex)?.codec?.lowercased() ?? "ohne Ton"
        if setting == .avPlayer {
            return av("Einstellung AVPlayer (\(video.codec ?? "?"), Ton \(sound))")
        }
        if let why = facts.whyAVPlayer(device: device) {
            return av("\(why) (Ton \(sound))")
        }
        return vlc("kein Dolby Vision, HDR oder AV1")
    }

    private static func vlc(_ reason: String) -> EngineDecision {
        EngineDecision(engine: .vlc, reason: reason)
    }

    private static func av(_ reason: String) -> EngineDecision {
        EngineDecision(engine: .avPlayer, reason: reason)
    }

    // MARK: - Tracks

    /// The audio track the server should copy for AVPlayer, as `Index`: the source's default
    /// track if AVPlayer can play it, else `nil`. The caller does not switch to another
    /// language on its own account: that would play the wrong language silently.
    public static func audioTrack(of source: MediaSource, index: Int? = nil) -> Int? {
        let facts = Facts(source: source)
        guard let track = facts.audio(index: index),
              facts.canPlay(track) else { return nil }
        return track.index
    }

    /// Whether this subtitle codec is a picture (PGS, VOBSUB, DVB). AVPlayer cannot draw
    /// those; they send the title to VLC.
    public static func isImageSubtitle(codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return imageSubtitles.contains(codec)
    }

    static let imageSubtitles: Set<String> = [
        "pgssub", "pgs", "hdmv_pgs_subtitle",
        "dvdsub", "dvd_subtitle", "vobsub",
        "dvbsub", "dvb_subtitle", "xsub",
    ]

    // MARK: - Stream copy

    /// Whether the server's remux address only repackages. Jellyfin names the reasons in
    /// `TranscodeReasons=` of the `TranscodingUrl`. Container and codec tag reasons still
    /// copy; every reason about the picture, the sound or a subtitle means a re-encode or
    /// burn-in, and that the app does not do: VLC takes the title instead.
    ///
    /// No reasons, or none that are known to re-encode, count as a copy.
    public static func isCopyOnly(transcodingURL: URL?) -> Bool {
        guard let url = transcodingURL,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name.lowercased() == "transcodereasons" })?.value
        else { return true }
        let found = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        return !found.contains { reencodingReasons.contains($0) }
    }

    static let reencodingReasons: Set<String> = [
        "VideoCodecNotSupported", "VideoProfileNotSupported", "VideoLevelNotSupported",
        "VideoResolutionNotSupported", "VideoBitDepthNotSupported", "VideoBitrateNotSupported",
        "VideoFramerateNotSupported", "VideoRangeTypeNotSupported", "RefFramesNotSupported",
        "AnamorphicVideoNotSupported", "InterlacedVideoNotSupported",
        "AudioCodecNotSupported", "AudioBitrateNotSupported", "AudioChannelsNotSupported",
        "AudioProfileNotSupported", "AudioSampleRateNotSupported", "AudioBitDepthNotSupported",
        "SubtitleCodecNotSupported",
    ]

    // MARK: - Facts about the file

    struct Facts {
        let video: MediaStream?
        let audioStreams: [MediaStream]
        let subtitleStreams: [MediaStream]
        let defaultAudio: Int?

        init(source: MediaSource) {
            let streams = source.mediaStreams ?? []
            video = streams.first { $0.type == "Video" }
            audioStreams = streams.filter { $0.type == "Audio" }
            subtitleStreams = streams.filter { $0.type == "Subtitle" }
            defaultAudio = source.defaultAudioStreamIndex
        }

        var codec: String { video?.codec?.lowercased() ?? "" }

        /// Dolby Vision profile of the picture, `nil` without Dolby Vision.
        var dolbyVisionProfile: Int? {
            if let profile = video?.dvProfile { return profile }
            if codec == "dvh1" || codec == "dvhe" { return 0 }
            if let range = video?.videoRangeType, range.isDolbyVision { return 0 }
            return nil
        }

        func audio(index: Int?) -> MediaStream? {
            if let index, let match = audioStreams.first(where: { $0.index == index }) { return match }
            if let defaultAudio, let match = audioStreams.first(where: { $0.index == defaultAudio }) {
                return match
            }
            return audioStreams.first { $0.isDefault == true } ?? audioStreams.first
        }

        func canPlay(_ track: MediaStream) -> Bool {
            AirPlaySuitability.audioCodecs.contains(track.codec?.lowercased() ?? "")
        }

        /// Reason for VLC because of the picture, `nil` if AVPlayer can show it.
        func pictureObstacle(device: EngineDevice) -> String? {
            let codec = codec
            if codec == "av1" {
                if !device.av1 { return "AV1 ohne Hardware-Dekoder" }
            } else if !AirPlaySuitability.videoCodecs.contains(codec) {
                return "Bild \(codec.isEmpty ? "?" : codec) nicht für AVPlayer"
            }
            if let profile = dolbyVisionProfile {
                // Profile 7 carries an enhancement layer in a second track; as a copy it
                // is not playable. Profile 0 is "Dolby Vision, profile unknown": try it.
                if profile == 7 { return "Dolby Vision 7 nicht kopierbar" }
                if video?.videoRangeType == .dolbyVisionEL { return "Dolby Vision mit Zusatzschicht" }
                if profile == 5, !device.dolbyVision { return "Dolby Vision 5 ohne Gerät dafür" }
            }
            return nil
        }

        /// Reason for VLC because of the sound, `nil` if AVPlayer can play the track (or none).
        func soundObstacle(index: Int?) -> String? {
            guard let track = audio(index: index) else { return nil }
            guard canPlay(track) else {
                return "Ton \(track.codec?.lowercased() ?? "?") nicht für AVPlayer"
            }
            return nil
        }

        func subtitleObstacle(index: Int?) -> String? {
            guard let index, index >= 0,
                  let track = subtitleStreams.first(where: { $0.index == index }),
                  PlayerEngineChoice.isImageSubtitle(codec: track.codec) else { return nil }
            return "Bild-Untertitel (\(track.codec?.lowercased() ?? "?"))"
        }

        /// Why this title is worth AVPlayer in the default mode, `nil` if it is not.
        func whyAVPlayer(device: EngineDevice) -> String? {
            if let profile = dolbyVisionProfile, device.dolbyVision, profile == 0 || profile == 5 || profile == 8 {
                return profile == 0 ? "Dolby Vision" : "Dolby Vision \(profile)"
            }
            if device.hdr, isHDR { return "HDR" }
            if codec == "av1" { return "AV1" }
            return nil
        }

        private var isHDR: Bool {
            if let range = video?.videoRangeType, range.isHDR {
                // Dolby Vision profile 5 has no HDR10 base layer: without a Dolby Vision
                // device it is no HDR file for this purpose.
                return dolbyVisionProfile != 5
            }
            let transfer = video?.colorTransfer?.lowercased() ?? ""
            return transfer == "smpte2084" || transfer == "arib-std-b67"
        }
    }
}

private extension ColorRange {
    var isDolbyVision: Bool {
        switch self {
        case .dolbyVision, .dolbyVisionHDR10, .dolbyVisionHLG, .dolbyVisionSDR, .dolbyVisionEL,
             .dolbyVisionHDR10Plus, .dolbyVisionElHdr10Plus: true
        default: false
        }
    }
}
