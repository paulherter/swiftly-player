import Foundation

/// "Play shuffled" for a series: all episodes in one random order, mixed once.
///
/// **Not yet watched episodes come first**, each group in its own random order, as
/// Jellyfin does it. The order is fixed when it starts; "Next episode" in the player
/// then simply walks along it. It lives in the package so every platform mixes and
/// advances the same way.
public struct ShuffleRun: Sendable, Equatable {

    public let episodes: [Item]

    public init(episodes: [Item]) { self.episodes = episodes }

    /// The mixed order: unwatched first, then watched, each group shuffled.
    public static func mixed<G: RandomNumberGenerator>(_ items: [Item], using generator: inout G) -> ShuffleRun {
        ShuffleRun(episodes: mix(items, isPlayed: { $0.userData?.played == true }, using: &generator))
    }

    public static func mixed(_ items: [Item]) -> ShuffleRun {
        var generator = SystemRandomNumberGenerator()
        return mixed(items, using: &generator)
    }

    static func mix<T, G: RandomNumberGenerator>(_ items: [T], isPlayed: (T) -> Bool,
                                                 using generator: inout G) -> [T] {
        let unplayed = items.filter { !isPlayed($0) }.shuffled(using: &generator)
        let played = items.filter(isPlayed).shuffled(using: &generator)
        return unplayed + played
    }

    /// The episode after this one in the order. `nil` at the end, and for an episode
    /// that is not part of the run (then the run no longer applies).
    public func next(after id: String) -> Item? {
        guard let now = episodes.firstIndex(where: { $0.id == id }),
              episodes.indices.contains(now + 1) else { return nil }
        return episodes[now + 1]
    }

    public func contains(_ id: String) -> Bool { episodes.contains { $0.id == id } }
}
