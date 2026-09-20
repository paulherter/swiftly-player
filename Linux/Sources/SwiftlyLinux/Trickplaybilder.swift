import CGtk
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JellyfinKit

/// **Das Vorschaubild über der Leiste beim Spulen** — aus Jellyfins
/// Trickplay-Blättern ausgeschnitten.
///
/// Wörtlich das Gegenstück zu `Sources/Shared/Trickplaybilder.swift`: welche
/// Kachel zu welcher Stelle gehört, rechnet ``Trickplay`` im Paket, hier
/// liegen nur das Holen und der Zwischenspeicher. Anders als dort ist der
/// Zwischenspeicher kein `CGImage` (das gibt es unter Linux nicht), sondern
/// ein `GdkPixbuf` je Blatt — `gdk_pixbuf_new_subpixbuf` schneidet daraus
/// ohne Kopie der Pixel, `gdk_texture_new_for_pixbuf` macht daraus, was
/// `GtkPicture` zeigen kann.
///
/// **Hat der Server kein Trickplay, bleibt `angabe` `nil`** — die Leiste
/// zeigt beim Spulen dann nur die Zeit, keinen leeren Kasten.
/// `@unchecked Sendable`, wie ``App`` selbst: alles hier läuft am Ende auf
/// GTKs Hauptfaden — die Zusicherung gilt, solange nur ``aufHauptfaden``
/// (oder das schon dort laufende `laden`/`anfordern`) das Innere anfasst.
final class Trickplaybilder: @unchecked Sendable {
    private(set) var angabe: Trickplay?
    private var titel: String?
    private var quelle: String?

    /// Ganze Blätter, nach Nummer. Ein Blatt aus 10×10 Kacheln zu 320×180
    /// sind rund 9 MB — mehr als eine Handvoll behalten wir nicht.
    private var blaetter: [Int: OpaquePointer] = [:]
    private var reihenfolge: [Int] = []
    private var unterwegs: Set<Int> = []
    private static let hoechstens = 6

    deinit { raeumen() }

    /// Für einen neuen Titel einmal nachsehen, ob es Trickplay gibt.
    func laden(client: JellyfinClient, item: Item, plan: PlaybackPlan) {
        guard titel != item.id else { return }
        titel = item.id
        quelle = plan.mediaSourceID
        angabe = nil
        raeumen()
        let t = item.id
        let q = quelle
        // **Stark gefangen, nicht schwach.** Ein schwacher Zeiger laesst sich
        // in einem verschachtelten `@Sendable`-Abschluss (``aufHauptfaden``)
        // nicht noch einmal anfassen — Swift 6 lehnt das ab. Wie ``App``
        // selbst (die auch immer `[self]` schreibt, nie `[weak self]`) lebt
        // dieses Objekt ohnehin nur so lange wie der Player, der es haelt;
        // ein Auftrag, der laenger braucht, schreibt hoechstens in ein
        // verwaistes Exemplar, das dann leer ausläuft.
        Task.detached { [self] in
            let gefunden = await client.trickplay(itemID: t, mediaSourceID: q)
            aufHauptfaden {
                guard self.titel == t else { return }
                self.angabe = gefunden
            }
        }
    }

    private func raeumen() {
        for (_, blatt) in blaetter { g_object_unref(UnsafeMutableRawPointer(blatt)) }
        blaetter = [:]
        reihenfolge = []
        unterwegs = []
    }

    /// Die Textur zur Stelle, aus ihrem Blatt ausgeschnitten — `nil`, solange
    /// das Blatt noch unterwegs ist (dann wird es hier gleich angefordert).
    func kachel(bei sekunden: Double, client: JellyfinClient?) -> OpaquePointer? {
        guard let angabe, let titel, let client,
              let k = angabe.kachel(sekunden: sekunden) else { return nil }
        guard let blatt = blaetter[k.blatt] else {
            anfordern(k.blatt, angabe: angabe, titel: titel, client: client)
            return nil
        }
        guard let ausschnitt = gdk_pixbuf_new_subpixbuf(
            blatt, Int32(k.x), Int32(k.y), Int32(k.breite), Int32(k.hoehe)) else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(ausschnitt)) }
        return gdk_texture_new_for_pixbuf(ausschnitt)
    }

    private func anfordern(_ nummer: Int, angabe: Trickplay, titel: String, client: JellyfinClient) {
        guard !unterwegs.contains(nummer) else { return }
        unterwegs.insert(nummer)
        let quelle = quelle
        Task.detached { [self] in
            let daten = await client.trickplayBlatt(itemID: titel, mediaSourceID: quelle,
                                                     breite: angabe.breite, blatt: nummer)
            aufHauptfaden {
                guard self.titel == titel else { return }
                self.unterwegs.remove(nummer)
                guard let daten, let blatt = Self.pixbuf(aus: daten) else { return }
                self.blaetter[nummer] = blatt
                self.reihenfolge.append(nummer)
                // Nie das letzte wegwerfen — dieselbe Regel wie ``Bildspeicher``.
                if self.reihenfolge.count > Self.hoechstens, self.reihenfolge.count > 1 {
                    if let alt = self.blaetter.removeValue(forKey: self.reihenfolge.removeFirst()) {
                        g_object_unref(UnsafeMutableRawPointer(alt))
                    }
                }
            }
        }
    }

    /// Ein JPEG-Blatt entschlüsseln — abseits des Hauptfadens ist hier nichts
    /// zu holen: `GdkPixbufLoader` packt ohnehin nur auf dem Faden aus, auf
    /// dem er lebt, und der ist hier GTKs Hauptfaden.
    private static func pixbuf(aus daten: Data) -> OpaquePointer? {
        guard let lader = gdk_pixbuf_loader_new() else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(lader)) }
        let geschrieben = daten.withUnsafeBytes { puffer -> Bool in
            guard let basis = puffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            return gdk_pixbuf_loader_write(lader, basis, gsize(puffer.count), nil) != 0
        }
        guard geschrieben, gdk_pixbuf_loader_close(lader, nil) != 0,
              let bild = gdk_pixbuf_loader_get_pixbuf(lader) else { return nil }
        g_object_ref(UnsafeMutableRawPointer(bild))
        return bild
    }
}
