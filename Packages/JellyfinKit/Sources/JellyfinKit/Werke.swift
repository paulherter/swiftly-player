import Foundation

/// **Ein Werk, ein Eintrag — auch wenn es in zwei Bibliotheken liegt.**
///
/// Liegt dieselbe Datei in zwei Bibliotheken (eine Test- oder Zusatzbibliothek
/// neben der eigentlichen, Hardlinks auf dieselben Dateien), führt Jellyfin
/// sie als zwei Einträge mit verschiedenen Kennungen. Den Stand teilt der
/// Server zwischen beiden — er verknüpft ihn über die Anbieternummern —,
/// deshalb stehen dann auch beide unter „Weiterschauen".
///
/// Gilt für Listen **quer über Bibliotheken**: Weiterschauen, Nächste Folge,
/// Zuletzt hinzugefügt, Suche, Merkliste, „Alle Filme"/„Alle Serien".
/// **Nicht** innerhalb einer Bibliotheksseite — dort bleibt, was der Server
/// liefert.
///
/// **Gleich ist, was eine Anbieternummer teilt** (TMDb, IMDb, TVDb):
/// - Film mit Film, Serie mit Serie — nach ihren eigenen Nummern.
/// - Folge mit Folge: dieselbe Serie (nach den Nummern der Serie), dieselbe
///   Staffel, dieselbe Folgennummer.
/// - **Ohne Nummern wird nichts zusammengefasst.** Name und Jahr sind kein
///   Beweis; zwei verschiedene Filme gleichen Namens gibt es.
///
/// Es reicht **eine** gemeinsame Nummer: trägt die eine Kopie TMDb und IMDb,
/// die andere nur IMDb, sind es trotzdem dieselben.
///
/// **Welcher Eintrag bleibt** (``rang(_:herkunft:bibliotheken:)``):
/// 1. der aus einer Film- oder Serienbibliothek vor dem aus einer gemischten,
///    einer Heimvideo- oder Ordnerbibliothek,
/// 2. dann der aus der Bibliothek, die in der Reihenfolge des Kontos zuerst
///    kommt,
/// 3. dann der mit Stand (angefangen, gesehen, zuletzt gespielt),
/// 4. dann der frühere in der Liste.
///
/// **Die Stelle in der Liste gehört dem ersten Auftreten** — der Sieger
/// rückt an den Platz der Kopie, die zuerst kam. So bleibt die Sortierung
/// des Servers stehen.
public enum Werke {

    /// Die Anbieter, in der Reihenfolge des Vorrangs.
    static let anbieter = ["Tmdb", "Imdb", "Tvdb"]

    /// Anbieternummern einer Serie, nach Kennung der Serie. Eine Folge trägt
    /// die Nummern ihrer Serie nicht, nur deren Kennung — und die Kennung ist
    /// genau das, was sich zwischen den Bibliotheken unterscheidet.
    public typealias Seriennummern = [String: [String: String]]

    /// Wodurch ein Eintrag als Werk erkennbar ist. Leer: nie zusammenfassen.
    ///
    /// - Parameter folgenJeSerie: Eine Folge zählt als ihre Serie — für
    ///   „Zuletzt hinzugefügt", wo eine Serie mit ihrer neuesten Folge einmal
    ///   dasteht.
    static func merkmale(_ item: Item, serien: Seriennummern,
                         folgenJeSerie: Bool = false) -> [String] {
        func nummern(_ ids: [String: String]?, _ vorsilbe: String) -> [String] {
            anbieter.compactMap { a in
                guard let nr = ids?[a]?.trimmingCharacters(in: .whitespaces), !nr.isEmpty
                else { return nil }
                return "\(vorsilbe):\(a.lowercased()):\(nr.lowercased())"
            }
        }
        switch item.type {
        case "Movie":
            return nummern(item.providerIds, "film")
        case "Series":
            return nummern(item.providerIds, "serie")
        case "Episode":
            guard let serie = item.seriesId else { return [] }
            if folgenJeSerie { return nummern(serien[serie], "serie") }
            guard let staffel = item.parentIndexNumber, let folge = item.indexNumber else { return [] }
            return nummern(serien[serie], "folge:\(staffel):\(folge)")
        default:
            return []
        }
    }

