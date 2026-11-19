import Foundation
import Testing

/// A UI must never compare against a word the core does not send. `crates/swiftly-uniffi/data/core-words.json` lists every word the
/// core sends (written by the Rust test `core_words_contract`); the Rust UI shell's `EngineCommand` enum
/// (`Sources/RustUI/AVEngine.swift`) must list exactly the engine commands in it, and its dispatch must go through the enum.
@Suite struct CoreWordsContractTests {
    private static var root: URL {
        var url = URL(filePath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func coreWords(_ group: String) throws -> Set<String> {
        let data = try Data(contentsOf: Self.root.appending(path: "crates/swiftly-uniffi/data/core-words.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String]])
        return Set(try #require(object[group], "core-words.json has no group \(group)"))
    }

    private func engineSource() throws -> String {
        try String(contentsOf: Self.root.appending(path: "Sources/RustUI/AVEngine.swift"), encoding: .utf8)
    }

    /// The `case x` lines of `enum EngineCommand` (one case per line, raw value = name).
    private func engineCommandCases(_ source: String) throws -> Set<String> {
        let start = try #require(source.range(of: "enum EngineCommand: String, CaseIterable {"))
        let body = source[start.upperBound...].prefix { $0 != "}" }
        let names = body.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("case ") ? String(t.dropFirst(5)) : nil
        }
        return Set(names)
    }

    @Test func theShellListsExactlyTheCommandsTheCoreSends() throws {
        let sent = try coreWords("engine.command")
        let handled = try engineCommandCases(try engineSource())
        #expect(!handled.isEmpty)
        #expect(handled.subtracting(sent).isEmpty, "AVEngine handles commands the core never sends: \(handled.subtracting(sent).sorted())")
        #expect(sent.subtracting(handled).isEmpty, "the core sends commands AVEngine does not know: \(sent.subtracting(handled).sorted())")
    }

    @Test func theDispatchGoesThroughTheEnumNotThroughLiterals() throws {
        let source = try engineSource()
        let from = try #require(source.range(of: "func apply(_ lines: String)"))
        let to = try #require(source.range(of: "private func load(", range: from.upperBound..<source.endIndex))
        let apply = source[from.upperBound..<to.lowerBound]
        #expect(!apply.contains("case \""), "apply() compares against a string literal instead of EngineCommand")
        #expect(!apply.contains("default:"), "apply() has a default branch: an unwired command would be dropped silently")
    }
}
