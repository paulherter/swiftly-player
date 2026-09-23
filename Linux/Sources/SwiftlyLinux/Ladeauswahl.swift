import CGtk
import Foundation
import JellyfinKit

/// **Die Ladeauswahl einer Serie** — die GTK-Fassung von `MacLadeauswahl`
/// (`Sources/macOS/Macdownloads.swift`, Mac fa55d091 und 25a21b02).
///
/// Paul am 22.09.: „der Chip Staffel laden kommt doch weg. Wir machen doch
/// dann einen neuen Knopf, auf den man drückt, wo ein Menü kommt, wo man dann
/// einzelne Staffeln auswählen kann. Die ganze Serie und so." Der Chip nahm
/// genau die gerade gewählte Staffel; wer zwei wollte, klickte zweimal. Und
/// der Ladering an jeder Folge (f4dae47c) ist mit ihm gegangen: wer eine
/// einzelne Folge will, hakt sie hier an und sieht dabei auch, wie groß sie
/// ist.
///
/// Ein Baum mit drei Ebenen — ganze Serie, Staffel, Folge —, und jede Ebene
/// trägt denselben runden Kasten in drei Zuständen: leer, teilweise, voll.
/// Der Schalter „Nur ungesehene" wählt nichts aus, er entscheidet, *was* ein
/// Haken auswählt.
///
/// **Der Fehlfall gehört dazu.** Scheitert ein Staffelabruf, steht der
/// Störhinweis da statt einer leeren Auswahl. Gescheiterte Abrufe werden
/// nicht gemerkt.
final class Ladeauswahlstand: @unchecked Sendable {
    var staffeln: [Item] = []
    var folgen: [String: [Item]] = [:]
    var gewaehlt: Set<String> = []
    var offeneStaffel: String?
    /// Die Staffel, die gerade aufgeklappt wurde — nur sie faehrt herein,
    /// jeder andere Neubau steht sofort.
    var frischAufgeklappt: String?
    var nurUngesehene = false
    var laedt = true
    var gestoert = false
    var alleFolgen: [Item] { staffeln.compactMap { folgen[$0.id] }.flatMap { $0 } }
}

/// Haelt den Rueckruf, der die Auswahl neu zeichnet — er ruft sich selbst
/// ueber die Knoepfe darin wieder auf. Angefasst nur auf GTKs Hauptfaden.
final class Maler: @unchecked Sendable {
    var tun: () -> Void = {}
}

extension App {
    /// Öffnet die Auswahl als Tafel unter dem Ladeknopf der Serienseite.
    func ladeauswahlZeigen(_ serie: Item, an knopf: Widget!) {
        guard let client else { return }
        let stand = Ladeauswahlstand()
        let tafel = tafelOeffnen(an: knopf)
        let rumpf = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(rumpf, 420, -1)
        gtk_popover_set_child(alsTafel(tafel), rumpf)

        let kopf = beschriftung(serie.name, stil: "swiftly-leistentitel")
        gtk_label_set_xalign(OpaquePointer(kopf), 0)
        gtk_label_set_ellipsize(OpaquePointer(kopf), PANGO_ELLIPSIZE_END)
        gtk_widget_set_margin_start(kopf, 16)
        gtk_widget_set_margin_end(kopf, 16)
        gtk_widget_set_margin_top(kopf, 10)
        gtk_widget_set_margin_bottom(kopf, 10)
        anhaengen(rumpf, kopf)

        let inhalt = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        anhaengen(rumpf, inhalt)
        let kiste = gehalten(inhalt)
        let tafelkiste = gehalten(tafel)
        beiSignal(tafel, "closed") { losgelassen(kiste); losgelassen(tafelkiste) }

        let maler = Maler()
        let malen: @Sendable () -> Void = { maler.tun() }
        maler.tun = { [weak self] in
            guard let self, gtk_widget_get_parent(kiste.widget) != nil else { return }
            self.ladeauswahlMalen(stand, serie: serie, in: kiste.widget,
                                  tafel: tafelkiste.widget, neu: malen,
                                  erneut: { [weak self] in
                                      self?.ladeauswahlHolen(stand, serie: serie,
                                                             client: client, fertig: malen)
                                  })
        }
        // Der Maler haelt sich ueber `malen` selbst — beim Schliessen loesen.
        beiSignal(tafel, "closed") { maler.tun = {} }
        malen()
        ladeauswahlHolen(stand, serie: serie, client: client, fertig: malen)
        gtk_popover_popup(alsTafel(tafel))
    }

