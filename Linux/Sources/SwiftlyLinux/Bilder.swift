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
    /// **Die gepackten Bilder hatten keine Grenze** — anders als die
    /// Texturen darunter (``Bildspeicher``, 256 MiB). Jedes Plakat, das je
    /// vorbeigescrollt war, blieb als JPEG im Speicher: bei einer grossen
    /// Bibliothek einmal ganz durch „Filme" gescrollt sind das tausende
    /// Bilder zu 50–300 KB, und der Speicher wuchs, bis die App ging.
    /// Dieselbe Regel wie dort: die aeltesten gehen zuerst.
    private var abgelegt: [String] = []
    private var belegt = 0
    private static let grenze = 96 * 1024 * 1024
    private var laufend: [String: Task<Data?, Never>] = [:]

    /// **Und auf der Platte** (Audit 27.09., wie `Bildablage` auf Apple).
    /// Ohne sie lud jeder Kaltstart jedes Plakat neu vom Server. Die Regel —
    /// nur Adressen mit `tag`, älteste zuerst weg — steht im Paket
    /// (``Bildplatte``); 512 MB wie auf dem Mac. Aufgeräumt wird einmal je
    /// Start, beim ersten Schreiben.
    private static let platte = Bildplatte(
        ordner: Plattform.zwischenspeicherordner.appendingPathComponent("bilder", isDirectory: true),
        grenze: 512 * 1024 * 1024)
    private static let aufgeraeumt: Void = { _ = platte.aufraeumen() }()

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

        let dateiname = Bildplatte.name(url)
        let aufgabe = Task<Data?, Never> { [self] in
            // Die Platte braucht keinen Platz in der Schleuse — sie teilt
            // sich keine Leitung mit den anderen.
            if let dateiname,
               let da = await Task.detached(priority: .userInitiated, operation: {
                   Self.platte.lesen(dateiname)
               }).value {
                return da
            }
            await einlass()
            defer { Task { await einlassZurueck() } }
            do {
                let (daten, antwort) = try await URLSession.shared.data(for: .mitEigenenKoepfen(url))
                guard let http = antwort as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { return nil }
                if let dateiname {
                    Task.detached(priority: .utility) {
                        Self.platte.schreiben(daten, dateiname)
                        _ = Self.aufgeraeumt
                    }
                }
                return daten
            } catch { return nil }
        }
        laufend[schluessel] = aufgabe
        let ergebnis = await aufgabe.value
        laufend[schluessel] = nil
        if let ergebnis, gespeichert[schluessel] == nil {
            gespeichert[schluessel] = ergebnis
            abgelegt.append(schluessel)
            belegt += ergebnis.count
            while belegt > Self.grenze, abgelegt.count > 1 {
                belegt -= gespeichert.removeValue(forKey: abgelegt.removeFirst())?.count ?? 0
            }
        }
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

    static var anzahl: Int { texturen.count }

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
///
/// - Parameter kante: Die laengste Kante in Bildpunkten, die das Feld
///   braucht. Groessere Bilder werden **beim Entpacken** darauf verkleinert
///   (``verkleinertEntpacken(_:kante:)``). Die Adressen fragen den Server
///   schon nach dieser Groesse; das hier faengt die Faelle ab, in denen er
///   trotzdem das Original schickt — dann belegte ein Plakat 150 × 225 eine
///   Textur von 2000 × 3000, zwoelf statt einem halben Megabyte.
@discardableResult
func bildSetzen(_ bildfeld: Widget!, daten: Data, schluessel: String, kante: Int? = nil) -> Bool {
    if let textur = Bildspeicher.holen(schluessel) {
        gtk_picture_set_paintable(OpaquePointer(bildfeld), textur)
        bildEinblenden(bildfeld)
        return true
    }
    return bildAuflegen(bildfeld, texturEntpacken(daten, kante: kante), daten: daten,
                        schluessel: schluessel)
}

/// **Eine entpackte Textur über Fadengrenzen.** `GdkTexture` ist
/// unveränderlich und darf den Faden wechseln; die Kiste trägt nur den
/// Zeiger (eine Referenz, die ``bildAuflegen`` übernimmt).
struct Texturkiste: @unchecked Sendable {
    let textur: OpaquePointer?
}

