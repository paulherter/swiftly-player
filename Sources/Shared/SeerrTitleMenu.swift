import JellyfinKit
import Observation
import SwiftUI
import SwiftlyCore

/// **What Seerr adds to the More menu of a library title** ("Problem melden", "Vom Server löschen") and the two
/// sheets behind those entries. The core decides which entries exist (`SeerrHub.titleMenu()`: rights, the device's
/// delete lock, the words); this resolves the title's TMDB id, opens the sheet and hands the flow on.
///
/// A page holds one of these as `@State`, appends `actions(...)` to its More list and hangs `SeerrTitleMenuSheets`
/// next to its other sheets (always in the tree, like the others, so the first open slides in).
@MainActor
@Observable
final class SeerrTitleMenu {
    var reportOpen = false
    var deleteOpen = false
    let report = SeerrReportFlow()
    let delete = SeerrDeleteFlow()
    /// A short line when an entry could not start (the title has no TMDB id, Seerr does not know it).
    var message: String?

    /// The Seerr entries of the More list, in the core's order and words.
    func actions(model: AppModel, item: Item, seconds: @escaping () -> Double? = { nil }) -> [TitleAction] {
        guard model.seerr.connected else { return [] }
        return model.seerr.hub.titleMenu().map { entry in
            var action = TitleAction(symbol: entry.kind == .reportProblem ? "exclamationmark.bubble" : "trash",
                                     wording: entry.text) { [self] in
                Task { await start(entry.kind, model: model, item: item, seconds: seconds()) }
            }
            action.cautionary = entry.kind == .deleteFromServer
            return action
        }
    }

    /// Opens the report sheet or prepares the delete flow for a library item.
    func start(_ kind: SwiftlyCore.SeerrMenuKind, model: AppModel, item: Item, seconds: Double?) async {
        guard let place = await SeerrPlace.of(item, model: model, seconds: seconds) else {
            message = String(localized: "Dieser Titel hat keine TMDB-Nummer.")
            return
        }
        switch kind {
        case .reportProblem:
            report.start(place)
            reportOpen = true
        case .deleteFromServer:
            let size = SeerrSize.text(item.mediaSources?.first?.size)
            if await delete.prepare(place, standardSize: size, model: model) {
                deleteOpen = true
            } else {
                message = String(localized: "Seerr kennt diesen Titel nicht.")
            }
        }
    }
}

/// The two sheets of ``SeerrTitleMenu``.
struct SeerrTitleMenuSheets: View {
    let menu: SeerrTitleMenu
    let model: AppModel
    /// The title is gone from the server: the page goes back.
    let deleted: () -> Void

    var body: some View {
        @Bindable var bound = menu
        ZStack {
            ReportIssueSheet(opened: $bound.reportOpen, flow: menu.report, model: model)
            DeleteFlowSheet(opened: $bound.deleteOpen, flow: menu.delete, finished: deleted)
        }
        .zIndex(20)
    }
}
