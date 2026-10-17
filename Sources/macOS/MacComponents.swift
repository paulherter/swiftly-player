import JellyfinKit
import OSLog
import SwiftUI

/// Building blocks for the Mac. No stock Apple controls (`List`, `Toggle`, `Picker`,
/// `Menu`, `Slider`): the same rule as on iPhone and TV, because they bring their
/// own metrics, corner radii and material.
///
/// The one thing new on this platform is the **hover state**: a pointer rests on a
/// surface before clicking it. That state exists neither on iPhone nor with a remote.

// MARK: - Sidebar

/// A sidebar row. Replaces the bottom bar of the phone: there the thumb was the
/// limit, here it is the window height.
struct SidebarRow: View {
    let symbol: String
    var label: LocalizedStringKey = ""
    /// For rows whose text comes from the server. A library name is not a catalog
    /// string: passed as a `LocalizedStringKey`, "Filme" would be looked up as a key and
    /// an English user could get something else.
    var name: String?
    let active: Bool
    let pick: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(Theme.body.weight(.medium))
                    .frame(width: 17)
                Group {
                    if let name { Text(verbatim: name) } else { Text(label) }
                }
                .font(Theme.body.weight(.medium))
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.rowHeight)
            .foregroundStyle(foreground)
            .background(background,
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private var foreground: Color {
        if active { return Theme.accent }
        return hovers ? Theme.font : Theme.fontQuiet
    }

    /// The accent marks selection, same as on iOS where the active tab carries it.
    /// Hover deliberately gets only white: it says "the pointer is here", not "chosen".
    private var background: Color {
        if active { return Theme.accent.opacity(0.10) }
        return hovers ? Theme.hoverArea : .clear
    }
}

/// Heading of a sidebar group.
struct SidebarCategory: View {
    let text: LocalizedStringKey
    var body: some View {
        // **Sentence case, not all caps.** Letter-spacing is only needed for capitals,
        // and capitals read worse and are spelled out letter by letter by VoiceOver.
        // macOS sidebar sections have long been set this way: 11 semibold, muted.
        Text(text)
            .font(Theme.group)
            .foregroundStyle(Theme.fontVeryQuiet)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chip

/// Filter and sort chip. Active is white with black text: the same shape as the
/// primary button, one size smaller.
struct Chip: View {
    let label: String
    var symbol: String?
    let active: Bool
    /// Countdown in the player: the clock fills from the left (`FillClock`).
    var fillContent: FillClock? = nil
    let pick: () -> Void

    @State private var hovers = false
    @Environment(\.onImageTint) private var onImage

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                // **One weight, not two.** Semibold is wider than regular and the chips sit side
                // by side, so every neighbor to the right shifted on toggle. 13 medium is used in
                // both states.
                Text(label).font(Theme.tile)
            }
            .padding(.horizontal, 13)
            // **30, not 28**: pills and chips are 30 high.
            .frame(height: 30)
            .foregroundStyle(active ? Theme.font : Theme.fontQuiet)
            // **No second primary button and no drawn border.** A white fill with dark text
            // would be the primary button character for character, and several chips sit next
            // to each other on the library page, but only one fully filled element is allowed
            // per page. So active is one step up the ladder plus full-strength text; neither
            // changes a metric.
            .background {
                ZStack {
                    // Translucent over the image color; active does not change the fill there, the text carries the state.
                    Capsule().fill(onImage ? Theme.surfaceTranslucent
                                           : (active ? Theme.raised : Theme.area))
                    if let fillContent {
                        // Driven by the clock throughout, accent at half opacity, as on iOS.
                        TimelineView(.animation) { time in
                            GeometryReader { g in
                                Rectangle()
                                    .fill(Theme.accent.opacity(0.5))
                                    .frame(width: g.size.width * fillContent.share(now: time.date))
                            }
                        }
                        .clipShape(Capsule())
                    }
                    // Hover state: white fill at 6 %. It says "the pointer is here", not "chosen".
                    if hovers { Capsule().fill(Theme.hoverArea) }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(Theme.PressButton())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .onHover { hovers = $0 }
        .animation(Theme.toggle, value: active)
        .animation(Theme.timeFloat, value: hovers)
    }
}

// MARK: - Buttons

/// The one primary button per page: white, black text, 48 high.
///
/// On the phone it spans the full width. Not here: that width answered the thumb,
/// and a pointer hits a narrow button just as well. A 1200 pt wide button would
/// also look like a mistake.
struct PrimaryButton: View {
    let label: LocalizedStringKey
    var symbol: String = "play.fill"
    var abbreviation: String?
    let pick: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 9) {
                // **17 semibold.** 16 is on no step of the type scale; 17 is the section-heading
                // size, and a primary button should be at least as loud.
                Image(systemName: symbol).font(Theme.categoryLarge)
                    .accessibilityHidden(true)
                Text(label).font(Theme.categoryLarge)
                if let abbreviation {
                    Text(abbreviation)
                        .font(Theme.tile)
                        .foregroundStyle(Theme.onAccent.opacity(0.45))
                }
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.primaryButtonHeight)
            // Text on a filled surface has its own tone.
            .foregroundStyle(Theme.onAccent)
            .background(hovers ? Theme.primaryButtonHovers : Theme.font,
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .contentShape(Rectangle())
        }
        // **The primary button also responds to press.** It only knew hover and was thus
        // the one button without feedback.
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
    }
}

/// Round action button next to the primary one: watchlist, trailer, watched, more.
///
/// `title` is not drawn; it is the VoiceOver name. A button that carries only a
/// symbol would otherwise be announced as just "button".
struct ActionButton: View {
    /// **The size is set by the row.** Next to the primary button all fields share its
    /// height. In an episode row it is the smaller field. Two values, one component:
    /// `Nebenknopf` used to be the same button a second time, 48 instead of 40.
    var mass: CGFloat = Theme.buttonField
    let symbol: String
    var title: LocalizedStringKey?
    var active: Bool = false
    let pick: () -> Void

    @State private var hovers = false
    /// Over an image color (movie and series pages): translucent instead of `area`.
    @Environment(\.onImageTint) private var onImage

