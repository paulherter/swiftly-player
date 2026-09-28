#if DEBUG
import Foundation
import JellyfinKit

/// **Messlauf für den Folgenwechsel** — wie lange vom Befehl „nächste Folge"
/// bis zum ersten Bild, mit und ohne Vorbereitung (`Folgenvorbereitung`).
///
///     xcrun simctl launch <geraet> de.paulherter.swiftly -wechsellauf [-ohnevorpuffer]
///
/// Braucht eine angemeldete App. Nimmt „The Mentalist" Staffel 6 Folge 10,
/// merkt sich den Stand von Folge 10 und 11, startet 170 s vor Schluss (dort
/// bereitet der Player die nächste Folge vor), schaltet nach 25 s weiter,
/// schliesst und legt beide Stände zurück. Die Zeit steht im Protokoll:
/// `[Wechsel] Beginn` bis `[Wechsel] erstes Bild nach … ms`.
@MainActor
enum Wechsellauf {
    static var an: Bool { ProcessInfo.processInfo.arguments.contains("-wechsellauf") }
    static var ohneVorpuffer: Bool { ProcessInfo.processInfo.arguments.contains("-ohnevorpuffer") }
    private static var sicherung: [(String, Data)] = []

    static func wunsch(_ model: AppModel) async -> Abspielwunsch? {
        guard let client = model.client else { log("nicht angemeldet"); return nil }
        guard let serie = await model.suche("The Mentalist")?.first(where: { $0.type == "Series" })
        else { log("keine Serie"); return nil }
        let alle = await model.folgen(serie: serie.id, staffel: nil) ?? []
        guard let f10 = alle.first(where: { $0.parentIndexNumber == 6 && $0.indexNumber == 10 }),
              let f11 = alle.first(where: { $0.parentIndexNumber == 6 && $0.indexNumber == 11 }),
              let plan = await model.plan(for: f10.id) else { log("Folgen fehlen"); return nil }
        sicherung = []
        for f in [f10, f11] {
            guard let roh = try? await client.nutzerdatenRoh(itemID: f.id) else { continue }
            sicherung.append((f.id, roh))
            log("Stand vorher F\(f.indexNumber ?? 0): \(String(decoding: roh, as: UTF8.self))")
        }
        let dauer = Double(f10.runTimeTicks ?? 0) / 10_000_000
        log("Start F10 bei \(Int(dauer - 170)) s von \(Int(dauer)) s · Vorbereitung \(ohneVorpuffer ? "aus" : "an")")
        return Abspielwunsch(item: f10, plan: plan, startAt: max(dauer - 170, 0))
    }

    static func ablauf(_ model: AppModel, schliessen: () -> Void) async {
        for _ in 0..<60 where !Spielstand.spielerLaeuft { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(25))
        log("Befehl naechste")
        model.fernbefehl?(.naechste)
        try? await Task.sleep(for: .seconds(15))
        model.fernbefehl?(.stopp)
        try? await Task.sleep(for: .seconds(3))
        schliessen()
        try? await Task.sleep(for: .seconds(3))
        guard let client = model.client else { return }
        for (id, roh) in sicherung {
            do {
                try await client.nutzerdatenZuruecklegen(itemID: id, roh: roh)
                let nachher = try await client.nutzerdatenRoh(itemID: id)
                log("Stand nachher: \(String(decoding: nachher, as: UTF8.self))")
            } catch {
                log("Zuruecklegen fehlgeschlagen: \(error)")
            }
        }
        log("Ende")
    }

    private static func log(_ text: String) { Protokoll.schreib("[Wechsellauf] " + text) }
}
#endif
