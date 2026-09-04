import CGtk
import Foundation
import JellyfinKit

/// **Swiftlys Aussehen, in GTKs Sprache übersetzt.**
///
/// Die Zahlen und Farben hier sind keine neuen Entscheidungen — sie stehen so
/// in `Sources/Shared/Farben.swift` und `Stil.swift` und gelten auf iPhone,
/// iPad, Apple TV und Mac. Wer eine ändert, ändert sie dort und trägt sie
/// hierher nach; eine zweite Palette wäre der sichere Weg, dass die
/// Plattformen auseinanderlaufen.
///
/// **Warum reines GTK4 und nicht libadwaita.** libadwaita ist GNOMEs
/// Gestaltungsbibliothek: sie sorgt dafür, dass eine App wie eine GNOME-App
/// aussieht. Das arbeitet gegen das Ziel — Swiftly soll auf jedem System wie
/// Swiftly aussehen, nicht wie das System. Dazu kommt, dass libadwaita auf
/// Windows kaum unterstützt wird, und Windows steht auf dem Plan. Alles, was
/// unten steht, ist deshalb einfaches GTK4 mit eigenem Stilblatt.
enum Stil {

    // MARK: Farben, wörtlich aus Farben.swift

    static let grund = "#0B0B0D"
    static let erhoeht = "#1E1E22"
    static let akzent = "#5CD1C2"
    static let markeAkzent = Markenpfade.akzentHex     // #2FDBC0
    static let schrift = "#FFFFFF"
    static let schriftLeise = "rgba(255,255,255,0.62)"
    static let schriftSehrLeise = "rgba(255,255,255,0.38)"

    // MARK: Maße, wörtlich aus Stil.swift

    /// Allgemeine Ecke — Felder, Knöpfe, Blätter.
    static let ecke = 6
    /// Ecke einer Kachel. Etwas runder, weil ein Plakat sonst hart wirkt.
    static let eckeKachel = 8
    /// Breite einer Kachel im schmalen Layout; breit sind es 132.
    static let kachelBreite = 112
    static let kachelBreiteBreit = 132

    /// Plakate sind 2:3. Die Höhe folgt daraus, statt geraten zu werden.
    static func kachelHoehe(_ breite: Int) -> Int { breite * 3 / 2 }

    // MARK: Stilblatt

    /// Wird einmal beim Start geladen und gilt für das ganze Programm.
    ///
    /// GTKs Stilblätter kennen dieselben Begriffe wie im Netz — Farbe,
    /// Rundung, Abstand —, nur die Auswahl geschieht über Widget-Namen statt
    /// über Marken. `.swiftly-*` sind unsere eigenen Klassen; alles ohne
    /// Punkt ist ein GTK-Typ.
    static var blatt: String {
        """
        window, .background, scrolledwindow, viewport {
            background-color: \(grund);
            color: \(schrift);
        }

        label { color: \(schrift); }
        .dim-label { color: \(schriftLeise); }
        .swiftly-leise { color: \(schriftSehrLeise); }

        .title-1 { font-size: 30px; font-weight: 700; }
        .title-2 { font-size: 19px; font-weight: 600; }
        .title-4 { font-size: 15px; font-weight: 600; }
        .caption { font-size: 11px; }
        .caption-heading { font-size: 12px; font-weight: 600; }

        entry {
            background-color: \(erhoeht);
            color: \(schrift);
            border: 1px solid rgba(255,255,255,0.10);
            border-radius: \(ecke)px;
            padding: 9px 12px;
            caret-color: \(akzent);
        }
        entry:focus {
            border-color: \(akzent);
            outline: none;
            box-shadow: none;
        }
        entry placeholder { color: \(schriftSehrLeise); }
        entry image { color: \(schriftLeise); margin-right: 8px; }

        button {
            background-image: none;
            background-color: \(erhoeht);
            color: \(schrift);
            border: 1px solid rgba(255,255,255,0.10);
            border-radius: \(ecke)px;
            padding: 10px 20px;
            font-weight: 600;
        }
        button:hover { background-color: rgba(255,255,255,0.12); }
        button:disabled { color: \(schriftSehrLeise); }

        button.swiftly-haupt {
            background-color: \(akzent);
            color: \(grund);
            border: none;
        }
        button.swiftly-haupt:hover { background-color: shade(\(akzent), 1.08); }
        button.swiftly-haupt:disabled {
            background-color: rgba(92,209,194,0.35);
            color: rgba(11,11,13,0.55);
        }

        button.flat {
            background-color: transparent;
            border: none;
            color: \(schriftLeise);
            font-weight: 500;
        }
        button.flat:hover { background-color: rgba(255,255,255,0.08); color: \(schrift); }

        /* Auf dem Mac schwebt die Titelzeile über dem Grund, ohne Kante.
           Dieselbe Wirkung: gleiche Farbe, keine Linie, kein Schatten. */
        headerbar {
            background-color: \(grund);
            background-image: none;
            border: none;
            box-shadow: none;
            min-height: 44px;
        }

        /* Plakate: eigener Grund, solange das Bild noch nicht da ist. */
        .swiftly-plakat {
            background-color: \(erhoeht);
            border-radius: \(eckeKachel)px;
        }

        scrollbar { background-color: transparent; }
        scrollbar slider {
            background-color: rgba(255,255,255,0.22);
            border-radius: 8px;
            min-width: 6px;
            min-height: 6px;
        }
        scrollbar slider:hover { background-color: rgba(255,255,255,0.36); }
        """
    }