    var body: some View {
        Button(action: pick) {
            // **A field, not a circle with an outline, and no white fill.** A button without
            // a label is square; it carries a surface instead of a drawn edge, and the one
            // fully filled element of the page stays the primary button. Active therefore
            // means accent on the symbol, not white behind it.
            Image(systemName: symbol)
                .font(Theme.categoryLarge)
                .frame(width: mass, height: mass)
                .foregroundStyle(active ? Theme.accent : Theme.font)
                .background {
                    let form = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    ZStack {
                        form.fill(Theme.buttonArea(onImage: onImage))
                        if hovers { form.fill(Theme.hoverArea) }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityLabel(title.map { Text($0) } ?? Text(verbatim: symbol))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Tiles

/// **`pick` is optional.** Without it the tile only draws itself, with no
/// button of its own, so it can be the label of a `NavigationLink`. A button
/// **inside** a button swallows the click: the inner one accepts it and does
/// nothing, the outer one never sees it. That is what once killed every path to the
/// detail pages.
///
/// Poster, 2:3. It grows slightly on hover, with **no accent outline:** the accent
/// carries progress, selection and the direct-play indicator, and "the pointer is
/// here" is not a selection.
struct PosterCell: View {
    let title: String
    let secondLine: String?
    let image: URL?
    var progress: Double?
    /// What shows at the top right: watched, open episodes, season count.
    ///
    /// **Three states, three marks.** The progress bar alone says nothing for a series,
    /// because it shows the state of the started *episode*, not of the series.
    /// `DisplayRules.tileMark` decides which information applies.
    var mark: TileMark?
    /// Symbol for when the server has no image.
    var symbolText: String?
    var pick: (() -> Void)?
    /// Called on hover; see `SeriesCache.prefetch(_:with:)`.
    var prefetch: (() -> Void)?
    /// **Only for a collection tile without its own image:** what the fallback poster
    /// (`Sammlungsmosaik`) is built from. `nil` everywhere else, which leaves the poster
    /// as before.
    var mosaic: (model: AppModel, collection: ItemCollection, art: String)? = nil

    @State private var hovers = false
    /// Poster and text fade in **together**. The image fades in by itself while the
    /// title would be there at once, so on a switch the labels would appear first and
    /// the posters would run in afterwards.
    @State private var present = false

    var body: some View {
        TileWrapper(pick: pick, hovers: $hovers, prefetch: prefetch,
                     name: [title, secondLine].compactMap { $0 }.joined(separator: ", "),
                     condition: condition) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let mosaic {
                        CollectionMosaic(model: mosaic.model, collection: mosaic.collection,
                                        art: mosaic.art)
                    } else {
                        ImageArea(image: image, width: Theme.tileWidth, height: Theme.tileHeight,
                                    progress: progress, symbolText: symbolText)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let mark { TileBadge(mark: mark) }
                }
                .scaleEffect(hovers ? 1.04 : 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(Theme.tileTitleText)
                        .foregroundStyle(Theme.font)
                        .lineLimit(1)
                    if let secondLine {
                        Text(verbatim: secondLine)
                            .font(Theme.secondLine)
                            .foregroundStyle(Theme.fontQuiet)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: Theme.tileWidth, alignment: .leading)
        }
        .opacity(present ? 1 : 0)
        .onAppear {
            guard !present else { return }
            withAnimation(Theme.reveal) { present = true }
        }
    }

    /// What the badge and the bar say, the same information as on tvOS
    /// (`TileContent.label`/`progressText`). It is a value here rather than
    /// part of the label because `TileWrapper` keeps the title separate. Without it,
    /// "watched" and "half watched" were only a drawing.
    private var condition: String? {
        var parts: [String] = []
        if let mark {
            switch mark {
            case .watched: parts.append(String(localized: "gesehen"))
            case .opened(let n): parts.append(String(localized: "\(n) offen"))
            case .seasons(let n): parts.append(n == 1 ? String(localized: "1 Staffel")
                                                       : String(localized: "\(n) Staffeln"))
            }
        }
        if let progress, progress >= 0.01 {
            parts.append(String(localized: "\(Int(progress * 100)) Prozent gesehen"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Wide tile, 16:9, only for "Weiterschauen" and "Nächste Folge".
///
/// A click starts playback at once. The way to the detail page is the right mouse
/// button; the caller attaches the tile menu (`TileMenu.swift`) as on any tile.
struct LandscapeTile: View {
    let title: String
    let secondLine: String?
    let image: URL?
    var progress: Double?
    /// Symbol for when the server has no image.
    var symbolText: String?
    var pick: (() -> Void)?
    /// Called on hover; see `SeriesCache.prefetch(_:with:)`.
    var prefetch: (() -> Void)?

    @State private var hovers = false

    var body: some View {
        TileWrapper(pick: pick, hovers: $hovers, prefetch: prefetch,
                     name: [title, secondLine].compactMap { $0 }.joined(separator: ", "),
                     condition: condition) {
            VStack(alignment: .leading, spacing: 8) {
                ImageArea(image: image, width: Theme.landscapeWidth, height: Theme.landscapeHeight,
                            progress: progress, symbolText: symbolText)
                    .scaleEffect(hovers ? 1.04 : 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(Theme.tileTitleText).foregroundStyle(Theme.font).lineLimit(1)
                    if let secondLine {
                        Text(verbatim: secondLine)
                            .font(Theme.secondLine).foregroundStyle(Theme.fontQuiet).lineLimit(1)
                    }
                }
            }
            .frame(width: Theme.landscapeWidth, alignment: .leading)
        }
    }

    /// The progress bar in words, only from one percent up, as in `PosterCell`.
    private var condition: String? {
        guard let progress, progress >= 0.01 else { return nil }
        return String(localized: "\(Int(progress * 100)) Prozent gesehen")
    }
}

/// The shell of both tiles: a button only if there is a click of its own.
private struct TileWrapper<ContentBody: View>: View {
    let pick: (() -> Void)?
    @Binding var hovers: Bool
    /// Called when the pointer **rests**, not on first contact. Sweeping across a row
    /// brushes a dozen tiles, and without the pause each of them would ask the server.
    var prefetch: (() -> Void)?
    let name: String
    /// Watched, half watched, open episodes, season count, as a value rather than part
    /// of the name. `nil` means there is nothing to say.
    var condition: String? = nil
    @ViewBuilder let content: ContentBody

    var body: some View {
        Group {
            if let pick {
                Button(action: pick) { content.contentShape(Rectangle()) }
                    .buttonStyle(Theme.PressButton())
            } else {
                content.contentShape(Rectangle())
            }
        }
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .task(id: hovers) {
            guard hovers, let prefetch else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            prefetch()
        }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(condition.map(Text.init) ?? Text(""))
        .accessibilityAddTraits(.isButton)
    }
}

/// The image area of a tile including progress.
///
/// The progress bar lies **inside** the mask, not as an overlay, or its square ends
/// would stick out past the rounded corners. A pitfall already hit on iOS.
struct ImageArea: View {
    let image: URL?
    let width: CGFloat
    let height: CGFloat
    var progress: Double?

    /// Settings > Appearance. See `EnvironmentValues.progressOnTiles`.
    @Environment(\.progressOnTiles) private var barShow
    /// Symbol for when the server has no image.
    var symbolText: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.area
            // **The tile knows its size, so it says so.** Without it every image is decoded
            // at 1600 pt on the long edge.
            NetworkImage(url: image, symbolText: symbolText, displayEdge: max(width, height))
            if let progress, progress > 0, barShow {
                // No GeometryReader: the width is fixed (`width`), and one per tile costs layout
                // passes in long grids.
                ZStack(alignment: .leading) {
                    // **The track is light** (white 30 %) and the bar carries the accent. A dark
                    // track reads as "something is missing here", a light one as "this is the whole
                    // length, and this is how far you are".
                    Rectangle().fill(Color.white.opacity(0.3))
                    Rectangle().fill(Theme.accent)
                        .frame(width: width * min(max(progress, 0), 1))
                }
                // 4, not 3: the same size as on the phone.
                .frame(height: 4)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
    }
}

// MARK: - Placeholder instead of spinner

/// A surface shaped like what is about to appear.
///
/// **Why no spinning ring.** A ring says "wait"; a placeholder says *what* is coming
/// and how much. The page is already laid out, only empty.
///
/// The pulse runs through `.opacity` with `repeatForever`: Core Animation takes it
/// over and keeps computing it on the render server, so SwiftUI never has to
/// rebuild anything per frame.
struct LoadField: View {
    var corner: CGFloat = Theme.cornerTile
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Theme.area)
            // **The pulse is dropped under Reduce Motion.** Nothing moves decoratively, and a
            // permanent pulse is exactly that. `Leerzustand` further down in this file already
            // does it correctly.
            .opacity(bright ? 1 : 0.5)
            .onAppear {
                guard !Theme.motionReduced else { bright = true; return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// A poster with two text lines below it, all as placeholder.
struct TilePlaceholder: View {
    var width: CGFloat = Theme.tileWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LoadField()
                .frame(width: width, height: width * 1.5)
            LoadField(corner: 3).frame(width: width, height: 12)
            LoadField(corner: 3).frame(width: 48, height: 10)
        }
    }
}

/// A grid of poster placeholders.
struct GridPlaceholder: View {
    let columns: Int
    var rails: Int = 3

    var body: some View {
        // **The same columns as the real grid** (`.adaptive` on tile width, leading
        // aligned). With `.flexible` the fields sat in wide cells and the tiles jumped to
        // the left when they appeared. `columns` now only decides how many fields there are.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.tileWidth,
                                               maximum: Theme.tileWidth),
                                     spacing: Theme.tileSpacing, alignment: .topLeading)],
                  alignment: .leading, spacing: 20) {
            ForEach(0 ..< (max(columns, 1) * rails), id: \.self) { _ in
                TilePlaceholder(width: Theme.tileWidth)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lädt")
    }
}

/// A row of poster placeholders, for the home page.
struct RailsPlaceholder: View {
    var landscape = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoadField(corner: 4).frame(width: 168, height: 20)
            HStack(spacing: Theme.tileSpacing) {
                ForEach(0 ..< 5, id: \.self) { _ in
                    LoadField()
                        .frame(width: landscape ? Theme.tileWidth * 2 : Theme.tileWidth,
                               height: landscape ? Theme.tileWidth * 1.125 : Theme.tileWidth * 1.5)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lädt")
    }
}

/// How many titles this library holds.
///
/// **Information, not an action**, so quiet text and no box. It answers "am I
/// through here?"; without it you scroll into uncertainty.
struct CountMark: View {
    let count: Int

    var body: some View {
        Text(verbatim: count.formatted())
            .font(Theme.tile)
            .monospacedDigit()
            .foregroundStyle(Theme.fontVeryQuiet)
            .accessibilityLabel(Text("\(count) Titel"))
    }
}

/// The badge at the top right of a tile.
///
/// **White on dark, not accent.** The accent carries progress and selection; a badge
/// is information. `DisplayRules.tileMark` in the package decides what it shows.
struct TileBadge: View {
    let mark: TileMark

    var body: some View {
        // **10 semibold, letter-spaced:** the badge step of the type scale. 11 and a bold
        // checkmark are on no step; there are three weights, and `.bold` is not one of them.
        HStack(spacing: 3) {
            if mark == .watched {
                Image(systemName: "checkmark").font(Theme.badge)
            }
            if let text = wording {
                Text(verbatim: text).font(Theme.badge).tracking(Theme.badgeLock)
            }
        }
        .foregroundStyle(Theme.font)
        .padding(.horizontal, wording == nil ? 5 : 6)
        .padding(.vertical, 3)
        .background {
            // The border stays: a badge sits on a poster, one of the few places that really
            // needs an edge.
            let form = RoundedRectangle(cornerRadius: 9, style: .continuous)
            form.fill(Theme.reason.opacity(0.78)).overlay { form.strokeBorder(Theme.margin) }
        }
        .padding(6)
    }

    private var wording: String? {
        switch mark {
        case .watched: nil
        case .opened(let n): String(localized: "\(n) offen")
        case .seasons(let n): n == 1 ? String(localized: "1 Staffel")
                                      : String(localized: "\(n) Staffeln")
        }
    }
}

// MARK: - States



/// Errors and empty states appear where they occur, not in an alert.
///
/// **Exactly the template anatomy:** symbol 44 in a circle of 78 in `area` · 22 ·
/// headline 20 semibold · 7 · text 15 `schriftLeise`, at most 262 wide · 24 ·
/// primary button · 16 · quiet button. An earlier smaller variant (symbol 30 in
/// `.light`, headline 15, text 12) played the same role three steps quieter, and
/// `.light` is no longer on the scale.
///
/// **An empty state gets a button only if there is something to do.** Both buttons
/// are therefore optional.
struct EmptyState: View {
    let symbol: String
    let headerLine: LocalizedStringKey
    var text: LocalizedStringKey?
    /// Lets the symbol breathe, for "trying right now". No ring: a ring says "wait",
    /// the symbol keeps saying what it is about.
    var loads = false
    var primaryButton: (title: LocalizedStringKey, perform: () -> Void)?
    var quietButton: (title: LocalizedStringKey, perform: () -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Theme.area)
                    .frame(width: 78, height: 78)
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.fontQuiet)
                    .animation(loads && !Theme.motionReduced
                               ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                               : Theme.reveal) {
                        $0.opacity(loads ? 0.45 : 1)
                    }
            }
            .padding(.bottom, 22)

            Text(headerLine)
                .font(Theme.rail)
                .tracking(Theme.lockRail)
                .foregroundStyle(Theme.font)
                .multilineTextAlignment(.center)
                .padding(.bottom, text == nil ? 0 : 7)

            if let text {
                Text(text)
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 262)
            }

            if let primaryButton {
                PrimaryButton(label: primaryButton.title, symbol: "arrow.clockwise",
                           pick: primaryButton.perform)
                    .fixedSize()
                    .padding(.top, 24)
            }
            if let quietButton {
                Button(action: quietButton.perform) {
                    Text(quietButton.title)
                        .font(Theme.body.weight(.medium))
                        // The quiet button carries the accent: it is the second action, and the accent
                        // marks it as one.
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .padding(.top, primaryButton == nil ? 24 : 16)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 34)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// **An empty section *within* a page,** not the whole page.
///
/// "Keine Folgen" under the season picker, "Nichts Ähnliches gefunden" under the
/// tabs: the page header already stands there, and a second large empty state with
/// circle and headline would be a second page start. Same design as `emptyHint`
/// in `Sources/Shared/SeriesView.swift`.
struct EmptyHint: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(Theme.body)
            .foregroundStyle(Theme.fontVeryQuiet)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }
}

/// **The counterpart to `EmptyHint`: "I don't know".**
///
/// `EmptyHint` says "nothing lies here". It used to say so even when the server had
/// not answered at all, so "Keine Folgen" and "Nichts Ähnliches gefunden" stood
/// there as fact. This is the same component as `DisturbHint` in
/// `Sources/Shared/Style.swift`, with the Mac's metrics and type steps, and **with
/// the same wording**: two sentences for the same situation would be two answers to
/// the same question.
struct DisturbHint: View {
    let model: AppModel
    var retry: (() -> Void)?
    var spacingTop: CGFloat = 40
    /// Who did not answer. Defaults to the user's own Jellyfin server; on a Seerr page
    /// it is Seerr, and the wrong address in the sentence would send the user
    /// debugging the wrong thing.
    var address: String?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 30))
                .foregroundStyle(Theme.fontQuiet)
                .padding(.bottom, 14)

            Text("Server ist abgetaucht")
                .font(Theme.rail)
                .tracking(Theme.lockRail)
                .foregroundStyle(Theme.font)
                .padding(.bottom, 6)

            Text("\(address ?? model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?")
                .font(Theme.body)
                .foregroundStyle(Theme.fontVeryQuiet)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 262)

            if let retry {
                Button(action: retry) {
                    Text("Erneut versuchen")
                        .font(Theme.body.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, spacingTop)
    }
}

// MARK: - Action list

/// What the bottom sheet is on the phone.
///
/// The content comes from `TitleAction` in `Sources/Shared` and is the same on all
/// platforms; only the presentation differs. Here the list opens **in place**,
/// directly under the button, like the season pill. A sheet from below would be
/// foreign on the Mac, and a `Menu` brings system metrics.
struct ActionList: View {
    let actions: [TitleAction]
    @Binding var opened: Bool

    var body: some View {
        VStack(spacing: 0) {
            // **A row is identified by its position, not by `action.id`.** `TitleAction.id`
            // is a fresh `UUID()` per computation; the page rebuilds the list on every
            // refresh, so every row would count as new, and instead of one panel motion the
            // list would fade rows in and out one by one.
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                ActionRow(action: action) {
                    action.perform()
                    withAnimation(Theme.leap) { opened = false }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 260, alignment: .leading)
        // **No shadow** anywhere in this app. What separates the panel from the
        // background is the surface and the one edge `rand` exists for. Corner radius 16
        // like every other own surface.
        .background {
            let form = RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous)
            form.fill(Theme.raised).overlay { form.strokeBorder(Theme.margin, lineWidth: 1) }
        }
    }
}

struct ActionRow: View {
    let action: TitleAction
    let pick: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                // Symbol 15 in a 20 wide column; 14 is on no step of the scale.
                Image(systemName: action.symbol)
                    .font(Theme.body)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                action.label.font(Theme.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(action.cautionary ? Theme.warning : Theme.font)
            .padding(.horizontal, 12)
            .frame(height: Theme.rowHeight)
            .background(hovers ? Theme.hoverArea : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
    }
}

/// A short message that withdraws by itself after three seconds. Errors appear where they occur, not in an alert.
struct HintStrip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Theme.body)
            .foregroundStyle(Theme.font)
            .padding(.horizontal, 14)
            .frame(height: 34)
            // The border stays: the strip floats above the page and is one of the few places
            // that need an edge.
            .background(Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.margin, lineWidth: 1))
    }
}

/// **The back control is a bare arrow, not a round button.**
///
/// It used to exist three times in nearly the same form: as an `Aktionsknopf` with the
/// ring turned off above the settings subpages, as a loose button in `DetailHeader`,
/// and as a third one in the library bar. Now one component, one hit area (40 x 40),
/// one weight (20 semibold), and hover as the only thing it reveals about itself.
struct BackArrow: View {
    let back: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: back) {
            Image(systemName: "chevron.left")
                .font(Theme.rail)
                .foregroundStyle(hovers ? Theme.font : Theme.fontQuiet)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityLabel(Text("Zurück"))
    }
}

