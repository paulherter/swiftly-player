import SwiftUI

/// Reads the SVG path language and builds a `Path` from it.
///
/// Deliberately a reader instead of generated code: the templates exist
/// as strings, so a new version can be swapped in without replacing a
/// thousand lines of point lists.
///
/// Supports M, L, H, V, C, S, Q, T, A and Z in upper and lower case.
enum SVGPath {

    /// Fits the path evenly into the frame and centers it.
    ///
    /// `box` is the viewBox **including its origin**, which is not always at
    /// zero. The wordmark, for example, starts at `23 -778`; without the shift
    /// it would lie far outside the frame.
    ///
    /// **The raw path is cached.** `Shape.path(in:)` is called by the framework
    /// on *every* layout, i.e. once per frame during an animation. Without a
    /// cache the wordmark was re-scanned and reassembled every time.
    ///
    /// Measured with `sample` while opening a series page on the Mac: **75 of
    /// 439 samples of the main run (17 %) were in `SVGPath`**, 56 of them in
    /// the scanner. The wordmark sits permanently in the sidebar there, so it
    /// is recomputed on every movement in the window.
    ///
    /// The **untransformed** path is cached: the templates are a handful of
    /// fixed strings, whereas the transformation depends on the frame and is
    /// cheap.
    static func path(_ data: String, box: CGRect, in frameRect: CGRect) -> Path {
        let raw = PathCache.shared.raw(data)
        let factor = min(frameRect.width / box.width, frameRect.height / box.height)
        let width = box.width * factor
        let height = box.height * factor
        var t = CGAffineTransform(
            translationX: frameRect.minX + (frameRect.width - width) / 2,
            y: frameRect.minY + (frameRect.height - height) / 2)
        t = t.scaledBy(x: factor, y: factor)
        t = t.translatedBy(x: -box.minX, y: -box.minY)
        return raw.applying(t)
    }

    /// The scanned path without any transformation.
    static func rawPath(_ data: String) -> Path { sketchOut(marks(data)) }

    // MARK: Splitting

    private enum Mark {
        case command(Character)
        case figure(CGFloat)
    }

    /// SVG allows numbers without separators ("1.5-2.3", ".5.5"), hence a
    /// scanner of its own instead of `split`.
    private static func marks(_ data: String) -> [Mark] {
        var result: [Mark] = []
        var buffer = ""

        func complete() {
            if let value = Double(buffer) { result.append(.figure(CGFloat(value))) }
            buffer = ""
        }

        for symbolText in data {
            switch symbolText {
            case "-", "+":
                // Splits off a new number, except directly after an exponent.
                if !buffer.isEmpty, !buffer.lowercased().hasSuffix("e") { complete() }
                buffer.append(symbolText)
            case ".":
                if buffer.contains(".") { complete() }   // second dot: new number
                buffer.append(symbolText)
            case "e", "E":
                buffer.append(symbolText)
            case let z where z.isNumber:
                buffer.append(z)
            case let z where z.isLetter:
                complete()
                result.append(.command(z))
            default:
                complete()
            }
        }
        complete()
        return result
    }

    // MARK: Walking through

    private static func sketchOut(_ marks: [Mark]) -> Path {
        var path = Path()
        var pen = CGPoint.zero
        var beginning = CGPoint.zero
        var lastControl: CGPoint?      // from C and S
        var lastSquareAdvice: CGPoint?        // from Q and T
        var command: Character = "M"
        var i = 0

        /// Fetches the next numbers. A letter before them ends the sequence.
        func numbers(_ count: Int) -> [CGFloat]? {
            var values: [CGFloat] = []
            var j = i
            while values.count < count, j < marks.count {
                guard case let .figure(value) = marks[j] else { return nil }
                values.append(value)
                j += 1
            }
            guard values.count == count else { return nil }
            i = j
            return values
        }

        while i < marks.count {
            if case let .command(symbolText) = marks[i] {
                command = symbolText
                i += 1
                if Character(symbolText.lowercased()) == "z" {
                    path.closeSubpath()
                    pen = beginning
                    lastControl = nil
                }
                continue
            }

            let relative = command.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: pen.x + x, y: pen.y + y) : CGPoint(x: x, y: y)
            }

