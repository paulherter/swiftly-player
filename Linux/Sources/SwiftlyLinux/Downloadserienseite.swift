import CGtk
import Foundation
import JellyfinKit

// MARK: - Was die Downloadseiten über einen Neubau hinweg wissen

/// **Stand der Downloadliste und der Seite einer geladenen Serie.**
///
/// Beide Listen werden bei jeder Änderung neu gebaut (``App/downloadseiteFuellen()``).
/// Was einen Neubau überleben muss — der Schätzer je Posten, ob der
/// Auswahlkreis gerade herein- oder hinausfährt, was auf der Serienseite
/// angekreuzt ist —, liegt deshalb hier und nicht in den Zeilen.
///
/// Angefasst nur auf GTKs Hauptfaden, daher `@unchecked Sendable`.
final class Downloadanzeige: @unchecked Sendable {
    static let geteilt = Downloadanzeige()

    /// Wie der Auswahlkreis beim nächsten Neubau steht.
    enum Kreisfahrt { case steht, herein, hinaus }

    // Der Fortschritt
    var schaetzer: [String: Fortschrittsschaetzer] = [:]
    var gemeldet: [String: Int64] = [:]

    // Die Liste
    var listenzeichen = ""
    var listenfahrt: Kreisfahrt = .steht

    // Die Seite einer geladenen Serie
    var serie: String?
    var titel = ""
    var liste: Widget?
    var angabe: Widget?
    var abspielen: Widget?
    var entfernen: Widget?
    var bearbeitenKnopf: Widget?
    var kulisse: Kulisse?
    var bearbeiten = false
    var gewaehlt: Set<String> = []
    var serienfahrt: Kreisfahrt = .steht
    var serienzeichen = ""
}

// MARK: - Der Balken

/// **Der Fortschritt mit runden Enden**, wie `MacDownloadzeile`: eine Kapsel
/// in Weiß 30 %, darin die Kapsel im Akzent, 3 hoch.
///
/// Hier stand ein `GtkProgressBar` — ein Standardsteuerelement (E4), und
/// ohne eigene Regel im Stilblatt zeichnete es das Systemthema: eckig, in
/// dessen Farbe. Gemalt wie ``Kreiszeichen``.
final class Ladebalken: @unchecked Sendable {
    fileprivate var lebt = true
    fileprivate var anteil: Double
    let anzeige: Widget

    init(anteil: Double) {
        self.anteil = anteil
        let feld: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-blank")
        gtk_drawing_area_set_content_height(alsZeichen(feld), 3)
        gtk_widget_set_hexpand(feld, 1)
        anzeige = feld!
        gtk_drawing_area_set_draw_func(alsZeichen(feld), balkenMalen,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // Die Zeichenfläche hält den Balken, nicht umgekehrt (wie ``Kulisse``).
        beiSignal(feld, "destroy") { self.lebt = false }
    }

    func setzen(_ neu: Double) {
        guard lebt, abs(neu - anteil) > 0.0001 else { return }
        anteil = neu
        gtk_widget_queue_draw(anzeige)
    }
}

private func kapsel(_ cr: OpaquePointer, _ x: Double, _ breite: Double, _ hoehe: Double) {
    let r = hoehe / 2
    cairo_new_path(cr)
    cairo_arc(cr, x + breite - r, r, r, -Double.pi / 2, Double.pi / 2)
    cairo_arc(cr, x + r, r, r, Double.pi / 2, 3 * Double.pi / 2)
    cairo_close_path(cr)
}

nonisolated(unsafe) private let balkenMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    let b = Unmanaged<Ladebalken>.fromOpaque(daten).takeUnretainedValue()
    guard b.lebt, breite > 0, hoehe > 0 else { return }
    let w = Double(breite), h = Double(hoehe)
    kapsel(cr, 0, w, h)
    cairo_set_source_rgba(cr, Stil.weissRGB.0, Stil.weissRGB.1, Stil.weissRGB.2, 0.3)
    cairo_fill_preserve(cr)
    cairo_clip(cr)
    let voll = w * min(max(b.anteil, 0), 1)
    guard voll > 0 else { return }
    kapsel(cr, 0, max(voll, h), h)
    cairo_set_source_rgba(cr, Stil.akzentRGB.0, Stil.akzentRGB.1, Stil.akzentRGB.2, 1)
    cairo_fill(cr)
}

