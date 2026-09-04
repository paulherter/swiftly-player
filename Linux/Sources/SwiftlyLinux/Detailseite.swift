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

        // **Der Ton gehört an die Scrollfläche, nicht an ihren Inhalt.** Auf
        // dem Mac steht er als `.background` an der `ScrollView` und bleibt
        // damit stehen, während der Inhalt darüber wegläuft. Am Inhalt würde
        // er mitscrollen, und der Kopf der Seite wäre irgendwann schwarz.
        let scroller = gtk_scrolled_window_new()
        gtk_widget_add_css_class(scroller, "swiftly-detailgrund")
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
        // Ausrichtung; Überzüge dagegen achten auf beides. Deshalb ist das
        // Hauptkind eine Zeichenfläche, die nur misst — und über ihr Signal
        // `resize` erfahren wir die Breite, die es in GTK sonst nirgends zu
        // holen gibt.
        let mass: Widget! = gtk_drawing_area_new()
        gtk_widget_set_size_request(mass, -1, Int32(Stil.heldHoehe))
        gtk_overlay_set_child(OpaquePointer(kopf), mass)

        let (kulissenhuelle, bild) = kulisse(titel)
        gtk_overlay_add_overlay(OpaquePointer(kopf), kulissenhuelle)
        gtk_overlay_add_overlay(OpaquePointer(kopf), heldenblock(titel))

        // **`max(breite * 0,62, 520)` — wörtlich die Rechnung des Macs.**
        // Erst stand hier eine feste Breite, dann die volle Breite mit einem
        // Verlauf, der die linken 38 % dicht hielt. Beides war daneben: fest
        // riss beim Ziehen am Fenster, voll rückte die Bildmitte unter den
        // Verlauf — die Person in der Mitte des Bildes stand dann im Dunst.
        // Das Bild gehört nach rechts und muss 62 % breit sein, nicht nur so
        // aussehen.
        breitenhalter = Zeigerkiste(kulissenhuelle)
        g_signal_connect_data(UnsafeMutableRawPointer(mass), "resize",
                              unsafeBitCast(kulisseGemessen, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(),
                              nil, GConnectFlags(rawValue: 0))
        tonNachladen(titel, bild: bild)
        return kopf
    }

    /// Wird aus dem Rückruf gerufen, sobald die Kopfzone ihre Breite kennt.
    func kulisseBreite(_ breite: Int32) {
        guard let huelle = breitenhalter?.widget, breite > 0 else { return }
        gtk_widget_set_size_request(huelle, Int32(max(Double(breite) * 0.62, 520)),
                                    Int32(Stil.heldHoehe))
    }

    /// **Rechts, nicht über die volle Breite** — wie auf dem Apple TV und dem
    /// Mac. Dort blendet eine *Maske* das Bild aus, weil der Grund sich
    /// einfärben kann und ein Anstrich dann als Fleck darin stünde. Hier
    /// färbt sich der Grund ebenfalls ein (``Bildfarbe``), aber die Blenden
    /// färben sich mit — deshalb zwei Verläufe im selben Ton statt einer
    /// Maske, die GTK ohnehin nicht kennt. Die Stützstellen sind dieselben.
    private func kulisse(_ titel: Item) -> (Widget, Widget) {
        // **Kein Beschnitt.** Der ließ eine Haarlinie des ungefilterten Bildes
        // am Rand stehen Zu beschneiden gibt es hier nichts: die Kulisse ist
        // nicht gerundet.
        let huelle: Widget! = gtk_overlay_new()
        gtk_widget_add_css_class(huelle, "swiftly-kulisse")
        gtk_widget_set_hexpand(huelle, 0)
        gtk_widget_set_vexpand(huelle, 0)
        gtk_widget_set_halign(huelle, GTK_ALIGN_END)
        gtk_widget_set_valign(huelle, GTK_ALIGN_START)
        gtk_widget_set_size_request(huelle, 520, Int32(Stil.heldHoehe))

        let mass: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_overlay_set_child(OpaquePointer(huelle), mass)

        let bild: Widget! = gtk_picture_new()
        gtk_picture_set_content_fit(OpaquePointer(bild), GTK_CONTENT_FIT_COVER)
        gtk_picture_set_can_shrink(OpaquePointer(bild), 1)
        gtk_overlay_add_overlay(OpaquePointer(huelle), bild)

        if let adressen,
           let url = Bildwahl.quer(titel, adressen: adressen, breite: 1600)?.url {
            bildLaden(bild, url: url, schluessel: url.absoluteString)
        }

        for klasse in ["swiftly-blende-quer", "swiftly-blende-hoch"] {
            let blende: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
            gtk_widget_add_css_class(blende, klasse)
            gtk_overlay_add_overlay(OpaquePointer(huelle), blende)
        }
        return (huelle!, bild!)
    }

    /// Holt ein winziges Abbild und färbt den Auslauf damit ein.
    private func tonNachladen(_ titel: Item, bild: Widget!) {
        guard let adressen,
              let url = Bildwahl.quer(titel, adressen: adressen, breite: 16)?.url
        else { return }
        // Über ``Bildlager``, nicht über `URLSession` — dort liegt schon der
        // Weg samt `FoundationNetworking`, und derselbe Titel wird beim
        // Zurückkommen nicht noch einmal geholt.
        Task.detached {
            guard let daten = await Bildlager.shared.laden(url, schluessel: url.absoluteString)
            else {
                FileHandle.standardError.write(Data("[Ton] nichts geladen: \(url)\n".utf8))
                return
            }
            guard let ton = Bildfarbe.ton(aus: daten) else {
                FileHandle.standardError.write(
                    Data("[Ton] \(daten.count) Byte, aber kein Ton berechnet\n".utf8))
                return
            }
            FileHandle.standardError.write(
                Data("[Ton] \(daten.count) Byte -> \(ton.r),\(ton.g),\(ton.b)\n".utf8))
            aufHauptfaden { Tonblatt.setzen(ton) }
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

        let angefangen = titel.fortsetzenAb
        let haupt = hauptknopf(angefangen != nil ? "Fortsetzen" : "Abspielen",
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
                                          weiter ? "Fortsetzen" : "Abspielen")
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
        let ersteZeile = gesehen ? "Als ungesehen markieren" : "Als gesehen markieren"

        let tafel: Widget! = gtk_popover_new()
        gtk_widget_add_css_class(tafel, "swiftly-mehr")
        gtk_popover_set_child(alsTafel(tafel), liste)
        gtk_popover_set_position(alsTafel(tafel), GTK_POS_BOTTOM)
        gtk_widget_set_parent(tafel, knopf)

        anhaengen(liste, handlungszeile("object-select-symbolic", ersteZeile) {
            [weak self] in
            guard let self, let client = self.client else { return }
            gesehen.toggle()
            let neu = gesehen
            Task.detached { try? await client.setzeGesehen(itemID: titel.id, an: neu) }
            gtk_popover_popdown(alsTafel(tafel))
        })
        anhaengen(liste, handlungszeile("video-x-generic-symbolic", "Trailer") {
            [weak self] in
            gtk_popover_popdown(alsTafel(tafel))
            self?.trailerStarten(titel)
        })
        anhaengen(liste, handlungszeile("view-refresh-symbolic", "Metadaten auffrischen") {
            [weak self] in
            guard let client = self?.client else { return }
            Task.detached { try? await client.metadatenAuffrischen(titel.id) }
            gtk_popover_popdown(alsTafel(tafel))
        })
        gtk_popover_popup(alsTafel(tafel))
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


/// Die Kopfzone hat ihre Breite gemessen. Form: `(GtkDrawingArea*, int, int,
/// gpointer)` — vier Argumente, nicht zwei.
nonisolated(unsafe) let kulisseGemessen: @convention(c) (
    UnsafeMutableRawPointer?, Int32, Int32, gpointer?
) -> Void = { _, breite, _, daten in
    guard let daten else { return }
    Unmanaged<App>.fromOpaque(daten).takeUnretainedValue().kulisseBreite(breite)
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
