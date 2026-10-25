import Testing
@testable import JellyfinKit

@Suite("Pluralformen")
struct PluralCategoryTests {

    @Test("Deutsch und Englisch: nur eins und der Rest")
    func germanEnglish() {
        #expect(PluralCategory.of(1, language: "de") == "one")
        #expect(PluralCategory.of(0, language: "de") == "other")
        #expect(PluralCategory.of(21, language: "en") == "other")
        #expect(PluralCategory.of(1, language: "en-US") == "one")
    }

    @Test("Russisch: 1 сезон, 2 сезона, 5 сезонов, 21 сезон")
    func russian() {
        for n in [1, 21, 101, 1001] { #expect(PluralCategory.of(n, language: "ru") == "one") }
        for n in [2, 3, 4, 22, 104] { #expect(PluralCategory.of(n, language: "ru") == "few") }
        for n in [0, 5, 11, 12, 14, 19, 100, 111] {
            #expect(PluralCategory.of(n, language: "ru") == "many")
        }
    }

    @Test("Unbekannte Sprache folgt der deutschen Regel")
    func unknown() {
        #expect(PluralCategory.of(1, language: "xx") == "one")
        #expect(PluralCategory.of(2, language: "xx") == "other")
    }
}
