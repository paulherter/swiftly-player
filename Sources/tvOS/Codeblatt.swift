import CoreImage.CIFilterBuiltins
import JellyfinKit
import SwiftUI

/// **Bewerten, Discord, Fehler melden — auf dem Fernseher als Code.**
///
/// tvOS hat keinen Browser und keine Bewertungsabfrage. Also steht die
/// Adresse als QR-Code da, den das Telefon abfotografiert, und darunter
/// kurz genug zum Abtippen. Die Adressen kommen aus dem Paket (`Gemeinschaft`).
enum Gemeinschaftsziel: String, Identifiable {
    case bewerten, discord, fehler
    var id: String { rawValue }

    var titel: LocalizedStringKey {
        switch self {
        case .bewerten: "Swiftly bewerten"
        case .discord:  "Swiftly hat einen Discord"
        case .fehler:   "Fehler melden"
        }
    }

    var text: LocalizedStringKey {
        switch self {
        case .bewerten: "Scann den Code mit dem Handy, dann landest du direkt beim Bewerten im App Store."
        case .discord:  "Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst."
        case .fehler:   "Scann den Code mit dem Handy. Deine Fassung steht im Issue schon drin."
        }
    }

    var adresse: URL {
        switch self {
        case .bewerten: Gemeinschaft.appStoreBewertung
        case .discord:  Gemeinschaft.discord
        case .fehler:   Fassung.fehlerMelden
        }
    }

    /// Was unter dem Code steht. Die Bewertungsseite ist zum Abtippen zu
    /// lang — dort reicht der Code.
    var kurz: String? {
        switch self {
        case .bewerten: nil
        case .discord:  Gemeinschaft.discordKurz
        case .fehler:   Gemeinschaft.fehlerKurz
        }
    }
}

struct Codeblatt: View {
    let ziel: Gemeinschaftsziel
    let schliessen: () -> Void

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()
            VStack(spacing: 0) {
                Text(ziel.titel)
                    .font(Stil.titelGross)
                    .foregroundStyle(Stil.schrift)
                Text(ziel.text)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .multilineTextAlignment(.center)
                    .frame(width: 1100)
                    .padding(.top, 16)
                if let bild = Self.code(ziel.adresse) {
                    Image(decorative: bild, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 360, height: 360)
                        // Weisser Rand gehört zum Code: ohne ihn liest
                        // eine Kamera auf dunklem Grund schlecht.
                        .padding(24)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Stil.ecke))
                        .padding(.top, 56)
                        .accessibilityLabel(Text(verbatim: ziel.kurz ?? ziel.adresse.absoluteString))
                }
                if let kurz = ziel.kurz {
                    Text(verbatim: kurz)
                        .font(Stil.koerper)
                        .foregroundStyle(Stil.schrift)
                        .padding(.top, 28)
                }
                Button("Zurück", action: schliessen)
                    .buttonStyle(KnopfStil())
                    .padding(.top, 52)
            }
        }
        .onExitCommand(perform: schliessen)
    }

    /// Der QR-Code als Bild, ein Pixel je Modul — vergrößert wird ohne
    /// Glättung, sonst verschwimmen die Kanten.
    private static func code(_ adresse: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(adresse.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let bild = filter.outputImage else { return nil }
        return CIContext().createCGImage(bild, from: bild.extent)
    }
}
