import CGtk
import Foundation
import JellyfinKit

/// **Die vorherrschende Farbe eines Bildes.**
///
/// Apple TV legt über sein Coverbild keinen schwarzen, sondern einen
/// **eingefärbten** Auslauf: unten geht das Bild in einen Ton über, der aus
/// ihm selbst stammt. Deshalb wirkt die Seite wie aus einem Guss, während ein
/// schwarzer Verlauf das Bild abschneidet. Der Mac macht es genauso
/// (`Sources/macOS/Bildfarbe.swift`), und die Regel dort ist knapp:
///
/// - Das Bild auf **einen** Punkt verkleinern — das ist der Mittelwert.
/// - Daraus Farbton und Sättigung nehmen, die Sättigung auf **0,45** deckeln
///   und die Helligkeit auf **0,26** setzen. Der Ton soll den Grund
///   einfärben, nicht ersetzen; 26 % liegt nah an `grund` (5 %), bleibt aber
///   erkennbar warm oder kalt.
///
/// **Den einen Punkt holt hier der Server**, nicht wir. Auf dem Mac wird das
/// große Bild dafür noch einmal dekodiert — einige Millisekunden, und sie
/// fielen genau ins Einfahren der Seite. Jellyfin kann jedes Bild auf ein
/// gewünschtes Maß bringen; 16 Punkt breit sind ein paar hundert Byte und
/// brauchen kein eigenes Nebenläufigkeitsproblem.
enum Bildfarbe {

    /// Der eingefärbte Grundton, oder `nil`, wenn nichts zu holen war.
    ///
    /// Der Weg zu den Bildpunkten ist derselbe wie in ``bildSetzen``: rohe
    /// Bytes zu `GBytes`, daraus eine `GdkTexture`, die das Format selbst
    /// erkennt. `gdk_texture_download` gibt sie als BGRA zu acht Bit heraus.
    static func ton(aus daten: Data) -> (r: Int, g: Int, b: Int)? {
        daten.withUnsafeBytes { puffer -> (r: Int, g: Int, b: Int)? in
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

            var summeR = 0.0, summeG = 0.0, summeB = 0.0
            for i in stride(from: 0, to: punkte.count, by: 4) {
                summeB += Double(punkte[i])
                summeG += Double(punkte[i + 1])
                summeR += Double(punkte[i + 2])
            }
            let anzahl = Double(breite * hoehe) * 255
            return farbe(r: summeR / anzahl, g: summeG / anzahl, b: summeB / anzahl)
        }
    }

    /// Mittelwert zu Farbton und Sättigung, dann abgedunkelt und entsättigt.
    private static func farbe(r: Double, g: Double, b: Double) -> (r: Int, g: Int, b: Int) {
        let hoch = max(r, g, b), tief = min(r, g, b), spanne = hoch - tief
        guard spanne > 0, hoch > 0 else { return (11, 11, 13) }   // grund

        var farbton: Double
        if hoch == r { farbton = (g - b) / spanne }
        else if hoch == g { farbton = 2 + (b - r) / spanne }
        else { farbton = 4 + (r - g) / spanne }
        farbton /= 6
        if farbton < 0 { farbton += 1 }

        return ausHSB(farbton: farbton,
                      saettigung: min(spanne / hoch, 0.45),
                      helligkeit: 0.26)
    }

