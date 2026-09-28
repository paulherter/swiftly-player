import Foundation
import Testing
@testable import JellyfinKit

@Suite("Erstbild")
struct ErstbildTests {

    private func rat(video: Bool = true, aus: Bool = false, gezeigt: UInt64 = 0,
                     lauf: TimeInterval = 5, bisher: Erstbild.Stufe = .keine) -> Erstbild.Rat {
        Erstbild.rat(hatVideospur: video, ausgenommen: aus, gezeigt: gezeigt,
                     laufzeit: lauf, bisher: bisher)
    }

    @Test("Zwei Rettungen, dann Ruhe")
    func stufen() {
        #expect(rat(bisher: .keine) == .ausgabeNeu)
        #expect(rat(bisher: .ausgabeNeu) == .softwareDekoder)
        #expect(rat(bisher: .software) == .aufgeben)
        #expect(rat(bisher: .aufgegeben) == .nichts)
        var stufe = Erstbild.Stufe.keine
        var folge: [Erstbild.Rat] = []
        for _ in 0..<5 {
            let r = rat(bisher: stufe)
            folge.append(r)
            stufe = Erstbild.naechste(nach: r, bisher: stufe)
        }
        #expect(folge == [.ausgabeNeu, .softwareDekoder, .aufgeben, .nichts, .nichts])
    }

    @Test("Erst nach der Frist")
    func frist() {
        #expect(rat(lauf: 0) == .warten)
        #expect(rat(lauf: Erstbild.frist - 0.5) == .warten)
        #expect(rat(lauf: Erstbild.frist) == .ausgabeNeu)
    }

    @Test("Ein Bild, keine Bildspur oder ausgenommen: nichts")
    func ausnahmen() {
        #expect(rat(gezeigt: 1, lauf: 60) == .nichts)
        #expect(rat(video: false, lauf: 60) == .nichts)
        #expect(rat(aus: true, lauf: 60) == .nichts)
        #expect(rat(gezeigt: 1, bisher: .software) == .nichts)
    }

    @Test("Nur laufende Uhr zaehlt")
    func zuwachs() {
        #expect(Erstbild.zuwachs(vorher: nil, jetzt: 10) == 0)
        #expect(Erstbild.zuwachs(vorher: 10, jetzt: 10) == 0)      // Puffern, Pause
        #expect(Erstbild.zuwachs(vorher: 10, jetzt: 9) == 0)       // zurueck
        #expect(Erstbild.zuwachs(vorher: 10, jetzt: 11) == 1)
        #expect(Erstbild.zuwachs(vorher: 10, jetzt: 610) == 0)     // Sprung
        // Zehn Takte Puffern, dann vier Sekunden Film: erst dann faellig.
        var lauf: TimeInterval = 0
        var vorher: TimeInterval? = nil
        for t in [0.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3] {
            lauf += Erstbild.zuwachs(vorher: vorher, jetzt: t); vorher = t
        }
        #expect(rat(lauf: lauf) == .warten)
        lauf += Erstbild.zuwachs(vorher: vorher, jetzt: 4)
        #expect(rat(lauf: lauf) == .ausgabeNeu)
    }

    @Test("Hinweis nur nach einem Eingriff")
    func hinweis() {
        #expect(Erstbild.hinweis(.keine) == nil)
        #expect(Erstbild.hinweis(.software) != nil)
        #expect(Erstbild.hinweis(.aufgegeben) != nil)
    }
}

@Suite("Erstbild · Software von Anfang")
struct ErstbildSoftwareTests {
    @Test("MPEG-4 Part 2 unverändert → Software, sonst frei")
    func mpeg4() {
        #expect(Erstbild.softwareVonAnfang(bildcodec: "mpeg4", methode: .directPlay))
        #expect(Erstbild.softwareVonAnfang(bildcodec: "MPEG4", methode: .directStream))
        #expect(!Erstbild.softwareVonAnfang(bildcodec: "mpeg4", methode: .transcode))
        #expect(!Erstbild.softwareVonAnfang(bildcodec: "h264", methode: .directPlay))
        #expect(!Erstbild.softwareVonAnfang(bildcodec: "hevc", methode: .directPlay))
        #expect(!Erstbild.softwareVonAnfang(bildcodec: nil, methode: .directPlay))
    }
}

@Suite("Erstbild · Software von Anfang, von der Platte")
struct ErstbildPlatteTests {
    private func posten(_ codec: String?, _ q: Downloadqualitaet = .original) -> Downloadposten {
        Downloadposten(id: "1", konto: "k", art: .film, titel: "t", container: "avi",
                       bytes: 1, sehstand: nil, bildcodec: codec).inQualitaet(q)
    }

    @Test("Geladene XviD-Datei öffnet mit Software, H.264 frei")
    func platte() {
        let datei = URL(fileURLWithPath: "/x.avi")
        #expect(PlaybackPlan.vonDerPlatte(datei, container: "avi", bildcodec: "mpeg4").softwareDekoder)
        #expect(!PlaybackPlan.vonDerPlatte(datei, container: "mkv", bildcodec: "h264").softwareDekoder)
        #expect(!PlaybackPlan.vonDerPlatte(datei, container: "avi").softwareDekoder)
    }

    @Test("libVLC 3 schaltet auch die Hardware in avcodec ab")
    func desktop() {
        #expect(Erstbild.softwareOptionenDesktop == [Erstbild.softwareOption, ":avcodec-hw=none"])
    }

    @Test("Der Posten merkt den Codec nur fürs Original")
    func posten() {
        #expect(posten("mpeg4").bildcodec == "mpeg4")
        #expect(posten("mpeg4", .hd720).bildcodec == nil)
    }

    @Test("Eine Liste ohne Codec liest sich weiter, eine mit behält ihn")
    func liste() throws {
        let alt = #"{"id":"1","konto":"k","art":"film","titel":"t","bytes":1,"geladen":0,"stand":"fertig","gesehen":false,"angelegt":0,"nochAufDemServer":true}"#
        #expect(try JSONDecoder().decode(Downloadposten.self, from: Data(alt.utf8)).bildcodec == nil)
        let neu = try JSONDecoder().decode(Downloadposten.self, from: JSONEncoder().encode(posten("mpeg4")))
        #expect(neu.bildcodec == "mpeg4")
    }
}

@Suite("MediaSource · Bildcodec")
struct MediaSourceBildcodecTests {
    @Test("Erste Bildspur, nil ohne")
    func codec() throws {
        let q = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"MediaStreams":[{"Type":"Audio","Codec":"mp3"},{"Type":"Video","Codec":"mpeg4"}]}"#.utf8))
        #expect(q.bildcodec == "mpeg4")
        let leer = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"MediaStreams":[]}"#.utf8))
        #expect(leer.bildcodec == nil)
    }
}
