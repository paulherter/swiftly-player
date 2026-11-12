import JellyfinKit
import SwiftlyCore
import SwiftUI

/// One person: who they are and what exists with them.
/// Built like a detail page: backdrop on the right, bottom left the round head
/// with name, birth date and place, below it the role and biography, then the
/// rows: what is on the server and, with Seerr, what can be requested.
/// The banner cross-fades between the backgrounds of their titles, softly and
/// slowly. With only one, it stays.
struct PersonView: View {
    let model: AppModel
    let route: PersonRoute

    @State private var core: PersonController?
    /// The banner stays on the first picture.
    private let bannerPoint = 0

    private var page: SwiftlyCore.PersonPage? { core?.page }
    private var loaded: Bool { page?.loaded ?? false }
    private var disrupted: Bool { page?.disrupted ?? false }
    private var title: [SwiftlyCore.Tile] { page?.titles ?? [] }
    private var requestable: [JellyfinKit.SeerrHit] { page?.seerrHits ?? [] }

    private var person: Person { route.person }
    private var bannerNow: URL? { page?.bannerURL }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                // Before `loaded` there was nothing here but name, picture and an empty area, while loading as well as with a silent server.
                if !loaded {
                    railsSection {
                        RailTitle(text: "Auf deinem Server")
                    } content: {
                        strip {
                            ForEach(0 ..< 5, id: \.self) { _ in
                                LoadField()
                                    .frame(width: Theme.posterWidth,
                                           height: Theme.posterHeight)
                            }
                        }
                    }
                    .transition(.opacity)
                } else if !title.isEmpty {
                    railsSection {
                        RailTitle(text: "Auf deinem Server")
                    } content: {
                        TitleStrip(model: model, items: title.map { Item(rust: $0) },
                                   looks: Dictionary(title.map { ($0.id, RustTileLook($0)) }, uniquingKeysWith: { a, _ in a }),
                                   more: { id in Task { try? await core?.titleVisible(id) } })
                    }
                    .transition(.opacity)
                }

                if !requestable.isEmpty {
                    railsSection {
                        RailTitle(text: "Kann angefragt werden")
                    } content: {
                        strip {
                            ForEach(requestable) { t in
                                NavigationLink(value: t) { SeerrTile(hit: t) }
                                    .buttonStyle(TileStyle())
                            }
                        }
                    }
                    .transition(.opacity)
                }

                if disrupted, title.isEmpty {
                    // Seerr is not awaited: what the own server says is the main answer of this page.
                    DisturbState(model: model, retry: { Task { await load() } })
                        .frame(height: Theme.posterHeight)
                } else if let empty = page?.emptyText {
                    Text(verbatim: empty)
                        .font(Theme.tile)
                        .foregroundStyle(Theme.fontQuiet)
                        .padding(.horizontal, Theme.edgePage)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, Theme.completionPadding)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .imageReason(url: bannerNow)
        .task(id: person.id) { await load() }
        // Seen/saved elsewhere: reload quietly (`load` keeps what was there on failure).
        .onChange(of: model.pagesRefresh) { _, _ in Task { await load() } }
    }

    // MARK: Header

    /// No `focusSection`: the header has nothing focusable, and a registered area
    /// without a target swallows the press and drops it, which once got the cast
    /// row stuck. See `Detailrahmen.focusable`.
    private var header: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                Backdrop(url: bannerNow)
                    .id(bannerPoint)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            HeaderShadow()

            block
                .padding(.leading, Theme.edgePage)
                // Same line where the detail page has its title.
                .padding(.top, 140 + Theme.headerOffsetDetail)
        }
        .frame(height: Theme.heroHeightDetail, alignment: .topLeading)
    }

    private var block: some View {
        HStack(alignment: .top, spacing: 40) {
            // Round because it is a picture, like the cast tiles. Half the edge length is not a corner-ladder step, it is the circle itself.
            Picture(url: model.personImage(person, maxHeight: 600),
                 width: 208, height: 208, corner: 208 / 2)

            VStack(alignment: .leading, spacing: 0) {
                Text(person.name)
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                // The two lines have their place from the start and only fade in; arriving at load they would push everything below down.
                VStack(alignment: .leading, spacing: 2) {
                    Text(birthRow ?? " ")
                    Text(place ?? " ")
                }
                .font(Theme.tile)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
                .opacity(loaded ? 1 : 0)
                .padding(.top, 10)

                if let line = page?.roleLine {
                    Text(verbatim: line)
                        .font(Theme.tile)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .padding(.top, 12)
                }

                if let text = page?.biography {
                    Text(text)
                        .font(Theme.body)
                        .lineSpacing(Theme.descriptionPadding)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .lineLimit(3)
                        .padding(.top, 16)
                        .transition(.opacity)
                }
            }
            // Like the detail pages' header text: never beyond the backdrop.
            .frame(width: 1000, alignment: .leading)
        }
    }

    private var birthRow: String? { page?.bornLine }

    private var place: String? { page?.place }

    // MARK: Loading

    private func load() async {
        if core == nil { core = try? AppCore.shared.person(session: model.session, person: person, origin: route.origin) }
        await core?.run(app: model)
    }
}
