import Foundation
import Testing
@testable import JellyfinKit

@Suite("Auffrischung")
struct RefreshTests {

    @Test("Noch nie geladen — dann auf jeden Fall")
    func stillNever() {
        #expect(Refresh.dueReturn(recent: nil))
    }

    @Test("Kurz weggeschaltet — die Reihen bleiben stehen")
    func shortDistance() {
        let now = Date()
        let just = now.addingTimeInterval(-5)
        #expect(!Refresh.dueReturn(recent: just, now: now))
    }

    @Test("Genau auf der Frist zählt schon als fällig")
    func onEdge() {
        let now = Date()
        let exact = now.addingTimeInterval(-Refresh.deadline)
        #expect(Refresh.dueReturn(recent: exact, now: now))
    }

    /// The case at hand: finished watching on the TV, then picked up the
    /// phone. Switching devices takes longer than the deadline.
    @Test("Nach einem Gerätewechsel wird neu geholt")
    func devicesSwitch() {
        let now = Date()
        let before = now.addingTimeInterval(-90)
        #expect(Refresh.dueReturn(recent: before, now: now))
    }

    @Test("Eine eigene Frist gilt statt der voreingestellten")
    func ownDeadline() {
        let now = Date()
        let preSixty = now.addingTimeInterval(-60)
        #expect(!Refresh.dueReturn(recent: preSixty,
                                                  now: now, deadline: 120))
        #expect(Refresh.dueReturn(recent: preSixty,
                                                 now: now, deadline: 10))
    }
}
