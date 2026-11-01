import Foundation
import Testing
@testable import JellyfinKit

/// The **statement** is checked (which engine, and that a reason exists), not the wording.
@Suite("Engine choice")
struct PlayerEngineChoiceTests {

    // MARK: - Helpers

    private func video(_ codec: String, range: ColorRange? = nil, dv: Int? = nil,
                       transfer: String? = nil) -> MediaStream {
        MediaStream(codec: codec, type: "Video", language: nil, displayTitle: nil, channels: nil,
                    isDefault: nil, index: 0, height: 2160, width: 3840,
                    videoRangeType: range, colorTransfer: transfer, dvProfile: dv)
    }

    private func audio(_ codec: String, index: Int = 1, standard: Bool? = true) -> MediaStream {
        MediaStream(codec: codec, type: "Audio", language: nil, displayTitle: nil, channels: 6,
                    isDefault: standard, index: index, height: nil, width: nil)
    }

    private func subtitle(_ codec: String, index: Int) -> MediaStream {
        MediaStream(codec: codec, type: "Subtitle", language: nil, displayTitle: nil, channels: nil,
                    isDefault: nil, index: index, height: nil, width: nil)
    }

    private func source(_ streams: [MediaStream], defaultAudio: Int? = nil) -> MediaSource {
        let list = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(streams))
        var root: [String: Any] = ["Id": "s1", "Container": "mkv", "MediaStreams": list]
        if let defaultAudio { root["DefaultAudioStreamIndex"] = defaultAudio }
        return try! JSONDecoder().decode(MediaSource.self,
                                         from: JSONSerialization.data(withJSONObject: root))
    }

    private let full = EngineDevice(dolbyVision: true, hdr: true, av1: true)
    private let plain = EngineDevice(dolbyVision: false, hdr: false, av1: false)

    private func decide(_ source: MediaSource,
                        device: EngineDevice? = nil, software: Bool = false, failed: Bool = false,
                        audioIndex: Int? = nil, subtitleIndex: Int? = nil) -> EngineDecision {
        decide(.dolbyVision, source, device: device, software: software, failed: failed,
               audioIndex: audioIndex, subtitleIndex: subtitleIndex)
    }

    private func decide(_ setting: PlayerEngineSetting, _ source: MediaSource,
                        device: EngineDevice? = nil, software: Bool = false, failed: Bool = false,
                        audioIndex: Int? = nil, subtitleIndex: Int? = nil) -> EngineDecision {
        PlayerEngineChoice.decide(setting: setting, softwareDecoder: software, avFailed: failed,
                                  source: source, audioIndex: audioIndex,
                                  subtitleIndex: subtitleIndex, device: device ?? full)
    }

    // MARK: - Default mode

    @Test("Dolby Vision profile 8 and 5 go to AVPlayer")
    func dolbyVision() {
        for profile in [5, 8] {
            let s = source([video("hevc", range: .dolbyVision, dv: profile), audio("eac3")])
            #expect(decide(s).engine == .avPlayer)
        }
    }

    @Test("Dolby Vision profile 7 stays with VLC")
    func profile7() {
        let s = source([video("hevc", range: .dolbyVisionEL, dv: 7), audio("eac3")])
        #expect(decide(s).engine == .vlc)
        #expect(decide(.avPlayer, s).engine == .vlc)
    }

    @Test("Profile 5 without a Dolby Vision device is VLC, profile 8 with HDR10 base is HDR")
    func withoutDevice() {
        let five = source([video("hevc", range: .dolbyVision, dv: 5), audio("eac3")])
        #expect(decide(five, device: EngineDevice(dolbyVision: false, hdr: true, av1: false)).engine == .vlc)
        let eight = source([video("hevc", range: .dolbyVisionHDR10, dv: 8), audio("eac3")])
        #expect(decide(eight, device: EngineDevice(dolbyVision: false, hdr: true, av1: false)).engine == .avPlayer)
        #expect(decide(eight, device: plain).engine == .vlc)
    }

    @Test("HDR10 and HLG go to AVPlayer, SDR stays with VLC")
    func hdr() {
        #expect(decide(source([video("hevc", range: .hdr10), audio("ac3")])).engine == .avPlayer)
        #expect(decide(source([video("hevc", range: .hlg), audio("ac3")])).engine == .avPlayer)
        #expect(decide(source([video("hevc", transfer: "smpte2084"), audio("ac3")])).engine == .avPlayer)
        #expect(decide(source([video("hevc", range: .sdr), audio("ac3")])).engine == .vlc)
        #expect(decide(source([video("h264", range: .sdr), audio("aac")])).engine == .vlc)
    }

    @Test("AV1 goes to AVPlayer only with a hardware decoder")
    func av1() {
        let s = source([video("av1", range: .sdr), audio("eac3")])
        #expect(decide(s).engine == .avPlayer)
        #expect(decide(s, device: plain).engine == .vlc)
        #expect(decide(.avPlayer, s, device: plain).engine == .vlc)
    }

    // MARK: - What AVPlayer cannot play

    @Test("Codecs outside the HLS set are VLC, whatever the setting")
    func codecs() {
        let vp9 = source([video("vp9", range: .hdr10), audio("aac")])
        #expect(decide(vp9).engine == .vlc)
        #expect(decide(.avPlayer, vp9).engine == .vlc)
        let empty = source([audio("aac")])
        #expect(decide(.avPlayer, empty).engine == .vlc)   // unknown goes to VLC
    }

    @Test("DTS and TrueHD as the playing track send the title to VLC; another track can play")
    func sound() {
        let dts = source([video("hevc", range: .dolbyVision, dv: 8), audio("dts", index: 1),
                          audio("ac3", index: 2, standard: false)])
        #expect(decide(dts).engine == .vlc)
        #expect(decide(dts, audioIndex: 2).engine == .avPlayer)
        #expect(PlayerEngineChoice.audioTrack(of: dts) == nil)
        #expect(PlayerEngineChoice.audioTrack(of: dts, index: 2) == 2)
        let named = source([video("hevc", range: .dolbyVision, dv: 8), audio("dts", index: 1, standard: false),
                            audio("eac3", index: 2, standard: false)], defaultAudio: 2)
        #expect(decide(named).engine == .avPlayer)
    }

    @Test("A picture subtitle sends the title to VLC, a text subtitle does not")
    func subtitles() {
        let s = source([video("hevc", range: .hdr10), audio("eac3"),
                        subtitle("hdmv_pgs_subtitle", index: 2), subtitle("subrip", index: 3)])
        #expect(decide(s, subtitleIndex: 2).engine == .vlc)
        #expect(decide(s, subtitleIndex: 3).engine == .avPlayer)
        #expect(decide(s, subtitleIndex: -1).engine == .avPlayer)
        #expect(decide(s).engine == .avPlayer)
        #expect(PlayerEngineChoice.isImageSubtitle(codec: "PGSSUB"))
        #expect(!PlayerEngineChoice.isImageSubtitle(codec: "ass"))
    }

    // MARK: - Setting and state

    @Test("Software decoder and an earlier failure win over everything")
    func overrides() {
        let s = source([video("hevc", range: .dolbyVision, dv: 8), audio("eac3")])
        #expect(decide(.avPlayer, s, software: true).engine == .vlc)
        #expect(decide(.avPlayer, s, failed: true).engine == .vlc)
        #expect(decide(.vlc, s).engine == .vlc)
    }

    @Test("Always AVPlayer takes any playable title, also SDR H.264")
    func always() {
        let s = source([video("h264", range: .sdr), audio("aac")])
        #expect(decide(.avPlayer, s).engine == .avPlayer)
        #expect(decide(.dolbyVision, s).engine == .vlc)
    }

    @Test("Every decision carries a reason for the log")
    func reason() {
        let s = source([video("hevc", range: .dolbyVision, dv: 8), audio("eac3")])
        let d = decide(s)
        #expect(!d.reason.isEmpty)
        #expect(d.logLine.contains("AVPlayer"))
        #expect(decide(.vlc, s).logLine.contains("VLC"))
    }

    @Test("The setting reads Android's values, unknown means the default")
    func setting() {
        #expect(PlayerEngineSetting(stored: "exoplayer") == .avPlayer)
        #expect(PlayerEngineSetting(stored: "vlc") == .vlc)
        #expect(PlayerEngineSetting(stored: "dolbyVision") == .dolbyVision)
        #expect(PlayerEngineSetting(stored: nil) == .dolbyVision)
        #expect(PlayerEngineSetting(stored: "x") == .dolbyVision)
        #expect(PlayerEngineSetting.allCases.count == 3)
    }

    // MARK: - Stream copy

    @Test("Only container and tag reasons count as a copy")
    func copy() {
        func url(_ reasons: String?) -> URL {
            URL(string: "https://s/videos/1/master.m3u8?a=b" + (reasons.map { "&TranscodeReasons=\($0)" } ?? ""))!
        }
        #expect(PlayerEngineChoice.isCopyOnly(transcodingURL: nil))
        #expect(PlayerEngineChoice.isCopyOnly(transcodingURL: url(nil)))
        #expect(PlayerEngineChoice.isCopyOnly(transcodingURL: url("ContainerNotSupported")))
        #expect(PlayerEngineChoice.isCopyOnly(transcodingURL: url("ContainerNotSupported,VideoCodecTagNotSupported")))
        #expect(!PlayerEngineChoice.isCopyOnly(transcodingURL: url("ContainerNotSupported,VideoCodecNotSupported")))
        #expect(!PlayerEngineChoice.isCopyOnly(transcodingURL: url("SubtitleCodecNotSupported")))
    }
}

@Suite("AVPlayer profile")
struct AVPlayerProfileTests {
    @Test("AV1 is copied only when asked for")
    func av1() {
        let off = DeviceProfile.airplay()
        let on = DeviceProfile.airplay(av1: true)
        #expect(off.transcodingProfiles.allSatisfy { !$0.videoCodec.contains("av1") })
        #expect(on.transcodingProfiles.allSatisfy { $0.videoCodec.contains("av1") })
        #expect(on.transcodingProfiles.allSatisfy { $0.videoCodec.contains("hevc") })
    }
}
