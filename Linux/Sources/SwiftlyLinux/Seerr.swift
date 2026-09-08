import CGtk
import Foundation
import JellyfinKit

/// **Seerr — anfordern, was der Server nicht hat.**
///
/// Der Client liegt im Paket (`JellyfinKit.SeerrClient`) und ist
/// plattformunabhaengig; hier steht nur die Oberflaeche. Auf den
/// Apple-Fassungen ist das `Seerrmodell` plus vier Ansichten — die Aufteilung
/// ist dieselbe, nur in GTK gezeichnet.
extension App {

    /// Der Zugang, einmal aus der Ablage geholt.
    func seerrLaden() {
        seerrzugang = Speicher.seerrLesen()
        seerrclient = seerrzugang.map { SeerrClient(zugang: $0) }
    }

    var seerrDa: Bool { seerrclient != nil }

    // MARK: Einstellungen

    /// **Adresse und Schluessel, mehr braucht es nicht.**
    ///
    /// Woertlich die Felder der Apple-Fassung (`SeerrEinstellungenView`):
    /// die Adresse des Dienstes und ein API-Schluessel. Geprueft wird mit
    /// `gilt()`, damit ein Tippfehler hier auffaellt und nicht erst, wenn
    /// jemand etwas anfordern will.
    func seerrSeiteBauen(_ block: Widget!) {
        anhaengen(block, seerrKopf())

        let hinweis = beschriftung(
            uebersetzt("Jellyseerr oder Overseerr. Damit findest du in der Suche auch, was noch nicht auf deinem Server liegt — und kannst es anfragen."),
            stil: "swiftly-zweitzeile", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(hinweis), 0)
        gtk_widget_set_margin_bottom(hinweis, 18)
        anhaengen(block, hinweis)

        let adresse: Widget! = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(adresse), "seerr.example.com")
        if let z = seerrzugang { gtk_editable_set_text(OpaquePointer(adresse), z.adresse.absoluteString) }
        anhaengen(block, feldzeile(uebersetzt("Adresse"), adresse))

        let benutzer: Widget! = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(benutzer), uebersetzt("Benutzername"))
        gtk_editable_set_text(OpaquePointer(benutzer), benutzername)
        anhaengen(block, feldzeile(uebersetzt("Benutzername"), benutzer))

        let passwort: Widget! = gtk_entry_new()
        gtk_entry_set_visibility(alsFeld(passwort), 0)
        gtk_entry_set_placeholder_text(alsFeld(passwort), uebersetzt("Passwort"))
        anhaengen(block, feldzeile(uebersetzt("Passwort"), passwort))

        // **Das Passwort wird nicht gesichert** — nur die Sitzung, die Seerr
        // dafuer ausstellt. Woertlich die Zusage der Apple-Fassung, und sie
        // steht dort wie hier sichtbar auf der Seite, nicht nur im Quelltext.
        let zusage = beschriftung(
            uebersetzt("Dein Passwort wird nicht gespeichert — nur die Sitzung, die Seerr dafür ausstellt."),
            stil: "swiftly-zweitzeile", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(zusage), 0)
        gtk_widget_add_css_class(zusage, "dim-label")
        anhaengen(block, zusage)

        let stand = beschriftung("", stil: "swiftly-zweitzeile", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(stand), 0)
        gtk_widget_set_margin_top(stand, 12)
        gtk_widget_set_visible(stand, 0)
        anhaengen(block, stand)

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        gtk_widget_set_margin_top(reihe, 20)
        let standKiste = Zeigerkiste(stand)
        let aKiste = Zeigerkiste(adresse)
        let bKiste = Zeigerkiste(benutzer)
        let pKiste = Zeigerkiste(passwort)

        let verbinden = hauptknopf(uebersetzt("Verbinden"), symbol: "object-select-symbolic")
        beiSignal(verbinden, "clicked") { [weak self] in
            guard let self else { return }
            let roh = String(cString: gtk_editable_get_text(OpaquePointer(aKiste.widget)))
            let b = String(cString: gtk_editable_get_text(OpaquePointer(bKiste.widget)))
            let pw = String(cString: gtk_editable_get_text(OpaquePointer(pKiste.widget)))
            // **Eine Eingabe ergibt mehrere Adressen.** `Seerr.adressen` faechert
            // sie auf (mit und ohne Schema, mit und ohne Port) — dieselbe Regel
            // wie auf den Apple-Fassungen, im Paket und dort getestet.
            let adressen = Seerr.adressen(aus: roh)
            guard !adressen.isEmpty else {
                self.seerrStandZeigen(standKiste, uebersetzt("Diese Adresse ergibt keine."))
                return
            }
            guard !b.isEmpty, !pw.isEmpty else {
                self.seerrStandZeigen(standKiste, uebersetzt("Benutzername und Passwort fehlen"))
                return
            }
            self.seerrStandZeigen(standKiste, uebersetzt("Verbinde …"))
            Task.detached {
                var letzter: String?
                for url in adressen {
                    do {
                        let neu = try await SeerrClient.anmelden(an: url, benutzer: b, passwort: pw)
                        aufHauptfaden {
                            self.seerrzugang = neu
                            self.seerrclient = SeerrClient(zugang: neu)
                            Speicher.seerrSchreiben(neu)
                            // Das Passwortfeld wird geleert, sobald es nicht
                            // mehr gebraucht wird.
                            gtk_editable_set_text(OpaquePointer(pKiste.widget), "")
                            self.seerrStandZeigen(standKiste, uebersetzt("Verbunden"))
                        }
                        return
                    } catch {
                        letzter = error.localizedDescription
                    }
                }
                // **Erst festhalten, dann hinueberreichen.** Eine
                // veraenderliche Variable ueber die Fadengrenze zu greifen
                // laesst Swift 6 nicht zu — und zu Recht: der Block laeuft
                // spaeter.
                let meldung = letzter ?? uebersetzt("Keine Verbindung")
                aufHauptfaden {
                    self.seerrStandZeigen(standKiste, meldung)
                }
            }
        }
        anhaengen(reihe, verbinden)

        if seerrzugang != nil {
            let weg = nebenknopf("user-trash-symbolic", name: uebersetzt("Verbindung trennen"))
            beiSignal(weg, "clicked") { [weak self] in
                guard let self else { return }
                self.seerrzugang = nil
                self.seerrclient = nil
                Speicher.seerrSchreiben(nil)
                gtk_editable_set_text(OpaquePointer(aKiste.widget), "")
                gtk_editable_set_text(OpaquePointer(pKiste.widget), "")
                self.seerrStandZeigen(standKiste, uebersetzt("Getrennt"))
            }
            anhaengen(reihe, weg)
        }
        anhaengen(block, reihe)
    }

    /// Eigener Kopf statt `unterseitenkopf` — das ist dort privat, und eine
    /// Kopie der Datei waere schlimmer als drei Zeilen hier.
    private func seerrKopf() -> Widget! {
        let l = beschriftung(uebersetzt("Seerr"), stil: "swiftly-unterkopf")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_margin_bottom(l, 10)
        return l
    }

    private func seerrStandZeigen(_ kiste: Zeigerkiste, _ text: String) {
        gtk_label_set_text(OpaquePointer(kiste.widget), text)
        gtk_widget_set_visible(kiste.widget, 1)
    }

    /// Beschriftung ueber dem Feld — die Form der uebrigen Einstellungen.
    private func feldzeile(_ titel: String, _ feld: Widget!) -> Widget! {
        let stapelchen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 6)
        gtk_widget_set_margin_bottom(stapelchen, 14)
        let l = beschriftung(titel, stil: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        anhaengen(stapelchen, l)
        anhaengen(stapelchen, feld)
        return stapelchen
    }
}

