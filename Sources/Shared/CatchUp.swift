import SwiftUI

/// **Refresh only where someone is looking.**
///
/// Sections stay alive at opacity 0 after the first visit, and pages in the stack
/// sit under the top one. Every playback end and every checkmark used to make all
/// of them reload, including invisible ones: around 30 requests after every player
/// close, right when the end report runs. Now the covered page remembers that
/// something is due and catches up when you come back.
private struct CatchUpRunner: ViewModifier {
    let counter: Int
    /// From outside: applies in addition to the section and visibility.
    let front: Bool
    let tu: () -> Void

    @Environment(\.sectionActive) private var sectionActive
    /// The page is not covered by another one in the stack.
    @State private var visible = true
    /// Up to which counter value the page is up to date.
    @State private var completed: Int?

    private var active: Bool { sectionActive && visible && front }

    func body(content: Content) -> some View {
        content
            .onAppear {
                visible = true
                if completed == nil { completed = counter }
            }
            .onDisappear { visible = false }
            .onChange(of: counter) { _, new in
                guard active else { return }
                completed = new
                tu()
            }
            .onChange(of: active) { _, now in
                guard now, let completed, completed != counter else { return }
                self.completed = counter
                tu()
            }
    }
}

extension View {
    /// Calls `tu` when `counter` changes and the page is in front; otherwise at the
    /// next appearance.
    func catchUp(at counter: Int, front: Bool = true,
                   _ tu: @escaping () -> Void) -> some View {
        modifier(CatchUpRunner(counter: counter, front: front, tu: tu))
    }
}
