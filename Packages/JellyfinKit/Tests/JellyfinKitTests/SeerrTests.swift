import Foundation
import Testing
@testable import JellyfinKit

@Suite("Seerr")
struct SeerrTests {

    // MARK: Suchantwort

    /// Wörtliches JSON, so wie Seerr es liefert — nicht über unseren eigenen
    /// Kodierer. Ein Test, der selbst kodiert, prüft nur sich selbst.
    private let antwort = Data("""
    {"page":1,"totalResults":4,"results":[
      {"id":1,"mediaType":"movie","title":"Mentalist Live","releaseDate":"2014-03-01",
       "posterPath":"/abc.jpg"},
      {"id":2,"mediaType":"tv","name":"The Mentalist","firstAirDate":"2008-09-23",
       "posterPath":"/def.jpg","mediaInfo":{"status":5}},
      {"id":3,"mediaType":"tv","name":"The Mentalist (UK)","firstAirDate":"2011-01-01",
       "mediaInfo":{"status":2}},
      {"id":4,"mediaType":"person","name":"Simon Baker","profilePath":"/ghi.jpg"}
    ]}
    """.utf8)

    @Test("Filme und Serien kommen durch, Personen nicht")
    func personenFallenRaus() {
        let t = Seerr.treffer(ausSuche: antwort)
        #expect(t.count == 3)
        #expect(!t.contains { $0.titel == "Simon Baker" })
    }

    @Test("Titel kommt aus title oder name, das Jahr aus dem Datum")
    func titelUndJahr() throws {
        let t = Seerr.treffer(ausSuche: antwort)
        let film = try #require(t.first { $0.id == 1 })
        #expect(film.titel == "Mentalist Live")
        #expect(film.jahr == 2014)
        let serie = try #require(t.first { $0.id == 2 })
        #expect(serie.titel == "The Mentalist")
        #expect(serie.jahr == 2008)
        #expect(serie.istSerie)
    }

    /// Seerr legt den Eintrag erst mit der ersten Anfrage an. Fehlt er, hat
    /// niemand gefragt — das ist `offen`, nicht „unbekannt".
    @Test("Ohne mediaInfo gilt der Titel als offen")
    func ohneMediaInfoOffen() throws {
        let t = try #require(Seerr.treffer(ausSuche: antwort).first { $0.id == 1 })
        #expect(t.stand == .offen)
        #expect(t.stand.anfragbar)
    }

    @Test("Die Zahlen der Schnittstelle werden übernommen, nicht umgedeutet")
    func staendeAusDerAntwort() throws {
        let t = Seerr.treffer(ausSuche: antwort)
        #expect(try #require(t.first { $0.id == 2 }).stand == .da)
        #expect(try #require(t.first { $0.id == 3 }).stand == .wartetAufFreigabe)
    }

    @Test("Kaputte Antwort liefert nichts, statt zu werfen")
    func kaputteAntwort() {
        #expect(Seerr.treffer(ausSuche: Data("kein JSON".utf8)).isEmpty)
    }

    // MARK: Stände

    /// Ein Stand ist keine Schaltfläche: was wartet oder lädt, lässt sich
    /// nicht noch einmal anfragen.
    @Test("Nur offen, gelöscht und teilweise da lassen sich anfragen")
    func nurWasSinnHat() {
        #expect(Seerrstand.offen.anfragbar)
        #expect(Seerrstand.geloescht.anfragbar)
        #expect(Seerrstand.teilweiseDa.anfragbar)
        #expect(!Seerrstand.wartetAufFreigabe.anfragbar)
        #expect(!Seerrstand.laedt.anfragbar)
        #expect(!Seerrstand.da.anfragbar)
    }

    @Test("Nur `da` gehört in den oberen Block")
    func nurDaIstDa() {
        #expect(Seerrstand.da.schonDa)
        #expect(!Seerrstand.teilweiseDa.schonDa)
        #expect(!Seerrstand.laedt.schonDa)
    }

    // MARK: Plakat

