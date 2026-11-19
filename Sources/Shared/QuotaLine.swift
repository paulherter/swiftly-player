import SwiftUI

/// The line that tells how much of the weekly limit is left ("Noch 1 von 3 Staffeln frei diese Woche").
///
/// **Quiet text, no box.** It is a statement, like the line under the play button. At the limit it turns
/// to the warning colour with a triangle. The words come from the core; `text == nil` keeps the line's
/// height empty, so the sheet does not jump when the line fills in.
struct QuotaLine: View {
    let text: String?
    var warning = false

    var body: some View {
        HStack(spacing: 6) {
            if warning, text != nil {
                Image(icon: "exclamationmark.triangle", size: 13)
                    .font(.app(size: 13))
                    .accessibilityHidden(true)
            }
            Text(verbatim: text ?? " ")
                .font(Theme.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(warning ? Theme.warning : Theme.fontQuiet)
        .opacity(text == nil ? 0 : 1)
        .animation(Theme.reveal, value: text)
        .accessibilityHidden(text == nil)
    }
}
