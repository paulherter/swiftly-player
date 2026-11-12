import Foundation
import SwiftUI
import Testing

@testable import SwiftlyCore

/// The combined Home order: the core's rule against SwiftUI's own `move(fromOffsets:toOffset:)`, which the
/// old two lists used.
@Suite struct HomeRowOrderTests {
    private let libs = [HomeLibraryChoice(id: "l1", name: "Filme", collection: false),
                        HomeLibraryChoice(id: "c1", name: "Marvel", collection: true)]

    @Test(arguments: [(IndexSet(integer: 0), 3), (IndexSet(integer: 3), 0), (IndexSet(integer: 1), 2),
                      (IndexSet(integer: 2), 5), (IndexSet(integer: 4), 1), (IndexSet(integer: 0), 0)])
    func movesLikeSwiftUI(_ source: IndexSet, _ destination: Int) {
        let list = ["a", "b", "c", "d", "e"]
        var expected = list
        expected.move(fromOffsets: source, toOffset: destination)
        #expect(HomeRowOrder.moved(list, from: source, to: destination) == expected)
    }

    @Test func librariesAndFixedRowsShareOneListAndHeal() {
        let order = HomeRowOrder.effective(stored: [], fallbackFixed: [], disconnected: false, libraries: libs)
        #expect(order.contains("library:l1") && order.contains("library:c1"))
        // Libraries come after the fixed rows by default, and every row appears once.
        #expect(Set(order).count == order.count)
        let moved = HomeRowOrder.moved(order, from: IndexSet(integer: order.count - 1), to: 0)
        #expect(moved.first == order.last)
        // A stored list with a deleted library and an unknown row heals.
        let healed = HomeRowOrder.effective(
            stored: ["library:gone", "library:c1", "nonsense"] , fallbackFixed: [], disconnected: false,
            libraries: [libs[1]])
        #expect(healed.first == "library:c1")
        #expect(!healed.contains("library:gone") && !healed.contains("nonsense"))
    }

    @Test func rowIdsRoundTrip() {
        #expect(HomeRowOrder.library(of: HomeRowOrder.libraryId("x")) == "x")
        #expect(HomeRowOrder.library(of: "continueWatching") == nil)
    }
}

@Suite struct HomeRowMoveTests {
    private func mode() -> HomeRowMoveMode {
        HomeRowMoveMode(order: ["a", "b", "x", "c", "d"], visible: ["a", "b", "c", "d"])
    }

    @Test func dropOntoTakesTheTargetsPlaceInBothDirections() {
        let list = ["a", "b", "c", "d"]
        #expect(HomeRowOrder.moved(list, row: "a", onto: "c") == ["b", "c", "a", "d"])
        #expect(HomeRowOrder.moved(list, row: "d", onto: "b") == ["a", "d", "b", "c"])
        #expect(HomeRowOrder.moved(list, row: "a", onto: "a") == list)
        #expect(HomeRowOrder.moved(list, row: "zz", onto: "a") == list)
    }

    @Test func moveByStopsAtTheEndsAndSkipsHiddenRows() {
        let order = ["a", "b", "x", "c"], visible = ["a", "b", "c"]
        #expect(HomeRowOrder.moved(order, row: "a", by: -1, among: visible) == order)
        #expect(HomeRowOrder.moved(order, row: "c", by: 1, among: visible) == order)
        #expect(HomeRowOrder.moved(order, row: "b", by: 1, among: visible) == ["a", "x", "c", "b"])
    }

    @Test func enterMoveCommit() {
        var m = mode()
        #expect(m.reduce(.enter(row: "b")) == nil)
        #expect(m.movingRow == "b")
        m.reduce(.down)
        #expect(m.order == ["a", "x", "c", "b", "d"])
        #expect(m.reduce(.commit) == ["a", "x", "c", "b", "d"])
        #expect(m.state == .idle)
    }

    @Test func cancelRestoresTheOrderOnEntry() {
        var m = mode()
        m.reduce(.enter(row: "d")); m.reduce(.up); m.reduce(.up)
        m.reduce(.cancel)
        #expect(m.order == ["a", "b", "x", "c", "d"])
        #expect(m.state == .idle)
    }

    @Test func illegalEventsChangeNothing() {
        var m = mode()
        for event in [HomeRowMoveMode.Event.up, .down, .commit, .cancel, .enter(row: "x")] {
            #expect(m.reduce(event) == nil)
            #expect(m.state == .idle)
            #expect(m.order == ["a", "b", "x", "c", "d"])
        }
        m.reduce(.enter(row: "a"))
        m.reduce(.enter(row: "c"))   // already moving: ignored
        #expect(m.movingRow == "a")
    }
}
