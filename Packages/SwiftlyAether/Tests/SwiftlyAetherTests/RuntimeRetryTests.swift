import Testing
@testable import SwiftlyAether

@Suite struct RuntimeRetryTests {
    let zero = "Failed to load: HLSVideoEngine: source has zero duration (cannot build segment plan)"

    @Test func firstZeroDurationOfAFileIsRetried() {
        #expect(RuntimeRetry.isDue(isFileURL: true, storedRuntime: 1338, alreadyDeclared: false, reason: zero))
    }
    @Test func noSecondRetry() {
        #expect(!RuntimeRetry.isDue(isFileURL: true, storedRuntime: 1338, alreadyDeclared: true, reason: zero))
    }
    @Test func streamsAndMissingRuntimeAreNeverRetried() {
        #expect(!RuntimeRetry.isDue(isFileURL: false, storedRuntime: 1338, alreadyDeclared: false, reason: zero))
        #expect(!RuntimeRetry.isDue(isFileURL: true, storedRuntime: 0, alreadyDeclared: false, reason: zero))
    }
    @Test func otherErrorsAreNotRetried() {
        #expect(!RuntimeRetry.isDue(isFileURL: true, storedRuntime: 1338, alreadyDeclared: false, reason: "read failed"))
    }
}
