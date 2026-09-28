import Testing
@testable import JellyfinKit

@Suite struct DownloadaufgabeTests {
    @Test func hinUndZurueck() {
        let text = Downloadaufgabe.beschreibung(id: "abc", generation: 42, datei: "abc.mkv")
        #expect(Downloadaufgabe.zerlegen(text)
                == .init(id: "abc", generation: 42, datei: "abc.mkv"))
    }

    @Test func alteFormBekommtNull() {
        #expect(Downloadaufgabe.zerlegen("abc\u{1F}abc.mp4")
                == .init(id: "abc", generation: 0, datei: "abc.mp4"))
    }

    @Test func unbrauchbar() {
        #expect(Downloadaufgabe.zerlegen(nil) == nil)
        #expect(Downloadaufgabe.zerlegen("nur-ein-teil") == nil)
        #expect(Downloadaufgabe.zerlegen("\u{1F}datei") == nil)
    }

    /// Der gemeldete Fall: anhalten, fortsetzen, und dann kommt der Abbruch
    /// der alten Aufgabe an.
    @Test func spaeteMeldungDerAltenAufgabeZaehltNicht() {
        let alt = 7, neu = 9
        #expect(!Downloadaufgabe.gilt(gemeldet: alt, aktuell: neu))
        #expect(Downloadaufgabe.gilt(gemeldet: neu, aktuell: neu))
    }

    @Test func unbekannterTitelZaehlt() {
        #expect(Downloadaufgabe.gilt(gemeldet: 3, aktuell: nil))
    }
}
