import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import JellyfinKit

/// Two error-text rules, and `send` used to turn the network error into
/// text. The statement is checked, not the wording (the tests run in
/// the language of the machine).
@Suite struct ErrorKindTests {

    @Test(arguments: [-1001, -1003, -1004, -1005, -1009])
    func networkErrorKeepsItsCode(code: Int) {
        let j = JellyfinError(petition: NSError(domain: NSURLErrorDomain, code: code))
        #expect(j == .network(code: code))
        #expect(j.urlErrorCode?.rawValue == code)
    }

    @Test func foreignErrorStaysTransport() {
        struct Own: Error {}
        if case .transport = JellyfinError(petition: Own()) {} else {
            Issue.record("kein transport")
        }
    }

    /// The same sentence whether the code arrives raw or is wrapped in the package error.
    @Test(arguments: [-1001, -1003, -1004, -1005, -1009])
    func networkErrorSameRead(code: Int) {
        let raw = readableError(NSError(domain: NSURLErrorDomain, code: code))
        #expect(readableError(JellyfinError.network(code: code)) == raw)
    }

    @Test func timeoutAndNoServerDiffer() {
        #expect(readableError(JellyfinError.network(code: URLError.Code.timedOut.rawValue))
                != readableError(JellyfinError.network(code: URLError.Code.cannotFindHost.rawValue)))
    }

    /// One rule: `localizedDescription` shows the same as `readableError`.
    @Test(arguments: [
        JellyfinError.network(code: -1001), .http(status: 401, body: nil), .http(status: 502, body: "x"),
        .decoding("keyNotFound(CodingKeys(stringValue: \"Id\"))"), .invalidServerURL,
        .notAuthenticated, .noPlayableSource, .transport("Eigener Satz."),
    ])
    func aRule(error: JellyfinError) {
        #expect(error.localizedDescription == readableError(error))
    }

    @Test func decoderTextReachedUserNot() {
        let text = readableError(JellyfinError.decoding("keyNotFound(CodingKeys(stringValue: \"Id\"))"))
        #expect(!text.contains("keyNotFound"))
        #expect(!text.isEmpty)
    }

    // MARK: Certificate

    /// **The bug that started this case.** On Android,
    /// `self-signed.badssl.com` arrived as `NSURLErrorDomain` code `-1`, and the
    /// app said "The connection to the server was aborted", though the connection
    /// was never made. The statement is checked: the sentence must not be the same
    /// as the one for a really aborted connection (`-1005`).
    @Test(arguments: [
        "SSL certificate problem: self signed certificate",
        "SSL certificate problem: certificate has expired",
        "SSL: no alternative certificate subject name matches target hostname 'x.de'",
        "SSL certificate problem: self signed certificate in certificate chain",
    ])
    func curlTLSErrorIsNotCancelled(text: String) {
        let error = NSError(domain: NSURLErrorDomain, code: -1,
                             userInfo: [NSLocalizedDescriptionKey: text])
        let cancelled = readableError(JellyfinError.network(code: URLError.Code.networkConnectionLost.rawValue))
        #expect(readableError(error) != cancelled)
        if case .certificate = JellyfinError(petition: error) {} else {
            Issue.record("kein Zertifikatsfall für \(text)")
        }
    }

    /// curl's English sentence does not reach the user.
    @Test func curlSentenceReachedUserNot() {
        let error = NSError(domain: NSURLErrorDomain, code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "SSL certificate problem: self signed certificate"])
        #expect(!readableError(error).contains("SSL"))
    }

    /// Every cause has its own sentence: four reasons, four statements.
    @Test func eachReasonSaysSomethingOther() {
        let sentences = CertificateReason.allCases.map { readableError(JellyfinError.certificate($0)) }
        #expect(Set(sentences).count == CertificateReason.allCases.count)
        #expect(!sentences.contains { $0.isEmpty })
    }

    /// From curl's sentence (the platforms without their own codes) ...
    @Test(arguments: [
        ("SSL certificate problem: self signed certificate", CertificateReason.notTrusted),
        ("SSL certificate problem: self signed certificate in certificate chain", .notTrusted),
        ("SSL certificate problem: unable to get local issuer certificate", .notTrusted),
        ("SSL certificate problem: certificate has expired", .expired),
        ("SSL certificate problem: certificate is not yet valid", .appliesNotYet),
        ("SSL: no alternative certificate subject name matches target hostname 'x.de'", .otherAddress),
        ("SSL connect error", .otherwise),
    ])
    func reasonOutSentence(text: String, expects: CertificateReason) {
        #expect(certificateReason(code: -1, text: text) == expects)
    }

    /// ... and from the code (Apple).
    @Test(arguments: [
        (URLError.Code.serverCertificateUntrusted, CertificateReason.notTrusted),
        (.serverCertificateHasUnknownRoot, .notTrusted),
        (.serverCertificateHasBadDate, .expired),
        (.serverCertificateNotYetValid, .appliesNotYet),
        (.secureConnectionFailed, .otherwise),
    ])
    func reasonOutCode(code: URLError.Code, expects: CertificateReason) {
        #expect(certificateReason(code: code.rawValue, text: "") == expects)
    }

    /// What does not talk about TLS is not turned into TLS either.
    @Test(arguments: [-1001, -1003, -1004, -1005, -1009])
    func networkErrorStaysNetworkError(code: Int) {
        #expect(certificateReason(code: code, text: "The request timed out.") == nil)
        #expect(JellyfinError(petition: NSError(domain: NSURLErrorDomain, code: code)) == .network(code: code))
    }

    /// **The unknown rest claims no cause.** If a code remains
    /// with no case for it, the sentence must not be the one for an
    /// aborted connection, or something wrong is shown again.
    @Test func unknownCodeClaimsNot() {
        let cancelled = readableError(JellyfinError.network(code: URLError.Code.networkConnectionLost.rawValue))
        #expect(readableError(JellyfinError.network(code: -1)) != cancelled)
        #expect(readableError(JellyfinError.network(code: -9999)) != cancelled)
    }

    @Test func responseBodyReachedUserNot() {
        let text = readableError(JellyfinError.http(status: 500, body: "Stapel geheim"))
        #expect(!text.contains("geheim"))
    }
}

