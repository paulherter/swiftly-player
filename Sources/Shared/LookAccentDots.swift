import JellyfinKit
import SwiftUI

// The accent dots of the looks panel, the same on iPhone, iPad and Mac.

/// **The five accents as dots.** 44 pt targets that overlap a little, so the dots stand
/// 8 pt apart as drawn.
struct AccentDots: View {
    let chosen: LookAccent
    let choose: (LookAccent) -> Void

    var body: some View {
        HStack(spacing: -10) {
            ForEach(LookAccent.all) { accent in
                let isChosen = chosen == accent
                Button {
                    #if os(iOS)
                    UISelectionFeedbackGenerator().selectionChanged()
                    #endif
                    choose(accent)
                } label: {
                    Circle()
                        .fill(accent.mainColor)
                        .frame(width: 22, height: 22)
                        .padding(2)
                        .overlay {
                            Circle().strokeBorder(Theme.font, lineWidth: 1.5)
                                .opacity(isChosen ? 1 : 0)
                        }
                        .animation(Motion.select, value: isChosen)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(Theme.PressButton())
                .accessibilityLabel(Text(accent.name))
                .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

extension LookAccent {
    /// For VoiceOver; the dots carry no text.
    var name: String {
        switch id {
        case LookAccent.violet.id: String(localized: "Violett")
        case LookAccent.coral.id: String(localized: "Koralle")
        case LookAccent.gold.id: String(localized: "Gold")
        case LookAccent.emerald.id: String(localized: "Smaragd")
        default: String(localized: "Türkis")
        }
    }
}