    /// Staffeln und alle Folgen — aus dem Speicher, was schon da ist.
    private func ladeauswahlHolen(_ stand: Ladeauswahlstand, serie: Item,
                                  client: JellyfinClient, fertig: @escaping @Sendable () -> Void) {
        stand.laedt = true
        stand.gestoert = false
        let staffelnDa = staffelspeicher[serie.id]
        let schon = folgenspeicher
        Task.detached { [self] in
            var staffeln = staffelnDa ?? []
            var gestoert = false
            if staffeln.isEmpty {
                if let liste = try? await client.staffeln(seriesID: serie.id) {
                    staffeln = liste
                } else {
                    gestoert = true
                }
            }
            var folgen: [String: [Item]] = [:]
            for staffel in staffeln {
                if let da = schon[staffel.id] { folgen[staffel.id] = da; continue }
                guard let liste = try? await client.folgen(seriesID: serie.id,
                                                           seasonID: staffel.id)
                else { gestoert = true; continue }
                folgen[staffel.id] = liste
            }
            let ergebnis = (staffeln, folgen, gestoert)
            aufHauptfaden {
                stand.staffeln = ergebnis.0
                stand.folgen = ergebnis.1
                stand.gestoert = ergebnis.2
                stand.laedt = false
                if !ergebnis.0.isEmpty { self.staffelspeicher[serie.id] = ergebnis.0 }
                for (k, v) in ergebnis.1 { self.folgenspeicher[k] = v }
                fertig()
            }
        }
    }

    /// **Was ein Haken nimmt.** Ohne Schalter alles, mit Schalter nur, was
    /// offen ist — und was schon auf der Platte liegt, nie.
    private func nehmbar(_ liste: [Item], _ stand: Ladeauswahlstand) -> [Item] {
        liste.filter { folge in
            guard downloads.posten(fuer: folge.id) == nil else { return false }
            guard stand.nurUngesehene else { return true }
            return !gesehen(folge)
        }
    }

    /// **Was in der Liste steht** (Mac 89299260). Mit „Nur ungesehene"
    /// stehen gesehene Folgen gar nicht erst da und zaehlen nirgends mit —
    /// vorher blieben sie sichtbar und waren nur nicht mehr waehlbar.
    private func sichtbar(_ liste: [Item], _ stand: Ladeauswahlstand) -> [Item] {
        stand.nurUngesehene ? liste.filter { !gesehen($0) } : liste
    }

    private func gesehen(_ folge: Item) -> Bool { folge.userData?.played ?? false }

    /// Vier Zustaende: die drei der Auswahl, und **da** fuer das, was schon
    /// auf diesem Rechner liegt und nicht mehr gewaehlt werden kann. Vorher
    /// blendete ``nehmbar(_:_:)`` Geladenes nur aus, und an seiner Stelle
    /// stand ein leerer Kreis, der auf Klicken nichts tat.
    private enum Kasten { case leer, teil, voll, da }

    private func kastenstand(_ alle: [Item], _ stand: Ladeauswahlstand,
                             daZaehlt: Bool = true) -> Kasten {
        let liste = sichtbar(alle, stand)
        if daZaehlt, !liste.isEmpty,
           liste.allSatisfy({ downloads.posten(fuer: $0.id) != nil }) {
            return .da
        }
        let frei = nehmbar(liste, stand)
        guard !frei.isEmpty else { return .leer }
        let an = frei.filter { stand.gewaehlt.contains($0.id) }.count
        return an == 0 ? .leer : (an == frei.count ? .voll : .teil)
    }

