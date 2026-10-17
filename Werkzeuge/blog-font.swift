// Extracts glyph outlines from Website/schrift/figtree-latin.woff2 (OFL) into a JSON table
// so blog-build.py can write cover images as SVG with paths instead of text.
// sips (CoreSVG) does not support web fonts but rasterizes paths cleanly.
// Run once, and again after a font change:
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift Werkzeuge/blog-font.swift
import CoreText
import Foundation

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let source = here.appendingPathComponent("../Website/schrift/figtree-latin.woff2")
let target = here.appendingPathComponent("blog-font.json")
let data = try! Data(contentsOf: source) as CFData
guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data) as? [CTFontDescriptor],
      let base = descriptors.first else { fatalError("Schrift nicht lesbar") }

let units: CGFloat = 1000
var symbolText = (32...126).map { Character(UnicodeScalar($0)!) }
symbolText += ["’", "‘", "“", "”", "–", "—", "…", "·", "é", "ü", "ö", "ä"]

func round(_ w: CGFloat) -> String {
    let r = (w * 10).rounded() / 10
    return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
}

var printout: [String: Any] = ["einheiten": 1000]
for weight in [600, 700] {
    let attr: [CFString: Any] = [kCTFontVariationAttribute: [0x77676874: weight]]
    let desk = CTFontDescriptorCreateCopyWithAttributes(base, attr as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(desk, units, nil)
    var table: [String: Any] = [:]
    for z in symbolText {
        var unit = Array(String(z).utf16)
        var glyph = [CGGlyph](repeating: 0, count: unit.count)
        guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, unit.count), glyph[0] != 0 else { continue }
        var prePush = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &prePush, 1)
        var d = ""
        if let path = CTFontCreatePathForGlyph(font, glyph[0], nil) {
            path.applyWithBlock { el in
                let p = el.pointee.points
                // flip y: SVG counts downwards
                func pt(_ i: Int) -> String { round(p[i].x) + " " + round(-p[i].y) }
                switch el.pointee.type {
                case .moveToPoint: d += "M" + pt(0)
                case .addLineToPoint: d += "L" + pt(0)
                case .addQuadCurveToPoint: d += "Q" + pt(0) + " " + pt(1)
                case .addCurveToPoint: d += "C" + pt(0) + " " + pt(1) + " " + pt(2)
                case .closeSubpath: d += "Z"
                @unknown default: break
                }
            }
        }
        table[String(z)] = ["v": Double(round(prePush.width))!, "d": d]
    }
    // Kerning: width of "ab" as a line minus both advances
    var pairs: [String: Double] = [:]
    let names = table.keys.sorted()  // without _kern yet
    for a in names { for b in names {
        let text = NSAttributedString(string: a + b, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let row = CTLineCreateWithAttributedString(text)
        let width = CGFloat(CTLineGetTypographicBounds(row, nil, nil, nil))
        let diff = width - CGFloat((table[a] as! [String: Any])["v"] as! Double) - CGFloat((table[b] as! [String: Any])["v"] as! Double)
        if abs(diff) >= 2 { pairs[a + b] = Double(round(diff))! }
    }}
    table["_kern"] = pairs
    printout[String(weight)] = table
}
let json = try! JSONSerialization.data(withJSONObject: printout, options: [.sortedKeys])
try! json.write(to: target)
print("geschrieben \(target.path) (\(json.count) Bytes)")
