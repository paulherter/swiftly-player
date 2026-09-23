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

    @State private var stand: Merklistenmodell

    init(model: AppModel) {
        self.model = model
        let frisch = Merklistenmodell()
        _stand = State(initialValue: frisch)
        _gattung = State(initialValue: Merkgattung.zu(art: frisch.gattung))
    }
    /// Die Pille der Ansicht und die Gattung im Modell muessen beim Start
    /// dasselbe sagen — das Modell holt sie aus der Ablage, die Ansicht
    /// liest sie von dort ab.
    @State private var gattung: Merkgattung

    /// Wo die Seite steht — als eigenes Objekt, damit ein Scrolltakt nicht
    /// den ganzen Rumpf neu auswertet. Begruendung an `Kopfstand`.
    @State private var kopfstand = Kopfstand()

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
                    Text("Merkliste")
                        .font(Stil.titelGross)
                        .tracking(Stil.sperrungTitel)
                        .foregroundStyle(Stil.schrift)
                    Spacer()
                    if stand.gesamt > 0 { Zaehlmarke(anzahl: stand.gesamt) }
                }

                HStack(spacing: 8) {
                    // **Zwei Knoepfe statt sechs Chips** — dieselbe
                    // Umstellung wie auf Filme und Serien, damit die
                    // Nachbarseiten dieselbe Frage gleich stellen.
                    Wahlknopf(symbol: "square.grid.2x2",
                              wert: gattung.beschriftung,
                              eintraege: Merkgattung.allCases,
                              beschriftung: { $0.beschriftung },
                              istGewaehlt: { $0 == gattung },
                              waehlen: { fall in
                                  gattung = fall
                                  stand.gattung = fall.art
                              })
                    Wahlknopf(symbol: "arrow.up.arrow.down",
                              wert: stand.sortierung.beschriftung,
                              eintraege: Sortierung.allCases,
                              beschriftung: { $0.beschriftung },
                              istGewaehlt: { $0 == stand.sortierung },
                              waehlen: { stand.sortierung = $0 })
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
                .opacity(1 - zugegangen)
                .zIndex(20)

                LazyVGrid(columns: spalten, alignment: .leading, spacing: 20) {
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
                        .buttonStyle(Stil.Druckknopf())
                        .task {
                            if stand.loestNachladenAus(eintrag.id, spalten: 6) {
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
        .overlay(alignment: .top) {
            Bestandsleiste(titel: "Merkliste", stand: kopfstand)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
            kopfstand.versatz = neu
        }
        .seitenscrollen()
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
                // **Gestört ist nicht leer.** Das Modell unterscheidet
                // beides (`Merklistenmodell.gestoert`); hier stand nur die
                // eine Antwort, und die falsche schickt einen zum Server
                // statt zum Netz.
                if stand.gestoert {
                    Leerzustand(
                        symbol: "externaldrive.badge.xmark",
                        kopfzeile: "Server ist abgetaucht",
                        text: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        hauptknopf: ("Erneut versuchen", { Task { await stand.laden(model) } }))
                } else {
                    // **Der Leerzustand sagt, wie man hineinkommt.** Sonst
                    // steht dort eine Sackgasse.
                    Leerzustand(symbol: "bookmark",
                                kopfzeile: "Noch nichts gemerkt",
                                text: "Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort antippst, sammelt sich hier.")
                }
            }
        }
        .animation(Stil.einblenden, value: stand.items.isEmpty)
        .task(id: "\(stand.kennung)|\(model.kontowechsel)") { await stand.laden(model) }
    }

    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich
}
