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
                case let .serie(sid, titel, folgen):
                    anhaengen(downloadliste, downloadseriezeile(sid, titel, folgen))
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
        // **Und was noch frei ist.** Der Mac nennt es in derselben Zeile;
        // ohne die Zahl steht dort eine Belegung ohne Bezugsgroesse.
        return anzahl + " · " + Downloadregeln.groesse(b.bytes)
            + " · " + Downloadregeln.groesse(downloads.freierPlatz)
            + " " + uebersetzt("frei")
    }

    // MARK: Eine Zeile

    /// **Die Masse kommen vom Mac, nicht aus dem Gefuehl.** Eine Folge liegt
    /// quer (142 x 80), ein Film und eine Serienzeile hochkant (76 x 114) —
    /// `MacDownloadzeile.quer`. Hier stand vorher 96 x 54 fuer alles.
    private func downloadzeile(_ p: Downloadposten) -> Widget! {
        let quer = p.art == .folge
        return downloadgrundzeile(
            titel: p.titel,
            unten: downloadstandwort(p),
            warnend: p.stand == .fehler,
            quer: quer,
            bild: downloadbild(p),
            serie: quer,
            ids: [p.id],
            // **Der Balken nur, solange etwas laeuft oder angehalten ist.**
            // Bei „wartet" gibt es nichts zu zeigen, und auf einem Fehler
            // sieht ein halb gefuellter Balken aus wie Fortschritt.
            anteil: (p.stand == .laedt || p.stand == .angehalten) ? p.anteil : nil,
            kennung: p.id,
            rechts: downloadknopf(p),
            // **Ein Klick auf die Zeile spielt ab** — auf dem Mac stand
            // dazu: „Das fehlte ganz." Abspielen und nicht die Detailseite,
            // denn die braucht den Server, und wer hier steht, hat
            // womoeglich keinen (H8).
            geklickt: { [weak self] in
                guard let self else { return }
                if self.downloadbearbeiten { self.downloadhakenUmlegen([p.id]) }
                else if p.stand == .fertig { self.downloadSpielen(p) }
            })
    }

    /// H12: eine Serie ist **eine** Zeile — und sie klappt auf, wie auf dem
    /// Mac. Vorher lag hier ein Abspielknopf, der stillschweigend die erste
    /// Folge nahm; an die uebrigen kam man gar nicht heran.
    private func downloadseriezeile(_ sid: String, _ titel: String,
                                    _ folgen: [Downloadposten]) -> Widget! {
        let offen = downloadOffeneSerien.contains(sid)
        let bytes = folgen.reduce(Int64(0)) { $0 + $1.bytes }
        let unten = String(format: uebersetzt("%d Folgen"), folgen.count)
            + " · " + Downloadregeln.groesse(bytes)

        let winkel = nebenknopf(offen ? "pan-down-symbolic" : "pan-end-symbolic",
                                name: offen ? uebersetzt("Zuklappen") : uebersetzt("Aufklappen"))
        gtk_widget_set_valign(winkel, GTK_ALIGN_CENTER)

        let kopf = downloadgrundzeile(
            titel: titel, unten: unten, warnend: false, quer: false,
            bild: folgen.first.flatMap { downloadbild($0, alsGruppe: true) },
            serie: true,
            ids: folgen.map(\.id),
            anteil: nil, kennung: nil, rechts: winkel,
            geklickt: { [weak self] in
                guard let self else { return }
                if self.downloadbearbeiten { self.downloadhakenUmlegen(folgen.map(\.id)) }
                else { self.downloadSerieUmlegen(sid) }
            })

        guard offen else { return kopf }

        // Aufgeklappt: die Folgen darunter, eingerueckt.
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        anhaengen(block, kopf)
        for f in folgen {
            let z = downloadzeile(f)
            gtk_widget_set_margin_start(z, 34)
            anhaengen(block, z)
        }
        return block
    }

    private func downloadSerieUmlegen(_ sid: String) {
        if downloadOffeneSerien.contains(sid) { downloadOffeneSerien.remove(sid) }
        else { downloadOffeneSerien.insert(sid) }
        downloadseiteFuellen()
    }

    private func downloadhakenUmlegen(_ ids: [String]) {
        if ids.allSatisfy({ downloadgewaehlt.contains($0) }) {
            downloadgewaehlt.subtract(ids)
        } else {
            downloadgewaehlt.formUnion(ids)
        }
        downloadseiteFuellen()
    }

    /// Der gemeinsame Rumpf beider Zeilen — Haken, Bild, Text, Balken,
    /// rechter Knopf. Eine Zeile, nicht zwei fast gleiche.
    private func downloadgrundzeile(titel: String, unten: String, warnend: Bool,
                                    quer: Bool, bild: URL?, serie: Bool,
                                    ids: [String], anteil: Double?,
                                    kennung: String?, rechts: Widget!,
                                    geklickt: @escaping () -> Void) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-zeile")
        beiSignal(knopf, "clicked") { geklickt() }

        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 16)
        gtk_widget_set_margin_top(zeile, 12)
        gtk_widget_set_margin_bottom(zeile, 12)
        gtk_widget_set_margin_start(zeile, 10)
        gtk_widget_set_margin_end(zeile, 10)

        if downloadbearbeiten { anhaengen(zeile, downloadhaken(ids)) }

        let (huelle, feld) = gerahmtesBild(breite: quer ? 142 : 76,
                                           hoehe: quer ? 80 : 114, stil: "swiftly-plakat")
        if let bild {
            bildLaden(feld, url: bild, schluessel: "dl-\(ids.first ?? titel)", sofort: true)
        } else {
            zeichenLegen(huelle, serie: serie)
        }
        anhaengen(zeile, huelle)

        let text = stapel(GTK_ORIENTATION_VERTICAL, abstand: 4)
        gtk_widget_set_hexpand(text, 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        let t = beschriftung(titel, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(t), 0)
        gtk_label_set_ellipsize(OpaquePointer(t), PANGO_ELLIPSIZE_END)
        anhaengen(text, t)

        let u = beschriftung(unten, stil: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(u), 0)
        gtk_label_set_ellipsize(OpaquePointer(u), PANGO_ELLIPSIZE_END)
        if warnend { gtk_widget_add_css_class(u, "swiftly-warnung") }
        anhaengen(text, u)
        if let kennung { downloadstandzeilen[kennung] = u }

        if let anteil {
            let spur: Widget! = gtk_progress_bar_new()
            gtk_progress_bar_set_fraction(OpaquePointer(spur), anteil)
            gtk_widget_add_css_class(spur, "swiftly-fortschritt")
            gtk_widget_set_margin_top(spur, 4)
            anhaengen(text, spur)
            if let kennung { downloadbalken[kennung] = spur }
        }
        anhaengen(zeile, text)
        anhaengen(zeile, rechts)

        gtk_button_set_child(alsKnopf(knopf), zeile)
        return knopf
    }

    /// **Kein `GtkCheckButton`.** Diese Oberflaeche benutzt keine
    /// Standardsteuerelemente (E4) — sie zeichnet ihre Schalter selbst, und
    /// ueberall sonst steht dafuer `object-select-symbolic` in einer eigenen
    /// Kapsel. Hier stand eine Runde lang das GTK-Kaestchen, und das ist
    /// derselbe Fehler wie ein Systemdialog mitten in der App.
    private func downloadhaken(_ ids: [String]) -> Widget! {
        let an = !ids.isEmpty && ids.allSatisfy { downloadgewaehlt.contains($0) }
        let haken = nebenknopf("object-select-symbolic",
                               name: an ? uebersetzt("Abwählen") : uebersetzt("Auswählen"),
                               aktiv: an)
        gtk_widget_set_valign(haken, GTK_ALIGN_CENTER)
        beiSignal(haken, "clicked") { [weak self] in self?.downloadhakenUmlegen(ids) }
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
        if let da = downloads.bild(fuer: p, alsGruppe: alsGruppe) { return da }
        // **Und sonst vom Server** — solange einer da ist. Der Mac faellt an
        // derselben Stelle auf `plakatURL` zurueck; ohne das bliebe die
        // Flaeche leer, obwohl das Bild eine Leitung weit weg liegt.
        return adressen?.bauen(itemID: alsGruppe ? (p.serienId ?? p.id) : p.id,
                               mass: .hoechstensHoch(300))
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
