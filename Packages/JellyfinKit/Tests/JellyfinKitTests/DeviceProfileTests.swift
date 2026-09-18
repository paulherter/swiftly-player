import Foundation
import Testing
@testable import JellyfinKit

@Suite("DeviceProfile")
struct DeviceProfileTests {

    @Test("Deklariert alle VLC-Container für Direct Play")
    func containersCovered() throws {
        let profile = DeviceProfile.vlc()
        let containers = Set(profile.directPlayProfiles.map(\.container))
        // Die Formate, an denen AVPlayer-basierte Clients scheitern.
        for critical in ["mkv", "avi", "ts", "m2ts", "webm", "vob"] {
            #expect(containers.contains(critical), "Container \(critical) fehlt")
        }
    }

    @Test("Enthält die Audiocodecs, die AVPlayer nicht kann")
    func lossessAudioCodecs() throws {
        let codecs = DeviceProfile.vlcAudioCodecs
        for critical in ["dts", "truehd", "mlp", "flac", "opus"] {
            #expect(codecs.contains(critical), "Audiocodec \(critical) fehlt")
        }
    }

    @Test("Bitmap-Untertitel werden eingebettet, nicht eingebrannt")
    func bitmapSubtitlesAreEmbedded() throws {
        let profile = DeviceProfile.vlc()
        // PGS und VOBSUB sind der häufigste Auslöser für ungewollte
        // Transkodierung: fehlen sie im Profil, brennt der Server sie ins Bild.
        for format in ["pgssub", "dvdsub", "vobsub", "dvbsub"] {
            let entry = profile.subtitleProfiles.first { $0.format == format }
            #expect(entry != nil, "Untertitelformat \(format) fehlt")
            #expect(entry?.method == "Embed", "\(format) würde eingebrannt werden")
        }
        #expect(!profile.subtitleProfiles.contains { $0.method == "Encode" })
    }

    @Test("Bitrate ist standardmäßig praktisch unbegrenzt")
    func bitrateIsUnbounded() throws {
        // 1 Gbit/s liegt weit über jedem Remux — löst also nie Transcode aus.
        #expect(DeviceProfile.vlc().maxStreamingBitrate >= 1_000_000_000)
    }

    @Test("Serialisiert mit Jellyfins PascalCase-Schlüsseln")
    func encodesWithServerKeys() throws {
        let data = try JSONEncoder().encode(DeviceProfile.vlc())
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["DirectPlayProfiles"] != nil)
        #expect(json["SubtitleProfiles"] != nil)
        #expect(json["MaxStreamingBitrate"] != nil)

        let first = try #require((json["DirectPlayProfiles"] as? [[String: Any]])?.first)
        #expect(first["Container"] != nil)
        #expect(first["Type"] as? String == "Video")
    }
}

@Suite("MediaSource")
struct MediaSourceTests {

    private func source(directPlay: Bool, directStream: Bool) -> MediaSource {
        let json = """
        {"Id":"x","SupportsDirectPlay":\(directPlay),"SupportsDirectStream":\(directStream)}
        """
        return try! JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))
    }

    @Test("Leitet die Auslieferungsart korrekt ab")
    func deliveryMethod() {
        #expect(source(directPlay: true,  directStream: true ).deliveryMethod == .directPlay)
        #expect(source(directPlay: false, directStream: true ).deliveryMethod == .directStream)
        #expect(source(directPlay: false, directStream: false).deliveryMethod == .transcode)
    }

    @Test("Direct Play und Direct Stream gelten beide als verlustfrei")
    func losslessFlag() {
        #expect(DeliveryMethod.directPlay.isLossless)
        #expect(DeliveryMethod.directStream.isLossless)
        #expect(!DeliveryMethod.transcode.isLossless)
    }
}

// MARK: - Regel 1 bis 3 aus CLAUDE.md, nachgezählt

@Suite("Profil laesst nichts umwandeln")
struct ProfilLueckenTests {

    /// Regel: eine Positivliste kann nur zu kurz sein. libVLC dekodiert
    /// praktisch alles; jeder Codec, der nicht in der Liste steht, laesst den
    /// Server umwandeln — auch wenn Container und Fassung passen.
    @Test("Direktwiedergabe schraenkt Codecs nicht ein")
    func keineCodecliste() {
        let profil = DeviceProfile.vlc()
        let video = profil.directPlayProfiles.filter { $0.type == "Video" }
        #expect(!video.isEmpty)
        for eintrag in video {
            #expect(eintrag.videoCodec == nil,
                    "Container \(eintrag.container) schraenkt den Videocodec ein")
            #expect(eintrag.audioCodec == nil,
                    "Container \(eintrag.container) schraenkt den Toncodec ein")
        }
    }

    /// Regel 1: fehlt ein Untertitelformat, brennt der Server es ins Bild —
    /// und muss dafuer das **Video** neu rechnen. `stpp` ist Timed Text in
    /// MP4 und kam in der Liste nicht vor.
    @Test("Jedes gaengige Untertitelformat ist deklariert")
    func untertitelVollstaendig() {
        let formate = Set(DeviceProfile.vlcSubtitleProfiles.map(\.format))
        for format in ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text",
                       "stpp", "ttml", "pgssub", "dvdsub", "vobsub", "dvbsub"] {
            #expect(formate.contains(format), "Untertitelformat \(format) fehlt")
        }
    }

    /// Regel 3: DTS, TrueHD und MLP sind der haeufigste Umwandlungsgrund bei
    /// Film-Rips. Die PCM-Spielarten kommen bei Blu-ray- und Kamera-Material
    /// vor, RealAudio gehoert zu den deklarierten Containern rm und rmvb.
    @Test("Tonliste deckt ab, was in den Containern vorkommt")
    func tonVollstaendig() {
        let codecs = Set(DeviceProfile.vlcAudioCodecs)
        for codec in ["dts", "dca", "dtshd", "truehd", "mlp",
                      "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le",
                      "pcm_alaw", "pcm_mulaw",
                      "cook", "sipr"] {
            #expect(codecs.contains(codec), "Toncodec \(codec) fehlt")
        }
    }

    /// Regel 2: ein Limit loest Umwandlung aus, obwohl Container und Codec
    /// passen.
    @Test("Bitrate ist praktisch unbegrenzt")
    func bitrateOffen() {
        let profil = DeviceProfile.vlc()
        #expect(profil.maxStreamingBitrate >= 1_000_000_000)
        #expect(profil.maxStaticBitrate >= 1_000_000_000)
    }
}
