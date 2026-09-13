import CGtk
import Foundation
import JellyfinKit

/// **Eine Person: wer das ist, und was es mit ihr gibt.**
///
/// Übernommen von `Sources/Shared/PersonView.swift`. Ein Klick auf einen
/// Darsteller führte hier nirgends hin — schlimmer: die Besetzungsreihe baute
/// einen `gtk_button_new()` ohne angeschlossenes Signal, also einen Knopf, der
/// sich beim Überfahren hebt und nichts tut. Genau die Form, vor der CLAUDE.md
/// warnt, und auf tvOS war es derselbe Fehler.
///
/// **Der Aufbau folgt der Detailseite**, weil eine Person hier dasselbe
/// Versprechen einlöst: oben ein Banner, darin unten links Bild und Name,
/// darunter die Rolle, über die man kam, und die Biografie. Dann zwei Reihen —
/// was auf dem Server liegt, und mit Seerr, was sich anfragen lässt.
///
/// **Was sie *nicht* hat:** Hauptknopf, Aktionsreihe, Dateiauszug. Eine Person
/// spielt man nicht ab. Deshalb steht die Weiche in ``detailZeigen(_:schub:)``
/// und nicht beim Aufrufer — jeder Weg auf eine Person soll dieselbe Seite
/// ergeben.
extension App {

    // MARK: - Hinein

    /// Öffnet eine Person, die auf einer Besetzungsreihe angetippt wurde.
    ///
    /// **Erst holen, dann schieben.** Der `Person`-Eintrag einer Besetzung
    /// trägt nur Name, Rolle und Bildmarke — Geburtsdatum, Ort und Biografie
    /// liegen am Item derselben Kennung. Die Seite entsteht deshalb aus dem
    /// geholten Item; kommt keins, entsteht sie aus dem, was die Kachel
    /// hergibt, statt gar nicht. Ein Klick, der nichts tut, war der Zustand
    /// vorher.
    func oeffnePerson(_ person: Person, herkunft: String?) {
        personRolle = person.role
        personHerkunft = herkunft
        guard let client else { return }
        Task.detached { [self] in
            let voll = try? await client.item(id: person.id)
            aufHauptfaden {
                let ziel = voll ?? Item(id: person.id, name: person.name, type: "Person")
                self.seitenstapel[self.bereich, default: []].append(ziel)
                self.detailZeigen(ziel)
            }
        }
    }

    // MARK: - Aufbau

    func personseiteZeigen(_ person: Item, schub: Schub) {
        detailBeruehrt = false
        abschnitte = []
        let scheibe = naechsteScheibe()

        let seite = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(seite, "swiftly-seitenton")

        let scroller = seitenscroller()
        gtk_scrolled_window_set_child(OpaquePointer(scroller), seite)

        let ueber: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(ueber), scroller)
        gtk_overlay_add_overlay(OpaquePointer(ueber), detailkopfBauen(person))
        anhaengen(detailhuelle, ueber)

        anhaengen(seite, personkopf(person))

        let unten = stapel(GTK_ORIENTATION_VERTICAL, abstand: 26)
        gtk_widget_set_margin_top(unten, 26)
        gtk_widget_set_margin_bottom(unten, Int32(Stil.randAbstand))
        anhaengen(seite, unten)

        // **Die Rolle wartet auf nichts** — sie kam mit dem Tipp.
        if let rolle = personRolle, !rolle.isEmpty, let herkunft = personHerkunft {
            let zeile = beschriftung(String(format: uebersetzt("%1$@ in %2$@"), rolle, herkunft),
                                     stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(zeile, "swiftly-rolle")
            gtk_label_set_xalign(OpaquePointer(zeile), 0)
            gtk_widget_set_margin_start(zeile, Int32(Stil.randAbstand))
            gtk_widget_set_margin_end(zeile, Int32(Stil.randAbstand))
            anhaengen(unten, zeile)
        }

        if let text = person.beschreibung, !text.isEmpty {
            anhaengen(unten, biografie(text))
        }

        // Die Reihen kommen nach; bis dahin steht der Raum leer da. **Kein
        // Ladering** (E17) — die Seite ist nicht am Warten, sie ist noch leer.
        let reihenraum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 26)
        anhaengen(unten, reihenraum)
        personReihenNachladen(person, in: reihenraum)

