import Foundation

/// **Die vier Abrufe, aus denen die Startseite entsteht.**
///
/// Ein Protokoll, damit der Lader ohne Server pruefbar ist. `JellyfinClient`
/// erfuellt es ohne eine Zeile Aenderung.
public protocol Startseitenquelle: Sendable {
    func resumeItems(limit: Int) async throws -> [Item]
    func nextUp(limit: Int) async throws -> [Item]
    func zuletztHinzugefuegt(in bibliothek: String?, holen: Int, zeigen: Int) async -> [Item]?
    func titel(gattung: String, limit: Int) async -> [Item]?
    /// Die Bibliotheken des Kontos — `nil`, wenn der Abruf nicht durchkam.
    func bibliotheken() async -> [Item]?
}

extension JellyfinClient: Startseitenquelle {
    public func bibliotheken() async -> [Item]? { try? await userViews() }
}

/// **Was auf der Startseite steht — fertig, bevor es eine Oberflaeche sieht.**
///
/// `nil` heisst „der Abruf kam nicht durch", nicht „leer". Die Oberflaeche
/// behaelt dann den alten Stand, ausser nach einem Kontowechsel — diese
/// Entscheidung bleibt bei ihr, weil nur sie den alten Stand kennt.
public struct Startseite: Sendable {
    public struct Gattungsreihe: Sendable, Identifiable {
        public let name: String
        public let items: [Item]
        public var id: String { name }
    }

    public let weiterschauen: [Item]?
    public let naechsteFolge: [Item]?
    /// Die gemeinsame Neuzugangsreihe — nur, wenn nicht getrennt.
    public let zuletzt: [Item]?
    public let neueFilme: [Item]?
    public let neueSerien: [Item]?
    public let gattungsreihen: [Gattungsreihe]
    /// Nichts kam an: weder Angefangenes noch Naechstes noch Neues.
    public let gestoert: Bool
}

/// **Eine Regel fuer alle Plattformen.**
///
/// Stand bis 15.09.2026 zweimal da: in `Startseitenmodell.laden` (iOS, tvOS,
/// macOS) und in `startseiteLaden` der GTK-Fassung — und schon auseinander.
/// Linux nahm die Titel aus „Weiterschauen" nicht aus „Nächste Folge" heraus
/// und kannte kein „gestört"; Apple liess Doppelte in Genre-Reihen stehen.
/// Hier gilt jeweils die richtigere Fassung, fuer alle. Android bekommt
/// dieselbe Regel ueber `SwiftlyKern`.
public enum Startseitenlader {

    public struct Wunsch: Sendable {
        public var getrennt: Bool
        public var filmBibliothek: String?
        public var serienBibliothek: String?
        /// `nil`, wenn die Genres als Chips oben stehen — dann gibt es keine Reihen.
        public var gattungen: [String]?
        /// Was zuletzt in „Weiterschauen" stand. Kommt der neue Abruf nicht
        /// durch, filtert „Nächste Folge" gegen diesen Stand.
        public var bisherWeiterschauen: [Item]

        public init(getrennt: Bool, filmBibliothek: String? = nil, serienBibliothek: String? = nil,
                    gattungen: [String]? = nil, bisherWeiterschauen: [Item] = []) {
            self.getrennt = getrennt
            self.filmBibliothek = filmBibliothek
            self.serienBibliothek = serienBibliothek
            self.gattungen = gattungen
            self.bisherWeiterschauen = bisherWeiterschauen
        }
    }

    /// **Die Genre-Reihen fuer sich.** Apple zeigt die festen Reihen sofort und
    /// die Genres danach — wer beides auf einmal holt, laesst die festen Reihen
    /// auf den langsamsten Genre-Abruf warten. In der gewaehlten Folge, leere
    /// fallen weg, ohne Doppelte.
    ///
    /// **Alle Genres zugleich, nicht eins nach dem anderen.** Nacheinander
    /// dauerte die letzte Reihe so viele Netzwege, wie Genres gewaehlt sind;
    /// jetzt dauern alle zusammen so lange wie der langsamste. Die Reihenfolge
    /// kommt aus `namen`, nicht aus der Ankunft.
    public static func gattungsreihen(von quelle: some Startseitenquelle,
                                      namen: [String]) async -> [Startseite.Gattungsreihe] {
        let geholt = await withTaskGroup(of: (Int, [Item]?).self) { gruppe in
            for (i, name) in namen.enumerated() {
                gruppe.addTask { (i, await quelle.titel(gattung: name, limit: 24)) }
            }
            var je: [Int: [Item]] = [:]
            for await (i, titel) in gruppe { if let titel { je[i] = titel } }
            return je
        }
        return namen.indices.compactMap { i in
            guard let titel = geholt[i], !titel.isEmpty else { return nil }
            return .init(name: namen[i], items: Listenregeln.ohneDoppelte(titel))
        }
    }

