import JellyfinKit
import SwiftUI

// MARK: - Focus in custom button styles

/// Why `@Environment(\.isFocused)` and not `@FocusState`:
///
/// `FocusState` belongs to the view that holds it, so a style reused on every page would
/// need each page to keep and pass down its own flag. `isFocused` lives in the environment
/// of the button itself, and SwiftUI sets it exactly where `makeBody` runs, so the style
/// knows by itself.
///
/// The detour through an inner view is needed: `makeBody` is a function, not a view, and
/// `@Environment` read there stays empty.

/// The button: a muted surface at rest, white when focused.
///
/// The focused look is character for character the iPhone's `PrimaryButtonStyle`. That is the
/// translation key: what means "this is the main action" there means "the remote is here"
/// on the TV.
struct ThemedButtonStyle: ButtonStyle {
    /// Without a label, only a symbol: square instead of wide.
    var onlySymbol = false
    /// **Lower where the button is not the main thing.**
    ///
    /// The season pill sits next to a row title, not in the header's button row; at the
    /// full 76 it looked heavy there. Colors and focus behavior stay the same, which is why
    /// it uses this style at all.
    var height: CGFloat = Theme.buttonHeight
    /// **When active, only the symbol takes the accent**, as on iPhone (watchlist on): no
    /// surface of its own, the surface stays like the neighbors'. Not when focused: on the
    /// white focus surface the symbol uses `reason`.
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, onlySymbol: onlySymbol, height: height, active: active)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let onlySymbol: Bool
        let height: CGFloat
        let active: Bool
        @Environment(\.isFocused) private var focus
        @Environment(\.isEnabled) private var released

        var body: some View {
            configuration.label
                .font(Theme.button)
                // A button that wraps grows taller than its neighbors and skews the whole
                // row. Keep labels short.
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, onlySymbol ? 0 : (height < Theme.buttonHeight ? 28 : 40))
                .frame(width: onlySymbol ? height : nil, height: height)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                // Focus lifts the pill, the same step as the tile. Layout is unaffected:
                // `scaleEffect` applies after layout and moves no neighbor, so a smaller
                // step would just make the button react less than everything around it.
                .scaleEffect(configuration.isPressed ? 0.97 : (focus ? Theme.focusMagnifier : 1))
                .animation(Theme.focusAnimation, value: focus)
        }

        /// Disabled means muted, not translucent, same as on iOS: white at 40 percent looks
        /// like a button that is still waiting rather than one that does not respond.
        private var foreground: Color {
            guard released else { return Theme.fontVeryQuiet }
            if focus { return Theme.reason }
            return active ? Theme.accent : Theme.font
        }

        private var background: Color {
            guard released else { return Theme.area }
            return focus ? .white : Color.white.opacity(0.10)
        }
    }
}

/// The tile: it grows when focused. Nothing else.
///
/// Two earlier attempts were off, an accent ring and then a gray surface around it. Both
/// **added** something to the tile, and both looked clean on two single tiles but muddy in
/// a row with six neighbors.
///
/// What remains is distance: the focused tile stands closer. It is also the only option
/// that needs no decoration, and the design says the artwork should be the only color in
/// the room.
///
/// Explicitly not `.buttonStyle(.card)`: Apple's card brings shadow, parallax and a flash.
struct TileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focus
        @Environment(\.tilePreload) private var preload

        var body: some View {
            configuration.label
                .scaleEffect(focus ? Theme.focusMagnifier : 1)
                .animation(Theme.focusAnimation, value: focus)
                // **Fetch the series state before the click**, debounced: swiping through a
                // row triggers nothing, while someone resting 150 ms on a tile usually has
                // the state by the time they press, and the series page's main button names
                // the right episode immediately.
                .task(id: focus) {
                    guard focus, let preload else { return }
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    await preload()
                }
        }
    }
}

extension EnvironmentValues {
    /// What a tile preloads while it holds focus. Set by `TileMenu`, read by
    /// `TileStyle`.
    @Entry var tilePreload: (@MainActor () async -> Void)? = nil
}

/// Tab of the top bar. Three states instead of two: resting, selected, focused. iOS has no
/// middle one because the finger is where it points.
struct TabStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, selected: selected)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                // **Focus does not carry the selection.** On the TV, color shows what is
                // selected, and VoiceOver does not see color. Without this, the open tab
                // sounds like any other.
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .font(.system(size: 30, weight: focus || selected ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 26)
                .padding(.top, 10)
                .padding(.bottom, 18)
                // Quiet, not loud: since focus switches tabs here, "focused" and "open" are
                // the same thing. A full white surface would be too much for a single
                // statement.
                .background {
                    if focus {
                        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    }
                }
                .scaleEffect(focus ? Theme.focusMagnifier : 1)
                .overlay(alignment: .bottom) {
                    // The accent line comes unchanged from `Reiter` in Style.swift: 2 pt
                    // there, 4 here.
                    if selected {
                        Capsule().fill(Theme.accent)
                            .frame(height: 4)
                            .padding(.horizontal, 26)
                            .padding(.bottom, 6)
                    }
                }
                .animation(Theme.focusAnimation, value: focus)
        }

        private var foreground: Color {
            if focus || selected { return Theme.font }
            return Theme.fontVeryQuiet
        }
    }
}

/// Filter chip. The only place where focus and selection meet, so the focused, selected
/// chip additionally gets the ring.
struct ChipStyle: ButtonStyle {
    let an: Bool

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, an: an)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let an: Bool
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                // **Focus does not carry the selection.** On the TV, color shows what is
                // selected, and VoiceOver does not see color. Without this, the open tab
                // sounds like any other.
                .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
                // **One weight, two fills**, as on iPhone.
                //
                // Selected used to be `reason` on a white surface, character for character
                // the main button. On a page with several chips that means several fully
                // filled objects, and the brand rules allow exactly one. The weight change
                // was also a problem: semibold is wider, and in a horizontal row that
                // shifts every neighbor to the right.
                //
                // The border goes too. A surface says "you can press here"; focus says the
                // rest.
                .font(Theme.tile)
                .foregroundStyle(an ? Theme.reason : Theme.fontQuiet)
                .padding(.horizontal, 22)
                .frame(height: Theme.chipHeight)
                .background(area, in: Capsule())
                .scaleEffect(focus ? Theme.focusMagnifier : 1)
                .animation(Theme.focusAnimation, value: focus)
        }

        /// **Selection carries the accent here, and that is an exception.**
        ///
        /// This first used `Theme.font`, a white surface, which was right while the text
        /// on it was `reason`. Then the text switched to white while the surface stayed:
        /// **white on white**, and the selected filter was unreadable.
        ///
        /// Next came one step up, `erhoeht` against `area`, as on iPhone. Readable, but
        /// the two tones (#303030 against #262626) are distinguishable at a desk and not at
        /// three meters.
        ///
        /// **Distance is why the TV may deviate.** A brightness step does not survive three
        /// meters, a color change does. The selected chip is therefore an accent capsule
        /// with `reason` on it (10.8:1), and the color appears nowhere else in the row.
        ///
        /// Focus loses nothing: it is not a white surface here but a light veil plus 6
        /// percent size. On the selected chip the light accent replaces the veil, so it
        /// also brightens on focus instead of standing still.
        private var area: Color {
            if an { return focus ? Theme.accentLight : Theme.accent }
            return focus ? Theme.focusArea : Theme.area
        }
    }
}

