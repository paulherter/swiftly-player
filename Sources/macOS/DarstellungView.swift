import JellyfinKit
import SwiftUI

/// **Profil → Darstellung.** Wie etwas aussieht und was auf der Startseite
/// steht — auf einer Seite, neben „Wiedergabe", wie auf iPhone und iPad.
///
/// Sie stand kurz unter den Einstellungen, weil Befehl-Komma dort alles
/// verspricht. Das hiess aber: dieselbe Seite an einer anderen Stelle als auf
/// jedem anderen Geraet, und die Kategorien im Profil verschwunden. Die
/// Einstellungen behalten, was das Geraet betrifft.
///
/// **Gezogen wird mit dem Griff rechts.** Der erste Versuch setzte Apples
/// `List` in die Karte: sie brachte ihre eigene obere Kante mit, sodass die
/// Karte oben eckig und unten rund war, ihre Zeilen füllten die Breite nicht,
/// und ziehen ließ sich gar nichts — ohne Bearbeitungsmodus rührt sich eine
/// `List` auf dem Mac nicht. Jetzt sind es gewöhnliche Zeilen in unserer
/// Karte: ein Klick schaltet um, der Griff rechts zieht, und die Linie zeigt,
/// wo die Zeile landet.
///
/// Zwei Spalten wie in den Einstellungen: links, was die Seite überhaupt
/// zeigt, rechts die Genres.
struct DarstellungView: View {
    let model: AppModel
    let zurueck: () -> Void

    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    /// Worüber die gezogene Zeile gerade schwebt — dort kommt die Linie hin.
    @State private var ueber: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: "Darstellung", zurueck: zurueck)

                HStack(alignment: .top, spacing: Stil.randAbstand * 2) {
                    VStack(alignment: .leading, spacing: 0) { allgemein; reihen }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) { genres }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: Stil.einstellungBreite, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .ohneKanteneffekt()
    }

    // MARK: Allgemein

    /// „Querformat im Player sperren" gibt es hier **nicht**: ein Fenster hat
    /// keine Ausrichtung, die man sperren koennte. Das ist kein Weglassen,
    /// sondern eine Einstellung ohne Gegenstueck (VERHALTEN.md F).
    private var allgemein: some View {
        Einstellungsgruppe(titel: "Allgemein") {
            Schalterzeile(symbol: "chart.bar.fill",
                          titel: Text("Fortschritt auf Kacheln"),
                          an: Binding(get: { model.fortschrittAufKacheln },
                                      set: { model.fortschrittAufKacheln = $0 }))
        }
    }

    // MARK: Reihen

    private var sichtbareReihen: [Startreihe] {
        model.startReihen.filter { $0.passt(getrennt: model.neuzugangGetrennt) }
    }

    private var reihen: some View {
        VStack(alignment: .leading, spacing: 0) {
            Einstellungsgruppe(titel: "Reihen") {
                ForEach(Array(sichtbareReihen.enumerated()), id: \.element) { stelle, reihe in
                    if stelle > 0 { Trennstrich().padding(.leading, 48) }
                    Wahlzeile(symbol: reihe.symbol, titel: Text(reihe.name),
                              an: Binding(get: { !model.startAus.contains(reihe) },
                                          set: { an in
                                              if an { model.startAus.remove(reihe) }
                                              else { model.startAus.insert(reihe) }
                                          }))
                        .ziehbar(reihe.rawValue, ueber: $ueber) { quelle in
                            reiheAblegen(quelle, auf: reihe)
                        }
                }
            }
            Fusszeile(text: "Zum Umsortieren eine Zeile ziehen.")

            Einstellungsgruppe(titel: "Neuzugänge") {
                Schalterzeile(symbol: "square.split.2x1",
                              titel: Text("Neuzugänge getrennt"),
                              unter: Text("Neue Filme und neue Serien als eigene Reihen"),
                              an: Binding(get: { model.neuzugangGetrennt },
                                          set: { model.neuzugangGetrennt = $0 }))
            }
        }
    }

    /// Die gezogene Reihe rückt an die Stelle der, auf der sie landet.
    private func reiheAblegen(_ quelle: String, auf ziel: Startreihe) {
        guard let bewegt = Startreihe(rawValue: quelle), bewegt != ziel else { return }
        var sichtbar = sichtbareReihen
        guard let von = sichtbar.firstIndex(of: bewegt),
              let nach = sichtbar.firstIndex(of: ziel) else { return }
        withAnimation(Stil.einblenden) {
            sichtbar.remove(at: von)
            sichtbar.insert(bewegt, at: nach)
            model.startReihen = sichtbar + model.startReihen.filter { !sichtbar.contains($0) }
        }
    }


    // MARK: Genres

    /// **Eine Liste, zwei Formen.** Welche Genres, stellt man einmal ein; ob
    /// sie als Reihen unten oder als Chips oben stehen, ist nur noch die
    /// Form. Vorher schaltete „als Chips" die Liste weg und zeigte stattdessen
    /// alle Genres des Servers — zwei verschiedene Mengen hinter einem
    /// Schalter, und niemand verstand, warum.
    private var genres: some View {
        VStack(alignment: .leading, spacing: 0) {
            Einstellungsgruppe(titel: "Genres") {
                form("Als eigene Reihen", symbol: "rectangle.grid.1x2", an: !model.genreChips) { model.genreChips = false }
                Trennstrich().padding(.leading, 48)
                form("Als Chips über den Reihen", symbol: "capsule", an: model.genreChips) { model.genreChips = true }

                ForEach(model.startGenres, id: \.self) { name in
                    Trennstrich().padding(.leading, 48)
                    Genrezeile(name: name) {
                        withAnimation(Stil.einblenden) {
                            model.startGenres.removeAll { $0 == name }
                        }
                    }
                    .ziehbar("genre:" + name, ueber: $ueber) { quelle in
                        genreAblegen(quelle, auf: name)
                    }
                }

                Trennstrich()
                Button { navigator.oeffne(.genrewahl, in: bereich) } label: {
                    Wertezeile(symbol: "plus", titel: Text("Genre hinzufügen"),
                               akzent: true, pfeil: true, schwebbar: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func genreAblegen(_ quelle: String, auf ziel: String) {
        let bewegt = String(quelle.dropFirst("genre:".count))
        guard bewegt != ziel,
              let von = model.startGenres.firstIndex(of: bewegt),
              let nach = model.startGenres.firstIndex(of: ziel) else { return }
        withAnimation(Stil.einblenden) {
            model.startGenres.remove(at: von)
            model.startGenres.insert(bewegt, at: nach)
        }
    }

    /// Wie die Zeilen darüber: Symbol, Titel, Haken — nicht kleiner.
    private func form(_ titel: LocalizedStringKey, symbol: String, an: Bool,
                      waehlen: @escaping () -> Void) -> some View {
        Wertezeile(symbol: symbol, titel: Text(titel), aktion: waehlen, haken: an)
            .accessibilityAddTraits(an ? .isSelected : [])
    }

}

/// Ein gewähltes Genre: der Name, rechts das Kreuz zum Entfernen.
///
/// **Kein Wischen zum Löschen.** Das ist eine Geste des Fingers; am Zeiger
/// steht dafür ein Knopf, wie überall sonst im Fenster.
private struct Genrezeile: View {
    let name: String
    let entfernen: () -> Void

    @State private var schwebt = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "tag")
                .font(.system(size: 15))
                .foregroundStyle(Stil.schriftLeise)
                .frame(width: 22)
            // Vom Server, also nicht übersetzt.
            Text(verbatim: name)
                .font(.system(size: 15))
                .foregroundStyle(Stil.schrift)
            Spacer(minLength: 12)
            Button(action: entfernen) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Stil.schriftLeise)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(schwebt ? 1 : 0.35)
            .accessibilityLabel(Text("Entfernen"))
            Griff()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(schwebt ? Stil.schrift.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}

/// Eine Zeile mit Schalter und Griff — **bewusst kein Knopf.**
///
/// Ein `Button` und eine Ziehgeste streiten auf dem Mac um denselben Klick:
/// mit `Schalterzeile` ließ sich die Zeile nicht bewegen. Ein Tipp-Erkenner
/// streitet nicht, und die Zeile schaltet genauso um.
private struct Wahlzeile: View {
    let symbol: String
    let titel: Text
    @Binding var an: Bool

    @State private var schwebt = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Stil.schriftLeise)
                .frame(width: 22)
            titel
                .font(.system(size: 15))
                .foregroundStyle(Stil.schrift)
            Spacer(minLength: 12)
            Schalter(an: an)
            Griff()
        }
        .padding(.horizontal, 12)
        // **Die ganze Zeile, nicht nur ihr Inhalt.** In Apples Liste blieb
        // die Schwebefläche so breit wie der Text und füllte die Karte nicht.
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(schwebt ? Stil.schrift.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .onTapGesture { an.toggle() }
        .accessibilityRepresentation { Toggle(isOn: $an) { titel } }
    }
}

/// Die drei Striche, die sagen: das hier lässt sich schieben.
private struct Griff: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Stil.schriftSehrLeise)
            .frame(width: 22, height: 28)
            .accessibilityHidden(true)
    }
}

