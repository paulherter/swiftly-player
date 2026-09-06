import JellyfinKit
import SwiftUI

/// Was gemerkt ist, quer über alle Bibliotheken — die Fernseherfassung.
///
/// **Eine Bibliothek wie jede andere, nur ist ihre Grenze der Haken.** Nicht
/// ein Ordner auf der Platte, sondern was der Nutzer angetippt hat; deshalb
/// sind Filme und Serien hier gemischt. Aufbau und Bausteine sind die der
/// Bibliotheksseite — Chipreihe, Anzahl, Gitter, Kachelmarken, Platzhalter
/// statt Ring.
///
/// **Und hier ist sie ein eigener Bereich**, kein Ziel aus einer Ecke. Auf
/// dem iPhone gehört der vierte Platz unten den Downloads, und die gibt es
/// auf einem Fernseher nicht — dort steckt kein Speicher, den man füllen
/// will, und die Kiste steht ohnehin am Netz. Der Platz in der Kopfleiste ist
/// also frei, und ein Reiter ist mit einer Fernbedienung der kürzeste Weg.
/// Der Grund ist Eingabeart und Gerät; damit erlaubt ihn Abschnitt F.
struct MerklisteView: View {
    let model: AppModel

    @State private var stand = Merklistenmodell()
    @State private var gattung: Merkgattung = .alle

    private var spalten: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Stil.gitterSpalte),
              count: Stil.gitterSpalten)
    }

    var body: some View {
        ZStack {
            if stand.items.isEmpty, stand.laedt {
                Rasterplatzhalter()
                    .padding(.horizontal, Stil.randSeite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, Stil.leisteUnten + 90)
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        chipreihe
                        if stand.items.isEmpty {
                            // **Der Leerzustand sagt, wie man hineinkommt.**
                            // Sonst steht dort eine Sackgasse.
                            Leerzustand(symbol: "bookmark",
                                        titel: "Noch nichts gemerkt",
                                        hinweis: "Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort auswählst, sammelt sich hier.")
                                .frame(height: 460)
                        } else {
                            gitter
                        }
                    }
                    .padding(.top, Stil.erstesEnde - Stil.chipHoehe - Stil.randOben)
                    .padding(.bottom, 60)
                    .padding(.horizontal, Stil.randSeite)
                }
            }
        }
        .animation(Stil.einblenden, value: stand.items.isEmpty)
        .task(id: "\(stand.kennung)|\(model.kontowechsel)") { await stand.laden(model) }
    }

    private var chipreihe: some View {
        HStack(alignment: .center, spacing: 20) {
            ForEach(Merkgattung.allCases) { fall in
                Button(fall.beschriftung) {
                    gattung = fall
                    stand.gattung = fall.art
                }
                .buttonStyle(ChipStil(an: gattung == fall))
            }

            // Senkrechter Strich statt Abstand: zwei Chipsorten nebeneinander
            // sehen sonst aus wie eine Reihe, und man sieht nicht, welche
            // Frage welche ist.
            Rectangle()
                .fill(Stil.rand)
                .frame(width: 2, height: Stil.chipHoehe * 0.6)

            ForEach(Sortierung.allCases) { fall in
                Button(fall.beschriftung) { stand.sortierung = fall }
                    .buttonStyle(ChipStil(an: stand.sortierung == fall))
            }

            Spacer(minLength: 40)

            if stand.gesamt > 0 { Zaehlmarke(anzahl: stand.gesamt) }
        }
    }

    private var gitter: some View {
        LazyVGrid(columns: spalten, alignment: .leading, spacing: Stil.gitterZeile) {
            ForEach(stand.items) { item in
                NavigationLink(value: item) {
                    Kachelinhalt(bild: model.imageURL(for: item, maxHeight: 600,
                                                      hochkant: true),
                                 titel: item.name,
                                 fortschritt: item.userData?.playedPercentage
                                     .map { $0 / 100 },
                                 mitUnterzeile: false,
                                 marke: Anzeigeregeln.kachelmarke(
                                    art: item.type,
                                    staffeln: item.childCount,
                                    gesehen: item.userData?.played,
                                    offeneFolgen: item.userData?.unplayedItemCount))
                }
                .buttonStyle(KachelStil())
                .onAppear {
                    guard item.id == stand.nachladenAb(spalten: Stil.gitterSpalten)
                    else { return }
                    Task { await stand.nachladen(model) }
                }
            }
        }
    }
}
