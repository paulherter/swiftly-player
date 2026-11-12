import Foundation

/// The focus-based "move mode" of the Home row list on Apple TV (and the keyboard path on the Mac) as ONE
/// explicit state machine: all transitions are in `reduce`, illegal events leave the state as it is.
///
/// Idle -> `enter(row)` -> Moving; Moving -> `up`/`down` shifts the row among the visible rows;
/// `commit` keeps the new order, `cancel` restores the order from when the mode was entered.
public struct HomeRowMoveMode: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// `row` is being moved; `original` is the order to restore on cancel.
        case moving(row: String, original: [String])
    }

    public enum Event: Equatable, Sendable {
        case enter(row: String)
        case up, down, commit, cancel
    }

    public private(set) var state: State = .idle
    /// The whole combined order, live while moving.
    public private(set) var order: [String]
    /// The rows shown right now (the ones that fit; hidden rows keep their place).
    public var visible: [String]

    public init(order: [String], visible: [String]) {
        self.order = order
        self.visible = visible
    }

    public var movingRow: String? {
        if case .moving(let row, _) = state { return row }
        return nil
    }

    /// What the host stores when `commit` ends the mode; `nil` for every other event.
    @discardableResult
    public mutating func reduce(_ event: Event) -> [String]? {
        switch (state, event) {
        case (.idle, .enter(let row)):
            guard visible.contains(row) else { return nil }
            state = .moving(row: row, original: order)
        case (.moving(let row, _), .up):
            order = HomeRowOrder.moved(order, row: row, by: -1, among: visible)
        case (.moving(let row, _), .down):
            order = HomeRowOrder.moved(order, row: row, by: 1, among: visible)
        case (.moving, .commit):
            state = .idle
            return order
        case (.moving(_, let original), .cancel):
            order = original
            state = .idle
        default:
            break // illegal here: up/down/commit/cancel when idle, enter while moving
        }
        return nil
    }
}
