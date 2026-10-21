import Testing
@testable import JellyfinKit

@Suite("Remote control line fallback")
struct RemoteLineFallbackTests {
    @Test("Plain network trouble does not blame the libcurl line")
    func networkIsNotTheLine() {
        for code: Int32 in [5, 6, 7, 28, 52, 55, 56] {
            #expect(!LineSetupFailed.blamesLine(code: code))
        }
    }

    @Test("Certificate, TLS and handshake errors blame the line")
    func otherCodesBlameTheLine() {
        for code: Int32 in [35, 58, 60, 61, 77, 22, 8] {
            #expect(LineSetupFailed.blamesLine(code: code))
        }
    }

    @Test("The limit is finite")
    func limit() {
        #expect(RemoteControl.lineSetupLimit >= 2 && RemoteControl.lineSetupLimit <= 5)
    }
}