/// **The divider between the choice and its settings** in a capsule row: library | filter,
/// sort on movies and series, genre | sort on the watchlist. Defined once so both rows
/// carry the same divider.
struct CapsuleSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.margin)
            .frame(width: 2, height: Theme.chipHeight * 0.6)
            .accessibilityHidden(true)
    }
}

/// **A capsule that opens something**: library and sort in the library's chip row.
///
/// Same shape as `ChipStyle` so the row has one shape. What sets it apart from an unselected
/// filter: semibold text and the arrow. The arrow belongs in the style, not in every label.
///
/// The arrow uses opacity, not its own color, so it follows the text. With a fixed color it
/// vanished in the sort button on the white focus surface.
struct CapsuleStyle: ButtonStyle {
    /// **A leading symbol instead of the trailing arrow**, like `ValuePill` on iPhone.
    /// Filter and sort appear there as a pill with symbol and value, without an arrow; the
    /// arrow only belongs to the library choice at the title. `nil` means the arrow as
    /// before.
    var symbol: String? = nil
    /// The trailing arrow: down because the capsule opens something, right where it leads
    /// to a page (for example "Teil der Sammlung").
    var arrow = "chevron.down"

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, symbol: symbol, arrow: arrow)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let symbol: String?
        let arrow: String
        @Environment(\.isFocused) private var focus

        var body: some View {
            HStack(spacing: 10) {
                if let symbol {
                    // Quieter than the value, as on iPhone (`schriftLeise` against
                    // `font`). Via opacity so it also follows the text on the focus
                    // surface.
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .medium))
                        .opacity(0.6)
                        .accessibilityHidden(true)
                }
                configuration.label
                    .lineLimit(1)
                if symbol == nil {
                    Image(systemName: arrow)
                        // Semibold, not bold: bold appears exactly once, on the page title.
                        .font(.system(size: 18, weight: .semibold))
                        .opacity(0.6)
                        .accessibilityHidden(true)
                }
            }
            // Same step as the neighboring `ChipStyle`; it is the same chip.
            .font(Theme.tile)
            .foregroundStyle(Theme.font)
            .padding(.horizontal, 22)
            .frame(height: Theme.chipHeight)
            .background(focus ? Theme.focusArea : Theme.raised, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : (focus ? Theme.focusMagnifier : 1))
            .animation(Theme.focusAnimation, value: focus)
        }
    }
}

/// **One row in the player's settings bar.**
///
/// Like `ChipStyle`, but full width and with square corners instead of a capsule: the bar is
/// a list, not a row of tags. Selection is white again, focus the calm surface, the same
/// rule as everywhere so the bar does not read as a foreign body.
struct BarsStyle: ButtonStyle {
    let an: Bool

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, an: an)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let an: Bool
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
                .foregroundStyle(an ? Theme.reason : Theme.font)
                .background(area, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                // One row across the full bar width: the wide step.
                .scaleEffect(focus ? Theme.focusMagnifierWide : 1)
                .animation(Theme.focusAnimation, value: focus)
        }

        /// **The white fill stays here**, unlike the filter chip.
        ///
        /// The top bar on the TV is what the bottom bar is on iPhone: the place that shows
        /// where you are. Its text is `reason` on white and therefore readable. The earlier
        /// bug only affected the filter chip, whose text switched to white while its
        /// surface stayed white.
        private var area: Color {
            if an { return Theme.font }
            return focus ? Theme.focusArea : .clear
        }
    }
}

