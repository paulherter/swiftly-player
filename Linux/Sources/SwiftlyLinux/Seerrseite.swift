import CGtk
import Foundation
import JellyfinKit

/// **Die Seerr-Seite — dieselbe Detailseite, nur mit fremden Daten.**
///
/// Es gab sie hier gar nicht: ein Tipp auf eine Kachel loeste sofort die
/// Rueckfrage aus, ob angefragt werden soll. Damit fehlte alles, was man vor
/// einer Anfrage wissen will — worum es geht, wie lang es ist, wie es
/// bewertet ist, welche Staffeln es gibt, wer mitspielt.
///
/// **Sie ist die Detailseite Zeile fuer Zeile**, nicht eine zweite Sorte
/// Seite daneben. Genau das war auf dem iPhone dreimal in Folge der Fehler
/// (Zeile 64 der Aenderungsliste): der Kopf war nachgebaut statt genommen,
/// und dadurch stand oben ein Verlauf, den es auf der echten Seite nicht
/// gibt. Hier also derselbe `detailkopfBauen`, dieselbe `Kulisse`, dasselbe
/// Fach-Raster im Heldenblock, dieselbe `reihe`-Ueberschrift fuer Besetzung
/// und Aehnliches.
///
/// Verschieden sind nur zwei Dinge, und beide haben mit der Quelle zu tun:
/// die Bilder kommen von TMDB statt vom eigenen Server, und statt
/// „Abspielen" steht dort der Knopf, der anfragt.
extension App {

    // MARK: Oeffnen

    /// **Sie faehrt herein wie eine Titelseite, nicht wie eine
    /// Einstellung.** Ein Seerr-Titel ist eine Ebene tiefer, kein Ort
    /// daneben — deshalb `Schub.tiefer` und der Pfeil zurueck oben links.
    ///
    /// Der Seitenstapel haelt `Item`, und ein Seerr-Treffer ist keines; die
    /// Seite liegt deshalb auf der Scheibe der Unterseiten. Zurueck fuehrt
    /// von dort auf den Bereich, aus dem sie geoeffnet wurde.
    func seerrSeiteOeffnen(_ t: Seerrtreffer) {
        seerrGewaehlteStaffeln = []
        let scheibe: Widget! = naechsteScheibe()
        // **Keine der Einstellungsunterseiten** — sonst hielte ein zweiter
        // Aufruf sie fuer dieselbe und baute an Ort und Stelle um, statt
        // hereinzufahren.
        offeneUnterseite = nil
        anhaengen(scheibe, seerrDetailBauen(t))
        schieben(zu: scheibe, richtung: .tiefer)
        seerrDetailNachladen(t)
    }

    // MARK: Aufbau

    private func seerrDetailBauen(_ t: Seerrtreffer) -> Widget! {
        let scroller = seitenscroller()
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)

        anhaengen(block, seerrHeldenkopf(t))

