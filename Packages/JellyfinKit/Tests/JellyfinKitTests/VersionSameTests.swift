import Testing
@testable import JellyfinKit

@Suite("Fassungsvergleich")
struct VersionSameTests {

    @Test("Eine hoehere Fassung ist neuer")
    func higherVersion() {
        #expect(VersionComparison.newer(there: "1.0.4", here: "1.0.3"))
        #expect(VersionComparison.newer(there: "1.1.0", here: "1.0.9"))
        #expect(VersionComparison.newer(there: "2.0.0", here: "1.9.9"))
    }

    @Test("Eine niedrigere oder gleiche ist es nicht")
    func notNew() {
        #expect(!VersionComparison.newer(there: "1.0.2", here: "1.0.3"))
        #expect(!VersionComparison.newer(there: "1.0.3", here: "1.0.3"))
        #expect(!VersionComparison.newer(there: "0.9.9", here: "1.0.0"))
    }

    /// The reason this rule lives in the package and not in the Windows
    /// version: compared as strings, 1.0.10 would be older.
    @Test("Zehn ist groesser als neun, nicht kleiner")
    func twoDigit() {
        #expect(VersionComparison.newer(there: "1.0.10", here: "1.0.9"))
        #expect(!VersionComparison.newer(there: "1.0.9", here: "1.0.10"))
    }

    @Test("Fehlende Stellen zaehlen als null")
    func errorEndSet() {
        #expect(!VersionComparison.newer(there: "1.1", here: "1.1.0"))
        #expect(VersionComparison.newer(there: "1.2", here: "1.1.9"))
    }

    @Test("Gleiche Fassung, hoeherer Bau: neuer")
    func higherBuild() {
        #expect(VersionComparison.newer(there: "1.0.3", here: "1.0.3", buildThere: 2, buildHere: 1))
        #expect(!VersionComparison.newer(there: "1.0.3", here: "1.0.3", buildThere: 2, buildHere: 2))
        #expect(!VersionComparison.newer(there: "1.0.3", here: "1.0.3", buildThere: 1, buildHere: 7))
    }

    @Test("Ohne Baunummer gilt gleiche Fassung als derselbe Stand")
    func withoutBuildNumber() {
        #expect(!VersionComparison.newer(there: "1.0.3", here: "1.0.3", buildHere: 1))
    }

    @Test("Eine hoehere Fassung schlaegt jede Baunummer")
    func versionPreBuild() {
        #expect(VersionComparison.newer(there: "1.0.4", here: "1.0.3", buildThere: 1, buildHere: 99))
    }

    @Test("Die Baunummer wird aus dem Text gelesen")
    func buildNumberRead() {
        #expect(VersionComparison.buildNumber(fromText: "## Update — September 20 (build 2, Windows)") == 2)
        #expect(VersionComparison.buildNumber(fromText: "Neu in Bau 7: schneller") == 7)
        #expect(VersionComparison.buildNumber(fromText: "Nichts davon") == nil)
    }

    @Test("Nur das ganze Wort zaehlt, nicht „Umbau 12“ oder „rebuild 9“")
    func buildNumberOnlyAsWord() {
        #expect(VersionComparison.buildNumber(fromText: "Umbau 12 der Suche") == nil)
        #expect(VersionComparison.buildNumber(fromText: "rebuild 9 caches, build 3") == 3)
        #expect(VersionComparison.buildNumber(fromText: "(Build 4)") == 4)
    }

    /// A text that lists several builds names the oldest first.
    @Test("Die groesste genannte Zahl gewinnt")
    func largestNumber() {
        let text = "build 2 brachte X\n\nbuild 7 bringt Y"
        #expect(VersionComparison.buildNumber(fromText: text) == 7)
    }
}
