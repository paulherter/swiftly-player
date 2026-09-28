import CGtk
import Foundation
import JellyfinKit

/// **Die Farbtöne eines Bildes — für den Grund der Detailseite.**
///
/// Seit 1.0.5 dieselbe Rechnung wie auf iPhone, Mac und Fernseher
/// (`Sources/Shared/Bildton.swift`, erste Farbwahl „wie Apple TV"): aus dem
/// Bild kommen **nur die Töne**, bis zu fünf, als Gipfel eines Histogramms;
/// Sättigung und Helligkeit setzt die App. Die Rechnung selbst liegt in
/// ``Bildtonrechnung`` im Paket, mit Tests — hier stehen nur der Weg zu den
/// Bildpunkten und die Darstellung in GTK.
///
/// **Hier stand die alte Mac-Fassung:** ein Mittelwert über das ganze Bild,
/// Sättigung auf 0,45 gedeckelt, Helligkeit fest 0,146, als linearer Verlauf
/// bis zur Unterkante des Kopfs. Ein Mittelwert macht aus einem
/// Sonnenuntergang Braungrau, und der Verlauf endete in einer Stufe, sobald
/// die Knöpfe auf ihm standen (Mac e836d519).
enum Bildfarbe {

    /// Die Töne in Grad, leer, wenn das Bild keine hergibt (Graustufen).
    ///
    /// Der Weg zu den Bildpunkten ist derselbe wie in ``bildSetzen``: rohe
    /// Bytes zu `GBytes`, daraus eine `GdkTexture`, die das Format selbst
    /// erkennt. `gdk_texture_download` gibt BGRA heraus; das Paket rechnet in
    /// RGBA. Das Bild holt der Server schon klein (48 Punkt, wie
    /// `kCGImageSourceThumbnailMaxPixelSize: 48` auf Apple).
    static func toene(aus daten: Data) -> [Double]? {
        daten.withUnsafeBytes { puffer -> [Double]? in
            guard let basis = puffer.baseAddress else { return nil }
            guard let bytes = g_bytes_new(basis, gsize(puffer.count)) else { return nil }
            defer { g_bytes_unref(bytes) }

            var fehler: UnsafeMutablePointer<GError>?
            guard let textur = gdk_texture_new_from_bytes(bytes, &fehler) else {
                if let fehler { g_error_free(fehler) }
                return nil
            }
            defer { g_object_unref(UnsafeMutableRawPointer(textur)) }

            let breite = Int(gdk_texture_get_width(textur))
            let hoehe = Int(gdk_texture_get_height(textur))
            guard breite > 0, hoehe > 0 else { return nil }

            let takt = breite * 4
            var punkte = [UInt8](repeating: 0, count: takt * hoehe)
            punkte.withUnsafeMutableBufferPointer { speicher in
                guard let basis = speicher.baseAddress else { return }
                gdk_texture_download(textur, basis, gsize(takt))
            }
            // BGRA → RGBA
            var i = 0
            while i + 3 < punkte.count {
                punkte.swapAt(i, i + 2)
                i += 4
            }
            return Bildtonrechnung.toene(rgba: punkte)
        }
    }
}

/// **Ein zweites Stilblatt, nur für die Farbe der offenen Seiten.**
///
/// Das große Blatt in ``Stil`` steht fest; die Farbe wechselt mit jedem
/// Titel. Ein eigener Anbieter mit höherem Rang lässt sich austauschen, ohne
/// alles andere neu zu laden.
///
/// **Je Seite eine eigene Klasse** (`swiftly-bildton-<n>`). Die alte Fassung
/// schrieb eine Regel für alle Seiten, und eine neue Detailseite stand bis zu
/// ihrem eigenen Ton in dem der vorigen — beim Einschieben sichtbar. Die
/// letzten paar Klassen bleiben stehen, damit die abgehende Seite ihre Farbe
/// behält, solange sie noch hinausfährt.
///
/// **Der Grund ist ein Bild, kein Verlauf.** GTKs Stilblatt kennt nur
/// lineare und radiale Verläufe; die Farbe der Vorlage ist ein Netz
/// (`MeshGradient`), das oben rechts unter der Kulisse am kräftigsten ist und
/// über ``auslauf`` Punkt in OKLab auf `grund` zurückgeht. Das Paket rechnet
/// die Farbe an jedem Punkt eines groben Rasters
/// (``Bildtonrechnung/punkte(_:spalten:zeilen:hoehe:farbhoehe:ab:auslauf:)``);
/// GTK zieht es als Hintergrundbild glatt auf die Seite. Die letzte Zeile ist
/// genau `grund` — darunter steht die Grundfarbe ohne Kante weiter.
///
/// **Dazu das Rauschen des Fernsehers** (`Bildton.rauschen`, eine Stufe
/// Ausschlag), gekachelt über dem Bild: dunkle Verläufe in acht Bit zeigen
/// sonst Bänder.
enum Tonblatt {
    nonisolated(unsafe) private static var anbieter: UnsafeMutablePointer<GtkCssProvider>?
    nonisolated(unsafe) private static var regeln: [(klasse: String, css: String)] = []
    nonisolated(unsafe) private static var zaehler = 0
    nonisolated(unsafe) private static var gemerkt: [String: [Double]] = [:]
    nonisolated(unsafe) private static var reihenfolge: [String] = []

