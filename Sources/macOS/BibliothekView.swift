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

    @State private var regal = Bibliotheksmodell()

    private var spalten: [GridItem] {
        [GridItem(.adaptive(minimum: Stil.kachelBreite, maximum: Stil.kachelBreite),
                  spacing: Stil.kachelAbstand, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                HStack(alignment: .firstTextBaseline) {
                    Text(titel)
                        .font(Stil.titelGross)
                        .tracking(-0.6)
                        .foregroundStyle(Stil.schrift)
                    Spacer()
                    if regal.gesamt > 0 {
                        Text(verbatim: "\(regal.gesamt)")
                            .font(.system(size: 13))
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }
                }

                HStack(spacing: 8) {
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

                LazyVGrid(columns: spalten, alignment: .leading, spacing: 20) {
                    ForEach(regal.items, id: \.id) { eintrag in
                        NavigationLink(value: eintrag) {
                            Posterkachel(titel: eintrag.name,
                                         zweitzeile: eintrag.productionYear.map { "\($0)" },
                                         bild: model.imageURL(for: eintrag, hochkant: true))
                        }
                        .buttonStyle(.plain)
                        .task {
                            // Nachschub steht, bevor man unten ankommt.
                            if eintrag.id == regal.nachladenAb(spalten: geschaetzteSpalten) {
                                await regal.nachladen(model, art: art)
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
        .overlay { if regal.laedt { Lader() } }
        .task(id: regal.kennung) { await regal.laden(model, art: art) }
    }

    /// Für das Nachladen genügt eine Schätzung: ob die drittletzte Reihe bei
    /// sechs oder sieben Spalten beginnt, verschiebt den Auslöser um eine
    /// Kachelbreite. Genau ausrechnen hieße die Fensterbreite mitzuführen.
    private var geschaetzteSpalten: Int { 6 }
}
