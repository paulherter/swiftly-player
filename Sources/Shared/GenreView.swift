import JellyfinKit
import SwiftUI

/// **Alle Titel eines Genres** — aus den Chips auf der Startseite.
///
/// Dasselbe Raster wie Bibliothek, Suche und Merkliste, dieselbe
/// Spaltenrechnung. Die zuletzt hinzugefügten zuerst: wer ein Genre antippt,
/// sucht meist, was neu ist.
struct GenreView: View {
    let model: AppModel
    let name: String

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var items: [Item] = []
    @State private var laedt = true

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            VStack(spacing: 0) {
                // Der Name kommt vom Server und wird nicht übersetzt.
                Unterseitenkopf(titel: name) { zurueck() }
                GeometryReader { rahmen in
                    raster(spalten: Stil.spalten(nutzbar: rahmen.size.width - 2 * Stil.rand(breit: breit),
                                                 breit: breit))
                }
            }
            if !laedt, items.isEmpty {
                Leerzustand(symbol: "tag",
                            kopfzeile: "Nichts in diesem Genre",
                            text: "Auf deinem Server steht gerade kein Film und keine Serie darin.")
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task(id: name) {
            items = await model.titel(gattung: name, limit: 200) ?? []
            laedt = false
        }
    }

    private func raster(spalten: Int) -> some View {
        ScrollView {
            // Erst die Form, dann der Inhalt — wie in der Bibliothek.
            if items.isEmpty, laedt {
                Rasterplatzhalter(spalten: spalten)
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.top, 8)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Stil.kachelAbstand),
                                     count: spalten),
                      alignment: .leading, spacing: 20) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        PosterTile(model: model, item: item, breite: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }
}
