import JellyfinKit
import SwiftUI

/// Eine Bibliothek als Gitter — sieben Spalten auf 1920 Punkt.
///
/// Sortierung steht hier als zweite Chipreihe, nicht wie auf dem iPhone in
/// einem Aufklappblatt. Ein Blatt kostet auf der Fernbedienung zwei Wege
/// (öffnen, wählen, schließen); nebeneinander gelegte Chips kosten einen —
/// und Platz ist auf dem Fernseher das, was das iPhone nicht hat.
struct BibliothekView: View {
    let model: AppModel
    /// Entweder über die Gattung („movies", „tvshows") aus der Kopfleiste …
    var art: String?
    /// … oder als benannte Bibliothek über den Sprungpfad.
    var bibliothek: Item?
    var filter: [Bibliotheksfilter] = Bibliotheksfilter.allCases

    /// Blättern, Filtern und Sortieren stehen in `Bibliotheksmodell` —
    /// geteilt mit der iPhone-Fassung.
    @State private var stand = Bibliotheksmodell()

    private var spalten: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Stil.gitterSpalte),
              count: Stil.gitterSpalten)
    }

    var body: some View {
        ZStack {
            if stand.laedt {
                Lader.fern
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        chipreihen

                        if stand.items.isEmpty {
                            leer
                        } else {
                            gitter
                        }
                    }
                    // Platz für die Kopfleiste darüber, wenn es eine gibt.
                    .padding(.top, bibliothek == nil ? 0 : Stil.randOben)
                    .padding(.bottom, 60)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .top) {
                    Color.clear.frame(height: bibliothek == nil ? 150 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Seitlicher Rand: siehe `HomeView` — der Systemrand faellt weg,
        // damit `randSeite` nicht darauf sitzt und sich verdoppelt.
        .ignoresSafeArea(edges: .horizontal)
        .task(id: stand.kennung) { await laden() }
    }

    // MARK: Teile

    private var chipreihen: some View {
        HStack(alignment: .center, spacing: 40) {
            HStack(spacing: 16) {
                ForEach(filter) { f in
                    Button(f.beschriftung) { stand.filter = f }
                        .buttonStyle(ChipStil(an: stand.filter == f))
                }
            }
            .focusSection()

            Spacer(minLength: 40)

            HStack(spacing: 16) {
                ForEach(Sortierung.allCases) { s in
                    Button(s.beschriftung) { stand.sortierung = s }
                        .buttonStyle(ChipStil(an: stand.sortierung == s))
                }
            }
            .focusSection()
        }
        .padding(.horizontal, Stil.randSeite)
    }

    private var gitter: some View {
        LazyVGrid(columns: spalten, alignment: .leading, spacing: Stil.gitterZeile) {
            ForEach(stand.items) { item in
                NavigationLink(value: item) {
                    Kachelinhalt(bild: model.imageURL(for: item, maxHeight: 600,
                                                      hochkant: true),
                                 titel: item.name,
                                 mitUnterzeile: false)
                }
                .buttonStyle(KachelStil())
                // Nachladen, sobald die drittletzte Reihe auftaucht — dann
                // steht der Nachschub, bevor der Fokus unten ankommt.
                .onAppear {
                    guard item.id == stand.nachladenAb(spalten: Stil.gitterSpalten)
                    else { return }
                    Task { await stand.nachladen(model, art: art, bibliothek: bibliothek) }
                }
            }
        }
        .padding(.horizontal, Stil.randSeite)
        // Der Fokusring der äußeren Spalten liegt sonst unter dem Rand.
        .scrollClipDisabled()
    }

    private var leer: some View {
        Leerzustand(
            symbol: stand.filter == .alle ? "tray" : "line.3.horizontal.decrease",
            titel: stand.filter == .alle ? "Hier ist noch nichts" : "Nichts gefunden",
            hinweis: stand.filter == .alle
                ? "Sobald in dieser Bibliothek etwas liegt, taucht es hier auf."
                : "Unter diesem Filter liegt gerade nichts.",
            knopf: stand.filter == .alle
                ? ("Aktualisieren", { Task { await laden() } })
                : ("Filter zurücksetzen", { stand.filter = .alle }))
        .frame(height: 500)
    }

    // MARK: Laden

    private func laden() async {
        await stand.laden(model, art: art, bibliothek: bibliothek)
    }
}
