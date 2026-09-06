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
    /// Welche Bibliothek dieser Gattung gezeigt wird. Ein Server kann mehrere
    /// Filmbibliotheken haben; vorher nahm die Ansicht stumm die erste.
    ///
    /// Aus demselben Grund wie das Regal **von aussen**: als `@State` fiele
    /// die Wahl bei jedem Leistenwechsel auf die erste Bibliothek zurück.
    @Binding var gewaehlt: Item?
    /// **Nur diese eine Bibliothek.** Auf einer eigenen Seite gibt es keine
    /// Auswahl: die Seite *ist* die Bibliothek. Die Chipreihe faellt damit
    /// weg, und der Zurueckpfeil kommt dazu.
    var nurDiese = false
    /// `nil` heisst: eine Wurzel, kein Weg — dann ohne Pfeil.
    var zurueck: (() -> Void)?

    private var spalten: [GridItem] {
        [GridItem(.adaptive(minimum: Stil.kachelBreite, maximum: Stil.kachelBreite),
                  spacing: Stil.kachelAbstand, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                HStack(alignment: .firstTextBaseline) {
                    if let zurueck {
                        Button(action: zurueck) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Stil.schrift)
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Zurück"))
                        .padding(.leading, -8)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(titel)
                            .font(Stil.titelGross)
                            .tracking(-0.6)
                            .foregroundStyle(Stil.schrift)
                        // **Wo bin ich hier eigentlich?** Der Servername
                        // stand auf keiner Seite; bei mehreren Konten mit
                        // gleich benannten Bibliotheken ist er der einzige
                        // Unterschied. GESTALTUNG, Abschnitt J.
                        if let server = model.serverName, !server.isEmpty {
                            Text(verbatim: server)
                                .font(.system(size: 13))
                                .foregroundStyle(Stil.schriftSehrLeise)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    // Der gemeinsame Baustein statt einer zweiten Fassung —
                    // sie stand hier zeichengleich nachgebaut.
                    if regal.gesamt > 0 { Zaehlmarke(anzahl: regal.gesamt) }
                }

                HStack(spacing: 8) {
                    // **Die Bibliothekswahl steht vorn, und nur ab zwei.**
                    //
                    // Als Chips wie Filter und Sortierung daneben — auf dem
                    // Mac steht alles offen nebeneinander, und ein `Menu`
                    // waere ein Apple-Standardsteuerelement (E4).
                    if auswahl.count > 1, !nurDiese {
                        ForEach(auswahl) { bib in
                            Chip(beschriftung: bib.name,
                                 aktiv: bib.id == gewaehlt?.id) {
                                guard bib.id != gewaehlt?.id else { return }
                                model.bibliothekWaehlen(bib, art: art)
                                gewaehlt = bib
                                Task { await laden() }
                            }
                        }
                        Rectangle()
                            .fill(Stil.rand)
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, 4)
                    }

                    ForEach(Bibliotheksfilter.allCases) { fall in
                        Chip(beschriftung: fall.beschriftung, aktiv: regal.filter == fall) {
                            regal.filter = fall
                        }
                    }
                    Spacer()
                    ForEach(Sortierung.allCases) { fall in
                        Chip(beschriftung: fall.beschriftung,
                             symbol: fall == regal.sortierung ? "line.3.horizontal.decrease" : nil,
                             aktiv: regal.sortierung == fall) {
                            regal.sortierung = fall
                        }
                    }
                }
                .padding(.top, 14)

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
                if regal.items.isEmpty, regal.laedt {
                    Rasterplatzhalter(spalten: geschaetzteSpalten, reihen: 2)
                        .padding(.top, 22)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                LazyVGrid(columns: spalten, alignment: .leading, spacing: 20) {
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
                        .buttonStyle(.plain)
                        .task {
                            // Nachschub steht, bevor man unten ankommt.
                            if eintrag.id == regal.nachladenAb(spalten: geschaetzteSpalten) {
                                await regal.nachladen(model, art: art, bibliothek: gewaehlt)
                            }
                        }
                    }
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        // **Die milchige Leiste am oberen Rand.** macOS 26 legt sie von sich
        // aus über jede Scrollfläche — sie war nie in unserem Code, und
        // deshalb habe ich zweimal an der falschen Stelle gesucht. Über dem
        // Bild verlor sie sich, links auf blankem Grund stand sie als Balken.
        //
        // E4 wieder: was das Rahmenwerk ungefragt dazustellt, gehört ebenso
        // abgestellt wie das, was man selbst hinschreibt.
        .ohneKanteneffekt()
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
            gewaehlt = nil
            Task { await laden() }
        }
    }

    /// Für das Nachladen genügt eine Schätzung: ob die drittletzte Reihe bei
    /// sechs oder sieben Spalten beginnt, verschiebt den Auslöser um eine
    /// Kachelbreite. Genau ausrechnen hieße die Fensterbreite mitzuführen.
    private var geschaetzteSpalten: Int { 6 }

    private func laden() async {
        if model.views.isEmpty { await model.loadViews() }
        if gewaehlt == nil { gewaehlt = model.gewaehlteBibliothek(art: art) }
        await regal.laden(model, art: art, bibliothek: gewaehlt)
    }

    /// Alle Bibliotheken dieser Gattung. Ab zwei wird der Titel zum Menue.
    private var auswahl: [Item] { model.bibliotheken(art: art) }

}
