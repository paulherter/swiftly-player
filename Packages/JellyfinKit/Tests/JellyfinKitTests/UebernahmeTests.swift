import Foundation
import Testing
@testable import JellyfinKit

@Suite("Übernahme: welche Sitzung angeboten wird")
struct UebernahmeTests {

    private let jetzt = Date(timeIntervalSince1970: 1_700_000_000)

    /// `Item` hat keinen öffentlichen Init — über JSON, wie der Server es
    /// schickt.
    private func titel(_ id: String = "e1") -> Item {
        let roh = "{\"Id\":\"\(id)\",\"Name\":\"Folge\",\"Type\":\"Episode\"}"
        return try! JSONDecoder().decode(Item.self, from: Data(roh.utf8))
    }

    private func sitzung(id: String = "s1", geraet: String? = "iphone",
                         benutzer: String? = "paul",
                         nimmtBefehle: Bool = true, laeuft: Item? = nil,
                         vorSekunden: TimeInterval? = 5) -> Fremdsitzung {
        Fremdsitzung(id: id, benutzerID: benutzer,
                     geraeteID: geraet, geraetename: "iPhone von Paul",
                     programm: "Swiftly", nimmtBefehle: nimmtBefehle,
                     laeuft: laeuft, stand: .init(angehalten: false, stelle: 812),
                     letzteRegung: vorSekunden.map { jetzt.addingTimeInterval(-$0) })
    }

    // MARK: - Der Normalfall

    @Test("Ein anderes Gerät mit laufendem Titel wird angeboten")
    func normal() {
        let a = Uebernahme.angebot(aus: [sitzung(laeuft: titel())],
                                   eigeneGeraeteID: "appletv", eigeneBenutzerID: "paul", jetzt: jetzt)
        #expect(a?.id == "s1")
        #expect(a?.stand?.stelle == 812)
    }

    @Test("Ticks werden zu Sekunden")
    func ticks() throws {
        let roh = #"{"Id":"s1","DeviceId":"x","SupportsRemoteControl":true,"PlayState":{"IsPaused":false,"PositionTicks":8120000000}}"#
        let s = try JSONDecoder().decode(Fremdsitzung.self, from: Data(roh.utf8))
        #expect(s.stand?.stelle == 812)
    }

    @Test("Jellyfins Zeitstempel mit sieben Nachkommastellen wird gelesen")
    func zeitstempel() throws {
        // Genau die Form, die `/Sessions` am 03.09.2026 geliefert hat.
        // `.iso8601` haette hier geworfen — und in einem `try?` waere der
        // Wert lautlos verschwunden, samt Stillefrist.
        let roh = #"{"Id":"s1","DeviceId":"x","SupportsRemoteControl":true,"LastActivityDate":"2026-09-03T14:10:09.2201736Z"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { try Zeitstempel.lesen(aus: $0) }
        let s = try d.decode(Fremdsitzung.self, from: Data(roh.utf8))
        #expect(s.letzteRegung != nil)
        let erwartet = Date(timeIntervalSince1970: 1_788_444_609.22)
        #expect(abs((s.letzteRegung ?? .distantPast).timeIntervalSince(erwartet)) < 1)
    }

    @Test("Und einer ohne Nachkommastellen auch")
    func zeitstempelOhneBruch() throws {
        let roh = #"{"Id":"s1","DeviceId":"x","SupportsRemoteControl":true,"LastActivityDate":"2026-09-03T14:10:09Z"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { try Zeitstempel.lesen(aus: $0) }
        #expect(try d.decode(Fremdsitzung.self, from: Data(roh.utf8)).letzteRegung != nil)
    }

    // MARK: - Die vier Bedingungen, jede einzeln

