import Foundation
import Testing
@testable import JellyfinKit

/// **These tests check the statement, not the wording.**
///
/// A test that insists on "10,3 GB" is red on an English device even
/// though the app is right, and that was exactly the bug in the code before:
/// a hard-coded comma. So the question here is *what* is shown
/// (the right unit, the same calculation as in the download list, no
/// separator before nothing) and never *how* the language writes it.
@Suite("Dateiangaben")
struct FileDetailsTests {

    private func source(container: String? = "mkv", bytes: Int64?) -> MediaSource {
        MediaSource(id: "a", name: "a", container: container, size: bytes,
                    supportsDirectPlay: true, supportsDirectStream: false,
                    supportsTranscoding: true, transcodingUrl: nil,
                    mediaStreams: [])
    }

    @Test("Kleine Dateien werden nicht in GB gemessen")
    func smallFileGetsItsUnit() {
        // Before: "0,0 GB". An audio track is not an empty file.
        let text = FileDetails.size(source(bytes: 112_000)).uppercased()
        #expect(text.contains("112"))
        #expect(text.contains("KB"))
        #expect(!text.contains("GB"))
    }

    @Test("Grosse Dateien bekommen GB")
    func largeFileGetsGB() {
        let text = FileDetails.size(source(bytes: 10_300_000_000)).uppercased()
        #expect(text.contains("10"))
        #expect(text.contains("GB"))
    }

    @Test("Dieselbe Rechnung wie in der Downloadliste")
    func computesHowDownloadList() {
        // A file must not be measured differently in the excerpt than in the
        // download list. This checks equality, not spelling,
        // so it holds in every language.
        for bytes: Int64 in [112_000, 1_500_000_000, 10_300_000_000, 18_600_000_000] {
            #expect(FileDetails.size(source(bytes: bytes)) == DownloadRules.size(bytes))
        }
    }

    @Test("Die Groesse bringt kein eigenes Trennzeichen mit")
    func sizeStandsAllReadablePresent() {
        // Mac and Linux also show the number on its own. A leading " · "
        // used to appear there as a middle dot before nothing.
        let text = FileDetails.size(source(bytes: 10_300_000_000))
        #expect(!text.contains("·"))
        #expect(text == text.trimmingCharacters(in: .whitespaces))
    }

    @Test("Ohne Groesse vom Server bleibt die Zeile leer")
    func withoutSizeNot() {
        #expect(FileDetails.size(source(bytes: nil)).isEmpty)
    }

    @Test("Container nennt Behaelter und Groesse")
    func containerNames() throws {
        let text = try #require(FileDetails.container(source(bytes: 10_300_000_000)))
        #expect(text.hasPrefix("MKV"))
        #expect(text.contains("·"))
        #expect(text.uppercased().contains("GB"))
    }

    @Test("Container ohne Groesse endet nicht im Trennzeichen")
    func containerWithoutSize() throws {
        let text = try #require(FileDetails.container(source(bytes: nil)))
        #expect(text == "MKV")
    }

    @Test("Ohne Behaelter gibt es keine Containerzeile")
    func withoutContainerNot() {
        #expect(FileDetails.container(source(container: nil, bytes: 10_300_000_000)) == nil)
    }
}
