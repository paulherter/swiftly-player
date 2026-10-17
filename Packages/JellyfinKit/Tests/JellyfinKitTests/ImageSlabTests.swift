import Foundation
import Testing
@testable import JellyfinKit

@Suite("Bildplatte")
struct ImageSlabTests {

    private func freshFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bildplatte-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Dateiname ist stabil und hängt am Text")
    func fileName() {
        #expect(ImagePlate.fileName("") == "cbf29ce484222325")
        #expect(ImagePlate.fileName("a") == ImagePlate.fileName("a"))
        #expect(ImagePlate.fileName("a") != ImagePlate.fileName("b"))
    }

    @Test("Zwei Adressen desselben Bildes treffen dieselbe Datei, ohne tag keine")
    func name() {
        let atHome = URL(string: "http://192.168.1.5:8096/Items/x/Images/Primary?tag=1&ApiKey=a")!
        let onTheGo = URL(string: "https://s.example/Items/x/Images/Primary?tag=1&api_key=b")!
        #expect(ImagePlate.name(atHome) != nil)
        #expect(ImagePlate.name(atHome) == ImagePlate.name(onTheGo))
        #expect(ImagePlate.name(URL(string: "https://s/Items/x/Images/Primary")!) == nil)
    }

    @Test("Geschrieben wird gelesen, leer nie")
    func toAndBack() throws {
        let slab = ImagePlate(folder: freshFolder(), limit: 1_000)
        defer { try? FileManager.default.removeItem(at: slab.folder) }
        slab.write(Data([1, 2, 3]), "a")
        #expect(slab.read("a") == Data([1, 2, 3]))
        slab.write(Data(), "leer")
        #expect(slab.read("leer") == nil)
        #expect(slab.read("fehlt") == nil)
    }

    @Test("Aufräumen wirft die am längsten nicht gezeigten weg, bis drei Viertel")
    func cleanUp() throws {
        let slab = ImagePlate(folder: freshFolder(), limit: 300)
        defer { try? FileManager.default.removeItem(at: slab.folder) }
        let now = Date()
        for (i, name) in ["alt", "mittel", "neu", "neuer"].enumerated() {
            slab.write(Data(repeating: 7, count: 100), name)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(Double(i - 4) * 60)],
                ofItemAtPath: slab.folder.appendingPathComponent(name).path)
        }
        // "alt" was just shown, which makes it the most recent.
        _ = slab.read("alt")
        #expect(slab.cleanUp() == 2)
        #expect(slab.read("alt") != nil)
        #expect(slab.read("neuer") != nil)
        #expect(slab.read("mittel") == nil)
        #expect(slab.read("neu") == nil)
    }

    @Test("Unter der Grenze bleibt alles")
    func underLimit() {
        let slab = ImagePlate(folder: freshFolder(), limit: 1_000)
        defer { try? FileManager.default.removeItem(at: slab.folder) }
        slab.write(Data(repeating: 1, count: 100), "a")
        #expect(slab.cleanUp() == 0)
        #expect(slab.read("a") != nil)
    }
}
