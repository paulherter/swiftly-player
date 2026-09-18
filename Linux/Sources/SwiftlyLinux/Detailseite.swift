import CGtk
import Foundation
import JellyfinKit

/// **Die Detailseite.** Film und Serie tragen denselben Kopf — so ist es auf
/// dem iPhone entschieden und gilt hier unverändert. Verschieden ist nur, was
/// darunter steht (A9 im Register).
///
/// Jede Zahl unten stammt aus `Sources/macOS/DetailView.swift`, `Kulisse.swift`
/// und `Macbausteine.swift`. Wo etwas abweicht, steht der Grund daneben.
extension App {

    // MARK: - Hinein und heraus

    /// Öffnet einen Titel auf dem Stapel des sichtbaren Bereichs.
    ///
    /// **Eine Folge bekommt keine eigene Seite** (A8): jeder Weg zu einer
    /// Folge führt auf die Serienseite, mit der Staffel der Folge gewählt.
    /// Das entscheidet ``detailZeigen(_:)`` beim Aufbauen.
    func oeffne(_ item: Item) {
        // **Eine Folge bekommt keine eigene Seite** (A8). Jeder Weg zu einer
        // Folge — aus „Zuletzt hinzugefügt", aus „Nächste Folge" — führt auf
        // die **Serienseite**, mit der Staffel der Folge schon gewählt. Eine
        // Seite nur für eine Folge trüge nichts, was nicht in der Folgenliste
        // schon steht.
        guard item.type == "Episode", let serieID = item.seriesId, let client else {
            startStaffel = nil
            seitenstapel[bereich, default: []].append(item)
            detailZeigen(item)
            return
        }
        // **Die Staffel frisch holen, nicht die der Kachel glauben.** Der
        // Listeneintrag trägt die Staffel, die er beim Laden hatte; wer eine
        // Staffel zu Ende sieht und die nächste dazulegt, hat dort weiter die
        // alte stehen. Dieselbe Abhilfe wie auf dem Mac (`StaffelZiel`).
        Task.detached { [self] in
            async let frisch = try? await client.item(id: item.id)
            async let serie = try? await client.item(id: serieID)
            let (f, s) = await (frisch, serie)
            aufHauptfaden {
                guard let s else { return }
                self.startStaffel = f?.seasonId ?? item.seasonId
                self.seitenstapel[self.bereich, default: []].append(s)
                self.detailZeigen(s)
            }
        }
    }

    func zurueck() {
        guard var meiner = seitenstapel[bereich], !meiner.isEmpty else { return }
        meiner.removeLast()
        seitenstapel[bereich] = meiner
        if let oben = meiner.last {
            detailZeigen(oben, schub: .zurueck)
        } else {
            bereichZeigen(bereich.kennung, schub: .zurueck)
        }
    }

    /// Startet einen Titel. **Nur „Weiterschauen" nimmt diesen Weg** (A1);
    /// alles andere öffnet erst die Übersicht (A2, A3, A7b).
    func starte(_ item: Item, ab: Double? = nil) {
        spielerOeffnen(item, ab: ab ?? item.fortsetzenAb ?? 0)
    }

    // MARK: - Aufbau

    func detailZeigen(_ item: Item, schub: Schub = .tiefer) {
        detailBeruehrt = false
        abschnitte = []
        let scheibe = naechsteScheibe()

        let seite = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        // **Ein Kasten malt den Ton, nicht zwei.**
        //
        // Vorher trugen Kopfzone und Unterbau ihn je selbst — zwei
        // gleichfarbige Flächen, die aneinanderstossen. Genau an ihrer Kante
        // stand der Strich, und zwar hartnäckig: beim Öffnen, beim Scrollen,
        // und nach einem Scrollen hin und zurück war er weg. Das ist kein
        // Farbfehler, das ist die Kante selbst — GTK zeichnet die Ränder
        // zweier Kästen einzeln, und wo sie sich treffen, scheint auf einem
        // halben Bildpunkt der Grund durch.
        //
        // Gibt es die Kante nicht, kann dort auch nichts durchscheinen. Der
        // Verlauf liegt jetzt als **ein** Anstrich auf der ganzen Seite: Ton
        // über die Höhe der Kopfzone, dann 260 Punkte nach `grund` — dieselbe
        // Länge wie auf dem Mac.
        gtk_widget_add_css_class(seite, "swiftly-seitenton")

        // **Der Ton gehört zum Kopf, nicht zur Seite.**
        //
        // Auf dem Mac steht er als `.background` an der `ScrollView` und
        // bleibt stehen, während der Inhalt darüber wegläuft. Dort geht das,
        // weil die Blenden das Bild **maskieren**: es wird durchsichtig, und
        // was darunter liegt, ist gleichgültig.
        //
        // Hier wird übermalt. Damit muss die Farbe an jeder Stelle die des
        // Untergrunds sein — und ein stehender Untergrund unter einem
        // laufenden Bild kann das nicht leisten. Genau daher der Strich an
        // der Unterkante, den Paul quer über die rechte Hälfte gesehen hat:
        // er wanderte mit dem Scrollstand.
        //
        // Also trägt die Kopfzone ihren Ton selbst, gleichmäßig, und darunter
        // steht ein eigener Auslauf von 260 Punkten nach `grund` — dieselbe
        // Länge wie auf dem Mac. Beide laufen mit dem Inhalt, also liegt
        // nichts je daneben. Der Unterschied zum Mac: dort bleibt der Ton
        // beim weiten Scrollen oben am Fensterrand stehen, hier verschwindet
        // er mit der Kopfzone.

        let scroller = seitenscroller()
        gtk_scrolled_window_set_child(OpaquePointer(scroller), seite)

        // **Der Zurückweg gehört in den Inhalt, nicht in die Systemleiste**
        // (E9). Er schwebt über der Seite, damit er beim Blättern stehen
        // bleibt; der Titel daneben blendet ein, sobald der grosse Titel
        // darunter verschwindet.
        let ueber: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(ueber), scroller)
        gtk_overlay_add_overlay(OpaquePointer(ueber), detailkopfBauen(item))

