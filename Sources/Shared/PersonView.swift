import JellyfinKit
import SwiftUI

/// **Eine Person: wer das ist, und was es mit ihr gibt.**
///
/// Ein Tipp auf einen Darsteller führte bisher nirgends hin — von einem
/// Tester gemeldet. Aufgebaut wie die Detailseite: oben ein Banner, unten
/// links darin Bild und Name, darunter die Rolle, über die man kam, und die
/// Biografie. Dann zwei Reihen: was es auf dem Server gibt, und — nur mit
/// Seerr — was sich anfragen lässt. Alles Persönliche kommt vom eigenen
/// Server; fehlt es dort, fällt der Teil weg.
///
/// **Das Banner wechselt** zwischen den Hintergründen der Titel dieser
/// Person, weich und langsam. Gibt es nur einen, bleibt es bei dem.
///
/// **Nichts springt nach.** Bild und Name stehen sofort da — sie kommen mit
/// dem Tipp. Alles andere blendet gemeinsam ein, sobald beide Abrufe da sind;
/// bis dahin stehen die Reihen als Platzhalter in ihrer Form. Vorher kamen
/// Geburtstag, Reihen und Anfragbares nacheinander, und die Seite ruckte.
struct PersonView: View {
    let model: AppModel
    let route: PersonRoute

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var auskunft: Item?
    @State private var titel: [Item] = []
    @State private var anfragbar: [Seerrtreffer] = []
    @State private var geladen = false
    /// Seerr hat geantwortet — erst dann gilt „es gibt sonst nichts".
    @State private var seerrFertig = false
    @State private var ganzeBiografie = false
    @State private var versatz: CGFloat = 0
    @State private var banner: [URL] = []
    @State private var bannerStelle = 0

    private var person: Person { route.person }
    private var bannerJetzt: URL? { banner.isEmpty ? nil : banner[bannerStelle % banner.count] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // **Ein Aufbau, nicht zwei.** Breit stand hier
                    // `Heldkopf` — der Kopf der Detailseiten, mit dem
                    // **eckigen Plakat** links. Bei einem Titel stimmt das,
                    // bei einem Menschen nicht: iPhone und Mac zeigen einen
                    // runden Kopf, wie die Kacheln der Besetzung, und das
                    // iPad zeigte als einziges ein Rechteck. Jetzt tragen
                    // alle drei denselben Kopf; verschieden ist nur, wie
                    // gross er ist.
                    held
                    // Die Rolle kommt mit dem Tipp — sie wartet auf nichts.
                    rollenzeile
                        .padding(.horizontal, Stil.rand(breit: breit))
                        .padding(.top, 14)
                    biografie
                        .frame(maxWidth: breit ? Stil.lesebreite : .infinity,
                               alignment: .leading)
                        .padding(.horizontal, Stil.rand(breit: breit))
                    reihen
                }
                // **Nie breiter als der Schirm.** Ein Kind, das breiter ist —
                // beim ersten Versuch eine Reihe Platzhalterkacheln —, machte
                // sonst die ganze Spalte so breit, und die Scrollfläche setzte
                // sie mittig: der Inhalt stand links aus dem Bild und rutschte
                // beim Laden an seinen Platz.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
                versatz = neu
            }

            Detailkopf(titel: person.name, versatz: versatz) { zurueck() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task(id: person.id) { await laden() }
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

    /// Das Banner wie auf der Detailseite, unten links Bild und Name.
    private var held: some View {
        ZStack {
            Heldbild(url: bannerJetzt, hoehe: breit ? Stil.heldHoeheBreit : Stil.heldHoehe)
                .id(bannerStelle)
                .transition(.opacity)
        }
        .overlay(alignment: .bottom) { Heldauslauf() }
        .overlay(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: 14) {
                // Rund, weil es ein Bild ist — wie die Kacheln der Besetzung.
                Bild(url: model.personBild(person, maxHeight: 300),
                     breite: kopfgroesse, hoehe: kopfgroesse, ecke: kopfgroesse / 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: person.name)
                        .font(Stil.titel)
                        .tracking(-0.6)
                        .foregroundStyle(Stil.schrift)
                        .lineLimit(2)
                    // **Die zwei Zeilen haben ihren Platz von Anfang an** und
                    // blenden nur ein. Kamen sie erst beim Laden dazu, schoben
                    // sie den Namen nach oben — mitten im Hereinfahren.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: geburtszeile ?? " ")
                        Text(verbatim: ort ?? " ")
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(1)
                    .opacity(geladen ? 1 : 0)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.bottom, 16)
        }
    }

    /// Breit ein grösserer Kopf — dieselbe Form, nur auf Armlänge statt in
    /// der Hand.
    private var kopfgroesse: CGFloat { breit ? 104 : 76 }

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
        if let rolle = person.role, !rolle.isEmpty, let herkunft = route.herkunft {
            Text("\(rolle) in \(herkunft)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Stil.akzent)
                .lineLimit(2)
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
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { ganzeBiografie.toggle() }
                } label: {
                    Text(ganzeBiografie ? LocalizedStringKey("Weniger") : LocalizedStringKey("Mehr"))
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Stil.schrift)
            }
            .padding(.top, 14)
            .transition(.opacity)
        }
    }

    // MARK: Reihen

    @ViewBuilder
    private var reihen: some View {
        // Wie auf der Detailseite: die Reihen stehen da, wenn sie da sind —
        // ohne Platzhalter, der beim Eintreffen ausgetauscht wird.
        if geladen {
            if !titel.isEmpty {
                Abschnitt(titel: "Auf deinem Server") {
                    HStack(alignment: .top, spacing: Stil.kachelAbstand) {
                        ForEach(titel) { item in
                            NavigationLink(value: item) {
                                PosterTile(model: model, item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Stil.rand(breit: breit))
                }
                .transition(.opacity)
            }
            if !anfragbar.isEmpty {
                Abschnitt(titel: "Kann angefragt werden") {
                    HStack(alignment: .top, spacing: Stil.kachelAbstand) {
                        ForEach(anfragbar) { t in
                            NavigationLink(value: t) {
                                Seerrkachel(treffer: t, breite: Stil.kachelBreite)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Stil.rand(breit: breit))
                }
                .transition(.opacity)
            }
            if titel.isEmpty, anfragbar.isEmpty, seerrFertig {
                Text("Auf deinem Server gibt es sonst nichts mit \(person.name).")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.top, 26)
            }
        }
    }

    // MARK: Laden

    private func laden() async {
        // **Der eigene Server zuerst, Seerr daneben.** Seerr fragt für eine
        // Filmografie erst bei TMDB nach und braucht dafür manchmal Sekunden;
        // auf die wartete die ganze Seite. Jetzt steht sie, sobald der Server
        // geantwortet hat, und „Kann angefragt werden" kommt unten dazu —
        // unten, damit sich darüber nichts verschiebt.
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

        // Alles vom Server in einem Zug, und weich. Nur Deckkraft: die Spalte
        // hält ihre Breite, was neu ist, blendet an seinem Platz ein.
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
