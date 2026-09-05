import JellyfinKit
import SwiftUI

/// Die Seite eines Titels, den der eigene Server noch nicht hat.
///
/// **Dieselbe Seite wie sonst, nur eine andere Handlung.** Getauscht ist der
/// grosse Knopf — aus *Fortsetzen* wird *Anfragen* — und die Reiter: es gibt
/// keine Folgen zu zeigen, wohl aber Besetzung und Vorschlaege.
///
/// **Der Aufbau ist der der Serienseite, Zeile fuer Zeile**, und das ist
/// keine Bequemlichkeit, sondern die Lehre aus drei Runden. Wer die Seite
/// nachbaut, trifft die Abstaende nicht: der Kopf sass tiefer, das Bild hing
/// beim Scrollen fest, oben stand ein Verlauf, den es dort nie gab. Jede
/// dieser drei Abweichungen war ein Baustein, der schon dalag und nicht
/// benutzt wurde — `Heldbild` misst sich im Raum „blatt", `Detailkopf`
/// bringt seinen eigenen, sehr viel schwaecheren Verlauf mit, und
/// `.ignoresSafeArea(edges: .top)` ist der Grund, warum das Bild ueberhaupt
/// bis nach oben laeuft.
///
/// Was hier abweicht, weicht mit Absicht ab und steht als Kommentar dabei.
struct SeerrDetailView: View {
    let model: AppModel
    let treffer: Seerrtreffer

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit

    /// Wie weit gescrollt wurde — der Kopf blendet danach ein. Wie dort.
    @State private var versatz: CGFloat = 0

    @State private var stand: Seerrstand
    @State private var laeuft = false
    @State private var fehler: String?
    @State private var angefragt = false
    @State private var detail: Seerrdetail?
    /// Welche Staffeln angekreuzt sind. Leer heisst **alle** — so wie beim
    /// ersten Oeffnen, wo niemand etwas ausgewaehlt hat.
    @State private var gewaehlt: Set<Int> = []
    @State private var blattOffen = false
    /// **Hat der Nutzer schon einmal gedrueckt?** Bei einem Film ist die
    /// Anfrage sonst einen Fingerbreit entfernt Bei einer Serie fragt das
    /// Staffelblatt ohnehin nach, das ist dort der zweite Schritt.
    @State private var bestaetigt = false

    init(model: AppModel, treffer: Seerrtreffer) {
        self.model = model
        self.treffer = treffer
        _stand = State(initialValue: treffer.stand)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero

                    VStack(alignment: .leading, spacing: 14) {
                        belegzeile
                        hauptknopf
                        beschreibung
                    }
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.top, 14)

