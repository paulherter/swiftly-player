import JellyfinKit
import SwiftUI

/// **The letter strip on Apple TV**, in the right margin beside a "By name" grid.
///
/// The remote has no slide, so the strip is a column of focusable letters: right from the
/// last column reaches it, up and down walk the letters and the grid follows at once, a
/// press hands focus to the first title of that letter, left goes back into the grid.
/// While focus is in the grid, the letter of the topmost title lights up, as on the
/// iPhone.
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
    /// The smallest row a letter gets; below it the strip condenses. A letter on a TV must
    /// stay readable from the sofa.
    static let minimumRow: CGFloat = 32

    var body: some View {
        GeometryReader { frame in
            let shown = index.condensed(fitting: max(2, Int(frame.size.height / Self.minimumRow)))
            let row = frame.size.height / CGFloat(max(shown.count, 1))
            VStack(spacing: 0) {
                ForEach(shown) { entry in
                    Button { choose(entry.letter) } label: {
                        LetterLabel(letter: entry.letter, current: entry.letter == current, height: row)
                    }
                    .buttonStyle(LetterStyle())
                    .focused($focused, equals: entry.letter)
                }
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
