import JellyfinKit
import SwiftlyCore

/// **The running order of "Play shuffled" or of a playlist, from the core** (`ShuffleRunModel`).
/// The core owns the order and the walk; the episodes themselves stay here, looked up by id.
struct ShuffleRunCore {
    private let core: ShuffleRunModel
    private let items: [String: Item]

    /// Unplayed episodes mixed first, the played ones after. `nil` for an empty or unreadable list.
    static func mixed(_ list: [Item]) -> ShuffleRunCore? {
        guard let json = LoadSelectionState.json(list),
              let core = try? ShuffleRunModel.mixed(episodesJson: json, seed: nil) else { return nil }
        return ShuffleRunCore(core: core, items: Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    /// The entries of a playlist in their order.
    static func ordered(_ list: [Item]) -> ShuffleRunCore? {
        guard let json = LoadSelectionState.json(list),
              let core = try? ShuffleRunModel.ordered(episodesJson: json) else { return nil }
        return ShuffleRunCore(core: core, items: Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    var first: Item? { core.first().flatMap { items[$0.id] } }
    func contains(_ id: String) -> Bool { core.contains(id: id) }
    func next(after id: String) -> Item? { core.nextAfter(id: id).flatMap { items[$0.id] } }
}
