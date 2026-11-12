// Prints the Core Text widths of the three comparison strings in Inter Variable at 17 and 22 pt (weights 400 | 600).
// Build and run on a Mac: swiftc -O coretext_widths.swift -o /tmp/ct && /tmp/ct ../fonts/InterVariable.ttf

import CoreText
import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
CTFontManagerRegisterFontsForURL(url, .process, nil)
let strings = ["Swiftly Player", "Größe, Übergänge und Ärger", "Frieren: Beyond Journey's End"]
func width(_ s: String, _ size: CGFloat, _ weight: CGFloat) -> (Double, Double) {
    let base = CTFontDescriptorCreateWithNameAndSize("Inter Variable" as CFString, size)
    let wghtTag = 0x77676874 // 'wght'
    let desc = CTFontDescriptorCreateCopyWithVariation(base, wghtTag as CFNumber, weight)
    let font = CTFontCreateWithFontDescriptor(desc, size, nil)
    let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let line = CTLineCreateWithAttributedString(attr)
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    let h = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    return (w, Double(h))
}
print("family:", CTFontCopyFamilyName(CTFontCreateWithName("Inter Variable" as CFString, 17, nil)))
for size in [17.0, 22.0] { for s in strings {
    let a = width(s, size, 400), b = width(s, size, 600)
    print(String(format: "%4.0f pt  %-34@ %8.3f | %8.3f   h %.3f", size, s as NSString, a.0, b.0, b.1))
}}
