import JellyfinKit
import SwiftUI

/// Anmelden, ohne ein Kennwort zu tippen.
///
/// Auf dem iPhone ist das eine Bequemlichkeit. Auf dem Fernseher ist es der
/// bessere Weg: ein Kennwort mit der Fernbedienung einzutippen heißt, sich
/// Buchstabe für Buchstabe durch ein Raster zu wischen. Der Code steht
/// deshalb groß und in einzelnen Feldern, damit man ihn quer durchs Zimmer
/// ablesen kann.
///
/// Der Ablauf — Code holen, im Zweisekundentakt nachfragen, fünf Minuten
/// Gültigkeit — steht in `QuickConnectModell` und ist mit dem iPhone geteilt.
struct QuickConnectView: View {
    let model: AppModel
    let schliessen: () -> Void

    @State private var stand = QuickConnectModell()

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            VStack(spacing: 0) {
                Text("Quick Connect")
                    .font(Stil.titelGross)
                    .foregroundStyle(Stil.schrift)

                Text("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist.")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .multilineTextAlignment(.center)
                    .frame(width: 1100)
                    .padding(.top, 16)

                if let vorgang = stand.vorgang {
                    codefelder(vorgang.code)
                        .padding(.top, 56)
                    wartezeile
                        .padding(.top, 28)
                } else if let fehler = stand.fehler {
                    Text(fehler)
                        .font(Stil.koerper)
                        .foregroundStyle(Stil.warnung)
                        .multilineTextAlignment(.center)
                        .frame(width: 1100)
                        .padding(.top, 56)
                } else {
                    Lader().padding(.top, 72)
                }

                anleitung.padding(.top, 56)

                HStack(spacing: 24) {
                    Button("Neuer Code") { Task { await stand.neuStarten(model) } }
                        .buttonStyle(KnopfStil())
                    Button("Zurück", action: schliessen)
                        .buttonStyle(KnopfStil())
                }
                .padding(.top, 52)
            }
        }
        .task { await stand.neuStarten(model) }
        .onDisappear { stand.anhalten() }
        .onExitCommand(perform: schliessen)
        .onChange(of: stand.freigegeben) { _, neu in
            guard let neu else { return }
            Task { await model.anmeldenMitQuickConnect(neu) }
        }
    }

    /// Ein Feld je Zeichen. Der Code ist das Einzige, was hier zählt —
    /// getrennt gesetzt verzählt man sich beim Abtippen nicht.
    private func codefelder(_ code: String) -> some View {
        HStack(spacing: 20) {
            ForEach(Array(code.enumerated()), id: \.offset) { paar in
                Text(String(paar.element))
                    .font(.system(size: 92, weight: .bold).monospacedDigit())
                    .foregroundStyle(Stil.schrift)
                    .frame(width: 120, height: 160)
                    .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.ecke))
                    .overlay {
                        RoundedRectangle(cornerRadius: Stil.ecke)
                            .strokeBorder(Stil.rand, lineWidth: 2)
                    }
            }
        }
    }

    private var wartezeile: some View {
        HStack(spacing: 14) {
            Lader(groesse: 30, staerke: 3)
            Text("Läuft ab in \(stand.restsekunden / 60):\(String(format: "%02d", stand.restsekunden % 60))")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
        }
    }

    /// Wortlaut aus der iPhone-Fassung übernommen, damit dieselbe Anleitung
    /// nicht an zwei Stellen anders klingt.
    private var anleitung: some View {
        VStack(alignment: .leading, spacing: 14) {
            Gruppentitel(text: "So gehts")
            schritt(1, "Jellyfin im Browser öffnen und anmelden")
            schritt(2, "Oben rechts aufs Profil, dann Quick Connect")
            schritt(3, "Code eintippen — hier gehts dann von allein weiter")
        }
        .frame(width: 900, alignment: .leading)
    }

    private func schritt(_ zahl: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Text("\(zahl)")
                .foregroundStyle(Stil.schriftSehrLeise)
                .frame(width: 32, alignment: .leading)
            Text(text)
                .foregroundStyle(Stil.schriftLeise)
        }
        .font(Stil.kachel)
    }
}
