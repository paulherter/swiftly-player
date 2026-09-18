import JellyfinKit
import SwiftUI

/// **Eine Person: wer das ist, und was es mit ihr gibt.**
///
/// Ein Klick auf einen Darsteller führte bisher nirgends hin — von einem
/// Tester gemeldet, zuerst auf dem iPhone behoben. Aufgebaut wie die
/// Detailseite dieses Fensters: das Bild rechts als Kulisse, links unten
/// Porträt und Name, darunter die Rolle, über die man kam, und die
/// Biografie. Dann die Reihen: was auf dem Server liegt, und — nur mit
/// Seerr — was sich anfragen lässt.
///
/// **Das Banner wechselt** zwischen den Hintergründen ihrer Titel, weich und
/// langsam. Gibt es nur einen, bleibt es bei dem.
///
/// **Nichts springt nach.** Porträt und Name stehen sofort da — sie kommen
/// mit dem Klick. Alles andere blendet gemeinsam ein, sobald der Server
/// geantwortet hat; Seerr kommt unten dazu, damit sich darüber nichts
/// verschiebt.
struct PersonView: View {
    let model: AppModel
    let person: Person
    /// Der Titel, aus dem man kam — steht über der Rolle.
    let herkunft: String?
    let zurueck: () -> Void

    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    @State private var farbe = Bildfarbe()
    @State private var kopfstand = Kopfstand()
    @State private var auskunft: Item?
    @State private var titel: [Item] = []
    @State private var anfragbar: [Seerrtreffer] = []
    @State private var geladen = false
    /// Seerr hat geantwortet — erst dann gilt „es gibt sonst nichts".
    @State private var seerrFertig = false
    @State private var ganzeBiografie = false
    @State private var banner: [URL] = []
    @State private var bannerStelle = 0

    private var bannerJetzt: URL? { banner.isEmpty ? nil : banner[bannerStelle % banner.count] }

    /// Wie hoch der runde Kopf ist — und damit der ganze Block, denn der Text
    /// daneben ist niedriger.
    private let blockhoehe: CGFloat = 88

