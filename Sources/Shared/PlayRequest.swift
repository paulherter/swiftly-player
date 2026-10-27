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
}