    /// Höhe des Kopfbilds (Linux: ``Stil/heldHoehe``), über der die Farbe
    /// voll steht, wie `Stimmungsgrund(ab: Stil.heldHoehe)` am Mac.
    static var ab: Double { Double(Stil.heldHoehe) }
    /// Über diese Höhe verteilt sich die Farbe wie auf dem Fernseher
    /// (`Stimmungsgrund.farbhoehe`).
    static let farbhoehe: Double = 900
    /// So lang geht die Farbe unter dem Kopf in `grund` zurück
    /// (`Stimmungsgrund.auslauf`).
    static let auslauf: Double = 1300

    /// Für das ``Fernsteuerpult``: welche Klassen Regeln haben, wie lang.
    static var stand: String {
        regeln.map { "\($0.klasse)=\($0.css.count)" }.joined(separator: " ")
    }

    /// Eine neue Klasse für eine neue Seite.
    static func neueKlasse() -> String {
        zaehler += 1
        return "swiftly-bildton-\(zaehler)"
    }

    /// Die Klasse, die eine Seite trägt — gelesen an der Seite selbst, damit
    /// ein spät nachgeladener Kopf nicht die Klasse einer neueren Seite nimmt.
    static func klasse(von seite: Widget!) -> String? {
        guard let seite, let liste = gtk_widget_get_css_classes(seite) else { return nil }
        defer { g_strfreev(liste) }
        var i = 0
        while let eintrag = liste[i] {
            let name = String(cString: eintrag)
            if name.hasPrefix("swiftly-bildton-") { return name }
            i += 1
        }
        return nil
    }

    /// Schon gerechnete Töne eines Titels — ohne Warten, damit eine Seite,
    /// auf die man zurückkehrt, ihre Farbe im ersten Bild hat (iOS
    /// `Bildton.gemerkt(fuer:)`).
    static func merkt(_ id: String) -> [Double]? { gemerkt[id] }

    static func merken(_ id: String, _ toene: [Double]) {
        if gemerkt[id] == nil { reihenfolge.append(id) }
        gemerkt[id] = toene
        if reihenfolge.count > 300 {
            let weg = reihenfolge.prefix(reihenfolge.count - 300)
            for alt in weg { gemerkt[alt] = nil }
            reihenfolge.removeFirst(weg.count)
        }
    }

    /// Die Lage, die den Ton einer Seite trägt (``lageMerken(_:klasse:)``).
    nonisolated(unsafe) private static var lagen: [String: Widget] = [:]

    /// Merkt die Tonlage einer Seite, bis GTK sie abräumt.
    static func lageMerken(_ lage: Widget!, klasse: String) {
        guard let lage else { return }
        lagen[klasse] = lage
        beiSignal(lage, "destroy") { lagen[klasse] = nil }
    }

    /// **Der Ton kommt weich** (`Blendzeiten.kopfbild`, `easeOut`) — nur wenn
    /// er beim Öffnen noch nicht gemerkt war; sonst steht die Lage schon.
    static func einblenden(_ klasse: String) {
        guard let lage = lagen[klasse], gtk_widget_get_opacity(lage) < 0.999 else { return }
        blenden(lage, auf: 1, dauer: Blendzeiten.kopfbild, kennlinie: .easeOut)
    }

    /// Die Farbe einer Seite setzen. Leere Töne heißen: `grund` bleibt.
    static func setzen(_ toene: [Double], klasse: String) {
        if anbieter == nil {
            anbieter = gtk_css_provider_new()
            Stil.meckern(anbieter)
            if let anzeige = gdk_display_get_default(), let anbieter {
                gtk_style_context_add_provider_for_display(anzeige,
                                                           OpaquePointer(anbieter), 900)
            }
        }
        guard let anbieter else { return }
        regeln.removeAll { $0.klasse == klasse }
        if !toene.isEmpty, let css = regel(toene, klasse: klasse) {
            regeln.append((klasse, css))
        }
        if regeln.count > 8 { regeln.removeFirst(regeln.count - 8) }
        gtk_css_provider_load_from_string(anbieter, regeln.map(\.css).joined(separator: "\n"))
    }

