import Foundation
import Testing
@testable import JellyfinKit

/// Was in der Ablage liegt, ist älter als der Code, der es liest.
///
/// **Der Fehler, den diese Prüfungen abfangen.** Swifts erzeugter
/// `init(from:)` verlangt **jeden** Schlüssel. Wer einer gespeicherten
/// Struktur ein Feld hinzufügt, macht damit jede Datei unlesbar, die vor
/// der Änderung geschrieben wurde — und weil beide Lesestellen `try?`
/// benutzen, wirft niemand einen Fehler: die App startet, sieht normal aus
/// und hat nur alles vergessen.
///
/// Zweimal passiert, beide Male still:
///
/// - 05.09.2026, Apple: die alte Ablage wurde roh weitergereicht, drei von
///   vier Schlüsseln passten nicht, **jeder bestehende Nutzer stand nach dem
///   Aktualisieren vor dem Anmeldeschirm.** Auf einem Rechner mit neuer
///   Ablage ist davon nichts zu sehen — aufgefallen ist es nur, weil eine
///   Prüfmaschine den alten Stand trug.
/// - 08.09.2026, Linux: in `wahlen.json` fehlten zwei neue Schlüssel,
///   `decode` warf, `lesen()` gab kommentarlos die Vorgaben zurück. **Alle
///   Einstellungen weg** — und eine App mit Vorgabewerten sieht normal aus.
///
/// **Warum eingefrorener Text und nicht `encode` und wieder `decode`.** Ein
/// Rundlauf prüft den Code gegen sich selbst und geht deshalb immer gut aus;
/// er hätte keinen der beiden Fälle gefunden. Nur eine Zeichenkette, die
/// *steht*, misst gegen eine frühere Fassung. Deshalb wird der Text unten
/// nicht erzeugt und nicht angepasst.
///
/// **Was zu tun ist, wenn eine dieser Prüfungen bricht.** Nicht den Text
/// nachziehen — das schaltet genau den Alarm ab, für den er dasteht. Das
/// neue Feld wird **optional**, damit alte Ablagen weiter lesbar bleiben.
/// Erst danach kommt ein *zusätzlicher* Abschnitt für die neue Fassung
/// dazu, der alte bleibt stehen.
///
/// **Ein Vorgabewert rettet nicht.** Am 09.09.2026 an dieser Prüfung
/// nachgemessen, weil die Annahme naheliegt und falsch ist:
///
///     public var neuesFeld: Bool = false   -> Prüfung BRICHT
///     public var neuesFeld: Bool?          -> Prüfung besteht
///
/// Der erzeugte `init(from:)` verlangt den Schlüssel auch dann, wenn die
/// Deklaration einen Wert danebenstehen hat; der Vorgabewert gilt für den
/// Elementweise-Init, nicht fürs Lesen. Wer sich darauf verlässt, hält eine
/// Struktur für abwärtskompatibel, die es nicht ist.
@Suite("Ablagen aus früheren Fassungen bleiben lesbar")
struct AblagefassungenTests {

    /// Ein Kontenbund, wie ihn die ausgelieferte Fassung 1.0.1 schreibt.
    /// Eingefroren am 09.09.2026. Nicht anfassen — siehe oben.
    private let bundWie101 = Data("""
    {
      "konten": [
        {
          "accessToken": "abc123",
          "userID": "u-1",
          "userName": "paul",
          "serverURL": "https://tv.paulherter.de"
        },
        {
          "accessToken": "def456",
          "userID": "u-2",
          "userName": "eltern",
          "serverURL": "https://tv.paulherter.de"
        }
      ],
      "aktiveKennung": "u-2"
    }
    """.utf8)

    /// Eine Einzelsitzung aus der Zeit vor den Mehrfachkonten.
    /// Eingefroren am 09.09.2026. Nicht anfassen.
    private let einzelneWieFrueher = Data("""
    {
      "accessToken": "abc123",
      "userID": "u-1",
      "userName": "paul",
      "serverURL": "https://tv.paulherter.de"
    }
    """.utf8)

    @Test("Ein Bund aus 1.0.1 wird vollständig gelesen")
    func bundBleibtLesbar() throws {
        // Comment nimmt nur ein Literal, keine zusammengesetzte Zeichenkette.
        let bund = try #require(Kontenbund.ausAblage(bund: bundWie101, einzelne: nil),
                                "Ein neues Feld ohne Vorgabewert macht jede aeltere Ablage unlesbar, und ausAblage verschluckt das mit try?")
        #expect(bund.konten.count == 2)
        #expect(bund.aktives.userID == "u-2")
        #expect(bund.aktives.userName == "eltern")
        #expect(bund.konten[0].accessToken == "abc123")
        #expect(bund.serverURL.host() == "tv.paulherter.de")
    }

    @Test("Eine Einzelsitzung von früher wird weiter übernommen")
    func einzelneBleibtLesbar() throws {
        let bund = try #require(Kontenbund.ausAblage(bund: nil, einzelne: einzelneWieFrueher))
        #expect(bund.konten.count == 1)
        #expect(bund.aktives.userName == "paul")
        #expect(bund.aktives.accessToken == "abc123")
    }

    /// Der umgekehrte Weg: eine ältere Fassung liest, was eine neuere
    /// geschrieben hat. Das kommt vor, sobald jemand zurückschaltet oder
    /// zwei Geräte verschieden weit sind.
    @Test("Ein unbekannter Schlüssel in der Ablage stört nicht")
    func neuereAblageStoertNicht() throws {
        let mitZusatz = Data("""
        {
          "konten": [
            {
              "accessToken": "abc123",
              "userID": "u-1",
              "userName": "paul",
              "serverURL": "https://tv.paulherter.de",
              "einFeldAusDerZukunft": 42
            }
          ],
          "aktiveKennung": "u-1",
          "nochEinsAusDerZukunft": ["a", "b"]
        }
        """.utf8)
        let bund = try #require(Kontenbund.ausAblage(bund: mitZusatz, einzelne: nil))
        #expect(bund.konten.count == 1)
        #expect(bund.aktives.userName == "paul")
    }

    /// Die Regel gilt nicht nur für den Bund. Wer eine weitere Struktur
    /// dauerhaft ablegt, hängt ihren eingefrorenen Text hier an — das ist
    /// billiger als der Abend, an dem jemand herausfindet, warum alle
    /// abgemeldet sind.
    @Test("Session allein bleibt aus eigenem Recht lesbar")
    func sessionBleibtLesbar() throws {
        let sitzung = try JSONDecoder().decode(Session.self, from: einzelneWieFrueher)
        #expect(sitzung.userID == "u-1")
        #expect(sitzung.serverURL.absoluteString == "https://tv.paulherter.de")
    }
}
