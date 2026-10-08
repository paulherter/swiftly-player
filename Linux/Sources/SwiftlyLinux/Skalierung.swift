import CGtk
import Foundation
#if os(Windows)
import WinSDK
#endif

/// **Gebrochene Anzeigeskalierung unter Windows — 125 %, 150 %, 175 %.**
///
/// GDKs Win32-Rueckseite kennt nur ganze Faktoren: sie teilt die DPI des
/// Systems ganzzahlig durch 96 (`gdk_win32_display_get_monitor_scale_factor`,
/// GTK 4.22). Bei 150 % (144 DPI) kommt 1 heraus, und weil der Prozess sich
/// zugleich als DPI-bewusst meldet, rechnet Windows auch nichts hoch.
/// Gemessen am 02.10.2026 mit GTK 4.22.4: bei 100 % und bei 150 % dieselbe
/// Zeile — `scale_factor 1`, Fenster 1440 x 900 Geraetepunkte. Die
/// Oberflaeche stand also in zwei Dritteln der Groesse da, die jedes andere
/// Programm hatte. Nur `gtk-xft-dpi` ging mit (144), und das trifft bloss
/// Schrift in Punkt; unsere Masse stehen in `px`.
///
/// Eine GTK-Fassung, die das unter Win32 selbst kann, gibt es nicht (NEWS
/// bis 4.24.1 nachgelesen). Also rechnet die App den Rest selbst: **der
/// Inhalt wird um den fehlenden Faktor kleiner ausgelegt und mit einer
/// Transformation vergroessert gezeichnet** (`gtk_widget_allocate` nimmt
/// eine entgegen). Schrift, Linien und Zeichnungen bleiben dabei Vektoren
/// und damit scharf — anders als wenn Windows das fertige Bild streckte.
/// Eine Stelle statt hunderter: jedes Mass in `Stil` und jede
/// Groessenanforderung gilt weiter in denselben Punkten wie unter Linux.
///
/// Der Faktor ist DPI / 96 geteilt durch das, was GDK schon tut: 1,5 bei
/// 150 %, 1,0 bei 200 % (GDK rechnet dort selbst mit 2), 1,25 bei 250 %.
///
/// **Linux aendert sich bei Vorgabe nicht.** Wayland liefert GTK den
/// gebrochenen Faktor ueber `fractional-scale`, dort bleibt der Systemanteil
/// 1 und keine Huelle entsteht.
///
/// **Dazu der Anteil des Nutzers** („Groesse der Oberflaeche" unter
/// Darstellung, 80 bis 150 %): er multipliziert den Systemanteil und geht
/// denselben Weg durch die Huelle — unter Windows wie unter Linux. Bei
/// 100 % bleibt alles, wie es ohne ihn waere.
enum Skalierung {
    /// Was dem System fehlt: DPI / 96 geteilt durch GDKs ganzen Faktor.
    /// Unter Linux immer 1.
    nonisolated(unsafe) private(set) static var systemanteil: Double = 1
    /// Was der Nutzer gewaehlt hat, eine der ``stufen``.
    nonisolated(unsafe) private(set) static var nutzeranteil: Double = 1
    /// Um wie viel der Inhalt groesser gezeichnet wird, als GDK es tut:
    /// Systemanteil mal Nutzeranteil.
    nonisolated(unsafe) private(set) static var faktor: Double = 1

