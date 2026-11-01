import JellyfinKit
import SwiftUI

/// **Which server: the first page of the app, and the first page of "Server hinzufügen".**
///
/// Three cards, one per kind: the mark, the name as text, one sentence about what
/// comes next. A tap goes straight on; there is no "Weiter" below, because a choice
/// of three that needs a fourth tap to confirm is a form, and this is a question.
///
/// **No primary button, on purpose.** The page's one filled thing is the set of cards,
/// all equal: none of the three kinds is the recommended one, so none may look like it.
/// The cards sit in `groupsArea` like a settings group, one step quieter than a field,
/// so the white button on the next page is still the loudest thing the person sees.
struct ServerKindPicker: View {
    enum Purpose {
        /// First start: the wordmark and the question, no way back.
        case firstStart
        /// From the profile: the subpage header with its arrow.
        case addServer
    }

    var purpose: Purpose = .firstStart
    /// Kinds that can be chosen. The rest stays visible and says it is coming, so
    /// nobody who runs Emby thinks the app ignores them.
    var available: Set<ServerKind> = Set(ServerKind.allCases)
    /// A kind being prepared after the tap (Plex fetches its code). Its card says so
    /// in words; the others wait.
    var busy: ServerKind?
    let pick: (ServerKind) -> Void
    /// The arrow in `.addServer`.
    var back: () -> Void = {}

    @FocusState private var focus: ServerKind?

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(spacing: 10) {
                        ForEach(ServerKind.pickerOrder, id: \.self) { kind in card(kind) }
                    }
                    .padding(.top, 28)
                }
                .padding(.horizontal, Theme.edgePageWide)
                .padding(.bottom, 40)
                // The same column as sign-in and server: on iPad the cards would otherwise
                // be 1000 points wide and the sentence a single line.
                .frame(maxWidth: Theme.formWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .top, spacing: 0) {
                if purpose == .addServer {
                    SubpageHeader(title: String(localized: "Server hinzufügen"), back: back)
                }
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background { if purpose == .addServer { SwipeBack() } }
        #endif
    }

    @ViewBuilder
    private var header: some View {
        switch purpose {
        case .firstStart:
            VStack(alignment: .leading, spacing: 0) {
                Wordmark(height: 32)
                    // The first thing on screen, at the height where the wordmark stood
                    // over the address field before, minus what the question needs.
                    .padding(.top, 96)
                Text("Was läuft bei dir?")
                    .growing(28, .bold)
                    .tracking(Theme.lockTitle)
                    .foregroundStyle(Theme.font)
                    .padding(.top, 40)
                    .accessibilityAddTraits(.isHeader)
                Text("Weitere Server kannst du später dazunehmen, auch gemischt.")
                    .growing(15)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.top, 8)
            }
        case .addServer:
            Text("Du bleibst bei allen angemeldet und wechselst auf der Profilseite zwischen ihnen.")
                .growing(15)
                .lineSpacing(3)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, 8)
        }
    }

    private func card(_ kind: ServerKind) -> some View {
        let open = available.contains(kind)
        let preparing = busy == kind
        return Button { pick(kind) } label: {
            HStack(spacing: 14) {
                ServerKindMark(kind: kind, size: 34,
                               color: open ? nil : Theme.fontVeryQuiet)
                    .frame(width: 44, height: 44)
                    .breathing(preparing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: kind.shownName)
                        .growing(17, .semibold)
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
                    .growing(15)
                    .lineSpacing(2)
                    .foregroundStyle(open ? Theme.fontQuiet : Theme.fontVeryQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if open {
                    Image(systemName: "chevron.right")
                        // The chevron of a row, as in `ValueRow`: 13 semibold, quiet.
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(KindCardStyle(focused: focus == kind))
        .focused($focus, equals: kind)
        .disabled(!open || busy != nil)
    }
}

/// **The card's states, without a ring.** Pressed: one step lighter and the 0.97 every
/// button has. Focused (keyboard on iPad): `raised`, the "chosen" step; BRAND forbids a
/// focus ring. Disabled: the label goes quiet, the surface stays, so the card does not
/// look broken, only not yet there.
private struct KindCardStyle: ButtonStyle {
    var focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous)
        return configuration.label
            .background(configuration.isPressed ? Theme.pressedArea
                        : focused ? Theme.raised : Theme.groupsArea, in: shape)
            .contentShape(shape)
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
            .scaleEffect(configuration.isPressed && !Theme.motionReduced ? 0.97 : 1)
            .animation(Theme.pressCurve(configuration.isPressed), value: configuration.isPressed)
            .animation(Theme.toggle, value: focused)
    }
}

#Preview("Erster Start") {
    ServerKindPicker { _ in }
}

#Preview("Plex wird vorbereitet") {
    ServerKindPicker(busy: .plex) { _ in }
}

#Preview("Hinzufügen, Emby noch nicht") {
    NavigationStack {
        ServerKindPicker(purpose: .addServer, available: [.jellyfin, .plex]) { _ in }
    }
}
