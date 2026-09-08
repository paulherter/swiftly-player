import JellyfinKit
import SwiftUI
import VLCKit

/// Tonspur, Untertitel und Tempo im laufenden Film.
///
/// **Ebene über dem Bild, die Wiedergabe läuft weiter, der Wechsel greift
/// sofort** — wörtlich die Regel der iPhone-Fassung. Auf dem iPhone ist es ein
/// Blatt von unten; hier klappt die Tafel über dem Knopf auf, aus dem der
/// Grundsatz „Auswahl bleibt am Ort" folgt: kleine Entscheidungen erscheinen
/// dort, wo sie ausgelöst wurden.
///
/// Kein `Picker`, kein `Menu` — dieselbe Regel wie überall.
struct Spurwahl: View {
    let tonspuren: [VLCMediaPlayer.Track]
    let untertitel: [VLCMediaPlayer.Track]
    let gewaehlterTon: String?
    let gewaehlterUntertitel: String?
    @Binding var tempo: Float
    /// `nil` heißt aus. Werte aus `Schlafzeiten` (VERHALTEN.md B10).
    @Binding var schlafminuten: Int?

    let waehleTon: (VLCMediaPlayer.Track) -> Void
    let waehleUntertitel: (VLCMediaPlayer.Track?) -> Void

    /// Wie hoch der Inhalt tatsaechlich waere.
    @State private var inhaltshoehe: CGFloat = 0
    @AppStorage("technikschild") private var technikschild = false
    @AppStorage("bildfuellend") private var bildfuellend = false
    let bildfuellendSetzen: (Bool) -> Void

    /// **Links waehlen, rechts sehen.**
    ///
    /// Vorher stand alles gleichzeitig ausgeklappt untereinander -- jede
    /// Tonspur, jeder Untertitel, Tempo, Schlafzeit, Technik. Bei einer Datei
    /// mit acht Spuren ist das eine Rolle, in der man den eingestellten Stand
    /// suchen muss. Jetzt traegt die Leiste links den aktuellen Wert, und
    /// rechts steht nur, was zu ihr gehoert.
    enum Bereich: String, CaseIterable, Identifiable {
        case ton, untertitel, bildformat, tempo, schlafzeit
        var id: String { rawValue }
        var name: LocalizedStringKey {
            switch self {
            case .ton:        "Ton"
            case .untertitel: "Untertitel"
            case .bildformat: "Bildformat"
            case .tempo:      "Tempo"
            case .schlafzeit: "Schlafzeit"
            }
        }
        /// **Mit `return`, obwohl es ohne ginge.** Der Katalogpruefer sucht
        /// unter anderem nach `titel: "..."` -- und `case .untertitel:`
        /// endet genau darauf. Ohne das Wort dazwischen haelt er den
        /// Symbolnamen fuer einen Text, der uebersetzt gehoert.
        var symbol: String {
            switch self {
            case .ton:        return "speaker.wave.2"
            case .untertitel: return "captions.bubble"
            case .bildformat: return "aspectratio"
            case .tempo:      return "speedometer"
            case .schlafzeit: return "moon"
            }
        }
    }

