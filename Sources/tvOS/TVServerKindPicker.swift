import JellyfinKit
import SwiftUI

/// **Which server: the first page of the app, and the first page of "Server hinzufügen".**
///
/// The iPhone's `ServerKindPicker` for the remote: three cards in one column (the screen is
/// wide, the remote moves in lines), each with the mark, the name and one sentence. A press
/// goes straight on; there is no "Weiter" below, a choice of three that needs a fourth press
/// to confirm is a form, and this is a question.
///
/// **No primary button, on purpose.** None of the three kinds is the recommended one, so none
/// may look like it. The cards rest on `area` and light up with the calm focus surface of
/// the settings rows; white stays reserved for the action buttons on the pages that follow.
struct TVServerKindPicker: View {
    enum Purpose {
        /// First start: the wordmark and the question, no way back.
        case firstStart
        /// From the profile: title and sentence like "Server hinzufügen" with a way out.
        case addServer
    }

    var purpose: Purpose = .firstStart
    let pick: (ServerKind) -> Void
    /// "Abbrechen" and the Menu button in `.addServer`.
    var back: () -> Void = {}

    @FocusState private var focus: ServerKind?

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(spacing: TVSpec.pickerCardSpacing) {
                    ForEach(ServerKind.pickerOrder, id: \.self) { kind in card(kind) }
                }
                .padding(.top, TVSpec.pickerCardsTop)
                .focusSection()

                if purpose == .addServer {
                    Button("Abbrechen", action: back)
                        .buttonStyle(ThemedButtonStyle())
                        .padding(.top, TVSpec.pickerCancelTop)
                }
            }
            .frame(width: TVSpec.messageWidth, alignment: .leading)
        }
        .defaultFocus($focus, ServerKind.pickerOrder.first)
        .onExitCommand { if purpose == .addServer { back() } }
    }

    @ViewBuilder
    private var header: some View {
        switch purpose {
        case .firstStart:
            VStack(spacing: 0) {
                Wordmark(height: TVSpec.serverWordmark)
                Text("Was läuft bei dir?")
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)
                    .padding(.top, TVSpec.pickerHeadlineTop)
                Text("Weitere Server kannst du später dazunehmen, auch gemischt.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
                    .padding(.top, TVSpec.pickerSentenceTop)
            }
            .frame(maxWidth: .infinity)
        case .addServer:
            VStack(alignment: .leading, spacing: 0) {
                Text("Server hinzufügen")
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)
                Text("Du bleibst bei allen angemeldet und wechselst auf der Profilseite zwischen ihnen.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.top, TVSpec.pickerSentenceTop)
            }
        }
    }

    private func card(_ kind: ServerKind) -> some View {
        Button { pick(kind) } label: {
            HStack(spacing: TVSpec.pickerCardGap) {
                ServerKindMark(kind: kind, size: TVSpec.pickerCardMark)
                    .frame(width: TVSpec.pickerCardMarkBox, height: TVSpec.pickerCardMarkBox)
                VStack(alignment: .leading, spacing: TVSpec.pickerCardTextSpacing) {
                    Text(verbatim: kind.shownName)
                        .font(Theme.button)
                        .foregroundStyle(Theme.font)
                    Text(kind.pitch)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(icon: "chevron.right")
                    .font(.app(size: TVSpec.valueIcon, weight: .semibold))
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, TVSpec.pickerCardInsetHorizontal)
            .padding(.vertical, TVSpec.pickerCardInsetVertical)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(TVKindCardStyle())
        .focused($focus, equals: kind)
    }
}

/// **A kind's card**: `area` at rest, the calm focus surface on top while the remote is on
/// it, and the wide step of the focus magnifier (the card is wider than 500). Never white
/// and never the accent, as the settings rows.
struct TVKindCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focus
        @Environment(\.isEnabled) private var released

        var body: some View {
            configuration.label
                .background {
                    ZStack {
                        Theme.area
                        Theme.focusArea.opacity(focus ? 1 : 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                }
                .opacity(released ? 1 : TVSpec.pickerDimWaitingOpacity)
                .scaleEffect(configuration.isPressed ? TVSpec.pressScale
                             : (focus ? Theme.focusMagnifierWide : 1))
                .animation(Theme.focusAnimation, value: focus)
                .animation(Theme.pressCurve(configuration.isPressed), value: configuration.isPressed)
        }
    }
}
