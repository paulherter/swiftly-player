import CGtk
import Foundation
import JellyfinKit

/// Der Unterbau der Serienseite: Reiter, Staffelwahl, Folgenliste.
///
/// Aus `Sources/macOS/SerienView.swift`. Die Staffelpille klappt ihre Liste
/// **direkt darunter** auf — kein Blatt, keine Tafel: eine kleine
/// Entscheidung klappt dort auf, wo sie ausgelöst wurde (E5).
extension App {

    enum Reiter: CaseIterable {
        case folgen, besetzung, aehnliches, extras
        var beschriftung: String {
            switch self {
            case .folgen:     uebersetzt("Folgen")
            case .besetzung:  uebersetzt("Besetzung")
            case .aehnliches: uebersetzt("Ähnliches")
            case .extras:     uebersetzt("Extras")
            }
        }
    }

    func serienunterbau(_ serie: Item, in unten: Widget!) {
        let reiterraum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        // **Kein Rand am Reiterinhalt.** Sonst reicht die Hervorhebung einer
        // Folgenzeile nur bis 24 vor die Kante — auf dem Mac läuft sie über
        // die ganze Breite. Den Rand tragen die Zeilen selbst, als
        // Innenabstand, damit ihr Grund darunter durchläuft.

        var gewaehlt: Reiter = .folgen
        var reiterknoepfe: [Widget?] = []

        // **Linksbuendig mit 26 Abstand** — `Reiterreihe` auf dem Mac
        // (`SerienView.swift:495`): `HStack(spacing: 26)` und ein `Spacer`
        // dahinter, die Knoepfe ohne `maxWidth`.
        //
        // Hier stand das am 13.09.2026 schon richtig. Ich habe es auf Drittel
        // umgebaut, weil ich einen Bildschirmabzug des Macs falsch gelesen
        // hatte — und damit den Unterschied erst erzeugt, den ich beheben
        // wollte. Der Quelltext ist die Vorlage; ein Abzug, der ihm
        // widerspricht, wird nachgelesen, nicht nachgebaut.
        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 26)
        gtk_widget_set_margin_start(zeile, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(zeile, Int32(Stil.randAbstand))
        for fall in Reiter.allCases {
            let knopf = reiterknopf(fall.beschriftung, aktiv: fall == gewaehlt)
            reiterknoepfe.append(knopf)
            // **Nur umschalten, nicht selbst anmalen.** Die Hervorhebung
            // stand hier und lief damit nur ueber den Klick; wer den Reiter
            // anders wechselt — das Fernsteuerpult, spaeter eine Taste —,
            // sah den Inhalt umspringen und den Strich unter „Folgen"
            // stehenbleiben. Sie gehoert dorthin, wo umgeschaltet wird.
            beiSignal(knopf, "clicked") { [weak self] in
                self?.reiterZeigen?(fall)
            }
            // **„Extras" erst, wenn der Server welche liefert** (Mac
            // `SerienView`, `Reiterreihe`): bis dahin und ohne sie gibt es
            // den Reiter nicht.
            if fall == .extras { gtk_widget_set_visible(knopf, 0) }
            anhaengen(zeile, knopf)
        }
        anhaengen(reiterraum, zeile)
        // **Die Haarlinie über die volle Breite**, wie auf dem Mac
        // (`SerienView.swift:504`). Hier stand sie einmal nicht, mit dem
        // Vermerk, das sei „eine bewusste Abweichung — zurück ist es eine
        // Zeile". Aufwand ist keiner der drei Gründe, die Abschnitt F
        // zulässt; hier ist die Zeile.
        let reiterlinie: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(reiterlinie, "swiftly-trennlinie")
        gtk_widget_set_size_request(reiterlinie, -1, 1)
        anhaengen(reiterraum, reiterlinie)

        anhaengen(unten, reiterraum)

        // **Ein Stapel, kein Abriss.**
        //
        // Vorher raeumte jeder Reiterwechsel `inhaltraum` leer und baute ihn
        // neu. Damit aendert sich die Hoehe des ganzen Scrollinhalts in einem
        // Zug — von einer langen Folgenliste auf eine kurze Besetzungsreihe —,
        // GTK teilt die Seite neu zu, und die Zeichenflaeche der Kulisse geht
        // durch eine Zwischengroesse. Von aussen: das Kopfbild verschwindet
        // kurz und kommt wieder. Genau das wurde zweimal gemeldet.
        //
        // Ein `GtkStack` haelt die drei Seiten nebeneinander und blendet
        // zwischen ihnen um; oben aendert sich nichts. Nebenbei faellt damit
        // das Neuladen weg: „Besetzung" und „Aehnliches" holten bisher bei
        // jedem Wechsel neu, obwohl sie schon dastanden.
        let reiterstapel: Widget! = gtk_stack_new()
        // Sonst malt ihn die `stack`-Regel im Stilblatt deckend in `grund`
        // und schneidet den auslaufenden Seitenton ab.
        gtk_widget_add_css_class(reiterstapel, "swiftly-reiterstapel")
        gtk_stack_set_transition_type(alsStapel(reiterstapel),
                                      GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_transition_duration(alsStapel(reiterstapel),
                                          UInt32(Stil.zeitBlende * 1000))
        // **Gleich hoch bleiben.** Ohne das nimmt der Stapel die Hoehe der
        // sichtbaren Seite, und die Seite springt beim Wechsel doch wieder.
        gtk_stack_set_vhomogeneous(alsStapel(reiterstapel), 0)
        anhaengen(unten, reiterstapel)

        // **Alle drei Seiten stehen von Anfang an** (iPhone `fcd0d890`).
        // Vorher entstanden „Folgen" sofort und „Ähnliches" erst beim ersten
        // Wechsel dorthin, mit eigenem Abruf und eigenem Platzhalter. Jetzt
        // kommen Stand, Staffeln, die Folgen der gewählten Staffel und
        // Ähnliches in einem Zug (``serieNachladen``); die Besetzung steht
        // schon im Titel.
        var seiten: [Reiter: Widget?] = [:]
        for fall in Reiter.allCases {
            let raum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 18)
            gtk_stack_add_named(alsStapel(reiterstapel), raum, String(describing: fall))
            reiterInhalt(fall, serie: serie, in: raum)
            seiten[fall] = raum
        }
        serieNachladen(serie, folgen: seiten[.folgen] ?? nil, aehnliches: seiten[.aehnliches] ?? nil)
        extrasNachladen(serie, in: seiten[.extras] ?? nil,
                        knopf: reiterknoepfe[Reiter.allCases.firstIndex(of: .extras) ?? 0])

        let zeigen: (Reiter) -> Void = { fall in
            gewaehlt = fall
            for (i, f) in Reiter.allCases.enumerated() {
                guard let k = reiterknoepfe[i] else { continue }
                if f == fall { gtk_widget_add_css_class(k, "swiftly-aktiv") }
                else { gtk_widget_remove_css_class(k, "swiftly-aktiv") }
                bedienhilfe(k, gewaehlt: f == fall)
            }
            gtk_stack_set_visible_child_name(alsStapel(reiterstapel), String(describing: fall))
        }
        reiterZeigen = zeigen
        zeigen(.folgen)
        // Damit das Fernsteuerpult den Reiter wechseln kann, ohne zu klicken.
        reiterWaehlen = zeigen
    }