    @State private var bereich: Bereich = .ton

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leiste
            Stil.linie.frame(width: 1)
            ScrollView {
                auswahl
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height }
                        action: { inhaltshoehe = $0 }
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(bereich)
            .transition(.opacity)
        }
        .frame(width: 660)
        // **Gemessen, nicht `maxHeight`.** Eine `ScrollView` nimmt sich
        // senkrecht alles, was sie kriegen kann; mit `maxHeight` allein
        // stuende die Tafel bei zwei Spuren mit einer handbreit Leere
        // darunter. Dieselbe Falle wie bei der Staffelwahl.
        .frame(height: min(max(inhaltshoehe + 36, 260), 460))
        .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.eckeFeld))
        .clipShape(RoundedRectangle(cornerRadius: Stil.eckeFeld))
        .overlay(RoundedRectangle(cornerRadius: Stil.eckeFeld)
            .strokeBorder(Stil.rand, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
    }

    private var leiste: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Bereich.allCases) { b in
                Button { withAnimation(.easeOut(duration: 0.16)) { bereich = b } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: b.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(Stil.akzent)
                            .frame(width: 18)
                        Text(b.name)
                            .font(.system(size: 14))
                            .foregroundStyle(Stil.schrift)
                        Spacer(minLength: 8)
                        Text(wert(b))
                            .font(.system(size: 13))
                            .foregroundStyle(Stil.schriftLeise)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(bereich == b ? Stil.akzent.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(Stil.linie).padding(.vertical, 8)

            // Der macOS-`Schalter` zeichnet nur, er schaltet nicht -- der
            // Knopf liegt aussen herum. Anders als der geteilte auf iOS.
            Button { technikschild.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(Stil.akzent)
                        .frame(width: 18)
                    Text("Technikschild")
                        .font(.system(size: 14))
                        .foregroundStyle(Stil.schrift)
                    Spacer(minLength: 8)
                    Schalter(an: technikschild)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Stil.grund.opacity(0.5))
    }

    /// Der aktuelle Stand, neben dem Namen -- das ist der ganze Punkt der
    /// Leiste: ein Blick sagt, was eingestellt ist.
    private func wert(_ b: Bereich) -> String {
        switch b {
        case .ton:        gewaehlterTon ?? String(localized: "Keine")
        case .untertitel: gewaehlterUntertitel ?? String(localized: "Aus")
        case .bildformat: String(localized: bildfuellend ? "Formatfüllend" : "Ganzes Bild")
        case .tempo:      Tempostufen.beschriftung(tempo)
        case .schlafzeit: schlafminuten.map { "\($0)" } ?? String(localized: "Aus")
        }
    }

    @ViewBuilder private var auswahl: some View {
        switch bereich {
        case .ton:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tonspuren, id: \.trackId) { spur in
                    Wahlzeile(text: spur.trackName,
                              gewaehlt: spur.trackName == gewaehlterTon) { waehleTon(spur) }
                }
            }
        case .untertitel:
            VStack(alignment: .leading, spacing: 0) {
                Wahlzeile(text: String(localized: "Aus"),
                          gewaehlt: gewaehlterUntertitel == nil) { waehleUntertitel(nil) }
                ForEach(untertitel, id: \.trackId) { spur in
                    Wahlzeile(text: spur.trackName,
                              gewaehlt: spur.trackName == gewaehlterUntertitel) {
                        waehleUntertitel(spur)
                    }
                }
            }
        case .bildformat:
            VStack(alignment: .leading, spacing: 0) {
                Wahlzeile(text: String(localized: "Ganzes Bild"), gewaehlt: !bildfuellend) {
                    bildfuellend = false
                    bildfuellendSetzen(false)
                }
                Wahlzeile(text: String(localized: "Formatfüllend"), gewaehlt: bildfuellend) {
                    bildfuellend = true
                    bildfuellendSetzen(true)
                }
            }
        case .tempo:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Tempostufen.werte, id: \.self) { wert in
                    Wahlzeile(text: Tempostufen.beschriftung(wert),
                              gewaehlt: tempo == wert) { tempo = wert }
                }
            }
        case .schlafzeit:
            VStack(alignment: .leading, spacing: 0) {
                Wahlzeile(text: String(localized: "Aus"),
                          gewaehlt: schlafminuten == nil) { schlafminuten = nil }
                ForEach(Schlafzeiten.werte, id: \.self) { minuten in
                    Wahlzeile(text: "\(minuten)", gewaehlt: schlafminuten == minuten) {
                        schlafminuten = minuten
                    }
                }
            }
        }
    }

}


// MARK: - Bausteine

private struct Gruppe<Inhalt: View>: View {
    let titel: LocalizedStringKey
    let symbol: String
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spaltentitel(text: titel, symbol: symbol)
            VStack(spacing: 0) { inhalt }
        }
    }
}

private struct Spaltentitel: View {
    let text: LocalizedStringKey
    let symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(Stil.rubrik).tracking(0.7).textCase(.uppercase)
        }
        .foregroundStyle(Stil.schriftSehrLeise)
    }
}

private struct Wahlzeile: View {
    let text: String
    let gewaehlt: Bool
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 8) {
                Text(verbatim: text)
                    .font(Stil.koerper)
                    .foregroundStyle(gewaehlt ? Stil.akzent : Stil.schrift)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if gewaehlt {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Stil.akzent)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Stil.zeileHoehe)
            .background(schwebt ? Stil.schrift.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: Stil.ecke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
    }
}
