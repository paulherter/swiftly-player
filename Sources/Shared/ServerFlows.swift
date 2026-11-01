import JellyfinKit
import SwiftUI

// **Which kind, then its sign-in: the pages that tie the picker to the three flows.**
//
// The picker and the flows are finished views; this is only the switch between them.
// State instead of a stack of pushes: the arrow of a flow goes back to the picker, and
// the picker's own arrow (in "Server hinzufügen") leaves the whole thing. A flow that
// signs an account in calls `finished`, which leaves the page where it started.

/// The first page of the app, before any server is known.
struct FirstStartView: View {
    let model: AppModel
    @State private var chosen: ServerKind?
    /// An address Emby recognised as Jellyfin: the Jellyfin page starts with it.
    @State private var carried: String?

    var body: some View {
        switch chosen {
        case nil:
            ServerKindPicker(purpose: .firstStart) { chosen = $0 }
        case .jellyfin:
            ConnectView(model: model, back: { carried = nil; chosen = nil }, presetAddress: carried)
        case .emby:
            EmbyFlowPage(app: model, finished: {}, back: { chosen = nil },
                         useJellyfin: { carried = $0; chosen = .jellyfin })
        case .plex:
            PlexFlowPage(app: model, finished: {}, back: { chosen = nil })
        }
    }
}

/// "Server hinzufügen" and the plus on a card. Without `route.kind` the picker comes
/// first; with it (a second account on a known server) the page goes straight to that
/// kind's sign-in.
struct AddServerFlow: View {
    let model: AppModel
    let route: ServerRoute

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: ServerKind?
    @State private var carried: URL?

    private var kind: ServerKind? { route.kind ?? chosen }
    /// The arrow of a flow: back to the picker, or out when there was no picker.
    private func back() { if route.kind == nil { carried = nil; chosen = nil } else { dismiss() } }

    var body: some View {
        switch kind {
        case nil:
            ServerKindPicker(purpose: .addServer, pick: { chosen = $0 }, back: { dismiss() })
        case .jellyfin:
            ServerOnboardingView(model: model, preset: route.preset ?? carried,
                                 done: { dismiss() }, kindPicked: true, back: { back() })
        case .emby:
            EmbyFlowPage(app: model, address: route.preset?.absoluteString,
                         finished: { dismiss() }, back: { back() },
                         useJellyfin: { carried = URL(string: $0); chosen = .jellyfin })
        case .plex:
            PlexFlowPage(app: model, finished: { dismiss() }, back: { back() })
        }
    }
}

/// The Emby sign-in with its model, made when the page appears (the model needs the app).
struct EmbyFlowPage: View {
    let app: AppModel
    var address: String?
    let finished: () -> Void
    let back: () -> Void
    var useJellyfin: ((String) -> Void)?
    @State private var page: EmbySignInModel?

    var body: some View {
        ZStack {
            if let page { EmbySignInView(model: page) } else { Theme.reason.ignoresSafeArea() }
        }
        .onAppear {
            guard page == nil else { return }
            page = app.embySignInModel(address: address, finished: finished, back: back,
                                       useJellyfin: useJellyfin)
        }
    }
}

/// The Plex sign-in with its model.
struct PlexFlowPage: View {
    let app: AppModel
    let finished: () -> Void
    let back: () -> Void
    @State private var page: PlexSignInModel?

    var body: some View {
        ZStack {
            if let page { PlexSignInView(model: page) } else { Theme.reason.ignoresSafeArea() }
        }
        .onAppear {
            guard page == nil else { return }
            page = app.plexSignInModel(finished: finished, back: back)
        }
    }
}
