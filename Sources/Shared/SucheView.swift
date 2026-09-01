import JellyfinKit
import SwiftUI

/// Volltextsuche über Filme, Serien und Folgen.
struct SucheView: View {
    let model: AppModel
    /// Der Bereich ist gerade offen. Der Tab bleibt nach dem ersten Besuch
    /// bestehen, deshalb reicht `onAppear` nicht — das Feld bekaeme nur beim
    /// allerersten Mal den Fokus.
    var aktiv: Bool = true
    /// Wisch nach rechts, wenn die Tastatur schon zu ist: zurück dorthin, wo
    /// man vorher war.
    var zurueck: (() -> Void)? = nil


    @State private var begriff = ""
    @State private var treffer: [Item] = []
    @State private var sucht = false
    @State private var aufgabe: Task<Void, Never>?
    @FocusState private var imFeld: Bool

    @Environment(\.breit) private var breit

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            GeometryReader { rahmen in
            VStack(spacing: 0) {
                // Das Profilzeichen gehört auch hierher. Es stand im Kopf von
                // Start, Filme und Serien — in der Suche fehlte es, und drei
                // von vier ist keine Regel, sondern ein vergessener Fall.
                //
                // Breit steht es in der Seitenleiste, und zwar für alle vier
                // Bereiche. Hier wäre es das zweite.
                HStack(spacing: 12) {
                    Suchfeld(text: $begriff, amTippen: $imFeld)
                        // Breit ein Maß, aber linksbündig: mittig wäre es
                        // gegen das Raster darunter versetzt, über die volle
                        // Breite ein 1036 Punkt langer Kasten für ein Wort.
                        .frame(maxWidth: breit ? Stil.lesebreite : .infinity,
                               alignment: .leading)
                    if !breit {
                        NavigationLink(value: ProfilRoute()) {
                            Profilzeichen(name: model.session?.userName ?? "?",
                                          bild: model.benutzerbildURL())
                        }
                        .buttonStyle(.plain)
                    }
                    if breit { Spacer(minLength: 0) }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 8)
                .padding(.bottom, 16)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if begriff.isEmpty {
                            leerhinweis
                        } else if sucht {
                            Lader().frame(maxWidth: .infinity).padding(.top, 40)
                        } else if treffer.isEmpty {
                            Text("Keine Treffer für \u{201E}\(begriff)\u{201C}")
                                .font(Stil.koerper)
                                .foregroundStyle(Stil.schriftLeise)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            // Nach Art gruppiert, wie bei Plex: in der Liste
                            // liest man Titel und Art auf einen Blick.
                            let nutzbar = rahmen.size.width - 2 * Stil.rand(breit: breit)
                            gruppe("Serien", treffer.filter { $0.type == "Series" },
                                   nutzbar: nutzbar)
                            gruppe("Filme", treffer.filter { $0.type == "Movie" },
                                   nutzbar: nutzbar)
                            gruppe("Folgen", treffer.filter { $0.type == "Episode" },
                                   nutzbar: nutzbar)
                            gruppe("Weiteres", treffer.filter {
                                !["Series", "Movie", "Episode"].contains($0.type ?? "")
                            }, nutzbar: nutzbar)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.bottom, breit ? 24 : Stil.leisteHoehe + 12,
                                for: .scrollContent)
                // Tippen ins Leere schliesst die Tastatur — sonst kommt man
                // aus dem Feld gar nicht mehr heraus.
                .simultaneousGesture(TapGesture().onEnded { imFeld = false })
            }
            }
        }
        // Erst die Tastatur, dann der Weg zurück — wie überall in iOS.
        //
        // Nebenläufig, nicht ausschließlich: mit `.gesture` gewinnt die Liste
        // darunter, und der Wisch kam nie an. So darf die Geste mitlaufen,
        // ohne dem Scrollen etwas wegzunehmen — sie wertet ohnehin nur aus,
        // was am Ende herauskam.
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onEnded { geste in
                    guard geste.translation.width > 55,
                          abs(geste.translation.height) < 55 else { return }
                    if imFeld { imFeld = false } else { zurueck?() }
                }
        )
        .onChange(of: aktiv) { _, offen in imFeld = offen }
        .onAppear { if aktiv { imFeld = true } }
        .onChange(of: begriff) { _, neu in suchen(neu) }
    }

    @ViewBuilder
    private func gruppe(_ titel: String, _ eintraege: [Item],
                        nutzbar: CGFloat) -> some View {
        if !eintraege.isEmpty {
            Text(titel)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Stil.schriftLeise)
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 14)
                .padding(.bottom, breit ? 10 : 6)

            // Schmal eine Zeilenliste, breit ein Gitter — so macht es der
            // Fernseher. Eine Zeile mit 52er Vorschaubild und danach 900 Punkt
            // Nichts ist keine Liste mehr.
            //
            // **A7 gilt in beiden Formen**: kein Treffer startet, jeder führt
            // auf seine Seite. Vorher startete hier, was sich abspielen ließ —
            // das stand so im Kommentar und war trotzdem die Ausnahme von der
            // Regel, die überall sonst gilt.
            if breit {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Stil.kachelAbstand),
                                         count: Stil.spalten(nutzbar: nutzbar, breit: breit)),
                          alignment: .leading, spacing: 20) {
                    ForEach(eintraege) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, breite: nil,
                                       auskunft: item.trefferauskunft)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.bottom, 10)
            } else {
                ForEach(eintraege) { item in
                    Trefferzeile(model: model, item: item)
                }
            }
        }
    }

    private var leerhinweis: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Stil.schriftSehrLeise)
            Text("Filme, Serien und Folgen durchsuchen")
                .font(Stil.koerper)
                .foregroundStyle(Stil.schriftLeise)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }


    /// Mit Verzögerung, damit nicht jeder Tastendruck eine Anfrage auslöst.
    private func suchen(_ begriff: String) {
        aufgabe?.cancel()
        let sauber = begriff.trimmingCharacters(in: .whitespaces)
        guard sauber.count >= 2 else {
            treffer = []
            sucht = false
            return
        }
        sucht = true
        aufgabe = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let ergebnis = await model.suche(sauber)
            guard !Task.isCancelled else { return }
            treffer = ergebnis
            sucht = false
        }
    }
}

