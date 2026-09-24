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
            uebersetzt("Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen."),
            stil: "swiftly-zweitzeile", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(hinweis), 0)
        gtk_widget_set_margin_bottom(hinweis, 18)
        anhaengen(block, hinweis)

        // **Verbunden oder Formular, nicht beides.** Auf dem Mac steht an
        // dieser Stelle `if seerr.verbunden { verbunden } else { formular }`.
        // Hier stand immer das Formular — und damit gab es keinen Weg, eine
        // Verbindung wieder zu loesen: wer sich einmal angemeldet hatte,
        // konnte den Zugang nur noch ueberschreiben.
        if seerrDa, let zugang = seerrzugang {
            anhaengen(block, seerrVerbundenGruppe(zugang))
            return
        }

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

        // „Erweitert" — eigene Header fuer einen Dienst vor Seerr (Issue #4).
        let (erweitert, kopfleser) = erweitertBauen(vorhanden: [])
        gtk_widget_set_margin_bottom(erweitert, 14)
        anhaengen(block, erweitert)

        // **Das Passwort wird nicht gesichert** — nur die Sitzung, die Seerr
        // dafuer ausstellt. Woertlich die Zusage der Apple-Fassung, und sie
        // steht dort wie hier sichtbar auf der Seite, nicht nur im Quelltext.
        let zusage = beschriftung(
            uebersetzt("Swiftly speichert dein Passwort nicht, nur die Anmeldung bei Seerr."),
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
            let koepfe = kopfleser.koepfe()
            // **Eine Eingabe ergibt mehrere Adressen.** `Seerr.adressen` faechert
            // sie auf (mit und ohne Schema, mit und ohne Port) — dieselbe Regel
            // wie auf den Apple-Fassungen, im Paket und dort getestet.
            let adressen = Seerr.adressen(aus: roh)
            guard !adressen.isEmpty else {
                self.seerrStandZeigen(standKiste, uebersetzt("Das ist keine gültige Adresse."))
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
                        let neu = try await SeerrClient.anmelden(an: url, benutzer: b, passwort: pw,
                                                                 koepfe: koepfe)
                        aufHauptfaden {
                            self.seerrzugang = neu
                            self.seerrclient = SeerrClient(zugang: neu)
                            self.seerrGilt = true
                            Speicher.seerrSchreiben(neu)
                            // Das Passwortfeld wird geleert, sobald es nicht
                            // mehr gebraucht wird.
                            gtk_editable_set_text(OpaquePointer(pKiste.widget), "")
                            self.seerrStandZeigen(standKiste, uebersetzt("Verbunden"))
                        }
                        return
                    } catch {
                        letzter = lesbarerFehler(error)
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
        // **Kein gesperrter Knopf, sondern keiner** (`SeerrEinstellungenView`
        // auf dem Mac): solange Adresse, Benutzer und Passwort nicht
        // dastehen, ist nichts zu tun, und ein grauer Knopf behauptet das
        // Gegenteil. Er erscheint, sobald alle drei gefuellt sind.
        let knopfKiste = Zeigerkiste(verbinden)
        let nachfuehren: () -> Void = {
            let voll = [aKiste, bKiste, pKiste].allSatisfy {
                !String(cString: gtk_editable_get_text(OpaquePointer($0.widget)))
                    .trimmingCharacters(in: .whitespaces).isEmpty
            }
            gtk_widget_set_visible(knopfKiste.widget, voll ? 1 : 0)
        }
        for feld in [adresse, benutzer, passwort] {
            beiSignal(feld, "changed", nachfuehren)
        }
        nachfuehren()

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

    /// **Derselbe Kopf wie jede andere Unterseite.**
    ///
    /// Hier stand ein eigener aus drei Zeilen, weil `unterseitenkopf` privat
    /// war — und genau die eine Zeile fehlte darin, auf die es ankommt: der
    /// Zurueckpfeil. Die Seite war damit eine Sackgasse. Der Mac nimmt an
    /// derselben Stelle `Unterseitenkopf(titel:zurueck:)`
    /// (`Sources/macOS/SeerrEinstellungenView.swift:27`).
    private func seerrKopf() -> Widget! {
        let kopf = unterseitenkopf(uebersetzt("Seerr"))
        gtk_widget_set_margin_bottom(kopf, 10)
        return kopf
    }

    private func seerrStandZeigen(_ kiste: Zeigerkiste, _ text: String) {
        gtk_label_set_text(OpaquePointer(kiste.widget), text)
        gtk_widget_set_visible(kiste.widget, 1)
    }

    /// **Was steht, wenn es steht.** Adresse, Zustand der Sitzung, und der
    /// Weg hinaus.
    ///
    /// „Verbindung trennen", nicht „Abmelden" — wortgleich vom Mac, samt
    /// Begruendung: bei Seerr selbst bleibt alles, wie es ist; es geht nur um
    /// diesen einen Zugang hier.
    private func seerrVerbundenGruppe(_ zugang: Seerrzugang) -> Widget! {
        let g = einstellungsgruppe(uebersetzt("Verbunden"))
        let wort: String
        switch seerrGilt {
        case .some(true):  wort = uebersetzt("Aktiv")
        case .some(false): wort = uebersetzt("Sitzung abgelaufen")
        case nil:          wort = uebersetzt("Wird geprüft …")
        }
        anhaengen(g.raum, wertezeile(symbol: "network-transmit-receive-symbolic",
                                     titel: zugang.adresse.absoluteString,
                                     wert: wort))
        anhaengen(g.raum, zeilenstrich())
        anhaengen(g.raum, wertezeile(symbol: "window-close-symbolic",
                                     titel: uebersetzt("Verbindung trennen")) { [weak self] in
            guard let self else { return }
            // Erst den Keks der Verbindung, dann den Zugang: sonst bleibt die
            // Sitzung gueltig und der naechste Anmeldeversuch bekommt keine
            // neue (`Seerr.kekseVergessen`).
            if let adresse = self.seerrzugang?.adresse { Seerr.kekseVergessen(fuer: adresse) }
            self.seerrzugang = nil
            self.seerrclient = nil
            self.seerrGilt = nil
            Speicher.seerrSchreiben(nil)
            // Die Suche zeigt sonst weiter die fremden Treffer der letzten
            // Abfrage — die kommen von einem Dienst, der nicht mehr
            // angebunden ist.
            self.seerrTrefferZeigen([])
            self.unterseiteOeffnen(.seerr)
        })

        // **Ob die Sitzung noch traegt, weiss nur der Dienst.** Der Keks
        // laeuft ab, und ein Zugang, der dasteht und nicht mehr gilt, ist
        // schlimmer als keiner: die Suche bliebe still leer.
        //
        // Geprueft wird einmal je Besuch, und das Ergebnis baut die Seite an
        // Ort und Stelle neu — denselben Weg nehmen hier alle Auswahllisten.
        // Ein Zeiger auf die Wertbeschriftung ueber eine Fadengrenze waere
        // die andere Moeglichkeit und die schlechtere.
        if let client = seerrclient, seerrGilt == nil {
            Task.detached { [self] in
                let gilt = await client.gilt()
                aufHauptfaden {
                    guard self.offeneUnterseite == .seerr else { return }
                    self.seerrGilt = gilt
                    self.unterseiteOeffnen(.seerr)
                }
            }
        }
        return g.aussen
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
        gtk_widget_set_visible(seerrKopfzeile, sichtbar ? 1 : 0)
        gtk_widget_set_visible(seerrRaster, sichtbar ? 1 : 0)
        gtk_label_set_text(OpaquePointer(seerrZahl), String(fremde.count))
        // Erst wenn auch Seerr nichts hat, gilt „Nichts gefunden".
        seerrTrefferLeer = fremde.isEmpty
        if suchleer != nil {
            gtk_widget_set_visible(suchleer, eigeneTrefferLeer && fremde.isEmpty ? 1 : 0)
        }
        rasterLeeren(seerrRaster)
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
    func seerrKachel(_ t: Seerrtreffer) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-kachel")
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)

        let (huelle, bild) = gerahmtesBild(breite: Stil.kachelBreite,
                                           hoehe: Stil.kachelHoehe, stil: "swiftly-plakat")
        if let url = t.plakat() {
            bildLaden(bild, url: url, schluessel: "seerr-\(t.art)-\(t.id)", sofort: true)
        }
        // **Blass, und das ist die ganze Auskunft.** Ein Plakat in voller
        // Deckung sieht aus wie ein Titel, den der Server hat
        // (`Sources/macOS/SeerrKachelUndSeite.swift:17-20`). Hier fehlte das
        // eine Merkmal, an dem man auf den ersten Blick sieht, dass er es
        // nicht ist.
        gtk_widget_set_opacity(huelle, 0.45)
        // **Unten links, nicht oben rechts** — `:19`, `.bottomLeading` mit 8
        // Innenrand. Und gefuellt in der Farbe des Standes, nicht als
        // umrandete Plakette: `swiftly-marke` war eine Klasse, die es im
        // Stilblatt gar nicht gab, also sahen „wartet", „angefragt" und
        // „teilweise" identisch aus.
        if let wort = seerrMarkenwort(t.stand) {
            let marke = beschriftung(wort, stil: "swiftly-marke")
            gtk_widget_add_css_class(marke, seerrMarkenstil(t.stand))
            gtk_widget_set_halign(marke, GTK_ALIGN_START)
            gtk_widget_set_valign(marke, GTK_ALIGN_END)
            gtk_widget_set_margin_bottom(marke, 8)
            gtk_widget_set_margin_start(marke, 8)
            gtk_overlay_add_overlay(OpaquePointer(huelle), marke)
        }
        anhaengen(block, huelle)

        // Innen 1 Punkt Abstand, Titel `kachelTitel` in `schriftLeise`, die
        // Zweitzeile in `schriftSehrLeise` — `:24-31`. Hier stand der Titel in
        // vollem Weiss und derselben Groesse wie ein Fliesstext.
        let textblock = stapel(GTK_ORIENTATION_VERTICAL, abstand: 1)
        let titel = beschriftung(t.titel, stil: "swiftly-kacheltitel")
        gtk_widget_add_css_class(titel, "dim-label")
        gtk_label_set_xalign(OpaquePointer(titel), 0)
        gtk_label_set_ellipsize(OpaquePointer(titel), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(titel), 1)
        anhaengen(textblock, titel)

        // „2019 · Serie", nicht nur die Jahreszahl — `:50-53`.
        let art = t.istSerie ? uebersetzt("Serie") : uebersetzt("Film")
        let unten = beschriftung(t.jahr.map { "\($0) · \(art)" } ?? art,
                                 stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(unten, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(unten), 0)
        anhaengen(textblock, unten)
        anhaengen(block, textblock)

        gtk_button_set_child(alsKnopf(knopf), block)
        // **Erst die Seite, dann die Anfrage.** Vorher loeste ein Tipp
        // sofort die Rueckfrage aus — ohne dass man wusste, worum es geht,
        // wie lang es ist oder welche Staffeln es gibt.
        beiSignal(knopf, "clicked") { [weak self] in self?.seerrSeiteOeffnen(t) }
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
    /// Die Farbe der Marke, als Stilklasse. Dieselben Werte wie
    /// `Seerrstand.farbe` auf Apple (`Sources/Shared/Seerrmarke.swift:63-68`).
    private func seerrMarkenstil(_ stand: Seerrstand) -> String {
        switch stand {
        case .wartetAufFreigabe: return "swiftly-marke-wartet"
        case .laedt:             return "swiftly-marke-laedt"
        default:                 return "swiftly-marke-akzent"
        }
    }

    private func seerrMarkenwort(_ stand: Seerrstand) -> String? {
        switch stand {
        case .offen, .geloescht:    return nil
        case .wartetAufFreigabe:    return uebersetzt("wartet")
        case .laedt:                return uebersetzt("angefragt")
        case .teilweiseDa:          return uebersetzt("teilweise")
        case .da:                   return nil
        }
    }}
