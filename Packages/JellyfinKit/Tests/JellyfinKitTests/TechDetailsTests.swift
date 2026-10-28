import Foundation
import Testing
@testable import JellyfinKit

@Suite("Technikangaben")
struct TechDetailsTests {

    @Test("Codecnamen werden lesbar, Unbekanntes bleibt erkennbar")
    func codecNames() {
        #expect(TechDetails.codecNameValue("hevc") == "HEVC")
        #expect(TechDetails.codecNameValue("h264") == "H.264")
        #expect(TechDetails.codecNameValue("eac3") == "E-AC-3")
        #expect(TechDetails.codecNameValue("hdmv_pgs_subtitle") == "PGS")
        // What is not recognized does not disappear; it is shown in full.
        #expect(TechDetails.codecNameValue("wasauchimmer") == "WASAUCHIMMER")
        #expect(TechDetails.codecNameValue("") == nil)
        #expect(TechDetails.codecNameValue(nil) == nil)
    }

    @Test("libVLC-Kennungen werden zu denselben Codecnamen")
    func vlcIds() {
        func identifier(_ s: String) -> UInt32 {
            s.utf8.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        #expect(TechDetails.codecNameValue(vlcId: identifier("mp4a")) == "AAC")
        #expect(TechDetails.codecNameValue(vlcId: identifier("a52 ")) == "AC-3")
        #expect(TechDetails.codecNameValue(vlcId: identifier("dts ")) == "DTS")
        #expect(TechDetails.codecNameValue(vlcId: identifier("trhd")) == "TrueHD")
        // libVLC 4 calls TrueHD `mlpa`, Jellyfin `truehd`; both must be named the same, or
        // track matching sees a contradiction where there is none.
        #expect(TechDetails.codecNameValue(vlcId: identifier("mlpa")) == TechDetails.codecNameValue("truehd"))
        #expect(TechDetails.codecNameValue(vlcId: identifier("wvtt")) == TechDetails.codecNameValue("webvtt"))
        #expect(TechDetails.codecNameValue(vlcId: identifier("stpp")) == TechDetails.codecNameValue("ttml"))
        #expect(TechDetails.codecNameValue(vlcId: identifier("dvbs")) == TechDetails.codecNameValue("DVBSUB"))
        #expect(TechDetails.codecNameValue(vlcId: identifier("spu ")) == TechDetails.codecNameValue("DVDSUB"))
        #expect(TechDetails.codecNameValue(vlcId: identifier("bdpg")) == TechDetails.codecNameValue("PGSSUB"))
        #expect(TechDetails.codecNameValue(vlcId: identifier("xxxx")) == nil)
        #expect(TechDetails.codecNameValue(vlcId: 0) == nil)
    }

    @Test("Tonspurname: Sprache aus Kürzel oder Wort, Codec, Kanäle")
    func audioTrackName() {
        let de = Locale(identifier: "de_DE")
        #expect(TechDetails.audioTrackName(language: "deu", codec: "AAC", channels: 6, locale: de) == "Deutsch · AAC · 5.1")
        #expect(TechDetails.audioTrackName(language: "German", codec: "DTS", channels: 2, locale: de) == "Deutsch · DTS · Stereo")
        #expect(TechDetails.audioTrackName(language: nil, codec: "AAC", channels: 2) == "AAC · Stereo")
        #expect(TechDetails.audioTrackName(language: "", codec: nil, channels: 0) == nil)
        #expect(TechDetails.audioTrackName(language: "ger", codec: nil, channels: nil)?.isEmpty == false)
        #expect(TechDetails.audioTrackName(language: "ger", codec: nil, channels: nil) != "ger")
    }

    @Test("Sechs Kanaele heissen 5.1, nicht sechs")
    func channels() {
        #expect(TechDetails.channelWord(6) == "5.1")
        #expect(TechDetails.channelWord(8) == "7.1")
        #expect(TechDetails.channelWord(2) == "Stereo")
        #expect(TechDetails.channelWord(1) == "Mono")
        #expect(TechDetails.channelWord(3) == "3 ch")
        #expect(TechDetails.channelWord(0) == nil)
        #expect(TechDetails.channelWord(nil) == nil)
    }

    @Test("Bitraten kippen bei einem Megabit")
    func bitrates() {
        #expect(TechDetails.bitrate(12_400_000) == "12.4 Mbit/s")
        #expect(TechDetails.bitrate(640_000) == "640 kbit/s")
        #expect(TechDetails.bitrate(0) == nil)
        #expect(TechDetails.bitrate(nil) == nil)
    }

    @Test("Bildrate zeigt 23,976, aber nicht 25,000")
    func frameRates() {
        #expect(TechDetails.frameRate(23.976) == "23.976")
        #expect(TechDetails.frameRate(25) == "25")
        #expect(TechDetails.frameRate(59.94) == "59.94")
        #expect(TechDetails.frameRate(0) == nil)
    }

    @Test("Die Bildzeile laesst SDR weg — das ist der Normalfall")
    func imageRow() {
        #expect(TechDetails.imageRow(width: 1920, height: 1080,
                                         depth: 10, reach: "HDR10")
                == "1920×1080 · 10 bit · HDR10")
        #expect(TechDetails.imageRow(width: 1920, height: 1080,
                                         depth: nil, reach: "SDR")
                == "1920×1080")
        #expect(TechDetails.imageRow(width: nil, height: 1080,
                                         depth: nil, reach: nil) == nil)
    }

    @Test("Nur die Umrechnung faellt farblich auf")
    func weight() {
        #expect(TechDetails.weight(.directPlay) == .good)
        #expect(TechDetails.weight(.directStream) == .good)
        #expect(TechDetails.weight(.transcode) == .cautionary)
    }

    private func track(_ type: ColorRange?, transfer: String? = nil,
                      profile: Int? = nil, compatible: Int? = nil) -> MediaStream {
        MediaStream(codec: "hevc", type: "Video", language: nil, displayTitle: nil,
                    channels: nil, isDefault: nil, index: 0, height: 2160, width: 3840,
                    videoRangeType: type, colorTransfer: transfer,
                    dvProfile: profile, dvBlSignalCompatibilityId: compatible)
    }

    @Test("HDR-Art: die Formate beim Namen, Dolby Vision mit Profil und Basisschicht")
    func dynamics() {
        #expect(TechDetails.dynamics(track(.sdr)) == "SDR")
        #expect(TechDetails.dynamics(track(.hdr10)) == "HDR10")
        #expect(TechDetails.dynamics(track(.hdr10Plus)) == "HDR10+")
        #expect(TechDetails.dynamics(track(.hlg)) == "HLG")
        #expect(TechDetails.dynamics(track(.dolbyVision, profile: 5, compatible: 0))
                == "Dolby Vision P5")
        #expect(TechDetails.dynamics(track(.dolbyVisionHDR10, profile: 8, compatible: 1))
                == "Dolby Vision P8.1 · HDR10")
        #expect(TechDetails.dynamics(track(.dolbyVisionEL, profile: 7, compatible: 6))
                == "Dolby Vision P7 · EL")
        #expect(TechDetails.dynamics(track(.dolbyVisionHLG, profile: 8, compatible: 4))
                == "Dolby Vision P8.4 · HLG")
        // Without a profile only what is certain is shown.
        #expect(TechDetails.dynamics(track(.dolbyVisionHDR10)) == "Dolby Vision · HDR10")
    }

    @Test("HDR-Art: ohne Typ zählt die Kennlinie, sonst steht nichts da")
    func dynamicsWithoutType() {
        #expect(TechDetails.dynamics(track(.unknown, transfer: "smpte2084")) == "HDR10")
        #expect(TechDetails.dynamics(track(nil, transfer: "arib-std-b67")) == "HLG")
        #expect(TechDetails.dynamics(track(.unknown)) == nil)
        #expect(TechDetails.dynamics(nil) == nil)
        // Invalid Dolby Vision plays as the base layer.
        #expect(TechDetails.dynamics(track(.dolbyVisionInvalid, transfer: "smpte2084"))
                == "HDR10")
        #expect(TechDetails.dynamics(track(.dolbyVisionInvalid)) == nil)
    }

    @Test("Dolby-Vision-Felder kommen aus der Serverantwort, auch als Zeichenkette")
    func dvOutJSON() throws {
        let raw = #"{"Codec":"hevc","Type":"Video","VideoRangeType":"DOVIWithHDR10","DvProfile":8,"DvBlSignalCompatibilityId":"1"}"#
        let s = try JSONDecoder().decode(MediaStream.self, from: Data(raw.utf8))
        #expect(s.dvProfile == 8)
        #expect(s.dvBlSignalCompatibilityId == 1)
        #expect(s.codec == "hevc")
        #expect(TechDetails.dynamics(s) == "Dolby Vision P8.1 · HDR10")
    }
}
