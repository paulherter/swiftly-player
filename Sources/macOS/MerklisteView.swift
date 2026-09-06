import JellyfinKit
import SwiftUI

/// Was gemerkt ist, quer über alle Bibliotheken — die Mac-Fassung.
///
/// **Eine Bibliothek wie jede andere, nur ist ihre Grenze der Haken.** Nicht
/// ein Ordner auf der Platte, sondern was der Nutzer angetippt hat; deshalb
/// sind Filme und Serien hier gemischt. Aufbau und Bausteine sind die der
/// Bibliotheksseite — Kopf mit Titel und Zählmarke, Chipreihe, Raster. Eine
/// eigene Seitenart wäre eine zweite Grammatik für dieselbe Sache.
///
/// **Breit zeigt Möglichkeiten, schmal zeigt Werte** (GESTALTUNG, Abschnitt
/// I): auf dem iPhone stehen dort zwei Pillen mit dem geltenden Wert, hier
/// stehen die Möglichkeiten offen nebeneinander. Der Grund ist die
/// Fenstergröße, und damit erlaubt ihn Abschnitt F.
struct MerklisteView: View {
    let model: AppModel
    /// Wird von der Kopfzeile gerufen; hier gibt es keinen eigenen Pfeil —
    /// den zeichnet `HauptView` über jeder aufgeschobenen Seite.

    @State private var stand = Merklistenmodell()
    @State private var gattung: Merkgattung = .alle

    private var spalten: [GridItem] {
        [GridItem(.adaptive(minimum: Stil.kachelBreite, maximum: Stil.kachelBreite),
                  spacing: Stil.kachelAbstand, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Merkliste")
                        .font(Stil.titelGross)
                        .tracking(-0.6)
                        .foregroundStyle(Stil.schrift)
                    Spacer()
                    if stand.gesamt > 0 { Zaehlmarke(anzahl: stand.gesamt) }
                }

                HStack(spacing: 8) {
                    ForEach(Merkgattung.allCases) { fall in
                        Chip(beschriftung: fall.beschriftung, aktiv: gattung == fall) {
                            gattung = fall
                            stand.gattung = fall.art
                        }
                    }
                    // **Rechts, und mit demselben Zeichen wie nebenan.**
                    //
                    // Die Sortierung stand hier links, unmittelbar hinter der
                    // Gattung und durch einen Strich getrennt — auf Filme und
                    // Serien steht sie rechts aussen, mit einem Trichter am
                    // gewaehlten Wert. Zwei Fassungen derselben Frage auf
                    // Nachbarseiten; der Strich faellt damit weg, denn der
                    // Abstand trennt jetzt.
                    Spacer()
                    ForEach(Sortierung.allCases) { fall in
                        Chip(beschriftung: fall.beschriftung,
                             symbol: fall == stand.sortierung ? "line.3.horizontal.decrease" : nil,
                             aktiv: stand.sortierung == fall) {
                            stand.sortierung = fall
                        }
                    }
                }
                .padding(.top, 14)

                LazyVGrid(columns: spalten, alignment: .leading, spacing: 24) {
                    ForEach(stand.items, id: \.id) { eintrag in
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
                                         zeichen: eintrag.type == "Series" ? "tv" : "film")
                        }
                        .buttonStyle(.plain)
                        .task {
                            if eintrag.id == stand.nachladenAb(spalten: 6) {
                                await stand.nachladen(model)
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
        .ohneKanteneffekt()
        // Kein Ladering: das Raster steht schon in seiner Form da.
        .overlay(alignment: .topLeading) {
            if stand.items.isEmpty, stand.laedt {
                Rasterplatzhalter(spalten: 6, reihen: 2)
                    .padding(.horizontal, Stil.randAbstand)
                    .padding(.top, Stil.inhaltOben + 90)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if stand.items.isEmpty, !stand.laedt {
                // **Der Leerzustand sagt, wie man hineinkommt.** Sonst steht
                // dort eine Sackgasse.
                Leerzustand(symbol: "bookmark",
                            titel: "Noch nichts gemerkt",
                            text: "Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort antippst, sammelt sich hier.")
            }
        }
        .animation(Stil.einblenden, value: stand.items.isEmpty)
        .task(id: "\(stand.kennung)|\(model.kontowechsel)") { await stand.laden(model) }
    }

    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich
}
