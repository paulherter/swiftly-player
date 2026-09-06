import JellyfinKit
import Observation
import SwiftUI

/// Was gemerkt ist, quer über alle Bibliotheken.
///
/// **Eine Bibliothek wie jede andere, nur ist ihre Grenze der Haken.** Nicht
/// ein Ordner auf der Platte, sondern was der Nutzer angetippt hat — und
/// deshalb sind Filme und Serien hier gemischt. Wer trennen will, nimmt die
/// Gattungspille; das ist dieselbe Frage wie in der Bibliothek, nur eine
/// Ebene höher gestellt.
///
/// Aufbau und Bausteine sind die der Bibliotheksseite: Kopf mit Titel,
/// Steuerzeile mit Werten und Zählmarke, darunter das Raster. Eine eigene
/// Seitenart wäre eine zweite Grammatik für dieselbe Sache.
@MainActor
@Observable
final class Merklistenmodell {
    private(set) var items: [Item] = []
    private(set) var gesamt = 0
    private(set) var laedt = true
    private var laedtNach = false

    /// `nil` heisst Filme **und** Serien.
    var gattung: String?
    /// Zuletzt gemerkt zuerst — das ist die Reihenfolge, in der man eine
    /// Merkliste liest. A–Z wäre die Ordnung eines Regals, nicht die einer
    /// Absicht.
    var sortierung: Sortierung = .neueste

    var kennung: String { "\(gattung ?? "-")|\(sortierung.rawValue)" }
    var nochMehrDa: Bool { items.count < gesamt }

    func nachladenAb(spalten: Int) -> String? {
        guard !items.isEmpty else { return nil }
        return items[max(0, items.count - 3 * spalten)].id
    }

    func laden(_ model: AppModel) async {
        laedt = items.isEmpty
        if let seite = await model.gemerkte(art: gattung, sortierung: sortierung, ab: 0) {
            items = seite.titel
            gesamt = seite.gesamt
        }
        laedt = false
    }

    func nachladen(_ model: AppModel) async {
        guard nochMehrDa, !laedtNach, !laedt else { return }
        laedtNach = true
        defer { laedtNach = false }
        guard let seite = await model.gemerkte(art: gattung, sortierung: sortierung,
                                               ab: items.count) else { return }
        // Nur wirklich Neues anhängen: der Server kann eine Seite doppelt
        // liefern, und `ForEach` beschwert sich über die doppelte Kennung.
        let bekannt = Set(items.map(\.id))
        items += seite.titel.filter { !bekannt.contains($0.id) }
        gesamt = seite.gesamt
    }
}

/// Die Gattungen, zwischen denen die Merkliste unterscheidet.
enum Merkgattung: String, CaseIterable, Identifiable {
    case alle, filme, serien
    var id: String { rawValue }

    /// **Nicht „Alle".** Auf der Bibliotheksseite steht an derselben Stelle
    /// eine Pille mit demselben Wort — die meint dort aber den *Zustand*
    /// (alle, angefangen, gemerkt, ungesehen), hier die *Gattung*. Gleiches
    /// Wort, gleiches Zeichen, gleicher Platz, zwei Bedeutungen: das ist
    /// keine Kürze, sondern eine Falle.
    var beschriftung: String {
        switch self {
        case .alle:   String(localized: "Filme & Serien")
        case .filme:  String(localized: "Filme")
        case .serien: String(localized: "Serien")
        }
    }

    /// Jellyfins `CollectionType`, wie ihn `AppModel.gemerkte` erwartet.
    var art: String? {
        switch self {
        case .alle:   nil
        case .filme:  "movies"
        case .serien: "tvshows"
        }
    }
}

struct MerklisteView: View {
    let model: AppModel

    @Environment(\.breit) private var breit
    @State private var stand = Merklistenmodell()
    @State private var gattung: Merkgattung = .alle
    @State private var gattungslisteOffen = false
    @State private var sortierlisteOffen = false
    /// Wie weit gescrollt wurde — daran hängt die Kante unter dem Kopf.
    ///
    /// **Fehlte hier.** Filme und Serien haben sie seit gestern; diese Seite
    /// ist beim Bauen ohne den Wert entstanden, und damit lief ihr Inhalt
    /// weiter unter einem halben Verlauf durch statt hinter einer Leiste.
    /// Dieselbe Seitenart, zwei Verhalten.
    @State private var versatz: CGFloat = 0

