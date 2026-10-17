import JellyfinKit
import SwiftUI

extension View {
    /// **The scroll distance under a collapsing header**, for library, watchlist
    /// and collections. The computation and its reasoning are in `HeaderScrollDistance` in
    /// the package.
    ///
    /// `active` pauses the measurement while a section change recomputes the layout,
    /// since it is worthless then.
    func scrollDistance(active: Bool = true, _ setDown: @escaping (CGFloat) -> Void) -> some View {
        onScrollGeometryChange(for: CGPoint.self) {
            CGPoint(x: $0.contentInsets.top, y: $0.contentOffset.y)
        } action: { _, new in
            guard active, let distance = HeaderScrollDistance.distance(margin: new.x, offset: new.y) else { return }
            setDown(distance)
        }
    }
}