/// Row in a picker list: track choice, settings.
struct RowsStyle: ButtonStyle {
    /// **A secondary action: quieter, but only while resting.**
    ///
    /// "Verlauf loeschen" and similar rows used to be tinted gray at the call site, also
    /// when focused. On the focus surface (white 12 %), `schriftSehrLeise` has only 3.59:1,
    /// so the row you are standing on was the least readable one. It belongs here because
    /// only the style knows about focus.
    var quiet = false

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, quiet: quiet)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let quiet: Bool
        @Environment(\.isFocused) private var focus
        @Environment(\.isEnabled) private var released

        var body: some View {
            configuration.label
                .font(.system(size: 30, weight: focus ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 26)
                .frame(height: Theme.rowsHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                // **Padding and height first, then the surface.** The other way round, the
                // surface wraps the text instead of the row: the outline sticks to the text
                // and the padding ends up outside. On the wide settings rows this is hardly
                // noticeable, in the narrow action panel immediately.
                //
                // The same calm surface as everywhere else, not white. White stays reserved
                // for action buttons.
                .background(focus ? Theme.focusArea : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .animation(Theme.focusAnimation, value: focus)
        }

        /// **Disabled means muted**, the same rule as `ThemedButtonStyle` next to it. It was
        /// missing here: rows such as "Immer Direct Play" in Playback and the bitrate row
        /// are disabled but looked like any other row. Whoever navigates to them gets no
        /// focus and no explanation, which made the section's initial focus jump into
        /// nothing.
        private var foreground: Color {
            guard released else { return Theme.fontVeryQuiet }
            if focus { return Theme.font }
            return quiet ? Theme.fontQuiet : Theme.font
        }
    }
}

// MARK: - Tile

/// The content of a tile: image, title, subtitle.
///
/// Deliberately **not** a button: a tile sometimes leads to a page (`NavigationLink`) and
/// sometimes starts playback immediately (`Button`). The user picks the trigger and puts
/// `TileStyle()` over it.
struct TileContent: View {
    let image: URL?
    let title: String
    var subline: String?
    /// Horizontal 16:9 instead of portrait 2:3, only for "Weiterschauen".
    var landscape = false
    var progress: Double?
    /// In the grid the tile carries only its title; the subtitle would be a line of noise
    /// times fourteen.
    var withUnderRow = true
    /// What appears at the top right: watched, open episodes, season count.
    ///
    /// **Three states, three symbols.** Until now there was only the bar, and for a series
    /// it says nothing because it shows the progress of the episode that was started.
    var mark: TileMark?
    /// **Watched: image dimmed, title quiet**, the same visual language as the episode row
    /// on iPhone. The checkmark comes via `mark`.
    var watched = false
    /// **A replacement for the image**, only for a collection without a poster of its own.
    /// `nil` everywhere else, and then the image is exactly as before.
    ///
    /// The type is fixed instead of `AnyView`: there is only this one replacement, and
    /// SwiftUI can diff instead of rebuilding every cell.
    var substitute: CollectionMosaic? = nil
    /// The symbol shown when there is no image: `Item.tileCharacter`.
    var symbolText: String? = nil

    private var width: CGFloat { landscape ? Theme.landscapeWidth : Theme.posterWidth }
    private var height: CGFloat { landscape ? Theme.landscapeHeight : Theme.posterHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let substitute {
                    substitute
                } else {
                    Picture(url: image, width: width, height: height, progress: progress,
                         symbolText: symbolText)
                }
            }
                // **Multiplied, not translucent**, like `Gesehenhaken` on iPhone. With
                // `opacity` the background showed through, and on a series page tinted by
                // its image every watched still picked up that tint. This only darkens.
                .colorMultiply(Color(white: watched ? 0.45 : 1))
                .overlay(alignment: .topTrailing) {
                    if let mark { TileBadge(mark: mark) }
                }

            Text(title)
                .font(Theme.tile)
                .foregroundStyle(watched ? Theme.fontQuiet : Theme.font)
                .lineLimit(1)
                .padding(.top, 14)

            if withUnderRow, let subline {
                Text(subline)
                    .font(Theme.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .frame(width: width, alignment: .leading)
        // **A tile is one statement, not three.** Without this, VoiceOver reads title and
        // subtitle as separate pieces and the progress bar drops out entirely, since it is
        // a drawing in the image.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(progressText.map(Text.init) ?? Text(""))
    }

    private var label: String {
        var parts = [title]
        if withUnderRow, let subline { parts.append(subline) }
        // The mark is a drawing in the image and would otherwise drop out for speech
        // output, the same consideration as for the bar.
        if let mark {
            switch mark {
            case .watched: parts.append(String(localized: "gesehen"))
            case .opened(let n): parts.append(String(localized: "\(n) offen"))
            case .seasons(let n): parts.append(n == 1 ? String(localized: "1 Staffel")
                                                       : String(localized: "\(n) Staffeln"))
            }
        }
        return parts.joined(separator: ", ")
    }

    /// The bar in words. Only from one percent: below that nobody has watched anything, and
    /// "zero percent watched" is no information.
    private var progressText: String? {
        guard let progress, progress >= 0.01 else { return nil }
        return String(localized: "\(Int(progress * 100)) Prozent gesehen")
    }
}

// MARK: - Top bar

/// The four sections, at the top rather than the bottom. On tvOS navigation is at the top,
/// and a bar at the bottom edge would be unreachably far from the eye.
enum Region: Int, CaseIterable, Identifiable {
    case start, movies, seriesList, watchlist, search
    var id: Int { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .start:     "Start"
        case .movies:     "Filme"
        case .seriesList:    "Serien"
        case .watchlist: "Merkliste"
        case .search:     "Suche"
        }
    }
}

/// Wordmark on the left, tabs next to it, profile on the right.
///
/// Deliberately left-aligned rather than centered like Apple's: the whole app is left-
/// aligned, and the wordmark belongs at the start of the line.
struct HeaderBar: View {
    @Binding var section: Region
    let model: AppModel
    var onProfile: () -> Void
    /// What is playing on other devices.
    var takeover: [RemoteSession] = []
    /// Open groups that can be joined (same badge, with a counter).
    var groups: [SyncPlayGroup] = []
    var badgePressed: () -> Void
    /// Increments when a panel of the badge closes, then focus belongs to it again (a panel
    /// is not a change of place).
    var badgeFocus = 0
    /// Increments after switching accounts from the profile picker: focus is then on the
    /// profile picture, and a press opens the profile again, so the profile is reachable
    /// right away.
    var profileFocus = 0

    /// Which tab currently has focus, `nil` once it is in the content.
    @FocusState private var atTab: Region?
    @FocusState private var atBadge: Bool
    @FocusState private var atProfile: Bool
    @State private var profileCatchUp: Task<Void, Never>?
    /// Disabled as soon as another page lies on top (`barPresent`), so re-claiming focus no
    /// longer pulls it back.
    @Environment(\.isEnabled) private var released

    var body: some View {
        HStack(spacing: 56) {
            Wordmark(height: 48)

            HStack(spacing: 8) {
                // **The watchlist is a tab again.** It was briefly a round button next to
                // the profile picture, but two circles side by side looked muddy, so it
                // came back. As a word in the bar it sits among the other sections, where
                // people look for it.
                ForEach(Region.allCases) { b in
                    Button { section = b } label: { Text(b.name) }
                        .buttonStyle(TabStyle(selected: section == b))
                        .focused($atTab, equals: b)
                }
            }
            .focusSection()
            // **The click switches, not the focus.** The other way round was built for a
            // while because it is common on tvOS, but it assumes focus reliably lands on
            // the open tab when coming from below. It does not: tvOS searches
            // geometrically, and three attempts to redirect it either had no effect,
            // flickered visibly or made the bar unreachable.
            //
            // With the click as the switch, the geometric landing is harmless: you just
            // stand on "Suche" without being there.

            Spacer(minLength: 0)

            // **Left of the profile picture, and only when there is something.** A badge
            // that is always there and mostly says nothing is decoration. This one appears
            // when something plays elsewhere and disappears again, so it is also not in the
            // focus path while it has nothing to offer.
            //
            // **Its own, tighter spacing for the two on the right.** The bar uses 56 pt,
            // right between wordmark and tabs but too much between badge and profile
            // picture. The two belong together; apart, it looked as if the badge had not
            // found room.
            HStack(spacing: 18) {
                if !takeover.isEmpty || !groups.isEmpty {
                    OfferingBadge(continueWatching: takeover, groups: groups,
                                      action: badgePressed)
                        .focused($atBadge)
                        // The panel grows from here (`BadgeOrigin`).
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            BadgeOrigin.point = CGPoint(x: $0.midX, y: $0.midY)
                        }
                        .focusSection()
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // The supporter heart, as on iPhone: white and filled, a destination rather
                // than a state. It opens the support page.
                Button {
                    SupportModel.shared.open()
                } label: {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.font)
                        .frame(width: 60, height: 60)
                        .contentShape(Circle())
                }
                .buttonStyle(ProfileStyle())
                .accessibilityLabel(Text(SupportCopy.supportSwiftly.localized))
                .focusSection()

                Button(action: onProfile) {
                    let image = model.userImageURL()
                    ProfileCharacter(name: model.session?.userName ?? "?",
                                  image: image,
                                  size: 60,
                                  withoutImage: image.map { AccountSwitchTransition.shared.withoutImage.contains($0) } ?? false)
                        // **One view per image URL**, otherwise the old profile picture
                        // would flash briefly on landing (like `ProfileTarget` on iPhone).
                        .id(image)
                        // While the new profile picture flies in, there is none here yet.
                        .opacity(AccountSwitchTransition.shared.transition.map { $0.replaced } ?? true ? 1 : 0)
                }
                .buttonStyle(ProfileStyle())
                .focused($atProfile)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameRect in
                    AccountSwitchTransition.shared.targetReport(frameRect)
                }
                // An image without a label is an unnamed key.
                .accessibilityLabel(Text("Profil und Einstellungen"))
                .focusSection()
            }
        }
        .padding(.horizontal, Theme.edgePage)
        // Safe area at the top and sides so the spacing matches; see `Theme.barTop`.
        .frame(height: Theme.stripHeight)
        .padding(.top, Theme.barTop)
        // Horizontal too: the bar sits above the section stack and would not inherit its
        // edge inset otherwise. The wordmark would then sit 80 pt further in than the
        // content below.
        .ignoresSafeArea(edges: [.top, .horizontal])
        .animation(Theme.motion(.easeInOut(duration: 0.25)), value: takeover.map(\.id))
        .animation(Theme.motion(.easeInOut(duration: 0.25)), value: groups.map(\.id))
        .onChange(of: badgeFocus) { _, _ in atBadge = true }
        // **And a second attempt.** The bar only becomes focusable again in the same pass
        // (`barPresent`), and SwiftUI discards an assignment made in that pass, the same
        // lesson as in the player.
        .onChange(of: profileFocus) { _, _ in
            atProfile = true
            profileCatchUp?.cancel()
            profileCatchUp = Task { @MainActor in
                for wait in [80, 250, 600] {
                    try? await Task.sleep(for: .milliseconds(wait))
                    // Once it sticks, or when the profile is open by now, there is no
                    // second attempt; otherwise a late tick would pull focus back from
                    // where the user just went.
                    guard !Task.isCancelled, released else { return }
                    if atProfile { break }
                    atProfile = true
                }
                AppLog.writeOut("[Fokus] Profilbild oben nach Kontowechsel: \(atProfile)")
            }
        }
        #if DEBUG
        .onChange(of: atProfile) { _, now in
            if AccountSwitchRun.an { AccountSwitchTransition.note("fokus: profilbild oben \(now) · leiste frei \(released)") }
        }
        #endif
    }
}