    /// **Welche Einträge dasselbe Werk sind** — je Gruppe die Stellen in der
    /// Liste, aufsteigend. Einträge ohne Doppel bilden eine Gruppe für sich.
    /// Die Gruppen stehen in der Reihenfolge ihres ersten Eintrags.
    public static func gruppen(_ items: [Item], serien: Seriennummern = [:],
                               folgenJeSerie: Bool = false) -> [[Int]] {
        var eltern = Array(items.indices)
        func wurzel(_ i: Int) -> Int {
            var i = i
            while eltern[i] != i { eltern[i] = eltern[eltern[i]]; i = eltern[i] }
            return i
        }
        var erster: [String: Int] = [:]
        for (i, item) in items.enumerated() {
            for m in merkmale(item, serien: serien, folgenJeSerie: folgenJeSerie) {
                if let j = erster[m] {
                    let a = wurzel(i), b = wurzel(j)
                    if a != b { eltern[max(a, b)] = min(a, b) }
                } else {
                    erster[m] = i
                }
            }
        }
        var je: [Int: [Int]] = [:]
        var folge: [Int] = []
        for i in items.indices {
            let w = wurzel(i)
            if je[w] == nil { folge.append(w) }
            je[w, default: []].append(i)
        }
        return folge.map { je[$0]! }
    }

    /// Ob es in der Liste überhaupt etwas zusammenzufassen gibt.
    public static func hatDoppelte(_ items: [Item], serien: Seriennummern = [:],
                                   folgenJeSerie: Bool = false) -> Bool {
        gruppen(items, serien: serien, folgenJeSerie: folgenJeSerie).contains { $0.count > 1 }
    }

    /// **Rang eines Eintrags nach seiner Bibliothek** — kleiner ist besser.
    ///
    /// Unbekannte Herkunft (eine ausgeblendete Bibliothek, oder die Abfrage
    /// ist gescheitert) steht hinten.
    static func rang(_ item: Item, herkunft: [String: String], bibliotheken: [Item]) -> (Int, Int) {
        guard let von = herkunft[item.id],
              let stelle = bibliotheken.firstIndex(where: { $0.id == von })
        else { return (2, Int.max) }
        let art = bibliotheken[stelle].collectionType?.lowercased()
        return (art == "movies" || art == "tvshows" ? 0 : 1, stelle)
    }

    static func hatStand(_ item: Item) -> Bool {
        guard let d = item.userData else { return false }
        return (d.playbackPositionTicks ?? 0) > 0 || d.played == true || d.lastPlayedDate != nil
    }

    /// **Je Werk ein Eintrag**, an der Stelle seines ersten Auftretens.
    ///
    /// - Parameters:
    ///   - herkunft: Kennung des Eintrags → Kennung seiner Bibliothek. Nur für
    ///     Einträge nötig, die ein Doppel haben.
    ///   - bibliotheken: Die Bibliotheken des Kontos (`UserViews`), in ihrer
    ///     Reihenfolge.
    ///   - serien: Anbieternummern der Serien, für Folgen.
    public static func zusammenfassen(_ items: [Item],
                                      herkunft: [String: String] = [:],
                                      bibliotheken: [Item] = [],
                                      serien: Seriennummern = [:],
                                      folgenJeSerie: Bool = false) -> [Item] {
        gruppen(items, serien: serien, folgenJeSerie: folgenJeSerie).map { gruppe in
            let sieger = gruppe.min { a, b in
                let ra = rang(items[a], herkunft: herkunft, bibliotheken: bibliotheken)
                let rb = rang(items[b], herkunft: herkunft, bibliotheken: bibliotheken)
                if ra != rb { return ra < rb }
                let sa = hatStand(items[a]), sb = hatStand(items[b])
                if sa != sb { return sa }
                return a < b
            }!
            return items[sieger]
        }
    }

    /// Die Einträge, deren Herkunft zählt: alle, die ein Doppel haben.
    static func mitDoppel(_ items: [Item], serien: Seriennummern, folgenJeSerie: Bool) -> [Item] {
        gruppen(items, serien: serien, folgenJeSerie: folgenJeSerie)
            .filter { $0.count > 1 }.flatMap { $0.map { items[$0] } }
    }

