import JellyfinKit
import func SwiftlyCore.delayForNewTitle

/// **Which track delay goes along to the next title, decided by the core** (`delayForNewTitle`, the Rust port of
/// `Delay.forNewTitle`): the same title and the same series keep it, anything else starts at zero.
enum DelayCarry {
    static func forNewTitle(
        _ current: Delay, oldTitle: String, oldSeries: String?, newTitle: String, addedSeries: String?
    ) -> Delay {
        Delay(milliseconds: Int(delayForNewTitle(
            currentMs: Int64(current.milliseconds), oldTitle: oldTitle, oldSeries: oldSeries,
            newTitle: newTitle, addedSeries: addedSeries)))
    }
}
