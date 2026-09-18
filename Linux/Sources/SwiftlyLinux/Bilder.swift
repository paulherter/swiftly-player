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

    // MARK: Die Schleuse

    /// **Wie viele Bilder gleichzeitig geholt werden duerfen.**
    ///
    /// Sie fehlte hier ganz. Auf Apple ist sie am 10.09.2026 an 134 Bildern
    /// gemessen worden (`Sources/Shared/Netzbild.swift:60-107`): zur Spitze
    /// waren **fuenfundzwanzig Abrufe gleichzeitig unterwegs**, sie teilten
    /// sich dieselbe Leitung und kamen deshalb alle **gleich spaet** an — bis
    /// dahin stand die Seite leer.
    ///
    /// Mit einer Schleuse aendert sich die Gesamtzeit kaum; es aendert sich,
    /// **wann das erste Bild dasteht**. Vier und nicht eins: eine einzelne
    /// Verbindung laesst die Leitung zwischen den Anfragen brachliegen. Vier
    /// und nicht zwoelf: dann waere der Unterschied wieder keiner.
    private static let gleichzeitig = 4
    private var imLauf = 0
    private var wartend: [CheckedContinuation<Void, Never>] = []

    /// Reihum und der Reihe nach — wer zuerst gefragt hat, kommt zuerst dran.
    /// Die Kacheln fragen von oben nach unten, also laedt auch von oben nach
    /// unten.
    private func einlass() async {
        if imLauf < Self.gleichzeitig {
            imLauf += 1
            return
        }
        await withCheckedContinuation { (fortsetzung: CheckedContinuation<Void, Never>) in
            wartend.append(fortsetzung)
        }
        // Der Platz wurde beim Freigeben auf uns umgebucht, `imLauf` bleibt.
    }

    private func einlassZurueck() {
        if wartend.isEmpty { imLauf -= 1 }
        else { wartend.removeFirst().resume() }
    }

    func laden(_ url: URL, schluessel: String) async -> Data? {
        if let da = gespeichert[schluessel] { return da }
        if let laeuft = laufend[schluessel] { return await laeuft.value }

        let aufgabe = Task<Data?, Never> { [self] in
            await einlass()
            defer { Task { await einlassZurueck() } }
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
/// **Eine Speichergrenze in Byte, keine Anzahl.**
///
/// Hier stand „hoechstens 200" mit der Rechnung „zweihundert Plakate sind
/// grob fuenfzig Megabyte". Genau diese Fassung ist auf Apple verworfen
/// worden, und der Grund steht dort ausgeschrieben
/// (`Sources/Shared/Netzbild.swift:109-127`): **240 Plakate sind etwas
/// voellig anderes als 240 Querbilder.** Wer in Bildern rechnet, rechnet
/// nicht in dem, was knapp wird — ein Raster aus Querbildern belegte hier das
/// Dreifache dessen, was die Zahl versprach.
///
/// Gemessen wird jetzt, was eine entschluesselte Textur wirklich belegt:
/// Breite mal Hoehe mal vier Byte. Die Grenze ist derselbe Betrag wie auf dem
/// Mac — ein Fenster kann viele Raster gleichzeitig zeigen.
///
/// `nonisolated(unsafe)`, wie alles hier: angefasst wird es nur auf GTKs
/// Hauptfaden.
enum Bildspeicher {
    nonisolated(unsafe) private static var texturen: [String: OpaquePointer] = [:]
    nonisolated(unsafe) private static var groessen: [String: Int] = [:]
    nonisolated(unsafe) private static var reihenfolge: [String] = []
    nonisolated(unsafe) private static var belegt = 0

    /// 256 MB, wie `Netzbild.speichergrenze` unter `#if os(macOS)`.
    private static let grenze = 256 * 1024 * 1024

    static func holen(_ schluessel: String) -> OpaquePointer? { texturen[schluessel] }

    /// Nimmt die Textur **mitsamt unserer Referenz** — der Aufrufer gibt sie
    /// nicht mehr frei. Das Bildfeld hält sich seine eigene.
    static func legen(_ schluessel: String, _ textur: OpaquePointer) {
        guard texturen[schluessel] == nil else {
            g_object_unref(UnsafeMutableRawPointer(textur))
            return
        }
        let breite = Int(gdk_texture_get_width(textur))
        let hoehe = Int(gdk_texture_get_height(textur))
        let bytes = max(breite * hoehe * 4, 1)
        texturen[schluessel] = textur
        groessen[schluessel] = bytes
        reihenfolge.append(schluessel)
        belegt += bytes
        // **Nie den letzten wegwerfen.** Sonst raeumt ein einzelnes Bild, das
        // groesser ist als die Grenze, sich selbst wieder ab, und die Schleife
        // liefe leer — dieselbe Sorte Schleife wie in `Fallen/`.
        while belegt > grenze, reihenfolge.count > 1 {
            let alt = reihenfolge.removeFirst()
            belegt -= groessen.removeValue(forKey: alt) ?? 0
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
/// **Und es blendet ein.** Auf Apple liegt hinter jedem Netzbild ein
/// `withAnimation(.smooth(duration: 0.22))`, sobald die Bytes da sind
/// (`Sources/Shared/Netzbild.swift:367`) — GESTALTUNG E, „Nichts erscheint
/// hart". Hier erschien jedes Plakat, jedes Kopfbild und jede Folgenzeile
/// schlagartig; bei einem Raster mit zwanzig Kacheln blitzt das sichtbar.
func bildSetzen(_ bildfeld: Widget!, daten: Data, schluessel: String) {
    if let textur = Bildspeicher.holen(schluessel) {
        gtk_picture_set_paintable(OpaquePointer(bildfeld), textur)
        bildEinblenden(bildfeld)
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
        bildEinblenden(bildfeld)
    }
}

/// 0 → 1 über 220 ms, dieselbe Dauer wie `.smooth(duration: 0.22)`.
///
/// **Nur, wenn das Feld voll sichtbar ist.** Sonst blendet ein Bild, das
/// gerade von einem anderen Lauf halb eingeblendet wird, von vorn an — und
/// bei einem Kachelbild, das zweimal gesetzt wird (Speichertreffer, dann
/// frische Bytes), säh man es flackern.
private func bildEinblenden(_ bildfeld: Widget!) {
    guard gtk_widget_get_opacity(bildfeld) >= 0.999 else { return }
    // Waehrend eine Seite faehrt, kostet jede Blende ein Bild der Fahrt.
    guard !Schubsperre.faehrt else { return }
    gtk_widget_set_opacity(bildfeld, 0)
    laufen(auf: bildfeld, dauer: 0.22) { e in
        gtk_widget_set_opacity(bildfeld, e)
    } fertig: {
        gtk_widget_set_opacity(bildfeld, 1)
    }
}

/// Lädt ein beliebiges Bild in ein `GtkPicture` — dasselbe wie ``posterLaden``,
/// nur mit fertiger Adresse. Gebraucht für das Benutzerbild in der
/// Seitenleiste, das keinen `Item` hat.
///
/// `sofort` für die wenigen grossen — das Kopfbild, das Plakat oben. Die
/// vielen kleinen (Folgen, Besetzung, Ähnliches) warten, bis die Seite
/// steht; sie sind es, die die Fahrt kosten.
/// - Parameter fertig: Wird auf dem Hauptfaden gerufen, sobald feststeht, ob
///   ein Bild ankam. **Dafür gibt es genau einen Grund:** ein Profilzeichen
///   zeigt den Buchstaben erst, wenn klar ist, dass kein Bild kommt. Ihn
///   vorsorglich darunterzulegen hiesse, dass er bei jedem Konto *mit* Bild
///   kurz aufblitzt — dieselbe Falle, die auf Apple in `Profilzeichen` steht:
///   „Der Buchstabe ist Rückfall, nicht Untergrund."
func bildLaden(_ bildfeld: Widget!, url: URL, schluessel: String, sofort: Bool = false,
               fertig: (@Sendable (Bool) -> Void)? = nil) {
    // **Schon entpackt heisst: gar keine Arbeit mehr.** Kein Umweg über eine
    // Aufgabe, kein Warten auf die Fahrt — das Bild steht einfach da.
    if let textur = Bildspeicher.holen(schluessel) {
        gtk_picture_set_paintable(OpaquePointer(bildfeld), textur)
        fertig?(true)
        return
    }
    g_object_ref(bildfeld)
    let kiste = Zeigerkiste(bildfeld)
    Task.detached {
        let daten = await Bildlager.shared.laden(url, schluessel: schluessel)
        let auflegen: @Sendable () -> Void = {
            if let daten { bildSetzen(kiste.widget, daten: daten, schluessel: schluessel) }
            g_object_unref(kiste.widget)
            fertig?(daten != nil)
        }
        // `gdk_texture_new_from_bytes` packt auf dem Hauptfaden aus; ein
        // Dutzend Folgenbilder mitten in der Fahrt kosten sichtbar Bilder.
        if sofort { aufHauptfaden(auflegen) } else { nachDemSchub(auflegen) }
    }
}
