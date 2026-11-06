import Foundation
import Testing
@testable import JellyfinKit

/// The desktop sync compares snapshots of the synced values to notice a local change.
/// A value whose text differs between two encodings of the same data looks like a new
/// change every time, saves again and starts the next sync: the loop of 1.1.0
/// ("Einstellungen zum Server geschrieben" every 0.4 s).
@Suite("Abgleich: gleicher Wert, gleicher Text")
struct SettingsSyncStableTextTests {

    @Test("Startbibliotheken geben bei jedem Kodieren denselben Text")
    func startLibrariesStable() {
        let choice = (0..<6).map { StartLibrary(id: "id\($0)", name: "Bibliothek \($0)", collection: $0 % 2 == 0) }
        let first = StartLibraries.data(choice)
        for _ in 0..<500 {
            #expect(StartLibraries.data(choice) == first)
        }
        // And what is sent is read back to the same choice.
        #expect(StartLibraries.read(first) == choice)
    }

    @Test("Ein Wert aus Startbibliotheken ändert den Schnappschuss nicht")
    func snapshotStable() throws {
        let choice = [StartLibrary(id: "a", name: "Filme", collection: false),
                      StartLibrary(id: "b", name: "Serien", collection: true)]
        let texts = Set((0..<500).map { _ in
            SettingsSync.Value.json(StartLibraries.data(choice) ?? Data()).encoded
        })
        #expect(texts.count == 1)
    }
}
