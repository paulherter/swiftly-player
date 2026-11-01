import JellyfinKit
import SwiftUI

// **Which kind, then its sign-in: the Mac's pages that tie the picker to the three flows.**
//
// The iPhone's `FirstStartView` and `AddServerFlow` in `Sources/Shared/ServerFlows.swift`,
// with the Mac's pages inside. The switch is the same: state instead of a stack of pushes,
// the arrow of a flow goes back to the picker, the picker's own arrow leaves the whole
// thing, and a flow that signs an account in calls `finished`.

/// The column every Mac sign-in page stands in: the header with its arrow, then the
/// content in a form-wide column that scrolls when the window is low.
///
/// **Escape is the arrow.** A window has no swipe back, so the keyboard gets the same way
/// as the mouse. At first start the column is centred (there is no sidebar yet and a
/// column at the far left of an empty window looks lost); from the profile it sits at the
/// left edge like every other subpage.
struct MacFlowPage<Content: View>: View {
    let title: String
    let back: () -> Void
    var centered = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubpageHeader(name: title, back: back)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 40)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: Theme.formWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .padding(.horizontal, Theme.edgeSpacing)
        .padding(.top, Theme.contentTop)
        .frame(maxHeight: .infinity, alignment: .top)
        // Window-wide, not tied to a focused field: the first step of a flow may have
        // nothing focused yet, and Escape should still work.
        .background {
            Button(action: back) { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut(.cancelAction)
                .accessibilityHidden(true)
        }
    }
}

/// The first page of the app, before any server is known.
struct MacFirstStart: View {
    let model: AppModel
    @State private var chosen: ServerKind?
    /// An address Emby recognised as Jellyfin: the Jellyfin page starts with it.
    @State private var carried: String?

    var body: some View {
        switch chosen {
        case nil:
            MacKindPicker(purpose: .firstStart) { chosen = $0 }
        case .jellyfin:
            ServerView(model: model, back: { leaveJellyfin() }, presetAddress: carried)
        case .emby:
            MacEmbyFlowPage(app: model, centered: true, finished: {}, back: { chosen = nil },
                            useJellyfin: { carried = $0; chosen = .jellyfin })
        case .plex:
            MacPlexFlowPage(app: model, centered: true, finished: {}, back: { chosen = nil })
        }
    }

    private func leaveJellyfin() {
        carried = nil
        model.errorMessage = nil
        chosen = nil
    }
}

/// "Server hinzufügen" and the plus on a card. Without `route.kind` the picker comes
/// first; with it (a second account on a known server) the page goes straight to that
/// kind's sign-in. `close` leaves the page like every other Mac subpage.
struct MacAddServerFlow: View {
    let model: AppModel
    let route: ServerRoute
    let close: () -> Void

    @State private var chosen: ServerKind?
    @State private var carried: URL?

    private var kind: ServerKind? { route.kind ?? chosen }
    /// The arrow of a flow: back to the picker, or out when there was no picker.
    private func back() { if route.kind == nil { carried = nil; chosen = nil } else { close() } }

    var body: some View {
        switch kind {
        case nil:
            MacKindPicker(purpose: .addServer, pick: { chosen = $0 }, back: close)
        case .jellyfin:
            ServerOnboardingView(model: model, preset: route.preset ?? carried,
                                 kindPicked: route.kind == nil, back: back)
        case .emby:
            MacEmbyFlowPage(app: model, address: route.preset?.absoluteString,
                            finished: close, back: back,
                            useJellyfin: { carried = URL(string: $0); chosen = .jellyfin })
        case .plex:
            MacPlexFlowPage(app: model, finished: close, back: back)
        }
    }
}

/// The Emby sign-in with its model, made when the page appears (the model needs the app).
struct MacEmbyFlowPage: View {
    let app: AppModel
    var address: String?
    var centered = false
    let finished: () -> Void
    let back: () -> Void
    var useJellyfin: ((String) -> Void)?
    @State private var page: EmbySignInModel?

    var body: some View {
        ZStack {
            if let page { MacEmbySignIn(model: page, centered: centered) }
        }
        .onAppear {
            guard page == nil else { return }
            page = app.embySignInModel(address: address, finished: finished, back: back,
                                       useJellyfin: useJellyfin)
        }
    }
}

/// The Plex sign-in with its model.
struct MacPlexFlowPage: View {
    let app: AppModel
    var centered = false
    let finished: () -> Void
    let back: () -> Void
    @State private var page: PlexSignInModel?

    var body: some View {
        ZStack {
            if let page { MacPlexSignIn(model: page, centered: centered) }
        }
        .onAppear {
            guard page == nil else { return }
            page = app.plexSignInModel(finished: finished, back: back)
        }
    }
}

// MARK: - Choices

extension View {
    /// What a choice that is not a row needs on the Mac: the surface every row lights on
    /// hover (`Theme.hoverArea`), the same surface for keyboard focus (never a ring), and
    /// Return or Space choosing it. For a person's circle, a server, a Plex profile.
    func choiceSurface(corner: CGFloat = Theme.corner,
                       activate: @escaping () -> Void) -> some View {
        modifier(ChoiceSurface(corner: corner, activate: activate))
    }
}

private struct ChoiceSurface: ViewModifier {
    let corner: CGFloat
    let activate: () -> Void
    @State private var hovers = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .background(Theme.hoverArea.opacity(hovers || focused ? 1 : 0),
                        in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .onHover { hovers = $0 }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.return) { activate(); return .handled }
            .onKeyPress(.space) { activate(); return .handled }
            .animation(Theme.timeFloat, value: hovers)
            .animation(Theme.timeFloat, value: focused)
    }
}
