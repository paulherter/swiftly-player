import JellyfinKit
import SwiftUI

/// Where focus can stand on the search page. The keyboard remembers its last key by this, and the
/// results remember their last tile.
enum SearchTarget: Hashable {
    case key(String)
    case hit(String)
    case recent(String)
    case retry
}

/// The measures of the search page, computed from the spec and never typed.
enum SearchLayout {
    /// 6 keys, 5 gaps, the card's inset on both sides: 444.
    static var keyboardWidth: CGFloat {
        CGFloat(SearchKeys.columns) * TVSpec.searchKey
            + CGFloat(SearchKeys.columns - 1) * TVSpec.searchKeyGap
            + 2 * TVSpec.listCardInset
    }

    /// 5 posters, 4 gaps: 1240.
    static var resultsWidth: CGFloat {
        CGFloat(TVSpec.searchColumns) * Theme.posterWidth
            + CGFloat(TVSpec.searchColumns - 1) * Theme.gridColumn
    }
}

/// **The on-screen keyboard of the search: a card with the field on top and the keys below.**
///
/// Not `.searchable` and not the system keyboard: that one is a full screen on top of the results, and
/// Android TV has no counterpart, so the two TVs would type differently. Here both draw the same grid
/// (`SearchKeys` in the package) next to the hits, and every letter is on the page at once.
///
/// At rest the keys are bare characters on the card, no surface of their own: forty-odd surfaces next
/// to each other would be a checkerboard, the one surface is the card. In focus a key turns white
/// with dark text, the rule of every button on the TV.
///
/// The field is never focusable. It only shows what was typed, cut at the front when it gets long so
/// that the last letter always stays visible.
struct TVSearchKeyboard: View {
    @Binding var term: String
    var focus: FocusState<SearchTarget?>.Binding

    /// A long press on "delete" has already emptied the field; the release must not delete once more.
    @State private var clearedByHold = false

    var body: some View {
        VStack(spacing: TVSpec.searchFieldGap) {
            field
            keys
        }
        .padding(TVSpec.listCardInset)
        .frame(width: SearchLayout.keyboardWidth)
        .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        // A hardware keyboard on the TV (or a Bluetooth one) types into the field as well.
        .onKeyPress(phases: [.down, .repeat]) { press in
            if press.key == .delete {
                term = SearchKeys.withoutLast(term)
                return .handled
            }
            guard !press.characters.isEmpty else { return .ignored }
            let next = SearchKeys.hardware(press.characters, into: term)
            guard next != term else { return .ignored }
            term = next
            return .handled
        }
    }

    // MARK: Field

