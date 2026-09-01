import JellyfinKit
import SwiftUI
import VLCKit

/// Die Einstellungen zur laufenden Wiedergabe — hinter dem Knopf oben rechts.
///
/// **Eine Achse statt zwei.** Die Fassung davor war Apples Muster fürs
/// iPhone im Querformat: drei Listen nebeneinander. Am Finger stimmt das, man
/// tippt direkt hin. Auf der Fernbedienung heißt es, erst quer zwischen
/// Spalten zu wandern und dann in jeder senkrecht zu suchen, ohne dass
/// irgendwo steht, welche Spalte was ist.
///
/// Jetzt ist alles links–rechts: eine Reihe Kategorien, darunter eine Reihe
/// Karten. Runter, seitlich, drücken — dieselbe Bewegung wie überall sonst in
/// der App.
///
/// Und das Blatt sitzt im unteren Drittel statt über dem ganzen Schirm: wer
/// die Tonspur wechselt, will nicht das Bild verlieren.
struct Wiedergabeblatt: View {
    let flaeche: VLCPlayerView
    let plan: PlaybackPlan
    let titel: String
    @Binding var offen: Bool
    @Binding var tempo: Float
    @Binding var schlafminuten: Int?

    @State private var kategorie: Kategorie = .untertitel
    /// Eigener Stand statt `isSelected`: VLC zieht die Auswahl erst einen
    /// Takt später nach, und die Anzeige hinge sonst hinterher.
    @State private var untertitelWahl: String??
    @State private var tonWahl: String?
    @FocusState private var amChip: Kategorie?


    enum Kategorie: String, CaseIterable, Identifiable {
        case untertitel, ton, tempo, schlafzeit
        var id: String { rawValue }
        var name: LocalizedStringKey {
            switch self {
            case .untertitel: "Untertitel"
            case .ton:        "Ton"
            case .tempo:      "Tempo"
            case .schlafzeit: "Schlafzeit"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45).ignoresSafeArea()

            LinearGradient(stops: [
                .init(color: Stil.grund.opacity(0), location: 0),
                .init(color: Stil.grund.opacity(0.86), location: 0.22),
                .init(color: Stil.grund, location: 0.46),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 560)
            .ignoresSafeArea(edges: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                Text(titel)
                    .font(Stil.knopf)
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(1)

                HStack(spacing: 16) {
                    ForEach(Kategorie.allCases) { k in
                        Button(k.name) { kategorie = k }
                            .buttonStyle(ChipStil(an: kategorie == k))
                            .focused($amChip, equals: k)
                    }
                }
                .focusSection()
                .padding(.top, 24)

                karten
                    .padding(.top, 34)

                beleg
                    .padding(.top, 34)
            }
            .padding(.horizontal, Stil.randSeite)
            .padding(.bottom, Stil.randOben)
        }
        // **Der Fokus gehoert auf den offenen Abschnitt.**
        //
        // Ohne das nimmt tvOS den letzten Knopf der Reihe: das Blatt zeigte
        // „Untertitel", der Zeiger stand auf „Schlafzeit". Zwei Aussagen an
        // derselben Stelle, und die falsche war die auffaellige.
        .task { amChip = kategorie }
        .onExitCommand { offen = false }
    }

    // MARK: Karten

