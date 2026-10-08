#if DEBUG
import CGtk
import Foundation

/// **Eine Probeseite fuer die Bildzeit beim Scrollen — nur im Debug-Bau,
/// nur ueber das ``Fernsteuerpult``.**
///
/// Gebaut aus denselben Teilen wie das Filmraster (`rasterBauen`,
/// `gerahmtesBild`, `kachelhuelle`, Plakat 300 × 450 wie vom Server), aber
/// ohne Server: das Bild kommt aus einer Datei. So laesst sich in einer
/// Maschine ohne Anmeldung messen, was ein Raster mit 4, 20 oder 60 Kacheln
/// je Bild kostet — bei Faktor 1 und mit der Huelle aus ``Skalierung``.
///
/// ```
/// echo probe:60 > %TEMP%\swiftly-zeige          # Seite mit 60 Kacheln
/// echo messreihe > %TEMP%\swiftly-zeige          # 1,0 und 1,5 je 4/20/60
/// ```
/// Das Bild liegt unter `%TEMP%\swiftly-probe.jpg` (Linux `/tmp`); fehlt
/// es, bleiben die Rahmen leer und die Zeile sagt es.
///
/// Gemessen wird an der Bilduhr des Fensters: vom Ende der Phase `update`
/// (dort ist der Scrollschritt gesetzt) bis `after-paint` — Auslegen,
/// Zeichnen und Abgeben eines Bildes. Dazu der Abstand zweier Bilder.
final class Messprobe: @unchecked Sendable {
    nonisolated(unsafe) static var laufend: Messprobe?

    private unowned let app: App
    private var schritte: [(faktor: Double, kacheln: Int)]
    private let davor: Double
    private var seite: Widget?
    private var scroller: Widget?
    private var erstesBild: Widget?
    private var raster: Widget?

    private enum Phase { case aufbau, rollen, pause, teil, fertig }
    private var phase = Phase.aufbau
    private var bis: gint64 = 0
    private var bilder = 0
    private var richtung = 1.0
    private var beginn: gint64 = 0
    private var arbeit: [Double] = []
    private var abstaende: [Double] = []
    private var letzteZeit: gint64 = 0
    nonisolated(unsafe) private static var uhrVerbunden = false

    /// `ohneBild`, `ohneEcke`, `ohneText`, `ungerastet`, `doppelt` — um die Kosten einer
    /// Kachel auseinanderzunehmen.
    private let optionen: Set<String>

    init(app: App, schritte: [(Double, Int)], optionen: Set<String> = []) {
        self.app = app
        self.optionen = optionen
        self.schritte = schritte.map { (faktor: $0.0, kacheln: $0.1) }
        self.davor = Skalierung.nutzeranteil
    }

    static var bilddatei: URL {
        #if os(Windows)
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swiftly-probe.jpg")
        #else
        URL(fileURLWithPath: "/tmp/swiftly-probe.jpg")
        #endif
    }

    // MARK: Die Seite

