import AetherEngine
import Foundation
import SwiftlyCore
import Testing

/// **Columns "ready", "duration", "frame", "seek", "end"**: the core's plan opens the title, the core's player state machine
/// drives the real engine, and the bench checks what a viewer would notice.
@Suite(.serialized) @MainActor struct PlayTests {
    @Test(arguments: benchTitles)
    func playsSeeksAndEnds(_ id: String) async throws {
        let opened = try await Opened(id: id)
        defer { opened.close() }
        var problems: [String] = []
        func check(_ column: String, _ ok: Bool, _ detail: String = "") {
            Record.note(id, column, ok, ok ? detail : detail)
            if !ok { problems.append("\(column): \(detail)") }
        }
        // Ready: the engine is playing and shows a picture.
        let ready = await opened.playing(within: 25)
        check("ready", ready != nil, ready.map { String(format: "%.1f s", $0) } ?? "no playing state/first frame within 25 s: \(opened.port.failure ?? "-") \(opened.port.state)")
        guard ready != nil else { #expect(Bool(false), "\(problems)"); return }
        // Duration: right to about half a second, also for a file without a header duration.
        _ = await until(6) { opened.port.duration > 0 && opened.model.transport.duration > 0 }
        let duration = opened.port.duration
        let shown = opened.model.transport.duration
        check("duration", abs(duration - 10) < 0.7 && abs(shown - 10) < 0.7, String(format: "engine %.2f s, core transport %.2f s", duration, shown))
        // Time advances.
        check("frame", await opened.advances(), "position \(String(format: "%.1f", opened.port.position)) s, av \(opened.port.avStatus ?? "engine")")
        // Seek: the core's seek intent lands near the target and the clock goes on.
        opened.model.send(.seekTo(seconds: 6))
        let landed = await until(8) { abs(opened.port.position - 6) < 1.2 || opened.port.position > 6 }
        let moving = await opened.advances(by: 0.5)
        check("seek", landed != nil && moving, "after seek to 6 s: \(String(format: "%.1f", opened.port.position)) s")
        // End of file: jump to the last second, the engine reaches the end and the core says so.
        opened.model.send(.seekTo(seconds: 9))
        let ended = await until(15) { opened.port.ended }
        check("end", ended != nil, "state \(opened.port.state), position \(String(format: "%.1f", opened.port.position)) s")
        #expect(problems.isEmpty, "\(problems)")
    }
}
