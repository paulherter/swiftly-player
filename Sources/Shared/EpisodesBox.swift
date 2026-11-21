import JellyfinKit
import SwiftlyCore
import SwiftUI

// **The content of the Folgen box** (episodes of a series, or the chapters of a film) that hangs from the player's Folgen
// button. The box itself (surface, edge, shadow, motion from and to the other menus) is `MenuBox` through
// `PlayerMenuLayer` with `PlayerMenuKind.folgen`; this file only draws what lies inside: the tabs "Folgen | Kapitel" (the
// first tab is the season button when a season list exists) and the rows.
//
// Pointer and keyboard (Mac, iPad with a keyboard) use the box's `MenuNavigator`: one cursor for hover and arrows, Return
// starts the row, Left goes back to the Folgen tab.

struct EpisodesBox: View {
    let model: AppModel
    /// The episode currently playing.
    let item: Item
    /// The seasons of the running series and the open one, shared with the menus' inputs; a choice in the season box lands
    /// in `picker.chosen`.
    let picker: SeasonPicker
    /// The core's season button ("Staffel N"); `nil` without the core or for a film.
    var seasonName: String?
    @Binding var anchors: PlayerMenuAnchors
    var openSeasons: () -> Void = {}
    /// The core's tabs (`menus.episodes.tabs`: Folgen | Kapitel; a film has only Kapitel) and the chapter strip's data.
    var tabs: [PlayerMenuPanelTab] = [.episodes]
    var chapters: PlayerChapters?
    var chapterPreview: (Double, PlayerPreview?) -> CGImage? = { _, _ in nil }
    var jumpToChapter: (Int) -> Void = { _ in }
    let close: () -> Void
    let start: (Item) -> Void

    @Environment(\.menuMaxHeight) private var menuMaxHeight
    @Environment(\.menuNavigator) private var navigator
    @State private var tab: PlayerMenuPanelTab
    @Namespace private var tabLine
    private var seasons: [Item] { get { picker.seasons } nonmutating set { picker.seasons = newValue } }
    @State private var loader: EpisodesLoader
    private var episodes: [Item] { loader.episodes }

    /// **The list is already there on opening.** What the store has (the player preloads it at start) is in the states
    /// before the first frame; otherwise the episodes would pop in after the box.
    init(model: AppModel, item: Item, picker: SeasonPicker, seasonName: String?, anchors: Binding<PlayerMenuAnchors>,
         openSeasons: @escaping () -> Void, tabs: [PlayerMenuPanelTab], startTab: PlayerMenuPanelTab,
         chapters: PlayerChapters?, chapterPreview: @escaping (Double, PlayerPreview?) -> CGImage?,
         jumpToChapter: @escaping (Int) -> Void, close: @escaping () -> Void, start: @escaping (Item) -> Void) {
        self.model = model; self.item = item; self.picker = picker; self.seasonName = seasonName; _anchors = anchors
        self.openSeasons = openSeasons; self.tabs = tabs; self.chapters = chapters; self.chapterPreview = chapterPreview
        self.jumpToChapter = jumpToChapter; self.close = close; self.start = start
        _tab = State(initialValue: tabs.contains(startTab) ? startTab : (tabs.first ?? .episodes))
        _loader = State(initialValue: EpisodesLoader(model: model, item: item, picker: picker))
    }

    // MARK: Rows by key

    /// What a row does, by id: chapters are numbered, episodes use their item id.
    private struct Entry { let id: String; let run: () -> Void }

    private var entries: [Entry] {
        if tab == .chapters {
            return (chapters?.rows ?? []).map { row in Entry(id: "c\(row.index)") { jumpToChapter(Int(row.index)); close() } }
        }
        return episodes.map { episode in Entry(id: episode.id) { start(episode) } }
    }

    private func register() {
        let list = entries
        navigator?.register(keys: list.map(\.id), drill: [],
                            back: tab == .chapters && tabs.contains(.episodes) ? { pick(.episodes) } : nil) { id in
            list.first(where: { $0.id == id })?.run()
        }
    }