    /// Holt die Extras der Serie; ohne welche bleibt der Reiter unsichtbar.
    private func extrasNachladen(_ serie: Item, in raum: Widget!, knopf: Widget?) {
        guard let client, let raum, let knopf else { return }
        let raumKiste = gehalten(raum)
        let knopfKiste = gehalten(knopf)
        Task.detached { [self] in
            let extras = (try? await client.extras(itemID: serie.id)) ?? []
            nachDemSchub {
                defer { losgelassen(raumKiste); losgelassen(knopfKiste) }
                guard !extras.isEmpty, let raum = raumKiste.widget,
                      let knopf = knopfKiste.widget else { return }
                anhaengen(raum, self.extrareihe(extras, titel: uebersetzt("Extras")))
                gtk_widget_set_visible(knopf, 1)
            }
        }
    }

    /// **Die Extras als Reihe** (Mac `Titelreihe(spielen: true)`, Kachel nach
    /// `Extrakachel`): Bild 210 x 118, darunter Name und Laufzeit. Ein Klick
    /// spielt das Extra ab Anfang, mit demselben Plan wie jeden Titel —
    /// Direct Play, nie Transkodieren. Auf der Serienseite steht dieselbe
    /// Überschrift im Reiter „Extras" wie auf dem Mac.
    func extrareihe(_ extras: [Item], titel: String) -> Widget! {
        let breite = 210
        let hoehe = 118
        let kacheln: [Widget?] = extras.map { extra in
            let (kaefig, bild) = gerahmtesBild(breite: breite, hoehe: hoehe, stil: "swiftly-plakat")
            if let adresse = adressen.flatMap({ Bildwahl.quer(extra, adressen: $0, breite: Skalierung.anfragekante(breite))?.url }) {
                bildLaden(bild, url: adresse, schluessel: Bildschluessel.fuer(adresse),
                          kante: Skalierung.bildkante(breite))
            } else {
                zeichenLegen(kaefig, serie: false)
            }
            // Ein Extra ohne Laufzeit meldet 0, nicht nichts — dann keine Zeile.
            let unten: String? = Anzeigeregeln.laufzeitZeigen(sekunden: extra.runtimeSeconds)
                ? extra.runtimeSeconds.map { laufzeit($0) } : nil
            return kachelhuelle(bild: kaefig, breite: breite, oben: extra.name, unten: unten) {
                [weak self] in self?.starte(extra, ab: 0)
            }
        }
        return reiheBauen(titel: titel, bildHoehe: hoehe, stueck: breite + Stil.kachelAbstand,
                          kacheln: kacheln)
    }

    private func reiterInhalt(_ was: Reiter, serie: Item, in raum: Widget!) {
        leeren(raum)
        switch was {
        case .folgen:
            // **Leer, aber mit Platz** (iPhone `2b17f044`). Solange geladen
            // wird, steht die Hoehe der Staffelwahl frei; Staffelwahl und
            // Folgen blenden dann an ihrem Platz ein. Die drei
            // Folgenplatzhalter sind weg: die Liste ist das Letzte auf der
            // Seite, darunter springt nichts.
            anhaengen(raum, staffelwahlPlatz())
        case .besetzung:
            if serie.darsteller.isEmpty {
                let leer = beschriftung(uebersetzt("Keine Besetzung hinterlegt."), stil: "swiftly-koerper")
                gtk_widget_set_margin_start(leer, Int32(Stil.randAbstand))
                anhaengen(raum, leer)
            } else {
                anhaengen(raum, besetzungsreihe(serie.darsteller, herkunft: serie.name))
            }
        case .extras:
            // Bleibt leer, bis ``extrasNachladen`` Extras findet.
            break
        case .aehnliches:
            // Bleibt leer, bis ``serieNachladen`` antwortet — kein
            // Platzhalter und kein „Nichts Ähnliches", solange geladen wird.
            break
        }
    }

    /// Der freie Platz der Staffelwahl: Chiphoehe 30 und die 18 darunter
    /// (``staffelnZeigen``).
    private func staffelwahlPlatz() -> Widget! {
        let platz = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(platz, -1, 30)
        gtk_widget_set_margin_bottom(platz, 18)
        return platz
    }

    // MARK: Staffeln und Folgen

