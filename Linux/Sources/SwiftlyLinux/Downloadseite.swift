import CGtk
import Foundation
import JellyfinKit

/// **Die Downloadseite auf Linux und Windows.**
///
/// Verhalten aus `VERHALTEN.md`, Abschnitt H — dasselbe wie auf dem Mac, und
/// dort steht auch schon, was gegenueber dem iPhone abweicht. Hier kommt
/// nichts Neues dazu: derselbe Kopf mit derselben Belegungszeile, dieselben
/// zwei Rubriken („Laedt gerade" und, was hier liegt), dieselbe Bearbeiten-
/// Weise mit Haken und einem Entfernen-Knopf, der erst erscheint, wenn etwas
/// angekreuzt ist.
///
/// **Auch das Bearbeiten ist uebernommen, nicht ersetzt.** Ein Knopf je Zeile
/// waere weniger Code gewesen; er waere aber eine zweite Bedienweise fuer
/// dieselbe Sache, und dafuer gibt es keinen Grund aus Eingabeart, Entfernung
/// oder Fenstergroesse — die drei, die eine Abweichung ueberhaupt
/// rechtfertigen duerfen.
///
/// Die Regeln — wer als Naechstes laedt, was entbehrlich ist, wie gruppiert
/// wird — stehen als `Downloadregeln` im Paket und nicht hier.
extension App {

    // MARK: Aufbau

