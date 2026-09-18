import Testing
@testable import JellyfinKit

/// Die Sprachliste, aus der die Einstellungen ihre Auswahl bauen.
///
/// **Sie wird geprüft, nicht angesehen.** Eine Liste mit 33 Einträgen und
/// mehreren Schreibweisen je Eintrag ist genau die Sorte Datei, in der ein
/// doppelter Eintrag niemandem auffällt — bis ein Spurname der falschen
/// Sprache zugeordnet wird.
@Suite("Sprachliste")
struct SprachlisteTests {

    // MARK: - Die erweiterte Liste

/// **Zwei Sprachen dürfen sich keine Form teilen.** Sonst entscheidet die
/// Reihenfolge in der Liste, welche gewinnt — und niemand sähe, warum ein
/// portugiesischer Spurname plötzlich als Spanisch gilt.
    @Test func keineFormDoppelt() {
    var gesehen: [String: String] = [:]
    for eintrag in Sprache.alle {
        for form in eintrag.formen {
            #expect(gesehen[form] == nil,
                    "„\(form)“ steht bei \(eintrag.name) und bei \(gesehen[form] ?? "")")
            gesehen[form] = eintrag.name
        }
    }
}

/// Kurzformen, die als gewöhnliches Wort in Spurnamen vorkommen, dürfen nicht
/// in der Liste stehen — „No subtitles" ist kein Norwegisch.
    @Test func keineStolperkurzformen() {
    let verboten = ["no", "is", "id", "he", "be", "or", "as", "in", "am", "so",
                    "an", "da", "de", "it", "el", "la", "un"]
    for eintrag in Sprache.alle {
        for form in eintrag.formen where verboten.contains(form) {
            Issue.record("\(eintrag.name) traegt die Stolperform „\(form)“")
        }
    }
}

    @Test func neueSprachenWerdenErkannt() {
    #expect(Sprache.erkannt(in: "Polski (forced)") == "Polski")
    #expect(Sprache.erkannt(in: "pol") == "Polski")
    #expect(Sprache.erkannt(in: "Portuguese (Brazil)") == "Português")
    #expect(Sprache.erkannt(in: "zh-Hans") == "中文")
    #expect(Sprache.erkannt(in: "No subtitles") == nil)
    #expect(Sprache.erkannt(in: "This is forced") == nil)
}
}
