import CGtk
import Foundation
import JellyfinKit

/// **Der Player sieht überall gleich aus** (E10): Schließen oben links,
/// Einstellungen oben rechts, Titel und Folge unten links, Zeitleiste
/// darunter, die drei Knöpfe mittig. Bild-im-Bild entfällt — wie auf dem Mac,
/// wo VLCKit es nicht trägt; hier gibt es unter Wayland kein Gegenstück.
///
/// Was der Player tut und was der Server erfährt, entscheidet nicht diese
/// Datei, sondern das Paket: ``Wiedergabetakt`` (B3, B4, B7, B12, C1, C2),
/// ``Folgenende`` (B5, B6) und ``Zeitannahme``. Hier steht nur, wie es
/// aussieht und wer wann gefragt wird.
extension App {

    /// **Die Fensterleiste bleibt stehen, auch im Player.**
    ///
    /// Sie zu verstecken war der Versuch, dem Mac zu folgen, wo die
    /// Fensterampel im Player ausgeblendet wird. Unter Wayland gehört die
    /// Titelzeile aber dem Fenster und nicht uns: sie zu verbergen ändert die
    /// Höhe des Inhalts — und zwar **mitten in der Auffahrt**, sodass das
    /// ganze Bild um ihre Höhe springt. Genau das war das Rucken.
    ///
    /// Das ist die eine Abweichung, die sich nicht wegräumen lässt, ohne die
    /// Fensterknöpfe zu verlieren; sie steht in derselben Reihe wie die
    /// schmale Kopfzeile über der Seitenleiste (VERHALTEN.md F).
    func spielerOeffnen(_ item: Item, ab: Double) {
        guard let client else { return }
        spielerSchliessen(melden: true)

        laufenderTitel = item
        spielstand = Wiedergabetakt.Stand()
        seitOeffnen = Date()

        let seite = spielerSeiteBauen(item)
        gtk_stack_add_named(OpaquePointer(seiten), seite, "spieler")
        // **Aufsteigen — die dritte der drei Bewegungen** (so auf dem Mac,
        // `HauptView.swift:160`). Von unten herauf und wieder hinunter;
        // genau deshalb zeigt der Winkel oben rechts nach unten.
        // **Der Grund bleibt liegen, der Player legt sich darüber.**
        // `SLIDE_UP` schiebt beide Seiten; `OVER_UP` schiebt nur die neue
        // herauf und lässt die alte stehen — dieselbe Unterscheidung wie beim
        // Seitenschub, wo das Nebeneinander genauso falsch aussah.
        gtk_stack_set_transition_type(OpaquePointer(seiten),
                                      GTK_STACK_TRANSITION_TYPE_OVER_UP)
        gtk_stack_set_transition_duration(OpaquePointer(seiten), 350)
        Schubsperre.fuer(0.35)
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "spieler")

