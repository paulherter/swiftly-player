import JellyfinKit
import SwiftlyCore
import SwiftUI

/// **One person: who they are and what exists for them.**
///
/// Built like this window's detail page: the image on the right as backdrop, portrait
/// and name at the bottom left, below them the role through which the user arrived,
/// and the biography. Then the rows: what is on the server, and, only with Seerr,
/// what can be requested.
///
/// **The banner changes** between the backgrounds of the person's titles, softly and
/// slowly. If there is only one, it stays.
///
/// **Nothing jumps afterwards.** Portrait and name are there at once because they
/// come with the click. Everything else fades in together once the server has
/// answered; Seerr is added at the bottom so nothing above it shifts.
struct PersonView: View {
    let model: AppModel
    let person: Person
    /// The title the user came from; shown above the role.
    let origin: String?
    let back: () -> Void

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    @State private var color = ImageColor()
    @State private var headerState = HeaderState()
    @State private var core: PersonController?
    /// The banner stays on the first picture.
    private let bannerPoint = 0

    private var page: SwiftlyCore.PersonPage? { core?.page }
    private var loaded: Bool { page?.loaded ?? false }
    private var disrupted: Bool { page?.disrupted ?? false }
    private var title: [SwiftlyCore.Tile] { page?.titles ?? [] }
    private var requestable: [JellyfinKit.SeerrHit] { page?.seerrHits ?? [] }
    private var bannerNow: URL? { page?.bannerURL }

    /// How tall the round head is, and so the whole block, since the text beside it is shorter.
    private let blockHeight: CGFloat = 88

