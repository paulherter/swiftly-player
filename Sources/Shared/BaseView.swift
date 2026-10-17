#if canImport(UIKit)
import UIKit

/// The platform's view class.
///
/// UIKit exists on iPhone and TV, not on the Mac. Instead of writing
/// `VLCPlayerView` twice, which would create exactly the duplication this project
/// otherwise fights, both hang on this name.
///
/// What really differs between the toolkits is manageable: the layout hook is
/// named differently, the background color sits on the layer rather than the view
/// in AppKit, and the autoresizing values are named differently. These four places
/// are `#if` in the player; everything else applies verbatim to both.
typealias BaseView = UIView

extension BaseView {
    /// "Grow with the parent": named differently in the two toolkits.
    static var growing: AutoresizingMask { [.flexibleWidth, .flexibleHeight] }
    static var withoutRequestMetric: CGFloat { UIView.noIntrinsicMetric }
}
#else
import AppKit

/// See the UIKit version above; the same explanation.
typealias BaseView = NSView

extension BaseView {
    static var growing: AutoresizingMask { [.width, .height] }
    static var withoutRequestMetric: CGFloat { NSView.noIntrinsicMetric }
}
#endif