        seerrBlock = stapel(GTK_ORIENTATION_VERTICAL, abstand: 30)
        gtk_widget_set_margin_start(seerrBlock, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(seerrBlock, Int32(Stil.randAbstand))
        gtk_widget_set_margin_top(seerrBlock, 22)
        gtk_widget_set_margin_bottom(seerrBlock, 40)
        anhaengen(block, seerrBlock)

        gtk_scrolled_window_set_child(OpaquePointer(scroller), block)

        let ueber: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(ueber), scroller)
        gtk_overlay_add_overlay(OpaquePointer(ueber), seerrKopfleiste(t))
        return ueber
    }

    /// Derselbe Kopf wie auf der Detailseite — Pfeil zurueck, weicher
    /// Verlauf. Nicht nachgebaut: `detailkopfBauen` nimmt ein `Item`, und
    /// eines gibt es hier nicht; die Masse sind darum von dort abgelesen und
    /// stehen an genau einer weiteren Stelle.
    private func seerrKopfleiste(_ t: Seerrtreffer) -> Widget! {
        let kopf: Widget! = gtk_overlay_new()
        gtk_widget_set_valign(kopf, GTK_ALIGN_START)
        gtk_widget_set_halign(kopf, GTK_ALIGN_FILL)

        let verlauf: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_add_css_class(verlauf, "swiftly-kopfverlauf")
        gtk_widget_set_size_request(verlauf, -1, 74)
        gtk_overlay_set_child(OpaquePointer(kopf), verlauf)

        let leiste = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 4)
        gtk_widget_set_valign(leiste, GTK_ALIGN_START)
        gtk_widget_set_margin_start(leiste, Int32(Stil.randAbstand - 8))
        gtk_widget_set_margin_top(leiste, 24)

        let pfeil: Widget! = gtk_button_new()
        gtk_widget_add_css_class(pfeil, "swiftly-zurueck")
        gtk_button_set_child(alsKnopf(pfeil), gtk_image_new_from_icon_name("go-previous-symbolic"))
        beiSignal(pfeil, "clicked") { [weak self] in self?.unterseiteZurueck() }
        anhaengen(leiste, pfeil)

        gtk_overlay_add_overlay(OpaquePointer(kopf), leiste)
        return kopf
    }

    /// Kulisse rechts, Block links — `heldenkopf` mit TMDB-Bild.
    private func seerrHeldenkopf(_ t: Seerrtreffer) -> Widget! {
        let kopf: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(kopf, 1)

        let bild = Kulisse()
        gtk_overlay_set_child(OpaquePointer(kopf), bild.anzeige)
        gtk_overlay_add_overlay(OpaquePointer(kopf), seerrHeldenblock(t))

        // **Die Kulisse braucht das Querbild, nicht das Plakat.** Auf dem
        // Fernseher fehlte es einmal ganz, weil nur der gefaerbte Grund
        // gesetzt wurde; hier also ausdruecklich `kulisse()`.
        if let gross = t.kulisse(breite: 1280) {
            Task.detached {
                guard let daten = await Bildlager.shared.laden(
                    gross, schluessel: gross.absoluteString) else { return }
                aufHauptfaden { bild.setzen(daten) }
            }
        }
        return kopf
    }

    /// Dieselben vier Faecher wie `heldenblock`: Titel 0/42, Angaben 54/20,
    /// Beschreibung 92/66, Knopfreihe 182/48.
    private func seerrHeldenblock(_ t: Seerrtreffer) -> Widget! {
        let feld: Widget! = gtk_fixed_new()
        gtk_widget_set_halign(feld, GTK_ALIGN_START)
        gtk_widget_set_valign(feld, GTK_ALIGN_START)
        gtk_widget_set_size_request(feld, 640, 230)
        gtk_widget_set_margin_start(feld, Int32(Stil.randAbstand))
        gtk_widget_set_margin_top(feld, Int32(Stil.titelHoehe + 98 - Stil.kopfzeileHoehe))

        let name = beschriftung(t.titel, stil: "swiftly-heldtitel")
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_fixed_put(alsFeld2(feld), fach(name, breite: 640, hoehe: 42), 0, 0)

        seerrAngaben = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        seerrAngabenFuellen(t, nil)
        gtk_fixed_put(alsFeld2(feld), fach(seerrAngaben, breite: 640, hoehe: 20), 0, 54)

        seerrHandlung = beschriftung("", stil: "swiftly-koerper", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(seerrHandlung), 0)
        gtk_label_set_yalign(OpaquePointer(seerrHandlung), 0)
        gtk_label_set_lines(OpaquePointer(seerrHandlung), 3)
        gtk_label_set_ellipsize(OpaquePointer(seerrHandlung), PANGO_ELLIPSIZE_END)
        gtk_widget_add_css_class(seerrHandlung, "swiftly-beschreibung")
        gtk_fixed_put(alsFeld2(feld), fach(seerrHandlung, breite: 640, hoehe: 66,
                                           senkrecht: GTK_ALIGN_START), 0, 92)

        seerrKnopfreihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        seerrKnopfreiheFuellen(t)
        gtk_fixed_put(alsFeld2(feld), fach(seerrKnopfreihe, breite: 640,
                                           hoehe: Stil.hauptknopfHoehe), 0, 182)
        return feld
    }

    // MARK: Angaben und Knopf

    /// Jahr, Laufzeit, Genres, Bewertung — **eine** Zeile, wie auf der
    /// Detailseite. Was Seerr noch nicht geliefert hat, fehlt einfach; die
    /// Zeile wird nachgefuellt, sobald die Antwort da ist.
    private func seerrAngabenFuellen(_ t: Seerrtreffer, _ d: Seerrdetail?) {
        guard seerrAngaben != nil else { return }
        leeren(seerrAngaben)
        var stuecke: [String] = []
        if let j = t.jahr { stuecke.append(String(j)) }
        if let min = d?.laufzeit, min > 0 {
            stuecke.append(String(format: uebersetzt("%d Min."), min))
        }
        if let g = d?.genres, !g.isEmpty { stuecke.append(g.prefix(2).joined(separator: ", ")) }
        if let b = d?.bewertung, b > 0 {
            stuecke.append(komma(b))
        }
        for (i, s) in stuecke.enumerated() {
            if i > 0 {
                let punkt = beschriftung("·", stil: "swiftly-zweitzeile")
                gtk_widget_add_css_class(punkt, "swiftly-sehrleise")
                anhaengen(seerrAngaben, punkt)
            }
            anhaengen(seerrAngaben, beschriftung(s, stil: "swiftly-zweitzeile"))
        }
    }

    /// **Der Knopf sagt, was gilt** — nicht immer „Anfragen".
    ///
    /// Fünf Stände, fünf Beschriftungen; wortgleich `Seerrstand.wort` auf den
    /// Apple-Fassungen, und wo es nichts zu druecken gibt, steht statt eines
    /// toten Knopfes der Satz aus `Seerrstand.hinweis`.
    private func seerrKnopfreiheFuellen(_ t: Seerrtreffer) {
        guard seerrKnopfreihe != nil else { return }
        leeren(seerrKnopfreihe)

        guard t.stand.anfragbar else {
            let wort = beschriftung(seerrStandwort(t.stand), stil: "swiftly-koerper")
            gtk_widget_add_css_class(wort, "swiftly-leise")
            gtk_widget_set_valign(wort, GTK_ALIGN_CENTER)
            anhaengen(seerrKnopfreihe, wort)
            return
        }

        let titel = t.istSerie && !seerrGewaehlteStaffeln.isEmpty
            ? String(format: uebersetzt("%d Staffeln anfragen"), seerrGewaehlteStaffeln.count)
            : uebersetzt("Anfragen")
        let knopf = hauptknopf(titel, symbol: "folder-download-symbolic")
        gtk_widget_set_size_request(knopf, Int32(Stil.hauptknopfBreite),
                                    Int32(Stil.hauptknopfHoehe))
        beiSignal(knopf, "clicked") { [weak self] in self?.seerrAnfragenVonSeite(t) }
        anhaengen(seerrKnopfreihe, knopf)
    }

    private func seerrStandwort(_ stand: Seerrstand) -> String {
        switch stand {
        case .offen, .geloescht:  return uebersetzt("Nicht auf deinem Server")
        case .wartetAufFreigabe:  return uebersetzt("Wartet auf Freigabe")
        case .laedt:              return uebersetzt("Angefragt")
        case .teilweiseDa:        return uebersetzt("Teilweise vorhanden")
        case .da:                 return uebersetzt("Auf deinem Server")
        }
    }

    // MARK: Nachladen

    private func seerrDetailNachladen(_ t: Seerrtreffer) {
        guard let client = seerrclient else { return }
        Task.detached { [self] in
            let d = await client.detail(art: t.art, id: t.id)
            aufHauptfaden {
                guard let d else { return }
                self.seerrAngabenFuellen(t, d)
                if let text = d.beschreibung, !text.isEmpty {
                    gtk_label_set_text(OpaquePointer(self.seerrHandlung), text)
                }
                self.seerrUnterbauFuellen(t, d)
            }
        }
    }

    /// Staffeln, Besetzung, Aehnliches — in dieser Reihenfolge, wie auf dem
    /// Mac.
    private func seerrUnterbauFuellen(_ t: Seerrtreffer, _ d: Seerrdetail) {
        guard seerrBlock != nil else { return }
        leeren(seerrBlock)

        if t.istSerie, !d.staffeln.isEmpty {
            anhaengen(seerrBlock, seerrStaffelliste(t, d))
        }
        if !d.besetzung.isEmpty {
            anhaengen(seerrBlock, seerrPersonenreihe(uebersetzt("Besetzung"), d.besetzung))
        }
        if !d.aehnliches.isEmpty {
            anhaengen(seerrBlock, seerrTitelreihe(uebersetzt("Ähnliche Titel"), d.aehnliches, t))
        }
    }

    /// **Staffeln werden gewaehlt, nicht angenommen.** Vorher schickte die
    /// Anfrage `staffeln: nil`, also stillschweigend alle — bei einer Serie
    /// mit hundert Folgen ist das kein Detail.
    private func seerrStaffelliste(_ t: Seerrtreffer, _ d: Seerrdetail) -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)
        anhaengen(block, beschriftung(uebersetzt("Welche Staffeln?"), stil: "swiftly-reihe"))

        let raum = zeilengruppe()
        for (i, st) in d.staffeln.enumerated() where !st.istSpecials {
            if i > 0 { anhaengen(raum.raum, zeilenstrich()) }
            let gewaehlt = seerrGewaehlteStaffeln.contains(st.nummer)
            let name = String(format: uebersetzt("Staffel %d"), st.nummer)
            let unter = String(format: uebersetzt("%d Folgen"), st.folgen)
            let zeile = wertezeile(symbol: gewaehlt ? "object-select-symbolic" : "tv-symbolic",
                                   titel: name, unter: unter,
                                   wert: st.stand.schonDa ? uebersetzt("Auf deinem Server") : nil,
                                   akzent: gewaehlt) { [weak self] in
                guard let self, !st.stand.schonDa else { return }
                if gewaehlt { self.seerrGewaehlteStaffeln.remove(st.nummer) }
                else { self.seerrGewaehlteStaffeln.insert(st.nummer) }
                self.seerrKnopfreiheFuellen(t)
                self.seerrUnterbauFuellen(t, d)
            }
            anhaengen(raum.raum, zeile)
        }
        anhaengen(block, raum.aussen)
        return block
    }

    private func seerrPersonenreihe(_ titel: String, _ leute: [Seerrperson]) -> Widget! {
        var kacheln: [Widget?] = []
        for person in leute.prefix(20) {
            let kachel = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)
            gtk_widget_set_size_request(kachel, 110, -1)
            let (huelle, bild) = gerahmtesBild(breite: 110, hoehe: 110, stil: "swiftly-rund")
            if let url = person.bild(breite: 220) {
                bildLaden(bild, url: url, schluessel: "seerr-person-\(person.id)", sofort: true)
            }
            anhaengen(kachel, huelle)
            let n = beschriftung(person.name, stil: "swiftly-koerper")
            gtk_label_set_ellipsize(OpaquePointer(n), PANGO_ELLIPSIZE_END)
            gtk_label_set_xalign(OpaquePointer(n), 0)
            anhaengen(kachel, n)
            if let rolle = person.rolle, !rolle.isEmpty {
                let r = beschriftung(rolle, stil: "swiftly-zweitzeile")
                gtk_label_set_ellipsize(OpaquePointer(r), PANGO_ELLIPSIZE_END)
                gtk_label_set_xalign(OpaquePointer(r), 0)
                anhaengen(kachel, r)
            }
            kacheln.append(kachel)
        }
        return reiheBauen(titel: titel, bildHoehe: 110, stueck: 110 + Stil.kachelAbstand,
                          rand: 0, kacheln: kacheln)
    }

    /// **Die Kacheln sind Knoepfe.** Auf dem Fernseher waren sie es einmal
    /// nicht, und dann kam man an „Aehnliches" gar nicht heran.
    private func seerrTitelreihe(_ titel: String, _ treffer: [Seerrtreffer],
                                 _ herkunft: Seerrtreffer) -> Widget! {
        // **Die Art fehlt bei Vorschlaegen** — die Seite weiss ja, was sie
        // ist. Ohne diesen Rueckfall kaeme dort nie ein Treffer an.
        let kacheln: [Widget?] = treffer.prefix(20).map {
            seerrKachel($0.art.isEmpty ? herkunft : $0)
        }
        return reiheBauen(titel: titel, bildHoehe: Stil.kachelHoehe,
                          stueck: Stil.kachelBreite + Stil.kachelAbstand,
                          rand: 0, kacheln: kacheln)
    }

    // MARK: Anfragen

    private func seerrAnfragenVonSeite(_ t: Seerrtreffer) {
        guard let client = seerrclient else { return }
        let staffeln = t.istSerie && !seerrGewaehlteStaffeln.isEmpty
            ? Array(seerrGewaehlteStaffeln).sorted() : nil
        melden(uebersetzt("Wird angefragt …"))
        Task.detached { [self] in
            do {
                try await client.anfragen(art: t.art, id: t.id, staffeln: staffeln)
                aufHauptfaden { self.melden(uebersetzt("Angefragt")) }
            } catch {
                let text = error.localizedDescription
                aufHauptfaden { self.melden(text) }
            }
        }
    }
}
