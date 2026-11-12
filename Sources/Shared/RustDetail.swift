import Foundation
import JellyfinKit

#if canImport(SwiftlyCore)
import SwiftlyCore
#endif

/// One episode row as the core words it.
struct RustEpisodeLook: Equatable {
    let title: String
    let secondaryLine: String
    let image: URL?
    /// 0 to 1.
    let progress: Double?
    let watched: Bool
}
