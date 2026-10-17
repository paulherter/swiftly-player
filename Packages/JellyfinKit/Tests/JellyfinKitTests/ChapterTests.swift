import Foundation
import Testing
@testable import JellyfinKit

@Suite("Kapitel einlesen")
struct ChapterInReadTests {

    /// The shape of `ChapterInfo` on a title as it arrives with
    /// `Fields=Chapters`, with the fields from the OpenAPI description.
    private let answer = """
    { "Id": "f1", "Name": "Film",
      "Chapters": [
        { "StartPositionTicks": 0, "Name": "Prolog",
          "ImageDateModified": "0001-01-01T00:00:00.0000000Z" },
        { "StartPositionTicks": 4235000000, "Name": "  Der Überfall ",
          "ImageTag": "abc", "ImageDateModified": "2026-01-01T00:00:00.0000000Z" },
        { "StartPositionTicks": 31500000000 }
      ] }
    """.data(using: .utf8)!

    @Test("Ticks werden zu Sekunden, Namen ohne Rand")
    func inRead() throws {
        let k = try JSONDecoder().decode(ChapterResponse.self, from: answer).chapter
        #expect(k.count == 3)
        #expect(k[0] == Chapter(name: "Prolog", from: 0))
        #expect(k[1] == Chapter(name: "Der Überfall", from: 423.5))
        // Without a name, an empty one, not an error.
        #expect(k[2] == Chapter(name: "", from: 3150))
    }

    @Test("Ohne Kapitel am Titel: leer, kein Fehler")
    func without() throws {
        let d = #"{ "Id": "f1", "Name": "Film" }"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ChapterResponse.self, from: d).chapter.isEmpty)
        let n = #"{ "Chapters": null }"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ChapterResponse.self, from: n).chapter.isEmpty)
    }

    @Test("Ein Kapitel ohne Anfang fällt weg, die anderen bleiben")
    func withoutStart() throws {
        let d = #"{ "Chapters": [ { "Name": "Kaputt" }, { "StartPositionTicks": "neun" },"#
            + #" { "StartPositionTicks": 600000000, "Name": "Echt" }, 42, null ] }"#
        let k = try JSONDecoder().decode(ChapterResponse.self, from: Data(d.utf8)).chapter
        #expect(k == [Chapter(name: "Echt", from: 60)])
    }
}

@Suite("Welche Kapitel die Leiste gliedern")
struct ChapterUsableTests {

    private func k(_ from: Double, _ name: String = "") -> Chapter { Chapter(name: name, from: from) }

    @Test("Sortiert und ohne doppelte Anfänge — das erste gilt")
    func sorted() {
        let raw = [k(900, "C"), k(0, "A"), k(300, "B"), k(300, "B2")]
        #expect(ChapterBar.usable(raw).map(\.name) == ["A", "B", "C"])
    }

    @Test("Ein einziges Kapitel teilt nichts")
    func single() {
        #expect(ChapterBar.usable([k(0, "Film")]).isEmpty)
        #expect(ChapterBar.usable([]).isEmpty)
    }

    @Test("Unsinn fällt weg, bevor gezählt wird")
    func unsinn() {
        #expect(ChapterBar.usable([k(-5), k(.nan), k(.infinity), k(60)]).isEmpty)
        #expect(ChapterBar.usable([k(-5), k(0), k(60)]).map(\.from) == [0, 60])
    }

    @Test("Das Platzhalterraster des Servers gliedert nichts")
    func grid() {
        // DummyChapterDuration = 300: one every five minutes, starting at 0.
        let placeholder = (0..<9).map { k(Double($0) * 300, "Kapitel \($0 + 1)") }
        #expect(ChapterBar.usable(placeholder).isEmpty)
    }

    @Test("Echte Kapitel liegen nie auf die Sekunde gleich weit — sie bleiben")
    func realChapter() {
        let disc = [k(0), k(312.4), k(655.1), k(1020.8), k(1301)]
        #expect(ChapterBar.usable(disc).count == 5)
    }

