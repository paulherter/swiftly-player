import CGtk
import Foundation
import JellyfinKit

/// Die drei Ebenen über dem Bild — nach `Sources/macOS/PlayerEbenen.swift`:
/// Audio & Untertitel, Einstellungen, Folgen. Jede füllt den ganzen Schirm.
///
/// **Eine erzwungene Abweichung:** GTKs CSS kennt kein `backdrop-filter`,
/// der Weichzeichner hinter der Ebene (`.ultraThinMaterial`) fehlt. Dafür
/// dunkelt die Ebene etwas stärker ab (Schwarz 78 % statt 72 %), damit die
/// Schrift über hellem Bild genauso lesbar bleibt.
///
/// **Was hier am 19.09.2026 kaputt war und warum:**
/// - Nach dem Schliessen einer Ebene reagierte nichts mehr: `ebeneOeffnen`
///   nahm der Steuerung `can-target`, und nichts gab es ihr zurück.
/// - Der Titel verschwand: `obenHalten` nahm ihn aus dem Overlay und legte
///   ihn neu hinein — beim Herausnehmen fiel der letzte Verweis, GTK gab das
///   Widget frei, und das Feld zeigte ins Leere. Jetzt wird nur umsortiert
///   (`gtk_widget_insert_before`), nie herausgenommen.
/// - Jede Wahl in einer Ebene baute die ganze Ebene neu (Springen, Flackern);
///   jetzt wandert nur der Haken.
enum Playerebene: Equatable, Hashable {
    case spuren, einstellungen, folgen
}

/// Maße des Players — wörtlich `Playermass` vom Mac.
enum Playermass {
    static let seite: Int32 = 40
    static let oben: Int32 = 28
    static let unten: Int32 = 24
    static let knopf: Int32 = 38
    static let symbol: Int32 = 22   // Kiste für ein 18-Punkt-SF-Symbol
    static let ueberLeiste: Int32 = 20
    static let leiste: Int32 = 32
    static let reihenAbstand: Int32 = 4
}

/// Die Haken einer Spalte. Eine Wahl malt nur die Haken um, statt die Ebene
/// neu zu bauen.
final class Wahlgruppe {
    private var zeilen: [(kennung: String, knopf: Widget, haken: Widget)] = []

    func aufnehmen(_ kennung: String, knopf: Widget, haken: Widget) {
        zeilen.append((kennung, knopf, haken))
    }

    func waehle(_ kennung: String) {
        for z in zeilen {
            let an = z.kennung == kennung
            gtk_widget_set_opacity(z.haken, an ? 1 : 0)
            if an { gtk_widget_add_css_class(z.knopf, "swiftly-gewaehlt") }
            else { gtk_widget_remove_css_class(z.knopf, "swiftly-gewaehlt") }
        }
    }
}

extension App {

    // MARK: Bausteine

    /// Einer der Symbolknöpfe oben rechts — 38 × 38, durchsichtig, beim
    /// Überfahren eine leise Fläche (Mac: `Symbolknopf`).
    func symbolknopf(_ name: String, beschriftung text: String,
                     aktion: @escaping () -> Void) -> (knopf: Widget?, zeichen: Playerzeichen) {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-symbolknopf")
        gtk_widget_set_size_request(knopf, Playermass.knopf, Playermass.knopf)
        gtk_widget_set_valign(knopf, GTK_ALIGN_START)
        let zeichen = Playerzeichen(name, groesse: Playermass.symbol)
        gtk_button_set_child(alsKnopf(knopf), zeichen.anzeige)
        gtk_widget_set_tooltip_text(knopf, text)
        beschriften(knopf, text)
        beiSignal(knopf, "clicked", aktion)
        return (knopf, zeichen)
    }

    /// Breite der Symbolreihe oben rechts — der stehende Titel hält ihr den
    /// Platz frei, wie `symbolreihe.hidden()` auf dem Mac.
    func symbolreihenBreite() -> Int32 {
        let anzahl: Int32 = hatFolgenebene ? 5 : 4
        return anzahl * Playermass.knopf + (anzahl - 1) * Playermass.reihenAbstand
    }