// `Uebernahmeabzeichen` is now `OfferingBadge` in `TVShared.swift`: the same badge,
// now also for open groups.
//
// **Deliberately with device name and title, not just a symbol.** A symbol alone raises the
// question of what it does, and pressing it would accidentally pause the film on the other
// device.

/// The same rest-to-focus jump as everywhere on the TV: a calm surface at rest, the light
/// one when focused.
///
/// **Cool when it comes from another device.** The badge used to be gray, the same tone as
/// "Abbrechen", although it is the only one that says "something plays elsewhere". All
/// versions now use `Theme.accent` for it.
///
/// **Opaque, not translucent.** The tint first lay directly on whatever was below. On a
/// dark background that worked, but over the home page's backdrop image the image showed
/// through and the text got lost. Now the same tint lies on the page background: no new
/// color value, but a surface that looks the same over any image.
///
/// Round, as a capsule, instead of the button's corner.
struct BadgeStyle: ButtonStyle {
    var otherDevice = false

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, otherDevice: otherDevice)
    }

    private struct ContentBody: View {
        let configuration: Configuration
        let otherDevice: Bool
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .background { reason }
                .overlay {
                    Capsule().strokeBorder(.white.opacity(focus || otherDevice ? 0 : 0.18))
                }
                // The wide step: this style carries the badge over the backdrop image
                // **and** the 760 pt wide device rows, where six percent is 45 pt.
                .scaleEffect(focus ? Theme.focusMagnifierWide : 1)
                .animation(Theme.motion(.easeOut(duration: 0.16)), value: focus)
        }

        private var foreground: Color {
            if focus { return Theme.reason }
            return otherDevice ? Theme.accent : .white
        }

        @ViewBuilder
        private var reason: some View {
            if focus {
                Capsule().fill(.white)
            } else if otherDevice {
                Capsule().fill(Theme.accent.opacity(0.18))
                    .background(Theme.reason, in: Capsule())
            } else {
                Capsule().fill(Theme.raised)
            }
        }
    }
}

// `ProfileCharacter` now lives in `Sources/Shared/Components.swift` and takes the size as a
// parameter: `ProfileCharacter(name:image:size: 60)`.
//
// **Two things look different from before**, both design rather than technical: the
// background is a green gradient instead of the flat `Theme.erhoeht` surface, and the ring
// is 1 instead of 2 thick. The letter is computed from the size (60 x 0.38 = 22.8 instead
// of a fixed 27). To keep the old look, the three values would need to become parameters of
// the shared component, as `Badge` already does.

// MARK: - Cast

/// One actor: image, name, role.
struct CastTile: View {
    let image: URL?
    let name: String
    let role: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Half the edge length means a circle: not a step of the corner ladder but the
            // shape itself, as on iPhone with `corner: 38` at 76.
            Picture(url: image, width: 208, height: 208, corner: 208 / 2)

            Text(name)
                .font(Theme.tile)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .padding(.top, 14)

            if let role, !role.isEmpty {
                Text(role)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .frame(width: 208, alignment: .leading)
    }
}


/// Focus on the profile picture.
///
/// `TileStyle` alone is not enough here: `focusMagnifier` (1.06) on 60 pt is four points, which
/// is invisible from three meters. Hence `focusMagnifierSmall`, and because an image cannot
/// brighten like a tile, additionally a ring in the accent color, which has the same role
/// as everywhere: it shows a selection.
struct ProfileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .overlay {
                    if focus {
                        Circle()
                            .strokeBorder(Theme.accent, lineWidth: 4)
                            .padding(-8)
                    }
                }
                .scaleEffect(focus ? Theme.focusMagnifierSmall : 1)
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}

// MARK: - Action panel

/// The entries behind the More button.
///
/// **It opens at the trigger, not from the bottom.** On iPhone this is a sheet taking half
/// the screen; there the thumb is at the bottom and the way is short. On the TV the trigger
/// sits in the middle of the picture, and a panel sliding in from below would have nothing
/// to do with it. Three to five rows also cover no screen, which stays reserved for whole
/// views.
///
/// What is in it is **not** this view's business: the list comes in as `[TitleAction]`
/// and is the same everywhere.
struct ActionPanel: View {
    let actions: [TitleAction]
    @Binding var opened: Bool
    /// **Which row is selected: it carries the accent.**
    ///
    /// Panels with a selection (filter, sort, library) used to show it only through the
    /// symbol: filled checkmark against empty circle, both in white. That is a shape step,
    /// and it survives three meters as little as a brightness step does, the same reason
    /// the selected filter chip carried the accent (see `ChipStyle`). Since the chip's
    /// choice moved into this panel, the accent came with it.
    ///
    /// `nil` means a list of actions, no selection.
    var selected: Int? = nil
    /// **A heading before a row**: a divider with the title below. In the title menu of
    /// movies and series, "Bibliotheken" stands above the individual libraries, set apart
    /// from "Alle" and "Sammlungen", which are not libraries. The same heading as in
    /// `SelectionSheet` on iPhone.
    var category: (Int) -> LocalizedStringKey? = { _ in nil }

    /// Focus has to move in when the panel opens. tvOS does not move it by itself while the
    /// trigger stays, and it does.
    @FocusState private var first: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { pair in
                if let over = category(pair.offset) {
                    VStack(alignment: .leading, spacing: 0) {
                        SeparatorLine()
                        Text(over)
                            .font(Theme.group)
                            .tracking(Theme.lockGroup)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.fontVeryQuiet)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Self.categoryInset)
                            .padding(.top, Theme.railsHeaderPadding)
                            .padding(.bottom, 8)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                Button {
                    // Close first, then act: several actions open something themselves, and
                    // a sheet above an open sheet would be wrong.
                    opened = false
                    pair.element.perform()
                } label: {
                    HStack(spacing: 22) {
                        Image(systemName: pair.element.symbol)
                            .foregroundStyle(pair.offset == selected ? Theme.accent
                                             : pair.element.cautionary ? Theme.warning : Theme.font)
                            .frame(width: 38)
                        pair.element.label
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(pair.element.cautionary ? Theme.warning : Theme.font)
                }
                .buttonStyle(RowsStyle())
                .accessibilityAddTraits(pair.offset == selected ? .isSelected : [])
                .focused($first, equals: pair.offset == 0)
            }
        }
        // **No padding at all.** First 14, then 6, and both times the panel background
        // showed through at the top and bottom. The rows bring their own rounding, so no
        // distance to the panel's rounding is needed; it was only a border around the
        // border.
        //
        // Clipped so the top and bottom rows end inside the panel's rounding instead of
        // sticking out.
        .frame(width: Self.width)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        // **No border, no shadow.** Depth comes from surface brightness: `erhoeht` is
        // already one step above the background. With radius 40 the shadow was the largest
        // in the app, contradicts the brand rule "no shadows, anywhere", and turns to mud
        // at three meters anyway.
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        .focusSection()
        .task { first = true }
        .onExitCommand { opened = false }
    }

    /// **The width is fixed, the position is not.**
    ///
    /// Three to five rows with symbol and text need it; narrower, the longer labels wrap.
    /// The placement relies on it, so it lives here and not as a number in the `frame`.
    static let width: CGFloat = 620

    /// Space between trigger and panel.
    static let padding: CGFloat = 16

    /// The inset of the heading: the same as a row's text (`RowsStyle`) and the
    /// `SeparatorLine`, so everything sits on one edge.
    static let categoryInset: CGFloat = 26

    /// **Which edge the panel hangs from under its trigger.**
    ///
    /// It aligns to the trigger's left edge. If the trigger is so far right that the panel
    /// would run out, it aligns to the right edge instead, which is what a menu on the Mac
    /// does. Finally it is clamped into the area: on the TV its edge is the title-safe
    /// area, and nothing beyond it is drawn.
    static func left(firer: CGRect, in area: CGSize) -> CGFloat {
        let left = firer.minX + width <= area.width
            ? firer.minX
            : firer.maxX - width
        return min(max(0, left), max(0, area.width - width))
    }
}