    var body: some View {
        GeometryReader { rahmen in
            inhalt(nutzbar: rahmen.size.width - 2 * Stil.rand(breit: breit))
        }
        .overlay(alignment: .topTrailing) {
            Auswahlblatt(offen: $gattungslisteOffen,
                         titel: "Gattung",
                         eintraege: Merkgattung.allCases,
                         beschriftung: { $0.beschriftung },
                         istGewaehlt: { $0 == gattung },
                         waehlen: { gattung = $0; stand.gattung = $0.art })
        }
        .overlay(alignment: .topTrailing) {
            Auswahlblatt(offen: $sortierlisteOffen,
                         titel: "Sortieren",
                         eintraege: Sortierung.allCases,
                         beschriftung: { $0.beschriftung },
                         istGewaehlt: { $0 == stand.sortierung },
                         waehlen: { stand.sortierung = $0 })
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task(id: "\(stand.kennung)|\(model.kontowechsel)") { await stand.laden(model) }
    }

    @ViewBuilder
    private func inhalt(nutzbar: CGFloat) -> some View {
        let spalten = Stil.spalten(nutzbar: nutzbar, breit: breit)
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                // Erst die Form, dann der Inhalt — wie in der Bibliothek.
                if stand.items.isEmpty, stand.laedt {
                    Rasterplatzhalter(spalten: spalten)
                        .padding(.horizontal, Stil.rand(breit: breit))
                        .padding(.top, 8)
                        .transition(.opacity)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Stil.kachelAbstand),
                                         count: spalten),
                          alignment: .leading, spacing: 20) {
                    ForEach(stand.items) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, breite: nil)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            guard item.id == stand.nachladenAb(spalten: spalten) else { return }
                            Task { await stand.nachladen(model) }
                        }
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 8)
                .opacity(stand.items.isEmpty ? 0 : 1)
            }
            .scrollIndicators(.hidden)
            .animation(Stil.einblenden, value: stand.items.isEmpty)
            // Null im Ruhezustand — wie in der Bibliothek.
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, neu in versatz = neu }
            .contentMargins(.top, kopfhoehe + 20, for: .scrollContent)
            .contentMargins(.bottom, 24, for: .scrollContent)

            kopf
                .onGeometryChange(for: CGFloat.self) { $0.size.height }
                    action: { kopfhoehe = $0 }

            if stand.items.isEmpty, !stand.laedt {
                // **Der Leerzustand sagt, wie man hineinkommt.** Sonst steht
                // dort eine Sackgasse: eine leere Liste, die nicht verrät,
                // woher ihr Inhalt käme.
                Leerzustand(symbol: "bookmark",
                            kopfzeile: "Noch nichts gemerkt",
                            text: "Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort antippst, sammelt sich hier.")
            }
        }
    }

    @State private var kopfhoehe: CGFloat = 112

    private var kopf: some View {
        Unschaerfekopf(versatz: versatz) {
            VStack(alignment: .leading, spacing: 14) {
                Unterseitenkopf(titel: String(localized: "Merkliste"),
                                zurueck: { zurueck() }) { EmptyView() }
                    // Der Kopf bringt seinen eigenen Rand mit; hier steht er
                    // schon in einem.
                    .padding(.horizontal, -Stil.rand(breit: breit))

                HStack(spacing: 8) {
                    // **Ein anderes Zeichen als der Filter.** Ein Trichter
                    // engt ein, ein Raster wählt aus — und die beiden Pillen
                    // stehen auf zwei Seiten an derselben Stelle.
                    Wertpille(symbol: "square.grid.2x2",
                              text: gattung.beschriftung) { gattungslisteOffen = true }
                    Wertpille(symbol: "arrow.up.arrow.down",
                              text: stand.sortierung.beschriftung) { sortierlisteOffen = true }
                    Spacer(minLength: 8)
                    if stand.gesamt > 0 { Zaehlmarke(anzahl: stand.gesamt) }
                }
            }
        }
    }

    @Environment(\.dismiss) private var schliessen
    private func zurueck() { schliessen() }
}