    private static func regel(_ toene: [Double], klasse: String) -> String? {
        let hoehe = ab + auslauf
        let spalten = 48, zeilen = 168
        let punkte = Bildtonrechnung.punkte(toene, spalten: spalten, zeilen: zeilen, hoehe: hoehe,
                                            farbhoehe: ab + farbhoehe, ab: ab, auslauf: auslauf)
        guard punkte.count == spalten * zeilen,
              let ton = pngDaten(punkte.map { UInt32(bitPattern: $0) }, breite: spalten, hoehe: zeilen)
        else { return nil }
        // Die Staffelliste liegt deckend über Folgen, aber im Ton der Seite
        // an dieser Stelle, darüber Weiß 8 % (iOS/Mac `SerienView`,
        // `Bildton.farbe(toene, bei: (0,2, 0,55))`).
        let f = Bildtonrechnung.farbe(toene, x: 0.2, y: 0.55)
        func k(_ w: Double) -> Int { Int((min(max(w * 0.92 + 0.08, 0), 1) * 255).rounded()) }
        return """
        .swiftly-seitenton.\(klasse) {
            background-color: \(Stil.grund);
            background-image: url("data:image/png;base64,\(rauschen)"),
                              url("data:image/png;base64,\(ton.base64EncodedString())");
            background-repeat: repeat, no-repeat;
            background-size: 96px 96px, 100% \(Int(hoehe))px;
            background-position: 0 0, 0 0;
        }
        .\(klasse) .swiftly-staffelliste { background-color: rgb(\(k(f.r)),\(k(f.g)),\(k(f.b))); }
        """
    }

    /// Das Rauschen einmal: 96 × 96, jeder Punkt zufällig schwarz oder weiß,
    /// Deckkraft zufällig bis 0,8 % — `Bildton.rauschen` mit
    /// `.opacity(0.008)`, hier in die Punkte selbst gerechnet.
    nonisolated(unsafe) private static let rauschen: String = {
        let kante = 96
        var punkte = [UInt32](repeating: 0, count: kante * kante)
        var zustand: UInt64 = 0x2545F4914F6CDD1D
        for i in 0 ..< punkte.count {
            zustand ^= zustand << 13
            zustand ^= zustand >> 7
            zustand ^= zustand << 17
            let hell = (zustand & 1) == 1
            let deckung = UInt32((Double(UInt8(truncatingIfNeeded: zustand >> 8)) * 0.008).rounded())
            let kanal: UInt32 = hell ? deckung : 0   // vormultipliziert
            punkte[i] = (deckung << 24) | (kanal << 16) | (kanal << 8) | kanal
        }
        return pngDaten(punkte, breite: kante, hoehe: kante, vormultipliziert: true)?
            .base64EncodedString() ?? ""
    }()

    /// ARGB (je ein `UInt32`, `0xAARRGGBB`) zu PNG — über eine
    /// `GdkMemoryTexture`, die GTK selbst speichern kann.
    private static func pngDaten(_ punkte: [UInt32], breite: Int, hoehe: Int,
                                 vormultipliziert: Bool = false) -> Data? {
        // `0xAARRGGBB` liegt im Speicher (little endian) als B, G, R, A.
        let format = vormultipliziert ? GDK_MEMORY_B8G8R8A8_PREMULTIPLIED : GDK_MEMORY_B8G8R8A8
        return punkte.withUnsafeBytes { roh -> Data? in
            guard let basis = roh.baseAddress,
                  let bytes = g_bytes_new(basis, gsize(roh.count)) else { return nil }
            defer { g_bytes_unref(bytes) }
            guard let textur = gdk_memory_texture_new(Int32(breite), Int32(hoehe), format,
                                                      bytes, gsize(breite * 4)) else { return nil }
            defer { g_object_unref(UnsafeMutableRawPointer(textur)) }
            guard let png = gdk_texture_save_to_png_bytes(textur) else { return nil }
            defer { g_bytes_unref(png) }
            var laenge: gsize = 0
            guard let daten = g_bytes_get_data(png, &laenge) else { return nil }
            return Data(bytes: daten, count: Int(laenge))
        }
    }
}