    /// Solange nicht jede Staffel gelesen ist, ist die Serie nicht „da" —
    /// auch wenn die erste gelesene zufaellig ganz geladen ist.
    private func standAlle(_ stand: Ladeauswahlstand) -> Kasten {
        kastenstand(stand.alleFolgen, stand, daZaehlt: !stand.laedt)
    }

    /// **„Ganze Serie" nennt nur, was noch fehlt** (`serienRechts` auf dem Mac).
    private func serienRechts(_ stand: Ladeauswahlstand) -> String {
        if stand.laedt { return uebersetzt("wird gelesen …") }
        let alle = stand.alleFolgen
        if standAlle(stand) == .da { return uebersetzt("alles da") }
        if !alle.isEmpty, sichtbar(alle, stand).isEmpty { return uebersetzt("alles gesehen") }
        let frei = nehmbar(alle, stand)
        return folgenzahl(frei.count) + " · " + Downloadregeln.groesse(bytes(frei))
    }

    /// Rechts in der Staffelzeile: was ein Haken dort noch nehmen wuerde.
    /// **„alles da" nur, wenn es stimmt** — nicht, solange die Staffel noch
    /// gelesen wird, und nicht, wenn „Nur ungesehene" alles ausschliesst.
    private func staffelRechts(_ alle: [Item]?, sichtbar eigene: [Item], _ kasten: Kasten,
                               _ stand: Ladeauswahlstand) -> String {
        guard let alle else { return stand.laedt ? uebersetzt("wird gelesen …") : "—" }
        if alle.isEmpty { return uebersetzt("Keine Folgen") }
        if eigene.isEmpty { return uebersetzt("alles gesehen") }
        if kasten == .da { return uebersetzt("alles da") }
        let frei = nehmbar(eigene, stand)
        if frei.isEmpty { return uebersetzt("alles da") }
        return String(format: uebersetzt("%d Folgen"), frei.count)
    }

    /// **Gesehen steht dabei, bevor man waehlt.** Ohne Schalter bleiben
    /// gesehene Folgen waehlbar — Kreis wie jede andere, aber Titel leise und
    /// rechts „gesehen" vor der Groesse.
    private func folgenRechts(_ folge: Item) -> String {
        let groesse = (folge.mediaSources?.first?.size).flatMap {
            $0 > 0 ? Downloadregeln.groesse(Int64($0)) : nil } ?? "—"
        return gesehen(folge) ? uebersetzt("gesehen") + " · " + groesse : groesse
    }

    /// **Eine geladene Folge sagt, dass sie da ist** — statt der Groesse ihr
    /// Stand.
    private func ladestand(_ posten: Downloadposten) -> String {
        switch posten.stand {
        case .fertig: return uebersetzt("geladen")
        case .laedt: return uebersetzt("lädt")
        default: return uebersetzt("wartet")
        }
    }

    private func folgenzahl(_ n: Int) -> String {
        n == 1 ? uebersetzt("1 Folge") : String(format: uebersetzt("%d Folgen"), n)
    }

    private func bytes(_ liste: [Item]) -> Int64 {
        liste.reduce(0) { $0 + Int64($1.mediaSources?.first?.size ?? 0) }
    }