    private var caret: some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: TVSpec.searchCaretWidth, height: TVSpec.searchCaretHeight)
            .accessibilityHidden(true)
    }

    /// Typed text first, then the caret. It stands still: a blinking one would be a pulse, and the
    /// page has none.
    private var field: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: TVSpec.valueIcon, weight: .medium))
                .foregroundStyle(Theme.fontVeryQuiet)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                if term.isEmpty {
                    caret
                    Text("Titel, Serie, Person")
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .lineLimit(1)
                        .padding(.leading, 6)
                } else {
                    // A trailing space is not measured by `Text`; a no-break space is, so the caret
                    // moves when the space key is pressed.
                    Text(verbatim: term.replacingOccurrences(of: " ", with: "\u{00A0}"))
                        .foregroundStyle(Theme.font)
                        .lineLimit(1)
                        .truncationMode(.head)
                    caret
                }
            }
            .font(Theme.body)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: Theme.buttonHeight)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Titel, Serie, Person"))
        .accessibilityValue(Text(verbatim: term))
    }

    // MARK: Keys

    private var keys: some View {
        VStack(spacing: TVSpec.searchKeyGap) {
            ForEach(Array(SearchKeys.rows(speech: true).enumerated()), id: \.offset) { _, row in
                HStack(spacing: TVSpec.searchKeyGap) {
                    ForEach(row, id: \.id) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    private func width(_ span: Int) -> CGFloat {
        CGFloat(span) * TVSpec.searchKey + CGFloat(span - 1) * TVSpec.searchKeyGap
    }

    @ViewBuilder
    private func keyButton(_ key: SearchKeys.Key) -> some View {
        switch key.kind {
        case .letter:
            Button {
                term = SearchKeys.typed(key.character, into: term)
            } label: {
                Text(verbatim: key.character).font(Theme.listTitle)
            }
            .buttonStyle(SearchKeyStyle())
            .frame(width: width(key.span), height: TVSpec.searchKey)
            .focused(focus, equals: .key(key.id))

        case .space:
            Button {
                term = SearchKeys.withSpace(term)
            } label: {
                Image(systemName: "space").font(.system(size: TVSpec.valueIcon, weight: .medium))
            }
            // At the start of a word and after a space the key does nothing. It stays focusable so
            // that the focus paths do not jump.
            .buttonStyle(SearchKeyStyle(muted: !SearchKeys.spaceFits(term)))
            .frame(width: width(key.span), height: TVSpec.searchKey)
            .focused(focus, equals: .key(key.id))
            .accessibilityLabel(Text("Leerzeichen"))

        case .delete:
            Button {
                // The hold fires while the key is still down; the click comes on release.
                if clearedByHold { clearedByHold = false; return }
                term = SearchKeys.withoutLast(term)
            } label: {
                Image(systemName: "delete.left").font(.system(size: TVSpec.valueIcon, weight: .medium))
            }
            .buttonStyle(SearchKeyStyle(muted: term.isEmpty))
            .frame(width: width(key.span), height: TVSpec.searchKey)
            .focused(focus, equals: .key(key.id))
            // Hold for half a second: everything goes. No fourth key "clear all".
            .onLongPressGesture(minimumDuration: 0.5) {
                guard !term.isEmpty else { return }
                clearedByHold = true
                term = ""
            }
            .accessibilityLabel(Text("Löschen"))
            .accessibilityHint(Text("Halten löscht alles"))

        case .speak:
            SpeakKey(term: $term, focus: focus, id: key.id)
                .frame(width: width(key.span), height: TVSpec.searchKey)
        }
    }
}

/// **The mic key is a real text field.** Only a field that the remote has focused and clicked opens the
/// system keyboard, and only that keyboard lets the Siri button dictate. A button that tried to open a
/// hidden field did nothing on the TV. So the field *is* the key: it looks like the other keys, a click
/// opens the system input, the Siri button dictates into it, and what is said lands in the search term.
private struct SpeakKey: View {
    @Binding var term: String
    var focus: FocusState<SearchTarget?>.Binding
    let id: String

    private var focused: Bool { focus.wrappedValue == .key(id) }

    var body: some View {
        TextField("Titel, Serie, Person", text: $term)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .foregroundStyle(.clear)
            .tint(.clear)
            .focused(focus, equals: .key(id))
            .opacity(TVSpec.hiddenFieldOpacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                Image(systemName: "mic")
                    .font(.system(size: TVSpec.valueIcon, weight: .medium))
                    .foregroundStyle(focused ? Theme.reason : Theme.fontQuiet)
                    .allowsHitTesting(false)
            }
            .background(focused ? Color.white : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .scaleEffect(focused ? Theme.focusMagnifierSmall : 1)
            .animation(Theme.focusAnimation, value: focused)
            .accessibilityLabel(Text("Sprechen"))
    }
}

/// A key: bare character at rest, white surface with dark character in focus, one step closer.
private struct SearchKeyStyle: ButtonStyle {
    /// The key does nothing right now (space after a space, delete on an empty field).
    var muted = false

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, muted: muted)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let muted: Bool
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .foregroundStyle(character)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                .scaleEffect((focus ? Theme.focusMagnifierSmall : 1) * (configuration.isPressed ? TVSpec.pressScale : 1))
                .animation(Theme.focusAnimation, value: focus)
                .animation(Theme.pressCurve(configuration.isPressed), value: configuration.isPressed)
        }

        /// A muted key in focus gets only the calm surface, not white, and keeps a readable character.
        private var surface: Color {
            guard focus else { return .clear }
            return muted ? Theme.focusArea : Color.white
        }

        private var character: Color {
            if focus { return muted ? Theme.fontQuiet : Theme.reason }
            return muted ? Theme.fontVeryQuiet : Theme.fontQuiet
        }
    }
}
