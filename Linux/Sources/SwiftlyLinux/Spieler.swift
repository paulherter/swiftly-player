import CGtk
import Foundation
import JellyfinKit

/// **Der Player sieht überall gleich aus** (E10): oben rechts die beiden
/// Werkzeuge — Wiedergabe und Schließen, in dieser Reihenfolge —, Titel und
/// Folge unten links, Zeitleiste darunter, die drei Knöpfe mittig.
///
/// Hier stand „Schließen oben links, Einstellungen oben rechts". Das war die
/// gespiegelte Fassung von E10: die Fensterampel sitzt auf GTK rechts, also
/// sollte der Schließweg ihr links ausweichen. Am 13.09.2026 wurde es am
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
        // **Der Fensterstand von vorher** — nur beim ersten Oeffnen gemerkt,
        // nicht bei einem Folgenwechsel im laufenden Player.
        if laufenderTitel == nil {
            vollbildVorDemPlayer = gtk_window_is_fullscreen(alsFenster(fenster)) != 0
        }
        Protokoll.mitUhr("Player schliessen") {
            spielerSchliessen(melden: true, fensterZurueck: false)
        }
        // **Kein Bild des vorigen Titels** (T2-H1). Geschlossen wird mit
        // stehendem Bild, angehalten erst nach der Fahrt — wer innerhalb
        // dieser 380 ms den naechsten Titel oeffnet, saehe und hoerte sonst
        // den alten, bis der neue Plan da ist.
        Protokoll.mitUhr("VLC anhalten") { abspieler.beenden(nurMedium: true) }
        folgenwechsel = Folgenwechsel()
        vorgeholteFolge = nil
        angebotsebene.neueFolge()

        laufenderTitel = item
        spielstand = Wiedergabetakt.Stand()
        seitOeffnen = Date()
        letzterTakt = nil
        // **Der Weg vom Tippen bis zum Bild, Stueck fuer Stueck.**
        //
        // Ein Tester meldete am 20.09.2026, nach dem Klick auf Abspielen
        // dauere es ueber fuenf Sekunden. Im Protokoll war davon nichts zu
        // sehen: zwischen der letzten Zeile und dem Oeffnen klaffte eine
        // Luecke, weil niemand mitschrieb, was dazwischen geschieht. Ob der
        // Server langsam antwortet oder wir vor der Anfrage trOEdeln, ist
        // ohne diese Zeilen nicht zu unterscheiden.
        Protokoll.schreib("[Spieler] Abspielen gedrueckt, \(item.type ?? "?"), ab \(Int(ab)) s"
            + (datei != nil ? ", aus Datei" : ""))
        offeneEbene = nil
        offeneEbeneArt = nil
        // Je Titel einmal nachsehen, ob der Server Vorschaubilder hat — die
        // Datei-Wiedergabe (unten) hat keinen Server, dem sie fragen könnte.
        spielerTrickplay = Trickplaybilder()

        let seite = Protokoll.mitUhr("Spielerseite bauen") { spielerSeiteBauen(item) }
        // **Jede Spielerseite bekommt ihren eigenen Namen.** Alle „spieler" zu
        // nennen ging nur, solange die vorige beim Schliessen sofort aus dem
        // Stapel flog — und genau das nahm ihr die Abfahrt nach unten. Mit
        // einem laufenden Zaehler koennen alte und neue Seite fuer die Dauer
        // der Fahrt nebeneinander liegen, ohne sich den Namen zu streiten.
        spielerZaehler += 1
        gtk_stack_add_named(OpaquePointer(seiten), seite, "spieler-\(spielerZaehler)")
        // **Überblenden, 0,3 s** — wie auf dem Mac (`HauptView.swift`,
        // `.animation(.easeInOut(duration: 0.3), value: steuerung.wunsch?.id)`),
        // auf iPhone und Apple TV: der Player blendet ein und aus.
        gtk_stack_set_transition_type(OpaquePointer(seiten),
                                      GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_transition_duration(OpaquePointer(seiten), 300)
        Schubsperre.fuer(0.3)
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
        Protokoll.mitUhr("Abschnitte anstossen") {
            nachschlagen(fuer: item, wechsel: wechsel, client: client)
        }
        // **Die Antwort gehoert zu genau diesem Oeffnen** (T2-H1). Der Player
        // steht schon, der Plan kommt danach — wer in der Zwischenzeit
        // schliesst oder einen anderen Titel oeffnet, bekam sonst den Film
        // ohne Player zu hoeren, oder das Bild des ersten im zweiten.
        let meiner = spielerZaehler
        let gedrueckt = Date()
        Protokoll.schreib("[Spieler] frage Abspielplan beim Server")
        Task.detached { [self] in
            // Neben dem Plan, nicht davor: es kostet keine Wartezeit extra.
            async let frisch = stelleFrisch ? try? await client.item(id: item.id) : nil
            let plan = try? await client.playbackPlan(for: item.id, profile: .vlc(maxBitrate: grenze))
            let planNach = Date().timeIntervalSince(gedrueckt)
            let geholt = await frisch
            let allesNach = Date().timeIntervalSince(gedrueckt)
            let stelle = geholt.map { $0.fortsetzenAb ?? 0 } ?? ab
            if stelleFrisch {
                Protokoll.schreib("[Spieler] Stelle frisch \(geholt.map { _ in String(Int(stelle)) } ?? "nicht geholt"), Kachel \(Int(ab)) s")
                fflush(nil)
            }
            aufHauptfaden {
                guard self.spielerZaehler == meiner, self.laufenderTitel?.id == item.id,
                      self.folgenwechsel === wechsel else {
                    Protokoll.schreib("[Spieler] Plan verworfen, Player zu oder anderer Titel \(item.id)")
                    fflush(nil)
                    return
                }
                guard let plan else {
                    Protokoll.schreib("[Spieler] kein Plan \(item.id)")
                    fflush(nil)
                    // **D3: der Fehler nennt den Server, nicht nur „ging
                    // nicht".** Bei mehreren Servern weiss man sonst nicht,
                    // welcher gemeint ist. Wörtlich der Satz vom Mac
                    // (`Abspielsteuerung.starte`).
                    let wo = self.servername.isEmpty ? uebersetzt("dem Server") : self.servername
                    self.spielerMeldung(
                        String(format: uebersetzt("Die Wiedergabe hat nicht geklappt. Von %@ kamen keine Daten zum Abspielen."), wo))
                    return
                }
                Protokoll.schreib(String(format:
                    "[Spieler] Plan da nach %.1f s (Stelle frisch nach %.1f s), %@",
                    planNach, allesNach,
                    "\(plan.method), \(plan.container ?? "ohne Container")"))
                self.laufenderPlan = plan
                self.spurlageNeu(item, plan: plan)
                self.spielerTrickplay?.laden(client: client, item: item, plan: plan)
                self.warnungZeigen(plan)
                Protokoll.mitUhr("VLC oeffnen") {
                    self.abspieler.oeffnen(plan.url, ab: stelle, puffer: self.wahlen.puffer)
                }
                // Was einmal gewaehlt wurde, gilt auch fuer die naechste Folge.
                self.abspieler.bildfuellend(self.wahlen.bildfuellend)
                self.technikschildSetzen(self.wahlen.technikschild)
                self.spielstand.position = stelle
                self.taktStarten()
            }
        }
    }

    func spielerSchliessen(melden: Bool = true, fensterZurueck: Bool = true) {
        guard laufenderTitel != nil else { return }
        // **Nach dem Player steht das Fenster so da wie vorher** — wie auf
        // dem Mac (30aef4a3). Wer im Player auf Vollbild ging, egal ob mit
        // dem Knopf, F oder dem Fenstermanager, bekommt beim Schliessen das
        // Fenster von vorher zurueck. Lief die App schon vorher im Vollbild,
        // bleibt sie dort: das hat jemand bewusst so eingestellt.
        if fensterZurueck, !vollbildVorDemPlayer,
           gtk_window_is_fullscreen(alsFenster(fenster)) != 0 {
            gtk_window_unfullscreen(alsFenster(fenster))
        }
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
        ebeneSchliessen()
        technikschildSetzen(false)
        Wachhalter.setzen(false, fenster: fenster)
        // **Erst den Titel löschen, dann aufräumen.** Alles, was den Zeiger
        // versteckt, hängt daran; solange er steht, kann ein später
        // eintreffendes Ereignis die Aufräumarbeit wieder umstossen.
        laufenderTitel = nil
        Discordstand.abraeumen()
        spielerSteuerung = nil
        steuerungOffen = false
        spielerMitte = nil
        spielerSymbolreihe = nil
        spielerEbenenknoepfe = [:]
        spielerTitelplatz = nil
        spielerWeiter = nil
        spielerAngebot = nil
        spielerTitelstand = nil
        spielerTrickplay = nil
        angebotsebene.neueFolge()
        zeigerZeigen(true)
        abschnitte = []
        // **Ein alter Wecker haelt sonst spaeter eine andere Wiedergabe an.**
        schlaftakt += 1
        schlafminuten = nil
        laufenderPlan = nil
        medienstandMelden()
        // Ausblenden im selben Takt wie das Öffnen.
        gtk_stack_set_transition_type(OpaquePointer(seiten),
                                      GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_transition_duration(OpaquePointer(seiten), 300)
        Schubsperre.fuer(0.3)
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
        Protokoll.schreib("[Spieler] Sehstand nach dem Player \(oben.id), Scroll \(Int(vorher))")
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
                    Protokoll.schreib("[Spieler] Sehstand aufgefrischt: \(gezeichnet) Zeilen, Staffel \(staffel)")
                    fflush(nil)
                }
                // Nach dem Neuzeichnen und Layout nachsehen, nicht im selben Zug.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                aufHauptfaden {
                    Protokoll.schreib("[Spieler] Scroll nach dem Auffrischen \(Int(vorher)) → \(Int(self.scrollstand()))")
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

    /// **Der Aufbau folgt dem Mac** (`Sources/macOS/PlayerScreen.swift`,
    /// `body`), von unten nach oben: Bild, Ladeschirm, Sprungmarken,
    /// Steuerung (flache Abdunklung, Kopf, Mitte, Leiste), Vorschau,
    /// Überspringen-Pille, Technikschild, Ebene, stehender Titel.
    ///
    /// **Die Mitte liegt als eigene Schicht in der Steuerung**, mittig im
    /// ganzen Bild — nicht zwischen Kopf und Fuss, die verschieden hoch sind
    /// und sie sonst aus der Mitte schöben.
    private func spielerSeiteBauen(_ item: Item) -> Widget! {
        let ueber: Widget! = gtk_overlay_new()
        // **Die alte Seite muss ihr Kind loslassen, nicht nur hergeben.**
        //
        // Hier stand `gtk_widget_unparent(abspieler.anzeige)` mit der
        // Begruendung, das Bild sei ein Widget, das der Abspieler behaelt.
        // Das stimmt — nur loest `unparent` allein das Bild aus dem
        // Fensterbaum, waehrend das alte `GtkOverlay` seinen eigenen Zeiger
        // darauf behaelt. Raeumt der Stapel die alte Seite 380 ms spaeter
        // ab (siehe den Wecker in ``spielerSchliessen``), ruft das Overlay
        // `unparent` ein zweites Mal — da haengt das Bild laengst in der
        // neuen Seite und wird ihr entrissen.
        //
        // Gemessen am 20.09.2026, Linux und Windows-VM, beim zweiten Titel:
        // `mapped=0 uhr=0 eltern=0`. Ohne Fenster kein Taktgeber, ohne
        // Taktgeber holt niemand mehr ein Bild von der Bruecke — VLCs Uhr
        // lief weiter, `has_vout` meldete 1, und auf dem Schirm stand das
        // Bild still. Von aussen ist das genau die Meldung „startet
        // schwarz, Pause holt es zurueck".
        //
        // `spielerRahmen` zeigt an dieser Stelle noch auf die **alte**
        // Seite; erst danach wird sie ueberschrieben. Das macht den Griff
        // typsicher, ohne auf GTKs Typpruefung auszuweichen.
        if let alteSeite = spielerRahmen,
           gtk_widget_get_parent(abspieler.anzeige) == alteSeite {
            gtk_overlay_set_child(OpaquePointer(alteSeite), nil)
        } else if gtk_widget_get_parent(abspieler.anzeige) != nil {
            gtk_widget_unparent(abspieler.anzeige)
        }
        spielerRahmen = ueber
        gtk_widget_add_css_class(ueber, "swiftly-spieler")
        gtk_overlay_set_child(OpaquePointer(ueber), abspieler.anzeige)

        let schleier = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(schleier, "swiftly-spieler")
        spielerLadeschirm = schleier
        // **Wenn VLC noch laedt, steht es da.** Sonst sieht ein Zuschauer beim
        // allerersten Titel nach einer frischen Installation eine schwarze
        // Flaeche und weiss nicht, ob etwas kaputt ist. Nur in diesem einen
        // Fall — laeuft VLC schon, bleibt der Schleier stumm wie bisher.
        if !abspieler.bereit {
            gtk_widget_set_valign(schleier, GTK_ALIGN_CENTER)
            let hinweis = beschriftung(uebersetzt("VLC lädt noch"), stil: "swiftly-zweitzeile")
            anhaengen(schleier, hinweis)
        }
        gtk_overlay_add_overlay(OpaquePointer(ueber), schleier)

        // Die Sprungmarken stehen unabhängig von der Steuerung: wer mit den
        // Pfeiltasten springt, hat sie meist gar nicht offen.
        let links = Sprungmarke(zurueck: true)
        let rechts = Sprungmarke(zurueck: false)
        spielerSprungLinks = links
        spielerSprungRechts = rechts
        for (marke, seite) in [(links, GTK_ALIGN_START), (rechts, GTK_ALIGN_END)] {
            gtk_widget_set_halign(marke.anzeige, seite)
            gtk_widget_set_valign(marke.anzeige, GTK_ALIGN_CENTER)
            gtk_widget_set_margin_start(marke.anzeige, 44)
            gtk_widget_set_margin_end(marke.anzeige, 44)
            gtk_overlay_add_overlay(OpaquePointer(ueber), marke.anzeige)
        }

        let steuerung: Widget! = gtk_overlay_new()
        gtk_widget_add_css_class(steuerung, "swiftly-steuerung")
        gtk_widget_set_opacity(steuerung, 0)
        gtk_widget_set_can_target(steuerung, 0)
        spielerSteuerung = steuerung
        steuerungOffen = false
        let saeule = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        anhaengen(saeule, spielerkopf(item))
        anhaengen(saeule, luft())
        anhaengen(saeule, spielerfuss(item))
        gtk_overlay_set_child(OpaquePointer(steuerung), saeule)
        let mitte = spielermitte()
        spielerMitte = mitte
        gtk_overlay_add_overlay(OpaquePointer(steuerung), mitte)
        gtk_overlay_add_overlay(OpaquePointer(ueber), steuerung)

        gtk_overlay_add_overlay(OpaquePointer(ueber), spielerVorschauBauen())
        angebotsebeneBauen(in: ueber)
        gtk_overlay_add_overlay(OpaquePointer(ueber), spielerTitelstandBauen(item))

        beiZeiger(ueber, herein: { [weak self] in self?.steuerungZeigen(durch: .nebenbei) },
                         hinaus: { [weak self] in self?.steuerungVerbergen() })
        beiBewegung(ueber) { [weak self] in self?.steuerungZeigen(durch: .nebenbei) }
        // **Klick ins Bild holt die Steuerung bewusst.** Bei offener Ebene tut
        // ein Klick auf ihren Grund nichts (Mac: `Ebenengrund`,
        // `.onTapGesture {}`) — sie schliesst über X oder Escape.
        beiKlick(ueber) { [weak self] in
            guard let self, self.offeneEbeneArt == nil else { return }
            self.steuerungZeigen()
        }
        steuerungZeigen()
        return ueber
    }

    /// **Oben links Titel und Metazeile, oben rechts nur Symbole** (Mac:
    /// `kopf`). Der Titel hier ist nur Platzhalter — gezeigt wird er vom
    /// stehenden Titel, der bei offener Folgenebene stehen bleibt.
    private func spielerkopf(_ item: Item) -> Widget! {
        let kopf = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        gtk_widget_set_margin_top(kopf, Playermass.oben)
        gtk_widget_set_margin_start(kopf, Playermass.seite)
        gtk_widget_set_margin_end(kopf, Playermass.seite)

        let links = stapel(GTK_ORIENTATION_VERTICAL, abstand: 3)
        gtk_widget_set_hexpand(links, 1)
        let platz = beschriftung(laufenderTitelzeile, stil: "swiftly-spielertitel")
        gtk_label_set_ellipsize(OpaquePointer(platz), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(platz), 0)
        gtk_widget_set_opacity(platz, 0)
        spielerTitelplatz = platz
        anhaengen(links, platz)
        let meta = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
        metazeileFuellen(meta, item)
        spielerMetazeile = meta
        anhaengen(links, meta)
        anhaengen(kopf, links)

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: Playermass.reihenAbstand)
        gtk_widget_set_valign(reihe, GTK_ALIGN_START)
        spielerSymbolreihe = reihe
        spielerEbenenknoepfe = [:]

        let (spuren, _) = symbolknopf("untertitel", beschriftung: uebersetzt("Audio & Untertitel")) {
            [weak self] in self?.ebeneOeffnen(.spuren)
        }
        spielerEbenenknoepfe[.spuren] = spuren
        anhaengen(reihe, spuren)

        if hatFolgenebene {
            let (folgen, _) = symbolknopf("folgen", beschriftung: uebersetzt("Folgen")) {
                [weak self] in self?.ebeneOeffnen(.folgen)
            }
            spielerEbenenknoepfe[.folgen] = folgen
            anhaengen(reihe, folgen)
        }

        let (einstellungen, _) = symbolknopf("einstellungen", beschriftung: uebersetzt("Einstellungen")) {
            [weak self] in self?.ebeneOeffnen(.einstellungen)
        }
        spielerEbenenknoepfe[.einstellungen] = einstellungen
        anhaengen(reihe, einstellungen)

        let vollAktiv = gtk_window_is_fullscreen(alsFenster(fenster)) != 0
        let (vollbild, vollbildzeichen) = symbolknopf(
            vollAktiv ? "vollbild-aus" : "vollbild",
            beschriftung: vollAktiv ? uebersetzt("Vollbild verlassen") : uebersetzt("Vollbild")) {
            [weak self] in self?.vollbildUmschalten()
        }
        spielerVollknopf = vollbild
        spielerVollbildbild = vollbildzeichen
        anhaengen(reihe, vollbild)

        let (schliessen, _) = symbolknopf("schliessen", beschriftung: uebersetzt("Player schließen")) {
            [weak self] in self?.spielerSchliessen()
        }
        anhaengen(reihe, schliessen)
        anhaengen(kopf, reihe)
        return kopf
    }

    /// **Der Titel oben links, eine Schicht über allem** (Mac:
    /// `stehenderTitel`). Eine Zeile, fett, mit … gekürzt; rechts hält er der
    /// Symbolreihe den Platz frei. Nimmt keine Klicks — er liegt über den
    /// Knöpfen der Steuerung und der Ebenen.
    private func spielerTitelstandBauen(_ item: Item) -> Widget! {
        let stand = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        gtk_widget_set_valign(stand, GTK_ALIGN_START)
        gtk_widget_set_margin_top(stand, Playermass.oben)
        gtk_widget_set_margin_start(stand, Playermass.seite)
        gtk_widget_set_margin_end(stand, Playermass.seite)
        gtk_widget_set_can_target(stand, 0)
        gtk_widget_set_opacity(stand, 0)

        let titel = beschriftung(laufenderTitelzeile, stil: "swiftly-spielertitel")
        gtk_label_set_ellipsize(OpaquePointer(titel), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(titel), 0)
        gtk_widget_set_hexpand(titel, 1)
        spielerTitelzeile = titel
        anhaengen(stand, titel)

        let platz = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        gtk_widget_set_size_request(platz, symbolreihenBreite(), 1)
        anhaengen(stand, platz)

        spielerTitelstand = stand
        return stand
    }

    private func metazeileFuellen(_ zeile: Widget!, _ item: Item) {
        var text: String?
        if item.type == "Episode", let staffel = item.parentIndexNumber, let folge = item.indexNumber {
            text = String(format: uebersetzt("Staffel %d · Folge %d"), staffel, folge)
        } else if let t = item.kontextzeile ?? (item.nebenzeile.isEmpty ? nil : item.nebenzeile) {
            text = t
        }
        if let text {
            let l = beschriftung(text, stil: "swiftly-spielerzeile")
            gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
            gtk_label_set_xalign(OpaquePointer(l), 0)
            anhaengen(zeile, l)
        }
        // Nicht verlustfrei: Warnzeichen und Verfahren, in der Warnfarbe
        // (Mac: `exclamationmark.triangle.fill`, `Stil.warnung`).
        let warnung = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 5)
        gtk_widget_set_visible(warnung, 0)
        let zeichen = Playerzeichen("warnung", groesse: 14, farbe: (0.910, 0.514, 0.227, 1))
        anhaengen(warnung, zeichen.anzeige)
        spielerWarntext = beschriftung("", stil: "swiftly-spielerzeile")
        anhaengen(warnung, spielerWarntext)
        gtk_widget_add_css_class(warnung, "swiftly-warnung")
        spielerWarnung = warnung
        anhaengen(zeile, warnung)
    }

    /// Beim Wechsel der Folge: Titel, Platzhalter und Metazeile neu.
    private func titelstandAuffrischen(_ item: Item) {
        let text = laufenderTitelzeile
        if let titel = spielerTitelzeile { gtk_label_set_text(OpaquePointer(titel), text) }
        if let platz = spielerTitelplatz { gtk_label_set_text(OpaquePointer(platz), text) }
        if let meta = spielerMetazeile {
            leeren(meta)
            metazeileFuellen(meta, item)
            if let plan = laufenderPlan { warnungZeigen(plan) }
        }
    }

    func vollbildUmschalten() {
        let jetzt = gtk_window_is_fullscreen(alsFenster(fenster)) != 0
        if jetzt { gtk_window_unfullscreen(alsFenster(fenster)) }
        else { gtk_window_fullscreen(alsFenster(fenster)) }
        spielerVollbildbild?.setzeName(jetzt ? "vollbild" : "vollbild-aus")
        if let knopf = spielerVollknopf {
            let text = jetzt ? uebersetzt("Vollbild") : uebersetzt("Vollbild verlassen")
            gtk_widget_set_tooltip_text(knopf, text)
            beschriften(knopf, text)
        }
        steuerungZeigen()
    }

    /// Mittig im Bild: zurück, abspielen, vor — Abstand 80, Zeichen 30 und 40
    /// in Kisten von 54 und 72 (Mac: `mittelsteuerung`, `Sprungknopf`).
    private func spielermitte() -> Widget! {
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 80)
        gtk_widget_set_halign(reihe, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(reihe, GTK_ALIGN_CENTER)

        let zurueck = Playerzeichen("zurueck", groesse: 36, zahl: wahlen.zurueckSekunden)
        spielerZurueckZeichen = zurueck
        anhaengen(reihe, spieltaste(zurueck.anzeige, kiste: 54,
                                    name: String(format: uebersetzt("%d Sekunden zurück"), wahlen.zurueckSekunden)) {
            [weak self] in
            guard let self else { return }
            self.springe(um: -Double(self.wahlen.zurueckSekunden))
            self.spielerZurueckZeichen?.stupsen()
            self.steuerungZeigen()
        })

        let mitte = Playerzeichen("pause", groesse: 46)
        spielerAbspielzeichen = mitte
        anhaengen(reihe, spieltaste(mitte.anzeige, kiste: 72,
                                    name: uebersetzt("Abspielen oder anhalten")) {
            [weak self] in
            guard let self else { return }
            self.abspieler.umschalten()
            self.spielstand.laeuft.toggle()
            self.spielerAbspielzeichen?.setzen(self.spielstand.laeuft)
            self.medienstandMelden()
            self.steuerungZeigen()
        })

        let vor = Playerzeichen("vor", groesse: 36, zahl: wahlen.vorSekunden)
        spielerVorZeichen = vor
        anhaengen(reihe, spieltaste(vor.anzeige, kiste: 54,
                                    name: String(format: uebersetzt("%d Sekunden vor"), wahlen.vorSekunden)) {
            [weak self] in
            guard let self else { return }
            self.springe(um: Double(self.wahlen.vorSekunden))
            self.spielerVorZeichen?.stupsen()
            self.steuerungZeigen()
        })
        return reihe
    }

    private func spieltaste(_ zeichen: Widget!, kiste: Int32, name: String,
                            auswahl: @escaping () -> Void) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-spieltaste")
        gtk_widget_set_size_request(knopf, kiste, kiste)
        gtk_widget_set_valign(knopf, GTK_ALIGN_CENTER)
        beschriften(knopf, name)
        gtk_button_set_child(alsKnopf(knopf), zeichen)
        beiSignal(knopf, "clicked", auswahl)
        return knopf
    }

    /// Nur die Leiste, über die volle Breite: links die verstrichene Zeit,
    /// rechts die Restzeit (Mac: `fuss`, `Zeitzeile`). Darüber hält eine
    /// unsichtbare Pille der Überspringen-Pille den Platz — rechts, 20 über
    /// der Leiste.
    private func spielerfuss(_ item: Item) -> Widget! {
        let unten = stapel(GTK_ORIENTATION_VERTICAL, abstand: Playermass.ueberLeiste)
        gtk_widget_set_margin_start(unten, Playermass.seite)
        gtk_widget_set_margin_end(unten, Playermass.seite)
        gtk_widget_set_margin_bottom(unten, Playermass.unten)

        let platzreihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        anhaengen(platzreihe, luftQuer())
        let weiter = Angebotsknopf { [weak self] in self?.angebotAusfuehren() }
        gtk_widget_set_halign(weiter.knopf, GTK_ALIGN_END)
        spielerWeiter = weiter
        anhaengen(platzreihe, weiter.knopf)
        anhaengen(unten, platzreihe)

        let leiste = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
        spielerZeit = beschriftung("0:00", stil: "swiftly-spielerzeit")
        gtk_widget_set_size_request(spielerZeit, 52, -1)
        gtk_label_set_xalign(OpaquePointer(spielerZeit), 0)
        anhaengen(leiste, spielerZeit)
        spielerRegler = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.001)
        gtk_scale_set_draw_value(alsSkala(spielerRegler), 0)
        gtk_widget_add_css_class(spielerRegler, "swiftly-regler")
        gtk_widget_set_hexpand(spielerRegler, 1)
        gtk_widget_set_size_request(spielerRegler, -1, Playermass.leiste)
        beschriften(spielerRegler, uebersetzt("Abspielstelle"))
        g_signal_connect_data(UnsafeMutableRawPointer(spielerRegler), "change-value",
                              unsafeBitCast(reglerGezogen, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(),
                              nil, GConnectFlags(rawValue: 0))
        // `amRegler` wie auf dem Mac: solange gezogen wird, blendet die
        // Steuerung nicht aus, die Stelle des Servers überschreibt die
        // gezogene nicht (B1, B4), und Mitte und Symbolreihe weichen der
        // Vorschau.
        beiGriff(spielerRegler) { [weak self] gedrueckt in
            guard let self else { return }
            self.amRegler = gedrueckt
            for w in [self.spielerMitte, self.spielerSymbolreihe] {
                guard let w else { continue }
                gtk_widget_set_opacity(w, gedrueckt ? 0 : 1)
                gtk_widget_set_can_target(w, gedrueckt ? 0 : 1)
            }
            if gedrueckt {
                gtk_widget_add_css_class(self.spielerRegler, "swiftly-regler-ziehen")
                self.steuerungZeigen()
            } else {
                gtk_widget_remove_css_class(self.spielerRegler, "swiftly-regler-ziehen")
                self.vorschauVerbergen()
                self.steuerungZeigen()
            }
        }
        // Die Vorschau erscheint schon beim Überfahren, nicht erst beim
        // Ziehen (Mac: `onContinuousHover`).
        beiMausOrt(spielerRegler, bewegt: { [weak self] x, _ in
            guard let self, !self.amRegler else { return }
            let breite = Double(gtk_widget_get_width(self.spielerRegler))
            guard breite > 0 else { return }
            self.vorschauZeigen(anteil: min(max(x / breite, 0), 1))
        }, verlassen: { [weak self] in
            guard let self, !self.amRegler else { return }
            self.vorschauVerbergen()
        })
        anhaengen(leiste, spielerRegler)
        spielerRest = beschriftung("−0:00", stil: "swiftly-spielerzeit")
        gtk_widget_set_size_request(spielerRest, 58, -1)
        gtk_label_set_xalign(OpaquePointer(spielerRest), 1)
        anhaengen(leiste, spielerRest)
        anhaengen(unten, leiste)
        return unten
    }

    /// Trickplay-Vorschau über dem Griff: Bild 170 breit in 16 : 9, darunter
    /// die Zeit fett (Mac: `vorschauKasten`). Ohne Trickplay nur die Zeit.
    private func spielerVorschauBauen() -> Widget! {
        let huelle = stapel(GTK_ORIENTATION_VERTICAL, abstand: 6)
        gtk_widget_set_halign(huelle, GTK_ALIGN_START)
        gtk_widget_set_valign(huelle, GTK_ALIGN_END)
        gtk_widget_set_can_target(huelle, 0)
        gtk_widget_set_opacity(huelle, 0)

        let (rahmen, bild) = gerahmtesBild(breite: 170, hoehe: 96, stil: "swiftly-vorschaubild")
        spielerVorschaubild = bild
        spielerVorschauhuelle = rahmen
        anhaengen(huelle, rahmen)

        let zeit = beschriftung("0:00", stil: "swiftly-vorschauzeit")
        gtk_widget_set_halign(zeit, GTK_ALIGN_CENTER)
        spielerVorschauzeit = zeit
        anhaengen(huelle, zeit)

        spielerVorschau = huelle
        return huelle
    }

    func vorschauZeigen(anteil: Double) {
        guard offeneEbeneArt == nil, spielstand.dauer > 0, let regler = spielerRegler,
              let huelle = spielerVorschau, let rahmen = spielerRahmen,
              let bild = spielerVorschaubild, let zeitfeld = spielerVorschauzeit else { return }
        let stelle = spielstand.dauer * anteil
        var r = graphene_rect_t()
        guard gtk_widget_compute_bounds(regler, rahmen, &r) != 0, r.size.width > 0 else { return }

        let hatBild = spielerTrickplay?.angabe != nil
        if let textur = spielerTrickplay?.kachel(bei: stelle, client: client) {
            gtk_picture_set_paintable(OpaquePointer(bild), textur)
        }
        gtk_widget_set_visible(spielerVorschauhuelle, hatBild ? 1 : 0)
        gtk_label_set_text(OpaquePointer(zeitfeld), Spielzeit.text(stelle))

        // Mittig über der Stelle, am Rand festgehalten; 2 über der
        // Trefferfläche der Leiste.
        let halb = hatBild ? 85.0 : 40.0
        let rahmenBreite = Double(gtk_widget_get_width(rahmen))
        let mitteX = Double(r.origin.x) + Double(r.size.width) * anteil
        let ziel = min(max(mitteX, halb), max(rahmenBreite - halb, halb))
        gtk_widget_set_margin_start(huelle, Int32((ziel - halb).rounded()))
        if !hatBild { gtk_widget_set_size_request(huelle, 80, -1) }
        else { gtk_widget_set_size_request(huelle, 170, -1) }
        let untenAb = Double(gtk_widget_get_height(rahmen)) - Double(r.origin.y) + 2
        gtk_widget_set_margin_bottom(huelle, Int32(untenAb.rounded()))
        gtk_widget_set_opacity(huelle, 1)
    }

    func vorschauVerbergen() {
        guard let huelle = spielerVorschau else { return }
        gtk_widget_set_opacity(huelle, 0)
    }

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
        // Takt, dazwischen wird nur die Zeit nachgezogen (17.09.2026).
        let ms = UInt32(Wiedergabetakt.anzeigetakt.components.seconds * 1000
                        + Wiedergabetakt.anzeigetakt.components.attoseconds / 1_000_000_000_000_000)
        // **Prioritaet 0, nicht 200.** Derselbe Grund wie bei
        // ``aufHauptfaden``: mit `G_PRIORITY_DEFAULT_IDLE` verhungert dieser
        // Takt hinter GTKs Neuzeichnen (120), sobald im Player Bild fuer Bild
        // ein neues Paintable gesetzt wird. Genau dann wird er aber gebraucht
        // — er nimmt den Ladeschleier weg und traegt die Zeit nach.
        spielertakt = g_timeout_add_full(0, ms, spielerTaktRuf,
                                         Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// **Der Nachweis fuer „das Bild bleibt schwarz".**
    ///
    /// Drei Zahlen trennen die Faelle, die von aussen gleich aussehen: `vout`
    /// sagt, ob VLC ueberhaupt eine Bildausgabe hat, `bilder` sagt, ob an der
    /// Bruecke welche ankommen, und `bildDa` sagt, ob die App sie glaubt.
    /// Steht `vout` auf 1 und `bilder` bei null, liegt es an der Bruecke;
    /// steht `bilder` hoch und `bildDa` auf false, an der Annahme.
    /// Nur im Debug-Bau und nur mit `SWIFTLY_BILDMESSUNG=1`.
    private func bildmessungSchreiben(_ messung: Wiedergabetakt.Messung) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SWIFTLY_BILDMESSUNG"] == "1" else { return }
        print(String(format: "[Bild] %5.2f s  vout=%d  zeit=%.2f  takte=%d  bilder=%d  bildDa=%d  einst=%d  laeuft=%d",
                     Date().timeIntervalSince(seitOeffnen), messung.zeigtBild ? 1 : 0,
                     messung.position, abspieler.takte, abspieler.geholteBilder,
                     spielstand.erstesBildDa ? 1 : 0, messung.stelltEin ? 1 : 0,
                     messung.laeuft ? 1 : 0) + "  " + abspieler.taktlage)
        fflush(nil)
        #endif
    }

    /// **Der Weg bis zum ersten Bild, im Protokoll jedes Baus.**
    ///
    /// Anders als ``bildmessungSchreiben(_:)`` laeuft das hier auch im
    /// ausgelieferten Bau, denn genau daran fehlte es: im Protokoll eines
    /// Testers stand am 20.09.2026 keine einzige Zeile aus dem Player, und
    /// die Meldung „startet schwarz" war damit nicht nachzurechnen.
    ///
    /// Es bleibt kurz. Bis das erste Bild steht, eine Zeile je Sekunde;
    /// danach eine einzige, die sagt, wie lange es gedauert hat. Ein Film
    /// von zwei Stunden kostet damit zwei Zeilen, ein Start, der haengt,
    /// so viele wie noetig.
    /// **Wenn der Takt ausbleibt, stand der Hauptfaden.**
    ///
    /// ``Protokoll/mitUhr(_:_:)`` misst einzelne Aufrufe — aber die teuerste
    /// Arbeit steckt unter Umstaenden gar nicht in einem Aufruf von uns,
    /// sondern in GTKs Zeichnen. Auf einem Rechner mit `GskCairoRenderer`
    /// wird jedes Bild in Software auf Fenstergroesse gerechnet, und eine
    /// ueberblendete Vollbildseite kostet dort ein Vielfaches. Das faellt
    /// durch jede Messung, die nur den eigenen Kode umschliesst.
    ///
    /// Diese Wache faellt nicht darauf herein: der Takt kommt alle 250 ms,
    /// und bleibt er eine Sekunde aus, hat etwas den Faden gehalten. Was es
    /// war, sagt sie nicht — aber dass es geschah, und wann. Ein Tester
    /// nannte es am 20.09.2026 „fenster war wie eingefroren".
    private func taktluecke() {
        let jetzt = ContinuousClock.now
        defer { letzterTakt = jetzt }
        guard let vorher = letzterTakt else { return }
        let d = jetzt - vorher
        let ms = Double(d.components.seconds) * 1000
               + Double(d.components.attoseconds) / 1e15
        if ms >= 1000 {
            Protokoll.schreib(String(format: "[Hauptfaden] Takt %.1f s ausgeblieben", ms / 1000))
        }
    }

    private func startverlaufSchreiben(_ messung: Wiedergabetakt.Messung,
                                       auftrag: Wiedergabetakt.Auftrag) {
        // **Was ein Sprung gebracht hat.** Einmal, beim naechsten vollen Takt.
        if let dazu = abspieler.sprungbilanz() {
            Protokoll.schreib(String(format:
                "[Player] nach dem Sprung: Zeit %.0f s, %d Bilder dazu, vout %d",
                messung.position, dazu, messung.zeigtBild ? 1 : 0))
        }
        if auftrag.ladeschirmWeg {
            startwarten = 0
            Protokoll.schreib(String(format:
                "[Player] erstes Bild nach %.1f s (vout %d, Bilder %d, Takte %d)",
                Date().timeIntervalSince(seitOeffnen), messung.zeigtBild ? 1 : 0,
                abspieler.geholteBilder, abspieler.takte))
            return
        }
        guard !spielstand.erstesBildDa else { return }
        // Der volle Takt kommt alle 500 ms; jede zweite Runde ist eine Sekunde.
        startwarten += 1
        guard startwarten % 2 == 0 else { return }
        Protokoll.schreib(String(format:
            "[Player] warte auf das erste Bild, %.0f s (vout %d, puffert %d, laeuft %d, Zeit %.1f, Bilder %d, Takte %d)",
            Date().timeIntervalSince(seitOeffnen), messung.zeigtBild ? 1 : 0,
            messung.stelltEin ? 1 : 0, messung.laeuft ? 1 : 0, messung.position,
            abspieler.geholteBilder, abspieler.takte))
    }

    private func taktBeenden() {
        if spielertakt != 0 { g_source_remove(spielertakt); spielertakt = 0 }
    }

    /// Ein Takt. Die Rechnung selbst steht im Paket — hier wird nur gemessen,
    /// gefragt und ausgeführt.
    func takten() {
        guard laufenderTitel != nil else { return }
        taktluecke()
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
        bildmessungSchreiben(messung)
        startverlaufSchreiben(messung, auftrag: auftrag)

        // **Bis das erste Bild steht, deckt ein Schleier.** Ohne ihn sieht man
        // den Aufbau des Stroms — Klötzchen, ein Ruck, manchmal ein grüner
        // Rahmen. Wann er weicht, entscheidet ``Zeitannahme`` im Paket, nicht
        // diese Datei; ich hatte den Auftrag nur nie ausgewertet.
        if auftrag.ladeschirmWeg, let schleier = spielerLadeschirm {
            // Mac: `withAnimation(.easeOut(duration: 0.3)) { schirmWeg = true }`.
            gtk_widget_set_can_target(schleier, 0)
            blenden(schleier, auf: 0, dauer: 0.3, kennlinie: .easeOut)
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
            Protokoll.schreib("[Angebot] Countdown abgelaufen bei \(Int(spielstand.position)) s")
            fflush(nil)
            naechsteFolge()
        }
        angebotNachfuehren()
        // Am Ende von selbst weiter — nur mit Karte (Abspann-Abschnitt vom
        // Server), nicht, wenn sie abgesagt wurde (17.09.2026).
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
        traktStart(client, titel: titel, ticks: ticks)
    }

    func meldeFortschritt(_ client: JellyfinClient, titel: Item, plan: PlaybackPlan,
                          ticks: Int64, pausiert: Bool) {
        guard meldungen.melden(meldung(.fortschritt(pausiert: pausiert), client,
                                       titel: titel, plan: plan, ticks: ticks)) else {
            Protokoll.schreib("[Melden] Fortschritt nach Stopp verworfen \(titel.id)")
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
        Protokoll.schreib("[Melden] sofort: \(laeuft ? "weiter" : "Pause") bei \(Int(stelle)) s")
        fflush(nil)
        traktLaufzustand(laeuft: laeuft, stelle: stelle)
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
        Protokoll.schreib("[Melden] sofort: Sprung auf \(Int(ziel)) s")
        fflush(nil)
        traktSprung(auf: ziel)
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
        // Trakt hat eine eigene Reihe und wartet nicht auf Jellyfin.
        traktStopp(titel: titel, ticks: ticks)
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
            Protokoll.schreib("[Melden] Stopped \(ticks / 10_000_000) s \(titel.id) session \(plan.playSessionID ?? "nil")")
        case .verworfen:
            Protokoll.schreib("[Melden] Stopped doppelt verworfen \(titel.id) session \(plan.playSessionID ?? "nil")")
        case .gescheitert, .zeitUeberschritten:
            // **H8, zweite Haelfte.** Die Stelle ist das, was ein Download
            // hinterlaesst und der Server nicht hat.
            Nachmeldezettel.aufnehmen(titel.id, ticks: ticks, konto: konto)
            Protokoll.schreib("[Melden] Stopped \(ergebnis) → Nachmeldung \(titel.id)")
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
        Protokoll.schreib("[Angebot] ausgeloest: \(jetzigesAngebot.beschriftung) bei \(Int(spielstand.position)) s")
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

    /// Der Knopf „Nächste Folge" — dieselbe vorgeholte Folge, die auch das
    /// selbsttätige Weiterschalten nimmt.
    func naechsteFolge() {
        guard let folge = vorgeholteFolge else { return }
        wechsleZu(folge)
    }

    /// **Qualität geändert im Player** — derselbe Titel, neu geplant, an
    /// derselben Stelle. Vorlage: die Qualitätswahl im Player auf
    /// macOS/tvOS/iOS (`PlayerScreen.qualitaetswahl`).
    func qualitaetGeaendert() {
        guard let titel = laufenderTitel else { return }
        Protokoll.schreib("[Qualität] \(wahlen.immerDirectPlay ? "Direct Play" : "\(wahlen.bitratenGrenze) Mbit/s") — neu laden bei \(Int(spielstand.position)) s")
        fflush(nil)
        qualitaetGewechselt = true
        wechsleZu(titel, ab: spielstand.position)
    }

    /// **Zu einer beliebigen Folge wechseln — der Ablauf aus dem Paket.**
    ///
    /// `Folgenwechsel` haelt den Riegel (ein Wechsel zur Zeit), stoppt die
    /// alte Sitzung und holt den Plan nebeneinander, startet erst danach und
    /// wendet nach dem Schliessen nichts mehr an. Hier bleibt nur, was Linux
    /// gehoert: welche Zustaende zur Folge zaehlen (``folgeAnwenden``).
    ///
    /// **Nicht nur die vorgeholte naechste Folge** — wörtlich `zurNaechstenFolge`
    /// vom Mac (`PlayerScreen.swift:899`): auch ein Klick in der Folgenebene
    /// auf eine beliebige andere Folge der Staffel geht hier durch.
    /// - Parameter ab: Startstelle — leer beim Folgenwechsel (Anfang), gesetzt
    ///   bei einer Qualitätswahl (Fortsetzstelle), wie `zurNaechstenFolge` auf
    ///   macOS/tvOS.
    func wechsleZu(_ folge: Item, ab: Double = 0) {
        guard let client, let titel = laufenderTitel, let plan = laufenderPlan else { return }
        let wechsel = folgenwechsel
        guard !wechsel.laeuft else {
            Protokoll.schreib("[Wechsel] gesperrt → \(folge.id)")
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
                        self.folgeAnwenden(folge, neu, ab: ab)
                        angewandt.wert = true
                    }
                },
                starten: { neu in
                    guard angewandt.wert else { return }
                    // Auf GTKs Faden: `meldetitel` gehoert ihm.
                    aufHauptfadenWarten { self.meldeStart(client, titel: folge, plan: neu, ticks: Int64(ab * 10_000_000)) }
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
            Protokoll.schreib("[Wechsel] \(ergebnis) → \(folge.id)")
            fflush(nil)
            guard ergebnis == .gewechselt else { return }
            self.nachschlagen(fuer: folge, wechsel: wechsel, client: client)
        }
    }

    /// Die neue Folge uebernehmen — **vor** dem Start.
    private func folgeAnwenden(_ folge: Item, _ plan: PlaybackPlan, ab: Double = 0) {
        laufenderTitel = folge
        laufenderPlan = plan
        // Grenze gewählt, aber es läuft das Original: entweder reicht die
        // Datei schon, oder der Server wandelt nicht um. Sagen statt schweigen.
        if qualitaetGewechselt {
            qualitaetGewechselt = false
            if !wahlen.immerDirectPlay, plan.method == .directPlay {
                melden(uebersetzt("Läuft in Originalqualität. Der Server wandelt nichts um."))
            }
        }
        spurlageNeu(folge, plan: plan)
        // Stelle, Spuren, Startmeldung und erstes Bild zurueck; `true`, weil
        // der Wechsel den Start meldet (C1: sonst erst nach dem Puffern).
        // `neuerTitel` setzt auch `seitStart` (B7) und `erstesBildDa`.
        MainActor.assumeIsolated {
            Wiedergabetakt.neuerTitel(&self.spielstand, startGemeldet: true)
            // **Mitten in der Folge anfangen ist ein Sprung** — wie auf
            // macOS/tvOS: die Anzeige steht gleich auf der Startstelle.
            if ab > 0 { Wiedergabetakt.gesprungen(&self.spielstand, ziel: ab) }
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
        abspieler.oeffnen(plan.url, ab: ab, puffer: wahlen.puffer)
        // Was einmal gewaehlt wurde, gilt auch fuer die naechste Folge.
        abspieler.bildfuellend(wahlen.bildfuellend)
        technikschildSetzen(wahlen.technikschild)
        abspieler.tempo = tempo
        medienstandMelden()
        // Neue Folge, neues Blatt — ``Trickplaybilder`` erkennt das an der
        // geänderten `titel`-Kennung und holt es sich neu.
        if let client { spielerTrickplay?.laden(client: client, item: folge, plan: plan) }
        // **Titel und Metazeile nachziehen** — dieselbe Folge, dieselbe
        // Serie, aber „Staffel 1 · Folge 3" wird zu „Staffel 1 · Folge 4".
        titelstandAuffrischen(folge)
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
                    Protokoll.schreib("[Wechsel] naechste Folge \(folge?.id ?? "keine") nach \(item.id)")
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
        // Die Vorschau folgt dem Griff, solange gezogen wird.
        if amRegler { vorschauZeigen(anteil: anteil) }
    }

    /// Die Sprungmarke links oder rechts: blendet in 0,15 s ein, das Zeichen
    /// hüpft, nach 0,7 s blendet sie wieder aus (Mac: `Sprungmarke`).
    func sprungZeigen(_ zurueck: Bool) {
        guard let marke = zurueck ? spielerSprungLinks : spielerSprungRechts else { return }
        if let andere = zurueck ? spielerSprungRechts : spielerSprungLinks {
            blenden(andere.anzeige, auf: 0, dauer: 0.15, kennlinie: .easeInOut)
        }
        let sekunden = zurueck ? wahlen.zurueckSekunden : wahlen.vorSekunden
        gtk_label_set_text(OpaquePointer(marke.text), "\(sekunden) s")
        marke.zeichen.stupsen()
        blenden(marke.anzeige, auf: 1, dauer: 0.15, kennlinie: .easeInOut)
        sprungtakt += 1
        let meins = sprungtakt
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            aufHauptfaden {
                guard self.sprungtakt == meins,
                      let marke = zurueck ? self.spielerSprungLinks : self.spielerSprungRechts else { return }
                blenden(marke.anzeige, auf: 0, dauer: 0.15, kennlinie: .easeInOut)
            }
        }
    }

    /// **Deckkraft und Klickbarkeit der Steuerung — an einer Stelle.**
    ///
    /// Sichtbar ist sie, wenn sie offen sein soll und keine Ebene darüber
    /// liegt. Einblenden 0,18 s easeOut, ausblenden 0,34 s easeInOut, nur
    /// Deckkraft (Mac: `.animation(steuerungDa ? .easeOut(duration: 0.18) :
    /// .easeInOut(duration: 0.34))`); beim Öffnen und Schliessen einer Ebene
    /// deren Takt, 0,2 s. **Die Klickbarkeit folgt immer mit** — dass sie
    /// einmal weggenommen und nie zurückgegeben wurde, war das „nach dem
    /// Schliessen geht gar nichts mehr".
    func steuerungSichtbarkeit(dauer: Double? = nil) {
        guard let steuerung = spielerSteuerung else { return }
        let sichtbar = steuerungOffen && offeneEbeneArt == nil
        gtk_widget_set_can_target(steuerung, sichtbar ? 1 : 0)
        blenden(steuerung, auf: sichtbar ? 1 : 0, dauer: dauer ?? (sichtbar ? 0.18 : 0.34),
                kennlinie: dauer != nil || sichtbar ? .easeOut : .easeInOut)
        titelstandNachfuehren(dauer: dauer)
        technikschildLage(dauer: dauer)
    }

    func steuerungVerbergen() {
        guard laufenderTitel != nil, spielerSteuerung != nil,
              offeneEbene == nil, spielstand.laeuft, !amRegler else { return }
        steuerungstakt += 1
        steuerungOffen = false
        steuerungSichtbarkeit()
        zeigerZeigen(false)
        angebotNachfuehren()
    }

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

    /// Holt die Steuerung (B1) und stellt die Uhr, nach der sie wieder geht.
    /// **Bei offener Ebene bleibt sie verborgen** — vorher holte jede
    /// Mausbewegung sie unter der Ebene wieder hervor.
    func steuerungZeigen(durch art: Angebotsebene.Oeffnung = .bewusst) {
        guard spielerSteuerung != nil else { return }
        zeigerZeigen(true)
        guard offeneEbeneArt == nil else { return }
        if !steuerungOffen {
            steuerungOffen = true
            steuerungSichtbarkeit()
        }
        if laufenderTitel != nil { angebotsebene.steuerung(offen: true, durch: art) }
        angebotNachfuehren()
        steuerungstakt += 1
        let meins = steuerungstakt
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            aufHauptfaden {
                guard self.laufenderTitel != nil, self.spielerSteuerung != nil,
                      self.offeneEbeneArt == nil, !self.amRegler,
                      self.steuerungstakt == meins, self.spielstand.laeuft else { return }
                self.steuerungOffen = false
                self.steuerungSichtbarkeit()
                self.zeigerZeigen(false)
                self.angebotNachfuehren()
            }
        }
    }

    /// Der Schlafzeitgeber. Die Stufen stehen im Paket (B10). Internal: die
    /// Einstellungenebene (`PlayerEbenen.swift`) ruft ihn direkt.
    func schlafzeitSetzen(_ minuten: Int) {
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
