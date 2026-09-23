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

    enum Unterseite { case profil, quickConnect, wiedergabe, seerr, trakt, einstellungen, kontoHinzufuegen, serverAufnahme, darstellung, genrewahl }

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
    /// **Von rechts herein, nicht hart geschnitten.** Der Mac legt jede
    /// Unterseite ueber `Navigator.oeffne` auf den Seitenstapel, und dort
    /// gilt woertlich: „tiefer gehen schiebt von rechts, zurueck schiebt nach
    /// rechts hinaus" (`Sources/macOS/Navigator.swift:13`). Die Vorgabe stand
    /// hier auf `.ohne` — damit erschien ausgerechnet die Profilseite, die
    /// erste, die man oeffnet, ohne jede Bewegung. Die Stellen, die eine
    /// Unterseite nach einem Kontowechsel *wiederherstellen*, geben `.ohne`
    /// weiterhin ausdruecklich mit: dort ist die Seite schon dagewesen.
    func unterseiteOeffnen(_ was: Unterseite, schub: Schub = .tiefer) {
        // Eine offene Unterseite nimmt der Leiste die Hervorhebung — sonst
        // leuchtet „Start", waehrend rechts das Profil steht.
        defer { bereichszeilenMalen() }
        let anOrt = (offeneUnterseite == was)
        let scheibe: Widget! = anOrt ? detailhuelle : naechsteScheibe()
        if anOrt { leeren(scheibe) }
        offeneUnterseite = was

        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        // **Nicht alle Unterseiten sind gleich breit.** Die Einstellungen
        // tragen zwei Spalten nebeneinander, der Rest liest sich wie Text.
        // Hier stand fuer alle dieselbe 560 — auf einem 1400 Punkt breiten
        // Fenster sah das aus wie eine Handyansicht in der Mitte.
        //
        // **`size_request` ist ein Mindestmass, kein Hoechstmass**, und GTK
        // kennt kein `max-width`. Der Mac deckelt mit `frame(maxWidth:)` nach
        // oben und laesst die Spalten schrumpfen; setzt man dieselbe Zahl
        // hier als Anforderung, sprengt die Seite das Fenster und die rechte
        // Spalte steht draussen.
        //
        // Der Deckel kommt deshalb ueber ``deckeln(_:auf:)`` von unten: die
        // Anpassung des Scrollers kennt die sichtbare Breite und meldet jede
        // Aenderung. Ohne ihn wuchsen die drei Seiten unbegrenzt mit dem
        // Fenster, waehrend der Mac bei 1366 aufhoert.
        // **Die zweispaltigen Seiten sind drei, nicht eine.** Wiedergabe und
        // Darstellung bauen ebenfalls mit ``zweispalter`` und bekamen
        // trotzdem `lesebreite` (700) — zwei Spalten zu je 326 Punkt, wo der
        // Mac ihnen `Stil.einstellungBreite` gibt
        // (`WiedergabeEinstellungenView.swift:58`, `DarstellungView.swift:44`).
        // Das war „das Wiedergabe-Menue passt gar nicht".
        //
        // **Die Formularseiten sind dagegen schmaler als 700, nicht breiter.**
        // Der Mac deckelt Serveraufnahme, Weiteres Konto und Quick Connect
        // auf 460 (`ServerAufnahmeView.swift:71`, `ProfilView.swift:205,279`).
        let zweispaltig: Set<Unterseite> = [.einstellungen, .wiedergabe, .darstellung]
        // **Profil und Seerr gehoeren dazu** (Mac 7c6d682f): „die Settings
        // sind so lang gezogen … gleichzeitig aber in der Hoehe so klein."
        // `lesebreite` ist das Mass fuer Fliesstext.
        let formular: Set<Unterseite> = [.serverAufnahme, .kontoHinzufuegen, .quickConnect,
                                          .profil, .seerr, .trakt]
        if zweispaltig.contains(was) {
            gtk_widget_set_halign(block, GTK_ALIGN_FILL)
            gtk_widget_set_hexpand(block, 1)
            gtk_widget_set_margin_start(block, Int32(Stil.randAbstand))
            gtk_widget_set_margin_end(block, Int32(Stil.randAbstand))
        } else if formular.contains(was) {
            gtk_widget_set_size_request(block, Int32(Stil.formularBreite), -1)
            gtk_widget_set_halign(block, GTK_ALIGN_START)
        } else {
            // **Links, nicht mittig.** Der Mac setzt
            // `frame(maxWidth: lesebreite, alignment: .leading)` und danach
            // `frame(maxWidth: .infinity, alignment: .leading)`: der Block ist
            // hoechstens 700 breit und steht am linken Rand. Hier stand
            // `CENTER`, und damit sass ausgerechnet die Profilseite — die
            // erste, die man oeffnet — als einzige in der Mitte, waehrend die
            // Unterseiten darunter links standen.
            gtk_widget_set_size_request(block, Int32(Stil.lesebreite), -1)
            gtk_widget_set_halign(block, GTK_ALIGN_START)
        }
        gtk_widget_set_margin_top(block, Int32(Stil.inhaltOben))
        gtk_widget_set_margin_bottom(block, 40)
        gtk_widget_set_margin_start(block, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(block, Int32(Stil.randAbstand))

        switch was {
        case .profil:         profilbauen(block)
        case .quickConnect:   quickConnectBauen(block)
        case .wiedergabe:     wiedergabeBauen(block)
        case .seerr:          seerrSeiteBauen(block)
        case .trakt:          traktSeiteBauen(block)
        case .einstellungen:  einstellungenBauen(block)
        case .kontoHinzufuegen: kontoHinzufuegenBauen(block)
        case .serverAufnahme:   serverAufnahmeBauen(block)
        case .darstellung:      darstellungBauen(block)
        case .genrewahl:        genrewahlBauen(block)
        }

        let scroller = seitenscroller()
        gtk_scrolled_window_set_child(OpaquePointer(scroller), block)
        // Die Einstellungen: **jede Spalte hoert bei `formularbreite` auf**
        // (`EinstellungenView.swift`), also zwei Spalten plus 48 Abstand.
        if was == .einstellungen {
            deckeln(block, in: scroller, auf: Stil.formularBreite * 2 + Stil.randAbstand * 2)
        } else if zweispaltig.contains(was) {
            deckeln(block, in: scroller, auf: Stil.einstellungBreite)
        }
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
    ///
    /// **Nach rechts hinaus, in beiden Stufen.** Das ist die zweite Hälfte der
    /// Regel aus `Navigator.swift:13`; hier stand `.ohne` für den einen Weg
    /// und die Vorgabe für den anderen, also fuhr die Wiedergabeseite beim
    /// Zurückgehen von links herein, als ginge man tiefer.
    func unterseiteZurueck() {
        if offeneUnterseite == .profil {
            offeneUnterseite = nil
            bereichZeigen(bereich.kennung, schub: .zurueck)
        } else {
            unterseiteOeffnen(.profil, schub: .zurueck)
        }
    }

    // MARK: Profil

    private func profilbauen(_ block: Widget!) {
        // **Mit Titel.** Er stand hier einmal nicht, weil der Bildblock als
        // Titel galt — das war die Fassung vor der Kontokarte. Seit der Mac
        // Karten zeigt, traegt er den Kopf wieder wie jede andere Unterseite
        // (`ProfilView.swift:28`), und zwar buendig mit den Karten.
        anhaengen(block, unterseitenkopf(uebersetzt("Profil")))

        let bildblock = stapel(GTK_ORIENTATION_VERTICAL, abstand: 14)
        // 10 ueber, 20 unter — `Sources/macOS/ProfilView.swift:29` und `:39`.
        gtk_widget_set_margin_top(bildblock, 10)
        gtk_widget_set_margin_bottom(bildblock, 20)
        anhaengen(bildblock, kontenkarten())
        anhaengen(block, bildblock)

        let g1 = zeilengruppe()
        anhaengen(g1.raum, wertezeile(symbol: "dialog-password-symbolic", titel: uebersetzt("Quick Connect"),
                                      unter: uebersetzt("Code vom Fernseher eingeben"),
                                      akzent: true, pfeil: true) { [weak self] in
            self?.unterseiteOeffnen(.quickConnect)
        })
        anhaengen(block, g1.aussen)

        // 18 zwischen den Gruppen — `Sources/macOS/ProfilView.swift:51` und `:84`.
        anhaengen(block, luftHoch(18))

        let g2 = zeilengruppe()
        anhaengen(g2.raum, wertezeile(symbol: "media-playback-start-symbolic",
                                      titel: uebersetzt("Wiedergabe"),
                                      unter: uebersetzt("Sprache, Untertitel, Tempo"),
                                      pfeil: true) { [weak self] in
            self?.unterseiteOeffnen(.wiedergabe)
        })
        anhaengen(g2.raum, zeilenstrich())
        // Zwischen Wiedergabe und Einstellungen — die Reihenfolge des Macs.
        anhaengen(g2.raum, wertezeile(symbol: "view-app-grid-symbolic",
                                      titel: uebersetzt("Darstellung"),
                                      unter: uebersetzt("Startseite, Reihen und Genres"),
                                      pfeil: true) { [weak self] in
            self?.unterseiteOeffnen(.darstellung)
        })
        anhaengen(g2.raum, zeilenstrich())
        anhaengen(g2.raum, wertezeile(symbol: "emblem-system-symbolic",
                                      titel: uebersetzt("Einstellungen"), pfeil: true) { [weak self] in
            self?.unterseiteOeffnen(.einstellungen)
        })
        anhaengen(block, g2.aussen)

        anhaengen(block, luftHoch(18))

        let g3 = zeilengruppe()
        // **„Weiteres Konto hinzufügen" stand hier und ist weg.** Das Plus in
        // der Kontokarte tut dasselbe, und zwar dort, wo die Konten stehen —
        // auf dem Mac am 11.09.2026 aus demselben Grund entfernt.
        //
        // **„Server hinzufügen" steht dafür da**, und das ist etwas anderes:
        // ein zweiter Jellyfin mit eigenen Konten, nicht ein zweites Konto
        // auf demselben.
        anhaengen(g3.raum, wertezeile(symbol: "network-server-symbolic",
                                      titel: uebersetzt("Server hinzufügen"),
                                      unter: uebersetzt("Ein zweiter Jellyfin, eigene Konten"),
                                      pfeil: true) { [weak self] in
            self?.serverAufnahmeOeffnen(nil)
        })
        anhaengen(g3.raum, zeilenstrich())
        anhaengen(g3.raum, wertezeile(symbol: "application-exit-symbolic",
                                      titel: uebersetzt("Abmelden")) { [weak self] in
            self?.abmelden()
        })
        anhaengen(block, g3.aussen)

        anhaengen(block, luftHoch(18))

        // **Bewerten, Discord, Fehler melden — ganz unten**, unter Server und
        // Abmelden. Stand in den Einstellungen und wurde dort kaum gesehen.
        // **Ohne „bewerten":** es gibt keinen Store, in dem eine Bewertung
        // landen koennte. Die Adressen stehen im Paket.
        let g4 = zeilengruppe()
        anhaengen(g4.raum, wertezeile(symbol: "user-available-symbolic",
                                      titel: uebersetzt("Discord beitreten"),
                                      unter: uebersetzt("Fragen stellen und sagen, was fehlt")) {
            imBrowser(Gemeinschaft.discord)
        })
        anhaengen(g4.raum, zeilenstrich())
        anhaengen(g4.raum, wertezeile(symbol: "dialog-warning-symbolic",
                                      titel: uebersetzt("Fehler melden"),
                                      unter: uebersetzt("Auf GitHub, deine App-Version ist schon eingetragen")) {
            #if os(Windows)
            let system = "Windows"
            #else
            let system = "Linux"
            #endif
            imBrowser(Gemeinschaft.fehlerMelden(fassung: "\(Fassung.voll) · libVLC \(VLCFassung.text)",
                                                plattform: system))
        })
        anhaengen(g4.raum, zeilenstrich())
        // Neben „Fehler melden", weil es dazugehoert (Mac 307e2844): wer im
        // Discord einen Fehler meldet, haengt das hier an.
        anhaengen(g4.raum, wertezeile(symbol: "text-x-generic-symbolic",
                                      titel: uebersetzt("Protokoll teilen"),
                                      unter: uebersetzt("Die letzte Stunde, ohne Zugangsdaten")) {
            guard let datei = Protokolldatei.schreiben() else { return }
            imDateimanagerZeigen(datei)
        })
        #if os(Windows)
        // **Nur unter Windows.** Auf Linux kommt die Aktualisierung aus der
        // Paketquelle, die `swiftly-installieren.sh` einrichtet — dort waere
        // ein eigener Weg an der Systemverwaltung vorbei.
        anhaengen(g4.raum, zeilenstrich())
        aktualisierungsraum = stapel(GTK_ORIENTATION_VERTICAL)
        aktualisierungszeileFuellen()
        anhaengen(g4.raum, aktualisierungsraum)
        #endif
        anhaengen(block, g4.aussen)

        let fuss = beschriftung(Fassung.voll, stil: "swiftly-zweitzeile")
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
            // **Ab vier, nicht erst ab sechs.** Der Mac gibt den Knopf bei
            // `code.count >= 4` frei (`ProfilView.swift:197-198`) — ein Code
            // ist zwar sechsstellig, aber ein Knopf, der bis zum letzten
            // Zeichen tot bleibt, sieht aus wie einer, der klemmt.
            gtk_widget_set_sensitive(knopf, self.text(feld).count >= 4 ? 1 : 0)
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

        // **Zwei Spalten, wie auf dem Mac** (`WiedergabeEinstellungenView.swift:38`):
        // links, was den Ton angeht — Qualitaet und Sprache. Rechts allein das
        // Verhalten. Hier stand alles untereinander.
        let (links, rechts) = zweispalter(in: block)

        // MARK: Qualität
        // Wandelt der Server nicht um, ist nichts zu wählen: Direct Play
        // steht fest an, die Bitrate ist gesperrt.
        let frei = umwandelnErlaubt
        let directPlay = wahlen.immerDirectPlay || !frei
        let q = einstellungsgruppe(uebersetzt("Qualität"))
        let schalter = schalterzeile(symbol: "media-playback-start-symbolic",
                                     titel: uebersetzt("Immer Direct Play"),
                                     unter: uebersetzt("Der Server wandelt nie um, es läuft immer die Originaldatei"),
                                     an: directPlay) { [weak self] an in
            self?.wahlen.immerDirectPlay = an
            self?.wahlen.sichern()
            self?.unterseiteOeffnen(.wiedergabe)
        }
        gtk_widget_set_sensitive(schalter, frei ? 1 : 0)
        anhaengen(q.raum, schalter)
        anhaengen(q.raum, zeilenstrich())
        let bitrate = wertezeile(symbol: "view-list-symbolic", titel: uebersetzt("Höchste Bitrate"),
                                 wert: Bitrate.text(wahlen.bitratenGrenze), pfeil: true) {
            [weak self] in self?.listeUmschalten(.bitrate)
        }
        // **Die Bitrate greift nur, wenn Direct Play nicht erzwungen wird** —
        // sonst bliebe sie wirkungslos und stünde trotzdem da.
        gtk_widget_set_sensitive(bitrate, directPlay ? 0 : 1)
        gtk_widget_set_opacity(bitrate, directPlay ? 0.4 : 1)
        anhaengen(q.raum, bitrate)
        if offeneListe == .bitrate {
            anhaengen(q.raum, werteliste(Bitrate.stufen.map { (Bitrate.text($0.wert), $0.wert) },
                                         gewaehlt: wahlen.bitratenGrenze) { [weak self] wert in
                self?.wahlen.bitratenGrenze = wert
                self?.wahlen.sichern()
                self?.listeSchliessen(.wiedergabe)
            })
        }
        anhaengen(links, q.aussen)

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
        anhaengen(links, sp.aussen)

        // MARK: Verhalten
        let v = einstellungsgruppe(uebersetzt("Verhalten"))
        anhaengen(v.raum, schalterzeile(symbol: "media-skip-forward-symbolic",
                                        titel: uebersetzt("Nächste Folge automatisch"),
                                        an: naechsteAutomatisch) { [weak self] an in
            self?.wahlen.naechsteAutomatischGewaehlt = an
            self?.wahlen.sichern()
        })
        // **Das Technikschild steht direkt hinter „Naechste Folge
        // automatisch"** — `macOS/WiedergabeEinstellungenView.swift:139`.
        // Es sass hier hinter Vor- und Zurueckspulen, also an fuenfter statt
        // an zweiter Stelle.
        anhaengen(v.raum, zeilenstrich())
        anhaengen(v.raum, schalterzeile(symbol: "preferences-system-symbolic",
                                        titel: uebersetzt("Technische Daten im Player"),
                                        an: wahlen.technikschild) { [weak self] an in
            self?.wahlen.technikschild = an
            self?.wahlen.sichern()
            self?.technikschildSetzen(an)
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
        anhaengen(v.raum, zeilenstrich())
        // **Der Puffer — drei Faelle, keine Sekundenzahl.**
        //
        // Der Vorrat wird in Bytes gehalten: dieselben 16 MiB sind bei einer
        // 5-Mbit-Serie rund fuenfundzwanzig Sekunden und bei einem 80-Mbit-
        // Film knapp zwei. Eine Sekundenangabe waere deshalb bei jedem Titel
        // etwas anderes. Die Stufen sagen den Fall.
        anhaengen(v.raum, wertezeile(symbol: "network-wireless-signal-weak-symbolic",
                                     titel: uebersetzt("Puffer"),
                                     wert: wahlen.puffer.name, pfeil: true) {
            [weak self] in self?.listeUmschalten(.puffer)
        })
        if offeneListe == .puffer {
            anhaengen(v.raum, werteliste(Pufferstufe.allCases.map { ($0.name, $0) },
                                         gewaehlt: wahlen.puffer) { [weak self] stufe in
                self?.wahlen.pufferstufe = stufe.rawValue
                self?.wahlen.sichern()
                self?.listeSchliessen(.wiedergabe)
            })
        }
        anhaengen(rechts, v.aussen)
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
        // **„Darstellung" ist eine eigene Seite**, erreichbar ueber das Profil
        // — wie auf dem Mac (`ProfilView.swift:71`). Sie stand hier als Gruppe
        // mitten in den Einstellungen; damit lagen dieselben Einstellungen an
        // zwei Orten in verschiedener Form.

        // **Zwei Spalten, wie auf dem Mac** (`EinstellungenView.swift:18`):
        // links Offline und Integration, rechts Server. Hier stand alles
        // untereinander in einer 560 Punkt schmalen Saeule — auf einem breiten
        // Fenster sah das aus wie eine Handyansicht in der Mitte.
        let (links, rechts) = zweispalter(in: block)

        let o = einstellungsgruppe(uebersetzt("Offline"))
        anhaengen(o.raum, schalterzeile(symbol: "folder-download-symbolic",
                                        titel: uebersetzt("Downloads"),
                                        unter: uebersetzt("Titel auf diesen Rechner laden und offline schauen"),
                                        an: wahlen.downloadsAn) { [weak self] an in
            guard let self else { return }
            if an || self.downloads.posten.isEmpty {
                self.wahlen.downloadsAn = an
                self.wahlen.sichern()
                self.meinsFuellen()
            } else {
                // **H10 — Ausschalten loescht nichts ungefragt.** Die Frage
                // steht dort, wo geschaltet wurde; einen Systemdialog wie auf
                // dem Mac gibt es in dieser Oberflaeche nicht.
                self.abschaltfrageZeigen()
            }
        })
        // Die Nachfrage: verborgen, bis jemand ausschalten will.
        downloadabschaltfrage = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)
        gtk_widget_set_margin_start(downloadabschaltfrage, 14)
        gtk_widget_set_margin_end(downloadabschaltfrage, 14)
        gtk_widget_set_margin_bottom(downloadabschaltfrage, 12)
        gtk_widget_set_visible(downloadabschaltfrage, 0)
        anhaengen(o.raum, downloadabschaltfrage)

        // **„Nur ueber WLAN" gibt es auch hier** (H5). Es stand nicht da, mit
        // der Begruendung, ein Schreibtischrechner habe kein Mobilfunknetz —
        // der Mac ist auch einer und hat die Zeile trotzdem: ein Laptop haengt
        // durchaus mal an einem getakteten Anschluss.
        //
        // **Eine Bedingung, nicht zwei.** Hier standen zwei ineinander
        // geschachtelte `if wahlen.downloadsAn` mit demselben Vergleich, und
        // dazwischen ein `zeilenstrich()` zu viel — im Bild eine doppelte
        // Haarlinie ueber der WLAN-Zeile.
        if wahlen.downloadsAn {
            let b = Downloadregeln.belegung(downloads.posten)
            anhaengen(o.raum, zeilenstrich())
            anhaengen(o.raum, schalterzeile(symbol: "network-wireless-symbolic",
                                            titel: uebersetzt("Nur über WLAN"),
                                            unter: uebersetzt("Downloads warten, bis du im WLAN bist"),
                                            an: wahlen.nurUeberWLAN) { [weak self] an in
                self?.wahlen.nurUeberWLAN = an
                self?.wahlen.sichern()
            })
            anhaengen(o.raum, zeilenstrich())
            anhaengen(o.raum, wertezeile(symbol: "drive-harddisk-symbolic",
                                         titel: uebersetzt("Speicher"),
                                         unter: String(format: uebersetzt("%d Titel auf diesem Rechner"),
                                                       downloads.posten.count),
                                         wert: Downloadregeln.groesse(b.bytes)))
        }
        anhaengen(links, o.aussen)

        // **Steht zwischen Offline und Server, und das ist kein Zufall.**
        // Es ist ein zweiter Dienst, kein zweiter Server — und eine Zugabe:
        // wer nichts anbindet, sieht ausser dieser einen Zeile nirgends
        // etwas davon. Wortgleich die Begruendung des Macs.
        //
        // Sie stand hier eine Fassung lang auf der **Profilseite** neben der
        // Wiedergabe, mit dem Zeichen der Downloads daneben, und im
        // Kommentar daneben stand, der Mac mache es genauso. Er macht es
        // nicht; nachgesehen in `EinstellungenView.integration`.
        let i = einstellungsgruppe(uebersetzt("Integration"))
        anhaengen(i.raum, wertezeile(symbol: "edit-find-symbolic",
                                     titel: uebersetzt("Seerr"),
                                     unter: uebersetzt("Anfragen, was noch nicht da ist"),
                                     wert: seerrDa ? uebersetzt("Verbunden") : nil,
                                     // Wert **oder** Pfeil, nicht beides — so
                                     // steht es auf dem Mac.
                                     pfeil: !seerrDa) { [weak self] in
            self?.unterseiteOeffnen(.seerr)
        })
        // Trakt neben Seerr — nur mit Zugangsdaten im Bau (`Trakt.swift`).
        traktZeile(i.raum)
        // **Hier und nicht bei „Wiedergabe".** Die Zeilen dort sagen, *wie*
        // etwas ablaeuft; diese gibt als einzige der App etwas nach draussen.
        // Sie gehoert neben den anderen fremden Dienst.
        anhaengen(i.raum, zeilenstrich())
        anhaengen(i.raum, schalterzeile(symbol: "user-available-symbolic",
                                        titel: uebersetzt("Discord"),
                                        unter: uebersetzt("Zeigt im Profil, was gerade läuft"),
                                        an: wahlen.discordAnzeigen) { [weak self] an in
            guard let self else { return }
            self.wahlen.discordAnzeigen = an
            self.wahlen.sichern()
            if !an { Discordstand.abraeumen() }
        })
        anhaengen(links, i.aussen)

        let s = einstellungsgruppe(uebersetzt("Server"))
        anhaengen(s.raum, wertezeile(symbol: "network-server-symbolic",
                                     titel: servername.isEmpty ? uebersetzt("Server") : servername,
                                     wert: serverfassung))
        anhaengen(s.raum, zeilenstrich())
        // **Die Zeile stand da und tat nichts.** Der Mac stösst die Prüfung
        // an, zeigt „Moment …" als Wert und das Ergebnis als **Unterzeile**;
        // waehrend sie laeuft, ist die Zeile nicht anklickbar
        // (`EinstellungenView.swift:199-202`). Hier stand beides im Wertfeld,
        // und ein zweiter Klick stiess die Pruefung noch einmal an.
        let laeuft = pruefergebnis == uebersetzt("Moment …")
        let pruefzeile = wertezeile(symbol: "network-wireless-symbolic",
                                    titel: uebersetzt("Verbindung prüfen"),
                                    unter: laeuft ? nil : pruefergebnis,
                                    wert: laeuft ? pruefergebnis : nil,
                                    auswahl: laeuft ? nil : { [weak self] in
                                        self?.verbindungPruefen()
                                    })
        anhaengen(s.raum, pruefzeile)
        anhaengen(rechts, s.aussen)
        anhaengen(rechts, eigeneKoepfeBauen())

        let fuss = beschriftung("\(Fassung.voll) · libVLC \(VLCFassung.text)",
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

    /// **Ein Hoechstmass, das GTK nicht kennt.**
    ///
    /// Der Mac schreibt `frame(maxWidth: Stil.einstellungBreite)`. GTK hat
    /// dafuer nichts: `set_size_request` ist ein Mindestmass, und wer es auf
    /// 1366 setzt, zwingt das Fenster auf 1366 plus Seitenleiste.
    ///
    /// Die sichtbare Breite kennt die waagerechte Anpassung des Scrollers als
    /// `page-size`, und sie meldet jede Aenderung ueber `changed`. Der Block
    /// bekommt daraufhin genau so viel angefordert, wie er haben darf.
    ///
    /// **Nur bei echter Aenderung setzen.** Ein `set_size_request` aendert
    /// die Anpassung und loest `changed` wieder aus — ohne den Vergleich
    /// waere das eine Schleife, und von der Sorte steht schon eine in
    /// `Fallen/`.
    func deckeln(_ block: Widget!, in scroller: Widget!, auf hoechstens: Int) {
        gtk_widget_set_halign(block, GTK_ALIGN_START)
        gtk_widget_set_hexpand(block, 0)
        guard let anpassung = gtk_scrolled_window_get_hadjustment(OpaquePointer(scroller))
        else { return }
        var zuletzt: Int32 = -1
        let anpassen: () -> Void = {
            let sichtbar = gtk_adjustment_get_page_size(anpassung)
            guard sichtbar > 1 else { return }
            let frei = sichtbar - Double(Stil.randAbstand) * 2
            let breite = Int32(max(min(frei, Double(hoechstens)), 320))
            guard breite != zuletzt else { return }
            zuletzt = breite
            gtk_widget_set_size_request(block, breite, -1)
        }
        beiSignalRoh(UnsafeMutableRawPointer(anpassung), "changed", anpassen)
        anpassen()
    }

    /// **Nicht privat.** Die Seerr-Seite baute sich ihren eigenen Kopf, weil
    /// dieser hier privat war — und liess dabei ausgerechnet den Pfeil weg.
    /// Die Seite war damit eine Sackgasse: hinein ja, hinaus nur ueber die
    /// Seitenleiste. Auf dem Mac traegt sie denselben `Unterseitenkopf` wie
    /// jede andere Unterseite (`SeerrEinstellungenView.swift:27`).
    func unterseitenkopf(_ titel: String) -> Widget! {
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
    // MARK: Kontokarten

    /// **Je Server eine Karte, der verbundene zuerst.**
    ///
    /// Hier stand bis zum 13.09.2026 ein Streifen aus Kreisen — das ist die
    /// Fassung, die der Mac am 11.09.2026 durch die Karte ersetzt hat. Der
    /// Nachbau hatte sogar ihre Begründung mitkopiert, samt Verweis auf eine
    /// Rechnung namens `mittenversatz`, die es dort längst nicht mehr gibt.
    /// Genau die Falle, vor der der Übernahmeskill warnt: die Änderungsliste
    /// sagt *dass* etwas gebaut wurde, nicht *wie* es heute aussieht.
    ///
    /// **Untereinander, nicht zum Wischen.** Im Fenster ist Platz nach unten,
    /// und Wischen ist eine Geste des Fingers. Das ist die Abweichung, die
    /// Abschnitt F zulässt — Eingabeart und Fenstergröße, nicht Geschmack.
    private func kontenkarten() -> Widget! {
        let spalte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 14)
        gtk_widget_set_halign(spalte, GTK_ALIGN_FILL)
        guard let bund else { return spalte }
        let server = bund.server.sorted { a, _ in istAktiverServer(a) }
        if server.isEmpty {
            anhaengen(spalte, kontokarte(nil, bund: bund))
        } else {
            for url in server { anhaengen(spalte, kontokarte(url, bund: bund)) }
        }
        return spalte
    }

    private func istAktiverServer(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.absoluteString.lowercased()
            == bund?.aktives.serverURL.absoluteString.lowercased()
    }

    private func kontokarte(_ server: URL?, bund: Kontenbund) -> Widget! {
        let alle = server.map { bund.konten(auf: $0) } ?? bund.konten
        let aktiv = istAktiverServer(server)
        // Auf dem verbundenen Server steht vorn, wer angemeldet ist; auf einem
        // anderen das erste Konto dort — ein Klick wechselt dorthin.
        let vorn: Session? = aktiv ? bund.aktives : alle.first
        let andere = alle.filter { $0.kontoschluessel != vorn?.kontoschluessel }

        let karte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(karte, "swiftly-kontokarte")
        // **Den Akzentrand nur, wenn es etwas zu unterscheiden gibt** (D10).
        // Bei einem einzigen Server wäre er eine Auszeichnung ohne Gegenstück.
        if aktiv, bund.server.count > 1 {
            gtk_widget_add_css_class(karte, "swiftly-aktiv")
        }
        anhaengen(karte, kartenkopf(vorn, aktiv: aktiv, server: server))
        let strich: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(strich, "swiftly-trennlinie")
        gtk_widget_set_size_request(strich, -1, 1)
        anhaengen(karte, strich)
        anhaengen(karte, kartenreihe(andere, aktiv: aktiv, server: server))
        return karte
    }

    /// Bild 56, daneben Name, Server und Fassung. Beim fremden Server ist die
    /// ganze Zeile ein Knopf, beim verbundenen reiner Text.
    private func kartenkopf(_ konto: Session?, aktiv: Bool, server: URL?) -> Widget! {
        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
        gtk_widget_set_margin_start(zeile, 16)
        gtk_widget_set_margin_end(zeile, 16)
        gtk_widget_set_margin_top(zeile, 16)
        gtk_widget_set_margin_bottom(zeile, 16)

        let mehrfach = (bund?.server.count ?? 0) > 1
        let teile = profilzeichen(name: konto?.userName ?? "?", kante: 56,
                                  stil: aktiv && mehrfach ? "swiftly-kontoaktiv"
                                                          : "swiftly-profilgross",
                                  schriftstil: "swiftly-zeichen72")
        anhaengen(zeile, teile.huelle)
        if let konto {
            profilbildLaden(teile, url: adressen?.benutzer(konto.userID, kante: 200),
                            schluessel: "konto-\(konto.userID)")
        }

        let texte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)
        gtk_widget_set_valign(texte, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(texte, 1)
        let name = beschriftung(konto?.userName ?? uebersetzt("Angemeldet"),
                                stil: "swiftly-kontoname")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        anhaengen(texte, name)

        // **Name und Fassung kennen wir nur vom Server, mit dem wir gerade
        // verbunden sind**; bei den anderen steht die Adresse.
        let zweite = aktiv ? (servername.isEmpty ? (server?.host() ?? "") : servername)
                           : (server?.host() ?? "")
        let z = beschriftung(zweite, stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(z, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(z), 0)
        gtk_label_set_ellipsize(OpaquePointer(z), PANGO_ELLIPSIZE_END)
        anhaengen(texte, z)

        if aktiv, !serverfassung.isEmpty {
            let f = beschriftung("Jellyfin \(serverfassung)", stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(f, "swiftly-leise")
            gtk_label_set_xalign(OpaquePointer(f), 0)
            anhaengen(texte, f)
        } else if !aktiv {
            // **„Klicken", nicht „Antippen"** — Maus und Tastatur, Abschnitt F.
            let f = beschriftung(uebersetzt("Klicken zum Wechseln"), stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(f, "swiftly-leise")
            gtk_label_set_xalign(OpaquePointer(f), 0)
            anhaengen(texte, f)
        }
        anhaengen(zeile, texte)

        guard !aktiv, let konto else { return zeile }
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-kontoknopf")
        gtk_button_set_child(alsKnopf(knopf), zeile)
        let schluessel = konto.kontoschluessel
        beiSignal(knopf, "clicked") { [weak self] in self?.kontoWechseln(zu: schluessel) }
        return knopf
    }

    /// Die übrigen Konten dieses Servers, dahinter das Plus.
    private func kartenreihe(_ andere: [Session], aktiv: Bool, server: URL?) -> Widget! {
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
        gtk_widget_set_margin_start(reihe, 16)
        gtk_widget_set_margin_end(reihe, 16)
        gtk_widget_set_margin_top(reihe, 12)
        gtk_widget_set_margin_bottom(reihe, 12)

        for konto in andere {
            let knopf: Widget! = gtk_button_new()
            gtk_widget_add_css_class(knopf, "swiftly-kontoknopf")
            let teile = profilzeichen(name: konto.userName, kante: 40,
                                      stil: "swiftly-kontoandere",
                                      schriftstil: "swiftly-zeichen26")
            gtk_button_set_child(alsKnopf(knopf), teile.huelle)
            gtk_widget_set_tooltip_text(knopf, konto.userName)
            profilbildLaden(teile, url: adressen?.benutzer(konto.userID, kante: 200),
                            schluessel: "konto-\(konto.userID)")
            let schluessel = konto.kontoschluessel
            beiSignal(knopf, "clicked") { [weak self] in self?.kontoWechseln(zu: schluessel) }
            anhaengen(reihe, knopf)
        }

        // **Das Plus steht auf jeder Karte** und legt ein Konto auf *diesem*
        // Server an. Auf dem verbundenen die gewohnte Anmeldung, auf einem
        // anderen dieselbe wie beim Hinzufügen eines Servers, nur mit schon
        // eingetragener Adresse. Es stand auf dem Mac vorher nur auf der Karte
        // des verbundenen Servers; wer ein Konto anderswo anlegen wollte,
        // musste erst dorthin wechseln.
        let plus: Widget! = gtk_button_new()
        gtk_widget_add_css_class(plus, "swiftly-kontoplus")
        gtk_widget_set_size_request(plus, 40, 40)
        gtk_button_set_child(alsKnopf(plus), gtk_image_new_from_icon_name("list-add-symbolic"))
        gtk_widget_set_tooltip_text(plus, uebersetzt("Weiteres Konto hinzufügen"))
        beiSignal(plus, "clicked") { [weak self] in
            guard let self else { return }
            if aktiv { self.unterseiteOeffnen(.kontoHinzufuegen) }
            else if let server { self.serverAufnahmeOeffnen(server) }
        }
        anhaengen(reihe, plus)

        let luft: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_set_hexpand(luft, 1)
        anhaengen(reihe, luft)
        return reihe
    }

    // MARK: Darstellung — die Startseite einstellen

    /// **Welche Reihen, in welcher Folge, und Genres als Reihen oder Chips.**
    ///
    /// Auf Linux war die Startseite fest verdrahtet. Die Rechnung dahinter
    /// liegt als ``Startreihenfolge`` im Paket, damit dieselbe Ablage auf
    /// jeder Plattform dasselbe ergibt.
    private func darstellungBauen(_ block: Widget!) {
        anhaengen(block, unterseitenkopf(uebersetzt("Darstellung")))

        // Zwei Spalten wie auf dem Mac (`macOS/DarstellungView.swift:37`):
        // links Allgemein, Reihen und Neuzugaenge, rechts die Genres.
        let (links, rechts) = zweispalter(in: block)

        // **Allgemein** — dieselbe Rubrik wie auf Apple
        // (`DarstellungView.swift:79`).
        let ga = einstellungsgruppe(uebersetzt("Allgemein"))
        anhaengen(ga.raum, schalterzeile(symbol: "view-list-symbolic",
                                         titel: uebersetzt("Fortschritt auf Kacheln"),
                                         an: wahlen.fortschrittAufKacheln) { [weak self] an in
            self?.wahlen.fortschrittAufKacheln = an
            self?.wahlen.sichern()
            // Die Startseite steht schon; ohne Neubau galt der Schalter erst
            // beim naechsten Laden (M8). Raster bauen sich beim Oeffnen neu.
            self?.startseiteLaden()
        })
        anhaengen(links, ga.aussen)
        anhaengen(links, luftHoch(26))

        // **„Reihen" ueber der Liste, „Neuzugaenge" darunter** — die
        // Reihenfolge des Macs (`DarstellungView.swift:110`). Der Schalter
        // stand hier ueber den Reihen und schob sie damit unter eine
        // Ueberschrift, zu der sie nicht gehoeren.
        // **Eine Gruppe, nicht Ueberschrift und Karte getrennt.** Der Mac
        // legt die Reihen in dieselbe `Einstellungsgruppe` wie ihre
        // Ueberschrift (`DarstellungView.swift:76`); hier stand die
        // Ueberschrift in einer leeren Gruppe und die Liste in einer zweiten
        // Karte darunter, mit einer sichtbaren Fuge dazwischen.
        //
        // **Umsortiert wird mit dem, was die Eingabeart hergibt** — auf dem
        // iPhone Griffe, hier zwei Pfeile je Zeile. Abschnitt F erlaubt genau
        // diesen Unterschied; Ziehen mit der Maus über eine Liste, die auch
        // ausblenden kann, wäre zwei Gesten an derselben Zeile.
        let g0 = einstellungsgruppe(uebersetzt("Reihen"))
        let sichtbar = Startreihenfolge.geltend(abgelegt: wahlen.startReihen)
            .filter { $0.passt(getrennt: wahlen.neuzugaengeGetrennt) }
        for (stelle, reihe) in sichtbar.enumerated() {
            if stelle > 0 { anhaengen(g0.raum, zeilenstrich()) }
            anhaengen(g0.raum, reihenzeile(reihe, stelle: stelle, von: sichtbar.count))
        }
        anhaengen(links, g0.aussen)

        let gn = einstellungsgruppe(uebersetzt("Neuzugänge"))
        anhaengen(gn.raum, schalterzeile(symbol: "folder-new-symbolic",
                                         titel: uebersetzt("Neuzugänge getrennt"),
                                         unter: uebersetzt("Neue Filme und neue Serien in eigenen Reihen"),
                                         an: wahlen.neuzugaengeGetrennt) { [weak self] an in
            self?.wahlen.neuzugaengeGetrennt = an
            self?.wahlen.sichern()
            self?.geladen.remove(.start)
            self?.unterseiteOeffnen(.darstellung)
        })

        let fuss1 = beschriftung(uebersetzt("Mit den Pfeilen umsortieren. Was aus ist, steht nicht auf der Startseite."),
                                 stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(fuss1, "swiftly-sehrleise")
        gtk_label_set_xalign(OpaquePointer(fuss1), 0)
        gtk_label_set_justify(OpaquePointer(fuss1), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(fuss1, 8)
        anhaengen(links, fuss1)
        anhaengen(links, luftHoch(26))
        anhaengen(links, gn.aussen)

        anhaengen(links, luftHoch(26))

        // **Zwei Formen derselben Auswahl**, nicht zwei Mengen. Wie die
        // übrigen Zeilen der Karte: ein Symbol, das die Form zeigt, kein
        // Auswahl-Kreis — der Haken steht rechts.
        let g2 = einstellungsgruppe(uebersetzt("Genres"))
        anhaengen(g2.raum, wertezeile(symbol: "view-grid-symbolic",
                                      titel: uebersetzt("Als eigene Reihen"),
                                      haken: !wahlen.genreChips) { [weak self] in
            self?.wahlen.genreChips = false
            self?.wahlen.sichern()
            self?.geladen.remove(.start)
            self?.unterseiteOeffnen(.darstellung)
        })
        anhaengen(g2.raum, zeilenstrich())
        anhaengen(g2.raum, wertezeile(symbol: "view-continuous-symbolic",
                                      titel: uebersetzt("Als Chips über den Reihen"),
                                      haken: wahlen.genreChips) { [weak self] in
            self?.wahlen.genreChips = true
            self?.wahlen.sichern()
            self?.geladen.remove(.start)
            self?.unterseiteOeffnen(.darstellung)
        })
        // **Eine Karte, nicht drei.** Auf dem Mac stehen die beiden Formen,
        // die gewaehlten Genres und „Genre hinzufuegen" in **einer**
        // `Einstellungsgruppe` (`DarstellungView.swift:118-147`) — deshalb
        // laeuft der Trennstrich zwischen ihnen durch und nicht ein Spalt.
        for (stelle, name) in wahlen.startGenres.enumerated() {
            anhaengen(g2.raum, zeilenstrich())
            anhaengen(g2.raum, genrezeile(name, stelle: stelle,
                                          von: wahlen.startGenres.count))
        }
        // Der Strich vor „Genre hinzufuegen" laeuft auf dem Mac ueber die
        // volle Breite (`Trennstrich()` ohne Einzug, `:142`) — er trennt
        // nicht zwei gleichartige Zeilen, sondern die Liste von ihrem Zugang.
        anhaengen(g2.raum, trennlinie())
        // **Im Akzent.** `Wertezeile(..., akzent: true, ...)` auf dem Mac
        // (`DarstellungView.swift:144-146`).
        anhaengen(g2.raum, wertezeile(symbol: "list-add-symbolic",
                                      titel: uebersetzt("Genre hinzufügen"),
                                      akzent: true,
                                      pfeil: true) { [weak self] in
            self?.unterseiteOeffnen(.genrewahl)
        })
        anhaengen(rechts, g2.aussen)
    }

    /// Eine Reihe in der Liste: Name, Schalter, zwei Pfeile.
    private func reihenzeile(_ reihe: Startreihe, stelle: Int, von: Int) -> Widget! {
        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        // **Derselbe Rumpf wie jede andere Zeile.** Er trug eigene 14/10 und
        // war damit als einziger in der Karte hoeher als „Fortschritt auf
        // Kacheln" daneben — auf dem Mac ist `Wahlzeile` dieselbe
        // 44-Punkt-Zeile wie `Schalterzeile`
        // (`Sources/macOS/Einstellungszeilen.swift`).
        gtk_widget_add_css_class(zeile, "swiftly-zeilenrumpf")

        // **Mit Zeichen wie jede andere Zeile der App.** Ohne es sah die
        // Reihenliste als einzige anders aus.
        let bild: Widget! = gtk_image_new_from_icon_name(reihe.zeichen)
        gtk_image_set_pixel_size(OpaquePointer(bild), 15)
        gtk_widget_set_size_request(bild, 22, -1)
        anhaengen(zeile, bild)
        let name = beschriftung(uebersetzt(reihe.listenname), stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_widget_set_hexpand(name, 1)
        anhaengen(zeile, name)

        let hoch = listenpfeil("go-up-symbolic", an: stelle > 0) { [weak self] in
            self?.reiheVerschieben(reihe, um: -1)
        }
        anhaengen(zeile, hoch)
        let runter = listenpfeil("go-down-symbolic", an: stelle < von - 1) { [weak self] in
            self?.reiheVerschieben(reihe, um: 1)
        }
        anhaengen(zeile, runter)

        let an = !wahlen.startAus.contains(reihe.rawValue)
        anhaengen(zeile, kleinerSchalter(an: an) { [weak self] neu in
            guard let self else { return }
            if neu { self.wahlen.startAus.removeAll { $0 == reihe.rawValue } }
            else { self.wahlen.startAus.append(reihe.rawValue) }
            self.wahlen.sichern()
            self.geladen.remove(.start)
        })
        return zeile
    }

    private func reiheVerschieben(_ reihe: Startreihe, um schritt: Int) {
        wahlen.startReihen = Startreihenfolge.verschoben(reihe, um: schritt,
                                                         abgelegt: wahlen.startReihen,
                                                         getrennt: wahlen.neuzugaengeGetrennt)
        wahlen.sichern()
        geladen.remove(.start)
        unterseiteOeffnen(.darstellung)
    }

    /// Ein gewähltes Genre: Name und ein Weg, es wieder loszuwerden.
    /// - Parameters:
    ///   - stelle: Wo das Genre in der Liste steht — für die beiden Pfeile.
    ///   - von: Wie viele es insgesamt sind.
    ///
    /// **Mit Pfeilen, wie die Startreihen darüber.** Der Mac lässt Genres
    /// ziehen (`DarstellungView.swift:136-140`, `genreAblegen` `:153-161`);
    /// hier gibt es dafür zwei Pfeile, genau wie bei den Reihen — dieselbe
    /// Abweichung aus derselben Begründung (Abschnitt F, Eingabeart).
    /// `genrezeile` hatte nur den Entfernen-Pfeil, obwohl `reihenzeile` drei
    /// Zeilen weiter oben vormacht, wie es geht.
    private func genrezeile(_ name: String, stelle: Int, von: Int) -> Widget! {
        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        gtk_widget_add_css_class(zeile, "swiftly-zeilenrumpf")
        // **Der Name kommt vom Server** und wird nicht übersetzt (E7).
        let l = beschriftung(name, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        anhaengen(zeile, l)
        anhaengen(zeile, listenpfeil("go-up-symbolic", an: stelle > 0) { [weak self] in
            self?.genreVerschieben(name, um: -1)
        })
        anhaengen(zeile, listenpfeil("go-down-symbolic", an: stelle < von - 1) { [weak self] in
            self?.genreVerschieben(name, um: 1)
        })
        let weg = listenpfeil("list-remove-symbolic", an: true) { [weak self] in
            guard let self else { return }
            self.wahlen.startGenres.removeAll { $0 == name }
            self.wahlen.sichern()
            self.geladen.remove(.start)
            self.unterseiteOeffnen(.darstellung)
        }
        anhaengen(zeile, weg)
        return zeile
    }

    /// Verschiebt ein Genre um eine Stelle. Die gezogene rückt an die Stelle
    /// der, auf der sie landet — wörtlich `genreAblegen` auf dem Mac.
    private func genreVerschieben(_ name: String, um schritt: Int) {
        var liste = wahlen.startGenres
        guard let von = liste.firstIndex(of: name) else { return }
        let nach = von + schritt
        guard nach >= 0, nach < liste.count else { return }
        liste.remove(at: von)
        liste.insert(name, at: nach)
        wahlen.startGenres = liste
        wahlen.sichern()
        geladen.remove(.start)
        unterseiteOeffnen(.darstellung, schub: .ohne)
    }

    /// Die freien Genres des Servers.
    private func genrewahlBauen(_ block: Widget!) {
        anhaengen(block, unterseitenkopf(uebersetzt("Genre hinzufügen")))
        let gruppe = zeilengruppe()
        anhaengen(block, gruppe.aussen)
        let raum = gruppe.raum
        let schon = Set(wahlen.startGenres)
        guard let client else { return }
        let kiste = gehalten(raum)
        Task.detached { [self] in
            let alle = (try? await client.gattungen()) ?? []
            aufHauptfaden {
                defer { losgelassen(kiste) }
                let frei = alle.filter { !schon.contains($0) }
                guard !frei.isEmpty else {
                    let text = alle.isEmpty
                        ? uebersetzt("Auf deinem Server sind keine Genres hinterlegt.")
                        : uebersetzt("Alle Genres stehen schon auf der Startseite.")
                    let l = beschriftung(text, stil: "swiftly-koerper", umbruch: true)
                    gtk_widget_set_margin_start(l, 14)
                    gtk_widget_set_margin_top(l, 12)
                    gtk_widget_set_margin_bottom(l, 12)
                    anhaengen(kiste.widget, l)
                    return
                }
                for (stelle, name) in frei.enumerated() {
                    if stelle > 0 { anhaengen(kiste.widget, zeilenstrich()) }
                    anhaengen(kiste.widget, wertezeile(symbol: "tag-symbolic", titel: name) {
                        [weak self] in
                        guard let self else { return }
                        self.wahlen.startGenres.append(name)
                        self.wahlen.sichern()
                        self.geladen.remove(.start)
                        self.unterseiteOeffnen(.darstellung)
                    })
                }
            }
        }
    }

    // MARK: Ein zweiter Server

    /// Öffnet die Aufnahme — ohne Adresse für einen neuen Server, mit Adresse
    /// für ein weiteres Konto auf einem schon bekannten.
    func serverAufnahmeOeffnen(_ voreingestellt: URL?) {
        serverAufnahmeAdresse = voreingestellt?.absoluteString ?? ""
        serverAufnahmeGeprueft = nil
        serverAufnahmeFehler = ""
        serverAufnahmeVorgegeben = voreingestellt != nil
        kontoPerCode = false
        unterseiteOeffnen(.serverAufnahme)
    }

    /// **Adresse prüfen, dann anmelden — im Fenster, nicht als Blatt.**
    ///
    /// Auf dem Mac steht beides untereinander auf einer Seite (`macOS/
    /// ServerAufnahmeView.swift`), und die Begründung gilt hier genauso: ein
    /// Blatt über einem halb ausgefüllten Formular nähme die Angabe weg, an
    /// welchem Server man sich gerade anmeldet.
    private func serverAufnahmeBauen(_ block: Widget!) {
        let neuerServer = !serverAufnahmeVorgegeben
        anhaengen(block, unterseitenkopf(neuerServer ? uebersetzt("Server hinzufügen")
                                                     : uebersetzt("Weiteres Konto")))

        let satz = beschriftung(neuerServer
            ? uebersetzt("Ein zweiter Jellyfin mit eigenen Konten. Beide bleiben angemeldet; auf der Profilseite wechselst du zwischen ihnen.")
            : uebersetzt("Ein weiteres Konto auf diesem Server. Beide bleiben angemeldet; auf der Profilseite wechselst du zwischen ihnen."),
            stil: "swiftly-koerper", umbruch: true)
        gtk_widget_add_css_class(satz, "dim-label")
        gtk_label_set_xalign(OpaquePointer(satz), 0)
        gtk_widget_set_margin_top(satz, 14)
        anhaengen(block, satz)

        if let geprueft = serverAufnahmeGeprueft {
            // **Was geprüft ist, steht als Haken da** — nicht als Feld, das
            // man noch einmal ausfüllen könnte.
            let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
            gtk_widget_set_margin_top(zeile, 22)
            let haken: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
            gtk_widget_add_css_class(haken, "swiftly-akzentzeile")
            anhaengen(zeile, haken)
            let text = beschriftung(geprueft, stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(text, "swiftly-leise")
            gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
            anhaengen(zeile, text)
            anhaengen(block, zeile)
            if kontoPerCode { kontoCodeteil(block) } else { serverAufnahmeFormular(block) }
            return
        }

        let feld = eingabezeile(symbol: "network-server-symbolic",
                                platzhalter: uebersetzt("jellyfin.beispiel.de"), dehnt: true)
        gtk_widget_set_margin_top(feld, 26)
        gtk_editable_set_text(OpaquePointer(feld), serverAufnahmeAdresse)
        anhaengen(block, feld)

        // „Erweitert" — eigene Header fuer einen Dienst vor dem Server.
        let (erweitert, leser) = erweitertBauen(vorhanden: [])
        anhaengen(block, erweitert)

        serverAufnahmeStand = beschriftung(serverAufnahmeFehler, stil: "swiftly-zweitzeile",
                                           umbruch: true)
        gtk_widget_add_css_class(serverAufnahmeStand, "swiftly-warnung")
        gtk_label_set_xalign(OpaquePointer(serverAufnahmeStand), 0)
        gtk_widget_set_visible(serverAufnahmeStand, serverAufnahmeFehler.isEmpty ? 0 : 1)
        gtk_widget_set_margin_top(serverAufnahmeStand, 12)
        anhaengen(block, serverAufnahmeStand)

        serverAufnahmeKnopf = hauptknopf(uebersetzt("Weiter"))
        let knopf: Widget! = serverAufnahmeKnopf
        gtk_widget_set_margin_top(knopf, 22)
        gtk_widget_set_sensitive(knopf, serverAufnahmeAdresse.isEmpty ? 0 : 1)
        anhaengen(block, knopf)

        let tun: () -> Void = { [weak self] in
            guard let self else { return }
            self.serverAufnahmeKoepfe = leser.koepfe()
            self.serverPruefen(self.text(feld))
        }
        beiSignal(knopf, "clicked", tun)
        beiSignal(feld, "activate", tun)
        beiSignal(feld, "changed") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(knopf, self.text(feld).isEmpty ? 0 : 1)
        }

        // Kam die Adresse mit, gibt es nichts einzutippen — dann sofort prüfen.
        if serverAufnahmeVorgegeben, !serverAufnahmeAdresse.isEmpty {
            let adresse = serverAufnahmeAdresse
            aufHauptfaden { [weak self] in self?.serverPruefen(adresse) }
        }
    }

    /// Name und Passwort für den **neuen** Server.
    private func serverAufnahmeFormular(_ block: Widget!) {
        let name = eingabezeile(symbol: "avatar-default-symbolic",
                                platzhalter: uebersetzt("Benutzername"), dehnt: true)
        gtk_widget_set_margin_top(name, 26)
        anhaengen(block, name)

        let wort = eingabezeile(symbol: "channel-secure-symbolic",
                                platzhalter: uebersetzt("Passwort"), geheim: true, dehnt: true)
        gtk_widget_set_margin_top(wort, 10)
        anhaengen(block, wort)

        serverAufnahmeStand = beschriftung(serverAufnahmeFehler, stil: "swiftly-zweitzeile",
                                           umbruch: true)
        gtk_widget_add_css_class(serverAufnahmeStand, "swiftly-warnung")
        gtk_label_set_xalign(OpaquePointer(serverAufnahmeStand), 0)
        gtk_widget_set_visible(serverAufnahmeStand, serverAufnahmeFehler.isEmpty ? 0 : 1)
        gtk_widget_set_margin_top(serverAufnahmeStand, 12)
        anhaengen(block, serverAufnahmeStand)

        serverAufnahmeKnopf = hauptknopf(uebersetzt("Anmelden"))
        let knopf: Widget! = serverAufnahmeKnopf
        gtk_widget_set_margin_top(knopf, 22)
        gtk_widget_set_sensitive(knopf, 0)
        anhaengen(block, knopf)

        let tun: () -> Void = { [weak self] in
            guard let self else { return }
            self.amNeuenServerAnmelden(benutzer: self.text(name), passwort: self.text(wort))
        }
        beiSignal(knopf, "clicked", tun)
        beiSignal(wort, "activate", tun)
        beiSignal(name, "activate") { gtk_widget_grab_focus(wort) }
        beiSignal(name, "changed") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(knopf, self.text(name).isEmpty ? 0 : 1)
        }

        anhaengen(block, trennerMitOder())

        let umschalten: Widget! = gtk_button_new_with_label(uebersetzt("Mit Quick Connect anmelden"))
        gtk_widget_add_css_class(umschalten, "swiftly-umriss")
        gtk_widget_set_margin_top(umschalten, 18)
        beiSignal(umschalten, "clicked") { [weak self] in
            guard let self else { return }
            self.serverAufnahmeFehler = ""
            self.kontoPerCode = true
            self.unterseiteOeffnen(.serverAufnahme, schub: .ohne)
        }
        anhaengen(block, umschalten)
    }

    // MARK: Weiteres Konto

    /// Ein zweites Jellyfin-Konto auf demselben Server.
    ///
    /// **Eine eigene Seite, nicht der Anmeldeschirm.** Der erste Anlauf hat
    /// einfach die Anmeldung wiederverwendet, und das sah aus wie ein Fehler:
    /// Wortmarke und Servername wie beim Neustart, und der Quick-Connect-Code
    /// stand in der Zeile, in der sonst Fehlermeldungen stehen — orange, unter
    /// dem Passwortfeld. „Code 812464 — approve it on a signed-in device" las
    /// sich damit wie eine Stoerung statt wie eine Anweisung.
    ///
    /// Vorlage ist `Sources/macOS/ProfilView.swift`, `KontoHinzufuegenView`:
    /// Kopf mit Zurueck, ein Satz, der sagt was passiert, der Server als
    /// **Anzeige** statt als Feld, Name und Passwort als Normalweg, Quick
    /// Connect als Umschalter daneben — und der Code in einem eigenen Teil.
    private func kontoHinzufuegenBauen(_ block: Widget!) {
        anhaengen(block, unterseitenkopf(uebersetzt("Weiteres Konto")))

        let satz = beschriftung(uebersetzt("Ein zweites Jellyfin-Konto auf demselben Server. Beide bleiben angemeldet; oben auf der Profilseite wechselst du zwischen ihnen."),
                                stil: "swiftly-koerper", umbruch: true)
        gtk_widget_add_css_class(satz, "dim-label")
        gtk_label_set_xalign(OpaquePointer(satz), 0)
        gtk_label_set_justify(OpaquePointer(satz), GTK_JUSTIFY_LEFT)
        gtk_widget_set_margin_top(satz, 14)
        anhaengen(block, satz)

        // **Wohin das Konto kommt — Anzeige, kein Feld.** Ein Bund gehoert zu
        // genau einem Server; ihn hier noch einmal eintippen zu lassen waere
        // eine Frage, deren Antwort feststeht.
        let serverreihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        gtk_widget_set_margin_top(serverreihe, 22)
        let symbol: Widget! = gtk_image_new_from_icon_name("network-server-symbolic")
        gtk_widget_add_css_class(symbol, "swiftly-sehrleise")
        anhaengen(serverreihe, symbol)
        var wohin: [String] = []
        if !servername.isEmpty { wohin.append(servername) }
        if let url = bund?.serverURL { wohin.append(url.absoluteString) }
        let serverzeile2 = beschriftung(wohin.joined(separator: " · "), stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(serverzeile2, "swiftly-sehrleise")
        gtk_widget_set_valign(serverzeile2, GTK_ALIGN_CENTER)
        anhaengen(serverreihe, serverzeile2)
        anhaengen(block, serverreihe)

        if kontoPerCode { kontoCodeteil(block) } else { kontoFormular(block) }
    }

    /// Name und Passwort — der Normalweg auf dem Schreibtisch.
    private func kontoFormular(_ block: Widget!) {
        let name = eingabezeile(symbol: "avatar-default-symbolic",
                                platzhalter: uebersetzt("Benutzername"), dehnt: true)
        gtk_widget_set_margin_top(name, 26)
        anhaengen(block, name)

        let wort = eingabezeile(symbol: "channel-secure-symbolic",
                               platzhalter: uebersetzt("Passwort"), geheim: true, dehnt: true)
        gtk_widget_set_margin_top(wort, 10)
        anhaengen(block, wort)

        // **„Läuft ab in 4:58"** — der Mac zeigt die Restzeit sekundenweise
        // (`ProfilView.swift:366-370`, `ServerAufnahmeView.swift:194-197`).
        // Hier lief die Fuenf-Minuten-Grenze nur intern als Zaehler; wer den
        // Code las, wusste nicht, wie lange er noch gilt.
        kontoRestfeld = beschriftung("", stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(kontoRestfeld, "swiftly-sehrleise")
        gtk_label_set_xalign(OpaquePointer(kontoRestfeld), 0)
        gtk_widget_set_margin_top(kontoRestfeld, 14)
        gtk_widget_set_visible(kontoRestfeld, 0)
        anhaengen(block, kontoRestfeld)

        kontoStandfeld = beschriftung(kontoFehler, stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(kontoStandfeld, "swiftly-warnung")
        gtk_label_set_xalign(OpaquePointer(kontoStandfeld), 0)
        gtk_widget_set_visible(kontoStandfeld, kontoFehler.isEmpty ? 0 : 1)
        gtk_widget_set_margin_top(kontoStandfeld, 12)
        anhaengen(block, kontoStandfeld)

        kontoKnopf = hauptknopf(uebersetzt("Hinzufügen"))
        let knopf: Widget! = kontoKnopf
        gtk_widget_set_margin_top(knopf, 22)
        gtk_widget_set_sensitive(knopf, 0)
        anhaengen(block, knopf)

        let tun: () -> Void = { [weak self] in
            guard let self else { return }
            self.kontoAnmelden(benutzer: self.text(name), passwort: self.text(wort))
        }
        beiSignal(knopf, "clicked", tun)
        beiSignal(wort, "activate", tun)
        beiSignal(name, "activate") { gtk_widget_grab_focus(wort) }
        beiSignal(name, "changed") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(knopf, self.text(name).isEmpty ? 0 : 1)
        }

        anhaengen(block, trennerMitOder())

        let umschalten: Widget! = gtk_button_new_with_label(uebersetzt("Mit Quick Connect anmelden"))
        gtk_widget_add_css_class(umschalten, "swiftly-umriss")
        gtk_widget_set_margin_top(umschalten, 18)
        beiSignal(umschalten, "clicked") { [weak self] in
            guard let self else { return }
            self.kontoFehler = ""
            self.kontoPerCode = true
            self.unterseiteOeffnen(.kontoHinzufuegen, schub: .ohne)
        }
        anhaengen(block, umschalten)

        gtk_widget_grab_focus(name)
    }

    /// Quick Connect — **der Code bekommt einen eigenen Teil.**
    ///
    /// Er wird auch erst hier geholt, nicht beim Oeffnen der Seite: sonst zoege
    /// jeder Besuch einen Code beim Server, den niemand braucht.
    private func kontoCodeteil(_ block: Widget!) {
        let satz = beschriftung(uebersetzt("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist."),
                                stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(satz, "dim-label")
        gtk_label_set_xalign(OpaquePointer(satz), 0)
        gtk_widget_set_margin_top(satz, 26)
        anhaengen(block, satz)

        // **Ein Klick legt den Code in die Zwischenablage.** Sechs Ziffern
        // abzutippen, die man gerade vor sich hat, ist die Art Arbeit, die
        // eine App abnehmen kann. Auf tvOS gibt es das nicht — dort gibt es
        // keine Zwischenablage.
        kontoCodefeld = beschriftung(kontoCode.isEmpty ? "······" : kontoCode,
                                     stil: "swiftly-codegross")
        let codeknopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(codeknopf, "swiftly-blank")
        gtk_button_set_child(alsKnopf(codeknopf), kontoCodefeld)
        // **Ueber die volle Breite.** Er stand linksbuendig und war damit nur
        // so breit wie sechs Ziffern; der Mac setzt `frame(maxWidth:
        // .infinity)` (`ProfilView.swift:358`).
        gtk_widget_set_halign(codeknopf, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(codeknopf, 1)
        gtk_widget_set_margin_top(codeknopf, 14)
        gtk_widget_set_tooltip_text(codeknopf, uebersetzt("Code kopieren"))
        beiSignal(codeknopf, "clicked") { [weak self] in
            guard let self, !self.kontoCode.isEmpty else { return }
            inZwischenablage(self.kontoCode, an: codeknopf)
            self.melden(uebersetzt("Code kopiert."))
        }
        anhaengen(block, codeknopf)

        kontoStandfeld = beschriftung(kontoFehler, stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(kontoStandfeld, "swiftly-warnung")
        gtk_label_set_xalign(OpaquePointer(kontoStandfeld), 0)
        gtk_widget_set_visible(kontoStandfeld, kontoFehler.isEmpty ? 0 : 1)
        gtk_widget_set_margin_top(kontoStandfeld, 14)
        anhaengen(block, kontoStandfeld)

        let zurueck: Widget! = gtk_button_new_with_label(uebersetzt("Lieber Name und Passwort"))
        gtk_widget_add_css_class(zurueck, "swiftly-umriss")
        gtk_widget_set_margin_top(zurueck, 22)
        beiSignal(zurueck, "clicked") { [weak self] in
            guard let self else { return }
            self.kontoCodelauf?.cancel()
            self.kontoCodelauf = nil
            self.kontoCode = ""
            self.kontoFehler = ""
            self.kontoPerCode = false
            self.unterseiteOeffnen(.kontoHinzufuegen, schub: .ohne)
        }
        anhaengen(block, zurueck)

        if kontoCode.isEmpty && kontoCodelauf == nil { kontoCodeHolen() }
    }

    private func trennerMitOder() -> Widget! {
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        gtk_widget_set_margin_top(reihe, 18)
        let links: Widget! = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)
        gtk_widget_set_hexpand(links, 1)
        gtk_widget_set_valign(links, GTK_ALIGN_CENTER)
        anhaengen(reihe, links)
        let wort = beschriftung(uebersetzt("oder"), stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(wort, "swiftly-sehrleise")
        anhaengen(reihe, wort)
        let rechts: Widget! = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)
        gtk_widget_set_hexpand(rechts, 1)
        gtk_widget_set_valign(rechts, GTK_ALIGN_CENTER)
        anhaengen(reihe, rechts)
        return reihe
    }

}

// MARK: - H10: Ausschalten loescht nichts ungefragt

extension App {

    /// **Die Frage steht dort, wo geschaltet wurde.**
    ///
    /// Auf dem Mac ist sie ein Systemdialog — „die Frage gehoert zum Fenster,
    /// nicht zu einer Zeile darin". Diese Oberflaeche benutzt keine
    /// Systemdialoge; einen dafuer einzufuehren waere ein Fremdkoerper (E4).
    /// Die Antwortmoeglichkeiten sind dieselben drei: behalten, alles
    /// entfernen, abbrechen.
    func abschaltfrageZeigen() {
        guard downloadabschaltfrage != nil else { return }
        leeren(downloadabschaltfrage)

        let b = Downloadregeln.belegung(downloads.posten)
        let text = String(format: uebersetzt("%d Titel liegen auf diesem Rechner (%@). Was soll damit geschehen?"),
                          b.anzahl, Downloadregeln.groesse(b.bytes))
        let l = beschriftung(text, stil: "swiftly-zweitzeile", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        anhaengen(downloadabschaltfrage, l)

        let knoepfe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)

        let behalten = chip(uebersetzt("Behalten"), aktiv: true)
        beiSignal(behalten, "clicked") { [weak self] in
            guard let self else { return }
            self.wahlen.downloadsAn = false
            self.wahlen.sichern()
            self.downloads.allesAnhalten()
            self.meinsFuellen()
            self.abschaltfrageWeg()
            self.unterseiteOeffnen(.einstellungen)
        }
        anhaengen(knoepfe, behalten)

        let weg = chip(uebersetzt("Alles entfernen"), symbol: "user-trash-symbolic")
        beiSignal(weg, "clicked") { [weak self] in
            guard let self else { return }
            self.downloads.allesEntfernen()
            self.wahlen.downloadsAn = false
            self.wahlen.sichern()
            self.meinsFuellen()
            self.abschaltfrageWeg()
            self.unterseiteOeffnen(.einstellungen)
        }
        anhaengen(knoepfe, weg)

        let ab = chip(uebersetzt("Abbrechen"))
        beiSignal(ab, "clicked") { [weak self] in
            // Der Schalter ist beim Tippen schon umgesprungen; wer abbricht,
            // will ihn zurueck.
            self?.abschaltfrageWeg()
            self?.unterseiteOeffnen(.einstellungen)
        }
        anhaengen(knoepfe, ab)

        anhaengen(downloadabschaltfrage, knoepfe)
        gtk_widget_set_visible(downloadabschaltfrage, 1)
    }

    func abschaltfrageWeg() {
        guard downloadabschaltfrage != nil else { return }
        leeren(downloadabschaltfrage)
        gtk_widget_set_visible(downloadabschaltfrage, 0)
    }
}


// MARK: - Aktualisierung (Windows)

#if os(Windows)
extension App {

    /// **Eine Zeile, die ihren Zustand zeigt.** Statt ein Label im Inneren
    /// der ``wertezeile(symbol:titel:unter:wert:akzent:pfeil:haken:auswahl:)``
    /// nachtraeglich zu suchen, wird die Zeile neu gebaut, wenn sich etwas
    /// aendert. Das ist hier billiger als es klingt — es ist eine Zeile — und
    /// es haelt die Darstellung an einer Stelle.
    func aktualisierungszeileFuellen() {
        guard let raum = aktualisierungsraum else { return }
        leeren(raum)

        switch aktualisierungslage {
        case .unbekannt:
            anhaengen(raum, wertezeile(symbol: "software-update-available-symbolic",
                                       titel: uebersetzt("Nach Updates suchen"),
                                       unter: uebersetzt("Swiftly fragt bei GitHub, ob es eine neuere Version gibt")) {
                [weak self] in self?.aktualisierungSuchen()
            })

        case .sucht:
            anhaengen(raum, wertezeile(symbol: "content-loading-symbolic",
                                       titel: uebersetzt("Wird gesucht …")))

        case .aktuell:
            anhaengen(raum, wertezeile(symbol: "object-select-symbolic",
                                       titel: uebersetzt("Swiftly ist aktuell"),
                                       unter: Fassung.voll) {
                [weak self] in self?.aktualisierungSuchen()
            })

        case .neu(let stand):
            anhaengen(raum, wertezeile(symbol: "software-update-available-symbolic",
                                       titel: String(format: uebersetzt("Swiftly %@ ist da"), stand.fassung),
                                       unter: uebersetzt("Lädt den Installer und startet ihn. Swiftly beendet sich dabei."),
                                       akzent: true) {
                [weak self] in self?.aktualisierungEinspielen(stand)
            })
            anhaengen(raum, zeilenstrich())
            anhaengen(raum, wertezeile(symbol: "text-x-generic-symbolic",
                                       titel: uebersetzt("Was sich ändert"),
                                       unter: erstesAusNotizen(stand.notizen)) {
                imBrowser(URL(string: "https://github.com/paulherter/swiftly-player/releases/latest")!)
            })

        case .laedt:
            anhaengen(raum, wertezeile(symbol: "content-loading-symbolic",
                                       titel: uebersetzt("Wird geladen …"),
                                       unter: uebersetzt("Das dauert einen Moment. Swiftly startet den Installer von selbst.")))

        case .schiefgegangen(let grund):
            anhaengen(raum, wertezeile(symbol: "dialog-warning-symbolic",
                                       titel: uebersetzt("Hat nicht geklappt"),
                                       unter: grund) {
                [weak self] in self?.aktualisierungSuchen()
            })
        }
    }

    /// Die erste Zeile aus dem Text der Veröffentlichung, die etwas aussagt.
    /// Überschriften und Leerzeilen taugen nicht als Vorschau.
    private func erstesAusNotizen(_ text: String) -> String {
        for zeile in text.split(separator: "\n") {
            let sauber = zeile.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*-• "))
            if sauber.count > 12 { return String(sauber.prefix(120)) }
        }
        return uebersetzt("Auf GitHub nachlesen")
    }

    func aktualisierungSuchen() {
        aktualisierungslage = .sucht
        aktualisierungszeileFuellen()
        Task.detached { [self] in
            do {
                let stand = try await Aktualisierung.suchen()
                aufHauptfaden {
                    self.aktualisierungslage = stand.map { .neu($0) } ?? .aktuell
                    Protokoll.schreib("[Update] " + (stand.map { "neu: \($0.fassung)" } ?? "aktuell"))
                    self.aktualisierungszeileFuellen()
                }
            } catch {
                aufHauptfaden {
                    self.aktualisierungslage = .schiefgegangen(uebersetzt("GitHub antwortet nicht."))
                    Protokoll.schreib("[Update] Suche fehlgeschlagen")
                    self.aktualisierungszeileFuellen()
                }
            }
        }
    }

    func aktualisierungEinspielen(_ stand: Aktualisierung.Stand) {
        aktualisierungslage = .laedt
        aktualisierungszeileFuellen()
        Task.detached { [self] in
            do {
                let datei = try await Aktualisierung.holen(stand)
                aufHauptfaden {
                    do {
                        try Aktualisierung.einspielen(datei)
                        Protokoll.schreib("[Update] Installer gestartet, Swiftly beendet sich")
                        // Der Installer kann eine laufende `Swiftly.exe` nicht
                        // ersetzen — also Platz machen.
                        exit(0)
                    } catch {
                        self.aktualisierungslage = .schiefgegangen(uebersetzt("Der Installer ließ sich nicht starten."))
                        self.aktualisierungszeileFuellen()
                    }
                }
            } catch {
                aufHauptfaden {
                    self.aktualisierungslage = .schiefgegangen(uebersetzt("Das Herunterladen ist abgebrochen."))
                    Protokoll.schreib("[Update] Herunterladen fehlgeschlagen")
                    self.aktualisierungszeileFuellen()
                }
            }
        }
    }
}
#endif
