import Testing
@testable import JellyfinKit

@Suite("Fortsetzstelle")
struct ResumePointTests {

    @Test func underMinuteFromFront() {
        #expect(ResumePoint.since(position: 30, runtime: 3600) == nil)
        #expect(ResumePoint.since(position: 60, runtime: 3600) == nil)
        #expect(ResumePoint.since(position: 61, runtime: 3600) == 61)
    }

    /// The case: episode played through, the end remembered.
    @Test func atEndFromFront() {
        #expect(ResumePoint.since(position: 3707, runtime: 3707) == nil)
        #expect(ResumePoint.since(position: 3660, runtime: 3707) == nil)
        #expect(ResumePoint.since(position: 3646, runtime: 3707) == 3646)
    }

    /// Beyond the runtime, which happens when server and file
    /// disagree. That too means "from the start", not "somewhere".
    @Test func overRuntimeToOut() {
        #expect(ResumePoint.since(position: 4000, runtime: 3707) == nil)
    }

    /// Without a runtime only the lower bound remains. Guessing would be worse.
    @Test func withoutRuntimeOnlyUnderLimit() {
        #expect(ResumePoint.since(position: 3707, runtime: nil) == 3707)
        #expect(ResumePoint.since(position: 30, runtime: nil) == nil)
        #expect(ResumePoint.since(position: 3707, runtime: 0) == 3707)
    }

    @Test func withoutPositionNot() {
        #expect(ResumePoint.since(position: nil, runtime: 3600) == nil)
    }
}