// MARK: - Panels hang from their trigger

/// Where a page's triggers are, measured rather than computed.
///
/// **That was the bug, and it appeared the same way in five places.** Every panel hung as
/// `.overlay(alignment:)` on the whole page with a hand-computed offset: `Theme.edgePage`
/// to the side, `Theme.erstesEnde + 16` or `unterDerKnopfreihe` downward. Both numbers
/// assume the **picture edge**, but an overlay is based on the **safe area**, 80 pt to the
/// side and 60 at the top on tvOS. Each panel was off by exactly that margin: on the movie
/// page the library choice sat 80 pt too far right and 60 too low, and sort 80 pt too far
/// left. Verified by measurement in the simulator (button 76...266, panel 160...779).
///
/// That a computed number eventually stops being right was already visible in
/// `macOS/LibraryView`: the `GridPlaceholder` sat as an overlay with a fixed offset
/// and covered the chip row as soon as the header zone grew by a line. The lesson is the
/// same: **measure the position.**
///
/// `Anchor<CGRect>` carries the trigger's rectangle up to the view the overlay hangs from,
/// and `GeometryProxy` resolves it there in that view's own coordinate system. It then does
/// not matter which safe area is switched off where.
struct PanelAnchor: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// This button opens a panel and remembers where it is.
    func panelTrigger(_ name: String) -> some View {
        anchorPreference(key: PanelAnchor.self, value: .bounds) { [name: $0] }
    }

    /// Places `content` under the trigger `name`, on the **page**, not on the button.
    ///
    /// On the button, the panel once ended up behind the tiles: an overlay inherits the
    /// drawing order of what it lies on, and the strip under a `Section` header draws after
    /// it. On the page it lies above the whole scroll area; only its **position** now comes
    /// from the button.
    func panel<ContentBody: View>(under name: String?,
                             @ViewBuilder content: @escaping () -> ContentBody) -> some View {
        overlayPreferenceValue(PanelAnchor.self) { anchor in
            GeometryReader { area in
                if let name, let section = anchor[name] {
                    let firer = area[section]
                    content()
                        .offset(x: ActionPanel.left(firer: firer,
                                                        in: area.size),
                                y: firer.maxY + ActionPanel.padding)
                }
            }
        }
    }
}

/// The More button. The page itself puts the panel on its header; see `Handlungstafel`.
struct MoreButton: View {
    @Binding var opened: Bool

    var body: some View {
        Button { opened.toggle() } label: {
            Image(systemName: "ellipsis").font(Theme.button)
        }
        .buttonStyle(ThemedButtonStyle(onlySymbol: true))
        // Without a label the button would be unnamed for VoiceOver.
        .accessibilityLabel(Text("Mehr"))
    }
}


/// **The header block, once, for home page and detail page.**
///
/// It lives here and not twice. Each page used to have its own layout, and the two had
/// already drifted apart: the detail page also showed genres, the home page the remaining
/// time. That is how `loadMore()` and `Titelangaben` drifted apart.
///
/// **Genres are out.** Not by taste: the home page cannot show them at all. Its titles come
/// from the server's short lists, which have no genres; only the detail page fetches the
/// full title. "The same on both" therefore necessarily means "without".
///
/// **The height is fixed, the content is not.** `Theme.infoHeight` applies whether or not
/// a description exists and whether the title is short or long. Only then does the button
/// row below sit in the same place on every detail page, and the text stays put when a page
/// opens instead of jumping.
struct HeaderInfo<End: View>: View {
    let item: Item
    /// For episodes the episode title appears under the series title. It costs a line that
    /// the description then lacks; the total height stays.
    var secondLine: String?
    /// **For an episode: the series whose details the line carries.**
    ///
    /// The large title above the line is the series name for an episode, and pressing the
    /// episode leads to the series page. So year, runtime, stars and rating belong to the
    /// series; otherwise the home page showed 5.6 (the episode) and one page further 8.5
    /// (the series). If it is missing, the line stays empty until it arrives instead of
    /// briefly showing the episode's values.
    var series: Item?
    /// Only set on detail pages: only then can "title as logo" apply.
    var logoModel: AppModel?
    /// What comes last: "Direct Play" on the detail page, nothing otherwise.
    @ViewBuilder var closing: () -> End

    /// Whose details are in the line; see `series`.
    private var detailsFrom: Item? {
        item.type == "Episode" ? series : item
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Page title from the ladder; 60 does not exist there. A long title shrinks
            // instead of shifting the page; a logo stays in its 68 pt slot. For an episode
            // the series logo is shown.
            TitleMark(title: item.type == "Episode" ? (item.seriesName ?? item.name) : item.name,
                       logo: logoModel.flatMap { $0.logoURL(for: detailsFrom ?? item) },
                       row: 56, slot: .compartment(height: 68))

            if let secondLine {
                Text(secondLine)
                    // Sheet heading from the ladder, with the tone as a token: 78 percent
                    // opacity changes its effect once something lies below, and here a hero
                    // image does.
                    .font(Theme.categoryLarge)
                    .tracking(Theme.lockCategory)
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(1)
                    .frame(height: 44, alignment: .leading)
                    .padding(.top, 10)
            }

            // Year, runtime, stars, rating, proof: one component; see `DetailsRail`.
            DetailsRail(title: detailsFrom, closing: closing)
            .frame(height: Theme.markHeight)
            .padding(.top, Theme.detailsPadding)

            // **The cleaned text, not the raw one.** Jellyfin returns descriptions as the
            // provider had them, with `<br>`, `<p>` and `&amp;`. At three meters that
            // appeared literally on screen.
            Text(item.description ?? "")
                .font(Theme.body)
                .lineSpacing(Theme.descriptionPadding)
                .foregroundStyle(Theme.font.opacity(0.62))
                // Three lines, two when an episode title sits above, so the block keeps its
                // fixed height.
                .lineLimit(secondLine == nil ? 3 : 2)
                .padding(.top, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // **Fixed, but taller by the second line when there is one.**
        //
        // 258 holds title, details and three lines of description. The episode title adds
        // 54 (44 high, 10 spacing), so 312, and that fits: the home page starts at 196, so
        // the block ends at 508 and stays below the header zone of 510.
        //
        // The detail pages never see the second line: an episode gets no page of its own,
        // every path to it leads to the series page. There it stays at 258, and the button
        // row remains in the same place on every page.
        .frame(width: 1000,
               height: Theme.infoHeight(secondLine: secondLine != nil),
               alignment: .topLeading)
    }

}

/// **The details line: one component, one order, everywhere.**
///
/// Year, runtime, stars, rating, proof (Direct Play). What is missing is dropped without a
/// gap. Home, movie and series pages set it via `HeaderInfo`. On the home page, an
/// episode used to show an extra "S1 E3" in front, the same information as in the episode
/// title below, and the values came from the episode instead of the title above.
///
/// **Everything is a `ProofMark`, aligned at the center.** With `.firstTextBaseline`,
/// marks with a symbol reported the SF Symbol's baseline; measured, the shells were offset
/// by up to 3 pt.
struct DetailsRail<End: View>: View {
    /// The title whose details are shown. `nil`: none yet.
    let title: Item?
    /// What follows the details: the proof on the detail page, the remaining time on the
    /// home page.
    @ViewBuilder var closing: () -> End