/// One wait loop for all. Short times instead of five minutes.
@Suite struct QuickConnectWaitTests {

    actor Respond {
        var episode: [QuickConnectState]
        var asked = 0
        init(_ episode: [QuickConnectState]) { self.episode = episode }
        func next() -> QuickConnectState {
            asked += 1
            return episode.isEmpty ? .opened : episode.removeFirst()
        }
    }

    static func end(_ feed: AsyncStream<QuickConnectWait.AppEvent>) async -> QuickConnectWait.AppEvent? {
        var lastItem: QuickConnectWait.AppEvent?
        for await e in feed { if case .rest = e { continue }; lastItem = e }
        return lastItem
    }

    @Test func networkErrorEndedWaitNot() async {
        let a = Respond([.failed, .failed, .opened, .released])
        let feed = QuickConnectWait.flow(deadline: .seconds(5), pollInterval: .milliseconds(20),
                                              tick: .milliseconds(10)) { await a.next() }
        #expect(await Self.end(feed) == .released)
        #expect(await a.asked == 4)
    }

    @Test func expiredCodeEndsImmediate() async {
        let a = Respond([.expired, .released])
        let feed = QuickConnectWait.flow(deadline: .seconds(5), pollInterval: .milliseconds(20),
                                              tick: .milliseconds(10)) { await a.next() }
        #expect(await Self.end(feed) == .end(last: .expired))
        #expect(await a.asked == 1)
    }

    /// If the last poll failed, the end says "network", not "expired".
    @Test func deadlineEndPostNetworkError() async {
        let feed = QuickConnectWait.flow(deadline: .milliseconds(120), pollInterval: .milliseconds(20),
                                              tick: .milliseconds(10)) { .failed }
        #expect(await Self.end(feed) == .end(last: .failed))
    }

    @Test func deadlineEndWithoutSharing() async {
        let feed = QuickConnectWait.flow(deadline: .milliseconds(120), pollInterval: .milliseconds(20),
                                              tick: .milliseconds(10)) { .opened }
        #expect(await Self.end(feed) == .end(last: .expired))
    }

    /// The deadline runs on the clock: a poll that hangs longer than the
    /// deadline (app in the background) counts the missed time too.
    @Test func deadlineRunsAnClock() async {
        let feed = QuickConnectWait.flow(deadline: .milliseconds(100), pollInterval: .milliseconds(10),
                                              tick: .milliseconds(10)) {
            try? await Task.sleep(for: .milliseconds(150))
            return .failed
        }
        let beginning = ContinuousClock.now
        #expect(await Self.end(feed) == .end(last: .failed))
        #expect(ContinuousClock.now - beginning < .milliseconds(400))
    }

    @Test func remainingCountsFromUnder() async {
        var leftovers: [Int] = []
        let feed = QuickConnectWait.flow(deadline: .seconds(3), pollInterval: .seconds(10),
                                              tick: .seconds(1)) { .opened }
        for await e in feed { if case let .rest(r) = e { leftovers.append(r) } }
        #expect(leftovers == [3, 2, 1])
    }

    /// Whoever stops reading stops polling.
    @Test func cancelEndedAskAgain() async throws {
        let a = Respond([])
        let read = Task {
            for await _ in QuickConnectWait.flow(deadline: .seconds(30), pollInterval: .milliseconds(10),
                                                     tick: .milliseconds(10)) { await a.next() } {}
        }
        // A loaded CI runner may start the task late: wait for the first
        // request instead of a fixed time.
        for _ in 0..<500 where await a.asked == 0 { try await Task.sleep(for: .milliseconds(10)) }
        read.cancel()
        try await Task.sleep(for: .milliseconds(30))
        let afterThat = await a.asked
        try await Task.sleep(for: .milliseconds(100))
        #expect(await a.asked == afterThat)
        #expect(afterThat > 0)
    }

    @Test func remainingSecondsRoundUp() {
        #expect(QuickConnectWait.remainingSecondsOf(.milliseconds(1)) == 1)
        #expect(QuickConnectWait.remainingSecondsOf(.seconds(2)) == 2)
        #expect(QuickConnectWait.remainingSecondsOf(.zero) == 0)
        #expect(QuickConnectWait.remainingSecondsOf(.milliseconds(-5)) == 0)
    }
}

// MARK: - Two-factor

/// **401 with a token is not a wrong password.** Two-factor plugins such as
/// JellyfinSecurity put the valid token in the body and wait for
/// confirmation; without this distinction the app showed "Username or
/// password is wrong".
@Test func twoFactorBecomesDetected() {
    let shell = #"{"User":{"Name":"paul"},"AccessToken":"abc123","ServerId":"x"}"#
    #expect(JellyfinError.loginError(status: 401, shell: shell) == .twoFactor)
    #expect(JellyfinError.loginError(status: 401, shell: nil) == .http(status: 401, body: nil))
    #expect(JellyfinError.loginError(status: 401, shell: "Error processing request.")
            == .http(status: 401, body: "Error processing request."))
    #expect(JellyfinError.loginError(status: 500, shell: shell) == .http(status: 500, body: shell))
    #expect(readableError(JellyfinError.twoFactor).contains("Zwei-Faktor")
            || readableError(JellyfinError.twoFactor).contains("two-factor"))
}
