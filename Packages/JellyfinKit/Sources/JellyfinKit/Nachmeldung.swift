import Foundation

/// Was der Server noch nicht weiss — **die zweite Hälfte von H8.**
///
/// Wer einen Titel heruntergeladen hat, sieht ihn im Flugzeug. Dabei entsteht
/// genau die Angabe, für die es die Funktion gibt: **wo er aufgehört hat.**
/// Ohne diese Ablage wäre sie weg — der Server hätte den Stand vom Start des
/// Flugs, und auf dem Fernseher zu Hause liefe die Folge von vorn los.
///
/// **Eine Angabe je Titel, die neueste gilt.** Nicht ein Protokoll aller
/// Sprünge: der Server will wissen, wo man steht, nicht wie man dorthin
/// gekommen ist. Zehn Meldungen desselben Titels nacheinander abzuschicken
/// wäre nicht nur Verkehr, sondern auch falsch — die vorletzte träfe zuletzt
/// ein, wenn zwei Anfragen sich überholen.
public struct Nachmeldung: Codable, Sendable, Equatable, Identifiable {
    public let itemID: String
    /// Das Konto, dem der Stand gehört. Dieselbe Regel wie bei H11: eine
    /// Stelle, die in einem fremden Konto landet, ist schlimmer als keine.
    public let konto: String
    public let ticks: Int64
    public let wann: Date

    public var id: String { konto + "/" + itemID }

    public init(itemID: String, konto: String, ticks: Int64, wann: Date = Date()) {
        self.itemID = itemID
        self.konto = konto
        self.ticks = ticks
        self.wann = wann
    }
}

public enum Nachmelderegeln {

    /// Eine neue Meldung in die Ablage — die alte desselben Titels fällt weg.
    public static func aufnehmen(_ neu: Nachmeldung,
                                 in ablage: [Nachmeldung]) -> [Nachmeldung] {
        // **Die ältere gewinnt nie.** Beim Wiederherstellen nach einem
        // Absturz kann eine alte Meldung nachträglich hereinkommen; sie darf
        // eine neuere Stelle nicht überschreiben.
        if let alt = ablage.first(where: { $0.id == neu.id }), alt.wann > neu.wann {
            return ablage
        }
        return ablage.filter { $0.id != neu.id } + [neu]
    }

    /// Was für dieses Konto abzuschicken ist, älteste zuerst.
    public static func faellig(_ ablage: [Nachmeldung], konto: String) -> [Nachmeldung] {
        ablage.filter { $0.konto == konto }.sorted { $0.wann < $1.wann }
    }

    /// Nach dem erfolgreichen Senden.
    public static func erledigt(_ ids: [String], in ablage: [Nachmeldung]) -> [Nachmeldung] {
        ablage.filter { !ids.contains($0.id) }
    }
}