    @Test("Ein gleichmäßiges Raster, das nicht bei 0 anfängt, ist keins vom Server")
    func gridNotOffNull() {
        #expect(ChapterBar.usable([k(90), k(390), k(690)]).count == 3)
    }

    @Test("Ein Raster mit kleinen Abweichungen bleibt ein Raster")
    func gridWithPlay() {
        #expect(ChapterBar.usable([k(0), k(300.2), k(600), k(900.3)]).isEmpty)
    }

    @Test("Zwei Kapitel sind noch kein Raster")
    func twoChapter() {
        #expect(ChapterBar.usable([k(0), k(300)]).count == 2)
    }
}

@Suite("Die geteilte Leiste")
struct ChapterBarTests {

    private typealias Piece = ChapterBar.Piece

    @Test("Grenzen: ohne den Anfang bei 0 und ohne alles ab dem Ende")
    func limits() {
        let chapter = [Chapter(name: "A", from: 0), Chapter(name: "B", from: 600),
                       Chapter(name: "C", from: 1800), Chapter(name: "D", from: 3000)]
        #expect(ChapterBar.limits(chapter, duration: 2400) == [600, 1800])
        // Nothing is cut while VLC does not know the duration.
        #expect(ChapterBar.limits(chapter, duration: 0).isEmpty)
    }

    @Test("Ohne Grenzen ist die Leiste ein Stück — wie vorher")
    func withoutLimits() {
        let whole = [Piece(from: 0, until: 1)]
        #expect(ChapterBar.pieces(limits: [], duration: 2400, width: 300, minWidth: 8) == whole)
        #expect(ChapterBar.pieces(limits: [600], duration: 0, width: 300, minWidth: 8) == whole)
        #expect(ChapterBar.pieces(limits: [600], duration: 2400, width: 0, minWidth: 8) == whole)
    }

    @Test("Jede Grenze ein Schnitt, als Anteil")
    func cuts() {
        let s = ChapterBar.pieces(limits: [1800, 600], duration: 2400, width: 300, minWidth: 8)
        #expect(s == [Piece(from: 0, until: 0.25), Piece(from: 0.25, until: 0.75), Piece(from: 0.75, until: 1)])
    }

    @Test("Zu enge Schnitte fallen weg, das Stück davor reicht weiter")
    func tooNarrow() {
        // 300 points for 3000 s: one point is ten seconds, eight points 80 s.
        let s = ChapterBar.pieces(limits: [600, 650, 700, 2960], duration: 3000,
                                      width: 300, minWidth: 8)
        // 650 would sit 5 points past 600 and is dropped; 700 would sit 10 past, and stays.
        // 2960 would leave only 4 points at the end.
        #expect(s.map(\.from) == [0, 0.2, 700.0 / 3000])
        #expect(s.last?.until == 1)
    }

    @Test("Die Lücke geht je zur Hälfte ab, an den Enden nichts")
    func frameRect() {
        let s = ChapterBar.pieces(limits: [100], duration: 400, width: 200, minWidth: 8)
        let left = s[0].frameRect(width: 200, gap: 2)
        let right = s[1].frameRect(width: 200, gap: 2)
        #expect(left.x == 0 && left.width == 49)
        #expect(right.x == 51 && right.width == 149)
        let whole = Piece(from: 0, until: 1).frameRect(width: 200, gap: 2)
        #expect(whole.x == 0 && whole.width == 200)
        // In the middle, something is taken off from both sides.
        let center = Piece(from: 0.25, until: 0.75).frameRect(width: 200, gap: 2)
        #expect(center.x == 51 && center.width == 98)
    }

