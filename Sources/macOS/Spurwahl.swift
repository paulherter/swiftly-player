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

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !tonspuren.isEmpty {
                Gruppe(titel: "Ton", symbol: "speaker.wave.2") {
                    ForEach(tonspuren, id: \.trackId) { spur in
                        Wahlzeile(text: spur.trackName,
                                  gewaehlt: spur.trackName == gewaehlterTon) {
                            waehleTon(spur)
                        }
                    }
                }
            }

            Gruppe(titel: "Untertitel", symbol: "captions.bubble") {
                Wahlzeile(text: String(localized: "Aus"),
                          gewaehlt: gewaehlterUntertitel == nil) {
                    waehleUntertitel(nil)
                }
                ForEach(untertitel, id: \.trackId) { spur in
                    Wahlzeile(text: spur.trackName,
                              gewaehlt: spur.trackName == gewaehlterUntertitel) {
                        waehleUntertitel(spur)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Spaltentitel(text: "Tempo", symbol: "slider.horizontal.3")
                HStack(spacing: 8) {
                    ForEach(Tempostufen.werte, id: \.self) { wert in
                        Chip(beschriftung: Tempostufen.beschriftung(wert),
                             aktiv: tempo == wert) {
                            tempo = wert
                        }
                    }
                }
            }

            // „Bild" aus der iPhone-Fassung fehlt hier mit Absicht: dort steht
            // die Wahl zwischen fester und freier Ausrichtung, und ein Fenster
            // hat keine Ausrichtung (VERHALTEN.md F).
            VStack(alignment: .leading, spacing: 10) {
                Spaltentitel(text: "Schlafzeit", symbol: "moon")
                HStack(spacing: 8) {
                    Chip(beschriftung: String(localized: "Aus"),
                         aktiv: schlafminuten == nil) { schlafminuten = nil }
                    ForEach(Schlafzeiten.werte, id: \.self) { minuten in
                        Chip(beschriftung: "\(minuten)", aktiv: schlafminuten == minuten) {
                            schlafminuten = minuten
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 320, alignment: .leading)
        .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.eckeFeld))
        .overlay(RoundedRectangle(cornerRadius: Stil.eckeFeld)
            .strokeBorder(Stil.rand, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
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
