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
    /// **Wie in der Bibliothek, nicht anders.** Die Sortierung stand hier als
    /// zweite Chipreihe neben der Gattung — auf Filme und Serien ist sie ein
    /// Knopf, der eine Tafel unter sich aufklappt. Zwei Fassungen derselben
    /// Frage auf Nachbarseiten; Und die Chipreihe hatte einen zweiten
    /// Nachteil: sie faengt die Menue-Taste nicht, also verliess Zurueck die
    /// Seite, statt die Auswahl zu schliessen.
    @State private var sortierwahlOffen = false
    @FocusState private var amSortierknopf: Bool
    @Environment(\.tafelOffen) private var tafelOffen

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
        // Hinter der offenen Tafel ist nichts fokussierbar — wie in der
        // Bibliothek; sonst steigt der Fokus aus der Tafel heraus.
        .disabled(sortierwahlOffen)
        .overlay(alignment: .topTrailing) {
            if sortierwahlOffen {
                Handlungstafel(handlungen: sortierhandlungen, offen: $sortierwahlOffen)
                    .padding(.trailing, Stil.randSeite)
                    .padding(.top, Stil.erstesEnde + 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: sortierwahlOffen)
        // Die Seite schaltet sich selbst ab, die Kopfleiste gehoert ihr aber
        // nicht — die muss `HauptView` stilllegen.
        .onChange(of: sortierwahlOffen) { _, offen in
            tafelOffen.wrappedValue = offen
            if !offen { amSortierknopf = true }
        }
        .onDisappear { tafelOffen.wrappedValue = false }
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

            // Der Strich, der hier stand, trennte die Gattung von einer
            // zweiten Chipreihe. Die ist zur Tafel geworden und steht rechts
            // — jetzt trennt der Abstand, und ein Strich mitten im Nichts
            // bliebe stehen.
            Spacer(minLength: 40)

            if stand.gesamt > 0 {
                Text("\(stand.gesamt) · sortiert nach")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }

            Button { sortierwahlOffen.toggle() } label: {
                HStack(spacing: 14) {
                    Text(stand.sortierung.beschriftung)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Stil.schrift.opacity(0.6))
                }
            }
            .buttonStyle(KnopfStil(hoehe: Stil.chipHoehe))
            .focused($amSortierknopf)
            .accessibilityLabel(Text("Sortierung, \(stand.sortierung.beschriftung)"))
        }
        .focusSection()
    }

    private var sortierhandlungen: [Titelhandlung] {
        Sortierung.allCases.map { fall in
            Titelhandlung(symbol: stand.sortierung == fall ? "checkmark" : "arrow.up.arrow.down",
                          // `beschriftung` ist eine fertige Zeichenkette —
                          // sie wird im Modell uebersetzt, nicht hier.
                          text: LocalizedStringKey(fall.beschriftung)) {
                stand.sortierung = fall
            }
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
