import Foundation
import Testing
@testable import JellyfinKit

@Suite("Technikangaben")
struct TechnikangabenTests {

    @Test("Codecnamen werden lesbar, Unbekanntes bleibt erkennbar")
    func codecnamen() {
        #expect(Technikangaben.codecname("hevc") == "HEVC")
        #expect(Technikangaben.codecname("h264") == "H.264")
        #expect(Technikangaben.codecname("eac3") == "E-AC-3")
        #expect(Technikangaben.codecname("hdmv_pgs_subtitle") == "PGS")
        // Was wir nicht kennen, verschwindet nicht — es steht gross da.
        #expect(Technikangaben.codecname("wasauchimmer") == "WASAUCHIMMER")
        #expect(Technikangaben.codecname("") == nil)
        #expect(Technikangaben.codecname(nil) == nil)
    }

    @Test("libVLC-Kennungen werden zu denselben Codecnamen")
    func vlcKennungen() {
        func kennung(_ s: String) -> UInt32 {
            s.utf8.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        #expect(Technikangaben.codecname(vlcKennung: kennung("mp4a")) == "AAC")
        #expect(Technikangaben.codecname(vlcKennung: kennung("a52 ")) == "AC-3")
        #expect(Technikangaben.codecname(vlcKennung: kennung("dts ")) == "DTS")
        #expect(Technikangaben.codecname(vlcKennung: kennung("trhd")) == "TrueHD")
        #expect(Technikangaben.codecname(vlcKennung: kennung("xxxx")) == nil)
        #expect(Technikangaben.codecname(vlcKennung: 0) == nil)
    }

    @Test("Tonspurname: Sprache aus Kürzel oder Wort, Codec, Kanäle")
    func tonspurname() {
        let deutsch = Locale.current.localizedString(forLanguageCode: "deu") ?? "Deutsch"
        #expect(Technikangaben.tonspurname(sprache: "deu", codec: "AAC", kanaele: 6) == "\(deutsch) · AAC · 5.1")
        #expect(Technikangaben.tonspurname(sprache: "German", codec: "DTS", kanaele: 2) == "Deutsch · DTS · Stereo")
        #expect(Technikangaben.tonspurname(sprache: nil, codec: "AAC", kanaele: 2) == "AAC · Stereo")
        #expect(Technikangaben.tonspurname(sprache: "", codec: nil, kanaele: 0) == nil)
        #expect(Technikangaben.tonspurname(sprache: "ger", codec: nil, kanaele: nil)?.isEmpty == false)
        #expect(Technikangaben.tonspurname(sprache: "ger", codec: nil, kanaele: nil) != "ger")
    }

    @Test("Sechs Kanaele heissen 5.1, nicht sechs")
    func kanaele() {
        #expect(Technikangaben.kanalwort(6) == "5.1")
        #expect(Technikangaben.kanalwort(8) == "7.1")
        #expect(Technikangaben.kanalwort(2) == "Stereo")
        #expect(Technikangaben.kanalwort(1) == "Mono")
        #expect(Technikangaben.kanalwort(3) == "3 ch")
        #expect(Technikangaben.kanalwort(0) == nil)
        #expect(Technikangaben.kanalwort(nil) == nil)
    }

    @Test("Bitraten kippen bei einem Megabit")
    func bitraten() {
        #expect(Technikangaben.bitrate(12_400_000) == "12.4 Mbit/s")
        #expect(Technikangaben.bitrate(640_000) == "640 kbit/s")
        #expect(Technikangaben.bitrate(0) == nil)
        #expect(Technikangaben.bitrate(nil) == nil)
    }

    @Test("Bildrate zeigt 23,976, aber nicht 25,000")
    func bildraten() {
        #expect(Technikangaben.bildrate(23.976) == "23.976")
        #expect(Technikangaben.bildrate(25) == "25")
        #expect(Technikangaben.bildrate(59.94) == "59.94")
        #expect(Technikangaben.bildrate(0) == nil)
    }

    @Test("Die Bildzeile laesst SDR weg — das ist der Normalfall")
    func bildzeile() {
        #expect(Technikangaben.bildzeile(breite: 1920, hoehe: 1080,
                                         tiefe: 10, umfang: "HDR10")
                == "1920×1080 · 10 bit · HDR10")
        #expect(Technikangaben.bildzeile(breite: 1920, hoehe: 1080,
                                         tiefe: nil, umfang: "SDR")
                == "1920×1080")
        #expect(Technikangaben.bildzeile(breite: nil, hoehe: 1080,
                                         tiefe: nil, umfang: nil) == nil)
    }

    @Test("Nur die Umrechnung faellt farblich auf")
    func gewicht() {
        #expect(Technikangaben.gewicht(.directPlay) == .gut)
        #expect(Technikangaben.gewicht(.directStream) == .gut)
        #expect(Technikangaben.gewicht(.transcode) == .warnend)
    }
}
