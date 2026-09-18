// Zieht Umrisse aus Website/schrift/figtree-latin.woff2 (OFL) in eine JSON-Tabelle,
// damit blog-bauen.py Titelbilder als SVG mit Pfaden statt Schrift schreiben kann.
// sips (CoreSVG) kennt keine Webfonts; Pfade rastert es sauber.
// Einmalig bzw. nach einem Schriftwechsel:
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift Werkzeuge/blog-schrift.swift
import CoreText
import Foundation

let hier = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let quelle = hier.appendingPathComponent("../Website/schrift/figtree-latin.woff2")
let ziel = hier.appendingPathComponent("blog-schrift.json")
let daten = try! Data(contentsOf: quelle) as CFData
guard let deskriptoren = CTFontManagerCreateFontDescriptorsFromData(daten) as? [CTFontDescriptor],
      let basis = deskriptoren.first else { fatalError("Schrift nicht lesbar") }

let einheiten: CGFloat = 1000
var zeichen = (32...126).map { Character(UnicodeScalar($0)!) }
zeichen += ["’", "‘", "“", "”", "–", "—", "…", "·", "é", "ü", "ö", "ä"]

func runde(_ w: CGFloat) -> String {
    let r = (w * 10).rounded() / 10
    return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
}

var ausgabe: [String: Any] = ["einheiten": 1000]
for gewicht in [600, 700] {
    let attr: [CFString: Any] = [kCTFontVariationAttribute: [0x77676874: gewicht]]
    let desk = CTFontDescriptorCreateCopyWithAttributes(basis, attr as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(desk, einheiten, nil)
    var tabelle: [String: Any] = [:]
    for z in zeichen {
        var einheit = Array(String(z).utf16)
        var glyphen = [CGGlyph](repeating: 0, count: einheit.count)
        guard CTFontGetGlyphsForCharacters(font, &einheit, &glyphen, einheit.count), glyphen[0] != 0 else { continue }
        var vorschub = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphen, &vorschub, 1)
        var d = ""
        if let pfad = CTFontCreatePathForGlyph(font, glyphen[0], nil) {
            pfad.applyWithBlock { el in
                let p = el.pointee.points
                // y spiegeln: SVG zaehlt nach unten
                func pt(_ i: Int) -> String { runde(p[i].x) + " " + runde(-p[i].y) }
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
        tabelle[String(z)] = ["v": Double(runde(vorschub.width))!, "d": d]
    }
    // Unterschneidung: Breite von "ab" als Zeile minus beide Vorschuebe
    var paare: [String: Double] = [:]
    let namen = tabelle.keys.sorted()  // noch ohne _kern
    for a in namen { for b in namen {
        let text = NSAttributedString(string: a + b, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let zeile = CTLineCreateWithAttributedString(text)
        let breite = CGFloat(CTLineGetTypographicBounds(zeile, nil, nil, nil))
        let diff = breite - CGFloat((tabelle[a] as! [String: Any])["v"] as! Double) - CGFloat((tabelle[b] as! [String: Any])["v"] as! Double)
        if abs(diff) >= 2 { paare[a + b] = Double(runde(diff))! }
    }}
    tabelle["_kern"] = paare
    ausgabe[String(gewicht)] = tabelle
}
let json = try! JSONSerialization.data(withJSONObject: ausgabe, options: [.sortedKeys])
try! json.write(to: ziel)
print("geschrieben \(ziel.path) (\(json.count) Bytes)")
