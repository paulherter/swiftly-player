import Foundation

/// Das DeviceProfile ist der wichtigste Datensatz der App.
///
/// Jellyfin entscheidet allein anhand dieses Profils, ob es eine Datei
/// unangetastet ausliefert (Direct Play), nur den Container umpackt
/// (Direct Stream) oder das Video neu encodiert (Transcode).
///
/// Swiftlys Ziel ist, dass Transcode nie passiert. Dafür deklarieren wir die
/// vollen Fähigkeiten von libVLC — inklusive der drei Punkte, an denen andere
/// Clients typischerweise in eine Transkodierung rutschen:
///
///  1. **Untertitel.** Wird ein Format nicht als `Embed`/`External` deklariert,
///     brennt der Server es ins Bild — und das erzwingt ein Video-Reencode.
///     Deshalb steht unten jedes Bitmap-Format (PGS, VOBSUB, DVB) drin.
///  2. **Bitrate.** Ein zu niedriges Limit löst Transkodierung aus, obwohl
///     Codec und Container passen. Im Heimnetz gibt es kein sinnvolles Limit.
///  3. **Audio.** DTS, TrueHD und MLP fehlen in AVPlayer-Profilen. VLC kann sie.
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

// MARK: - Das VLC-Profil

public extension DeviceProfile {

    /// Container, die libVLC direkt öffnet.
    static let vlcContainers = [
        "mkv", "mp4", "mov", "m4v", "avi", "flv", "webm", "asf", "wmv",
        "ts", "m2ts", "mts", "mpegts", "mpg", "mpeg", "vob", "3gp", "3g2",
        "ogv", "ogm", "rm", "rmvb", "divx", "f4v", "mk3d", "nsv", "dav", "wtv",
    ]

    /// Videocodecs, die libVLC dekodiert. Auf Apple-Silicon laufen h264, hevc
    /// und av1 (ab A17 Pro / M3) in Hardware, der Rest in Software.
    static let vlcVideoCodecs = [
        "h264", "hevc", "h265", "av1", "vp8", "vp9", "mpeg4", "mpeg2video",
        "mpeg1video", "vc1", "wmv1", "wmv2", "wmv3", "msmpeg4v1", "msmpeg4v2",
        "msmpeg4v3", "h263", "theora", "dvvideo", "prores", "ffv1", "mjpeg",
    ]

    /// Audiocodecs. DTS, TrueHD und MLP sind der Grund, warum ein reines
    /// AVPlayer-Profil bei Film-Rips regelmäßig transkodiert.
    static let vlcAudioCodecs = [
        "aac", "aac_latm", "ac3", "eac3", "dts", "dca", "dtshd", "truehd", "mlp",
        "mp3", "mp2", "mp1", "flac", "alac", "vorbis", "opus", "wmav1", "wmav2",
        "wmapro", "wmalossless",
        // Blu-ray-, DVD- und Kameramaterial fuehrt PCM in mehreren Breiten.
        "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s32le", "pcm_f32le",
        "pcm_alaw", "pcm_mulaw", "pcm_bluray", "pcm_dvd",
        // Gehoert zu den Containern rm und rmvb, die unten deklariert sind.
        "cook", "sipr", "ra_144", "ra_288",
        "ape", "wavpack", "tta", "musepack",
        "amr_nb", "amr_wb", "nellymoser", "speex", "adpcm_ima_wav", "adpcm_ms",
    ]

