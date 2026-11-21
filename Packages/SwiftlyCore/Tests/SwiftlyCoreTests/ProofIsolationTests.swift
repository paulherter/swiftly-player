import XCTest
@testable import SwiftlyCore

/// A proof or fixture launch must never use the real app's Keychain service; a release build never switches.
final class ProofIsolationTests: XCTestCase {
    func testFixtureAndProofRunsGetTheirOwnService() {
        for args in [["Swiftly", "-SwiftlyFixture", "http://127.0.0.1:1"], ["Swiftly", "-SwiftlyProofShot", "/x.png"],
                     ["Swiftly", "-SwiftlyOpenPage", "serie"], ["Swiftly", "-SwiftlyLiveMemory"], ["Swiftly", "-testsitzung", "u"]] {
            XCTAssertEqual(ProofIsolation.service(arguments: args, debugBuild: true), ProofIsolation.proofKeychainService, "\(args)")
        }
    }

    func testAnOrdinaryLaunchKeepsTheRealService() {
        XCTAssertEqual(ProofIsolation.service(arguments: ["Swiftly", "-ApplePersistenceIgnoreState", "YES"], debugBuild: true),
                       ProofIsolation.realKeychainService)
        XCTAssertEqual(ProofIsolation.service(arguments: ["Swiftly"], debugBuild: true), "de.paulherter.swiftly")
    }

    func testAReleaseBuildNeverSwitches() {
        XCTAssertEqual(ProofIsolation.service(arguments: ["Swiftly", "-SwiftlyFixture", "http://127.0.0.1:1"], debugBuild: false),
                       ProofIsolation.realKeychainService)
    }
}
