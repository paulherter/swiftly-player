import Foundation
import Testing
@testable import JellyfinKit

@Suite("Bildplatte")
struct BildplatteTests {

    private func frischerOrdner() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bildplatte-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Dateiname ist stabil und hängt am Text")
    func dateiname() {
        #expect(Bildplatte.dateiname("") == "cbf29ce484222325")
        #expect(Bildplatte.dateiname("a") == Bildplatte.dateiname("a"))
        #expect(Bildplatte.dateiname("a") != Bildplatte.dateiname("b"))
    }

    @Test("Zwei Adressen desselben Bildes treffen dieselbe Datei, ohne tag keine")
    func name() {
        let daheim = URL(string: "http://192.168.1.5:8096/Items/x/Images/Primary?tag=1&ApiKey=a")!
        let unterwegs = URL(string: "https://s.example/Items/x/Images/Primary?tag=1&api_key=b")!
        #expect(Bildplatte.name(daheim) != nil)
        #expect(Bildplatte.name(daheim) == Bildplatte.name(unterwegs))
        #expect(Bildplatte.name(URL(string: "https://s/Items/x/Images/Primary")!) == nil)
    }

    @Test("Geschrieben wird gelesen, leer nie")
    func hinUndZurueck() throws {
        let platte = Bildplatte(ordner: frischerOrdner(), grenze: 1_000)
        defer { try? FileManager.default.removeItem(at: platte.ordner) }
        platte.schreiben(Data([1, 2, 3]), "a")
        #expect(platte.lesen("a") == Data([1, 2, 3]))
        platte.schreiben(Data(), "leer")
        #expect(platte.lesen("leer") == nil)
        #expect(platte.lesen("fehlt") == nil)
    }

    @Test("Aufräumen wirft die am längsten nicht gezeigten weg, bis drei Viertel")
    func aufraeumen() throws {
        let platte = Bildplatte(ordner: frischerOrdner(), grenze: 300)
        defer { try? FileManager.default.removeItem(at: platte.ordner) }
        let jetzt = Date()
        for (i, name) in ["alt", "mittel", "neu", "neuer"].enumerated() {
            platte.schreiben(Data(repeating: 7, count: 100), name)
            try FileManager.default.setAttributes(
                [.modificationDate: jetzt.addingTimeInterval(Double(i - 4) * 60)],
                ofItemAtPath: platte.ordner.appendingPathComponent(name).path)
        }
        // „alt" wurde gerade gezeigt — damit ist es das jüngste.
        _ = platte.lesen("alt")
        #expect(platte.aufraeumen() == 2)
        #expect(platte.lesen("alt") != nil)
        #expect(platte.lesen("neuer") != nil)
        #expect(platte.lesen("mittel") == nil)
        #expect(platte.lesen("neu") == nil)
    }

    @Test("Unter der Grenze bleibt alles")
    func unterGrenze() {
        let platte = Bildplatte(ordner: frischerOrdner(), grenze: 1_000)
        defer { try? FileManager.default.removeItem(at: platte.ordner) }
        platte.schreiben(Data(repeating: 1, count: 100), "a")
        #expect(platte.aufraeumen() == 0)
        #expect(platte.lesen("a") != nil)
    }
}
