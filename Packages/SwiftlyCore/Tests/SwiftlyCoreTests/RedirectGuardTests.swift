import Foundation
import Testing

@testable import SwiftlyCore

/// `KeepPostRedirects` of the old Seerr sign-in session, now the host side of `NetRequest.keepMethod`.
@Suite("Redirect guard")
struct RedirectGuardTests {
    @Test func aMissingMethodCountsAsGet() {
        #expect(RedirectGuard.keepsMethod(original: nil, redirected: "GET"))
        #expect(RedirectGuard.keepsMethod(original: "post", redirected: "POST"))
    }

    @Test func aPostTurnedIntoAGetIsNotKept() {
        #expect(!RedirectGuard.keepsMethod(original: "POST", redirected: "GET"))
        #expect(!RedirectGuard.keepsMethod(original: "POST", redirected: nil))
    }
}