// MARK: - Weiterzählen zwischen den Meldungen

/// **Während geladen wird, zählt die Zeile je Bild weiter** (Mac cc4e6e75).
///
/// Die Verwaltung meldet höchstens einmal je Sekunde; dazwischen rechnet
/// `Fortschrittsschaetzer` aus dem Paket im Tempo der letzten Sekunden
/// weiter. Zahl und Balken lesen **denselben** Wert. Der Takt hängt an der
/// Unterzeile und geht mit ihr — angehalten wird er gar nicht erst gesetzt,
/// dann steht die Zahl sofort.
private final class Zaehlwerk {
    let id: String
    let bytes: Int64
    let zeile: Widget
    let balken: Ladebalken?
    var zuletzt = Date.distantPast

    init(id: String, bytes: Int64, zeile: Widget, balken: Ladebalken?) {
        self.id = id; self.bytes = bytes; self.zeile = zeile; self.balken = balken
    }
}

nonisolated(unsafe) private let zaehlTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, daten in
    guard let daten else { return 0 }
    let z = Unmanaged<Zaehlwerk>.fromOpaque(daten).takeUnretainedValue()
    let jetzt = Date()
    // Dreißig Bilder je Sekunde reichen für eine Zahl — wie
    // `TimelineView(.animation(minimumInterval: 1/30))` auf dem Mac.
    guard jetzt.timeIntervalSince(z.zuletzt) >= 1.0 / 30 else { return 1 }
    z.zuletzt = jetzt
    let a = Downloadanzeige.geteilt
    guard var s = a.schaetzer[z.id] else { return 1 }
    let geladen = s.wert(um: jetzt)
    a.schaetzer[z.id] = s
    gtk_label_set_text(OpaquePointer(z.zeile), downloadLadetext(geladen, von: z.bytes))
    if z.bytes > 0 { z.balken?.setzen(Double(geladen) / Double(z.bytes)) }
    return 1
}

nonisolated(unsafe) private let zaehlwerkLoesen: @convention(c) (gpointer?) -> Void = { daten in
    guard let daten else { return }
    Unmanaged<Zaehlwerk>.fromOpaque(daten).release()
}

/// „0,84 von 2,31 GB" — **feste Einheit, feste Stellen** (Mac cc4e6e75).
/// `groesse` wechselte mitten im Laden von „845 MB" auf „1 GB" und
/// „1,01 GB"; die Zeile wurde bei jedem Schritt anders breit. Die Regel steht
/// als `Downloadregeln.fortschritt` im Paket.
func downloadLadetext(_ geladen: Int64, von bytes: Int64) -> String {
    guard bytes > 0 else { return Downloadregeln.groesse(geladen) }
    let f = Downloadregeln.fortschritt(geladen: geladen, von: bytes)
    return String(format: uebersetzt("%@ von %@"), f.geladen, f.gesamt)
}

/// Hängt das Weiterzählen an die Unterzeile einer laufenden Zeile.
func downloadZaehlen(_ id: String, bytes: Int64, zeile: Widget!, balken: Ladebalken?) {
    let z = Zaehlwerk(id: id, bytes: bytes, zeile: zeile, balken: balken)
    _ = gtk_widget_add_tick_callback(zeile, zaehlTakt,
                                     Unmanaged.passRetained(z).toOpaque(), zaehlwerkLoesen)
}

// MARK: - Die Entf-Taste

private final class Tastenauftrag {
    let block: (UInt32) -> Bool
    init(_ block: @escaping (UInt32) -> Bool) { self.block = block }
}

