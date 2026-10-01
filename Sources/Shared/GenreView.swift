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
    /// Titel, die der Server insgesamt hat — fuer die Zaehlmarke und die
    /// Frage „gibt es noch mehr".
    @State private var gesamt = 0
    /// Wie viele Eintraege des Servers schon abgerufen sind. **Nicht
    /// `items.count`:** Doppelte (ein Werk in zwei Bibliotheken) fallen je
    /// Seite weg, der Server zaehlt sie aber mit — nachgeladen wird ab
    /// dem Abrufstand, sonst kaeme dieselbe Seite wieder.
    @State private var abgerufen = 0
    @State private var laedtNach = false
    /// Aendert sich bei Sehstand oder Merkliste anderswo — dann still neu.
    @State private var auffrischStand = 0
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
                Leerzustand.serverAbgetaucht(model, erneut: { Task { await holen() } })
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
        // Auch bei Gesehen-/Lesezeichenwechsel anderswo: still neu laden
        // (ohne Platzhalter, mit so viel, wie schon dasteht), sonst zeigt die
        // Kachel Balken und Haken von vorher.
        .task(id: "\(name)|\(auffrischStand)") { await holen() }
        .nachholen(bei: model.listenAuffrischen) { auffrischStand = model.listenAuffrischen }
    }

    private func holen() async {
        laedt = items.isEmpty
        let stand = abgerufen
        let umfang = min(300, max(AppModel.seitengroesse, stand))
        let ergebnis = await model.titelMitZahl(gattung: name, limit: umfang)
        // Ein abgebrochener Lauf (`.task(id:)`) hat nichts mehr zu sagen.
        guard !Task.isCancelled else { return }
        // Hat `nachladen` waehrenddessen eine Seite angehaengt, ist diese
        // Antwort kuerzer als das, was dasteht: die Liste wuerde schrumpfen
        // und gleich wieder nachladen. Dann noch einmal mit dem neuen Umfang.
        guard stand == abgerufen else { return await holen() }
        if let ergebnis {
            gestoert = false
            items = ergebnis.items
            gesamt = ergebnis.gesamt
            abgerufen = umfang
        } else {
            // Bleibt eine Liste stehen, ist sie besser als eine Stoermeldung.
            gestoert = items.isEmpty
        }
        laedt = false
    }

    private func nachladen() async {
        guard abgerufen < gesamt, !laedtNach, !laedt else { return }
        laedtNach = true
        defer { laedtNach = false }
        let ab = abgerufen
        guard let seite = await model.titelMitZahl(gattung: name, startIndex: ab),
              ab == abgerufen else { return }
        // Seitenuebergreifend nach Kennung: die Seite fasst nur ihre eigenen
        // Doppelten zusammen.
        items = Listenregeln.anhaengen(seite.items, an: items)
        gesamt = seite.gesamt
        abgerufen = ab + AppModel.seitengroesse
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
                if !items.isEmpty { Zaehlmarke(anzahl: max(gesamt, items.count)) }
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
                    .kachelmenue(item, model: model)
                    .onAppear {
                        guard Listenregeln.imNachladebereich(item.id, in: items, spalten: spalten)
                        else { return }
                        Task { await nachladen() }
                    }
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
