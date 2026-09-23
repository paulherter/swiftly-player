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
                    // Fließtext aus der Leiter statt einer eigenen Zahl.
                    .font(Stil.koerper)
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
                            // **17 und 52 wie jede andere Zeile in einem
                            // Blatt** — dieselben Werte, die `Handlungsblatt`
                            // und `Auswahlblatt` setzen. Hier standen 15 und
                            // eine feste Hoehe von 50: dieselbe Rolle, ein
                            // paar Punkte daneben, und mit groesserer
                            // Systemschrift haette die feste Hoehe den Text
                            // angeschnitten.
                            //
                            // Der Baustein selbst passt nicht: `Handlungsblatt`
                            // kennt nur Rubrik und Zeilen, hier steht ein
                            // erklaerender Absatz dazwischen. Uebernommen sind
                            // deshalb die Masse, nicht das Gehaeuse.
                            .font(.system(size: 17))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Stil.schrift)
                    .padding(.horizontal, Stil.randAbstand)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckzeile())
                Blattlinie()
                Blattabbruch { offen = false }
            }
    }
}
