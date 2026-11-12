import SwiftUI
import JellyfinKit

/// A tile in the "Extras" row, on the movie page and under the series.
/// Tapping plays the extra like any other title: the same plan, Direct
/// Play, never transcode.
struct ExtraTile: View {
    let model: AppModel
    let extra: Item
    /// The core's picture and wording of this extra (`Tile`); `nil` keeps the title's own.
    var look: RustTileLook? = nil
    @Binding var prepares: Bool
    let missing: () -> Void
    let play: (PlayRequest) -> Void

    var body: some View {
        Button {
            Theme.jerk(.medium)
            PlayRequest.start(extra, model: model, prepares: $prepares,
                                  missing: missing, play: play)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Picture(url: look?.image ?? model.imageURL(for: extra, maxHeight: 300),
                     width: 210, height: 118) {
                    Image(icon: "film", size: Theme.emptySymbol / 2)
                        .font(.app(size: Theme.emptySymbol / 2))
                        .foregroundStyle(Theme.font)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.area)
                }
                VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: look?.title ?? extra.name)
                    .font(Theme.tile).foregroundStyle(Theme.font).lineLimit(1)
                if let look {
                    // The core words the runtime line (an extra without a runtime has none).
                    if let line = look.subtitle {
                        Text(verbatim: line).font(Theme.small)
                            .foregroundStyle(Theme.fontVeryQuiet)
                    }
                // An extra without a runtime reports 0, not nothing; without the rule it
                // would read "0 min.".
                } else if DisplayRules.runtimeShow(seconds: extra.runtimeSeconds),
                   let s = extra.runtimeSeconds {
                    Text(runtime(s)).font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
                }
            }
            .frame(width: 210, alignment: .leading)
        }
        .buttonStyle(Theme.PressButton())
        .disabled(prepares)
    }
}
