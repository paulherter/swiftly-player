import SwiftUI
import SwiftlyCore

/// **Season admin on a Seerr title page: "Ablehnen" / "Freigeben" for a season whose request is waiting.**
///
/// One rule and one call for iPhone, iPad, Mac and Apple TV: who may decide comes from the core
/// (`hub.info().canManageRequests`), which request waits for a season from the season row (`waitingRequest`), and
/// the verb runs through the core's admin screen. The page reads again afterwards so the season shows its new state.
/// Only the buttons differ per platform (a pill under the pointer or finger, a focusable button on the TV).
enum SeasonAdmin {
    /// The waiting request of a season, only for an account that may decide.
    @MainActor
    static func waitingRequest(_ row: SwiftlyCore.SeerrSeasonRowInfo, model: AppModel) -> Int64? {
        model.seerr.hub.info().canManageRequests ? row.waitingRequest : nil
    }

    /// Approves or declines, then reloads the title's flow.
    @MainActor
    static func decide(_ request: Int64, approve: Bool, model: AppModel, flow: SeerrTitleFlow?) async {
        let admin = SwiftlyCore.SeerrAdminScreen(hub: model.seerr.hub)
        if approve { _ = try? await admin.approve(id: request) } else { _ = try? await admin.decline(id: request) }
        await flow?.reload()
    }
}