        // Den Titel oben einblenden — dieselbe Strecke wie auf der Detailseite.
        let senkrecht = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))!
        beiSignalRoh(UnsafeMutableRawPointer(senkrecht), "value-changed") { [weak self] in
            guard let self, let kopf = self.detailkopfTitel else { return }
            let v = gtk_adjustment_get_value(senkrecht)
            let staerke = min(max((v - 74) / 42, 0), 1)
            gtk_widget_set_opacity(kopf, staerke)
            if let leiste = self.detailkopfLeiste { gtk_widget_set_opacity(leiste, staerke) }
            if let verlauf = self.detailkopfVerlauf {
                gtk_widget_set_opacity(verlauf, 1 - staerke)
            }
        }

        schieben(zu: scheibe, richtung: schub)
    }

    // MARK: - Kopf

    /// Banner mit rundem Kopf, Name, Geburtstag und Ort.
    ///
    /// **Rund, weil es ein Bild ist** (E26) — wie die Kacheln der Besetzung,
    /// aus denen man kommt. Das iPad zeigte als einziges ein eckiges Plakat,
    /// weil es `Heldkopf` der Detailseiten benutzte; das war der Ausreißer,
    /// nicht die Regel.
    private func personkopf(_ person: Item) -> Widget! {
        let kopf: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(kopf, 1)

        // **Kuerzer als eine Detailseite.** Dort traegt die Kopfzone 230 Punkt
        // Block (Titel, Angaben, Beschreibung, Knopfreihe); hier stehen nur
        // ein 104er Kopf und zwei Zeilen. Dieselbe Hoehe waere ein Loch.
        let kulisse = Kulisse(hoehe: Stil.personHoehe)
        kulisse.vollBreit = true
        gtk_overlay_set_child(OpaquePointer(kopf), kulisse.anzeige)
        gtk_overlay_add_overlay(OpaquePointer(kopf), personblock(person))
        personBannerNachladen(person, in: kulisse)
        return kopf
    }

    /// **Feste Stellen statt fester Höhen** — dieselbe Überlegung wie bei
    /// ``heldenblock(_:)``. Was zu groß wird, wird abgeschnitten und
    /// verschiebt nichts.
    ///
    /// **Die Zahlen kommen aus `PersonView.swift:149-176`,** nicht aus dem
    /// Augenmass: runder Kopf 88, 16 Abstand, daneben ein Textblock, der
    /// **unten** buendig steht (`HStack(alignment: .bottom)`). Name 34 mit
    /// 6 darunter, dann die beiden 14er Zeilen mit 1 dazwischen — zusammen
    /// 82, also beginnt der Text 6 unter der Oberkante des Kopfes.
    ///
    ///     0    Kopfbild 88 rund, daneben ab 104:
    ///     6    Name         41
    ///     53   Geboren      17
    ///     71   Ort          17
    private func personblock(_ person: Item) -> Widget! {
        let feld: Widget! = gtk_fixed_new()
        gtk_widget_set_halign(feld, GTK_ALIGN_START)
        gtk_widget_set_valign(feld, GTK_ALIGN_END)
        gtk_widget_set_size_request(feld, 720, Int32(Stil.personblockHoehe))
        gtk_widget_set_margin_start(feld, Int32(Stil.randAbstand))
        // 22 wie `PersonView.swift:143`.
        gtk_widget_set_margin_bottom(feld, 22)

        // **Mit Initiale, wenn es kein Bild gibt.** `gerahmtesBild` laesst in
        // dem Fall einen leeren Kreis stehen; `profilzeichen` traegt den
        // Anfangsbuchstaben, so wie ueberall sonst in der App.
        let teile = profilzeichen(name: person.name, kante: Stil.personblockHoehe,
                                  stil: "swiftly-personkopf",
                                  schriftstil: "swiftly-zeichen96")
        gtk_fixed_put(alsFeld2(feld), teile.huelle, 0, 0)
        if let adressen, let url = adressen.bauen(itemID: person.id,
                                                  mass: .hoechstensHoch(300)) {
            profilbildLaden(teile, url: url, schluessel: Bildschluessel.fuer(url))
        }

        let name = beschriftung(person.name, stil: "swiftly-heldtitel")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_widget_set_size_request(name, 560, 41)
        gtk_fixed_put(alsFeld2(feld), name, 104, 6)

        // **Die zwei Zeilen haben ihren Platz von Anfang an.** Kämen sie erst
        // beim Laden dazu, schöben sie den Namen nach oben — mitten im
        // Hereinfahren. Hier stehen sie auf festen Stellen, also verschiebt
        // sich nichts, auch wenn eine leer bleibt.
        if let geboren = geburtszeile(person) {
            // 14 und `schriftLeise` — `Sources/macOS/PersonView.swift:169`.
            // Hier standen 12 (`swiftly-zweitzeile`) und `schriftSehrLeise`.
            let z = beschriftung(geboren, stil: "swiftly-angaben")
            gtk_widget_add_css_class(z, "dim-label")
            gtk_label_set_xalign(OpaquePointer(z), 0)
            gtk_widget_set_size_request(z, 520, 17)
            gtk_fixed_put(alsFeld2(feld), z, 104, 53)
        }
        if let ort = person.productionLocations?.first, !ort.isEmpty {
            let z = beschriftung(ort, stil: "swiftly-angaben")
            gtk_widget_add_css_class(z, "dim-label")
            gtk_label_set_xalign(OpaquePointer(z), 0)
            gtk_label_set_ellipsize(OpaquePointer(z), PANGO_ELLIPSIZE_END)
            gtk_widget_set_size_request(z, 520, 17)
            gtk_fixed_put(alsFeld2(feld), z, 104, 71)
        }
        return feld
    }

    /// **Serverdaten laufen nie durch die Übersetzung** (E7) — das Datum wird
    /// deshalb über die Landeseinstellung geformt, nicht über den Katalog.
    private func geburtszeile(_ person: Item) -> String? {
        guard let teile = person.tagesdatum,
              let datum = Calendar.current.date(from: teile) else { return nil }
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return String(format: uebersetzt("Geboren %@"), f.string(from: datum))
    }

    /// Das Banner zeigt einen Hintergrund aus den Titeln dieser Person.
    ///
    /// **Nur ein Bild, kein Wechsel.** Auf Apple wechselt es alle sechs
    /// Sekunden zwischen den Hintergründen. Hier steht bewusst das erste
    /// still: der Wechsel braucht einen Takt, der beim Verlassen der Seite
    /// sauber endet, und ein Takt, der auf ein abgeräumtes GTK-Objekt zeigt,
    /// ist ein Absturz. Das kommt nach, wenn der Rest steht — als eigener
    /// Schritt, nicht nebenbei.
    private func personBannerNachladen(_ person: Item, in kulisse: Kulisse) {
        guard let client, let adressen else { return }
        Task.detached { [self] in
            let titel = await client.titel(person: person.id)
            guard let erster = titel.first else { return }
            // **Nur echte Querbilder — und wenn keiner eines hat, der
            // Ersatz.** Hat der erste Titel keinen Hintergrund, blieb die
            // Kulisse hier leer, und der runde Kopf sass unten in 380 Punkt
            // Dunkelheit. Genau der „viel zu tiefe" Kopf, den Paul gemeldet
            // hat; auf Apple faengt `kopfbildURL` denselben Fall ab
            // (`PersonView.swift:245`).
            var gross = Bildwahl.quer(erster, adressen: adressen, breite: 1600)?.url
            if gross == nil {
                gross = await client.kopfbildErsatz(fuer: erster, adressen: adressen,
                                                    breite: 1600)
            }
            guard let gross,
                  let daten = await Bildlager.shared.laden(gross,
                                                           schluessel: Bildschluessel.fuer(gross))
            else { return }
            aufHauptfaden { kulisse.setzen(daten) }
        }
    }

    /// Vier Zeilen, dann „Mehr". Eine Biografie ist hier Auskunft, nicht der
    /// Grund, die Seite zu öffnen — sie soll die Titel nicht nach unten
    /// schieben, bevor man sie will.
    private func biografie(_ text: String) -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 6)
        gtk_widget_set_margin_start(block, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(block, Int32(Stil.randAbstand))

        let feld = beschriftung(text, stil: "swiftly-beschreibung", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(feld), 0)
        gtk_label_set_lines(OpaquePointer(feld), 4)
        gtk_label_set_ellipsize(OpaquePointer(feld), PANGO_ELLIPSIZE_END)
        anhaengen(block, feld)

        // **Kein Standardsteuerelement** (E4): ein nacktes Zeichen mit Wort,
        // kein `GtkExpander`.
        let mehr: Widget! = gtk_button_new()
        gtk_widget_add_css_class(mehr, "swiftly-umriss")
        gtk_widget_set_halign(mehr, GTK_ALIGN_START)
        gtk_button_set_label(alsKnopf(mehr), uebersetzt("Mehr"))
        // `Widget` ist ein Zeiger, kein Objekt — `weak` geht daran nicht. Das
        // ist hier auch nicht nötig: der Rückruf hängt am Knopf und stirbt mit
        // ihm, und beide Felder gehören derselben Seite.
        beiSignal(mehr, "clicked") {
            let ganz = gtk_label_get_lines(OpaquePointer(feld)) == 4
            gtk_label_set_lines(OpaquePointer(feld), ganz ? -1 : 4)
            gtk_label_set_ellipsize(OpaquePointer(feld),
                                    ganz ? PANGO_ELLIPSIZE_NONE : PANGO_ELLIPSIZE_END)
            gtk_button_set_label(alsKnopf(mehr),
                                 ganz ? uebersetzt("Weniger") : uebersetzt("Mehr"))
        }
        anhaengen(block, mehr)
        return block
    }

    // MARK: - Reihen

    /// **Der eigene Server zuerst, Seerr daneben.**
    ///
    /// Seerr fragt für eine Filmografie erst bei TMDB nach und braucht dafür
    /// manchmal Sekunden; auf die wartete auf Apple einmal die ganze Seite.
    /// Die Reihe „Auf deinem Server" steht deshalb, sobald der Server
    /// geantwortet hat, und „Kann angefragt werden" kommt **unten** dazu —
    /// unten, damit sich darüber nichts verschiebt.
    private func personReihenNachladen(_ person: Item, in raum: Widget!) {
        guard let client else { return }
        let kiste = gehalten(raum)
        Task.detached { [self] in
            let eigene = await client.titel(person: person.id)
            nachDemSchub {
                let ziel = kiste.widget
                if !eigene.isEmpty {
                    anhaengen(ziel, self.reiheBauen(titel: uebersetzt("Auf deinem Server"),
                                                    art: .neu, items: eigene))
                } else {
                    // **Nur, wenn wirklich nichts da ist.** Ein leerer Raum
                    // ohne Wort sähe aus wie eine Seite, die noch lädt.
                    let hinweis = beschriftung(
                        String(format: uebersetzt("Auf deinem Server gibt es sonst nichts mit %@."),
                               person.name),
                        stil: "swiftly-koerper", umbruch: true)
                    gtk_label_set_xalign(OpaquePointer(hinweis), 0)
                    gtk_widget_add_css_class(hinweis, "swiftly-leise")
                    gtk_widget_set_margin_start(hinweis, Int32(Stil.randAbstand))
                    gtk_widget_set_margin_end(hinweis, Int32(Stil.randAbstand))
                    anhaengen(ziel, hinweis)
                }
                losgelassen(kiste)
            }
        }
    }
}
