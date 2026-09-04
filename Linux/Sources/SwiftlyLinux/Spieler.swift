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

    func spielerOeffnen(_ item: Item, ab: Double) {
        guard let client else { return }
        spielerSchliessen(melden: true)

        laufenderTitel = item
        spielstand = Wiedergabetakt.Stand()
        seitOeffnen = Date()

        let seite = spielerSeiteBauen(item)
        gtk_stack_add_named(OpaquePointer(seiten), seite, "spieler")
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "spieler")
        gtk_widget_set_visible(kopfzeile, 0)

        // **Erst den Plan holen, dann öffnen.** Die Adresse steht nicht in
        // `Item`; sie kommt aus `/PlaybackInfo`, und dort entscheidet sich
        // zugleich, ob der Server transkodiert. Ohne Plan kein Bild.
        Task.detached { [self] in
            let plan = try? await client.playbackPlan(for: item.id)
            aufHauptfaden {
                guard let plan else {
                    self.spielerMeldung("Der Server nennt keine Quelle für diesen Titel.")
                    return
                }
                self.laufenderPlan = plan
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
        if melden, let client, let plan = laufenderPlan, let titel = laufenderTitel {
            let ticks = Int64(spielstand.position * 10_000_000)
            Task.detached {
                try? await client.reportStopped(itemID: titel.id, plan: plan,
                                                positionTicks: ticks)
            }
        }
        abspieler.beenden(nurMedium: true)
        taktBeenden()
        spurwahlSchliessen()
        laufenderTitel = nil
        laufenderPlan = nil
        gtk_widget_set_visible(kopfzeile, 1)
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "start")
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
        gtk_overlay_set_child(OpaquePointer(ueber), abspieler.anzeige)

        let steuerung = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(steuerung, "swiftly-steuerung")
        spielerSteuerung = steuerung

        // Oben: Schliessen links, Einstellungen rechts.
        let oben = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        raender(oben, 18)
        let zu = rundknopf("window-close-symbolic")
        beiSignal(zu, "clicked") { [weak self] in self?.spielerSchliessen() }
        anhaengen(oben, zu)
        anhaengen(oben, luftQuer())
        let spuren = rundknopf("emblem-system-symbolic")
        beiSignal(spuren, "clicked") { [weak self] in self?.spurwahlZeigen() }
        anhaengen(oben, spuren)
        anhaengen(steuerung, oben)

        anhaengen(steuerung, luft())

        // Unten: Titel, Zeitleiste, drei Knöpfe.
        let unten = stapel(GTK_ORIENTATION_VERTICAL, abstand: 12)
        gtk_widget_set_margin_start(unten, 28)
        gtk_widget_set_margin_end(unten, 28)
        gtk_widget_set_margin_bottom(unten, 24)

        let namen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)
        let gross = beschriftung(item.seriesName ?? item.name, stil: "swiftly-titel")
        gtk_label_set_xalign(OpaquePointer(gross), 0)
        anhaengen(namen, gross)
        if let zeile = item.kontextzeile {
            let k = beschriftung(zeile, stil: "swiftly-koerper")
            gtk_widget_add_css_class(k, "dim-label")
            gtk_label_set_xalign(OpaquePointer(k), 0)
            anhaengen(namen, k)
        }
        anhaengen(unten, namen)

        // Zeitleiste: Stand links, Balken, Rest rechts.
        let leiste = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        spielerZeit = beschriftung("0:00", stil: "swiftly-zweitzeile")
        anhaengen(leiste, spielerZeit)
        spielerRegler = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.001)
        gtk_scale_set_draw_value(alsSkala(spielerRegler), 0)
        gtk_widget_add_css_class(spielerRegler, "swiftly-regler")
        gtk_widget_set_hexpand(spielerRegler, 1)
        // **`change-value` bringt Sprungart und Wert mit** — mit dem
        // schlichten Rückruf wäre das derselbe Absturz wie bei
        // `edge-reached`. Deshalb ein eigener, der die Form kennt.
        g_signal_connect_data(UnsafeMutableRawPointer(spielerRegler), "change-value",
                              unsafeBitCast(reglerGezogen, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(),
                              nil, GConnectFlags(rawValue: 0))
        anhaengen(leiste, spielerRegler)
        spielerRest = beschriftung("", stil: "swiftly-zweitzeile")
        anhaengen(leiste, spielerRest)
        anhaengen(unten, leiste)

        // Die drei Knöpfe mittig. **Vorwärts weiter als rückwärts** (B2),
        // und beide Weiten kommen aus den Einstellungen.
        let knoepfe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 26)
        gtk_widget_set_halign(knoepfe, GTK_ALIGN_CENTER)
        let zurueck = rundknopf("media-seek-backward-symbolic", gross: false)
        beiSignal(zurueck, "clicked") { [weak self] in
            guard let self else { return }
            self.abspieler.springen(-Double(self.wahlen.zurueckSekunden))
        }
        anhaengen(knoepfe, zurueck)
        spielerSpieltaste = rundknopf("media-playback-pause-symbolic", gross: true)
        beiSignal(spielerSpieltaste, "clicked") { [weak self] in self?.abspieler.umschalten() }
        anhaengen(knoepfe, spielerSpieltaste)
        let vor = rundknopf("media-seek-forward-symbolic", gross: false)
        beiSignal(vor, "clicked") { [weak self] in
            guard let self else { return }
            self.abspieler.springen(Double(self.wahlen.vorSekunden))
        }
        anhaengen(knoepfe, vor)
        anhaengen(unten, knoepfe)

        // „Nächste Folge" erscheint erst gegen Ende (B5).
        spielerWeiter = hauptknopf("Nächste Folge", symbol: "media-skip-forward-symbolic")
        gtk_widget_set_halign(spielerWeiter, GTK_ALIGN_END)
        gtk_widget_set_size_request(spielerWeiter, 200, Int32(Stil.hauptknopfHoehe))
        gtk_widget_set_visible(spielerWeiter, 0)
        beiSignal(spielerWeiter, "clicked") { [weak self] in self?.naechsteFolge() }
        anhaengen(unten, spielerWeiter)

        anhaengen(steuerung, unten)
        gtk_overlay_add_overlay(OpaquePointer(ueber), steuerung)

        // **Die Steuerung blendet nach 4 s Ruhe aus** (B1) — nur während der
        // Wiedergabe. Jede Bewegung des Zeigers holt sie zurück.
        beiZeiger(ueber, herein: { [weak self] in self?.steuerungZeigen() },
                         hinaus: { [weak self] in self?.steuerungZeigen() })
        steuerungZeigen()
        return ueber
    }

    private func rundknopf(_ symbol: String, gross: Bool = false) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, gross ? "swiftly-spielrund-gross" : "swiftly-spielrund")
        let bild: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(bild), gross ? 26 : 18)
        gtk_button_set_child(alsKnopf(knopf), bild)
        return knopf
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
            stelltEin: false,
            laeuft: abspieler.laeuft,
            hatTonspuren: abspieler.hatTonspuren)

        // **`Wiedergabetakt` ist `@MainActor`, dieser Rückruf nicht.**
        // GTKs Taktgeber läuft auf dem Hauptfaden des Prozesses, und das ist
        // derselbe, den Swift `MainActor` nennt. `assumeIsolated` sagt genau
        // das — und prüft es zur Laufzeit, statt es zu behaupten.
        let auftrag = MainActor.assumeIsolated {
            Wiedergabetakt.rechnen(&spielstand, messung: messung,
                                   stelltWiederHer: false,
                                   sprungLaeuft: false,
                                   amSchieben: false,
                                   seitStart: seitOeffnen)
        }

        zeitenZeigen()

        if auftrag.spurenAnwenden { spurenVorwaehlen() }
        if auftrag.startMelden { melden(.start) }
        if auftrag.fortschrittMelden { melden(.fortschritt) }

        // B5: der Knopf. B6: das selbsttätige Weiterschalten — deutlich enger
        // gefasst, und frühestens `anlaufruhe` Sekunden nach dem Öffnen.
        let zeigen = Folgenende.knopfZeigen(position: spielstand.position,
                                            dauer: spielstand.dauer)
        gtk_widget_set_visible(spielerWeiter, zeigen ? 1 : 0)
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
        gtk_label_set_text(OpaquePointer(spielerZeit), zeitText(spielstand.position))
        if spielstand.dauer > 0 {
            let rest = max(0, spielstand.dauer - spielstand.position)
            gtk_label_set_text(OpaquePointer(spielerRest), "−" + zeitText(rest))
            gtk_range_set_value(alsBereich(spielerRegler),
                                spielstand.position / spielstand.dauer)
        }
        knopfzustand(spielerSpieltaste, aktiv: false,
                     symbol: spielstand.laeuft ? "media-playback-pause-symbolic"
                                               : "media-playback-start-symbolic")
    }

    /// **Tonspuren werden einmal gesetzt, sobald VLC sie kennt** (B8).
    private func spurenVorwaehlen() {
        let wunsch = wahlen.tonSprache
        guard !wunsch.isEmpty else { return }
        if let treffer = abspieler.tonspuren.first(where: {
            $0.name.localizedCaseInsensitiveContains(wunsch)
        }) {
            abspieler.setzeTonspur(treffer.kennung)
        }
    }

    private func naechsteFolge() {
        guard let client, let titel = laufenderTitel, let serie = titel.seriesId else { return }
        Task.detached { [self] in
            guard let naechste = try? await client.folgeNach(itemID: titel.id,
                                                             seriesID: serie),
                  let plan = try? await client.playbackPlan(for: naechste.id) else { return }
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
                // Die nächste Folge startet **von vorn** (B5).
                self.abspieler.oeffnen(plan.url, ab: 0)
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
        steuerungZeigen()
    }

    func steuerungZeigen() {
        gtk_widget_set_opacity(spielerSteuerung, 1)
        steuerungstakt += 1
        let meins = steuerungstakt
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            aufHauptfaden {
                // Nur ausblenden, wenn seither nichts passiert ist — und
                // nicht in Pause: ein Standbild ohne Steuerung sieht aus wie
                // eine ruhige Einstellung.
                guard self.steuerungstakt == meins, self.spielstand.laeuft else { return }
                gtk_widget_set_opacity(self.spielerSteuerung, 0)
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
        gtk_widget_add_css_class(tafel, "swiftly-tafel")
        raender(tafel, 20)
        gtk_widget_set_size_request(tafel, 320, -1)
        gtk_widget_set_halign(tafel, GTK_ALIGN_END)
        gtk_widget_set_valign(tafel, GTK_ALIGN_START)
        gtk_widget_set_margin_top(tafel, 70)
        gtk_widget_set_margin_end(tafel, 18)

        let ton = abspieler.tonspuren
        if !ton.isEmpty {
            let g = spurgruppe("Ton", "audio-volume-high-symbolic")
            let jetzt = abspieler.tonspur
            for spur in ton {
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

        spurtafel = tafel
        gtk_overlay_add_overlay(OpaquePointer(spielerRahmen), tafel)
    }

    private func spurwahlSchliessen() {
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
            gtk_image_set_pixel_size(OpaquePointer(haken), 13)
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