    var body: some View {
        HStack(alignment: .center, spacing: Theme.detailsSpacing) {
            if let title, Self.hasDetails(title) {
                HStack(alignment: .center, spacing: Theme.detailsSpacing) {
                    if let year = title.productionYear {
                        ProofMark(word: Text(verbatim: String(year)), color: Theme.fontQuiet)
                            .monospacedDigit()
                    }
                    if let seconds = title.runtimeSeconds, seconds > 0 {
                        ProofMark(word: Text(verbatim: runtime(seconds)), color: Theme.fontQuiet)
                            .monospacedDigit()
                    }
                    ProofMarks(rating: title.communityRating,
                                sharing: title.officialRating)
                }
                // **A title change is a cut, not a movement.** When focus moves from title
                // to title on the home page, the change arrived in an animated transaction,
                // and the marks slid, shifted and grew from one width to another, as did
                // the line that was empty before. An identity per title makes new marks
                // instead of deformed old ones, and without animation they appear
                // immediately.
                .id(title.id)
                .transaction { $0.animation = nil }
            }
            // The final item keeps its own motion: the detail page's Direct Play mark still
            // fades in (`DetailHeader`).
            closing()
        }
    }

    /// Whether the title has anything for the line at all; otherwise an empty stack would
    /// sit there and keep its spacing before the last item.
    private static func hasDetails(_ title: Item) -> Bool {
        title.productionYear != nil || (title.runtimeSeconds ?? 0) > 0
            || title.communityRating != nil || title.officialRating != nil
    }
}

/// "Noch 50 Minuten" with a clock, "Gesehen" with a checkmark, or nothing.
struct RemainingTimeMark: View {
    let item: Item

    @ViewBuilder
    var body: some View {
        if let rest = item.remainingTimeText {
            Label(rest, systemImage: "clock")
                .font(Theme.tile)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
        } else if item.isWatched {
            Label("Gesehen", systemImage: "checkmark")
                .font(Theme.tile)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
        }
    }
}

// MARK: - Backdrop

/// The image on the right, 1180 x 700, with the two gradients in front.
///
/// **Once here, not three times.** Home, movie and series pages show the same backdrop; as
/// copies there would be three places where an opacity can change unnoticed. That is how
/// `loadMore()` and `Titelangaben` drifted apart.
///
/// **The gradients lie on top, they do not mask.** A mask lowers the opacity of the whole
/// layer, the focus ring included, which looks like a bug, not like a gradient. That no
/// longer applies to the backdrop, which does mask now: it is not a control and has no
/// ring; the sentence above comes from the tiles. The reason for the change is at `mask`
/// below.
///
/// Not clipped: the image may overhang downward, its own gradient ends it. Clipped, it
/// produced a hard edge that appeared as a light stripe across the screen. **The backdrops
/// already shown, decoded.**
///
/// `AsyncImage` starts from scratch in every new view: it asks the cache, decodes, and only
/// then shows. On the detail page that is a new `AsyncImage` for the same image that was
/// just on the home page, and in between it shows nothing.
///
/// The network cache does not help: it saves the fetch, not the decoding, and both happen
/// asynchronously. What has been on screen once must therefore be kept **here**, ready to
/// draw.
///
/// Capped because a TV-size backdrop takes several megabytes: the last eight cover the path
/// home page, detail page, back, and nobody needs more at once.
///
/// **Most recently used, not most recently fetched.** The oldest *stored* item used to be
/// evicted even if it had just been shown, so the home page backdrop you return to was lost
/// after eight detail pages. Now reading and storing both move an item to the back.
@MainActor
final class BackdropImage {
    static let shared = BackdropImage()
    private var known: [URL: Image] = [:]
    private var railsEpisode: [URL] = []
    private static let atMost = 8

    func image(_ url: URL) -> Image? {
        guard let image = known[url] else { return nil }
        postBack(url)
        return image
    }

    func remember(_ image: Image, for url: URL) {
        known[url] = image
        postBack(url)
        while railsEpisode.count > Self.atMost {
            known[railsEpisode.removeFirst()] = nil
        }
    }

    private func postBack(_ url: URL) {
        if let spot = railsEpisode.lastIndex(of: url) { railsEpisode.remove(at: spot) }
        railsEpisode.append(url)
    }
}

struct Backdrop: View {
    let url: URL?
    @State private var image: Image?
    /// What is known appears immediately, not in the next pass. The same consideration as
    /// for `ImageReason`: a value supplied later comes too late, the empty pass has already
    /// happened.
    @MainActor init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap { BackdropImage.shared.image($0) })
    }

    var body: some View {
        ZStack {
            if let image {
                image.resizable().aspectRatio(contentMode: .fill)
            }
        }
        // **Via `ImageCache`, not `AsyncImage`**, like `Picture` (see `Style.swift`):
        // `AsyncImage` decodes on the main thread, stores nothing on disk and cancels when
        // it disappears, and on the home page the backdrop changes with every focus stop.
        // `ImageCache` can also send custom headers (front-end proxy, #4). The result is
        // additionally kept by `BackdropImage` so the home page backdrop is still there
        // after several detail pages.
        .task(id: url) {
            guard let url else { return }
            if let present = BackdropImage.shared.image(url) { image = present; return }
            guard let loaded = await ImageCache.shared.load(url, preRank: true) else { return }
            guard !Task.isCancelled else { return }
            BackdropImage.shared.remember(loaded, for: url)
            image = loaded
        }
        // A new URL while the view stays: do not keep showing the old image, take what is
        // known for the new one.
        .onChange(of: url) { _, new in
            image = new.flatMap { BackdropImage.shared.image($0) }
        }
        .frame(width: 1180, height: 700)
        .clipped()
        .backdropsFade()
        .padding(.trailing, -Theme.edgePage)
        .allowsHitTesting(false)
    }
}
/// **The backdrop fade, once, for home page and detail page.**
///
/// It existed twice and the two differed: masked here, painted over with gradients of
/// `Theme.reason` there. When going from the home page to a detail page, SwiftUI cross-faded
/// one version into the other, and hard edges were visible mid-fade because the old version
/// had them.
///
/// Now both sides show the same image with the same fade. A cross-fade between two
/// identical things is invisible.
///
/// **Masked, not painted over.** Painting over assumes the background is exactly `#0B0B0D`;
/// as soon as it is tinted, the painted area shows as a patch. With a mask the image's own
/// opacity falls, and whatever lies behind shows through, whatever its color.
///
/// **One falloff, not two.** Here used to be a horizontal and a vertical mask on top of
/// each other. Together they form a rectangular falloff: each is soft on its own, but their
/// product still traces the two straight lines, and the corner gets doubly dark. See
/// `ImageTone.rundeBlende`.