    func downloadseiteBauen() -> Widget! {
        let blaettern: Widget! = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(blaettern),
                                       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_vexpand(blaettern, 1)

        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        // Dieselben Masse wie jede andere Seite: oben 52, seitlich 24.
        gtk_widget_set_margin_start(block, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(block, Int32(Stil.randAbstand))
        gtk_widget_set_margin_top(block, Int32(Stil.inhaltOben))
        gtk_widget_set_margin_bottom(block, 40)

        // Kopf: Titel links, Knoepfe rechts.
        let kopf = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
        let titelblock = stapel(GTK_ORIENTATION_VERTICAL, abstand: 4)
        gtk_widget_set_hexpand(titelblock, 1)
        // **`swiftly-titel-gross`, mit Strichen.** Ohne sie gibt es die
        // Klasse nicht, und die Ueberschrift stand als Fliesstext da — als
        // einzige Seite der App. Am Bild gefunden.
        let titel = beschriftung(uebersetzt("Downloads"), stil: "swiftly-titel-gross")
        gtk_label_set_xalign(OpaquePointer(titel), 0)
        anhaengen(titelblock, titel)
        // **Keine Belegungszeile mehr unter dem Titel** (Mac fa55d091): der
        // Kopf war der einzige mit zwei Zeilen, und Paul hat genau das
        // gesehen. Das Feld bleibt, damit ``downloadseiteFuellen`` weiter
        // hineinschreiben kann — es steht nur nicht mehr in der Seite.
        downloadbelegung = beschriftung("", stil: "swiftly-zweitzeile")
        anhaengen(kopf, titelblock)

        downloadentfernen = chip(uebersetzt("Entfernen"), symbol: "user-trash-symbolic")
        gtk_widget_set_valign(downloadentfernen, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(downloadentfernen, 0)
        beiSignal(downloadentfernen, "clicked") { [weak self] in
            guard let self else { return }
            let weg = Array(self.downloadgewaehlt)
            self.downloadgewaehlt = []
            self.downloadsEntfernen(weg)
            self.downloadbearbeitenUmlegen()
        }
        anhaengen(kopf, downloadentfernen)

        downloadbearbeitenknopf = chip(uebersetzt("Bearbeiten"), symbol: "document-edit-symbolic")
        gtk_widget_set_valign(downloadbearbeitenknopf, GTK_ALIGN_CENTER)
        beiSignal(downloadbearbeitenknopf, "clicked") { [weak self] in
            self?.downloadbearbeitenUmlegen()
        }
        anhaengen(kopf, downloadbearbeitenknopf)
        anhaengen(block, kopf)

        downloadliste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_margin_top(downloadliste, 18)
        anhaengen(block, downloadliste)

        // **Der Wortlaut des iPhones, woertlich** (Mac fa55d091): der
        // sachliche zweite Satz steht dort gar nicht mehr.
        downloadleer = leerzustand("folder-download-symbolic",
                                   uebersetzt("Noch nichts geladen"),
                                   uebersetzt("Lad was runter, bevor der Zug ins Funkloch fährt."))
        gtk_widget_set_visible(downloadleer, 0)
        anhaengen(block, downloadleer)

        gtk_scrolled_window_set_child(OpaquePointer(blaettern), block)
        // **Lesemass, nicht Fensterbreite** (`Macdownloads.swift`,
        // `maxWidth: 900`): eine Zeile aus Bild, Titel und Ring hat ueber
        // 1600 Punkt in der Mitte nichts zu sagen.
        deckeln(block, in: blaettern, auf: 900)
        return blaettern
    }

    // MARK: Fuellen

    /// **Neu gebaut wird, wenn sich etwas geändert hat, das man sieht.**
    ///
    /// Die Liste ist kurz, und eine Liste, die sich an drei Stellen selbst
    /// nachbessert, läuft auseinander — also wird sie ganz neu gebaut. Aber
    /// nicht bei jeder Fortschrittsmeldung: die kommt einmal je Sekunde,
    /// und dazwischen zählt die Zeile selbst weiter (``downloadZaehlen``).
    /// Ein Neubau je Meldung hätte den Schätzer jedes Mal neu aufgesetzt.
    ///
    /// Gerufen wird von `Downloadverwaltung.beiAenderung`; auch die Seite
    /// einer geladenen Serie hängt daran.
    func downloadseiteFuellen() {
        downloadschaetzerNachfuehren()
        downloadserieNachfuehren()
        guard downloadliste != nil else { return }

        let a = Downloadanzeige.geteilt
        let alle = downloads.posten
        let zeichen = "\(UInt(bitPattern: downloadliste))|" + downloadzeichen(alle)
            + "|\(downloadbearbeiten)|\(downloadgewaehlt.sorted())|\(a.listenfahrt)"
        guard zeichen != a.listenzeichen else { return }
        a.listenzeichen = zeichen

        leeren(downloadliste)
        let laufend = alle.filter { $0.stand != .fertig }
        let fertige = Downloadregeln.gruppiert(alle.filter { $0.stand == .fertig })

        gtk_label_set_text(OpaquePointer(downloadbelegung), belegungszeile())
        gtk_widget_set_visible(downloadbearbeitenknopf, alle.isEmpty ? 0 : 1)
        gtk_widget_set_visible(downloadentfernen,
                               downloadbearbeiten && !downloadgewaehlt.isEmpty ? 1 : 0)
        gtk_widget_set_visible(downloadleer, alle.isEmpty ? 1 : 0)

        if !laufend.isEmpty {
            anhaengen(downloadliste, downloadrubrik(uebersetzt("Lädt gerade")))
            for (i, p) in laufend.enumerated() {
                anhaengen(downloadliste, downloadlistenzeile(p))
                if i < laufend.count - 1 { anhaengen(downloadliste, zeilenstrich()) }
            }
        }

        if !fertige.isEmpty {
            // **Keine Überschrift über dem Geladenen** (Mac cc4e6e75). Hier
            // stand „Auf diesem Rechner" — auf der Downloadseite ist alles
            // auf diesem Rechner, der Satz sagte nichts. Der Abstand zu
            // „Lädt gerade" bleibt.
            anhaengen(downloadliste, luftHoch(laufend.isEmpty ? 4 : 26))
            for (i, g) in fertige.enumerated() {
                switch g {
                case let .einzeln(p):
                    anhaengen(downloadliste, downloadlistenzeile(p))
                case let .serie(sid, titel, folgen):
                    anhaengen(downloadliste, downloadseriengruppe(sid, titel, folgen))
                }
                if i < fertige.count - 1 { anhaengen(downloadliste, zeilenstrich()) }
            }
        }
    }

    /// Was an einer Zeile zu sehen ist, ohne den Fortschritt — der zählt
    /// selbst. Dazu, ob ein Bild auf der Platte liegt: es kommt nach.
    func downloadzeichen(_ posten: [Downloadposten]) -> String {
        posten.map { p in
            "\(p.id):\(p.stand):\(p.gesehen):\(p.nochAufDemServer):\(p.bytes)"
                + ":\(downloads.bild(fuer: p) != nil):\(downloads.bild(fuer: p, alsGruppe: true) != nil)"
                + (p.stand == .fertig ? ":\(p.geladen)" : "")
        }.joined(separator: ",")
    }

    /// **Der Schätzer je Posten, über jeden Neubau hinweg.** Eine neue
    /// Meldung geht hinein; wer nicht lädt, steht sofort (Mac cc4e6e75:
    /// „angehalten heißt stehen").
    private func downloadschaetzerNachfuehren() {
        let a = Downloadanzeige.geteilt
        let jetzt = Date()
        var da = Set<String>()
        for p in downloads.posten {
            da.insert(p.id)
            var s = a.schaetzer[p.id] ?? Fortschrittsschaetzer()
            if a.gemeldet[p.id] != p.geladen {
                s.melden(p.geladen, gesamt: p.bytes, um: jetzt)
                a.gemeldet[p.id] = p.geladen
            }
            if p.stand != .laedt { s.anhalten() }
            a.schaetzer[p.id] = s
        }
        for id in a.schaetzer.keys where !da.contains(id) {
            a.schaetzer[id] = nil
            a.gemeldet[id] = nil
        }
    }

    private func downloadrubrik(_ text: String) -> Widget! {
        // **20 Semifett in `schrift`, 26 darueber, 10 darunter** — die Rubrik
        // von `DownloadsView` auf dem Mac, nicht die der Seitenleiste.
        let r = beschriftung(text, stil: "swiftly-reihe")
        gtk_label_set_xalign(OpaquePointer(r), 0)
        gtk_widget_set_margin_top(r, 26)
        gtk_widget_set_margin_bottom(r, 10)
        return r
    }

    /// „12 Titel · 42,8 GB · 310 GB frei" — die Zahlen kommen aus dem Paket,
    /// damit sie hier so aussehen wie in den Einstellungen des Systems.
    private func belegungszeile() -> String {
        let b = Downloadregeln.belegung(downloads.posten)
        guard b.anzahl > 0 || downloads.posten.contains(where: { $0.stand != .fertig }) else {
            return uebersetzt("Nichts auf diesem Rechner")
        }
        let anzahl = String(format: uebersetzt("%d Titel"), b.anzahl)
        // **Und was noch frei ist.** Der Mac nennt es in derselben Zeile;
        // ohne die Zahl steht dort eine Belegung ohne Bezugsgroesse.
        return anzahl + " · " + Downloadregeln.groesse(b.bytes)
            + " · " + Downloadregeln.groesse(downloads.freierPlatz)
            + " " + uebersetzt("frei")
    }

    // MARK: Eine Zeile

    /// Eine Zeile der Downloadliste — mit deren Bearbeiten.
    private func downloadlistenzeile(_ p: Downloadposten) -> Widget! {
        downloadzeile(p, bearbeiten: downloadbearbeiten,
                      gewaehlt: downloadgewaehlt.contains(p.id),
                      fahrt: Downloadanzeige.geteilt.listenfahrt) { [weak self] in
            self?.downloadhakenUmlegen([p.id])
        }
    }

    /// **Die Masse kommen vom Mac, nicht aus dem Gefuehl.** Eine Folge liegt
    /// quer (142 x 80), ein Film und eine Serienzeile hochkant (76 x 114) —
    /// `MacDownloadzeile.quer`. Hier stand vorher 96 x 54 fuer alles.
    ///
    /// Dieselbe Zeile steht auf der Seite einer geladenen Serie; wer was
    /// angekreuzt hat, sagt der Aufrufer.
    func downloadzeile(_ p: Downloadposten, bearbeiten: Bool, gewaehlt: Bool,
                       fahrt: Downloadanzeige.Kreisfahrt,
                       umlegen: @escaping () -> Void) -> Widget! {
        let quer = p.art == .folge
        let laeuft = p.stand == .laedt || p.stand == .angehalten
        // Angehalten steht die Zahl dort, wo der Schätzer zuletzt war — nie
        // hinter der gemeldeten.
        var geladen = p.geladen
        if laeuft, var s = Downloadanzeige.geteilt.schaetzer[p.id] {
            geladen = max(s.wert(um: Date()), p.geladen)
            Downloadanzeige.geteilt.schaetzer[p.id] = s
        }
        return downloadgrundzeile(
            titel: p.titel,
            unten: p.stand == .laedt ? downloadLadetext(geladen, von: p.bytes)
                                     : downloadstandwort(p),
            warnend: p.stand == .fehler,
            quer: quer,
            bild: downloadbild(p),
            serie: quer,
            bearbeiten: bearbeiten, gewaehlt: gewaehlt, fahrt: fahrt, umlegen: umlegen,
            // **Der Balken nur, solange etwas laeuft oder angehalten ist.**
            // Bei „wartet" gibt es nichts zu zeigen, und auf einem Fehler
            // sieht ein halb gefuellter Balken aus wie Fortschritt.
            anteil: laeuft ? (p.bytes > 0 ? Double(geladen) / Double(p.bytes) : p.anteil) : nil,
            zaehlen: p.stand == .laedt ? (p.id, p.bytes) : nil,
            rechts: downloadknopf(p),
            // **Ein Klick auf die Zeile spielt ab** — auf dem Mac stand
            // dazu: „Das fehlte ganz." Abspielen und nicht die Detailseite,
            // denn die braucht den Server, und wer hier steht, hat
            // womoeglich keinen (H8).
            geklickt: { [weak self] in
                if bearbeiten { umlegen() }
                else if p.stand == .fertig { self?.downloadSpielen(p) }
            })
    }

    /// H12: eine Serie ist **eine** Zeile — und sie **öffnet ihre Seite**
    /// (Mac cc4e6e75): großes Bild, Name, Abspielknopf, darunter die Folgen
    /// nach Staffel. Hier klappte die Zeile vorher an Ort und Stelle auf —
    /// eine Liste unter dem Namen, ohne Bild und ohne Abspielknopf. Genau
    /// diese Fassung hat der Mac verworfen.
    private func downloadseriengruppe(_ sid: String, _ titel: String,
                                      _ folgen: [Downloadposten]) -> Widget! {
        let bytes = folgen.reduce(Int64(0)) { $0 + $1.bytes }
        let unten = String(format: uebersetzt("%d Folgen"), folgen.count)
            + " · " + Downloadregeln.groesse(bytes)

        // Rechts der Winkel, 36 breit, wo sonst der Knopf steht.
        let winkel: Widget! = gtk_image_new_from_icon_name("pan-end-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(winkel), 13)
        gtk_widget_add_css_class(winkel, "swiftly-leise")
        gtk_widget_set_size_request(winkel, 36, -1)
        gtk_widget_set_valign(winkel, GTK_ALIGN_CENTER)

        let ids = folgen.map(\.id)
        let umlegen: () -> Void = { [weak self] in self?.downloadhakenUmlegen(ids) }
        return downloadgrundzeile(
            titel: titel, unten: unten, warnend: false, quer: false,
            bild: folgen.first.flatMap { downloadbild($0, alsGruppe: true) },
            serie: true,
            bearbeiten: downloadbearbeiten,
            gewaehlt: !ids.isEmpty && ids.allSatisfy { downloadgewaehlt.contains($0) },
            fahrt: Downloadanzeige.geteilt.listenfahrt, umlegen: umlegen,
            anteil: nil, zaehlen: nil, rechts: winkel,
            geklickt: { [weak self] in
                guard let self else { return }
                if self.downloadbearbeiten { umlegen() }
                else { self.downloadserieOeffnen(sid, titel: titel) }
            })
    }

    private func downloadhakenUmlegen(_ ids: [String]) {
        if ids.allSatisfy({ downloadgewaehlt.contains($0) }) {
            downloadgewaehlt.subtract(ids)
        } else {
            downloadgewaehlt.formUnion(ids)
        }
        downloadseiteFuellen()
    }

    /// Bearbeiten an oder aus — **der Kreis kommt von links** (Mac cc4e6e75,
    /// `.move(edge: .leading)` in `sprung`, 0,22 s) und fährt beim Beenden
    /// dorthin zurück, bevor die Liste ohne ihn neu gebaut wird.
    func downloadbearbeitenUmlegen() {
        let a = Downloadanzeige.geteilt
        downloadbearbeiten.toggle()
        if !downloadbearbeiten { downloadgewaehlt = [] }
        a.listenfahrt = downloadbearbeiten ? .herein : .hinaus
        downloadseiteFuellen()
        a.listenfahrt = .steht
        guard !downloadbearbeiten, downloadliste != nil else { return }
        a.listenfahrt = .hinaus
        laufen(auf: downloadliste, dauer: 0.22, schritt: { _ in }, fertig: { [weak self] in
            a.listenfahrt = .steht
            self?.downloadseiteFuellen()
        })
    }

    /// Der gemeinsame Rumpf aller Zeilen — Kreis, Bild, Text, Balken,
    /// rechter Knopf. Eine Zeile, nicht zwei fast gleiche.
    private func downloadgrundzeile(titel: String, unten: String, warnend: Bool,
                                    quer: Bool, bild: URL?, serie: Bool,
                                    bearbeiten: Bool, gewaehlt: Bool,
                                    fahrt: Downloadanzeige.Kreisfahrt,
                                    umlegen: @escaping () -> Void,
                                    anteil: Double?, zaehlen: (String, Int64)?,
                                    rechts: Widget!,
                                    geklickt: @escaping () -> Void) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        // **Eigene Klasse, nicht `swiftly-zeile`** (Mac cc4e6e75, `Abdunkeln`):
        // der Druck dunkelt den Inhalt ab, statt eine graue Fläche hinter die
        // Zeile zu legen. `swiftly-zeile` ist die Zeile der Seitenleiste und
        // bleibt, wie sie ist.
        gtk_widget_add_css_class(knopf, "swiftly-dlzeile")
        if bearbeiten { gtk_widget_add_css_class(knopf, "swiftly-bearbeiten") }
        beiSignal(knopf, "clicked") { geklickt() }

        let aussen = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        gtk_widget_set_margin_top(aussen, 12)
        gtk_widget_set_margin_bottom(aussen, 12)
        gtk_widget_set_margin_start(aussen, 10)
        gtk_widget_set_margin_end(aussen, 10)

        // **Der Kreis kommt von links herein und schiebt die Zeile vor sich
        // her.** Er steht in einem Aufklapper, der seine Breite von null auf
        // voll zieht; die 16 Luft danach gehören zu ihm, sonst stünde beim
        // Hereinfahren schon eine Lücke da.
        if bearbeiten || fahrt == .hinaus {
            let haken = downloadhaken(an: gewaehlt, umlegen: umlegen)
            gtk_widget_set_margin_end(haken, 16)
            let fahrer: Widget! = gtk_revealer_new()
            gtk_revealer_set_transition_type(alsAufklapp(fahrer),
                                             GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT)
            gtk_revealer_set_child(alsAufklapp(fahrer), haken)
            gtk_widget_set_valign(fahrer, GTK_ALIGN_CENTER)
            gtk_revealer_set_transition_duration(alsAufklapp(fahrer), 0)
            gtk_revealer_set_reveal_child(alsAufklapp(fahrer), fahrt == .herein ? 0 : 1)
            gtk_revealer_set_transition_duration(alsAufklapp(fahrer), 220)
            if fahrt != .steht {
                let kiste = gehalten(fahrer)
                let herein = fahrt == .herein
                aufHauptfaden {
                    defer { losgelassen(kiste) }
                    gtk_revealer_set_reveal_child(alsAufklapp(kiste.widget), herein ? 1 : 0)
                }
            }
            anhaengen(aussen, fahrer)
        }

        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 16)
        gtk_widget_set_hexpand(zeile, 1)
        anhaengen(aussen, zeile)

        let (huelle, feld) = gerahmtesBild(breite: quer ? 142 : 76,
                                           hoehe: quer ? 80 : 114, stil: "swiftly-plakat")
        if let bild {
            bildLaden(feld, url: bild, schluessel: "dl-\(bild.lastPathComponent)", sofort: true)
        } else {
            zeichenLegen(huelle, serie: serie)
        }
        anhaengen(zeile, huelle)

        let text = stapel(GTK_ORIENTATION_VERTICAL, abstand: 4)
        gtk_widget_set_hexpand(text, 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        let t = beschriftung(titel, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(t), 0)
        gtk_label_set_ellipsize(OpaquePointer(t), PANGO_ELLIPSIZE_END)
        anhaengen(text, t)

        let u = beschriftung(unten, stil: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(u), 0)
        gtk_label_set_ellipsize(OpaquePointer(u), PANGO_ELLIPSIZE_END)
        gtk_widget_add_css_class(u, warnend ? "swiftly-warnung" : "dim-label")
        anhaengen(text, u)

        var balken: Ladebalken?
        if let anteil {
            let b = Ladebalken(anteil: anteil)
            gtk_widget_set_margin_top(b.anzeige, 4)
            anhaengen(text, b.anzeige)
            balken = b
        }
        if let z = zaehlen { downloadZaehlen(z.0, bytes: z.1, zeile: u, balken: balken) }
        anhaengen(zeile, text)
        anhaengen(zeile, rechts)

        gtk_button_set_child(alsKnopf(knopf), aussen)
        return knopf
    }

    /// **Kein `GtkCheckButton`.** Diese Oberflaeche benutzt keine
    /// Standardsteuerelemente (E4) — sie zeichnet ihre Schalter selbst, und
    /// ueberall sonst steht dafuer `object-select-symbolic` in einer eigenen
    /// Kapsel. Hier stand eine Runde lang das GTK-Kaestchen, und das ist
    /// derselbe Fehler wie ein Systemdialog mitten in der App.
    private func downloadhaken(an: Bool, umlegen: @escaping () -> Void) -> Widget! {
        let haken = nebenknopf("object-select-symbolic",
                               name: an ? uebersetzt("Abwählen") : uebersetzt("Auswählen"),
                               aktiv: an)
        gtk_widget_set_valign(haken, GTK_ALIGN_CENTER)
        beiSignal(haken, "clicked") { umlegen() }
        return haken
    }

    /// **Ein Knopf, sechs Zustaende** — dieselben Aussagen wie der Ring auf
    /// dem Mac, nur als Zeichenknopf, weil es hier keinen gezeichneten Ring
    /// gibt.
    private func downloadknopf(_ p: Downloadposten) -> Widget! {
        let (symbol, name, tat): (String, String, () -> Void)
        switch p.stand {
        case .laedt:
            symbol = "media-playback-pause-symbolic"
            name = uebersetzt("Anhalten")
            tat = { [weak self] in self?.downloads.anhalten(p.id) }
        // **Wartend ist nicht laufend.** `.wartet` stand hier mit `.laedt`
        // zusammen und loeste damit „Anhalten" aus — bei etwas, das noch gar
        // nicht laeuft. Der Mac fasst `.angehalten`, `.fehler` und `.wartet`
        // zusammen und setzt fort (`Macdownloads.swift:115`).
        case .angehalten, .wartet:
            symbol = "media-playback-start-symbolic"
            name = uebersetzt("Fortsetzen")
            tat = { [weak self] in self?.downloads.fortsetzen(p.id) }
        case .fehler:
            symbol = "view-refresh-symbolic"
            name = uebersetzt("Nochmal versuchen")
            tat = { [weak self] in self?.downloads.fortsetzen(p.id) }
        case .fertig:
            symbol = "media-playback-start-symbolic"
            name = uebersetzt("Abspielen")
            tat = { [weak self] in self?.downloadSpielen(p) }
        }
        let knopf = nebenknopf(symbol, name: name)
        gtk_widget_set_valign(knopf, GTK_ALIGN_CENTER)
        beiSignal(knopf, "clicked") { tat() }
        return knopf
    }

    private func downloadstandwort(_ p: Downloadposten) -> String {
        switch p.stand {
        case .wartet:     return uebersetzt("Wartet")
        case .laedt:
            guard p.bytes > 0 else { return Downloadregeln.groesse(p.geladen) }
            return Downloadregeln.groesse(p.geladen) + " / " + Downloadregeln.groesse(p.bytes)
        case .angehalten: return uebersetzt("Angehalten")
        case .fehler:     return p.grund ?? uebersetzt("Fehler")
        case .fertig:
            // **H9: verschwindet der Titel vom Server, bleibt die Datei — und
            // die Zeile traegt einen leisen Hinweis.** Mitloeschen waere eine
            // boese Ueberraschung im Flugzeug, und das ist der Fall, fuer den
            // die ganze Funktion gebaut ist. Der Hinweis fehlte hier ganz.
            var stuecke = [Downloadregeln.groesse(p.geladen)]
            if let behaelter = p.container, !behaelter.isEmpty {
                stuecke.append(behaelter.uppercased())
            }
            if !p.nochAufDemServer {
                stuecke.append(uebersetzt("nicht mehr auf dem Server"))
            }
            return stuecke.joined(separator: " · ")
        }
    }

    /// Das Bild kommt **von der Platte**, nicht vom Server — sonst waere die
    /// Seite in genau dem Fall leer, fuer den es sie gibt. Fehlt es, bleibt
    /// das Zeichen stehen.
    private func downloadbild(_ p: Downloadposten, alsGruppe: Bool = false) -> URL? {
        if let da = downloads.bild(fuer: p, alsGruppe: alsGruppe) { return da }
        // **Und sonst vom Server** — solange einer da ist. Der Mac faellt an
        // derselben Stelle auf `plakatURL` zurueck; ohne das bliebe die
        // Flaeche leer, obwohl das Bild eine Leitung weit weg liegt.
        return adressen?.bauen(itemID: alsGruppe ? (p.serienId ?? p.id) : p.id,
                               mass: .hoechstensHoch(300))
    }

    // MARK: Abspielen

    /// **Aus der Datei, nicht vom Server.**
    ///
    /// Der Player bekommt dieselbe `Item`-Form wie sonst — die baut
    /// `Downloadposten.alsItem` im Paket — und statt einer Serveradresse den
    /// Pfad auf der Platte. Alles Weitere ist derselbe Weg.
    func downloadSpielen(_ p: Downloadposten) {
        guard let pfad = downloads.datei(fuer: p.id) else { return }
        spielerOeffnen(p.alsItem, ab: 0, ausDatei: pfad)
    }
}
