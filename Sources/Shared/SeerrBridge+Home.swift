import Foundation
import JellyfinKit
import Observation
import SwiftUI
import SwiftlyCore

/// The lists screen of the Seerr connection that is current, one per hub: the Home block, "Meine Anfragen" and the
/// Profile rows each hold their own flow, and every flow asks this for the screen of the connection the app has now.
/// A different connection (account or Seerr switch) gives a new screen, and the flow clears what it kept.
@MainActor
final class SeerrConnectionLists {
    let hub: SwiftlyCore.SeerrHub
    let screen: SwiftlyCore.SeerrListsScreen

    init(model: AppModel) {
        hub = model.seerr.hub
        screen = SwiftlyCore.SeerrListsScreen(hub: hub)
    }

    /// Seerr is connected and its session works (the screens draw nothing at all otherwise).
    static func ready(_ model: AppModel, hub: SwiftlyCore.SeerrHub) async -> Bool {
        guard model.seerr.connected else { return false }
        return await hub.ready()
    }
}

/// **The block above the Home rails.** The core decides everything (banner "<Titel> ist da", the manager's line,
/// the "Angefragt" rail, whether anything shows at all); this keeps the last answer and forwards the X.
///
/// **The room is reserved before the answer.** While Seerr is connected and has not answered, the core's state is
/// `.pending` and carries the shape the last start of this profile had; the block draws that shape blank
/// (``SeerrReserved``), so the rails below stand where they stay. The first frame asks the core for it
/// (``block(_:)``) without a call, from the shape stored per profile. No Seerr connection: no reserve.
@MainActor
@Observable
final class SeerrHomeFlow {
    @ObservationIgnored private var lists: SeerrConnectionLists?

    /// The core's last answer (`.pending` or `.shown`); `nil`: nothing to draw yet or at all.
    private(set) var info: SwiftlyCore.SeerrHomeInfo?
    /// The first answer is in (also "nothing to show"), so the reserve is over.
    private(set) var settled = false

    /// The Start page waits for this block (first start of a profile: nothing remembered, so no room to reserve) up
    /// to the core's budget; `false` once Seerr answered, the budget ran out, or the profile remembers a shape.
    func holdsPage(_ model: AppModel) -> Bool {
        block(model)?.holdsPage ?? false
    }

    /// The core's gate (answer or budget, whichever comes first); when the budget wins, the page shows with the
    /// reserve of the core's first guess and the room closes in one motion if Seerr has nothing.
    private func waitForPageGate(_ current: SeerrConnectionLists) {
        Task { @MainActor in
            guard let released = try? await current.screen.gateHome() else { return }
            guard current === lists, !settled, released.state == .pending else { return }
            withAnimation(Theme.reveal) { info = released }
        }
    }

    /// What the Home draws now: the answer, or before any answer the reserve of the stored shape (computed from the
    /// device's memory, so the very first frame has the final size). `nil`: draw nothing.
    func block(_ model: AppModel) -> SwiftlyCore.SeerrHomeInfo? {
        if let info { return info }
        guard !settled, model.seerr.connected else { return nil }
        return SwiftlyCore.seerrHomePending(memory: Self.remembered(model))
    }

    /// Reads the block again (Home appears, pull to refresh, back from the background). Never throws: an
    /// unanswered call keeps what was there.
    func load(_ model: AppModel) async {
        let current = connection(model)
        if !settled {
            _ = current.screen.beginHome(memory: Self.remembered(model))
            waitForPageGate(current)
            // What the last start showed is there at once (the core's stash); the live read below replaces it.
            if let stale = await current.screen.restoreHomeForApp(), current === lists, !settled {
                set(stale)
            }
        }
        guard await SeerrConnectionLists.ready(model, hub: current.hub) else {
            // Nothing remembered and Seerr not usable: next start does not wait for it.
            if Self.remembered(model).isEmpty { Self.remember("-", model) }
            set(nil)
            return
        }
        let loaded = await current.screen.loadHomeForApp()
        // Start stands: the first Seerr read of this start (account, own requests, admin queue, discover rails) fills
        // the core's stash in the background; the core runs it once at a time and the pages wait for it.
        Task.detached(priority: .background) { [hub = current.hub] in _ = try? await hub.warmUp() }
        guard let next = loaded, current === lists else {
            // A failed read (not a cancelled one) ends the reserve: nothing to show.
            if !Task.isCancelled, current === lists, info?.state != .shown { set(nil) }
            return
        }
        if next.state != .pending {
            Self.remember(next.memory, model)
            SeerrArrival.remember(expanded: next.arrivalsExpanded)
        }
        set(next)
    }

    /// The X or a swipe on a card (open or closed stack): hidden for good (the device keeps the ids). The cards behind
    /// close the gap in the stack's own spring; the last card closes the block.
    func dismissArrival(_ requestId: Int64) {
        guard let lists else { return }
        lists.screen.dismissArrivalForApp(requestId)
        let next = lists.screen.home()
        set(next, animation: ArrivalMotion.spring)
        // The core closes a stack of fewer than two cards: keep the stored state in step.
        SeerrArrival.remember(expanded: next.arrivalsExpanded)
    }

