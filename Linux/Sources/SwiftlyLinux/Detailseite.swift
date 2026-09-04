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
            detailZeigen(oben)
        } else {
            gtk_stack_set_visible_child_name(OpaquePointer(inhalt), bereich.kennung)
        }
    }

    /// Startet einen Titel. **Nur „Weiterschauen" nimmt diesen Weg** (A1);
    /// alles andere öffnet erst die Übersicht (A2, A3, A7b).
    func starte(_ item: Item, ab: Double? = nil) {
        spielerOeffnen(item, ab: ab ?? item.fortsetzenAb ?? 0)
    }

    // MARK: - Aufbau

    func detailZeigen(_ item: Item) {
        leeren(detailhuelle)
        gtk_stack_set_visible_child_name(OpaquePointer(inhalt), "detail")

        let seite = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)

        let scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_scrolled_window_set_child(OpaquePointer(scroller), seite)

        // **Der Zurückweg gehört in den Inhalt, nicht in die Systemleiste**
        // (E9). Er schwebt über der Seite, damit er beim Blättern stehen
        // bleibt; der Titel daneben blendet ein, sobald der grosse Titel
        // darunter verschwindet.
        let ueber: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(ueber), scroller)
        gtk_overlay_add_overlay(OpaquePointer(ueber), detailkopfBauen(item))
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
            gtk_widget_set_opacity(kopf, min(max((v - 74) / 42, 0), 1))
        }
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
                guard let voll,
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

        let unten = stapel(GTK_ORIENTATION_VERTICAL, abstand: 26)
        gtk_widget_set_margin_top(unten, 26)
        gtk_widget_set_margin_bottom(unten, Int32(Stil.randAbstand))
        anhaengen(seite, unten)

        if titel.type == "Series" {
            serienunterbau(titel, in: unten)
        } else {
            if !titel.darsteller.isEmpty {
                anhaengen(unten, besetzungsreihe(titel.darsteller))
            }
            aehnlicheNachladen(titel, in: unten)
        }
    }

    // MARK: - Kopfleiste mit Pfeil

    private func detailkopfBauen(_ item: Item) -> Widget! {
        let leiste = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 4)
        gtk_widget_add_css_class(leiste, "swiftly-detailkopf")
        gtk_widget_set_valign(leiste, GTK_ALIGN_START)
        gtk_widget_set_halign(leiste, GTK_ALIGN_FILL)
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
        gtk_widget_set_opacity(detailkopfTitel, 0)
        anhaengen(leiste, detailkopfTitel)
        return leiste
    }

    // MARK: - Heldenkopf

    /// Kulisse rechts, Block links. Höhe 380 (`Stil.heldHoehe`).
    private func heldenkopf(_ titel: Item) -> Widget! {
        let kopf: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(kopf, 1)

        // **Das Hauptkind gibt das Maß, sonst nichts.** Ein `GtkOverlay`
        // legt seinem Hauptkind die volle Fläche zu und übergeht dessen
        // Ausrichtung — die Kulisse stand deshalb über die ganze Breite und
        // über 570 statt 380 Punkt Höhe. Damit fiel auch der Verlauf über
        // eine viel größere Strecke, und das Bild endete unten mit einer
        // sichtbaren Kante. Überzüge dagegen achten auf Ausrichtung und
        // Wunschgröße; also ist das Hauptkind eine leere Box mit dem Maß,
        // und Kulisse wie Block liegen darüber.
        let mass: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_set_size_request(mass, -1, Int32(Stil.heldHoehe))
        gtk_overlay_set_child(OpaquePointer(kopf), mass)

        gtk_overlay_add_overlay(OpaquePointer(kopf), kulisse(titel))
        gtk_overlay_add_overlay(OpaquePointer(kopf), heldenblock(titel))
        return kopf
    }

    /// **Rechts, nicht über die volle Breite** — wie auf dem Apple TV und dem
    /// Mac. Dort blendet eine *Maske* das Bild aus, weil der Grund sich
    /// einfärben kann (`Bildfarbe`) und ein Anstrich dann als Fleck darin
    /// stünde. Hier gibt es diese Einfärbung nicht, der Grund ist immer
    /// `grund` — deshalb zwei Verläufe darüber statt einer Maske, die GTK
    /// ohnehin nicht kennt. Die Stützstellen sind dieselben.
    private func kulisse(_ titel: Item) -> Widget! {
        let (huelle, bild) = gerahmtesBild(breite: 900, hoehe: Stil.heldHoehe,
                                           stil: "swiftly-kulisse")
        gtk_widget_set_halign(huelle, GTK_ALIGN_END)
        gtk_widget_set_valign(huelle, GTK_ALIGN_START)

        if let adressen,
           let url = Bildwahl.quer(titel, adressen: adressen, breite: 1600)?.url {
            bildLaden(bild, url: url, schluessel: url.absoluteString)
        }

        // **Die Blenden gehören in die Bildhülle, nicht in einen Überzug
        // darum.** Zuerst lagen sie über der ganzen Fensterbreite — und ein
        // Verlauf, der bei 0 % am linken Fensterrand beginnt, ist am linken
        // Bildrand längst durchsichtig. Das Bild stand deshalb mit harter
        // Kante da, und der Titel lag unlesbar darauf. In der Hülle fällt
        // dieselbe Kurve auf die 900 Punkt des Bildes.
        for klasse in ["swiftly-blende-quer", "swiftly-blende-hoch"] {
            let blende: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
            gtk_widget_add_css_class(blende, klasse)
            gtk_overlay_add_overlay(OpaquePointer(huelle), blende)
        }
        return huelle
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
        // titelHoehe (52) + 98
        gtk_widget_set_margin_top(feld, Int32(Stil.titelHoehe + 98))

        let name = beschriftung(titel.name, stil: "swiftly-heldtitel")
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_widget_set_size_request(name, 640, 42)
        gtk_fixed_put(alsFeld2(feld), name, 0, 0)

        let angaben = angabenreihe(titel)
        gtk_widget_set_size_request(angaben, 640, 20)
        gtk_fixed_put(alsFeld2(feld), angaben, 0, 54)

        let text = beschriftung(titel.overview ?? "", stil: "swiftly-koerper", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(text), 0)
        gtk_label_set_lines(OpaquePointer(text), 3)
        gtk_label_set_ellipsize(OpaquePointer(text), PANGO_ELLIPSIZE_END)
        gtk_label_set_justify(OpaquePointer(text), GTK_JUSTIFY_LEFT)
        gtk_widget_add_css_class(text, "swiftly-beschreibung")
        gtk_widget_set_size_request(text, 640, 66)
        gtk_fixed_put(alsFeld2(feld), text, 0, 92)

        gtk_fixed_put(alsFeld2(feld), knopfreihe(titel), 0, 182)
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
        Task.detached { [self] in
            let ziel: Item?
            if titel.type == "Series" {
                ziel = try? await client.naechsteFolgeDerSerie(seriesID: titel.id)
            } else {
                ziel = titel
            }
            let plan: PlaybackPlan? = await {
                guard let ziel else { return nil }
                return try? await client.playbackPlan(for: ziel.id)
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

        if let ab = titel.fortsetzenAb {
            let haupt = hauptknopf("Fortsetzen", symbol: "media-playback-start-symbolic")
            gtk_widget_set_size_request(haupt, Int32(Stil.hauptknopfBreite),
                                        Int32(Stil.hauptknopfHoehe))
            beiSignal(haupt, "clicked") { [weak self] in self?.starte(titel, ab: ab) }
            anhaengen(reihe, haupt)
            let vorn = nebenknopf("media-skip-backward-symbolic")
            beiSignal(vorn, "clicked") { [weak self] in self?.starte(titel, ab: 0) }
            anhaengen(reihe, vorn)
        } else {
            let haupt = hauptknopf("Abspielen", symbol: "media-playback-start-symbolic")
            gtk_widget_set_size_request(haupt, Int32(Stil.hauptknopfBreite),
                                        Int32(Stil.hauptknopfHoehe))
            beiSignal(haupt, "clicked") { [weak self] in self?.starte(titel, ab: 0) }
            anhaengen(reihe, haupt)
        }

        // **Merkliste schaltet sofort um, ohne Rückfrage** (D6). Der Zustand
        // des Knopfes ist die Antwort. Das Zeichen ist ein Lesezeichen, kein
        // Stern — „Merkliste erreicht eigentlich das Merklistensymbol an
        // sich", und auf dem Mac steht dort `bookmark`.
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
        let ersteZeile = gesehen ? "Als ungesehen markieren" : "Als gesehen markieren"

        let tafel: Widget! = gtk_popover_new()
        gtk_widget_add_css_class(tafel, "swiftly-mehr")
        gtk_popover_set_child(OpaquePointer(tafel), liste)
        gtk_popover_set_position(OpaquePointer(tafel), GTK_POS_BOTTOM)
        gtk_widget_set_parent(tafel, knopf)

        anhaengen(liste, handlungszeile("object-select-symbolic", ersteZeile) {
            [weak self] in
            guard let self, let client = self.client else { return }
            gesehen.toggle()
            let neu = gesehen
            Task.detached { try? await client.setzeGesehen(itemID: titel.id, an: neu) }
            gtk_popover_popdown(OpaquePointer(tafel))
        })
        anhaengen(liste, handlungszeile("video-x-generic-symbolic", "Trailer") {
            [weak self] in
            gtk_popover_popdown(OpaquePointer(tafel))
            self?.trailerStarten(titel)
        })
        anhaengen(liste, handlungszeile("view-refresh-symbolic", "Metadaten auffrischen") {
            [weak self] in
            guard let client = self?.client else { return }
            Task.detached { try? await client.metadatenAuffrischen(titel.id) }
            gtk_popover_popdown(OpaquePointer(tafel))
        })
        gtk_popover_popup(OpaquePointer(tafel))
    }

    private func handlungszeile(_ symbol: String, _ text: String,
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
                guard let film = filme.first else { return }
                self.starte(film, ab: 0)
            }
        }
    }
}