struct BackdropsFade: ViewModifier {
    func body(content: Content) -> some View {
        content
            // **The original curve, only as a mask instead of a paint.** The good part was
            // never the technique but the curve, and it is kept unchanged.
            //
            // Translated: the old version painted `Theme.reason` with opacity `o` **over**
            // the image, so `1 - o` stayed visible. Exactly those values are now the mask:
            //
            // Horizontally, o is 1.00 / 0.78 / 0.16 / 0 at 0 / 0.26 / 0.62 / 1, so
            // visibility is 0 / 0.22 / 0.84 / 1.
            //
            // Vertically, over the lower 320 of 700 (from 0.543), o is 0 / 0.75 / 1.00, so
            // visibility is 1 / 0.25 / 0.
            //
            // **The only difference is what it fades into.** A paint ends in opaque #0B0B0D
            // and so assumes the background is exactly that; as soon as it is tinted, the
            // painted area shows as a patch. That was the hard vertical seam. A mask ends
            // in transparency, and whatever lies behind shows through, whatever its color.
            //
            // Everything tried in between (longer ramps, a circle in the corner, the
            // minimum of two ramps) changed the curve instead of only its technique, so
            // each was worse than this.
            //
            // **The same anchors, more sample points.** The hard part was not the values
            // but their number: between 0.26 and 0.62 visibility jumped from 22 to 84
            // percent, and the slope kinked at both points. A kink reads as an edge.
            //
            // The four anchors of the original are unchanged (0 / 0.22 / 0.84 / 1 and 1 /
            // 0.25 / 0); between them are now intermediate points that carry the transition
            // instead of taking it in one go. The curve stays the same, it just has no
            // corners.
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.00), location: 0),
                    .init(color: .white.opacity(0.05), location: 0.15),
                    .init(color: .white.opacity(0.22), location: 0.29),
                    .init(color: .white.opacity(0.50), location: 0.45),
                    .init(color: .white.opacity(0.75), location: 0.57),
                    .init(color: .white.opacity(0.90), location: 0.70),
                    .init(color: .white.opacity(0.98), location: 0.85),
                    .init(color: .white.opacity(1.00), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(1.00), location: 0),
                    .init(color: .white.opacity(1.00), location: 0.50),
                    .init(color: .white.opacity(0.88), location: 0.60),
                    .init(color: .white.opacity(0.62), location: 0.70),
                    .init(color: .white.opacity(0.34), location: 0.80),
                    .init(color: .white.opacity(0.14), location: 0.89),
                    .init(color: .white.opacity(0.04), location: 0.95),
                    .init(color: .white.opacity(0.00), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
    }
}

extension View {
    func backdropsFade() -> some View { modifier(BackdropsFade()) }
}

/// **A quiet shadow under the top bar.**
///
/// Since the home page has the same tinted background as a detail page, its old header
/// gradient is gone, and the bar was then drawn on light backdrops directly over the image.
///
/// **Much less than the old gradient.** That one started at 72 percent and ran out over 588
/// pt; it grayed out half the header zone and was exactly what made the page look
/// different. This one covers the bar and ends 90 pt below, just far enough not to touch
/// the title at 196.
///
/// Sampled like every gradient here, so there is no kink at the top or bottom where banding
/// could arise.
struct HeaderShadow: View {
    var body: some View {
        ZStack(alignment: .top) {
            // The strip under the whole bar: it carries the wordmark and section names.
            LinearGradient(gradient: strip, startPoint: .top, endPoint: .bottom)
                .frame(height: Theme.barBottom + 90)

            // **And a large soft patch behind the profile mark.**
            //
            // It sits at the top right, exactly where the backdrop is brightest. The even
            // strip is not enough there, and the round image lay flat on the motif.
            //
            // Huge is the means here, not exaggeration: a small shadow would be
            // recognizable as a disc behind the mark. At a reach of 520 pt it is no longer
            // seen as a shape, only as calmer surroundings.
            RadialGradient(gradient: spot,
                           center: UnitPoint(x: 0.945, y: 0.02),
                           startRadius: 0, endRadius: 520)
                .frame(height: 620)
        }
        .allowsHitTesting(false)
    }

    /// Covers the bar, ending 90 pt below, just far enough not to touch the title at 196.
    private var strip: Gradient { history(0.46) }

    /// Stronger than the strip, but only in one place.
    private var spot: Gradient { history(0.52) }

    /// Sampled instead of stepped: it runs out horizontally at both ends, so there is no
    /// kink at the top or bottom where banding could arise.
    private func history(_ strength: Double) -> Gradient {
        let levels = 14
        return Gradient(stops: (0 ... levels).map { i in
            let t = Double(i) / Double(levels)
            let soft = t * t * (3 - 2 * t)
            return .init(color: Theme.reason.opacity(strength * (1 - soft)), location: t)
        })
    }
}

// MARK: - Season picker

/// The pill next to "Folgen".
///
/// From the design: 60 high, corner radius 30, `Theme.erhoeht` with a quiet
/// border. No `Menu`: Apple's dropdown brings its own design, and the app uses no standard
/// control anywhere. The list comes as a `Handlungstafel`, the same one the More button
/// opens.
struct SeasonPill: View {
    let name: String
    @Binding var opened: Bool

    var body: some View {
        Button { opened.toggle() } label: {
            HStack(spacing: 14) {
                Text(name)
                    .font(Theme.button)
                // Opacity instead of a fixed color: the arrow inherits the button's text.
                // Fixed half-white, it vanished on the white focus surface.
                Image(systemName: "chevron.down")
                    .font(Theme.group)
                    .opacity(0.6)
                    .accessibilityHidden(true)
            }
        }
        // **The same style as the buttons in the header.** It used to carry its own:
        // different surface, border and rounding. But it **is** the same thing: a button
        // that opens something, like the More button next to it.
        .buttonStyle(ThemedButtonStyle(height: 60))
        .accessibilityLabel(Text("Staffel wählen, \(name)"))
    }
}

/// Focus on the season pill: the calm surface, as for rows and chips. White stays reserved
/// for action buttons.

// MARK: - Handover: which device?

/// When something plays on several devices, it asks instead of guessing.
///
/// **`TV` prefix because the shared version exists too.** This one is built for ten feet
/// and the focus ring, the one in `Components.swift` for the finger. Same purpose, different
/// distance, which is the case where separate views are allowed.
///
/// **Why a sheet of its own and not a list in the badge.** The badge sits in the top bar
/// and has room for one line there. And the choice has consequences: what is chosen here
/// **pauses on the other device**. That belongs in front of the eyes, not in a dropdown.
struct TVTakeoverSelection: View {
    let sessions: [RemoteSession]
    var select: (RemoteSession) -> Void
    var cancel: () -> Void
    /// **Focus is placed explicitly, not searched.** Otherwise the disabled badge behind
    /// kept it and nothing here was operable (see `TVSharedPanel.pick`).
    @FocusState private var focus: String?

