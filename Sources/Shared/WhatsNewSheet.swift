import JellyfinKit
import SwiftUI

/// **"What's new": once after an update, filled from `whatsnew/<version>.json`.**
///
/// Kept plain on purpose, so every future version looks right without touching this view:
/// a small version line, the title, three to five entries, an optional gift card, one main
/// button. The entry symbols are SF Symbols in one size, one weight, monochrome; no tiles,
/// no colors, no illustrations. Values: `Notizen/Supporter/WHATS-NEW-SYSTEM.md`,
/// "Umgesetzt (iOS)".
///
/// Lives in the gift sheet (`GiftFlow`), so it never meets another sheet from below.
/// Included in the iPhone/iPad and Mac targets.
struct WhatsNewSheet: View {
    let entry: WhatsNewEntry
    /// The gift of the entry can still be picked up (in its window, not owned).
    let giftAvailable: Bool
    let icon: Namespace.ID

    private var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
    private var gift: Look? { giftAvailable ? entry.giftLook : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Neu in Version \(entry.version)")
                .giftFont(13, .semibold)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.top, 34)
            Text(verbatim: entry.title.localized(language))
                .giftFont(28, .bold)
                .foregroundStyle(Theme.font)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 20) {
                ForEach(entry.items.indices, id: \.self) { index in
                    row(entry.items[index])
                }
            }
            .padding(.top, 26)

            if let gift {
                HStack(spacing: 14) {
                    LookTile(look: gift, size: 44)
                        .matchedGeometryEffect(id: "gift", in: icon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: gift.name)
                            .giftFont(15, .semibold)
                            .foregroundStyle(Theme.font)
                        Text("Geschenk, bleibt für immer in deiner Sammlung")
                            .giftFont(13)
                            .foregroundStyle(Theme.fontVeryQuiet)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 24)
            }

            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Button(action: primary) { Text(primaryTitle) }
                    .buttonStyle(GiftButton(primary: true))
                if gift != nil {
                    Button { GiftFlow.shared.close() } label: { Text("Nicht jetzt") }
                        .buttonStyle(GiftButton(primary: false))
                }
            }
        }
        .padding(.horizontal, Theme.sheetInset)
        .padding(.bottom, 16)
        .overlay(alignment: .topTrailing) { CloseButton { GiftFlow.shared.close() } }
    }

    /// One entry: the symbol in a fixed 28 pt square, centered on the text block beside it
    /// (the line when there is one, both lines when there are two). `firstTextBaseline`
    /// put the symbol's baseline on the title's and so the symbol above the middle.
    private func row(_ item: WhatsNewEntry.Item) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: item.symbol)
                .font(.system(size: 19, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Theme.fontQuiet)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.title.localized(language))
                    .giftFont(15, .semibold)
                    .foregroundStyle(Theme.font)
                if let detail = item.detail {
                    Text(verbatim: detail.localized(language))
                        .giftFont(13)
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var primaryTitle: LocalizedStringKey {
        // Without the gift (window over, or picked up already) "Grab it" has nothing to do.
        switch gift == nil && entry.primary.label == "grab" ? "continue" : entry.primary.label {
        case "grab": "Hol ihn dir"
        case "try": "Ausprobieren"
        case "tryLook": "Look ausprobieren"
        default: "Verstanden"
        }
    }

    private func primary() {
        let action = entry.primary.action
        if action.hasPrefix("applyLook:"), let gift {
            GiftFlow.shared.grab(gift)
        } else if action == "open:looks" {
            GiftFlow.shared.openLooks()
        } else {
            GiftFlow.shared.close()
        }
    }
}
