import Testing
@testable import JellyfinKit

private func film(_ id: String, tmdb: String? = nil, imdb: String? = nil,
                  stand: Bool = false) -> Item {
    var nummern: [String: String] = [:]
    if let tmdb { nummern["Tmdb"] = tmdb }
    if let imdb { nummern["Imdb"] = imdb }
    return Item(id: id, name: "Obsession", type: "Movie",
                userData: stand ? UserItemData(playbackPositionTicks: 600_000_000) : nil,
                providerIds: nummern.isEmpty ? nil : nummern)
}

private func folge(_ id: String, serie: String, staffel: Int, nr: Int) -> Item {
    Item(id: id, name: "Folge", type: "Episode", seriesName: "The Mentalist",
         indexNumber: nr, parentIndexNumber: staffel, seriesId: serie)
}

/// Wie am Testserver: „Filme" (movies) und „Videothek" (gemischt).
private let bibliotheken = [Item(id: "videothek", name: "Videothek", collectionType: nil),
                            Item(id: "filme", name: "Filme", collectionType: "movies"),
                            Item(id: "kino", name: "Kinoabend", collectionType: "movies")]

@Suite("Werke")
struct WerkeTests {

    @Test("Gleiche TMDb-Nummer aus zwei Bibliotheken: ein Eintrag, der aus „movies“")
    func filmAusFilmbibliothek() {
        let liste = [film("v", tmdb: "1"), film("f", tmdb: "1")]
        let ergebnis = Werke.zusammenfassen(liste, herkunft: ["v": "videothek", "f": "filme"],
                                            bibliotheken: bibliotheken)
        #expect(ergebnis.map(\.id) == ["f"])
    }

    @Test("Bei gleicher Art gewinnt die Bibliothek, die zuerst kommt")
    func reihenfolgeDerBibliotheken() {
        let liste = [film("k", tmdb: "1"), film("f", tmdb: "1")]
        let ergebnis = Werke.zusammenfassen(liste, herkunft: ["k": "kino", "f": "filme"],
                                            bibliotheken: bibliotheken)
        #expect(ergebnis.map(\.id) == ["f"])
    }

    @Test("Aus derselben Bibliothek gewinnt der Eintrag mit Stand")
    func standEntscheidet() {
        let liste = [film("a", tmdb: "1"), film("b", tmdb: "1", stand: true)]
        #expect(Werke.zusammenfassen(liste).map(\.id) == ["b"])
    }

    @Test("Eine gemeinsame Nummer reicht, TMDb vor IMDb")
    func eineNummerReicht() {
        let liste = [film("v", tmdb: "1", imdb: "tt9"), film("f", imdb: "TT9")]
        let ergebnis = Werke.zusammenfassen(liste, herkunft: ["v": "videothek", "f": "filme"],
                                            bibliotheken: bibliotheken)
        #expect(ergebnis.map(\.id) == ["f"])
    }

    @Test("Ohne Anbieternummern wird nichts zusammengefasst")
    func ohneNummern() {
        let liste = [film("a"), film("b")]
        #expect(Werke.zusammenfassen(liste).map(\.id) == ["a", "b"])
        #expect(!Werke.hatDoppelte(liste))
    }

    @Test("Folgen: gleiche Serie, Staffel und Nummer sind eine")
    func folgen() {
        let serien: Werke.Seriennummern = ["s1": ["Tvdb": "80"], "s2": ["Tvdb": "80"], "s3": ["Tvdb": "99"]]
        let liste = [folge("a", serie: "s2", staffel: 1, nr: 2),
                     folge("b", serie: "s1", staffel: 1, nr: 2),
                     folge("c", serie: "s1", staffel: 1, nr: 3),
                     folge("d", serie: "s3", staffel: 1, nr: 2)]
        let ergebnis = Werke.zusammenfassen(liste, herkunft: ["a": "videothek", "b": "filme"],
                                            bibliotheken: bibliotheken, serien: serien)
        #expect(ergebnis.map(\.id) == ["b", "c", "d"])
    }

    @Test("Folgen ohne Nummern der Serie bleiben getrennt")
    func folgenOhneSeriennummern() {
        let liste = [folge("a", serie: "s1", staffel: 1, nr: 2),
                     folge("b", serie: "s2", staffel: 1, nr: 2)]
        #expect(Werke.zusammenfassen(liste).map(\.id) == ["a", "b"])
        #expect(Werke.serienVerdacht(liste) == ["s1", "s2"])
    }

    @Test("Die Reihenfolge der Liste bleibt, der Sieger rückt an den ersten Platz")
    func reihenfolgeStabil() {
        let liste = [film("x", tmdb: "7"), film("v", tmdb: "1"), film("y", tmdb: "8"),
                     film("f", tmdb: "1"), film("z", tmdb: "9")]
        let ergebnis = Werke.zusammenfassen(liste, herkunft: ["v": "videothek", "f": "filme"],
                                            bibliotheken: bibliotheken)
        #expect(ergebnis.map(\.id) == ["x", "f", "y", "z"])
    }

    @Test("Sieb für „Alle“: die Kopie aus der ersten Bibliothek bleibt, gezählt je Werk")
    func sieb() {
        var sieb = Titelsieb(je: [("filme", [film("f", tmdb: "1"), film("g")]),
                                  ("kino", [film("k", tmdb: "1"), film("h")])])
        #expect(sieb.gesamt == 3)
        #expect(sieb.sieben([film("k", tmdb: "1"), film("h"), film("f", tmdb: "1"), film("g")])
            .map(\.id) == ["h", "f", "g"])
    }
}
