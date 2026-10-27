import JellyfinKit
import SwiftUI

/// **The letter strip on Apple TV**, in the right margin beside a "By name" grid.
///
/// The remote has no slide, so the strip is a column of focusable letters: right from the
/// last column reaches it, up and down walk the letters and the grid follows at once, a
/// press hands focus to the first title of that letter, left goes back into the grid.
/// While focus is in the grid, the letter of the topmost title lights up, as on the
/// iPhone.
///
/// **Every letter, scrolling.** A library in two alphabets has some 45 letters, more than
/// fit at a size readable from the sofa; condensing them as on the iPhone left gaps ("#, C,
/// K, O…") that read as a broken order. The column scrolls instead: tvOS keeps the
/// focused letter in view, and without focus the current letter stays centred.
struct TVAlphabetRail: View {
    let index: AlphabetIndex
    /// The letter of the topmost visible title.
    let current: String?
    /// Focus moved onto a letter: the grid scrolls there, focus stays on the strip.
    let preview: (String) -> Void
    /// The letter was pressed: the grid scrolls there and focus moves to its first title.
    let choose: (String) -> Void

    @FocusState private var focused: String?

    /// Wide enough for a focused letter in its circle, narrow enough for the 80 pt margin.
    static let width: CGFloat = 56
    /// One letter's row, readable from the sofa.
    static let row: CGFloat = 40

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(index.entries) { entry in
                        Button { choose(entry.letter) } label: {
                            LetterLabel(letter: entry.letter, current: entry.letter == current,
                                        height: Self.row)
                        }
                        .buttonStyle(LetterStyle())
                        .focused($focused, equals: entry.letter)
                        .id(entry.letter)
                    }
                }
                .padding(.vertical, Self.row)
            }
            .scrollIndicators(.hidden)
            // A soft edge says there are more letters above or below.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: 0.06),
                                         .init(color: .black, location: 0.94),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: current) { _, new in
                guard focused == nil, let new else { return }
                withAnimation(Motion.select) { reader.scrollTo(new, anchor: .center) }
            }
        }
        .frame(width: Self.width)
        .focusSection()
        .onChange(of: focused) { _, new in
            if let new { preview(new) }
        }
        .accessibilityLabel(Text("Alphabet"))
    }
}

/// One letter; its look depends on focus, which only a view inside the button can read.
private struct LetterLabel: View {
    let letter: String
    let current: Bool
    let height: CGFloat
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(verbatim: letter)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isFocused ? Theme.font : current ? Theme.accent : Theme.fontQuiet)
            .frame(width: 40, height: 40)
            .background(Circle().fill(isFocused ? Theme.accent : .clear))
            .scaleEffect(isFocused ? 1.15 : 1)
            .frame(width: TVAlphabetRail.width, height: height)
            .animation(Motion.select, value: isFocused)
            .animation(Motion.select, value: current)
    }
}

/// No system card or lift: the circle in ``LetterLabel`` is the whole focus look.
private struct LetterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
