import CoreImage.CIFilterBuiltins
import JellyfinKit
import SwiftUI

/// Rate, Discord, report a bug: as a code on TV. tvOS has no browser and no rating prompt, so the address is a QR code to scan with a phone, with a short form below to type. The addresses come from the package (`Community`).
enum CommunityTarget: String, Identifiable {
    case rate = "bewerten", discord, error = "fehler"
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .rate: "Swiftly bewerten"
        case .discord:  "Swiftly hat einen Discord"
        case .error:   "Fehler melden"
        }
    }

    var text: LocalizedStringKey {
        switch self {
        case .rate: "Scann den Code mit dem Handy, dann landest du direkt beim Bewerten im App Store."
        case .discord:  "Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst."
        case .error:   "Scann den Code mit dem Handy. Deine App-Version steht dann schon im Issue."
        }
    }

    var address: URL {
        switch self {
        case .rate: Community.appStoreRating
        case .discord:  Community.discord
        case .error:   Version.errorReport
        }
    }

    /// What stands under the code. The rating page is too long to type, so the code alone is enough there.
    var short: String? {
        switch self {
        case .rate: nil
        case .discord:  Community.discordShort
        case .error:   Community.errorShort
        }
    }
}

struct CodeSheet: View {
    let target: CommunityTarget
    let close: () -> Void

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                Text(target.title)
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)
                Text(target.text)
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
                    .frame(width: 1100)
                    .padding(.top, 16)
                if let image = Self.code(target.address) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 360, height: 360)
                        // The white border belongs to the code; without it a camera reads poorly on a dark ground.
                        .padding(24)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        .padding(.top, 56)
                        .accessibilityLabel(Text(verbatim: target.short ?? target.address.absoluteString))
                }
                if let short = target.short {
                    Text(verbatim: short)
                        .font(Theme.body)
                        .foregroundStyle(Theme.font)
                        .padding(.top, 28)
                }
                Button("Zurück", action: close)
                    .buttonStyle(ThemedButtonStyle())
                    .padding(.top, 52)
            }
        }
        .onExitCommand(perform: close)
    }

    /// The QR code as an image, one pixel per module; scaling up without smoothing, or the edges blur. Also used for the Trakt code (`TraktConnectView`).
    static func code(_ address: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        return CIContext().createCGImage(image, from: image.extent)
    }
}
