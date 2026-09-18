import CGtk
import Foundation
import JellyfinKit

/// **Der Player sieht überall gleich aus** (E10): oben rechts die beiden
/// Werkzeuge — Wiedergabe und Schließen, in dieser Reihenfolge —, Titel und
/// Folge unten links, Zeitleiste darunter, die drei Knöpfe mittig.
///
/// Hier stand „Schließen oben links, Einstellungen oben rechts". Das war die
/// gespiegelte Fassung von E10: die Fensterampel sitzt auf GTK rechts, also
/// sollte der Schließweg ihr links ausweichen. Am 13.09.2026 hat Paul es am
/// Bild verglichen und anders entschieden — die Ampel sitzt in der
/// Titelzeile, die Werkzeuge gut fünfzig Punkt tiefer, sie stoßen gar nicht
/// aneinander. Das Register ist nachgezogen. Bild-im-Bild entfällt — wie auf dem Mac,
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
    /// **`ausDatei` ist der Weg ohne Server.**
    ///
    /// Ein Download soll auch dann laufen, wenn der Server aus ist — das ist
    /// der ganze Zweck. Der Plan aus `/PlaybackInfo` faellt dann weg, und mit
    /// ihm die Meldungen an den Server: es gibt niemanden, dem man melden
    /// koennte. Alles Uebrige — Steuerung, Sprungzeichen, Technikschild — ist
    /// derselbe Weg.
    func spielerOeffnen(_ item: Item, ab: Double, ausDatei datei: URL? = nil,
                        stelleFrisch: Bool = false) {
        guard client != nil || datei != nil else { return }
        spielerSchliessen(melden: true)
        // **Kein Bild des vorigen Titels** (T2-H1). Geschlossen wird mit
        // stehendem Bild, angehalten erst nach der Fahrt — wer innerhalb
        // dieser 380 ms den naechsten Titel oeffnet, saehe und hoerte sonst
        // den alten, bis der neue Plan da ist.
        abspieler.beenden(nurMedium: true)
        folgenwechsel = Folgenwechsel()
        vorgeholteFolge = nil
        angebotsebene.neueFolge()

        laufenderTitel = item
        spielstand = Wiedergabetakt.Stand()
        seitOeffnen = Date()

        let seite = spielerSeiteBauen(item)
        // **Jede Spielerseite bekommt ihren eigenen Namen.** Alle „spieler" zu
        // nennen ging nur, solange die vorige beim Schliessen sofort aus dem
        // Stapel flog — und genau das nahm ihr die Abfahrt nach unten. Mit
        // einem laufenden Zaehler koennen alte und neue Seite fuer die Dauer
        // der Fahrt nebeneinander liegen, ohne sich den Namen zu streiten.
        spielerZaehler += 1
        gtk_stack_add_named(OpaquePointer(seiten), seite, "spieler-\(spielerZaehler)")
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
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "spieler-\(spielerZaehler)")

        // **Erst den Plan holen, dann öffnen.** Die Adresse steht nicht in
        // `Item`; sie kommt aus `/PlaybackInfo`, und dort entscheidet sich
        // zugleich, ob der Server transkodiert. Ohne Plan kein Bild.
        // **Aus der Datei geht es sofort los.** Kein Plan, keine Abschnitte,
        // keine Meldung — es gibt keinen Server, der davon wuesste.
        if let datei {
            laufenderPlan = nil
            spurlageNeu(item, plan: nil)
            abspieler.oeffnen(datei, ab: ab, puffer: wahlen.puffer)
            abspieler.bildfuellend(wahlen.bildfuellend)
            technikschildSetzen(wahlen.technikschild)
            spielstand.position = ab
            taktStarten()
            return
        }
        guard let client else { return }

        // **Die Grenze vor dem Faden ablesen.** `wahlen` gehört dem
        // Hauptfaden; im abgesetzten Auftrag darf sie nicht angefasst werden.
        let grenze = wahlen.profilBitrate
        // **Abschnitte holen, solange der Plan unterwegs ist.** Vorspann und
        // Abspann kommen vom Server; ohne sie entscheidet allein die
        // Restzeitregel, mit ihnen steht der Knopf an der Stelle, die in der
        // Datei vermerkt ist. `Abschnittslogik` im Paket wusste das längst.
        let wechsel = folgenwechsel
        nachschlagen(fuer: item, wechsel: wechsel, client: client)
        // **Die Antwort gehoert zu genau diesem Oeffnen** (T2-H1). Der Player
        // steht schon, der Plan kommt danach — wer in der Zwischenzeit
        // schliesst oder einen anderen Titel oeffnet, bekam sonst den Film
        // ohne Player zu hoeren, oder das Bild des ersten im zweiten.
        let meiner = spielerZaehler
        Task.detached { [self] in
            // Neben dem Plan, nicht davor: es kostet keine Wartezeit extra.
            async let frisch = stelleFrisch ? try? await client.item(id: item.id) : nil
            let plan = try? await client.playbackPlan(for: item.id, profile: .vlc(maxBitrate: grenze))
            let geholt = await frisch
            let stelle = geholt.map { $0.fortsetzenAb ?? 0 } ?? ab
            if stelleFrisch {
                print("[Spieler] Stelle frisch \(geholt.map { _ in String(Int(stelle)) } ?? "nicht geholt"), Kachel \(Int(ab)) s")
                fflush(nil)
            }
            aufHauptfaden {
                guard self.spielerZaehler == meiner, self.laufenderTitel?.id == item.id,
                      self.folgenwechsel === wechsel else {
                    print("[Spieler] Plan verworfen, Player zu oder anderer Titel \(item.id)")
                    fflush(nil)
                    return
                }
                guard let plan else {
                    print("[Spieler] kein Plan \(item.id)")
                    fflush(nil)
                    // **D3: der Fehler nennt den Server, nicht nur „ging
                    // nicht".** Bei mehreren Servern weiss man sonst nicht,
                    // welcher gemeint ist. Wörtlich der Satz vom Mac
                    // (`Abspielsteuerung.starte`).
                    let wo = self.servername.isEmpty ? uebersetzt("dem Server") : self.servername
                    self.spielerMeldung(
                        String(format: uebersetzt("Die Wiedergabe hat nicht geklappt — %@ hat keinen Plan geliefert."), wo))
                    return
                }
                self.laufenderPlan = plan
                self.spurlageNeu(item, plan: plan)
                self.warnungZeigen(plan)
                self.abspieler.oeffnen(plan.url, ab: stelle, puffer: self.wahlen.puffer)
                // Was einmal gewaehlt wurde, gilt auch fuer die naechste Folge.
                self.abspieler.bildfuellend(self.wahlen.bildfuellend)
                self.technikschildSetzen(self.wahlen.technikschild)
                self.spielstand.position = stelle
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
        //
        // **Ueber den Folgenwechsel** (T2-H1): laeuft einer, bricht er ab und
        // wendet nichts mehr an; ist der Start der neuen Folge unterwegs,
        // geht der Stopp danach. **Die Seiten frischen erst nach der
        // Endmeldung auf** (wie d8492ca auf Apple) — vorher holte die
        // Startseite ihre Reihen, bevor der Server die Stelle kannte.
        let gespielt = laufenderTitel!
        if melden, spielstand.startGemeldet,
           let client, let plan = laufenderPlan, let titel = laufenderTitel {
            let ticks = Int64(spielstand.position * 10_000_000)
            let konto = benutzerID
            folgenwechsel.schliessen { [self] in
                await self.meldeStopp(client, titel: titel, plan: plan, ticks: ticks, konto: konto)
                aufHauptfaden { self.nachDemPlayerAuffrischen(titel) }
            }
        } else {
            folgenwechsel.schliessen {}
            aufHauptfaden { self.nachDemPlayerAuffrischen(gespielt) }
        }
        taktBeenden()
        spurwahlSchliessen()
        technikschildSetzen(false)
        // **Erst den Titel löschen, dann aufräumen.** Alles, was den Zeiger
        // versteckt, hängt daran; solange er steht, kann ein später
        // eintreffendes Ereignis die Aufräumarbeit wieder umstossen.
        laufenderTitel = nil
        Discordstand.abraeumen()
        spielerSteuerung = nil
        spielerWeiter = nil
        spielerAngebot = nil
        angebotsebene.neueFolge()
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
                // **Das Medium nur anhalten, wenn inzwischen kein neuer Film
                // laeuft.** Der Wecker gehoert zu *dieser* Seite; startet
                // jemand innerhalb der 380 ms den naechsten Titel, haette er
                // sonst dessen Medium angehalten. **Die alte Seite geht aber
                // in jedem Fall** — hier stand ein `return`, und kam der neue
                // Plan schneller als die Fahrt, blieb sie im Stapel liegen
                // (T2-H1). Die Anzeige haengt dann schon in der neuen Seite.
                if self.laufenderTitel == nil {
                    self.abspieler.beenden(nurMedium: true)
                }
                if gtk_widget_get_parent(dann.widget) != nil {
                    gtk_stack_remove(OpaquePointer(self.seiten), dann.widget)
                }
                if self.spielerRahmen == dann.widget {
                    self.spielerRahmen = nil
                    self.spielerSteuerung = nil
                }
            }
        }
    }

    /// **Nach der Endmeldung den neuen Stand zeigen** (D8, d8492ca).
    ///
    /// Die Startseite holt ihre Reihen neu — eine zu Ende gesehene Folge
    /// stuende sonst weiter mit Balken in „Weiterschauen". Liegt unter dem
    /// Player die Seite des Titels oder seiner Serie, wird sie neu gebaut:
    /// sie holte ihren Stand nur einmal beim Oeffnen und zeigte die Folge
    /// weiter als ungesehen. Laeuft inzwischen wieder ein Player, gilt der
    /// Anlass nicht mehr.
    func nachDemPlayerAuffrischen(_ gespielt: Item) {
        guard laufenderTitel == nil else { return }
        startseiteLaden()
        sehstandVergessen(gespielt)
        guard offeneUnterseite == nil, let oben = seitenstapel[bereich]?.last,
              oben.id == gespielt.id || oben.id == gespielt.seriesId else { return }
        // **Nicht neu bauen, nur den Sehstand nachziehen.** Hier stand
        // `detailZeigen(oben)` (bafc898): die Seite entstand neu und stand
        // wieder oben, mit Staffel 1 und ohne Fokus. Jetzt fragen Hauptknopf
        // und Folgenzeilen selbst nach und zeichnen sich an Ort und Stelle.
        let vorher = scrollstand()
        print("[Spieler] Sehstand nach dem Player \(oben.id), Scroll \(Int(vorher))")
        fflush(nil)
        kopfAuffrischen?.tun()
        guard let client, let serie = gespielt.seriesId else { return }
        // Die Staffel der gespielten Folge und die, die gerade dasteht —
        // nach einem Weiterschalten koennen es zwei sein.
        var staffeln: [String] = []
        for s in [offeneStaffel?.id, gespielt.seasonId] { if let s, !staffeln.contains(s) { staffeln.append(s) } }
        for staffel in staffeln {
            Task.detached { [self] in
                guard let folgen = try? await client.folgen(seriesID: serie, seasonID: staffel)
                else { return }
                aufHauptfaden {
                    self.folgenspeicher[staffel] = folgen
                    if self.offeneStaffel?.id == staffel { self.staffelfolgen = folgen }
                    var gezeichnet = 0
                    for folge in folgen {
                        guard let zeile = self.sehstandZeilen[folge.id] else { continue }
                        zeile.auffrischen(folge)
                        gezeichnet += 1
                    }
                    print("[Spieler] Sehstand aufgefrischt: \(gezeichnet) Zeilen, Staffel \(staffel)")
                    fflush(nil)
                }
                // Nach dem Neuzeichnen und Layout nachsehen, nicht im selben Zug.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                aufHauptfaden {
                    print("[Spieler] Scroll nach dem Auffrischen \(Int(vorher)) → \(Int(self.scrollstand()))")
                    fflush(nil)
                }
            }
        }
    }

    /// Wie weit die offene Detailseite gescrollt ist, in Punkten.
    func scrollstand() -> Double {
        guard let detailScroller,
              let senkrecht = gtk_scrolled_window_get_vadjustment(OpaquePointer(detailScroller))
        else { return -1 }
        return gtk_adjustment_get_value(senkrecht)
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
        // **Die Einblendung liegt über der Steuerung**, als eigene Ebene: sie
        // erscheint von selbst, ohne dass die Steuerung aufgehen muss.
        angebotsebeneBauen(in: ueber)

        // **Die Steuerung blendet nach 4 s Ruhe aus** (B1) — nur während der
        // Wiedergabe. Jede Bewegung des Zeigers holt sie zurück.
        // **Zeiger im Fenster: Steuerung da. Zeiger draussen: weg** — so auf
        // dem Mac. Vorher holte auch das Verlassen sie zurueck, was genau
        // verkehrt herum war.
        // Zeiger heisst **nebenbei**: die Steuerung kommt, eine laufende Karte
        // „Nächste Folge" bleibt (Paul, 17.09.2026). Klick, Taste, Knopf
        // sagen sie ab.
        beiZeiger(ueber, herein: { [weak self] in self?.steuerungZeigen(durch: .nebenbei) },
                         hinaus: { [weak self] in self?.steuerungVerbergen() })
        // Und jede Bewegung holt sie zurück, nicht nur das Betreten.
        beiBewegung(ueber) { [weak self] in self?.steuerungZeigen(durch: .nebenbei) }
        // **Ein Klick daneben schliesst die Wiedergabetafel.** Auf dem Mac
        // liegt dafuer ein durchsichtiger Faenger unter ihr
        // (`PlayerScreen.swift:365`); hier reicht die Steuerungsflaeche
        // selbst, weil die Tafel als eigener Ueberzug darueber liegt und
        // Klicks in ihr gar nicht bis hierher kommen.
        // Ohne Tafel ist es ein **Klick ins Bild**: die Steuerung bewusst holen,
        // das sagt eine laufende Karte ab (wie der Mac).
        beiKlick(ueber) { [weak self] in
            guard let self else { return }
            guard self.spurtafel != nil else { self.steuerungZeigen(); return }
            self.spurwahlSchliessen()
        }
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

        // **Beide Knoepfe rechts oben, wie auf dem Mac.**
        //
        // Hier stand der Schliessweg links, mit der Begruendung aus E10: auf
        // GTK sitzt die Fensterampel rechts, also gehe unser Schliesser nach
        // links. Am Bild nebeneinander gehalten stimmt das Ergebnis trotzdem
        // nicht — die Titelzeile liegt unter Wayland **ueber** dem Player und
        // nicht daneben, die Verwechslung, gegen die die Regel geschrieben
        // wurde, gibt es hier gar nicht. Von Paul am 13.09.2026 so
        // entschieden; E10 gehoert entsprechend nachgezogen.
        //
        // **Und nur noch zwei.** Der Mac hat Spurwahl und Schliessen; das
        // Vollbild braucht auf einem Fenster keinen eigenen Knopf, das kann
        // der Fensterverwalter. Es steht weiter in der Wiedergabetafel.
        anhaengen(oben, luftQuer())

        // Die Tafel traegt mehr als Ton und Untertitel — seit sie die Form der
        // Mac-Fassung hat, stehen dort auch Bildformat, Tempo, Schlafzeit und
        // das Technikschild.
        // **Gezeichnet, nicht gesucht.** `media-eq-symbolic` gibt es im
        // Adwaita-Satz nicht — GTK zeigte dafuer das Ersatzbild. Der Mac
        // nimmt `slider.horizontal.3`; ``Reglerzeichen`` malt es.
        let regler = Reglerzeichen(mass: 13)
        spielerReglerzeichen = regler
        let spuren = chip(uebersetzt("Wiedergabe"), nurSymbol: true,
                          zeichnung: regler.anzeige)
        spielerSpurknopf = spuren
        beiSignal(spuren, "clicked") { [weak self] in self?.spurwahlZeigen() }
        anhaengen(oben, spuren)

        // Der Winkel zeigt nach unten, weil der Player von unten aufsteigt und
        // wieder dorthin verschwindet.
        // `chevron.down` auf dem Mac (`PlayerScreen.swift:431`) — ein Winkel,
        // kein Pfeil. Der Winkel heisst hier `pan-down-symbolic`;
        // `go-down-symbolic` ist der ausgefuellte Pfeil und sagt „herunter-
        // laden".
        let zu = chip(uebersetzt("Schließen"), symbol: "pan-down-symbolic", nurSymbol: true)
        beiSignal(zu, "clicked") { [weak self] in self?.spielerSchliessen() }
        anhaengen(oben, zu)
        return oben
    }

    /// Vollbild an oder aus — und das Zeichen sagt, was der nächste Druck tut.
    func vollbildUmschalten() {
        let jetzt = gtk_window_is_fullscreen(alsFenster(fenster)) != 0
        if jetzt { gtk_window_unfullscreen(alsFenster(fenster)) }
        else { gtk_window_fullscreen(alsFenster(fenster)) }
        if let knopf = spielerVollknopf {
            knopfzustand(knopf, aktiv: false,
                         symbol: jetzt ? "view-fullscreen-symbolic"
                                       : "view-restore-symbolic")
        }
        steuerungZeigen()
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
                                    name: String(format: uebersetzt("%d Sekunden zurück"), wahlen.zurueckSekunden)) {
            [weak self] in
            guard let self else { return }
            self.springe(um: -Double(self.wahlen.zurueckSekunden))
            self.spielerZurueckZeichen?.stupsen()
            self.sprungZeigen(true)
            self.steuerungZeigen()
        })

        let mitte = Abspielzeichen(pause: true)
        spielerAbspielzeichen = mitte
        anhaengen(reihe, spieltaste(mitte.anzeige, kuerzel: uebersetzt("Leertaste"),
                                    name: uebersetzt("Abspielen oder anhalten"), gross: true) {
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
                                    name: String(format: uebersetzt("%d Sekunden vor"), wahlen.vorSekunden)) {
            [weak self] in
            guard let self else { return }
            self.springe(um: Double(self.wahlen.vorSekunden))
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
        let weiter = Angebotsknopf { [weak self] in self?.angebotAusfuehren() }
        gtk_widget_set_valign(weiter.knopf, GTK_ALIGN_END)
        spielerWeiter = weiter
        anhaengen(kopfzeile, weiter.knopf)
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
        // **Die eine Stelle, an der ein Systemsteuerelement steht** (E4).
        //
        // Der Mac zeichnet die Zeitleiste selbst (`Zeitregler`, mit
        // `DragGesture` statt `Slider`). Hier ist es ein `GtkScale`, per
        // Stilblatt bis auf Spurhoehe (4), Knaufgroesse (13/15) und
        // Schattierung auf dieselbe Optik gebracht, ohne Wert und ohne
        // Systemfarben. Der Grund ist nicht Aufwand, sondern die Eingabe:
        // ein Regler ist das eine Bedienelement, das mit der Tastatur
        // erreichbar sein muss (E8), und `GtkScale` bringt Pfeiltasten,
        // Bild-auf/ab und die Ansage der Position mit. Von Hand gezeichnet
        // waere das noch einmal so viel Code — und die Vorlesehilfe saehe
        // eine Flaeche.
        spielerRegler = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.001)
        gtk_scale_set_draw_value(alsSkala(spielerRegler), 0)
        gtk_widget_add_css_class(spielerRegler, "swiftly-regler")
        gtk_widget_set_hexpand(spielerRegler, 1)
        // Für eine Vorlesehilfe ein Regler mit Namen, nicht eine namenlose
        // Fläche — sonst lässt sich die Stelle auch mit den Pfeiltasten nicht
        // sinnvoll ändern (E8).
        beschriften(spielerRegler, uebersetzt("Abspielstelle"))
        // **`change-value` bringt Sprungart und Wert mit** — mit dem
        // schlichten Rückruf wäre das derselbe Absturz wie bei
        // `edge-reached`. Deshalb ein eigener, der die Form kennt.
        g_signal_connect_data(UnsafeMutableRawPointer(spielerRegler), "change-value",
                              unsafeBitCast(reglerGezogen, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(),
                              nil, GConnectFlags(rawValue: 0))
        // **`amRegler` wurde nie gesetzt.** Das Feld stand da, wurde gelesen
        // — als `amSchieben` in `Wiedergabetakt.rechnen` — und war immer
        // `false`. Zwei Folgen: die Steuerung blendete nach vier Sekunden
        // aus, **waehrend** jemand den Regler zog (B1 nimmt das Schieben
        // ausdruecklich aus), und die Stelle des Servers ueberschrieb die
        // gezogene (B4). Der Mac bindet dafuer `Zeitregler.amRegler`
        // (`PlayerScreen.swift:707`, `:872`); hier gibt es dafuer die Geste.
        beiGriff(spielerRegler) { [weak self] gedrueckt in
            self?.amRegler = gedrueckt
            if gedrueckt { self?.steuerungZeigen() }
        }
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

    // MARK: Der Takt (B12)

    private func taktStarten() {
        taktBeenden()
        // **Die Zahl kommt aus dem Paket**, nicht aus dieser Datei. Hier
        // stand eine 500, und der Mac liest dieselbe Groesse aus
        // `Wiedergabetakt.taktlaenge` — zwei Bauplaetze fuer eine Zahl, die
        // in B12 als geteilt festgeschrieben ist.
        // Er laeuft im Anzeigetakt (250 ms); jeder zweite Aufruf ist der ganze
        // Takt, dazwischen wird nur die Zeit nachgezogen (Paul, 17.09.2026).
        let ms = UInt32(Wiedergabetakt.anzeigetakt.components.seconds * 1000
                        + Wiedergabetakt.anzeigetakt.components.attoseconds / 1_000_000_000_000_000)
        spielertakt = g_timeout_add_full(200, ms, spielerTaktRuf,
                                         Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func taktBeenden() {
        if spielertakt != 0 { g_source_remove(spielertakt); spielertakt = 0 }
    }

    /// Ein Takt. Die Rechnung selbst steht im Paket — hier wird nur gemessen,
    /// gefragt und ausgeführt.
    func takten() {
        guard laufenderTitel != nil else { return }
        // **Dazwischen nur die Zeit**, wie auf iOS: im halben Sekundentakt lief
        // sie nach dem Abspielen verzoegert an und zaehlte ungleichmaessig.
        nurZeitTakt.toggle()
        if nurZeitTakt {
            if !folgenwechsel.laeuft {
                Wiedergabetakt.zeitUebernehmen(&spielstand, gemeldet: abspieler.position,
                                               amSchieben: amRegler, seitStart: seitOeffnen)
                zeitenZeigen()
            }
            return
        }
        // Das Schild haengt am selben Takt wie alles andere: 500 ms.
        // Schneller sieht man nur Flackern, langsamer verpasst man den
        // Ruckler.
        MainActor.assumeIsolated { technikschildNachfuehren() }
        let messung = Wiedergabetakt.Messung(
            dauer: abspieler.dauer,
            position: abspieler.position,
            guteStelle: spielstand.position,
            zeigtBild: abspieler.zeigtBild,
            stelltEin: abspieler.stelltEin,
            laeuft: abspieler.laeuft,
            // **Die Spurliste nur lesen, solange sie gebraucht wird.**
            // `hatTonspuren` baut bei jedem Aufruf die ganze VLC-Liste neu auf
            // und laeuft sie ab — zweimal je Sekunde, den ganzen Film lang.
            // Steht die Spur schon, kuerzt das `||` den Griff weg. Wortgleich
            // auf iOS und macOS.
            hatTonspuren: spielstand.spurenGesetzt || abspieler.hatTonspuren)

        // **`Wiedergabetakt` ist `@MainActor`, dieser Rückruf nicht.**
        // GTKs Taktgeber läuft auf dem Hauptfaden des Prozesses, und das ist
        // derselbe, den Swift `MainActor` nennt. `assumeIsolated` sagt genau
        // das — und prüft es zur Laufzeit, statt es zu behaupten.
        let auftrag = MainActor.assumeIsolated {
            // **Nach einem Sprung haelt der Stand die Zielstelle, bis VLC dort
            // ist** (`spielstand.sprung`, Bug 17.09.2026); beim Ziehen wird VLCs
            // Zeit gar nicht uebernommen.
            Wiedergabetakt.rechnen(&spielstand, messung: messung,
                                   stelltWiederHer: false,
                                   amSchieben: amRegler,
                                   seitStart: seitOeffnen)
        }

        zeitenZeigen()
        MainActor.assumeIsolated { stromPruefen() }

        // **Bis das erste Bild steht, deckt ein Schleier.** Ohne ihn sieht man
        // den Aufbau des Stroms — Klötzchen, ein Ruck, manchmal ein grüner
        // Rahmen. Wann er weicht, entscheidet ``Zeitannahme`` im Paket, nicht
        // diese Datei; ich hatte den Auftrag nur nie ausgewertet.
        if auftrag.ladeschirmWeg, let schleier = spielerLadeschirm {
            sanft(auf: schleier, von: 1, nach: 0) { gtk_widget_set_opacity(schleier, $0) }
            spielerLadeschirm = nil
        }
        if auftrag.spurenAnwenden { spurenVorwaehlen() } else { spurdateienNachfuehren() }
        if auftrag.startMelden { melden(.start); medienstandMelden() }
        if auftrag.fortschrittMelden { melden(.fortschritt) }

        // **Und derselbe Takt traegt die Discord-Anzeige.**
        //
        // Auf den Apple-Fassungen haengt sie an der Wiedergabezentrale, weil
        // dort ohnehin bei jeder Zustandsaenderung die frischen Werte stehen.
        // Die gibt es hier nicht — hier ist es dieser Takt, und er kennt
        // dieselben drei Zahlen. Ob ueberhaupt etwas hinausgeht, entscheidet
        // `Discordstand`; der Schalter ist aus, bis jemand ihn anlegt.
        if let titel = laufenderTitel {
            Discordstand.melden(
                titel: titel.seriesName ?? titel.name,
                unterzeile: titel.seriesName == nil ? nil
                            : [titel.folgenkuerzel, titel.name]
                                .compactMap { $0 }.joined(separator: " · "),
                stelle: spielstand.position, dauer: spielstand.dauer,
                laeuft: spielstand.laeuft, erlaubt: wahlen.discordAnzeigen)
        }

        // B5: der Knopf. B6: das selbsttätige Weiterschalten — deutlich enger
        // gefasst, und frühestens `anlaufruhe` Sekunden nach dem Öffnen.
        //
        // **Der Knopf ist nicht immer „Nächste Folge".** Steht die Stelle in
        // einem überspringbaren Abschnitt, heisst er „Vorspann überspringen"
        // und springt an dessen Ende — dieselbe Entscheidung wie auf allen
        // anderen Plattformen, sie liegt in `Abschnittslogik`.
        // **Waehrend ein Wechsel laeuft, gibt es nichts anzubieten.** Sonst
        // bliebe der Knopf „Naechste Folge" antippbar, waehrend sie schon
        // geholt wird — ein Druck stiesse denselben Wechsel ein zweites Mal an.
        // **„Nächste Folge" nur, wenn es eine gibt** (T2-H2): die vorab
        // geholte, nicht „ist eine Folge" — sonst stand der Knopf auch im
        // Abspann des Finales, und das Weiterschalten scheiterte jeden Takt.
        // (Gerechnet in `angebotTakt`.)
        // **Die Einblendung** (Countdown der Karte) — Rechnung in
        // `Angebotsebene`. Im Stehen, beim Ziehen und unter dem Schleier
        // laeuft keine Uhr.
        if angebotTakt(vergangen: Self.taktSekunden), vorgeholteFolge != nil {
            print("[Angebot] Countdown abgelaufen bei \(Int(spielstand.position)) s")
            fflush(nil)
            naechsteFolge()
        }
        angebotNachfuehren()
        // Am Ende von selbst weiter — nur mit Karte (Abspann-Abschnitt vom
        // Server), nicht, wenn sie abgesagt wurde (Paul, 17.09.2026).
        if angebotsebene.weiterAmEnde,
           vorgeholteFolge != nil, !folgenwechsel.laeuft,
           Folgenende.weiterschalten(position: spielstand.position,
                                     dauer: spielstand.dauer,
                                     seitOeffnen: Date().timeIntervalSince(seitOeffnen)) {
            naechsteFolge()
        }
    }

    private enum Meldung { case start, fortschritt }

    private func melden(_ was: Meldung) {
        // **Waehrend eines Wechsels schweigt der Takt** (T2-M3): ab dem Stopp
        // der alten Folge ginge sonst noch Fortschritt fuer sie hinaus, und
        // Jellyfin eroeffnete ihre Sitzung neu.
        guard folgenwechsel.meldungenErlaubt,
              let client, let plan = laufenderPlan, let titel = laufenderTitel else { return }
        let ticks = Int64(spielstand.position * 10_000_000)
        switch was {
        case .start:
            meldeStart(client, titel: titel, plan: plan, ticks: ticks)
        case .fortschritt:
            meldeFortschritt(client, titel: titel, plan: plan, ticks: ticks,
                             pausiert: !spielstand.laeuft)
        }
    }

    // MARK: Meldungen an den Server — die eine Stelle

    private func meldung(_ art: Meldewarteschlange<Meldeinhalt>.Art, _ client: JellyfinClient,
                         titel: Item, plan: PlaybackPlan,
                         ticks: Int64) -> Meldewarteschlange<Meldeinhalt>.Meldung {
        .init(art: art,
              schluessel: Stoppsperre.schluessel(itemID: titel.id, playSessionID: plan.playSessionID),
              nutzlast: Meldeinhalt(client: client, titel: titel, plan: plan, ticks: ticks,
                                    spuren: spurlage.gemeldet))
    }

    /// Hier und nur hier geht Start, Fortschritt und Stopp hinaus — in die
    /// Reihe ``meldungen``, **abgesetzt, nicht abgewartet** (T1-H2): der Takt
    /// wartet nie auf den Server. Nur das Ende wartet (``meldeStopp``).
    func meldeStart(_ client: JellyfinClient, titel: Item, plan: PlaybackPlan, ticks: Int64) {
        meldetitel = (client, titel, plan)
        gemeldetPausiert = false
        meldungen.melden(meldung(.start, client, titel: titel, plan: plan, ticks: ticks))
    }

    func meldeFortschritt(_ client: JellyfinClient, titel: Item, plan: PlaybackPlan,
                          ticks: Int64, pausiert: Bool) {
        guard meldungen.melden(meldung(.fortschritt(pausiert: pausiert), client,
                                       titel: titel, plan: plan, ticks: ticks)) else {
            print("[Melden] Fortschritt nach Stopp verworfen \(titel.id)")
            fflush(nil)
            return
        }
        gemeldetPausiert = pausiert
    }

    /// **libVLC hat angehalten oder laeuft wieder — sofort melden** (T2-N1).
    ///
    /// Haengt an VLCs Ereignis (``Abspieler/laufzustand``), nicht am Druck:
    /// Knopf, Leertaste, Medientaste, Fernbefehl und Schlafwecker gehen alle
    /// hier durch, und gemeldet wird der Zustand, den VLC wirklich hat —
    /// nicht der, den der Knopf erwartet.
    func laufzustandGemeldet(laeuft: Bool) {
        guard let meldetitel, gemeldetPausiert == laeuft,
              meldetitel.titel.id == laufenderTitel?.id else { return }
        let stelle = spielstand.sprung?.ziel ?? abspieler.position
        print("[Melden] sofort: \(laeuft ? "weiter" : "Pause") bei \(Int(stelle)) s")
        fflush(nil)
        meldeFortschritt(meldetitel.client, titel: meldetitel.titel, plan: meldetitel.plan,
                         ticks: Int64(stelle * 10_000_000), pausiert: !laeuft)
    }

    /// **Jeder Sprung geht hier durch** — Knoepfe, Pfeiltasten, Regler,
    /// Ueberspringen und Fernbefehle. Stand und Sprungriegel werden mitgesetzt
    /// (T2-N2: „Springen auf" vom Dashboard setzte nur VLCs Zeit, und der
    /// Takt zog die Anzeige zurueck), und die Zielstelle geht sofort hinaus
    /// (T2-N1).
    func springe(auf ziel: Double) {
        let ziel = max(0, ziel)
        abspieler.setzeZeit(ziel)
        // Anzeige und Angebot sofort auf dem Ziel; der Takt haelt es, bis VLC
        // dort ist (Bug 17.09.2026).
        Wiedergabetakt.gesprungen(&spielstand, ziel: ziel)
        _ = angebotTakt(vergangen: 0)
        zeitenZeigen()
        angebotNachfuehren()
        letzterSprung = Date()
        guard let meldetitel, meldetitel.titel.id == laufenderTitel?.id,
              folgenwechsel.meldungenErlaubt else { return }
        print("[Melden] sofort: Sprung auf \(Int(ziel)) s")
        fflush(nil)
        meldeFortschritt(meldetitel.client, titel: meldetitel.titel, plan: meldetitel.plan,
                         ticks: Int64(ziel * 10_000_000), pausiert: gemeldetPausiert)
    }

    /// Relativ springen. Solange ein Sprung unterwegs ist, ist VLCs Zeit noch
    /// die alte — dann zaehlt die Stelle, zu der schon gesprungen wurde.
    func springe(um sekunden: Double) {
        let von = spielstand.sprung?.ziel ?? abspieler.position
        springe(auf: von + sekunden)
    }

    /// Angebot und Einblendung an die angezeigte Stelle anpassen — im Takt, und
    /// mit `vergangen: 0` direkt nach einem Sprung. `true`: Countdown abgelaufen.
    func angebotTakt(vergangen: Double) -> Bool {
        let angebot: Knopfangebot = folgenwechsel.laeuft ? .keiner
            : Abschnittslogik.angebot(position: spielstand.position,
                                      dauer: spielstand.dauer,
                                      abschnitte: abschnitte,
                                      hatNaechsteFolge: vorgeholteFolge != nil)
        jetzigesAngebot = angebot
        guard !folgenwechsel.laeuft else { return false }
        return angebotsebene.takt(
            angebot: angebot,
            karteFaellig: Abschnittslogik.karteFaellig(position: spielstand.position,
                                                       dauer: spielstand.dauer,
                                                       abschnitte: abschnitte,
                                                       hatNaechsteFolge: vorgeholteFolge != nil),
            laeuft: spielstand.laeuft && spielerLadeschirm == nil && !amRegler,
            vergangen: vergangen,
            countdown: Abschnittslogik.countdown(position: spielstand.position, dauer: spielstand.dauer))
    }

    /// Das Ende — **abgewartet**, weil danach die Seiten neu laden (d8492ca).
    /// Die Reihe schickt es hinter einem noch laufenden Start; doppelt kommt
    /// es nicht. Bei Fehler oder Fristablauf in die Nachmeldung (H8).
    func meldeStopp(_ client: JellyfinClient, titel: Item, plan: PlaybackPlan,
                    ticks: Int64, konto: String) async {
        let eintrag = meldung(.stopp, client, titel: titel, plan: plan, ticks: ticks)
        // Sofort, nicht nach der Antwort: Pause oder Sprung in der
        // Zwischenzeit gehoeren keinem Titel mehr (T1-M9).
        aufHauptfaden {
            if let t = self.meldetitel,
               Stoppsperre.schluessel(itemID: t.titel.id, playSessionID: t.plan.playSessionID)
                == eintrag.schluessel {
                self.meldetitel = nil
            }
        }
        let ergebnis = await meldungen.meldenUndWarten(eintrag)
        switch ergebnis {
        case .gesendet:
            print("[Melden] Stopped \(ticks / 10_000_000) s \(titel.id) session \(plan.playSessionID ?? "nil")")
        case .verworfen:
            print("[Melden] Stopped doppelt verworfen \(titel.id) session \(plan.playSessionID ?? "nil")")
        case .gescheitert, .zeitUeberschritten:
            // **H8, zweite Haelfte.** Die Stelle ist das, was ein Download
            // hinterlaesst und der Server nicht hat.
            Nachmeldezettel.aufnehmen(titel.id, ticks: ticks, konto: konto)
            print("[Melden] Stopped \(ergebnis) → Nachmeldung \(titel.id)")
        }
        fflush(nil)
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

    /// **Steht der Strom, wird er neu aufgebaut** — die fünf Schwellen dafür
    /// liegen als ``Stromwacht`` im Paket, mit Tests, und wurden auf Linux nie
    /// gerufen.
    ///
    /// **Warum das nötig ist, obwohl libVLC `http-reconnect` kann.** Das
    /// greift, wenn die Verbindung *abbricht*. Der Fall, den die Wacht meint,
    /// ist der andere: die Verbindung steht, es kommt nur nichts mehr — ein
    /// Server, der mitten im Strom aufhört zu liefern. Dann wartet libVLC
    /// beliebig lange, und auf dem Bild steht ein Standbild.
    ///
    /// **Die Wacht ist eine Bremse und darf selbst keinen Hänger erzeugen.**
    /// Deshalb entscheidet nicht diese Datei, sondern das Paket: ein Sprung
    /// unterwegs, ein wachsender Puffer oder ein frischer Netzwechsel sind je
    /// ein Grund zu warten. Die Zahlen stehen dort je Konstante begründet.
    private func stromPruefen() {
        guard let plan = laufenderPlan, plan.url.isFileURL == false,
              spielstand.laeuft, spielstand.startGemeldet else {
            stromStehtSeit = nil
            return
        }
        let jetzt = abspieler.position
        if abs(jetzt - stromLetzteStelle) > 0.05 {
            stromLetzteStelle = jetzt
            stromStehtSeit = nil
            return
        }
        // Wächst der Puffer, lebt der Strom — dann ist es der Server, der
        // langsam ist, und dem reisst man nichts ab.
        let gelesen = abspieler.zaehlwerte?.gelesen ?? 0
        if gelesen > stromGelesen {
            stromGelesen = gelesen
            stromPufferWuchs = Date()
        }
        let seit = stromStehtSeit ?? Date()
        stromStehtSeit = seit

        let rat = Stromwacht.rat(
            stillstandSeit: Date().timeIntervalSince(seit),
            netzwechselVor: nil,
            sprungOffen: spielstand.sprung != nil,
            letzterSprungVor: Date().timeIntervalSince(letzterSprung),
            pufferWuchsVor: Date().timeIntervalSince(stromPufferWuchs))
        guard rat == .neuVerbinden else { return }

        // **An derselben Stelle wieder auf.** `oeffnen` baut den Strom neu
        // auf, ohne die Seite anzufassen — die Steuerung, das Technikschild
        // und der Takt laufen weiter.
        stromStehtSeit = nil
        let stelle = spielstand.position
        abspieler.oeffnen(plan.url, ab: stelle, puffer: wahlen.puffer)
        abspieler.bildfuellend(wahlen.bildfuellend)
        spielstand.spurenGesetzt = false
        spurlage.neuGeoeffnet()
    }

    // Ton- und Untertitelwahl beim Start: ``spurenVorwaehlen()`` in `Spurwahl.swift`.

    /// Was der Knopf unten rechts gerade tut.
    func angebotAusfuehren() {
        angebotsebene.gedrueckt()
        print("[Angebot] ausgeloest: \(jetzigesAngebot.beschriftung) bei \(Int(spielstand.position)) s")
        fflush(nil)
        angebotNachfuehren()
        switch jetzigesAngebot {
        case .keiner:
            break
        case let .ueberspringen(nach, _):
            springe(auf: nach)
            steuerungZeigen()
        case .naechsteFolge:
            naechsteFolge()
        }
    }

    /// **Der Wechsel zur naechsten Folge — der Ablauf aus dem Paket.**
    ///
    /// `Folgenwechsel` haelt den Riegel (ein Wechsel zur Zeit), stoppt die
    /// alte Sitzung und holt den Plan nebeneinander, startet erst danach und
    /// wendet nach dem Schliessen nichts mehr an. Hier stand er von Hand:
    /// Fortschritt, Stopp und Start in drei losen Auftraegen, die in
    /// beliebiger Reihenfolge ankamen (T2-M3), und ein Erfolg, der den
    /// geschlossenen Player wieder bespielte (T2-H1). Hier bleibt nur, was
    /// Linux gehoert: welche Zustaende zur Folge zaehlen (``folgeAnwenden``).
    func naechsteFolge() {
        guard let client, let titel = laufenderTitel, let plan = laufenderPlan,
              let folge = vorgeholteFolge else { return }
        let wechsel = folgenwechsel
        guard !wechsel.laeuft else {
            print("[Wechsel] gesperrt → \(folge.id)")
            fflush(nil)
            return
        }
        let alt = (titel: titel, plan: plan, gemeldet: spielstand.startGemeldet,
                   ticks: Int64(spielstand.position * 10_000_000))
        let grenze = wahlen.profilBitrate
        let konto = benutzerID
        let angewandt = Merker()
        Task.detached { [self] in
            let ergebnis = await wechsel.ausfuehren(Folgenwechsel.Schritte<PlaybackPlan>(
                stoppen: {
                    // Ein Stopp ohne Start ist keine Sitzung.
                    guard alt.gemeldet else { return }
                    await self.meldeStopp(client, titel: alt.titel, plan: alt.plan,
                                          ticks: alt.ticks, konto: konto)
                },
                planen: {
                    try? await client.playbackPlan(for: folge.id,
                                                   profile: .vlc(maxBitrate: grenze))
                },
                anwenden: { neu in
                    // **Auf GTKs Faden, und hier noch einmal gefragt.** Der
                    // Ablauf laeuft abseits; zwischen seinem letzten Blick und
                    // diesem Auftrag kann der Player zugegangen sein.
                    aufHauptfadenWarten {
                        guard self.folgenwechsel === wechsel, wechsel.phase == .startet
                        else { return }
                        self.folgeAnwenden(folge, neu)
                        angewandt.wert = true
                    }
                },
                starten: { neu in
                    guard angewandt.wert else { return }
                    // Auf GTKs Faden: `meldetitel` gehoert ihm.
                    aufHauptfadenWarten { self.meldeStart(client, titel: folge, plan: neu, ticks: 0) }
                },
                gescheitert: {
                    aufHauptfaden {
                        guard self.folgenwechsel === wechsel else { return }
                        // Die alte Folge laeuft weiter, der Server kennt sie
                        // aber schon als beendet. Der Takt meldet sie neu an.
                        self.spielstand.startGemeldet = false
                        self.melden(uebersetzt("Nächste Folge konnte nicht geladen werden."))
                    }
                }))
            print("[Wechsel] \(ergebnis) → \(folge.id)")
            fflush(nil)
            guard ergebnis == .gewechselt else { return }
            self.nachschlagen(fuer: folge, wechsel: wechsel, client: client)
        }
    }

    /// Die neue Folge uebernehmen — **vor** dem Start.
    private func folgeAnwenden(_ folge: Item, _ plan: PlaybackPlan) {
        laufenderTitel = folge
        laufenderPlan = plan
        spurlageNeu(folge, plan: plan)
        // Stelle, Spuren, Startmeldung und erstes Bild zurueck; `true`, weil
        // der Wechsel den Start meldet (C1: sonst erst nach dem Puffern).
        // `neuerTitel` setzt auch `seitStart` (B7) und `erstesBildDa`.
        MainActor.assumeIsolated {
            Wiedergabetakt.neuerTitel(&self.spielstand, startGemeldet: true)
        }
        seitOeffnen = Date()
        // **Nichts zeigt mehr auf die alte Folge** (T1-M4).
        abschnitte = []
        vorgeholteFolge = nil
        angebotsebene.neueFolge()
        // **Das Tempo überlebt den Folgenwechsel.** Linux legt je Folge einen
        // neuen libVLC-Spieler an; ohne diese Zeile fängt die nächste Folge
        // wieder bei 1,0 an, obwohl der Zuschauer 1,25 gewählt hat.
        let tempo = abspieler.tempo
        // Die nächste Folge startet **von vorn** (B5).
        abspieler.oeffnen(plan.url, ab: 0, puffer: wahlen.puffer)
        // Was einmal gewaehlt wurde, gilt auch fuer die naechste Folge.
        abspieler.bildfuellend(wahlen.bildfuellend)
        technikschildSetzen(wahlen.technikschild)
        abspieler.tempo = tempo
        medienstandMelden()
    }

    /// **Abschnitte und naechste Folge zur laufenden Folge nachholen** — nur
    /// uebernehmen, wenn seither kein Wechsel begonnen hat, der Player offen
    /// ist und noch diese Folge zeigt (`Folgenwechsel.nachschlagen`, T1-M4).
    func nachschlagen(fuer item: Item, wechsel: Folgenwechsel, client: JellyfinClient) {
        let gilt: @Sendable (App) -> Bool = { app in
            app.folgenwechsel === wechsel && wechsel.phase == .ruht
                && app.laufenderTitel?.id == item.id
        }
        Task.detached { [self] in
            await wechsel.nachschlagen(holen: { await client.abschnitte(fuer: item.id) }) { marken in
                aufHauptfaden { if gilt(self) { self.abschnitte = marken } }
            }
        }
        guard let serie = item.seriesId else { return }
        Task.detached { [self] in
            await wechsel.nachschlagen(holen: {
                (try? await client.folgeNach(itemID: item.id, seriesID: serie)) ?? nil
            }) { folge in
                aufHauptfaden {
                    guard gilt(self) else { return }
                    self.vorgeholteFolge = folge
                    print("[Wechsel] naechste Folge \(folge?.id ?? "keine") nach \(item.id)")
                    fflush(nil)
                    self.medienstandMelden()
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
        springe(auf: ziel)
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
        // **Eine offene Tafel hält die Steuerung.** Wer gerade eine Tonspur
        // sucht, hat den Zeiger stillstehen — das ist kein Grund, ihm die
        // Liste unter der Hand wegzunehmen.
        // **Und nicht, waehrend jemand den Regler zieht** (B1). Der Mac
        // nimmt `amRegler` an derselben Stelle aus (`PlayerScreen.swift:257`).
        guard laufenderTitel != nil, spielerSteuerung != nil,
              spurtafel == nil, spielstand.laeuft, !amRegler else { return }
        steuerungstakt += 1
        gtk_widget_set_opacity(spielerSteuerung, 0)
        spurwahlSchliessen()
        zeigerZeigen(false)
        angebotNachfuehren()
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

    /// `.bewusst` (Klick, Taste, Knopf) sagt eine laufende Karte „Nächste
    /// Folge" ab, `.nebenbei` (Zeiger) nicht — Regel in `Angebotsebene`.
    func steuerungZeigen(durch art: Angebotsebene.Oeffnung = .bewusst) {
        // Der Zeiger meldet sich auch noch, während der Player hinausfährt.
        guard spielerSteuerung != nil else { return }
        zeigerZeigen(true)
        gtk_widget_set_opacity(spielerSteuerung, 1)
        if laufenderTitel != nil { angebotsebene.steuerung(offen: true, durch: art) }
        angebotNachfuehren()
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
                // **Nicht, waehrend jemand den Regler zieht** (B1: „nur bei
                // Wiedergabe, nicht beim Schieben"). Der Mac prueft an
                // derselben Stelle `!amRegler` (`PlayerScreen.swift:707`).
                guard self.laufenderTitel != nil, self.spielerSteuerung != nil,
                      self.spurtafel == nil, !self.amRegler,
                      self.steuerungstakt == meins, self.spielstand.laeuft else { return }
                gtk_widget_set_opacity(self.spielerSteuerung, 0)
                self.zeigerZeigen(false)
                // **Die Tafel gehoert zur Steuerung.** Sie liegt als eigener
                // Ueberzug daneben, also nimmt die Deckkraft der Steuerung sie
                // nicht mit — sie blieb offen ueber einem Bild ohne Bedienung.
                self.spurwahlSchliessen()
                self.angebotNachfuehren()
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
    /// **Links waehlen, rechts sehen** — die Form der Mac-Fassung.
    ///
    /// Vorher stand alles gleichzeitig ausgeklappt untereinander: jede
    /// Tonspur, jeder Untertitel, Tempo, Schlafzeit. Bei einer Datei mit acht
    /// Spuren ist das eine Rolle, in der man den eingestellten Stand suchen
    /// muss. Jetzt traegt die Leiste links den **aktuellen Wert** neben dem
    /// Namen, und rechts steht nur, was zum gewaehlten Bereich gehoert.
    ///
    /// Die Tafel klappt weiter **unter dem Knopf** auf, aus dem sie stammt
    /// (E5) — kleine Entscheidungen erscheinen dort, wo sie ausgeloest wurden.
    func spurwahlZeigen() {
        steuerungZeigen()
        if spurtafel != nil {
            // **Ein Ueberzug wird ueber den Ueberzug entfernt**, nicht ueber
            // `gtk_widget_unparent` — der laesst GTKs Buchfuehrung stehen.
            spurwahlSchliessen()
            return
        }
        spurbereich = .ton
        spurtafelBauen()
    }

    /// Baut die Tafel neu auf. Wird auch beim Bereichswechsel gerufen: GTK
    /// hat kein „Inhalt tauschen" wie SwiftUI, und eine Tafel mit zwei
    /// Spalten neu zu bauen kostet weniger als ein Ausraeumen von Hand --
    /// genau die Sorte Schleife, die in `Fallen/` steht.
    private func spurtafelBauen() {
        if let alt = spurtafel, spielerRahmen != nil {
            gtk_overlay_remove_overlay(OpaquePointer(spielerRahmen), alt)
            spurtafel = nil
        }

        let spalten = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)

        // --- Leiste links ------------------------------------------------
        // 260 breit, Innenrand 10, Zeilenabstand 4 — `Spurwahl.swift:105,154`.
        let leiste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 4)
        gtk_widget_add_css_class(leiste, "swiftly-spurleiste")
        raender(leiste, 10)
        gtk_widget_set_size_request(leiste, 260, -1)
        gtk_widget_set_valign(leiste, GTK_ALIGN_FILL)
        // **Das Technikschild steht abgesetzt, und es ist ein Schalter.**
        //
        // Auf dem Mac trennt eine Haarlinie es von den fuenf Waehlern darueber
        // und es traegt einen Schalter statt eines Wertes
        // (`macOS/PlayerScreen.swift`, Wiedergabetafel). Hier stand es als
        // sechste Wahlzeile mit dem Wert „Aus" — eine Zeile, die aussieht als
        // klappe sie etwas auf, und dann nur umschaltet.
        for b in Spurbereich.allCases where b != .technik {
            anhaengen(leiste, leistenzeile(b))
        }
        let tstrich: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(tstrich, "swiftly-trennlinie")
        gtk_widget_set_size_request(tstrich, -1, 1)
        gtk_widget_set_margin_top(tstrich, 8)
        gtk_widget_set_margin_bottom(tstrich, 8)
        anhaengen(leiste, tstrich)

        // Dieselbe Zeile wie die fuenf darueber, nur mit Schalter statt Wert
        // (`Spurwahl.swift:133-147`).
        let tzeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        // Ein Kasten, kein Knopf — die Klassenregel greift nur auf `button`,
        // also stehen Hoehe und seitlicher Rand hier.
        gtk_widget_set_size_request(tzeile, -1, 40)
        gtk_widget_set_margin_start(tzeile, 12)
        gtk_widget_set_margin_end(tzeile, 12)
        let tbild: Widget! = gtk_image_new_from_icon_name(Spurbereich.technik.symbol)
        gtk_image_set_pixel_size(OpaquePointer(tbild), 13)
        gtk_widget_set_size_request(tbild, 18, -1)
        gtk_widget_add_css_class(tbild, "swiftly-spurzeichen")
        anhaengen(tzeile, tbild)
        let tl = beschriftung(Spurbereich.technik.titel, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(tl), 0)
        gtk_widget_set_hexpand(tl, 1)
        anhaengen(tzeile, tl)
        anhaengen(tzeile, kleinerSchalter(an: wahlen.technikschild) { [weak self] an in
            guard let self else { return }
            self.wahlen.technikschild = an
            self.wahlen.sichern()
            self.technikschildSetzen(an)
        })
        anhaengen(leiste, tzeile)
        anhaengen(spalten, leiste)

        // **Doch ein Strich.** `Spurwahl.swift:79` setzt zwischen die Spalten
        // `Stil.linie.frame(width: 1)`. Hier stand das Gegenteil als
        // Kommentar — geschrieben, ohne die Vorlage aufzuschlagen.
        let spaltenstrich: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_add_css_class(spaltenstrich, "swiftly-trennlinie")
        gtk_widget_set_size_request(spaltenstrich, 1, -1)
        anhaengen(spalten, spaltenstrich)

        // --- Auswahl rechts ----------------------------------------------
        // Innenrand 18 — `Spurwahl.swift:81`.
        let rechts = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)
        raender(rechts, 18)
        gtk_widget_set_hexpand(rechts, 1)
        // **Ohne Rubrik.** Welcher Bereich gemeint ist, sagt die
        // hervorgehobene Zeile links — die Ueberschrift daneben wiederholt sie
        // nur. Auf dem Mac steht dort keine.
        let raum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        anhaengen(rechts, raum)
        auswahlFuellen(raum)

        // **Eine Tonspurliste kann lang sein — vierzig Untertitel sind
        // normal.** Der Scroller traegt die Hoehengrenze, nicht die Tafel: so
        // bleibt sie bei kurzen Listen so hoch wie ihr Inhalt.
        let rolle: Widget! = gtk_scrolled_window_new()
        // **`EXTERNAL`, nicht `AUTOMATIC`** (E4): scrollen ja, Leiste nein.
        // Das war die einzige Scrollflaeche der App mit einem echten
        // Systembalken — bei einem Titel mit vierzig Untertiteln stand er da.
        // Der Mac setzt an derselben Stelle `.scrollIndicators(.never)`
        // (`Spurwahl.swift:86`).
        gtk_scrolled_window_set_policy(OpaquePointer(rolle),
                                       GTK_POLICY_NEVER, GTK_POLICY_EXTERNAL)
        gtk_scrolled_window_set_propagate_natural_height(OpaquePointer(rolle), 1)
        gtk_scrolled_window_set_max_content_height(OpaquePointer(rolle), 420)
        gtk_scrolled_window_set_child(OpaquePointer(rolle), rechts)
        weichesScrollen(rolle)
        gtk_widget_set_hexpand(rolle, 1)
        anhaengen(spalten, rolle)

        let rahmen: Widget! = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(rahmen, "swiftly-tafel")
        anhaengen(rahmen, spalten)
        // 660 breit — `Spurwahl.swift:88`.
        gtk_widget_set_size_request(rahmen, 660, -1)
        gtk_widget_set_halign(rahmen, GTK_ALIGN_END)
        gtk_widget_set_valign(rahmen, GTK_ALIGN_START)
        // 18 oben plus 28 Knopfhoehe plus 18 Abstand — der Versatz vom Mac.
        gtk_widget_set_margin_top(rahmen, 64)
        gtk_widget_set_margin_end(rahmen, 22)
        gtk_widget_set_margin_bottom(rahmen, 22)

        spurtafel = rahmen
        gtk_overlay_add_overlay(OpaquePointer(spielerRahmen), rahmen)
    }

    /// Eine Zeile der Leiste: Zeichen, Name und der Stand.
    /// **Eine eigene Klasse, nicht `swiftly-wertzeile`.** Die traegt 48
    /// Punkt Einzug links, weil sie in den Einstellungen unter einem Symbol
    /// beginnt, das es hier nicht gibt — in der Tafel stand der Text dadurch
    /// eine halbe Spaltenbreite von seinem Zeichen entfernt.
    private func leistenzeile(_ b: Spurbereich) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-spurzeile")
        if b == spurbereich { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
        // Abstand 10, Zeichen in 18 Punkt Spalte — `Spurwahl.swift:110-114`.
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        let bild: Widget! = gtk_image_new_from_icon_name(b.symbol)
        gtk_image_set_pixel_size(OpaquePointer(bild), 13)
        gtk_widget_set_size_request(bild, 18, -1)
        anhaengen(reihe, bild)
        let l = beschriftung(b.titel, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        anhaengen(reihe, l)
        let fueller = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        gtk_widget_set_hexpand(fueller, 1)
        anhaengen(reihe, fueller)
        let w = beschriftung(spurwert(b), stil: "swiftly-leise")
        gtk_label_set_ellipsize(OpaquePointer(w), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(w), 18)
        anhaengen(reihe, w)
        gtk_button_set_child(alsKnopf(knopf), reihe)
        beiSignal(knopf, "clicked") { [weak self] in
            guard let self, self.spurbereich != b else { return }
            self.spurbereich = b
            self.spurtafelBauen()
        }
        return knopf
    }

    /// **Der Stand neben dem Namen — das ist der ganze Punkt der Leiste.**
    private func spurwert(_ b: Spurbereich) -> String {
        switch b {
        case .ton:
            let jetzt = abspieler.tonspur
            return tonspurnamen().first { $0.kennung == jetzt }?.name
                ?? uebersetzt("Keine")
        case .untertitel:
            let jetzt = abspieler.untertitelspur
            guard jetzt >= 0 else { return uebersetzt("Aus") }
            return untertitelnamen().first { $0.kennung == jetzt }?.name
                ?? uebersetzt("Aus")
        case .bildformat:
            return uebersetzt(wahlen.bildfuellend ? "Formatfüllend" : "Ganzes Bild")
        case .tempo:
            return Tempostufen.beschriftung(abspieler.tempo)
        case .schlafzeit:
            return schlafminuten.map { "\($0)" } ?? uebersetzt("Aus")
        case .technik:
            return uebersetzt(wahlen.technikschild ? "An" : "Aus")
        }
    }

    /// Was rechts steht — nur der gewaehlte Bereich.
    private func auswahlFuellen(_ raum: Widget!) {
        switch spurbereich {
        case .ton:
            let jetzt = abspieler.tonspur
            // **„Disable" ist keine Tonspur.** VLC haengt den Eintrag an
            // jede Liste; `tonspurnamen` laesst ihn weg, wie der Mac.
            for spur in tonspurnamen() {
                anhaengen(raum, wahlzeile(spur.name, gewaehlt: spur.kennung == jetzt) {
                    [weak self] in
                    self?.tonspurGewaehlt(spur.kennung)
                    self?.spurtafelBauen()
                })
            }
        case .untertitel:
            let jetzt = abspieler.untertitelspur
            anhaengen(raum, wahlzeile(uebersetzt("Aus"), gewaehlt: jetzt < 0) { [weak self] in
                self?.untertitelGewaehlt(nil)
                self?.spurtafelBauen()
            })
            for spur in untertitelnamen() {
                anhaengen(raum, wahlzeile(spur.name, gewaehlt: spur.kennung == jetzt) {
                    [weak self] in
                    self?.untertitelGewaehlt(spur.kennung)
                    self?.spurtafelBauen()
                })
            }
        case .bildformat:
            anhaengen(raum, wahlzeile(uebersetzt("Ganzes Bild"),
                                      gewaehlt: !wahlen.bildfuellend) { [weak self] in
                guard let self else { return }
                self.wahlen.bildfuellend = false
                self.wahlen.sichern()
                self.abspieler.bildfuellend(false)
                self.spurtafelBauen()
            })
            anhaengen(raum, wahlzeile(uebersetzt("Formatfüllend"),
                                      gewaehlt: wahlen.bildfuellend) { [weak self] in
                guard let self else { return }
                self.wahlen.bildfuellend = true
                self.wahlen.sichern()
                self.abspieler.bildfuellend(true)
                self.spurtafelBauen()
            })
        case .tempo:
            let jetzt = abspieler.tempo
            for wert in Tempostufen.werte {
                anhaengen(raum, wahlzeile(Tempostufen.beschriftung(wert),
                                          gewaehlt: abs(jetzt - wert) < 0.01) { [weak self] in
                    self?.abspieler.tempo = wert
                    self?.spurtafelBauen()
                })
            }
        case .schlafzeit:
            anhaengen(raum, wahlzeile(uebersetzt("Aus"),
                                      gewaehlt: schlafminuten == nil) { [weak self] in
                self?.schlafminuten = nil
                self?.spurtafelBauen()
            })
            for minuten in Schlafzeiten.werte {
                anhaengen(raum, wahlzeile("\(minuten)",
                                          gewaehlt: schlafminuten == minuten) { [weak self] in
                    self?.schlafzeitSetzen(minuten)
                    self?.spurtafelBauen()
                })
            }
        case .technik:
            anhaengen(raum, wahlzeile(uebersetzt("Anzeigen"),
                                      gewaehlt: wahlen.technikschild) { [weak self] in
                guard let self else { return }
                self.wahlen.technikschild = true
                self.wahlen.sichern()
                self.technikschildSetzen(true)
                self.spurtafelBauen()
            })
            anhaengen(raum, wahlzeile(uebersetzt("Aus"),
                                      gewaehlt: !wahlen.technikschild) { [weak self] in
                guard let self else { return }
                self.wahlen.technikschild = false
                self.wahlen.sichern()
                self.technikschildSetzen(false)
                self.spurtafelBauen()
            })
        }
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
                self.melden(uebersetzt("Schlafzeit abgelaufen."))
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

/// Ein Wert, den genau ein Faden nach dem anderen anfasst — hier die Frage,
/// ob `anwenden` wirklich angewandt hat. `aufHauptfadenWarten` sorgt fuer
/// die Reihenfolge.
private final class Merker: @unchecked Sendable {
    var wert = false
}

/// `aufHauptfaden`, aber wartend: `Folgenwechsel` ruft `anwenden` synchron
/// und meldet den Start gleich danach. Nie vom Hauptfaden aus rufen.
private func aufHauptfadenWarten(_ block: @escaping @Sendable () -> Void) {
    let fertig = DispatchSemaphore(value: 0)
    aufHauptfaden {
        block()
        fertig.signal()
    }
    fertig.wait()
}

/// Was eine Meldung an den Server braucht. Der Client wird beim Einreihen
/// festgehalten: wechselt danach das Konto, gehoert die Meldung trotzdem dem,
/// der geschaut hat.
struct Meldeinhalt: Sendable {
    let client: JellyfinClient
    let titel: Item
    let plan: PlaybackPlan
    let ticks: Int64
    /// Die laufenden Spuren als Jellyfin-Index (T3 #8) — aus ``Spurlage``.
    var spuren = Spurindizes()

    var spurtext: String {
        "\(spuren.ton.map(String.init) ?? "—")/\(spuren.untertitel.map(String.init) ?? "—")"
    }
}

#if DEBUG
/// Fernsteuerpult `meldungen:haengen|normal` — jede Meldung wartet 60 s, wie
/// ein Server, der nicht antwortet. Nur zum Messen, dass Zeitleiste und Takt
/// davon unberuehrt bleiben und die Frist greift.
enum Meldeprobe {
    nonisolated(unsafe) static var haengen = false
}
#endif
