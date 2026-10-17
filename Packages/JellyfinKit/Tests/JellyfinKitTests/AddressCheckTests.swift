import Foundation
import Testing
@testable import JellyfinKit

/// Wrong address, corrected and submitted again: the late answer of the
/// first check used to throw the user back from sign-in to the address
/// form.
@Suite struct AddressCheckTests {

    @Test func oldResponseBecomesDiscarded() {
        var state = CheckState()
        let alt = state.begin("gibtsnicht.example")
        let new = state.begin("tv.example.de")
        #expect(!state.applies(alt))
        #expect(state.applies(new))
        // The old answer arrives last and must not finish anything.
        let altActs = state.complete(alt)
        #expect(!altActs)
        #expect(state.ongoing == new)
        let newActs = state.complete(new)
        #expect(newActs)
        #expect(state.ongoing == nil)
    }

    @Test func changedAddressThrowsCheck() {
        var state = CheckState()
        let mark = state.begin("tv.example")
        state.discard()
        #expect(!state.applies(mark))
        let acts = state.complete(mark)
        #expect(!acts)
    }

    @Test func marksAreInUnambiguousAlsoSameAddress() {
        var state = CheckState()
        let first = state.begin("tv.example.de")
        let second = state.begin("tv.example.de")
        #expect(first != second)
        #expect(!state.applies(first))
    }

    @Test(arguments: [-1003, -1006, -1001, -999, -1009])
    func noFallBackNameDeadlineCancel(code: Int) {
        #expect(!AddressCheck.fallbackPaysOff(to: JellyfinError.network(code: code)))
        #expect(!AddressCheck.fallbackPaysOff(to: NSError(domain: NSURLErrorDomain, code: code)))
    }

    @Test func fallBackRejectedConnection() {
        #expect(AddressCheck.fallbackPaysOff(to: JellyfinError.network(code: -1004)))
        #expect(AddressCheck.fallbackPaysOff(to: JellyfinError.certificate(.notTrusted)))
        #expect(!AddressCheck.fallbackPaysOff(to: CancellationError()))
    }

    @Test func homeNetworkDoesNotWaitOutside() {
        let homeBase = AddressCheck.session(for: URL(string: "http://192.168.1.5:8096")!)
        let outside = AddressCheck.session(for: URL(string: "https://tv.example.de")!)
        #expect(homeBase !== outside)
        #expect(outside.configuration.timeoutIntervalForResource == AddressCheck.deadline)
        #if canImport(Darwin)
        #expect(homeBase.configuration.waitsForConnectivity)
        #expect(!outside.configuration.waitsForConnectivity)
        #endif
    }

    /// An unknown name resolves immediately on the outside, not after the timeout.
    @Test func unknownNameFailsImmediate() async throws {
        let c = JellyfinClient(baseURL: URL(string: "https://gibtsnicht-swiftly-pruefung.invalid")!,
                               deviceID: "test", deviceName: "test", clientVersion: "0")
        let beginning = Date()
        await #expect(throws: (any Error).self) { _ = try await c.checkReachability() }
        #expect(Date().timeIntervalSince(beginning) < 5)
    }
}
