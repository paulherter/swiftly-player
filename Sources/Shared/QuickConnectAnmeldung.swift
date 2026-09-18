import JellyfinKit
import SwiftUI

/// Anmelden, ohne ein Passwort zu tippen.
///
/// Die Gegenrichtung zu der Quick-Connect-Seite im Profil: dort gibt dieses
/// Gerät einen fremden Code frei, hier lässt es sich selbst freigeben. Der
/// Code ist das Einzige, was zählt — deshalb steht er groß und in einzelnen
/// Feldern, damit man sich beim Abtippen nicht verzählt.
struct QuickConnectAnmeldung: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Der Ablauf steht in `QuickConnectModell` — geteilt mit der
    /// tvOS-Fassung.
    @State private var stand = QuickConnectModell()

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Quick Connect")
                        .font(Stil.titel)
                        .foregroundStyle(Stil.schrift)
                        .padding(.top, 24)

                    Text("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist.")
                        .font(Stil.koerper)
                        .foregroundStyle(Stil.schriftLeise)
                        .lineSpacing(3)
                        .padding(.top, 10)

                    if let vorgang = stand.vorgang {
                        codefelder(vorgang.code)
                        wartezeile
                    } else if let fehler = stand.fehler {
                        Text(fehler)
                            .font(Stil.koerper)
                            .foregroundStyle(Stil.warnung)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        Lader().frame(maxWidth: .infinity).padding(.top, 40)
                    }

                    anleitung
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.top, 96, for: .scrollContent)

            Seitenpfeil { dismiss() }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Neuen Code holen") { Task { await neuStarten() } }
                .buttonStyle(NebenknopfStil())
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .task { await neuStarten() }
        .onDisappear { stand.anhalten() }
        .onChange(of: stand.freigegeben) { _, neu in
            guard let neu else { return }
            dismiss()
            Task { await model.anmeldenMitQuickConnect(neu) }
        }
    }

    /// Einzelne Felder statt einer Zeichenkette: sechs Ziffern am Stück liest
    /// niemand fehlerfrei vom Bildschirm ab.
    private func codefelder(_ code: String) -> some View {
        let zeichen = Array(code)
        return HStack(spacing: 8) {
            ForEach(Array(zeichen.enumerated()), id: \.offset) { paar in
                if paar.offset == zeichen.count / 2 {
                    Color.clear.frame(width: 6)
                }
                Text(String(paar.element))
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Stil.schrift)
                    .frame(width: 46, height: 60)
                    .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Stil.rand) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
    }

    /// Ohne Restzeit weiß niemand, ob überhaupt noch etwas passiert.
    private var wartezeile: some View {
        HStack(spacing: 9) {
            Circle().fill(Stil.akzent).frame(width: 8, height: 8)
            Text("Warte auf Freigabe · noch \(stand.restsekunden / 60):\(String(format: "%02d", stand.restsekunden % 60))")
                .font(.system(size: 14))
                .foregroundStyle(Stil.schriftLeise)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
    }

    private var anleitung: some View {
        VStack(alignment: .leading, spacing: 0) {
            Trennlinie()
            Gruppentitel(text: "So gehts")
            schritt(1, "Jellyfin im Browser öffnen und anmelden")
            schritt(2, "Oben rechts aufs Profil, dann Quick Connect")
            schritt(3, "Code eintippen — hier gehts dann von allein weiter")
        }
        .padding(.top, 38)
    }

    private func schritt(_ zahl: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(zahl)")
                .font(.system(size: 14))
                .foregroundStyle(Stil.schriftSehrLeise)
                .frame(width: 20, alignment: .leading)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Stil.schriftLeise)
                .lineSpacing(2)
        }
        .padding(.top, 10)
    }

    // MARK: - Ablauf

    /// Erst zumachen, dann anmelden: die Anmeldung tauscht die ganze
    /// Ansicht aus, und ein Vorhang, der über einer ausgetauschten Ansicht
    /// liegt, blitzt auf.
    private func neuStarten() async {
        await stand.neuStarten(model)
    }
}