    @Test("Die Bildadresse zeigt auf TMDB, nicht auf Seerr")
    func plakatadresse() throws {
        let t = try #require(Seerr.treffer(ausSuche: antwort).first { $0.id == 1 })
        let u = try #require(t.plakat())
        #expect(u.absoluteString == "https://image.tmdb.org/t/p/w342/abc.jpg")
    }

    @Test("Ohne Pfad gibt es keine Adresse")
    func ohnePlakat() throws {
        let t = try #require(Seerr.treffer(ausSuche: antwort).first { $0.id == 3 })
        #expect(t.plakat() == nil)
    }

    // MARK: Keks

    @Test("Der Sitzungskeks wird aus dem Kopf geschnitten")
    func keksSchneiden() {
        let kopf = "connect.sid=s%3Aabc123.xyz; Path=/; HttpOnly; SameSite=Strict"
        #expect(Seerr.keks(ausKopf: kopf) == "connect.sid=s%3Aabc123.xyz")
    }

    /// Mehrere Kekse kommen mit Komma aneinandergehängt. Wer auf einen
    /// einzigen hofft, bekommt bei einem Server mit Lastverteilung nichts.
    @Test("Aus mehreren Keksen wird der richtige gefunden")
    func mehrereKekse() {
        let kopf = "lb=eu-1; Path=/, connect.sid=s%3Aabc; Path=/; HttpOnly"
        #expect(Seerr.keks(ausKopf: kopf) == "connect.sid=s%3Aabc")
    }

    @Test("Ohne Sitzungskeks kommt nichts zurück")
    func keinKeks() {
        #expect(Seerr.keks(ausKopf: "lb=eu-1; Path=/") == nil)
        #expect(Seerr.keks(ausKopf: "connect.sid=; Path=/") == nil)
    }

    // MARK: Anfrage

    @Test("Ein Film wird ohne Staffeln angefragt")
    func filmOhneStaffeln() {
        let r = Seerr.anfrageRumpf(art: "movie", id: 42, staffeln: nil)
        #expect(r["mediaType"] as? String == "movie")
        #expect(r["mediaId"] as? Int == 42)
        #expect(r["seasons"] == nil)
    }

    /// Ein leeres Feld hat Seerr schon einmal mit „gar keine" verwechselt —
    /// deshalb steht dort dann das Wort `all`.
    @Test("Eine Serie ohne Auswahl fragt alle Staffeln an")
    func serieOhneAuswahl() {
        let r = Seerr.anfrageRumpf(art: "tv", id: 7, staffeln: nil)
        #expect(r["seasons"] as? String == "all")
        let leer = Seerr.anfrageRumpf(art: "tv", id: 7, staffeln: [])
        #expect(leer["seasons"] as? String == "all")
    }

    @Test("Gewählte Staffeln gehen als Liste hinaus")
    func gewaehlteStaffeln() {
        let r = Seerr.anfrageRumpf(art: "tv", id: 7, staffeln: [1, 3])
        #expect(r["seasons"] as? [Int] == [1, 3])
    }

    // MARK: Adresse

    @Test("Die Adresse wird aufgeräumt, egal wie sie getippt wurde")
    func adresseAufraeumen() throws {
        let erwartet = "https://seerr.example.de"
        for eingabe in ["seerr.example.de", "https://seerr.example.de/",
                        "https://seerr.example.de/api/v1", "  seerr.example.de/api/  "] {
            let u = try #require(Seerr.adresse(aus: eingabe), "\(eingabe)")
            #expect(u.absoluteString == erwartet, "\(eingabe)")
        }
    }

    @Test("http bleibt http, wenn es dasteht")
    func httpBleibt() throws {
        let u = try #require(Seerr.adresse(aus: "http://192.168.1.9:5055"))
        #expect(u.absoluteString == "http://192.168.1.9:5055")
    }

    @Test("Leer ist keine Adresse")
    func leerIstNichts() {
        #expect(Seerr.adresse(aus: "   ") == nil)
    }
}