    /// Untertitelformate. `Embed` heißt: im Container mitliefern, Client
    /// rendert selbst. `External` heißt: als separate Datei nachladen.
    /// Beides vermeidet das Einbrennen — und damit die Transkodierung.
    static let vlcSubtitleProfiles: [SubtitleProfile] = {
        let embedded = [
            "srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text",
            // `stpp` ist Timed Text in MP4. Fehlt es, brennt der Server den
            // Untertitel ins Bild — und muss dafuer das Video neu rechnen.
            // Das ist der teuerste der drei Faelle aus CLAUDE.md.
            "stpp", "ttml", "dfxp",
            "sami", "smi", "microdvd", "teletext", "dvbsub", "dvb_subtitle",
            "pgssub", "pgs", "hdmv_pgs_subtitle",
            "dvdsub", "dvd_subtitle", "vobsub", "idx",
            "cc_dec", "eia_608", "subviewer", "mpl2", "pjs", "jacosub", "realtext",
        ]
        let external = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "sub", "idx", "smi"]
        return embedded.map { SubtitleProfile(format: $0, method: "Embed") }
             + external.map { SubtitleProfile(format: $0, method: "External") }
    }()

    /// Das Profil, mit dem Swiftly gegen den Server auftritt.
    ///
    /// - Parameter maxBitrate: Standardmäßig praktisch unbegrenzt. Nur für
    ///   unterwegs über eine schmale Leitung sinnvoll zu senken — dann
    ///   transkodiert der Server bewusst.
    static func vlc(maxBitrate: Int = 1_000_000_000) -> DeviceProfile {
        var direct: [DirectPlayProfile] = []

        // Ein Eintrag pro Container **ohne** Codec-Einschränkung: für Jellyfin
        // heißt ein fehlendes `VideoCodec`/`AudioCodec`, dass jeder Codec in
        // diesem Container erlaubt ist.
        //
        // Hier standen einmal die beiden Listen von oben, aneinandergereiht.
        // Das war ein stiller Widerspruch zum Ziel dieser App: eine
        // Positivliste kann nur zu kurz sein, und alles, was nicht darin
        // steht, lässt den Server umwandeln — auch wenn libVLC es
        // klaglos abspielen würde. Die Listen bleiben trotzdem stehen, sie
        // tragen jetzt nur noch die Diagnose in `PlaybackPlan.diagnose`:
        // dort beantworten sie die Frage „woran lag es", nicht „was ist
        // erlaubt".
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

        // Reine Audiodateien.
        for container in ["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "wma", "ape", "alac"] {
            direct.append(DirectPlayProfile(container: container, type: "Audio",
                                            videoCodec: nil, audioCodec: nil))
        }

        // Fallback, falls doch einmal transkodiert werden muss. Bewusst
        // HLS + h264/aac, weil das überall läuft.
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

// MARK: - Das AirPlay-Profil

public extension DeviceProfile {

    /// Das Profil für **echtes AirPlay** — bewusst eng, und das ist keine
    /// Nachlässigkeit.
    ///
    /// **Wofür.** AirPlay für Video geht bei Apple ausschließlich über
    /// `AVPlayer`. Der kennt weder Matroska noch DTS, und der Apple TV am
    /// anderen Ende nimmt DTS ohnehin nicht an. Wer AirPlay anbietet, muss dem
    /// Server deshalb ein Profil zeigen, das *AVPlayers* Grenzen beschreibt —
    /// nicht libVLCs. Dieses hier ist die einzige Stelle in der App, an der
    /// wir absichtlich weniger deklarieren, als wir können.
    ///
    /// **Und es bricht das Versprechen der App nicht.** Am Server nachgemessen
    /// (Jellyfin 10.11.11): mit diesem Profil antwortet er
    /// `SupportsDirectPlay: false`, `SupportsDirectStream: false`,
    /// `SupportsTranscoding: true` — aber **`TranscodeReasons: None`**. Es
    /// wird nichts neu gerechnet, nur der Container von Matroska nach
    /// fragmentiertem MP4 umgepackt. Die Übersicht nennt das trotzdem
    /// „Transcoding"; das ist Jellyfins Beschriftung, nicht der Vorgang.
    ///
    /// Was hier drinsteht, steht in Apples Vorgaben für HLS: Video H.264 und
    /// HEVC, Ton AAC, AC-3, E-AC-3, ALAC und FLAC. Dieselbe Liste prüft
    /// ``AirPlayEignung`` **vor** dem Knopf — damit niemand AirPlay drückt und
    /// Bild ohne Ton bekommt.
    static func airplay(maxBitrate: Int = 1_000_000_000) -> DeviceProfile {
        // Passt die Datei schon, macht der Server gar nichts. Der Fall ist
        // seltener als er klingt, aber er kostet nichts, ihn zu erlauben.
        let direct = ["mp4", "m4v", "mov"].map { container in
            DirectPlayProfile(container: container, type: "Video",
                              videoCodec: "h264,hevc",
                              audioCodec: "aac,ac3,eac3,alac,flac,mp3")
        }

        // **Der eigentliche Weg.** `videoCodec` nennt beide erlaubten Codecs,
        // damit Jellyfin die Videospur kopieren darf statt sie zu rechnen —
        // steht dort nur `h264`, wird jeder HEVC-Film neu encodiert.
        let transcoding = [
            TranscodingProfile(container: "mp4", type: "Video",
                               videoCodec: "h264,hevc",
                               audioCodec: "aac,ac3,eac3",
                               context: "Streaming", protocolName: "hls")
        ]

        // Nur Textformate, und `External` statt `Embed`.
        //
        // **Ein Bitmap-Untertitel wäre hier der einzige echte Transcode-Grund
        // der ganzen App.** PGS oder VOBSUB kann AVPlayer nicht zeichnen, also
        // würde der Server sie ins Bild brennen — und dafür das Video neu
        // rechnen müssen. Sie stehen deshalb absichtlich *nicht* drin: fehlt
        // das Format, liefert Jellyfin den Strom ohne Untertitel aus, statt
        // ihn einzubrennen. Kein Untertitel ist besser als ein Neuencode.
        let untertitel = ["vtt", "webvtt", "srt", "subrip"]
            .map { SubtitleProfile(format: $0, method: "External") }

        return DeviceProfile(
            name: "Swiftly (AirPlay)",
            maxStreamingBitrate: maxBitrate,
            maxStaticBitrate: maxBitrate,
            directPlayProfiles: direct,
            transcodingProfiles: transcoding,
            subtitleProfiles: untertitel,
            codecProfiles: []
        )
    }

}
