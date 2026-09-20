import CoreGraphics
import ImageIO
import JellyfinKit
import SwiftUI

/// **Das Vorschaubild über der Leiste beim Spulen** — aus Jellyfins
/// Trickplay-Blättern ausgeschnitten.
///
/// Welche Kachel zu welcher Stelle gehört, rechnet ``Trickplay`` im Paket.
/// Hier liegen nur das Holen, das Entschlüsseln und der Zwischenspeicher:
/// ein Blatt trägt hundert Bilder, und wer spult, bleibt meist auf einem oder
/// zwei Blättern. Geholt wird ein Blatt deshalb genau einmal.
@MainActor @Observable
final class Trickplaybilder {
    /// `nil`: der Server hat keins, oder es ist noch nicht bekannt. Dann zeigt
    /// die Leiste nur die Zeit.
    private(set) var angabe: Trickplay?
    private var titel: String?
    private var quelle: String?

    /// Entschlüsselte Blätter, nach Nummer. Ein Blatt aus 10×10 Kacheln zu
    /// 320×180 sind rund 9 MB — mehr als eine Handvoll behalten wir nicht.
    @ObservationIgnored private var blaetter: [Int: CGImage] = [:]
    @ObservationIgnored private var reihenfolge: [Int] = []
    @ObservationIgnored private var unterwegs: Set<Int> = []
    private static let hoechstens = 6
    /// Zählt eintreffende Blätter, damit die Ansicht neu zeichnet.
    private(set) var stand = 0

    /// Für einen neuen Titel einmal nachsehen, ob es Trickplay gibt.
    func laden(model: AppModel, item: Item, plan: PlaybackPlan) async {
        guard titel != item.id else { return }
        titel = item.id
        quelle = plan.mediaSourceID
        angabe = nil
        blaetter = [:]
        reihenfolge = []
        unterwegs = []
        let gefunden = await model.trickplay(fuer: item.id, quelle: plan.mediaSourceID)
        // Kam in der Zwischenzeit schon der nächste Titel, gehört das nicht mehr hierher.
        guard titel == item.id else { return }
        angabe = gefunden
        Protokoll.schreib("[Trickplay] \(item.id): "
            + (gefunden.map { "\($0.breite)px, \($0.anzahl) Bilder, alle \($0.intervall) ms" } ?? "keins"))
    }

    /// Das Bild zur Stelle — oder `nil`, solange sein Blatt noch unterwegs ist.
    /// Fehlt es, wird es angefordert.
    func bild(bei sekunden: Double, model: AppModel) -> CGImage? {
        _ = stand
        guard let angabe, let titel, let kachel = angabe.kachel(sekunden: sekunden) else { return nil }
        guard let blatt = blaetter[kachel.blatt] else {
            anfordern(kachel.blatt, angabe: angabe, titel: titel, model: model)
            return nil
        }
        return blatt.cropping(to: CGRect(x: kachel.x, y: kachel.y,
                                         width: kachel.breite, height: kachel.hoehe))
    }

    private func anfordern(_ nummer: Int, angabe: Trickplay, titel: String, model: AppModel) {
        guard !unterwegs.contains(nummer) else { return }
        unterwegs.insert(nummer)
        let quelle = quelle
        Task {
            let daten = await model.trickplayBlatt(titel, quelle: quelle,
                                                   breite: angabe.breite, blatt: nummer)
            let bild = await Task.detached(priority: .userInitiated) {
                Self.entschluesseln(daten)
            }.value?.bild
            guard self.titel == titel else { return }
            unterwegs.remove(nummer)
            guard let bild else { return }
            blaetter[nummer] = bild
            reihenfolge.append(nummer)
            if reihenfolge.count > Self.hoechstens {
                blaetter[reihenfolge.removeFirst()] = nil
            }
            stand += 1
        }
    }

    /// Abseits des Hauptlaufs: ein Blatt ist 3200×1800 Pixel.
    nonisolated private static func entschluesseln(_ daten: Data?) -> Blattkiste? {
        guard let daten, let quelle = CGImageSourceCreateWithData(daten as CFData, nil),
              let bild = CGImageSourceCreateImageAtIndex(
                  quelle, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return Blattkiste(bild: bild)
    }
}

/// `CGImage` ist unveränderlich, nur nicht als `Sendable` erklärt.
private struct Blattkiste: @unchecked Sendable { let bild: CGImage }