    /// **Ein Einblenden, nicht fünf** (iPhone `fcd0d890`, `SeriesDetailView.laden`).
    ///
    /// Die Seite setzte jede Antwort einzeln: erst die Staffelwahl, dann die
    /// Folgen mit eigenem Platzhalter, und „Ähnliches" erst, wenn jemand den
    /// Reiter öffnete. Jetzt kommen Stand, Staffeln, die Folgen der
    /// gewählten Staffel und Ähnliches zusammen und blenden gemeinsam ein.
    /// Der Plan läuft daneben (``planNachladen``) und blendet nur den Beleg
    /// ein, dessen Platz schon steht.
    ///
    /// - Parameter aehnliches: `nil` beim Wiederholen nach einer Störung —
    ///   dann gilt der Abruf nur den Staffeln.
    private func serieNachladen(_ serie: Item, folgen raum: Widget!, aehnliches araum: Widget?) {
        guard let client else { return }
        let id = startStaffel
        let nummer = startStaffelNummer
        // **Der Stand nur, wenn kein Hinweis kam** (A10). Ein Abruf, den
        // niemand liest, kostet auf jeder Serienseite eine Anfrage.
        let brauchtStand = Staffelwahlregel.brauchtStand(hinweisID: id, hinweisNummer: nummer)

        // **Schon geholt heisst: sofort da.** Kein Lader, kein Sprung —
        // „Ähnliches" steht dann in einem anderen Reiter und kommt allein.
        if let schon = staffelspeicher[serie.id], !schon.isEmpty, !brauchtStand {
            staffelnZeigen(schon, serie: serie, in: raum,
                           gewaehlt: Staffelwahlregel.waehle(aus: schon, hinweisID: id,
                                                             hinweisNummer: nummer))
            if let araum { aehnlicheNachladen(serie, in: araum, leeren: true, alsRaster: true) }
            return
        }
        let kiste = gehalten(raum)
        let aKiste = araum.map(gehalten)
        Task.detached { [self] in
            // Alles nebenher: Stand, Staffeln und Ähnliches hängen nicht
            // aneinander; nur die Folgen brauchen die gewählte Staffel.
            //
            // **Eigene Aufgaben statt `async let`** (siehe ``nebenher(_:)``).
            // Genau diese drei als `async let` beendeten die Windows-App
            // beim Öffnen jeder Serie.
            let staffelnRoh = nebenher { try? await client.staffeln(seriesID: serie.id) }
            let standRoh = brauchtStand ? nebenher { await client.standInSerie(serie.id) } : nil
            let aehnlichRoh = aKiste == nil ? nil
                : nebenher { try? await client.aehnliche(itemID: serie.id, zu: serie) }
            // **`nil` heisst gestoert, `[]` wirklich leer** (a2bb95bd) — und
            // ein gescheiterter Abruf wird nicht gemerkt (4fffc63c).
            let geholt = await staffelnRoh.value
            let staffeln = geholt ?? []
            let stand = await standRoh?.value ?? nil
            let gewaehlt = Staffelwahlregel.waehle(aus: staffeln, hinweisID: id,
                                                   hinweisNummer: nummer, stand: stand)
            // Die Folgen der Staffel, die gleich dasteht — ``staffelnZeigen``
            // nimmt dieselbe.
            let erste = gewaehlt ?? staffeln.first
            let folgen: [Item]? = await {
                guard let erste else { return nil }
                return try? await client.folgen(seriesID: serie.id, seasonID: erste.id)
            }()
            let aehnliche: [Item]?? = if let aehnlichRoh { .some(await aehnlichRoh.value) } else { .none }
            nachDemSchub {
                defer {
                    losgelassen(kiste)
                    if let aKiste { losgelassen(aKiste) }
                }
                if let aKiste, let aehnliche {
                    self.aehnlicheZeigen(aehnliche, titel: serie, in: aKiste.widget,
                                         leeren: true, alsRaster: true)
                    gtk_widget_set_opacity(aKiste.widget, 0)
                    blenden(aKiste.widget, auf: 1, dauer: Stil.zeitBlendeHerein)
                }
                guard geholt != nil else {
                    leeren(kiste.widget)
                    anhaengen(kiste.widget, self.stoerhinweis { [weak self] in
                        guard let self, let raum = kiste.widget else { return }
                        leeren(raum)
                        anhaengen(raum, self.staffelwahlPlatz())
                        self.serieNachladen(serie, folgen: raum, aehnliches: nil)
                    })
                    return
                }
                self.staffelspeicher[serie.id] = staffeln
                if let erste, let folgen { self.folgenspeicher[erste.id] = folgen }
                self.staffelnZeigen(staffeln, serie: serie, in: kiste.widget,
                                    gewaehlt: gewaehlt)
                gtk_widget_set_opacity(kiste.widget, 0)
                blenden(kiste.widget, auf: 1, dauer: Stil.zeitBlendeHerein)
            }
        }
    }

    private func staffelnZeigen(_ staffeln: [Item], serie: Item, in raum: Widget!,
                                gewaehlt: Item?) {
        leeren(raum)
        guard !staffeln.isEmpty else {
            anhaengen(raum, leerhinweis(uebersetzt("Keine Folgen")))
            return
        }
        // **Welche Staffel dasteht, entscheidet der Weg auf die Seite** (A10).
        // Die Rechnung liegt im Paket (`Staffelwahlregel`), damit sie auf
        // jeder Plattform dieselbe Antwort gibt; hier stand vorher nur ein
        // Kennungsvergleich mit Rückfall auf `staffeln[0]`, also Staffel 1 —
        // während der Hauptknopf daneben „Weiterschauen S6E1" sagte.
        let wahl = Staffelwahl()
        wahl.jetzt = gewaehlt ?? staffeln[0]
        offeneStaffel = wahl.jetzt

        // **Mit Winkel, und der zeigt den Zustand.** Auf dem Mac trägt der
        // Chip `chevron.down`, offen `chevron.up` (`SerienView.swift:548`);
        // hier stand ein nacktes Textlabel, dem man nicht ansieht, dass es
        // etwas aufklappt.
        let pille: Widget! = gtk_button_new()
        gtk_widget_add_css_class(pille, "swiftly-chip")
        gtk_widget_set_halign(pille, GTK_ALIGN_START)
        let pilleninhalt = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
        let pillentext = beschriftung(wahl.jetzt?.name ?? uebersetzt("Staffel"))
        // Ein Winkel, kein Pfeil — `chevron.down` auf dem Mac.
        let pillenwinkel: Widget! = gtk_image_new_from_icon_name("pan-down-symbolic")
        anhaengen(pilleninhalt, pillentext)
        anhaengen(pilleninhalt, pillenwinkel)
        gtk_button_set_child(alsKnopf(pille), pilleninhalt)
        // Nur bei mehr als einer Staffel ist eine Wahl zu treffen.
        // **Bei einer Staffel gibt es nichts zu waehlen.** Der Mac blendet
        // die Pille dann ganz aus; ausgegraut stehen zu lassen sieht aus wie
        // ein Knopf, der klemmt.
        // Die Beschriftung bleibt auch bei einer Staffel stehen — nur der
        // Winkel faellt weg, weil es nichts zu waehlen gibt.
        gtk_widget_set_visible(pille, staffeln.isEmpty ? 0 : 1)
        gtk_image_set_pixel_size(OpaquePointer(pillenwinkel), 11)

        let folgenraum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)

        // **Kein Blatt, sondern eine Liste an Ort und Stelle.**
        //
        // Hier stand ein `GtkPopover`, und der Kommentar daneben behauptete,
        // der Mac zeige dort ein Blatt. Er zeigt keines: `Staffelwahl`
        // (`Sources/macOS/SerienView.swift:541`) klappt die Liste **im
        // Seitenfluss** unter dem Chip auf, und der Doc-Kommentar sagt
        // ausdrücklich, warum — „ein `Menu` wäre hier das Naheliegende und
        // genau deshalb falsch: es bringt Systemmaße, Systemecken und ein
        // Systemmaterial mit". Ein GTK-Popover bringt genau dieselben drei
        // Dinge mit. Dass alles darunter mitwandert, ist kein Nebeneffekt,
        // sondern das Verhalten der Vorlage.
        //
        // 220 breit, Innenrand 4 senkrecht, `erhoeht` mit `eckeFeld` und
        // einer Haarlinie — alles aus `SerienView.swift:554–566`.
        let wahlblock = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_halign(wahlblock, GTK_ALIGN_START)
        anhaengen(wahlblock, pille)