    @Test("Das eigene Gerät wird nie angeboten")
    func nichtSelbst() {
        // Der häufigste Fehler hier — und er fällt erst auf, wenn nur ein
        // Gerät läuft.
        #expect(Uebernahme.angebot(aus: [sitzung(geraet: "appletv", laeuft: titel())],
                                   eigeneGeraeteID: "appletv", eigeneBenutzerID: "paul", jetzt: jetzt) == nil)
    }

    @Test("Eine Sitzung ohne laufenden Titel wird nicht angeboten")
    func ohneTitel() {
        #expect(Uebernahme.angebot(aus: [sitzung(laeuft: nil)],
                                   eigeneGeraeteID: "appletv", eigeneBenutzerID: "paul", jetzt: jetzt) == nil)
    }

    @Test("Nimmt die Gegenstelle keine Befehle, wird nicht angeboten")
    func ohneFernsteuerung() {
        // Sonst liefe dort weiter, während hier dasselbe beginnt — zwei
        // Tonspuren im Raum.
        #expect(Uebernahme.angebot(aus: [sitzung(nimmtBefehle: false, laeuft: titel())],
                                   eigeneGeraeteID: "appletv", eigeneBenutzerID: "paul", jetzt: jetzt) == nil)
    }

    @Test("Nach 90 Sekunden Stille nicht mehr")
    func zuAlt() {
        #expect(Uebernahme.angebot(aus: [sitzung(laeuft: titel(), vorSekunden: 91)],
                                   eigeneGeraeteID: "appletv", eigeneBenutzerID: "paul", jetzt: jetzt) == nil)
        #expect(Uebernahme.angebot(aus: [sitzung(laeuft: titel(), vorSekunden: 89)],
                                   eigeneGeraeteID: "appletv", eigeneBenutzerID: "paul", jetzt: jetzt) != nil)
    }

    @Test("Ohne Zeitangabe gilt sie als frisch")
    func ohneZeit() {
        // Fehlt `LastActivityDate`, ist Ablehnen die schlechtere Wahl: der
        // Titel läuft ja laut Server.
        #expect(Uebernahme.angebot(aus: [sitzung(laeuft: titel(), vorSekunden: nil)],
                                   eigeneGeraeteID: "appletv", eigeneBenutzerID: "paul", jetzt: jetzt) != nil)
    }

    @Test("Die Sitzung eines anderen Kontos wird nie angeboten")
    func fremdesKonto() {
        // **Der Fehler, den Paul gesehen hat.** `controllableByUserId` gibt
        // nicht die eigenen Sitzungen zurück, sondern die, die man bedienen
        // darf — als Administrator den ganzen Haushalt. Im Abzeichen stand
        // dann, was jemand anders schaut.
        #expect(Uebernahme.angebot(aus: [sitzung(benutzer: "koney", laeuft: titel())],
                                   eigeneGeraeteID: "appletv",
                                   eigeneBenutzerID: "paul", jetzt: jetzt) == nil)
    }

    @Test("Ohne Kontoangabe wird nicht angeboten")
    func ohneKonto() {
        // Lieber kein Abzeichen als eins, das vielleicht jemand anders zeigt.
        #expect(Uebernahme.angebot(aus: [sitzung(benutzer: nil, laeuft: titel())],
                                   eigeneGeraeteID: "appletv",
                                   eigeneBenutzerID: "paul", jetzt: jetzt) == nil)
    }

    @Test("Das eigene Konto auf einem anderen Gerät schon")
    func eigenesKonto() {
        #expect(Uebernahme.angebot(aus: [sitzung(benutzer: "paul", laeuft: titel())],
                                   eigeneGeraeteID: "appletv",
                                   eigeneBenutzerID: "paul", jetzt: jetzt) != nil)
    }

    // MARK: - Mehrere

    @Test("Bei mehreren gewinnt die jüngste Regung")
    func jueng() {
        let alt = sitzung(id: "alt", geraet: "ipad", laeuft: titel(), vorSekunden: 60)
        let neu = sitzung(id: "neu", geraet: "iphone", laeuft: titel(), vorSekunden: 3)
        #expect(Uebernahme.angebot(aus: [alt, neu],
                                   eigeneGeraeteID: "appletv", eigeneBenutzerID: "paul", jetzt: jetzt)?.id == "neu")
        #expect(Uebernahme.angebot(aus: [neu, alt],
                                   eigeneGeraeteID: "appletv", eigeneBenutzerID: "paul", jetzt: jetzt)?.id == "neu",
                "die Reihenfolge der Antwort darf nichts ändern")
    }

    @Test("Untaugliche werden übersprungen, nicht der ganze Vorgang")
    func gemischt() {
        let selbst = sitzung(id: "selbst", geraet: "appletv", laeuft: titel(), vorSekunden: 1)
        let gut = sitzung(id: "gut", geraet: "iphone", laeuft: titel(), vorSekunden: 30)
        #expect(Uebernahme.angebot(aus: [selbst, gut],
                                   eigeneGeraeteID: "appletv", eigeneBenutzerID: "paul", jetzt: jetzt)?.id == "gut")
    }

    @Test("Zwei Geräte: beide werden angeboten, jüngstes zuerst")
    func zweiGeraete() {
        let alt = sitzung(id: "ipad", geraet: "ipad", laeuft: titel(), vorSekunden: 40)
        let neu = sitzung(id: "iphone", geraet: "iphone", laeuft: titel(), vorSekunden: 3)
        let liste = Uebernahme.angebote(aus: [alt, neu], eigeneGeraeteID: "appletv",
                                        eigeneBenutzerID: "paul", jetzt: jetzt)
        #expect(liste.map(\.id) == ["iphone", "ipad"])
    }

    @Test("Untaugliche stehen auch nicht in der Liste")
    func listeGefiltert() {
        let fremd = sitzung(id: "fremd", geraet: "mac", benutzer: "koney", laeuft: titel())
        let selbst = sitzung(id: "selbst", geraet: "appletv", laeuft: titel())
        let gut = sitzung(id: "gut", geraet: "iphone", laeuft: titel())
        let liste = Uebernahme.angebote(aus: [fremd, selbst, gut], eigeneGeraeteID: "appletv",
                                        eigeneBenutzerID: "paul", jetzt: jetzt)
        #expect(liste.map(\.id) == ["gut"])
    }

    @Test("Keine Sitzungen, kein Angebot")
    func leer() {
        #expect(Uebernahme.angebot(aus: [], eigeneGeraeteID: "appletv", eigeneBenutzerID: "paul", jetzt: jetzt) == nil)
    }
}