// MARK: - Detail page

/// The header of a detail page: arrow on the left, title next to it.
///
/// **No outline, no circle:** a bare chevron, 20 semibold on 40 x 40, like
/// `DetailHeader` in `Sources/Shared/Style.swift`. The title fades in once scrolled far
/// enough.
///
/// **No glass bar behind it.** On the phone it carries the title over the scrolling
/// image. Here the backdrop only spans the right two thirds, so the bar on the left
/// sat on plain background and showed as a dark band, while on the right it
/// disappeared into the image. A strip that is only half there is worse than none.
///
/// Where the page currently stands.
///
/// **Why this is its own object and not `@State` in the page.**
///
/// `onScrollGeometryChange` fires on every scroll tick. Writing into `@State` of the
/// page makes SwiftUI re-evaluate its **entire body**: on a series page that is the
/// header, the tab row and the episode list, sixty times a second. When dragging
/// fast, the main thread cannot keep up, the scroll view loses its grip and jumps.
///
/// With `@Observable`, only the view that **reads** the value is redrawn, and that is
/// solely `DetailHeader`. The page just passes the holder on.
@MainActor
@Observable
final class HeaderState {
    var offset: CGFloat = 0
}

struct DetailHeader: View {
    let title: String
    /// Where the page stands; see `HeaderState`.
    let state: HeaderState
    private var offset: CGFloat { state.offset }

