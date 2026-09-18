import JellyfinKit
import SwiftUI

/// **Einmal je Installation: Swiftly hat einen Discord.**
///
/// Kommt nach dem fünften zu Ende geschauten Titel, wenn der Player zu ist
/// (`Gemeinschaft.anstoss`). Ein Blatt von unten, kein Dialog mitten im
/// Schirm: wegwischen reicht, und danach kommt es nie wieder. Die Zeile
/// in den Einstellungen bleibt.
struct Discordhinweis: View {
    @Binding var offen: Bool
    @Environment(\.openURL) private var oeffnen

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .blatt(offen: $offen) {
                Blattrubrik(text: Text("Swiftly hat einen Discord"))
                Text("Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst.")
                    .font(.system(size: 15))
                    .foregroundStyle(Stil.schriftLeise)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Stil.randAbstand)
                    .padding(.bottom, 8)
                Button {
                    offen = false
                    oeffnen(Gemeinschaft.discord)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 17))
                            .frame(width: 20)
                        Text("Discord beitreten")
                            .font(.system(size: 16))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Stil.schrift)
                    .padding(.horizontal, Stil.randAbstand)
                    .frame(height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Blattlinie()
                Blattabbruch { offen = false }
            }
    }
}