/// Packt Bildbytes zu einer Textur aus — **auf jedem Faden**.
///
/// `gdk_texture_new_from_bytes` ist ausdrücklich fadensicher (GTK ≥ 4.6,
/// „to avoid blocking the main thread while loading a big image"), und ein
/// eigener `GdkPixbufLoader` je Aufruf ebenso. Hier liegt es, damit die
/// Folgenliste einer Serie mit vielen Folgen ihre Bilder nicht mehr auf dem
/// Hauptfaden entpackt — dort kostete jedes JPEG ein paar Millisekunden, und
/// zwanzig davon hintereinander waren das Ruckeln beim Öffnen.
func texturEntpacken(_ daten: Data, kante: Int?) -> Texturkiste {
    daten.withUnsafeBytes { puffer -> Texturkiste in
        guard let basis = puffer.baseAddress,
              let bytes = g_bytes_new(basis, gsize(puffer.count)) else { return Texturkiste(textur: nil) }
        defer { g_bytes_unref(bytes) }
        var fehler: UnsafeMutablePointer<GError>?
        let gelesen = kante.flatMap { verkleinertEntpacken(puffer, kante: $0) }
            ?? gdk_texture_new_from_bytes(bytes, &fehler)
        if gelesen == nil, let fehler {
            let text = fehler.pointee.message.map { String(cString: $0) } ?? "unbekannt"
            FileHandle.standardError.write(Data("Bild ließ sich nicht lesen: \(text)\n".utf8))
            g_error_free(fehler)
        } else if let fehler {
            g_error_free(fehler)
        }
        return Texturkiste(textur: gelesen)
    }
}

/// Legt eine entpackte Textur auf — nur auf dem Hauptfaden. Liegt dieselbe
/// schon im Speicher (ein zweites Feld war schneller), gilt die gemerkte.
@discardableResult
func bildAuflegen(_ bildfeld: Widget!, _ kiste: Texturkiste, daten: Data,
                  schluessel: String) -> Bool {
    #if DEBUG
    Pruefzaehler.bild(daten, gelesen: kiste.textur != nil)
    #endif
    if let schon = Bildspeicher.holen(schluessel) {
        if let neu = kiste.textur { g_object_unref(UnsafeMutableRawPointer(neu)) }
        gtk_picture_set_paintable(OpaquePointer(bildfeld), schon)
        bildEinblenden(bildfeld)
        return true
    }
    guard let textur = kiste.textur else { return false }
    gtk_picture_set_paintable(OpaquePointer(bildfeld), textur)
    Bildspeicher.legen(schluessel, textur)
    bildEinblenden(bildfeld)
    return true
}

nonisolated(unsafe) private let groesseGemeldet: @convention(c) (
    UnsafeMutablePointer<GdkPixbufLoader>?, Int32, Int32, gpointer?
) -> Void = { lader, breite, hoehe, daten in
    let grenze = Int32(truncatingIfNeeded: Int(bitPattern: daten))
    let laengste = max(breite, hoehe)
    guard grenze > 0, laengste > grenze else { return }
    let faktor = Double(grenze) / Double(laengste)
    gdk_pixbuf_loader_set_size(lader, max(1, Int32((Double(breite) * faktor).rounded())),
                               max(1, Int32((Double(hoehe) * faktor).rounded())))
}

