import AppKit
import XCTest
@testable import FocusKit

/// The focus mark is quiet at launch and appears only after Tab; hidden views are not reachable.
/// Run with `Werkzeuge/focus-ring-test.sh`.
@MainActor
final class KeyboardFocusTests: XCTestCase {
    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                         keyCode: code)!
    }
    private func click() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testInitialStateIsQuiet() {
        XCTAssertEqual(KeyboardFocusMonitor().state, .quiet)
        XCTAssertFalse(KeyboardFocus.quiet.showsMark)
    }

    func testTabShowsMarkAndClickHidesIt() {
        let monitor = KeyboardFocusMonitor()
        monitor.handle(key(48))   // Tab
        XCTAssertEqual(monitor.state, .keyboard)
        XCTAssertTrue(monitor.state.showsMark)
        monitor.handle(click())
        XCTAssertEqual(monitor.state, .quiet)
    }

    func testTypingDoesNotShowMark() {
        let monitor = KeyboardFocusMonitor()
        monitor.handle(key(0))    // "a"
        XCTAssertEqual(monitor.state, .quiet)
        monitor.handle(key(125))  // down arrow
        XCTAssertEqual(monitor.state, .keyboard)
        monitor.handle(key(0))    // typing keeps the state
        XCTAssertEqual(monitor.state, .keyboard)
    }

    func testTransitionTable() {
        let table: [(KeyboardFocus, KeyboardFocus.Event, KeyboardFocus)] = [
            (.quiet, .navigationKey, .keyboard), (.quiet, .otherKey, .quiet), (.quiet, .pointerDown, .quiet),
            (.keyboard, .navigationKey, .keyboard), (.keyboard, .otherKey, .keyboard), (.keyboard, .pointerDown, .quiet),
        ]
        for (from, event, to) in table {
            XCTAssertEqual(KeyboardFocus.reduce(from, event), to, "\(from) + \(event)")
        }
    }

    func testHiddenViewsAreNotReachable() {
        XCTAssertTrue(KeyboardFocus.isReachable(playerOpen: false, curtainShown: false))
        XCTAssertFalse(KeyboardFocus.isReachable(playerOpen: true, curtainShown: false))
        XCTAssertFalse(KeyboardFocus.isReachable(playerOpen: false, curtainShown: true))
        XCTAssertFalse(KeyboardFocus.isReachable(playerOpen: true, curtainShown: true))
    }
}
