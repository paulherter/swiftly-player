import Foundation
import Testing
@testable import JellyfinKit

@Suite("Übergabe als Karte (Entwurf B)")
struct HandoffCardTests {
    typealias K = HandoffCard
    let screen = (b: 390.0, h: 844.0)
    var full: K.Status { K.fullscreen(width: screen.b, height: screen.h) }
    var idle: K.Status { K.idleStatus(width: screen.b, height: screen.h, metrics: K.iPhone) }
    let emblem = K.Status(x: 350, y: 70, width: 44)

    @Test("Hochkant ist das ganze Bild schirmbreit, quer und am Fernseher 16:9 eingepasst")
    func fullscreen() {
        #expect(full.width == 390)
        #expect(abs(full.height - 219.375) < 0.001)
        #expect(abs(K.fullscreen(width: 844, height: 390).width - 390.0 * 16 / 9) < 1e-9)
        #expect(K.fullscreen(width: 1920, height: 1080).width == 1920)
    }

    @Test("Die Karte ruht mittig, über der Mitte, mit Platz für zwei Zeilen")
    func idleStatus() {
        #expect(idle.x == 195)
        #expect(idle.width == 240)
        #expect(idle.y < 422)
        let bottom = K.rowsTop(idle, metrics: K.iPhone) + 17 * 1.2 + 13 * 1.2
        // Card and rows together roughly centered.
        let top = idle.y - idle.height / 2
        #expect(abs((top + bottom) / 2 - 422) < 8)
        // Narrow screens: at most 70 % of the width.
        #expect(K.idleStatus(width: 300, height: 600, metrics: K.iPhone).width == 210)
    }

    @Test("Die Karte startet am Abzeichen und steht nach gut einer Sekunde in Ruhe")
    func transition() {
        #expect(K.transition(0, from: emblem, to: idle) == emblem)
        #expect(K.transition(K.cardsStart, from: emblem, to: idle) == emblem)
        let late = K.transition(1.4, from: emblem, to: idle)
        #expect(abs(late.x - idle.x) < 0.5)
        #expect(abs(late.y - idle.y) < 0.5)
        #expect(abs(late.width - idle.width) < 0.5)
        // Straight path: no arc, only a small settle (damping 0.86).
        var widest = 0.0
        for i in 0 ... 300 {
            let l = K.transition(Double(i) / 200, from: emblem, to: idle)
            widest = max(widest, l.y - idle.y)
        }
        #expect(widest < (idle.y - emblem.y) * 0.03)
    }

    @Test("Schweben erst ab kurz vor 0,7 s, höchstens 1,8 Punkt")
    func float() {
        #expect(K.hoverOffset(0.5) == 0)
        #expect(K.hoverOffset(K.float - 0.15) == 0)
        for i in 0 ... 400 {
            #expect(abs(K.hoverOffset(0.5 + Double(i) / 100)) <= K.hoverTravel + 1e-9)
        }
    }

    @Test("Frühestens bei 0,7 s wird gezoomt, sonst beim ersten Bild")
    func zoomStart() {
        #expect(K.zoomStart(ready: 0.3) == 0.7)
        #expect(K.zoomStart(ready: 1.9) == 1.9)
    }

    @Test("Der Zoom endet auf dem ganzen Bild, federt höchstens 3 % über")
    func zoom() {
        let start = K.wait(1.2, from: emblem, to: idle)
        let v = K.momentum(1.2, from: emblem, to: idle)
        #expect(K.zoom(0, from: start, momentum: v, to: full) == start)
        let fade = K.zoom(K.cardsOutFrom, from: start, momentum: v, to: full)
        #expect(fade.width > full.width * 0.9)
        let calm = K.zoom(1.5, from: start, momentum: v, to: full)
        #expect(abs(calm.width - full.width) < 0.5)
        for i in 0 ... 150 {
            #expect(K.zoom(Double(i) / 100, from: start, momentum: v, to: full).width <= full.width * 1.03)
        }
    }

    @Test("Drehung unterwegs: die Karte fliegt von ihrer Lage neu in die Querlage")
    func newAlign() {
        let landscape = K.idleStatus(width: 844, height: 390, metrics: K.iPhone)
        let now = K.transition(0.5, from: emblem, to: idle)
        #expect(K.transition(0.5, from: now, to: landscape, since: 0.5) == now)
        let late = K.transition(2.0, from: now, to: landscape, since: 0.5)
        #expect(abs(late.x - landscape.x) < 0.5 && abs(late.y - landscape.y) < 0.5)
    }

