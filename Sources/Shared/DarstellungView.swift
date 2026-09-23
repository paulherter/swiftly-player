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
            // Derselbe Grund wie jede andere Seite. Er war kurz ein eigener
            // (`gruppengrund`), weil reines Schwarz unter einer Karte die
            // ganze Strecke auf einmal war; seit der Grund #101010 ist,
            // betraegt der Sprung ein Fuenftel davon und braucht keine
            // Ausnahme mehr.
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
            Fusszeile("Zum Umsortieren an den Griffen rechts ziehen.")
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
                    // Fließtext aus der Leiter statt einer eigenen Zahl —
                    // derselbe Grad, nur ohne die Zahl im Aufrufer. Vorher
                    // `.system(size: 15)`.
                    // **Mitwachsend, nicht fest** — BRAND.md, Abschnitt 2. Grad und
                    // Gewicht sind die der Tokens, nur folgen sie der Systemschrift.
                    // Die Haken und Winkel bleiben fest: das sind Zeichen, kein Text.
                    .mitwachsend(15)
                    .foregroundStyle(Stil.schrift)
                    .listRowBackground(Stil.gruppenflaeche)
            }
            .onMove { model.startGenres.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { model.startGenres.remove(atOffsets: $0) }

            // Ein Knopf, kein Link: im Bearbeitungsmodus führt ein Link in
            // einer Liste nirgends hin.
            Button { genrewahl = true } label: {
                Label("Genre hinzufügen", systemImage: "plus")
                    // Listenzeile: 15 Semifett. 15 Medium stand in keiner
                    // Leiter — zwischen Fließtext und Listenzeile gibt es
                    // keine Stufe. Vorher `.system(size: 15, weight: .medium)`.
                    .mitwachsend(15, .semibold)
                    .foregroundStyle(Stil.akzent)
            }
            // **Auch diese Zeile antwortet auf den Druck.** Sie war der eine
            // Knopf auf der Seite ohne jede Rückmeldung.
            .buttonStyle(Stil.Druckzeile())
            .listRowBackground(Stil.gruppenflaeche)
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
                        .font(.system(size: 13, weight: .semibold))
                        // **Gewählt heißt Weiß und Gewicht, nicht Farbe.** Der
                        // Haken stand türkis; das ist Rangfolge unter
                        // Geschwistern, und der Akzent trägt allein Zustand.
                        // Halbfett ist der Titel der Zeile ohnehin schon.
                        .foregroundStyle(Stil.schrift)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .zeile(gewaehlt: an)
        .deleteDisabled(true)
        .accessibilityAddTraits(an ? .isSelected : [])
    }
}

/// Die Rubrik über einer Gruppe — dieselbe wie `Gruppentitel` auf den anderen
/// Einstellungsseiten, ohne dessen eigenen Rand: den setzt die Liste.
///
/// **Sie war bis zum 22.09. die alte Fassung**: 11 Punkt, Versalien, gesperrt.
/// Als `Gruppentitel` auf Normalschreibung im Grad der Reihenüberschrift
/// umgestellt wurde, ist diese Kopie stehen geblieben — und damit sah genau
/// eine der vier Einstellungsseiten anders aus als die drei anderen. Rückmeldung
/// vom 22.09.: „bei Darstellung ist noch die falsche drin."
///
/// Dass es überhaupt eine Kopie gibt, hat einen Grund: `Gruppentitel` bringt
/// seinen Seitenrand mit, und in einer Liste setzt den die Liste. Der Grad
/// gehört trotzdem an eine Stelle — deshalb liest sie ihn hier ab, statt ihn
/// noch einmal hinzuschreiben.
private struct Rubrik: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .mitwachsend(20, .semibold)
            .tracking(Stil.sperrungReihe)
            .foregroundStyle(Stil.schriftLeise)
    }
}

private extension View {
    /// Eine Zeile aus unseren Bausteinen in Apples Liste: deren Innenrand
    /// weg, weil die Zeile ihren eigenen mitbringt, und unser Grund.
    func zeile(gewaehlt: Bool = false) -> some View {
        listRowInsets(EdgeInsets())
            // **Gewählt heisst eine Stufe hoeher.** Solange der Haken türkis
            // war, war die Farbe die ganze Auskunft; in Weiß braucht die
            // gewählte Zeile ihren Grund dazu, sonst fällt sie nicht mehr auf.
            // `erhoeht` ist derselbe Ton, den auch der gewaehlte Filterchip
            // traegt — ein Zeichen fuer „gewaehlt", nicht zwei.
            .listRowBackground(gewaehlt ? Stil.erhoeht : Stil.gruppenflaeche)
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
    /// Ohne diese Flagge stand hier bei jedem Netzfehler „Auf deinem Server
    /// sind keine Genres hinterlegt." — eine Aussage ueber den Server, die
    /// die App gar nicht treffen konnte.
    @State private var gestoert = false

    private var frei: [String] { alle.filter { !model.startGenres.contains($0) } }

    var body: some View {
        ZStack(alignment: .top) {
            // Derselbe Grund wie jede andere Seite. Er war kurz ein eigener
            // (`gruppengrund`), weil reines Schwarz unter einer Karte die
            // ganze Strecke auf einmal war; seit der Grund #101010 ist,
            // betraegt der Sprung ein Fuenftel davon und braucht keine
            // Ausnahme mehr.
            Stil.grund.ignoresSafeArea()
            VStack(spacing: 0) {
                Unterseitenkopf(titel: String(localized: "Genre hinzufügen")) { zurueck() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if gestoert, alle.isEmpty {
                            Stoerhinweis(model: model) { Task { await gattungenLaden() } }
                        } else if geladen, frei.isEmpty {
                            Text(alle.isEmpty ? "Auf deinem Server sind keine Genres hinterlegt."
                                              : "Alle Genres stehen schon auf der Startseite.")
                                .mitwachsend(15)
                                .foregroundStyle(Stil.schriftLeise)
                                .padding(.horizontal, Stil.rand(breit: breit))
                                .padding(.top, 8)
                        } else if !frei.isEmpty {
                            Einstellungsgruppe(titel: "Auf deinem Server") {
                                ForEach(Array(frei.enumerated()), id: \.element) { stelle, name in
                                    if stelle > 0 {
                                        Blattlinie()
                                    }
                                    Button {
                                        model.startGenres.append(name)
                                        zurueck()
                                    } label: {
                                        Wertzeile(symbol: "tag", titel: Text(verbatim: name))
                                    }
                                    .buttonStyle(Stil.Druckknopf())
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
        .task { await gattungenLaden() }
    }

    private func gattungenLaden() async {
        let geholt = await model.gattungen()
        gestoert = geholt == nil
        if let geholt { alle = geholt }
        geladen = true
    }
}
