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
            case .folgen:     "Folgen"
            case .besetzung:  "Besetzung"
            case .aehnliches: "Ähnliches"
            }
        }
    }

    func serienunterbau(_ serie: Item, in unten: Widget!) {
        let reiterraum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        let inhaltraum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 18)
        gtk_widget_set_margin_start(inhaltraum, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(inhaltraum, Int32(Stil.randAbstand))

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
        // Die Haarlinie läuft über die volle Breite, die Reiter nicht.
        anhaengen(reiterraum, trennlinie())

        anhaengen(unten, reiterraum)
        anhaengen(unten, inhaltraum)
        reiterInhalt(.folgen, serie: serie, in: inhaltraum)
    }

    private func reiterInhalt(_ was: Reiter, serie: Item, in raum: Widget!) {
        leeren(raum)
        switch was {
        case .folgen:
            anhaengen(raum, beschriftung("Lade …", stil: "swiftly-koerper"))
            staffelnLaden(serie, in: raum)
        case .besetzung:
            if serie.darsteller.isEmpty {
                anhaengen(raum, beschriftung("Keine Besetzung hinterlegt.", stil: "swiftly-koerper"))
            } else {
                anhaengen(raum, besetzungsreihe(serie.darsteller))
            }
        case .aehnliches:
            anhaengen(raum, beschriftung("Lade …", stil: "swiftly-koerper"))
            aehnlicheNachladen(serie, in: raum, leeren: true)
        }
    }

    // MARK: Staffeln und Folgen

    private func staffelnLaden(_ serie: Item, in raum: Widget!) {
        guard let client else { return }
        let kiste = gehalten(raum)
        Task.detached { [self] in
            let staffeln = (try? await client.staffeln(seriesID: serie.id)) ?? []
            aufHauptfaden {
                defer { losgelassen(kiste) }
                self.staffelnZeigen(staffeln, serie: serie, in: kiste.widget)
            }
        }
    }

    private func staffelnZeigen(_ staffeln: [Item], serie: Item, in raum: Widget!) {
        leeren(raum)
        guard !staffeln.isEmpty else {
            anhaengen(raum, beschriftung("Keine Staffeln gefunden.", stil: "swiftly-koerper"))
            return
        }
        // Mit welcher Staffel geöffnet wird: der über eine Folge gewählten,
        // sonst der ersten.
        let wahl = Staffelwahl()
        wahl.jetzt = staffeln.first { $0.id == startStaffel } ?? staffeln[0]

        let pille: Widget! = gtk_button_new()
        gtk_widget_add_css_class(pille, "swiftly-chip")
        gtk_widget_set_halign(pille, GTK_ALIGN_START)
        gtk_button_set_label(alsKnopf(pille), wahl.jetzt?.name ?? "")
        // Nur bei mehr als einer Staffel ist eine Wahl zu treffen.
        gtk_widget_set_sensitive(pille, staffeln.count > 1 ? 1 : 0)

        let folgenraum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)

        // **Eine Tafel, kein aufklappender Kasten in der Seite.** Auf dem Mac
        // erscheint die Staffelliste als Blatt über der Pille — dieselbe
        // Form wie beim Mehr-Knopf, und dieselbe Regel: kleine
        // Entscheidungen erscheinen dort, wo sie ausgelöst wurden (E5). Mein
        // erster Versuch schob sie als Liste in den Seitenfluss und verschob
        // dabei alles darunter.
        beiSignal(pille, "clicked") { [weak self] in
            guard let self else { return }
            let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
            gtk_widget_set_size_request(liste, 200, -1)
            let tafel: Widget! = gtk_popover_new()
            gtk_widget_add_css_class(tafel, "swiftly-mehr")
            gtk_popover_set_child(alsTafel(tafel), liste)
            gtk_popover_set_position(alsTafel(tafel), GTK_POS_BOTTOM)
            gtk_widget_set_parent(tafel, pille)
            for staffel in staffeln {
                let gewaehlt = staffel.id == wahl.jetzt?.id
                anhaengen(liste, self.staffelzeile(staffel.name, gewaehlt: gewaehlt) {
                    [weak self] in
                    wahl.jetzt = staffel
                    gtk_button_set_label(alsKnopf(pille), staffel.name)
                    gtk_popover_popdown(alsTafel(tafel))
                    self?.folgenLaden(serie: serie, staffel: staffel, in: folgenraum)
                })
            }
            gtk_popover_popup(alsTafel(tafel))
        }

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
        leeren(raum)
        anhaengen(raum, beschriftung("Lade …", stil: "swiftly-koerper"))
        let kiste = gehalten(raum)
        Task.detached { [self] in
            let folgen = (try? await client.folgen(seriesID: serie.id,
                                                   seasonID: staffel.id)) ?? []
            aufHauptfaden {
                defer { losgelassen(kiste) }
                leeren(kiste.widget)
                for folge in folgen { anhaengen(kiste.widget, self.folgenzeile(folge)) }
            }
        }
    }

    /// Eine Folge in der Liste. Bild 160 × 90 (16 : 9), 18 Abstand, darunter
    /// Kopfzeile mit Laufzeit rechts und zwei Zeilen Beschreibung.
    ///
    /// **Das Bild der Folge, nicht das der Serie.** `Bildwahl.quer` nimmt
    /// absichtlich den Hintergrund der Serie — richtig für „Weiterschauen",
    /// falsch hier: in einer Folgenliste stünde in jeder Zeile dasselbe Bild.
    private func folgenzeile(_ folge: Item) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-folgenzeile")

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 18)

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
        anhaengen(reihe, huelle)

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
        anhaengen(reihe, text)

        // **Der Haken steht immer, wenn die Folge gesehen ist** — er ist die
        // einzige Auskunft darüber in der Liste, und ohne ihn sieht eine
        // durchgesehene Staffel aus wie eine unangetastete.
        if folge.istGesehen {
            let haken: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(haken), 14)
            gtk_widget_add_css_class(haken, "swiftly-beleg")
            gtk_widget_set_valign(haken, GTK_ALIGN_START)
            gtk_widget_set_margin_top(haken, 2)
            anhaengen(reihe, haken)
        }

        gtk_button_set_child(alsKnopf(knopf), reihe)
        // **Eine Folge aus der Liste startet an ihrer eigenen Stelle** (A5).
        beiSignal(knopf, "clicked") { [weak self] in self?.starte(folge) }
        return knopf
    }

    // MARK: Besetzung und Ähnliches

    func besetzungsreihe(_ leute: [Person]) -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 14)
        let titel = beschriftung("Besetzung", stil: "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(titel), 0)
        gtk_widget_set_margin_start(titel, Int32(Stil.randAbstand))
        anhaengen(block, titel)

        let scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 18)
        gtk_widget_set_margin_start(reihe, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(reihe, Int32(Stil.randAbstand))
        for person in leute { anhaengen(reihe, kopfbild(person)) }
        gtk_scrolled_window_set_child(OpaquePointer(scroller), reihe)
        anhaengen(block, scroller)
        return block
    }

    /// Ein Kopf: 84 rund, darunter Name und Rolle.
    private func kopfbild(_ person: Person) -> Widget! {
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
        return huelleKnopf
    }

    func aehnlicheNachladen(_ titel: Item, in raum: Widget!, leeren leeren_: Bool = false) {
        guard let client else { return }
        let kiste = gehalten(raum)
        Task.detached { [self] in
            let treffer = (try? await client.aehnliche(itemID: titel.id)) ?? []
            aufHauptfaden {
                defer { losgelassen(kiste) }
                let ziel = kiste.widget
                if leeren_ { leeren(ziel) }
                guard !treffer.isEmpty else {
                    if leeren_ {
                        anhaengen(ziel, beschriftung("Nichts Ähnliches gefunden.",
                                                     stil: "swiftly-koerper"))
                    }
                    return
                }
                anhaengen(ziel, self.reiheBauen(titel: "Ähnliches", art: .neu, items: treffer))
            }
        }
    }
}


/// Welche Staffel gewählt ist. Wie ``Spielziel`` eine Klasse, damit Tafel und
/// Pille denselben Wert sehen; angefasst wird sie nur auf GTKs Hauptfaden.
final class Staffelwahl: @unchecked Sendable {
    var jetzt: Item?
}