    private func ladeauswahlMalen(_ stand: Ladeauswahlstand, serie: Item, in inhalt: Widget!,
                                  tafel: Widget!, neu: @escaping () -> Void,
                                  erneut: @escaping () -> Void) {
        // Wo die Liste stand, bleibt sie stehen — neu gebaut wird bei jedem
        // Haken, gescrollt werden soll dabei nichts.
        var alteStelle = 0.0
        if let alt = gtk_widget_get_first_child(inhalt),
           gtk_widget_has_css_class(alt, "swiftly-auswahlscroller") != 0,
           let a = gtk_scrolled_window_get_vadjustment(OpaquePointer(alt)) {
            alteStelle = gtk_adjustment_get_value(a)
        }
        leeren(inhalt)
        if stand.gestoert, stand.alleFolgen.isEmpty {
            let hinweis = stoerhinweis(oben: 10, erneut: erneut)
            gtk_widget_set_margin_bottom(hinweis, 16)
            anhaengen(inhalt, hinweis)
            return
        }

        let umschalten: ([Item]) -> Void = { [weak self] liste in
            guard let self else { return }
            let frei = self.nehmbar(liste, stand)
            guard !frei.isEmpty else { return }
            let alleAn = frei.allSatisfy { stand.gewaehlt.contains($0.id) }
            for f in frei {
                if alleAn { stand.gewaehlt.remove(f.id) } else { stand.gewaehlt.insert(f.id) }
            }
            neu()
        }

        let scroller: Widget! = gtk_scrolled_window_new()
        gtk_widget_add_css_class(scroller, "swiftly-auswahlscroller")
        gtk_scrolled_window_set_policy(OpaquePointer(scroller), GTK_POLICY_NEVER,
                                       GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(OpaquePointer(scroller), 1)
        gtk_scrolled_window_set_max_content_height(OpaquePointer(scroller), 360)
        let karten = stapel(GTK_ORIENTATION_VERTICAL, abstand: 12)
        gtk_widget_set_margin_start(karten, 16)
        gtk_widget_set_margin_end(karten, 16)
        gtk_widget_set_margin_bottom(karten, 12)
        gtk_scrolled_window_set_child(OpaquePointer(scroller), karten)
        anhaengen(inhalt, scroller)

        // Die Serienkarte: ganze Serie, darunter der Schalter.
        let serienkarte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(serienkarte, "swiftly-auswahlkarte")
        let alle = stand.alleFolgen
        anhaengen(serienkarte, auswahlzeileBauen(
            kasten: standAlle(stand), titel: uebersetzt("Ganze Serie"),
            rechts: serienRechts(stand),
            klein: false, einzug: 16, aufgeklappt: nil,
            tun: { umschalten(alle) }, aufklappen: nil))
        anhaengen(serienkarte, trennlinie())
        let schalterblock = stapel(GTK_ORIENTATION_VERTICAL, abstand: 3)
        gtk_widget_set_margin_start(schalterblock, 16)
        gtk_widget_set_margin_end(schalterblock, 16)
        gtk_widget_set_margin_top(schalterblock, 12)
        gtk_widget_set_margin_bottom(schalterblock, 12)
        let schalterreihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 13)
        let st = beschriftung(uebersetzt("Nur ungesehene"), stil: "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(st), 0)
        gtk_widget_set_hexpand(st, 1)
        anhaengen(schalterreihe, st)
        anhaengen(schalterreihe, kleinerSchalter(an: stand.nurUngesehene) { [weak self] an in
            guard let self else { return }
            stand.nurUngesehene = an
            let erlaubt = Set(self.nehmbar(stand.alleFolgen, stand).map(\.id))
            stand.gewaehlt.formIntersection(erlaubt)
            neu()
        })
        anhaengen(schalterblock, schalterreihe)
        let su = beschriftung(uebersetzt("Entscheidet, was ein Haken auswählt."),
                              stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(su, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(su), 0)
        anhaengen(schalterblock, su)
        anhaengen(serienkarte, schalterblock)
        anhaengen(karten, serienkarte)

        // Die Staffelkarte: je Staffel eine Zeile, aufklappbar zu den Folgen.
        if !stand.staffeln.isEmpty {
            let staffelkarte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
            gtk_widget_add_css_class(staffelkarte, "swiftly-auswahlkarte")
            for (nr, staffel) in stand.staffeln.enumerated() {
                let eigene = sichtbar(stand.folgen[staffel.id] ?? [], stand)
                let kasten = kastenstand(eigene, stand)
                let offen = stand.offeneStaffel == staffel.id
                // **Die Folgen fahren herein, und die Tafel waechst mit**
                // (Mac 89299260, `hoeheSetzen`). Dort liefen Zeilen und Hoehe
                // in derselben Kurve, `sprung` (0,22 s). Hier traegt ein
                // `GtkRevealer` die Folgen; die Tafel misst ihn in jedem Bild
                // neu und waechst damit von selbst in derselben Kurve.
                let aufklapp: Widget! = gtk_revealer_new()
                gtk_revealer_set_transition_type(alsAufklapp(aufklapp),
                                                 GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
                // Ungehalten: der Aufruf kommt nur aus der Zeile daneben, die
                // mit dem Aufklapper lebt und geht.
                let aufklappKiste = Zeigerkiste(aufklapp)
                anhaengen(staffelkarte, auswahlzeileBauen(
                    kasten: kasten, titel: staffel.name,
                    rechts: staffelRechts(stand.folgen[staffel.id], sichtbar: eigene,
                                          kasten, stand),
                    klein: false, einzug: 16, aufgeklappt: offen,
                    tun: { umschalten(eigene) },
                    aufklappen: {
                        guard offen else {
                            stand.offeneStaffel = staffel.id
                            stand.frischAufgeklappt = staffel.id
                            neu()
                            return
                        }
                        // Zu: erst einfahren, dann neu bauen.
                        let w: Widget! = aufklappKiste.widget
                        gtk_revealer_set_reveal_child(alsAufklapp(w), 0)
                        laufen(auf: w, dauer: 0.22, schritt: { _ in }, fertig: {
                            guard stand.offeneStaffel == staffel.id else { return }
                            stand.offeneStaffel = nil
                            neu()
                        })
                    }))
                if offen {
                    let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
                    for folge in eigene {
                        anhaengen(block, trennlinie())
                        let posten = downloads.posten(fuer: folge.id)
                        anhaengen(block, auswahlzeileBauen(
                            kasten: posten != nil ? .da
                                    : (stand.gewaehlt.contains(folge.id) ? .voll : .leer),
                            titel: folge.name,
                            rechts: posten.map(ladestand) ?? folgenRechts(folge),
                            klein: true, einzug: 38, leise: gesehen(folge),
                            aufgeklappt: nil, tun: { umschalten([folge]) }, aufklappen: nil))
                    }
                    gtk_revealer_set_child(alsAufklapp(aufklapp), block)
                    if stand.frischAufgeklappt == staffel.id {
                        stand.frischAufgeklappt = nil
                        gtk_revealer_set_transition_duration(alsAufklapp(aufklapp), 220)
                        let kiste = gehalten(aufklapp)
                        aufHauptfaden {
                            defer { losgelassen(kiste) }
                            gtk_revealer_set_reveal_child(alsAufklapp(kiste.widget), 1)
                        }
                    } else {
                        // Jeder andere Neubau (ein Haken) steht sofort.
                        gtk_revealer_set_transition_duration(alsAufklapp(aufklapp), 0)
                        gtk_revealer_set_reveal_child(alsAufklapp(aufklapp), 1)
                        gtk_revealer_set_transition_duration(alsAufklapp(aufklapp), 220)
                    }
                }
                anhaengen(staffelkarte, aufklapp)
                if nr < stand.staffeln.count - 1 { anhaengen(staffelkarte, trennlinie()) }
            }
            anhaengen(karten, staffelkarte)
        }
        if alteStelle > 0 {
            let stelle = alteStelle
            let sk = gehalten(scroller)
            aufHauptfaden {
                defer { losgelassen(sk) }
                if let a = gtk_scrolled_window_get_vadjustment(OpaquePointer(sk.widget)) {
                    gtk_adjustment_set_value(a, stelle)
                }
            }
        }

        // Der Fuß: was gewählt ist, was danach frei bleibt, der Beleg und der
        // Hauptknopf.
        let fuss = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)
        gtk_widget_set_margin_top(fuss, 4)
        gtk_widget_set_margin_bottom(fuss, 12)
        anhaengen(fuss, trennlinie())
        let gewaehlteFolgen = stand.alleFolgen.filter { stand.gewaehlt.contains($0.id) }
        let summe = bytes(gewaehlteFolgen)
        let zahlreihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        gtk_widget_set_margin_start(zahlreihe, 16)
        gtk_widget_set_margin_end(zahlreihe, 16)
        let links = beschriftung(stand.gewaehlt.isEmpty ? uebersetzt("Nichts gewählt")
                                 : folgenzahl(stand.gewaehlt.count) + " · "
                                   + Downloadregeln.groesse(summe),
                                 stil: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(links), 0)
        gtk_widget_set_hexpand(links, 1)
        anhaengen(zahlreihe, links)
        // **Rechts im Fuss: frei danach, oder was fehlt** (Mac 89299260).
        // Bei zu wenig Platz stand hier „Danach 0 GB frei" — richtig
        // gerechnet und trotzdem falsch, denn es sagte nicht, dass es nicht
        // reicht. Ob es reicht, entscheidet `Downloadregeln.fussplatz` im
        // Paket, mit derselben Reserve wie die Nachfrage danach.
        switch Downloadregeln.fussplatz(fuer: summe, frei: downloads.freierPlatz) {
        case .frei(let rest):
            let rechts = beschriftung(String(format: uebersetzt("Danach %@ frei"),
                                             Downloadregeln.groesse(rest)),
                                      stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(rechts, "swiftly-leise")
            anhaengen(zahlreihe, rechts)
        case .zuWenig(let fehlt):
            let warnung = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 5)
            gtk_widget_add_css_class(warnung, "swiftly-warnung")
            let zeichen: Widget! = gtk_image_new_from_icon_name("dialog-information-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(zeichen), 12)
            gtk_widget_add_css_class(zeichen, "swiftly-warnung")
            anhaengen(warnung, zeichen)
            let text = beschriftung(String(format: uebersetzt("%@ zu wenig"),
                                           Downloadregeln.groesse(fehlt)),
                                    stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(text, "swiftly-warnung")
            anhaengen(warnung, text)
            anhaengen(zahlreihe, warnung)
        }
        anhaengen(fuss, zahlreihe)

        let beleg = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
        gtk_widget_add_css_class(beleg, "swiftly-belegmarke")
        gtk_widget_add_css_class(beleg, "swiftly-beleg")
        gtk_widget_set_halign(beleg, GTK_ALIGN_START)
        gtk_widget_set_margin_start(beleg, 16)
        let haken: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(haken), 11)
        anhaengen(beleg, haken)
        anhaengen(beleg, beschriftung(uebersetzt("Direct Play · Originalqualität"),
                                      stil: "swiftly-zweitzeile"))
        anhaengen(fuss, beleg)

        let knopf = hauptknopf(stand.gewaehlt.isEmpty ? uebersetzt("Laden")
                               : String(format: uebersetzt("%@ laden"),
                                        folgenzahl(stand.gewaehlt.count)),
                               symbol: "folder-download-symbolic")
        gtk_widget_set_size_request(knopf, 388, Int32(Stil.hauptknopfHoehe))
        gtk_widget_set_sensitive(knopf, stand.gewaehlt.isEmpty ? 0 : 1)
        let tafelkiste = gehalten(tafel)
        beiSignal(knopf, "clicked") { [weak self] in
            gtk_popover_popdown(alsTafel(tafelkiste.widget))
            losgelassen(tafelkiste)
            guard let self else { return }
            self.staffelLaden(gewaehlteFolgen)
            // Mit dem ersten Download der Serie gehen Kopfbild und Plakat mit
            // — einmal; was schon liegt, wird nicht neu geholt.
            if self.downloads.kopfbild(serie: serie.id, konto: self.benutzerID) == nil {
                self.downloadSerienbilderMitgeben(serie)
            }
        }
        anhaengen(fuss, knopf)
        anhaengen(inhalt, fuss)
    }

    /// Eine Zeile der Auswahl: Kasten links, Titel, rechts die Angabe und bei
    /// einer Staffel der Winkel. 58 hoch, eine Folge 52 — die eingerückte
    /// Folge soll flacher stehen als die Staffel, zu der sie gehört.
    private func auswahlzeileBauen(kasten: Kasten, titel: String, rechts: String,
                                   klein: Bool, einzug: Int, leise: Bool = false,
                                   aufgeklappt: Bool?,
                                   tun: @escaping () -> Void,
                                   aufklappen: (() -> Void)?) -> Widget! {
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 13)
        gtk_widget_set_margin_start(reihe, Int32(einzug))
        gtk_widget_set_margin_end(reihe, 16)
        gtk_widget_set_size_request(reihe, -1, klein ? 52 : 58)

        // **Da: leise, ohne Kreis und ohne Knopf.** Ein Haken im Akzent
        // hiesse „gewaehlt"; dieser sagt nur, dass nichts mehr zu tun ist.
        guard kasten != .da else {
            let feld = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
            gtk_widget_set_size_request(feld, 22, 22)
            gtk_widget_set_valign(feld, GTK_ALIGN_CENTER)
            let haken: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(haken), 15)
            gtk_widget_add_css_class(haken, "swiftly-leise")
            gtk_widget_set_hexpand(haken, 1)
            anhaengen(feld, haken)
            beschriften(feld, uebersetzt("geladen"))
            anhaengen(reihe, feld)
            return auswahlzeileRest(reihe, titel: titel, rechts: rechts, klein: klein,
                                    leise: true, aufgeklappt: aufgeklappt,
                                    tun: tun, aufklappen: aufklappen)
        }
        let kastenknopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(kastenknopf, "swiftly-kasten")
        switch kasten {
        case .leer, .da: break
        case .teil:
            gtk_widget_add_css_class(kastenknopf, "swiftly-aktiv")
            let b: Widget! = gtk_image_new_from_icon_name("list-remove-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(b), 12)
            gtk_button_set_child(alsKnopf(kastenknopf), b)
        case .voll:
            gtk_widget_add_css_class(kastenknopf, "swiftly-aktiv")
            let b: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(b), 11)
            gtk_button_set_child(alsKnopf(kastenknopf), b)
        }
        beschriften(kastenknopf, uebersetzt("Auswählen"))
        gtk_widget_set_size_request(kastenknopf, 22, 22)
        gtk_widget_set_valign(kastenknopf, GTK_ALIGN_CENTER)
        beiSignal(kastenknopf, "clicked", tun)
        anhaengen(reihe, kastenknopf)
        return auswahlzeileRest(reihe, titel: titel, rechts: rechts, klein: klein,
                                leise: leise, aufgeklappt: aufgeklappt,
                                tun: tun, aufklappen: aufklappen)
    }

    /// Titel, Angabe und Winkel rechts vom Kasten.
    private func auswahlzeileRest(_ reihe: Widget!, titel: String, rechts: String,
                                  klein: Bool, leise: Bool, aufgeklappt: Bool?,
                                  tun: @escaping () -> Void,
                                  aufklappen: (() -> Void)?) -> Widget! {
        let zeile: Widget! = gtk_button_new()
        gtk_widget_add_css_class(zeile, "swiftly-auswahlzeile")
        gtk_widget_set_hexpand(zeile, 1)
        let innen = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        let t = beschriftung(titel, stil: klein ? "swiftly-kacheltitel" : "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(t), 0)
        gtk_label_set_ellipsize(OpaquePointer(t), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(t, 1)
        // Gesehen oder geladen: Titel in `schriftLeise`, wie auf dem Mac.
        if leise { gtk_widget_add_css_class(t, "dim-label") }
        anhaengen(innen, t)
        let r = beschriftung(rechts, stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(r, "swiftly-leise")
        anhaengen(innen, r)
        if let aufgeklappt {
            let w: Widget! = gtk_image_new_from_icon_name(aufgeklappt ? "pan-down-symbolic"
                                                                      : "pan-end-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(w), 13)
            gtk_widget_add_css_class(w, "swiftly-leise")
            anhaengen(innen, w)
        }
        gtk_button_set_child(alsKnopf(zeile), innen)
        beiSignal(zeile, "clicked") { (aufklappen ?? tun)() }
        anhaengen(reihe, zeile)
        return reihe
    }
}
