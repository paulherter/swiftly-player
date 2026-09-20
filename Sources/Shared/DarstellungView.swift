import JellyfinKit
import SwiftUI

/// **Profil → Darstellung.** Wie etwas aussieht und was auf der Startseite
/// steht — auf einer Seite, neben „Wiedergabe".
///
/// Stand zuerst unter Einstellungen, die Startseite dort noch einmal als
/// Unterseite: zwei Ebenen tief für einen Schalter. Jetzt steht alles hier.
///
/// **Apples Liste zum Umsortieren, keine eigene.** Der erste Versuch zog
/// Zeilen nach langem Drücken selbst — das griff mal, mal nicht. Die Liste
/// im Bearbeitungsmodus bringt die Griffe mit, die man aus den System-Apps
/// kennt, und sie funktionieren jedes Mal. Gefärbt wie unsere Karten.
struct DarstellungView: View {
    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var genrewahl = false

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            VStack(spacing: 0) {
                Unterseitenkopf(titel: String(localized: "Darstellung")) { zurueck() }
                // **Breit zwei Spalten**, wie Einstellungen und Wiedergabe:
                // links, was die Seite überhaupt zeigt, rechts die Genres.
                // Eine schmale Liste in einem breiten Fenster war die
                // einzige Seite, die das nicht tat.
                if breit {
                    HStack(alignment: .top, spacing: 0) {
                        liste { allgemein; reihen }
                        liste { genres }
                    }
                } else {
                    liste { allgemein; reihen; genres }
                }
            }
        }
        .tint(Stil.akzent)
        .navigationDestination(isPresented: $genrewahl) { GenrewahlView(model: model) }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
    }

    /// Apples Liste, gefasst wie unsere Karten: derselbe Rand wie jede
    /// andere Seite, die Rubriken in unserem Grad.
    private func liste<Inhalt: View>(@ViewBuilder _ inhalt: () -> Inhalt) -> some View {
        List { inhalt() }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, Stil.rand(breit: breit), for: .scrollContent)
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
    }

    // MARK: Allgemein

    @ViewBuilder
    private var allgemein: some View {
        Section {
            // Auf dem iPad fehlt diese Zeile, und das ist Absicht: dort darf
            // die App die Drehung nicht erzwingen. Siehe `Orientierung`.
            if Orientierung.querformatSperreMoeglich {
                Wahlzeile(symbol: "rectangle.on.rectangle",
                          titel: Text("Querformat im Player sperren"),
                          an: Binding(get: { model.querformatFest },
                                      set: { model.querformatFest = $0 }))
                    .zeile()
            }
            Wahlzeile(symbol: "chart.bar.fill", titel: Text("Fortschritt auf Kacheln"),
                      an: Binding(get: { model.fortschrittAufKacheln },
                                  set: { model.fortschrittAufKacheln = $0 }))
                .zeile()
        } header: {
            Rubrik(text: "Allgemein")
        }
    }

    // MARK: Reihen

    private var sichtbareReihen: [Startreihe] {
        model.startReihen.filter { $0.passt(getrennt: model.neuzugangGetrennt) }
    }

    private var reihen: some View {
        Section {
            ForEach(sichtbareReihen) { reihe in
                Wahlzeile(symbol: reihe.symbol, titel: Text(reihe.name),
                          an: Binding(get: { !model.startAus.contains(reihe) },
                                      set: { an in
                                          if an { model.startAus.remove(reihe) }
                                          else { model.startAus.insert(reihe) }
                                      }))
                    .zeile()
            }
            .onMove { von, nach in verschieben(von: von, nach: nach) }
            .deleteDisabled(true)

            Wahlzeile(symbol: "square.split.2x1",
                      titel: Text("Neuzugänge getrennt"),
                      unter: Text("Neue Filme und neue Serien als eigene Reihen"),
                      an: Binding(get: { model.neuzugangGetrennt },
                                  set: { model.neuzugangGetrennt = $0 }))
                .zeile()
        } header: {
            Rubrik(text: "Startseite")
        } footer: {
            Fusszeile(text: "Zum Umsortieren an den Griffen rechts ziehen.")
        }
    }

    /// Verschoben wird in der sichtbaren Liste. Was gerade nicht zu sehen ist
    /// — die gemeinsame Reihe, wenn getrennt ist, oder umgekehrt —, hängt
    /// hinten an und kommt beim Umschalten dort wieder zum Vorschein.
    private func verschieben(von: IndexSet, nach: Int) {
        var sichtbar = sichtbareReihen
        sichtbar.move(fromOffsets: von, toOffset: nach)
        model.startReihen = sichtbar + model.startReihen.filter { !sichtbar.contains($0) }
    }

    // MARK: Genres

    /// **Eine Liste, zwei Formen.** Welche Genres, stellt man einmal ein; ob
    /// sie als Reihen unten oder als Chips oben stehen, ist nur noch die
    /// Form. Vorher schaltete „als Chips" die Liste weg und zeigte stattdessen
    /// alle Genres des Servers — zwei verschiedene Mengen hinter einem
    /// Schalter, und niemand verstand, warum.
    private var genres: some View {
        Section {
            form("Als eigene Reihen", symbol: "rectangle.grid.1x2", an: !model.genreChips) { model.genreChips = false }
            form("Als Chips über den Reihen", symbol: "capsule", an: model.genreChips) { model.genreChips = true }

            ForEach(model.startGenres, id: \.self) { name in
                // Vom Server, also nicht übersetzt.
                Text(verbatim: name)
                    .font(.system(size: 15))
                    .foregroundStyle(Stil.schrift)
                    .listRowBackground(Stil.flaeche)
            }
            .onMove { model.startGenres.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { model.startGenres.remove(atOffsets: $0) }

            // Ein Knopf, kein Link: im Bearbeitungsmodus führt ein Link in
            // einer Liste nirgends hin.
            Button { genrewahl = true } label: {
                Label("Genre hinzufügen", systemImage: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Stil.akzent)
            }
            .listRowBackground(Stil.flaeche)
            .deleteDisabled(true)
        } header: {
            Rubrik(text: "Genres")
        }
    }

    /// Wie die Zeilen darüber: Symbol, Titel, Haken — nicht kleiner.
    private func form(_ titel: LocalizedStringKey, symbol: String, an: Bool, waehlen: @escaping () -> Void) -> some View {
        Button(action: waehlen) {
            Zeilenaufbau(symbol: symbol, titel: Text(titel), unter: nil, gedimmt: false) {
                if an {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Stil.akzent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zeile()
        .deleteDisabled(true)
        .accessibilityAddTraits(an ? .isSelected : [])
    }
}

/// Die Rubrik über einer Gruppe — derselbe Grad wie `Gruppentitel` auf den
/// anderen Einstellungsseiten, ohne dessen eigenen Rand: den setzt die Liste.
private struct Rubrik: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Stil.schriftSehrLeise)
    }
}

