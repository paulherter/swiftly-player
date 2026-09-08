import CGtk
import Foundation
import JellyfinKit

/// **Die Downloadseite auf Linux und Windows.**
///
/// Verhalten aus `VERHALTEN.md`, Abschnitt H — dasselbe wie auf dem Mac, und
/// dort steht auch schon, was gegenueber dem iPhone abweicht. Hier kommt
/// nichts Neues dazu: derselbe Kopf mit derselben Belegungszeile, dieselben
/// zwei Rubriken („Laedt gerade" und, was hier liegt), dieselbe Bearbeiten-
/// Weise mit Haken und einem Entfernen-Knopf, der erst erscheint, wenn etwas
/// angekreuzt ist.
///
/// **Auch das Bearbeiten ist uebernommen, nicht ersetzt.** Ein Knopf je Zeile
/// waere weniger Code gewesen; er waere aber eine zweite Bedienweise fuer
/// dieselbe Sache, und dafuer gibt es keinen Grund aus Eingabeart, Entfernung
/// oder Fenstergroesse — die drei, die eine Abweichung ueberhaupt
/// rechtfertigen duerfen.
///
/// Die Regeln — wer als Naechstes laedt, was entbehrlich ist, wie gruppiert
/// wird — stehen als `Downloadregeln` im Paket und nicht hier.
extension App {

    // MARK: Aufbau

