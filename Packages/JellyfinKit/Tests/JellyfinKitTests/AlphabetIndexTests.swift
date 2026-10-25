import Testing
@testable import JellyfinKit

@Suite("Alphabetleiste")
struct AlphabetIndexTests {

    @Test("Ziffern und Zeichen unter #, lateinische Akzente fallen weg, andere Schriften bleiben")
    func letters() {
        #expect(AlphabetIndex.letter(for: "47 ronin") == "#")
        #expect(AlphabetIndex.letter(for: "(500) days") == "#")
        #expect(AlphabetIndex.letter(for: "adam project") == "A")
        #expect(AlphabetIndex.letter(for: "élan") == "E")
        #expect(AlphabetIndex.letter(for: "ßtraße") == "S")
        #expect(AlphabetIndex.letter(for: "ёлки") == "Е")
        #expect(AlphabetIndex.letter(for: "йети") == "Й")
        #expect(AlphabetIndex.letter(for: "Ärger") == "A")
        #expect(AlphabetIndex.letter(for: "  ") == "#")
    }

    @Test("Lateinische Titel nach Sortiername, andere Schriften nach dem Titel")
    func titleLetter() {
        // The article goes, as the server sorts it.
        #expect(AlphabetIndex.letter(name: "The Adam Project", sortName: "adam project") == "A")
        // A transliterated sort name does not hide the Cyrillic title.
        #expect(AlphabetIndex.letter(name: "Выживший", sortName: "vyzhivshii") == "В")
        #expect(AlphabetIndex.letter(name: "47 Ронинов", sortName: "47 roninov") == "#")
        #expect(AlphabetIndex.letter(name: "Alvin", sortName: nil) == "A")
    }

    @Test("Alphabetisch: #, Latein, Kyrillisch mit Ё unter Е, dann der Rest")
    func entries() {
        // Server order with transliterated sort names: Cyrillic between the Latin ones.
        let index = AlphabetIndex(titles: [
            ("2 Guns", "2 guns"), ("Adam", "adam"), ("Вышибала", "vyshibala"),
            ("Venom", "venom"), ("Ёлки", "iolki"), ("Ешь, молись", "esh molis"),
            ("За бортом", "za bortom"), ("Über den Wolken", "uber den wolken"),
        ])
        #expect(index.entries.map(\.letter) == ["#", "A", "U", "V", "В", "Е", "З"])
        #expect(index.entries.first { $0.letter == "В" }?.first == 2)
        #expect(index.entries.first { $0.letter == "V" }?.first == 3)
        #expect(index.entries.first { $0.letter == "Е" }?.first == 4)
        #expect(index.count == 8)
        #expect(index.isUseful)
        #expect(!AlphabetIndex(titles: [("Alpha", nil), ("Avatar", nil)]).isUseful)
    }

    @Test("Ziel unter den Geladenen: der erste Titel mit genau diesem Buchstaben")
    func target() {
        let titles: [(name: String, sortName: String?)] = [
            ("47 Ronin", "47 ronin"), ("Adam", "adam"), ("Вышибала", "vyshibala"),
            ("Venom", "venom"), ("Высшая лига", "vysshaia liga"),
        ]
        let index = AlphabetIndex(titles: titles)
        #expect(index.target(for: "A", inLoaded: titles) == 1)
        #expect(index.target(for: "В", inLoaded: titles) == 2)
        #expect(index.target(for: "V", inLoaded: titles) == 3)
        #expect(index.target(for: "Z", inLoaded: titles) == nil)
        // Not loaded yet: load more.
        #expect(index.target(for: "V", inLoaded: Array(titles.prefix(3))) == nil)
    }

    @Test("Zu viele Buchstaben: erster und letzter bleiben, der Rest gleichmäßig")
    func condensed() {
        let names = (0..<26).map { (String(UnicodeScalar(97 + $0)!) + "x", Optional<String>.none) }
        let index = AlphabetIndex(titles: names)
        let five = index.condensed(fitting: 5)
        #expect(five.count == 5)
        #expect(five.first?.letter == "A")
        #expect(five.last?.letter == "Z")
        #expect(index.condensed(fitting: 40).count == 26)
    }
}
