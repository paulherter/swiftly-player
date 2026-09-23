import JellyfinKit
import SwiftUI

/// **Alle Titel eines Genres** — aus den Chips auf der Startseite.
///
/// Dasselbe Raster wie Bibliothek und Suche, dieselbe Spaltenrechnung. Die
/// zuletzt hinzugefügten zuerst: wer ein Genre anklickt, sucht meist, was
/// neu ist.
struct GenreView: View {
    let model: AppModel
    let name: String
    let zurueck: () -> Void

    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    @State private var items: [Item] = []
    @State private var laedt = true
    /// **`nil` heisst gestoert, `[]` heisst leer.** `model.titel` gibt beides
    /// getrennt zurueck, und hier stand `?? []` — der Unterschied wurde also
    /// weggeworfen, und ein Netzfehler wurde zur Aussage „in diesem Genre
    /// gibt es nichts".
    @State private var gestoert = false

    private var spalten: [GridItem] {
        [GridItem(.adaptive(minimum: Stil.kachelBreite, maximum: Stil.kachelBreite),
                  spacing: Stil.kachelAbstand, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Der Name kommt vom Server und wird nicht übersetzt.
                Unterseitenkopf(name: name, zurueck: zurueck)

                // Erst die Form, dann der Inhalt — wie in der Bibliothek.
                if items.isEmpty, laedt {
                    Rasterplatzhalter(spalten: 6, reihen: 2).padding(.top, 20)
                }

                LazyVGrid(columns: spalten, alignment: .leading, spacing: 20) {
                    ForEach(items, id: \.id) { eintrag in
                        Button { navigator.oeffne(.titel(eintrag), in: bereich) } label: {
                            Posterkachel(titel: eintrag.name,
                                         zweitzeile: eintrag.productionYear.map { "\($0)" },
                                         bild: model.imageURL(for: eintrag, hochkant: true),
                                         fortschritt: eintrag.userData?.playedPercentage.map { $0 / 100 },
                                         marke: Anzeigeregeln.kachelmarke(
                                            art: eintrag.type,
                                            staffeln: eintrag.childCount,
                                            gesehen: eintrag.userData?.played,
                                            offeneFolgen: eintrag.userData?.unplayedItemCount),
                                         zeichen: eintrag.type == "Series" ? "tv" : "film",
                                         vorholen: { Serienspeicher.geteilt.vorholen(eintrag, mit: model) })
                        }
                        .buttonStyle(Stil.Druckknopf())
                    }
                }
                .padding(.top, 20)

                if !laedt, gestoert, items.isEmpty {
                    Leerzustand(
                        symbol: "externaldrive.badge.xmark",
                        kopfzeile: "Server ist abgetaucht",
                        text: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        hauptknopf: ("Erneut versuchen", { Task { await holen() } }))
                        .padding(.top, 80)
                } else if !laedt, items.isEmpty {
                    // **Ohne Knopf, und das mit Absicht.** Ein Leerzustand
                    // bekommt nur dann einen, wenn es etwas zu tun gibt
                    // (BAUTEILE 6); hier ist der Ausweg der Rückweg.
                    Leerzustand(symbol: "tag", kopfzeile: "Nichts in diesem Genre",
                                text: "In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien.")
                        .padding(.top, 80)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .seitenscrollen()
        .task(id: name) { await holen() }
    }

    private func holen() async {
        laedt = true
        let ergebnis = await model.titel(gattung: name, limit: 200)
        gestoert = ergebnis == nil
        items = ergebnis ?? []
        laedt = false
    }
}