        let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(liste, "swiftly-staffelliste")
        gtk_widget_set_size_request(liste, 220, -1)
        gtk_widget_set_halign(liste, GTK_ALIGN_START)

        // Der Mac fährt sie mit `Stil.zeitSprung` (snappy, 0,22 s) von oben
        // herein und blendet sie dabei ein; ein `GtkRevealer` mit
        // `SLIDE_DOWN` ist das nächstliegende Gegenstück.
        let aufklapp: Widget! = gtk_revealer_new()
        gtk_revealer_set_transition_type(alsAufklapp(aufklapp),
                                         // **Waechst aus dem Knopf** (Mac
                                         // 51c9c8a8): Einblenden plus das
                                         // Aufklappen im Stilblatt, kein
                                         // Herunterfahren.
                                         GTK_REVEALER_TRANSITION_TYPE_CROSSFADE)
        gtk_revealer_set_transition_duration(alsAufklapp(aufklapp), 220)
        gtk_revealer_set_child(alsAufklapp(aufklapp), liste)
        gtk_widget_set_margin_top(aufklapp, 8)
        gtk_widget_set_halign(aufklapp, GTK_ALIGN_START)
        // **Zugeklappt ist sie weg, nicht nur durchsichtig.** Eine Blende
        // behält zu die volle Höhe ihrer Liste (headless gemessen: 336 Punkt
        // bei acht Staffeln) — das war der riesige Abstand zwischen
        // Staffelwahl und erster Folge. Sichtbar wird sie beim Aufklappen,
        // unsichtbar, sobald das Zuklappen fertig ist.
        gtk_widget_set_visible(aufklapp, 0)
        let aufklappKiste = gehalten(aufklapp)
        beiEigenschaft(UnsafeMutableRawPointer(aufklapp), "notify::child-revealed") {
            guard let a = aufklappKiste.widget,
                  gtk_revealer_get_child_revealed(alsAufklapp(a)) == 0,
                  gtk_revealer_get_reveal_child(alsAufklapp(a)) == 0 else { return }
            gtk_widget_set_visible(a, 0)
        }
        beiSignal(aufklapp, "destroy") { losgelassen(aufklappKiste) }
        anhaengen(wahlblock, aufklapp)

        // **Einmal angelegt, nicht bei jedem Klick.** Vorher entstand hier je
        // Klick eine neue Tafel, die am Knopf hängenblieb; beim Verlassen der
        // Seite meldete GTK „Finalizing GtkButton, but it still has children
        // left" und ließ einen Zeiger stehen. Genau daran ist die App beim
        // Öffnen einer Serie gestorben.
        var zeilen: [String: Widget?] = [:]
        for staffel in staffeln {
            let zeile = staffelzeile(staffel.name,
                                     gewaehlt: staffel.id == wahl.jetzt?.id) { [weak self] in
                guard let self else { return }
                wahl.jetzt = staffel
                self.offeneStaffel = staffel
                self.detailBeruehrt = true
                gtk_label_set_text(OpaquePointer(pillentext), staffel.name)
                for (kennung, w) in zeilen {
                    self.staffelzeileMalen(w, gewaehlt: kennung == staffel.id)
                }
                gtk_widget_remove_css_class(liste, "swiftly-offen")
                gtk_revealer_set_reveal_child(alsAufklapp(aufklapp), 0)
                gtk_image_set_from_icon_name(OpaquePointer(pillenwinkel), "pan-down-symbolic")
                self.folgenLaden(serie: serie, staffel: staffel, in: folgenraum)
            }
            zeilen[staffel.id] = zeile
            anhaengen(liste, zeile)
        }

        beiSignal(pille, "clicked") {
            // Auch bei einer einzigen Staffel oeffnet sie: der Chip sagt, welche
            // Staffel man sieht (Mac 91e2475a).
            let offen = gtk_revealer_get_reveal_child(alsAufklapp(aufklapp)) == 0
            if offen { gtk_widget_set_visible(aufklapp, 1) }
            // Die Klasse stoesst das Aufklappen im Stilblatt an.
            if offen { gtk_widget_add_css_class(liste, "swiftly-offen") }
            else { gtk_widget_remove_css_class(liste, "swiftly-offen") }
            gtk_revealer_set_reveal_child(alsAufklapp(aufklapp), offen ? 1 : 0)
            gtk_image_set_from_icon_name(OpaquePointer(pillenwinkel),
                                         offen ? "pan-up-symbolic" : "pan-down-symbolic")
        }

