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
    /// Der Server hat nicht geantwortet — anders als „nichts in diesem Genre".
    @State private var gestoert = false

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
            if laedt {
                // **Kein Ladering, das Raster steht in seiner Form.** So
                // machen es Bibliothek, Merkliste und Suche; diese Seite war
                // die einzige der drei Genre-Fassungen, die beim Laden einen
                // schwarzen Schirm zeigte.
                Rasterplatzhalter()
                    .padding(.horizontal, Stil.randSeite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, Stil.leisteUnten + 90)
                    .transition(.opacity)
            } else if gestoert {
                // **Gestoert ist nicht leer.** `titel(gattung:)` gibt `nil`
                // zurueck, wenn der Server nicht antwortet; das `?? []`
                // machte daraus eine leere Liste, und die Seite behauptete,
                // das Genre sei leer. Derselbe Text wie in der Bibliothek.
                Leerzustand(
                    symbol: "externaldrive.badge.xmark",
                    titel: "Server ist abgetaucht",
                    hinweis: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                    knopf: ("Erneut versuchen", { Task { await laden() } }))
            } else if items.isEmpty {
                // Ein Ausweg, kein Sackgassenschild.
                Leerzustand(symbol: "tag", titel: "Nichts in diesem Genre",
                            hinweis: "In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien.",
                            knopf: ("Aktualisieren", { Task { await laden() } }))
            }
        }
        .animation(Stil.einblenden, value: laedt)
        .task(id: name) { await laden() }
    }

    private func laden() async {
        laedt = true
        let antwort = await model.titel(gattung: name, limit: 200)
        gestoert = antwort == nil
        items = antwort ?? []
        laedt = false
    }
}