private struct Trefferzeile: View {
    let model: AppModel
    let item: Item

    /// **Jeder Treffer führt auf die Seite, keiner startet.**
    ///
    /// Vorher startete alles, was kein Behälter ist, sofort — mit einem
    /// Abspielpfeil daneben. Das war ausdrücklich so gebaut („aus der
    /// Trefferliste direkt in die Wiedergabe, ohne Zwischenseite") und
    /// widersprach doch der Regel, die überall sonst gilt: nur
    /// „Weiterschauen" springt direkt in die Wiedergabe. Wer sucht, will
    /// erst sehen, was er gefunden hat.
    var body: some View {
        NavigationLink(value: item) { inhalt }
            .buttonStyle(.plain)
    }

    private var inhalt: some View {
        HStack(spacing: 12) {
            // Hochkant und klein, wie im Entwurf — quer nahm zu viel Breite
            // und liess für den Titel kaum Platz.
            Bild(url: model.imageURL(for: item, maxHeight: 260, hochkant: true),
                 breite: 52, hoehe: 78, ecke: Stil.ecke)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(Stil.listentitel)
                    .foregroundStyle(Stil.schrift)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Text(item.trefferauskunft)
                    .font(.system(size: 13))
                    .foregroundStyle(Stil.schriftLeise)
            }

            Spacer(minLength: 0)

            // Ein Pfeil für alle: es führt jeder Treffer weiter.
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Stil.schriftSehrLeise)
        }
        .padding(.horizontal, Stil.randAbstand)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

}
