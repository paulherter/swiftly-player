import Foundation
import Testing
@testable import JellyfinKit

/// **Diese Tests prüfen die Aussage, nicht den Wortlaut.**
///
/// Ein Test, der auf „10,3 GB" besteht, ist auf einem englischen Gerät rot,
/// obwohl die App recht hat — und genau der Fehler stand vorher im Code:
/// ein fest eingesetztes Komma. Deshalb wird hier gefragt, *was* dasteht
/// (die richtige Einheit, dieselbe Rechnung wie in der Downloadliste, kein
/// Trennzeichen vor dem Nichts) und nie, *wie* die Sprache es schreibt.
@Suite("Dateiangaben")
struct DateiangabenTests {

    private func quelle(container: String? = "mkv", bytes: Int64?) -> MediaSource {
        MediaSource(id: "a", name: "a", container: container, size: bytes,
                    supportsDirectPlay: true, supportsDirectStream: false,
                    supportsTranscoding: true, transcodingUrl: nil,
                    mediaStreams: [])
    }

    @Test("Kleine Dateien werden nicht in GB gemessen")
    func kleineDateiBekommtIhreEinheit() {
        // Vorher: „0,0 GB". Eine Tonspur ist keine leere Datei.
        let text = Dateiangaben.groesse(quelle(bytes: 112_000)).uppercased()
        #expect(text.contains("112"))
        #expect(text.contains("KB"))
        #expect(!text.contains("GB"))
    }

    @Test("Grosse Dateien bekommen GB")
    func grosseDateiBekommtGB() {
        let text = Dateiangaben.groesse(quelle(bytes: 10_300_000_000)).uppercased()
        #expect(text.contains("10"))
        #expect(text.contains("GB"))
    }

    @Test("Dieselbe Rechnung wie in der Downloadliste")
    func rechnetWieDieDownloadliste() {
        // Eine Datei darf im Auszug nicht anders gemessen sein als in der
        // Downloadliste. Das prüft die Gleichheit, nicht die Schreibweise —
        // damit gilt es in jeder Sprache.
        for bytes: Int64 in [112_000, 1_500_000_000, 10_300_000_000, 18_600_000_000] {
            #expect(Dateiangaben.groesse(quelle(bytes: bytes)) == Downloadregeln.groesse(bytes))
        }
    }

    @Test("Die Groesse bringt kein eigenes Trennzeichen mit")
    func groesseStehtAlleinLesbarDa() {
        // Mac und Linux zeigen die Zahl auch einzeln. Ein führendes „ · "
        // stand dort als Mittelpunkt vor dem Nichts.
        let text = Dateiangaben.groesse(quelle(bytes: 10_300_000_000))
        #expect(!text.contains("·"))
        #expect(text == text.trimmingCharacters(in: .whitespaces))
    }

    @Test("Ohne Groesse vom Server bleibt die Zeile leer")
    func ohneGroesseNichts() {
        #expect(Dateiangaben.groesse(quelle(bytes: nil)).isEmpty)
    }

    @Test("Container nennt Behaelter und Groesse")
    func containerNenntBeides() throws {
        let text = try #require(Dateiangaben.container(quelle(bytes: 10_300_000_000)))
        #expect(text.hasPrefix("MKV"))
        #expect(text.contains("·"))
        #expect(text.uppercased().contains("GB"))
    }

    @Test("Container ohne Groesse endet nicht im Trennzeichen")
    func containerOhneGroesse() throws {
        let text = try #require(Dateiangaben.container(quelle(bytes: nil)))
        #expect(text == "MKV")
    }

    @Test("Ohne Behaelter gibt es keine Containerzeile")
    func ohneContainerNichts() {
        #expect(Dateiangaben.container(quelle(container: nil, bytes: 10_300_000_000)) == nil)
    }
}