    /// The tap on the stack or "Weniger anzeigen": the core opens or closes it, the cards move with one spring.
    func setArrivalsExpanded(_ on: Bool) {
        guard let lists else { return }
        let next = lists.screen.setArrivalsExpanded(expanded: on)
        withAnimation(ArrivalMotion.spring) { info = next }
        SeerrArrival.remember(expanded: next.arrivalsExpanded)
    }

    private func connection(_ model: AppModel) -> SeerrConnectionLists {
        if let lists, lists.hub === model.seerr.hub { return lists }
        let fresh = SeerrConnectionLists(model: model)
        lists = fresh
        info = nil
        settled = false
        return fresh
    }

    /// `.hidden` and `nil` draw nothing and end the reserve; the rails below close the room in one short motion
    /// when the remembered shape was wrong (it is right from the next start on).
    private func set(_ next: SwiftlyCore.SeerrHomeInfo?, animation: Animation = Theme.reveal) {
        let shown = next.flatMap { $0.state == .hidden ? nil : $0 }
        withAnimation(animation) {
            info = shown
            settled = shown?.state != .pending
        }
    }

    /// The stored shape of this profile's block (per account, device setting).
    private static func remembered(_ model: AppModel) -> String {
        UserDefaults.standard.string(forKey: memoryKey(model)) ?? ""
    }

    private static func remember(_ code: String, _ model: AppModel) {
        UserDefaults.standard.set(code, forKey: memoryKey(model))
    }

    private static func memoryKey(_ model: AppModel) -> String {
        SwiftlyCore.seerrHomeMemoryKey(account: model.session?.accountKey)
    }
}

/// A block that has not answered yet: its blank content keeps the room, but nothing shows, nothing can be touched
/// or focused, and VoiceOver skips it. The answer fades in over the same room (nothing moves).
struct SeerrReserved: ViewModifier {
    let pending: Bool

    func body(content: Content) -> some View {
        content
            .opacity(pending ? 0 : 1)
            .disabled(pending)
            .accessibilityHidden(pending)
            .animation(Theme.reveal, value: pending)
    }
}

/// **"Meine Anfragen".** One load, the filter pills, withdraw; the core's list replaces the records every time.
@MainActor
@Observable
final class SeerrRequestsFlow {
    @ObservationIgnored private var lists: SeerrConnectionLists?

    /// `nil` until the first answer; with Seerr not connected it stays `nil`.
    private(set) var info: SwiftlyCore.SeerrRequestsInfo?
    /// The first load has finished (answer or not), so the page can come in as a whole.
    private(set) var settled = false

    func load(_ model: AppModel) async {
        let current = connection(model)
        // The list of the last visit is there at once (the core's stash); the live read below replaces it.
        if info == nil, model.seerr.connected, let stored = try? await current.screen.restoreRequests(), current === lists {
            info = stored
            settled = true
        }
        guard await SeerrConnectionLists.ready(model, hub: current.hub) else {
            info = nil
            settled = true
            return
        }
        if let next = try? await current.screen.loadRequests(), current === lists { info = next }
        settled = true
    }

    /// A filter pill (the core keeps the choice and returns the list again).
    func select(_ pill: SwiftlyCore.RequestPill) {
        guard let lists else { return }
        info = lists.screen.selectPill(pill: pill)
    }

    /// Takes an own waiting request back; the row leaves the list when Seerr agrees.
    func withdraw(_ id: Int64) async {
        guard let lists else { return }
        let screen = lists.screen
        if let next = try? await screen.withdraw(id: id), lists === self.lists { info = next }
    }

    private func connection(_ model: AppModel) -> SeerrConnectionLists {
        if let lists, lists.hub === model.seerr.hub { return lists }
        let fresh = SeerrConnectionLists(model: model)
        lists = fresh
        info = nil
        settled = false
        return fresh
    }
}

extension SwiftlyCore.SeerrRequestRow: @retroactive Identifiable {}

/// **The Home block reads again when its inputs change.** Seerr signs in after the first rows, so the first read
/// finds no connection and sets nothing: without this the block stayed missing until the next visit. One modifier
/// for every platform's Home (the connection appears or goes, the arrival hint is switched in the settings).
private struct SeerrHomeReload: ViewModifier {
    let flow: SeerrHomeFlow
    let model: AppModel
    @AppStorage(SeerrArrival.hintKey) private var arrivalHint = true
    @AppStorage(SeerrArrival.requestsKey) private var requestsRail = false

    func body(content: Content) -> some View {
        content
            .onChange(of: arrivalHint) { _, _ in Task { await flow.load(model) } }
            .onChange(of: requestsRail) { _, _ in Task { await flow.load(model) } }
            .onChange(of: model.seerr.connected) { _, _ in Task { await flow.load(model) } }
    }
}

extension View {
    func seerrHomeReload(_ flow: SeerrHomeFlow, model: AppModel) -> some View {
        modifier(SeerrHomeReload(flow: flow, model: model))
    }
}