private extension View {
    /// **Ziehen und Ablegen an einer Zeile.**
    ///
    /// Gezogen wird die ganze Zeile, abgelegt wird auf einer anderen — die
    /// gezogene rückt an deren Stelle. Die Linie oben zeigt vorher, wohin.
    func ziehbar(_ kennung: String, ueber: Binding<String?>,
                 ablegen: @escaping (String) -> Void) -> some View {
        draggable(kennung)
            .overlay(alignment: .top) {
                if ueber.wrappedValue == kennung {
                    Rectangle().fill(Stil.akzent).frame(height: 2)
                }
            }
            .dropDestination(for: String.self) { werte, _ in
                ueber.wrappedValue = nil
                guard let quelle = werte.first else { return false }
                ablegen(quelle)
                return true
            } isTargeted: { an in
                if an { ueber.wrappedValue = kennung }
                else if ueber.wrappedValue == kennung { ueber.wrappedValue = nil }
            }
    }
}

/// Der kleine Satz unter einer Karte — Erklärung, kein Titel.
private struct Fusszeile: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Stil.schrift.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .padding(.horizontal, 2)
    }
}

/// **Ein Genre für die Startseite wählen** — aus denen, die der Server kennt.
/// Ein Klick nimmt es auf und geht zurück; was schon gewählt ist, steht hier
/// nicht mehr.
struct GenrewahlView: View {
    let model: AppModel
    let zurueck: () -> Void

    @State private var alle: [String] = []
    @State private var geladen = false

    private var frei: [String] { alle.filter { !model.startGenres.contains($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: "Genre hinzufügen", zurueck: zurueck)

                if geladen, frei.isEmpty {
                    Text(alle.isEmpty ? "Auf deinem Server sind keine Genres hinterlegt."
                                      : "Alle Genres stehen schon auf der Startseite.")
                        .font(Stil.koerper)
                        .foregroundStyle(Stil.schriftLeise)
                        .padding(.top, 22)
                } else if !frei.isEmpty {
                    Einstellungsgruppe(titel: "Auf deinem Server") {
                        ForEach(Array(frei.enumerated()), id: \.element) { stelle, name in
                            if stelle > 0 { Trennstrich().padding(.leading, 48) }
                            Button {
                                model.startGenres.append(name)
                                zurueck()
                            } label: {
                                Wertezeile(symbol: "tag", titel: Text(verbatim: name),
                                           schwebbar: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: Stil.lesebreite, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .ohneKanteneffekt()
        .task {
            alle = await model.gattungen()
            geladen = true
        }
    }
}
