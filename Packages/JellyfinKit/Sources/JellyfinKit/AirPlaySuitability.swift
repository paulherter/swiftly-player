import Foundation

/// Whether a file can go to a TV via **real AirPlay**, and if not, why.
///
/// **The obstacle is the device at the other end, not our player.** Video
/// AirPlay forwards the stream in its own format and the receiver has to decode
/// it. An Apple TV accepts neither DTS nor TrueHD, in any app. Per Apple's HLS
/// specification: video H.264 and HEVC, audio AAC, AC-3, E-AC-3, ALAC and FLAC.
///
/// This check therefore comes **before** the button, not after. Skipping it
/// offers AirPlay and then delivers picture without sound.
///
/// **It looks at all audio tracks, not just the first.** Rips often carry DTS
/// *and* an AC-3 track; AirPlay works then, the server just has to be told
/// which track to use. That is what `audioTrack` is for; without it half the
/// collection would be rejected wrongly.
///
/// Lives in the package, not in the views, because four platforms show the same
/// button and owe the same message. Like `EpisodeEnd` and `TimeAssumption`.
public struct AirPlaySuitability: Sendable, Equatable {

    /// Index of the audio track that gets through via AirPlay, `nil` if none.
    ///
    /// This is the `Index` from the server response, not the position in the list:
    /// Jellyfin counts video, audio and subtitles in one sequence, and
    /// `AudioStreamIndex` expects exactly that number.
    public let audioTrack: Int?

    public let obstacles: [Obstacle]

    public var fitting: Bool { obstacles.isEmpty }

    public init(audioTrack: Int?, obstacles: [Obstacle]) {
        self.audioTrack = audioTrack
        self.obstacles = obstacles
    }

    /// What stands in the way of AirPlay.
    public struct Obstacle: Sendable, Equatable {
        public enum Art: String, Sendable {
            case video
            case audio = "ton"
            /// The server would have to remux but cannot or will not.
            case umpacken
        }

        public let art: Art
        public let codec: String

        public init(art: Art, codec: String) {
            self.art = art
            self.codec = codec
        }

        public var text: String {
            switch art {
            case .video:
                translated("Das Bild liegt als \(codec.uppercased()) vor. AirPlay überträgt nur H.264 und HEVC.")
            case .audio:
                translated("Der Ton liegt als \(codec.uppercased()) vor. Apple-Geräte nehmen das über AirPlay nicht an.")
            case .umpacken:
                translated("Die Datei liegt als \(codec.uppercased()) vor. Für AirPlay müsste der Server sie umpacken — er bietet das nicht an. In den Servereinstellungen unter „Wiedergabe“ muss Transkodierung erlaubt sein.")
            }
        }
    }

    /// One sentence for the message in the app.
    ///
    /// **The second sentence matters more.** An error that only says "doesn't
    /// work" leaves the viewer stranded, although a way exists that works for
    /// *any* format: decoding on the phone.
    public var message: String? {
        guard !fitting else { return nil }
        let grounds = obstacles.map(\.text).joined(separator: " ")
        return grounds + " "
            + translated("Über Bildschirmsynchronisierung im Kontrollzentrum läuft der Film trotzdem auf dem Fernseher.")
    }

    // MARK: - What gets through

    /// Video codecs that AirPlay transmits.
    ///
    /// The four-character codes are included because Jellyfin reports `hevc` or
    /// `hvc1` depending on the container. Dolby Vision (`dvh1`, `dvhe`) is HEVC
    /// with an extra layer and works on an Apple TV 4K.
    public static let videoCodecs: Set<String> = [
        "h264", "avc1", "avc",
        "hevc", "h265", "hvc1", "hev1",
        "dvh1", "dvhe",
    ]

    /// Audio codecs that AirPlay transmits.
    ///
    /// **Not included and cannot be added:** DTS in all variants, TrueHD, MLP. The
    /// receiver rejects them. PCM, Opus and Vorbis are also missing from Apple's
    /// specification.
    public static let audioCodecs: Set<String> = [
        "aac", "aac_latm", "he-aac",
        "ac3", "eac3", "ec-3",
        "alac", "flac", "mp3",
    ]

    // MARK: - Checking

    public static func check(source: MediaSource) -> AirPlaySuitability {
        let streams = source.mediaStreams ?? []
        var obstacles: [Obstacle] = []

        // Video. Without a video track it is an audio file; nothing stands in the way
        // of the sound and AirPlay is not the question anyway.
        if let video = streams.first(where: { $0.type == "Video" }) {
            let codec = video.codec?.lowercased() ?? ""
            if !videoCodecs.contains(codec) {
                obstacles.append(Obstacle(art: .video, codec: codec.isEmpty ? "?" : codec))
            }
        }

        // Audio. Of all usable tracks the best one, not the first.
        let audioStreams = streams.filter { $0.type == "Audio" }
        let suitable = audioStreams.filter { audioCodecs.contains($0.codec?.lowercased() ?? "") }
        let selected = bestAudioTrack(suitable)

        if selected == nil, !audioStreams.isEmpty {
            // For the message, what counts is what the viewer would have heard otherwise:
            // the default track, else the first.
            let named = audioStreams.first { $0.isDefault == true } ?? audioStreams[0]
            obstacles.append(Obstacle(art: .audio,
                                         codec: named.codec?.lowercased() ?? "?"))
        }

        return AirPlaySuitability(audioTrack: obstacles.isEmpty ? selected?.index : nil,
                              obstacles: obstacles)
    }

    /// The default track if it works, otherwise the one with the most channels.
    ///
    /// Default first because the viewer is used to it; only when it drops out is
    /// more audio better than less. On a tie the server's order is kept.
    private static func bestAudioTrack(_ tracks: [MediaStream]) -> MediaStream? {
        if let standard = tracks.first(where: { $0.isDefault == true }) { return standard }
        // Not `max(by:)`: on a tie it returns the *last* track and would reverse the
        // server's order.
        var best: MediaStream?
        for track in tracks where (track.channels ?? 0) > (best?.channels ?? -1) {
            best = track
        }
        return best
    }
}

/// What AirPlay yields for a title.
public enum AirPlayInfo: Sendable {
    /// Works, with this plan that `AVPlayer` can open.
    case goes(PlaybackPlan)
    /// Does not work, and here is why.
    case goesNot(AirPlaySuitability)
}
