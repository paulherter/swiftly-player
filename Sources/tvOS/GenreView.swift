import JellyfinKit
import SwiftUI

/// **Alle Titel eines Genres** — aus den Chips auf der Startseite.
///
/// Dasselbe Gitter wie die Bibliothek, dieselbe Spaltenzahl. Die zuletzt
/// hinzugefügten zuerst: wer ein Genre öffnet, sucht meist, was neu ist.
struct GenreView: View {
    let model: AppModel
    let name: String

    @State private var items: [Item] = []
    @State private var laedt = true

    private var spalten: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Stil.gitterSpalte),
              count: Stil.gitterSpalten)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Der Name kommt vom Server und wird nicht übersetzt.
                Reihentitel(name: name)
                    .padding(.horizontal, Stil.randSeite)
                    .padding(.top, Stil.kopfversatzDetail + 40)
                    .padding(.bottom, Stil.titelAbstand)

                LazyVGrid(columns: spalten, alignment: .leading, spacing: Stil.gitterZeile) {
                    ForEach(items) { item in
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
                    }
                }
                .padding(.horizontal, Stil.randSeite)
            }
            .padding(.bottom, Stil.abschlussLuft)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .overlay {
            if !laedt, items.isEmpty {
                Leerzustand(symbol: "tag", titel: "Nichts in diesem Genre",
                            hinweis: "Auf deinem Server steht gerade kein Film und keine Serie darin.")
            }
        }
        .task(id: name) {
            items = await model.titel(gattung: name, limit: 200) ?? []
            laedt = false
        }
    }
}
