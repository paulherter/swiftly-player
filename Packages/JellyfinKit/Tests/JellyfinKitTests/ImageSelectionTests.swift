import Foundation
import Testing
@testable import JellyfinKit

/// **The chain is not trusted, it is measured.**
///
/// Each step has a reason, and each reason is a case that occurs on the
/// server: an episode without its own backdrop, a series without a
/// thumbnail, a movie without anything. The tests build exactly these cases.
///
/// `Item` has no public initializer; it is created from JSON. That is
/// an advantage here: the tests run against what the server really sends,
/// field names included.
@Suite("Bildwahl")
struct ImageSelectionTests {

    private let addresses = ImageAddress(base: URL(string: "https://tv.example.de")!,
                                       token: "abc")

    private func item(_ json: String) throws -> Item {
        try JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    // MARK: Landscape: the chain

    @Test("Der Hintergrund der Serie steht vor allem anderen")
    func seriesBackgroundFirst() throws {
        let episode = try item("""
        {"Id":"f1","Name":"Folge","SeriesId":"s1",
         "ParentBackdropItemId":"s1","ParentBackdropImageTags":["bd"],
         "ImageTags":{"Primary":"pp","Thumb":"tt"}}
        """)
        let hit = ImageSelection.landscape(episode, addresses: addresses)
        #expect(hit?.source == "Serienhintergrund")
        #expect(hit?.url.path.contains("/Items/s1/Images/Backdrop") == true)
    }

    @Test("Ohne Serienhintergrund kommt der eigene — der Normalfall beim Film")
    func ownBackground() throws {
        let film = try item("""
        {"Id":"m1","Name":"Film","BackdropImageTags":["bd"]}
        """)
        let hit = ImageSelection.landscape(film, addresses: addresses)
        #expect(hit?.source == "eigener Hintergrund")
        #expect(hit?.url.path.contains("/Items/m1/Images/Backdrop") == true)
    }

    @Test("Eine Folge fällt zuletzt auf ihr eigenes Standbild zurück")
    func episodesStillImageLast() throws {
        let episode = try item("""
        {"Id":"f1","Name":"Folge","SeriesId":"s1","ImageTags":{"Primary":"pp"}}
        """)
        let hit = ImageSelection.landscape(episode, addresses: addresses)
        #expect(hit?.source == "Folgenstandbild")
    }

    @Test("Ein Film ohne Hintergrund bekommt kein Standbild untergeschoben")
    func filmWithoutBackgroundStaysEmpty() throws {
        // Step 5 applies explicitly to episodes only: putting a movie's poster
        // into a 16:9 tile would look worse than nothing.
        let film = try item("""
        {"Id":"m1","Name":"Film","ImageTags":{"Primary":"pp"}}
        """)
        #expect(ImageSelection.landscape(film, addresses: addresses) == nil)
    }

    @Test("Ohne Marke wird die Stufe übersprungen, nicht geraten")
    func withoutMarkSkipped() throws {
        // This is exactly where the 404s came from: without a tag the image does not exist,
        // and a guessed address looks like an empty tile.
        let episode = try item("""
        {"Id":"f1","Name":"Folge","SeriesId":"s1","ParentBackdropItemId":"s1",
         "ImageTags":{"Thumb":"tt"}}
        """)
        let hit = ImageSelection.landscape(episode, addresses: addresses)
        #expect(hit?.source == "eigene Vorschau")
    }

    @Test("Nichts da heißt nichts zurück")
    func garNot() throws {
        let empty = try item(#"{"Id":"x","Name":"Leer"}"#)
        #expect(ImageSelection.landscape(empty, addresses: addresses) == nil)
    }

    // MARK: Portrait

    @Test("Eine Folge zeigt hochkant das Plakat der Serie")
    func episodeShowsSeriesPoster() throws {
        let episode = try item("""
        {"Id":"f1","Name":"Folge","SeriesId":"s1","SeriesPrimaryImageTag":"sp",
         "ImageTags":{"Primary":"pp"}}
        """)
        let url = ImageSelection.portrait(episode, addresses: addresses)
        // An episode's own image is 16:9 and would be cut into 2:3.
        #expect(url?.path.contains("/Items/s1/Images/Primary") == true)
    }

    @Test("Eine Folge ohne Serienmarke nimmt ihr eigenes Bild")
    func episodeWithoutSeriesMark() throws {
        let episode = try item("""
        {"Id":"f1","Name":"Folge","SeriesId":"s1","ImageTags":{"Primary":"pp"}}
        """)
        let url = ImageSelection.portrait(episode, addresses: addresses)
        #expect(url?.path.contains("/Items/f1/Images/Primary") == true)
    }

    @Test("Ein Film nimmt sein eigenes Plakat")
    func filmPoster() throws {
        let film = try item(#"{"Id":"m1","Name":"Film","ImageTags":{"Primary":"pp"}}"#)
        #expect(ImageSelection.portrait(film, addresses: addresses)?
            .path.contains("/Items/m1/Images/Primary") == true)
    }

    // MARK: Watched fraction

    @Test("Null Prozent heißt kein Balken, nicht ein Balken der Länge null")
    func noBarNull() throws {
        let unwatched = try item("""
        {"Id":"x","Name":"X","UserData":{"PlayedPercentage":0}}
        """)
        #expect(unwatched.watchedShare == nil)
    }

    @Test("Prozent wird zu einem Anteil zwischen null und eins")
    func shareOutPercent() throws {
        let half = try item("""
        {"Id":"x","Name":"X","UserData":{"PlayedPercentage":42.5}}
        """)
        #expect(half.watchedShare == 0.425)
    }
}
