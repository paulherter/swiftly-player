import SwiftUI

/// The rows of the settings pages.
///
/// Layout taken verbatim from the iPhone version: flat rows with hairlines,
/// groups separated only by whitespace and a small tracked title. No cards,
/// which would look foreign next to our flat surfaces.
///
/// Only what concerns the pointer differs: rows are 44 instead of 52 tall,
/// they light up on hover, and the value list expands in place instead of
/// appearing as a sheet from below.

/// **A group as its own surface.**
///
/// It used to carry its rows edge to edge between two hairlines, the older
/// style from before the card look. Decided together with iPhone and iPad: the
/// card delimits the group without whitespace and is the form people know
/// from the device.
///
/// **It is the one exception to "at most one filled surface per page".** A
/// settings page has no main subject and no white main button; the rule
/// protects that button's message, and where there is none it protects
/// nothing.
struct CardView<ContentBody: View>: View {
    @ViewBuilder let content: ContentBody

    var body: some View {
        VStack(spacing: 0) { content }
            // Card radius is 14, not 16: 16 belongs to standalone surfaces and popovers,
            // 14 to cards and groups. And `groupsArea` instead of `area`: a large
            // block carries the same tone lighter than a button (see the token).
            .background(Theme.groupsArea,
                        in: RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
    }
}

/// **Normal case, not uppercase.**
///
/// It used to be 11 pt, uppercase, tracked at 1.2 and in its own "white 40%",
/// the iOS 6 pattern Apple has not used for years. In the TV app a group is
/// simply headed "Automatic Playback": the same size as a row heading, in a
/// muted tone, in normal case.
///
/// And 11 pt was the smallest size in the app, above a group whose rows use
/// 15, so the heading was quieter than what it heads.
struct GroupsTitle: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(Theme.rail)
            .tracking(Theme.lockRail)
            .foregroundStyle(Theme.fontQuiet)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A group with a title, the card below it.
struct SettingGroup<ContentBody: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: ContentBody

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupsTitle(text: title)
                .padding(.top, 26)
                .padding(.bottom, 10)
            CardView { content }
        }
    }
}

/// A group without a title: the same card, just without the heading.
struct RowsGroup<ContentBody: View>: View {
    @ViewBuilder let content: ContentBody

    var body: some View { CardView { content } }
}

/// The body of every row: icon, title, subtitle, something on the right.
private struct RowsBody<Right: View>: View {
    let symbol: String
    let title: Text
    var under: Text?
    var accent = false
    let hovers: Bool
    @ViewBuilder let right: Right

    var body: some View {
        // Icon 15 in a 20-wide column, 14 spacing to the text, title 15 semibold,
        // subtitle 12 in `schriftSehrLeise`. The subtitle used to be "white 45%", a
        // fourth text level next to the three that exist.
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(Theme.body)
                .foregroundStyle(accent ? Theme.accent : Theme.fontQuiet)
                .frame(width: 20)
                // Image only, next to the title; otherwise VoiceOver reads the symbol name
                // before every row.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(Theme.listTitle)
                    .foregroundStyle(accent ? Theme.accent : Theme.font)
                if let under {
                    under
                        .font(Theme.small)
                        // **One step lighter under the pointer.** The hover surface raises the
                        // background, and `schriftSehrLeise` on it drops below 4.5:1 by calculation.
                        // If you raise a surface, raise the quiet text colors with it.
                        .foregroundStyle(hovers ? Theme.fontQuiet
                                                 : Theme.fontVeryQuiet)
                }
            }
            Spacer(minLength: 12)
            right
        }
        .padding(.horizontal, 12)
        // **"14 + content + 14" as padding, not as a fixed height.**
        //
        // This used to be `minHeight: 46` with exactly that reasoning, but a minimum
        // height does not count the content. Single-line it worked: about 20 pt of
        // text, 13 above and below. A row **with a subtitle** is 37 tall (17 title,
        // 2 spacing, 12 small), which left four and a half points on each side, too
        // cramped. Quick Connect uses the same form.
        //
        // As padding the rule holds for both: 48 single-line, 65 two-line. The
        // minimum height remains as a lower bound for the hit area, but now applies
        // only if a row happens to contain less.
        .padding(.vertical, 14)
        .frame(minHeight: 46)
        .background(hovers ? Theme.hoverArea : .clear)
        .contentShape(Rectangle())
    }
}

/// A row with a switch. Not a `Toggle`, which brings Apple's capsule shape,
/// Apple's green and Apple's dimensions.
struct ToggleRow: View {
    let symbol: String
    let title: Text
    var under: Text?
    @Binding var an: Bool

    @State private var hovers = false

    var body: some View {
        Button { an.toggle() } label: {
            RowsBody(symbol: symbol, title: title, under: under, hovers: hovers) {
                ToggleSwitch(an: an)
            }
        }
        .buttonStyle(Theme.PressRow())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityRepresentation { Toggle(isOn: $an) { title } }
    }
}

/// The switch itself: a capsule, accent color when on.
struct ToggleSwitch: View {
    let an: Bool