    /// **Eine getrennte Neuzugangsreihe: erst die Bibliothek, nie still leer.**
    ///
    /// Ohne `ParentId` liefert der Server die Neuzugaenge **aller**
    /// Bibliotheken — „Neue Serien" zeigte so dieselben Filme wie „Neue
    /// Filme". Deshalb fragt die Reihe zuerst in der gewaehlten Bibliothek,
    /// ohne Wahl in jeder Bibliothek der Art (die erste mit Neuzugaengen
    /// zaehlt, wie `AppModel.gewaehlteBibliothek(art:)`).
    ///
    /// **Findet sich dort nichts, faellt sie auf die Abfrage ohne `ParentId`
    /// zurueck** — nur mit Titeln der passenden Gattung, damit keine Filme in
    /// „Neue Serien" stehen. Das trifft Server, deren Bibliotheken keine oder
    /// eine gemischte Art tragen, deren Bibliotheksliste nicht lesbar ist, oder
    /// deren gewaehlte Bibliothek leer ist. Bis 1.0.5 (15) blieb die Reihe dann
    /// leer und fiel auf der Startseite ohne Hinweis weg. Grund und Fall stehen
    /// im Protokoll (Profil → „Protokoll teilen").
    static func neu(von quelle: some Startseitenquelle, in bibliothek: String?,
                    art: String) async -> [Item]? {
        let grund: String
        if let bibliothek {
            let geholt = await quelle.zuletztHinzugefuegt(in: bibliothek, holen: 200, zeigen: 24)
            if let geholt, !geholt.isEmpty { return geholt }
            grund = geholt == nil ? "Abruf der gewaehlten Bibliothek kam nicht durch"
                                  : "gewaehlte Bibliothek ohne Neuzugaenge"
        } else if let alle = await quelle.bibliotheken() {
            let passende = alle.filter { $0.collectionType?.lowercased() == art }
            var leer = 0
            for kandidat in passende {
                if let geholt = await quelle.zuletztHinzugefuegt(in: kandidat.id, holen: 200, zeigen: 24) {
                    if !geholt.isEmpty { return geholt }
                    leer += 1
                }
            }
            if passende.isEmpty {
                let arten = alle.map { $0.collectionType ?? "ohne" }.joined(separator: ",")
                grund = "keine Bibliothek der Art (\(alle.count) Bibliotheken: \(arten))"
            } else {
                grund = "\(passende.count) Bibliothek(en) der Art, \(leer) leer, Rest nicht erreichbar"
            }
        } else {
            grund = "Bibliotheksliste nicht lesbar"
        }
        let gattungen: Set<String> = art == "movies" ? ["Movie"] : ["Episode", "Series", "Season"]
        guard let alle = await quelle.zuletztHinzugefuegt(in: nil, holen: 200, zeigen: 48) else {
            Protokollring.geteilt.anhaengen("Startseite: Neu \(art): \(grund); Rueckfall ohne Bibliothek kam nicht durch")
            return nil
        }
        let passend = Array(alle.filter { gattungen.contains($0.type ?? "") }.prefix(24))
        Protokollring.geteilt.anhaengen("Startseite: Neu \(art): \(grund); Rueckfall ohne Bibliothek, \(passend.count) Titel")
        return passend
    }

    public static func laden(von quelle: some Startseitenquelle, _ wunsch: Wunsch) async -> Startseite {
        async let angefangen = try? quelle.resumeItems(limit: 20)
        async let naechste = try? quelle.nextUp(limit: 20)
        async let gemeinsam = wunsch.getrennt ? nil
            : quelle.zuletztHinzugefuegt(in: nil, holen: 200, zeigen: 24)
        async let filme = wunsch.getrennt
            ? neu(von: quelle, in: wunsch.filmBibliothek, art: "movies") : nil
        async let serien = wunsch.getrennt
            ? neu(von: quelle, in: wunsch.serienBibliothek, art: "tvshows") : nil

        let a = await angefangen
        let schonDa = Set((a ?? wunsch.bisherWeiterschauen).map(\.id))
        let b = await naechste.map { $0.filter { !schonDa.contains($0.id) } }
        let c = await gemeinsam
        let d = await filme
        let e = await serien

        let reihen = await gattungsreihen(von: quelle, namen: wunsch.gattungen ?? [])

        let neuesDa = wunsch.getrennt ? (d != nil || e != nil) : c != nil
        return Startseite(
            weiterschauen: a.map(Listenregeln.ohneDoppelte),
            naechsteFolge: b.map(Listenregeln.ohneDoppelte),
            zuletzt: c.map(Listenregeln.ohneDoppelte),
            neueFilme: d.map(Listenregeln.ohneDoppelte),
            neueSerien: e.map(Listenregeln.ohneDoppelte),
            gattungsreihen: reihen,
            gestoert: a == nil && b == nil && !neuesDa)
    }
}
