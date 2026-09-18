#if DEBUG
import Foundation
import JellyfinKit

/// **Messlauf für Sprünge** (Bug 17.09.2026: Zeit und Angebotsknopf kommen
/// nach einem Doppeltipp erst Sekunden später) — ohne Finger, nur über das
/// Protokoll.
///
///     xcrun simctl launch <geraet> de.paulherter.swiftly -sprunglauf
///
/// Nimmt eine Folge von „The Mentalist" mit Vorspann-Abschnitt, merkt sich
/// ihren Wiedergabestand, spult vor, zweimal schnell vor, zurück, springt in
/// den Rückblick und hinaus, angehalten in den Abspann und hinaus, schliesst und legt den Stand zurück. Der
/// Player schreibt dabei jeden Takt eine `[Sprungtakt]`-Zeile mit Anzeige,
/// VLC-Zeit und Angebot; die Zeitstempel des Protokolls tragen Millisekunden.
@MainActor
enum Sprunglauf {
    static var an: Bool { ProcessInfo.processInfo.arguments.contains("-sprunglauf") }

    private static var folge: Item?
    private static var roh: Data?
    private static var vorspann: JellyfinKit.Abschnitt?
    private static var abspann: JellyfinKit.Abschnitt?

    static func wunsch(_ model: AppModel) async -> Abspielwunsch? {
        guard let client = model.client else { Protokoll.schreib("[Sprunglauf] nicht angemeldet"); return nil }
        guard let serie = await model.suche("The Mentalist").first(where: { $0.type == "Series" })
        else { Protokoll.schreib("[Sprunglauf] keine Serie"); return nil }
        for kandidat in await model.folgen(serie: serie.id, staffel: nil).prefix(60) {
            let abschnitte = await model.abschnitte(fuer: kandidat.id)
            guard let intro = abschnitte.first(where: { $0.art == .vorspann || $0.art == .rueckblick }),
                  let ende = abschnitte.first(where: { $0.art == .abspann }),
                  let plan = await model.plan(for: kandidat.id) else { continue }
            let daten = try? await client.nutzerdatenRoh(itemID: kandidat.id)
            folge = kandidat; roh = daten; vorspann = intro; abspann = ende
            Protokoll.schreib("[Sprunglauf] Folge \(kandidat.id) \(kandidat.name) · Vorspann \(intro.von)–\(intro.bis) · Stand vorher \(String(decoding: daten ?? Data(), as: UTF8.self))")
            return Abspielwunsch(item: kandidat, plan: plan, startAt: intro.bis + 240)
        }
        Protokoll.schreib("[Sprunglauf] keine Folge mit Vorspann")
        return nil
    }

    static func ablauf(_ model: AppModel, schliessen: () -> Void) async {
        guard let folge, let vorspann, let abspann else { return }
        for _ in 0..<60 where !Spielstand.spielerLaeuft { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(4))
        func befehl(_ b: Fernbefehl, warte: Double) async {
            Protokoll.schreib("[Sprunglauf] Befehl \(b)")
            model.fernbefehl?(b)
            try? await Task.sleep(for: .seconds(warte))
        }
        await befehl(.vor, warte: 7)
        await befehl(.vor, warte: 0.25)
        await befehl(.vor, warte: 7)
        await befehl(.zurueck, warte: 7)
        await befehl(.springenAuf(vorspann.von + 3), warte: 7)
        await befehl(.springenAuf(vorspann.bis + 30), warte: 7)
        // Wie „Überspringen", gleich danach „30 s vor" (Paul 17.09.: sprang zurück).
        await befehl(.springenAuf(vorspann.bis), warte: 0.3)
        await befehl(.vor, warte: 6)
        // Angehalten, damit der Countdown der Karte nicht in die naechste
        // Folge wechselt und deren Stand veraendert.
        await befehl(.pause, warte: 2)
        await befehl(.springenAuf(abspann.von + 3), warte: 7)
        await befehl(.springenAuf(abspann.von - 60), warte: 7)
        await befehl(.stopp, warte: 4)
        schliessen()
        try? await Task.sleep(for: .seconds(2))
        guard let client = model.client, let roh else { return }
        do {
            try await client.nutzerdatenZuruecklegen(itemID: folge.id, roh: roh)
            let nachher = try await client.nutzerdatenRoh(itemID: folge.id)
            Protokoll.schreib("[Sprunglauf] Stand nachher \(String(decoding: nachher, as: UTF8.self))")
        } catch {
            Protokoll.schreib("[Sprunglauf] Zuruecklegen fehlgeschlagen: \(error)")
        }
    }
}
#endif
