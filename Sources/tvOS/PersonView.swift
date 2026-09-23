import JellyfinKit
import SwiftUI

/// **Eine Person: wer das ist, und was es mit ihr gibt.**
///
/// Ein Druck auf einen Darsteller führte hier nirgends hin — der Knopf in
/// `Besetzungsstreifen` hatte eine leere Aktion, also genau die Form, vor der
/// CLAUDE.md warnt: gebaut, aber nicht angeschlossen. Aufgebaut wie eine
/// Detailseite: Kulisse rechts, links unten der runde Kopf mit Name,
/// Geburtsdatum und Ort, darunter die Rolle und die Biografie. Dann die
/// Reihen — was auf dem Server liegt, und mit Seerr, was sich anfragen lässt.
///
/// **Das Banner wechselt** zwischen den Hintergründen ihrer Titel, weich und
/// langsam. Gibt es nur einen, bleibt es bei dem.
struct PersonView: View {
    let model: AppModel
    let route: PersonRoute

    @State private var auskunft: Item?
    @State private var titel: [Item] = []
    @State private var anfragbar: [Seerrtreffer] = []
    @State private var geladen = false
    /// `nil` von `titel(person:)` heisst gestoert. Vorher stand bei einem
    /// stummen Server „Auf deinem Server gibt es sonst nichts mit …" da.
    @State private var gestoert = false
    /// Seerr hat geantwortet — erst dann gilt „es gibt sonst nichts".
    @State private var seerrFertig = false
    @State private var banner: [URL] = []
    @State private var bannerStelle = 0

    private var person: Person { route.person }
    private var bannerJetzt: URL? { banner.isEmpty ? nil : banner[bannerStelle % banner.count] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                kopf

                // **Vor `geladen` stand hier nichts** — Name, Bild, und
                // darunter eine leere Flaeche, beim Laden wie bei einem
                // stummen Server.
                if !geladen {
                    reihenabschnitt {
                        Reihentitel(text: "Auf deinem Server")
                    } inhalt: {
                        streifen {
                            ForEach(0 ..< 5, id: \.self) { _ in
                                Ladefeld()
                                    .frame(width: Stil.posterBreite,
                                           height: Stil.posterHoehe)
                            }
                        }
                    }
                    .transition(.opacity)
                } else if !titel.isEmpty {
                    reihenabschnitt {
                        Reihentitel(text: "Auf deinem Server")
                    } inhalt: {
                        Titelstreifen(model: model, items: titel)
                    }
                    .transition(.opacity)
                }

                if !anfragbar.isEmpty {
                    reihenabschnitt {
                        Reihentitel(text: "Kann angefragt werden")
                    } inhalt: {
                        streifen {
                            ForEach(anfragbar) { t in
                                NavigationLink(value: t) { Seerrkachel(treffer: t) }
                                    .buttonStyle(KachelStil())
                            }
                        }
                    }
                    .transition(.opacity)
                }

                if gestoert, titel.isEmpty {
                    // Auf Seerr wird nicht gewartet: was der eigene Server
                    // sagt, ist die Hauptauskunft dieser Seite.
                    Stoerzustand(model: model, erneut: { Task { await laden() } })
                        .frame(height: Stil.posterHoehe)
                } else if geladen, seerrFertig, titel.isEmpty, anfragbar.isEmpty {
                    Text("Auf deinem Server gibt es sonst nichts mit \(person.name).")
                        .font(Stil.kachel)
                        .foregroundStyle(Stil.schriftLeise)
                        .padding(.horizontal, Stil.randSeite)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, Stil.abschlussLuft)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .bildgrund(url: bannerJetzt)
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

    /// **Kein `focusSection`.** Im Kopf steht nichts Fokussierbares, und ein
    /// angemeldeter Bereich ohne Ziel darin zieht den Druck an sich und lässt
    /// ihn fallen — daran ist die Besetzungsreihe schon einmal hängen
    /// geblieben. Siehe `Detailrahmen.fokussierbar`.
    private var kopf: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                Kulisse(url: bannerJetzt)
                    .id(bannerStelle)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            Kopfschatten()

            block
                .padding(.leading, Stil.randSeite)
                // Dieselbe Zeile, in der die Detailseite ihren Titel hat.
                .padding(.top, 140 + Stil.kopfversatzDetail)
        }
        .frame(height: Stil.heldenHoeheDetail, alignment: .topLeading)
    }

    private var block: some View {
        HStack(alignment: .top, spacing: 40) {
            // Rund, weil es ein Bild ist — wie die Kacheln der Besetzung. Die
            // halbe Kantenlaenge ist keine Stufe der Eckenleiter, sondern der
            // Kreis selbst.
            Bild(url: model.personBild(person, maxHeight: 600),
                 breite: 208, hoehe: 208, ecke: 208 / 2)

            VStack(alignment: .leading, spacing: 0) {
                Text(person.name)
                    .font(Stil.titelGross)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                // **Die zwei Zeilen haben ihren Platz von Anfang an** und
                // blenden nur ein. Kämen sie erst beim Laden dazu, schöben
                // sie alles darunter nach unten.
                VStack(alignment: .leading, spacing: 2) {
                    Text(geburtszeile ?? " ")
                    Text(ort ?? " ")
                }
                .font(Stil.kachel)
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
                .opacity(geladen ? 1 : 0)
                .padding(.top, 10)

                if let rolle = person.role, !rolle.isEmpty, let herkunft = route.herkunft {
                    Text("\(rolle) in \(herkunft)")
                        .font(Stil.kachel)
                        .foregroundStyle(Stil.akzent)
                        .lineLimit(1)
                        .padding(.top, 12)
                }

                if let text = auskunft?.beschreibung {
                    Text(text)
                        .font(Stil.koerper)
                        .lineSpacing(Stil.beschreibungLuft)
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .lineLimit(3)
                        .padding(.top, 16)
                        .transition(.opacity)
                }
            }
            // Wie der Kopftext der Detailseiten: nie über die Kulisse hinaus.
            .frame(width: 1000, alignment: .leading)
        }
    }

    private var geburtszeile: String? {
        guard let tag = auskunft?.tagesdatum,
              let datum = Calendar.current.date(from: tag) else { return nil }
        return String(localized: "Geboren \(datum.formatted(date: .long, time: .omitted))")
    }

    private var ort: String? {
        guard let ort = auskunft?.productionLocations?.first, !ort.isEmpty else { return nil }
        return ort
    }

    // MARK: Laden

    private func laden() async {
        // **Der eigene Server zuerst, Seerr daneben.** Seerr fragt für eine
        // Filmografie erst bei TMDB nach und braucht dafür manchmal Sekunden;
        // auf die wartete sonst die ganze Seite.
        async let eigene = model.titel(person: person.id)
        let a = await model.item(id: person.id)
        async let fremde = filmografie(tmdb: a?.tmdbKennung)
        let geholt = await eigene
        // Gescheitert: die Seite behaelt, was sie hatte, und sagt es.
        let b = geholt ?? titel

        // Nur echte Querbilder wechseln; hat keiner der Titel eins, nimmt das
        // Banner, was der erste als Ersatz hergibt.
        var bilder = b.compactMap { model.querbildEcht(for: $0) }
        if bilder.isEmpty, let erster = b.first, let ersatz = model.kopfbildURL(for: erster) {
            bilder = [ersatz]
        }

        withAnimation(Stil.einblenden) {
            auskunft = a
            gestoert = geholt == nil
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
