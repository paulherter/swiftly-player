import Testing
@testable import JellyfinKit

@Suite("Fokus nach dem Schließen eines Player-Menüs")
struct PlayerMenuFocusReturnTests {
    @Test("Zurück zum Knopf, der das Menü geöffnet hat")
    func returnsToOpener() {
        var back = PlayerMenuFocusReturn()
        back.opened(from: .settings)
        #expect(back.closed() == .settings)
    }

    @Test("Ein anderer Knopf tauscht das offene Menü: der zuletzt gedrückte zählt")
    func swapKeepsLast() {
        var back = PlayerMenuFocusReturn()
        back.opened(from: .tracks)
        back.opened(from: .episodes)
        #expect(back.closed() == .episodes)
    }

    @Test("Die Staffelliste hängt an der Folgen-Box und lässt den Knopf stehen")
    func seasonBoxKeepsOpener() {
        var back = PlayerMenuFocusReturn()
        back.opened(from: .episodes)
        back.opened(from: nil)
        #expect(back.closed() == .episodes)
    }

    @Test("Nur einmal: nach dem Schließen ist nichts mehr gemerkt")
    func onlyOnce() {
        var back = PlayerMenuFocusReturn()
        back.opened(from: .chapters)
        _ = back.closed()
        #expect(back.closed() == nil)
    }
}
