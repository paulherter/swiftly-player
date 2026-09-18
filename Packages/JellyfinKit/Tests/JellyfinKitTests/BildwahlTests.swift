import Foundation
import Testing
@testable import JellyfinKit

/// **Die Kette wird nicht geglaubt, sie wird nachgemessen.**
///
/// Jede Stufe hat einen Grund, und jeder Grund ist ein Fall, der am Server
/// vorkommt: eine Folge ohne eigenen Hintergrund, eine Serie ohne
/// Vorschaubild, ein Film ohne alles. Die Tests bauen genau diese Fälle.
///
/// `Item` hat keinen öffentlichen Erzeuger — es entsteht aus JSON. Das ist
/// hier ein Vorteil: geprüft wird gegen das, was der Server wirklich schickt,
/// samt Feldnamen.
@Suite("Bildwahl")
struct BildwahlTests {

    private let adressen = Bildadresse(basis: URL(string: "https://tv.example.de")!,
                                       token: "abc")

    private func item(_ json: String) throws -> Item {
        try JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    // MARK: Quer — die Kette

    @Test("Der Hintergrund der Serie steht vor allem anderen")
    func serienhintergrundZuerst() throws {
        let folge = try item("""
        {"Id":"f1","Name":"Folge","SeriesId":"s1",
         "ParentBackdropItemId":"s1","ParentBackdropImageTags":["bd"],
         "ImageTags":{"Primary":"pp","Thumb":"tt"}}
        """)
        let treffer = Bildwahl.quer(folge, adressen: adressen)
        #expect(treffer?.quelle == "Serienhintergrund")
        #expect(treffer?.url.path.contains("/Items/s1/Images/Backdrop") == true)
    }

    @Test("Ohne Serienhintergrund kommt der eigene — der Normalfall beim Film")
    func eigenerHintergrund() throws {
        let film = try item("""
        {"Id":"m1","Name":"Film","BackdropImageTags":["bd"]}
        """)
        let treffer = Bildwahl.quer(film, adressen: adressen)
        #expect(treffer?.quelle == "eigener Hintergrund")
        #expect(treffer?.url.path.contains("/Items/m1/Images/Backdrop") == true)
    }

    @Test("Eine Folge fällt zuletzt auf ihr eigenes Standbild zurück")
    func folgenstandbildZuletzt() throws {
        let folge = try item("""
        {"Id":"f1","Name":"Folge","SeriesId":"s1","ImageTags":{"Primary":"pp"}}
        """)
        let treffer = Bildwahl.quer(folge, adressen: adressen)
        #expect(treffer?.quelle == "Folgenstandbild")
    }

    @Test("Ein Film ohne Hintergrund bekommt kein Standbild untergeschoben")
    func filmOhneHintergrundBleibtLeer() throws {
        // Stufe 5 gilt ausdrücklich nur für Folgen: das Plakat eines Films in
        // eine 16:9-Kachel zu legen sähe schlechter aus als gar nichts.
        let film = try item("""
        {"Id":"m1","Name":"Film","ImageTags":{"Primary":"pp"}}
        """)
        #expect(Bildwahl.quer(film, adressen: adressen) == nil)
    }

    @Test("Ohne Marke wird die Stufe übersprungen, nicht geraten")
    func ohneMarkeUebersprungen() throws {
        // Genau hier kamen die 404 her: ohne Marke gibt es das Bild nicht,
        // und eine geratene Adresse sieht aus wie eine leere Kachel.
        let folge = try item("""
        {"Id":"f1","Name":"Folge","SeriesId":"s1","ParentBackdropItemId":"s1",
         "ImageTags":{"Thumb":"tt"}}
        """)
        let treffer = Bildwahl.quer(folge, adressen: adressen)
        #expect(treffer?.quelle == "eigene Vorschau")
    }

    @Test("Nichts da heißt nichts zurück")
    func garNichts() throws {
        let leer = try item(#"{"Id":"x","Name":"Leer"}"#)
        #expect(Bildwahl.quer(leer, adressen: adressen) == nil)
    }

    // MARK: Hochkant

    @Test("Eine Folge zeigt hochkant das Plakat der Serie")
    func folgeZeigtSerienplakat() throws {
        let folge = try item("""
        {"Id":"f1","Name":"Folge","SeriesId":"s1","SeriesPrimaryImageTag":"sp",
         "ImageTags":{"Primary":"pp"}}
        """)
        let url = Bildwahl.hochkant(folge, adressen: adressen)
        // Das eigene Bild einer Folge ist 16:9 und wuerde in 2:3 zerschnitten.
        #expect(url?.path.contains("/Items/s1/Images/Primary") == true)
    }

    @Test("Eine Folge ohne Serienmarke nimmt ihr eigenes Bild")
    func folgeOhneSerienmarke() throws {
        let folge = try item("""
        {"Id":"f1","Name":"Folge","SeriesId":"s1","ImageTags":{"Primary":"pp"}}
        """)
        let url = Bildwahl.hochkant(folge, adressen: adressen)
        #expect(url?.path.contains("/Items/f1/Images/Primary") == true)
    }

    @Test("Ein Film nimmt sein eigenes Plakat")
    func filmPlakat() throws {
        let film = try item(#"{"Id":"m1","Name":"Film","ImageTags":{"Primary":"pp"}}"#)
        #expect(Bildwahl.hochkant(film, adressen: adressen)?
            .path.contains("/Items/m1/Images/Primary") == true)
    }

    // MARK: Gesehener Anteil

    @Test("Null Prozent heißt kein Balken, nicht ein Balken der Länge null")
    func keinBalkenBeiNull() throws {
        let ungesehen = try item("""
        {"Id":"x","Name":"X","UserData":{"PlayedPercentage":0}}
        """)
        #expect(ungesehen.gesehenerAnteil == nil)
    }

    @Test("Prozent wird zu einem Anteil zwischen null und eins")
    func anteilAusProzent() throws {
        let halb = try item("""
        {"Id":"x","Name":"X","UserData":{"PlayedPercentage":42.5}}
        """)
        #expect(halb.gesehenerAnteil == 0.425)
    }
}
