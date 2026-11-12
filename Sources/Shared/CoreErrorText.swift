import Foundation
import JellyfinKit
import SwiftlyCore

/// The core owns the wording of network errors on Apple: `readableError` (JellyfinKit) asks it for every
/// `NSURLErrorDomain` code and certificate cause. The other cases (HTTP status, decoding, ...) stay in
/// JellyfinKit because the core exports no error-kind function.
enum CoreErrorText {
    static func install() {
        readableNetworkTextFromCore = { code, description in
            readableNetworkErrorSystem(locale: AppCore.language, code: Int32(truncatingIfNeeded: code), description: description)
        }
    }
}
