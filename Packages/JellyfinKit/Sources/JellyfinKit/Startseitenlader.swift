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
}

extension JellyfinClient: Startseitenquelle {}

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
    public static func gattungsreihen(von quelle: some Startseitenquelle,
                                      namen: [String]) async -> [Startseite.Gattungsreihe] {
        var reihen: [Startseite.Gattungsreihe] = []
        for name in namen {
            guard let titel = await quelle.titel(gattung: name, limit: 24), !titel.isEmpty else { continue }
            reihen.append(.init(name: name, items: Listenregeln.ohneDoppelte(titel)))
        }
        return reihen
    }

    public static func laden(von quelle: some Startseitenquelle, _ wunsch: Wunsch) async -> Startseite {
        async let angefangen = try? quelle.resumeItems(limit: 20)
        async let naechste = try? quelle.nextUp(limit: 20)
        async let gemeinsam = wunsch.getrennt ? nil
            : quelle.zuletztHinzugefuegt(in: nil, holen: 60, zeigen: 24)
        async let filme = wunsch.getrennt
            ? quelle.zuletztHinzugefuegt(in: wunsch.filmBibliothek, holen: 60, zeigen: 24) : nil
        async let serien = wunsch.getrennt
            ? quelle.zuletztHinzugefuegt(in: wunsch.serienBibliothek, holen: 60, zeigen: 24) : nil

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
