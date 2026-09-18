import JellyfinKit
import SwiftUI

/// Die Folgen der laufenden Staffel, aus dem Player heraus.
///
/// Auf dem iPhone sitzt derselbe Knopf oben rechts im Player. Dieselbe Liste
/// wie auf der Serienseite — deshalb `Folgenzeile` und kein zweiter Aufbau.
struct Folgenblatt: View {
    let model: AppModel
    /// Die gerade laufende Folge.
    let item: Item
    @Binding var offen: Bool
    let waehlen: (Item) -> Void

    @State private var folgen: [Item] = []
    @State private var laedt = true

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(item.seriesName ?? String(localized: "Folgen"))
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Stil.schrift)
                    Spacer(minLength: 0)
                    Button("Fertig") { offen = false }
                        .buttonStyle(KnopfStil())
                }
                .padding(.bottom, 36)

                if laedt {
                    Lader.fern.frame(maxWidth: .infinity).padding(.vertical, 100)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(folgen) { folge in
                                Folgenzeile(model: model, folge: folge) {
                                    waehlen(folge)
                                }
                            }
                        }
                    }
                    .scrollClipDisabled()
                    .scrollIndicators(.hidden)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Stil.randSeite)
            .padding(.vertical, Stil.randOben)
        }
        .onExitCommand { offen = false }
        .task {
            guard let serie = item.seriesId else {
                laedt = false
                return
            }
            folgen = await model.folgen(serie: serie, staffel: item.seasonId)
            laedt = false
        }
    }
}
