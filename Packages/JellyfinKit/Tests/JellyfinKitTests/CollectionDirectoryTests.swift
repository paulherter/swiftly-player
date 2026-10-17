import Testing
@testable import JellyfinKit

/// The rule behind "N movies" or "N series" under a collection tile,
/// kept once here instead of in three places (Apple, Mac, Android via the core).
///
/// **Checked without fixed wording**, like `newArrivalsRow` in
/// `AuthRequestTests`: which language the catalog picks in the test
/// run is not fixed, only the number and the difference between the kinds.
@Suite("Sammlungsanzahl")
struct CollectionCountTextTests {

    @Test func seriesInTvshows() {
        #expect(ItemCollection.countText(art: "tvshows", count: 3).contains("3"))
    }

    @Test func moviesElse() {
        #expect(ItemCollection.countText(art: "movies", count: 3).contains("3"))
    }

    /// Movies and series must not carry the same text.
    @Test func moviesAndSeriesDiffer() {
        #expect(ItemCollection.countText(art: "movies", count: 3) != ItemCollection.countText(art: "tvshows", count: 3))
    }

    /// The case of `art` must not change anything, just as
    /// `ItemCollection.count(art:)` itself compares with `.lowercased()`.
    @Test func artCaseIrrelevant() {
        #expect(ItemCollection.countText(art: "TVShows", count: 1) == ItemCollection.countText(art: "tvshows", count: 1))
    }

    /// Singular and plural differ; the collection tile should
    /// not show "1 Filme".
    @Test func singularAndPluralDiffer() {
        #expect(ItemCollection.countText(art: "movies", count: 1) != ItemCollection.countText(art: "movies", count: 2))
        #expect(ItemCollection.countText(art: "tvshows", count: 1) != ItemCollection.countText(art: "tvshows", count: 2))
    }
}
