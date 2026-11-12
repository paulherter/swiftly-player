import JellyfinKit
import SwiftUI

/// Playback: quality, language, behavior.
///
/// Groups, order and texts match the iPhone version. The values come from
/// `Wiedergabewahlen` and `SpeedLevels`, not from separate lists here.
///
/// Only difference: the value list expands **below the row** instead of as a
/// bottom sheet (selection stays in place).
struct PlaybackSettingsView: View {
    let model: AppModel
    let back: () -> Void

    @State private var openList: ListKind?
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    enum ListKind { case bitrate, audio, subtitle, back, forward }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: "Wiedergabe", back: back)

                // **Two columns, left-aligned, as on iPad.** Left: everything audio-related
                // (quality and language). Right: behavior alone. The gap is twice the page margin
                // so the cards sit apart the same way they sit from the window edge.
                HStack(alignment: .top, spacing: Theme.edgeSpacing * 2) {
                    VStack(alignment: .leading, spacing: 0) {
                        quality
                        language
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    behavior
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: Theme.settingWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        // **The milky bar at the top edge.** macOS 26 adds it over every scroll view by
        // itself; it is not in our code. Over the image it was barely visible, on a plain
        // background to the left it showed as a bar. Anything the framework adds unasked
        // has to be switched off just like anything we add ourselves.
        .pagesScroll()
        .onChange(of: feed.facts(model), initial: true) { _, new in feed.apply(new, model) }
    }

    // MARK: Groups

    /// Rows, titles, second lines, dimming, options and validation come from the Rust core; the
    /// symbols, the groups and the Mac wording (`SettingsWording`) stay here.
    private let feed = SettingsRowsFeed.shared

    @ViewBuilder private func switchRow(_ key: String, _ symbol: String) -> some View {
        if let row = feed.row(key) {
            ToggleRow(symbol: symbol, title: feed.title(key), under: feed.under(key), an: feed.binding(key))
                .disabled(!row.enabled)
        }
    }

    /// A row with a value whose list opens below it.
    @ViewBuilder private func listRow(_ key: String, _ symbol: String, _ kind: ListKind) -> some View {
        if let row = feed.row(key) {
            ValuesRow(symbol: symbol, title: feed.title(key), under: feed.under(key),
                      value: feed.shown(key), arrow: true, action: { toggle(kind) })
                .disabled(!row.enabled)
                .opacity(row.enabled ? 1 : 0.4)
            if openList == kind {
                ValuesList(entries: feed.choices(key), label: { $0.label }, isSelected: { $0.selected },
                           select: { feed.choose(key, $0.value); close() })
            }
        }
    }

    private var quality: some View {
        SettingGroup(title: "Qualität") {
            switchRow("immerDirectPlay", "play.fill")
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            listRow("bitratenGrenze", "chart.bar", .bitrate)
        }
    }

    private var language: some View {
        SettingGroup(title: "Sprache") {
            listRow("tonSprache", "speaker.wave.2", .audio)
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            listRow("utSprache", "captions.bubble", .subtitle)
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            switchRow("utAuto", "text.alignleft")
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            // The page for size, colour, outline and so on (spec: subtitle look, section 1).
            ValuesRow(symbol: "textformat.size", title: feed.title("utAussehen"),
                      value: feed.shown("utAussehen") ?? "", arrow: true,
                      action: { navigator.openIt(.subtitleLook, in: section) })
        }
    }

    private var behavior: some View {
        SettingGroup(title: "Verhalten") {
            switchRow("naechsteAuto", "forward.end.fill")
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            switchRow("introAbspannAuto", "forward.fill")
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            // **The switch for the technical badge.**
            //
            // It lives under "Verhalten" rather than with the picture options: it changes
            // nothing about playback, it only shows what playback does. Off by default, like
            // downloads and Seerr.
            switchRow("technikschild", "waveform.badge.magnifyingglass")
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            // "Endet um 18:38" instead of the remaining time; off by default (`PlayerEndTime`).
            switchRow("endzeitImPlayer", "clock")
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            listRow("zurueckSek", "gobackward", .back)
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            listRow("vorSek", "goforward", .forward)
        }
    }

    private func toggle(_ list: ListKind) {
        withAnimation(Theme.leap) {
            openList = openList == list ? nil : list
        }
    }

    private func close() {
        withAnimation(Theme.leap) { openList = nil }
    }
}
