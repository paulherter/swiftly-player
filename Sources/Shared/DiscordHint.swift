import JellyfinKit
import SwiftUI

/// **Once per install: Swiftly has a Discord.**
///
/// Shown after the fifth finished title, once the player is closed
/// (`Community.kickoff`). A bottom sheet, not a dialog in the middle of
/// the screen: swiping it away is enough and it never comes back. The row
/// in Settings stays.
struct DiscordHint: View {
    @Binding var opened: Bool
    @Environment(\.openURL) private var open

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: $opened) {
                SheetCategory(text: Text("Swiftly hat einen Discord"))
                Text("Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst.")
                    // Body text from the type scale instead of a one-off size.
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.edgeSpacing)
                    .padding(.bottom, 8)
                Button {
                    opened = false
                    open(Community.discord)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 17))
                            .frame(width: 20)
                        Text("Discord beitreten")
                            // **17 and 52 like any other row in a sheet** - the same values `ActionSheet`
                            // and `SelectionSheet` use. It used 15 and a fixed height of 50: same role,
                            // a few points off, and with a larger system font the fixed height would
                            // have clipped the text.
                            //
                            // The component itself does not fit: `ActionSheet` only knows a heading
                            // and rows, while here an explanatory paragraph sits in between. So only
                            // the metrics are reused, not the container.
                            .font(.system(size: 17))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.font)
                    .padding(.horizontal, Theme.edgeSpacing)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressRow())
                SheetLine()
                SheetCancel { opened = false }
            }
    }
}
