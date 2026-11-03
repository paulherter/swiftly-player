import JellyfinKit
import SwiftUI

/// **The index strip beside a grid**, as in Plex or the iOS section index: letters for
/// "By name", years or ratings for the other orders (``AlphabetIndex``).
///
/// A tap or a slide along the strip jumps the grid to the first title of that entry;
/// while the grid scrolls on its own, the entry of the topmost title lights up. Only
/// entries the list actually has are shown, condensed when the height is not enough for
/// all of them.
///
/// **One gesture for tap and slide** (`DragGesture` with no minimum distance): the
/// thumb lands on a letter and may then slide, the same as the system index. Each new
/// letter under the finger jumps once and ticks once.
struct AlphabetRail: View {
    let index: AlphabetIndex
    /// The key of the topmost visible title.
    let current: String?
    let jump: (String) -> Void

    /// The letter under the finger while it is down; it wins over `current`.
    @State private var touched: String?
    /// **The last entry jumped to, until the grid is there.** The grid loads and scrolls
    /// first; without this the strip fell back to the old entry meanwhile.
    @State private var held: String?

    private var shownKey: String? { touched ?? held ?? current }

    /// The smallest row a letter gets; below it the strip condenses.
    static let minimumRow: CGFloat = 14
    static let width: CGFloat = 22
    /// Fewer titles than this need no strip.
    static let minimumTitles = 30

    var body: some View {
        GeometryReader { frame in
            // **The whole height, as in Plex**: the letters spread from the header to the
            // bar, so a long strip and a short one both reach the same edges.
            let shown = index.condensed(fitting: max(2, Int(frame.size.height / Self.minimumRow)))
            let row = frame.size.height / CGFloat(max(AlphabetIndex.rows(shown), 1))
            VStack(spacing: 0) {
                ForEach(shown) { entry in
                    // The next step of a scale, half a row high (``AlphabetIndex/gapShare``).
                    if entry.gap {
                        Circle().fill(Theme.fontVeryQuiet).frame(width: 3, height: 3)
                            .frame(width: Self.width, height: row * AlphabetIndex.gapShare)
                    }
                    Text(verbatim: entry.label)
                        .font(.app(size: 11, weight: .semibold))
                        .foregroundStyle(entry.letter == shownKey ? Theme.accent : Theme.fontQuiet)
                        .frame(width: Self.width, height: row)
                }
            }
            // The light moves from entry to entry instead of jumping.
            .animation(Motion.select, value: shownKey)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Before layout the height can be 0; `Int(.infinity)` would trap.
                        guard row > 0,
                              let letter = AlphabetIndex.entry(at: value.location.y,
                                                               height: frame.size.height,
                                                               in: shown)?.letter
                        else { return }
                        guard letter != touched else { return }
                        touched = letter
                        jump(letter)
                    }
                    .onEnded { _ in
                        held = touched
                        touched = nil
                    }
            )
            .sensoryFeedback(.selection, trigger: touched) { _, new in new != nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Alphabet"))
            .accessibilityValue(Text(verbatim: index.label(of: touched ?? current) ?? ""))
            .accessibilityAdjustableAction { direction in
                let letters = shown.map(\.letter)
                let at = letters.firstIndex(of: current ?? "") ?? 0
                let next = direction == .increment ? min(at + 1, letters.count - 1) : max(at - 1, 0)
                jump(letters[next])
            }
        }
        .frame(width: Self.width)
        .onChange(of: current) { _, new in
            if let held, new == held {
                self.held = nil
            }
        }
        .task(id: held) {
            guard held != nil else { return }
            try? await Task.sleep(for: .seconds(AlphabetIndex.holdSeconds))
            if !Task.isCancelled { held = nil }
        }
    }
}
