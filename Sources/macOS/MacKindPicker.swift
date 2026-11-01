import JellyfinKit
import SwiftUI

/// **Which server: the first page of the app, and the first page of "Server hinzufügen".**
///
/// The Mac's counterpart of the iPhone's `ServerKindPicker`: the same three cards in the
/// same order with the same words (`ServerKind.shownName`, `pitch`), one click goes
/// straight on, no "Weiter" below. What differs is the input:
///
/// - **Hover** lights a card with the same surface every Mac row uses (`hoverArea`).
/// - **Keyboard:** the first card has the focus when the page opens, up and down move
///   between the cards, Return chooses, Escape goes back where there is a way back.
///   Focus is the `raised` step, never a ring (BRAND), the way the iPad shows it.
///
/// At first start the column is centred like the Jellyfin address page next to it;
/// from the profile it is a subpage at the left edge with its arrow.
struct MacKindPicker: View {
    enum Purpose {
        /// First start: the wordmark and the question, no way back.
        case firstStart
        /// From the profile: the subpage header with its arrow.
        case addServer
    }

    var purpose: Purpose = .firstStart
    /// Kinds that can be chosen; the rest stays visible and says it is coming.
    var available: Set<ServerKind> = Set(ServerKind.allCases)
    /// A kind being prepared after the click. Its card says so; the others wait.
    var busy: ServerKind?
    let pick: (ServerKind) -> Void
    /// The arrow in `.addServer`.
    var back: () -> Void = {}

    @FocusState private var focus: ServerKind?

    private var order: [ServerKind] { ServerKind.pickerOrder.filter { available.contains($0) } }

    var body: some View {
        Group {
            switch purpose {
            case .firstStart:
                VStack(spacing: 0) {
                    Wordmark(height: 44)
                    Text("Was läuft bei dir?")
                        .font(Theme.titleLarge)
                        .tracking(Theme.lockTitle)
                        .foregroundStyle(Theme.font)
                        .padding(.top, 40)
                        .accessibilityAddTraits(.isHeader)
                    Text("Weitere Server kannst du später dazunehmen, auch gemischt.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.fontQuiet)
                        .padding(.top, 8)
                    cards.padding(.top, 28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .addServer:
                VStack(alignment: .leading, spacing: 0) {
                    SubpageHeader(title: "Server hinzufügen", back: back)
                    Text("Du bleibst bei allen angemeldet und wechselst auf der Profilseite zwischen ihnen.")
                        .font(Theme.body)
                        .lineSpacing(3)
                        .foregroundStyle(Theme.fontQuiet)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                    cards.padding(.top, 26)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: Theme.formWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.top, Theme.contentTop)
            }
        }
        .onAppear { focus = order.first }
        .onExitCommand { if purpose == .addServer { back() } }
    }

    private var cards: some View {
        VStack(spacing: 10) {
            ForEach(ServerKind.pickerOrder, id: \.self) { kind in card(kind) }
        }
        .frame(width: Theme.formWidth)
    }

    private func card(_ kind: ServerKind) -> some View {
        let open = available.contains(kind)
        return KindCard(kind: kind, open: open, preparing: busy == kind,
                        focused: focus == kind) { pick(kind) }
            .focused($focus, equals: kind)
            .focusable(open && busy == nil)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard open, busy == nil else { return .ignored }
                pick(kind)
                return .handled
            }
            .onKeyPress(.downArrow) { move(from: kind, by: 1) }
            .onKeyPress(.upArrow) { move(from: kind, by: -1) }
            .disabled(!open || busy != nil)
    }

    /// Up and down walk the cards that can be chosen; at the ends nothing happens.
    private func move(from kind: ServerKind, by step: Int) -> KeyPress.Result {
        guard let at = order.firstIndex(of: kind), order.indices.contains(at + step) else { return .handled }
        focus = order[at + step]
        return .handled
    }
}

/// One card: mark, name as text, one sentence, a chevron. Hover and focus change the
/// surface; a disabled card goes quiet but keeps its surface, so it reads as "not yet",
/// not as broken.
private struct KindCard: View {
    let kind: ServerKind
    let open: Bool
    let preparing: Bool
    let focused: Bool
    let pick: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 14) {
                ServerKindMark(kind: kind, size: 34, color: open ? nil : Theme.fontVeryQuiet)
                    .frame(width: 44, height: 44)
                    .breathing(preparing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: kind.shownName)
                        .font(Theme.listTitle)
                        .foregroundStyle(open ? Theme.font : Theme.fontVeryQuiet)
                    Group {
                        if preparing {
                            Text("Einen Moment…")
                        } else if open {
                            Text(kind.pitch)
                        } else {
                            Text("Kommt mit einem der nächsten Updates.")
                        }
                    }
                    .font(Theme.body)
                    .lineSpacing(2)
                    .foregroundStyle(open ? Theme.fontQuiet : Theme.fontVeryQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if open {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? Theme.raised : hovers && open ? Theme.pressedArea : Theme.groupsArea,
                        in: RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .animation(Theme.timeFloat, value: focused)
    }
}
