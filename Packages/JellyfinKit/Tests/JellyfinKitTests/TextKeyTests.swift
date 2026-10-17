#if !canImport(Darwin)
import Foundation
import Testing
@testable import JellyfinKit

/// Only outside Apple, where `String(localized:)` translates, not `TextCatalog`.
/// `%lld` reads 64 bits, even where `Int` has only 32 (armeabi-v7a).
@Suite struct TextKeyTests {
    @Test func numbersGoAs64BitFormat() {
        #expect(TextKey.Argument.figure(40).asFormatArgument is Int64)
    }

    @Test func runtimeWithTwoNumbers() {
        let catalog = TextCatalog(empty: "de")
        #expect(catalog.text("\(1) Std. \(40) Min.") == "1 Std. 40 Min.")
        #expect(catalog.text("Noch \(42) Minuten") == "Noch 42 Minuten")
    }

    /// Windows reports `de-DE`, not `de_DE`; both must lead to `de`.
    @Test func windowsLanguageNamesWithHyphen() {
        let w = TextCatalog.languageRequests(from: [:], system: ["de-DE", "en-US"])
        #expect(w == ["de-DE", "de", "en-US", "en"])
        #expect(TextCatalog.languageRequests(from: ["LANGUAGE": "de-AT"]).prefix(2) == ["de-AT", "de"])
        #expect(TextCatalog.languageRequests(from: ["LANG": "fr_FR.UTF-8"]) == ["fr-FR", "fr", "en"])
    }

    /// The language list comes from the `.lproj` folders, not only from `localizations`.
    @Test func languageFolderBundle() throws {
        let place = FileManager.default.temporaryDirectory
            .appendingPathComponent("katalog-\(UUID().uuidString)")
        for name in ["de.lproj", "en.lproj", "Base.lproj"] {
            try FileManager.default.createDirectory(at: place.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: place) }
        let bundle = try #require(Bundle(path: place.path))
        #expect(TextCatalog.languageFolder(in: bundle).isSuperset(of: ["de", "en"]))
        #expect(!TextCatalog.languageFolder(in: bundle).contains("Base"))
    }
}
#endif
