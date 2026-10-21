import JellyfinKit
import SwiftUI

// **The pieces of the looks panel that only iPhone and iPad have:** the small segments (and,
// in debug builds, the accent dots). The panel itself is `LooksPanel` (`LookGiftSheet.swift`).


/// **A few choices as segments, drawn by the app.** The chosen one's surface slides over
/// with a short smooth curve (0.25 s, no overshoot); the labels cross-fade with it.
///
/// One surface moved by an offset, not one per segment matched by geometry: the matched
/// version cut over hard inside a list row, where the transaction carried no animation.
struct Segments<Value: Hashable>: View {
    let options: [Value]
    let value: Value
    let title: (Value) -> String
    let choose: (Value) -> Void

    private static var slide: Animation { Motion.select }

    var body: some View {
        let index = options.firstIndex(of: value) ?? 0
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    guard option != value else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    choose(option)
                } label: {
                    Text(title(option))
                        .growing(13, .semibold)
                        .foregroundStyle(value == option ? Theme.font : Theme.fontQuiet)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(value == option ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .frame(width: max(112, CGFloat(options.count) * 56), height: 32)
        .background(alignment: .leading) {
            GeometryReader { geometry in
                let width = (geometry.size.width - 4 - CGFloat(options.count - 1) * 2) / CGFloat(max(options.count, 1))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(white: 0.29))
                    .frame(width: width, height: geometry.size.height - 4)
                    .offset(x: 2 + CGFloat(index) * (width + 2), y: 2)
            }
        }
        .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        .frame(height: 44)
        .animation(Self.slide, value: index)
    }
}
