import Foundation
import Testing
@testable import JellyfinKit

@Suite("Vorläufige Serie aus einer Folge")
struct VorlaeufigeSerieTests {

    private func folge(serie: String? = "s1", name: String? = "Young Sheldon") -> Item {
        Item(id: "f1", name: "Folge 1", type: "Episode",
             seriesName: name, seriesId: serie)
    }

    @Test("Nimmt Kennung und Namen aus der Folge und gilt als Serie")
    func nimmtWasDaIst() throws {
        let s = try #require(Item.vorlaeufigeSerie(zu: folge()))
        #expect(s.id == "s1")
        #expect(s.name == "Young Sheldon")
        #expect(s.type == "Series")
    }

    /// Ohne Serie gibt es nichts vorwegzunehmen — dann soll die Seite laden,
    /// statt einen Eintrag zu zeigen, der auf nichts zeigt.
    @Test("Ohne Serienkennung oder Serienname kommt nichts zurück")
    func ohneAngabenNichts() {
        #expect(Item.vorlaeufigeSerie(zu: folge(serie: nil)) == nil)
        #expect(Item.vorlaeufigeSerie(zu: folge(name: nil)) == nil)
    }

    @Test("Der Erzeuger füllt nur, was genannt wird")
    func nurGenanntes() {
        let i = Item(id: "x", name: "Ein Film", type: "Movie")
        #expect(i.overview == nil)
        #expect(i.userData == nil)
        #expect(i.genres == nil)
    }
}

/// Stand einmal gemischt: an den Kacheln „F6, F7", am Abspielknopf „E7" —
/// derselbe Wert, zwei Sprachen an einer Stelle (gemeldet 27.09.2026). Deutsch
/// heißt es überall „Folge"/„F", Englisch „Episode"/„E" — nie umgekehrt.
@Suite("Folgenkürzel — ein Buchstabe, überall derselbe")
struct FolgenkuerzelTests {

    private func folge(staffel: Int? = 7, nummer: Int? = 3, serie: String? = "21 Jump Street") -> Item {
        Item(id: "f1", name: "Eine Folge", type: "Episode",
             seriesName: serie, indexNumber: nummer, parentIndexNumber: staffel)
    }

    /// Welcher Buchstabe vor der Folgennummer steht — „F" oder „E", je nach
    /// Sprache der Testumgebung. Ein anderer Buchstabe wäre ein Fehler im
    /// Katalog, keine gültige Übersetzung.
    private func buchstabeVorZiffer(_ text: String, ziffer: String) -> Character? {
        guard let bereich = text.range(of: ziffer), bereich.lowerBound > text.startIndex else { return nil }
        return text[text.index(before: bereich.lowerBound)]
    }

    @Test("Kürzel nennt Staffel und Folge, mit demselben Buchstaben wie die Kontextzeile")
    func kuerzelUndKontextzeileGleicherBuchstabe() {
        let kuerzel = try! #require(folge().folgenkuerzel)
        let zeile = try! #require(folge().kontextzeile)
        #expect(kuerzel.contains("S7"))
        #expect(zeile.contains("21 Jump Street"))
        let bF = try! #require(buchstabeVorZiffer(kuerzel, ziffer: "3"))
        let bZ = try! #require(buchstabeVorZiffer(zeile, ziffer: "3"))
        // Genau das war der gemeldete Fehler: an der Kachel („F6, F7") stand
        // ein anderer Buchstabe als am Abspielknopf („E7") — in derselben
        // Sprache, zur selben Zeit.
        #expect(bF == bZ)
        #expect(["F", "E"].contains(String(bF)))
    }

    @Test("Ohne Staffel oder ohne Folgennummer gibt es kein Kürzel")
    func ohneAngabenKeinKuerzel() {
        #expect(folge(staffel: nil).folgenkuerzel == nil)
        #expect(folge(nummer: nil).folgenkuerzel == nil)
    }

    @Test("Ohne Serie und ohne Staffel/Folge gibt die Kontextzeile nichts zurück")
    func kontextzeileOhneAngabenNil() {
        let i = Item(id: "m1", name: "Ein Film", type: "Movie")
        #expect(i.kontextzeile == nil)
    }

    /// Der Katalog selbst, unabhängig von der Sprache der Testumgebung: das
    /// Kürzel ist auf Deutsch „F", auf Englisch „E" — nie umgekehrt. Gelesen
    /// wie ``Textkatalog`` es auf Linux/Android tut — über die `.lproj`-Datei
    /// direkt —, weil `String(localized:locale:)` die Sprache der
    /// Testumgebung nicht zuverlässig überschreibt.
    @Test("Katalog: Deutsch F, Englisch E")
    func katalogBuchstabeJeSprache() throws {
        func wert(_ sprache: String) throws -> String? {
            let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings",
                                                       subdirectory: nil, localization: sprache))
            let tabelle = try #require(NSDictionary(contentsOf: url) as? [String: String])
            return tabelle["S%lld • F%lld"]
        }
        #expect(try wert("de") == "S%lld • F%lld")
        #expect(try wert("en") == "S%lld • E%lld")
    }
}
