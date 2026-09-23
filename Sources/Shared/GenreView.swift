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
    /// Der Abruf ist gescheitert — nicht „das Genre ist leer".
    @State private var gestoert = false
    /// Wie weit gescrollt ist — fuer Verlauf und Scrollkante des Kopfes.
    ///
    /// **Ohne Rueckkopplung:** dieser Kopf ist immer gleich hoch (keine
    /// Wertreihe, die zuklappt), und gemessen wird ohnehin die Summe aus
    /// Versatz und oberem Rand — die bleibt richtig, auch wenn sich der Rand
    /// aendert. Siehe die lange Begruendung in `MerklisteView`.
    @State private var versatz: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            GeometryReader { rahmen in
                raster(spalten: Stil.spalten(nutzbar: rahmen.size.width - 2 * Stil.rand(breit: breit),
                                             breit: breit))
            }
            if !laedt, gestoert {
                // **`nil` heisst gestoert, `[]` heisst leer.** `model.titel`
                // gibt beides getrennt zurueck, und hier stand `?? []` — der
                // Unterschied wurde also weggeworfen, und ein Netzfehler
                // wurde zur Aussage „in diesem Genre gibt es nichts".
                Leerzustand(
                    symbol: "externaldrive.badge.xmark",
                    kopfzeile: "Server ist abgetaucht",
                    text: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                    hauptknopf: ("Erneut versuchen", { Task { await holen() } }))
            } else if !laedt, items.isEmpty {
                Leerzustand(symbol: "tag",
                            kopfzeile: "Nichts in diesem Genre",
                            text: "In diesem Genre gibt es auf deinem Server gerade keine Filme und Serien.")
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task(id: name) { await holen() }
    }

    private func holen() async {
        laedt = true
        let ergebnis = await model.titel(gattung: name, limit: 200)
        gestoert = ergebnis == nil
        items = ergebnis ?? []
        laedt = false
    }

    /// **Derselbe Kopf wie auf den beiden anderen gepushten Rasterseiten.**
    ///
    /// Er stand hier fest ueber der Scrollflaeche: kein Verlauf, keine
    /// Scrollkante, Plakate liefen an einer harten Kante vorbei. Merkliste
    /// und die Downloadunterseite haengen ihren Kopf seit dem Umbau in
    /// `Unschaerfekopf` und geben ihm den Versatz mit; Genre war die einzige
    /// der drei, die das nicht tat.
    ///
    /// `Unterseitenkopf` bringt seinen eigenen Seitenrand mit, `Unschaerfekopf`
    /// auch — der innere wird deshalb zurueckgerechnet, genau wie in
    /// `MerklisteView` und `DownloadsView`.
    private var kopf: some View {
        Unschaerfekopf(versatz: versatz) {
            // Der Name kommt vom Server und wird nicht übersetzt.
            //
            // **Rechts die Zählmarke, und sonst nichts.** Eine Unterseite
            // trägt Pfeil, Titel und Zählmarke (BRAND, Abschnitt 7) — die
            // fehlte hier, dabei ist „bin ich hier durch?" bei einem Genre
            // dieselbe Frage wie in der Bibliothek. Ein Servername gehört
            // dagegen ausdrücklich **nicht** hierher: den zeigt allein die
            // Bibliotheksseite, weil dort bei zwei Konten zwei
            // Bibliotheken gleich heißen können.
            Unterseitenkopf(titel: name, zurueck: { zurueck() }) {
                if !items.isEmpty { Zaehlmarke(anzahl: items.count) }
            }
            .padding(.horizontal, -Stil.rand(breit: breit))
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
                    .buttonStyle(Stil.Druckknopf())
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentOffset.y + $0.contentInsets.top
        } action: { _, neu in versatz = neu }
        // Der Kopf sitzt als Sicherheitsrand, nicht als Auflage — die
        // Begruendung steht in `HauptView`. Kurz: sein oberer Rand kam sonst
        // aus einer eigenen Messung, die in dieselbe Flaeche zurueckgeht.
        .safeAreaInset(edge: .top, spacing: 0) { kopf }
    }
}
