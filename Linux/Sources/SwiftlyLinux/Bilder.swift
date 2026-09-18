import CGtk
import Foundation
// Auf Linux liegt URLSession nicht in Foundation, sondern in einem
// eigenen Modul. Auf Apple gibt es das Modul nicht.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JellyfinKit

/// Lädt Poster vom Server und hängt sie in ein Bildfeld.
///
/// **Zwei Dinge machen das mehr als einen Download.** Erstens muss das
/// fertige Bild auf dem Hauptfaden gesetzt werden, sonst zerlegt es GTK.
/// Zweitens lohnt ein Zwischenspeicher: dieselbe Serie taucht in
/// „Weiterschauen" und „Nächste Folge" auf, und ohne Gedächtnis lädt die App
/// dasselbe Poster zweimal.
///
/// Der Zwischenspeicher hat bewusst **keine Größenangabe im Schlüssel**. Das
/// ist ein Befund aus Swiftfin: wer die angeforderte Breite mitschlüsselt,
/// lädt dasselbe Poster für jede Anzeigegröße neu.
actor Bildlager {
    static let shared = Bildlager()

    private var gespeichert: [String: Data] = [:]
    private var laufend: [String: Task<Data?, Never>] = [:]

    func laden(_ url: URL, schluessel: String) async -> Data? {
        if let da = gespeichert[schluessel] { return da }
        if let laeuft = laufend[schluessel] { return await laeuft.value }

        let aufgabe = Task<Data?, Never> {
            do {
                let (daten, antwort) = try await URLSession.shared.data(from: url)
                guard let http = antwort as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { return nil }
                return daten
            } catch { return nil }
        }
        laufend[schluessel] = aufgabe
        let ergebnis = await aufgabe.value
        laufend[schluessel] = nil
        if let ergebnis { gespeichert[schluessel] = ergebnis }
        return ergebnis
    }
}

/// **Fertig entpackte Bilder.**
///
/// ``Bildlager`` merkt sich die Bytes — das spart den Weg zum Server, aber
/// nicht das Entpacken, und genau das kostet: `gdk_texture_new_from_bytes`
/// packt das JPEG auf GTKs Hauptfaden aus. Wer eine Seite verlässt und
/// zurückkommt, hat dieselben zwanzig Bilder noch einmal ausgepackt, obwohl
/// sich nichts geändert hat.
///
/// Hier liegt deshalb die Textur selbst. Ist sie da, wird sie **sofort**
/// aufgelegt — ohne Aufgabe, ohne Warten, ohne ``Schubsperre``. Damit kostet
/// eine zweite Fahrt auf dieselbe Seite gar nichts mehr.
///
/// Eine Textur trägt entpackte Punkte, also wird sie gedeckelt. Zweihundert
/// Plakate sind grob fünfzig Megabyte; das Älteste geht, wenn es eng wird.
///
/// `nonisolated(unsafe)`, wie alles hier: angefasst wird es nur auf GTKs
/// Hauptfaden.
enum Bildspeicher {
    nonisolated(unsafe) private static var texturen: [String: OpaquePointer] = [:]
    nonisolated(unsafe) private static var reihenfolge: [String] = []
    private static let hoechstens = 200

    static func holen(_ schluessel: String) -> OpaquePointer? { texturen[schluessel] }

    /// Nimmt die Textur **mitsamt unserer Referenz** — der Aufrufer gibt sie
    /// nicht mehr frei. Das Bildfeld hält sich seine eigene.
    static func legen(_ schluessel: String, _ textur: OpaquePointer) {
        guard texturen[schluessel] == nil else {
            g_object_unref(UnsafeMutableRawPointer(textur))
            return
        }
        texturen[schluessel] = textur
        reihenfolge.append(schluessel)
        while reihenfolge.count > hoechstens {
            let alt = reihenfolge.removeFirst()
            if let raus = texturen.removeValue(forKey: alt) {
                g_object_unref(UnsafeMutableRawPointer(raus))
            }
        }
    }
}

/// Setzt ein heruntergeladenes Bild in ein `GtkPicture`.
///
/// GTK nimmt rohe Bytes über `GdkTexture` entgegen und erkennt das Format
/// selbst — JPEG, PNG, WebP, was der Server eben liefert.
func bildSetzen(_ bildfeld: Widget!, daten: Data, schluessel: String) {
    if let textur = Bildspeicher.holen(schluessel) {
        gtk_picture_set_paintable(OpaquePointer(bildfeld), textur)
        return
    }
    daten.withUnsafeBytes { puffer in
        guard let basis = puffer.baseAddress else { return }
        guard let bytes = g_bytes_new(basis, gsize(puffer.count)) else { return }
        defer { g_bytes_unref(bytes) }

        var fehler: UnsafeMutablePointer<GError>?
        guard let textur = gdk_texture_new_from_bytes(bytes, &fehler) else {
            if let fehler {
                let text = fehler.pointee.message.map { String(cString: $0) } ?? "unbekannt"
                FileHandle.standardError.write(Data("Bild ließ sich nicht lesen: \(text)\n".utf8))
                g_error_free(fehler)
            }
            return
        }
        gtk_picture_set_paintable(OpaquePointer(bildfeld), textur)
        Bildspeicher.legen(schluessel, textur)
    }
}

/// Lädt ein beliebiges Bild in ein `GtkPicture` — dasselbe wie ``posterLaden``,
/// nur mit fertiger Adresse. Gebraucht für das Benutzerbild in der
/// Seitenleiste, das keinen `Item` hat.
///
/// `sofort` für die wenigen grossen — das Kopfbild, das Plakat oben. Die
/// vielen kleinen (Folgen, Besetzung, Ähnliches) warten, bis die Seite
/// steht; sie sind es, die die Fahrt kosten.
func bildLaden(_ bildfeld: Widget!, url: URL, schluessel: String, sofort: Bool = false) {
    // **Schon entpackt heisst: gar keine Arbeit mehr.** Kein Umweg über eine
    // Aufgabe, kein Warten auf die Fahrt — das Bild steht einfach da.
    if let textur = Bildspeicher.holen(schluessel) {
        gtk_picture_set_paintable(OpaquePointer(bildfeld), textur)
        return
    }
    g_object_ref(bildfeld)
    let kiste = Zeigerkiste(bildfeld)
    Task.detached {
        let daten = await Bildlager.shared.laden(url, schluessel: schluessel)
        let auflegen: @Sendable () -> Void = {
            if let daten { bildSetzen(kiste.widget, daten: daten, schluessel: schluessel) }
            g_object_unref(kiste.widget)
        }
        // `gdk_texture_new_from_bytes` packt auf dem Hauptfaden aus; ein
        // Dutzend Folgenbilder mitten in der Fahrt kosten sichtbar Bilder.
        if sofort { aufHauptfaden(auflegen) } else { nachDemSchub(auflegen) }
    }
}