    @Test("Kein Halt zwischen Flug und Zoom: der Zoom übernimmt den Schwung")
    func momentumHandoff() {
        // Early frame: zoom at 0.7 s, the card is still flying then.
        let tz = K.zoomStart(ready: 0.3)
        let start = K.wait(tz, from: emblem, to: idle)
        let v = K.momentum(tz, from: emblem, to: idle)
        #expect(abs(v.y) > 1)
        let h = 1.0 / 240
        let z = K.zoom(h, from: start, momentum: v, to: full)
        let vz = (z.y - start.y) / h
        #expect(abs(vz - v.y) < max(20, abs(v.y) * 0.2))
    }

    @Test("Ecke: in Ruhe 12, am ganzen Bild 0, klein nie eine Pille")
    func corner() {
        #expect(K.corner(idle, metrics: K.iPhone, full: full) == 12)
        #expect(K.corner(full, metrics: K.iPhone, full: full) == 0)
        #expect(K.corner(emblem, metrics: K.iPhone, full: full) <= 44 * 0.055)
    }

    @Test("Zeilen kommen nach dem Flug und gehen mit dem Zoom")
    func rows() {
        #expect(K.rowsCoverage(0.3, zoomOff: nil) == 0)
        #expect(K.rowsCoverage(0.8, zoomOff: nil) == 1)
        #expect(K.rowsCoverage(1.0, zoomOff: 0.8) == 0)
        #expect(K.stageCoverage(toZoom: 0.2) == 1)
        #expect(K.stageCoverage(toZoom: K.cardsOutUntil) == 0)
    }

    @Test("Ladelinie nur, wenn das Bild bei 0,75 s noch fehlt")
    func loadLine() {
        #expect(!K.loadLine(ready: 0.4))
        #expect(K.loadLine(ready: 1.5))
        #expect(K.loadLine(ready: nil))
    }

    @Test("Abgeber als Spiegelbild: schrumpft mit der Zoomfeder, fliegt mit der Flugfeder nach oben hinaus")
    func exit() {
        let landscape = K.fullscreen(width: 844, height: 390)
        let card = K.idleStatus(width: 844, height: 390, metrics: K.iPhone)
        #expect(K.exit(0.1, full: landscape, card: card) == landscape)
        // Shrinking = zoom in reverse: after the same time the same fraction of the path.
        let u = 0.3
        let since = K.exit(K.exitStart + u, full: landscape, card: card)
        let toward = K.zoom(u, from: card, momentum: .init(x: 0, y: 0, width: 0), to: landscape)
        let shareOff = (landscape.width - since.width) / (landscape.width - card.width)
        let fractionTo = (toward.width - card.width) / (landscape.width - card.width)
        #expect(abs(shareOff - fractionTo) < 1e-9)
        // Before takeoff it rests (apart from hovering) at the rest position.
        let calm = K.exit(K.departure, full: landscape, card: card)
        #expect(abs(calm.width - card.width) < 1)
        #expect(abs(calm.y - card.y) < K.hoverTravel + 1)
        // No jump at takeoff.
        let afterThat = K.exit(K.departure + 1.0 / 240, full: landscape, card: card)
        #expect(abs(afterThat.y - calm.y) < 3)
        // Then all the way out at the top, and the player closes only afterwards.
        let out = K.exitOut(full: landscape, card: card)
        #expect(out > K.departure && out < K.departure + 1)
        let l = K.exit(out, full: landscape, card: card)
        #expect(l.y + l.height / 2 < 0)
        #expect(K.exitRowsCoverage(K.departure - 0.01) == 1)
        #expect(K.exitRowsCoverage(K.departure + K.rowsOut) == 0)
    }

    @Test("Abflugrichtung nach Gerätegröße: zum Größeren hoch, zum Kleineren runter")
    func departureDirection() {
        #expect(K.departurePostTop(from: "iPhone", to: "Apple TV"))
        #expect(!K.departurePostTop(from: "Apple TV", to: "iPhone"))
        #expect(!K.departurePostTop(from: "Mac", to: "iPad"))
        #expect(K.departurePostTop(from: "iPad", to: "Mac"))
        #expect(K.departurePostTop(from: "iPhone", to: "iPhone"))
        #expect(K.departurePostTop(from: "Apple TV", to: "Wohnzimmer"))
        // A desktop counts like the Mac.
        #expect(!K.departurePostTop(from: "Linux", to: "iPhone"))
        #expect(K.departurePostTop(from: "Windows", to: "Apple TV"))
        #expect(!K.departurePostTop(from: "Apple TV", to: "Linux"))
        #expect(K.departurePostTop(from: "Linux", to: "Mac"))
        #expect(K.departurePostTop(from: "Android", to: "Android TV"))
        #expect(!K.departurePostTop(from: "Android TV", to: "iPhone"))
        #expect(!K.departurePostTop(from: "Mac", to: "Android"))
        // Downwards: all the way out at the bottom.
        let tv = K.fullscreen(width: 1920, height: 1080)
        let card = K.idleStatus(width: 1920, height: 1080, metrics: K.tv)
        let out = K.exitOut(full: tv, card: card, bearing: .bottom)
        #expect(out > K.departure && out < K.departure + 1)
        let l = K.exit(out, full: tv, card: card, bearing: .bottom)
        #expect(l.y - l.height / 2 > 1080)
    }