                    // **Zwei Reihen, keine Reiter.** Genau wie auf der
                    // Filmseite: eine Reihe Besetzung, darunter eine Reihe
                    // Aehnliches. Als Reiter mit Raster stand hier eine Wand
                    // aus zwanzig Koepfen Waagerecht zeigt eine Reihe fuenf
                    // und deutet den Rest an; wer mehr will, schiebt.
                    besetzung
                    aehnlichesreihe
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            // Der Raum, in dem `Heldbild` seine Dehnung misst. Fehlte er,
            // blieb das Bild beim Scrollen stehen, statt mitzugehen.
            .coordinateSpace(.named("blatt"))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
                versatz = neu
            }
            // Ohne das steht ueber dem Bild der schwarze Streifen des
            // sicheren Bereichs.
            .ignoresSafeArea(edges: .top)

            // **Unser eigenes Blatt, nicht das des Systems.** Ein `.sheet`
            // bringt seine eigene Sprache mit — abgerundete Ecken oben,
            // Griff, Navigationsleiste — und stand damit neben „Mehr" und
            // den Wiedergabelisten wie aus einer anderen App.
            if blattOffen { staffelblatt.zIndex(20) }
            if let fehler {
                Hinweisstreifen(text: fehler) { self.fehler = nil }
                    .zIndex(21)
            }

            Detailkopf(titel: treffer.titel, versatz: versatz) { zurueck() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        // **Die Frage steht nicht ewig.** Wer den Knopf einmal antippt und
        // dann weiterliest, soll nicht Minuten spaeter einen Knopf vorfinden,
        // der beim naechsten Tipp sofort anfragt.
        .task(id: bestaetigt) {
            guard bestaetigt else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            bestaetigt = false
        }
        .task {
            detail = await model.seerr.detail(treffer)
            // **Nichts vorausgewaehlt.** „Man laedt ja nie alle runter im
            // Normalfall" — wer alles will, kreuzt alles an; wer eine will,
            // muss nicht erst acht abwaehlen.
        }
    }

    // MARK: Teile

    /// Wortgleich mit `SeriesDetailView.hero`, nur mit dem Querbild von TMDB
    /// statt dem des eigenen Servers.
    private var hero: some View {
        Heldbild(url: treffer.kulisse())
            .overlay(alignment: .bottom) { Heldauslauf() }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: treffer.titel)
                        .font(Stil.titel)
                        .tracking(-0.6)
                        .foregroundStyle(Stil.schrift)
                    Text(verbatim: nebenzeile)
                        .font(.system(size: 14))
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(1)
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.bottom, 16)
            }
    }

    /// Jahr, Staffeln oder Laufzeit, Gattungen — dieselbe Reihenfolge wie
    /// dort.
    private var nebenzeile: String {
        var teile: [String] = []
        if let jahr = treffer.jahr { teile.append("\(jahr)") }
        if treffer.istSerie {
            let n = detail?.staffeln.count ?? 0
            if n > 0 { teile.append(n == 1 ? String(localized: "1 Staffel")
                                           : String(localized: "\(n) Staffeln")) }
        } else if let m = detail?.laufzeit, m > 0 {
            teile.append(String(localized: "\(m) Min."))
        }
        let gattungen = detail?.genres ?? []
        if !gattungen.isEmpty { teile.append(gattungen.joined(separator: ", ")) }
        if teile.isEmpty {
            teile.append(treffer.istSerie ? String(localized: "Serie")
                                          : String(localized: "Film"))
        }
        return teile.joined(separator: " · ")
    }

    /// **Dieselbe Zeile wie dort**, nur mit dem Stand statt „Direct Play":
    /// ueber einen Titel, den es hier nicht gibt, weiss niemand, wie er
    /// laeuft. Symbol, Wort, Stern — in denselben Groessen und Abstaenden;
    /// deshalb steht der Aufbau hier und nicht in `Belegzeile`, die den
    /// Wiedergabeplan als Eingabe hat.
    private var belegzeile: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: stand.symbol)
                    .font(.system(size: 11, weight: .heavy))
                Text(verbatim: stand.wort)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(stand.farbe)

            if let b = detail?.bewertung, b > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill").font(.system(size: 11))
                    Text(verbatim: String(format: "%.1f", b)
                            .replacingOccurrences(of: ".", with: ","))
                        .font(.system(size: 13))
                }
                .foregroundStyle(Color.white.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
    }

    /// **Ein Stand ist keine Schaltflaeche.**
    ///
    /// Was wartet oder laedt, laesst sich nicht noch einmal anfragen; dort
    /// steht eine Auskunft statt eines grauen Knopfes.
    ///
    /// Der Stapel ringsum ist der von `SeriesDetailView.hauptknopf` —
    /// derselbe `VStack(spacing: 9)`, damit die Zeile darunter auf derselben
    /// Hoehe sitzt wie dort „Noch 25 Minuten".
    @ViewBuilder
    private var hauptknopf: some View {
        VStack(alignment: .leading, spacing: 9) {
            if angefragt {
                auskunft(String(localized: "Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
            } else if stand.anfragbar {
                Button(action: gedrueckt) {
                    HStack(spacing: 8) {
                        if laeuft {
                            Lader(groesse: 18, staerke: 2)
                        } else {
                            Image(systemName: bestaetigt ? "checkmark" : "plus")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        Text(knopftext)
                    }
                }
                // **Derselbe Stil wie „Fortsetzen", nur in Akzent.** Hoehe,
                // Ecke und Schriftgrad stehen dort und nicht hier — ein
                // nachgebauter Knopf sass sichtbar tiefer und runder.
                .buttonStyle(HauptknopfStil(dehnt: !breit, flaeche: Stil.akzent))
                .disabled(laeuft)
                // Der Wechsel der Beschriftung soll zu sehen sein, sonst
                // liest niemand, dass sich etwas geaendert hat.
                .animation(.snappy(duration: 0.18), value: bestaetigt)
            } else {
                auskunft(stand.hinweis)
            }
        }
    }

    private var knopftext: String {
        if laeuft { return String(localized: "Wird angefragt…") }
        return bestaetigt ? String(localized: "Wirklich anfragen?")
                          : String(localized: "Anfragen")
    }

    /// **Zwei Stufen, und die zweite ist der eigentliche Auftrag.**
    ///
    /// Bei einer Serie uebernimmt das Staffelblatt die zweite Stufe: dort
    /// steht noch einmal, was angefragt wird, und der Knopf darin loest aus.
    /// Ein Film hat nichts auszuwaehlen — deshalb fragt hier der Knopf
    /// selbst nach, statt ein Blatt zu oeffnen, das nur eine Frage enthaelt.
    private func gedrueckt() {
        if treffer.istSerie {
            withAnimation(.snappy(duration: 0.22)) { blattOffen = true }
            return
        }
        guard bestaetigt else {
            bestaetigt = true
            return
        }
        Task { await anfragen() }
    }

    @ViewBuilder
    private var beschreibung: some View {
        if let text = detail?.beschreibung {
            Klapptext(text: text)
        }
    }

    /// Wortgleich mit `ItemDetailView.besetzung`, nur mit den Koepfen von
    /// TMDB statt denen des eigenen Servers — samt der Grenze bei zwoelf.
    ///
    /// Kein Pfeil daneben: eine Seite mit der vollen Besetzung gibt es hier
    /// nicht, und ein Pfeil waere das Versprechen, dass es sie gaebe.
    @ViewBuilder
    private var besetzung: some View {
        let leute = detail?.besetzung ?? []
        if !leute.isEmpty {
            Abschnitt(titel: "Besetzung") {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(leute.prefix(12)) { person in
                        Besetzungskachel(bild: person.bild(), name: person.name,
                                         rolle: person.rolle)
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
            }
        }
    }

    /// Dieselbe Reihe wie dort — mit `Seerrkachel` statt `PosterTile`, weil
    /// auch das Vorgeschlagene nicht auf dem Server liegt und blass gehoert.
    ///
    /// Das feste Mass steht hier und nicht in der Kachel: im Raster der Suche
    /// bekommt sie ihre Breite von der Spalte, in einer Reihe hat sie keine.
    @ViewBuilder
    private var aehnlichesreihe: some View {
        let andere = detail?.aehnliches ?? []
        if !andere.isEmpty {
            Abschnitt(titel: "Ähnliche Titel") {
                HStack(alignment: .top, spacing: Stil.kachelAbstand) {
                    ForEach(andere) { t in
                        NavigationLink(value: t) {
                            Seerrkachel(treffer: t).frame(width: Stil.kachelBreite)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
            }
        }
    }

    // MARK: Stand in Worten

    // Symbol, Wort, Farbe und Hinweis stehen in `Seerrmarke.swift` — dieselbe
    // Tabelle, aus der auch die Kachel liest. Hier stand sie ein zweites Mal,
    // mit anderen Symbolen und anderen Farben.

    private func auskunft(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Stil.koerper)
            .foregroundStyle(Stil.schriftLeise)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 13).padding(.horizontal, 14)
            .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Staffeln

    /// Die Staffeln zum Ankreuzen.
    ///
    /// **Was schon da ist, laesst sich nicht ankreuzen** — und sagt daneben,
    /// dass es da ist. Ein Kaestchen, das man druecken darf und das nichts
    /// bewirkt, ist schlimmer als keines.
    @ViewBuilder
    private var staffelliste: some View {
        ForEach(detail?.staffeln ?? []) { st in
            Button {
                guard st.stand.anfragbar else { return }
                if gewaehlt.contains(st.nummer) { gewaehlt.remove(st.nummer) }
                else { gewaehlt.insert(st.nummer) }
            } label: {
                HStack(spacing: 10) {
                    Text("Staffel \(st.nummer)")
                        .font(Stil.koerper)
                        .foregroundStyle(st.stand.anfragbar ? Stil.schrift
                                                            : Stil.schriftSehrLeise)
                    if st.folgen > 0 {
                        Text("· \(st.folgen) Folgen")
                            .font(Stil.klein).foregroundStyle(Stil.schriftSehrLeise)
                    }
                    Spacer(minLength: 8)
                    if st.stand.anfragbar {
                        Image(systemName: gewaehlt.contains(st.nummer)
                                ? "checkmark.square.fill" : "square")
                            .font(.system(size: 19))
                            .foregroundStyle(gewaehlt.contains(st.nummer)
                                ? Stil.akzent : Stil.schriftSehrLeise)
                    } else {
                        Text(st.stand == .da ? "vorhanden" : "unterwegs")
                            .font(Stil.klein).foregroundStyle(Stil.schriftSehrLeise)
                    }
                }
                .padding(.horizontal, Stil.randAbstand)
                .frame(height: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Welche Staffeln — als Blatt von unten.
    ///
    /// Der Rumpf steht in ``Blatt``: Schleier, Auffahren, die Flaeche bis in
    /// den unteren Sicherheitsbereich und der Griff zum Hinunterziehen. Hier
    /// steht nur, was drinsteht. Vorher war beides an dieser Stelle
    /// nachgebaut — und dabei fehlten das Auffahren und der Griff, und unter
    /// dem Blatt blieb der Streifen des Home-Indikators offen.
    private var staffelblatt: some View {
        Blatt(offen: $blattOffen) {
            VStack(spacing: 0) {
                Text("Welche Staffeln?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Stil.schriftLeise)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Stil.randAbstand)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 0) { staffelliste }
                }
                .frame(maxHeight: 320)

                Trennlinie()

                Button {
                    withAnimation(.snappy(duration: 0.22)) { blattOffen = false }
                    Task { await anfragen() }
                } label: {
                    Text(gewaehlt.isEmpty ? "Staffel wählen"
                                          : "\(gewaehlt.count) anfragen")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(gewaehlt.isEmpty ? Stil.schriftSehrLeise : Stil.akzent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(.plain)
                .disabled(gewaehlt.isEmpty)
            }
        }
    }

    private func anfragen() async {
        fehler = nil
        laeuft = true
        defer { laeuft = false }
        do {
            // Leer heisst alle — Seerr versteht das Wort `all`, und wer
            // nichts angekreuzt hat, will nicht nichts.
            let staffeln = gewaehlt.isEmpty ? nil : Array(gewaehlt).sorted()
            try await model.seerr.anfragen(treffer, staffeln: staffeln)
            angefragt = true
            stand = .wartetAufFreigabe
        } catch {
            fehler = error.localizedDescription
        }
    }
}
