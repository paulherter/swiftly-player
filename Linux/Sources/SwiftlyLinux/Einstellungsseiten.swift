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

    func unterseiteOeffnen(_ was: Unterseite, schub: Schub = .tiefer) {
        let name = naechsteScheibe()
        seiteZeigen(name, schub: schub)
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
        anhaengen(detailhuelle, scroller)
    }

    /// Zurück aus einer Unterseite: erst zum Profil, von dort in den Bereich.
    private func unterseiteZurueck() {
        if offeneUnterseite == .profil {
            offeneUnterseite = nil
            seiteZeigen(bereich.kennung, schub: .zurueck)
        } else {
            unterseiteOeffnen(.profil, schub: .zurueck)
        }
    }

    // MARK: Profil

    private func profilbauen(_ block: Widget!) {
        // Nur der Pfeil, kein Titel — der Bildblock ist der Titel.
        anhaengen(block, unterseitenpfeil())

        let bildblock = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)
        gtk_widget_set_margin_top(bildblock, 42)
        gtk_widget_set_margin_bottom(bildblock, 30)

        let (huelle, bild) = gerahmtesBild(breite: 84, hoehe: 84, stil: "swiftly-profilgross")
        gtk_widget_set_halign(huelle, GTK_ALIGN_CENTER)
        anhaengen(bildblock, huelle)
        if let adressen, !benutzerID.isEmpty,
           let url = adressen.benutzer(benutzerID, kante: 200) {
            bildLaden(bild, url: url, schluessel: url.absoluteString)
        }

        let name = beschriftung(benutzername.isEmpty ? "Angemeldet" : benutzername,
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
        anhaengen(g1.raum, wertezeile(symbol: "user-info-symbolic", titel: "Quick Connect",
                                      unter: "Code vom Fernseher eingeben",
                                      akzent: true, pfeil: true) { [weak self] in
            self?.unterseiteOeffnen(.quickConnect)
        })
        anhaengen(block, g1.aussen)

        anhaengen(block, luftHoch(26))

        let g2 = zeilengruppe()
        anhaengen(g2.raum, wertezeile(symbol: "media-playback-start-symbolic",
                                      titel: "Wiedergabe",
                                      unter: "Sprache, Untertitel, Tempo",
                                      pfeil: true) { [weak self] in
            self?.unterseiteOeffnen(.wiedergabe)
        })
        anhaengen(g2.raum, zeilenstrich())
        anhaengen(g2.raum, wertezeile(symbol: "emblem-system-symbolic",
                                      titel: "Einstellungen", pfeil: true) { [weak self] in
            self?.unterseiteOeffnen(.einstellungen)
        })
        anhaengen(block, g2.aussen)

        anhaengen(block, luftHoch(26))

        let g3 = zeilengruppe()
        anhaengen(g3.raum, wertezeile(symbol: "system-log-out-symbolic",
                                      titel: "Abmelden") { [weak self] in
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
        anhaengen(block, unterseitenkopf("Quick Connect"))

        let text = beschriftung("Auf dem anderen Gerät steht ein sechsstelliger Code. "
                                + "Gib ihn hier ein, dann meldet es sich mit deinem Konto an.",
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

        let knopf = hauptknopf("Freigeben", symbol: "object-select-symbolic")
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
                                       gut ? "Freigegeben. Das andere Gerät meldet sich jetzt an."
                                           : "Der Code stimmt nicht oder ist abgelaufen.")
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
        anhaengen(block, unterseitenkopf("Wiedergabe"))

        let satz = beschriftung("Gilt für alles, was neu startet. "
                                + "Im Player lässt sich jederzeit abweichen.",
                                stil: "swiftly-koerper", umbruch: true)
        gtk_widget_add_css_class(satz, "dim-label")
        gtk_label_set_xalign(OpaquePointer(satz), 0)
        gtk_label_set_justify(OpaquePointer(satz), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(satz, 14)
        anhaengen(block, satz)

        // MARK: Qualität
        let q = einstellungsgruppe("Qualität")
        anhaengen(q.raum, schalterzeile(symbol: "media-playback-start-symbolic",
                                        titel: "Immer Direct Play",
                                        unter: "Nie umwandeln lassen — der Grund für diese App",
                                        an: wahlen.immerDirectPlay) { [weak self] an in
            self?.wahlen.immerDirectPlay = an
            self?.wahlen.sichern()
            self?.unterseiteOeffnen(.wiedergabe)
        })
        anhaengen(q.raum, zeilenstrich())
        let bitrate = wertezeile(symbol: "view-list-symbolic", titel: "Höchste Bitrate",
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

        let hinweis = beschriftung("Die Bitrate greift nur, wenn Direct Play nicht erzwungen "
                                   + "wird — sonst bliebe sie wirkungslos und stünde trotzdem da.",
                                   stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(hinweis, "swiftly-fuss")
        gtk_label_set_xalign(OpaquePointer(hinweis), 0)
        gtk_label_set_justify(OpaquePointer(hinweis), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(hinweis, 10)
        anhaengen(block, hinweis)

        // MARK: Sprache
        let sp = einstellungsgruppe("Sprache")
        anhaengen(sp.raum, wertezeile(symbol: "audio-volume-high-symbolic", titel: "Ton",
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
        anhaengen(sp.raum, wertezeile(symbol: "media-view-subtitles-symbolic", titel: "Untertitel",
                                      wert: sprachname(wahlen.untertitelSprache, aus: "Aus"),
                                      pfeil: true) {
            [weak self] in self?.listeUmschalten(.untertitel)
        })
        if offeneListe == .untertitel {
            anhaengen(sp.raum, werteliste(Sprachwahl.alle(aus: "Aus").map { ($0.name, $0.wert) },
                                          gewaehlt: wahlen.untertitelSprache) { [weak self] wert in
                self?.wahlen.untertitelSprache = wert
                self?.wahlen.sichern()
                self?.listeSchliessen(.wiedergabe)
            })
        }
        anhaengen(sp.raum, zeilenstrich())
        anhaengen(sp.raum, schalterzeile(symbol: "format-justify-left-symbolic",
                                         titel: "Untertitel automatisch",
                                         unter: "Nur wenn der Ton nicht in der gewählten Sprache läuft",
                                         an: wahlen.untertitelAutomatisch) { [weak self] an in
            self?.wahlen.untertitelAutomatisch = an
            self?.wahlen.sichern()
        })
        anhaengen(block, sp.aussen)

        // MARK: Verhalten
        let v = einstellungsgruppe("Verhalten")
        anhaengen(v.raum, schalterzeile(symbol: "media-skip-forward-symbolic",
                                        titel: "Nächste Folge automatisch",
                                        an: wahlen.naechsteAutomatisch) { [weak self] an in
            self?.wahlen.naechsteAutomatisch = an
            self?.wahlen.sichern()
        })
        anhaengen(v.raum, zeilenstrich())
        anhaengen(v.raum, wertezeile(symbol: "media-seek-backward-symbolic", titel: "Zurückspulen",
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
        anhaengen(v.raum, wertezeile(symbol: "media-seek-forward-symbolic", titel: "Vorspulen",
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

    private func sprachname(_ wert: String, aus: String = "Wie die Datei") -> String {
        wert.isEmpty ? aus : wert
    }

    // MARK: Einstellungen

    private func einstellungenBauen(_ block: Widget!) {
        anhaengen(block, unterseitenkopf("Einstellungen"))

        // „Querformat im Player sperren" gibt es hier **nicht**: ein Fenster
        // hat keine Ausrichtung, die man sperren könnte. Kein Weglassen,
        // sondern eine Einstellung ohne Gegenstück (VERHALTEN.md F).
        let d = einstellungsgruppe("Darstellung")
        anhaengen(d.raum, schalterzeile(symbol: "view-list-symbolic",
                                        titel: "Fortschritt auf Kacheln",
                                        an: wahlen.fortschrittAufKacheln) { [weak self] an in
            self?.wahlen.fortschrittAufKacheln = an
            self?.wahlen.sichern()
        })
        anhaengen(block, d.aussen)

        let s = einstellungsgruppe("Server")
        anhaengen(s.raum, wertezeile(symbol: "network-server-symbolic",
                                     titel: servername.isEmpty ? "Server" : servername,
                                     wert: serverfassung))
        anhaengen(s.raum, zeilenstrich())
        let pruefzeile = wertezeile(symbol: "network-wireless-symbolic",
                                    titel: "Verbindung prüfen")
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
}