    /// **Where the bar starts to appear: derived, not guessed.**
    ///
    /// It should be there exactly when the large title disappears under it. From the
    /// geometry of the hero header:
    ///
    /// - The title starts `Theme.titleHeight + 98` below the top of the hero image and is
    ///   42 pt high.
    /// - The bar itself is `Theme.titleHeight + 24` high.
    ///
    /// The top of the title reaches the bottom of the bar at 98 - 24 = **74**, and 42 pt
    /// later it is completely underneath. The bar fades in over exactly that distance.
    ///
    /// `Stil.heroHeightValue - 150` = 230 was a value from the iPhone layout, where hero image
    /// and title sit differently; on the Mac the bar would only appear after the title
    /// was long gone.
    var since: CGFloat = 98 - 24
    /// Over what distance it fades in: the height of the large title.
    var over: CGFloat = 42
    let back: () -> Void

    private var strength: Double {
        guard over > 0 else { return 1 }
        return Double(min(max((offset - since) / over, 0), 1))
    }

    var body: some View {
        HStack(spacing: 4) {
            BackArrow(back: back)

            Text(verbatim: title)
                .font(Theme.categoryLarge)
                .tracking(Theme.lockCategory)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .opacity(strength)

            Spacer(minLength: 0)
        }
        // **Flush with the content.** The window controls sit above the sidebar, not above
        // the content area, so no extra spacing is needed. The arrow sits on the same line
        // as "Weiterschauen" on the home page; the 8 pt offset is the button's own padding.
        .padding(.leading, Theme.edgeSpacing - 8)
        .padding(.trailing, Theme.edgeSpacing)
        // Since content scrolls under the title bar, the arrow would otherwise sit on the
        // window edge. 24 puts it at the same height as the sidebar's wordmark.
        .padding(.top, 24)
        // **Air below the text.** The bar reaches slightly lower than its content; otherwise
        // the title sits on the hairline. The amount appears twice: once as spacing, so the
        // text stays in place, and once in the height, so the bar grows downward instead of
        // pushing the text along.
        .padding(.bottom, 10)
        .frame(height: Theme.titleHeight + 24 + 10, alignment: .bottom)
        // **The bar that appears while scrolling:** a hairline at the bottom, behind it the
        // background, which becomes opaque with the scroll distance.
        //
        // It also covers the edge effect macOS 26 draws at the top of every scroll view.
        // That effect was once disabled with `scrollEdgeEffectHidden`, which caused a
        // running trackpad gesture to stick at the edge (see `pagesScroll`). This bar is
        // the answer: it lies there anyway, and it is ours.
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1).opacity(strength)
        }
        .background {
            ZStack {
                // **Only when it does something.**
                //
                // `BarGlass` is a *live* blur: it smears whatever scrolls underneath and
                // recomputes that every frame, even when the mask sets it to zero and nothing is
                // visible. Over a scrolling page that is the most expensive surface in the window.
                // Added to the view only from a hint of visibility on, it costs nothing while
                // scrolling through the hero image.
                //
                // **And no glass at all.** Apple's materials all carry a light layer, even the
                // thinnest. Over our background and colorful posters that turns into a gray block
                // lighter than the page, and it flashes while bouncing because its strength is
                // controlled through a mask recomputed per frame. A plain surface cannot flash, is
                // exactly as dark as the page and costs nothing.
                //
                // The soft gradient at rest is gone. It kept the back arrow legible on a bright hero
                // image on the phone, where the image reaches both edges. On the Mac the backdrop
                // only spans the right two thirds; the arrow sits on plain background on the left,
                // where the gradient was a dark glow with no purpose. What remains is the bar that
                // appears while scrolling.
                Theme.reason.opacity(strength)
            }
            .ignoresSafeArea(edges: .top)
        }
    }
}

