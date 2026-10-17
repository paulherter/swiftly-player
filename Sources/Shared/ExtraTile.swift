import SwiftUI
import JellyfinKit

/// A tile in the "Extras" row, on the movie page and under the series.
/// Tapping plays the extra like any other title: the same plan, Direct
/// Play, never transcode.
struct ExtraTile: View {
    let model: AppModel
    let extra: Item
    @Binding var prepares: Bool
    let missing: () -> Void
    let play: (PlayRequest) -> Void

    var body: some View {
        Button {
            Theme.jerk(.medium)
            PlayRequest.start(extra, model: model, prepares: $prepares,
                                  missing: missing, play: play)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Picture(url: model.imageURL(for: extra, maxHeight: 300),
                     width: 210, height: 118)
                Text(extra.name)
                    .font(Theme.tile).foregroundStyle(Theme.font).lineLimit(1)
                // An extra without a runtime reports 0, not nothing; without the rule it
                // would read "0 min.".
                if DisplayRules.runtimeShow(seconds: extra.runtimeSeconds),
                   let s = extra.runtimeSeconds {
                    Text(runtime(s)).font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
            }
            .frame(width: 210, alignment: .leading)
        }
        .buttonStyle(Theme.PressButton())
        .disabled(prepares)
    }
}