    private static func ausHSB(farbton: Double, saettigung: Double,
                               helligkeit: Double) -> (r: Int, g: Int, b: Int) {
        let i = Int(farbton * 6) % 6
        let f = farbton * 6 - Double(Int(farbton * 6))
        let p = helligkeit * (1 - saettigung)
        let q = helligkeit * (1 - f * saettigung)
        let t = helligkeit * (1 - (1 - f) * saettigung)
        let (r, g, b): (Double, Double, Double) = switch i {
        case 0: (helligkeit, t, p)
        case 1: (q, helligkeit, p)
        case 2: (p, helligkeit, t)
        case 3: (p, q, helligkeit)
        case 4: (t, p, helligkeit)
        default: (helligkeit, p, q)
        }
        return (Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

/// **Ein zweites Stilblatt, nur für den Ton der offenen Seite.**
///
/// Das große Blatt in ``Stil`` steht fest; der Ton wechselt mit jedem Titel.
/// Ein eigener Anbieter mit höherem Rang lässt sich austauschen, ohne alles
/// andere neu zu laden — und weil immer nur eine Detailseite offen ist,
/// genügt einer.
enum Tonblatt {
    nonisolated(unsafe) private static var anbieter: UnsafeMutablePointer<GtkCssProvider>?

    /// **Der Ton färbt den Kopf der Seite, nicht die ganze Seite.**
    ///
    /// Erst stand er allein in den beiden Verläufen — daran lag die harte
    /// Kante unten am Bild: der Verlauf endete im Bildton, die Seite darum
    /// blieb `grund`, und dazwischen stand eine Stufe. Dann färbte er alles
    /// gleichmäßig, und das war zu viel.
    ///
    /// Auf dem Mac läuft er über `heldHoehe + 260` Punkte nach `grund` aus
    /// (`SerienView`, `DetailView`) — oben trägt er, unten ist die Seite
    /// wieder schwarz.
    ///
    /// **Über der Kopfzone bleibt er hier konstant, und das ist der Punkt.**
    /// Der Mac *maskiert* das Bild: die Blenden senken seine Deckung, und die
    /// Seite scheint durch — was die Seite dort auch tut, es passt immer.
    /// GTK kennt keine Maske, hier wird **übermalt**. Damit muss die Farbe an
    /// jeder Stelle die der Seite sein, sonst liegt ein Fleck auf dem Bild.
    ///
    /// Genau das war der „weiße Schleier": die linken 15 % des Bildes trugen
    /// reinen Ton, während die Seite dort schon nach Schwarz auslief — ein
    /// hellerer Fleck, und unten dieselbe Stufe. Am Bildschirmfoto
    /// nachgemessen: 9393 Punkte in genau 66,60,56.
    ///
    /// Bleibt der Ton über die Höhe der Kopfzone gleich und läuft erst
    /// darunter aus, stimmen Übermalen und Untergrund überein. Der
    /// Unterschied zum Mac ist ein etwas flacherer Anfang des Verlaufs.
    ///
    /// Oben braucht es zusätzlich eine kurze Blende. Auf dem Mac reicht das
    /// Bild bis an die Fensterkante, hier sitzt die Titelzeile darüber — ohne
    /// die ersten sieben Prozent stünde dort dieselbe Stufe.
    ///
    /// **`rgba(…)`, nicht achtstelliges Hex.** GTK meldet einen Fehler im
    /// Stilblatt nicht auf der Fehlerleitung, sondern über ein Signal; eine
    /// Schreibweise, die es nicht kennt, fällt lautlos aus. Was sicher geht,
    /// steht hier.
    static func setzen(_ ton: (r: Int, g: Int, b: Int)) {
        if anbieter == nil {
            anbieter = gtk_css_provider_new()
            Stil.meckern(anbieter)
            if let anzeige = gdk_display_get_default(), let anbieter {
                gtk_style_context_add_provider_for_display(anzeige,
                                                           OpaquePointer(anbieter), 900)
            }
        }
        guard let anbieter else { return }
        func t(_ deckung: Double) -> String {
            "rgba(\(ton.r),\(ton.g),\(ton.b),\(deckung))"
        }
        gtk_css_provider_load_from_string(anbieter, """
        .swiftly-detailgrund {
            background-color: \(Stil.grund);
            background-image: linear-gradient(to bottom,
                \(t(1)) 0px, \(t(1)) \(Stil.heldHoehe)px,
                \(Stil.grund) \(Stil.heldHoehe + 260)px);
            background-repeat: no-repeat;
        }
        .swiftly-blende-quer {
            background-image: linear-gradient(to right,
                \(t(1)) 0%, \(t(0.95)) 15%, \(t(0.78)) 29%, \(t(0.50)) 45%,
                \(t(0.25)) 57%, \(t(0.10)) 70%, \(t(0.02)) 85%, \(t(0)) 100%);
        }
        .swiftly-blende-hoch {
            background-image: linear-gradient(to bottom,
                \(t(1)) 0%, \(t(0)) 7%, \(t(0)) 50%, \(t(0.12)) 60%,
                \(t(0.38)) 70%, \(t(0.66)) 80%, \(t(0.86)) 89%,
                \(t(0.96)) 95%, \(t(1)) 100%);
        }
        """)
    }
}