    var body: some View {
        // Off: `rand`, not a custom opacity; same role as any resting border, so the
        // same token. The dimensions are the Mac's (38 × 22 instead of 46 × 28): a
        // pointer is more precise, and the row is 44 tall here instead of 52.
        Capsule()
            .fill(an ? Theme.accent : Theme.margin)
            .frame(width: 38, height: 22)
            .overlay(alignment: an ? .trailing : .leading) {
                Circle()
                    .fill(an ? Theme.reason : Theme.font)
                    .frame(width: 16, height: 16)
                    .padding(3)
            }
            .animation(Theme.toggle, value: an)
    }
}

// Custom controls are just "button" to VoiceOver at first. The following
// modifiers say what each one is, with the same care the iPhone version
// gives its components.

/// A row that shows a value on the right and does something when clicked.
struct ValuesRow: View {
    let symbol: String
    let title: Text
    var under: Text?
    var value: String?
    var accent = false
    var arrow = false
    var action: (() -> Void)?
    /// Checkmark instead of arrow or value, for a choice among several; see the
    /// genre form in `PresentationView`.
    var checkmark = false
    /// Whether the row is highlighted on hover.
    ///
    /// **By default only if it has its own action**, otherwise a display-only
    /// row would pretend it could be pressed.
    ///
    /// But if the row is the **label inside an outer button**, it is pressable
    /// and still has no action of its own. That is what this switch is for.
    /// Before, `action: {}` was used as a workaround, which was why "Wiedergabe"
    /// and "Einstellungen" in the profile **did not react at all**: an empty
    /// action is not `nil`, so the row built its own button, which swallowed the
    /// click before the outer one saw it.
    var hoverable: Bool?

    @State private var hovers = false

    private var hasButton: Bool { action != nil }

    var body: some View {
        // Without an action of its own, **no** button: the row is the label of an
        // outer button, and a button inside it would swallow the click. Same bug as
        // with the tiles.
        Group {
            if let action {
                Button(action: action) { shell }.buttonStyle(Theme.PressRow())
            } else {
                shell
            }
        }
        .onHover { hovers = $0 && (hoverable ?? hasButton) }
        .animation(Theme.timeFloat, value: hovers)
        // The checkmark is hidden; "selected" carries the row's trait.
        .accessibilityAddTraits(checkmark ? .isSelected : [])
    }

    private var shell: some View {
            RowsBody(symbol: symbol, title: title, under: under,
                        accent: accent, hovers: hovers) {
                HStack(spacing: 8) {
                    // Value on the right 15 `schriftLeise`, chevron 13 semibold in
                    // `schriftSehrLeise`. These used to be 14 and 12, neither on the type scale.
                    if let value {
                        Text(verbatim: value)
                            .font(Theme.body)
                            .foregroundStyle(Theme.fontQuiet)
                    }
                    if arrow {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.fontVeryQuiet)
                            // Only says "there is more here"; the row title already says where.
                            .accessibilityHidden(true)
                    }
                    // The checkmark stands for a multiple choice: being checked is the state of
                    // the thing itself there, and carries the accent color (the second exception
                    // to the accent rule).
                    if checkmark {
                        Image(systemName: "checkmark")
                            .font(Theme.listTitle)
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                    }
                }
            }
    }
}

/// The value list. On iPhone a sheet from below; here it expands **under the
/// row**. "A choice stays in place", the same rule as for the season pill and
/// the More list.
struct ValuesList<E: Identifiable>: View {
    let entries: [E]
    let label: (E) -> String
    let isSelected: (E) -> Bool
    let select: (E) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entryRecord in
                ValueSelectionRow(text: label(entryRecord),
                              selected: isSelected(entryRecord)) { select(entryRecord) }
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 48)
        // One step above the card: in dark mode depth goes upward.
        .background(Theme.area)
        .overlay(alignment: .bottom) { SheetLine() }
    }
}

private struct ValueSelectionRow: View {
    let text: String
    let selected: Bool
    let pick: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: pick) {
            // **Selected means white, not accent.** A choice among siblings is a
            // ranking, and rank is carried by tone and fill. The accent used to be on
            // text and checkmark.
            HStack(spacing: 8) {
                Text(verbatim: text)
                    .font(Theme.body)
                    .foregroundStyle(selected ? Theme.font : Theme.fontQuiet)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.listTitle)
                        .foregroundStyle(Theme.font)
                        .frame(width: 14)
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
        // Which value applies used to depend on tone and checkmark, neither of which
        // VoiceOver sees. The neighboring components already set the same trait.
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Header of a subpage: back arrow and title side by side.
///
/// On iPhone these are two things, an arrow at the top left and the title in
/// the content. A window has no swipe back, so the arrow must be visible and
/// hittable; side by side it reads as one line.
struct SubpageHeader: View {
    var title: LocalizedStringKey = ""
    /// **When the title comes from the server.** A genre is called what it is
    /// called and must not go through the translation table: "Action" as a key
    /// might hit something entirely different there.
    var name: String? = nil
    let back: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // **The way back is a bare arrow.** It used to be an `Aktionsknopf` with the
            // ring turned off, a button posing as something else.
            BackArrow(back: back)
            Group {
                if let name { Text(verbatim: name) } else { Text(title) }
            }
                .font(Theme.titleLarge)
                .tracking(Theme.lockTitle)
                .foregroundStyle(Theme.font)
                // **A server-provided name has no length limit.** Without `lineLimit`, a
                // long library or server name in 28 bold wrapped over three lines and pushed
                // the page below away. It now shrinks instead of pushing, the same solution
                // as on the detail pages.
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            Spacer(minLength: 0)
        }
    }
}
