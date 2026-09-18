import JellyfinKit
import SwiftUI

/// Ein Titel, den der eigene Server noch nicht hat — die Mac-Kachel.
///
/// **Blass, und das ist die ganze Auskunft.** Wer schnell scrollt, soll ohne
/// ein Wort zu lesen sehen, dass hier nichts abzuspielen ist. Die Überschrift
/// darüber bestätigt es nur; sie ist nicht die Erklärung.
struct Seerrkachel: View {
    let treffer: Seerrtreffer
    @State private var schwebt = false
    @State private var da = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Bildflaeche(bild: treffer.plakat(breite: 342),
                            breite: Stil.kachelBreite, hoehe: Stil.kachelHoehe,
                            zeichen: treffer.istSerie ? "tv" : "film")
                    .opacity(0.45)
                marke.padding(8)
            }
            .scaleEffect(schwebt ? 1.04 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: treffer.titel)
                    .font(Stil.kachelTitel)
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(1)
                Text(verbatim: untertitel)
                    .font(Stil.zweitzeile)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .lineLimit(1)
            }
        }
        .frame(width: Stil.kachelBreite, alignment: .leading)
        .opacity(da ? 1 : 0)
        .onAppear {
            guard !da else { return }
            withAnimation(Stil.einblenden) { da = true }
        }
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(treffer.titel), \(treffer.stand.ansage)"))
    }

    private var untertitel: String {
        let art = treffer.istSerie ? String(localized: "Serie") : String(localized: "Film")
        return treffer.jahr.map { "\($0) · \(art)" } ?? art
    }

    /// **Nur was etwas Neues sagt.** „Kann angefragt werden" steht schon als
    /// Überschrift über dem Block; eine Marke, die es wiederholt, ist Lärm.
    @ViewBuilder
    private var marke: some View {
        if treffer.stand != .da {
            HStack(spacing: 4) {
                Image(systemName: treffer.stand.symbol)
                    .font(.system(size: 10, weight: .bold))
                if let wort = treffer.stand.kurzwort {
                    Text(verbatim: wort).font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(Stil.grund)
            .padding(.horizontal, treffer.stand.kurzwort == nil ? 6 : 8)
            .padding(.vertical, 3)
            .background(treffer.stand.farbe, in: Capsule())
        }
    }
}

/// Die Seite eines Titels, den der eigene Server noch nicht hat.
///
/// **Dieselbe Seite wie sonst, nur eine andere Handlung.** Getauscht ist der
/// grosse Knopf — aus *Abspielen* wird *Anfragen* — und die Reihen: es gibt
/// keine Folgen zu zeigen, wohl aber Besetzung und Vorschläge.
struct SeerrDetailView: View {
    let model: AppModel
    let treffer: Seerrtreffer
    let zurueck: () -> Void

    @State private var stand: Seerrstand
    @State private var detail: Seerrdetail?
    @State private var laeuft = false
    @State private var angefragt = false
    @State private var fehler: String?
    /// Welche Staffeln angekreuzt sind. Leer heisst **alle**.
    @State private var gewaehlt: Set<Int> = []
    @State private var staffelnOffen = false
    /// **Hat der Nutzer schon einmal gedrückt?** Bei einem Film ist die
    /// Anfrage sonst einen Klick entfernt.
    @State private var bestaetigt = false
    /// Wie weit die Seite steht — die Kopfleiste blendet daran ein.
    @State private var kopfstand = Kopfstand()
    /// Der Ton des Kopfbildes. **Fehlte hier ganz** — die Seite war deshalb
    /// schlicht schwarz, wo jede andere den Verlauf traegt.
    @State private var farbe = Bildfarbe()
    /// Wie hoch die Staffelliste tatsaechlich waere.
    @State private var listenhoehe: CGFloat = 0

    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    init(model: AppModel, treffer: Seerrtreffer, zurueck: @escaping () -> Void) {
        self.model = model
        self.treffer = treffer
        self.zurueck = zurueck
        _stand = State(initialValue: treffer.stand)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // **Derselbe Kopf wie auf einer echten Detailseite.**
                //
                // Hier stand eine Titelzeile ohne Bild Dieselbe Sorte Fehler
                // wie damals auf dem iPhone: nachgebaut statt uebernommen.
                // `Kulisse` nimmt eine blanke Adresse, das Querbild von TMDB
                // passt also ohne Umweg hinein; der Aufbau ist Zeile fuer
                // Zeile der von `Heldenkopf` in `DetailView`.
                held.zIndex(1)

                // **Wie auf der echten Seite:** 26 Punkt zwischen den
                // Reihen, derselbe Rand, dieselbe Ueberschrift. Hier stand
                // spacing 0 mit eigenen `padding(.top, 34)` an jeder Reihe.
                VStack(alignment: .leading, spacing: 26) {
                    besetzung
                    aehnliches
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Stil.randAbstand)
                .padding(.top, 26)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.never)
        .ohneKanteneffekt()
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        // **Der Verlauf aus dem Bild — er fehlte hier ganz.**
        //
        // Jede echte Detailseite traegt ihn: der Ton laeuft unter dem
        // Heldenbild noch ein Stueck weiter und verliert sich im Grundton.
        // Ohne ihn war die Seite schlicht schwarz
        //
        // **Und daran hing der zweite Befund mit.** Die Kulisse ist 1,62 mal
        // so hoch wie die Kopfzone und laeuft mit ihrer weichen Blende
        // darueber hinaus — ueber die Besetzungsreihe. Lag darunter kein
        // Grund, schien sie durch, und die Koepfe wurden nach rechts hin
        // durchsichtig. Mit `background(Stil.grund)` steht etwas dahinter.
        .background(alignment: .top) {
            LinearGradient(colors: [farbe.ton, Stil.grund],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Stil.heldHoehe + 260)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Stil.grund)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
            kopfstand.versatz = neu
        }
        // **Dieselbe Kopfleiste wie die echte Seite.** Sie blendet ein, wenn
        // der grosse Titel unter ihr verschwindet, und der Zurueckpfeil
        // steckt in ihr. Vorher stand hier ein runder `Aktionsknopf` mitten
        // im Bild — den hat die echte Seite nicht.
        // **Die Staffelliste haengt an der Seite, nicht im Block.** Der Fang
        // liegt darunter: ein Klick daneben schliesst sie, wie bei der
        // Ladetafel.
        .overlay(alignment: .topLeading) {
            if treffer.istSerie, staffelnOffen {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(Stil.zeitSprung) { staffelnOffen = false }
                        }
                    staffelliste
                        .padding(.leading, Stil.randAbstand)
                        // Unter dem Knopf: der Block beginnt bei
                        // `titelHoehe + 98`, die Knopfreihe darin bei 182.
                        .padding(.top, Stil.titelHoehe + 98 + 182
                                       + Stil.hauptknopfHoehe + 10)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            Detailkopf(titel: treffer.titel, stand: kopfstand, zurueck: zurueck)
        }
        .task { await farbe.laden(treffer.kulisse(breite: 780)) }
        .task { detail = await model.seerr.detail(treffer) }
    }

    /// **Woertlich der Aufbau von `Heldenkopf` in `DetailView`.**
    ///
    /// Nicht „aehnlich" — dieselben Stellen, dieselbe Breite, dieselben Grade.
    /// Was hier abweicht, weicht ab, weil es die Sache verlangt: statt „Direct
    /// Play" steht der Stand, denn ueber einen Titel, den es hier nicht gibt,
    /// weiss niemand, wie er laeuft.
    ///
    /// 0    Titel        42 54   Angaben      20 92   Beschreibung 66   (drei
    /// Zeilen) 182  Knopfreihe   48 230  Ende
    private var held: some View {
        ZStack(alignment: .topLeading) {
            // Das Querbild steht am Treffer, nicht am Detail — Seerr liefert
            // es schon in der Suche mit. Faellt es aus, bleibt die Flaeche
            // leer statt ein hochgezogenes Plakat zu zeigen.
            Kulisse(url: treffer.kulisse(breite: 1280),
                    hoehe: Stil.heldHoehe * 1.62)

            block
                .padding(.leading, Stil.randAbstand)
                .padding(.top, Stil.titelHoehe + 98)
        }
        .frame(height: Stil.heldHoehe, alignment: .topLeading)
    }

    private var block: some View {
        ZStack(alignment: .topLeading) {
            // **Der Titel kommt von TMDB und ist kein Schluessel.**
            Text(verbatim: treffer.titel)
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(width: 640, height: 42, alignment: .leading)
                .offset(y: 0)

            angabenReihe
                .frame(width: 640, height: 20, alignment: .leading)
                .clipped()
                .offset(y: 54)

            Text(verbatim: detail?.beschreibung ?? "")
                .font(Stil.koerper)
                .lineSpacing(3)
                .foregroundStyle(Stil.schrift.opacity(0.62))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(width: 640, height: 66, alignment: .topLeading)
                .clipped()
                .offset(y: 92)

            handlung
                .frame(height: Stil.hauptknopfHoehe, alignment: .leading)
                .offset(y: 182)
        }
        .frame(width: 640, height: 230, alignment: .topLeading)
    }

    /// Jahr, Staffeln oder Laufzeit, Genres, Bewertung — **eine Zeile**,
    /// nicht zwei. Sie stand hier auf zwei verteilt, mit dem Stand darunter;
    /// die echte Seite setzt alles nebeneinander, und dahinter kommt der
    /// Beleg. Hier ist der Beleg der Stand.
    private var angabenReihe: some View {
        HStack(spacing: 14) {
            Text(verbatim: nebenzeile)
                .font(.system(size: 14))
                .foregroundStyle(Stil.schriftLeise)
            if let bewertung = detail?.bewertung {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill").font(.system(size: 10))
                    // `String(format:)` wie nebenan — die echte Seite zeigt
                    // „8.4", hier stand „8,4". Zwei Schreibweisen derselben
                    // Zahl auf zwei Seiten.
                    Text(verbatim: String(format: "%.1f", bewertung))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Stil.schriftLeise)
            }
            HStack(spacing: 6) {
                Image(systemName: stand.symbol)
                    .font(.system(size: 11, weight: .heavy))
                Text(stand.wort)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(stand.farbe)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

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

    /// Symbol, Wort, Stern — dieselbe Zeile wie auf einer echten Seite, nur
    /// mit dem Stand statt „Direct Play": über einen Titel, den es hier nicht
    /// gibt, weiss niemand, wie er läuft.
    private var belegzeile: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: stand.symbol).font(.system(size: 12, weight: .heavy))
                Text(verbatim: stand.wort).font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(stand.farbe)

            if let b = detail?.bewertung, b > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill").font(.system(size: 12))
                    Text(verbatim: String(format: "%.1f", b)
                            .replacingOccurrences(of: ".", with: ","))
                        .font(.system(size: 14))
                }
                .foregroundStyle(Stil.schrift.opacity(0.8))
            }
        }
    }

    /// **Ein Stand ist keine Schaltfläche.** Was wartet oder lädt, lässt sich
    /// nicht noch einmal anfragen; dort steht eine Auskunft statt eines
    /// grauen Knopfes.
    @ViewBuilder
    private var handlung: some View {
        if angefragt {
            auskunft(String(localized: "Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
        } else if stand.anfragbar {
            // **Nur der Knopf.** Die Staffelliste stand hier daneben, in einem
            // `VStack` — und der steckt in einem Block mit **fester** Hoehe
            // (230, Knopfreihe bei 182). Waechst er, rutscht der Knopf nach
            // oben statt die Liste nach unten. Die Liste haengt jetzt als
            // Tafel an der Seite, wie die Ladetafel.
            HStack(spacing: 12) {
                Hauptknopf(beschriftung: knopftext,
                           symbol: bestaetigt ? "checkmark" : "plus") { gedrueckt() }
                    .frame(maxWidth: 320)
                if let fehler {
                    Text(verbatim: fehler)
                        .font(Stil.zweitzeile).foregroundStyle(Stil.warnung)
                        .lineLimit(2)
                }
            }
        } else {
            auskunft(stand.hinweis)
        }
    }

    private var knopftext: LocalizedStringKey {
        if laeuft { return "Wird angefragt…" }
        if treffer.istSerie {
            guard staffelnOffen else { return "Staffeln wählen" }
            // **Die Zahl steht auf dem Knopf.** Vorher stand dort „Anfragen",
            // und was angefragt wurde, war nicht abzulesen — leer hiess alle.
            return gewaehlt.isEmpty ? "Staffeln wählen"
                                    : "\(gewaehlt.count) Staffeln anfragen"
        }
        return bestaetigt ? "Wirklich anfragen?" : "Anfragen"
    }

    /// **Zwei Stufen, und die zweite ist der eigentliche Auftrag.** Bei einer
    /// Serie übernimmt die Staffelliste die zweite Stufe; ein Film hat nichts
    /// auszuwählen, deshalb fragt dort der Knopf selbst nach.
    private func gedrueckt() {
        guard !laeuft else { return }
        if treffer.istSerie {
            // **Ohne Auswahl passiert nichts.** Vorher hiess leer „alle", und
            // wer nur nachsehen wollte, welche Staffeln es gibt, fragte die
            // ganze Serie an.
            guard staffelnOffen else {
                withAnimation(Stil.zeitSprung) { staffelnOffen = true }
                return
            }
            guard !gewaehlt.isEmpty else { return }
            Task { await anfragen() }
            return
        }
        guard bestaetigt else { bestaetigt = true; return }
        Task { await anfragen() }
    }

    /// **Was schon da ist, lässt sich nicht ankreuzen** — und sagt daneben,
    /// dass es da ist.
    private var staffelliste: some View {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(detail?.staffeln ?? []) { st in
                Button {
                    guard st.stand.anfragbar else { return }
                    if gewaehlt.contains(st.nummer) { gewaehlt.remove(st.nummer) }
                    else { gewaehlt.insert(st.nummer) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: st.stand.anfragbar
                              ? (gewaehlt.contains(st.nummer) ? "checkmark.square.fill" : "square")
                              : "checkmark.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(gewaehlt.contains(st.nummer) ? Stil.akzent
                                                                          : Stil.schriftSehrLeise)
                        Text("Staffel \(st.nummer)")
                            .font(Stil.koerper)
                            .foregroundStyle(st.stand.anfragbar ? Stil.schrift
                                                                : Stil.schriftSehrLeise)
                        if st.folgen > 0 {
                            Text("· \(st.folgen) Folgen")
                                .font(Stil.zweitzeile).foregroundStyle(Stil.schriftSehrLeise)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
          }
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listenhoehe = $0 }
        }
        .scrollIndicators(.never)
        // **Sie schwebt, also traegt sie einen Schatten** — wie die Ladetafel
        // und die Handlungsliste. Vorher lag sie im Fluss, dort war keiner
        // noetig.
        //
        // **Und sie ist so hoch wie ihre Liste, hoechstens aber 380.** Hier
        // stand `maxHeight: 380` allein — eine `ScrollView` nimmt sich
        // senkrecht aber alles, was sie kriegen kann, also stand die Kachel
        // bei sieben Staffeln mit einer handbreit Leere darunter da.
        //
        // Gemessen wird der Inhalt, nicht geschaetzt: eine Staffelzeile ist 38
        // Punkt hoch, aber ob eine Serie sieben oder zwanzig hat, weiss nur
        // der Server. `Der Chef` hat neun, `Perry Mason` neun.
        .frame(maxWidth: 320, alignment: .leading)
        .frame(height: min(max(listenhoehe, 38), 380))
        .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.eckeFlaeche))
        .overlay(RoundedRectangle(cornerRadius: Stil.eckeFlaeche).strokeBorder(Stil.rand))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var besetzung: some View {
        let leute = detail?.besetzung ?? []
        if !leute.isEmpty {
            // **Aufbau von `Besetzungsreihe`, Zeile fuer Zeile.** Der
            // Baustein selbst nimmt `[Person]` vom eigenen Server; hier
            // kommen die Koepfe von TMDB. Alles andere ist gleich: 14 Punkt
            // Abstand, 16 halbfett, dieselbe Blaetterreihe.
            VStack(alignment: .leading, spacing: 14) {
                Text("Besetzung")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Stil.schrift)
                Blätterreihe(rand: 0, breiteJeStueck: 84 + 18, bildHoehe: 84) {
                    ForEach(leute.prefix(12)) { person in
                        Kopfbild(name: person.name, rolle: person.rolle,
                                 bild: person.bild())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var aehnliches: some View {
        let andere = detail?.aehnliches ?? []
        if !andere.isEmpty {
            // Aufbau von `Titelreihe` — dieselbe Ueberschrift, derselbe
            // Abstand, dieselbe Blaetterreihe. Nur die Kachel ist eine
            // andere, weil der Titel hier noch nicht auf dem Server liegt.
            VStack(alignment: .leading, spacing: 14) {
                Text("Ähnliche Titel")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Stil.schrift)
                Blätterreihe(rand: 0) {
                    ForEach(andere) { t in
                        Button { navigator.oeffne(.seerrTitel(t), in: bereich) } label: {
                            Seerrkachel(treffer: t)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func auskunft(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Stil.koerper)
            .foregroundStyle(Stil.schriftLeise)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.vertical, 13).padding(.horizontal, 14)
            .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.eckeFlaeche))
    }

    private func anfragen() async {
        fehler = nil
        laeuft = true
        defer { laeuft = false }
        do {
            // **Nie leer.** `gedrueckt()` laesst es gar nicht so weit
            // kommen; hier steht der Riegel ein zweites Mal, weil `nil` bei
            // Seerr „alle Staffeln" bedeutet und das der Fall ist, den
            // niemand versehentlich ausloesen soll.
            guard !gewaehlt.isEmpty else { return }
            let staffeln = Array(gewaehlt).sorted()
            try await model.seerr.anfragen(treffer, staffeln: staffeln)
            angefragt = true
            stand = .wartetAufFreigabe
        } catch {
            fehler = error.localizedDescription
        }
    }
}
