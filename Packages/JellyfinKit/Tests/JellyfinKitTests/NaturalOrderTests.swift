import Foundation
import Testing
@testable import JellyfinKit

@Suite("Natürliche Sortierung")
struct NaturalOrderTests {

    private func order(_ titles: [(String, String?)], locale: String = "ru_RU") -> [String] {
        NaturalOrder.sorted(titles, locale: Locale(identifier: locale)) { ($0.0, $0.1) }.map(\.0)
    }

    @Test("Ziffern zuerst und als Zahlen, dann Latein, dann Kyrillisch")
    func groups() {
        let server: [(String, String?)] = [
            ("Выживший", "vyzhivshii"), ("12 стульев", "12 stulev"), ("Venom", "venom"),
            ("2+1", "2+1"), ("007: Спектр", "007 spektr"), ("Adam", "adam"),
            ("За бортом", "za bortom"), ("Zootopia", "zootopia"), ("8 подруг", "8 podrug"),
        ]
        #expect(order(server) == ["2+1", "007: Спектр", "8 подруг", "12 стульев",
                                  "Adam", "Venom", "Zootopia", "Выживший", "За бортом"])
    }

    @Test("Anführungszeichen vorn zählen nicht: «Старый» Новый год steht bei С")
    func quotes() {
        #expect(order([("«Старый» Новый год", "staryi novyi god"), ("1+1", "1+1"),
                       ("Сказка", "skazka"), ("Сталкер", "stalker")])
                == ["1+1", "Сказка", "Сталкер", "«Старый» Новый год"])
    }

    @Test("Lateinische Titel nach Sortiername, ohne Artikel")
    func article() {
        #expect(order([("The Batman", "batman"), ("The Adam Project", "adam project"), ("Alvin", "alvin")])
                == ["The Adam Project", "Alvin", "The Batman"])
    }

    @Test("Kyrillisch nach russischen Regeln: Ё wie Е einsortiert, wie im Wörterbuch, vor Ж")
    func cyrillic() {
        #expect(order([("Жанна", nil), ("Ёлки", nil), ("Ешь", nil), ("Елена", nil)])
                == ["Елена", "Ёлки", "Ешь", "Жанна"])
    }

    @Test("Deutsch, Englisch, Russisch gemischt: Umlaute bei ihrem Buchstaben, Kyrillisch danach")
    func scripts() {
        let titles: [(String, String?)] = [
            ("Ёлки", "iolki"), ("Über den Wolken", "uber den wolken"), ("Alien", "alien"),
            ("Ärger im Paradies", "arger im paradies"), ("Батман", "batman"), ("Up", "up"),
        ]
        #expect(order(titles, locale: "de_DE")
                == ["Alien", "Ärger im Paradies", "Über den Wolken", "Up", "Батман", "Ёлки"])
        // The strip has the same order and the same letters.
        let index = AlphabetIndex(titles: titles.map { (name: $0.0, sortName: $0.1) })
        #expect(index.entries.map(\.letter) == ["A", "U", "Б", "Е"])
    }

    @Test("Gleiche Namen behalten die Reihenfolge des Servers")
    func stable() {
        let titles = [("Dune", "dune", 1), ("Dune", "dune", 2), ("Alien", "alien", 3)]
        let sorted = NaturalOrder.sorted(titles) { ($0.0, $0.1) }
        #expect(sorted.map(\.2) == [3, 1, 2])
    }
}