nonisolated(unsafe) private let tasteAufSeite: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32, GdkModifierType, gpointer?
) -> gboolean = { _, wert, _, _, daten in
    guard let daten else { return 0 }
    return Unmanaged<Tastenauftrag>.fromOpaque(daten).takeUnretainedValue().block(wert) ? 1 : 0
}

nonisolated(unsafe) private let tastenauftragLoesen: @convention(c) (
    gpointer?, UnsafeMutablePointer<_GClosure>?
) -> Void = { daten, _ in
    guard let daten else { return }
    Unmanaged<Tastenauftrag>.fromOpaque(daten).release()
}

// MARK: - Eine geladene Serie

/// **Die Serie auf diesem Rechner, als eigene Seite** — die GTK-Fassung von
/// `Downloadserienseite` (`Sources/macOS/Macdownloads.swift`, Mac cc4e6e75).
///
/// Oben das große Bild, der Name mit Folgenzahl und Größe, ein Abspielknopf,
/// darunter die Folgen nach Staffel. Vorher klappte die Serienzeile der
/// Downloadliste an Ort und Stelle auf — eine Liste unter dem Namen, ohne
/// Bild und ohne Abspielknopf. Genau diese Fassung hat der Mac verworfen.
///
/// **Alles von der Platte.** Wer hier steht, hat womöglich kein Netz: das
/// Bild ist das gesicherte Kopfbild der Serie, sonst das Querbild der
/// nächsten Folge oder das Plakat, und erst danach eine Serveradresse. Der
/// Abspielknopf spielt die Datei (`downloadSpielen`), nicht den Titel vom
/// Server.
///
/// **Entfernen geht über die rechte Taste auf einer Folge oder über
/// Bearbeiten** — Auswahlkreise, dann der Papierkorb oder die Entf-Taste.
/// Das Wischen des iPhones gibt es mit Zeiger nicht (Abschnitt F).
///
/// **Auf dem Seitenstapel liegt eine Marke**, kein Titel vom Server: der
/// Stapel hält `Item`, und die Marke trägt die Serienkennung mit einem
/// Vorsatz, damit keine Seite sie für die Serie selbst hält (siehe
/// `nachDemPlayerAuffrischen`, das die Serienkennung vergleicht).
extension App {

    static let downloadserienVorsatz = "downloadserie:"
    static let downloadserienArt = "Downloadserie"

    /// Öffnet die Seite einer geladenen Serie auf dem Stapel der Downloads.
    func downloadserieOeffnen(_ serienId: String, titel: String) {
        let marke = Item(id: Self.downloadserienVorsatz + serienId, name: titel,
                         type: Self.downloadserienArt)
        seitenstapel[bereich, default: []].append(marke)
        downloadserieZeigen(marke, schub: .tiefer)
    }

    /// Baut die Seite zur Marke — beim Öffnen und beim Zurückkehren in den
    /// Bereich.
    func downloadserieZeigen(_ marke: Item, schub: Schub) {
        let sid = String(marke.id.dropFirst(Self.downloadserienVorsatz.count))
        let a = Downloadanzeige.geteilt
        if a.serie != sid { a.bearbeiten = false; a.gewaehlt = [] }
        a.serie = sid
        a.titel = marke.name ?? ""
        a.serienzeichen = ""
        a.serienfahrt = .steht

        let scheibe = naechsteScheibe()
        let seite = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        let scroller = seitenscroller()
        gtk_scrolled_window_set_child(OpaquePointer(scroller), seite)

        let ueber: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(ueber), scroller)
        // Derselbe Kopf wie jede Detailseite: Pfeil zurück, und der Name
        // blendet ein, sobald der große darunter verschwindet.
        gtk_overlay_add_overlay(OpaquePointer(ueber), detailkopfBauen(marke))
        anhaengen(detailhuelle, ueber)

