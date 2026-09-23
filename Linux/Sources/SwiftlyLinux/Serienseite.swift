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
        // kurz und kommt wieder. Genau das hat Paul zweimal gemeldet.
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

        var gebaut: Set<String> = []
        let zeigen: (Reiter) -> Void = { [weak self] fall in
            guard let self else { return }
            gewaehlt = fall
            for (i, f) in Reiter.allCases.enumerated() {
                guard let k = reiterknoepfe[i] else { continue }
                if f == fall { gtk_widget_add_css_class(k, "swiftly-aktiv") }
                else { gtk_widget_remove_css_class(k, "swiftly-aktiv") }
            }
            let name = String(describing: fall)
            if !gebaut.contains(name) {
                gebaut.insert(name)
                let raum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 18)
                gtk_stack_add_named(alsStapel(reiterstapel), raum, name)
                self.reiterInhalt(fall, serie: serie, in: raum)
            }
            gtk_stack_set_visible_child_name(alsStapel(reiterstapel), name)
        }
        reiterZeigen = zeigen
        zeigen(.folgen)
        // Damit das Fernsteuerpult den Reiter wechseln kann, ohne zu klicken.
        reiterWaehlen = zeigen
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
            // **`nil` heisst gestoert, `[]` wirklich leer** (a2bb95bd) — und
            // ein gescheiterter Abruf wird nicht gemerkt (4fffc63c).
            let geholt = await staffelnRoh
            let staffeln = geholt ?? []
            let stand = await standRoh
            let gewaehlt = Staffelwahlregel.waehle(aus: staffeln, hinweisID: id,
                                                   hinweisNummer: nummer, stand: stand)
            aufHauptfaden {
                defer { losgelassen(kiste) }
                guard geholt != nil else {
                    leeren(kiste.widget)
                    anhaengen(kiste.widget, self.stoerhinweis { [weak self] in
                        guard let self, let raum = kiste.widget else { return }
                        leeren(raum)
                        anhaengen(raum, folgenPlatzhalter(rand: Stil.randAbstand))
                        self.staffelnLaden(serie, in: raum)
                    })
                    return
                }
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
        gtk_widget_set_margin_bottom(wahlblock, 18)
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
        // Knopf → Reihe → (Beschriftung, Haken). Der Haken ist das letzte Kind.
        guard let reihe = gtk_button_get_child(alsKnopf(zeile)),
              let haken = gtk_widget_get_last_child(reihe) else { return }
        gtk_widget_set_visible(haken, gewaehlt ? 1 : 0)
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
        for folge in folgen { anhaengen(raum, folgenzeile(folge)) }
    }

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
        // Gesehenes tritt zurueck, es verschwindet nicht: 0,45 wie auf dem Mac.
        gtk_widget_set_opacity(huelle, folge.istGesehen ? 0.45 : 1)

        let bildhaken: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(bildhaken), 10)
        gtk_widget_add_css_class(bildhaken, "swiftly-folgenhaken")
        gtk_widget_set_halign(bildhaken, GTK_ALIGN_END)
        gtk_widget_set_valign(bildhaken, GTK_ALIGN_START)
        gtk_widget_set_visible(bildhaken, folge.istGesehen ? 1 : 0)
        gtk_overlay_add_overlay(OpaquePointer(huelle), bildhaken)
        // **Ein Abspielzeichen über dem Bild, wenn der Zeiger da ist** — der
        // Mac hat es (`SerienView.swift:665-674`). Ohne es sieht ein Standbild
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

        // **Der stille Haken steht jetzt auf dem Bild, nicht hier.** Diese
        // Spalte traegt nur noch den Umschaltknopf, der beim Schweben kommt.
        let ruhig = bildhaken

        let knopf = nebenknopf("object-select-symbolic", aktiv: gesehen)
        gtk_widget_add_css_class(knopf, "swiftly-hakenknopf")
        gtk_widget_set_size_request(knopf, 34, 34)
        gtk_widget_set_visible(knopf, 0)
        beiSignal(knopf, "clicked") { [weak self] in
            guard let self, let client = self.client else { return }
            gesehen.toggle()
            knopfzustand(knopf, aktiv: gesehen, symbol: "object-select-symbolic")
            gtk_widget_set_visible(ruhig, gesehen ? 1 : 0)
            // Das Bild tritt mit zurueck — dieselbe Auskunft, dieselbe Stelle.
            gtk_widget_set_opacity(huelle, gesehen ? 0.45 : 1)
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
            gtk_widget_set_opacity(huelle, gesehen ? 0.45 : 1)
            knopfzustand(knopf, aktiv: gesehen, symbol: "object-select-symbolic")
            gtk_widget_set_visible(ruhig, !schwebt && gesehen ? 1 : 0)
        })
        beiSignal(zeile, "destroy") { [weak self] in
            if self?.sehstandZeilen[folge.id]?.marke == marke { self?.sehstandZeilen[folge.id] = nil }
        }

        beiZeiger(zeile, herein: {
            schwebt = true
            gtk_widget_add_css_class(zeile, "swiftly-schwebt")
            gtk_widget_set_visible(knopf, 1)
            gtk_widget_set_visible(ruhig, 0)
            gtk_widget_set_visible(kreis, 1)
        }, hinaus: {
            // Der Ladeknopf bleibt stehen. Er wurde hier versteckt — und
            // sobald seine Tafel aufging, verliess der Zeiger die Zeile, der
            // Knopf verschwand und nahm die Tafel mit. Das war „nichts passiert".
            schwebt = false
            gtk_widget_remove_css_class(zeile, "swiftly-schwebt")
            gtk_widget_set_visible(knopf, 0)
            gtk_widget_set_visible(ruhig, gesehen ? 1 : 0)
            gtk_widget_set_visible(kreis, 0)
        })

        // **Eine Folge aus der Liste startet an ihrer eigenen Stelle** (A5) —
        // oder, in der Player-Folgenebene, wechselt der laufende Player zu ihr.
        beiKlick(zeile) { [weak self] in
            if let aktion { aktion(aktuell) } else { self?.starte(aktuell) }
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
            let geholt = try? await client.aehnliche(itemID: titel.id)
            let treffer = geholt ?? []
            nachDemSchub {
                defer { losgelassen(kiste) }
                let ziel = kiste.widget
                if leeren_ { leeren(ziel) }
                // Als Reiter steht dort sonst der ganze Inhalt — ein
                // gescheiterter Abruf sagt es (Mac 4fffc63c). Als Reihe auf
                // der Filmseite bleibt der Abschnitt einfach weg, wie dort.
                if geholt == nil, leeren_ {
                    anhaengen(ziel, self.stoerhinweis { [weak self] in
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
    }
}


/// Welche Staffel gewählt ist. Wie ``Spielziel`` eine Klasse, damit Tafel und
/// Pille denselben Wert sehen; angefasst wird sie nur auf GTKs Hauptfaden.
final class Staffelwahl: @unchecked Sendable {
    var jetzt: Item?
}
