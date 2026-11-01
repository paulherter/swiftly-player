import JellyfinKit
import SwiftUI

/// **First start: the picker, then the page of the chosen kind.** The remote's version of the
/// iPhone's `FirstStartView`; the Menu button on a kind's page is one step back to the picker.
struct TVFirstStartView: View {
    let model: AppModel

    @State private var chosen: ServerKind?
    /// An address another page already knows (Emby found a Jellyfin there).
    @State private var carried: String?

    var body: some View {
        switch chosen {
        case nil:
            TVServerKindPicker(purpose: .firstStart) { chosen = $0 }
        case .jellyfin:
            ServerView(model: model, presetAddress: carried,
                       back: { carried = nil; chosen = nil })
        case .emby:
            TVEmbyFlowPage(app: model, finished: {}, back: { chosen = nil },
                           useJellyfin: { carried = $0; chosen = .jellyfin })
        case .plex:
            TVPlexFlowPage(app: model, finished: {}, back: { chosen = nil })
        }
    }
}

/// **"Server hinzufügen" from the profile, and the plus on an account of a known server.**
/// Without `route.kind` the picker comes first; with it (a second account on a known server)
/// the page goes straight to that kind's sign-in. `close` leaves the whole flow.
struct TVAddServerFlow: View {
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
            TVServerKindPicker(purpose: .addServer, pick: { chosen = $0 }, back: close)
        case .jellyfin:
            ServerOnboardingView(model: model, close: close, preset: route.preset ?? carried,
                                 kindPicked: true, back: back)
        case .emby:
            TVEmbyFlowPage(app: model, address: route.preset?.absoluteString,
                           finished: close, back: back,
                           useJellyfin: { carried = URL(string: $0); chosen = .jellyfin })
        case .plex:
            TVPlexFlowPage(app: model, finished: close, back: back)
        }
    }
}

/// The Emby sign-in with its model, made when the page appears (the model needs the app).
struct TVEmbyFlowPage: View {
    let app: AppModel
    var address: String?
    let finished: () -> Void
    let back: () -> Void
    var useJellyfin: ((String) -> Void)?
    @State private var page: EmbySignInModel?

    var body: some View {
        ZStack {
            if let page { TVEmbySignInView(model: page) } else { Theme.reason.ignoresSafeArea() }
        }
        .onAppear {
            guard page == nil else { return }
            page = app.embySignInModel(address: address, finished: finished, back: back,
                                       useJellyfin: useJellyfin)
        }
    }
}

/// The Plex sign-in with its model.
struct TVPlexFlowPage: View {
    let app: AppModel
    let finished: () -> Void
    let back: () -> Void
    @State private var page: PlexSignInModel?

    var body: some View {
        ZStack {
            if let page { TVPlexSignInView(model: page) } else { Theme.reason.ignoresSafeArea() }
        }
        .onAppear {
            guard page == nil else { return }
            page = app.plexSignInModel(finished: finished, back: back)
        }
    }
}

/// A route is its own identity, so it can drive `fullScreenCover(item:)` on the profile page.
extension ServerRoute: Identifiable {
    var id: Self { self }
}