    func downloadseiteBauen() -> Widget! {
        let blaettern: Widget! = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(blaettern),
                                       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_vexpand(blaettern, 1)

        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        // Dieselben Masse wie jede andere Seite: oben 52, seitlich 24.
        gtk_widget_set_margin_start(block, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(block, Int32(Stil.randAbstand))
        gtk_widget_set_margin_top(block, Int32(Stil.inhaltOben))
        gtk_widget_set_margin_bottom(block, 40)

        // Kopf: Titel links, Knoepfe rechts.
        let kopf = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
        let titelblock = stapel(GTK_ORIENTATION_VERTICAL, abstand: 4)
        gtk_widget_set_hexpand(titelblock, 1)
        let titel = beschriftung(uebersetzt("Downloads"), stil: "swiftly-titelgross")
        gtk_label_set_xalign(OpaquePointer(titel), 0)
        anhaengen(titelblock, titel)
        downloadbelegung = beschriftung("", stil: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(downloadbelegung), 0)
        anhaengen(titelblock, downloadbelegung)
        anhaengen(kopf, titelblock)

        downloadentfernen = chip(uebersetzt("Entfernen"), symbol: "user-trash-symbolic")
        gtk_widget_set_valign(downloadentfernen, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(downloadentfernen, 0)
        beiSignal(downloadentfernen, "clicked") { [weak self] in
            guard let self else { return }
            self.downloads.entfernen(Array(self.downloadgewaehlt))
            self.downloadgewaehlt = []
            self.downloadbearbeiten = false
            self.downloadseiteFuellen()
        }
        anhaengen(kopf, downloadentfernen)

        downloadbearbeitenknopf = chip(uebersetzt("Bearbeiten"), symbol: "document-edit-symbolic")
        gtk_widget_set_valign(downloadbearbeitenknopf, GTK_ALIGN_CENTER)
        beiSignal(downloadbearbeitenknopf, "clicked") { [weak self] in
            guard let self else { return }
            self.downloadbearbeiten.toggle()
            if !self.downloadbearbeiten { self.downloadgewaehlt = [] }
            self.downloadseiteFuellen()
        }
        anhaengen(kopf, downloadbearbeitenknopf)
        anhaengen(block, kopf)

        downloadliste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_margin_top(downloadliste, 18)
        anhaengen(block, downloadliste)

        downloadleer = leerzustand("folder-download-symbolic",
                                   uebersetzt("Noch nichts geladen"),
                                   uebersetzt("Was du hier ablegst, läuft auch ohne Netz."))
        gtk_widget_set_visible(downloadleer, 0)
        anhaengen(block, downloadleer)

        gtk_scrolled_window_set_child(OpaquePointer(blaettern), block)
        return blaettern
    }

    // MARK: Fuellen

    /// **Die ganze Liste wird neu gebaut, nicht nachgebessert.**
    ///
    /// Sie ist kurz — wer zwanzig Filme geladen hat, hat viel geladen —, und
    /// eine Liste, die sich an drei Stellen selbst nachbessert, laeuft
    /// auseinander. Gerufen wird von `Downloadverwaltung.beiAenderung`, also
    /// hoechstens einmal je Sekunde waehrend eines Downloads; der Fortschritt
    /// selbst geht ueber ``downloadbalkenNachfuehren`` und baut nichts neu.
    func downloadseiteFuellen() {
        guard downloadliste != nil else { return }
        leeren(downloadliste)
        downloadbalken = [:]
        downloadstandzeilen = [:]

        let alle = downloads.posten
        let laufend = alle.filter { $0.stand != .fertig }
        let fertige = Downloadregeln.gruppiert(alle.filter { $0.stand == .fertig })

        gtk_label_set_text(OpaquePointer(downloadbelegung), belegungszeile())
        gtk_widget_set_visible(downloadbearbeitenknopf, alle.isEmpty ? 0 : 1)
        gtk_widget_set_visible(downloadentfernen,
                               downloadbearbeiten && !downloadgewaehlt.isEmpty ? 1 : 0)
        gtk_widget_set_visible(downloadleer, alle.isEmpty ? 1 : 0)

        if !laufend.isEmpty {
            anhaengen(downloadliste, downloadrubrik(uebersetzt("Lädt gerade")))
            for (i, p) in laufend.enumerated() {
                anhaengen(downloadliste, downloadzeile(p))
                if i < laufend.count - 1 { anhaengen(downloadliste, zeilenstrich()) }
            }
        }

        if !fertige.isEmpty {
            anhaengen(downloadliste, downloadrubrik(uebersetzt("Auf diesem Rechner")))
            for (i, g) in fertige.enumerated() {
                switch g {
                case let .einzeln(p):
                    anhaengen(downloadliste, downloadzeile(p))
                case let .serie(_, titel, folgen):
                    anhaengen(downloadliste, downloadseriezeile(titel, folgen))
                }
                if i < fertige.count - 1 { anhaengen(downloadliste, zeilenstrich()) }
            }
        }
    }

    private func downloadrubrik(_ text: String) -> Widget! {
        let r = rubrik(text)
        gtk_widget_set_margin_top(r, 22)
        gtk_widget_set_margin_bottom(r, 8)
        return r
    }

    /// „12 Titel · 42,8 GB · 310 GB frei" — die Zahlen kommen aus dem Paket,
    /// damit sie hier so aussehen wie in den Einstellungen des Systems.
    private func belegungszeile() -> String {
        let b = Downloadregeln.belegung(downloads.posten)
        guard b.anzahl > 0 || downloads.posten.contains(where: { $0.stand != .fertig }) else {
            return uebersetzt("Nichts auf diesem Rechner")
        }
        let anzahl = String(format: uebersetzt("%d Titel"), b.anzahl)
        return anzahl + " · " + Downloadregeln.groesse(b.bytes)
    }

    // MARK: Eine Zeile

    private func downloadzeile(_ p: Downloadposten) -> Widget! {
        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        gtk_widget_set_margin_top(zeile, 8)
        gtk_widget_set_margin_bottom(zeile, 8)

        if downloadbearbeiten { anhaengen(zeile, downloadhaken([p.id])) }

        // Bild wie auf der Kachel, nur quer und klein.
        let (huelle, bild) = gerahmtesBild(breite: 96, hoehe: 54, stil: "swiftly-plakat")
        if let url = downloadbild(p) {
            bildLaden(bild, url: url, schluessel: "dl-\(p.id)", sofort: true)
        } else {
            zeichenLegen(huelle, serie: p.art == .folge)
        }
        anhaengen(zeile, huelle)

        let text = stapel(GTK_ORIENTATION_VERTICAL, abstand: 3)
        gtk_widget_set_hexpand(text, 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        let titel = beschriftung(p.titel, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(titel), 0)
        gtk_label_set_ellipsize(OpaquePointer(titel), PANGO_ELLIPSIZE_END)
        anhaengen(text, titel)

        let stand = beschriftung(downloadstandwort(p), stil: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(stand), 0)
        gtk_label_set_ellipsize(OpaquePointer(stand), PANGO_ELLIPSIZE_END)
        if p.stand == .fehler { gtk_widget_add_css_class(stand, "swiftly-warnung") }
        anhaengen(text, stand)
        downloadstandzeilen[p.id] = stand

        // **Der Balken nur, solange etwas laeuft.** Ein Balken auf 100 % bei
        // etwas Fertigem sagt nichts und sieht aus wie ein haengender
        // Vorgang.
        if p.stand != .fertig, let anteil = p.anteil {
            let spur: Widget! = gtk_progress_bar_new()
            gtk_progress_bar_set_fraction(OpaquePointer(spur), anteil)
            gtk_widget_add_css_class(spur, "swiftly-fortschritt")
            anhaengen(text, spur)
            downloadbalken[p.id] = spur
        }
        anhaengen(zeile, text)

        anhaengen(zeile, downloadknopf(p))
        return zeile
    }

    /// H12: eine Serie ist **eine** Zeile — mit der Zahl ihrer Folgen.
    private func downloadseriezeile(_ titel: String, _ folgen: [Downloadposten]) -> Widget! {
        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        gtk_widget_set_margin_top(zeile, 8)
        gtk_widget_set_margin_bottom(zeile, 8)

        if downloadbearbeiten { anhaengen(zeile, downloadhaken(folgen.map(\.id))) }

        let (huelle, bild) = gerahmtesBild(breite: 96, hoehe: 54, stil: "swiftly-plakat")
        if let erste = folgen.first, let url = downloadbild(erste, alsGruppe: true) {
            bildLaden(bild, url: url, schluessel: "dl-serie-\(erste.serienId ?? erste.id)",
                      sofort: true)
        } else {
            zeichenLegen(huelle, serie: true)
        }
        anhaengen(zeile, huelle)

        let text = stapel(GTK_ORIENTATION_VERTICAL, abstand: 3)
        gtk_widget_set_hexpand(text, 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        let name = beschriftung(titel, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        anhaengen(text, name)

        let bytes = folgen.reduce(Int64(0)) { $0 + $1.bytes }
        let unten = String(format: uebersetzt("%d Folgen"), folgen.count)
            + " · " + Downloadregeln.groesse(bytes)
        let zweit = beschriftung(unten, stil: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(zweit), 0)
        anhaengen(text, zweit)
        anhaengen(zeile, text)

        let spielen = nebenknopf("media-playback-start-symbolic", name: uebersetzt("Abspielen"))
        if let erste = folgen.first {
            beiSignal(spielen, "clicked") { [weak self] in self?.downloadSpielen(erste) }
        }
        gtk_widget_set_valign(spielen, GTK_ALIGN_CENTER)
        anhaengen(zeile, spielen)
        return zeile
    }

    private func downloadhaken(_ ids: [String]) -> Widget! {
        let haken: Widget! = gtk_check_button_new()
        gtk_widget_set_valign(haken, GTK_ALIGN_CENTER)
        let an = !ids.isEmpty && ids.allSatisfy { downloadgewaehlt.contains($0) }
        gtk_check_button_set_active(alsHaken(haken), an ? 1 : 0)
        // **`haken` wird stark gefasst, und das ist hier richtig.** Ein
        // Widget ist ein Zeiger, keine Klasse — `weak` gibt es dafuer nicht.
        // GTK haelt es, solange es in der Liste haengt, und der Rueckruf
        // stirbt mit ihm.
        beiSignal(haken, "toggled") { [weak self] in
            guard let self else { return }
            if gtk_check_button_get_active(alsHaken(haken)) != 0 {
                self.downloadgewaehlt.formUnion(ids)
            } else {
                self.downloadgewaehlt.subtract(ids)
            }
            gtk_widget_set_visible(self.downloadentfernen,
                                   self.downloadgewaehlt.isEmpty ? 0 : 1)
        }
        return haken
    }

    /// **Ein Knopf, sechs Zustaende** — dieselben Aussagen wie der Ring auf
    /// dem Mac, nur als Zeichenknopf, weil es hier keinen gezeichneten Ring
    /// gibt.
    private func downloadknopf(_ p: Downloadposten) -> Widget! {
        let (symbol, name, tat): (String, String, () -> Void)
        switch p.stand {
        case .wartet, .laedt:
            symbol = "media-playback-pause-symbolic"
            name = uebersetzt("Anhalten")
            tat = { [weak self] in self?.downloads.anhalten(p.id) }
        case .angehalten:
            symbol = "media-playback-start-symbolic"
            name = uebersetzt("Fortsetzen")
            tat = { [weak self] in self?.downloads.fortsetzen(p.id) }
        case .fehler:
            symbol = "view-refresh-symbolic"
            name = uebersetzt("Nochmal versuchen")
            tat = { [weak self] in self?.downloads.fortsetzen(p.id) }
        case .fertig:
            symbol = "media-playback-start-symbolic"
            name = uebersetzt("Abspielen")
            tat = { [weak self] in self?.downloadSpielen(p) }
        }
        let knopf = nebenknopf(symbol, name: name)
        gtk_widget_set_valign(knopf, GTK_ALIGN_CENTER)
        beiSignal(knopf, "clicked") { tat() }
        return knopf
    }

    private func downloadstandwort(_ p: Downloadposten) -> String {
        switch p.stand {
        case .wartet:     return uebersetzt("Wartet")
        case .laedt:
            guard p.bytes > 0 else { return Downloadregeln.groesse(p.geladen) }
            return Downloadregeln.groesse(p.geladen) + " / " + Downloadregeln.groesse(p.bytes)
        case .angehalten: return uebersetzt("Angehalten")
        case .fehler:     return p.grund ?? uebersetzt("Fehler")
        case .fertig:     return Downloadregeln.groesse(p.geladen)
        }
    }

    /// **Nur die Zahlen, nicht die Liste.** Waehrend eines Downloads meldet
    /// sich die Verwaltung einmal je Sekunde; die Liste dafuer jedes Mal neu
    /// zu bauen hiesse, dem Nutzer die Bildlaufstelle wegzuziehen und jedes
    /// Plakat neu zu laden.
    func downloadbalkenNachfuehren() {
        for p in downloads.posten {
            if let spur = downloadbalken[p.id], let anteil = p.anteil {
                gtk_progress_bar_set_fraction(OpaquePointer(spur), anteil)
            }
            if let zeile = downloadstandzeilen[p.id] {
                gtk_label_set_text(OpaquePointer(zeile), downloadstandwort(p))
            }
        }
        gtk_label_set_text(OpaquePointer(downloadbelegung), belegungszeile())
    }

    /// Das Bild kommt **von der Platte**, nicht vom Server — sonst waere die
    /// Seite in genau dem Fall leer, fuer den es sie gibt. Fehlt es, bleibt
    /// das Zeichen stehen.
    private func downloadbild(_ p: Downloadposten, alsGruppe: Bool = false) -> URL? {
        downloads.bild(fuer: p, alsGruppe: alsGruppe)
    }

    // MARK: Abspielen

    /// **Aus der Datei, nicht vom Server.**
    ///
    /// Der Player bekommt dieselbe `Item`-Form wie sonst — die baut
    /// `Downloadposten.alsItem` im Paket — und statt einer Serveradresse den
    /// Pfad auf der Platte. Alles Weitere ist derselbe Weg.
    func downloadSpielen(_ p: Downloadposten) {
        guard let pfad = downloads.datei(fuer: p.id) else { return }
        spielerOeffnen(p.alsItem, ab: 0, ausDatei: pfad)
    }
}
