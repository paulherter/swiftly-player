import Foundation
import Testing
@testable import JellyfinKit

/// **A10: welche Staffel beim Öffnen dasteht.**
///
/// Der Fehler, den diese Prüfungen festhalten, hatte eine sichtbare Form:
/// oben stand „Abspielen S6E1", unten die Folgenliste von Staffel 5. Beide
/// Angaben kamen aus derselben Seite und widersprachen einander.
@Suite("Staffelwahl beim Oeffnen")
struct StaffelwahlTests {

    private func staffel(_ id: String, nummer: Int?) -> Item {
        let json = """
        {"Id":"\(id)","Name":"Staffel \(nummer.map(String.init) ?? "?")","Type":"Season"
        \(nummer.map { ",\"IndexNumber\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    private func folge(seasonID: String?, staffelnummer: Int?) -> Item {
        let json = """
        {"Id":"f1","Name":"Folge","Type":"Episode"
        \(seasonID.map { ",\"SeasonId\":\"\($0)\"" } ?? "")
        \(staffelnummer.map { ",\"ParentIndexNumber\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    private var alle: [Item] {
        [staffel("s1", nummer: 1), staffel("s5", nummer: 5), staffel("s6", nummer: 6)]
    }

    @Test("Ein Hinweis mit Kennung gilt")
    func kennung() {
        #expect(Staffelwahlregel.waehle(aus: alle, hinweisID: "s5")?.id == "s5")
    }

    /// Am Geraet gemessen liefert der Server an einer Folge nicht immer eine
    /// `SeasonId`. Dann greift der Kennungsvergleich ins Leere, und nur die
    /// Nummer traegt noch — deshalb werden beide geprueft.
    @Test("Ohne Kennung traegt die Nummer")
    func nummer() {
        #expect(Staffelwahlregel.waehle(aus: alle, hinweisNummer: 6)?.id == "s6")
        // Eine Kennung, die es nicht gibt, darf die Nummer nicht aushebeln.
        #expect(Staffelwahlregel.waehle(aus: alle, hinweisID: "gibtsnicht",
                                        hinweisNummer: 5)?.id == "s5")
    }

    /// **Der Kern von A10.** Ohne Hinweis stand bisher Staffel 1 da, waehrend
    /// der Hauptknopf daneben „Weiterschauen S6E1" sagte.
    @Test("Ohne Hinweis gilt die laufende Staffel, nicht die erste")
    func laufende() {
        let stand = folge(seasonID: "s6", staffelnummer: 6)
        #expect(Staffelwahlregel.waehle(aus: alle, stand: stand)?.id == "s6")
    }

    @Test("Ohne SeasonId am Stand traegt dessen Staffelnummer")
    func standOhneKennung() {
        let stand = folge(seasonID: nil, staffelnummer: 5)
        #expect(Staffelwahlregel.waehle(aus: alle, stand: stand)?.id == "s5")
    }

    /// Audit T2-M4: Die Folge kommt ohne `SeasonId`, man schaut aber gerade
    /// eine andere Staffel. Die Nummer des Hinweises schlägt die Kennung des
    /// Stands — die alten Kopien auf iOS und tvOS prüften andersherum.
    @Test("Hinweisnummer schlägt Kennung des Stands")
    func hinweisnummerVorStand() {
        let stand = folge(seasonID: "s5", staffelnummer: 5)
        #expect(Staffelwahlregel.waehle(aus: alle, hinweisID: nil, hinweisNummer: 6,
                                        stand: stand)?.id == "s6")
    }

    @Test("Ohne alles bleibt die erste")
    func rueckfall() {
        #expect(Staffelwahlregel.waehle(aus: alle)?.id == "s1")
        #expect(Staffelwahlregel.waehle(aus: []) == nil)
    }

    /// Der Stand wird nur geholt, wenn er gebraucht wird — ein Abruf, den
    /// niemand liest, kostet auf jeder Serienseite eine Anfrage.
    @Test("Der Stand wird nur ohne Hinweis geholt")
    func standNurOhneHinweis() {
        #expect(Staffelwahlregel.brauchtStand(hinweisID: nil, hinweisNummer: nil))
        #expect(!Staffelwahlregel.brauchtStand(hinweisID: "s1", hinweisNummer: nil))
        #expect(!Staffelwahlregel.brauchtStand(hinweisID: nil, hinweisNummer: 1))
    }

    /// Eine Staffel ohne Nummer — „Specials" etwa — darf nicht auf einen
    /// `nil`-Hinweis passen, sonst gewinnt sie jeden Vergleich.
    @Test("Eine Staffel ohne Nummer passt auf keinen leeren Hinweis")
    func ohneNummer() {
        let mitSpecials = [staffel("sp", nummer: nil)] + alle
        #expect(Staffelwahlregel.waehle(aus: mitSpecials, hinweisNummer: nil)?.id == "sp",
                "Ohne jeden Hinweis gilt die erste der Liste — hier Specials")
        #expect(Staffelwahlregel.waehle(aus: mitSpecials, hinweisNummer: 5)?.id == "s5")
        let stand = folge(seasonID: nil, staffelnummer: nil)
        #expect(Staffelwahlregel.waehle(aus: mitSpecials, stand: stand)?.id == "sp")
    }
}
