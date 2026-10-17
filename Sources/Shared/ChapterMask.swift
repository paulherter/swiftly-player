import JellyfinKit
import SwiftUI

/// **The shape of the timeline: one segment per chapter.**
///
/// Lies as a mask over track, bar and notches. Drawing happens underneath as
/// before; the mask only cuts out the gaps and gives each segment its height.
/// So the three bars (iPhone, Mac, TV) keep their own structure, and none has to
/// piece its fill together per chapter.
///
/// **Without chapters it is a single capsule across the full width**, exactly the
/// shape the track had itself. Whoever has no chapters sees no difference.
///
/// Where to cut and which cuts are too narrow is computed by ``Kapitelleiste`` in
/// the package; only drawing is here.
struct ChapterMask: View {
    let pieces: [ChapterBar.Piece]
    let width: CGFloat
    /// The gap between two segments, as wide as a notch so chapter boundary and
    /// section boundary have the same weight.
    let gap: CGFloat
    let thickness: CGFloat
    /// **The segment that rises**: while scrubbing the one under the handle,
    /// otherwise none. Without chapters that is the whole bar, and it gets thicker
    /// when touched as before.
    let elevated: Int?
    let thicknessRaised: CGFloat
    /// How the rise runs: each platform with its own curve, and each respects Reduce
    /// Motion. `nil`: it jumps.
    let motion: Animation?

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(pieces.indices, id: \.self) { i in
                let frameRect = pieces[i].frameRect(width: Double(width), gap: Double(gap))
                Capsule()
                    .frame(width: CGFloat(frameRect.width),
                           height: i == elevated ? thicknessRaised : thickness)
                    .offset(x: CGFloat(frameRect.x))
            }
        }
        .frame(width: width, alignment: .leading)
        // **Only the heights change with motion, not the bar underneath.** If the
        // animation were on the whole bar, the fill would trail a beat behind the finger
        // on every chapter change.
        .animation(motion, value: elevated)
    }
}