        // Die Kopfzone: Kulisse rechts, Block links — wie ``heldenkopf``.
        let kopf: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(kopf, 1)
        let kulisse = Kulisse()
        gtk_overlay_set_child(OpaquePointer(kopf), kulisse.anzeige)
        gtk_overlay_add_overlay(OpaquePointer(kopf), downloadserienblock(a.titel))
        anhaengen(seite, kopf)
        a.kulisse = kulisse
        beiSignal(kulisse.anzeige, "destroy") {
            if a.kulisse === kulisse { a.kulisse = nil }
        }

        // Die Folgen nach Staffel — Lesemaß 900 wie die Downloadliste.
        let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_margin_start(liste, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(liste, Int32(Stil.randAbstand))
        gtk_widget_set_margin_bottom(liste, 40)
        anhaengen(seite, liste)
        deckeln(liste, in: scroller, auf: 900)
        a.liste = liste
        beiSignal(liste, "destroy") {
            if a.liste == liste { a.liste = nil; a.angabe = nil; a.abspielen = nil
                                  a.entfernen = nil; a.bearbeitenKnopf = nil }
        }

        // Den Namen oben einblenden — dieselbe Strecke wie auf der
        // Detailseite: ab 98 − 24 = 74, über die 42 Punkt seiner Höhe.
        let senkrecht = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))!
        beiSignalRoh(UnsafeMutableRawPointer(senkrecht), "value-changed") { [weak self] in
            guard let self, let name = self.detailkopfTitel else { return }
            let staerke = min(max((gtk_adjustment_get_value(senkrecht) - 74) / 42, 0), 1)
            gtk_widget_set_opacity(name, staerke)
            if let leiste = self.detailkopfLeiste { gtk_widget_set_opacity(leiste, staerke) }
            if let verlauf = self.detailkopfVerlauf { gtk_widget_set_opacity(verlauf, 1 - staerke) }
        }

        // **Die Entf-Taste wirft die Auswahl weg** — auf dem Schreibtisch
        // der übliche Weg. Die Rückschritttaste mit, denn sie ist die Taste,
        // die auf dem Mac „delete" heißt.
        let horcher = gtk_event_controller_key_new()
        gtk_event_controller_set_propagation_phase(horcher, GTK_PHASE_CAPTURE)
        let auftrag = Tastenauftrag { [weak self] wert in
            guard let self, wert == 0xFFFF || wert == 0xFF9F || wert == 0xFF08,
                  a.bearbeiten, !a.gewaehlt.isEmpty else { return false }
            self.downloadserieGewaehlteEntfernen()
            return true
        }
        g_signal_connect_data(UnsafeMutableRawPointer(horcher), "key-pressed",
                              unsafeBitCast(tasteAufSeite, to: GCallback.self),
                              Unmanaged.passRetained(auftrag).toOpaque(),
                              tastenauftragLoesen, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(ueber, horcher)

        downloadserieNachfuehren(erzwingen: true)
        downloadkopfbildSetzen(sid)
        schieben(zu: scheibe, richtung: schub)
        downloadkopfbildNachholen(sid)
    }

    /// Name und Angabe, darunter die Knöpfe — an der Stelle, an der die
    /// Detailseite sie trägt.
    private func downloadserienblock(_ titel: String) -> Widget! {
        let a = Downloadanzeige.geteilt
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_halign(block, GTK_ALIGN_START)
        gtk_widget_set_valign(block, GTK_ALIGN_START)
        gtk_widget_set_margin_start(block, Int32(Stil.randAbstand))
        // Wie ``heldenblock``: titelHoehe + 98, minus die Kopfleiste.
        gtk_widget_set_margin_top(block, Int32(Stil.titelHoehe + 98 - Stil.kopfzeileHoehe))

        let name = beschriftung(titel, stil: "swiftly-heldtitel")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_widget_set_size_request(name, 640, 42)
        anhaengen(block, name)

        let angabe = beschriftung("", stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(angabe, "dim-label")
        gtk_label_set_xalign(OpaquePointer(angabe), 0)
        gtk_widget_set_margin_top(angabe, 12)
        anhaengen(block, angabe)
        a.angabe = angabe

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        gtk_widget_set_margin_top(reihe, 22)
        gtk_widget_set_halign(reihe, GTK_ALIGN_START)

        // **Die nächste ungesehene Folge**, sonst von vorn — die Regel steht
        // in `Downloadregeln.naechsteFolge`, die Beschriftung in
        // `Item.serienknopf` („Abspielen S2 F6"), beides im Paket.
        let haupt = hauptknopf(uebersetzt("Abspielen"), symbol: "media-playback-start-symbolic")
        gtk_widget_set_size_request(haupt, Int32(Stil.hauptknopfBreite),
                                    Int32(Stil.hauptknopfHoehe))
        gtk_widget_set_halign(haupt, GTK_ALIGN_START)
        beiSignal(haupt, "clicked") { [weak self] in
            guard let self, let n = Downloadregeln.naechsteFolge(aus: self.downloadserienfolgen())
            else { return }
            self.downloadSpielen(n)
        }
        anhaengen(reihe, haupt)
        a.abspielen = haupt

        let bearbeiten = chip(uebersetzt("Bearbeiten"), symbol: "document-edit-symbolic",
                              aktiv: a.bearbeiten)
        beiSignal(bearbeiten, "clicked") { [weak self] in
            guard let self else { return }
            a.bearbeiten.toggle()
            a.gewaehlt = []
            self.downloadserieFahren(herein: a.bearbeiten)
        }
        anhaengen(reihe, bearbeiten)
        a.bearbeitenKnopf = bearbeiten

        let weg = chip(uebersetzt("Entfernen"), symbol: "user-trash-symbolic")
        gtk_widget_set_visible(weg, 0)
        beiSignal(weg, "clicked") { [weak self] in self?.downloadserieGewaehlteEntfernen() }
        anhaengen(reihe, weg)
        a.entfernen = weg

        anhaengen(block, reihe)
        return block
    }

    /// Die Folgen dieser Serie, nach Staffel und Folge.
    func downloadserienfolgen() -> [Downloadposten] {
        guard let sid = Downloadanzeige.geteilt.serie else { return [] }
        return downloads.posten
            .filter { $0.serienId == sid }
            .sorted { ($0.staffel ?? 0, $0.folge ?? 0) < ($1.staffel ?? 0, $1.folge ?? 0) }
    }

    /// **Neu gebaut, wenn sich etwas geändert hat, das man sieht** — nicht
    /// bei jeder Fortschrittsmeldung; die zählt die Zeile selbst weiter.
    func downloadserieNachfuehren(erzwingen: Bool = false) {
        let a = Downloadanzeige.geteilt
        guard let liste = a.liste, let sid = a.serie else { return }
        let folgen = downloadserienfolgen()

        // **Die letzte Folge weg, die Seite weg.** Eine Serienseite ohne
        // Folgen hat nichts mehr zu zeigen; zurück in die Liste — aber nur,
        // wenn sie auch die ist, die gerade dasteht.
        if folgen.isEmpty {
            if bereich == .downloads,
               seitenstapel[.downloads]?.last?.id == Self.downloadserienVorsatz + sid {
                aufHauptfaden { [self] in self.zurueck() }
            }
            return
        }

        let zeichen = downloadzeichen(folgen) + "|\(a.bearbeiten)|\(a.gewaehlt.sorted())|\(a.serienfahrt)"
        guard erzwingen || zeichen != a.serienzeichen else { return }
        a.serienzeichen = zeichen

        if let angabe = a.angabe {
            gtk_label_set_text(OpaquePointer(angabe),
                               String(format: uebersetzt("%d Folgen"), folgen.count) + " · "
                               + Downloadregeln.groesse(folgen.reduce(0) { $0 + $1.bytes }))
        }
        if let haupt = a.abspielen {
            let naechste = Downloadregeln.naechsteFolge(aus: folgen)
            hauptknopfBeschriften(haupt, Item.serienknopf(folge: naechste?.alsItem, laedt: false))
            gtk_widget_set_sensitive(haupt, naechste == nil ? 0 : 1)
        }
        if let k = a.bearbeitenKnopf {
            if a.bearbeiten { gtk_widget_add_css_class(k, "swiftly-aktiv") }
            else { gtk_widget_remove_css_class(k, "swiftly-aktiv") }
        }
        if let weg = a.entfernen {
            gtk_widget_set_visible(weg, a.bearbeiten && !a.gewaehlt.isEmpty ? 1 : 0)
        }

        leeren(liste)
        var reihe: [Int?] = []
        var je: [Int?: [Downloadposten]] = [:]
        for p in folgen {
            if je[p.staffel] == nil { reihe.append(p.staffel) }
            je[p.staffel, default: []].append(p)
        }
        for nummer in reihe {
            let eigene = je[nummer] ?? []
            if let n = nummer {
                let rubrik = beschriftung(String(format: uebersetzt("Staffel %d"), n),
                                          stil: "swiftly-gruppenrubrik")
                gtk_label_set_xalign(OpaquePointer(rubrik), 0)
                gtk_widget_set_margin_top(rubrik, 26)
                gtk_widget_set_margin_bottom(rubrik, 10)
                anhaengen(liste, rubrik)
            }
            for (i, p) in eigene.enumerated() {
                anhaengen(liste, downloadseriezeile(p))
                if i < eigene.count - 1 { anhaengen(liste, zeilenstrich()) }
            }
        }
    }

    /// Eine Folge auf der Serienseite: dieselbe Zeile wie in der Liste, mit
    /// dem Weg, der auf dem iPhone „lange drücken" heißt — hier die rechte
    /// Taste, und die Nachfrage steht als Tafel am Ort (E4).
    private func downloadseriezeile(_ p: Downloadposten) -> Widget! {
        let a = Downloadanzeige.geteilt
        let zeile = downloadzeile(p, bearbeiten: a.bearbeiten,
                                  gewaehlt: a.gewaehlt.contains(p.id),
                                  fahrt: a.serienfahrt) { [weak self] in
            if a.gewaehlt.contains(p.id) { a.gewaehlt.remove(p.id) } else { a.gewaehlt.insert(p.id) }
            self?.downloadserieNachfuehren()
        }
        let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        let tafel = tafelAn(zeile)
        gtk_popover_set_child(alsTafel(tafel), liste)
        anhaengen(liste, handlungszeile("user-trash-symbolic",
                                        uebersetzt("Download entfernen")) { [weak self] in
            gtk_popover_popdown(alsTafel(tafel))
            self?.downloadsEntfernen([p.id])
        })
        beiRechtsklick(zeile) { gtk_popover_popup(alsTafel(tafel)) }
        return zeile
    }

    private func downloadserieGewaehlteEntfernen() {
        let a = Downloadanzeige.geteilt
        let weg = Array(a.gewaehlt)
        a.gewaehlt = []
        a.bearbeiten = false
        downloadsEntfernen(weg)
        downloadserieFahren(herein: false)
    }

    /// Entfernt und baut beide Listen nach — nicht aus dem Klick heraus, der
    /// gerade in einer Zeile läuft, die dabei abgeräumt wird.
    func downloadsEntfernen(_ ids: [String]) {
        downloads.entfernen(ids)
        aufHauptfaden { [self] in self.downloadseiteFuellen() }
    }

    /// Der Kreis fährt herein oder hinaus (Mac `.move(edge: .leading)`,
    /// `sprung`, 0,22 s); danach steht er wieder.
    private func downloadserieFahren(herein: Bool) {
        let a = Downloadanzeige.geteilt
        a.serienfahrt = herein ? .herein : .hinaus
        downloadserieNachfuehren(erzwingen: true)
        a.serienfahrt = .steht
        guard !herein, let liste = a.liste else { return }
        a.serienfahrt = .hinaus
        laufen(auf: liste, dauer: 0.22, schritt: { _ in }, fertig: { [weak self] in
            a.serienfahrt = .steht
            self?.downloadserieNachfuehren(erzwingen: true)
        })
    }

    // MARK: Das Kopfbild

    /// Wie breit das Kopfbild in Pixeln sein muss: die Kulisse nimmt 62 %
    /// der Breite, und ein 16:9-Bild braucht mindestens die Breite, die die
    /// Höhe füllt (`Downloadserienseite.kopfpixel` auf dem Mac, dieselbe
    /// Rechnung). Mal der Skalierung, damit es scharf ist.
    func downloadkopfpixel() -> Int {
        let breite = Double(max(gtk_widget_get_width(buehne), 1))
        let teiler = Double(max(gtk_widget_get_scale_factor(fenster), 1))
        let punkte = max(breite * 0.62, Double(Stil.heldHoehe) * 1.62 * 16 / 9)
        return Int((punkte * teiler).rounded(.up))
    }

    /// **Kopfbild und Plakat gehen mit dem ersten Download einer Serie mit**
    /// (Mac cc4e6e75, `SerienView.ladebilder`) — das Kopfbild in
    /// Fensterauflösung, das Plakat 600 hoch statt der 300 einer Kachel.
    func downloadSerienbilderMitgeben(_ serie: Item) {
        guard let client, let adressen, !benutzerID.isEmpty else { return }
        let konto = benutzerID
        let pixel = downloadkopfpixel()
        let plakat = Bildwahl.hochkant(serie, adressen: adressen, maxHoehe: 600)
        let verwaltung = downloads
        Task.detached {
            let paar = await client.kopfbildPaar(fuer: serie, adressen: adressen, gross: pixel)
            aufHauptfaden {
                verwaltung.serienbilderSichern(serie: serie.id, konto: konto,
                                               kopf: paar?.gross, plakat: plakat)
            }
        }
    }

    /// Das Bild von der Platte, sonst vom Server. Die Reihenfolge des Macs:
    /// Kopfbild, Querbild der nächsten Folge, Plakat, Serveradresse.
    private func downloadkopfbildSetzen(_ sid: String, nachgeholt: URL? = nil) {
        let folgen = downloadserienfolgen()
        guard let p = Downloadregeln.naechsteFolge(aus: folgen) ?? folgen.first,
              let kulisse = Downloadanzeige.geteilt.kulisse else { return }
        let url = nachgeholt
            ?? downloads.kopfbild(serie: sid, konto: p.konto)
            ?? downloads.bild(fuer: p)
            ?? downloads.bild(fuer: p, alsGruppe: true)
            ?? adressen?.bauen(itemID: p.serienId ?? p.id, mass: .hoechstensHoch(300))
        guard let url else { return }
        Task.detached {
            let daten: Data?
            if url.isFileURL {
                daten = try? Data(contentsOf: url)
            } else {
                daten = await Bildlager.shared.laden(url, schluessel: Bildschluessel.fuer(url))
            }
            guard let daten else { return }
            aufHauptfaden { kulisse.setzen(daten) }
        }
    }

    /// **Downloads von vorher haben kein großes Kopfbild** — mit Netz wird
    /// es hier einmal nachgeholt. Ohne Netz scheitert die Abfrage still, und
    /// es bleibt beim Bild von der Platte.
    private func downloadkopfbildNachholen(_ sid: String) {
        guard let client, let adressen, let p = downloadserienfolgen().first,
              downloads.kopfbild(serie: sid, konto: p.konto) == nil else { return }
        let pixel = downloadkopfpixel()
        let verwaltung = downloads
        Task.detached { [self] in
            guard let serie = try? await client.item(id: sid),
                  let paar = await client.kopfbildPaar(fuer: serie, adressen: adressen,
                                                       gross: pixel),
                  let da = await verwaltung.kopfbildNachholen(serie: sid, konto: p.konto,
                                                              von: paar.gross)
            else { return }
            aufHauptfaden {
                guard Downloadanzeige.geteilt.serie == sid else { return }
                self.downloadkopfbildSetzen(sid, nachgeholt: da)
            }
        }
    }
}