    /// Die Stufen des Reglers. Zehnerschritte: feiner sieht man den
    /// Unterschied nicht, und acht Rasten lassen sich mit der Maus treffen.
    static let stufen: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5]

    /// Ein beliebiger Wert (aus der Datei, von Hand geaendert) auf die
    /// naechste Stufe.
    static func gerastet(_ wert: Double) -> Double {
        guard wert.isFinite else { return 1 }
        return stufen.min { abs($0 - wert) < abs($1 - wert) } ?? 1
    }

    private static func zusammensetzen() {
        let f = systemanteil * nutzeranteil
        faktor = abs(f - 1) < 0.005 ? 1 : f
    }

    /// Einmal beim Start, vor dem Stilblatt und bevor irgendein Mass gesetzt
    /// wird.
    static func einrichten(nutzer: Double = 1) {
        nutzeranteil = gerastet(nutzer)
        var gdk = 1
        var schirm = "?"
        if let anzeige = gdk_display_get_default(),
           let liste = gdk_display_get_monitors(anzeige),
           g_list_model_get_n_items(liste) > 0,
           let roh = g_list_model_get_item(liste, 0) {
            var flaeche = GdkRectangle()
            gdk_monitor_get_geometry(OpaquePointer(roh), &flaeche)
            gdk = Int(max(gdk_monitor_get_scale_factor(OpaquePointer(roh)), 1))
            gdkFaktor = gdk
            schirm = "\(flaeche.width) x \(flaeche.height), GDK \(gdk_monitor_get_scale(OpaquePointer(roh)))"
            g_object_unref(roh)
        }
        #if os(Windows)
        // Die DPI, mit denen dieser Prozess gestartet ist — dieselbe Zahl,
        // aus der GDK seinen ganzen Faktor bildet.
        let dpi = Int(GetDpiForSystem())
        let roh = Double(dpi) / 96 / Double(gdk)
        // Nur was auffaellt. Windows bietet Viertelschritte an; alles
        // darunter ist Rauschen und lohnt die Huelle nicht.
        systemanteil = roh > 1.05 ? roh : 1
        if systemanteil != 1, let einstellungen = gtk_settings_get_default() {
            // GDK setzt `gtk-xft-dpi` auf die Windows-DPI. Schrift in Punkt
            // waere damit schon vergroessert und wuerde es durch die Huelle
            // ein zweites Mal.
            var wert = GValue()
            g_value_init(&wert, g_type_from_name("gint"))
            g_value_set_int(&wert, 96 * 1024)
            g_object_set_property(unsafeBitCast(einstellungen, to: UnsafeMutablePointer<GObject>.self),
                                  "gtk-xft-dpi", &wert)
            g_value_unset(&wert)
        }
        zusammensetzen()
        Protokoll.schreib(String(format: "[Start] Skalierung: Windows %d %% (%d DPI), Schirm %@, System %.2f x Nutzer %.2f, eigener Faktor %.2f",
                                 locale: Locale(identifier: "en_US_POSIX"),
                                 Int((Double(dpi) / 96 * 100).rounded()), dpi, schirm,
                                 systemanteil, nutzeranteil, faktor))
        #else
        zusammensetzen()
        Protokoll.schreib(String(format: "[Start] Skalierung: Schirm %@, Nutzer %.2f",
                                 locale: Locale(identifier: "en_US_POSIX"), schirm, nutzeranteil))
        #endif
    }

    /// Der Regler wurde bewegt. `false`, wenn sich nichts aendert.
    ///
    /// Stehende Huellen legen sich danach neu aus (``neuAuslegen()``); wo
    /// beim Start keine entstand, weil der Faktor 1 war, setzt der Aufrufer
    /// sie nachtraeglich ein — siehe `App.oberflaecheSkalieren`.
    static func nutzerSetzen(_ anteil: Double) -> Bool {
        let neu = gerastet(anteil)
        guard neu != nutzeranteil else { return false }
        nutzeranteil = neu
        zusammensetzen()
        return true
    }

    /// Jede stehende Huelle rechnet neu — der Faktor wird beim Messen und
    /// Auslegen gelesen, nicht beim Bauen.
    static func neuAuslegen() {
        for h in huellen { gtk_widget_queue_resize(h.assumingMemoryBound(to: GtkWidget.self)) }
    }

    /// Steckt das Kind schon in einer Huelle?
    static func istGehuellt(_ kind: Widget!) -> Bool {
        guard let eltern = gtk_widget_get_parent(kind) else { return false }
        return huellen.contains(UnsafeMutableRawPointer(eltern))
    }

    /// Die Huellen, die gerade leben — Fensterinhalt, Titelzeile, offene
    /// Tafeln, das GL-Feld.
    nonisolated(unsafe) private static var huellen: [UnsafeMutableRawPointer] = []

    /// Wie viele Geraetepunkte auf einen Punkt kommen, so wie wirklich
    /// gezeichnet wird: GDKs ganzer Faktor mal der eigene. Wer auf ganze
    /// Geraetepunkte einrastet (Scrollen, Seitenschub), rastet hiermit —
    /// mit GDKs Faktor allein laege bei 150 % jede zweite Stelle auf einem
    /// halben Geraetepunkt.
    static func geraetepunkte(_ widget: Widget!) -> Double {
        Double(max(gtk_widget_get_scale_factor(widget), 1)) * faktor
    }

    /// Dasselbe aufgerundet — fuer Bildspeicher, die nur ganze Faktoren
    /// kennen. Lieber zu fein gerechnet und verkleinert als gestreckt.
    static func raster(_ widget: Widget!) -> Int32 {
        Int32(geraetepunkte(widget).rounded(.up))
    }

    /// **Wie viele Bildpunkte ein Kachelbild bekommt, das `punkte` gross
    /// gezeichnet wird** — die laengste Kante beim Entpacken.
    ///
    /// Ohne Huelle wie seit jeher: die doppelte Kante, scharf auch bei
    /// GDK-Faktor 2. **Unter der Huelle genau die Geraetepunkte.** Gemessen
    /// am 03.10.2026 in der Windows-VM (Cairo, 2560 x 1392, 60 Kacheln,
    /// Scrollen): mit doppelter Kante kostete ein Bild bei Faktor 1,5 rund
    /// 38 ms gegen 13 ms bei Faktor 1 — fast alles davon war das Umrechnen
    /// von 450 auf 337,5 Bildpunkte, Bild fuer Bild, bei jedem Schritt. Ohne
    /// Bilder lagen beide Faktoren gleich (5,0 gegen 5,5 ms). In
    /// Geraetepunkten entpackt: 10,9 ms bei 1,5.
    static func bildkante(_ punkte: Int) -> Int {
        guard faktor != 1 else { return punkte * 2 }
        return Int((Double(punkte) * Double(gdkFaktor) * faktor).rounded(.up))
    }

    /// Was beim Server angefragt wird: wie bisher die doppelte Kante, und nur
    /// wenn die Geraetepunkte darueber liegen (150 % mal 150 %) mehr — ein
    /// Bild wird beim Entpacken nur verkleinert, nie vergroessert.
    static func anfragekante(_ punkte: Int) -> Int {
        max(punkte * 2, bildkante(punkte))
    }

    /// GDKs ganzer Faktor des ersten Schirms, beim Start gelesen.
    nonisolated(unsafe) private(set) static var gdkFaktor = 1

    /// Ein Mass in Punkten als Fenstermass — fuer die wenigen Stellen, die
    /// mit dem Fenster selbst reden und damit ausserhalb der Huelle stehen.
    /// Mit `hoechstens` nie groesser als der Schirm: 900 Punkt Mindestbreite
    /// sind bei 150 % auf einem kleinen Schirm sonst breiter als er.
    static func fenstermass(_ punkte: Int, hoechstens: Int32? = nil) -> Int32 {
        guard faktor != 1 else { return Int32(punkte) }
        let mass = Int32((Double(punkte) * faktor).rounded())
        return hoechstens.map { min(mass, $0) } ?? mass
    }

    /// **Die gemerkte Fenstergroesse rechnet nur mit dem Systemanteil.**
    /// Sie steht in Punkten in der Datei, damit das Fenster nicht bei jedem
    /// Start um den Faktor waechst. Der Anteil des Nutzers bleibt draussen:
    /// wer die Oberflaeche groesser stellt, will mehr Groesse im selben
    /// Fenster, kein groesseres Fenster.
    static func fenstergroesse(_ punkte: Int) -> Int32 {
        systemanteil == 1 ? Int32(punkte) : Int32((Double(punkte) * systemanteil).rounded())
    }

    /// Das Gegenstueck zu ``fenstergroesse(_:)``.
    static func punkte(_ fenstermass: Int32) -> Int {
        systemanteil == 1 ? Int(fenstermass) : Int((Double(fenstermass) / systemanteil).rounded())
    }

    /// Das kleinste Fenster in den Punkten der gemerkten Groesse: bei 80 %
    /// darf das Fenster schmaler sein als 900 Punkt, bei 150 % muss es
    /// breiter sein.
    static func mindestpunkte(_ punkte: Int) -> Int {
        Int((Double(punkte) * nutzeranteil).rounded())
    }

    /// Das Kind, vergroessert gezeichnet. Fuer alles, was GTK als eigene
    /// Wurzel auslegt: der Fensterinhalt, die Titelzeile, jede Tafel.
    /// Ohne Faktor kommt das Kind selbst zurueck.
    static func gehuellt(_ kind: Widget!) -> Widget! {
        faktor == 1 ? kind : huelle(kind, umgekehrt: false)
    }

    /// Das Gegenstueck **innerhalb** der Huelle: das Kind wird um den Faktor
    /// groesser ausgelegt und verkleinert gezeichnet, steht also wieder eins
    /// zu eins in Geraetepunkten. Fuer das GL-Feld des Players — sein
    /// Bildspeicher richtet sich nach der ausgelegten Groesse, und ein
    /// HDR-Bild in zwei Dritteln der Aufloesung waere genau die Unschaerfe,
    /// die diese Datei vermeiden soll.
    static func entzerrt(_ kind: Widget!) -> Widget! {
        faktor == 1 ? kind : huelle(kind, umgekehrt: true)
    }

    private static func huelle(_ kind: Widget!, umgekehrt: Bool) -> Widget! {
        let h: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        if umgekehrt {
            g_object_set_data(UnsafeMutablePointer<GObject>(OpaquePointer(h)), kennung,
                              UnsafeMutableRawPointer(bitPattern: 1))
        }
        gtk_widget_set_layout_manager(h, gtk_custom_layout_new(huelleArt, huelleMessen, huelleAuslegen))
        gtk_box_append(UnsafeMutablePointer<GtkBox>(OpaquePointer(h)), kind)
        // Gemerkt, solange sie lebt: aendert der Nutzer die Groesse, legt
        // sich jede stehende Huelle neu aus.
        let zeiger = UnsafeMutableRawPointer(h!)
        huellen.append(zeiger)
        beiSignal(h, "destroy") { huellen.removeAll { $0 == zeiger } }
        // Die Huelle ist nur Rechnung, kein Baustein: sie dehnt sich wie ihr
        // Kind und verschwindet mit ihm — sonst hielte sie im Player Platz
        // frei, sobald das GL-Feld ausgeblendet wird.
        gtk_widget_set_hexpand(h, gtk_widget_get_hexpand(kind))
        gtk_widget_set_vexpand(h, gtk_widget_get_vexpand(kind))
        g_object_bind_property(UnsafeMutableRawPointer(kind), "visible",
                               UnsafeMutableRawPointer(h), "visible", GBindingFlags(rawValue: 2))   // G_BINDING_SYNC_CREATE
        return h
    }

    fileprivate static let kennung = "swiftly-entzerrt"

    fileprivate static func faktor(fuer huelle: Widget!) -> Double {
        g_object_get_data(UnsafeMutablePointer<GObject>(OpaquePointer(huelle)), kennung) != nil
            ? 1 / faktor : faktor
    }
}