    @Test("Eingerastet wird nur an Schnitten mit Platz auf beiden Seiten")
    func snapCuts() {
        // 300 points for 3000 s; each neighbouring piece needs 4 × 8 = 32 points.
        let s = ChapterBar.pieces(limits: [600, 900, 1100, 2000], duration: 3000,
                                      width: 300, minWidth: 8)
        #expect(s.count == 5)
        // The pieces are 60, 30, 20, 90 and 100 points wide. All cuts are
        // drawn; only the one at 2000 may snap, every other one
        // has a piece under 32 points on one side.
        #expect(ChapterBar.snapCuts(s, duration: 3000, width: 300) == [2000])
        #expect(ChapterBar.snapCuts([Piece(from: 0, until: 1)], duration: 3000, width: 300).isEmpty)
    }

    @Test("Dreissig Kapitel auf schmaler Leiste: gezeichnet, aber kein Einrasten")
    func densityChapter() {
        let limits = (1..<30).map { Double($0) * 240 }   // 2 h, every 4 min
        let s = ChapterBar.pieces(limits: limits, duration: 7200, width: 280, minWidth: 8)
        #expect(s.count == 30)
        #expect(ChapterBar.snapCuts(s, duration: 7200, width: 280).isEmpty)
    }

    @Test("Eine Grenze gehört zum Stück, das dort anfängt")
    func pieceAt() {
        let s = [Piece(from: 0, until: 0.25), Piece(from: 0.25, until: 1)]
        #expect(ChapterBar.piece(at: 0, in: s) == 0)
        #expect(ChapterBar.piece(at: 0.2499, in: s) == 0)
        #expect(ChapterBar.piece(at: 0.25, in: s) == 1)
        #expect(ChapterBar.piece(at: 1, in: s) == 1)
        #expect(ChapterBar.piece(at: .nan, in: s) == nil)
        #expect(ChapterBar.piece(at: 0.5, in: []) == nil)
    }

    @Test("Das Kapitel an einer Stelle — vor dem ersten keins")
    func chapterAt() {
        let chapter = [Chapter(name: "Anfang", from: 30), Chapter(name: "Mitte", from: 600)]
        #expect(ChapterBar.chapter(at: 10, in: chapter) == nil)
        #expect(ChapterBar.chapter(at: 30, in: chapter)?.name == "Anfang")
        #expect(ChapterBar.chapter(at: 599.9, in: chapter)?.name == "Anfang")
        #expect(ChapterBar.chapter(at: 4000, in: chapter)?.name == "Mitte")
    }

    @Test("Eingerastet auf einem Schnitt heisst: das Kapitel, das dort anfängt")
    func snappedNamesCorrectDirection() {
        // Converted back via the fraction, the position often lands just before.
        let chapter = [Chapter(name: "A", from: 0), Chapter(name: "B", from: 1234.567)]
        for duration in [2468.9, 3000.1, 5423.77, 7199.3] {
            let s = ChapterBar.pieces(limits: ChapterBar.limits(chapter, duration: duration),
                                          duration: duration, width: 600, minWidth: 8)
            let cut = ChapterBar.snapCuts(s, duration: duration, width: 600)[0]
            #expect(ChapterBar.chapter(at: cut, in: chapter)?.name == "B")
            #expect(ChapterBar.chapter(at: duration * (cut / duration), in: chapter)?.name == "B")
        }
        #expect(ChapterBar.chapter(at: 1234.567 - 1e-9, in: chapter)?.name == "B")
        #expect(ChapterBar.chapter(at: 1234.5, in: chapter)?.name == "A")
    }

    @Test("Ein weggefallener Schnitt nimmt dem Kapitel nicht den Namen")
    func nameDespiteTooNarrow() {
        let chapter = [Chapter(name: "A", from: 0), Chapter(name: "B", from: 600),
                       Chapter(name: "C", from: 650)]
        let s = ChapterBar.pieces(limits: ChapterBar.limits(chapter, duration: 3000),
                                      duration: 3000, width: 300, minWidth: 8)
        #expect(s.count == 2)
        #expect(ChapterBar.chapter(at: 660, in: chapter)?.name == "C")
    }
}
