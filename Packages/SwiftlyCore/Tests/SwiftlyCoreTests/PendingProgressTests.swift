import Foundation
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// The host merge of "offline playback the server has not seen" into the unsent-stops store: the core's
/// record rule (`legacyPendingReportRecord`) must give what the Swift `PostReportRules.record` gave, and
/// the store must stay readable by the Swift `PendingReport`.
@Suite struct PendingProgressTests {
    private func entry(_ id: String, _ account: String, _ ticks: Int64, _ at: TimeInterval) -> PendingReport {
        PendingReport(itemID: id, account: account, ticks: ticks, moment: Date(timeIntervalSince1970: at))
    }

    private func json(_ list: [PendingReport]) -> String {
        String(decoding: try! JSONEncoder().encode(list), as: UTF8.self)
    }

    private func read(_ data: Data?) -> [PendingReport] {
        (try? JSONDecoder().decode([PendingReport].self, from: data ?? Data())) ?? []
    }

    @Test func emptyOrBrokenInputLeavesTheStore() {
        #expect(PendingProgress.merged(unreportedJson: "[]", into: nil) == nil)
        #expect(PendingProgress.merged(unreportedJson: "nonsense", into: nil) == nil)
    }

    @Test func matchesTheSwiftRecordRule() throws {
        let stored = [entry("a", "u1", 100, 1_000), entry("b", "u2", 50, 2_000)]
        let incoming = [entry("a", "u1", 900, 3_000),   // newer: wins
                        entry("b", "u2", 10, 1_000),    // older: loses
                        entry("b", "u1", 70, 2_500)]    // other account: separate
        let core = read(PendingProgress.merged(unreportedJson: json(incoming),
                                                into: json(stored).data(using: .utf8)))
        let swift = incoming.reduce(stored) { PostReportRules.record($1, in: $0) }
        #expect(Set(core.map(\.id)) == Set(swift.map(\.id)))
        for s in swift {
            let c = try #require(core.first { $0.id == s.id })
            #expect(c.ticks == s.ticks)
            #expect(abs(c.moment.timeIntervalSince(s.moment)) < 0.001)
        }
    }

    @Test func startsFromAnEmptyStore() {
        let core = read(PendingProgress.merged(unreportedJson: json([entry("a", "u1", 5, 10)]), into: nil))
        #expect(core.count == 1)
        #expect(core.first?.ticks == 5)
    }
}
