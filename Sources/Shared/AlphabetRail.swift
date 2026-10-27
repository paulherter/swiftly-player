import JellyfinKit
import SwiftUI

/// **The letter strip beside an A–Z grid**, as in Plex or the iOS section index.
///
/// A tap or a slide along the strip jumps the grid to the first title of that letter;
/// while the grid scrolls on its own, the letter of the topmost title lights up. Only
/// letters the list actually has are shown (``AlphabetIndex``), condensed when the
/// height is not enough for all of them.
///
/// **One gesture for tap and slide** (`DragGesture` with no minimum distance): the
/// thumb lands on a letter and may then slide, the same as the system index. Each new
/// letter under the finger jumps once and ticks once.
struct AlphabetRail: View {
    let index: AlphabetIndex
    /// The letter of the topmost visible title.
    let current: String?
    let jump: (String) -> Void

    /// The letter under the finger while it is down; it wins over `current`.
    @State private var touched: String?

    /// The smallest row a letter gets; below it the strip condenses.
    static let minimumRow: CGFloat = 14
    static let width: CGFloat = 22

    var body: some View {
        GeometryReader { frame in
            // **The whole height, as in Plex**: the letters spread from the header to the
            // bar, so a long strip and a short one both reach the same edges.
            let shown = index.condensed(fitting: max(2, Int(frame.size.height / Self.minimumRow)))
            let row = frame.size.height / CGFloat(max(shown.count, 1))
            VStack(spacing: 0) {
                ForEach(shown) { entry in
                    Text(verbatim: entry.letter)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(entry.letter == (touched ?? current) ? Theme.accent : Theme.fontQuiet)
                        .frame(width: Self.width, height: row)
                }
            }
            // The light moves from letter to letter instead of jumping.
            .animation(Motion.select, value: touched ?? current)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let at = Int(value.location.y / row)
                        let letter = shown[min(max(at, 0), shown.count - 1)].letter
                        guard letter != touched else { return }
                        touched = letter
                        jump(letter)
                    }
                    .onEnded { _ in touched = nil }
            )
            .sensoryFeedback(.selection, trigger: touched) { _, new in new != nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Alphabet"))
            .accessibilityValue(Text(verbatim: touched ?? current ?? ""))
            .accessibilityAdjustableAction { direction in
                let letters = shown.map(\.letter)
                let at = letters.firstIndex(of: current ?? "") ?? 0
                let next = direction == .increment ? min(at + 1, letters.count - 1) : max(at - 1, 0)
                jump(letters[next])
            }
        }
        .frame(width: Self.width)
    }
}