        // **Erst den Plan holen, dann öffnen.** Die Adresse steht nicht in
        // `Item`; sie kommt aus `/PlaybackInfo`, und dort entscheidet sich
        // zugleich, ob der Server transkodiert. Ohne Plan kein Bild.
        // **Die Grenze vor dem Faden ablesen.** `wahlen` gehört dem
        // Hauptfaden; im abgesetzten Auftrag darf sie nicht angefasst werden.
        let grenze = wahlen.profilBitrate
        // **Abschnitte holen, solange der Plan unterwegs ist.** Vorspann und
        // Abspann kommen vom Server; ohne sie entscheidet allein die
        // Restzeitregel, mit ihnen steht der Knopf an der Stelle, die in der
        // Datei vermerkt ist. `Abschnittslogik` im Paket wusste das längst.
        Task.detached { [self] in
            let marken = await client.abschnitte(fuer: item.id)
            aufHauptfaden { self.abschnitte = marken }
        }
        Task.detached { [self] in
            let plan = try? await client.playbackPlan(for: item.id, profile: .vlc(maxBitrate: grenze))
            aufHauptfaden {
                guard let plan else {
                    // **D3: der Fehler nennt den Server, nicht nur „ging
                    // nicht".** Bei mehreren Servern weiss man sonst nicht,
                    // welcher gemeint ist. Wörtlich der Satz vom Mac
                    // (`Abspielsteuerung.starte`).
                    let wo = self.servername.isEmpty ? "dem Server" : self.servername
                    self.spielerMeldung(
                        "Die Wiedergabe hat nicht geklappt — \(wo) hat keinen Plan geliefert.")
                    return
                }
                self.laufenderPlan = plan
                self.warnungZeigen(plan)
                self.abspieler.oeffnen(plan.url, ab: ab)
                self.spielstand.position = ab
                self.taktStarten()
            }
        }
    }

    func spielerSchliessen(melden: Bool = true) {
        guard laufenderTitel != nil else { return }
        // **Die Stelle vor `stop()` melden** (C3): danach steht VLCs Zeit auf
        // null, und der Server merkte sich den Anfang statt der Stelle.
        // **Ein Stopp ohne Start ist keine Sitzung.** Wer den Player vor dem
        // ersten Bild wieder schliesst, hat nie eine eröffnet; der Mac meldet
        // dann auch nichts (`PlayerScreen.swift:547`).
        if melden, spielstand.startGemeldet,
           let client, let plan = laufenderPlan, let titel = laufenderTitel {
            let ticks = Int64(spielstand.position * 10_000_000)
            Task.detached {
                try? await client.reportStopped(itemID: titel.id, plan: plan,
                                                positionTicks: ticks)
            }
        }
        taktBeenden()
        spurwahlSchliessen()
        // **Erst den Titel löschen, dann aufräumen.** Alles, was den Zeiger
        // versteckt, hängt daran; solange er steht, kann ein später
        // eintreffendes Ereignis die Aufräumarbeit wieder umstossen.
        laufenderTitel = nil
        spielerSteuerung = nil
        zeigerZeigen(true)
        abschnitte = []
        // **Ein alter Wecker haelt sonst spaeter eine andere Wiedergabe an.**
        schlaftakt += 1
        schlafminuten = nil
        laufenderPlan = nil
        medienstandMelden()
        // `UNDER_DOWN`: der Player fährt nach unten hinaus und gibt frei,
        // was darunter liegt — die Startseite bewegt sich nicht.
        gtk_stack_set_transition_type(OpaquePointer(seiten),
                                      GTK_STACK_TRANSITION_TYPE_UNDER_DOWN)
        gtk_stack_set_transition_duration(OpaquePointer(seiten), 350)
        Schubsperre.fuer(0.35)
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "start")
        // **Das Bild bleibt stehen, bis es unten ist.**
        //
        // Vorher hielt `beenden` das Medium sofort an — dann fuhr eine
        // schwarze Flaeche hinunter statt der Seite, die man gerade noch
        // gesehen hat. Angehalten wird, wenn die Fahrt durch ist.
        // Der Zeiger geht über eine Fadengrenze, also in die Kiste — dieselbe
        // Zusicherung wie überall hier.
        let dann = gehalten(spielerRahmen)
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            aufHauptfaden {
                defer { losgelassen(dann) }
                self.abspieler.beenden(nurMedium: true)
                if let seite = gtk_stack_get_child_by_name(OpaquePointer(self.seiten), "spieler"),
                   seite == dann.widget {
                    gtk_stack_remove(OpaquePointer(self.seiten), seite)
                }
                self.spielerRahmen = nil
                self.spielerSteuerung = nil
            }
        }
        if let seite = gtk_stack_get_child_by_name(OpaquePointer(seiten), "spieler") {
            gtk_stack_remove(OpaquePointer(seiten), seite)
        }
        // **Die Startseite holt ihre Reihen neu, wenn der Player zugeht**
        // (D8) — ohne Frist. Eine zu Ende gesehene Folge stünde sonst weiter
        // mit Balken in „Weiterschauen".
        startseiteLaden()
    }

    // MARK: Aufbau

    private func spielerSeiteBauen(_ item: Item) -> Widget! {
        let ueber: Widget! = gtk_overlay_new()
        spielerRahmen = ueber
        gtk_widget_add_css_class(ueber, "swiftly-spieler")
        // Aus der vorigen Seite aushängen, bevor es in die neue kommt: ein
        // Widget mit Eltern lässt sich nicht ein zweites Mal einhängen.
        if gtk_widget_get_parent(abspieler.anzeige) != nil {
            gtk_widget_unparent(abspieler.anzeige)
        }
        gtk_overlay_set_child(OpaquePointer(ueber), abspieler.anzeige)

        let steuerung = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(steuerung, "swiftly-steuerung")
        spielerSteuerung = steuerung

        anhaengen(steuerung, spielerkopf())
        anhaengen(steuerung, luft())
        anhaengen(steuerung, spielermitte())
        anhaengen(steuerung, luft())
        anhaengen(steuerung, spielerfuss(item))

        // **Die Sprunganzeige** — ein Zeichen am Bildrand, 700 ms lang, auf
        // der Seite, in die gesprungen wurde. Sie steht **ausserhalb** der
        // Steuerung: sie soll auch dann erscheinen, wenn die Steuerung schon
        // weggeblendet ist und jemand nur die Pfeiltaste drückt.
        let sprungLinks = Sprungzeichen(zurueck: true, zahl: wahlen.zurueckSekunden, mass: 56)
        let sprungRechts = Sprungzeichen(zurueck: false, zahl: wahlen.vorSekunden, mass: 56)
        spielerSprungLinks = sprungLinks
        spielerSprungRechts = sprungRechts
        for (zeichen, seite) in [(sprungLinks, GTK_ALIGN_START), (sprungRechts, GTK_ALIGN_END)] {
            gtk_widget_set_halign(zeichen.anzeige, seite)
            gtk_widget_set_valign(zeichen.anzeige, GTK_ALIGN_CENTER)
            gtk_widget_set_margin_start(zeichen.anzeige, 70)
            gtk_widget_set_margin_end(zeichen.anzeige, 70)
            gtk_widget_set_size_request(zeichen.anzeige, 72, 72)
            gtk_widget_set_opacity(zeichen.anzeige, 0)
            gtk_widget_set_can_target(zeichen.anzeige, 0)
            gtk_overlay_add_overlay(OpaquePointer(ueber), zeichen.anzeige)
        }

        let schleier = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(schleier, "swiftly-spieler")
        spielerLadeschirm = schleier
        gtk_overlay_add_overlay(OpaquePointer(ueber), schleier)

        gtk_overlay_add_overlay(OpaquePointer(ueber), steuerung)

        // **Die Steuerung blendet nach 4 s Ruhe aus** (B1) — nur während der
        // Wiedergabe. Jede Bewegung des Zeigers holt sie zurück.
        // **Zeiger im Fenster: Steuerung da. Zeiger draussen: weg** — so auf
        // dem Mac. Vorher holte auch das Verlassen sie zurueck, was genau
        // verkehrt herum war.
        beiZeiger(ueber, herein: { [weak self] in self?.steuerungZeigen() },
                         hinaus: { [weak self] in self?.steuerungVerbergen() })
        // Und jede Bewegung holt sie zurück, nicht nur das Betreten.
        beiBewegung(ueber) { [weak self] in self?.steuerungZeigen() }
        steuerungZeigen()
        return ueber
    }

    /// **Links steht nichts, rechts die zwei Werkzeuge** — wörtlich der Mac.
    ///
    /// Dort sass der Winkel einmal links neben der Fensterampel und ist
    /// bewusst nach rechts gewandert: sonst stünden an derselben Ecke zwei
    /// Schliesser mit verschiedener Wirkung. Unter Wayland gehört die
    /// Fensterleiste ohnehin dem Fenster, und während der Wiedergabe ist sie
    /// weg — der Grund gilt trotzdem, weil die Aufteilung dieselbe sein soll.
    ///
    /// Der Winkel zeigt nach unten, weil der Player von unten aufsteigt und
    /// wieder dorthin verschwindet.
    private func spielerkopf() -> Widget! {
        let oben = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        gtk_widget_set_margin_top(oben, 18)
        gtk_widget_set_margin_end(oben, 22)
        gtk_widget_set_margin_start(oben, 16)
        anhaengen(oben, luftQuer())

        let spuren = chip("Ton und Untertitel", symbol: "media-view-subtitles-symbolic")
        spielerSpurknopf = spuren
        beiSignal(spuren, "clicked") { [weak self] in self?.spurwahlZeigen() }
        anhaengen(oben, spuren)

        let zu = chip("Schließen", symbol: "pan-down-symbolic")
        beiSignal(zu, "clicked") { [weak self] in self?.spielerSchliessen() }
        anhaengen(oben, zu)
        return oben
    }

    /// Die drei Knöpfe **in der Mitte des Bildes**, nicht unten in der Leiste
    /// — und ohne runde Fläche darunter: auf dem Mac steht dort nur das
    /// Zeichen, darunter das Tastenkürzel in ganz leiser Schrift.
    ///
    /// **Vorwärts weiter als rückwärts** (B2), und beide Weiten kommen aus
    /// den Einstellungen; deshalb tragen die Zeichen ihre Zahl.
    private func spielermitte() -> Widget! {
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 52)
        gtk_widget_set_halign(reihe, GTK_ALIGN_CENTER)

        let zurueck = Sprungzeichen(zurueck: true, zahl: wahlen.zurueckSekunden)
        spielerZurueckZeichen = zurueck
        anhaengen(reihe, spieltaste(zurueck.anzeige, kuerzel: "←",
                                    name: "\(wahlen.zurueckSekunden) Sekunden zurück") {
            [weak self] in
            guard let self else { return }
            self.abspieler.springen(-Double(self.wahlen.zurueckSekunden))
            self.sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
            self.spielerZurueckZeichen?.stupsen()
            self.sprungZeigen(true)
            self.steuerungZeigen()
        })

        let mitte = Abspielzeichen(pause: true)
        spielerAbspielzeichen = mitte
        anhaengen(reihe, spieltaste(mitte.anzeige, kuerzel: "Leertaste",
                                    name: "Abspielen oder anhalten", gross: true) {
            [weak self] in
            guard let self else { return }
            self.abspieler.umschalten()
            // **Der Zustand des Knopfes ist die Antwort** (D6). Der Takt
            // laeuft alle 500 ms; darauf zu warten hiess, dass der Ton
            // schon eine halbe Sekunde weg war, bevor das Zeichen umsprang.
            self.spielstand.laeuft.toggle()
            self.spielerAbspielzeichen?.setzen(self.spielstand.laeuft)
            self.medienstandMelden()
            self.steuerungZeigen()
        })

        let vor = Sprungzeichen(zurueck: false, zahl: wahlen.vorSekunden)
        spielerVorZeichen = vor
        anhaengen(reihe, spieltaste(vor.anzeige, kuerzel: "→",
                                    name: "\(wahlen.vorSekunden) Sekunden vor") {
            [weak self] in
            guard let self else { return }
            self.abspieler.springen(Double(self.wahlen.vorSekunden))
            self.sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
            self.spielerVorZeichen?.stupsen()
            self.sprungZeigen(false)
            self.steuerungZeigen()
        })
        return reihe
    }

    /// Ein Knopf der Mitte: das Zeichen, darunter das Kürzel.
    private func spieltaste(_ zeichen: Widget!, kuerzel: String, name: String,
                            gross: Bool = false,
                            auswahl: @escaping () -> Void) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-spieltaste")
        // **E8: ein selbstgebauter Knopf erbt keine Barrierefreiheit.** Was
        // hier steht, ist eine gemalte Fläche; ohne Namen ist er für eine
        // Vorlesehilfe „Taste" und sonst nichts.
        beschriften(knopf, name)
        // **Mittig, nicht oben.** Die Säulen sind verschieden hoch — 78 für
        // das Abspielzeichen, 46 für die Sprünge —, und in einer Kiste füllt
        // ein Kind sonst die volle Höhe und legt seinen Inhalt nach oben.
        // Dann sassen die Sprungzeichen höher als das Abspielzeichen. Weil
        // die Kürzel darunter gleich hoch sind, liegen die Zeichen bei
        // mittiger Ausrichtung von selbst auf einer Linie.
        gtk_widget_set_valign(knopf, GTK_ALIGN_CENTER)
        let saeule = stapel(GTK_ORIENTATION_VERTICAL, abstand: 9)
        gtk_widget_set_halign(zeichen, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(zeichen, gross ? 78 : 46, gross ? 78 : 46)
        gtk_widget_set_valign(zeichen, GTK_ALIGN_CENTER)
        anhaengen(saeule, zeichen)
        let k = beschriftung(kuerzel, stil: "swiftly-kuerzel")
        anhaengen(saeule, k)
        gtk_button_set_child(alsKnopf(knopf), saeule)
        beiSignal(knopf, "clicked", auswahl)
        return knopf
    }

    /// **Der Titel steht unten, nicht oben**: er gehört zur Zeitleiste, nicht
    /// zu den Werkzeugen. Wörtlich die Aufteilung der iPhone-Fassung.
    private func spielerfuss(_ item: Item) -> Widget! {
        let unten = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)
        gtk_widget_set_margin_start(unten, 28)
        gtk_widget_set_margin_end(unten, 28)
        gtk_widget_set_margin_bottom(unten, 26)

        let kopfzeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 16)
        gtk_widget_set_valign(kopfzeile, GTK_ALIGN_END)
        let namen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)
        gtk_widget_set_hexpand(namen, 1)
        // **Der Titel der Folge, nicht der Serie.** Hier stand
        // `seriesName ?? name` — dann las man oben „Adults" und darunter
        // „S2 • E1 • Adults", also zweimal dasselbe und nirgends, welche
        // Folge läuft. Der Mac nimmt `titel.name`.
        let gross = beschriftung(item.name, stil: "swiftly-spielertitel")
        gtk_label_set_xalign(OpaquePointer(gross), 0)
        gtk_label_set_ellipsize(OpaquePointer(gross), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(gross), 1)
        anhaengen(namen, gross)

        let zweite = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
        if let zeile = item.kontextzeile {
            let k = beschriftung(zeile, stil: "swiftly-spielerzeile")
            gtk_label_set_xalign(OpaquePointer(k), 0)
            anhaengen(zweite, k)
        }
        // **Die Abweichung meldet sich, wo man sie merkt.** Dass der Server
        // nicht transkodiert, ist der Grund für diese App; der Player ist die
        // Stelle, an der es auffiele. Stand bisher nur auf der Detailseite.
        spielerWarnung = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 5)
        gtk_widget_set_visible(spielerWarnung, 0)
        let zeichen: Widget! = gtk_image_new_from_icon_name("dialog-warning-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(zeichen), 13)
        anhaengen(spielerWarnung, zeichen)
        spielerWarntext = beschriftung("", stil: "swiftly-spielerzeile")
        anhaengen(spielerWarnung, spielerWarntext)
        gtk_widget_add_css_class(spielerWarnung, "swiftly-warnung")
        anhaengen(zweite, spielerWarnung)
        anhaengen(namen, zweite)
        anhaengen(kopfzeile, namen)

        // „Nächste Folge" erscheint erst gegen Ende (B5) — als Chip in der
        // Titelzeile, nicht als grosser Knopf. So auf dem Mac.
        spielerWeiter = chip("Nächste Folge", symbol: "media-skip-forward-symbolic")
        gtk_widget_set_valign(spielerWeiter, GTK_ALIGN_END)
        gtk_widget_set_visible(spielerWeiter, 0)
        beiSignal(spielerWeiter, "clicked") { [weak self] in self?.angebotAusfuehren() }
        anhaengen(kopfzeile, spielerWeiter)
        anhaengen(unten, kopfzeile)

        // Zeitleiste: Stand links, Balken, Rest rechts.
        let leiste = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
        spielerZeit = beschriftung("0:00", stil: "swiftly-spielerzeit")
        // **Eine Breite, sonst drückt der Regler sie weg.** Der Regler
        // dehnt sich; eine Beschriftung ohne Wunschbreite kann dabei auf
        // null zusammenfallen, und dann steht dort gar nichts.
        gtk_widget_set_size_request(spielerZeit, 52, -1)
        gtk_label_set_xalign(OpaquePointer(spielerZeit), 0)
        anhaengen(leiste, spielerZeit)
        spielerRegler = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.001)
        gtk_scale_set_draw_value(alsSkala(spielerRegler), 0)
        gtk_widget_add_css_class(spielerRegler, "swiftly-regler")
        gtk_widget_set_hexpand(spielerRegler, 1)
        // Für eine Vorlesehilfe ein Regler mit Namen, nicht eine namenlose
        // Fläche — sonst lässt sich die Stelle auch mit den Pfeiltasten nicht
        // sinnvoll ändern (E8).
        beschriften(spielerRegler, "Abspielstelle")
        // **`change-value` bringt Sprungart und Wert mit** — mit dem
        // schlichten Rückruf wäre das derselbe Absturz wie bei
        // `edge-reached`. Deshalb ein eigener, der die Form kennt.
        g_signal_connect_data(UnsafeMutableRawPointer(spielerRegler), "change-value",
                              unsafeBitCast(reglerGezogen, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(),
                              nil, GConnectFlags(rawValue: 0))
        anhaengen(leiste, spielerRegler)
        spielerRest = beschriftung("−0:00", stil: "swiftly-spielerzeit")
        gtk_widget_set_size_request(spielerRest, 58, -1)
        gtk_label_set_xalign(OpaquePointer(spielerRest), 1)
        anhaengen(leiste, spielerRest)
        anhaengen(unten, leiste)
        return unten
    }

    /// Zeigt an, wenn der Server doch transkodiert.
    private func warnungZeigen(_ plan: PlaybackPlan) {
        guard let feld = spielerWarnung else { return }
        gtk_widget_set_visible(feld, plan.isLossless ? 0 : 1)
        if !plan.isLossless, let text = spielerWarntext {
            gtk_label_set_text(OpaquePointer(text), plan.method.rawValue)
        }
    }

    private func spielerMeldung(_ text: String) {
        guard let feld = spielerZeit else { return }
        gtk_label_set_text(OpaquePointer(feld), text)
    }

    // MARK: Der Takt — 500 ms (B12)

    private func taktStarten() {
        taktBeenden()
        spielertakt = g_timeout_add_full(200, 500, spielerTaktRuf,
                                         Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func taktBeenden() {
        if spielertakt != 0 { g_source_remove(spielertakt); spielertakt = 0 }
    }

    /// Ein Takt. Die Rechnung selbst steht im Paket — hier wird nur gemessen,
    /// gefragt und ausgeführt.
    func takten() {
        guard laufenderTitel != nil else { return }
        let messung = Wiedergabetakt.Messung(
            dauer: abspieler.dauer,
            position: abspieler.position,
            guteStelle: spielstand.position,
            zeigtBild: abspieler.zeigtBild,
            stelltEin: abspieler.stelltEin,
            laeuft: abspieler.laeuft,
            hatTonspuren: abspieler.hatTonspuren)

        // **`Wiedergabetakt` ist `@MainActor`, dieser Rückruf nicht.**
        // GTKs Taktgeber läuft auf dem Hauptfaden des Prozesses, und das ist
        // derselbe, den Swift `MainActor` nennt. `assumeIsolated` sagt genau
        // das — und prüft es zur Laufzeit, statt es zu behaupten.
        let auftrag = MainActor.assumeIsolated {
            // **Nach einem Sprung und beim Ziehen darf VLCs Zeit nicht
            // übernommen werden.** Sonst fällt die Anzeige auf die alte
            // Stelle zurück, bis der Strom neu steht — die Marke hüpft.
            Wiedergabetakt.rechnen(&spielstand, messung: messung,
                                   stelltWiederHer: false,
                                   sprungLaeuft: Date() < sprungBis,
                                   amSchieben: amRegler,
                                   seitStart: seitOeffnen)
        }

        zeitenZeigen()

        // **Bis das erste Bild steht, deckt ein Schleier.** Ohne ihn sieht man
        // den Aufbau des Stroms — Klötzchen, ein Ruck, manchmal ein grüner
        // Rahmen. Wann er weicht, entscheidet ``Zeitannahme`` im Paket, nicht
        // diese Datei; ich hatte den Auftrag nur nie ausgewertet.
        if auftrag.ladeschirmWeg, let schleier = spielerLadeschirm {
            sanft(auf: schleier, von: 1, nach: 0) { gtk_widget_set_opacity(schleier, $0) }
            spielerLadeschirm = nil
        }
        if auftrag.spurenAnwenden { spurenVorwaehlen() }
        if auftrag.startMelden { melden(.start); medienstandMelden() }
        if auftrag.fortschrittMelden { melden(.fortschritt) }

        // B5: der Knopf. B6: das selbsttätige Weiterschalten — deutlich enger
        // gefasst, und frühestens `anlaufruhe` Sekunden nach dem Öffnen.
        //
        // **Der Knopf ist nicht immer „Nächste Folge".** Steht die Stelle in
        // einem überspringbaren Abschnitt, heisst er „Vorspann überspringen"
        // und springt an dessen Ende — dieselbe Entscheidung wie auf allen
        // anderen Plattformen, sie liegt in `Abschnittslogik`.
        let angebot = Abschnittslogik.angebot(position: spielstand.position,
                                              dauer: spielstand.dauer,
                                              abschnitte: abschnitte,
                                              hatNaechsteFolge: laufenderTitel?.seriesId != nil)
        jetzigesAngebot = angebot
        gtk_widget_set_visible(spielerWeiter, angebot.sichtbar ? 1 : 0)
        if angebot.sichtbar {
            hauptknopfBeschriften(spielerWeiter, angebot.beschriftung,
                                  symbol: angebot == .naechsteFolge
                                      ? "media-skip-forward-symbolic"
                                      : "media-seek-forward-symbolic")
        }
        if wahlen.naechsteAutomatisch,
           Folgenende.weiterschalten(position: spielstand.position,
                                     dauer: spielstand.dauer,
                                     seitOeffnen: Date().timeIntervalSince(seitOeffnen)) {
            naechsteFolge()
        }
    }

    private enum Meldung { case start, fortschritt }

    private func melden(_ was: Meldung) {
        guard let client, let plan = laufenderPlan, let titel = laufenderTitel else { return }
        let ticks = Int64(spielstand.position * 10_000_000)
        let pausiert = !spielstand.laeuft
        Task.detached {
            switch was {
            case .start:
                try? await client.reportStart(itemID: titel.id, plan: plan, ticks: ticks)
            case .fortschritt:
                try? await client.reportProgress(itemID: titel.id, plan: plan,
                                                 positionTicks: ticks, paused: pausiert)
            }
        }
    }

    private func zeitenZeigen() {
        gtk_label_set_text(OpaquePointer(spielerZeit), Spielzeit.text(spielstand.position))
        if spielstand.dauer > 0 {
            let rest = max(0, spielstand.dauer - spielstand.position)
            gtk_label_set_text(OpaquePointer(spielerRest), "−" + Spielzeit.text(rest))
            gtk_range_set_value(alsBereich(spielerRegler),
                                spielstand.position / spielstand.dauer)
        }
        spielerAbspielzeichen?.setzen(spielstand.laeuft)
    }

    /// **Ton- und Untertitelspur werden einmal gesetzt, sobald VLC sie
    /// kennt** (B8).
    ///
    /// **Zwei Sachen waren hier falsch.** Die Untertitelvorwahl und
    /// „Untertitel automatisch" standen in den Einstellungen, wurden
    /// gesichert — und nie gelesen. Und der Abgleich lief über
    /// `localizedCaseInsensitiveContains` auf einen einzigen Namen; VLC
    /// meldet je nach Datei „German", „Deutsch" oder „ger". Dafür gibt es
    /// ``Sprache/passt(_:zu:)`` im Paket, das alle Schreibweisen kennt — der
    /// Mac benutzt es (`VLCPlayer.swift`), ich hatte es übersehen.
    private func spurenVorwaehlen() {
        let tonWunsch = wahlen.tonSprache
        if !tonWunsch.isEmpty,
           let treffer = abspieler.tonspuren.first(where: {
               $0.kennung >= 0 && Sprache.passt($0.name, zu: tonWunsch)
           }) {
            abspieler.setzeTonspur(treffer.kennung)
        }

        // „Automatisch" heisst: Untertitel nur, wenn der Ton nicht in der
        // gewünschten Sprache läuft. Sonst gilt die feste Vorwahl.
        let uWunsch = wahlen.untertitelSprache
        guard !uWunsch.isEmpty else { return }
        if wahlen.untertitelAutomatisch, !tonWunsch.isEmpty {
            let tonLaeuft = abspieler.tonspuren.first { $0.kennung == abspieler.tonspur }
            if let tonLaeuft, Sprache.passt(tonLaeuft.name, zu: tonWunsch) { return }
        }
        if let treffer = abspieler.untertitelspuren.first(where: {
            $0.kennung >= 0 && Sprache.passt($0.name, zu: uWunsch)
        }) {
            abspieler.setzeUntertitel(treffer.kennung)
        }
    }

    /// Was der Knopf unten rechts gerade tut.
    func angebotAusfuehren() {
        switch jetzigesAngebot {
        case .keiner:
            break
        case let .ueberspringen(nach, _):
            abspieler.setzeZeit(nach)
            spielstand.position = nach
            sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
            steuerungZeigen()
        case .naechsteFolge:
            naechsteFolge()
        }
    }

    func naechsteFolge() {
        guard let client, let titel = laufenderTitel, let serie = titel.seriesId else { return }
        let grenze = wahlen.profilBitrate
        Task.detached { [self] in
            guard let naechste = try? await client.folgeNach(itemID: titel.id,
                                                             seriesID: serie),
                  let plan = try? await client.playbackPlan(for: naechste.id,
                                                            profile: .vlc(maxBitrate: grenze))
            else {
                aufHauptfaden { self.melden("Nächste Folge konnte nicht geladen werden.") }
                return
            }
            aufHauptfaden {
                // **Beim Folgenwechsel: Ende der alten melden, Start der
                // neuen. Genau einmal** (C4). `neuerTitel` setzt den Stand
                // zurück — einschließlich `seitStart` (B7).
                self.melden(.fortschritt)
                if let alterPlan = self.laufenderPlan {
                    let ticks = Int64(self.spielstand.position * 10_000_000)
                    Task.detached {
                        try? await client.reportStopped(itemID: titel.id, plan: alterPlan,
                                                        positionTicks: ticks)
                    }
                }
                self.laufenderTitel = naechste
                self.laufenderPlan = plan
                MainActor.assumeIsolated {
                    Wiedergabetakt.neuerTitel(&self.spielstand, startGemeldet: false)
                }
                self.spielstand.erstesBildDa = false
                self.seitOeffnen = Date()
                self.abschnitte = []
                // **Das Tempo überlebt den Folgenwechsel.** Linux legt je
                // Folge einen neuen libVLC-Spieler an; ohne diese Zeile fängt
                // die nächste Folge wieder bei 1,0 an, obwohl der Zuschauer
                // 1,25 gewählt hat. Auf dem Mac bleibt derselbe Spieler
                // stehen, deshalb stellt sich die Frage dort nicht.
                let tempo = self.abspieler.tempo
                // Die nächste Folge startet **von vorn** (B5).
                self.abspieler.oeffnen(plan.url, ab: 0)
                self.abspieler.tempo = tempo
                Task.detached { [self] in
                    let marken = await client.abschnitte(fuer: naechste.id)
                    aufHauptfaden { self.abschnitte = marken }
                }
            }
        }
    }

    // MARK: Steuerung ein- und ausblenden (B1)

    /// Der Zeitregler wurde gezogen. **Der Sprung greift sofort**, und der
    /// Stand wird mitgeführt: sonst zöge ihn der nächste Takt zurück, bevor
    /// VLC an der neuen Stelle angekommen ist.
    func reglerGesetzt(_ anteil: Double) {
        guard spielstand.dauer > 0 else { return }
        let ziel = spielstand.dauer * anteil
        spielstand.position = ziel
        abspieler.setzeZeit(ziel)
        sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
        steuerungZeigen()
    }

    /// Lässt die Sprunganzeige kurz aufblitzen.
    func sprungZeigen(_ zurueck: Bool) {
        let zeichen = zurueck ? spielerSprungLinks : spielerSprungRechts
        guard let zeichen else { return }
        zeichen.setzeZahl(zurueck ? wahlen.zurueckSekunden : wahlen.vorSekunden)
        zeichen.stupsen()
        gtk_widget_set_opacity(zeichen.anzeige, 1)
        sprungtakt += 1
        let meins = sprungtakt
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            aufHauptfaden {
                guard self.sprungtakt == meins else { return }
                sanft(auf: zeichen.anzeige, von: 1, nach: 0) {
                    gtk_widget_set_opacity(zeichen.anzeige, $0)
                }
            }
        }
    }

    /// Blendet die Steuerung sofort weg — **ausser in Pause**: ein Standbild
    /// ohne Steuerung sieht aus wie eine ruhige Einstellung, nicht wie eine
    /// angehaltene Wiedergabe.
    func steuerungVerbergen() {
        // **`laufenderTitel` zuerst.** Ohne diese Prüfung versteckte das
        // Verlassen des wegfahrenden Fensters den Zeiger noch einmal —
        // nachdem `spielerSchliessen` ihn schon zurückgeholt hatte. Ergebnis:
        // ein Fenster ohne Mauszeiger, dauerhaft, bis zum Neustart.
        guard laufenderTitel != nil, spielerSteuerung != nil,
              spielstand.laeuft else { return }
        steuerungstakt += 1
        gtk_widget_set_opacity(spielerSteuerung, 0)
        spurwahlSchliessen()
        zeigerZeigen(false)
    }

    /// **Der Zeiger geht mit der Steuerung.** Ein Pfeil, der auf einem
    /// Standbild stehenbleibt, ist genau das, was am Mac
    /// `setHiddenUntilMouseMoves` verhindert.
    func zeigerZeigen(_ an: Bool) {
        guard let fenster else { return }
        if an {
            gtk_widget_set_cursor(fenster, nil)
        } else {
            let leer = gdk_cursor_new_from_name("none", nil)
            gtk_widget_set_cursor(fenster, leer)
            if let leer { g_object_unref(UnsafeMutableRawPointer(leer)) }
        }
    }

    func steuerungZeigen() {
        // Der Zeiger meldet sich auch noch, während der Player hinausfährt.
        guard spielerSteuerung != nil else { return }
        zeigerZeigen(true)
        gtk_widget_set_opacity(spielerSteuerung, 1)
        steuerungstakt += 1
        let meins = steuerungstakt
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            aufHauptfaden {
                // Nur ausblenden, wenn seither nichts passiert ist — und
                // nicht in Pause: ein Standbild ohne Steuerung sieht aus wie
                // eine ruhige Einstellung.
                // **Der Player kann in den vier Sekunden zugegangen sein.**
                // Dann steht in `spielerSteuerung` ein abgeräumtes Widget,
                // und GTK meldet „assertion GTK_IS_WIDGET failed".
                guard self.laufenderTitel != nil, self.spielerSteuerung != nil,
                      self.steuerungstakt == meins, self.spielstand.laeuft else { return }
                gtk_widget_set_opacity(self.spielerSteuerung, 0)
                self.zeigerZeigen(false)
                // **Die Tafel gehoert zur Steuerung.** Sie liegt als eigener
                // Ueberzug daneben, also nimmt die Deckkraft der Steuerung sie
                // nicht mit — sie blieb offen ueber einem Bild ohne Bedienung.
                self.spurwahlSchliessen()
            }
        }
    }

    // MARK: Spurwahl

    /// **Ebene über dem Bild, die Wiedergabe läuft weiter, der Wechsel
    /// greift sofort** (B11) — wörtlich die Regel der iPhone-Fassung.
    ///
    /// Auf dem iPhone ein Blatt von unten; hier klappt die Tafel unter dem
    /// Knopf auf, aus dem sie stammt: **kleine Entscheidungen erscheinen
    /// dort, wo sie ausgelöst wurden** (E5).
    ///
    /// „Bild" aus der iPhone-Fassung fehlt mit Absicht: dort steht die Wahl
    /// zwischen fester und freier Ausrichtung, und ein Fenster hat keine (F).
    private func spurwahlZeigen() {
        steuerungZeigen()
        if let alt = spurtafel {
            // **Ein Überzug wird über den Überzug entfernt**, nicht über
            // `gtk_widget_unparent` — der lässt GTKs Buchführung stehen.
            gtk_overlay_remove_overlay(OpaquePointer(spielerRahmen), alt)
            spurtafel = nil
            return
        }
        let tafel = stapel(GTK_ORIENTATION_VERTICAL, abstand: 22)
        raender(tafel, 20)

        let ton = abspieler.tonspuren
        if !ton.isEmpty {
            let g = spurgruppe("Ton", "audio-volume-high-symbolic")
            let jetzt = abspieler.tonspur
            for spur in ton {
                // **„Disable" ist keine Tonspur.** VLC hängt den Eintrag an
                // jede Liste; für Ton gibt es ihn auf dem Mac nicht, und ein
                // Film ohne Ton ist auch keine Wahl, die jemand trifft.
                guard spur.kennung >= 0 else { continue }
                anhaengen(g.raum, wahlzeile(spur.name, gewaehlt: spur.kennung == jetzt) {
                    [weak self] in
                    self?.abspieler.setzeTonspur(spur.kennung)
                    self?.spurwahlSchliessen()
                })
            }
            anhaengen(tafel, g.aussen)
        }

        let u = spurgruppe("Untertitel", "media-view-subtitles-symbolic")
        let jetztU = abspieler.untertitelspur
        anhaengen(u.raum, wahlzeile("Aus", gewaehlt: jetztU < 0) { [weak self] in
            self?.abspieler.setzeUntertitel(-1)
            self?.spurwahlSchliessen()
        })
        for spur in abspieler.untertitelspuren where spur.kennung >= 0 {
            anhaengen(u.raum, wahlzeile(spur.name, gewaehlt: spur.kennung == jetztU) {
                [weak self] in
                self?.abspieler.setzeUntertitel(spur.kennung)
                self?.spurwahlSchliessen()
            })
        }
        anhaengen(tafel, u.aussen)

        let t = spurgruppe("Tempo", "preferences-system-symbolic")
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        let jetztTempo = abspieler.tempo
        for wert in Tempostufen.werte {
            let c = chip(Tempostufen.beschriftung(wert), aktiv: abs(jetztTempo - wert) < 0.01)
            beiSignal(c, "clicked") { [weak self] in
                self?.abspieler.tempo = wert
                self?.spurwahlSchliessen()
            }
            anhaengen(reihe, c)
        }
        anhaengen(t.raum, reihe)
        anhaengen(tafel, t.aussen)

        let sz = spurgruppe("Schlafzeit", "weather-clear-night-symbolic")
        let szReihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        let aus = chip("Aus", aktiv: schlafminuten == nil)
        beiSignal(aus, "clicked") { [weak self] in
            self?.schlafminuten = nil
            self?.spurwahlSchliessen()
        }
        anhaengen(szReihe, aus)
        for minuten in Schlafzeiten.werte {
            let c = chip("\(minuten)", aktiv: schlafminuten == minuten)
            beiSignal(c, "clicked") { [weak self] in
                self?.schlafzeitSetzen(minuten)
                self?.spurwahlSchliessen()
            }
            anhaengen(szReihe, c)
        }
        anhaengen(sz.raum, szReihe)
        anhaengen(tafel, sz.aussen)

        // **Eine Tonspurliste kann lang sein — vierzig Untertitel sind
        // normal.** Ohne Scroller wächst die Tafel über den Bildschirmrand
        // hinaus, und was unten steht, ist nicht erreichbar. Der Scroller
        // trägt die Höhengrenze, nicht die Tafel: so bleibt sie bei kurzen
        // Listen so hoch wie ihr Inhalt.
        let rolle: Widget! = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(rolle),
                                       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(OpaquePointer(rolle), 1)
        gtk_scrolled_window_set_max_content_height(OpaquePointer(rolle), 520)
        gtk_scrolled_window_set_child(OpaquePointer(rolle), tafel)
        weichesScrollen(rolle)

        let rahmen: Widget! = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(rahmen, "swiftly-tafel")
        anhaengen(rahmen, rolle)
        gtk_widget_set_size_request(rahmen, 320, -1)
        gtk_widget_set_halign(rahmen, GTK_ALIGN_END)
        gtk_widget_set_valign(rahmen, GTK_ALIGN_START)
        // Die Tafel klappt **unter dem Knopf** auf, aus dem sie stammt (E5).
        // 18 oben plus 28 Knopfhöhe plus 18 Abstand — der Versatz vom Mac.
        gtk_widget_set_margin_top(rahmen, 64)
        gtk_widget_set_margin_end(rahmen, 22)
        gtk_widget_set_margin_bottom(rahmen, 22)

        spurtafel = rahmen
        gtk_overlay_add_overlay(OpaquePointer(spielerRahmen), rahmen)
    }

    func spurwahlSchliessen() {
        if let tafel = spurtafel, spielerRahmen != nil {
            gtk_overlay_remove_overlay(OpaquePointer(spielerRahmen), tafel)
        }
        spurtafel = nil
    }

    private func spurgruppe(_ titel: String, _ symbol: String) -> (aussen: Widget, raum: Widget) {
        let aussen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)
        let kopf = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 7)
        let bild: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(bild), 11)
        gtk_widget_add_css_class(bild, "swiftly-leise")
        anhaengen(kopf, bild)
        anhaengen(kopf, rubrik(titel))
        anhaengen(aussen, kopf)
        let raum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        anhaengen(aussen, raum)
        return (aussen!, raum!)
    }

    private func wahlzeile(_ text: String, gewaehlt: Bool,
                           auswahl: @escaping () -> Void) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-wertzeile")
        if gewaehlt { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        let l = beschriftung(text, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(l), 1)
        gtk_widget_set_hexpand(l, 1)
        anhaengen(reihe, l)
        if gewaehlt {
            let haken: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(haken), 12)
            anhaengen(reihe, haken)
        }
        gtk_button_set_child(alsKnopf(knopf), reihe)
        beiSignal(knopf, "clicked", auswahl)
        return knopf
    }

    /// Der Schlafzeitgeber. Die Stufen stehen im Paket (B10).
    private func schlafzeitSetzen(_ minuten: Int) {
        schlafminuten = minuten
        schlaftakt += 1
        let meins = schlaftakt
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: UInt64(minuten) * 60_000_000_000)
            aufHauptfaden {
                guard self.schlaftakt == meins, self.schlafminuten == minuten else { return }
                self.abspieler.anhalten()
                self.schlafminuten = nil
                self.spielstand.laeuft = false
                self.spielerAbspielzeichen?.setzen(false)
                self.steuerungZeigen()
                self.melden("Schlafzeit abgelaufen.")
            }
        }
    }
}

/// Wenn jemand den Zeitregler zieht. Die Form ist `(GtkRange*, GtkScrollType,
/// gdouble, gpointer)` — vier Argumente, nicht zwei.
nonisolated(unsafe) let reglerGezogen: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, Double, gpointer?
) -> gboolean = { _, _, anteil, daten in
    guard let daten else { return 0 }
    let app = Unmanaged<App>.fromOpaque(daten).takeUnretainedValue()
    app.reglerGesetzt(min(max(anteil, 0), 1))
    return 0   // false: GTK darf den Wert selbst übernehmen
}

/// Der Taktgeber. Wie jeder C-Rückruf trägt er die App als Zeiger.
nonisolated(unsafe) let spielerTaktRuf: @convention(c) (gpointer?) -> gboolean = { daten in
    guard let daten else { return 0 }
    Unmanaged<App>.fromOpaque(daten).takeUnretainedValue().takten()
    return 1
}