    /// Baut die Probeseite mit `anzahl` Kacheln und zeigt sie.
    static func seiteZeigen(_ app: App, kacheln anzahl: Int, optionen: Set<String> = []) -> (seite: Widget, scroller: Widget, raster: Widget, bild: Widget?) {
        if let alt = gtk_stack_get_child_by_name(OpaquePointer(app.seiten), "probe") {
            gtk_stack_remove(OpaquePointer(app.seiten), alt)
        }
        let daten = try? Data(contentsOf: bilddatei)
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        // Die Seitenleiste steht im Filmraster daneben; hier nur ihr Platz.
        let leiste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(leiste, "swiftly-seitenleiste")
        gtk_widget_set_size_request(leiste, Int32(Stil.seitenleisteBreite), -1)
        anhaengen(reihe, leiste)

        let scroller = app.seitenscroller()
        let rahmen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_margin_start(rahmen, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(rahmen, Int32(Stil.randAbstand))
        gtk_widget_set_margin_top(rahmen, Int32(Stil.randAbstand))
        let raster = app.rasterBauen()
        var erstes: Widget?
        for i in 0..<anzahl {
            let (kaefig, bild) = gerahmtesBild(breite: Stil.kachelBreite, hoehe: Stil.kachelHoehe,
                                               stil: optionen.contains("ohneEcke") ? "swiftly-probe" : "swiftly-plakat")
            if optionen.contains("ohneEcke") { gtk_widget_set_overflow(kaefig, GTK_OVERFLOW_VISIBLE) }
            // Je Kachel eine eigene Textur, wie im echten Raster — dort hat
            // jeder Film sein eigenes Plakat.
            // Wie das Filmraster (``Skalierung/bildkante(_:)``); `doppelt`
            // misst den Stand davor, immer die doppelte Kachelkante.
            let kante = optionen.contains("doppelt")
                ? Stil.kachelHoehe * 2 : Skalierung.bildkante(Stil.kachelHoehe)
            if !optionen.contains("ohneBild"), let daten, let textur = texturEntpacken(daten, kante: kante).textur {
                gtk_picture_set_paintable(OpaquePointer(bild), textur)
                g_object_unref(UnsafeMutableRawPointer(textur))
            }
            if i % 3 == 0 { _ = balkenLegen(kaefig, breite: Stil.kachelBreite, anteil: 0.4) }
            if erstes == nil { erstes = bild }
            let kachel = app.kachelhuelle(bild: kaefig, breite: Stil.kachelBreite,
                                          oben: optionen.contains("ohneText") ? "" : "Probe \(i + 1)",
                                          unten: optionen.contains("ohneText") ? nil : "2026") {}
            gtk_widget_set_halign(kachel, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(kachel, GTK_ALIGN_START)
            gtk_flow_box_insert(OpaquePointer(raster), kachel, -1)
        }
        anhaengen(rahmen, raster)
        gtk_scrolled_window_set_child(OpaquePointer(scroller), rahmen)
        anhaengen(reihe, scroller)
        gtk_stack_add_named(OpaquePointer(app.seiten), reihe, "probe")
        gtk_stack_set_visible_child_name(OpaquePointer(app.seiten), "probe")
        Protokoll.schreib("[Probe] Seite mit \(anzahl) Kacheln \(optionen.sorted()), Bild \(daten.map { "\($0.count) Bytes" } ?? "FEHLT")")
        return (reihe!, scroller!, raster!, erstes)
    }

    // MARK: Die Reihe

    func starten() {
        Messprobe.laufend = self
        // Gemessen wird im ganzen Schirm, wie man ein Raster ansieht.
        gtk_window_maximize(alsFenster(app.fenster))
        _ = gtk_widget_add_tick_callback(app.fenster, messTakt, nil, nil)
        naechsterSchritt()
    }

    private func naechsterSchritt() {
        guard let schritt = schritte.first else {
            phase = .fertig
            app.oberflaecheSkalieren(davor)
            Protokoll.schreib("[Probe] Messreihe fertig")
            return
        }
        app.oberflaecheSkalieren(schritt.faktor)
        let (s, sc, r, b) = Messprobe.seiteZeigen(app, kacheln: schritt.kacheln, optionen: optionen)
        seite = s; scroller = sc; raster = r; erstesBild = b
        phase = .aufbau
        bis = g_get_monotonic_time() + 2_000_000
    }

    fileprivate func takt(_ uhr: OpaquePointer?) -> Bool {
        // Einmal je Prozess; die Rueckrufe fragen ``laufend``, nicht einen
        // gemerkten Zeiger — eine fertige Reihe ist dann einfach weg.
        if !Messprobe.uhrVerbunden, let uhr {
            Messprobe.uhrVerbunden = true
            g_signal_connect_data(UnsafeMutableRawPointer(uhr), "update",
                                  unsafeBitCast(uhrUpdate, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            g_signal_connect_data(UnsafeMutableRawPointer(uhr), "after-paint",
                                  unsafeBitCast(uhrNachMalen, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
        }
        let jetzt = g_get_monotonic_time()
        switch phase {
        case .fertig:
            Messprobe.laufend = nil
            return false
        case .aufbau:
            if jetzt >= bis { messungBeginnen(.rollen) }
        case .rollen:
            guard let scroller else { break }
            let anpassung = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
            let hoechst = gtk_adjustment_get_upper(anpassung) - gtk_adjustment_get_page_size(anpassung)
            var wert = gtk_adjustment_get_value(anpassung) + 15 * richtung
            if wert > hoechst { wert = hoechst; richtung = -1 }
            if wert < 0 { wert = 0; richtung = 1 }
            // Wie ``weichesScrollen``: auf ganze Geraetepunkte.
            if !optionen.contains("ungerastet") {
                let teiler = Skalierung.geraetepunkte(scroller)
                wert = (wert * teiler).rounded() / teiler
            }
            gtk_adjustment_set_value(anpassung, wert)
            bilder += 1
            if bilder == 1 { sichtbarZaehlen(hoechst) }
            if bilder >= 180 { auswerten("rollen"); phase = .pause; bis = jetzt + 500_000 }
        case .pause:
            if jetzt >= bis { messungBeginnen(.teil) }
        case .teil:
            // Eine Kachel aendert sich, der Rest steht: zeigt, ob nur ihr
            // Bereich neu gezeichnet wird oder das ganze Fenster.
            if let erstesBild { gtk_widget_set_opacity(erstesBild, bilder % 2 == 0 ? 0.98 : 1) }
            bilder += 1
            if bilder >= 120 {
                if let erstesBild { gtk_widget_set_opacity(erstesBild, 1) }
                auswerten("teil")
                schritte.removeFirst()
                naechsterSchritt()
            }
        }
        return true
    }

    private func messungBeginnen(_ neu: Phase) {
        phase = neu
        bilder = 0
        arbeit.removeAll()
        abstaende.removeAll()
        letzteZeit = 0
    }

    private var sichtbar = 0
    private var scrollbar = 0.0

    private func sichtbarZaehlen(_ hoechst: Double) {
        guard let scroller else { return }
        scrollbar = hoechst
        let hoehe = Float(gtk_widget_get_height(scroller))
        var zahl = 0
        var kachel = raster.flatMap { gtk_widget_get_first_child($0) }
        while let k = kachel {
            var r = graphene_rect_t()
            if gtk_widget_compute_bounds(k, scroller, &r) != 0,
               r.origin.y + r.size.height > 0, r.origin.y < hoehe { zahl += 1 }
            kachel = gtk_widget_get_next_sibling(k)
        }
        sichtbar = zahl
    }

    fileprivate func updateEnde() {
        guard phase == .rollen || phase == .teil else { return }
        beginn = g_get_monotonic_time()
    }

    fileprivate func malenEnde(_ uhr: OpaquePointer?) {
        guard phase == .rollen || phase == .teil, beginn != 0 else { return }
        let jetzt = g_get_monotonic_time()
        arbeit.append(Double(jetzt - beginn) / 1000)
        beginn = 0
        let zeit = uhr.map { gdk_frame_clock_get_frame_time($0) } ?? jetzt
        if letzteZeit != 0 { abstaende.append(Double(zeit - letzteZeit) / 1000) }
        letzteZeit = zeit
    }

    private func auswerten(_ was: String) {
        func stelle(_ werte: [Double], _ anteil: Double) -> Double {
            guard !werte.isEmpty else { return .nan }
            let s = werte.sorted()
            return s[min(Int((Double(s.count - 1) * anteil).rounded()), s.count - 1)]
        }
        let gdk = gtk_widget_get_scale_factor(app.fenster)
        let zeile = String(format: "[Probe] %@ faktor %.2f kacheln %d sichtbar %d fenster %d x %d px, "
                           + "%d gemalt: arbeit median %.1f p95 %.1f ms | abstand median %.1f p95 %.1f ms",
                           locale: Locale(identifier: "en_US_POSIX"),
                           was, Skalierung.faktor, schritte.first?.kacheln ?? -1, sichtbar,
                           gtk_widget_get_width(app.fenster) * gdk, gtk_widget_get_height(app.fenster) * gdk,
                           arbeit.count, stelle(arbeit, 0.5), stelle(arbeit, 0.95),
                           stelle(abstaende, 0.5), stelle(abstaende, 0.95))
        Protokoll.schreib(zeile + (optionen.isEmpty ? "" : " \(optionen.sorted())") + (was == "rollen" && scrollbar <= 0 ? " (nicht scrollbar)" : ""))
    }
}

nonisolated(unsafe) private let messTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, uhr, _ in
    guard let probe = Messprobe.laufend else { return 0 }
    return probe.takt(uhr) ? 1 : 0
}

nonisolated(unsafe) private let uhrUpdate: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    Messprobe.laufend?.updateEnde()
}

nonisolated(unsafe) private let uhrNachMalen: @convention(c) (OpaquePointer?, gpointer?) -> Void = { uhr, _ in
    Messprobe.laufend?.malenEnde(uhr)
}
#endif