            switch Character(command.lowercased()) {
            case "m":
                guard let w = numbers(2) else { return path }
                pen = point(w[0], w[1])
                beginning = pen
                path.move(to: pen)
                lastControl = nil
                // Further pairs after an M count as L, as SVG prescribes.
                command = relative ? "l" : "L"

            case "l":
                guard let w = numbers(2) else { return path }
                pen = point(w[0], w[1])
                path.addLine(to: pen)
                lastControl = nil

            case "h":
                guard let w = numbers(1) else { return path }
                pen = CGPoint(x: relative ? pen.x + w[0] : w[0], y: pen.y)
                path.addLine(to: pen)
                lastControl = nil

            case "v":
                guard let w = numbers(1) else { return path }
                pen = CGPoint(x: pen.x, y: relative ? pen.y + w[0] : w[0])
                path.addLine(to: pen)
                lastControl = nil

            case "c":
                guard let w = numbers(6) else { return path }
                let k1 = point(w[0], w[1]), k2 = point(w[2], w[3]), target = point(w[4], w[5])
                path.addCurve(to: target, control1: k1, control2: k2)
                lastControl = k2
                pen = target

            case "s":
                guard let w = numbers(4) else { return path }
                // The first handle is the reflection of the previous one at the pen.
                let k1 = lastControl.map {
                    CGPoint(x: 2 * pen.x - $0.x, y: 2 * pen.y - $0.y)
                } ?? pen
                let k2 = point(w[0], w[1]), target = point(w[2], w[3])
                path.addCurve(to: target, control1: k1, control2: k2)
                lastControl = k2
                lastSquareAdvice = nil
                pen = target

            case "q":
                guard let w = numbers(4) else { return path }
                let grip = point(w[0], w[1]), target = point(w[2], w[3])
                path.addQuadCurve(to: target, control: grip)
                lastSquareAdvice = grip
                lastControl = nil
                pen = target

            case "t":
                guard let w = numbers(2) else { return path }
                let grip = lastSquareAdvice.map {
                    CGPoint(x: 2 * pen.x - $0.x, y: 2 * pen.y - $0.y)
                } ?? pen
                let target = point(w[0], w[1])
                path.addQuadCurve(to: target, control: grip)
                lastSquareAdvice = grip
                lastControl = nil
                pen = target

            case "a":
                guard let w = numbers(7) else { return path }
                let target = point(w[5], w[6])
                arc(&path, from: pen, to: target, rx: w[0], ry: w[1],
                      rotation: w[2], large: w[3] != 0, inClockwise: w[4] != 0)
                lastControl = nil
                lastSquareAdvice = nil
                pen = target

            default:
                return path
            }
        }
        return path
    }

    // MARK: Arcs

    /// Converts an elliptical arc into cubic curves.
    ///
    /// `Path` knows only curves, no SVG arc segment. The route there is the one
    /// from the SVG specification: convert from endpoint to center form, then
    /// split into pieces of at most 90 degrees, at which point the curve
    /// approximation is more accurate than a pixel.
    private static func arc(_ path: inout Path, from: CGPoint, to: CGPoint,
                              rx: CGFloat, ry: CGFloat, rotation: CGFloat,
                              large: Bool, inClockwise: Bool) {
        guard rx != 0, ry != 0 else {
            path.addLine(to: to)
            return
        }
        var rx = abs(rx), ry = abs(ry)
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)

        let dx2 = (from.x - to.x) / 2, dy2 = (from.y - to.y) / 2
        let x1 =  cosP * dx2 + sinP * dy2
        let y1 = -sinP * dx2 + cosP * dy2

        // Inflate semi-axes that are too small, otherwise there is no solution.
        let extent = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if extent > 1 {
            rx *= sqrt(extent)
            ry *= sqrt(extent)
        }

        let counter = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = denominator == 0 ? 0 : sqrt(counter / denominator)
        if large == inClockwise { factor = -factor }

        let cx1 =  factor * rx * y1 / ry
        let cy1 = -factor * ry * x1 / rx
        let center = CGPoint(x: cosP * cx1 - sinP * cy1 + (from.x + to.x) / 2,
                            y: sinP * cx1 + cosP * cy1 + (from.y + to.y) / 2)

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dotProduct = ux * vx + uy * vy
            let magnitude = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard magnitude > 0 else { return 0 }
            let w = acos(min(max(dotProduct / magnitude, -1), 1))
            return (ux * vy - uy * vx < 0) ? -w : w
        }

        let start = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var extentSpan = angle((x1 - cx1) / rx, (y1 - cy1) / ry,
                            (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !inClockwise, extentSpan > 0 { extentSpan -= 2 * .pi }
        if inClockwise, extentSpan < 0 { extentSpan += 2 * .pi }

        let pieces = max(1, Int(ceil(abs(extentSpan) / (.pi / 2))))
        let step = extentSpan / CGFloat(pieces)
        // Handle length for approximating a circular arc with a curve.
        let grip = 4.0 / 3.0 * tan(step / 4)

        var angleNow = start
        for _ in 0 ..< pieces {
            let angleNext = angleNow + step
            let cos1 = cos(angleNow), sin1 = sin(angleNow)
            let cos2 = cos(angleNext), sin2 = sin(angleNext)

            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cosP * rx * x - sinP * ry * y + center.x,
                        y: sinP * rx * x + cosP * ry * y + center.y)
            }

            let target = map(cos2, sin2)
            let k1 = map(cos1 - grip * sin1, sin1 + grip * cos1)
            let k2 = map(cos2 + grip * sin2, sin2 - grip * cos2)
            path.addCurve(to: target, control1: k1, control2: k2)
            angleNow = angleNext
        }
    }
}

/// A shape from SVG path data.
/// Caches the scanned raw paths. A handful of entries: the templates are
/// fixed strings in the program.
///
/// `Shape.path(in:)` is not pinned to the main thread, hence a lock
/// instead of an actor.
private final class PathCache: @unchecked Sendable {
    static let shared = PathCache()

    private let lock = NSLock()
    private var known: [String: Path] = [:]

    func raw(_ data: String) -> Path {
        lock.lock()
        if let present = known[data] {
            lock.unlock()
            return present
        }
        lock.unlock()

        let new = SVGPath.rawPath(data)

        lock.lock()
        // More than a handful would be a sign that paths created at runtime are
        // coming in; better to clear than to grow without limit.
        if known.count > 32 { known.removeAll() }
        known[data] = new
        lock.unlock()
        return new
    }
}

struct SVGForm: Shape {
    let data: String
    let box: CGRect
    func path(in frameRect: CGRect) -> Path { SVGPath.path(data, box: box, in: frameRect) }
}
