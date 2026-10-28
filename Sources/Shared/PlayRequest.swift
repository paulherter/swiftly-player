import Foundation
import JellyfinKit

/// Carries title, plan and start position to the player together.
///
/// Deliberately one object: separate states are read by `fullScreenCover` at
/// presentation time in their old value, so the player started at zero.
/// The same holds for `fullScreenCover` on tvOS.
struct PlayRequest: Identifiable {
    let id = UUID()
    let item: Item
    let plan: PlaybackPlan
    let startAt: Double
    /// **Tracks chosen on the client that sent this title here** (``PlayOrder``);
    /// `nil` for everything started on this device. They apply to this title only,
    /// the next episode follows the device's own rule.
    var tracks: TrackIndices? = nil
}

import SwiftUI

extension PlayRequest {
    /// **The one path from tap to player** for movie and episode, on iPhone and
    /// TV.
    ///
    /// It existed four times, identical except for details: lock, fetch plan,
    /// build request, unlock. Where the copies diverged it was not intentional:
    /// the iPhone series page said nothing when the server had no file, the TV's
    /// did.
    ///
    /// - Parameters:
    /// - ab: the start position; if omitted, the title's remembered one applies.
    /// - frisch: refetch the title first, since the position in the list entry is
    /// often stale.
    /// - sourceID: the version the user picked when a title has several.
    /// - bereitet: blocks a second tap while the plan is in flight.
    /// - fehlt: if the server returns no plan.
    @MainActor
    static func start(_ item: Item, since: Double? = nil, freshValue: Bool = false,
                        sourceID: String? = nil,
                        model: AppModel, prepares: Binding<Bool>,
                        missing: @escaping () -> Void = {},
                        play: @escaping (PlayRequest) -> Void) {
        guard !prepares.wrappedValue else { return }
        prepares.wrappedValue = true
        Task {
            defer { prepares.wrappedValue = false }
            // Side by side: the plan depends only on the id.
            async let freshTitle: Item? = freshValue ? model.item(id: item.id) : nil
            async let planFetch = model.plan(for: item.id, sourceID: sourceID)
            let target = await freshTitle ?? item
            guard let plan = await planFetch else { missing(); return }
            play(PlayRequest(item: target, plan: plan,
                                    startAt: since ?? target.resumeFrom ?? 0))
        }
    }

    /// Incremented per received order: of two orders in quick succession only the
    /// later one opens.
    @MainActor private static var receivedCount = 0

    /// **A title another client sent here** (``RemoteControl/playHear(_:)``): the
    /// same path as a tap on "Play", with position, version and tracks from the
    /// order. Loaded with this account's own user, so only what the receiving user
    /// may see opens.
    ///
    /// **A running player is replaced**, as the Jellyfin web client does, but only
    /// once the new title is known to play: title and plan come first, so an order
    /// that cannot load leaves the film running. Then the player is closed through
    /// its own stop, so its end is reported like any other, and the new one opens
    /// after the old one is completely gone (see ``closeRunning(_:)``).
    @MainActor
    static func received(_ order: PlayOrder, model: AppModel,
                         play: @escaping (PlayRequest) -> Void) async {
        guard let id = order.itemID else { return }
        receivedCount += 1
        let mine = receivedCount
        guard let item = await model.item(id: id) else {
            AppLog.writeOut("[Abspielen auf] Titel \(id) nicht ladbar, Auftrag verworfen")
            return
        }
        start(item, since: order.start, sourceID: order.mediaSourceID,
              model: model, prepares: .constant(false),
              missing: { AppLog.writeOut("[Abspielen auf] keine Datei für \(id), Auftrag verworfen") }) { wish in
            var wish = wish
            wish.tracks = order.tracks
            Task { @MainActor in
                guard mine == receivedCount else {
                    AppLog.writeOut("[Abspielen auf] Auftrag \(id) überholt")
                    return
                }
                guard await closeRunning(model) else {
                    AppLog.writeOut("[Abspielen auf] Player schließt nicht, Auftrag verworfen")
                    return
                }
                guard mine == receivedCount else { return }
                play(wish)
            }
        }
    }

    /// **Stops a running player and waits until it is completely gone**, up to five
    /// seconds; `false` if it did not go. Two players on top of each other would be
    /// worse than a missed order.
    ///
    /// Gone means: the player has unregistered (`remoteCommand`, set in its
    /// `onDisappear`) and, on iPhone and iPad, UIKit has finished dismissing it
    /// (``PlayerFrame/active``, no controller in transition). Presenting the next
    /// one earlier is silently dropped by UIKit.
    @MainActor
    private static func closeRunning(_ model: AppModel) async -> Bool {
        if let running = model.remoteCommand {
            AppLog.writeOut("[Abspielen auf] laufender Player wird ersetzt")
            running(.stop)
        }
        for _ in 0..<50 {
            if model.remoteCommand == nil, presentationQuiet() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return model.remoteCommand == nil && presentationQuiet()
    }

    @MainActor
    private static func presentationQuiet() -> Bool {
        #if os(iOS)
        if PlayerFrame.active != nil { return false }
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.keyWindow?.rootViewController else { return true }
        var controller: UIViewController? = root
        while let c = controller {
            if c.isBeingDismissed || c.isBeingPresented || c.transitionCoordinator != nil { return false }
            controller = c.presentedViewController
        }
        #endif
        return true
    }
}
