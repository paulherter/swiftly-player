import Foundation

struct OracleError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

/// One differential domain: a pure function from a JSON case to a JSON result.
struct Domain {
    let name: String
    let work: (Any) throws -> Any

    init(_ name: String, _ work: @escaping (Any) throws -> Any) {
        self.name = name
        self.work = work
    }

    func run(in dir: URL) throws {
        let input = dir.appendingPathComponent("\(name).in.json")
        let data = try Data(contentsOf: input)
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = doc["cases"] as? [Any] else { throw OracleError("bad input file \(input.path)") }
        var results: [Any] = []
        results.reserveCapacity(cases.count)
        for c in cases { results.append(try work(c)) }
        let out: [String: Any] = ["domain": name, "results": results]
        let bytes = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
        try bytes.write(to: dir.appendingPathComponent("\(name).swift.json"))
    }
}

func nsnull(_ x: Any?) -> Any { x ?? NSNull() }
