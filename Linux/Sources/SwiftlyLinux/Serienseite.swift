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
        case folgen, besetzung, aehnliches
        var beschriftung: String {
            switch self {
            case .folgen:     uebersetzt("Folgen")
            case .besetzung:  uebersetzt("Besetzung")
            case .aehnliches: uebersetzt("Ähnliches")
            }
        }
    }

    func serienunterbau(_ serie: Item, in unten: Widget!) {
        let reiterraum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        // **Kein Rand am Reiterinhalt.** Sonst reicht die Hervorhebung einer
        // Folgenzeile nur bis 24 vor die Kante — auf dem Mac läuft sie über
        // die ganze Breite. Den Rand tragen die Zeilen selbst, als
        // Innenabstand, damit ihr Grund darunter durchläuft.
        let inhaltraum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 18)

        var gewaehlt: Reiter = .folgen
        var reiterknoepfe: [Widget?] = []

        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 26)
        gtk_widget_set_margin_start(zeile, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(zeile, Int32(Stil.randAbstand))
        for fall in Reiter.allCases {
            let knopf = reiterknopf(fall.beschriftung, aktiv: fall == gewaehlt)
            reiterknoepfe.append(knopf)
            beiSignal(knopf, "clicked") { [weak self] in
                guard let self else { return }
                gewaehlt = fall
                for (i, f) in Reiter.allCases.enumerated() {
                    guard let k = reiterknoepfe[i] else { continue }
                    if f == fall { gtk_widget_add_css_class(k, "swiftly-aktiv") }
                    else { gtk_widget_remove_css_class(k, "swiftly-aktiv") }
                }
                self.reiterInhalt(fall, serie: serie, in: inhaltraum)
            }
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
        anhaengen(unten, inhaltraum)
        reiterInhalt(.folgen, serie: serie, in: inhaltraum)
    }

    private func reiterInhalt(_ was: Reiter, serie: Item, in raum: Widget!) {
        leeren(raum)
        switch was {
        case .folgen:
            // **Kein Ladering und kein „Lade …"** (E17), sondern drei
            // Folgenzeilen in ihrer Form.
            anhaengen(raum, folgenPlatzhalter(rand: Stil.randAbstand))
            staffelnLaden(serie, in: raum)
        case .besetzung:
            if serie.darsteller.isEmpty {
                let leer = beschriftung(uebersetzt("Keine Besetzung hinterlegt."), stil: "swiftly-koerper")
                gtk_widget_set_margin_start(leer, Int32(Stil.randAbstand))
                anhaengen(raum, leer)
            } else {
                anhaengen(raum, besetzungsreihe(serie.darsteller, herkunft: serie.name))
            }
        case .aehnliches:
            anhaengen(raum, rasterPlatzhalter(rand: Stil.randAbstand))
            aehnlicheNachladen(serie, in: raum, leeren: true, alsRaster: true)
        }
    }

    // MARK: Staffeln und Folgen

    private func staffelnLaden(_ serie: Item, in raum: Widget!) {
        guard let client else { return }
        let id = startStaffel
        let nummer = startStaffelNummer
        // **Der Stand nur, wenn kein Hinweis kam** (A10). Ein Abruf, den
        // niemand liest, kostet auf jeder Serienseite eine Anfrage.
        let brauchtStand = Staffelwahlregel.brauchtStand(hinweisID: id, hinweisNummer: nummer)

        // **Schon geholt heisst: sofort da.** Kein Lader, kein Sprung.
        if let schon = staffelspeicher[serie.id], !schon.isEmpty, !brauchtStand {
            staffelnZeigen(schon, serie: serie, in: raum,
                           gewaehlt: Staffelwahlregel.waehle(aus: schon, hinweisID: id,
                                                             hinweisNummer: nummer))
            return
        }
        let kiste = gehalten(raum)
        Task.detached { [self] in
            // Beides nebenher: der Stand haengt nicht an den Staffeln.
            async let staffelnRoh = try? await client.staffeln(seriesID: serie.id)
            async let standRoh = brauchtStand ? await client.standInSerie(serie.id) : nil
            let staffeln = await staffelnRoh ?? []
            let stand = await standRoh
            let gewaehlt = Staffelwahlregel.waehle(aus: staffeln, hinweisID: id,
                                                   hinweisNummer: nummer, stand: stand)
            aufHauptfaden {
                defer { losgelassen(kiste) }
                self.staffelspeicher[serie.id] = staffeln
                self.staffelnZeigen(staffeln, serie: serie, in: kiste.widget,
                                    gewaehlt: gewaehlt)
            }
        }
    }

    private func staffelnZeigen(_ staffeln: [Item], serie: Item, in raum: Widget!,
                                gewaehlt: Item?) {
        leeren(raum)
        guard !staffeln.isEmpty else {
            anhaengen(raum, beschriftung(uebersetzt("Keine Staffeln gefunden."), stil: "swiftly-koerper"))
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
        let pillenwinkel: Widget! = gtk_image_new_from_icon_name("go-down-symbolic")
        anhaengen(pilleninhalt, pillentext)
        anhaengen(pilleninhalt, pillenwinkel)
        gtk_button_set_child(alsKnopf(pille), pilleninhalt)
        // Nur bei mehr als einer Staffel ist eine Wahl zu treffen.
        // **Bei einer Staffel gibt es nichts zu waehlen.** Der Mac blendet
        // die Pille dann ganz aus; ausgegraut stehen zu lassen sieht aus wie
        // ein Knopf, der klemmt.
        gtk_widget_set_visible(pille, staffeln.count > 1 ? 1 : 0)

        let folgenraum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)

        // **Einmal angelegt, nicht bei jedem Klick.** Vorher entstand hier je
        // Klick eine neue Tafel, die am Knopf hängenblieb; beim Verlassen der
        // Seite meldete GTK „Finalizing GtkButton, but it still has children
        // left" und ließ einen Zeiger stehen. Genau daran ist die App beim
        // Öffnen einer Serie gestorben.
        let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(liste, 200, -1)
        let tafel = tafelAn(pille)
        gtk_popover_set_child(alsTafel(tafel), liste)

        // **Eine Tafel, kein aufklappender Kasten in der Seite.** Auf dem Mac
        // erscheint die Staffelliste als Blatt über der Pille — dieselbe
        // Form wie beim Mehr-Knopf, und dieselbe Regel: kleine
        // Entscheidungen erscheinen dort, wo sie ausgelöst wurden (E5). Mein
        // erster Versuch schob sie als Liste in den Seitenfluss und verschob
        // dabei alles darunter.
        beiSignal(pille, "clicked") { [weak self] in
            guard let self else { return }
            leeren(liste)
            for staffel in staffeln {
                let gewaehlt = staffel.id == wahl.jetzt?.id
                anhaengen(liste, self.staffelzeile(staffel.name, gewaehlt: gewaehlt) {
                    [weak self] in
                    wahl.jetzt = staffel
                    self?.offeneStaffel = staffel
                    self?.detailBeruehrt = true
                    gtk_label_set_text(OpaquePointer(pillentext), staffel.name)
                    gtk_popover_popdown(alsTafel(tafel))
                    self?.folgenLaden(serie: serie, staffel: staffel, in: folgenraum)
                })
            }
            gtk_image_set_from_icon_name(OpaquePointer(pillenwinkel), "go-up-symbolic")
            gtk_popover_popup(alsTafel(tafel))
        }
        beiSignal(tafel, "closed") {
            gtk_image_set_from_icon_name(OpaquePointer(pillenwinkel), "go-down-symbolic")
        }

        gtk_widget_set_margin_start(pille, Int32(Stil.randAbstand))
        anhaengen(raum, pille)
        anhaengen(raum, folgenraum)
        if let jetzt = wahl.jetzt {
            folgenLaden(serie: serie, staffel: jetzt, in: folgenraum)
        }
    }

    /// Eine Zeile in der Staffeltafel — Name links, Haken bei der gewählten.
    private func staffelzeile(_ text: String, gewaehlt: Bool,
                              _ auswahl: @escaping () -> Void) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-handlung")
        if gewaehlt { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        let l = beschriftung(text, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
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

    private func folgenLaden(serie: Item, staffel: Item, in raum: Widget!) {
        guard let client else { return }
        if let schon = folgenspeicher[staffel.id] {
            folgenZeigen(schon, in: raum)
            return
        }
        leeren(raum)
        anhaengen(raum, folgenPlatzhalter(rand: Stil.randAbstand))
        let kiste = gehalten(raum)
        Task.detached { [self] in
            let folgen = (try? await client.folgen(seriesID: serie.id,
                                                   seasonID: staffel.id)) ?? []
            nachDemSchub {
                defer { losgelassen(kiste) }
                self.folgenspeicher[staffel.id] = folgen
                self.folgenZeigen(folgen, in: kiste.widget)
            }
        }
    }

    /// Zeigt eine Folgenliste — aus dem Netz oder aus dem Speicher.
    private func folgenZeigen(_ folgen: [Item], in raum: Widget!) {
        leeren(raum)
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
        for folge in folgen { anhaengen(raum, folgenzeile(folge)) }
    }

    /// Eine Folge in der Liste. Bild 160 × 90 (16 : 9), 18 Abstand, darunter
    /// Kopfzeile mit Laufzeit rechts und zwei Zeilen Beschreibung.
    ///
    /// **Das Bild der Folge, nicht das der Serie.** `Bildwahl.quer` nimmt
    /// absichtlich den Hintergrund der Serie — richtig für „Weiterschauen",
    /// falsch hier: in einer Folgenliste stünde in jeder Zeile dasselbe Bild.
    private func folgenzeile(_ folge: Item) -> Widget! {
        // **Kein Knopf, eine Geste.** Die Zeile trägt selbst einen Knopf —
        // den Haken zum Umschalten —, und ein Knopf im Knopf ist in GTK kein
        // sicherer Bau. Auf dem Mac steht dort aus demselben Grund
        // `.onTapGesture`.
        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 18)
        gtk_widget_add_css_class(zeile, "swiftly-folgenzeile")

        let (huelle, bild) = gerahmtesBild(breite: 160, hoehe: 90, stil: "swiftly-plakat")
        gtk_widget_set_valign(huelle, GTK_ALIGN_START)
        if let adressen, let marke = folge.imageTags?["Primary"],
           let url = adressen.bauen(itemID: folge.id, marke: marke,
                                    mass: .hoechstensHoch(220)) {
            bildLaden(bild, url: url, schluessel: url.absoluteString)
        } else {
            zeichenLegen(huelle, serie: true)
        }
        if wahlen.fortschrittAufKacheln, let anteil = folge.gesehenerAnteil {
            balkenLegen(huelle, breite: 160, anteil: anteil)
        }
        // **Ein Abspielzeichen über dem Bild, wenn der Zeiger da ist** — der
        // Mac hat es (`SerienView.swift:443`). Ohne es sieht ein Standbild
        // nicht danach aus, als ließe es sich anklicken.
        let kreis: Widget! = gtk_image_new_from_icon_name("media-playback-start-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(kreis), 16)
        gtk_widget_add_css_class(kreis, "swiftly-spielkreis")
        gtk_widget_set_halign(kreis, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(kreis, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(kreis, 0)
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
        if let sekunden = folge.runtimeSeconds, sekunden > 0 {
            let dauer = beschriftung(laufzeit(sekunden), stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(dauer, "swiftly-leise")
            anhaengen(kopf, dauer)
        }
        anhaengen(text, kopf)

        if let inhalt = folge.overview, !inhalt.isEmpty {
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

        // **Der Haken steht immer, wenn die Folge gesehen ist** — auf iPhone
        // und Mac genauso. Er ist die einzige Auskunft darüber in der Liste;
        // ohne ihn sieht eine durchgesehene Staffel aus wie eine
        // unangetastete. **Zum Ändern** braucht es den Zeiger, zum Sehen
        // nicht: beim Schweben tritt an seine Stelle ein runder Knopf.
        var gesehen = folge.istGesehen
        let platz = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        gtk_widget_set_size_request(platz, 40, -1)
        gtk_widget_set_halign(platz, GTK_ALIGN_END)
        gtk_widget_set_valign(platz, GTK_ALIGN_START)
        gtk_widget_set_margin_top(platz, 2)

        let ruhig: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(ruhig), 12)
        gtk_widget_add_css_class(ruhig, "swiftly-leise")
        gtk_widget_set_halign(ruhig, GTK_ALIGN_END)
        gtk_widget_set_hexpand(ruhig, 1)
        gtk_widget_set_visible(ruhig, gesehen ? 1 : 0)
        anhaengen(platz, ruhig)

        let knopf = nebenknopf("object-select-symbolic", aktiv: gesehen)
        gtk_widget_add_css_class(knopf, "swiftly-hakenknopf")
        gtk_widget_set_size_request(knopf, 34, 34)
        gtk_widget_set_visible(knopf, 0)
        beiSignal(knopf, "clicked") { [weak self] in
            guard let self, let client = self.client else { return }
            gesehen.toggle()
            knopfzustand(knopf, aktiv: gesehen, symbol: "object-select-symbolic")
            gtk_widget_set_visible(ruhig, gesehen ? 1 : 0)
            let neu = gesehen
            // **Der Zustand des Knopfes ist die Antwort** (D6) — aber nur,
            // solange sie stimmt. Lehnt der Server ab, geht der Haken zurück
            // und sagt warum; auf dem Mac genauso.
            // Zeiger über eine Fadengrenze gehen in die Kiste — dieselbe
            // Zusicherung wie überall hier.
            let knopfkiste = gehalten(knopf)
            let hakenkiste = gehalten(ruhig)
            Task.detached { [self] in
                do {
                    try await client.setzeGesehen(itemID: folge.id, an: neu)
                    // Der gemerkte Stand dieser Staffel ist ab jetzt falsch.
                    aufHauptfaden { self.sehstandVergessen(folge) }
                }
                catch {
                    aufHauptfaden {
                        knopfzustand(knopfkiste.widget, aktiv: !neu,
                                     symbol: "object-select-symbolic")
                        gtk_widget_set_visible(hakenkiste.widget, !neu ? 1 : 0)
                        self.melden(lesbarerFehler(error))
                    }
                }
                aufHauptfaden { losgelassen(knopfkiste); losgelassen(hakenkiste) }
            }
        }
        anhaengen(platz, knopf)
        anhaengen(zeile, platz)

        // **H1 und „Download je Folge".** Auf dem Mac steht neben dem
        // Gesehen-Knopf ein Downloadring je Folge, sobald Downloads an sind
        // — und der Grund steht in der Aenderungsliste: eine Anime-Staffel
        // hat ueber hundert Folgen, und eine ganze Staffel zu laden ist
        // selten das, was gemeint war. Hier fehlte er ganz; die Serienseite
        // hatte gar keinen Ladeknopf, weil der in der Knopfreihe nur bei
        // Filmen steht.
        var ladeknopf: Widget!
        if downloadsAn {
            ladeknopf = nebenknopf(ladeknopfsymbol(downloads.posten(fuer: folge.id)),
                                   name: uebersetzt("Laden"),
                                   aktiv: downloads.posten(fuer: folge.id)?.stand == .fertig)
            gtk_widget_set_size_request(ladeknopf, 34, 34)
            gtk_widget_set_valign(ladeknopf, GTK_ALIGN_START)
            gtk_widget_set_margin_top(ladeknopf, 2)
            gtk_widget_set_visible(ladeknopf, 0)
            beiSignal(ladeknopf, "clicked") { [weak self] in
                self?.ladetafelZeigen(folge, an: ladeknopf)
            }
            anhaengen(zeile, ladeknopf)
        }

        beiZeiger(zeile, herein: {
            if ladeknopf != nil { gtk_widget_set_visible(ladeknopf, 1) }
            gtk_widget_add_css_class(zeile, "swiftly-schwebt")
            gtk_widget_set_visible(knopf, 1)
            gtk_widget_set_visible(ruhig, 0)
            gtk_widget_set_visible(kreis, 1)
        }, hinaus: {
            if ladeknopf != nil { gtk_widget_set_visible(ladeknopf, 0) }
            gtk_widget_remove_css_class(zeile, "swiftly-schwebt")
            gtk_widget_set_visible(knopf, 0)
            gtk_widget_set_visible(ruhig, gesehen ? 1 : 0)
            gtk_widget_set_visible(kreis, 0)
        })

        // **Eine Folge aus der Liste startet an ihrer eigenen Stelle** (A5).
        beiKlick(zeile) { [weak self] in self?.starte(folge) }
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
            bildLaden(bild, url: url, schluessel: url.absoluteString)
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
    /// Auf dem Mac ist das derselbe Unterschied (`SerienView.swift:236` gegen
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
            let treffer = (try? await client.aehnliche(itemID: titel.id)) ?? []
            nachDemSchub {
                defer { losgelassen(kiste) }
                let ziel = kiste.widget
                if leeren_ { leeren(ziel) }
                guard !treffer.isEmpty else {
                    if leeren_ {
                        anhaengen(ziel, beschriftung(uebersetzt("Nichts Ähnliches gefunden."),
                                                     stil: "swiftly-koerper"))
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
                }
            }
        }
    }
}


/// Welche Staffel gewählt ist. Wie ``Spielziel`` eine Klasse, damit Tafel und
/// Pille denselben Wert sehen; angefasst wird sie nur auf GTKs Hauptfaden.
final class Staffelwahl: @unchecked Sendable {
    var jetzt: Item?
}
