import Foundation
import Testing
@testable import JellyfinKit

@Suite("DeviceProfile")
struct DeviceProfileTests {

    @Test("Deklariert alle VLC-Container für Direct Play")
    func containersCovered() throws {
        let profile = DeviceProfile.vlc()
        let containers = Set(profile.directPlayProfiles.map(\.container))
        // The formats AVPlayer-based clients fail on.
        for critical in ["mkv", "avi", "ts", "m2ts", "webm", "vob"] {
            #expect(containers.contains(critical), "Container \(critical) fehlt")
        }
    }

    @Test("Enthält die Audiocodecs, die AVPlayer nicht kann")
    func losslessAudioCodecs() throws {
        let codecs = DeviceProfile.vlcAudioCodecs
        for critical in ["dts", "truehd", "mlp", "flac", "opus"] {
            #expect(codecs.contains(critical), "Audiocodec \(critical) fehlt")
        }
    }

    @Test("Bitmap-Untertitel werden eingebettet, nicht eingebrannt")
    func bitMapSubtitlesAreEmbedded() throws {
        let profile = DeviceProfile.vlc()
        // PGS and VOBSUB are the most common cause of unwanted
        // transcoding: if the profile lacks them, the server burns them into the picture.
        for format in ["pgssub", "dvdsub", "vobsub", "dvbsub"] {
            let entry = profile.subtitleProfiles.first { $0.format == format }
            #expect(entry != nil, "Untertitelformat \(format) fehlt")
            #expect(entry?.method == "Embed", "\(format) würde eingebrannt werden")
        }
        #expect(!profile.subtitleProfiles.contains { $0.method == "Encode" })
    }

    @Test("Externe PGS-Datei wird roh geholt, externes VobSub nicht zugesagt")
    func externalBitMapSubtitle() {
        let extern = DeviceProfile.vlc().subtitleProfiles.filter { $0.method == "External" }.map(\.format)
        // Without this entry Jellyfin answers `Encode` for a .sup file.
        #expect(extern.contains("pgssub"))
        // The server could not deliver it as is, only convert it, and would fail on that.
        #expect(!extern.contains("dvdsub"))
    }

    @Test("Reine Audiodateien: Matroska, WavPack, AIFF und rohe Bitstroeme spielen direkt")
    func audioContainer() {
        let audio = Set(DeviceProfile.vlc().directPlayProfiles.filter { $0.type == "Audio" }.map(\.container))
        for container in ["mkv", "wv", "aiff", "caf", "w64", "tta", "ac3", "eac3", "dts", "truehd", "webm"] {
            #expect(audio.contains(container), "\(container)")
        }
        #expect(DeviceProfile.vlc().directPlayProfiles.filter { $0.type == "Audio" }
            .allSatisfy { $0.audioCodec == nil })
    }

    @Test("Bitrate ist standardmäßig praktisch unbegrenzt")
    func bitrateIsUnbounded() throws {
        // 1 Gbit/s is far above any remux, so it never triggers a transcode.
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

// MARK: - Rules 1 to 3, recounted

@Suite("Profil laesst nichts umwandeln")
struct ProfileGapsTests {

    /// Rule: an allow list can only be too short. libVLC decodes
    /// practically everything; every codec missing from the list makes the
    /// server convert, even when container and version fit.
    @Test("Direktwiedergabe schraenkt Codecs nicht ein")
    func noCodecList() {
        let profile = DeviceProfile.vlc()
        let video = profile.directPlayProfiles.filter { $0.type == "Video" }
        #expect(!video.isEmpty)
        for entryRecord in video {
            #expect(entryRecord.videoCodec == nil,
                    "Container \(entryRecord.container) schraenkt den Videocodec ein")
            #expect(entryRecord.audioCodec == nil,
                    "Container \(entryRecord.container) schraenkt den Toncodec ein")
        }
    }

    /// Rule 1: if a subtitle format is missing, the server burns it into the picture
    /// and has to re-encode the **video** for that. `stpp` is Timed Text in
    /// MP4 and was not in the list.
    @Test("Jedes gaengige Untertitelformat ist deklariert")
    func subtitleComplete() {
        let formate = Set(DeviceProfile.vlcSubtitleProfiles.map(\.format))
        for format in ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text",
                       "stpp", "ttml", "pgssub", "dvdsub", "vobsub", "dvbsub"] {
            #expect(formate.contains(format), "Untertitelformat \(format) fehlt")
        }
    }

    /// Rule 3: DTS, TrueHD and MLP are the most common reason for conversion in
    /// movie rips. The PCM variants occur in Blu-ray and camera material,
    /// RealAudio belongs to the declared containers rm and rmvb.
    @Test("Tonliste deckt ab, was in den Containern vorkommt")
    func audioComplete() {
        let codecs = Set(DeviceProfile.vlcAudioCodecs)
        for codec in ["dts", "dca", "dtshd", "truehd", "mlp",
                      "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le",
                      "pcm_alaw", "pcm_mulaw",
                      "cook", "sipr"] {
            #expect(codecs.contains(codec), "Toncodec \(codec) fehlt")
        }
    }

    /// Rule 2: a limit triggers conversion even though container and codec
    /// fit.
    @Test("Bitrate ist praktisch unbegrenzt")
    func bitrateOpen() {
        let profile = DeviceProfile.vlc()
        #expect(profile.maxStreamingBitrate >= 1_000_000_000)
        #expect(profile.maxStaticBitrate >= 1_000_000_000)
    }

    @Test("AirPlay: HEVC nur als hvc1/dvh1 direkt, sonst umpacken")
    func airplayHevcId() throws {
        let profile = DeviceProfile.airplay()
        let hevc = try #require(profile.codecProfiles.first { $0.codec == "hevc" })
        let requirement = try #require(hevc.conditions.first)
        #expect(requirement.property == "VideoCodecTag")
        #expect(requirement.condition == "EqualsAny")
        #expect(requirement.value == "hvc1|dvh1")
        // Matroska carries no tag; making it mandatory would block it too.
        #expect(requirement.isRequired == false)
        // And it must reach the server that way.
        let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        #expect(json.contains(#""Property":"VideoCodecTag""#))
        // Remuxing may keep copying HEVC.
        #expect(profile.transcodingProfiles.first?.videoCodec.contains("hevc") == true)
    }
}