    @ViewBuilder
    private var karten: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 24) {
                switch kategorie {
                case .untertitel:
                    Wahlkarte(name: String(localized: "Aus"), marke: nil,
                              an: untertitelJetzt == nil) {
                        untertitelWahl = .some(nil)
                        flaeche.waehleUntertitel(nil)
                    }
                    // **Kennung ist `trackId`, nicht die Position.**
                    //
                    // VLC gibt bei jedem Lesen frische `Track`-Objekte
                    // heraus, und nach einer Spurwahl sind die alten tot.
                    // Über die Position gekennzeichnet hält SwiftUI die Zeile
                    // für unverändert, behält den alten Rückruf — und der
                    // greift auf ein totes Objekt zu. Genau daraus wurde
                    // „beide angehakt und kein Weg zurück". Steht so seit
                    // Langem in `PlayerSettings` der iPhone-Fassung.
                    ForEach(flaeche.untertitelspuren, id: \.trackId) { spur in
                        Wahlkarte(name: spur.trackName,
                                  marke: format(spur.trackName),
                                  an: untertitelJetzt == spur.trackName) {
                            untertitelWahl = .some(spur.trackName)
                            flaeche.waehleUntertitel(spur)
                        }
                    }

                case .ton:
                    ForEach(flaeche.tonspuren, id: \.trackId) { spur in
                        Wahlkarte(name: spur.trackName, marke: nil,
                                  an: tonJetzt == spur.trackName) {
                            tonWahl = spur.trackName
                            flaeche.waehleTonspur(spur)
                        }
                    }

                case .tempo:
                    ForEach(Tempostufen.werte, id: \.self) { stufe in
                        Wahlkarte(name: Tempostufen.beschriftung(stufe), marke: nil,
                                  an: abs(tempo - stufe) < 0.01) {
                            tempo = stufe
                            flaeche.tempo = stufe
                        }
                    }

                case .schlafzeit:
                    Wahlkarte(name: String(localized: "Aus"), marke: nil,
                              an: schlafminuten == nil) { schlafminuten = nil }
                    ForEach(Schlafzeiten.werte, id: \.self) { minuten in
                        Wahlkarte(name: String(localized: "\(minuten) Minuten"), marke: nil,
                                  an: schlafminuten == minuten) { schlafminuten = minuten }
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .frame(height: 150)
        .focusSection()
    }

    /// Eine Aussage, keine Auswahl — deshalb Fußzeile und keine Spalte.
    /// Nebeneinander mit Auswahllisten sah es aus, als könnte man es drücken.
    private var beleg: some View {
        HStack(spacing: 12) {
            Belegzeile(direktplay: plan.isLossless,
                       hinweis: plan.isLossless ? nil : plan.method.rawValue)
            if let text = dateizeile {
                Text("· " + text)
                    .font(.system(size: 27))
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .lineLimit(1)
            }
        }
    }

    /// Container, Bild und Ton in einer Zeile — Formulierungen aus
    /// `Dateiangaben`, geteilt mit dem iPhone.
    private var dateizeile: String? {
        guard let quelle = plan.quelle else { return nil }
        var teile: [String] = []
        if let behaelter = quelle.container { teile.append(behaelter.uppercased()) }
        if let video = Dateiangaben.videospur(quelle) {
            teile.append(Dateiangaben.video(video, quelle))
        }
        if let ton = Dateiangaben.tonspuren(quelle).first { teile.append(ton.kurz) }
        return teile.isEmpty ? nil : teile.joined(separator: " · ")
    }

    // MARK: Was gerade gilt

    private var untertitelJetzt: String? {
        if let wahl = untertitelWahl { return wahl }
        return flaeche.gewaehlterUntertitel?.trackName
    }

    private var tonJetzt: String? {
        tonWahl ?? flaeche.gewaehlteTonspur?.trackName
    }

    /// Ausgeschrieben statt gerechnet — eine erste Fassung schnitt Nullen per
    /// Zeichenkette weg und machte aus „0,75" ein „,75".
    /// Das Untertitelformat aus dem Spurnamen ziehen, wenn es dort steht.
    ///
    /// Nicht Zierde: `DeviceProfile` muss jedes Format als `Embed` oder
    /// `External` führen, sonst brennt der Server es ins Bild und
    /// transkodiert. Wer sieht, dass eine Spur PGS ist, versteht auch, warum
    /// ausgerechnet sie den Beleg kippen kann.
    private func format(_ name: String) -> String? {
        let bekannt = ["SRT", "ASS", "SSA", "PGS", "VTT", "SUB", "DVBSUB"]
        let gross = name.uppercased()
        return bekannt.first { gross.contains($0) }
    }
}

/// Eine Karte in der Werte-Reihe.
struct Wahlkarte: View {
    let name: String
    let marke: String?
    let an: Bool
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(name)
                        .font(.system(size: 29, weight: an ? .semibold : .medium))
                        .foregroundStyle(an ? Stil.akzent : Stil.schrift)
                        .lineLimit(1)
                    if let marke {
                        Text(marke)
                            .font(Stil.plakette)
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }
                }
                Spacer(minLength: 0)
                // Der Haken bleibt Akzent, auch wenn die Karte den Fokus hat
                // — Auswahl und Fokus sind zwei verschiedene Aussagen.
                if an {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(Stil.akzent)
                }
            }
            .frame(width: 380, height: 130, alignment: .leading)
            .padding(.horizontal, 26)
        }
        .buttonStyle(KartenStil())
        // Haken und Akzentfarbe sagen, was gewaehlt ist — beides stumm.
        .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
    }
}

/// Fokus auf einer Wahlkarte: die ruhige Fläche, wie bei Zeilen und Chips.
struct KartenStil: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .background(fokus ? Stil.fokusflaeche : Stil.flaeche,
                            in: RoundedRectangle(cornerRadius: Stil.ecke))
                .scaleEffect(fokus ? 1.04 : 1)
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}