/// A horizontal row with arrows for paging.
///
/// **Mac only.** On iPhone and TV one swipes or presses; here there is a pointer and
/// possibly no trackpad, and a horizontal row without arrows would be unreachable.
/// The reason is the input method, exactly the kind of deviation that is allowed.
///
/// The arrows appear on hover and only where there is something to fetch: none on
/// the left at the left edge, none on the right at the right edge.
struct PagingRail<ContentBody: View>: View {
    /// The side margin. **Zero if the caller already sets one,** otherwise the tiles sit
    /// 48 pt inset under a heading that starts at 24, and the line no longer matches.
    var margin: CGFloat = Theme.edgeSpacing
    var stepRange: CGFloat = 3
    var widthJePiece: CGFloat = Theme.tileWidth + Theme.tileSpacing
    /// How tall a tile's **image** is, not the whole tile.
    ///
    /// The paging arrows belong visually in the middle of the image. Centered on the
    /// whole row they sit too low, because two text lines follow under each image; for a
    /// poster that is about 45 pt of offset.
    var imageHeight: CGFloat = Theme.tileHeight
    @ViewBuilder let content: ContentBody

    @State private var hovers = false
    /// **The raw numbers live in a holder that is not observed.**
    ///
    /// Three `@State` values used to be written on every scroll tick, so the body was
    /// re-evaluated and laid out sixty times a second while the next tick was already
    /// due. That is the sticking on a fast swipe: the motion drops frames because the row
    /// is being laid out again beside it, and a swipe that drops frames does not pick up
    /// again.
    ///
    /// A plain class is not `@Observable`: writing invalidates nothing. It is read only at
    /// the moment of paging.
    @State private var metrics = RailsMetrics()
    /// **Only the decision is state, not the number.** Whether there is more to fetch on
    /// the left or right changes twice per row, not sixty times a second.
    @State private var canLeft = false
    @State private var canRight = false

    @MainActor final class RailsMetrics {
        var offset: CGFloat = 0
        var total: CGFloat = 0
        var visible: CGFloat = 0
    }

    /// What a tick tells about the row, in one value so a single observer is enough.
    private struct MeasureValues: Equatable {
        let offset: CGFloat
        let total: CGFloat
        let visible: CGFloat
    }

