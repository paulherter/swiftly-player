#if !canImport(Darwin)
import Foundation
import Testing
@testable import JellyfinKit

/// Nur ausserhalb von Apple — dort uebersetzt `String(localized:)`, nicht `Textkatalog`.
/// `%lld` liest 64 Bit — auch dort, wo `Int` nur 32 Bit hat (armeabi-v7a).
@Suite struct TextschluesselTests {
    @Test func zahlenGehenAls64BitInsFormat() {
        #expect(Textschluessel.Argument.zahl(40).alsFormatargument is Int64)
    }

    @Test func laufzeitMitZweiZahlen() {
        let katalog = Textkatalog(leer: "de")
        #expect(katalog.text("\(1) Std. \(40) Min.") == "1 Std. 40 Min.")
        #expect(katalog.text("Noch \(42) Minuten") == "Noch 42 Minuten")
    }

    /// Windows meldet `de-DE`, nicht `de_DE` — beides muss auf `de` fuehren.
    @Test func windowsSprachnamenMitBindestrich() {
        let w = Textkatalog.sprachwuensche(aus: [:], system: ["de-DE", "en-US"])
        #expect(w == ["de-DE", "de", "en-US", "en"])
        #expect(Textkatalog.sprachwuensche(aus: ["LANGUAGE": "de-AT"]).prefix(2) == ["de-AT", "de"])
        #expect(Textkatalog.sprachwuensche(aus: ["LANG": "fr_FR.UTF-8"]) == ["fr-FR", "fr", "en"])
    }

    /// Die Sprachliste kommt aus den `.lproj`-Ordnern, nicht nur aus `localizations`.
    @Test func sprachordnerImBuendel() throws {
        let ort = FileManager.default.temporaryDirectory
            .appendingPathComponent("katalog-\(UUID().uuidString)")
        for name in ["de.lproj", "en.lproj", "Base.lproj"] {
            try FileManager.default.createDirectory(at: ort.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: ort) }
        let buendel = try #require(Bundle(path: ort.path))
        #expect(Textkatalog.sprachordner(in: buendel).isSuperset(of: ["de", "en"]))
        #expect(!Textkatalog.sprachordner(in: buendel).contains("Base"))
    }
}
#endif
