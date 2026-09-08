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