    /// **No background of its own.** `MainView` puts the dimming layer below, as its own
    /// layer: it only fades, while the picker grows out of the badge
    /// (``Herkunftsauftritt``, as on iPhone).
    var body: some View {
        ZStack {
            VStack(spacing: 34) {
                VStack(spacing: 10) {
                    Text("Wo weiterschauen?")
                        .font(Theme.subpageTitle)
                        .tracking(Theme.lockSubpage)
                    Text("Auf dem anderen Gerät hört die Wiedergabe auf. Hier läuft sie an derselben Stelle weiter.")
                        .font(Theme.small)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    ForEach(sessions) { s in
                        Button { select(s) } label: {
                            HStack(spacing: 20) {
                                Image(systemName: s.devicesCharacter)
                                    .font(.system(size: 28, weight: .medium))
                                    .frame(width: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    // The fallback is our word, the name is not: without
                                    // `String(localized:)`, "Gerät" appeared in German in
                                    // every language, the same trap as on iPhone, same form
                                    // as in `Bausteine`.
                                    Text(s.deviceName ?? String(localized: "Gerät"))
                                        .font(Theme.listTitle)
                                    Text(s.titleLine)
                                        .font(Theme.small)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Text(PlayTime.text(s.state?.spot ?? 0))
                                    .font(Theme.small.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 28)
                            .frame(height: 88)
                            .frame(maxWidth: 760)
                        }
                        // Each row is a different device, so it is cool like the badge that
                        // led here. "Abbrechen" below stays gray.
                        .buttonStyle(BadgeStyle(otherDevice: true))
                        .focused($focus, equals: s.id)
                    }
                }
                .focusSection()

                Button("Abbrechen", action: cancel)
                    .buttonStyle(BadgeStyle())
            }
            .padding(48)
        }
        // Menu closes, as everywhere on the TV.
        .onExitCommand(perform: cancel)
        .defaultFocus($focus, sessions.first?.id)
        .task { focus = sessions.first?.id }
    }
}


// MARK: - Placeholder instead of a spinner

/// A surface in the shape of what is about to come.
///
/// **Why no spinning ring.** A ring says "wait"; a placeholder says *what* is coming and
/// how much: the page is already there, only empty. At three meters that counts double: a
/// ring is a dot, a grid is an announcement.
struct LoadField: View {
    var corner: CGFloat = Theme.cornerTile
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Theme.area)
            .opacity(bright ? 1 : 0.5)
            .onAppear {
                // **No endless pulsing against the system setting.** On an empty library
                // the whole grid would otherwise pulse, and `accessibilityHidden` does not
                // help: whoever does not want to see motion sees it anyway. The surface
                // then stands still and light; the shape is the message, not the motion.
                // The iOS version does the same.
                guard !Theme.motionReduced else { bright = true; return }
                withAnimation(Theme.pulsate) {
                    bright = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// A poster with two text lines below, all as placeholders.
struct TilePlaceholder: View {
    var landscape = false

    private var width: CGFloat { landscape ? Theme.landscapeWidth : Theme.posterWidth }
    private var height: CGFloat { landscape ? Theme.landscapeHeight : Theme.posterHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadField().frame(width: width, height: height)
            LoadField(corner: Theme.cornerBar).frame(width: width * 0.8, height: 20).padding(.top, 14)
            LoadField(corner: Theme.cornerBar).frame(width: width * 0.4, height: 16).padding(.top, 6)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// A grid of poster placeholders, as wide as the real one.
struct GridPlaceholder: View {
    var columns: Int = Theme.gridColumns
    var rails: Int = 2

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.tileSpacing),
                                 count: max(columns, 1)),
                  alignment: .leading, spacing: Theme.railsSpacing) {
            ForEach(0 ..< (max(columns, 1) * rails), id: \.self) { _ in
                TilePlaceholder()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Laedt")
    }
}

/// A row of poster placeholders, for the home page.
struct RailsPlaceholder: View {
    var landscape = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LoadField(corner: Theme.cornerBar).frame(width: 300, height: 30)
            HStack(spacing: Theme.tileSpacing) {
                ForEach(0 ..< 5, id: \.self) { _ in TilePlaceholder(landscape: landscape) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Laedt")
    }
}

/// How many titles this library holds.
///
/// **A statement, not an action**: quiet text, no box.
struct CountMark: View {
    let count: Int

    var body: some View {
        Text(verbatim: count.formatted())
            .font(Theme.small)
            .monospacedDigit()
            .foregroundStyle(Theme.fontVeryQuiet)
            .accessibilityLabel(Text("\(count) Titel"))
    }
}

/// The badge at the top right of a tile.
///
/// **White on dark, not in the accent.** On the TV the accent also carries the focus ring,
/// and a second accent surface next to it takes away its meaning. Which information is
/// shown is decided by `DisplayRules.tileMark` in the package.
struct TileBadge: View {
    let mark: TileMark

    var body: some View {
        // **The iPhone's sizes, doubled**: symbol 10, text `Theme.badge`, padding 5/6 by
        // 3, outer padding 6. This used to be a half-adopted version: 15 bold and 17
        // semibold are neither iPhone steps nor TV steps, and the padding was only enlarged
        // by eye.
        HStack(spacing: 6) {
            if mark == .watched {
                Image(systemName: "checkmark").font(Theme.badge)
            }
            if let text = wording {
                // No letter spacing, as on iPhone: "3 offen" and "2 Staffeln" are ordinary
                // words, not capitals.
                Text(verbatim: text).font(Theme.badge)
            }
        }
        .foregroundStyle(Theme.font)
        .padding(.horizontal, wording == nil ? 10 : 12)
        .padding(.vertical, 6)
        .background {
            // `cornerSmall` (14), not `cornerTile`: the badge is about 36 pt high, the tile
            // below 208 wide, so the same value would be a completely different rounding on
            // it. The 14 used to be a plain number and has become exactly the small step;
            // on iPhone the same place uses 9 against the tile's 10.
            RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                .fill(Theme.reason.opacity(0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                        .strokeBorder(Theme.margin)
                }
        }
        .padding(12)
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

/// **The Quick Connect code, one field per character.**
///
/// It existed twice in the app, in different forms: on the Quick Connect page as fields at
/// 92 pt, when adding a server as one line at 80 with letter spacing 14. The same code, the
/// same task (someone copies it onto another device), and two looks.
///
/// The fields win, and the reasoning was already there: set apart, you do not miscount
/// while copying. That applies doubly on the TV, because you read across the room with the
/// phone in hand.
///
/// 92 pt is deliberately outside the type ladder. The ladder orders text; this is not a
/// step in the layout but legibility at three meters, the same reason the ladder is doubled
/// on the TV at all, thought one step further.
struct CodeFields: View {
    let code: String

    var body: some View {
        HStack(spacing: 20) {
            ForEach(Array(code.enumerated()), id: \.offset) { pair in
                Text(String(pair.element))
                    .font(.system(size: 92, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.font)
                    .frame(width: 120, height: 160)
                    .background(Theme.raised,
                                in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }
        }
        // A code is a character sequence, not a word; otherwise VoiceOver reads "ABCD" as a
        // syllable instead of four characters.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Code"))
        .accessibilityValue(Text(verbatim: code.map(String.init).joined(separator: " ")))
    }
}