private struct Fusszeile: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Stil.schriftSehrLeise)
    }
}

private extension View {
    /// Eine Zeile aus unseren Bausteinen in Apples Liste: deren Innenrand
    /// weg, weil die Zeile ihren eigenen mitbringt, und unser Grund.
    func zeile() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Stil.flaeche)
    }
}

/// **Ein Genre für die Startseite wählen** — aus denen, die der Server kennt.
/// Ein Tipp nimmt es auf und geht zurück; was schon gewählt ist, steht hier
/// nicht mehr.
struct GenrewahlView: View {
    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var alle: [String] = []
    @State private var geladen = false

    private var frei: [String] { alle.filter { !model.startGenres.contains($0) } }

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            VStack(spacing: 0) {
                Unterseitenkopf(titel: String(localized: "Genre hinzufügen")) { zurueck() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if geladen, frei.isEmpty {
                            Text(alle.isEmpty ? "Auf deinem Server sind keine Genres hinterlegt."
                                              : "Alle Genres stehen schon auf der Startseite.")
                                .font(Stil.koerper)
                                .foregroundStyle(Stil.schriftLeise)
                                .padding(.horizontal, Stil.rand(breit: breit))
                                .padding(.top, 8)
                        } else if !frei.isEmpty {
                            Einstellungsgruppe(titel: "Auf deinem Server") {
                                ForEach(Array(frei.enumerated()), id: \.element) { stelle, name in
                                    if stelle > 0 {
                                        Trennlinie().padding(.leading, Stil.trennEinzugKarte(breit: breit))
                                    }
                                    Button {
                                        model.startGenres.append(name)
                                        zurueck()
                                    } label: {
                                        Wertzeile(symbol: "tag", titel: Text(verbatim: name))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: breit ? Stil.lesebreite : .infinity, alignment: .leading)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task {
            alle = await model.gattungen()
            geladen = true
        }
    }
}
