import SwiftUI

/// Scrolls a list to the top in two cases, in one component:
///
/// - **The ordering changes** (`order`: sort, filter, genre). Someone 300
///   titles deep would otherwise get the new order at the old position.
/// - **Second tap on the tab** you are already in (`nochmal`, see
///   `tabStillTimes`), while the area is visible (`active`).
///
/// The initial value triggers nothing. There is only one `scrollPosition` per
/// scroll view, hence both triggers in one component.
private struct PostTopModifier: ViewModifier {
    let order: String
    let anotherTime: Int
    let active: Bool
    @State private var spot = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollPosition($spot)
            .onChange(of: order) { _, _ in
                spot.scrollTo(edge: .top)
            }
            .onChange(of: anotherTime) { _, _ in
                guard active else { return }
                withAnimation(Theme.toggle) { spot.scrollTo(edge: .top) }
            }
    }
}

extension View {
    /// Attach to the `ScrollView` (or an ancestor).
    func toTop(order: String = "", anotherTime: Int = 0, active: Bool = true) -> some View {
        modifier(PostTopModifier(order: order, anotherTime: anotherTime, active: active))
    }
}
