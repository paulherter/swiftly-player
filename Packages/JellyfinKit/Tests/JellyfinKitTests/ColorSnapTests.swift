import Foundation
import Testing
@testable import JellyfinKit

@Suite("Farbumfang")
struct ColorSnapTests {

    @Test("Was HDR ist und was nicht")
    func isHDR() {
        #expect(ColorRange.hdr10.isHDR)
        #expect(ColorRange.hlg.isHDR)
        #expect(ColorRange.dolbyVision.isHDR)
        #expect(ColorRange.hdr10Plus.isHDR)
        #expect(!ColorRange.sdr.isHDR)
        #expect(!ColorRange.unknown.isHDR)
        // Dolby Vision **over** SDR is not HDR; the name is misleading.
        #expect(!ColorRange.dolbyVisionSDR.isHDR)
        #expect(!ColorRange.dolbyVisionInvalid.isHDR)
    }

    @Test("PQ und HLG sind nicht austauschbar")
    func curve() {
        #expect(ColorRange.hdr10.curve == .pq)
        #expect(ColorRange.hdr10Plus.curve == .pq)
        #expect(ColorRange.dolbyVision.curve == .pq)
        #expect(ColorRange.hlg.curve == .hlg)
        #expect(ColorRange.dolbyVisionHLG.curve == .hlg)
        #expect(ColorRange.sdr.curve == nil)
        #expect(ColorRange.unknown.curve == nil)
    }

    @Test("Der Typ des Servers gilt zuerst")
    func typeAppliesFirst() {
        #expect(ColorInfo.reach(type: .hlg, curve: "smpte2084",
                                    primaries: "bt2020") == .hlg)
    }

    @Test("Sagt der Typ nichts, tragen die rohen Angaben")
    func rawDetails() {
        // The case: a file the server never analyzed.
        #expect(ColorInfo.reach(type: .unknown, curve: "smpte2084",
                                    primaries: "bt2020") == .hdr10)
        #expect(ColorInfo.reach(type: nil, curve: "arib-std-b67",
                                    primaries: nil) == .hlg)
    }

    @Test("Weite Primärvalenzen allein sind kein HDR")
    func bt2020IsNoHDR() {
        // BT.2020 also exists in SDR. Guessing would be worse than leaving it.
        #expect(ColorInfo.reach(type: nil, curve: nil,
                                    primaries: "bt2020") == .unknown)
    }

    @Test("Ohne jede Angabe wird nichts behauptet")
    func atAllNot() {
        #expect(ColorInfo.reach(type: nil, curve: nil,
                                    primaries: nil) == .unknown)
    }

    @Test("Aus der Serverantwort gelesen")
    func outJSON() throws {
        let raw = #"{"Type":"Video","Codec":"hevc","VideoRangeType":"HDR10","ColorTransfer":"smpte2084","ColorPrimaries":"bt2020"}"#
        let s = try JSONDecoder().decode(MediaStream.self, from: Data(raw.utf8))
        #expect(s.videoRangeType == .hdr10)
        #expect(s.colorTransfer == "smpte2084")
    }

    @Test("Eine unbekannte Schreibweise wirft nicht")
    func unknownValue() throws {
        // Jellyfin can add values; a new version must not
        // kill the app.
        let raw = #"{"Type":"Video","Codec":"hevc","VideoRangeType":"HDR42"}"#
        // **`try`, not `try?`.** With `try?` this test would also pass
        // when decoding fails completely, and that would be the bug itself:
        // a new value would make `MediaStream` unreadable and the file
        // would have no details at all.
        let s = try JSONDecoder().decode(MediaStream.self, from: Data(raw.utf8))
        #expect(s.codec == "hevc", "der Rest muss trotzdem ankommen")
        #expect(s.videoRangeType == nil)
    }

    private func track(_ type: ColorRange?, _ curve: String?) -> MediaStream {
        MediaStream(codec: "hevc", type: "Video", language: nil, displayTitle: nil,
                    channels: nil, isDefault: nil, index: 0, height: 2160, width: 3840,
                    videoRangeType: type, colorTransfer: curve, colorPrimaries: "bt2020")
    }

    @Test("Kennlinie der Bildspur fuer den eigenen Zeichenweg")
    func idLineTrack() {
        #expect(ColorInfo.curve(videoTrack: track(.hdr10, "smpte2084")) == .pq)
        #expect(ColorInfo.curve(videoTrack: track(.dolbyVisionHDR10, nil)) == .pq)
        #expect(ColorInfo.curve(videoTrack: track(.hlg, nil)) == .hlg)
        #expect(ColorInfo.curve(videoTrack: track(.sdr, nil)) == nil)
        #expect(ColorInfo.curve(videoTrack: track(nil, nil)) == nil)
        #expect(ColorInfo.curve(videoTrack: nil) == nil)
        // Invalid Dolby Vision: the base layer counts, so the raw values.
        #expect(ColorInfo.curve(videoTrack: track(.dolbyVisionInvalid, "smpte2084")) == .pq)
        #expect(ColorInfo.curve(videoTrack: track(.dolbyVisionInvalid, "bt709")) == nil)
        // Without a type the raw values apply.
        #expect(ColorInfo.curve(videoTrack: track(nil, "arib-std-b67")) == .hlg)
    }
}