    /// Lädt das Stilblatt in die Anzeige.
    static func anwenden() {
        let anbieter = gtk_css_provider_new()
        gtk_css_provider_load_from_string(anbieter, blatt)
        if let anzeige = gdk_display_get_default() {
            // `GtkStyleProvider` ist eine Schnittstelle, kein Typ, den Swift
            // benennen kann — wie `GtkEditable`. Der Anbieter geht deshalb
            // als undurchsichtiger Zeiger hinein.
            gtk_style_context_add_provider_for_display(
                anzeige, OpaquePointer(anbieter),
                800)   // GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
        }
        g_object_unref(UnsafeMutableRawPointer(anbieter))
    }

    // MARK: Wortmarke

    /// Legt die Wortmarke einmal als SVG-Datei ab und gibt den Pfad zurück.
    ///
    /// Der Pfad selbst kommt aus `Markenpfade` im geteilten Paket — dieselbe
    /// Zeichenkette, aus der die Apple-Fassungen ihre Vektorform bauen. GTK
    /// liest SVG über librsvg; fehlt das, gibt es einen Textrückfall.
    static func wortmarkeDatei(hoehe: Int) -> String? {
        let r = Markenpfade.wortmarkeRahmen
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" \
        viewBox="\(r.x) \(r.y) \(r.breite) \(r.hoehe)" \
        width="\(Int(Double(hoehe) * r.breite / r.hoehe))" height="\(hoehe)">
        <path d="\(Markenpfade.wortmarke)" fill="\(schrift)"/>
        <path d="\(Markenpfade.wortmarkeAkzent)" fill="\(markeAkzent)"/>
        </svg>
        """
        let ziel = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftly-wortmarke-\(hoehe).svg")
        do {
            try svg.write(to: ziel, atomically: true, encoding: .utf8)
            return ziel.path
        } catch {
            return nil
        }
    }

    /// Die Wortmarke als Widget, in der gewünschten Höhe.
    ///
    /// **Zwei Fallen liegen hier hintereinander.**
    ///
    /// `GtkImage` nimmt seine Größenangabe nur für Symbole; eine geladene
    /// Datei zeigt es in deren eigener Größe und ignoriert den Wunsch. Also
    /// `GtkPicture`.
    ///
    /// Aber `gtk_widget_set_size_request` setzt nur eine **Mindest**größe.
    /// Ein `GtkPicture` wächst darüber hinaus, sobald Platz da ist — deshalb
    /// stand die Marke danach zweieinhalbmal zu groß im Fenster. Es braucht
    /// zusätzlich `hexpand`/`vexpand` auf null und eine Ausrichtung, sonst
    /// nimmt sie sich, was der Stapel ihr anbietet.
    ///
    /// Die Breite folgt dem Seitenverhältnis des Rahmens (3005 zu 1024, also
    /// knapp 2,94 zu 1) statt geraten zu werden.
    static func wortmarke(hoehe: Int = 64) -> Widget! {
        let r = Markenpfade.wortmarkeRahmen
        let breite = Int(Double(hoehe) * r.breite / r.hoehe)
        // Doppelt so fein anlegen, damit es auf feinen Bildschirmen scharf bleibt.
        guard let datei = wortmarkeDatei(hoehe: hoehe * 2) else {
            return beschriftung("swiftly", stil: "title-1")
        }
        let bild: Widget! = gtk_picture_new_for_filename(datei)
        gtk_picture_set_content_fit(OpaquePointer(bild), GTK_CONTENT_FIT_CONTAIN)
        gtk_picture_set_can_shrink(OpaquePointer(bild), 1)
        gtk_widget_set_size_request(bild, Int32(breite), Int32(hoehe))
        gtk_widget_set_hexpand(bild, 0)
        gtk_widget_set_vexpand(bild, 0)
        gtk_widget_set_halign(bild, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(bild, GTK_ALIGN_CENTER)
        return bild
    }
}