/// Entpackt ein Bild so, dass seine laengste Kante hoechstens `kante` ist.
///
/// **Beim Entpacken, nicht danach.** `GdkPixbufLoader` fragt nach dem Kopf
/// der Datei, wie gross das Ergebnis werden soll; JPEG wird dann gleich in
/// der kleineren Stufe entschluesselt, statt erst voll und dann gerechnet.
/// Kleinere Bilder bleiben, wie sie sind — es wird nie vergroessert.
/// `nil`, wenn der Lader das Format nicht kennt; dann nimmt der Aufrufer den
/// gewohnten Weg ueber `gdk_texture_new_from_bytes`.
private func verkleinertEntpacken(_ puffer: UnsafeRawBufferPointer, kante: Int) -> OpaquePointer? {
    guard kante > 0, let basis = puffer.baseAddress,
          let lader = gdk_pixbuf_loader_new() else { return nil }
    defer { g_object_unref(UnsafeMutableRawPointer(lader)) }
    g_signal_connect_data(UnsafeMutableRawPointer(lader), "size-prepared",
                          unsafeBitCast(groesseGemeldet, to: GCallback.self),
                          UnsafeMutableRawPointer(bitPattern: kante), nil, GConnectFlags(rawValue: 0))
    var fehler: UnsafeMutablePointer<GError>?
    let geschrieben = gdk_pixbuf_loader_write(lader, basis.assumingMemoryBound(to: guchar.self),
                                              gsize(puffer.count), &fehler) != 0
    if let f = fehler { g_error_free(f); fehler = nil }
    let geschlossen = gdk_pixbuf_loader_close(lader, &fehler) != 0
    if let f = fehler { g_error_free(f) }
    guard geschrieben, geschlossen, let bild = gdk_pixbuf_loader_get_pixbuf(lader),
          let pixel = gdk_pixbuf_read_pixel_bytes(bild) else { return nil }
    defer { g_bytes_unref(pixel) }
    // Nur die beiden Formen, die der Lader fuer Fotos liefert: 8 Bit je
    // Kanal, drei oder vier Kanaele. Alles andere geht den gewohnten Weg.
    guard gdk_pixbuf_get_bits_per_sample(bild) == 8 else { return nil }
    let alpha = gdk_pixbuf_get_has_alpha(bild) != 0
    guard gdk_pixbuf_get_n_channels(bild) == (alpha ? 4 : 3) else { return nil }
    return gdk_memory_texture_new(gdk_pixbuf_get_width(bild), gdk_pixbuf_get_height(bild),
                                  alpha ? GDK_MEMORY_R8G8B8A8 : GDK_MEMORY_R8G8B8,
                                  pixel, gsize(gdk_pixbuf_get_rowstride(bild)))
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
    laufen(auf: bildfeld, dauer: bewegungReduziert() ? Stil.zeitReduziert : 0.22) { e in
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
/// - Parameter kante: siehe ``bildSetzen(_:daten:schluessel:kante:)``.
/// - Parameter ersatzSerie: Kommt kein Bild (Netz, Server, kaputte Datei),
///   legt die Kachel ihr Platzhalterzeichen in den Rahmen — Serie oder Film
///   — statt leer dazustehen (UX-Audit 27.09.). Dasselbe Zeichen, das eine
///   Kachel ohne Bildadresse schon traegt. `nil`: kein Ersatz, etwa wo ein
///   Aufrufer mit `fertig` selbst entscheidet.
func bildLaden(_ bildfeld: Widget!, url: URL, schluessel: String, sofort: Bool = false,
               kante: Int? = nil, ersatzSerie: Bool? = nil,
               fertig: (@Sendable (Bool) -> Void)? = nil) {
    // Eine verkleinerte Textur ist eine andere als die volle — sonst bekaeme
    // ein grosses Feld mit derselben Adresse das kleine Bild aus dem Speicher.
    let texturschluessel = kante.map { "\(schluessel)@\($0)" } ?? schluessel
    // **Schon entpackt heisst: gar keine Arbeit mehr.** Kein Umweg über eine
    // Aufgabe, kein Warten auf die Fahrt — das Bild steht einfach da.
    if let textur = Bildspeicher.holen(texturschluessel) {
        gtk_picture_set_paintable(OpaquePointer(bildfeld), textur)
        fertig?(true)
        return
    }
    g_object_ref(bildfeld)
    let kiste = Zeigerkiste(bildfeld)
    Task.detached {
        let daten = await Bildlager.shared.laden(url, schluessel: schluessel)
        // **Entpackt wird hier, abseits des Hauptfadens** (``texturEntpacken``).
        let entpackt = daten.map { texturEntpacken($0, kante: kante) }
        let auflegen: @Sendable () -> Void = {
            let gelegt = daten.map {
                bildAuflegen(kiste.widget, entpackt ?? Texturkiste(textur: nil), daten: $0,
                             schluessel: texturschluessel)
            } ?? false
            // Nur solange das Feld noch in seinem Rahmen haengt — eine Seite,
            // die inzwischen abgebaut ist, bekommt kein Zeichen mehr. Der
            // Rahmen ist der `GtkOverlay` aus ``gerahmtesBild``; wer
            // `ersatzSerie` setzt, sagt damit zu, dass es einer ist.
            if !gelegt, let ersatzSerie, let rahmen = gtk_widget_get_parent(kiste.widget) {
                zeichenLegen(rahmen, serie: ersatzSerie)
            }
            g_object_unref(kiste.widget)
            fertig?(daten != nil)
        }
        // Aufgelegt wird nach der Fahrt: auch das Auflegen kostet ein Bild,
        // und ein Dutzend Folgenbilder mitten im Schub wären sichtbar.
        if sofort { aufHauptfaden(auflegen) } else { nachDemSchub(auflegen) }
    }
}