    private func pick(_ target: PlayerMenuPanelTab) {
        guard target != tab else { return }
        navigator?.cursor = nil
        withAnimation(Theme.motionReduced ? Theme.fadeReduced : .smooth(duration: 0.25)) { tab = target }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelTabs
                .padding(.leading, 10)
                .frame(height: 46, alignment: .bottomLeading)
                .padding(.bottom, 4)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if tab == .chapters {
                            ForEach(chapters?.rows ?? [], id: \.index) { row in
                                boxRow(id: "c\(row.index)", now: row.current,
                                       title: row.title(numberTitle: chapters?.numberTitle ?? "Kapitel %lld"),
                                       line: row.current ? "\(String(localized: "Läuft")) · \(row.startText)" : row.startText,
                                       action: { jumpToChapter(Int(row.index)); close() }) {
                                    Group {
                                        if let image = chapterPreview(row.start, row.preview) {
                                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                                        } else { Theme.area }
                                    }
                                    .frame(width: 100, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        } else {
                            ForEach(episodes) { episode in
                                boxRow(id: episode.id, now: episode.id == item.id, title: episode.stripHeaderLine,
                                       line: episode.stripDurationLine, action: { start(episode) }) {
                                    Picture(url: model.imageURL(for: episode, maxHeight: 360)
                                                   ?? model.landscapeImageURL(for: episode, width: 640),
                                            width: 100, height: 56, corner: 8,
                                            progress: episode.isWatched ? nil : episode.watchedShare) { Theme.area }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
                .onChange(of: episodes.map(\.id), initial: true) { _, ids in
                    if tab == .episodes, ids.contains(item.id) { reader.scrollTo(item.id, anchor: .center) }
                }
                .onAppear {
                    if tab == .chapters, let now = chapters?.rows.first(where: \.current) { reader.scrollTo("c\(now.index)", anchor: .center) }
                }
                // The arrow keys bring the cursor row into view.
                .onChange(of: navigator?.cursor) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(id) } }
                }
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .animation(Theme.motionReduced ? Theme.fadeReduced : .easeOut(duration: 0.15), value: tab)
        }
        // The surface, edge and shadow are the menu box's (`MenuBox`): this is only what lies inside it.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: min(MenuMetric.folgenHeight, menuMaxHeight))
        .accessibilityAction(.escape, close)
        .task { await loader.load() }
        .onChange(of: tab, initial: true) { register() }
        .onChange(of: episodes.map(\.id)) { register() }
        // A choice from the season box.
        .onChange(of: picker.chosen) { _, id in
            Task { await loader.switchSeason(to: id, animation: Theme.reveal) }
        }
    }

    private func boxRow<Still: View>(id: String, now: Bool, title: String, line: String?, action: @escaping () -> Void,
                                     @ViewBuilder still: () -> Still) -> some View {
        let on = navigator?.cursor == id
        return Button(action: action) {
            HStack(spacing: 12) {
                still().frame(width: 100, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.app(size: 13, weight: .semibold)).foregroundStyle(Theme.font)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let line, !line.isEmpty {
                        Text(verbatim: line).font(.app(size: 12)).foregroundStyle(now ? Theme.accent : Theme.fontVeryQuiet).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(now || on ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        // One cursor for the pointer and the arrow keys (as in the other menu rows); touch screens never set it.
        .onHover { inside in
            guard let navigator else { return }
            if inside { navigator.cursor = id } else if navigator.cursor == id { navigator.cursor = nil }
        }
        .accessibilityAddTraits(now ? .isSelected : [])
        .id(id)
    }

    /// Tabs "Folgen | Kapitel": 15 semibold, the open one white with a 2 pt line under it that glides to the other tab
    /// (smooth 0.25), the other grey; 20 between the tabs, 5 between label and line.
    private var panelTabs: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(tabs, id: \.self) { t in
                let on = t == tab
                Button {
                    // The first tab IS the season button: it opens the season list; from another tab it first comes back.
                    if t == .episodes, seasonName != nil, !seasons.isEmpty, on { openSeasons(); return }
                    pick(t)
                } label: {
                    HStack(spacing: 5) {
                        if t == .episodes, let seasonName {
                            // "Staffel N ⌄" (the open season) in place of the word "Folgen", like the detail page's season picker.
                            Text(verbatim: seasonName).contentTransition(.opacity)
                            Image(icon: "chevron.down", size: 11).font(.app(size: 11, weight: .semibold))
                        } else {
                            Text(t == .episodes ? LocalizedStringKey("Folgen") : LocalizedStringKey("Kapitel"))
                        }
                    }
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(on ? Theme.font : Theme.fontVeryQuiet)
                    .padding(.bottom, 7)
                    .overlay(alignment: .bottom) {
                        if on { Theme.font.frame(height: 2).matchedGeometryEffect(id: "tabline", in: tabLine) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .background { if t == .episodes { Color.clear.menuAnchor(.seasons, into: $anchors) } }
                .animation(Theme.toggle, value: t == .episodes ? seasonName : nil)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityValue(Text(verbatim: t == .episodes ? (seasonName ?? "") : ""))
            }
        }
        .lineLimit(1)
        .frame(height: 26, alignment: .leading)
    }
}