    var hatFolgenebene: Bool {
        laufenderTitel?.type == "Episode" && laufenderTitel?.seriesId != nil
    }

    /// Grund jeder Ebene: flach, Schwarz. Nimmt jeden Klick an, damit darunter
    /// nichts spult (Mac: `Ebenengrund`, `.onTapGesture {}`).
    private func ebenengrund() -> Widget! {
        let grund = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(grund, "swiftly-ebenengrund")
        gtk_widget_set_hexpand(grund, 1)
        gtk_widget_set_vexpand(grund, 1)
        return grund
    }

    /// Kopfzeile einer Ebene: links, was sie zeigt, rechts das X — mit
    /// denselben Maßen wie die Kopfzeile des Players, damit beide X
    /// aufeinander liegen.
    private func ebenenkopf(links: Widget?) -> Widget! {
        let kopf = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        gtk_widget_set_valign(kopf, GTK_ALIGN_START)
        gtk_widget_set_margin_top(kopf, Playermass.oben)
        gtk_widget_set_margin_start(kopf, Playermass.seite)
        gtk_widget_set_margin_end(kopf, Playermass.seite)
        let links = links ?? stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_hexpand(links, 1)
        anhaengen(kopf, links)
        let (x, _) = symbolknopf("schliessen", beschriftung: uebersetzt("Schließen")) {
            [weak self] in self?.ebeneSchliessen()
        }
        spielerEbenenX = x
        anhaengen(kopf, x)
        return kopf
    }