    /// **Ob Folgen verschiedener Serienkennungen dieselbe Serie sein
    /// könnten** — dann lohnt es, die Nummern der Serien zu holen. Vorprüfung
    /// über den Seriennamen; entscheiden tun erst die Nummern.
    static func serienVerdacht(_ items: [Item]) -> Set<String> {
        var je: [String: Set<String>] = [:]
        for i in items where i.type == "Episode" {
            guard let id = i.seriesId, let name = i.seriesName else { continue }
            let schluessel = name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                          locale: nil).trimmingCharacters(in: .whitespaces)
            je[schluessel, default: []].insert(id)
        }
        return je.values.filter { $0.count > 1 }.reduce(into: Set()) { $0.formUnion($1) }
    }
}

public extension JellyfinClient {

    /// **Je Werk ein Eintrag — mit dem, was die Regel dafür vom Server
    /// braucht.** Siehe ``Werke``.
    ///
    /// Ohne Doppel kostet das keine Abfrage. Mit Doppeln: einmal die Nummern
    /// der beteiligten Serien (nur bei Folgen), die Bibliotheken des Kontos,
    /// und je Doppel seine Bibliothek. Scheitert davon etwas, wird trotzdem
    /// zusammengefasst — dann bleibt der frühere Eintrag.
    func jeWerkEinmal(_ items: [Item], folgenJeSerie: Bool = false) async -> [Item] {
        let verdacht = Werke.serienVerdacht(items)
        var serien: Werke.Seriennummern = [:]
        if !verdacht.isEmpty, let geholt = try? await kennungen(ids: Array(verdacht)) {
            for s in geholt { serien[s.id] = s.providerIds ?? [:] }
        }
        let doppel = Werke.mitDoppel(items, serien: serien, folgenJeSerie: folgenJeSerie)
        guard !doppel.isEmpty else { return items }
        let bibliotheken = (try? await userViews()) ?? []
        let herkunft = await herkunft(von: doppel.map(\.id), unter: Set(bibliotheken.map(\.id)))
        return Werke.zusammenfassen(items, herkunft: herkunft, bibliotheken: bibliotheken,
                                    serien: serien, folgenJeSerie: folgenJeSerie)
    }

    /// Aus welcher Bibliothek ein Eintrag stammt — über seine Vorfahren. Der
    /// Server übersetzt dabei den Bibliotheksordner in die Ansicht des
    /// Kontos, dieselbe Kennung wie in `UserViews`.
    func herkunft(von ids: [String], unter bibliotheken: Set<String>) async -> [String: String] {
        guard !bibliotheken.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, String?).self) { gruppe in
            for id in Set(ids) {
                gruppe.addTask {
                    let ahnen = (try? await self.vorfahren(von: id)) ?? []
                    return (id, ahnen.first { bibliotheken.contains($0.id) }?.id)
                }
            }
            var je: [String: String] = [:]
            for await (id, von) in gruppe { if let von { je[id] = von } }
            return je
        }
    }

    /// **Die Merkliste, je Werk einmal — und trotzdem seitenweise.**
    ///
    /// Die Seiten zählen in **Werken**, nicht in Einträgen des Servers: wer
    /// `startIndex` aus der Zahl der geladenen Kacheln bildet, bekommt die
    /// nächste Seite lückenlos. Dafür kommt erst die ganze Merkliste schlank
    /// (Kennung, Gattung, Nummern — in derselben Sortierung), daraus steht
    /// fest, was bleibt; die Seite selbst kommt dann vollständig über ihre
    /// Kennungen.
    func gemerkteWerke(typen: [String], sortBy: String, sortOrder: String,
                       startIndex: Int, limit: Int) async throws -> ItemsResponse {
        let alle = try await gemerkteKennungen(typen: typen, sortBy: sortBy, sortOrder: sortOrder)
        let werke = await jeWerkEinmal(alle)
        let seite = Array(werke.dropFirst(startIndex).prefix(limit))
        guard !seite.isEmpty else { return ItemsResponse(items: [], totalRecordCount: werke.count) }
        let voll = try await items(limit: seite.count, ids: seite.map(\.id))
        return ItemsResponse(items: Listenregeln.inReihenfolge(voll.items, wie: seite),
                             totalRecordCount: werke.count)
    }
}
