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
                // **Feld und Auskunft in einer Zeile**, wie die Chipreihe der
                // Bibliothek: links das Feld, rechts die Trefferzahl.
                HStack(alignment: .center, spacing: 40) {
                    Eingabefeld(platzhalter: "Titel, Serie, Person", text: $begriff,
                                aussen: $amFeld) {
                        Task { await suchen() }
                    }
                    .frame(width: 1000)

                    if !treffer.isEmpty {
                        Text("\(treffer.count) Treffer")
                            .font(Stil.klein)
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Stil.randSeite)

                if laeuft {
                    Lader.fern.frame(maxWidth: .infinity).padding(.top, 80)
                } else if treffer.isEmpty && gesucht {
                    Leerzustand(symbol: "magnifyingglass",
                                titel: "Nichts gefunden",
                                hinweis: "Versuch es mit einem anderen Wort.")
                        .frame(height: 460)
                } else if !gesucht {
                    // **Ein Satz statt schwarzer Stille.**
                    //
                    // Vor der ersten Eingabe stand hier gar nichts — ein
                    // schwarzer Schirm mit einem leuchtenden Feld. Ein
                    // Vorschlagsregal waere Platzfuellerei; ein Satz sagt,
                    // was das Feld annimmt und ab wann es sucht.
                    Text("Titel, Serie oder Name. Ab zwei Zeichen wird gesucht.")
                        .font(Stil.koerper)
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .padding(.horizontal, Stil.randSeite)
                        .padding(.top, 10)
                } else if !treffer.isEmpty {
                    LazyVGrid(columns: spalten, alignment: .leading,
                              spacing: Stil.gitterZeile) {
                        ForEach(treffer) { item in
                            NavigationLink(value: item) {
                                Kachelinhalt(bild: model.imageURL(for: item,
                                                                  maxHeight: 600,
                                                                  hochkant: true),
                                             titel: item.name,
                                             unterzeile: gattungUndJahr(item))
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
        // 130 statt 150: das Feld beginnt damit bei 190 — dieselbe Zeile wie
        // die Chipreihe der Bibliothek und der erste Reihentitel der
        // Startseite.
        //
        // Das Mindestmass von 150 oben gilt fuer Reihen **mit** Titel: es
        // haelt Reihentitel (46) und Abstand (36) frei. Das Suchgitter hat
        // keinen Titel ueber sich, sondern das Feld — und das soll beim
        // Anspringen einer Kachel sichtbar bleiben, nicht mehr.
        .safeAreaInset(edge: .top) { Color.clear.frame(height: 130) }
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

    /// „Serie · 2008" — damit ein Film und eine Serie gleichen Namens
    /// unterscheidbar sind.
    ///
    /// Bisher stand hier das Folgenkuerzel, und es war ausserdem
    /// abgeschaltet (`mitUnterzeile: false`): unter den Kacheln stand nur
    /// der Titel, und bei mehreren Treffern derselben Serie sah man
    /// dasselbe Plakat mehrfach ohne Unterschied.
    private func gattungUndJahr(_ item: Item) -> String? {
        var teile: [String] = []
        switch item.type {
        case "Movie":  teile.append(String(localized: "Film"))
        case "Series": teile.append(String(localized: "Serie"))
        default: break
        }
        if let jahr = item.productionYear { teile.append(String(jahr)) }
        return teile.isEmpty ? nil : teile.joined(separator: " · ")
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
