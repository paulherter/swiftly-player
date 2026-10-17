import Foundation
import Testing
@testable import JellyfinKit

/// While waiting for approval, the raw
/// `Error Domain=NSURLErrorDomain Code=-1001` was shown instead of the code. A network error while
/// polling must not end the wait; only the expired code does.
@Suite struct QuickConnectStateTests {

    @Test func expiredCodeEndedWait() {
        let state = QuickConnectState(error: QuickConnectExpired())
        #expect(state == .expired)
        #expect(state.endedWait)
    }

    @Test(arguments: [-1001, -1003, -1004, -1005, -1009])
    func networkErrorEndedWaitNot(code: Int) {
        let state = QuickConnectState(error: NSError(domain: NSURLErrorDomain, code: code))
        #expect(state == .failed)
        #expect(!state.endedWait)
    }

    @Test func sharingEndedWait() {
        #expect(QuickConnectState.released.endedWait)
        #expect(!QuickConnectState.opened.endedWait)
    }

    @Test func endTextDistinguishesNetworkAndDeadline() {
        #expect(QuickConnectDeadline.endText(last: .failed)
                != QuickConnectDeadline.endText(last: .expired))
        #expect(QuickConnectDeadline.endText(last: .opened)
                == QuickConnectDeadline.endText(last: .expired))
    }

    /// No raw `NSError` text, not even for codes without their own line.
    @Test(arguments: [-1001, -1003, -1004, -1005, -1009])
    func networkErrorBecomesReadable(code: Int) {
        let text = readableError(NSError(domain: NSURLErrorDomain, code: code))
        #expect(!text.contains("Error Domain"))
        #expect(!text.isEmpty)
    }
}