    @Test("Physisch oben aus der Schwerkraft, in Koordinaten der Oberfläche")
    func physicalTop() {
        func near(_ a: K.Direction, _ b: K.Direction) -> Bool { abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 }
        // Held upright, interface upright: up is up.
        #expect(near(K.departureDirection(gravityX: 0, gravityY: -1, surface: .up, toTop: true), .top))
        // Held upright, player still landscape (home on the right): up is the left side.
        #expect(near(K.departureDirection(gravityX: 0, gravityY: -1, surface: .landscapeHomeRight, toTop: true),
                    .init(x: -1, y: 0)))
        #expect(near(K.departureDirection(gravityX: 0, gravityY: -1, surface: .landscapeHomeLeft, toTop: true),
                    .init(x: 1, y: 0)))
        // Held in landscape (home on the right, top edge left): gravity points to the
        // left side of the device (−x); up is up.
        #expect(near(K.departureDirection(gravityX: -1, gravityY: 0, surface: .landscapeHomeRight, toTop: true), .top))
        #expect(near(K.departureDirection(gravityX: 1, gravityY: 0, surface: .landscapeHomeLeft, toTop: true), .top))
        // To the smaller device: physically down.
        #expect(near(K.departureDirection(gravityX: 0, gravityY: -1, surface: .up, toTop: false), .bottom))
        // Diagonal stays diagonal (unit vector).
        let s = K.departureDirection(gravityX: -0.5, gravityY: -0.5, surface: .up, toTop: true)
        #expect(abs(s.x * s.x + s.y * s.y - 1) < 1e-9 && s.x > 0 && s.y < 0)
        // Flat on the table: the interface's up.
        #expect(K.departureDirection(gravityX: 0.1, gravityY: 0.1, surface: .landscapeHomeRight, toTop: true) == .top)
        #expect(K.departureDirection(gravityX: 0.1, gravityY: 0.1, surface: .up, toTop: false) == .bottom)
        // Out sideways is also fully outside.
        let landscape = K.fullscreen(width: 844, height: 390)
        let card = K.idleStatus(width: 844, height: 390, metrics: K.iPhone)
        let left = K.Direction(x: -1, y: 0)
        let l = K.exit(K.exitOut(full: landscape, card: card, bearing: left), full: landscape, card: card, bearing: left)
        #expect(l.x + l.width / 2 < 0)
    }

    @Test("Stützpunkte: gleich verteilt, erster und letzter Wert auf den Grenzen")
    func anchorPoints() {
        let w = K.anchorPoints(from: 0, until: 1) { $0 }
        #expect(w.count == 121)
        #expect(w.first == 0 && w.last == 1)
    }

    @Test("Übernahme-Hinweis: nur Swiftly Player, nur frisch")
    func hint() {
        func s(_ p: String?) -> RemoteSession {
            RemoteSession(id: "s", devicesIdentifier: "g", deviceName: "Wohnzimmer", program: p,
                         takesCommands: true, running: nil, state: nil)
        }
        #expect(Takeover.takesHint(s("Swiftly Player")))
        #expect(Takeover.takesHint(s("Swiftly")))
        #expect(!Takeover.takesHint(s("Swiftly Music")))
        #expect(!Takeover.takesHint(s("Jellyfin Web")))
        #expect(!Takeover.takesHint(s(nil)))
        #expect(Takeover.isHandoff(hintPre: 0.2))
        #expect(!Takeover.isHandoff(hintPre: nil))
        #expect(!Takeover.isHandoff(hintPre: 5))
        #expect(!Takeover.isHandoff(hintPre: -1))
    }

    @Test("Der Hinweis wird gelesen — nur mit unserem Kopf")
    func hintRead() throws {
        func raw(_ s: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        }
        let our = try raw(#"{"MessageType":"GeneralCommand","Data":{"Name":"DisplayMessage","Arguments":{"Header":"Swiftly-Uebernahme","Text":"iPhone"}}}"#)
        #expect(RemoteControl.handoffHint(our) == "iPhone")
        let foreign = try raw(#"{"MessageType":"GeneralCommand","Data":{"Name":"DisplayMessage","Arguments":{"Header":"Hallo","Text":"x"}}}"#)
        #expect(RemoteControl.handoffHint(foreign) == nil)
    }
}
