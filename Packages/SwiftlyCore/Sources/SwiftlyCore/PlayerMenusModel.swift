import Observation

/// **What the player menu views read.** The core builds every level of every sheet (`PlayerModel.menus`); this
/// adapter only keeps the open level (a stack) and hands presses to the core. No option list lives in Swift.
///
/// - `menus` is read by the views; it follows the player (transport, controls, tracks) by itself. When the group, the
///   subtitle look, the season list or the device list change, call `refresh()`.
/// - `open(_:)` shows a sheet at its first level (`.options`, `.tracks(tab:)`, `.episodes(tab:)`); `back()` goes up one
///   level; `level == nil` means no sheet.
/// - `press(_:)` sends any action of any row. Player actions run in the core. `.open` navigates here. The rest goes to
///   `perform`, the host's glue (settings, group, takeover, system); after `.selectSeason` the stack returns to the
///   episodes level.
@MainActor
@Observable
public final class PlayerMenusModel {
    public private(set) var path: [PlayerMenuLevel] = []
    private var revision = 0
    @ObservationIgnored private let player: PlayerModel
    @ObservationIgnored private let inputs: @MainActor () -> PlayerMenusInputs
    @ObservationIgnored private let perform: @MainActor (PlayerMenuAction) -> Void

    /// - Parameters:
    ///   - inputs: what only the host knows (group, look, seasons, device list, AirPlay); asked on every read.
    ///   - perform: carries out `.look`, `.techBadge`, `.leaveGroup`, `.lockScreen`, `.reportProblem`,
    ///     `.searchSubtitles`, `.selectSeason`, `.handoff`, `.airPlay`.
    public init(
        player: PlayerModel,
        inputs: @escaping @MainActor () -> PlayerMenusInputs,
        perform: @escaping @MainActor (PlayerMenuAction) -> Void
    ) {
        self.player = player
        self.inputs = inputs
        self.perform = perform
    }

    /// Every level, built by the core from the player and the host's inputs.
    public var menus: PlayerMenus {
        // Reading the parts registers this view with the player's changes.
        _ = (player.transport, player.controls, player.tracks)
        _ = revision
        return player.menus(inputs())
    }

    /// The open level, `nil` when no sheet shows.
    public var level: PlayerMenuLevel? { path.last }
    public var canGoBack: Bool { path.count > 1 }

    /// A host input changed (group, look, seasons, devices): the views read `menus` again.
    public func refresh() { revision += 1 }

    public func open(_ level: PlayerMenuLevel) { path = [level] }
    public func back() { if path.count > 1 { path.removeLast() } }
    public func close() { path = [] }

    public func press(_ action: PlayerMenuAction) {
        guard let rest = player.pressMenu(action) else { return }
        switch rest {
        case let .open(level):
            path.append(level)
        case .selectSeason:
            perform(rest)
            path = [.episodes(tab: .episodes)]
        default:
            perform(rest)
        }
    }
}
