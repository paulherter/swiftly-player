import Foundation
import Observation

/// The `@MainActor @Observable` adapter of `SeerrScreen`: the detail page of a Seerr title and its
/// request flow (state, words, season sheet, the second tap of a movie) live in the core; the views
/// only draw `page` and send intents.
///
/// The core expires the second tap on its own timer without telling the host, so the controller
/// reads the page again when that time is up.
@MainActor
@Observable
public final class SeerrScreenController {
    /// The open page; `nil` until `open` has been called.
    public private(set) var page: SeerrPageInfo?
    @ObservationIgnored private let screen: SeerrScreen
    @ObservationIgnored private var expiry: Task<Void, Never>?

    public init(model: SeerrModel, locale: String = Locale.current.identifier) {
        screen = SeerrScreen(model: model, locale: locale)
    }

    /// The discover rail of the last search (the views keep their own grids; this is for new ones).
    public var discover: SeerrDiscoverInfo { screen.discover() }

    /// Opens a hit; returns when the detail is in.
    public func open(_ hit: SeerrHit) async {
        try? await screen.open(hit: hit)
        refresh()
    }

    /// The main button. The wording of the second tap is rolled here, once per tap.
    public func press() async {
        try? await screen.press(roll: UInt32.random(in: 0 ..< 1_000))
        refresh()
    }

    /// The sheet's button.
    public func confirmSeasons() async {
        try? await screen.confirmSeasons()
        refresh()
    }

    public func toggleSeason(_ number: Int) {
        screen.toggleSeason(number: Int64(number))
        refresh()
    }

    public func closeSheet() {
        screen.closeSheet()
        refresh()
    }

    public func dismissError() {
        screen.dismissError()
        refresh()
    }

    /// Reads the page again; starts the wait for the end of the second tap while it stands.
    public func refresh() {
        page = screen.page()
        expiry?.cancel()
        guard page?.buttonChecked == true else { return }
        let wait = Double(screen.confirmStandsSeconds()) + 0.2
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.page = self?.screen.page()
        }
    }
}
