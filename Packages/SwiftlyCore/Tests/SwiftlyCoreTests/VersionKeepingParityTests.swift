import Foundation
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **`MediaVersions.matching` (what `AppModel.plan(for:keeping:)` used) against `VersionKeeping.matching` (the
/// core's `matchingNextVersion`)** over names (equal, other case, padded, empty, missing), heights and lists
/// (none, one, many, entries without an id). `VersionKeeping.swift` is the app's file, linked into this target.
@Suite struct VersionKeepingParityTests {
    static func source(_ id: String?, _ name: String?, _ height: Int?) throws -> MediaSource {
        var parts: [String] = []
        if let id { parts.append(#""Id":"\#(id)""#) }
        if let name { parts.append(#""Name":"\#(name)""#) }
        if let height {
            parts.append(#""MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":\#(height * 16 / 9),"Height":\#(height)}]"#)
        }
        return try JSONDecoder().decode(MediaSource.self, from: Data("{\(parts.joined(separator: ","))}".utf8))
    }

    @Test func theGridKeepsTheSameVersion() throws {
        let names: [String?] = ["4K HDR", " 4k hdr ", "1080p", "", nil, "Director's Cut"]
        let heights: [Int?] = [2160, 1080, 720, nil]
        var checked = 0
        var different: [String] = []
        for previousName in names {
            for previousHeight in heights {
                let previous = try Self.source("p", previousName, previousHeight)
                var lists: [[MediaSource]] = [[]]
                lists.append([try Self.source("a", "4K HDR", 2160)])
                lists.append([try Self.source("a", "4K HDR", 2160), try Self.source("b", "1080p", 1080)])
                lists.append([try Self.source("a", "Cut", 1080), try Self.source("b", "1080P", 1080),
                              try Self.source("c", "4k hdr", 2160)])
                lists.append([try Self.source(nil, "4K HDR", 2160), try Self.source("b", "x", 720)])
                lists.append([try Self.source("a", nil, 720), try Self.source("b", "", 720), try Self.source("c", "  ", 1080)])
                lists.append([try Self.source("a", " 1080p ", nil), try Self.source("b", "1080p", 1080)])
                for list in lists {
                    let old = MediaVersions.matching(previous: previous, in: list)?.id
                    let new = VersionKeeping.matching(previous: previous, in: list)
                    checked += 1
                    if old != new, different.count < 10 {
                        different.append("previous \(previousName ?? "-")/\(previousHeight ?? 0) in \(list.map { $0.id ?? "-" }): old \(old ?? "nil") core \(new ?? "nil")")
                    }
                }
                // The list entry without `MediaSources` yet.
                #expect(MediaVersions.matching(previous: previous, in: nil)?.id == VersionKeeping.matching(previous: previous, in: nil))
            }
        }
        #expect(checked > 150)
        #expect(different.isEmpty, "\(different.joined(separator: "\n"))")
    }
}
