#if DEBUG
import Foundation
import JellyfinKit

/// **Selbsttest für Downloads ohne Netz** — ohne Finger, nur über das
/// Protokoll.
///
///     xcrun simctl launch <geraet> de.paulherter.swiftly -offlinelauf -offlinekonto <Name>
///
/// Nimmt zwei aufeinanderfolgende Folgen von „The Mentalist" mit Vorspann-
/// und Abspann-Abschnitt, lädt beide (sofern nicht schon da), schaltet das
/// Netz über ``Netzsperre`` ab und prüft:
///
/// 1. ob Abschnitte und nächste Folge ohne Server da sind,
/// 2. was der Player an beiden Stellen anbietet und ob „Nächste Folge" wechselt,
/// 3. was lokal gemerkt wird (Nachmeldungen, Stand am Download),
/// 4. nach dem Wiederverbinden: was am Server ankommt, dass eine ältere
///    Meldung einen neueren Serverstand nicht überschreibt und dass nichts
///    doppelt geht.
///
/// Danach legt er den Wiedergabestand beider Folgen genau so zurück, wie er
/// vorher war, und entfernt Downloads, die er selbst angelegt hat.
@MainActor
enum Offlinelauf {
    static var an: Bool { ProcessInfo.processInfo.arguments.contains("-offlinelauf") }

    private static var erste: Item?
    private static var zweite: Item?
    private static var roh: [String: Data] = [:]
    private static var vorspann: JellyfinKit.Abschnitt?
    private static var abspann: JellyfinKit.Abschnitt?
    private static var selbstGeladen: [String] = []
    private static var vorherKonto: String?

    private static func log(_ text: String) { Protokoll.schreib("[Offlinelauf] " + text) }

    /// Sucht das Paar, lädt, schaltet das Netz ab und gibt den Wunsch für den
    /// Player zurück — oder `nil`, wenn etwas fehlt.
    static func wunsch(_ model: AppModel) async -> Abspielwunsch? {
        guard model.session != nil else { log("nicht angemeldet"); return nil }
        log("Konto \(model.session?.userName ?? "?") · im Bund: \(model.konten.map { "\($0.userName) \($0.serverURL.host() ?? "")" })")
        // **Nur auf dem ausdrücklich genannten Profil** (`-offlinekonto <Name>`),
        // nie auf einem anderen — dort stehen echte Sehstände. Liegt es im
        // Bund, aber nicht vorn, wird umgeschaltet und am Ende zurück.
        let args = ProcessInfo.processInfo.arguments
        let erlaubt = args.firstIndex(of: "-offlinekonto").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        guard let erlaubt, !erlaubt.lowercased().contains("eltern")
        else { log("Profil nicht freigegeben — Lauf endet"); return nil }
        if model.session?.userName != erlaubt,
           let ziel = model.konten.first(where: { $0.userName == erlaubt }) {
            vorherKonto = model.session?.kontoschluessel
            model.kontoWechseln(zu: ziel.kontoschluessel)
            for _ in 0..<40 where model.session?.userName != erlaubt || model.client == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(3))
            log("umgeschaltet auf \(model.session?.userName ?? "?")")
        }
        guard model.session?.userName == erlaubt, let client = model.client,
              let konto = model.session?.userID
        else { log("Profil \(erlaubt) nicht aktiv — Lauf endet"); return nil }
        let treffer = await model.suche("Mentalist")
        guard let serie = treffer?.first(where: { $0.type == "Series" && $0.name == "The Mentalist" })
        else { log("keine Serie: \(treffer.map { $0.map(\.name) } ?? ["Fehler"])"); return nil }
        let alle = await model.folgen(serie: serie.id, staffel: nil) ?? []
        var mitAbschnitten = 0
        for (a, b) in zip(alle, alle.dropFirst())
        where a.parentIndexNumber == b.parentIndexNumber && (a.parentIndexNumber ?? 0) > 0 {
            let teile = await model.abschnitte(fuer: a.id)
            if !teile.isEmpty { mitAbschnitten += 1 }
            guard let intro = teile.first(where: { $0.art == .vorspann || $0.art == .rueckblick }),
                  let ende = teile.first(where: { $0.art == .abspann }) else { continue }
            erste = a; zweite = b; vorspann = intro; abspann = ende
            break
        }
        guard let erste, let zweite, let vorspann, let abspann
        else { log("kein Folgenpaar mit Vorspann und Abspann — \(alle.count) Folgen, \(mitAbschnitten) mit Abschnitten"); return nil }
        for f in [erste, zweite] {
            roh[f.id] = try? await client.nutzerdatenRoh(itemID: f.id)
            log("Stand vorher \(f.id) \(String(decoding: roh[f.id] ?? Data(), as: UTF8.self))")
        }
        log("Paar \(erste.id) S\(erste.parentIndexNumber ?? 0)F\(erste.indexNumber ?? 0) → \(zweite.id) · Vorspann \(vorspann.von)–\(vorspann.bis) · Abspann \(abspann.von)–\(abspann.bis)")

