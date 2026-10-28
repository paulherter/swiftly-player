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
    /// **Tracks chosen on the device that sent this title here** (``PlayOrder``);
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

    /// **A title another device sent here** (``RemoteControl/playHear(_:)``): the
    /// same path as a tap, with position, version and tracks from the order.
    ///
    /// **A running player is replaced**, as the Jellyfin web client does. It is
    /// closed through its own stop, so its end is reported like any other, and the
    /// new title opens once it is gone. If it does not close, nothing opens: two
    /// players on top of each other would be worse than a missed order.
    @MainActor
    static func received(_ order: PlayOrder, model: AppModel,
                         play: @escaping (PlayRequest) -> Void) async {
        guard let id = order.itemID else { return }
        if let running = model.remoteCommand {
            running(.stop)
            for _ in 0..<30 where model.remoteCommand != nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard model.remoteCommand == nil else {
                AppLog.writeOut("[Abspielen auf] Player schließt nicht, Auftrag verworfen")
                return
            }
        }
        guard let item = await model.item(id: id) else {
            PlayOutputs.say(String(localized: "Der Titel vom anderen Gerät ließ sich nicht laden."))
            return
        }
        start(item, since: order.start, sourceID: order.mediaSourceID,
              model: model, prepares: .constant(false),
              missing: {
                  PlayOutputs.say(String(localized: "Der Server hat keine Datei zu diesem Titel."))
              }) { wish in
            var wish = wish
            wish.tracks = order.tracks
            play(wish)
        }
    }
}