        hinweisfeld = beschriftung("", stil: "swiftly-hinweis")
        gtk_widget_set_visible(hinweisfeld, 0)
        gtk_widget_set_halign(hinweisfeld, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(hinweisfeld, GTK_ALIGN_END)
        gtk_widget_set_margin_bottom(hinweisfeld, 32)
        gtk_overlay_add_overlay(OpaquePointer(ueber), hinweisfeld)
        anhaengen(detailhuelle, ueber)

        // Der magere Listeneintrag steht sofort, der volle Satz kommt nach.
        // **Der Kopf hat feste Plätze** — es wandert nichts, wenn ein Text
        // nachkommt, also darf er kommen, wann er kommt.
        aufbauenMit(item, in: seite)
        titelNachladen(item, in: seite)
        // Den Titel oben einblenden, sobald der grosse unter der Leiste
        // verschwindet: ab 98 − 24 = 74, über die 42 Punkt seiner Höhe.
        let senkrecht = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))!
        beiSignalRoh(UnsafeMutableRawPointer(senkrecht), "value-changed") { [weak self] in
            guard let self, let kopf = self.detailkopfTitel else { return }
            let v = gtk_adjustment_get_value(senkrecht)
            // **Ab wo die Leiste kommt — hergeleitet, nicht geschätzt.** Der
            // große Titel beginnt 98 unter der Oberkante des Heldenbildes und
            // ist 42 hoch; die Leiste ist 24 hoch. Seine Oberkante erreicht
            // ihre Unterkante also bei 98 − 24 = 74, und 42 später ist er ganz
            // darunter. Genau über diese Strecke blendet sie ein.
            let staerke = min(max((v - 74) / 42, 0), 1)
            gtk_widget_set_opacity(kopf, staerke)
            if let leiste = self.detailkopfLeiste { gtk_widget_set_opacity(leiste, staerke) }
            if let verlauf = self.detailkopfVerlauf {
                gtk_widget_set_opacity(verlauf, 1 - staerke)
            }
        }

        // **Erst auslegen, dann schieben.** Eine Seite, die während der Fahrt
        // noch umbricht, ruckelt — dasselbe, was auf dem Mac hinter
        // „losfahren, sobald die Seite wirklich steht" steht.
        schieben(zu: scheibe, richtung: schub)
    }

    /// **Ein kurzer Satz, der von selbst wieder geht.**
    ///
    /// Der Mac hat dafür den `Hinweisstreifen` — drei Sekunden, dann weg. Auf
    /// Linux gab es gar nichts: „Fortschritt zurückgesetzt", „kein Trailer",
    /// „danach kommt nichts mehr" fielen einfach unter den Tisch, und der
    /// Nutzer sah einen Knopf, der scheinbar nichts tat.
    func melden(_ text: String) {
        guard let feld = hinweisfeld else { return }
        gtk_label_set_text(OpaquePointer(feld), text)
        gtk_widget_set_visible(feld, 1)
        gtk_widget_set_opacity(feld, 1)
        hinweistakt += 1
        let meins = hinweistakt
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            aufHauptfaden {
                guard self.hinweistakt == meins, self.hinweisfeld != nil else { return }
                sanft(auf: self.hinweisfeld, von: 1, nach: 0) {
                    gtk_widget_set_opacity(self.hinweisfeld, $0)
                }
            }
        }
    }

    /// **Extras** — Featurettes, entfallene Szenen, Making-of.
    ///
    /// Der Mac hat die Reihe (`DetailView.swift:133`), Linux nicht. Sie ist
    /// leer bei den meisten Titeln und genau deshalb leicht zu übersehen: wo
    /// nichts ist, fällt nichts auf.
    private func extrasNachladen(_ titel: Item, in raum: Widget!) {
        guard let client else { return }
        let kiste = gehalten(raum)
        Task.detached { [self] in
            let extras = (try? await client.extras(itemID: titel.id)) ?? []
            nachDemSchub {
                defer { losgelassen(kiste) }
                guard !extras.isEmpty else { return }
                anhaengen(kiste.widget, self.reiheBauen(titel: uebersetzt("Extras"), art: .neu,
                                                        items: extras))
            }
        }
    }

    /// **Der Dateiauszug — der Beleg für das Versprechen dieser App.**
    ///
    /// Container, Auflösung, Codec, Grösse, Untertitelsprachen: daran liest
    /// man ab, **warum** Direct Play geht. Er fehlte auf Linux ganz, weil
    /// `Dateiangaben` in `Sources/Shared` lag und von hier nicht erreichbar
    /// war; jetzt liegt es im Paket.
    ///
    /// Die Werte kommen aus derselben Quelle, die auch den Plan trägt — es
    /// wird nichts zusätzlich geholt.
    func dateizeile(_ quelle: MediaSource) -> Widget! {
        var teile: [String] = []
        if let behaelter = Dateiangaben.container(quelle) { teile.append(behaelter) }
        if let spur = Dateiangaben.videospur(quelle) {
            teile.append(Dateiangaben.video(spur, quelle))
        }
        teile.append(Dateiangaben.groesse(quelle))
        let ut = Dateiangaben.untertitel(Dateiangaben.untertitelspuren(quelle))
        if !ut.isEmpty { teile.append(ut) }

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 22)
        gtk_widget_add_css_class(reihe, "swiftly-dateizeile")
        for text in teile where !text.isEmpty {
            let l = beschriftung(text, stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(l, "swiftly-leise")
            anhaengen(reihe, l)
        }
        return reihe
    }

    private func titelNachladen(_ item: Item, in seite: Widget!) {
        guard let client else { return }
        // **Der Zeiger geht über eine Fadengrenze**, und Swift 6 besteht auf
        // der Kiste. Ausgepackt wird er nur in `aufHauptfaden`, also wieder
        // auf dem Faden, dem GTK gehört — genau die Zusicherung, die
        // ``Zeigerkiste`` gibt.
        let kiste = gehalten(seite)
        Task.detached { [self] in
            let voll = try? await client.item(id: item.id)
            aufHauptfaden {
                defer { losgelassen(kiste) }
                // Nur nachtragen, wenn diese Seite noch die oberste ist.
                // **Was der Nutzer schon gewählt hat, wird nicht
                // weggeworfen.** Der volle Satz kommt nach und ersetzte die
                // ganze Seite — wer in der Zwischenzeit eine Staffel oder
                // einen Reiter gewählt hatte, sah sie zurückspringen. Der
                // Mac tauscht nur den Titel und behält den Zustand; hier
                // wird stattdessen nicht mehr neu gebaut, sobald jemand
                // etwas angefasst hat.
                guard let voll, !self.detailBeruehrt,
                      self.seitenstapel[self.bereich]?.last?.id == item.id else { return }
                leeren(kiste.widget)
                self.aufbauenMit(voll, in: kiste.widget)
            }
        }
    }

    /// **Nach `item.type` verzweigen**, nicht nach dem nachgeladenen Satz:
    /// die Art steht schon in der Liste, und den Zweig unterwegs zu wechseln
    /// hiesse, die halbe Seite wegzuwerfen und neu zu bauen.
    private func aufbauenMit(_ titel: Item, in seite: Widget!) {
        anhaengen(seite, heldenkopf(titel))


        // **Der Auslauf ist ein Anstrich, kein Widget.**
        //
        // Erst stand er als eigene Box in einem Überzug hinter dem Unterbau —
        // und ein `GtkOverlay` nimmt die Höhe seines **Hauptkinds**. Damit war
        // die ganze Seite auf 260 Punkte gedeckelt, und Scrollen ging gar
        // nicht mehr. Ein Hintergrundverlauf am Unterbau selbst tut dasselbe,
        // liegt von sich aus hinter dem Inhalt und misst nichts.
        let unten = stapel(GTK_ORIENTATION_VERTICAL, abstand: 26)
        // Die Luft nach der Kopfzone. Sie darf jetzt wieder ein Rand sein —
        // der Ton liegt auf der Seite, nicht auf diesem Kasten.
        gtk_widget_set_margin_top(unten, 26)
        gtk_widget_set_margin_bottom(unten, Int32(Stil.randAbstand))
        anhaengen(seite, unten)

        if titel.type == "Series" {
            serienunterbau(titel, in: unten)
        } else {
            if !titel.darsteller.isEmpty {
                anhaengen(unten, besetzungsreihe(titel.darsteller))
            }
            extrasNachladen(titel, in: unten)
            aehnlicheNachladen(titel, in: unten)
            // **Der Dateiauszug steht ganz unten, und nur beim Film** — bei
            // einer Serie gibt es keine Datei, nur die ihrer Folgen. Der
            // Raum steht schon, gefüllt wird er, wenn der Plan kommt.
            let raum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
            gtk_widget_set_margin_start(raum, Int32(Stil.randAbstand))
            gtk_widget_set_margin_end(raum, Int32(Stil.randAbstand))
            dateiraum = raum
            anhaengen(unten, raum)
        }
    }

    // MARK: - Kopfleiste mit Pfeil

    private func detailkopfBauen(_ item: Item) -> Widget! {
        // Höhe wie auf dem Mac: 24 Luft, 40 Knopf, 10 unter dem Text.
        let kopf: Widget! = gtk_overlay_new()
        gtk_widget_set_valign(kopf, GTK_ALIGN_START)
        gtk_widget_set_halign(kopf, GTK_ALIGN_FILL)

        // Solange oben steht: ein weicher Verlauf, damit der Pfeil auf hellem
        // Bild lesbar bleibt. Er ist das Hauptkind und gibt die Höhe vor.
        let verlauf: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_add_css_class(verlauf, "swiftly-kopfverlauf")
        gtk_widget_set_size_request(verlauf, -1, 74)
        gtk_overlay_set_child(OpaquePointer(kopf), verlauf)

        // Und beim Scrollen die Leiste darüber.
        detailkopfLeiste = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_add_css_class(detailkopfLeiste, "swiftly-kopfleiste")
        gtk_widget_set_opacity(detailkopfLeiste, 0)
        gtk_overlay_add_overlay(OpaquePointer(kopf), detailkopfLeiste)
        detailkopfVerlauf = verlauf

        let leiste = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 4)
        gtk_widget_set_valign(leiste, GTK_ALIGN_START)
        // Bündig mit dem Inhalt: 24 minus die 8 Innenabstand des Knopfes.
        gtk_widget_set_margin_start(leiste, Int32(Stil.randAbstand - 8))
        gtk_widget_set_margin_end(leiste, Int32(Stil.randAbstand))
        // 24 setzt den Pfeil auf dieselbe Höhe, auf der die Seitenleiste ihre
        // Wortmarke trägt.
        gtk_widget_set_margin_top(leiste, 24)

        let pfeil: Widget! = gtk_button_new()
        gtk_widget_add_css_class(pfeil, "swiftly-zurueck")
        gtk_button_set_child(alsKnopf(pfeil), gtk_image_new_from_icon_name("go-previous-symbolic"))
        beiSignal(pfeil, "clicked") { [weak self] in self?.zurueck() }
        anhaengen(leiste, pfeil)

        detailkopfTitel = beschriftung(item.seriesName ?? item.name, stil: "swiftly-leistentitel")
        gtk_label_set_ellipsize(OpaquePointer(detailkopfTitel), PANGO_ELLIPSIZE_END)
        gtk_widget_set_valign(detailkopfTitel, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(detailkopfTitel, 8)
        gtk_widget_set_opacity(detailkopfTitel, 0)
        anhaengen(leiste, detailkopfTitel)

        gtk_overlay_add_overlay(OpaquePointer(kopf), leiste)
        return kopf
    }

    // MARK: - Heldenkopf

    /// Kulisse rechts, Block links. Höhe 380 (`Stil.heldHoehe`).
    private func heldenkopf(_ titel: Item) -> Widget! {
        let kopf: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(kopf, 1)

        // **Die Kulisse ist das Hauptkind** — sie gibt das Mass (380 hoch)
        // und malt sich selbst, maskiert statt übermalt. Warum das den
        // Unterschied macht, steht in ``Kulisse``.
        let bild = Kulisse()
        gtk_overlay_set_child(OpaquePointer(kopf), bild.anzeige)
        gtk_overlay_add_overlay(OpaquePointer(kopf), heldenblock(titel))

        tonUndBildNachladen(titel, in: bild)
        return kopf
    }

    /// Holt das Kopfbild und, aus einem winzigen Abbild, seinen Ton.
    private func tonUndBildNachladen(_ titel: Item, in kulisse: Kulisse) {
        guard let adressen,
              let gross = Bildwahl.quer(titel, adressen: adressen, breite: 1600)?.url
        else { return }
        let klein = Bildwahl.quer(titel, adressen: adressen, breite: 16)?.url

        Task.detached { [self] in
            if let klein,
               let daten = await Bildlager.shared.laden(klein, schluessel: klein.absoluteString),
               let ton = Bildfarbe.ton(aus: daten) {
                aufHauptfaden { Tonblatt.setzen(ton) }
            }
            guard let daten = await Bildlager.shared.laden(gross,
                                                           schluessel: gross.absoluteString)
            else { return }
            aufHauptfaden { kulisse.setzen(daten) }
        }
    }

    /// **Feste Stellen statt fester Höhen.**
    ///
    /// Ein Stapel mit festen Höhen je Zeile sollte reichen — auf dem Mac tat
    /// er es nicht, die Knöpfe wanderten je nach Serverantwort. Jede Zeile
    /// steht deshalb an einer ausgerechneten Stelle; was zu gross wird, wird
    /// abgeschnitten und verschiebt nichts.
    ///
    ///     0    Titel        42
    ///     54   Angaben      20
    ///     92   Beschreibung 66   (drei Zeilen)
    ///     182  Knopfreihe   48
    ///     230  Ende
    private func heldenblock(_ titel: Item) -> Widget! {
        let feld: Widget! = gtk_fixed_new()
        gtk_widget_set_halign(feld, GTK_ALIGN_START)
        gtk_widget_set_valign(feld, GTK_ALIGN_START)
        gtk_widget_set_size_request(feld, 640, 230)
        gtk_widget_set_margin_start(feld, Int32(Stil.randAbstand))
        // titelHoehe (52) + 98, minus die Kopfleiste. Auf dem Mac ist die
        // Strecke ab Fensteroberkante gemessen — dort gibt es keine
        // Titelzeile, hier schon, und ihre Höhe kommt oben drauf.
        gtk_widget_set_margin_top(feld, Int32(Stil.titelHoehe + 98 - Stil.kopfzeileHoehe))

        // **Jede Zeile in ihrem Fach.** Die vier Stellen und Höhen stehen so
        // auf dem Mac; ohne festes Fach wüchse jede Beschriftung über ihre
        // Höhe hinaus, weil Inter höher baut als SF Pro — und die Abstände
        // dazwischen wüchsen mit. Was zu gross wird, wird abgeschnitten und
        // verschiebt nichts.
        let name = beschriftung(titel.name, stil: "swiftly-heldtitel")
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_fixed_put(alsFeld2(feld), fach(name, breite: 640, hoehe: 42), 0, 0)

        gtk_fixed_put(alsFeld2(feld), fach(angabenreihe(titel), breite: 640, hoehe: 20),
                      0, 54)

        let text = beschriftung(titel.overview ?? "", stil: "swiftly-koerper", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(text), 0)
        gtk_label_set_yalign(OpaquePointer(text), 0)
        gtk_label_set_lines(OpaquePointer(text), 3)
        gtk_label_set_ellipsize(OpaquePointer(text), PANGO_ELLIPSIZE_END)
        gtk_label_set_justify(OpaquePointer(text), GTK_JUSTIFY_LEFT)
        gtk_widget_add_css_class(text, "swiftly-beschreibung")
        gtk_fixed_put(alsFeld2(feld), fach(text, breite: 640, hoehe: 66,
                                           senkrecht: GTK_ALIGN_START), 0, 92)

        gtk_fixed_put(alsFeld2(feld), fach(knopfreihe(titel), breite: 640,
                                           hoehe: Stil.hauptknopfHoehe), 0, 182)
        return feld
    }

    /// Jahr, Laufzeit, Genres, Bewertung, Freigabe und der Beleg — **eine
    /// Zeile**, nicht drei.
    private func angabenreihe(_ titel: Item) -> Widget! {
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
        gtk_widget_set_halign(reihe, GTK_ALIGN_START)

        let zeile = beschriftung(titel.nebenzeile, stil: "swiftly-angaben")
        gtk_widget_add_css_class(zeile, "dim-label")
        anhaengen(reihe, zeile)

        if let bewertung = titel.communityRating {
            let paar = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 5)
            let stern: Widget! = gtk_image_new_from_icon_name("starred-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(stern), 10)
            gtk_widget_add_css_class(stern, "dim-label")
            anhaengen(paar, stern)
            let wert = beschriftung(komma(bewertung), stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(wert, "dim-label")
            anhaengen(paar, wert)
            gtk_widget_set_valign(paar, GTK_ALIGN_CENTER)
            anhaengen(reihe, paar)
        }

        if let freigabe = titel.officialRating { anhaengen(reihe, plakette(freigabe)) }

        // **Der Beleg.** Läuft alles verlustfrei, steht „Direct Play" im
        // Akzent, ohne Erklärung (D1). Nur die Abweichung meldet sich lauter,
        // in Warnorange, mit Grund (D2).
        let beleg = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
        gtk_widget_set_visible(beleg, 0)
        gtk_widget_set_valign(beleg, GTK_ALIGN_CENTER)
        anhaengen(reihe, beleg)
        planNachladen(titel, in: beleg)
        return reihe
    }

    /// **Der Plan gehört zur Folge, nicht zur Serie.** Bei einer Serie nennt
    /// der Server keine MediaSource — der Aufruf käme leer zurück, und
    /// `PlaybackInfo` ist ein POST, bei dem der Server die Datei anfasst:
    /// der teuerste Abruf der App, hier umsonst.
    private func planNachladen(_ titel: Item, in beleg: Widget!) {
        guard let client else { return }
        let kiste = gehalten(beleg)
        // Die Grenze vor dem Faden ablesen — `wahlen` gehört dem Hauptfaden.
        let grenze = wahlen.profilBitrate
        Task.detached { [self] in
            let ziel: Item?
            if titel.type == "Series" {
                ziel = try? await client.naechsteFolgeDerSerie(seriesID: titel.id)
            } else {
                ziel = titel
            }
            let plan: PlaybackPlan? = await {
                guard let ziel else { return nil }
                return try? await client.playbackPlan(for: ziel.id,
                                                      profile: .vlc(maxBitrate: grenze))
            }()
            aufHauptfaden {
                defer { losgelassen(kiste) }
                guard let plan else { return }
                let ziel = kiste.widget
                let zeichen: Widget! = gtk_image_new_from_icon_name(
                    plan.isLossless ? "object-select-symbolic" : "dialog-warning-symbolic")
                gtk_image_set_pixel_size(OpaquePointer(zeichen), 11)
                anhaengen(ziel, zeichen)
                let text = beschriftung(plan.isLossless ? "Direct Play" : plan.method.rawValue,
                                        stil: "swiftly-zweitzeile")
                anhaengen(ziel, text)
                gtk_widget_add_css_class(ziel, plan.isLossless ? "swiftly-beleg" : "swiftly-warnung")
                gtk_widget_set_visible(ziel, 1)
                // Derselbe Plan trägt die Quelle — der Auszug kostet keinen
                // zweiten Abruf.
                if let quelle = plan.quelle, let raum = self.dateiraum {
                    leeren(raum)
                    anhaengen(raum, self.dateizeile(quelle))
                }
            }
        }
    }

    /// Vier Ziele wie auf dem Apple TV: Fortsetzen, Von vorn, Merkliste, Mehr.
    ///
    /// **Feste Breite für den Hauptknopf, aber kein Platzhalter.** Sonst
    /// wüchse er mit seiner Beschriftung — „Fortsetzen" ist länger als
    /// „Abspielen" — und schöbe alles dahinter. „Von vorn" gibt es dagegen nur
    /// bei angefangenen Titeln; eine leere Lücke wäre schlimmer als der
    /// kleine Versatz.
    private func knopfreihe(_ titel: Item) -> Widget! {
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)

        // **Der Hauptknopf startet dort, wo der Server sagt** (A4):
        // angefangene Folge an ihrer Stelle, sonst nächste ungesehene, sonst
        // Folge 1. Bei einer Serie steht das nicht im Eintrag — Jellyfin
        // beantwortet beides in einem Aufruf (`Shows/NextUp`).
        //
        // Hier stand vorher schlicht die Serie selbst, und die hat keine
        // MediaSource: der Server nannte keine Quelle, und der Knopf tat
        // nichts als eine Fehlermeldung. Bei einem Film ist der Titel selbst
        // schon das Ziel.
        let ziel = Spielziel()
        ziel.titel = titel.type == "Series" ? nil : titel
        offenesZiel = ziel

        let angefangen = titel.fortsetzenAb
        let haupt = hauptknopf(angefangen != nil ? uebersetzt("Fortsetzen") : uebersetzt("Abspielen"),
                               symbol: "media-playback-start-symbolic")
        gtk_widget_set_size_request(haupt, Int32(Stil.hauptknopfBreite),
                                    Int32(Stil.hauptknopfHoehe))
        beiSignal(haupt, "clicked") { [weak self] in
            guard let self, let was = ziel.titel else { return }
            self.starte(was, ab: was.fortsetzenAb ?? 0)
        }
        // Solange das Ziel nicht feststeht, ist nichts zu starten.
        gtk_widget_set_sensitive(haupt, ziel.titel == nil ? 0 : 1)
        anhaengen(reihe, haupt)

        // **„Von vorn" nur bei angefangenen Titeln.** Wo es das nicht gibt,
        // rückt der Rest auf; eine leere Lücke stehen zu lassen wäre
        // schlimmer als der kleine Versatz.
        let vorn = nebenknopf("view-refresh-symbolic")
        gtk_widget_set_visible(vorn, angefangen != nil ? 1 : 0)
        beiSignal(vorn, "clicked") { [weak self] in
            guard let self, let was = ziel.titel else { return }
            self.starte(was, ab: 0)
        }
        anhaengen(reihe, vorn)

        if titel.type == "Series", let client {
            let knopfKiste = gehalten(haupt)
            let vornKiste = gehalten(vorn)
            Task.detached {
                let folge = try? await client.naechsteFolgeDerSerie(seriesID: titel.id)
                aufHauptfaden {
                    defer { losgelassen(knopfKiste); losgelassen(vornKiste) }
                    guard let folge else { return }
                    ziel.titel = folge
                    gtk_widget_set_sensitive(knopfKiste.widget, 1)
                    let weiter = folge.fortsetzenAb != nil
                    hauptknopfBeschriften(knopfKiste.widget,
                                          weiter ? uebersetzt("Fortsetzen") : uebersetzt("Abspielen"))
                    gtk_widget_set_visible(vornKiste.widget, weiter ? 1 : 0)
                }
            }
        }

        // **Merkliste schaltet sofort um, ohne Rückfrage** (D6). Der Zustand
        // des Knopfes ist die Antwort. Das Zeichen ist ein Lesezeichen, kein
        // Stern — auf dem Mac steht dort `bookmark`.
        var gemerkt = titel.userData?.isFavorite ?? false
        let merk = nebenknopf("user-bookmarks-symbolic", aktiv: gemerkt)
        beiSignal(merk, "clicked") { [weak self] in
            guard let self, let client = self.client else { return }
            gemerkt.toggle()
            knopfzustand(merk, aktiv: gemerkt, symbol: "user-bookmarks-symbolic")
            let neu = gemerkt
            Task.detached { try? await client.setzeMerkliste(itemID: titel.id, an: neu) }
        }
        anhaengen(reihe, merk)

        // **Vier Ziele, nicht fünf.** „Gesehen" und „Trailer" sind in die
        // Mehr-Liste gewandert; fünf beschriftete Knöpfe waren zu viel für
        // eine Reihe. So steht es auf dem Apple TV und auf dem Mac.
        let mehr = nebenknopf("view-more-symbolic")
        beiSignal(mehr, "clicked") { [weak self] in self?.mehrZeigen(titel, an: mehr) }
        anhaengen(reihe, mehr)
        return reihe
    }

    // MARK: Mehr

    /// **Kleine Entscheidungen klappen dort auf, wo sie ausgelöst wurden**
    /// (E5). Ein `GtkPopover` ist dafür das Mittel von GTK — er trägt keine
    /// eigene Gestalt, die wir nicht überschreiben könnten, und schließt von
    /// selbst, wenn man daneben klickt.
    private func mehrZeigen(_ titel: Item, an knopf: Widget!) {
        let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(liste, 230, -1)

        var gesehen = titel.istGesehen
        let ersteZeile = gesehen ? uebersetzt("Als ungesehen markieren") : uebersetzt("Als gesehen markieren")

        // **Die vorige Tafel zuerst weg.** `mehrZeigen` läuft bei jedem Klick;
        // ohne das hinge nach dem dritten Klick die dritte Tafel am Knopf und
        // die beiden davor daneben.
        if let alt = offeneTafel { gtk_widget_unparent(alt); offeneTafel = nil }
        let tafel = tafelAn(knopf)
        gtk_popover_set_child(alsTafel(tafel), liste)
        offeneTafel = tafel

        anhaengen(liste, handlungszeile("object-select-symbolic", ersteZeile) {
            [weak self] in
            guard let self, let client = self.client else { return }
            gesehen.toggle()
            let neu = gesehen
            gtk_popover_popdown(alsTafel(tafel))
            // **Der Zustand des Knopfes ist die Antwort** (D6) — aber wenn
            // der Server ablehnt, ist die Antwort falsch. Dann nimmt sie
            // sich zurück und sagt warum; auf dem Mac genauso.
            // Hier gibt es nichts zurückzunehmen: die Liste wird bei jedem
            // Öffnen neu aus `titel.istGesehen` gebaut. Gesagt werden muss es
            // trotzdem — sonst sieht es aus, als hätte es geklappt.
            Task.detached { [self] in
                do { try await client.setzeGesehen(itemID: titel.id, an: neu) }
                catch { aufHauptfaden { self.melden(lesbarerFehler(error)) } }
            }
        })
        // **„Von vorn" nur, wenn es etwas zurueckzusetzen gibt** — bei einem
        // Film, der bei null steht, waere es eine Zeile ohne Wirkung. Wortlaut
        // und Bedingung aus `Titelhandlungen.fuerFilm`.
        if titel.type == "Series" {
            if let stand = offenesZiel?.titel {
                anhaengen(liste, handlungszeile("media-playback-start-symbolic",
                                                uebersetzt("Folge von vorn abspielen")) {
                    [weak self] in
                    gtk_popover_popdown(alsTafel(tafel))
                    self?.starte(stand, ab: 0)
                })
                anhaengen(liste, handlungszeile("media-skip-forward-symbolic",
                                                uebersetzt("Nächste Folge abspielen")) {
                    [weak self] in
                    gtk_popover_popdown(alsTafel(tafel))
                    guard let self, let client = self.client,
                          let serie = stand.seriesId else { return }
                    Task.detached { [self] in
                        guard let naechste = try? await client.folgeNach(itemID: stand.id,
                                                                        seriesID: serie) else {
                            aufHauptfaden { self.melden(uebersetzt("Danach kommt nichts mehr.")) }
                            return
                        }
                        aufHauptfaden { self.starte(naechste, ab: 0) }
                    }
                })
            }
            if let staffel = offeneStaffel {
                anhaengen(liste, handlungszeile("object-select-symbolic",
                                                String(format: uebersetzt("%@ als gesehen"), staffel.name)) {
                    [weak self] in
                    gtk_popover_popdown(alsTafel(tafel))
                    guard let self, let client = self.client else { return }
                    Task.detached { try? await client.setzeGesehen(itemID: staffel.id, an: true) }
                    self.melden(String(format: uebersetzt("%@ ist als gesehen vermerkt."), staffel.name))
                })
            }
        } else if titel.fortsetzenAb != nil {
            anhaengen(liste, handlungszeile("media-playback-start-symbolic",
                                            uebersetzt("Von vorn abspielen")) {
                [weak self] in
                gtk_popover_popdown(alsTafel(tafel))
                self?.starte(titel, ab: 0)
            })
            anhaengen(liste, handlungszeile("view-refresh-symbolic",
                                            uebersetzt("Fortschritt zurücksetzen")) {
                [weak self] in
                gtk_popover_popdown(alsTafel(tafel))
                guard let self, let client = self.client else { return }
                Task.detached { try? await client.setzeGesehen(itemID: titel.id, an: false) }
                self.melden(uebersetzt("Der Fortschritt ist zurückgesetzt."))
            })
        }
        anhaengen(liste, handlungszeile("video-x-generic-symbolic", uebersetzt("Trailer")) {
            [weak self] in
            gtk_popover_popdown(alsTafel(tafel))
            self?.trailerStarten(titel)
        })
        anhaengen(liste, handlungszeile("view-refresh-symbolic", uebersetzt("Metadaten auffrischen")) {
            [weak self] in
            guard let client = self?.client else { return }
            Task.detached { try? await client.metadatenAuffrischen(titel.id) }
            gtk_popover_popdown(alsTafel(tafel))
        })
        gtk_popover_popup(alsTafel(tafel))
    }

    func handlungszeile(_ symbol: String, _ text: String,
                                _ auswahl: @escaping () -> Void) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-handlung")
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        let bild: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(bild), 14)
        anhaengen(reihe, bild)
        let l = beschriftung(text, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        anhaengen(reihe, l)
        gtk_button_set_child(alsKnopf(knopf), reihe)
        beiSignal(knopf, "clicked", auswahl)
        return knopf
    }

    private func trailerStarten(_ titel: Item) {
        guard let client else { return }
        Task.detached { [self] in
            let filme = (try? await client.trailer(zu: titel.id)) ?? []
            aufHauptfaden {
                // **Schweigen ist keine Antwort.** Ohne diese Zeile passierte
                // beim Druck auf „Trailer" schlicht nichts, und man wusste
                // nicht, ob der Knopf kaputt ist oder der Server nichts hat.
                guard let film = filme.first else {
                    self.melden(uebersetzt("Für diesen Titel liegt kein Trailer vor."))
                    return
                }
                self.starte(film, ab: 0)
            }
        }
    }
}


/// Wohin der Hauptknopf zeigt. Eine Klasse, damit der Rückruf denselben Wert
/// sieht wie das Nachladen — bei einer Serie steht er erst fest, wenn der
/// Server geantwortet hat.
///
/// **`@unchecked Sendable` mit derselben Begründung wie ``Zeigerkiste``:**
/// gelesen und geschrieben wird ausschließlich auf GTKs Hauptfaden, das
/// Nachladen kommt über ``aufHauptfaden`` dorthin zurück. Swift kann das
/// nicht sehen, nur wir.
final class Spielziel: @unchecked Sendable {
    var titel: Item?
}
