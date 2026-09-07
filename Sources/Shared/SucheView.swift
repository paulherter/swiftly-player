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
    /// Was Seerr kennt und der eigene Server nicht hat.
    ///
    /// **Eigener Zustand, eigene Aufgabe.** Die beiden Abrufe laufen
    /// nebeneinander; kommt von Seerr nichts oder kommt es spät, steht
    /// trotzdem sofort da, was der eigene Server hat.
    @State private var seerrtreffer: [Seerrtreffer] = []
    @FocusState private var imFeld: Bool

    @Environment(\.breit) private var breit
    @Environment(\.fensterknoepfe) private var fensterknoepfe

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            GeometryReader { rahmen in
            VStack(spacing: 0) {
                // **Kein Profilzeichen auf der Suchseite.**
                //
                // Hier stand eines, mit der Begründung: es steht im Kopf von
                // Start, Filme und Serien, drei von vier sei keine Regel
                // sondern ein vergessener Fall. Das klingt richtig und ist es
                // nicht
                //
                // Der Grund ist das Suchfeld. Es ist auf dieser Seite das
                // einzige Bedienelement und will von Rand zu Rand; ein Zeichen
                // daneben nimmt ihm die letzten vierzig Punkt und macht aus
                // einem Feld eine Zeile mit Anhängsel. Die anderen drei Seiten
                // tragen oben eine Überschrift, neben der noch Platz ist.
                //
                // Gleichförmigkeit gilt für das Verhalten, nicht für jedes
                // Element auf jeder Seite.
                HStack(spacing: 12) {
                    Suchfeld(text: $begriff, amTippen: $imFeld)
                        // Breit ein Maß, aber linksbündig: mittig wäre es
                        // gegen das Raster darunter versetzt, über die volle
                        // Breite ein 1036 Punkt langer Kasten für ein Wort.
                        .frame(maxWidth: breit ? Stil.lesebreite : .infinity,
                               alignment: .leading)
                    if breit { Spacer(minLength: 0) }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, (breit ? Stil.kopfOben : 8)
                            + (fensterknoepfe ? Fensterknoepfe.hoehe : 0))
                .padding(.bottom, 16)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if begriff.isEmpty {
                            leerhinweis
                        } else if sucht, treffer.isEmpty, seerrtreffer.isEmpty {
                            // **Kein Ring.** Solange noch nichts da ist,
                            // steht das Raster in seiner Form; sind schon
                            // Treffer da, bleiben die stehen, statt einem
                            // Ring zu weichen.
                            Rasterplatzhalter(
                                spalten: Stil.spalten(
                                    nutzbar: rahmen.size.width - 2 * Stil.rand(breit: breit),
                                    breit: breit),
                                reihen: 2)
                                .padding(.horizontal, Stil.rand(breit: breit))
                                .padding(.top, 12)
                                .transition(.opacity)
                        } else if treffer.isEmpty, seerrtreffer.isEmpty {
                            // **Beide leer, nicht nur die Bibliothek.** Hier
                            // stand `treffer.isEmpty`, und damit gewann dieser
                            // Zweig, sobald der eigene Server nichts hatte —
                            // der Seerr-Block darunter wurde nie erreicht.
                            // Genau der Fall, für den die ganze Anbindung
                            // gebaut ist: „Blade Runner" gibt es hier nicht,
                            // und *deshalb* will man ihn anfragen. Von
                            Text("Keine Treffer für \u{201E}\(begriff)\u{201C}")
                                .font(Stil.koerper)
                                .foregroundStyle(Stil.schriftLeise)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            // Nach Art gruppiert, wie bei Plex: in der Liste
                            // liest man Titel und Art auf einen Blick.
                            let nutzbar = rahmen.size.width - 2 * Stil.rand(breit: breit)
                            // **Ohne Seerr keine Überschrift.** Wer nichts
                            // angebunden hat, soll nicht „Auf deinem Server"
                            // lesen und sich fragen, wo der andere Block ist.
                            // Die Überschrift trägt nur, wenn darunter
                            // wirklich etwas steht — sonst kündigt sie einen
                            // leeren Block an.
                            if !seerrtreffer.isEmpty, !treffer.isEmpty {
                                blockTitel("Auf deinem Server", treffer.count)
                            }
                            gruppe("Serien", treffer.filter { $0.type == "Series" },
                                   nutzbar: nutzbar)
                            gruppe("Filme", treffer.filter { $0.type == "Movie" },
                                   nutzbar: nutzbar)
                            gruppe("Folgen", treffer.filter { $0.type == "Episode" },
                                   nutzbar: nutzbar)
                            gruppe("Weiteres", treffer.filter {
                                !["Series", "Movie", "Episode"].contains($0.type ?? "")
                            }, nutzbar: nutzbar)
                            if !seerrtreffer.isEmpty {
                                blockTitel("Kann angefragt werden", seerrtreffer.count).padding(.top, 8)
                                seerrRaster(nutzbar: nutzbar)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.bottom, breit ? 24 : Stil.leisteHoehe + 12,
                                for: .scrollContent)
                // Tippen ins Leere schliesst die Tastatur — sonst kommt man
                // aus dem Feld gar nicht mehr heraus.
                .simultaneousGesture(TapGesture().onEnded { imFeld = false })
                // Nur die Trefferflaeche zieht sich heran, nicht das Suchfeld
                // darueber — siehe `bereichsinhalt()`.
                .bereichsinhalt()
            }
            }
            // Ueber dem Inhalt, unter allem, was die Seite sonst noch
            // auflegt — siehe `bereichsleiste()`.
            .bereichsleiste()
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
                // **Auch schmal ein Raster, nicht mehr eine Zeilenliste.**
                // Mit Seerr stehen zwei Blöcke untereinander, und ein Plakat
                // sagt auf einen Blick, ob ein Titel da ist — eine Zeile mit
                // 52er Vorschaubild kann das nicht.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Stil.kachelAbstand),
                                         count: Stil.spalten(nutzbar: nutzbar, breit: breit)),
                          alignment: .leading, spacing: 16) {
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
            }
        }
    }

    /// **Die Rubrik sagt jetzt auch, wie viel.**
    ///
    /// Bibliothek und Merkliste tragen rechts eine Zählmarke; sie beantwortet
    /// „bin ich hier durch?". In der Suche fehlte sie — dabei ist gerade dort
    /// interessant, wie viel überhaupt kam, und beim zweiten Block nebenbei,
    /// wie viel Seerr anzubieten hat.
    private func blockTitel(_ text: LocalizedStringKey, _ anzahl: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(Stil.schriftSehrLeise)
            Spacer(minLength: 8)
            if anzahl > 0 { Zaehlmarke(anzahl: anzahl) }
        }
        .padding(.horizontal, Stil.rand(breit: breit))
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func seerrRaster(nutzbar: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                     spacing: Stil.kachelAbstand),
                                 count: Stil.spalten(nutzbar: nutzbar, breit: breit)),
                  alignment: .leading, spacing: 16) {
            ForEach(seerrtreffer) { t in
                NavigationLink(value: t) { Seerrkachel(treffer: t) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Stil.rand(breit: breit))
        .padding(.bottom, 10)
    }

    /// **Breit steht er unter dem Feld, nicht in der Mitte.**
    ///
    /// Schmal fuellt das Suchfeld die Zeile, und ein mittiger Hinweis steht
    /// unter seiner Mitte. Breit ist das Feld nur `lesebreite` lang und sitzt
    /// links — der Hinweis stand dann in der Mitte des Fensters, also neben
    /// dem, worauf er sich bezieht.
    private var leerhinweis: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Stil.schriftSehrLeise)
            Text("Filme, Serien und Folgen durchsuchen")
                .font(Stil.koerper)
                .foregroundStyle(Stil.schriftLeise)
        }
        // **Mittig unter dem Feld, nicht mittig im Fenster.**
        //
        // Er stand in der Mitte der ganzen Breite, das Feld darueber aber
        // links in seiner Lesebreite — der Hinweis schwebte also neben dem,
        // worauf er sich bezieht. Linksbuendig war es dann das andere Extrem:
        // Zeichen und Satz klebten an der Kante eines leeren Fensters. Jetzt
        // bekommt er dieselbe Spalte wie das Feld und steht in deren Mitte.
        .frame(maxWidth: breit ? Stil.lesebreite : .infinity)
        .frame(maxWidth: .infinity, alignment: breit ? .leading : .center)
        .padding(.horizontal, breit ? Stil.rand(breit: true) : 0)
        .padding(.top, 70)
    }


    /// Mit Verzögerung, damit nicht jeder Tastendruck eine Anfrage auslöst.
    private func suchen(_ begriff: String) {
        aufgabe?.cancel()
        let sauber = begriff.trimmingCharacters(in: .whitespaces)
        // Die Schwelle steht im Paket, damit sie auf allen sechs Fassungen
        // dieselbe ist — sie stand bisher überall einzeln getippt.
        guard Anzeigeregeln.suchbegriffTaugt(sauber) else {
            treffer = []
            seerrtreffer = []
            sucht = false
            return
        }
        sucht = true
        aufgabe = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // **Nebeneinander, nicht nacheinander.** Der eigene Server ist
            // der Grund, warum jemand die App benutzt; er darf nicht auf
            // eine Zugabe warten. Deshalb wird zuerst gezeigt, was er hat.
            async let fremd = model.seerr.suchen(sauber)
            let ergebnis = await model.suche(sauber)
            guard !Task.isCancelled else { return }
            // Doppelte Kennungen lassen einen Tipp danebengreifen.
            treffer = Listenregeln.ohneDoppelte(ergebnis)
            sucht = false

            let dazu = await fremd
            guard !Task.isCancelled else { return }
            // Was der eigene Server schon hat, gehört nicht in den unteren
            // Block — sonst stünde derselbe Titel zweimal auf der Seite.
            seerrtreffer = dazu.filter { !$0.stand.schonDa }
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