    /// Eine Spalte mit fester Überschrift; nur die Zeilen darunter scrollen
    /// für sich — bei 50 und mehr Untertiteln bleibt die andere Spalte in
    /// Ruhe (Mac: `Wahlspalte`, 200 breit).
    func ebenenspalte(_ titel: String, _ fuellen: (Widget?) -> Void) -> Widget! {
        let aussen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(aussen, 200, -1)
        gtk_widget_set_vexpand(aussen, 1)

        let kopf = beschriftung(titel, stil: "swiftly-spaltentitel")
        gtk_label_set_xalign(OpaquePointer(kopf), 0)
        gtk_label_set_ellipsize(OpaquePointer(kopf), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(kopf), 1)
        gtk_widget_set_margin_start(kopf, 10)
        gtk_widget_set_margin_end(kopf, 10)
        gtk_widget_set_margin_bottom(kopf, 9)
        anhaengen(aussen, kopf)

        let inhalt = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)
        gtk_widget_set_valign(inhalt, GTK_ALIGN_START)
        gtk_widget_set_margin_bottom(inhalt, 12)
        let rolle: Widget! = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(rolle), GTK_POLICY_NEVER, GTK_POLICY_EXTERNAL)
        gtk_widget_set_vexpand(rolle, 1)
        gtk_scrolled_window_set_child(OpaquePointer(rolle), inhalt)
        weichesScrollen(rolle)
        anhaengen(aussen, rolle)
        fuellen(inhalt)
        return aussen
    }

    /// Haken und Name. Gewählt weiß und halbfett, sonst 62 % Weiß (Mac:
    /// `Ebenenzeile`).
    func ebenenzeile(_ text: String, kennung: String, gruppe: Wahlgruppe, gewaehlt: Bool,
                     auswahl: @escaping () -> Void) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-ebenenzeile")
        if gewaehlt { gtk_widget_add_css_class(knopf, "swiftly-gewaehlt") }
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 9)
        let haken = Playerzeichen("haken", groesse: 15)
        let hakenplatz = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        gtk_widget_set_size_request(hakenplatz, 17, -1)
        anhaengen(hakenplatz, haken.anzeige)
        gtk_widget_set_opacity(hakenplatz, gewaehlt ? 1 : 0)
        anhaengen(reihe, hakenplatz)
        let l = beschriftung(text)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
        // Ein Zeichen breit gewünscht, damit ein langer Name die Spalte nicht
        // über ihre 200 hinaus aufdrückt; `hexpand` gibt ihm den Rest.
        gtk_label_set_max_width_chars(OpaquePointer(l), 1)
        gtk_widget_set_hexpand(l, 1)
        anhaengen(reihe, l)
        gtk_button_set_child(alsKnopf(knopf), reihe)
        gtk_widget_set_tooltip_text(knopf, text)
        gruppe.aufnehmen(kennung, knopf: knopf, haken: hakenplatz!)
        beiSignal(knopf, "clicked") {
            gruppe.waehle(kennung)
            auswahl()
        }
        return knopf
    }

    /// Spalten nebeneinander, mittig, unter der Kopfzeile (Mac:
    /// `Spaltenreihe`, Abstand 45, oben `oben + knopf + 6`).
    private func spaltenebene(_ spalten: [Widget?]) -> Widget! {
        let ueber: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(ueber), ebenengrund())
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 45)
        gtk_widget_set_halign(reihe, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(reihe, GTK_ALIGN_FILL)
        gtk_widget_set_margin_top(reihe, Playermass.oben + Playermass.knopf + 6)
        for s in spalten { anhaengen(reihe, s) }
        gtk_overlay_add_overlay(OpaquePointer(ueber), reihe)
        gtk_overlay_add_overlay(OpaquePointer(ueber), ebenenkopf(links: nil))
        return ueber
    }

    // MARK: Öffnen und Schliessen

    /// Öffnet eine Ebene: sie blendet in 0,2 s ein, die Steuerung im selben
    /// Takt aus (Mac: `.animation(.easeInOut(duration: 0.2), value: offeneEbene)`).
    func ebeneOeffnen(_ ziel: Playerebene) {
        guard laufenderTitel != nil, let rahmen = spielerRahmen, offeneEbeneArt != ziel else { return }
        if let alt = offeneEbene { ebeneAbbauen(alt) }
        offeneEbeneArt = ziel
        let inhalt: Widget!
        switch ziel {
        case .spuren:        inhalt = spurenEbeneBauen()
        case .einstellungen: inhalt = einstellungenEbeneBauen()
        case .folgen:        inhalt = folgenEbeneBauen()
        }
        offeneEbene = inhalt
        gtk_widget_set_opacity(inhalt, 0)
        gtk_overlay_add_overlay(OpaquePointer(rahmen), inhalt)
        // Über allem, nur unter dem stehenden Titel.
        if let stand = spielerTitelstand { gtk_widget_insert_before(inhalt, rahmen, stand) }
        blenden(inhalt, auf: 1, dauer: 0.2, kennlinie: .easeOut)
        steuerungSichtbarkeit(dauer: 0.2)
        vorschauVerbergen()
        zeigerZeigen(true)
        angebotNachfuehren()
        if let x = spielerEbenenX { gtk_widget_grab_focus(x) }
        Protokoll.schreib("[Ebene] auf: \(ziel)")
        fflush(nil)
    }

    /// Schliesst die offene Ebene: sie blendet in 0,2 s aus, die Steuerung im
    /// selben Takt wieder ein, und **alles wird wieder bedienbar** — Klicks
    /// (`can-target`), Tasten (die Ebene hält keine mehr) und der Fokus, der
    /// auf den Knopf zurückgeht, der die Ebene geöffnet hat.
    func ebeneSchliessen() {
        guard let art = offeneEbeneArt else { return }
        if let alt = offeneEbene { ebeneAbbauen(alt) }
        offeneEbene = nil
        offeneEbeneArt = nil
        spielerFolgenListe = nil
        spielerFolgenScroller = nil
        spielerFolgenZiel = nil
        spielerEbenenX = nil
        guard spielerSteuerung != nil else { return }
        steuerungOffen = true
        steuerungSichtbarkeit(dauer: 0.2)
        steuerungZeigen()
        if let knopf = spielerEbenenknoepfe[art] { gtk_widget_grab_focus(knopf) }
        Protokoll.schreib("[Ebene] zu: \(art), Steuerung klickbar: \(gtk_widget_get_can_target(spielerSteuerung) != 0)")
        fflush(nil)
    }

    /// Nimmt eine Ebene aus dem Spiel: sofort ohne Klicks, dann ausblenden,
    /// dann aus dem Overlay. Herausgenommen wird erst, wenn sie noch dort
    /// hängt — das Widget selbst wird dabei nicht mehr angefasst, falls der
    /// Player inzwischen abgeräumt ist.
    private func ebeneAbbauen(_ alt: Widget!) {
        gtk_widget_set_can_target(alt, 0)
        gtk_widget_set_can_focus(alt, 0)
        let adresse = Int(bitPattern: alt)
        blenden(alt, auf: 0, dauer: 0.2, kennlinie: .easeOut) {
            gtk_widget_set_visible(alt, 0)
            aufHauptfaden { [weak self] in
                guard let self, let rahmen = self.spielerRahmen else { return }
                var kind = gtk_widget_get_first_child(rahmen)
                while let k = kind {
                    if Int(bitPattern: k) == adresse {
                        gtk_overlay_remove_overlay(OpaquePointer(rahmen), k)
                        return
                    }
                    kind = gtk_widget_get_next_sibling(k)
                }
            }
        }
    }

    /// Der stehende Titel: da, solange die Steuerung da ist, und über der
    /// Folgenebene — sonst nicht (Mac: `stehenderTitel`).
    func titelstandNachfuehren(dauer: Double? = nil) {
        guard let stand = spielerTitelstand else { return }
        let da = (steuerungOffen && offeneEbeneArt == nil) || offeneEbeneArt == .folgen
        blenden(stand, auf: da ? 1 : 0, dauer: dauer ?? (da ? 0.18 : 0.34),
                kennlinie: dauer != nil || da ? .easeOut : .easeInOut)
    }

    // MARK: Audio & Untertitel

    private func spurenEbeneBauen() -> Widget! {
        let tonJetzt = abspieler.tonspur
        let tongruppe = Wahlgruppe()
        let audio = ebenenspalte(uebersetzt("Audio")) { raum in
            for spur in tonspurnamen() {
                anhaengen(raum, ebenenzeile(spur.name, kennung: "\(spur.kennung)", gruppe: tongruppe,
                                            gewaehlt: spur.kennung == tonJetzt) {
                    [weak self] in self?.tonspurGewaehlt(spur.kennung)
                })
            }
        }
        let untertitelJetzt = abspieler.untertitelspur
        let utgruppe = Wahlgruppe()
        let untertitel = ebenenspalte(uebersetzt("Untertitel")) { raum in
            anhaengen(raum, ebenenzeile(uebersetzt("Aus"), kennung: "aus", gruppe: utgruppe,
                                        gewaehlt: untertitelJetzt < 0) {
                [weak self] in self?.untertitelGewaehlt(nil)
            })
            for spur in untertitelnamen() {
                anhaengen(raum, ebenenzeile(spur.name, kennung: "\(spur.kennung)", gruppe: utgruppe,
                                            gewaehlt: spur.kennung == untertitelJetzt) {
                    [weak self] in self?.untertitelGewaehlt(spur.kennung)
                })
            }
        }
        return spaltenebene([audio, untertitel])
    }

    // MARK: Einstellungen

    private func einstellungenEbeneBauen() -> Widget! {
        let bildgruppe = Wahlgruppe()
        let bild = ebenenspalte(uebersetzt("Bild")) { raum in
            for (kennung, fuellend) in [("original", false), ("fuellen", true)] {
                anhaengen(raum, ebenenzeile(uebersetzt(fuellend ? "Füllen" : "Original"),
                                            kennung: kennung, gruppe: bildgruppe,
                                            gewaehlt: wahlen.bildfuellend == fuellend) {
                    [weak self] in
                    guard let self else { return }
                    self.wahlen.bildfuellend = fuellend
                    self.wahlen.sichern()
                    self.abspieler.bildfuellend(fuellend)
                })
            }
        }
        let schlafgruppe = Wahlgruppe()
        let schlaf = ebenenspalte(uebersetzt("Schlafzeit")) { raum in
            anhaengen(raum, ebenenzeile(uebersetzt("Aus"), kennung: "aus", gruppe: schlafgruppe,
                                        gewaehlt: schlafminuten == nil) {
                [weak self] in
                guard let self else { return }
                self.schlafminuten = nil
                self.schlaftakt += 1
            })
            for minuten in Schlafzeiten.werte {
                anhaengen(raum, ebenenzeile(String(format: uebersetzt("%d Min."), minuten),
                                            kennung: "\(minuten)", gruppe: schlafgruppe,
                                            gewaehlt: schlafminuten == minuten) {
                    [weak self] in self?.schlafzeitSetzen(minuten)
                })
            }
        }
        let technikgruppe = Wahlgruppe()
        let technik = ebenenspalte(uebersetzt("Technikschild")) { raum in
            for (kennung, an) in [("aus", false), ("an", true)] {
                anhaengen(raum, ebenenzeile(uebersetzt(an ? "An" : "Aus"), kennung: kennung,
                                            gruppe: technikgruppe,
                                            gewaehlt: wahlen.technikschild == an) {
                    [weak self] in
                    guard let self else { return }
                    self.wahlen.technikschild = an
                    self.wahlen.sichern()
                    self.technikschildSetzen(an)
                })
            }
        }
        var spalten = [bild, schlaf, technik]
        // **Qualität: Direct Play oder eine Obergrenze.** Eine Obergrenze
        // heißt, der Server darf umwandeln — Direct Play ist dann aus. Nur
        // bei Wiedergabe vom Server, und nur, wenn das Konto umwandeln darf.
        // Gilt wie die Einstellung in der App und lädt den Film an derselben
        // Stelle neu.
        if umwandelnErlaubt, laufenderPlan?.url.isFileURL == false {
            let qualitaetgruppe = Wahlgruppe()
            let qualitaet = ebenenspalte(uebersetzt("Qualität")) { raum in
                anhaengen(raum, ebenenzeile(uebersetzt("Direct Play"), kennung: "direct",
                                            gruppe: qualitaetgruppe,
                                            gewaehlt: wahlen.immerDirectPlay) {
                    [weak self] in
                    guard let self else { return }
                    self.wahlen.immerDirectPlay = true
                    self.wahlen.sichern()
                    self.qualitaetGeaendert()
                })
                for stufe in Bitrate.stufen {
                    anhaengen(raum, ebenenzeile(Bitrate.text(stufe.wert), kennung: "\(stufe.wert)",
                                                gruppe: qualitaetgruppe,
                                                gewaehlt: !wahlen.immerDirectPlay
                                                    && wahlen.bitratenGrenze == stufe.wert) {
                        [weak self] in
                        guard let self else { return }
                        self.wahlen.immerDirectPlay = false
                        self.wahlen.bitratenGrenze = stufe.wert
                        self.wahlen.sichern()
                        self.qualitaetGeaendert()
                    })
                }
            }
            spalten.append(qualitaet)
        }
        return spaltenebene(spalten)
    }

    // MARK: Folgen

    /// Die Folgen der Serie — dieselben Zeilen wie auf der Serienseite
    /// (`folgenzeile`). Der Titel bleibt stehen, wo er im Player stand; an
    /// Stelle der Metazeile sitzt die Staffelwahl. **Beim Öffnen steht die
    /// Liste sofort da** (aus dem Speicher der Serienseite), übergeblendet
    /// wird nur beim Staffelwechsel (Mac: `FolgenEbene`).
    private func folgenEbeneBauen() -> Widget! {
        let ueber: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(ueber), ebenengrund())
        let saeule = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_overlay_add_overlay(OpaquePointer(ueber), saeule)

        let links = stapel(GTK_ORIENTATION_VERTICAL, abstand: 3)
        let platz = beschriftung(laufenderTitelzeile, stil: "swiftly-spielertitel")
        gtk_label_set_ellipsize(OpaquePointer(platz), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(platz), 0)
        gtk_widget_set_opacity(platz, 0)
        anhaengen(links, platz)
        let staffelwahlraum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_halign(staffelwahlraum, GTK_ALIGN_START)
        anhaengen(links, staffelwahlraum)
        anhaengen(saeule, ebenenkopf(links: links))

        let rolle: Widget! = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(rolle), GTK_POLICY_NEVER, GTK_POLICY_EXTERNAL)
        gtk_widget_set_vexpand(rolle, 1)
        gtk_widget_set_margin_top(rolle, 10)
        let innen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_margin_top(innen, 12)
        gtk_widget_set_margin_bottom(innen, 12)
        gtk_scrolled_window_set_child(OpaquePointer(rolle), innen)
        weichesScrollen(rolle)
        anhaengen(saeule, rolle)
        spielerFolgenListe = innen
        spielerFolgenScroller = rolle

        guard let laufend = laufenderTitel, let serieID = laufend.seriesId else { return ueber }
        spielerStaffelwahl = staffelwahlraum
        if let schon = staffelspeicher[serieID], !schon.isEmpty {
            staffelwahlFuellen(schon, laufend: laufend, serieID: serieID)
        }
        if let client {
            Task.detached { [self] in
                let staffeln = (try? await client.staffeln(seriesID: serieID)) ?? []
                aufHauptfaden {
                    guard self.offeneEbeneArt == .folgen, self.laufenderTitel?.seriesId == serieID,
                          !staffeln.isEmpty else { return }
                    let vorher = self.staffelspeicher[serieID]?.map(\.id)
                    self.staffelspeicher[serieID] = staffeln
                    guard vorher != staffeln.map(\.id) else { return }
                    self.staffelwahlFuellen(staffeln, laufend: laufend, serieID: serieID)
                }
            }
        }
        return ueber
    }

    /// Der Titel, wie er oben links steht: bei Folgen der Serienname.
    var laufenderTitelzeile: String {
        guard let item = laufenderTitel else { return "" }
        let serie = item.type == "Episode" ? item.seriesName : nil
        return (serie?.isEmpty == false ? serie : nil) ?? item.name
    }

    private func folgenlisteZeichnen(_ folgen: [Item], laufend: Item, scrollen: Bool) {
        guard let innen = spielerFolgenListe else { return }
        spielerFolgenZiel = nil
        leeren(innen)
        for folge in folgen {
            let zeile = folgenzeile(folge, laeuft: folge.id == laufend.id) {
                [weak self] gewaehlteFolge in
                guard let self else { return }
                self.ebeneSchliessen()
                // Die laufende Folge anklicken heisst: weiterschauen.
                guard gewaehlteFolge.id != self.laufenderTitel?.id else { return }
                self.wechsleZu(gewaehlteFolge)
            }
            anhaengen(innen, zeile)
            if scrollen, folge.id == laufend.id { spielerFolgenZiel = zeile }
        }
        guard let rolle = spielerFolgenScroller,
              let adj = gtk_scrolled_window_get_vadjustment(OpaquePointer(rolle)) else { return }
        gtk_adjustment_set_value(adj, 0)
        guard spielerFolgenZiel != nil else { return }
        // **Die laufende Folge in die Mitte**, sobald die Liste ausgelegt ist
        // — vorher kennt weder die Zeile ihren Ort noch der Scroller seine
        // Höhe. Im ersten Bild ist die Ebene noch fast durchsichtig.
        var erledigt = false
        laufen(auf: innen, dauer: 1.0, schritt: { [weak self] _ in
            guard !erledigt, let self, let zeile = self.spielerFolgenZiel,
                  let liste = self.spielerFolgenListe else { return }
            var r = graphene_rect_t()
            let seite = gtk_adjustment_get_page_size(adj)
            guard seite > 0, gtk_widget_compute_bounds(zeile, liste, &r) != 0,
                  r.size.height > 0 else { return }
            erledigt = true
            self.spielerFolgenZiel = nil
            let ziel = Double(r.origin.y) + 12 + Double(r.size.height) / 2 - seite / 2
            let hoechstens = gtk_adjustment_get_upper(adj) - seite
            gtk_adjustment_set_value(adj, min(max(ziel, 0), max(hoechstens, 0)))
        }, fertig: {})
    }

    private func folgenlisteAnzeigen(_ folgen: [Item], laufend: Item, ueberblenden: Bool) {
        folgenlisteZeichnen(folgen, laufend: laufend, scrollen: true)
        guard ueberblenden, let innen = spielerFolgenListe else { return }
        gtk_widget_set_opacity(innen, 0)
        blenden(innen, auf: 1, dauer: 0.25, kennlinie: .easeOut)
    }

    private func folgenFuerStaffelLaden(_ staffel: Item, serieID: String, laufend: Item,
                                        ueberblenden: Bool) {
        let gezeigt = folgenspeicher[staffel.id]?.map(\.id)
        if let schon = folgenspeicher[staffel.id] {
            folgenlisteAnzeigen(schon, laufend: laufend, ueberblenden: ueberblenden)
        }
        guard let client else { return }
        spielerFolgenStaffel = staffel.id
        Task.detached { [self] in
            let geladen = (try? await client.folgen(seriesID: serieID, seasonID: staffel.id)) ?? []
            aufHauptfaden {
                guard self.offeneEbeneArt == .folgen, self.spielerFolgenStaffel == staffel.id else { return }
                self.folgenspeicher[staffel.id] = geladen
                // Dieselbe Liste noch einmal zu bauen hiesse: Bilder neu
                // laden, Scrollstand weg — ein sichtbares Zucken für nichts.
                guard gezeigt != geladen.map(\.id) else { return }
                self.folgenlisteAnzeigen(geladen, laufend: laufend,
                                         ueberblenden: gezeigt == nil ? false : ueberblenden)
            }
        }
    }

    /// Die Staffelwahl der Serienseite, an Stelle der Metazeile. Bei nur einer
    /// Staffel steht nur ihr Name da.
    private func staffelwahlFuellen(_ staffeln: [Item], laufend: Item, serieID: String) {
        guard let raum = spielerStaffelwahl else { return }
        leeren(raum)
        guard !staffeln.isEmpty else { return }
        let anfangsWahl = staffeln.first { $0.id == laufend.seasonId }
            ?? staffeln.first { $0.indexNumber != nil && $0.indexNumber == laufend.parentIndexNumber }
            ?? staffeln[0]

        let pille: Widget! = gtk_button_new()
        gtk_widget_add_css_class(pille, "swiftly-chip")
        gtk_widget_set_halign(pille, GTK_ALIGN_START)
        let inhalt = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
        let text = beschriftung(anfangsWahl.name)
        anhaengen(inhalt, text)
        if staffeln.count > 1 {
            anhaengen(inhalt, Playerzeichen("winkel", groesse: 12).anzeige)
        }
        gtk_button_set_child(alsKnopf(pille), inhalt)
        anhaengen(raum, pille)

        let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(liste, "swiftly-staffelliste")
        gtk_widget_set_size_request(liste, 220, -1)
        gtk_widget_set_halign(liste, GTK_ALIGN_START)
        let aufklapp: Widget! = gtk_revealer_new()
        gtk_revealer_set_transition_type(alsAufklapp(aufklapp), GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
        gtk_revealer_set_transition_duration(alsAufklapp(aufklapp), 220)
        gtk_revealer_set_child(alsAufklapp(aufklapp), liste)
        gtk_widget_set_margin_top(aufklapp, 8)
        gtk_widget_set_halign(aufklapp, GTK_ALIGN_START)
        anhaengen(raum, aufklapp)

        var zeilen: [String: Widget?] = [:]
        for staffel in staffeln {
            let zeile = staffelzeile(staffel.name, gewaehlt: staffel.id == anfangsWahl.id) {
                [weak self] in
                guard let self else { return }
                gtk_label_set_text(OpaquePointer(text), staffel.name)
                for (kennung, w) in zeilen { self.staffelzeileMalen(w, gewaehlt: kennung == staffel.id) }
                gtk_revealer_set_reveal_child(alsAufklapp(aufklapp), 0)
                self.folgenFuerStaffelLaden(staffel, serieID: serieID, laufend: laufend, ueberblenden: true)
            }
            zeilen[staffel.id] = zeile
            anhaengen(liste, zeile)
        }
        beiSignal(pille, "clicked") {
            guard staffeln.count > 1 else { return }
            let offen = gtk_revealer_get_reveal_child(alsAufklapp(aufklapp)) == 0
            gtk_revealer_set_reveal_child(alsAufklapp(aufklapp), offen ? 1 : 0)
        }
        folgenFuerStaffelLaden(anfangsWahl, serieID: serieID, laufend: laufend, ueberblenden: false)
    }
}