// MARK: - Suche und Anfrage

extension App {

    /// Die Treffer aus Seerr unter die eigenen legen — oder beides verbergen.
    /// **Was schon auf dem Server liegt, wird hier nicht noch einmal
    /// gezeigt.** Ein Titel im Stand `da` steht bereits in den eigenen
    /// Treffern darueber — die Zeile „Anfragen ueber Seerr" darunter waere
    /// dieselbe Kachel ein zweites Mal, und beim Antippen kaeme eine
    /// Nachfrage fuer etwas, das niemand anfragen muss. Die Apple-Fassungen
    /// loesen das ueber zwei Bloecke; hier gibt es nur einen, also faellt
    /// der Stand ganz heraus.
    func seerrTrefferZeigen(_ treffer: [Seerrtreffer]) {
        guard seerrRaster != nil else { return }
        let fremde = treffer.filter { $0.stand != .da }
        let sichtbar = !fremde.isEmpty
        gtk_widget_set_visible(seerrUeberschrift, sichtbar ? 1 : 0)
        gtk_widget_set_visible(seerrRaster, sichtbar ? 1 : 0)
        leeren(seerrRaster)
        for t in fremde {
            gtk_flow_box_insert(OpaquePointer(seerrRaster), seerrKachel(t), -1)
        }
    }

