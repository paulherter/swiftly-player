import SwiftUI
import SwiftlyCore

/// **The episodes of a title the server does not have ("Folgen"): one view for iPhone, iPad, Mac and Apple TV.**
///
/// Season chips, then a row per episode: the still in final size (a quiet field while it loads or when TMDB has
/// none), "N. Name", runtime and day, and the story. Which season shows, the rows and every word come from the
/// core through ``SeerrTitleFlow`` (the season rule is `SeerrTitleScreen.episodeSeason`); all of it arrives with the
/// page's first answer, so nothing pops in afterwards. The platforms differ only where the input differs: the Mac
/// lights a row under the pointer, the TV makes chips and rows focusable (focus moves chips, then rows, by remote).
struct SeerrEpisodes: View {
    let flow: SeerrTitleFlow
    /// The page's left and right margin.
    let margin: CGFloat
    #if os(tvOS)
    /// Whether the season menu is open; the page shows its panel (the series page's `ActionPanel`).
    @Binding var pickerOpen: Bool
    @FocusState private var atPill: Bool
    #endif

    var body: some View {
        if let current = flow.episodeSeasonRow {
            VStack(alignment: .leading, spacing: 0) {
                #if os(tvOS)
                // The season button of the series page (`SeasonPill`) next to the title, not a row of chips.
                HStack(spacing: 24) {
                    RailTitle(text: "Folgen").accessibilityAddTraits(.isHeader)
                    if flow.episodeSeasons.count > 1 {
                        SeasonPill(name: current.title, opened: $pickerOpen)
                            .focused($atPill)
                            .panelTrigger("staffel")
                    }
                }
                .padding(.horizontal, margin)
                .padding(.bottom, Look.headingGap)
                .onChange(of: pickerOpen) { _, opened in if !opened { atPill = true } }
                #else
                RailTitle(text: "Folgen")
                    .padding(.horizontal, margin)
                    .padding(.bottom, Look.headingGap)
                    .accessibilityAddTraits(.isHeader)
                if flow.episodeSeasons.count > 1 { chips(current: current.number) }
                #endif
                ForEach(current.episodeList) { episode in
                    SeerrEpisodeRow(episode: episode, margin: margin)
                }
                .id(current.number)
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    #if !os(tvOS)
    private func chips(current: Int64) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Look.chipGap) {
                ForEach(flow.episodeSeasons) { season in
                    let on = season.number == current
                    Button { flow.pickEpisodeSeason(season.number) } label: {
                        Text(verbatim: season.title)
                            .font(.app(size: 14, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.font : Theme.fontQuiet)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(Capsule().fill(Theme.font.opacity(on ? 0.14 : 0.06)))
                    }
                    .buttonStyle(Theme.PressButton())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, margin)
        }
        .padding(.bottom, Look.chipsBottom)
    }
    #endif

    /// The sizes that differ with the distance to the screen.
    fileprivate enum Look {
        #if os(tvOS)
        static let headingGap: CGFloat = 12
        static let chipGap: CGFloat = 16
        static let chipsBottom: CGFloat = 10
        static let stillWidth: CGFloat = 320
        static let stillHeight: CGFloat = 180
        static let gap: CGFloat = 32
        static let rowPadding: CGFloat = 16
        static let textWidth: CGFloat = 1100
        static let titleFont = Theme.listTitle
        static let storyLines = 3
        #elseif os(macOS)
        static let headingGap: CGFloat = 10
        static let chipGap: CGFloat = 8
        static let chipsBottom: CGFloat = 6
        static let stillWidth: CGFloat = 160
        static let stillHeight: CGFloat = 90
        static let gap: CGFloat = 16
        static let rowPadding: CGFloat = 8
        static let textWidth: CGFloat = 560
        static let titleFont = Font.app(size: 15, weight: .medium)
        static let storyLines = 3
        #else
        static let headingGap: CGFloat = 10
        static let chipGap: CGFloat = 8
        static let chipsBottom: CGFloat = 6
        static let stillWidth: CGFloat = 128
        static let stillHeight: CGFloat = 72
        static let gap: CGFloat = 12
        static let rowPadding: CGFloat = 8
        static let textWidth: CGFloat = 560
        static let titleFont = Font.app(size: 15, weight: .medium)
        static let storyLines = 2
        #endif
    }
}

/// One episode of a Seerr title.
private struct SeerrEpisodeRow: View {
    let episode: SwiftlyCore.SeerrEpisodeInfo
    let margin: CGFloat

    typealias Look = SeerrEpisodes.Look

    #if os(macOS)
    @State private var hovers = false
    #endif

    var body: some View {
        #if os(tvOS)
        // **Focusable so the remote can walk down the list** (and the page scrolls with it); a row has no action.
        Button {} label: { content }
            .buttonStyle(EpisodeFocusStyle())
            .padding(.horizontal, margin - Look.rowPadding)
            .accessibilityElement(children: .combine)
        #elseif os(macOS)
        // A pointer cannot focus: the row under it gets a quiet surface, in the same place as the library's rows.
        content
            .background(RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous)
                .fill(Theme.font.opacity(hovers ? 0.06 : 0)))
            .onHover { hovers = $0 }
            .animation(Theme.timeFloat, value: hovers)
            .padding(.horizontal, margin - Look.rowPadding)
            .accessibilityElement(children: .combine)
        #else
        content
            .padding(.horizontal, margin - Look.rowPadding)
            .accessibilityElement(children: .combine)
        #endif
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Look.gap) {
            Picture(url: episode.still.flatMap { URL(string: $0) }, width: Look.stillWidth, height: Look.stillHeight,
                    corner: Theme.cornerTile)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "\(episode.number). \(episode.title)")
                    .font(Look.titleFont).foregroundStyle(Theme.font).lineLimit(2)
                if !episode.meta.isEmpty {
                    Text(verbatim: episode.meta).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
                }
                if let story = episode.overview {
                    Text(verbatim: story).font(Theme.small).foregroundStyle(Theme.fontQuiet)
                        .lineLimit(Look.storyLines)
                }
            }
            #if os(iOS)
            .frame(maxWidth: .infinity, alignment: .leading)
            #else
            .frame(maxWidth: Look.textWidth, alignment: .leading)
            #endif
            #if !os(iOS)
            Spacer(minLength: 0)
            #endif
        }
        .multilineTextAlignment(.leading)
        .frame(minHeight: Look.stillHeight, alignment: .top)
        .padding(.horizontal, Look.rowPadding)
        .padding(.vertical, Look.rowPadding)
    }
}

#if os(tvOS)
/// The row's focus: the calm surface of the settings rows, no magnification (a row is not a tile).
private struct EpisodeFocusStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .background(focus ? Theme.focusArea : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}
#endif
