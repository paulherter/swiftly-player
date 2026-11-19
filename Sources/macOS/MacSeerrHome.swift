import JellyfinKit
import SwiftUI
import SwiftlyCore

/// **Seerr's two sections of the Start page on the Mac**, placed in the core's row order like any other row:
/// "Anfrage ist da" (the arrival stack, `DesktopArrivalSection`) and "Meine Anfragen" (a rail of Seerr tiles).
/// Every word and whether anything shows come from the core (`SeerrHomeInfo`); nothing is drawn without Seerr or with
/// nothing to say, so there is no gap between the rows. While Seerr has not answered, the stack's room of the last start
/// holds a skeleton and the rail keeps its room blank (`SeerrReserved`).
struct MacSeerrHomeSection: View {
    enum Part { case arrival, requests }

    let part: Part
    let flow: SeerrHomeFlow
    let model: AppModel

    @Environment(PlayControls.self) private var controls
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    var body: some View {
        if let info = flow.block(model) {
            switch part {
            case .arrival where !info.arrivals.isEmpty:
                DesktopArrivalSection(arrivals: info.arrivals, expanded: info.arrivalsExpanded,
                                      pending: info.state == .pending,
                                      play: playArrival, openTitle: openArrival,
                                      close: { flow.dismissArrival($0) },
                                      setExpanded: { flow.setArrivalsExpanded($0) })
                    .transition(.opacity)
            case .requests where !info.rail.isEmpty:
                Rail(name: info.railTitle) {
                    ForEach(info.rail) { card in
                        Button { navigator.openIt(.seerrTitle(card.route), in: section) } label: {
                            SeerrTile(card: card, width: Theme.tileWidth)
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
                .modifier(SeerrReserved(pending: info.state == .pending))
            default:
                EmptyView()
            }
        }
    }

    /// "Abspielen": a movie plays, a series plays the episode where you are.
    private func playArrival(_ libraryId: String) {
        Task {
            guard let item = await model.item(id: libraryId) else { return }
            if item.type == "Series" {
                guard let episode = await model.episodeToPlay(series: item) else { return }
                controls.launch(episode)
            } else {
                controls.launch(item)
            }
        }
    }

    /// A click on a card: the title's page.
    private func openArrival(_ libraryId: String) {
        Task {
            guard let item = await model.item(id: libraryId) else { return }
            navigator.openIt(.title(item), in: section)
        }
    }
}