    /// **Die Kopfzone ist kürzer als auf der Detailseite, und das ist
    /// gerechnet.**
    ///
    /// Auf der Detailseite füllen Titel, Angaben, Beschreibung und Knopfreihe
    /// die 380 Punkt bis zur Unterkante. Hier steht nur ein Name. Stand der
    /// Block oben, klaffte darunter ein Loch; hängte man ihn unten an, klaffte
    /// es darüber — links neben dem Namen liegt ja keine Kulisse, sondern
    /// blanker Grund.
    ///
    /// Also dieselbe Rechnung wie dort, nur ohne das, was es hier nicht gibt:
    /// derselbe Vorlauf oben (`titelHoehe + 98`, damit auch die einblendende
    /// Leiste weiter passt), darunter der Block und sein Fussabstand.
    private var kopfhoehe: CGFloat { Stil.titelHoehe + 98 + blockhoehe + 22 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                held.zIndex(1)

                VStack(alignment: .leading, spacing: 26) {
                    // Rolle und Biografie stehen zusammen und eng — auf dem
                    // iPhone genauso. Der grosse Abstand gilt zwischen den
                    // Blöcken, nicht innerhalb.
                    VStack(alignment: .leading, spacing: 10) {
                        rollenzeile
                        biografie
                    }
                    Titelreihe(titel: "Auf deinem Server", eintraege: titel, model: model)
                    anfragereihe
                    if geladen, seerrFertig, titel.isEmpty, anfragbar.isEmpty {
                        Text("Auf deinem Server gibt es sonst nichts mit \(person.name).")
                            .font(Stil.koerper)
                            .foregroundStyle(Stil.schriftLeise)
                    }
                }
                .padding(.horizontal, Stil.randAbstand)
                .padding(.top, 26)
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .ohneKanteneffekt()
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        // Derselbe Auslauf wie auf der Detailseite: der Bildton läuft unter
        // dem Kopf noch ein Stück weiter und verliert sich im Grundton.
        .background(alignment: .top) {
            LinearGradient(colors: [farbe.ton, Stil.grund],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: kopfhoehe + 260)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Stil.grund)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
            kopfstand.versatz = neu
        }
        .overlay(alignment: .top) {
            Detailkopf(titel: person.name, stand: kopfstand, zurueck: zurueck)
        }
        .task(id: person.id) { await laden() }
        .task(id: bannerJetzt) { await farbe.laden(bannerJetzt) }
        .task(id: banner.count) {
            // Weich wechseln, und langsam genug, dass man hinsieht, bevor es
            // weitergeht. Mit einem Bild gibt es nichts zu wechseln.
            guard banner.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 1.2)) { bannerStelle += 1 }
            }
        }
    }

    // MARK: Kopf

    private var held: some View {
        // Ohne eigenen Hintergrund bleibt die Fläche leer statt ein Porträt
        // quer zu beschneiden — ein Gesicht im Anschnitt sieht schlechter aus
        // als Ruhe.
        ZStack {
            Kulisse(url: bannerJetzt, hoehe: kopfhoehe * 1.62)
                .id(bannerStelle)
                .transition(.opacity)
        }
        .frame(height: kopfhoehe, alignment: .topLeading)
        // **Unten im Bild, nicht oben.**
        //
        // Der Block sass auf der Höhe, auf der er auf der Detailseite sitzt —
        // dort folgen darunter aber noch Beschreibung und Knopfreihe, die die
        // Kopfzone bis zur Unterkante füllen. Hier folgt nichts, und zwischen
        // dem Namen und der Biografie stand ein Loch von rund 170 Punkt.
        // Unten verankert steht er, wo er auf iPhone und iPad steht.
        .overlay(alignment: .bottomLeading) {
            block
                .padding(.leading, Stil.randAbstand)
                .padding(.bottom, 22)
        }
    }

    /// Porträt, Name, zwei Auskunftszeilen, Rolle — **feste Höhen**, damit
    /// nichts nach oben schiebt, wenn der Server antwortet.
    private var block: some View {
        HStack(alignment: .bottom, spacing: 16) {
            // Rund, weil es ein Bild ist — wie die Köpfe der Besetzung.
            Profilzeichen(name: person.name,
                          bild: model.personBild(person, maxHeight: 300),
                          groesse: blockhoehe)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: person.name)
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                // Die zwei Zeilen haben ihren Platz von Anfang an und blenden
                // nur ein.
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: geburtszeile ?? " ")
                    Text(verbatim: ort ?? " ")
                }
                .font(.system(size: 14))
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
                .opacity(geladen ? 1 : 0)
            }
            .frame(width: 560, alignment: .leading)
        }
    }

    private var geburtszeile: String? {
        guard let tag = auskunft?.tagesdatum, let datum = Calendar.current.date(from: tag) else { return nil }
        return String(localized: "Geboren \(datum.formatted(date: .long, time: .omitted))")
    }

    private var ort: String? {
        guard let ort = auskunft?.productionLocations?.first, !ort.isEmpty else { return nil }
        return ort
    }

    @ViewBuilder
    private var rollenzeile: some View {
        if let rolle = person.role, !rolle.isEmpty, let herkunft {
            Text("\(rolle) in \(herkunft)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Stil.akzent)
                .lineLimit(1)
        }
    }

    /// Vier Zeilen, dann „Mehr". Eine Biografie ist hier Auskunft, nicht der
    /// Grund, die Seite zu öffnen — sie soll die Titel nicht nach unten
    /// schieben, bevor man sie will.
    @ViewBuilder
    private var biografie: some View {
        if let text = auskunft?.beschreibung {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: text)
                    .font(Stil.koerper)
                    .lineSpacing(3)
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(ganzeBiografie ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                Button(ganzeBiografie ? "Weniger" : "Mehr") {
                    withAnimation(.easeInOut(duration: 0.2)) { ganzeBiografie.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Stil.schrift)
            }
            .frame(maxWidth: Stil.lesebreite, alignment: .leading)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var anfragereihe: some View {
        if !anfragbar.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Kann angefragt werden")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Stil.schrift)
                Blätterreihe(rand: 0) {
                    ForEach(anfragbar) { treffer in
                        Button { navigator.oeffne(.seerrTitel(treffer), in: bereich) } label: {
                            Seerrkachel(treffer: treffer)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Laden

    private func laden() async {
        // **Der eigene Server zuerst, Seerr daneben.** Seerr fragt für eine
        // Filmografie erst bei TMDB nach und braucht dafür manchmal Sekunden;
        // auf die wartete sonst die ganze Seite.
        async let eigene = model.titel(person: person.id)
        let a = await model.item(id: person.id)
        async let fremde = filmografie(tmdb: a?.tmdbKennung)
        let b = await eigene

        // Nur echte Querbilder wechseln; hat keiner der Titel eins, nimmt das
        // Banner, was der erste als Ersatz hergibt.
        var bilder = b.compactMap { model.querbildEcht(for: $0) }
        if bilder.isEmpty, let erster = b.first, let ersatz = model.kopfbildURL(for: erster) {
            bilder = [ersatz]
        }

        withAnimation(Stil.einblenden) {
            auskunft = a
            titel = b
            banner = bilder
            geladen = true
        }

        // **Nur, was nicht schon da ist.** Seerr kennt, was es selbst
        // verwaltet; was anders auf den Server kam, steht dort als offen —
        // der Name fängt es ab.
        let eigeneNamen = Set(b.map { $0.name.lowercased() })
        let neu = await fremde.filter { !$0.stand.schonDa && !eigeneNamen.contains($0.titel.lowercased()) }
        withAnimation(Stil.einblenden) {
            anfragbar = neu
            seerrFertig = true
        }
    }

    private func filmografie(tmdb: Int?) async -> [Seerrtreffer] {
        guard model.seerr.verbunden, let tmdb else { return [] }
        return await model.seerr.filmografie(person: tmdb)
    }
}
