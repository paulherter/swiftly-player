import Foundation
import JellyfinKit
import Testing

@testable import SwiftlyCore

/// The colour of a picture: `AvComputation` (the old Swift code behind `ImageTone`) against the core's
/// `pictureTones`, `toneGrid`, `toneAt`, `moodColor`, `moodDecay`, `moodMesh` and `moodNoiseTile`, on the
/// same pixels and the same measures the screens use.
struct ImageToneParityTests {
    private func pixels(_ seed: UInt64, width: Int = 48, height: Int = 27, gray: Bool = false) -> [UInt8] {
        var state = seed
        var out: [UInt8] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                let r = UInt8(truncatingIfNeeded: (x * 5 + Int(state & 0x3F)))
                let g = UInt8(truncatingIfNeeded: (y * 9 + Int((state >> 6) & 0x3F)))
                let b = UInt8(truncatingIfNeeded: ((x + y) * 3 + Int((state >> 12) & 0x7F)))
                out += gray ? [r, r, r, 255] : [r, g, b, 255]
            }
        }
        return out
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func theTonesOfAPictureAreTheSame() {
        for seed: UInt64 in [1, 7, 42, 99, 12345] {
            let rgba = pixels((seed &* 0x9E37_79B9_7F4A_7C15) | 1)
            let old = AvComputation.tones(rgba: rgba)
            let new = pictureTones(rgba: Data(rgba))
            #expect(old.count == new.count)
            for (o, n) in zip(old, new) { #expect(close(o, n)) }
        }
        #expect(AvComputation.tones(rgba: pixels(5, gray: true)) == pictureTones(rgba: Data(pixels(5, gray: true))))
        #expect(pictureTones(rgba: Data()).isEmpty)
    }

    @Test func theGridAndEverySampleAreTheSame() {
        let tones = pictureTones(rgba: Data(pixels(77)))
        #expect(!tones.isEmpty)
        let grid = toneGrid(tones: tones)
        #expect(grid.count == 25)
        for row in 0 ..< 5 {
            for column in 0 ..< 5 {
                let x = Double(column) / 4, y = Double(row) / 4
                let old = AvComputation.hsb(tones, x: x, y: y)
                let point = grid[row * 5 + column]
                #expect(Double(point.x) == x && Double(point.y) == y)
                #expect(close(point.hue ?? -1, old.audio))
                #expect(close(point.saturation ?? -1, old.saturation))
                #expect(close(point.brightness ?? -1, old.brightness))
            }
        }
        // `color(_:at:)` at a point that is not on the grid (the series page uses 0.2 / 0.55).
        let one = toneAt(tones: tones, x: 0.2, y: 0.55)
        let old = AvComputation.hsb(tones, x: 0.2, y: 0.55)
        #expect(close(one.hue ?? -1, old.audio) && close(one.saturation ?? -1, old.saturation))
        #expect(toneGrid(tones: []).allSatisfy { $0.hue == nil })
        #expect(toneAt(tones: [], x: 0.2, y: 0.55).hue == nil)
    }

    @Test func theFadeSamplesAreTheSame() {
        let tones = pictureTones(rgba: Data(pixels(3)))
        for (y, since, run) in [(0.0, 350.0, 1300.0), (350, 350, 1300), (900, 350, 1300), (1650, 350, 1300),
                                (2000, 350, 1300), (120, 280, 1300)] {
            let f = AvComputation.decay(y: y, since: since, runOut: run)
            #expect(close(f, moodDecay(y: y, since: since, runOut: run)))
            for x in [0.0, 0.5, 1.0] {
                let row = min(1, y / (since + 900))
                let old = AvComputation.color(tones, x: x, y: row, decay: f)
                let new = moodColor(tones: tones, x: x, y: row, decay: f)
                #expect(close(old.r, new.red) && close(old.g, new.green) && close(old.b, new.blue))
            }
        }
        let none = moodColor(tones: [], x: 0.5, y: 0.5, decay: 0.3)
        #expect(close(none.red, 16.0 / 255))
    }

    @Test func theDetailMeshIsTheOldOne() {
        let tones = pictureTones(rgba: Data(pixels(11)))
        let since = 350.0, runOut = 1300.0, colorHeight = 900.0
        let height = since + runOut
        let mesh = moodMesh(tones: tones, height: height, colorHeight: since + colorHeight, since: since,
                            runOut: runOut)
        // The rows the old `ImageTone.network(_:height:...)` built.
        var rows: [Double] = [0, since * 0.5, since]
        for i in 1 ... 10 { rows.append(since + runOut * Double(i) / 10) }
        rows.append(height)
        #expect(mesh.columns == 5 && Int(mesh.rows) == rows.count)
        var index = 0
        for y in rows {
            let f = AvComputation.decay(y: y, since: since, runOut: runOut)
            for s in 0 ..< 5 {
                let x = Double(s) / 4
                let old = AvComputation.color(tones, x: x, y: min(1, y / (since + colorHeight)), decay: f)
                let point = mesh.points[index]
                #expect(Double(point.x) == x)
                #expect(point.y == Float(min(1, y / height)))
                #expect(close(old.r, point.red) && close(old.g, point.green) && close(old.b, point.blue))
                index += 1
            }
        }
        #expect(detailMoodMesh(tones: tones, since: since) == mesh)
    }

    /// The old `ImageTone.noise` loop, kept here as the oracle.
    @Test func theNoiseTileIsTheOldOne() {
        let border = 96
        var old = [UInt8](repeating: 0, count: border * border * 4)
        var condition: UInt64 = 0x2545F4914F6CDD1D
        for i in stride(from: 0, to: old.count, by: 4) {
            condition ^= condition << 13
            condition ^= condition >> 7
            condition ^= condition << 17
            let bright = (condition & 1) == 1
            let coverage = UInt8(truncatingIfNeeded: condition >> 8)
            let channel: UInt8 = bright ? coverage : 0
            old[i] = channel; old[i + 1] = channel; old[i + 2] = channel
            old[i + 3] = coverage
        }
        #expect([UInt8](moodNoiseTile()) == old)
    }
}