        // **Die Staffelwahl steht allein und linksbuendig** (Mac 1bf1685f):
        // der Chip „Staffel laden" ist weg, und mit ihm die Reihe, die ihn
        // neben der Wahl hielt. Geladen wird ueber den Knopf in der
        // Knopfreihe (``ladeauswahlZeigen(_:an:)``). 18 unter der Wahl.
        staffelladeknopf = nil
        gtk_widget_set_margin_start(wahlblock, Int32(Stil.randAbstand))
        // 14 bis zur ersten Zeile, dazu ihre 12 Innenabstand — wie am iPhone
        // (`SeriesView.folgenliste`) und am Mac. Der Abstand des Reiterraums
        // (18) gilt hier nicht, sonst stünden beide übereinander.
        gtk_box_set_spacing(alsBox(raum), 0)
        gtk_widget_set_margin_bottom(wahlblock, 14)
        anhaengen(raum, wahlblock)
        anhaengen(raum, folgenraum)
        if let jetzt = wahl.jetzt {
            folgenLaden(serie: serie, staffel: jetzt, in: folgenraum)
        }
    }

    /// **Ist die Staffel schon vollstaendig da, faellt der Chip weg** — so
    /// auf dem Mac (`SerienView.swift:46-50`, `staffelVollstaendig`).
    func staffelladeknopfMalen() {
        guard let knopf = staffelladeknopf else { return }
        let offen = staffelfolgen.contains { downloads.posten(fuer: $0.id) == nil }
        gtk_widget_set_visible(knopf, (downloadKnopfZeigen && !staffelfolgen.isEmpty && offen) ? 1 : 0)
    }

    /// Eine Zeile in der Staffelliste — Name links, Haken bei der gewählten.
    ///
    /// **Der Haken steht immer da und wird nur ausgeblendet.** Er kam bisher
    /// erst beim Bauen dazu; seit die Liste einmal entsteht und nicht bei
    /// jedem Klick, muss die Wahl umziehen können, ohne dass die Zeile neu
    /// gebaut wird — sonst zeigt die Liste beim zweiten Öffnen zwei Haken.
    /// Internal: die Player-Folgenebene (`PlayerEbenen.swift`) baut ihre
    /// Staffelliste aus derselben Zeile — wörtlich, nicht nachgebaut.
    func staffelzeile(_ text: String, gewaehlt: Bool,
                              _ auswahl: @escaping () -> Void) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-handlung")
        gtk_widget_add_css_class(knopf, "swiftly-staffelzeile")
        if gewaehlt { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
        bedienhilfe(knopf, gewaehlt: gewaehlt)
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        let l = beschriftung(text, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        anhaengen(reihe, l)
        // 12 fett, wie `Staffelzeile` auf dem Mac (`SerienView.swift:592`).
        let haken: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(haken), 12)
        gtk_widget_set_visible(haken, gewaehlt ? 1 : 0)
        anhaengen(reihe, haken)
        gtk_button_set_child(alsKnopf(knopf), reihe)
        beiSignal(knopf, "clicked", auswahl)
        return knopf
    }

    /// Setzt die Wahl auf einer bestehenden Zeile um — Akzent an, Haken an.
    func staffelzeileMalen(_ zeile: Widget?, gewaehlt: Bool) {
        guard let zeile else { return }
        if gewaehlt { gtk_widget_add_css_class(zeile, "swiftly-aktiv") }
        else        { gtk_widget_remove_css_class(zeile, "swiftly-aktiv") }
        bedienhilfe(zeile, gewaehlt: gewaehlt)
        // Knopf → Reihe → (Beschriftung, Haken). Der Haken ist das letzte Kind.
        guard let reihe = gtk_button_get_child(alsKnopf(zeile)),
              let haken = gtk_widget_get_last_child(reihe) else { return }
        gtk_widget_set_visible(haken, gewaehlt ? 1 : 0)
    }

    private func folgenLaden(serie: Item, staffel: Item, in raum: Widget!) {
        guard let client else { return }
        if let schon = folgenspeicher[staffel.id] {
            folgenZeigen(schon, in: raum)
            // **Der Speicher zeigt sofort, der Server hat recht.** Was hier
            // liegt, stammt vom letzten Besuch; wer inzwischen am Handy
            // weitergeschaut hat, sah weder Balken noch Restzeit. Frisch
            // holen und die Zeilen an Ort und Stelle nachziehen — ohne
            // Neubau, die Liste springt nicht.
            Task.detached { [self] in
                guard let frisch = try? await client.folgen(seriesID: serie.id,
                                                            seasonID: staffel.id) else { return }
                nachDemSchub {
                    self.folgenspeicher[staffel.id] = frisch
                    for f in frisch { self.sehstandZeilen[f.id]?.auffrischen(f) }
                }
            }
            return
        }
        // **Keine Platzhalter** (iPhone `2b17f044`): die bisherige Liste
        // bleibt stehen, bis die neue da ist, und die blendet dann ein.
        let kiste = gehalten(raum)
        Task.detached { [self] in
            let geholt = try? await client.folgen(seriesID: serie.id,
                                                  seasonID: staffel.id)
            nachDemSchub {
                defer { losgelassen(kiste) }
                // **Gestoert ist nicht leer** — „Keine Folgen" hiesse hier,
                // der Server habe keine; er hat nur nicht geantwortet.
                guard let folgen = geholt else {
                    leeren(kiste.widget)
                    self.staffelfolgen = []
                    anhaengen(kiste.widget, self.stoerhinweis { [weak self] in
                        self?.folgenLaden(serie: serie, staffel: staffel, in: kiste.widget)
                    })
                    return
                }
                self.folgenspeicher[staffel.id] = folgen
                self.folgenZeigen(folgen, in: kiste.widget)
                gtk_widget_set_opacity(kiste.widget, 0)
                blenden(kiste.widget, auf: 1, dauer: Stil.zeitBlendeHerein)
            }
        }
    }

    /// Zeigt eine Folgenliste — aus dem Netz oder aus dem Speicher.
    private func folgenZeigen(_ folgen: [Item], in raum: Widget!) {
        leeren(raum)
        // Der Chip „Staffel laden" braucht die Liste, die er laden soll.
        staffelfolgen = folgen
        staffelladeknopfMalen()
        guard !folgen.isEmpty else {
            // **Leer ist eine Auskunft, kein leerer Kasten.** Sonst steht
            // dort nichts und man hält es für einen Fehler.
            let l = beschriftung(uebersetzt("Keine Folgen"), stil: "swiftly-koerper")
            gtk_widget_add_css_class(l, "swiftly-leise")
            gtk_widget_set_halign(l, GTK_ALIGN_CENTER)
            gtk_widget_set_margin_top(l, 40)
            gtk_widget_set_margin_bottom(l, 40)
            anhaengen(raum, l)
            return
        }
        // **Schrittweise, nicht auf einmal.** Hier baute eine Schleife jede
        // Zeile in einem Zug — bei einer Staffel mit vierzig Folgen je Zeile
        // ein Bild, Texte und Knöpfe, alles auf dem Hauptfaden und alles vor
        // dem nächsten Bild. Das war das Stocken beim Öffnen einer Serie mit
        // vielen Folgen. Jetzt stehen die ersten sofort (sie sind zu sehen),
        // der Rest kommt in kleinen Stücken, jedes nach dem nächsten
        // gezeichneten Bild (``nachFrist`` läuft unter dem Bildtakt).
        folgenaufbau += 1
        let nummer = folgenaufbau
        let sofort = App.folgenSofort
        for folge in folgen.prefix(sofort) { anhaengen(raum, folgenzeile(folge)) }
        guard folgen.count > sofort else { return }
        let kiste = gehalten(raum)
        func weiter(ab start: Int) {
            nachFrist(0) { [weak self] in
                guard let self, self.folgenaufbau == nummer, let raum = kiste.widget,
                      gtk_widget_get_parent(raum) != nil else {
                    losgelassen(kiste)
                    return
                }
                let ende = min(start + App.folgenJeSchritt, folgen.count)
                for folge in folgen[start..<ende] { anhaengen(raum, self.folgenzeile(folge)) }
                if ende < folgen.count { weiter(ab: ende) } else { losgelassen(kiste) }
            }
        }
        weiter(ab: sofort)
    }

    /// So viele Folgen stehen sofort — mehr passen unter den Kopf nicht.
    static let folgenSofort = 8
    /// Und so viele kommen je Schritt danach.
    static let folgenJeSchritt = 4

    /// Eine Folge in der Liste. Bild 160 × 90 (16 : 9), 18 Abstand, darunter
    /// Kopfzeile mit Laufzeit rechts und zwei Zeilen Beschreibung.
    ///
    /// **Das Bild der Folge, nicht das der Serie.** `Bildwahl.quer` nimmt
    /// absichtlich den Hintergrund der Serie — richtig für „Weiterschauen",
    /// falsch hier: in einer Folgenliste stünde in jeder Zeile dasselbe Bild.
    /// Internal: die Player-Folgenebene (`PlayerEbenen.swift`) baut ihre
    /// Liste aus derselben Zeile — wörtlich, nicht nachgebaut.
    ///
    /// - Parameter laeuft: Markiert die Zeile wie die laufende Folge in der
    ///   Player-Folgenebene (`.swiftly-aktiv`, Weiss zu 8 %).
    /// - Parameter aktion: Ohne Angabe startet ein Klick den Titel frisch
    ///   (`starte`, wie auf der Serienseite). Die Player-Folgenebene übergibt
    ///   stattdessen den Wechsel im laufenden Player (`wechsleZu`), sonst
    ///   führte ein Klick dort zu einem Player, der sich einmal schliesst und
    ///   neu öffnet, statt nur die Folge zu tauschen.
    func folgenzeile(_ folge: Item, laeuft: Bool = false,
                     aktion: ((Item) -> Void)? = nil) -> Widget! {
        // **Kein Knopf, eine Geste.** Die Zeile trägt selbst einen Knopf —
        // den Haken zum Umschalten —, und ein Knopf im Knopf ist in GTK kein
        // sicherer Bau. Auf dem Mac steht dort aus demselben Grund
        // `.onTapGesture`.
        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 18)
        gtk_widget_add_css_class(zeile, "swiftly-folgenzeile")
        if laeuft { gtk_widget_add_css_class(zeile, "swiftly-aktiv") }

        let (huelle, bild) = gerahmtesBild(breite: 160, hoehe: 90, stil: "swiftly-plakat")
        gtk_widget_set_valign(huelle, GTK_ALIGN_START)
        if let adressen, let marke = folge.imageTags?["Primary"],
           let url = adressen.bauen(itemID: folge.id, marke: marke,
                                    mass: .hoechstensHoch(220)) {
            bildLaden(bild, url: url, schluessel: Bildschluessel.fuer(url))
        } else {
            zeichenLegen(huelle, serie: true)
        }
        // **Das Vorschaubild traegt den Sehstand**, nicht die Spalte rechts.
        // Es zeigte schon den Fortschrittsbalken — „wie weit bin ich" —, und
        // der Haken ist dessen Ende. Damit steht der Sehstand an einer Stelle
        // statt an zweien, und rechts bleibt Platz fuer den Download. Auf dem
        // Mac seit jeher so (`SerienView.swift:642`), auf dem iPhone seit
        // `beb6a79`; auf Linux stand der Haken ganz rechts am Zeilenende.
        //
        // **Ein voller Balken und ein Haken waeren dieselbe Auskunft
        // zweimal** — deshalb der Balken nur, solange nicht gesehen.
        var balkenteile: [Widget?] = []
        if wahlen.fortschrittAufKacheln, !folge.istGesehen,
           let anteil = folge.gesehenerAnteil {
            balkenteile = balkenLegen(huelle, breite: 160, anteil: anteil)
        }
        let bildhaken = gesehenhakenLegen(huelle, an: folge.istGesehen)
        // **Ein Abspielzeichen über dem Bild, wenn der Zeiger da ist** — der
        // Mac hat es (`SerienView.swift:665-674`). Ohne es sieht ein Standbild
        // nicht danach aus, als ließe es sich anklicken.
        let kreis: Widget! = gtk_image_new_from_icon_name("media-playback-start-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(kreis), 16)
        gtk_widget_add_css_class(kreis, "swiftly-spielkreis")
        gtk_widget_set_halign(kreis, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(kreis, GTK_ALIGN_CENTER)
        // Steht immer da, nur unsichtbar — so kann es einblenden statt
        // aufzuspringen (`zeitSchweben`). Klicks gehen an die Zeile.
        gtk_widget_set_opacity(kreis, 0)
        gtk_widget_set_can_target(kreis, 0)
        gtk_overlay_add_overlay(OpaquePointer(huelle), kreis)
        anhaengen(zeile, huelle)

        let text = stapel(GTK_ORIENTATION_VERTICAL, abstand: 5)
        gtk_widget_set_hexpand(text, 1)

        let kopf = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        let nummer = folge.indexNumber.map { "\($0). " } ?? ""
        let name = beschriftung(nummer + folge.name, stil: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(name), 1)
        gtk_widget_set_hexpand(name, 1)
        anhaengen(kopf, name)
        // **Angefangen: die Restzeit statt der Laufzeit** — wie `Folgenzeile`
        // am iPhone („Noch 24 Minuten"). Der Balken im Bild sagt, wie weit;
        // das Wort, wie lange noch.
        func dauertext(_ f: Item) -> String? {
            guard let sekunden = f.runtimeSeconds, sekunden > 0 else { return nil }
            return (f.istGesehen ? nil : f.restzeitText) ?? laufzeit(sekunden)
        }
        var dauerfeld: Widget?
        if let text = dauertext(folge) {
            let dauer = beschriftung(text, stil: "swiftly-zweitzeile")
            dauerfeld = dauer
            gtk_widget_add_css_class(dauer, "swiftly-leise")
            anhaengen(kopf, dauer)
        }
        anhaengen(text, kopf)

        if let inhalt = folge.beschreibung, !inhalt.isEmpty {
            let z = beschriftung(inhalt, stil: "swiftly-zweitzeile", umbruch: true)
            gtk_widget_add_css_class(z, "dim-label")
            gtk_label_set_xalign(OpaquePointer(z), 0)
            gtk_label_set_lines(OpaquePointer(z), 2)
            gtk_label_set_ellipsize(OpaquePointer(z), PANGO_ELLIPSIZE_END)
            gtk_label_set_justify(OpaquePointer(z), GTK_JUSTIFY_LEFT)
            gtk_widget_set_size_request(z, 200, -1)
            anhaengen(text, z)
        }
        anhaengen(zeile, text)

        // **Kein Haken-Knopf mehr am Zeilenende** (wie am Mac). Er kam unter
        // dem Zeiger und war der zweite Weg zum Sehstand; der Weg ist jetzt
        // das Kachelmenü (Rechtsklick). Der Haken als *Auskunft* steht auf
        // dem Bild und bleibt dort, auch unter dem Zeiger.
        var gesehen = folge.istGesehen
        let ruhig = bildhaken

        // **Kein Ladering je Folge mehr** (Mac f4dae47c): er war einer von
        // drei Wegen zum Laden und der schlechteste — bei fuenfundzwanzig
        // Folgen fuenfundzwanzig Mal dasselbe. Wer eine einzelne Folge will,
        // hakt sie in der Ladeauswahl an (Knopf „Laden" in der Knopfreihe).

        // **Nach dem Player frischt die Zeile sich selbst auf** — Balken,
        // Haken, Knopf und die Stelle, an der ein Klick startet. Vorher baute
        // `nachDemPlayerAuffrischen` die ganze Serienseite neu, und sie sprang
        // nach oben (bafc898). So bleiben Scrollstelle, Staffel und Fokus.
        var aktuell = folge
        var schwebt = false
        // **Der Tastaturfokus zählt wie der Zeiger.** Der Haken zum Umschalten
        // steht nur beim Überfahren da; wer mit Tab kommt, sähe ihn nie und
        // käme nicht an ihn heran.
        var fokussiert = false
        // Ein Name statt vier Bruchstücke: Nummer, Titel, und wie weit.
        func benennen() {
            let teile = [nummer + aktuell.name,
                         sehstandWort(gesehen: gesehen, anteil: aktuell.gesehenerAnteil)]
            bedienhilfe(zeile, name: teile.compactMap { $0 }.joined(separator: ", "),
                        gewaehlt: laeuft)
        }
        benennen()
        let marke = naechsteSehstandMarke()
        sehstandZeilen[folge.id] = (marke, { [weak self] neu in
            guard let self else { return }
            aktuell = neu
            for teil in balkenteile { gtk_overlay_remove_overlay(OpaquePointer(huelle), teil) }
            balkenteile = []
            if self.wahlen.fortschrittAufKacheln, !neu.istGesehen, let anteil = neu.gesehenerAnteil {
                balkenteile = balkenLegen(huelle, breite: 160, anteil: anteil)
            }
            gesehen = neu.istGesehen
            bildAbdunkeln(huelle, gesehen)
            gtk_widget_set_visible(ruhig, gesehen ? 1 : 0)
            if let feld = dauerfeld, let text = dauertext(neu) {
                gtk_label_set_text(OpaquePointer(feld), text)
            }
            benennen()
        })
        beiSignal(zeile, "destroy") { [weak self] in
            if self?.sehstandZeilen[folge.id]?.marke == marke { self?.sehstandZeilen[folge.id] = nil }
        }

        // Zeiger oder Fokus: dieselbe Hervorhebung, derselbe Haken.
        func vorneZeigen() {
            let vorn = schwebt || fokussiert
            if vorn { gtk_widget_add_css_class(zeile, "swiftly-schwebt") }
            else { gtk_widget_remove_css_class(zeile, "swiftly-schwebt") }
            blenden(kreis, auf: vorn ? 1 : 0, dauer: Stil.zeitSchweben)
        }
        // Der Ladeknopf bleibt stehen. Er wurde beim Verlassen versteckt — und
        // sobald seine Tafel aufging, verliess der Zeiger die Zeile, der
        // Knopf verschwand und nahm die Tafel mit. Das war „nichts passiert".
        beiZeiger(zeile, herein: { schwebt = true; vorneZeigen() },
                         hinaus: { schwebt = false; vorneZeigen() })
        beiFokus(zeile, herein: { fokussiert = true; vorneZeigen() },
                        hinaus: { fokussiert = false; vorneZeigen() })

        // **Eine Folge aus der Liste startet an ihrer eigenen Stelle** (A5) —
        // oder, in der Player-Folgenebene, wechselt der laufende Player zu ihr.
        beiKlick(zeile, tastatur: true) { [weak self] in
            if let aktion { aktion(aktuell) } else { self?.starte(aktuell) }
        }
        // **Das Kachelmenü an jeder Folge** (1.0.5, Apple `.kachelmenue(folge, …)`
        // in `SeriesView` und in der Folgenliste des Players): Rechtsklick,
        // langer Druck oder Menütaste. Auf der Serienseite dieselben Einträge
        // wie an einer Kachel — darunter „Gemeinsam schauen", das hier vorher
        // allein stand —, in der Folgenebene des Players nur der Sehstand.
        let bildadresse: URL? = adressen.flatMap { a in
            folge.imageTags?["Primary"].flatMap {
                a.bauen(itemID: folge.id, marke: $0, mass: .hoechstensHoch(220))
            }
        }
        let imPlayer = aktion != nil
        kachelmenueAnlegen(zeile) { [weak self] in
            Kachelmenueangabe(item: aktuell, quer: true, bild: bildadresse, imPlayer: imPlayer,
                              nachher: { neu in
                                  guard let self else { return }
                                  self.sehstandZeilen[neu.id]?.auffrischen(neu)
                                  // Der Hauptknopf der Serie zeigt danach vielleicht woandershin.
                                  self.kopfAuffrischen?.tun()
                              })
        }
        return zeile
    }

    // MARK: Besetzung und Ähnliches

    func besetzungsreihe(_ leute: [Person], herkunft: String? = nil,
                         rand: Int = Stil.randAbstand) -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 14)
        let titel = beschriftung(uebersetzt("Besetzung"), stil: "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(titel), 0)
        gtk_widget_set_margin_start(titel, Int32(rand))
        anhaengen(block, titel)

        let scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 18)
        gtk_widget_set_margin_start(reihe, Int32(rand))
        gtk_widget_set_margin_end(reihe, Int32(rand))
        for person in leute { anhaengen(reihe, kopfbild(person, herkunft: herkunft)) }
        gtk_scrolled_window_set_child(OpaquePointer(scroller), reihe)
        anhaengen(block, scroller)
        return block
    }

    /// Ein Kopf: 84 rund, darunter Name und Rolle.
    private func kopfbild(_ person: Person, herkunft: String?) -> Widget! {
        // **Ein Knopf, damit `:hover` greift.** GTK führt den Zustand nur auf
        // Bedienelementen; auf einer schlichten Box wüchse das Bild nie.
        // Dieselbe Hülle wie bei den Kacheln.
        let huelleKnopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(huelleKnopf, "swiftly-kachel")
        gtk_widget_set_valign(huelleKnopf, GTK_ALIGN_START)

        let kachel = stapel(GTK_ORIENTATION_VERTICAL, abstand: 7)
        gtk_widget_set_size_request(kachel, 84, -1)
        gtk_widget_set_valign(kachel, GTK_ALIGN_START)

        let (huelle, bild) = gerahmtesBild(breite: 84, hoehe: 84, stil: "swiftly-kopfbild")
        gtk_widget_add_css_class(huelle, "swiftly-plakat")
        anhaengen(kachel, huelle)
        if let adressen, let marke = person.primaryImageTag,
           let url = adressen.bauen(itemID: person.id, marke: marke,
                                    mass: .hoechstensHoch(200)) {
            bildLaden(bild, url: url, schluessel: Bildschluessel.fuer(url))
        } else {
            zeichenLegen(huelle, serie: false)
        }

        let name = beschriftung(person.name, stil: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(name), 1)
        anhaengen(kachel, name)

        if let rolle = person.role, !rolle.isEmpty {
            let r = beschriftung(rolle, stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(r, "swiftly-leise")
            gtk_label_set_xalign(OpaquePointer(r), 0)
            gtk_label_set_ellipsize(OpaquePointer(r), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(OpaquePointer(r), 1)
            anhaengen(kachel, r)
        }
        gtk_button_set_child(alsKnopf(huelleKnopf), kachel)
        // **Bis zum 12.09.2026 hing hier nichts.** Der Knopf war gebaut, hob
        // sich beim Überfahren und tat nichts — dieselbe Form, die auf tvOS
        // ein Tester gemeldet hat. Die Herkunft geht mit, damit die
        // Personenseite „Rolle in Titel" sagen kann.
        beiSignal(huelleKnopf, "clicked") { [weak self] in
            self?.oeffnePerson(person, herkunft: herkunft)
        }
        return huelleKnopf
    }

    /// **Auf der Serienseite ein Raster, auf der Filmseite eine Reihe.**
    ///
    /// Auf dem Mac ist das derselbe Unterschied (`SerienView.swift:390-411` gegen
    /// `DetailView`): unter einem Reiter, den man ausdrücklich gewählt hat,
    /// steht alles auf einmal da; eine Reihe, durch die man erst blättern
    /// muss, wäre dort ein Weg im Weg. Auf der Filmseite läuft „Ähnliches"
    /// dagegen unter dem übrigen Inhalt mit und darf nicht die halbe Seite
    /// nehmen.
    func aehnlicheNachladen(_ titel: Item, in raum: Widget!, leeren leeren_: Bool = false,
                            rand: Int = Stil.randAbstand, alsRaster: Bool = false) {
        guard let client else { return }
        let kiste = gehalten(raum)
        Task.detached { [self] in
            // **Mit dem Titel selbst als Vorlage** (`6e480f14`): liegt er in
            // zwei Bibliotheken, fiel sonst seine Kopie unter „Ähnliches".
            let geholt = try? await client.aehnliche(itemID: titel.id, zu: titel)
            nachDemSchub {
                defer { losgelassen(kiste) }
                self.aehnlicheZeigen(geholt, titel: titel, in: kiste.widget, leeren: leeren_,
                                     rand: rand, alsRaster: alsRaster)
            }
        }
    }

    /// Füllt den Platz mit einer Antwort — aus ``aehnlicheNachladen`` oder aus
    /// dem gemeinsamen Abruf der Serienseite (``serieNachladen``).
    func aehnlicheZeigen(_ geholt: [Item]?, titel: Item, in ziel: Widget!, leeren leeren_: Bool,
                         rand: Int = Stil.randAbstand, alsRaster: Bool) {
        // Doppelte Kennungen raus — dieselbe Regel wie in Suche und Startseite.
        let treffer = Listenregeln.ohneDoppelte(geholt ?? [])
        if leeren_ { leeren(ziel) }
        // Als Reiter steht dort sonst der ganze Inhalt — ein
        // gescheiterter Abruf sagt es (Mac 4fffc63c). Als Reihe auf
        // der Filmseite bleibt der Abschnitt einfach weg, wie dort.
        if geholt == nil, leeren_ {
            let kiste = Zeigerkiste(ziel)
            anhaengen(ziel, stoerhinweis { [weak self] in
                guard let self, let raum = kiste.widget else { return }
                self.aehnlicheNachladen(titel, in: raum, leeren: true,
                                        rand: rand, alsRaster: alsRaster)
            })
            return
        }
        guard !treffer.isEmpty else {
            if leeren_ {
                // Mittig, mit Zeichen — wie jeder andere Leerzustand.
                // Hier stand eine Textzeile oben links.
                //
                // **`mail-inbox-symbolic`, nicht `mail-archive`.**
                // Der Mac nimmt `tray` (`SerienView.swift:392`), und
                // den Ablagekorb hat unter Breeze nur der Posteingang;
                // `mail-archive-symbolic` gibt es dort gar nicht, GTK
                // zeigte dafuer das Ersatzbild mit rotem
                // Verbotszeichen. Am Bild gefunden.
                // `Leerhinweis`, wie auf dem Mac: ein leerer
                // Abschnitt innerhalb der Seite.
                anhaengen(ziel, self.leerhinweis(uebersetzt("Nichts Ähnliches gefunden")))
            }
            return
        }
        if alsRaster {
            let raster = self.rasterBauen()
            gtk_widget_set_margin_start(raster, Int32(rand))
            gtk_widget_set_margin_end(raster, Int32(rand))
            self.rasterFuellen(raster, treffer)
            anhaengen(ziel, raster)
        } else {
            anhaengen(ziel, self.reiheBauen(titel: uebersetzt("Ähnliches"), art: .neu,
                                            items: treffer, rand: rand))
            // Ein eigener Platz auf der Filmseite steht bis hier
            // unsichtbar, damit er keinen Abstand mitbringt.
            gtk_widget_set_visible(ziel, 1)
        }
    }
}


/// Welche Staffel gewählt ist. Wie ``Spielziel`` eine Klasse, damit Tafel und
/// Pille denselben Wert sehen; angefasst wird sie nur auf GTKs Hauptfaden.
final class Staffelwahl: @unchecked Sendable {
    var jetzt: Item?
}
