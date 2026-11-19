import SwiftUI

/// **"Ablehnen" asks once.** Seerr takes no reason with a decline, so nothing is asked and nothing is promised:
/// the sheet says what the person will see.
struct DeclineSheet: View {
    @Binding var opened: Bool
    let title: String
    let confirm: () -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: $opened) {
                SheetCategory(text: Text("Anfrage ablehnen?"))
                Text(verbatim: title)
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.font)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.edgeSpacing)
                Text("Wer sie gestellt hat, sieht nur „Abgelehnt“.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.edgeSpacing)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                SheetLine()
                Button {
                    opened = false
                    confirm()
                } label: {
                    Text("Ablehnen")
                        .font(.app(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
                }
                .buttonStyle(Theme.PressRow())
                .accessibilityIdentifier("decline-confirm")
                SheetLine()
                SheetCancel { opened = false }
            }
    }
}
