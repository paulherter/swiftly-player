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
       "posterPath":"/abc.jpg","backdropPath":"/quer.jpg"},
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

    /// Der Kopf einer Seite braucht das Querbild. Ein hochgezogenes Plakat
    /// ist zu hoch und drückt alles darunter nach unten.
    @Test("Das Querbild kommt aus backdropPath, nicht aus dem Plakat")
    func kulissenbild() throws {
        let t = try #require(Seerr.treffer(ausSuche: antwort).first { $0.id == 1 })
        let u = try #require(t.kulisse())
        #expect(u.absoluteString == "https://image.tmdb.org/t/p/w780/quer.jpg")
    }

    /// **Kein Rückfall auf das Plakat.** Lieber gar kein Kopfbild als eines,
    /// das die halbe Seite nach unten schiebt.
    @Test("Ohne Querbild kommt nichts, nicht das Plakat")
    func keinRueckfallAufsPlakat() throws {
        let t = try #require(Seerr.treffer(ausSuche: antwort).first { $0.id == 2 })
        #expect(t.kulisse() == nil)
        #expect(t.plakat() != nil)
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

    /// Wer eine IP tippt, meint kein `https` — dort steht praktisch nie ein
    /// Zertifikat. Dieselbe Regel wie beim Medienserver.
    @Test("Eine IP im Heimnetz bekommt http, ein Name https")
    func heimnetzBekommtHttp() throws {
        #expect(try #require(Seerr.adresse(aus: "192.168.1.9:5055")).scheme == "http")
        #expect(try #require(Seerr.adresse(aus: "10.0.0.4")).scheme == "http")
        #expect(try #require(Seerr.adresse(aus: "seerr.local:5055")).scheme == "http")
        #expect(try #require(Seerr.adresse(aus: "seerr.example.de")).scheme == "https")
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
    // MARK: Detail

    private let serie = Data("""
    {"overview":"Ein Berater der Polizei.","episodeRunTime":[45],"voteAverage":8.1,
     "genres":[{"name":"Krimi"},{"name":"Drama"},{"name":"Mystery"}],
     "seasons":[
       {"seasonNumber":0,"episodeCount":3},
       {"seasonNumber":1,"episodeCount":23},
       {"seasonNumber":2,"episodeCount":22}],
     "mediaInfo":{"seasons":[{"seasonNumber":1,"status":5}]}}
    """.utf8)

    @Test("Beschreibung, Laufzeit und Bewertung kommen an")
    func detailFelder() throws {
        let d = try #require(Seerr.detail(aus: serie))
        #expect(d.beschreibung == "Ein Berater der Polizei.")
        #expect(d.laufzeit == 45)
        #expect(d.bewertung == 8.1)
    }

    /// Zwei reichen für eine Nebenzeile; die dritte sagt nichts mehr und
    /// drängt die Laufzeit aus dem Bild.
    @Test("Höchstens zwei Gattungen")
    func hoechstensZweiGenres() throws {
        let d = try #require(Seerr.detail(aus: serie))
        #expect(d.genres == ["Krimi", "Drama"])
    }

    /// TMDB legt Specials in Staffel 0 ab. Wer „alle Staffeln" anfragt, meint
    /// sie nicht — und in einer Liste zum Ankreuzen stünde sie ganz oben.
    @Test("Staffel 0 fällt heraus")
    func staffelNullRaus() throws {
        let d = try #require(Seerr.detail(aus: serie))
        #expect(d.staffeln.map(\.nummer) == [1, 2])
    }

    /// Der Stand steht nicht bei der Staffel, sondern in einer zweiten Liste
    /// daneben — das wird zusammengeführt, nicht geraten.
    @Test("Der Stand je Staffel wird zugeordnet")
    func staffelstaende() throws {
        let d = try #require(Seerr.detail(aus: serie))
        #expect(d.staffeln.first { $0.nummer == 1 }?.stand == .da)
        #expect(d.staffeln.first { $0.nummer == 2 }?.stand == .offen)
        #expect(d.staffeln.first { $0.nummer == 2 }?.folgen == 22)
    }

    @Test("Ein Film hat keine Staffeln, aber eine Laufzeit")
    func filmdetail() throws {
        let film = Data(#"{"overview":"Ein Film.","runtime":112,"voteAverage":6.9}"#.utf8)
        let d = try #require(Seerr.detail(aus: film))
        #expect(d.staffeln.isEmpty)
        #expect(d.laufzeit == 112)
    }

    /// Eine leere Beschreibung ist keine Beschreibung — sonst stünde auf der
    /// Seite eine Überschrift über nichts.
    @Test("Leere Beschreibung zählt als keine")
    func leereBeschreibung() throws {
        let d = try #require(Seerr.detail(aus: Data(#"{"overview":"   "}"#.utf8)))
        #expect(d.beschreibung == nil)
    }

    @Test("Kaputte Detailantwort liefert nichts")
    func kaputtesDetail() {
        #expect(Seerr.detail(aus: Data("nope".utf8)) == nil)
    }

    // MARK: Besetzung und Vorschlaege

    /// Woertliches JSON, kein selbst kodiertes: an dieser Antwort haengt, ob
    /// die beiden Reiter der Seite ueberhaupt etwas zeigen.
    private let mitAnhang = Data(#"""
    {
      "overview": "Ein Film.",
      "runtime": 112,
      "credits": {
        "cast": [
          {"id": 1, "name": "Simon Baker", "character": "Patrick Jane",
           "profilePath": "/a.jpg"},
          {"id": 2, "name": "Robin Tunney", "character": "", "profilePath": null},
          {"id": 3, "character": "Namenlos"}
        ],
        "crew": [{"id": 9, "name": "Bruno Heller", "job": "Creator"}]
      },
      "recommendations": {
        "results": [
          {"id": 42, "title": "Der Nachbar", "releaseDate": "2011-02-03",
           "posterPath": "/p.jpg", "backdropPath": "/b.jpg"},
          {"id": 43, "title": "Schon da", "mediaInfo": {"status": 5}}
        ]
      }
    }
    """#.utf8)

    @Test("Die Besetzung kommt aus credits.cast, die Crew nicht")
    func besetzung() throws {
        let d = try #require(Seerr.detail(aus: mitAnhang))
        #expect(d.besetzung.map(\.name) == ["Simon Baker", "Robin Tunney"])
        #expect(d.besetzung.first?.rolle == "Patrick Jane")
    }

    /// Eine leere Figur ist keine Figur — sonst stuende unter dem Namen eine
    /// Zeile, die nichts sagt und trotzdem Platz nimmt.
    @Test("Eine leere Rolle zaehlt als keine")
    func leereRolle() throws {
        let d = try #require(Seerr.detail(aus: mitAnhang))
        #expect(d.besetzung.first { $0.name == "Robin Tunney" }?.rolle == nil)
    }

    @Test("Ohne Bild kommt keine Adresse, nicht eine kaputte")
    func portraetOhnePfad() throws {
        let d = try #require(Seerr.detail(aus: mitAnhang))
        #expect(d.besetzung.first?.bild()?.absoluteString
                == "https://image.tmdb.org/t/p/w185/a.jpg")
        #expect(d.besetzung.first { $0.name == "Robin Tunney" }?.bild() == nil)
    }

    /// **Der Fehler, den ** Die Detailantwort traegt `credits`, aber keine
    /// Vorschlaege — die stehen unter einem eigenen Pfad. Deshalb war die
    /// Besetzung da und „Aehnliches" leer.
    @Test("Die Detailantwort allein bringt keine Vorschlaege")
    func detailOhneVorschlaege() throws {
        let d = try #require(Seerr.detail(aus: mitAnhang))
        #expect(d.besetzung.count == 2)
        #expect(d.aehnliches.isEmpty)
    }

    private let vorschlagsantwort = Data(#"""
    {
      "page": 1,
      "totalPages": 3,
      "results": [
        {"id": 42, "title": "Der Nachbar", "releaseDate": "2011-02-03",
         "posterPath": "/p.jpg", "backdropPath": "/b.jpg"},
        {"id": 43, "title": "Schon da", "mediaInfo": {"status": 5}}
      ]
    }
    """#.utf8)

    /// **Der Fall, an dem es sonst still scheitert.** In dieser Antwort steht
    /// kein `mediaType` — die Seite weiss ja, was sie ist. Ohne den Rueckfall
    /// kaeme auch aus einer vollen Antwort nichts an.
    @Test("Vorschlaege ohne mediaType erben die Art der Seite")
    func vorschlaegeErbenDieArt() {
        let v = Seerr.vorschlaege(aus: vorschlagsantwort, art: "movie")
        #expect(v.map(\.id) == [42, 43])
        #expect(v.allSatisfy { $0.art == "movie" })
        #expect(v.first?.jahr == 2011)
        #expect(v.first?.kulisse()?.absoluteString
                == "https://image.tmdb.org/t/p/w780/b.jpg")
        #expect(v.last?.stand == .da)
    }

    @Test("Eine kaputte Vorschlagsantwort liefert nichts, wirft aber nicht")
    func kaputteVorschlaege() {
        #expect(Seerr.vorschlaege(aus: Data("nope".utf8), art: "tv").isEmpty)
    }

    /// Die Auskunft bleibt dieselbe, nur die Vorschlaege kommen dazu — so
    /// setzt der Client die beiden Abrufe zusammen.
    @Test("Zusammensetzen laesst alles andere unberuehrt")
    func zusammensetzen() throws {
        let d = try #require(Seerr.detail(aus: mitAnhang))
        let voll = d.mit(aehnliches: Seerr.vorschlaege(aus: vorschlagsantwort, art: "movie"))
        #expect(voll.beschreibung == d.beschreibung)
        #expect(voll.besetzung == d.besetzung)
        #expect(voll.laufzeit == 112)
        #expect(voll.aehnliches.count == 2)
    }

    @Test("Fehlen die credits, bleibt die Besetzung leer")
    func ohneAnhang() throws {
        let d = try #require(Seerr.detail(aus: Data(#"{"overview":"x"}"#.utf8)))
        #expect(d.besetzung.isEmpty)
        #expect(d.aehnliches.isEmpty)
    }
}

@Suite("Seerr-Adresse")
struct SeerrAdresseTests {

    @Test("Ohne Schema wird geraten — und der zweite Versuch steht daneben")
    func zweiterVersuch() {
        let a = Seerr.adressen(aus: "seerr.beispiel.de")
        #expect(a.map(\.absoluteString) == ["https://seerr.beispiel.de",
                                            "http://seerr.beispiel.de"])
        // Eine Adresse im Heimnetz raet andersherum — und weicht nach oben aus.
        let b = Seerr.adressen(aus: "192.168.1.9:5055")
        #expect(b.map(\.absoluteString) == ["http://192.168.1.9:5055",
                                            "https://192.168.1.9:5055"])
    }

    @Test("Wer das Schema selbst tippt, bekommt keinen zweiten Versuch")
    func getipptesSchemaGiltt() {
        #expect(Seerr.adressen(aus: "https://seerr.beispiel.de").count == 1)
        #expect(Seerr.adressen(aus: "http://192.168.1.9:5055").count == 1)
    }

    @Test("Der Anhang faellt weg, das Schema bleibt")
    func anhang() {
        #expect(Seerr.adressen(aus: "https://seerr.beispiel.de/api/v1")
                    .map(\.absoluteString) == ["https://seerr.beispiel.de"])
    }

    @Test("Leere Eingabe ergibt nichts")
    func leer() {
        #expect(Seerr.adressen(aus: "   ").isEmpty)
    }
}