        // Laden — Original, dieselbe Quelle, die der Player nähme.
        let neu = [erste, zweite].filter { model.downloads.posten(fuer: $0.id) == nil }
        selbstGeladen = neu.map(\.id)
        model.downloads.anstossen(neu.map { f in
            let q = f.mediaSources?.first
            return Downloadposten(
                id: f.id, konto: konto, art: .folge, titel: f.name,
                serie: serie.name, serienId: serie.id,
                staffel: f.parentIndexNumber, folge: f.indexNumber,
                laufzeitTicks: f.runTimeTicks, container: q?.container,
                quelle: q?.id, bytes: q?.size ?? 0,
                sehstand: f.userData, bildcodec: q?.bildcodec)
        })
        log("lade \(neu.count) (\(neu.map { Downloadregeln.groesse($0.mediaSources?.first?.size ?? 0) }))")
        for runde in 0..<360 {
            let fertig = [erste, zweite].allSatisfy { model.downloads.datei(fuer: $0.id) != nil }
            if fertig { break }
            if runde % 6 == 0 {
                let stand = [erste, zweite].map { model.downloads.posten(fuer: $0.id).map { "\($0.stand.rawValue) \($0.geladen)/\($0.bytes)" } ?? "—" }
                log("warte auf Downloads: \(stand)")
            }
            try? await Task.sleep(for: .seconds(5))
        }
        guard [erste, zweite].allSatisfy({ model.downloads.datei(fuer: $0.id) != nil })
        else { log("Downloads nicht fertig"); return nil }
        // Abschnitte speichern laufen nach dem Ablegen an — kurz Zeit lassen.
        try? await Task.sleep(for: .seconds(3))
        stand(model, [erste, zweite])

        // **Netz aus.**
        Netzsperre.an = true
        model.downloads.netzSimulieren(weg: true)
        log("Netz aus")

        let t0 = Date()
        let teile = await model.abschnitte(fuer: erste.id)
        log("offline Abschnitte \(erste.id): \(teile.map { "\($0.art.rawValue) \($0.von)–\($0.bis)" }) in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        let t1 = Date()
        let nach = await model.folgeNach(erste)
        log("offline nächste Folge nach \(erste.id): \(nach?.id ?? "keine") in \(String(format: "%.2f", Date().timeIntervalSince(t1))) s")

        guard let plan = await model.plan(for: erste.id) else { log("kein Plan von der Platte"); return nil }
        return Abspielwunsch(item: erste, plan: plan, startAt: vorspann.von + 2)
    }

    static func ablauf(_ model: AppModel, schliessen: () -> Void) async {
        guard let erste, let zweite, let abspann else { return }
        for _ in 0..<60 where !Spielstand.laeuft { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(5))
        func befehl(_ b: Fernbefehl, warte: Double) async {
            log("Befehl \(b)")
            model.fernbefehl?(b)
            try? await Task.sleep(for: .seconds(warte))
        }
        // Im Vorspann steht „Intro überspringen" (Sprungtakt-Zeilen).
        await befehl(.springenAuf(abspann.von + 2), warte: 6)
        // Im Abspann „Nächste Folge" — und der Befehl wechselt.
        await befehl(.naechste, warte: 10)
        log("läuft jetzt: \(model.laufenderTitelKennung ?? "nichts")")
        await befehl(.springenAuf(600), warte: 6)
        await befehl(.stopp, warte: 4)
        schliessen()
        try? await Task.sleep(for: .seconds(3))

        log("Nachmeldungen offline: \(model.nachmeldungenFuerLauf.map { "\($0.itemID) \($0.ticks / 10_000_000) s" })")
        stand(model, [erste, zweite])

        // **Netz wieder an** — über denselben Weg wie in der App: die
        // Verbindungsprüfung meldet nach.
        Netzsperre.an = false
        model.downloads.netzSimulieren(weg: false)
        log("Netz an")
        // Zweimal gleichzeitig: es darf nichts doppelt ankommen.
        async let a = model.verbindungPruefen()
        async let b = model.verbindungPruefen()
        log("Prüfung: \(await a) / \(await b)")
        log("Nachmeldungen danach: \(model.nachmeldungenFuerLauf.count)")
        guard let client = model.client else { return }
        await serverstand(client, [erste, zweite])

        // **Der neuere Stand gewinnt:** eine Stelle von vor einer Stunde darf
        // die eben angekommene nicht überschreiben.
        model.nachmeldungUnterschieben(zweite.id, ticks: 120 * 10_000_000,
                                       wann: Date().addingTimeInterval(-3600))
        await model.nachmeldungenAbschicken()
        log("ältere Meldung: danach liegen \(model.nachmeldungenFuerLauf.count)")
        await serverstand(client, [zweite])

        // Nach dem Wiederverbinden zieht die Liste den Serverstand nach.
        await model.downloadsNachziehen()
        stand(model, [erste, zweite])

        await aufraeumen(model)
    }

    private static func stand(_ model: AppModel, _ folgen: [Item]) {
        for f in folgen {
            guard let p = model.downloads.posten(fuer: f.id) else { continue }
            log("Download \(f.id): gesehen \(p.gesehen) · Stelle \(p.stelleTicks.map { "\($0 / 10_000_000) s" } ?? "—") · Abschnitte \(p.abschnitte.map { "\($0.count)" } ?? "nie gefragt")")
        }
    }

    private static func serverstand(_ client: JellyfinClient, _ folgen: [Item]) async {
        for f in folgen {
            let nachher = (try? await client.nutzerdatenRoh(itemID: f.id)) ?? Data()
            log("Stand am Server \(f.id) \(String(decoding: nachher, as: UTF8.self))")
        }
    }

    static func aufraeumen(_ model: AppModel) async {
        Netzsperre.an = false
        model.downloads.netzSimulieren(weg: false)
        guard let client = model.client else { return }
        for (id, daten) in roh {
            do {
                try await client.nutzerdatenZuruecklegen(itemID: id, roh: daten)
                let nachher = try await client.nutzerdatenRoh(itemID: id)
                log("zurückgelegt \(id) \(String(decoding: nachher, as: UTF8.self))")
            } catch {
                log("Zurücklegen fehlgeschlagen \(id): \(error)")
            }
        }
        model.downloads.entfernen(selbstGeladen)
        log("fertig, entfernt \(selbstGeladen.count)")
        if let vorherKonto {
            model.kontoWechseln(zu: vorherKonto)
            log("zurück auf das vorige Konto")
        }
    }
}
#endif
