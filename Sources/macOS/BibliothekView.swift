import JellyfinKit
import SwiftUI

/// Filme oder Serien.
///
/// Das Raster ist **beweglich**, und das ist die eine Stelle, an der der Mac
/// wirklich anders rechnet: auf dem iPhone stehen drei Spalten fest, weil 390
/// Punkt Breite feststehen. Ein Fenster hat keine feste Breite — also
/// bestimmt die Kachelbreite die Spaltenzahl, nicht umgekehrt.
///
/// Filter, Sortierung und Nachladen kommen aus `Bibliotheksmodell` in
/// `Sources/Shared` — dieselbe Seitenlogik wie auf den anderen Plattformen,
/// einmal vorhanden.
struct BibliothekView: View {
    let model: AppModel
    let art: String
    let titel: LocalizedStringKey
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    /// **Von aussen, nicht selbst gehalten.** Als `@State` verschwand das
    /// Regal mit der Ansicht, und die Ansicht verschwindet bei jedem
    /// Leistenwechsel (`\.id(bereich)`). Deshalb lief bei jedem Wechsel
    /// zwischen Filmen und Serien der Ladebalken erneut.
    let regal: Bibliotheksmodell
    /// Was der Titel gewählt hat: Alle, Sammlungen oder eine Bibliothek —
    /// die Regel steht in ``Bereichsangebot``, wie auf dem iPhone.
    ///
    /// Aus demselben Grund wie das Regal **von aussen**: als `@State` fiele
    /// die Wahl bei jedem Leistenwechsel zurück.
    ///
    /// **Seit dem 23.09.2026 statt der Rubrik „Bibliotheken" in der
    /// Seitenleiste.** Die übrigen Bibliotheken öffneten sich dort als eigene
    /// Wurzel; jetzt stehen sie im Titelmenü, wie auf dem iPhone.
    @Binding var wahl: Bereichswahl
    /// **Eine Sammlung statt des Bereichs** — dann ist die Seite eine
    /// Unterseite mit Pfeil, ohne Titelmenü, und liest aus der Sammlung.
    /// `art` sagt, ob ihre Filme oder ihre Serien gemeint sind; `nil`: alles.
    var sammlung: (item: Item, art: String?)?
    /// Welche Filter zur Wahl stehen.
    var filter: [Bibliotheksfilter] = Bibliotheksfilter.allCases
    /// `nil` heisst: eine Wurzel, kein Weg — dann ohne Pfeil.
    var zurueck: (() -> Void)?

    /// Wo die Seite steht — **als eigenes Objekt, nicht als `@State`.**
    ///
    /// `onScrollGeometryChange` feuert bei jedem Takt. Schreibt es in ein
    /// `@State` dieser Ansicht, wertet SwiftUI deren ganzen Rumpf neu aus —
    /// Kopf, Filterzeile und das ganze Raster, sechzigmal in der Sekunde.
    /// Beim schnellen Ziehen kommt der Hauptlauf dann nicht mehr nach, die
    /// Scrollfläche verliert den Anschluss und springt. Als `@Observable`
    /// zeichnet nur neu, wer den Wert **liest** — die Leiste und die
    /// Filterzeile.
    @State private var kopfstand = Kopfstand()

    /// Wie weit die Wertreihe schon zugegangen ist, 0 bis 1.
    private var zugegangen: Double {
        Double(min(max(kopfstand.versatz / Stil.wertreihenWeg, 0), 1))
    }

