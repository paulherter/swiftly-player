import Testing
@testable import JellyfinKit

@Suite("Bewertungsfrage")
struct RatingQuestionTests {

    @Test("Erst ab dem dritten fertigen Titel")
    func firstOffThreshold() {
        #expect(!RatingQuestion.due(done: 2, lastAsked: nil, version: "1.0.3"))
        #expect(RatingQuestion.due(done: 3, lastAsked: nil, version: "1.0.3"))
    }

    @Test("Hoechstens einmal je Fassung")
    func inTimesJeVersion() {
        #expect(!RatingQuestion.due(done: 9, lastAsked: "1.0.3", version: "1.0.3"))
        #expect(RatingQuestion.due(done: 9, lastAsked: "1.0.2", version: "1.0.3"))
    }

    @Test("Neunzig Prozent gelten als fertig, der Abspann muss nicht mit")
    func ninetyPercent() {
        #expect(RatingQuestion.countsAsReady(position: 5_400, duration: 6_000))
        #expect(!RatingQuestion.countsAsReady(position: 3_000, duration: 6_000))
    }

    @Test("Ein kurzer Clip zaehlt nicht")
    func shortClip() {
        #expect(!RatingQuestion.countsAsReady(position: 45, duration: 45))
        #expect(!RatingQuestion.countsAsReady(position: 0, duration: 0))
    }
}
