import CGtk
import Foundation
import JellyfinKit

/// Profil, Quick Connect, Wiedergabe, Einstellungen.
///
/// Aufbau, Reihenfolge und Texte wörtlich aus `Sources/macOS/ProfilView.swift`,
/// `EinstellungenView.swift` und `WiedergabeEinstellungenView.swift`. Die
/// Seiten sind im Fenster schmal gehalten (560) — über die volle Breite
/// gezogen stünden Symbol und Wert einen halben Meter auseinander.
///
/// **Wie viele Seiten die Einstellungen haben, darf sich unterscheiden**
/// (VERHALTEN.md F): iPhone, iPad und Mac führen Profil, Einstellungen und
/// Wiedergabe getrennt, der Fernseher hat eine Seite. Linux folgt dem Mac.
extension App {

    enum Unterseite { case profil, quickConnect, wiedergabe, einstellungen }

    /// **Einstellungen blenden über, sie schieben nicht.**
    ///
    /// Der Seitenschub gehört zum Blättern in Titeln — er sagt „du bist eine
    /// Ebene tiefer". Profil, Wiedergabe und Einstellungen liegen aber
    /// nebeneinander, nicht untereinander; sie zu schieben behauptet eine
    /// Tiefe, die es nicht gibt. Deshalb ist ``Schub/ohne`` hier die Vorgabe.
    ///
    /// **Und dieselbe Seite noch einmal wird an Ort und Stelle neu gebaut.**
    /// Wer eine Sprache wählt, löst einen Neubau aus; bisher fuhr dafür jedes
    /// Mal eine neue Seite herein, obwohl sich nur eine Zeile geändert hat.
    func unterseiteOeffnen(_ was: Unterseite, schub: Schub = .ohne) {
        let anOrt = (offeneUnterseite == was)
        let scheibe: Widget! = anOrt ? detailhuelle : naechsteScheibe()
        if anOrt { leeren(scheibe) }
        offeneUnterseite = was

        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(block, 560, -1)
        gtk_widget_set_halign(block, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(block, Int32(Stil.inhaltOben))
        gtk_widget_set_margin_bottom(block, 40)
        gtk_widget_set_margin_start(block, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(block, Int32(Stil.randAbstand))

        switch was {
        case .profil:         profilbauen(block)
        case .quickConnect:   quickConnectBauen(block)
        case .wiedergabe:     wiedergabeBauen(block)
        case .einstellungen:  einstellungenBauen(block)
        }

        let scroller = seitenscroller()
        gtk_scrolled_window_set_child(OpaquePointer(scroller), block)
        anhaengen(scheibe, scroller)
        if !anOrt { schieben(zu: scheibe, richtung: schub) }
    }

    /// **Die Zeile stand da und tat nichts.** Der Mac stösst die Prüfung an,
    /// zeigt „Moment …" und danach das Ergebnis daneben — ein Knopf ohne
    /// Rückruf ist schlimmer als keiner, weil er Funktion vortäuscht.
    private func verbindungPruefen() {
        guard let client else { return }
        pruefergebnis = uebersetzt("Moment …")
        unterseiteOeffnen(.einstellungen, schub: .ohne)
        Task.detached { [self] in
            let ok = (try? await client.publicSystemInfo()) != nil
            aufHauptfaden {
                self.pruefergebnis = ok ? uebersetzt("Erreichbar") : uebersetzt("Nicht erreichbar")
                if self.offeneUnterseite == .einstellungen {
                    self.unterseiteOeffnen(.einstellungen, schub: .ohne)
                }
            }
        }
    }

    /// Zurück aus einer Unterseite: erst zum Profil, von dort in den Bereich.
    private func unterseiteZurueck() {
        if offeneUnterseite == .profil {
            offeneUnterseite = nil
            bereichZeigen(bereich.kennung, schub: .ohne)
        } else {
            unterseiteOeffnen(.profil)
        }
    }

    // MARK: Profil

    private func profilbauen(_ block: Widget!) {
        // Nur der Pfeil, kein Titel — der Bildblock ist der Titel.
        anhaengen(block, unterseitenpfeil())

        let bildblock = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)
        gtk_widget_set_margin_top(bildblock, 42)
        gtk_widget_set_margin_bottom(bildblock, 30)

        // **Bei einem Konto steht kein Streifen da.** Wer nur eines hat, soll
        // nicht das Gefühl haben, ihm fehle eines.
        if let bund, bund.konten.count > 1 {
            anhaengen(bildblock, kontenstreifen(bund))
        } else {
            let (huelle, bild) = gerahmtesBild(breite: 84, hoehe: 84, stil: "swiftly-profilgross")
            gtk_widget_set_halign(huelle, GTK_ALIGN_CENTER)
            anhaengen(bildblock, huelle)
            if let adressen, !benutzerID.isEmpty,
               let url = adressen.benutzer(benutzerID, kante: 200) {
                bildLaden(bild, url: url, schluessel: url.absoluteString, sofort: true)
            }
        }

        let name = beschriftung(benutzername.isEmpty ? uebersetzt("Angemeldet") : benutzername,
                                stil: "swiftly-titel")
        anhaengen(bildblock, name)
        var teile: [String] = []
        if !servername.isEmpty { teile.append(servername) }
        if !serverfassung.isEmpty { teile.append("Jellyfin \(serverfassung)") }
        let unter = beschriftung(teile.joined(separator: " · "), stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(unter, "swiftly-leise")
        anhaengen(bildblock, unter)
        anhaengen(block, bildblock)

        let g1 = zeilengruppe()
        anhaengen(g1.raum, wertezeile(symbol: "phone-symbolic", titel: uebersetzt("Quick Connect"),
                                      unter: uebersetzt("Code vom Fernseher eingeben"),
                                      akzent: true, pfeil: true) { [weak self] in
            self?.unterseiteOeffnen(.quickConnect)
        })
        anhaengen(block, g1.aussen)

        anhaengen(block, luftHoch(26))

        let g2 = zeilengruppe()
        anhaengen(g2.raum, wertezeile(symbol: "media-playback-start-symbolic",
                                      titel: uebersetzt("Wiedergabe"),
                                      unter: uebersetzt("Sprache, Untertitel, Tempo"),
                                      pfeil: true) { [weak self] in
            self?.unterseiteOeffnen(.wiedergabe)
        })
        anhaengen(g2.raum, zeilenstrich())
        anhaengen(g2.raum, wertezeile(symbol: "emblem-system-symbolic",
                                      titel: uebersetzt("Einstellungen"), pfeil: true) { [weak self] in
            self?.unterseiteOeffnen(.einstellungen)
        })
        anhaengen(block, g2.aussen)

        anhaengen(block, luftHoch(26))

        let g3 = zeilengruppe()
        // **Eine Zeile über „Abmelden", ohne Anstrich.** Sie steht auch bei
        // einem einzigen Konto da — das ist der Einstieg, nicht die Auskunft,
        // dass etwas fehlt.
        anhaengen(g3.raum, wertezeile(symbol: "contact-new-symbolic",
                                      titel: uebersetzt("Weiteres Konto hinzufügen"),
                                      unter: uebersetzt("Auf demselben Server"),
                                      pfeil: true) { [weak self] in
            self?.kontoHinzufuegenOeffnen()
        })
        anhaengen(g3.raum, zeilenstrich())
        anhaengen(g3.raum, wertezeile(symbol: "system-log-out-symbolic",
                                      titel: uebersetzt("Abmelden")) { [weak self] in
            self?.abmelden()
        })
        anhaengen(block, g3.aussen)

        let fuss = beschriftung("Swiftly 1.0", stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(fuss, "swiftly-fuss")
        gtk_label_set_xalign(OpaquePointer(fuss), 0)
        gtk_widget_set_margin_top(fuss, 26)
        anhaengen(block, fuss)
    }

    // MARK: Quick Connect

    private func quickConnectBauen(_ block: Widget!) {
        anhaengen(block, unterseitenkopf(uebersetzt("Quick Connect")))

        let text = beschriftung(uebersetzt("Auf dem anderen Gerät steht ein sechsstelliger Code. Gib ihn hier ein, dann meldet es sich mit deinem Konto an."),
                                stil: "swiftly-koerper", umbruch: true)
        gtk_widget_add_css_class(text, "dim-label")
        gtk_label_set_xalign(OpaquePointer(text), 0)
        gtk_label_set_justify(OpaquePointer(text), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(text, 14)
        anhaengen(block, text)

        let feld: Widget! = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(feld), "000000")
        gtk_entry_set_max_length(alsFeld(feld), 6)
        gtk_widget_add_css_class(feld, "swiftly-code")
        gtk_widget_set_margin_top(feld, 22)
        anhaengen(block, feld)

        let stand = beschriftung("", stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_set_visible(stand, 0)
        gtk_widget_set_margin_top(stand, 12)
        anhaengen(block, stand)

        let knopf = hauptknopf(uebersetzt("Freigeben"), symbol: "object-select-symbolic")
        gtk_widget_set_size_request(knopf, -1, Int32(Stil.hauptknopfHoehe))
        gtk_widget_set_halign(knopf, GTK_ALIGN_FILL)
        gtk_widget_set_margin_top(knopf, 22)
        gtk_widget_set_sensitive(knopf, 0)
        anhaengen(block, knopf)

        let feldKiste = Zeigerkiste(feld)
        let standKiste = gehalten(stand)
        beiSignal(feld, "changed") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(knopf, self.text(feld).count == 6 ? 1 : 0)
        }
        beiSignal(knopf, "clicked") { [weak self] in
            guard let self, let client = self.client else { return }
            let code = self.text(feldKiste.widget)
            gtk_widget_set_sensitive(knopf, 0)
            let knopfKiste = gehalten(knopf)
            Task.detached {
                // `gut` entsteht **vor** dem Sprung auf den Hauptfaden und
                // wird dort nur gelesen — eine veränderliche Variable über
                // die Grenze zu reichen ginge nicht.
                let gut: Bool
                do { try await client.quickConnectFreigeben(code: code); gut = true }
                catch { gut = false }
                aufHauptfaden {
                    defer { losgelassen(knopfKiste) }
                    gtk_label_set_text(OpaquePointer(standKiste.widget),
                                       gut ? uebersetzt("Freigegeben. Das andere Gerät meldet sich jetzt an.")
                                           : uebersetzt("Der Code stimmt nicht oder ist abgelaufen."))
                    gtk_widget_add_css_class(standKiste.widget,
                                             gut ? "swiftly-beleg" : "swiftly-warnung")
                    gtk_widget_set_visible(standKiste.widget, 1)
                    gtk_widget_set_sensitive(knopfKiste.widget, 1)
                }
            }
        }
    }

    // MARK: Wiedergabe

    private func wiedergabeBauen(_ block: Widget!) {
        anhaengen(block, unterseitenkopf(uebersetzt("Wiedergabe")))

        let satz = beschriftung(uebersetzt("Gilt für alles, was neu startet. Im Player lässt sich jederzeit abweichen."),
                                stil: "swiftly-koerper", umbruch: true)
        gtk_widget_add_css_class(satz, "dim-label")
        gtk_label_set_xalign(OpaquePointer(satz), 0)
        gtk_label_set_justify(OpaquePointer(satz), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(satz, 14)
        anhaengen(block, satz)

        // MARK: Qualität
        let q = einstellungsgruppe(uebersetzt("Qualität"))
        anhaengen(q.raum, schalterzeile(symbol: "media-playback-start-symbolic",
                                        titel: uebersetzt("Immer Direct Play"),
                                        unter: uebersetzt("Nie umwandeln lassen — der Grund für diese App"),
                                        an: wahlen.immerDirectPlay) { [weak self] an in
            self?.wahlen.immerDirectPlay = an
            self?.wahlen.sichern()
            self?.unterseiteOeffnen(.wiedergabe)
        })
        anhaengen(q.raum, zeilenstrich())
        let bitrate = wertezeile(symbol: "view-list-symbolic", titel: uebersetzt("Höchste Bitrate"),
                                 wert: Bitrate.text(wahlen.bitratenGrenze), pfeil: true) {
            [weak self] in self?.listeUmschalten(.bitrate)
        }
        // **Die Bitrate greift nur, wenn Direct Play nicht erzwungen wird** —
        // sonst bliebe sie wirkungslos und stünde trotzdem da.
        gtk_widget_set_sensitive(bitrate, wahlen.immerDirectPlay ? 0 : 1)
        gtk_widget_set_opacity(bitrate, wahlen.immerDirectPlay ? 0.4 : 1)
        anhaengen(q.raum, bitrate)
        if offeneListe == .bitrate {
            anhaengen(q.raum, werteliste(Bitrate.stufen.map { (Bitrate.text($0.wert), $0.wert) },
                                         gewaehlt: wahlen.bitratenGrenze) { [weak self] wert in
                self?.wahlen.bitratenGrenze = wert
                self?.wahlen.sichern()
                self?.listeSchliessen(.wiedergabe)
            })
        }
        anhaengen(block, q.aussen)

        let hinweis = beschriftung(uebersetzt("Die Bitrate greift nur, wenn Direct Play nicht erzwungen wird — sonst bliebe sie wirkungslos und stünde trotzdem da."),
                                   stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(hinweis, "swiftly-fuss")
        gtk_label_set_xalign(OpaquePointer(hinweis), 0)
        gtk_label_set_justify(OpaquePointer(hinweis), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(hinweis, 10)
        anhaengen(block, hinweis)

        // MARK: Sprache
        let sp = einstellungsgruppe(uebersetzt("Sprache"))
        anhaengen(sp.raum, wertezeile(symbol: "audio-volume-high-symbolic", titel: uebersetzt("Ton"),
                                      wert: sprachname(wahlen.tonSprache), pfeil: true) {
            [weak self] in self?.listeUmschalten(.ton)
        })
        if offeneListe == .ton {
            anhaengen(sp.raum, werteliste(Sprachwahl.alle.map { ($0.name, $0.wert) },
                                          gewaehlt: wahlen.tonSprache) { [weak self] wert in
                self?.wahlen.tonSprache = wert
                self?.wahlen.sichern()
                self?.listeSchliessen(.wiedergabe)
            })
        }
        anhaengen(sp.raum, zeilenstrich())
        anhaengen(sp.raum, wertezeile(symbol: "media-view-subtitles-symbolic", titel: uebersetzt("Untertitel"),
                                      wert: sprachname(wahlen.untertitelSprache, aus: uebersetzt("Aus")),
                                      pfeil: true) {
            [weak self] in self?.listeUmschalten(.untertitel)
        })
        if offeneListe == .untertitel {
            anhaengen(sp.raum, werteliste(Sprachwahl.alle(aus: uebersetzt("Aus")).map { ($0.name, $0.wert) },
                                          gewaehlt: wahlen.untertitelSprache) { [weak self] wert in
                self?.wahlen.untertitelSprache = wert
                self?.wahlen.sichern()
                self?.listeSchliessen(.wiedergabe)
            })
        }
        anhaengen(sp.raum, zeilenstrich())
        anhaengen(sp.raum, schalterzeile(symbol: "format-justify-left-symbolic",
                                         titel: uebersetzt("Untertitel automatisch"),
                                         unter: uebersetzt("Nur wenn der Ton nicht in der gewählten Sprache läuft"),
                                         an: wahlen.untertitelAutomatisch) { [weak self] an in
            self?.wahlen.untertitelAutomatisch = an
            self?.wahlen.sichern()
        })
        anhaengen(block, sp.aussen)

        // MARK: Verhalten
        let v = einstellungsgruppe(uebersetzt("Verhalten"))
        anhaengen(v.raum, schalterzeile(symbol: "media-skip-forward-symbolic",
                                        titel: uebersetzt("Nächste Folge automatisch"),
                                        an: wahlen.naechsteAutomatisch) { [weak self] an in
            self?.wahlen.naechsteAutomatisch = an
            self?.wahlen.sichern()
        })
        anhaengen(v.raum, zeilenstrich())
        anhaengen(v.raum, wertezeile(symbol: "media-seek-backward-symbolic", titel: uebersetzt("Zurückspulen"),
                                     wert: "\(wahlen.zurueckSekunden) s", pfeil: true) {
            [weak self] in self?.listeUmschalten(.zurueck)
        })
        if offeneListe == .zurueck {
            anhaengen(v.raum, werteliste(Spanne.stufen.map { ("\($0.wert) s", $0.wert) },
                                         gewaehlt: wahlen.zurueckSekunden) { [weak self] wert in
                self?.wahlen.zurueckSekunden = wert
                self?.wahlen.sichern()
                self?.listeSchliessen(.wiedergabe)
            })
        }
        anhaengen(v.raum, zeilenstrich())
        anhaengen(v.raum, wertezeile(symbol: "media-seek-forward-symbolic", titel: uebersetzt("Vorspulen"),
                                     wert: "\(wahlen.vorSekunden) s", pfeil: true) {
            [weak self] in self?.listeUmschalten(.vor)
        })
        if offeneListe == .vor {
            anhaengen(v.raum, werteliste(Spanne.stufen.map { ("\($0.wert) s", $0.wert) },
                                         gewaehlt: wahlen.vorSekunden) { [weak self] wert in
                self?.wahlen.vorSekunden = wert
                self?.wahlen.sichern()
                self?.listeSchliessen(.wiedergabe)
            })
        }
        anhaengen(block, v.aussen)
    }

    private func sprachname(_ wert: String, aus: String = uebersetzt("Wie die Datei")) -> String {
        wert.isEmpty ? aus : wert
    }

    // MARK: Einstellungen

    private func einstellungenBauen(_ block: Widget!) {
        anhaengen(block, unterseitenkopf(uebersetzt("Einstellungen")))

        // „Querformat im Player sperren" gibt es hier **nicht**: ein Fenster
        // hat keine Ausrichtung, die man sperren könnte. Kein Weglassen,
        // sondern eine Einstellung ohne Gegenstück (VERHALTEN.md F).
        let d = einstellungsgruppe(uebersetzt("Darstellung"))
        anhaengen(d.raum, schalterzeile(symbol: "view-list-symbolic",
                                        titel: uebersetzt("Fortschritt auf Kacheln"),
                                        an: wahlen.fortschrittAufKacheln) { [weak self] an in
            self?.wahlen.fortschrittAufKacheln = an
            self?.wahlen.sichern()
        })
        anhaengen(d.raum, zeilenstrich())
        anhaengen(d.raum, schalterzeile(symbol: "folder-new-symbolic",
                                        titel: uebersetzt("Neuzugänge getrennt"),
                                        unter: uebersetzt("Neue Filme und neue Serien in eigenen Reihen"),
                                        an: wahlen.neuzugaengeGetrennt) { [weak self] an in
            self?.wahlen.neuzugaengeGetrennt = an
            self?.wahlen.sichern()
            self?.startseiteLaden()
        })
        anhaengen(block, d.aussen)

        let s = einstellungsgruppe(uebersetzt("Server"))
        anhaengen(s.raum, wertezeile(symbol: "network-server-symbolic",
                                     titel: servername.isEmpty ? uebersetzt("Server") : servername,
                                     wert: serverfassung))
        anhaengen(s.raum, zeilenstrich())
        // **Die Zeile stand da und tat nichts.** Der Mac stösst die Prüfung
        // an, zeigt „Moment …" und danach das Ergebnis als Wert daneben.
        let pruefzeile = wertezeile(symbol: "network-wireless-symbolic",
                                    titel: uebersetzt("Verbindung prüfen"),
                                    wert: pruefergebnis) { [weak self] in
            self?.verbindungPruefen()
        }
        anhaengen(s.raum, pruefzeile)
        anhaengen(block, s.aussen)

        let fuss = beschriftung("Swiftly 1.0 · libVLC \(VLCFassung.text)",
                                stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(fuss, "swiftly-fuss")
        gtk_label_set_xalign(OpaquePointer(fuss), 0)
        gtk_widget_set_margin_top(fuss, 26)
        anhaengen(block, fuss)
    }

    // MARK: Bausteine der Seiten

    private func listeUmschalten(_ was: Werteauswahl) {
        offeneListe = offeneListe == was ? nil : was
        unterseiteOeffnen(.wiedergabe)
    }

    private func listeSchliessen(_ seite: Unterseite) {
        offeneListe = nil
        unterseiteOeffnen(seite)
    }

    private func unterseitenpfeil() -> Widget! {
        let pfeil: Widget! = gtk_button_new()
        gtk_widget_add_css_class(pfeil, "swiftly-zurueck")
        gtk_button_set_child(alsKnopf(pfeil),
                             gtk_image_new_from_icon_name("go-previous-symbolic"))
        gtk_widget_set_halign(pfeil, GTK_ALIGN_START)
        // Kein negativer Rand: GTK laesst ihn nicht zu. Der Pfeil steht
        // ohnehin schon im 24er-Rand des Blocks.
        gtk_widget_set_margin_start(pfeil, 0)
        beiSignal(pfeil, "clicked") { [weak self] in self?.unterseiteZurueck() }
        return pfeil
    }

    private func unterseitenkopf(_ titel: String) -> Widget! {
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
        anhaengen(reihe, unterseitenpfeil())
        let t = beschriftung(titel, stil: "swiftly-titel-gross")
        gtk_widget_set_valign(t, GTK_ALIGN_CENTER)
        anhaengen(reihe, t)
        return reihe
    }
    // MARK: Kontenstreifen

    /// Der waagerechte Streifen über dem Profil, wenn mehrere Konten da sind.
    ///
    /// **Zwei Dinge, die man leicht verwechselt, und deren Trennung der Kern
    /// des Entwurfs ist:**
    ///
    /// - **Gross ist, was in der Mitte steht.** Auf dem Schreibtisch steht das
    ///   aktive Konto mittig im Inhaltsbereich und misst 96; die anderen
    ///   messen 72 und stehen daneben. Grösse und Ort sagen also *nichts*
    ///   darüber aus, wer verbunden ist — sie folgen der Auswahl.
    /// - **Verbunden ist, was Akzentring und Punkt trägt.** Das ändert sich
    ///   erst beim Klicken, nie beim blossen Hinsehen.
    ///
    /// Die Mitte macht ``GtkCenterBox``: das aktive Konto ist das Mittelkind
    /// und bleibt in der Mitte, solange die Seiten es zulassen — genau das,
    /// was im Entwurf mit einem festen Abstand von links gezeichnet ist.
    private func kontenstreifen(_ bund: Kontenbund) -> Widget! {
        let mitte: Widget! = gtk_center_box_new()
        gtk_widget_set_hexpand(mitte, 1)

        let davor = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 26)
        gtk_widget_set_halign(davor, GTK_ALIGN_END)
        gtk_widget_set_margin_end(davor, 26)
        let danach = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 26)
        gtk_widget_set_halign(danach, GTK_ALIGN_START)
        gtk_widget_set_margin_start(danach, 26)

        var vorAktivem = true
        for konto in bund.konten {
            let ist = konto.userID == bund.aktiveKennung
            if ist {
                gtk_center_box_set_center_widget(OpaquePointer(mitte), kontokachel(konto, aktiv: true))
                vorAktivem = false
                continue
            }
            anhaengen(vorAktivem ? davor : danach, kontokachel(konto, aktiv: false))
        }
        gtk_center_box_set_start_widget(OpaquePointer(mitte), davor)
        gtk_center_box_set_end_widget(OpaquePointer(mitte), danach)
        return mitte
    }

    /// Ein Konto im Streifen: Bild, darunter der Punkt.
    ///
    /// Die Zeile ist 96 hoch, egal wie gross das Bild ist — sonst hüpften die
    /// kleineren Bilder an den oberen Rand, statt auf einer Linie mit dem
    /// grossen zu stehen. Darunter liegen 14 Punkte Platz, in denen beim
    /// aktiven Konto der Punkt sitzt; auch dieser Platz bleibt bei den
    /// anderen leer stehen, damit die Bilder nicht wandern.
    private func kontokachel(_ konto: Session, aktiv: Bool) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-kontoknopf")
        if !aktiv { gtk_widget_set_opacity(knopf, 0.55) }

        let saeule = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)

        let zone = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(zone, -1, 96)
        let kante = aktiv ? 96 : 72
        let (huelle, bild) = gerahmtesBild(breite: kante, hoehe: kante,
                                           stil: aktiv ? "swiftly-kontoaktiv"
                                                       : "swiftly-kontoandere")
        gtk_widget_set_valign(huelle, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(huelle, 1)
        anhaengen(zone, huelle)
        anhaengen(saeule, zone)

        let punktzone = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(punktzone, -1, 14)
        if aktiv {
            let punkt: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
            gtk_widget_add_css_class(punkt, "swiftly-kontopunkt")
            gtk_widget_set_size_request(punkt, 5, 5)
            gtk_widget_set_halign(punkt, GTK_ALIGN_CENTER)
            gtk_widget_set_margin_top(punkt, 9)
            anhaengen(punktzone, punkt)
        }
        anhaengen(saeule, punktzone)

        gtk_button_set_child(alsKnopf(knopf), saeule)
        if let adressen, let url = adressen.benutzer(konto.userID, kante: 200) {
            bildLaden(bild, url: url, schluessel: url.absoluteString, sofort: true)
        }
        // Das aktive Konto ist kein Ziel — ein Klick darauf täte nichts, und
        // ein Knopf, der nichts tut, ist eine Zusage, die nicht eingehalten wird.
        if aktiv {
            gtk_widget_set_sensitive(knopf, 0)
        } else {
            let kennung = konto.userID
            beiSignal(knopf, "clicked") { [weak self] in self?.kontoWechseln(zu: kennung) }
        }
        return knopf
    }

}
