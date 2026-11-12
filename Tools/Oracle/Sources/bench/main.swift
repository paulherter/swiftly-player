import Foundation
import JellyfinKit

// Swift side of the Rust-vs-Swift benchmarks. Prints one JSON line per
// operation with the same keys as the Rust `perf` bin: {"op","input","ms","runs"}. 2 warm-up runs, median of 7.
//
//  json_decode_10k   JSONDecoder().decode(ItemsResponse.self, from: bytes)          (Rust: serde_json -> swiftly_model::server::ItemsResponse)
//  page_assembly_10k TitleFilter(identifiers: items) + seven(page) over 167 pages of 60  (Rust: TitleFilter::from_identifiers + sift)
//  natural_sort_10k  NaturalOrder.sorted(indices, locale: de) over the item names    (Rust: NaturalOrder::sorted + NaturalCollator("de"))
//  image_key_100k    ImageAddress.construct(...) then ImageStoreKey.of(url), 100000 calls (Rust: ImageAddress::construct + store_key)
//  device_profile_build: DeviceProfile.vlc/airplay are internal in JellyfinKit -> skipped here (Rust-only number).
//  core_startup: no Swift core object -> skipped.

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "../../crates/swiftly-hardening/oracle/perf_library_10k.json"
guard let data = FileManager.default.contents(atPath: path) else { fatalError("missing \(path)") }

nonisolated(unsafe) var sink = 0

func median(_ body: () -> Int) -> (Double, Int) {
    for _ in 0..<2 { sink &+= body() }
    var times: [Double] = []
    for _ in 0..<7 {
        let t0 = ContinuousClock.now
        sink &+= body()
        let d = ContinuousClock.now - t0
        times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }
    times.sort()
    return (times[times.count / 2], times.count)
}

func emit(_ op: String, _ input: String, _ r: (Double, Int)) {
    print("{\"op\":\"\(op)\",\"input\":\"\(input)\",\"ms\":\(String(format: "%.4f", r.0)),\"runs\":\(r.1)}")
}

let decoder = JSONDecoder()
let items = try decoder.decode(ItemsResponse.self, from: data).items
emit("json_decode_10k", "10000 items, \(data.count) bytes", median {
    (try? decoder.decode(ItemsResponse.self, from: data).items.count) ?? 0
})

emit("page_assembly_10k", "10000 items, 167 pages of 60", median {
    var filter = TitleFilter(identifiers: items)
    var kept = 0
    var i = 0
    while i < items.count {
        kept += filter.seven(Array(items[i..<min(i + 60, items.count)])).count
        i += 60
    }
    return kept
})

let names = items.map { $0.name }
let de = Locale(identifier: "de")
emit("natural_sort_10k", "10000 titles, locale de", median {
    NaturalOrder.sorted(Array(names.indices), locale: de) { (name: names[$0], sortName: nil as String?) }.count
})

let address = ImageAddress(base: URL(string: "http://127.0.0.1:8096")!, token: "t", kind: .jellyfin)
emit("image_key_100k", "100000 construct + store key", median {
    var n = 0
    for i in 0..<100_000 {
        if let url = address.construct(itemID: "m\(i % 5000)", art: .poster, mark: "p\(i % 5000)", mass: .atMostHigh(300)) {
            n &+= ImageStoreKey.of(url)?.utf8.count ?? 0
        }
    }
    return n
})

// search_history_10k: SearchHistory.remember over 10000 words (list-keeping logic behind the search screen).
emit("search_history_10k", "10000 remember calls", median {
    var raw = ""
    for i in 0..<10_000 { raw = SearchHistory.remember("wort\(i % 37) \(i)", in: raw) }
    return raw.utf8.count
})