    private var spalten: [GridItem] {
        [GridItem(.adaptive(minimum: Stil.kachelBreite, maximum: Stil.kachelBreite),
                  spacing: Stil.kachelAbstand, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                HStack(alignment: .firstTextBaseline) {
                    // **Der Rueckpfeil steht in der `Bestandsleiste`**, nicht
                    // hier im Inhalt: hier scrollte er weg, und wer weit unten
                    // war, kam nur noch ueber ⌘[ zurueck.
                    VStack(alignment: .leading, spacing: 3) {
                        titelzeile
                        // **Wo bin ich hier eigentlich?** Der Servername
                        // stand auf keiner Seite; bei mehreren Konten mit
                        // gleich benannten Bibliotheken ist er der einzige
                        // Unterschied. GESTALTUNG, Abschnitt J.
                        if let server = model.serverName, !server.isEmpty {
                            Text(verbatim: server)
                                .font(Stil.klein)
                                .foregroundStyle(Stil.schriftSehrLeise)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    // Der gemeinsame Baustein statt einer zweiten Fassung —
                    // sie stand hier zeichengleich nachgebaut.
                    if gezeigt > 0 { Zaehlmarke(anzahl: gezeigt) }
                }

                // **Zwei Knoepfe statt acht Chips.**
                //
                // Hier standen alle Filter und alle Sortierungen als Chips
                // nebeneinander — bei vier und vier sind das acht
                // Gegenstaende in einer Zeile, von denen zwei gelten. Paul am
                // 22.09.: „wir machen das wie auf dem iPhone: einen
                // Alle-Knopf und einen A-bis-Z-Knopf, da drueckt man drauf,
                // dann kommt ein Pop-up. Das ist deutlich cleaner."
                //
                // Der Knopf traegt jetzt den **gewaehlten Wert**; was zur
                // Wahl steht, steht in der Tafel darunter.
                //
                // **Die Bibliothekswahl steht nicht hier.** Sie stand einmal
                // als Chips vorn; seit dem 23.09.2026 ist sie das Titelmenü
                // darüber, das die Überschrift gleich mitnimmt.
                //
                // **Bei „Sammlungen" bleibt die Zeile stehen, nur leer** —
                // die Liste der Sammlungen muss man weder filtern noch
                // umsortieren. Fiele die Zeile weg, spränge das Raster beim
                // Wechsel um ihre Höhe; auf dem iPhone hält `Regalsteuerung`
                // aus demselben Grund ihre Höhe.
                HStack(spacing: 8) {
                    Wahlknopf(symbol: "line.3.horizontal.decrease",
                              wert: regal.filter.beschriftung,
                              eintraege: filter,
                              beschriftung: { $0.beschriftung },
                              istGewaehlt: { $0 == regal.filter },
                              waehlen: { regal.filter = $0 })
                    Wahlknopf(symbol: "arrow.up.arrow.down",
                              wert: regal.sortierung.beschriftung,
                              eintraege: Sortierung.allCases,
                              beschriftung: { $0.beschriftung },
                              istGewaehlt: { $0 == regal.sortierung },
                              waehlen: { regal.sortierung = $0 })
                    Spacer(minLength: 0)
                }
                .opacity(zeigtSammlungen ? 0 : 1)
                .allowsHitTesting(!zeigtSammlungen)
                .accessibilityHidden(zeigtSammlungen)
                .padding(.top, 14)
                // **Sie blendet beim Scrollen weg** — was man vor dem
                // Scrollen wissen will, muss nicht mitfahren (BAUTEILE 7).
                // Nur Deckkraft, keine Hoehe: eine Hoehe am Scrollversatz ist
                // die Schleife aus BAUTEILE 10.
                .opacity(1 - zugegangen)
                .zIndex(20)

                // **Der Platzhalter steht im Fluss, nicht als Auflage.**
                //
                // Er hing als `.overlay(alignment:.topLeading)` mit einem
                // festen Abstand von oben — die Kopfzone darueber ist aber
                // nicht immer gleich hoch: die Bibliothekschips gibt es erst
                // ab zwei Bibliotheken, und die stehen erst da, wenn
                // `model.views` angekommen ist. Beim **ersten** Umschalten war
                // das noch nicht so, der Platzhalter sass also zu weit oben
                // und legte sich ueber die Chipreihe.
                //
                // Im Fluss kann das nicht passieren: er steht dort, wo das
                // Raster stuende, und wandert mit allem darueber.
                if regal.items.isEmpty, regal.laedt, !zeigtSammlungen {
                    Rasterplatzhalter(spalten: geschaetzteSpalten, reihen: 2)
                        .padding(.top, 22)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                LazyVGrid(columns: spalten, alignment: .leading, spacing: 20) {
                    if zeigtSammlungen {
                        sammlungskacheln
                    } else {
                    ForEach(regal.items, id: \.id) { eintrag in
                        Button { navigator.oeffne(.titel(eintrag), in: bereich) } label: {
                            Posterkachel(titel: eintrag.name,
                                         zweitzeile: eintrag.productionYear.map { "\($0)" },
                                         bild: model.imageURL(for: eintrag, hochkant: true),
                                         fortschritt: eintrag.userData?.playedPercentage
                                             .map { $0 / 100 },
                                         marke: Anzeigeregeln.kachelmarke(
                                            art: eintrag.type,
                                            staffeln: eintrag.childCount,
                                            gesehen: eintrag.userData?.played,
                                            offeneFolgen: eintrag.userData?.unplayedItemCount),
                                         zeichen: art == "tvshows" ? "tv" : "film")
                        }
                        .buttonStyle(Stil.Druckknopf())
                        .task {
                            // Nachschub steht, bevor man unten ankommt.
                            if regal.loestNachladenAus(eintrag.id, spalten: geschaetzteSpalten),
                               let quelle {
                                await regal.nachladen(model, aus: quelle)
                            }
                        }
                    }
                    }
                }
                .padding(.top, 22)

                // **Die Seite hatte weder Leer- noch Fehlerzustand.** Lud
                // sie nichts, stand dort nichts — kein Wort dazu, ob die
                // Bibliothek leer ist, der Filter zu eng oder der Server
                // weg. „Jede Ansicht, die lädt, hat sie alle" (BRAND 5).
                // Wortlaut und Ausweg wie auf dem iPhone.
                // „Sammlungen" gibt es im Menü nur, wenn es welche gibt —
                // kein Laden, kein Leer.
                if regal.items.isEmpty, !regal.laedt, !zeigtSammlungen {
                    if regal.gestoert {
                        Leerzustand(
                            symbol: "externaldrive.badge.xmark",
                            kopfzeile: "Server ist abgetaucht",
                            text: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                            hauptknopf: ("Erneut versuchen", { Task { await laden() } }))
                            .padding(.top, 80)
                    } else {
                        Leerzustand(
                            symbol: regal.filter == .alle ? "tray" : "line.3.horizontal.decrease",
                            kopfzeile: regal.filter == .alle ? "Hier ist noch nichts"
                                                             : "Nichts gefunden",
                            text: regal.filter == .alle
                                ? (sammlung == nil
                                   ? "Sobald in dieser Bibliothek etwas liegt, taucht es hier auf."
                                   : "Sobald in dieser Sammlung etwas liegt, taucht es hier auf.")
                                : "Unter \u{201E}\(regal.filter.beschriftung)\u{201C} liegt gerade nichts. Nimm einen anderen Filter.",
                            stillerKnopf: regal.filter == .alle
                                ? ("Aktualisieren", { Task { await laden() } })
                                : ("Filter zurücksetzen", { regal.filter = .alle }))
                            .padding(.top, 80)
                    }
                }
            }
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        // **Der Titel bleibt oben stehen, mit dem Verlauf dahinter** — wie
        // auf dem iPhone. Der grosse Titel scrollt weg, der kleine blendet
        // ein; die beiden sind nie zugleich zu sehen.
        .overlay(alignment: .top) {
            Bestandsleiste(titel: titel, name: kopfname, stand: kopfstand, zurueck: zurueck)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
            kopfstand.versatz = neu
        }
        // **Die milchige Leiste am oberen Rand.** macOS 26 legt sie von sich
        // aus über jede Scrollfläche — sie war nie in unserem Code, und
        // deshalb habe ich zweimal an der falschen Stelle gesucht. Über dem
        // Bild verlor sie sich, links auf blankem Grund stand sie als Balken.
        //
        // E4 wieder: was das Rahmenwerk ungefragt dazustellt, gehört ebenso
        // abgestellt wie das, was man selbst hinschreibt.
        .seitenscrollen()
        // **Kein Ladering.** Statt eines drehenden Rings steht das Raster
        // schon in seiner Form da und wird ueberblendet, sobald die Titel
        // ankommen — die Seite ist dann leer, nicht am Warten.
        // GESTALTUNG, Abschnitt G.
        .animation(Stil.einblenden, value: regal.items.isEmpty)
        .task(id: regal.kennung) { await laden() }
        // **Auch das Regal gehört zu einem Konto.** `.task(id:)` hängt an
        // Sortierung und Filter — die ändern sich beim Kontowechsel nicht,
        // und das Regal lebt in `HauptView`, überlebt also den
        // Leistenwechsel. Ohne diese Zeile stand nach dem Umschalten weiter
        // die Bibliothek des vorigen Kontos da, und zwar bis zum Neustart.
        //
        // Die gemerkte Bibliothek muss mit weg: sie ist ein `Item` des
        // vorigen Kontos, und das neue sieht womöglich eine andere Auswahl.
        // Geleert wird nichts — `Bibliotheksmodell` ersetzt die Einträge
        // erst, wenn die neuen da sind.
        .onChange(of: model.kontowechsel) { _, _ in
            Task { await laden() }
        }
        // **Sammlungen und gemischte Bibliotheken kommen nach** — aus
        // `angebotLaden()`. Ändert sich damit, was „Alle" liest oder was
        // gewählt sein darf, wird neu geladen. Über die Kennungen und nicht
        // über die Anzahl: verschwindet eine Bibliothek und kommt eine neue
        // dazu, bleibt die Anzahl gleich.
        .onChange(of: angebotskennung) { _, _ in
            guard sammlung == nil else { return }
            let neu = model.bereichswahl(art: art)
            guard neu != wahl || quelle?.schluessel != geladeneQuelle else { return }
            wahl = neu
            Task { await laden() }
        }
    }

    /// Für das Nachladen genügt eine Schätzung: ob die drittletzte Reihe bei
    /// sechs oder sieben Spalten beginnt, verschiebt den Auslöser um eine
    /// Kachelbreite. Genau ausrechnen hieße die Fensterbreite mitzuführen.
    private var geschaetzteSpalten: Int { 6 }

    private func laden() async {
        if model.views.isEmpty { await model.loadViews() }
        if sammlung == nil {
            // Sammlungen und gemischte Bibliotheken kommen nebenher: die
            // Seite wartet nicht auf sie.
            Task { await model.angebotLaden() }
            // **Die gemerkte Wahl gehört einem Konto.** Sie wird bei jedem
            // Laden gegen das Angebot des angemeldeten Kontos geprüft; eine
            // Bibliothek des vorigen Kontos gibt es darin nicht, und die
            // Seite fällt auf „Alle" zurück.
            wahl = model.bereichswahl(art: art)
            guard wahl != .sammlungen else { return }
        }
        geladeneQuelle = quelle?.schluessel
        await regal.laden(model, aus: quelle)
    }

    // MARK: Titelmenü

    /// Was der Titel zur Wahl anbietet. Ab zwei Einträgen wird er zum Menü.
    private var angebot: Bereichsangebot { model.bereichsangebot(art: art) }

    private var angebotskennung: String {
        angebot.eintraege.map(\.merkwert).joined(separator: ",") + "|"
            + angebot.alleQuellen.joined(separator: "+")
    }

    private var zeigtSammlungen: Bool { sammlung == nil && wahl == .sammlungen }

    /// Woraus das Raster liest. `nil`: in diesem Bereich gibt es nichts.
    private var quelle: Regalquelle? {
        if let sammlung {
            return Regalquelle(eltern: sammlung.item.id, art: sammlung.art, sammlung: true)
        }
        switch wahl {
        case .alle:
            // Aus einer Bibliothek wie vor dem Umbau; aus mehreren gesiebt,
            // je Titel einmal (``Titelsieb``).
            return angebot.hatBestand
                ? Regalquelle(eltern: angebot.alleAus, art: art,
                              nurAus: angebot.alleAus == nil ? angebot.alleQuellen : [])
                : nil
        case .bibliothek(let id):
            return Regalquelle(eltern: id, art: art)
        case .sammlungen:
            return nil
        }
    }
    @State private var geladeneQuelle: String?

    private var sammlungsliste: [Sammlung] {
        model.sammlungsverzeichnis?.sammlungen(art: art) ?? []
    }

    /// Was die Zählmarke zeigt.
    private var gezeigt: Int { zeigtSammlungen ? sammlungsliste.count : regal.gesamt }

    /// Der Name in der Leiste beim Scrollen — `nil`: der Titel selbst.
    private var kopfname: String? {
        if let sammlung { return sammlung.item.name }
        return wahl == .alle ? nil : beschriftung(wahl)
    }

    /// **„Alle" heißt einfach „Filme".** Der Titel sagt, wo man ist; „Alle
    /// Filme" steht nur im Menü.
    @ViewBuilder
    private var titelzeile: some View {
        if let sammlung {
            // Der Name kommt vom Server und wird nicht übersetzt.
            Text(verbatim: sammlung.item.name)
                .font(Stil.titelGross)
                .tracking(Stil.sperrungTitel)
                .foregroundStyle(Stil.schrift)
        } else if angebot.istMenue {
            Titelwahl(titel: wahl == .alle ? Text(titel) : Text(verbatim: beschriftung(wahl)),
                      eintraege: angebot.eintraege,
                      beschriftung: { beschriftung($0) },
                      istGewaehlt: { $0 == wahl },
                      rubrik: { $0 == angebot.ersteBibliothek ? "Bibliotheken" : nil },
                      waehlen: { neu in
                          guard neu != wahl else { return }
                          model.bereichWaehlen(neu, art: art)
                          wahl = neu
                          Task { await laden() }
                      })
        } else {
            Text(titel)
                .font(Stil.titelGross)
                .tracking(Stil.sperrungTitel)
                .foregroundStyle(Stil.schrift)
        }
    }

    /// **Sammlungen im selben Raster, mit derselben Kachel.** Unter dem
    /// Namen steht statt des Jahres, wie viele Filme bzw. Serien darin sind.
    /// Ohne eigenes Bild steht ein Mosaik aus den ersten Plakaten da.
    @ViewBuilder
    private var sammlungskacheln: some View {
        ForEach(sammlungsliste) { eintrag in
            Button {
                navigator.oeffne(.sammlung(eintrag.item, art: art), in: bereich)
            } label: {
                Posterkachel(titel: eintrag.item.name,
                             zweitzeile: anzahltext(eintrag.anzahl(art: art)),
                             bild: model.imageURL(for: eintrag.item, hochkant: true),
                             zeichen: art == "tvshows" ? "tv" : "film",
                             mosaik: eintrag.item.imageTags?["Primary"] == nil
                                 ? (model, eintrag, art) : nil)
            }
            .buttonStyle(Stil.Druckknopf())
        }
    }

    private func anzahltext(_ n: Int) -> String {
        Sammlung.anzahltext(art: art, anzahl: n)
    }

    private func beschriftung(_ w: Bereichswahl) -> String {
        switch w {
        case .alle:
            art == "tvshows" ? String(localized: "Alle Serien") : String(localized: "Alle Filme")
        case .sammlungen:
            String(localized: "Sammlungen")
        case .bibliothek(let id):
            angebot.bibliothek(id)?.name ?? ""
        }
    }
}
