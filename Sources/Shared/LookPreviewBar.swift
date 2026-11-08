import SwiftUI

#if os(iOS)
extension GiftFlow {
    /// A look that may not be worn is being tried: the home page shows it in full and a
    /// slim bar replaces the panel.
    var showsPreviewBar: Bool { looksOpen && LookStore.shared.isPreviewing }
}

/// **"Try a look": a slim bar over the tab bar.** Icon, name, "Preview", and "Unlock". The
/// chevrons on both sides of the name (and a swipe on the bar) switch to the previous and
/// next look. A look that may be worn brings the panel back.
struct LookPreviewBar: View {
    private var store: LookStore { .shared }

    var body: some View {
        let look = store.selection.look
        HStack(spacing: 0) {
            chevron("chevron.left", label: Text("Voriger Look")) { move(-1) }
            LookTile(look: look, size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(look.name)
                    .growing(15, .semibold)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("Vorschau")
                    .growing(12)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .lineLimit(1)
            }
            .padding(.leading, 8)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            chevron("chevron.right", label: Text("Nächster Look")) { move(1) }
            Button { SupportFlow.shared.keep() } label: { Text("Freischalten") }
                .buttonStyle(PlayButtonStyle(compact: true))
                .fixedSize()
                .padding(.leading, 2)
        }
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .frame(height: 60)
        .background(Color(white: 0.118).opacity(0.96), in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.font.opacity(0.12), lineWidth: 1) }
        .padding(.horizontal, 20)
        // Above the tab bar.
        .padding(.bottom, Theme.stripHeight + 12)
        .contentShape(Capsule())
        .highPriorityGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    move(value.translation.width < 0 ? 1 : -1)
                })
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Nächster Look")) { move(1) }
        .accessibilityAction(named: Text("Voriger Look")) { move(-1) }
        .tint(Theme.accent)
    }

    private func chevron(_ icon: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon: icon, size: 13)
                .font(.app(size: 13, weight: .bold))
                .foregroundStyle(Theme.fontQuiet)
                .frame(width: 30, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(label)
    }

    /// The look `step` places along the picker, round the end; gifts not picked up are skipped.
    private func move(_ step: Int) {
        let looks = store.pickerLooks().filter { !($0.isGift && !store.owned.contains($0.id)) }
        guard looks.count > 1,
              let index = looks.firstIndex(of: store.selection.look) else { return }
        let next = looks[(index + step + looks.count) % looks.count]
        UISelectionFeedbackGenerator().selectionChanged()
        let selection = store.selection.switching(to: next)
        Motion.recolor {
            if store.mayWear(selection) {
                store.endPreview()
                _ = store.choose(selection)
            } else {
                if !store.isPreviewing { store.beginPreview() }
                store.tryOn(selection)
            }
        }
    }
}
#endif
