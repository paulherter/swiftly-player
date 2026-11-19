import JellyfinKit
import SwiftUI
import SwiftlyCore

/// **The rails of the empty Search page.** Trending, popular films and series, what is coming soon.
///
/// A title the own server has is a normal poster tile and opens its normal page; every other one is a
/// ``SeerrTile`` and opens the Seerr page. The rails and their headings come from the core; nothing is
/// drawn while Seerr is not connected, still loading, or has nothing (no heading, no grey block).
struct SeerrDiscoverView: View {
    let model: AppModel
    let flow: SeerrSearchFlow

    @Environment(\.wide) private var wide

    var body: some View {
        if flow.ready, let rails = flow.rails, rails.load == .content {
            VStack(alignment: .leading, spacing: Theme.railsSpacing) {
                ForEach(rails.rails, id: \.id) { rail in
                    self.rail(rail)
                }
            }
            .padding(.top, 8)
            .transition(.opacity)
        }
    }

    private func rail(_ rail: SwiftlyCore.SeerrRail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RailTitle(name: rail.title)
                .padding(.horizontal, Theme.margin(wide: wide))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.tileSpacing) {
                    ForEach(rail.tiles) { card in
                        tile(card)
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func tile(_ card: SwiftlyCore.SeerrTileCard) -> some View {
        let width = Theme.railsWidth(wide: wide)
        if case .title(let item)? = flow.own[card.id] {
            NavigationLink(value: item) {
                PosterTile(model: model, item: item, width: width)
            }
            .buttonStyle(Theme.PressButton())
        } else {
            NavigationLink(value: card.route) {
                SeerrTile(card: card, width: width)
            }
            .buttonStyle(Theme.PressRow())
        }
    }
}