    /// **The header zone is shorter than on the detail page, by calculation.**
    ///
    /// On the detail page, title, details, description and button row fill the 380 pt to
    /// the bottom edge. Here there is only a name. With the block at the top, a hole
    /// gaped below it; hung at the bottom, the hole gaped above it, because to the left of
    /// the name there is no backdrop, only plain background.
    ///
    /// So the same calculation as there, minus what does not exist here: the same lead-in
    /// at the top (`titleHeight + 98`, so the fading bar still fits), then the block and
    /// its bottom spacing.
    private var headerHeight: CGFloat { Theme.titleHeight + 98 + blockHeight + 22 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero.zIndex(1)

                VStack(alignment: .leading, spacing: 26) {
                    // Role and biography stand together and close, as on the iPhone. The large spacing
                    // applies between blocks, not within them.
                    VStack(alignment: .leading, spacing: 10) {
                        roleRow
                        biography
                    }
                    // **Before `loaded`, nothing was shown here:** name, image and an empty surface
                    // below, the same while loading, for a person without titles, and for a silent
                    // server. Three situations, one picture.
                    if !loaded {
                        VStack(alignment: .leading, spacing: 12) {
                            RailTitle(text: "Auf deinem Server")
                            HStack(alignment: .top, spacing: Theme.tileSpacing) {
                                ForEach(0 ..< 4, id: \.self) { _ in
                                    LoadField()
                                        .frame(width: Theme.tileWidth,
                                               height: Theme.tileWidth * 1.5)
                                }
                            }
                        }
                        .transition(.opacity)
                    }
                    TitleRail(title: "Auf deinem Server", entries: title.map { Item(rust: $0) }, model: model,
                              looks: Dictionary(title.map { ($0.id, RustTileLook($0)) }, uniquingKeysWith: { a, _ in a }),
                              more: { id in Task { try? await core?.titleVisible(id) } })
                    requestRail
                    if disrupted, title.isEmpty {
                        // Seerr is not waited for: what the own server says is the main information of this page.
                        DisturbHint(model: model, retry: { Task { await load() } },
                                     spacingTop: 0)
                    } else if let empty = page?.emptyText {
                        Text(verbatim: empty)
                            .font(Theme.body)
                            .foregroundStyle(Theme.fontQuiet)
                    }
                }
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.top, 26)
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        // The same run-out as on the detail page: the image tone continues a little below the
        // header and fades into the background tone.
        .background(alignment: .top) {
            LinearGradient(colors: [color.audio, Theme.reason],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: headerHeight + 260)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.reason)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        .overlay(alignment: .top) {
            DetailHeader(title: person.name, state: headerState, back: back)
        }
        .task(id: "\(person.id)|\(model.listenRefresh)") { await load() }
        .task(id: bannerNow) { await color.load(bannerNow) }
        // **The decorative banner loop is gone.**
        //
        // It swapped the background image every six seconds with a 1.2 second cross-fade.
        // Nothing moves decoratively, and a loop that never ends is the clearest form of
        // that. The iPhone version dropped it; on the Mac it kept running, and the surface
        // is larger there.
        //
        // `bannerPoint` stays at zero: the first image stays.
    }

    // MARK: Header

    private var hero: some View {
        // Without a background of its own the area stays empty instead of cropping a portrait
        // sideways: a face cut off looks worse than calm.
        ZStack {
            Backdrop(url: bannerNow, height: headerHeight * 1.62)
                .id(bannerPoint)
                .transition(.opacity)
        }
        .frame(height: headerHeight, alignment: .topLeading)
        // **At the bottom of the image, not the top.**
        //
        // The block sat at the height where it sits on the detail page, but there the
        // description and button row follow and fill the header zone to the bottom edge.
        // Here nothing follows, and a gap of about 170 pt opened between name and
        // biography. Anchored at the bottom it sits where it does on iPhone and iPad.
        .overlay(alignment: .bottomLeading) {
            block
                .padding(.leading, Theme.edgeSpacing)
                .padding(.bottom, 22)
        }
    }

    /// Portrait, name, two info lines, role: **fixed heights**, so nothing pushes upward
    /// when the server answers.
    private var block: some View {
        HStack(alignment: .bottom, spacing: 16) {
            // Round because it is a picture, like the cast heads.
            ProfileCharacter(name: person.name,
                          image: model.personImage(person, maxHeight: 300),
                          size: blockHeight)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: person.name)
                    // Page title: 28 bold, letter-spacing for that step.
                    .font(Theme.titleLarge)
                    .tracking(Theme.lockTitle)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                // The two lines have their place from the start and only fade in.
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: birthRow ?? " ")
                    Text(verbatim: place ?? " ")
                }
                // Detail line (birth date, place): 12. Sizes 13 and 14 "without role" are reserved for this page.
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
                .opacity(loaded ? 1 : 0)
            }
            .frame(width: Theme.readWidth, alignment: .leading)
        }
    }

    private var birthRow: String? { page?.bornLine }

    private var place: String? { page?.place }

    @ViewBuilder
    private var roleRow: some View {
        if let line = page?.roleLine {
            Text(verbatim: line)
                .font(Theme.tile)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
        }
    }

    /// Four lines, then "Mehr". Here a biography is information, not the reason to open
    /// the page; it should not push the titles down before the user wants it.
    @ViewBuilder
    private var biography: some View {
        if let text = page?.biography {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: text)
                    .font(Theme.body)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(page?.biographyExpanded == true ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                Button(page?.biographyToggle ?? "") {
                    withAnimation(Theme.leap) { core?.toggleBiography() }
                }
                .buttonStyle(Theme.PressButton())
                .font(Theme.body.weight(.medium))
                // The quiet button carries the accent: it is the second action.
                .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: Theme.readWidth, alignment: .leading)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var requestRail: some View {
        if !requestable.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                RailTitle(text: "Kann angefragt werden")
                PagingRail(margin: 0) {
                    ForEach(requestable) { hit in
                        Button { navigator.openIt(.seerrTitle(hit), in: section) } label: {
                            SeerrTile(hit: hit)
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Loading

    private func load() async {
        if core == nil { core = try? AppCore.shared.person(session: model.session, person: person, origin: origin) }
        await core?.run(app: model)
    }
}
