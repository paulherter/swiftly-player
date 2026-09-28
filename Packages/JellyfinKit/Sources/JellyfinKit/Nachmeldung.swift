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

    /// **Der neuere Stand gewinnt** (`UserData.LastPlayedDate`).
    ///
    /// Hat jemand den Titel seit dem Flug anderswo weitergeschaut — am
    /// Fernseher, auf dem Mac —, traegt der Server einen juengeren Zeitpunkt.
    /// Dann waere die Stelle aus dem Flugzeug ein Rueckschritt, und sie
    /// verfaellt. Ohne Zeitpunkt am Server (nie gespielt) geht sie hin.
    public static func senden(_ m: Nachmeldung, serverZuletzt: Date?) -> Bool {
        guard let serverZuletzt else { return true }
        return m.wann > serverZuletzt
    }

    /// **Eine Meldung ging doch noch durch** — dann ist die liegende fuer
    /// denselben Titel dieses Kontos ueberholt und darf nie mehr hinaus.
    /// Sonst schickte das naechste Wiederverbinden eine aeltere Stelle
    /// hinterher, und das waere eine Doppelmeldung mit Rueckschritt.
    public static func ueberholt(itemID: String, konto: String,
                                 in ablage: [Nachmeldung]) -> [Nachmeldung] {
        ablage.filter { !($0.itemID == itemID && $0.konto == konto) }
    }
}

public extension JellyfinClient {

    /// Was aus einer Nachmeldung wurde.
    enum Nachmeldeausgang: Sendable, Equatable {
        /// Angekommen.
        case gesendet
        /// Nicht gesendet und erledigt: der Server hat einen neueren Stand,
        /// oder den Titel gibt es dort nicht mehr.
        case verworfen
    }

    /// **Eine liegengebliebene Stelle an den Server — wenn sie noch gilt.**
    ///
    /// Erst den Stand am Server lesen, dann entscheiden
    /// (``Nachmelderegeln/senden(_:serverZuletzt:)``), dann als Ende einer
    /// Wiedergabe melden. Das Ende und nicht ein blosses Setzen der Stelle:
    /// so wendet der Server seine eigenen Schwellen an und setzt „gesehen",
    /// wenn die Folge im Flugzeug zu Ende lief — dieselbe Regel wie bei
    /// einer Wiedergabe mit Netz.
    ///
    /// Wirft bei einem Netz- oder Serverfehler; dann bleibt die Meldung liegen.
    func nachmelden(_ m: Nachmeldung) async throws -> Nachmeldeausgang {
        let stand: UserItemData
        do {
            stand = try await nutzerdaten(itemID: m.itemID)
        } catch JellyfinError.http(status: 404, _) {
            return .verworfen
        }
        guard Nachmelderegeln.senden(m, serverZuletzt: stand.zuletztGespielt) else {
            return .verworfen
        }
        // Ein Plan von der Platte reicht: gemeldet werden nur die Kennungen,
        // und eine Sitzung gab es offline ohnehin nicht.
        let plan = PlaybackPlan.vonDerPlatte(URL(fileURLWithPath: "/"), container: nil)
        try await reportStopped(itemID: m.itemID, plan: plan, positionTicks: m.ticks)
        // **Und wann es war.** Ein Ende ohne vorherigen Start setzt am Server
        // kein `LastPlayedDate` (am Prüfserver gemessen, 25.09.2026) — ohne
        // diese Zeile hätte die nächste Entscheidung nach dem Zeitstempel
        // nichts, woran sie sich halten kann. Scheitert nur das, ist die
        // Stelle trotzdem angekommen.
        try? await zuletztGespieltSetzen(itemID: m.itemID, wann: m.wann)
        return .gesendet
    }

    /// **Alles Liegengebliebene eines Kontos, aelteste zuerst.**
    ///
    /// Gibt die Kennungen zurueck, die erledigt sind (gesendet oder
    /// verworfen). Beim ersten Fehler wird abgebrochen, nicht weiterprobiert:
    /// scheitert eine, ist der Server wieder weg, und die uebrigen stuenden
    /// danach als verloren da.
    func nachmelden(_ offen: [Nachmeldung],
                    protokoll: @Sendable (String) -> Void = { _ in }) async -> [String] {
        var erledigt: [String] = []
        for m in offen {
            do {
                let ausgang = try await nachmelden(m)
                protokoll("[Melden] Nachmeldung \(m.itemID) \(m.ticks / 10_000_000) s: \(ausgang)")
                erledigt.append(m.id)
            } catch {
                protokoll("[Melden] Nachmeldung \(m.itemID) gescheitert, bleibt liegen")
                break
            }
        }
        return erledigt
    }
}
