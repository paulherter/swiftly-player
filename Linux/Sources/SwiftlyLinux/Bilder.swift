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

/// Setzt ein heruntergeladenes Bild in ein `GtkPicture`.
///
/// GTK nimmt rohe Bytes über `GdkTexture` entgegen und erkennt das Format
/// selbst — JPEG, PNG, WebP, was der Server eben liefert.
func bildSetzen(_ bildfeld: Widget!, daten: Data) {
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
        g_object_unref(UnsafeMutableRawPointer(textur))
    }
}

/// Holt das Poster eines Titels und trägt es nach, sobald es da ist.
func posterLaden(_ bildfeld: Widget!, item: Item, adressen: Bildadresse, kante: Int) {
    guard let url = adressen.bauen(itemID: item.id,
                                   art: .poster,
                                   marke: item.imageTags?["Primary"],
                                   mass: .hoechstensBreit(kante)) else { return }
    let schluessel = "\(item.id)-poster"

    // **Das Bildfeld überlebt den Download möglicherweise nicht.** Scrollt
    // jemand weiter, räumt GTK es ab. Deshalb wird es festgehalten, solange
    // geladen wird, und danach wieder losgelassen.
    g_object_ref(bildfeld)
    Task.detached {
        let daten = await Bildlager.shared.laden(url, schluessel: schluessel)
        aufHauptfaden {
            if let daten { bildSetzen(bildfeld, daten: daten) }
            g_object_unref(bildfeld)
        }
    }
}