    /// **Eine Kachel wie jede andere, plus die Marke.**
    ///
    /// Die Marke sagt, was mit dem Titel schon passiert ist: wartet,
    /// angefragt, teilweise. Ohne sie fragt man dreimal dasselbe an und
    /// wundert sich, dass nichts geschieht — genau dafuer gibt es
    /// `Seerrstand` im Paket.
    private func seerrKachel(_ t: Seerrtreffer) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-kachel")
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)

        let (huelle, bild) = gerahmtesBild(breite: Stil.kachelBreite,
                                           hoehe: Stil.kachelHoehe, stil: "swiftly-plakat")
        if let url = t.plakat() {
            bildLaden(bild, url: url, schluessel: "seerr-\(t.art)-\(t.id)", sofort: true)
        }
        if let wort = seerrMarkenwort(t.stand) {
            let marke = beschriftung(wort, stil: "swiftly-plakette")
            gtk_widget_add_css_class(marke, "swiftly-marke")
            gtk_widget_set_halign(marke, GTK_ALIGN_END)
            gtk_widget_set_valign(marke, GTK_ALIGN_START)
            gtk_widget_set_margin_top(marke, 6)
            gtk_widget_set_margin_end(marke, 6)
            gtk_overlay_add_overlay(OpaquePointer(huelle), marke)
        }
        anhaengen(block, huelle)

        let titel = beschriftung(t.titel, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(titel), 0)
        gtk_label_set_ellipsize(OpaquePointer(titel), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(titel), 1)
        anhaengen(block, titel)

        let unten = beschriftung(t.jahr.map { String($0) } ?? "", stil: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(unten), 0)
        anhaengen(block, unten)

        gtk_button_set_child(alsKnopf(knopf), block)
        beiSignal(knopf, "clicked") { [weak self] in self?.seerrAnfrageZeigen(t) }
        return knopf
    }

    /// Dieselbe Tabelle wie `Seerrstand.kurzwort` auf den Apple-Fassungen —
    /// **Wort fuer Wort, auch wo es sich falsch anfuehlt.**
    ///
    /// `laedt` heisst „angefragt", nicht „laedt". Der Stand bedeutet bei
    /// Seerr, dass die Anfrage durch ist und beim Beschaffer liegt; ob dort
    /// gerade etwas ueber die Leitung geht, weiss niemand. Seerrs eigene
    /// Oberflaeche nennt ihn ebenfalls „Requested". Auf dem Mac stand das
    /// schon einmal falsch und ist dort behoben; hier neu zu erfinden hiesse,
    /// denselben Fehler ein zweites Mal einzubauen.
    private func seerrMarkenwort(_ stand: Seerrstand) -> String? {
        switch stand {
        case .offen, .geloescht:    return nil
        case .wartetAufFreigabe:    return uebersetzt("wartet")
        case .laedt:                return uebersetzt("angefragt")
        case .teilweiseDa:          return uebersetzt("teilweise")
        case .da:                   return nil
        }
    }

    /// **Gefragt wird, bevor angefordert wird.**
    ///
    /// Eine Anfrage ist folgenreich: sie legt beim Server jemandes Arbeit an.
    /// Ein Klick, der das ohne Rueckfrage ausloest, ist derselbe Fehler wie
    /// ein Loeschknopf ohne Nachfrage.
    ///
    /// **Die Rueckfrage steht dort, wo geklickt wurde**, statt in einem
    /// Dialog. Einen Nachfragedialog gibt es in dieser Fassung nicht, und
    /// einen nebenbei einzufuehren waere ein Standardsteuerelement mitten in
    /// einer Oberflaeche, die bewusst keine benutzt (E4). Die Zeile
    /// erscheint unter der Ueberschrift, nennt den Titel und hat zwei
    /// Knoepfe — sie ist nicht zu uebersehen und nicht aus Versehen zu
    /// treffen.
    private func seerrAnfrageZeigen(_ t: Seerrtreffer) {
        guard t.stand.anfragbar, seerrRueckfrage != nil else { return }
        leeren(seerrRueckfrage)

        let text = t.istSerie
            ? String(format: uebersetzt("%@ mit allen Staffeln anfragen?"), t.titel)
            : String(format: uebersetzt("%@ anfragen?"), t.titel)
        let l = beschriftung(text, stil: "swiftly-koerper", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        anhaengen(seerrRueckfrage, l)

        let ja = chip(uebersetzt("Anfragen"), symbol: "object-select-symbolic", aktiv: true)
        beiSignal(ja, "clicked") { [weak self] in
            guard let self else { return }
            self.seerrAnfragen(t)
        }
        anhaengen(seerrRueckfrage, ja)

        let nein = chip(uebersetzt("Abbrechen"))
        beiSignal(nein, "clicked") { [weak self] in self?.seerrRueckfrageWeg() }
        anhaengen(seerrRueckfrage, nein)

        gtk_widget_set_visible(seerrRueckfrage, 1)
    }

    func seerrRueckfrageWeg() {
        guard seerrRueckfrage != nil else { return }
        leeren(seerrRueckfrage)
        gtk_widget_set_visible(seerrRueckfrage, 0)
    }

    /// Statt einer Kurzmeldung, die es hier nicht gibt: dieselbe Zeile sagt,
    /// was aus der Anfrage geworden ist, und bleibt stehen, bis der Naechste
    /// angetippt wird.
    private func seerrSagen(_ text: String) {
        guard seerrRueckfrage != nil else { return }
        leeren(seerrRueckfrage)
        let l = beschriftung(text, stil: "swiftly-koerper", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        anhaengen(seerrRueckfrage, l)
        gtk_widget_set_visible(seerrRueckfrage, 1)
    }

    private func seerrAnfragen(_ t: Seerrtreffer) {
        guard let client = seerrclient else { return }
        seerrSagen(uebersetzt("Wird angefragt …"))
        Task.detached {
            do {
                // `nil` heisst bei einer Serie „alle Staffeln"; der Client
                // setzt das um, die Regel steht dort.
                try await client.anfragen(art: t.art, id: t.id, staffeln: nil)
                aufHauptfaden { self.seerrSagen(uebersetzt("Angefragt")) }
            } catch {
                let meldung = error.localizedDescription
                aufHauptfaden { self.seerrSagen(meldung) }
            }
        }
    }
}
