import Foundation

/// "Watch together" on the Swift side: ONE enum, all transitions in `reduce`. It only reads the core's page
/// (`SyncPlayPage`, whose phase the core decides) and says whether a player is plugged in; it decides nothing
/// about the group itself. Every state has its UI: nothing to offer, the offer, working, in a group, watching.
public enum TogetherState: Equatable, Sendable {
    /// The group's phase as the core reports it (`SyncPlayGroupDetail.phase`).
    public enum Phase: Equatable, Sendable {
        case running, halted, waits, empty

        init(code: String?) {
            switch code {
            case "laeuft": self = .running
            case "angehalten": self = .halted
            case "wartet": self = .waits
            default: self = .empty
            }
        }
    }

    public enum Event: Equatable, Sendable {
        /// A new page from the core.
        case page(SyncPlayPage)
        /// The player opened on a title of the group.
        case playerAttached
        /// The player closed (the core leaves the group).
        case playerDetached
        /// No SyncPlay on this account (other server kind, signed out).
        case unavailable
    }

    /// Nothing to offer: no right, no group.
    case off
    /// A group can be created or joined.
    case idle
    /// Creating or joining is under way.
    case working
    /// In a group, no player open here.
    case inGroup(Phase)
    /// In a group and the player is open.
    case watching(Phase)

    public static func reduce(_ state: TogetherState, _ event: Event) -> TogetherState {
        switch event {
        case .unavailable:
            return .off
        case .page(let page):
            if let group = page.detail.group {
                let phase = Phase(code: group.phase)
                if case .watching = state { return .watching(phase) }
                return .inGroup(phase)
            }
            if page.works { return .working }
            return page.mayCreate || page.mayJoin ? .idle : .off
        case .playerAttached:
            if case .inGroup(let phase) = state { return .watching(phase) }
            return state  // no group: a player alone is not our business
        case .playerDetached:
            if case .watching(let phase) = state { return .inGroup(phase) }
            return state
        }
    }

    public var inGroup: Bool {
        switch self {
        case .inGroup, .watching: true
        default: false
        }
    }

    public var phase: Phase? {
        switch self {
        case .inGroup(let phase), .watching(let phase): phase
        default: nil
        }
    }
}

extension SyncPlayGroupRow: Identifiable {}