private let huelleArt: @convention(c) (Widget?) -> GtkSizeRequestMode = { huelle in
    guard let kind = gtk_widget_get_first_child(huelle) else { return GTK_SIZE_REQUEST_CONSTANT_SIZE }
    return gtk_widget_get_request_mode(kind)
}

/// Was das Kind braucht, mal Faktor — aufgerundet, damit es beim Auslegen
/// nie unter sein Mindestmass faellt.
private let huelleMessen: @convention(c) (Widget?, GtkOrientation, Int32,
                                          UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                          UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Void = {
    huelle, richtung, fuer, mindest, natuerlich, mindestGrund, natuerlichGrund in
    mindestGrund?.pointee = -1
    natuerlichGrund?.pointee = -1
    guard let kind = gtk_widget_get_first_child(huelle), gtk_widget_get_visible(kind) != 0 else {
        mindest?.pointee = 0; natuerlich?.pointee = 0
        return
    }
    let f = Skalierung.faktor(fuer: huelle)
    var klein: Int32 = 0, gut: Int32 = 0
    gtk_widget_measure(kind, richtung, fuer < 0 ? -1 : Int32((Double(fuer) / f).rounded(.down)),
                       &klein, &gut, nil, nil)
    mindest?.pointee = Int32((Double(klein) * f).rounded(.up))
    natuerlich?.pointee = Int32((Double(gut) * f).rounded(.up))
}

/// Das Kind bekommt die Flaeche in seinen eigenen Punkten und wird mit dem
/// Faktor gezeichnet. Aufgerundet: lieber ein Bruchteil eines Punkts ueber
/// den Rand (das Fenster schneidet ab) als ein Streifen Hintergrund daneben.
private let huelleAuslegen: @convention(c) (Widget?, Int32, Int32, Int32) -> Void = {
    huelle, breite, hoehe, _ in
    guard let kind = gtk_widget_get_first_child(huelle), gtk_widget_get_visible(kind) != 0 else { return }
    let f = Skalierung.faktor(fuer: huelle)
    var klein: Int32 = 0
    gtk_widget_measure(kind, GTK_ORIENTATION_HORIZONTAL, -1, &klein, nil, nil, nil)
    let b = max(Int32((Double(breite) / f).rounded(.up)), klein)
    gtk_widget_measure(kind, GTK_ORIENTATION_VERTICAL, b, &klein, nil, nil, nil)
    let h = max(Int32((Double(hoehe) / f).rounded(.up)), klein)
    gtk_widget_allocate(kind, b, h, -1, gsk_transform_scale(nil, Float(f), Float(f)))
}
