import JellyfinKit
import SwiftUI

/// Suche: Feld oben, Treffer als Gitter darunter.
///
/// Bewusst nicht `.searchable` — das bringt auf tvOS Apples eigene Leiste mit
/// Tastatur und Platzierung mit, und die passt weder zur Kopfleiste noch zum
/// flachen Grund.
struct SucheView: View {
    let model: AppModel
    /// Ob der Bereich gerade offen ist. Wechselt das auf wahr, geht die
    /// Tastatur von selbst auf.
    var aktiv: Bool = false

    @State private var begriff = ""
    @State private var treffer: [Item] = []
    @State private var laeuft = false
    @State private var gesucht = false
    @FocusState private var amFeld: Bool

    private var spalten: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Stil.gitterSpalte),
              count: Stil.gitterSpalten)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Eingabefeld(platzhalter: "Titel, Serie, Person", text: $begriff,
                            aussen: $amFeld) {
                    Task { await suchen() }
                }
                .frame(width: 900)
                .padding(.horizontal, Stil.randSeite)

                if laeuft {
                    Lader.fern.frame(maxWidth: .infinity).padding(.top, 80)
                } else if treffer.isEmpty && gesucht {
                    Leerzustand(symbol: "magnifyingglass",
                                titel: "Nichts gefunden",
                                hinweis: "Versuch es mit einem anderen Wort.")
                        .frame(height: 460)
                } else if !treffer.isEmpty {
                    LazyVGrid(columns: spalten, alignment: .leading,
                              spacing: Stil.gitterZeile) {
                        ForEach(treffer) { item in
                            NavigationLink(value: item) {
                                Kachelinhalt(bild: model.imageURL(for: item,
                                                                  maxHeight: 600,
                                                                  hochkant: true),
                                             titel: item.name,
                                             unterzeile: item.folgenkuerzel,
                                             mitUnterzeile: false)
                            }
                            .buttonStyle(KachelStil())
                        }
                    }
                    .padding(.horizontal, Stil.randSeite)
                    .scrollClipDisabled()
                }
            }
            .padding(.bottom, 60)
        }
        .scrollIndicators(.hidden)
        // Wer auf „Suche" geht, will tippen — nicht erst ein Feld ansteuern.
        // Deshalb liegt der Fokus sofort dort, und tvOS öffnet damit von
        // selbst die Tastatur.
        .onAppear { if aktiv { amFeld = true } }
        .onChange(of: aktiv) { _, offen in if offen { amFeld = true } }
        // **Sicherer Bereich, nicht Innenabstand und nicht `contentMargins`.**
        //
        // Beides war zu wenig. Innenabstand gehört zum Inhalt, den scrollt
        // tvOS weg. `contentMargins` setzt nur die Ruhelage. Entscheidend
        // ist aber, bis wohin tvOS beim **Fokuswechsel** schiebt — und dafür
        // zählt allein der sichere Bereich der Scrollfläche. Ohne ihn schob
        // sie so weit, dass die Kachel gerade sichtbar war, und der
        // Reihentitel darüber verschwand unter der Wortmarke.
        //
        // 150 ist das **Mindestmaß**, nicht ein Geschmackswert: der sichere
        // Systemrand (60) plus 150 macht 210, davon gehen Reihentitel (46)
        // und sein Abstand zur Kachel (36) ab — bleiben genau die 128 der
        // Leistenunterkante. Weniger, und der Titel rutscht beim Anspringen
        // einer Reihe wieder darunter.
        .safeAreaInset(edge: .top) { Color.clear.frame(height: 150) }
        // Auf tvOS kommt der Text erst, wenn die Systemtastatur schließt —
        // eine Verzögerung wie auf dem iPhone wäre hier sinnlos.
        .onChange(of: begriff) { _, neu in
            guard !neu.isEmpty else {
                treffer = []
                gesucht = false
                return
            }
            Task { await suchen() }
        }
        // Seitlicher Rand: siehe `HomeView` — der Systemrand faellt weg,
        // damit `randSeite` nicht darauf sitzt und sich verdoppelt.
        .ignoresSafeArea(edges: .horizontal)
    }

    private func suchen() async {
        let wort = begriff.trimmingCharacters(in: .whitespaces)
        guard !wort.isEmpty else { return }
        laeuft = treffer.isEmpty
        treffer = await model.suche(wort)
        gesucht = true
        laeuft = false
    }
}
