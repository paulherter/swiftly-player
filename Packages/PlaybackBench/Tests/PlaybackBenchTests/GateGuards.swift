import Foundation
import Testing

/// apple-feature-gate: structural guards over the Apple screens' sources, for lines that only a screen can break and that no
/// headless host can draw (the SwiftUI screens need a device). Same idea as `PlayerScreenStartGuard`: a regression here turns the
/// test red; a person still checks the look.
struct GateGuards {
    private static var root: URL { BenchServer.root }

    private static func swiftFiles(_ dirs: [String]) -> [URL] {
        var out: [URL] = []
        for dir in dirs {
            let base = root.appending(path: "Sources/\(dir)")
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }

    /// Line 12 (#33/#22): every place a person presses "play" on a title that may have two versions passes `ask:` (so it asks
    /// before starting). Trailers, extras and the start after a pick (`sourceID:` / `picking:`) are the only calls without it.
    @Test func everyPlayTapAsksForTheVersion() throws {
        var offenders: [String] = []
        var found = 0
        for url in Self.swiftFiles(["Shared", "iOS", "tvOS"]) {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("PlayRequest.start(") {
                found += 1
                let window = lines[i..<min(i + 5, lines.count)].joined(separator: " ")
                let isTrailer = line.contains("Item(id: id, name: current.name)")
                let isExtra = line.contains("(extra") || window.contains("extra,")
                if window.contains("ask:") || window.contains("sourceID:") || window.contains("picking:") || isTrailer || isExtra { continue }
                offenders.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        #expect(found > 15, "found only \(found) start sites: the guard lost its target")
        #expect(offenders.isEmpty, "a play tap that never asks which version: \(offenders)")
    }

    /// Every screen that can ask hangs the dialog (`.versionChoice` / `.versionPick`) onto its view, else the ask is silent.
    @Test(arguments: ["Shared/HomeView.swift", "Shared/PlaylistPage.swift", "Shared/SeriesView.swift", "Shared/BrowseViews.swift",
                      "macOS/MainView.swift", "macOS/DetailView.swift", "macOS/SeriesView.swift", "tvOS/MainView.swift"])
    func theAskingScreenShowsTheDialog(_ file: String) throws {
        let text = try String(contentsOf: Self.root.appending(path: "Sources/\(file)"), encoding: .utf8)
        #expect(text.contains(".versionChoice(") || text.contains(".versionPick("), "\(file) cannot show \"Fassung wählen\"")
    }

    /// Lines 10/11 (Mac series page without a description, today): the description is drawn on film and series pages of every
    /// platform and nobody switches it off again.
    @Test func filmAndSeriesPagesDrawTheirDescription() throws {
        let text = { (file: String) throws -> String in
            try String(contentsOf: Self.root.appending(path: "Sources/\(file)"), encoding: .utf8)
        }
        // macOS: the shared hero shows the overview unless a caller passes `showsOverview: false`.
        let macDetail = try text("macOS/DetailView.swift")
        #expect(macDetail.contains("var showsOverview: Bool = true"))
        for url in Self.swiftFiles(["macOS"]) {
            let body = try String(contentsOf: url, encoding: .utf8)
            #expect(!body.contains("showsOverview: false"), "\(url.lastPathComponent) switches the description off")
        }
        // iOS/iPadOS: movie page from the hero part, series page from the series button part.
        #expect(try text("Shared/BrowseViews.swift").contains("hero?.overview"))
        #expect(try text("Shared/SeriesView.swift").contains("button?.overview"))
        // tvOS: the header draws the fresh item's cleaned description; the series page hands over the core's fresh item.
        #expect(try text("tvOS/TVComponents.swift").contains("item.description"))
        #expect(try text("tvOS/SeriesView.swift").contains("page?.item ?? series"))
    }
}
