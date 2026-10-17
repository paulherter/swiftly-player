import JellyfinKit
import Observation
import SwiftUI

/// **Right-click on a tile: the same menu everywhere**, like the long press on
/// iPhone (`Sources/Shared/TileMenu.swift`): play or resume, for "Weiterschauen"
/// go to the overview, mark watched/unwatched, watch together, and for
/// "Weiterschauen" remove from the row. The actions are the existing ones:
/// `PlayControls.starte`, `AppModel.setWatched`,
/// `AppModel.fromContinueWatchingTake`, `SharedModel.createFor`.
///
/// **Two deviations, both due to mouse and window:**
/// - **No preview.** A context menu on the Mac is an AppKit menu at the pointer;
/// SwiftUI does not show `preview:` there, and the tile stays visible beside it
/// anyway.
/// - **No "Download".** On the Mac the confirmation before a download is a panel
/// at the page's download button (`MacDownloads.swift`); a menu item has no button
/// to attach it to. Downloading goes through the page.
struct TileMenu: ViewModifier {
    let item: Item
    let model: AppModel
    /// The tile is in "Weiterschauen": then "To overview" (a click starts playback
    /// there directly) and "Remove from Weiterschauen" are offered.
    var continueWatching = false
    /// The way to the overview, only for "Weiterschauen"; elsewhere the click itself
    /// is that way.
    var overview: (() -> Void)?
    /// After a watched-state change, so the page catches up.
    var afterwards: (() async -> Void)?
    /// **In the player: only the watched state**, the same rule as on iPhone and TV
    /// (`Sources/Shared/TileMenu.swift`).
    var inPlayer = false

    @Environment(PlayControls.self) private var controls

    /// Movies, series and episodes, the same rule as on iPhone.
    static func carries(_ item: Item) -> Bool {
        ["Movie", "Series", "Episode"].contains(item.type ?? "")
    }

    func body(content: Content) -> some View {
        if Self.carries(item) {
            content.contextMenu { entries }
        } else {
            content
        }
    }

    private var isSeries: Bool { item.type == "Series" }

    @ViewBuilder
    private var entries: some View {
        if !inPlayer {
            Button { play() } label: {
                if !isSeries, item.resumeFrom != nil {
                    Label("Fortsetzen", systemImage: "play.fill")
                } else {
                    Label("Abspielen", systemImage: "play.fill")
                }
            }
        }
        if continueWatching, let overview {
            Button(action: overview) {
                Label("Zur Übersicht", systemImage: "info.circle")
            }
        }
        // **Only the entry that has an effect**, except for series (partly watched) and
        // started titles: an episode that was only skipped through counts as started, and
        // "unwatched" removes it from "Weiterschauen". As on iPhone
        // (`Shared/TileMenu.swift`).
        let isWatched = item.userData?.played ?? false
        let begun = item.resumeFrom != nil
        if isSeries || !isWatched {
            Button { watched(true) } label: {
                Label("Als gesehen markieren", systemImage: "checkmark.circle")
            }
        }
        if isSeries || isWatched || begun {
            Button { watched(false) } label: {
                Label("Als ungesehen markieren", systemImage: "eye.slash")
            }
        }
        if !isSeries, !inPlayer, SharedModel.shared.mayCreate {
            Button { SharedModel.shared.createFor = item } label: {
                Label("Gemeinsam schauen", systemImage: "person.2")
            }
        }
        if continueWatching {
            Button { remove() } label: {
                Label("Aus Weiterschauen entfernen", systemImage: "minus.circle")
            }
        }
    }

    // MARK: Actions

    /// For a series, the episode where you are; `PlayControls.starte` fetches the
    /// position fresh itself.
    private func play() {
        let model = model, item = item, controls = controls
        Task {
            var target = item
            if item.type == "Series" {
                // **Failed is not "nothing left"**, as on iPhone.
                do {
                    guard let state = try await model.stateInSeriesChecked(item) else {
                        TileMessage.shared.text = String(localized: "Danach kommt nichts mehr.")
                        return
                    }
                    target = state
                } catch {
                    TileMessage.shared.text = readableError(error)
                    return
                }
            }
            controls.launch(target)
        }
    }

    private func watched(_ an: Bool) {
        let model = model, item = item, afterwards = afterwards
        Task {
            if let error = await model.setWatched(item, an: an) {
                TileMessage.shared.text = error
                return
            }
            await afterwards?()
        }
    }

    private func remove() {
        let model = model, item = item, afterwards = afterwards
        Task {
            if let error = await model.fromContinueWatchingTake(item) {
                TileMessage.shared.text = error
                return
            }
            await afterwards?()
        }
    }
}

extension View {
    /// The tile menu, see ``TileMenu``.
    func tileMenu(_ item: Item, model: AppModel, continueWatching: Bool = false,
                     overview: (() -> Void)? = nil, inPlayer: Bool = false,
                     afterwards: (() async -> Void)? = nil) -> some View {
        modifier(TileMenu(item: item, model: model, continueWatching: continueWatching,
                             overview: overview, afterwards: afterwards, inPlayer: inPlayer))
    }
}

/// What a tile menu reports when something fails: one for the whole app, shown by
/// `MainView` in the `Hinweisstreifen` at the bottom centre, like any short
/// message on the Mac.
@MainActor
@Observable
final class TileMessage {
    static let shared = TileMessage()
    var text: String?
}

/// The strip for it. A click or four seconds dismisses it, like
/// ``Gemeinsamfehler``.
struct TileMessageStrip: View {
    @State private var message = TileMessage.shared

    var body: some View {
        ZStack {
            if let text = message.text {
                HintStrip(text: text)
                    .contentShape(Capsule())
                    .onTapGesture { message.text = nil }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { message.text = nil }
                    .transition(.opacity)
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, message.text == text else { return }
                        message.text = nil
                    }
            }
        }
        .animation(Theme.reveal, value: message.text)
    }
}