    var body: some View {
        ScrollView(.horizontal) {
            // **`LazyHStack`, not `HStack`.** An `HStack` builds every tile immediately (eleven
            // images in the cast row, as many in the similar-titles row), in the same frame in
            // which the page slides in. That was the jank: the motion was not hard, it dropped
            // frames because half the page was being built next to it. On the way out everything
            // already existed, which is why that direction ran smoothly.
            LazyHStack(alignment: .top, spacing: Theme.tileSpacing) { content }
                .padding(.horizontal, margin)
                // So the tiles are not clipped at the top when they grow on hover.
                .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .scrollPosition($spot, anchor: .leading)
        // **One observer instead of two geometry readers.** The two `GeometryReader`s wrote
        // into state during layout and triggered further layout passes, which also cost
        // frames.
        .onScrollGeometryChange(for: MeasureValues.self) {
            MeasureValues(offset: $0.contentOffset.x,
                      total: $0.contentSize.width,
                      visible: $0.containerSize.width)
        } action: { _, new in
            metrics.offset = new.offset
            metrics.total = new.total
            metrics.visible = new.visible
            #if DEBUG
            // Measured, because the left arrow is visible on a freshly opened page: is the row really at zero?
            RailsProbe.report(offset: new.offset, total: new.total,
                               visible: new.visible)
            #endif
            // **A threshold of four points, not one.**
            //
            // `anchor: .leading` holds the row at its edge, and while the window settles on its
            // width (measured: 172 to 1131) a fraction of a point can remain. One point is too
            // tight; four is below perception and above the noise.
            //
            // **And nothing to page means no arrow.** If the row is narrower than its window
            // (measured: 328 in 1131), there is nothing to fetch on either side.
            let fits = new.total <= new.visible + 4
            let left = !fits && new.offset > 4
            let right = !fits && new.offset + new.visible < new.total - 4
            if left != canLeft { canLeft = left }
            if right != canRight { canRight = right }
        }
        // Top-aligned and placed by hand: 4 pt is the row's vertical margin, 17 is half the
        // button height.
        .overlay(alignment: .topLeading) {
            if hovers, canLeft {
                arrow("chevron.left", "Zurückblättern") { paging(-1) }
                    .offset(y: 4 + imageHeight / 2 - 17)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovers, canRight {
                arrow("chevron.right", "Weiterblättern") { paging(1) }
                    .offset(y: 4 + imageHeight / 2 - 17)
            }
        }
        .onHover { hovers = $0 }
        // **The end fades too.** Previously only hovering was animated; paging to the edge
        // made the arrow vanish abruptly.
        .animation(Theme.timeArrow, value: hovers)
        .animation(Theme.timeArrow, value: canLeft)
        .animation(Theme.timeArrow, value: canRight)
        #if DEBUG
        .task {
            try? await Task.sleep(for: .seconds(4))
            RailsProbe.idleStatus(offset: metrics.offset, total: metrics.total,
                                 visible: metrics.visible)
        }
        #endif
    }

    @State private var spot: ScrollPosition = .init(idType: CGFloat.self)

    private func paging(_ bearing: CGFloat) {
        let range = widthJePiece * stepRange
        let target = max(0, min(metrics.total - metrics.visible,
                              metrics.offset + bearing * range))
        withAnimation(Theme.reveal) {
            spot.scrollTo(x: target)
        }
    }

    private func arrow(_ symbol: String, _ name: LocalizedStringKey,
                       _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Image(systemName: symbol)
                .font(Theme.listTitle)
                .foregroundStyle(Theme.font)
                .frame(width: 34, height: 34)
                // A surface without a drawn edge, and a field instead of a circle: a button without a
                // label is square. Below 34 pt the small corner radius applies.
                .background(Theme.area,
                            in: RoundedRectangle(cornerRadius: Theme.cornerSmall,
                                                 style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text(name))
        .padding(.horizontal, 6)
        .transition(.opacity)
    }
}


/// **What holds for every page scroll view.**
///
/// **The edge effect is no longer disabled: it caused the sticking.** This used to
/// call `scrollEdgeEffectHidden(true, for: .all)`, a macOS 26 API, on **every** scroll
/// view in the app. An A/B comparison of two builds confirmed it: with the effect
/// back, scrolling up and down no longer sticks. The symptom was a running trackpad
/// gesture sticking at one end and only taking hold again after lifting the fingers.
/// Drawing load was not the limit: a 313 pt drag at 120 Hz through AppKit's own clip
/// view ran with 0 to 3 % dropped frames.
///
/// **What that line was for is now done by the bar.** macOS 26 draws a soft gradient
/// at the edges of a scroll view. At the top it is covered by `Bestandsleiste` or
/// `DetailHeader`, which have their own opaque bar in `reason` once scrolled. At the
/// bottom and sides it stays; against a background of `#101010` a gradient fading to
/// the same color is not noticeable. A design answer instead of a disabled API.
///
/// **It bounces only when there is something to bounce.** Decided here, not left to
/// `.basedOnSize`: one page carried 446 pt of content in an 833 pt window and still
/// accepted scroll gestures, bouncing where there was nothing to scroll. `.basedOnSize`
/// alone did not catch this, and on long, truly scrollable pages bouncing disappeared
/// **entirely**. On Apple platforms bouncing is the feedback "this is the end", and it
/// belongs there.
///
/// So it is measured: if the content is taller than its window it bounces as usual;
/// if it fits, it does not. The initial value is `.automatic`, so until the first
/// measurement it behaves like any other system scroll view and no long page loses
/// its bounce.
extension View {
    func pagesScroll() -> some View { modifier(PagesScroll()) }
}

private extension View {
    /// Separates the availability check from the body; otherwise the whole modifier would have to appear twice.
    @ViewBuilder
    func edgeTopFree() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}

private struct PagesScroll: ViewModifier {
    /// Is there anything to scroll? Until the first measurement: yes.
    @State private var long = true

    func body(content: Content) -> some View {
        content
            .scrollBounceBehavior(long ? .automatic : .basedOnSize)
            // **The edge effect is removed only at the top, not all around.**
            //
            // macOS 26 puts a soft veil on every edge of a scroll view. At the top lies our own
            // bar with the page title, and the veil lies over it, so the top is not quite white.
            //
            // Disabling it on all edges once caused the sticking while scrolling (confirmed with
            // a probe). So only `.top`: the edge where we draw something of our own. At the
            // bottom and sides the effect stays where it is in nobody's way.
            .edgeTopFree()
            // **Only the answer is state, not the height.** It changes twice per page, not sixty times a second.
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentSize.height > $0.containerSize.height + 4
            } action: { _, new in
                if new != long { long = new }
            }
    }
}


// MARK: - Adoption

// MARK: - Choice via a panel

/// **One value, one button, one panel below.**
///
/// The button carries the **chosen value**, not one of eight options. What is on offer
/// is in the panel, which opens **in place** like the season picker, the more-list and
/// the loading panel. A `Menu` would be the obvious choice and exactly therefore
/// wrong: it brings system metrics, system corners and a system material.
///
/// On the iPhone the counterpart is `ValuePill` plus `SelectionSheet`, where it comes
/// from below; here it stays in place. That is the deviation allowed because sheets
/// from below do not belong on the Mac.
///
/// **At most one of all choice buttons is open.** Each button used to keep its own
/// state and know nothing of the others, and the catcher for "click elsewhere" lay
/// behind its own button while the neighbor in the same row lay above it. Clicking
/// "Alle" and then "Zuletzt" put the second pop-up over the first, which felt like
/// clicking into nothing; the other should simply close.
///
/// A shared supervisor instead of one state per page: the rule then holds wherever
/// choice buttons stand side by side, without any call site knowing about it.
@MainActor
@Observable
final class SelectionSupervision {
    static let shared = SelectionSupervision()
    var opened: UUID?
}

/// Escape for an open dropdown panel. `onExitCommand` hangs on the responder chain and
/// does not reach a panel in an overlay (see `LoadPanel`); an invisible button with
/// `cancelAction` does. Present only while the panel is open, so Escape belongs to
/// others otherwise.
private struct PanelEscape: ViewModifier {
    let opened: Bool
    let toward: () -> Void
    func body(content: Content) -> some View {
        content.background {
            if opened {
                Button("") { toward() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// Escape closes the panel while it is open.
    func panelEscape(_ opened: Bool, toward: @escaping () -> Void) -> some View {
        modifier(PanelEscape(opened: opened, toward: toward))
    }
}

struct SelectionButton<Record: Identifiable>: View {
    let symbol: String
    /// What currently applies: the button's label.
    let value: String
    let entries: [Record]
    let label: (Record) -> String
    let isSelected: (Record) -> Bool
    let select: (Record) -> Void
    var panelWidth: CGFloat = 220

    /// Which one am I among the choice buttons; see `SelectionSupervision`.
    @State private var identifier = UUID()
    private var supervision: SelectionSupervision { .shared }
    private var opened: Bool { supervision.opened == identifier }

    var body: some View {
        Chip(label: value, symbol: opened ? "chevron.up" : symbol, active: opened) {
            withAnimation(Theme.leap) {
                // **If another one is open, this click counts as a click elsewhere.** It closes the
                // other and does nothing else, as a menu on the Mac behaves.
                if let other = supervision.opened, other != identifier {
                    supervision.opened = nil
                } else {
                    supervision.opened = opened ? nil : identifier
                }
            }
        }
        // The catcher lies **under** the panel, not over it: a click outside closes, a
        // click inside selects. Same design as the loading panel on the movie page.
        .background {
            if opened {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .frame(width: 4000, height: 4000)
                    .onTapGesture { withAnimation(Theme.leap) { supervision.opened = nil } }
            }
        }
        .panelEscape(opened) { withAnimation(Theme.leap) { supervision.opened = nil } }
        .overlay(alignment: .topLeading) {
            if opened {
                panel
                    .offset(y: 38)
                    .transition(.expand(from: .topLeading))
                    .zIndex(40)
            }
        }
        // Leaving the page with a panel open must not make the next page swallow its first click.
        .onDisappear { if opened { supervision.opened = nil } }
    }

    private var panel: some View {
        SelectionPanel(entries: entries, label: label,
                  isSelected: isSelected, width: panelWidth) { entryRecord in
            select(entryRecord)
            withAnimation(Theme.leap) { supervision.opened = nil }
        }
    }
}

/// The panel under a `Wahlknopf` or a `Titelwahl`.
struct SelectionPanel<Record: Identifiable>: View {
    let entries: [Record]
    let label: (Record) -> String
    let isSelected: (Record) -> Bool
    var width: CGFloat = 220
    /// **A section before an entry:** a divider, then the heading. In the title menu of
    /// Filme and Serien, "Bibliotheken" stands above the individual libraries, set apart
    /// from "Alle" and "Sammlungen", which are not libraries. Like `SelectionSheet.category`
    /// on the iPhone; written like the sidebar sections, so without capitals.
    var category: (Record) -> LocalizedStringKey? = { _ in nil }
    let select: (Record) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entryRecord in
                if let over = category(entryRecord) {
                    VStack(alignment: .leading, spacing: 0) {
                        SheetLine().padding(.vertical, 4)
                        SidebarCategory(text: over)
                            .padding(.horizontal, 2)
                            .padding(.top, 4)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                SelectionPanelRow(text: label(entryRecord),
                               selected: isSelected(entryRecord)) {
                    select(entryRecord)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: width, alignment: .leading)
        // No shadow anywhere. The surface and the one edge `rand` exists for separate the panel from the background.
        .background {
            let form = RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous)
            form.fill(Theme.raised).overlay { form.strokeBorder(Theme.margin, lineWidth: 1) }
        }
    }
}

/// **The page title as a menu:** Filme and Serien with a chevron, as on the iPhone.
///
/// From two entries in the ``SectionOffering`` on, the title becomes a button: "Alle"
/// on top, then "Sammlungen", after a divider the libraries. This replaces the
/// "Bibliotheken" section in the sidebar, which was a second path to the same thing
/// and one that left the section.
///
/// On the iPhone the choice comes as a sheet from below; here it opens in place like
/// any `Wahlknopf` and shares its supervisor, so at most one panel is open.
struct TitleSelection<Record: Identifiable>: View {
    /// What the title shows.
    let title: Text
    let entries: [Record]
    let label: (Record) -> String
    let isSelected: (Record) -> Bool
    var category: (Record) -> LocalizedStringKey? = { _ in nil }
    let select: (Record) -> Void

    @State private var identifier = UUID()
    @State private var hovers = false
    private var supervision: SelectionSupervision { .shared }
    private var opened: Bool { supervision.opened == identifier }

    var body: some View {
        Button {
            withAnimation(Theme.leap) {
                if let other = supervision.opened, other != identifier {
                    supervision.opened = nil
                } else {
                    supervision.opened = opened ? nil : identifier
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                title
                    .font(Theme.titleLarge)
                    .tracking(Theme.lockTitle)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                Image(systemName: opened ? "chevron.up" : "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hovers || opened ? Theme.font : Theme.fontQuiet)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .background {
            if opened {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .frame(width: 4000, height: 4000)
                    .onTapGesture { withAnimation(Theme.leap) { supervision.opened = nil } }
            }
        }
        .panelEscape(opened) { withAnimation(Theme.leap) { supervision.opened = nil } }
        .overlay(alignment: .topLeading) {
            if opened {
                SelectionPanel(entries: entries, label: label,
                          isSelected: isSelected, width: 260, category: category) { entryRecord in
                    select(entryRecord)
                    withAnimation(Theme.leap) { supervision.opened = nil }
                }
                .offset(y: 44)
                .transition(.expand(from: .topLeading))
                .zIndex(40)
            }
        }
        .onDisappear { if opened { supervision.opened = nil } }
    }
}

/// A row in a `Wahlknopf` panel. **Chosen means white, not accent:** a choice among
/// siblings is ranking, and ranking is carried by tone and surface.
private struct SelectionPanelRow: View {
    let text: String
    let selected: Bool
    let pick: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                Text(verbatim: text)
                    .font(Theme.body)
                    .foregroundStyle(selected ? Theme.font : Theme.fontQuiet)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.listTitle)
                        .foregroundStyle(Theme.font)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.rowHeight)
            .background(hovers ? Theme.hoverArea : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// **The bar that appears while scrolling, on a library page.**
///
/// The title (for example "Filme") stays at the top while scrolling, with a gradient
/// behind it, and the filter elements fade away.
///
/// **It depends on an opacity, not on a height.** That is where the iPhone header once
/// fell into a loop: hanging a header's height on the scroll offset changes the safe
/// area that is part of the measurement, so the header shrinks, the margin shrinks,
/// the offset falls back, the header grows. Here the bar always keeps the same height
/// and lies as an overlay above the scroll view; only how visible it is gets
/// measured, so no layout can feed back.
///
/// The large title scrolls away with the content, the small one fades in, and the two
/// are never visible at once. Same design as `DetailHeader`, and **a gradient, not
/// glass:** the background is `#101010` and the gradient fades to the color beneath.
struct StateBar: View {
    let title: LocalizedStringKey
    /// When the heading comes from the server: a library name is not translated.
    var name: String?
    let state: HeaderState
    /// **Where it fades in: derived, not guessed.**
    ///
    /// The large title starts `Theme.contentTop` below the top of the content and is about
    /// 33 pt high (28 pt bold); the bar is `Theme.headerBarHeight` high. Its bottom edge
    /// reaches the bar's bottom edge at `contentTop + 33 - headerBarHeight`, at which
    /// point it is entirely underneath. Over the next 26 pt the bar fades in, so the two
    /// titles are never visible at once.
    ///
    /// Computed, not typed: if the top margin changes, the point moves with it.
    var since: CGFloat = max(Theme.contentTop + 33 - Theme.headerBarHeight, 0)
    var over: CGFloat = 26
    /// **The back arrow stays put when there is one.**
    ///
    /// On a library subpage the arrow sits in the content and would scroll under the bar,
    /// so someone far down could only get back with Cmd+[. It belongs in the bar, and
    /// unlike the title it does not fade in: an exit that only exists after some scroll
    /// distance is none.
    var back: (() -> Void)?

    private var strength: Double {
        guard over > 0 else { return 1 }
        return Double(min(max((state.offset - since) / over, 0), 1))
    }

    var body: some View {
        HStack(spacing: 4) {
            if let back {
                BackArrow(back: back)
                    .padding(.leading, -8)
            }
            Group {
                if let name { Text(verbatim: name) } else { Text(title) }
            }
            .font(Theme.categoryLarge)
            .tracking(Theme.lockCategory)
            .foregroundStyle(Theme.font)
            .lineLimit(1)
            .opacity(strength)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.edgeSpacing)
        .frame(height: Theme.headerBarHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1).opacity(strength)
        }
        // **No permanent gradient: the background arrives only with scrolling.**
        //
        // There used to be a `LinearGradient` from `reason` to transparent that depended on
        // nothing; only the opaque surface beneath followed `staerke`. So the gradient always
        // lay over the title, even on a page that was not scrolled.
        //
        // On the iPhone it has a job: content runs under the clock and battery, which need
        // backing. On the Mac the window bar sits above, so there is nothing to cover.
        //
        // It was also a translucent layer over a moving surface, which has to be recomposited
        // every frame even when nothing of it is visible.
        .background {
            Theme.reason.opacity(strength)
                .ignoresSafeArea(edges: .top)
                // The background takes no clicks, only the arrow inside it.
                .allowsHitTesting(false)
        }
    }
}


#if DEBUG
/// **Does a row really sit at zero when it appears?**
///
/// The left paging arrow shows right after a page opens, and a click on it moves the
/// row "a millimeter". Both mean the measured offset is not zero. This probe writes
/// the first measurements of each row to the log, only the first, or there would be
/// one line per frame.
@MainActor
enum RailsProbe {
    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "reihe")
    private static var reported = 0

    /// Only the cases that say something: **when is the left arrow enabled** and at
    /// which offset. One line per frame would be unreadable, and the first twelve
    /// measurements all fell into startup, when the row was still 172 pt wide.
    static func report(offset: CGFloat, total: CGFloat, visible: CGFloat) {
        guard offset > 1, reported < 20 else { return }
        reported += 1
        let row = String(format: "LINKSPFEIL frei #%d · Versatz %.2f · gesamt %.0f · sichtbar %.0f",
                           reported, offset, total, visible)
        log.notice("\(row, privacy: .public)")
    }

    /// How a row stands after layout: once per row, late.
    static func idleStatus(offset: CGFloat, total: CGFloat, visible: CGFloat) {
        guard calm < 8 else { return }
        calm += 1
        let row = String(format: "Ruhelage #%d · Versatz %.2f · gesamt %.0f · sichtbar %.0f",
                           calm, offset, total, visible)
        log.notice("\(row, privacy: .public)")
    }
    private static var calm = 0
}
#endif

// MARK: - Expanding

extension AnyTransition {
    /// **A panel grows out of its button; it does not fly in.**
    ///
    /// This used `.move(edge: .top)` in five places. That moves a view by its **own full
    /// height**: a 200 pt list came from 200 pt above its resting place, crossed the
    /// elements above it on the way, and had nothing to do with the button that opens it.
    ///
    /// The rule: what opens does so **where** it was triggered and closes the same way.
    /// Hence an anchor, the panel corner that touches the button, and a small scale
    /// instead of a distance. 0.94 is enough to see the origin and little enough that
    /// nothing pops.
    ///
    /// Under Reduce Motion only the fade remains: no path, no size change.
    static func expand(from anchor: UnitPoint) -> AnyTransition {
        Theme.motionReduced
            ? .opacity
            : .scale(scale: 0.94, anchor: anchor).combined(with: .opacity)
    }
}
