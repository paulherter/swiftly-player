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
        // **Eine Sammlung ist keine Detailseite.** Wer auf dem Server Filme
        // zu Sammlungen gruppiert, bekommt sie als Kachel mitten in der
        // Bibliothek; sie lief hier auf die Filmseite und stand leer da.
        // Wie auf dem iPhone (`HauptView`, `SammlungView(art: nil)`): die
        // Sammlungsseite, ohne Gattung, also alles, was darin steht.
        if item.type == "BoxSet" {
            sammlungOeffnen(item, art: nil)
            return
        }
        // **Eine Folge bekommt keine eigene Seite** (A8). Jeder Weg zu einer
        // Folge — aus „Zuletzt hinzugefügt", aus „Nächste Folge" — führt auf
        // die **Serienseite**, mit der Staffel der Folge schon gewählt. Eine
        // Seite nur für eine Folge trüge nichts, was nicht in der Folgenliste
        // schon steht.
        guard item.type == "Episode", let serieID = item.seriesId, let client else {
            startStaffel = nil
            startStaffelNummer = nil
            seitenstapel[bereich, default: []].append(item)
            detailZeigen(item)
            return
        }
        // **Die Staffel frisch holen, nicht die der Kachel glauben.** Der
        // Listeneintrag trägt die Staffel, die er beim Laden hatte; wer eine
        // Staffel zu Ende sieht und die nächste dazulegt, hat dort weiter die
        // alte stehen. Dieselbe Abhilfe wie auf dem Mac (`StaffelZiel`).
        // **Was das Ueberfahren schon geholt hat, steht sofort** — siehe
        // ``serieVorholen(_:)``. Ohne das lief hier bei jedem Klick derselbe
        // Abruf noch einmal.
        let schon = vollspeicher[serieID]
        Task.detached { [self] in
            // Eigene Aufgaben statt `async let` (siehe ``nebenher(_:)``).
            let frisch = nebenher { try? await client.item(id: item.id) }
            let serie = schon == nil ? nebenher { try? await client.item(id: serieID) } : nil
            let f = await frisch.value
            let s = await serie?.value ?? schon
            aufHauptfaden {
                guard let s else { return }
                // **Beides frisch, Kennung und Nummer.** Der Mac holte lange
                // nur die Kennung nach (`StaffelZiel.frischeStaffelID`) — und
                // liefert der Server an einer Folge keine `SeasonId`, was A10
                // ausdruecklich als gemessenen Fall nennt, traegt allein die
                // Nummer den Vergleich. Dann waere es die veraltete gewesen.
                // Seit dem 13.09.2026 zieht der Mac beides nach.
                self.startStaffel = f?.seasonId ?? item.seasonId
                self.startStaffelNummer = f?.parentIndexNumber ?? item.parentIndexNumber
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
            detailZeigen(oben, schub: .zurueck)
        } else {
            bereichZeigen(bereich.kennung, schub: .zurueck)
        }
    }

    /// Startet einen Titel. **Nur „Weiterschauen" nimmt diesen Weg** (A1);
    /// alles andere öffnet erst die Übersicht (A2, A3, A7b).
    ///
    /// **Ohne `ab` gilt die Stelle vom Server, frisch geholt** (M5, wie
    /// iOS `HomeView.starte`): die Stelle in der Kachel ist oft veraltet —
    /// wer auf dem Handy weitergeschaut hat, saehe sonst ein Stueck doppelt.
    func starte(_ item: Item, ab: Double? = nil) {
        spielerOeffnen(item, ab: ab ?? item.fortsetzenAb ?? 0, stelleFrisch: ab == nil)
    }

    // MARK: - Aufbau

    func detailZeigen(_ item: Item, schub: Schub = .tiefer) {
        // **Eine Person ist keine Detailseite** — sie hat keinen Hauptknopf,
        // keine Aktionsreihe und keine Datei. Die Weiche steht hier und nicht
        // beim Aufrufer, aus demselben Grund, aus dem A8 hier steht: jeder Weg
        // auf eine Person soll dieselbe Seite ergeben, egal wer ihn nimmt.
        if item.type == "Person" {
            personseiteZeigen(item, schub: schub)
            return
        }
        detailBeruehrt = false
        abschnitte = []
        let scheibe = naechsteScheibe()

        let seite = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        // **Ein Kasten malt den Ton, nicht zwei.**
        //
        // Vorher trugen Kopfzone und Unterbau ihn je selbst — zwei
        // gleichfarbige Flächen, die aneinanderstossen. Genau an ihrer Kante
        // stand der Strich, und zwar hartnäckig: beim Öffnen, beim Scrollen,
        // und nach einem Scrollen hin und zurück war er weg. Das ist kein
        // Farbfehler, das ist die Kante selbst — GTK zeichnet die Ränder
        // zweier Kästen einzeln, und wo sie sich treffen, scheint auf einem
        // halben Bildpunkt der Grund durch.
        //
        // Gibt es die Kante nicht, kann dort auch nichts durchscheinen. Der
        // Verlauf liegt jetzt als **ein** Anstrich auf der ganzen Seite: Ton
        // über die Höhe der Kopfzone, dann 260 Punkte nach `grund` — dieselbe
        // Länge wie auf dem Mac.
        // **Die Farbe des Kopfbilds unter der ganzen Seite** (1.0.5, wie
        // iPhone und Mac `Stimmungsgrund`): je Seite eine eigene Klasse, damit
        // die neue nicht in der Farbe der vorigen einfährt (``Tonblatt``).
        // `swiftly-bildton` trägt, was über Bildfarbe gilt — Knöpfe weiß 8 %.
        let klasse = Tonblatt.neueKlasse()
        gtk_widget_add_css_class(seite, "swiftly-bildton")
        gtk_widget_add_css_class(seite, klasse)

        // **Der Ton liegt auf einer eigenen Lage unter der Seite** und
        // blendet ein, wenn er nach dem Öffnen kommt — wie auf Apple
        // (`Stimmungslader`, 0,55 s). Vorher trug die Seite ihn selbst als
        // Hintergrundbild, und das sprang: ein `transition` auf
        // `background-image` greift in GTK nicht, wenn eine Regel neu
        // hinzukommt. Die Deckung einer Lage blendet zuverlässig.
        // Der Grund darunter (`lagen`) ist `grund`; die Seite selbst ist
        // durchsichtig. Die Seite misst, die Lage folgt ihr.
        let tonlage: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_add_css_class(tonlage, "swiftly-seitenton")
        gtk_widget_add_css_class(tonlage, klasse)
        gtk_widget_set_can_target(tonlage, 0)
        let lagen: Widget! = gtk_overlay_new()
        gtk_widget_add_css_class(lagen, "swiftly-seitenton")
        gtk_overlay_set_child(OpaquePointer(lagen), tonlage)
        gtk_overlay_add_overlay(OpaquePointer(lagen), seite)
        gtk_overlay_set_measure_overlay(OpaquePointer(lagen), seite, 1)
        Tonblatt.lageMerken(tonlage, klasse: klasse)
        if let schon = Tonblatt.merkt(item.id) {
            Tonblatt.setzen(schon, klasse: klasse)
        } else {
            gtk_widget_set_opacity(tonlage, 0)
        }

        // **Der Ton gehört zum Kopf, nicht zur Seite.**
        //
        // Auf dem Mac steht er als `.background` an der `ScrollView` und
        // bleibt stehen, während der Inhalt darüber wegläuft. Dort geht das,
        // weil die Blenden das Bild **maskieren**: es wird durchsichtig, und
        // was darunter liegt, ist gleichgültig.
        //
        // Hier wird übermalt. Damit muss die Farbe an jeder Stelle die des
        // Untergrunds sein — und ein stehender Untergrund unter einem
        // laufenden Bild kann das nicht leisten. Genau daher der Strich an der
        // Unterkante, den
        //
        // Also trägt die Kopfzone ihren Ton selbst, gleichmäßig, und darunter
        // steht ein eigener Auslauf von 260 Punkten nach `grund` — dieselbe
        // Länge wie auf dem Mac. Beide laufen mit dem Inhalt, also liegt
        // nichts je daneben. Der Unterschied zum Mac: dort bleibt der Ton beim
        // weiten Scrollen oben am Fensterrand stehen, hier verschwindet er mit
        // der Kopfzone.

        let scroller = seitenscroller()
        gtk_scrolled_window_set_child(OpaquePointer(scroller), lagen)
        detailScroller = scroller
        beiSignal(scroller, "destroy") { [weak self] in
            if self?.detailScroller == scroller { self?.detailScroller = nil }
        }

        // **Der Zurückweg gehört in den Inhalt, nicht in die Systemleiste**
        // (E9). Er schwebt über der Seite, damit er beim Blättern stehen
        // bleibt; der Titel daneben blendet ein, sobald der grosse Titel
        // darunter verschwindet.
        let ueber: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(ueber), scroller)
        gtk_overlay_add_overlay(OpaquePointer(ueber), detailkopfBauen(item))

        hinweisfeld = beschriftung("", stil: "swiftly-hinweis")
        gtk_widget_set_visible(hinweisfeld, 0)
        gtk_widget_set_halign(hinweisfeld, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(hinweisfeld, GTK_ALIGN_END)
        gtk_widget_set_margin_bottom(hinweisfeld, 32)
        gtk_overlay_add_overlay(OpaquePointer(ueber), hinweisfeld)
        // **Das Feld stirbt mit der Seite.** Ohne das zeigte `hinweisfeld`
        // nach dem Verlassen der Seite ins Leere, und ein spaeter Fehler
        // (Serienseite, ``melden(_:)`` nach einer Antwort) oder die Frist des
        // Ausblendens griff auf freigegebenen Speicher — ein Absturz, der nur
        // auftritt, wenn man schnell genug zurueckgeht.
        let dieses = hinweisfeld
        beiSignal(hinweisfeld, "destroy") { [weak self] in
            if self?.hinweisfeld == dieses { self?.hinweisfeld = nil }
        }
        anhaengen(detailhuelle, ueber)

        // Der magere Listeneintrag steht sofort, der volle Satz kommt nach.
        // **Der Kopf hat feste Plätze** — es wandert nichts, wenn ein Text
        // nachkommt, also darf er kommen, wann er kommt.
        aufbauenMit(item, in: seite, mager: true)
        titelNachladen(item, in: seite)
        // Den Titel oben einblenden, sobald der grosse unter der Leiste
        // verschwindet: ab 98 − 24 = 74, über die 42 Punkt seiner Höhe.
        let senkrecht = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))!
        beiSignalRoh(UnsafeMutableRawPointer(senkrecht), "value-changed") { [weak self] in
            guard let self, let kopf = self.detailkopfTitel else { return }
            let v = gtk_adjustment_get_value(senkrecht)
            // **Ab wo die Leiste kommt — hergeleitet, nicht geschätzt.** Der
            // große Titel beginnt 98 unter der Oberkante des Heldenbildes und
            // ist 42 hoch; die Leiste ist 24 hoch. Seine Oberkante erreicht
            // ihre Unterkante also bei 98 − 24 = 74, und 42 später ist er ganz
            // darunter. Genau über diese Strecke blendet sie ein.
            let staerke = min(max((v - 74) / 42, 0), 1)
            gtk_widget_set_opacity(kopf, staerke)
            if let leiste = self.detailkopfLeiste { gtk_widget_set_opacity(leiste, staerke) }
            if let verlauf = self.detailkopfVerlauf {
                gtk_widget_set_opacity(verlauf, 1 - staerke)
            }
        }

        // **Erst auslegen, dann schieben.** Eine Seite, die während der Fahrt
        // noch umbricht, ruckelt — dasselbe, was auf dem Mac hinter
        // „losfahren, sobald die Seite wirklich steht" steht.
        schieben(zu: scheibe, richtung: schub)
    }

    /// **Ein kurzer Satz, der von selbst wieder geht.**
    ///
    /// Der Mac hat dafür den `Hinweisstreifen` — drei Sekunden, dann weg. Auf
    /// Linux gab es gar nichts: „Fortschritt zurückgesetzt", „kein Trailer",
    /// „danach kommt nichts mehr" fielen einfach unter den Tisch, und der
    /// Nutzer sah einen Knopf, der scheinbar nichts tat.
    func melden(_ text: String) {
        guard let feld = hinweisfeld else { return }
        gtk_label_set_text(OpaquePointer(feld), text)
        gtk_widget_set_visible(feld, 1)
        gtk_widget_set_opacity(feld, 1)
        hinweistakt += 1
        let meins = hinweistakt
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            aufHauptfaden {
                guard self.hinweistakt == meins, self.hinweisfeld != nil else { return }
                sanft(auf: self.hinweisfeld, von: 1, nach: 0) {
                    gtk_widget_set_opacity(self.hinweisfeld, $0)
                }
            }
        }
    }

    /// **Alles unter der Beschreibung kommt auf einmal** (iPhone `83677a44`,
    /// `ItemDetailView.untenDa`).
    ///
    /// Besetzung, Extras, Teil der Sammlung, Ähnliches und der Dateiauszug
    /// hatten hier je einen eigenen Platz und je einen eigenen Abruf; sie
    /// trafen einzeln ein, drückten sich in die Seite und schoben den Rest
    /// vor sich her. Jetzt wartet die Seite auf alle Antworten und den Plan
    /// und blendet sie gemeinsam ein, zusammen mit dem Beleg im Kopf — keine
    /// Platzhalter, kein Leerhinweis, solange noch geladen wird. Was fehlt,
    /// fehlt als Reihe; ein Störhinweis stand hier auch vorher nicht.
    private func untenNachladen(_ titel: Item, in block: Widget!, beleg: Widget!) {
        guard let client else { return }
        let blockKiste = gehalten(block)
        let gattung = Bibliotheksgattung.art(zuTyp: titel.type)
        // Derselbe Auftrag wie der Beleg oben — kein zweiter POST.
        let planauftrag = planAuftrag(titel)
        Task.detached { [self] in
            // Eigene Aufgaben statt `async let` (siehe ``nebenher(_:)``).
            let extraRoh = nebenher { try? await client.extras(itemID: titel.id) }
            let aehnlichRoh = nebenher { try? await client.aehnliche(itemID: titel.id, zu: titel) }
            let sammlungRoh = nebenher {
                await self.sammlungsreihenHolen(titel, art: gattung, client: client)
            }
            let plan = await planauftrag?.value
            // Extras sind kein eigener Abschnitt mit Aussage: fehlen sie,
            // fehlt die Reihe.
            let extras = (await extraRoh.value) ?? []
            // Doppelte Kennungen raus — dieselbe Regel wie in Suche,
            // Startseite und Merkliste (iPhone `ItemDetailView`).
            let aehnliche = Listenregeln.ohneDoppelte((await aehnlichRoh.value) ?? [])
            let sammlungen = await sammlungRoh.value
            nachDemSchub {
                defer { losgelassen(blockKiste) }
                guard let block = blockKiste.widget else { return }
                if !titel.darsteller.isEmpty {
                    anhaengen(block, self.besetzungsreihe(titel.darsteller, herkunft: titel.name))
                }
                if !extras.isEmpty {
                    anhaengen(block, self.extrareihe(extras, titel: uebersetzt("Extras")))
                }
                // Über „Ähnliches": die Sammlung ist die nähere Verwandtschaft.
                for (sammlung, andere) in sammlungen {
                    if let gattung {
                        anhaengen(block, self.sammlungsreihe(sammlung, titel: andere, art: gattung))
                    }
                }
                if !aehnliche.isEmpty {
                    anhaengen(block, self.reiheBauen(titel: uebersetzt("Ähnliches"), art: .neu,
                                                     items: aehnliche))
                }
                // **Der Dateiauszug ganz unten** — er beantwortet eine Frage,
                // die man erst später stellt. Derselbe Plan trägt die Quelle,
                // der Auszug kostet keinen zweiten Abruf.
                if let quelle = plan?.quelle {
                    let raum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
                    gtk_widget_set_margin_start(raum, Int32(Stil.randAbstand))
                    gtk_widget_set_margin_end(raum, Int32(Stil.randAbstand))
                    anhaengen(raum, self.dateizeile(quelle))
                    anhaengen(block, raum)
                }
                // **Ein Einblenden, nicht fünf.** Der Beleg oben kommt für
                // sich (``planNachladen``) — er wartete sonst auf alles hier.
                if gtk_widget_get_first_child(block) != nil {
                    gtk_widget_set_opacity(block, 0)
                    gtk_widget_set_visible(block, 1)
                    blenden(block, auf: 1, dauer: Stil.zeitBlendeHerein)
                }
            }
        }
    }

    /// **„Teil der Sammlung"** — die anderen Titel der Sammlung, in ihrer
    /// Folge, ueber „Aehnliches": die Sammlung ist die naehere
    /// Verwandtschaft (Mac `Sammlungsreihe`). Der Kopf oeffnet die
    /// Sammlungsseite. Hoechstens zwei Reihen; steht ein Film in mehr
    /// Sammlungen, sind die uebrigen meist automatisch angelegte Doppel.
    /// Fehlt die Sammlung, fehlt die Reihe — wie bei den Extras.
    ///
    /// Das Verzeichnis kommt über ``angebotLaden(dann:)``, das auf dem
    /// Hauptfaden zurückruft; bis dahin wartet dieser Abruf, die übrigen
    /// laufen daneben.
    private func sammlungsreihenHolen(_ titel: Item, art gattung: String?,
                                      client: JellyfinClient) async -> [(Sammlung, [Item])] {
        guard let gattung else { return [] }
        let sammlungen: [Sammlung] = await withCheckedContinuation { fertig in
            aufHauptfaden {
                self.angebotLaden {
                    guard self.angebotFuer != nil, let verzeichnis = self.sammlungsverzeichnis else {
                        fertig.resume(returning: [])
                        return
                    }
                    fertig.resume(returning: Array(verzeichnis.sammlungen(mit: titel).prefix(2)))
                }
            }
        }
        var gefunden: [(Sammlung, [Item])] = []
        for sammlung in sammlungen {
            let quelle = Regalquelle(eltern: sammlung.id, art: gattung, sammlung: true)
            guard let liste = try? await client.items(parentID: quelle.eltern, limit: 100,
                                                      sortBy: Sortierung.erscheinung.feld,
                                                      sortOrder: quelle.richtung(.erscheinung),
                                                      recursive: quelle.rekursiv,
                                                      includeItemTypes: quelle.typen).items
            else { continue }
            let andere = Listenregeln.ohneDoppelte(liste).filter { $0.id != titel.id }
            if !andere.isEmpty { gefunden.append((sammlung, andere)) }
        }
        return gefunden
    }

    /// Kopf „Teil der Sammlung" mit Winkel, darunter der Name, dann die Reihe.
    private func sammlungsreihe(_ sammlung: Sammlung, titel: [Item], art gattung: String) -> Widget! {
        let reihe = reiheBauen(titel: uebersetzt("Teil der Sammlung"), art: .neu, items: titel)
        // Die Ueberschrift der Reihe wird zum Knopf: Titel und Winkel, der
        // Name der Sammlung darunter (Mac: 5 zwischen Titel und Winkel, 2
        // zwischen den Zeilen, Winkel 13 halbfett, sehr leise, unter dem
        // Zeiger weiss).
        guard let ueberschrift = gtk_widget_get_first_child(reihe) else { return reihe }
        g_object_ref(UnsafeMutableRawPointer(ueberschrift))
        gtk_box_remove(alsBox(reihe), ueberschrift)
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-sammlungskopf")
        gtk_widget_set_halign(knopf, GTK_ALIGN_START)
        gtk_widget_set_margin_start(knopf, Int32(Stil.randAbstand))
        gtk_widget_set_margin_start(ueberschrift, 0)
        gtk_widget_set_margin_end(ueberschrift, 0)
        let spalte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)
        let oben = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 5)
        anhaengen(oben, ueberschrift)
        g_object_unref(UnsafeMutableRawPointer(ueberschrift))
        let winkel: Widget! = gtk_image_new_from_icon_name("go-next-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(winkel), 13)
        gtk_widget_set_valign(winkel, GTK_ALIGN_CENTER)
        anhaengen(oben, winkel)
        anhaengen(spalte, oben)
        let name = beschriftung(sammlung.item.name, stil: "swiftly-koerper")
        gtk_widget_add_css_class(name, "dim-label")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        anhaengen(spalte, name)
        gtk_button_set_child(alsKnopf(knopf), spalte)
        let item = sammlung.item
        beiSignal(knopf, "clicked") { [weak self] in self?.sammlungOeffnen(item, art: gattung) }
        gtk_box_prepend(alsBox(reihe), knopf)
        // Die Reihe hat eine feste Hoehe fuer eine Titelzeile von 24; die
        // Namenszeile kommt dazu.
        gtk_widget_set_size_request(reihe, -1, -1)
        return reihe
    }

    /// **Der Dateiauszug — der Beleg für das Versprechen dieser App.**
    ///
    /// Container, Auflösung, Codec, Grösse, Untertitelsprachen: daran liest
    /// man ab, **warum** Direct Play geht. Er fehlte auf Linux ganz, weil
    /// `Dateiangaben` in `Sources/Shared` lag und von hier nicht erreichbar
    /// war; jetzt liegt es im Paket.
    ///
    /// Die Werte kommen aus derselben Quelle, die auch den Plan trägt — es
    /// wird nichts zusätzlich geholt.
    func dateizeile(_ quelle: MediaSource) -> Widget! {
        var teile: [String] = []
        // Wie auf dem Mac: die Größe steckt in „MKV · 10,3 GB" und steht
        // nur dann einzeln, wenn der Server keinen Container nennt.
        if let behaelter = Dateiangaben.container(quelle) {
            teile.append(behaelter)
        } else {
            teile.append(Dateiangaben.groesse(quelle))
        }
        if let spur = Dateiangaben.videospur(quelle) {
            teile.append(Dateiangaben.video(spur, quelle))
        }
        let ut = Dateiangaben.untertitel(Dateiangaben.untertitelspuren(quelle))
        if !ut.isEmpty { teile.append(ut) }

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 22)
        gtk_widget_add_css_class(reihe, "swiftly-dateizeile")
        for text in teile where !text.isEmpty {
            let l = beschriftung(text, stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(l, "swiftly-leise")
            anhaengen(reihe, l)
        }
        return reihe
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
            // **Erst, wenn die Seite steht.** Der volle Satz baut die ganze
            // Seite neu, samt Kopf und Kulisse — und kam fast immer mitten in
            // der Fahrt an. Dort kostete er die Bilder, in denen die Seite
            // nach ein, zwei Zentimetern stehen blieb (Mac: `Einfahrt`).
            nachDemSchub {
                defer { losgelassen(kiste) }
                // Nur nachtragen, wenn diese Seite noch die oberste ist.
                // **Was der Nutzer schon gewählt hat, wird nicht
                // weggeworfen.** Der volle Satz kommt nach und ersetzte die
                // ganze Seite — wer in der Zwischenzeit eine Staffel oder
                // einen Reiter gewählt hatte, sah sie zurückspringen. Der
                // Mac tauscht nur den Titel und behält den Zustand; hier
                // wird stattdessen nicht mehr neu gebaut, sobald jemand
                // etwas angefasst hat.
                guard self.seitenstapel[self.bereich]?.last?.id == item.id else { return }
                // **Ohne Neubau laedt die magere Fassung ihren Unterbau
                // selbst.** Sonst liefen alle Abrufe darunter zweimal: einmal
                // fuer die magere Seite, die gleich wieder verschwindet, und
                // einmal fuer die volle.
                guard let voll, !self.detailBeruehrt else {
                    self.magererUnterbau?()
                    self.magererUnterbau = nil
                    return
                }
                self.magererUnterbau = nil
                leeren(kiste.widget)
                self.aufbauenMit(voll, in: kiste.widget)
            }
        }
    }

    /// **Nach `item.type` verzweigen**, nicht nach dem nachgeladenen Satz:
    /// die Art steht schon in der Liste, und den Zweig unterwegs zu wechseln
    /// hiesse, die halbe Seite wegzuwerfen und neu zu bauen.
    ///
    /// - Parameter mager: Der Listeneintrag vor dem vollen Satz. Dann steht
    ///   der Unterbau nur als Platz da; gebaut und geladen wird er erst, wenn
    ///   ``titelNachladen`` ohne Neubau zurueckkommt (``magererUnterbau``).
    private func aufbauenMit(_ titel: Item, in seite: Widget!, mager: Bool = false) {
        // Der volle Satz, wie er gerade gezeigt wird — das ``Fernsteuerpult``
        // braucht ihn, weil auf dem Seitenstapel nur der magere
        // Listeneintrag liegt und der keine Besetzung traegt.
        letzterVollerTitel = titel
        belegraum = nil
        anhaengen(seite, heldenkopf(titel, klasse: Tonblatt.klasse(von: seite)))


        // **Der Auslauf ist ein Anstrich, kein Widget.**
        //
        // Erst stand er als eigene Box in einem Überzug hinter dem Unterbau —
        // und ein `GtkOverlay` nimmt die Höhe seines **Hauptkinds**. Damit war
        // die ganze Seite auf 260 Punkte gedeckelt, und Scrollen ging gar
        // nicht mehr. Ein Hintergrundverlauf am Unterbau selbst tut dasselbe,
        // liegt von sich aus hinter dem Inhalt und misst nichts.
        let unten = stapel(GTK_ORIENTATION_VERTICAL, abstand: 26)
        // Die Luft nach der Kopfzone. Sie darf jetzt wieder ein Rand sein —
        // der Ton liegt auf der Seite, nicht auf diesem Kasten.
        gtk_widget_set_margin_top(unten, 26)
        gtk_widget_set_margin_bottom(unten, Int32(Stil.randAbstand))
        anhaengen(seite, unten)

        let beleg = belegraum
        magererUnterbau = nil
        guard !mager else {
            // Gehalten, bis der Auftrag laeuft oder verworfen wird — die
            // Huelle gibt beim Verwerfen frei.
            let platz = Festgehalten(unten)
            let belegPlatz = beleg.map(Festgehalten.init)
            magererUnterbau = { [weak self] in
                self?.unterbauBauen(titel, in: platz.widget, beleg: belegPlatz?.widget)
            }
            return
        }
        unterbauBauen(titel, in: unten, beleg: beleg)
    }

    private func unterbauBauen(_ titel: Item, in unten: Widget!, beleg: Widget!) {
        if titel.type == "Series" {
            serienunterbau(titel, in: unten)
        } else {
            // **Ein Block für alles unter dem Kopf** — Besetzung, Extras,
            // Teil der Sammlung, Ähnliches und ganz unten der Dateiauszug, in
            // dieser Folge wie auf dem Mac. Er steht unsichtbar da, bis alle
            // Antworten beisammen sind (``untenNachladen``). Der Dateiauszug
            // nur beim Film: bei einer Serie gibt es keine Datei, nur die
            // ihrer Folgen.
            let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 26)
            gtk_widget_set_visible(block, 0)
            anhaengen(unten, block)
            untenNachladen(titel, in: block, beleg: beleg)
        }
    }

    // MARK: - Kopfleiste mit Pfeil

    /// Nicht `private`: die Personenseite liegt in einer eigenen Datei und
    /// braucht denselben Kopf. `private` gilt in einer `extension` dateiweit —
    /// ein zweiter Kopf waere die kopierte Funktion, gegen die die Regel steht.
    func detailkopfBauen(_ item: Item) -> Widget! {
        // Höhe wie auf dem Mac: 24 Luft, 40 Knopf, 10 unter dem Text.
        let kopf: Widget! = gtk_overlay_new()
        gtk_widget_set_valign(kopf, GTK_ALIGN_START)
        gtk_widget_set_halign(kopf, GTK_ALIGN_FILL)

        // Solange oben steht: ein weicher Verlauf, damit der Pfeil auf hellem
        // Bild lesbar bleibt. Er ist das Hauptkind und gibt die Höhe vor.
        let verlauf: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_add_css_class(verlauf, "swiftly-kopfverlauf")
        gtk_widget_set_size_request(verlauf, -1, 74)
        gtk_overlay_set_child(OpaquePointer(kopf), verlauf)

        // Und beim Scrollen die Leiste darüber.
        detailkopfLeiste = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_add_css_class(detailkopfLeiste, "swiftly-kopfleiste")
        gtk_widget_set_opacity(detailkopfLeiste, 0)
        gtk_overlay_add_overlay(OpaquePointer(kopf), detailkopfLeiste)
        detailkopfVerlauf = verlauf

        let leiste = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 4)
        gtk_widget_set_valign(leiste, GTK_ALIGN_START)
        // Bündig mit dem Inhalt: 24 minus die 8 Innenabstand des Knopfes.
        gtk_widget_set_margin_start(leiste, Int32(Stil.randAbstand - 8))
        gtk_widget_set_margin_end(leiste, Int32(Stil.randAbstand))
        // 24 setzt den Pfeil auf dieselbe Höhe, auf der die Seitenleiste ihre
        // Wortmarke trägt.
        gtk_widget_set_margin_top(leiste, 24)

        let pfeil: Widget! = gtk_button_new()
        gtk_widget_add_css_class(pfeil, "swiftly-zurueck")
        beschriften(pfeil, uebersetzt("Zurück"))
        gtk_button_set_child(alsKnopf(pfeil), gtk_image_new_from_icon_name("go-previous-symbolic"))
        beiSignal(pfeil, "clicked") { [weak self] in self?.zurueck() }
        anhaengen(leiste, pfeil)

        detailkopfTitel = beschriftung(item.seriesName ?? item.name, stil: "swiftly-leistentitel")
        gtk_label_set_ellipsize(OpaquePointer(detailkopfTitel), PANGO_ELLIPSIZE_END)
        gtk_widget_set_valign(detailkopfTitel, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(detailkopfTitel, 8)
        gtk_widget_set_opacity(detailkopfTitel, 0)
        anhaengen(leiste, detailkopfTitel)

        gtk_overlay_add_overlay(OpaquePointer(kopf), leiste)
        return kopf
    }

    // MARK: - Heldenkopf

    /// Kulisse rechts, Block links. Höhe 380 (`Stil.heldHoehe`).
    private func heldenkopf(_ titel: Item, klasse: String?) -> Widget! {
        let kopf: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(kopf, 1)

        // **Die Kulisse ist das Hauptkind** — sie gibt das Mass (380 hoch)
        // und malt sich selbst, maskiert statt übermalt. Warum das den
        // Unterschied macht, steht in ``Kulisse``.
        // **So hoch wie die Kopfzone.**
        //
        // Auf dem Mac ist das Bild `heldHoehe * 1,62` und liegt damit auch
        // hinter dem Inhalt darunter — dort ist es eine Lage im Stapel, die
        // nichts misst. In GTK ist die Kulisse das Hauptkind des Ueberzugs
        // und gibt damit die Hoehe vor: mit 1,62 rutschten Reiter und
        // Folgenliste um 236 Punkt nach unten. Die Maske beendet das Bild
        // ohnehin weich; die fehlende Strecke dahinter ist der kleinere
        // Fehler. Wer es nachbaut, braucht eine Lage **unter** dem Scroller,
        // nicht im Kopf.
        let bild = Kulisse()
        bild.mitGemerktem(titel.id)
        gtk_overlay_set_child(OpaquePointer(kopf), bild.anzeige)
        gtk_overlay_add_overlay(OpaquePointer(kopf), heldenblock(titel))

        tonUndBildNachladen(titel, in: bild, klasse: klasse)
        return kopf
    }

    /// Holt das Kopfbild und, aus einem winzigen Abbild, seinen Ton.
    ///
    /// **Beide Grössen aus einer Hand.** Hier standen zwei Wege nebeneinander:
    /// das grosse Bild ueber `kopfbildErsatz` mit seinem Ausweichweg, das
    /// winzige direkt ueber `Bildwahl.quer`. Bei einer Serie ohne Hintergrund
    /// fand der erste das Standbild der naechsten Folge und der zweite gar
    /// nichts — Bild da, Ton nicht, und unter der Kulisse stand eine harte
    /// Kante gegen den blanken Grund. Der Mac hat den Fall nicht: dort
    /// bedient **eine** Adresse (`AppModel.kopfbildURL`) beides.
    private func tonUndBildNachladen(_ titel: Item, in kulisse: Kulisse, klasse: String?) {
        guard let adressen, let client else { return }
        Task.detached { [self] in
            // Klein wie auf Apple: 48 Punkt reichen für das Histogramm der
            // Töne (`Bildton.toeneAus`).
            guard let paar = await client.kopfbildPaar(fuer: titel, adressen: adressen, klein: 48)
            else { return }
            if let klasse,
               let daten = await Bildlager.shared.laden(paar.klein,
                                                        schluessel: Bildschluessel.fuer(paar.klein)),
               let toene = Bildfarbe.toene(aus: daten) {
                // Das Stilblatt neu zu laden stellt jedes Widget der App neu
                // (``Schubsperre``) — nicht während die Seite fährt. Die Lage
                // blendet danach ohnehin erst ein.
                nachDemSchub {
                    let schon = Tonblatt.merkt(titel.id)
                    Tonblatt.merken(titel.id, toene)
                    if schon != toene { Tonblatt.setzen(toene, klasse: klasse) }
                    Tonblatt.einblenden(klasse)
                }
            }
            guard let daten = await Bildlager.shared.laden(paar.gross,
                                                           schluessel: Bildschluessel.fuer(paar.gross))
            else { return }
            let gross = paar.gross
            aufHauptfaden { kulisse.setzen(daten, von: gross) }
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

        // **Jede Zeile in ihrem Fach.** Die vier Stellen und Höhen stehen so
        // auf dem Mac; ohne festes Fach wüchse jede Beschriftung über ihre
        // Höhe hinaus, weil Inter höher baut als SF Pro — und die Abstände
        // dazwischen wüchsen mit. Was zu gross wird, wird abgeschnitten und
        // verschiebt nichts.
        let name = beschriftung(titel.name, stil: "swiftly-heldtitel")
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(name), 0)
        // Ein Logo blendet über den Text und bleibt im Fach von 42.
        let titelfach = fach(name, breite: 640, hoehe: 42)
        titelmarkeAnbinden(titelfach, text: name, titel: titel)
        gtk_fixed_put(alsFeld2(feld), titelfach, 0, 0)

        // **26, nicht 20** (Mac 28d314fd): Plakette und Beleg sind 13 Punkt
        // Schrift mit 4 Punkt Luft oben und unten; in 20 wurden sie oben und
        // unten beschnitten.
        gtk_fixed_put(alsFeld2(feld), fach(angabenreihe(titel), breite: 640, hoehe: 26),
                      0, 54)

        // **`beschreibung`, nicht `overview`.** Jellyfin liefert HTML — `<br>`
        // und `&amp;` standen hier woertlich in der Seite. `Beschreibung.lesbar`
        // im Paket raeumt das auf und wurde hier nur nie aufgerufen.
        let text = beschriftung(titel.beschreibung ?? "", stil: "swiftly-koerper", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(text), 0)
        gtk_label_set_yalign(OpaquePointer(text), 0)
        gtk_label_set_lines(OpaquePointer(text), 3)
        gtk_label_set_ellipsize(OpaquePointer(text), PANGO_ELLIPSIZE_END)
        gtk_label_set_justify(OpaquePointer(text), GTK_JUSTIFY_LEFT)
        gtk_widget_add_css_class(text, "swiftly-beschreibung")
        gtk_fixed_put(alsFeld2(feld), fach(text, breite: 640, hoehe: 66,
                                           senkrecht: GTK_ALIGN_START), 0, 92)

        gtk_fixed_put(alsFeld2(feld), fach(knopfreihe(titel), breite: 640,
                                           hoehe: Stil.hauptknopfHoehe), 0, 182)
        return feld
    }

    /// Jahr, Laufzeit, Genres, Bewertung, Freigabe und der Beleg — **eine
    /// Zeile**, nicht drei.
    private func angabenreihe(_ titel: Item) -> Widget! {
        // **8 zwischen den Marken, 14 nach dem Text** — wie der Mac
        // (`FilmView.angabenReihe`) und `Belegzeile` am iPhone. 14 überall
        // war zwischen drei kleinen Plaketten ein Loch.
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        gtk_widget_set_halign(reihe, GTK_ALIGN_START)

        let zeile = beschriftung(titel.nebenzeile, stil: "swiftly-angaben")
        gtk_widget_add_css_class(zeile, "dim-label")
        gtk_widget_set_margin_end(zeile, 6)
        anhaengen(reihe, zeile)

        // **In derselben Huelle wie Direct Play** (Mac ec0383c8,
        // `DetailView.swift` `marke`): Stern und Zahl in `schriftLeise`,
        // Flaeche in 15 Prozent derselben Farbe. Vorher stand die Bewertung
        // als einzige Angabe der Zeile nackt da.
        if let bewertung = titel.communityRating {
            let paar = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
            let stern: Widget! = gtk_image_new_from_icon_name("starred-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(stern), 11)
            anhaengen(paar, stern)
            let wert = beschriftung(komma(bewertung), stil: "swiftly-kacheltitel")
            anhaengen(paar, wert)
            gtk_widget_add_css_class(paar, "swiftly-belegmarke")
            gtk_widget_add_css_class(paar, "swiftly-bewertung")
            gtk_widget_set_valign(paar, GTK_ALIGN_CENTER)
            anhaengen(reihe, paar)
        }

        if let freigabe = titel.officialRating { anhaengen(reihe, plakette(freigabe)) }

        // **Der Beleg steht hinten** — Jahr · Laufzeit · Sterne · FSK ·
        // Direct Play, wie am Fernseher (`Belegmarken(belegZuletzt:)`). Er
        // kommt als Letzter, also schiebt sein Erscheinen nichts: davor steht
        // alles schon, dahinter ist nichts. Läuft alles verlustfrei, steht
        // „Direct Play" im Akzent (D1), sonst die Abweichung in Warnorange (D2).
        //
        // **Der Plan kommt nicht mehr mit allem unter dem Kopf.** Er wartete
        // auf Extras, Ähnliches und die Sammlung und ploppte dann auf. Jetzt
        // wird er beim Öffnen geholt — oder schon beim Überfahren der Kachel
        // (``planVorholenBald(_:)``); liegt er vor, steht er im ersten Bild.
        let beleg = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
        gtk_widget_set_visible(beleg, 0)
        gtk_widget_add_css_class(beleg, "swiftly-belegmarke")
        gtk_widget_set_valign(beleg, GTK_ALIGN_CENTER)
        anhaengen(reihe, beleg)
        if let fertig = planfertig[planschluessel(titel)] {
            belegZeigen(fertig, in: beleg, sofort: true)
        } else {
            planNachladen(titel, in: beleg)
        }
        return reihe
    }

    /// **Der Plan gehört zur Folge, nicht zur Serie.** Bei einer Serie nennt
    /// der Server keine MediaSource — der Aufruf käme leer zurück, und
    /// `PlaybackInfo` ist ein POST, bei dem der Server die Datei anfasst:
    /// der teuerste Abruf der App, hier umsonst.
    private func planNachladen(_ titel: Item, in beleg: Widget!) {
        guard let auftrag = planAuftrag(titel) else { return }
        let kiste = gehalten(beleg)
        Task.detached {
            let plan = await auftrag.value
            aufHauptfaden {
                defer { losgelassen(kiste) }
                self.belegZeigen(plan, in: kiste.widget)
            }
        }
    }

    /// Unter welchem Schlüssel ein Plan gilt: Titel und Bitratengrenze.
    func planschluessel(_ titel: Item) -> String { "\(titel.id)|\(wahlen.profilBitrate)" }

    /// **Ein Abruf je Titel, geteilt.** Beleg, Dateiauszug und das Vorholen
    /// beim Überfahren warten auf denselben Auftrag. Nur auf dem Hauptfaden.
    func planAuftrag(_ titel: Item) -> Task<PlaybackPlan?, Never>? {
        guard let client else { return nil }
        let schluessel = planschluessel(titel)
        if let laeuft = planauftraege[schluessel] { return laeuft }
        let grenze = wahlen.profilBitrate
        let auftrag = Task.detached { [self] () -> PlaybackPlan? in
            let plan = await self.planHolen(titel, client: client, grenze: grenze)
            aufHauptfaden {
                if let plan { self.planfertig[schluessel] = plan }
                // Ein gescheiterter Abruf darf beim nächsten Öffnen neu.
                else { self.planauftraege[schluessel] = nil }
            }
            return plan
        }
        planauftraege[schluessel] = auftrag
        return auftrag
    }

    /// **Vorholen beim Überfahren, mit Frist.** Der Plan ist ein POST, bei dem
    /// der Server die Datei anfasst — wer mit dem Zeiger über ein Raster
    /// fährt, soll nicht zwanzig davon auslösen. Erst nach 0,3 s auf
    /// derselben Kachel.
    func planVorholenBald(_ item: Item) {
        guard item.type == "Movie" || item.type == "Series" else { return }
        planWunsch = item.id
        nachFrist(0.3) { [weak self] in
            guard let self, self.planWunsch == item.id else { return }
            _ = self.planAuftrag(item)
        }
    }

    /// Bei einer Serie der Plan der Folge, die als Nächstes liefe.
    private func planHolen(_ titel: Item, client: JellyfinClient, grenze: Int) async -> PlaybackPlan? {
        let ziel: Item?
        if titel.type == "Series" {
            ziel = try? await client.naechsteFolgeDerSerie(seriesID: titel.id)
        } else {
            ziel = titel
        }
        guard let ziel else { return nil }
        return try? await client.playbackPlan(for: ziel.id, profile: .vlc(maxBitrate: grenze))
    }

    /// Setzt den Beleg und blendet ihn ein. Ohne Plan bleibt er weg.
    private func belegZeigen(_ plan: PlaybackPlan?, in beleg: Widget!, sofort: Bool = false) {
        guard let plan, let ziel = beleg, gtk_widget_get_visible(ziel) == 0 else { return }
        let zeichen: Widget! = gtk_image_new_from_icon_name(
            plan.isLossless ? "object-select-symbolic" : "dialog-warning-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(zeichen), 11)
        anhaengen(ziel, zeichen)
        let text = beschriftung(plan.isLossless ? "Direct Play" : plan.method.rawValue,
                                stil: "swiftly-kacheltitel")
        anhaengen(ziel, text)
        gtk_widget_add_css_class(ziel, plan.isLossless ? "swiftly-beleg" : "swiftly-warnung")
        gtk_widget_set_visible(ziel, 1)
        guard !sofort else { gtk_widget_set_opacity(ziel, 1); return }
        // Nur Deckkraft, 0,2 s — er steht hinten, es rückt nichts.
        gtk_widget_set_opacity(ziel, 0)
        blenden(ziel, auf: 1, dauer: Stil.zeitBeleg)
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
        offenesZiel = ziel

        let angefangen = titel.fortsetzenAb
        let haupt = hauptknopf(angefangen != nil ? uebersetzt("Fortsetzen") : uebersetzt("Abspielen"),
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
        // **Rechtsklick oder langer Druck: das Kachelmenü des Titels**, wie an
        // seiner Kachel (Apple: `.kachelmenue(titel, …)` am Hauptknopf).
        // Danach fragt der Knopf sein Ziel neu.
        let plakat = adressen.flatMap { Bildwahl.hochkant(titel, adressen: $0,
                                                          maxHoehe: Stil.kachelHoehe * 2) }
        kachelmenueAnlegen(haupt, Kachelmenueangabe(
            item: titel, bild: plakat, kante: Stil.kachelHoehe * 2,
            nachher: { [weak self] _ in self?.kopfAuffrischen?.tun() }))

        // **„Von vorn" nur bei angefangenen Titeln.** Wo es das nicht gibt,
        // rückt der Rest auf; eine leere Lücke stehen zu lassen wäre
        // schlimmer als der kleine Versatz.
        let vorn = nebenknopf("view-refresh-symbolic", name: uebersetzt("Von vorn abspielen"))
        gtk_widget_set_visible(vorn, angefangen != nil ? 1 : 0)
        beiSignal(vorn, "clicked") { [weak self] in
            guard let self, let was = ziel.titel else { return }
            self.starte(was, ab: 0)
        }
        anhaengen(reihe, vorn)

        // **Nach dem Player nur dieses Ziel neu fragen**, nicht die Seite
        // neu bauen — sonst springt sie nach oben (``nachDemPlayerAuffrischen``).
        // Bei einem Film ist das der Titel selbst mit seiner neuen Stelle.
        let zielHolen: () -> Void = { [weak self] in
            guard let self, let client = self.client else { return }
            let knopfKiste = gehalten(haupt)
            let vornKiste = gehalten(vorn)
            let serie = titel.type == "Series"
            Task.detached {
                // **`standInSerie`, nicht `naechsteFolgeDerSerie`** (A4): „der
                // Hauptknopf startet dort, wo der Server sagt — angefangene
                // Folge an ihrer Stelle, sonst naechste ungesehene, **sonst
                // Folge 1**." Der blanke NextUp-Abruf liefert bei einer
                // durchgesehenen Serie nichts, und dann blieb der Knopf fuer
                // immer gesperrt: ausgegraut, waehrend jede Folge darunter
                // sich abspielen liess. Der Rueckfall liegt seit dem
                // 13.09.2026 im Paket.
                let folge = serie ? await client.standInSerie(titel.id)
                                  : try? await client.item(id: titel.id)
                aufHauptfaden {
                    defer { losgelassen(knopfKiste); losgelassen(vornKiste) }
                    guard let folge else { return }
                    ziel.titel = folge
                    gtk_widget_set_sensitive(knopfKiste.widget, 1)
                    let weiter = folge.fortsetzenAb != nil
                    hauptknopfBeschriften(knopfKiste.widget,
                                          weiter ? uebersetzt("Fortsetzen") : uebersetzt("Abspielen"))
                    gtk_widget_set_visible(vornKiste.widget, weiter ? 1 : 0)
                }
            }
        }
        if titel.type == "Series" { zielHolen() }
        let marke = naechsteSehstandMarke()
        kopfAuffrischen = (marke, zielHolen)
        beiSignal(haupt, "destroy") { [weak self] in
            if self?.kopfAuffrischen?.marke == marke { self?.kopfAuffrischen = nil }
        }

        // **Merkliste schaltet sofort um, ohne Rückfrage** (D6). Der Zustand
        // des Knopfes ist die Antwort. Das Zeichen ist ein Lesezeichen, kein
        // Stern — auf dem Mac steht dort `bookmark`.
        //
        // **Gemalt, nicht gesucht.** Breeze fuehrt unter
        // `bookmark-new-symbolic` ein Baendchen mit Pluszeichen — das heisst
        // „neues Lesezeichen anlegen", nicht „auf der Merkliste" — und kennt
        // keine gefuellte Fassung. Siehe ``Merkzeichen``.
        // **Der Stand liegt in einer Klasse, nicht in einer lokalen Variablen.**
        // Der Rueckfall bei einem Serverfehler kommt aus einer abgesetzten
        // Aufgabe zurueck, und eine `var` darf die Fadengrenze nicht
        // ueberqueren — dieselbe Ueberlegung wie bei ``Spielziel``.
        let stand = Merkstand(titel.userData?.isFavorite ?? false)
        let merkzeichen = Merkzeichen(gefuellt: stand.an)
        merkzeichen.aufHellemGrund(stand.an)
        let merk = nebenknopf("", name: uebersetzt("Merkliste"), aktiv: stand.an,
                              zeichnung: merkzeichen.anzeige)
        beiSignal(merk, "clicked") { [weak self] in
            guard let self, let client = self.client else { return }
            stand.an.toggle()
            if stand.an { gtk_widget_add_css_class(merk, "swiftly-aktiv") }
            else        { gtk_widget_remove_css_class(merk, "swiftly-aktiv") }
            merkzeichen.setzen(stand.an)
            merkzeichen.aufHellemGrund(stand.an)
            let neu = stand.an
            // **Ein Fehlschlag dreht den Knopf zurueck** (D6: der Zustand des
            // Knopfes **ist** die Antwort — dann muss er auch stimmen). Hier
            // stand `try?`: der Knopf blieb umgeschaltet, der Server wusste
            // nichts davon, und niemand erfuhr es. Der Gesehen-Knopf drei
            // Zeilen weiter macht es seit jeher richtig, und der Mac auch
            // (`DetailView.swift:506-515`).
            // Der Zeiger geht ueber die Fadengrenze in der ``Zeigerkiste``,
            // wie ueberall hier.
            let kiste = gehalten(merk)
            Task.detached { [self] in
                do {
                    try await client.setzeMerkliste(itemID: titel.id, an: neu)
                    aufHauptfaden { losgelassen(kiste); self.listenAuffrischen() }
                } catch {
                    aufHauptfaden {
                        defer { losgelassen(kiste) }
                        let zurueck = !neu
                        stand.an = zurueck
                        let knopf = kiste.widget
                        if zurueck { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
                        else       { gtk_widget_remove_css_class(knopf, "swiftly-aktiv") }
                        merkzeichen.setzen(zurueck)
                        merkzeichen.aufHellemGrund(zurueck)
                        self.melden(lesbarerFehler(error))
                    }
                }
            }
        }
        // Die Zeichenflaeche haelt ihr Zeichen; ohne diesen Zugriff stirbt es
        // beim Verlassen des Aufrufs.
        beiSignal(merkzeichen.anzeige, "destroy") { _ = merkzeichen }
        anhaengen(reihe, merk)

        // **H1: den Ladeknopf gibt es nur mit dem Schalter** — und nur,
        // wenn das Konto laden darf (`Downloadrecht`). Wer Downloads nicht
        // eingeschaltet hat, sieht hier nichts davon, dieselbe Regel wie bei
        // Seerr.
        // **Auch auf der Serienseite** (Mac 25a21b02): „Laden steht in der
        // Reihe, nicht in einem versteckten Chip." Bei einer Serie oeffnet er
        // die Auswahl — ganze Serie, Staffel, einzelne Folge.
        if downloadKnopfZeigen, titel.type == "Series" {
            let laden = nebenknopf("folder-download-symbolic", name: uebersetzt("Laden"))
            beiSignal(laden, "clicked") { [weak self] in
                self?.ladeauswahlZeigen(titel, an: laden)
            }
            anhaengen(reihe, laden)
        }
        if downloadKnopfZeigen, titel.type != "Series" {
            let stand = downloads.posten(fuer: titel.id)
            let symbol = ladeknopfsymbol(stand)
            let laden = nebenknopf(symbol, name: uebersetzt("Laden"),
                                   aktiv: stand?.stand == .fertig)
            beiSignal(laden, "clicked") { [weak self] in
                self?.ladetafelZeigen(titel, an: laden)
            }
            anhaengen(reihe, laden)
        }

        // **Vier Ziele, nicht fünf.** „Gesehen" und „Trailer" sind in die
        // Mehr-Liste gewandert; fünf beschriftete Knöpfe waren zu viel für
        // eine Reihe. So steht es auf dem Apple TV und auf dem Mac.
        let mehr = nebenknopf("view-more-horizontal-symbolic", name: uebersetzt("Mehr"))
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
        // 260, wie `Handlungsliste` auf dem Mac (`Macbausteine.swift:591`).
        gtk_widget_set_size_request(liste, 260, -1)

        var gesehen = titel.istGesehen
        let ersteZeile = gesehen ? uebersetzt("Als ungesehen markieren") : uebersetzt("Als gesehen markieren")

        // Rechtsbuendig unter dem Knopf, und sie waechst aus der rechten
        // oberen Ecke — `.aufklappen(von: .topTrailing)` auf dem Mac.
        let tafel = tafelOeffnen(an: knopf, buendig: GTK_ALIGN_END)
        gtk_popover_set_child(alsTafel(tafel), liste)

        anhaengen(liste, handlungszeile("object-select-symbolic", ersteZeile) {
            [weak self] in
            guard let self, let client = self.client else { return }
            gesehen.toggle()
            let neu = gesehen
            gtk_popover_popdown(alsTafel(tafel))
            // **Der Zustand des Knopfes ist die Antwort** (D6) — aber wenn
            // der Server ablehnt, ist die Antwort falsch. Dann nimmt sie
            // sich zurück und sagt warum; auf dem Mac genauso.
            // Hier gibt es nichts zurückzunehmen: die Liste wird bei jedem
            // Öffnen neu aus `titel.istGesehen` gebaut. Gesagt werden muss es
            // trotzdem — sonst sieht es aus, als hätte es geklappt.
            Task.detached { [self] in
                do {
                    try await client.setzeGesehen(itemID: titel.id, an: neu)
                    aufHauptfaden { self.sehstandVergessen(titel) }
                }
                catch { aufHauptfaden { self.melden(lesbarerFehler(error)) } }
            }
        })
        // **„Von vorn" nur, wenn es etwas zurueckzusetzen gibt** — bei einem
        // Film, der bei null steht, waere es eine Zeile ohne Wirkung. Wortlaut
        // und Bedingung aus `Titelhandlungen.fuerFilm`.
        //
        // **„Trailer" steht an zweiter Stelle, nicht an dritter.** Der Mac
        // reiht Gesehen, Trailer, dann die typspezifischen Eintraege
        // (`DetailView.swift:597-618`); hier stand Trailer dahinter. Die
        // Eintraege selbst waren schon dieselben — nur die Reihenfolge nicht,
        // und eine von Hand nachgezogene Liste laeuft genau so auseinander.
        anhaengen(liste, handlungszeile("video-x-generic-symbolic", uebersetzt("Trailer")) {
            [weak self] in
            gtk_popover_popdown(alsTafel(tafel))
            self?.trailerStarten(titel)
        })
        if titel.type == "Series" {
            if let stand = offenesZiel?.titel {
                anhaengen(liste, handlungszeile("media-playback-start-symbolic",
                                                uebersetzt("Folge von vorn abspielen")) {
                    [weak self] in
                    gtk_popover_popdown(alsTafel(tafel))
                    self?.starte(stand, ab: 0)
                })
                // **„Nächste Folge" weicht für „Gemeinsam schauen"** (Entwurf A,
                // wie `Titelhandlungen.fuerSerie` auf iOS): die Liste soll
                // nicht länger werden, die nächste Folge erreicht man ebenso
                // über die Folgen.
                if gemeinsam.lage.darfAnlegen {
                    anhaengen(liste, handlungszeile("system-users-symbolic",
                                                    uebersetzt("Gemeinsam schauen")) {
                        [weak self] in
                        gtk_popover_popdown(alsTafel(tafel))
                        guard let self else { return }
                        // Nach dem Signal: die neue Tafel ersetzt diese.
                        let anker = Zeigerkiste(knopf), lebt = Lebenszeichen(knopf)
                        aufHauptfaden(solange: lebt) { [self] in self.gemeinsamAnlegenZeigen(stand, an: anker.widget) }
                    })
                } else {
                anhaengen(liste, handlungszeile("media-skip-forward-symbolic",
                                                uebersetzt("Nächste Folge abspielen")) {
                    [weak self] in
                    gtk_popover_popdown(alsTafel(tafel))
                    guard let self, let client = self.client,
                          let serie = stand.seriesId else { return }
                    // Ohne Server die naechste geladene Folge (`Downloadregeln`).
                    let posten = self.downloads.posten
                    Task.detached { [self] in
                        guard let naechste = await Downloadregeln.folgeNach(
                            stand, aus: posten, ohneNetz: false, server: {
                                try await client.folgeNach(itemID: stand.id, seriesID: serie)
                            }) else {
                            aufHauptfaden { self.melden(uebersetzt("Danach kommt nichts mehr.")) }
                            return
                        }
                        aufHauptfaden { self.starte(naechste, ab: 0) }
                    }
                })
                }
            }
            if let staffel = offeneStaffel {
                anhaengen(liste, handlungszeile("object-select-symbolic",
                                                String(format: uebersetzt("%@ als gesehen"), staffel.name)) {
                    [weak self] in
                    gtk_popover_popdown(alsTafel(tafel))
                    guard let self, let client = self.client else { return }
                    // `[self]` wie an den neun anderen Stellen dieser Datei.
                    // Ein zweites `[weak self]` **innerhalb** einer Closure,
                    // die oben schon `guard let self` gemacht hat, uebersetzt
                    // unter Swift 6 nicht: „reference to captured var 'self'".
                    // `App` lebt ohnehin so lange wie das Programm.
                    Task.detached { [self] in
                        try? await client.setzeGesehen(itemID: staffel.id, an: true)
                        aufHauptfaden { self.sehstandVergessen(staffel) }
                    }
                    self.melden(String(format: uebersetzt("%@ ist als gesehen vermerkt."), staffel.name))
                })
            }
        } else if titel.fortsetzenAb != nil {
            anhaengen(liste, handlungszeile("media-playback-start-symbolic",
                                            uebersetzt("Von vorn abspielen")) {
                [weak self] in
                gtk_popover_popdown(alsTafel(tafel))
                self?.starte(titel, ab: 0)
            })
            anhaengen(liste, handlungszeile("view-refresh-symbolic",
                                            uebersetzt("Fortschritt zurücksetzen")) {
                [weak self] in
                gtk_popover_popdown(alsTafel(tafel))
                guard let self, let client = self.client else { return }
                Task.detached { [self] in
                    try? await client.setzeGesehen(itemID: titel.id, an: false)
                    aufHauptfaden { self.sehstandVergessen(titel) }
                }
                self.melden(uebersetzt("Der Fortschritt ist zurückgesetzt."))
            })
        }
        // **Gemeinsam schauen**, vor den Metadaten — dieselbe Stelle wie in
        // `Titelhandlungen.fuerFilm`.
        if titel.type != "Series", gemeinsam.lage.darfAnlegen {
            anhaengen(liste, handlungszeile("system-users-symbolic", uebersetzt("Gemeinsam schauen")) {
                [weak self] in
                gtk_popover_popdown(alsTafel(tafel))
                guard let self else { return }
                let anker = Zeigerkiste(knopf), lebt = Lebenszeichen(knopf)
                aufHauptfaden(solange: lebt) { [self] in self.gemeinsamAnlegenZeigen(titel, an: anker.widget) }
            })
        }
        anhaengen(liste, handlungszeile("view-refresh-symbolic", uebersetzt("Metadaten auffrischen")) {
            [weak self] in
            guard let client = self?.client else { return }
            Task.detached { try? await client.metadatenAuffrischen(titel.id) }
            gtk_popover_popdown(alsTafel(tafel))
        })
        gtk_popover_popup(alsTafel(tafel))
    }

    func handlungszeile(_ symbol: String, _ text: String,
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
                // **Schweigen ist keine Antwort.** Ohne diese Zeile passierte
                // beim Druck auf „Trailer" schlicht nichts, und man wusste
                // nicht, ob der Knopf kaputt ist oder der Server nichts hat.
                if let film = filme.first {
                    self.starte(film, ab: 0)
                    return
                }
                // **Der Server hat keinen, das Netz vielleicht schon.** Der
                // Mac faellt auf `remoteTrailers` zurueck und oeffnet die
                // Adresse im Browser (`DetailView.swift:618-621`); hier stand
                // nur die Absage. `remoteTrailers` wurde in der ganzen Datei
                // nie gelesen.
                if let adresse = titel.remoteTrailers?.compactMap(\.url).first,
                   let ziel = URL(string: adresse) {
                    imBrowser(ziel)
                    return
                }
                self.melden(uebersetzt("Für diesen Titel liegt kein Trailer vor."))
            }
        }
    }
}


/// Wohin der Hauptknopf zeigt. Eine Klasse, damit der Rückruf denselben Wert
/// sieht wie das Nachladen — bei einer Serie steht er erst fest, wenn der
/// Server geantwortet hat.
///
/// **`@unchecked Sendable` mit derselben Begründung wie ``Zeigerkiste``:**
/// gelesen und geschrieben wird ausschließlich auf GTKs Hauptfaden, das
/// Nachladen kommt über ``aufHauptfaden`` dorthin zurück. Swift kann das
/// nicht sehen, nur wir.
/// Ob ein Titel auf der Merkliste steht — als Klasse, damit der Rueckfall
/// nach einem Serverfehler denselben Wert sieht wie der Klick.
final class Merkstand: @unchecked Sendable {
    var an: Bool
    init(_ an: Bool) { self.an = an }
}

final class Spielziel: @unchecked Sendable {
    var titel: Item?
}

// MARK: - Herunterladen

/// **Die Nachfrage ist eine Tafel am Knopf** — dieselbe Regel wie bei der
/// Mehr-Liste und wortgleich die Entscheidung des Macs: „Auf dem Schreibtisch
/// gibt es einen Zeiger; was zu einem Knopf gehoert, erscheint bei ihm."
///
/// Sie sagt zuerst, was der Titel kostet und was frei ist, und erst dann gibt
/// es den Knopf. Ein Download, der nach zwanzig Minuten an einer vollen
/// Platte scheitert, ist die schlechtere Auskunft.
extension App {

    func ladeknopfsymbol(_ p: Downloadposten?) -> String {
        switch p?.stand {
        case nil:          return "folder-download-symbolic"
        case .wartet:      return "media-playback-pause-symbolic"
        case .laedt:       return "media-playback-pause-symbolic"
        case .angehalten:  return "media-playback-start-symbolic"
        case .fehler:      return "dialog-warning-symbolic"
        case .fertig:      return "object-select-symbolic"
        }
    }

    func ladetafelZeigen(_ titel: Item, an knopf: Widget!) {
        let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(liste, 280, -1)

        let tafel = tafelOeffnen(an: knopf)
        gtk_popover_set_child(alsTafel(tafel), liste)

        // Steht er schon in der Liste, geht es nicht ums Anfangen.
        if let vorhanden = downloads.posten(fuer: titel.id) {
            anhaengen(liste, ladeangabe(uebersetzt("Auf diesem Rechner"),
                                        Downloadregeln.groesse(vorhanden.geladen)))
            switch vorhanden.stand {
            case .laedt, .wartet:
                anhaengen(liste, handlungszeile("media-playback-pause-symbolic",
                                                uebersetzt("Anhalten")) { [weak self] in
                    gtk_popover_popdown(alsTafel(tafel))
                    self?.downloads.anhalten(titel.id)
                })
            case .angehalten, .fehler:
                anhaengen(liste, handlungszeile("media-playback-start-symbolic",
                                                uebersetzt("Fortsetzen")) { [weak self] in
                    gtk_popover_popdown(alsTafel(tafel))
                    self?.downloads.fortsetzen(titel.id)
                })
            case .fertig:
                anhaengen(liste, handlungszeile("media-playback-start-symbolic",
                                                uebersetzt("Ohne Netz abspielen")) { [weak self] in
                    gtk_popover_popdown(alsTafel(tafel))
                    guard let self, let p = self.downloads.posten(fuer: titel.id) else { return }
                    self.downloadSpielen(p)
                })
            }
            anhaengen(liste, handlungszeile("user-trash-symbolic",
                                            uebersetzt("Vom Rechner entfernen")) { [weak self] in
                gtk_popover_popdown(alsTafel(tafel))
                self?.downloads.entfernen(titel.id)
            })
            gtk_popover_popup(alsTafel(tafel))
            return
        }

        ladetafelNeu(titel, liste: liste, tafel: tafel, wahl: .original, offen: false)
        gtk_popover_popup(alsTafel(tafel))
    }

    /// Der Inhalt der Nachfrage fuer einen neuen Download — **neu gezeichnet,
    /// sobald eine andere Qualitaet gewaehlt wird**, damit Groesse und „Danach
    /// frei" mitgehen.
    private func ladetafelNeu(_ titel: Item, liste: Widget!, tafel: Widget!,
                              wahl: Downloadqualitaet, offen: Bool) {
        leeren(liste)
        // **Die Groesse kommt aus der Quelle, die auch der Player naehme.**
        // Steht dort keine, wird trotzdem geladen — dann gibt es eben keinen
        // Balken, sondern nur die wachsende Zahl. `Downloadposten.anteil`
        // liefert dafuer `nil`, und die Zeile weiss damit umzugehen.
        //
        // **In der gewaehlten Qualitaet** (Mac `Ladetafel.fassung`): beim
        // Original die echte Groesse, sonst die Schaetzung aus Bitrate mal
        // Laufzeit, mit „≈" davor.
        let quelle = titel.mediaSources?.first
        let original = quelle?.size ?? 0
        let bytes = wahl.geschaetzteBytes(original: original, laufzeitTicks: titel.runTimeTicks)
        let umgewandelt = !wahl.istOriginal
        let auskunft = downloads.auskunft(fuer: bytes)
        let angeboten = Downloadqualitaet.angeboten(
            waehlbar: downloadqualitaetWaehlbar,
            quellBitrate: Downloadqualitaet.bitrate(bytes: original, laufzeitTicks: titel.runTimeTicks))
        let wahlZeigen = downloadqualitaetWaehlbar && angeboten.count > 1
        let neu: (Downloadqualitaet, Bool) -> Void = { [weak self] q, auf in
            self?.ladetafelNeu(titel, liste: liste, tafel: tafel, wahl: q, offen: auf)
        }
        let qualitaetszeile: () -> Void = { [weak self] in
            guard let self else { return }
            let feld = self.qualitaetswahlBauen(
                wahl: wahl, angeboten: angeboten, waehlbar: true, offen: offen,
                groesse: { $0.geschaetzteBytes(original: original, laufzeitTicks: titel.runTimeTicks) },
                umschalten: { neu(wahl, !offen) }, waehlen: { neu($0, false) })
            gtk_widget_set_margin_start(feld, 14)
            gtk_widget_set_margin_end(feld, 14)
            gtk_widget_set_margin_bottom(feld, 6)
            anhaengen(liste, feld)
        }

        anhaengen(liste, ladeangabe(uebersetzt("Diese Datei"),
                                    bytes > 0 ? (umgewandelt ? "≈ " : "") + Downloadregeln.groesse(bytes)
                                              : uebersetzt("Unbekannt")))
        if !auskunft.reicht {
            anhaengen(liste, ladeangabe(uebersetzt("Frei auf diesem Rechner"),
                                        Downloadregeln.groesse(max(0, auskunft.freiDanach
                                                                   + bytes
                                                                   + Downloadregeln.luft)),
                                        warnend: true))
            // Der naheliegende Ausweg ist eine kleinere Fassung.
            if wahlZeigen { qualitaetszeile() }
            if auskunft.reichtNachAufraeumen, !auskunft.entbehrlich.isEmpty {
                let text = String(format: uebersetzt("%d gesehene Titel könnten weichen (%@)."),
                                  auskunft.entbehrlich.count,
                                  Downloadregeln.groesse(auskunft.entbehrlichBytes))
                anhaengen(liste, ladehinweis(text))
            } else {
                anhaengen(liste, ladehinweis(uebersetzt("Nicht genug Platz")))
                return
            }
        }

        // **Und der Fall dazwischen: Platz ja, Leitung getaktet** (H5). Der
        // Mac hat dafuer einen eigenen Zweig mit Warnzeichen und dem Knopf
        // „In die Warteschlange" (`Macdownloads.swift:161-166`); hier gab es
        // nur „passt nicht" und „laedt", obwohl die Messung selbst existiert.
        else if !Downloadregeln.darfLaden(imWLAN: downloads.imWLAN,
                                          nurUeberWLAN: downloads.nurUeberWLAN) {
            anhaengen(liste, ladeangabe(uebersetzt("Kein WLAN"),
                                        uebersetzt("Mobilfunk"), warnend: true))
            anhaengen(liste, handlungszeile("folder-download-symbolic",
                                            uebersetzt("In die Warteschlange")) { [weak self] in
                gtk_popover_popdown(alsTafel(tafel))
                self?.ladenAnstossen(titel, quelle: quelle, bytes: original, qualitaet: wahl)
            })
            return
        }
        // **Drei Zahlen, ein Knopf** (H3). Groesse, Qualitaet und was danach
        // frei ist — so steht die Tafel auf dem Mac
        // (`Macdownloads.swift:168-176`). Hier stand im Normalfall nur die
        // Groesse; „Frei auf diesem Rechner" erschien ausschliesslich, wenn
        // es knapp wurde, und der Erklaersatz zur Originalqualitaet fehlte
        // ganz — dabei ist er der Grund, warum es keine Qualitaetswahl gibt.
        else {
            if wahlZeigen {
                qualitaetszeile()
            } else if let c = quelle?.container, !c.isEmpty {
                anhaengen(liste, ladeangabe(uebersetzt("Qualität"), c.uppercased()))
            }
            anhaengen(liste, ladeangabe(uebersetzt("Danach frei"),
                                        Downloadregeln.groesse(auskunft.freiDanach)))
        }

        anhaengen(liste, handlungszeile("folder-download-symbolic",
                                        uebersetzt("Laden")) { [weak self] in
            gtk_popover_popdown(alsTafel(tafel))
            self?.ladenAnstossen(titel, quelle: quelle, bytes: original, qualitaet: wahl)
        })
        if auskunft.reicht {
            anhaengen(liste, ladehinweis(umgewandelt
                ? uebersetzt("Der Server wandelt die Datei beim Laden um. Die Größe ist geschätzt.")
                : uebersetzt("Swiftly lädt die Originaldatei, in derselben Qualität wie beim Streamen.")))
        }
    }

    private func ladeangabe(_ was: String, _ wert: String, warnend: Bool = false) -> Widget! {
        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        gtk_widget_set_margin_start(zeile, 14)
        gtk_widget_set_margin_end(zeile, 14)
        gtk_widget_set_margin_top(zeile, 9)
        gtk_widget_set_margin_bottom(zeile, 9)
        let l = beschriftung(was, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        if warnend { gtk_widget_add_css_class(l, "swiftly-warnung") }
        anhaengen(zeile, l)
        let w = beschriftung(wert, stil: "swiftly-koerper")
        anhaengen(zeile, w)
        return zeile
    }

    private func ladehinweis(_ text: String) -> Widget! {
        let l = beschriftung(text, stil: "swiftly-zweitzeile", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_margin_start(l, 14)
        gtk_widget_set_margin_end(l, 14)
        gtk_widget_set_margin_bottom(l, 10)
        return l
    }

    /// Aus dem Eintrag wird ein Posten. Was hier hineinkommt, muss reichen,
    /// um den Titel **ohne Server** zu zeigen und abzuspielen — deshalb
    /// Laufzeit, Container und die Serienangaben.
    func ladenAnstossen(_ titel: Item, quelle: MediaSource?, bytes: Int64,
                        qualitaet: Downloadqualitaet = .original) {
        // H11: ohne Konto kein Posten. Leer heisst hier „nicht angemeldet",
        // und ein Download ohne Konto liefe unter derselben Datei wie der
        // eines zweiten Nutzers.
        guard !benutzerID.isEmpty else { return }
        let posten = Downloadposten(
            id: titel.id,
            konto: benutzerID,
            art: titel.type == "Episode" ? .folge : .film,
            titel: titel.name ?? "",
            serie: titel.seriesName,
            serienId: titel.seriesId,
            staffel: titel.parentIndexNumber,
            folge: titel.indexNumber,
            laufzeitTicks: titel.runTimeTicks,
            container: quelle?.container,
            quelle: quelle?.id,
            bytes: bytes,
            // Der ganze Sehstand, nicht nur der Haken: ohne Netz faengt die
            // Downloadliste an der Stelle an, die der Server kannte.
            sehstand: titel.userData,
            bildcodec: quelle?.bildcodec).inQualitaet(qualitaet)

        var bilder: [String: URL] = [:]
        if let adressen {
            if let (url, _) = Bildwahl.quer(titel, adressen: adressen, breite: 400) {
                bilder[titel.id] = url
            }
        }
        downloads.anstossen(posten, bilder: bilder)
        melden(uebersetzt("Wird geladen."))
    }

    /// **Die ganze Staffel, der Reihe nach** (H4).
    ///
    /// Der Chip neben der Staffelwahl fehlte auf Linux ganz — es gab nur den
    /// Download je Einzelfolge, und wer eine Staffel mitnehmen wollte, musste
    /// zweiundzwanzig Mal klicken. Der Mac hat ihn seit langem
    /// (`SerienView.swift:103-110`, `:317-322`).
    ///
    /// **Was schon da ist, kommt nicht noch einmal in die Schlange**, und die
    /// Reihenfolge macht `Downloadregeln.naechster` — hier wird nur
    /// eingereiht.
    func staffelLaden(_ folgen: [Item], qualitaet: Downloadqualitaet = .original) {
        let offene = folgen.filter { downloads.posten(fuer: $0.id) == nil }
        guard !offene.isEmpty else { return }
        for folge in offene {
            ladenAnstossen(folge, quelle: folge.mediaSources?.first,
                           bytes: folge.mediaSources?.first?.size ?? 0, qualitaet: qualitaet)
        }
        melden(zahlwort(offene.count, eins: uebersetzt("1 Folge wird geladen."),
                        viele: uebersetzt("%d Folgen werden geladen.")))
    }
}
