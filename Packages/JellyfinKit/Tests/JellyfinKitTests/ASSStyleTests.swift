import Foundation
import Testing
@testable import JellyfinKit

@Suite("ASS-Stil aus der Datei")
struct ASSStyleTests {

    static let header = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,60,&H00CCCCCC,&H000000FF,&H00202020,&H80000000,-1,0,0,0,100,100,0,0,1,3,2,2,10,10,40,1
    Style: Yellow,Arial,60,&H0000FFFF,&H000000FF,&H00000000,&H00000000,0,-1,0,0,100,100,0,0,1,0,0,2,10,10,40,1
    Style: Box,Arial,40,&H00FFFFFF,&H000000FF,&H80000000,&H00000000,0,0,0,0,100,100,0,0,3,0,0,2,10,10,40,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """

    @Test("Ein vom Server aus SRT gemachter Standardstil zählt nicht als Stil der Datei")
    func converterDefaultIsNoFileStyle() {
        let jellyfin = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 384
        PlayResY: 288

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,20,&Hffffff,&Hffffff,&H0,&H0,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1
        """
        #expect(ASSStyleSheet.parse(jellyfin).isConverterDefault)
        #expect(ASSStyleSheet.parse(jellyfin.replacingOccurrences(of: "Arial,20", with: "Arial,16").replacingOccurrences(of: "1,2,2,2,10", with: "1,1,0,2,10")).isConverterDefault)
        // A real script (own sizes, several styles) is a file style.
        #expect(!sheet.isConverterDefault)
        #expect(!ASSStyleSheet().isConverterDefault)
    }

    private var sheet: ASSStyleSheet { ASSStyleSheet.parse(Self.header) }

    // MARK: colours

    @Test("&HAABBGGRR: Rot und Blau sind vertauscht, Alpha 00 ist deckend")
    func colourOrder() throws {
        let yellow = try #require(SubtitleColour.parse("&H0000FFFF"))
        #expect(yellow.rgb == 0xFFFF00)
        #expect(yellow.opacity == 1)
        let blue = try #require(SubtitleColour.parse("&H00FF0000&"))   // BB=FF -> blue
        #expect(blue.rgb == 0x0000FF)
        let half = try #require(SubtitleColour.parse("&H80000000"))
        #expect(half.rgb == 0)
        #expect(abs(half.opacity - 0.498) < 0.01)
        let clear = try #require(SubtitleColour.parse("&HFF000000"))
        #expect(clear.opacity == 0)
    }

    @Test("Farben ohne Alpha, kurze Hexwerte und die Dezimalform alter SSA-Dateien")
    func colourForms() throws {
        #expect(SubtitleColour.parse("&H00FFFF&")?.rgb == 0xFFFF00)
        #expect(SubtitleColour.parse("&HFF&")?.rgb == 0xFF0000)        // short: padded on the left
        #expect(SubtitleColour.parse("H00FF00")?.rgb == 0x00FF00)
        #expect(SubtitleColour.parse("16777215")?.rgb == 0xFFFFFF)     // decimal white
        #expect(SubtitleColour.parse("255")?.rgb == 0xFF0000)          // decimal red (BGR)
        #expect(SubtitleColour.parse("-2147483648")?.opacity == 1 - 128.0 / 255)  // 0x80000000
        #expect(SubtitleColour.parse("") == nil)
        #expect(SubtitleColour.parse("&HZZ&") == nil)
    }

    // MARK: header

    @Test("Die Stile der Kopfzeile werden gelesen")
    func headerStyles() throws {
        let sheet = sheet
        #expect(sheet.playResY == 1080)
        let normal = try #require(sheet.style(named: "Default"))
        #expect(normal.primary.rgb == 0xCCCCCC)
        #expect(normal.outline.rgb == 0x202020)
        #expect(abs(normal.back.opacity - 0.498) < 0.01)
        #expect(normal.bold && !normal.italic)
        #expect(normal.outlineWidth == 3 && normal.shadowWidth == 2 && normal.fontSize == 60)
        let yellow = try #require(sheet.style(named: "yellow"))   // case does not matter
        #expect(yellow.primary.rgb == 0xFFFF00 && yellow.italic && !yellow.bold)
        #expect(sheet.style(named: "*Default")?.name == "Default")
        // Unknown name: the Default style.
        #expect(sheet.style(named: "Nobody")?.name == "Default")
        #expect(ASSStyleSheet.parse("").style(named: "Default") == nil)
    }

    @Test("Alte SSA-Köpfe: TertiaryColour ist der Rand")
    func ssaHeader() throws {
        let ssa = """
        [V4 Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment
        Style: Default,Arial,24,16777215,255,65280,0,0,0,1,2,1,2
        """
        let style = try #require(ASSStyleSheet.parse(ssa).style(named: "Default"))
        #expect(style.primary.rgb == 0xFFFFFF)
        #expect(style.outline.rgb == 0x00FF00)
        #expect(style.outlineWidth == 2 && style.shadowWidth == 1)
    }

    // MARK: event lines

    private func runs(_ line: String) -> [ASSRun] { ASSCue.runs(eventLines: line, sheet: sheet) }

    @Test("Ohne Tags gilt der Stil der Zeile: Farben, Rand, Schatten, fett")
    func styleWithoutTags() throws {
        let result = runs("0,0,Default,,0,0,0,,Hello there")
        #expect(result.count == 1)
        let run = result[0]
        #expect(run.text == "Hello there")
        #expect(run.primary?.rgb == 0xCCCCCC)
        #expect(run.outline?.rgb == 0x202020)
        #expect(run.bold == true && run.italic == false)
        #expect(run.outlineEm == 3.0 / 60 && run.shadowEm == 2.0 / 60)
    }

    @Test("\\c und \\1c ändern die Füllfarbe, \\3c den Rand, \\r setzt zurück")
    func colourOverrides() {
        let result = runs(#"0,0,Default,,0,0,0,,{\c&H0000FF&}red {\3c&H00FF00&}green edge{\r} back"#)
        #expect(result.map(\.text) == ["red ", "green edge", " back"])
        #expect(result[0].primary?.rgb == 0xFF0000)
        #expect(result[0].outline?.rgb == 0x202020)
        #expect(result[1].outline?.rgb == 0x00FF00)
        #expect(result[2].primary?.rgb == 0xCCCCCC)
        #expect(runs(#"0,0,Default,,0,0,0,,{\1c&H00FFFF&}x"#)[0].primary?.rgb == 0xFFFF00)
        // A bare \c goes back to the style.
        let again = runs(#"0,0,Default,,0,0,0,,{\c&H0000FF&}a{\c}b"#)
        #expect(again[1].primary?.rgb == 0xCCCCCC)
    }

    @Test("\\alpha und \\1a..\\4a: 00 deckend, FF klar; \\c lässt die Deckkraft stehen")
    func alphaOverrides() {
        let all = runs(#"0,0,Default,,0,0,0,,{\alpha&H80&}half"#)[0]
        #expect(abs((all.primary?.opacity ?? 0) - 0.498) < 0.01)
        #expect(abs((all.outline?.opacity ?? 0) - 0.498) < 0.01)
        let fillOnly = runs(#"0,0,Default,,0,0,0,,{\1a&HFF&}ghost"#)[0]
        #expect(fillOnly.primary?.opacity == 0)
        #expect(fillOnly.outline?.opacity == 1)
        let outlineGone = runs(#"0,0,Default,,0,0,0,,{\3a&HFF&}x"#)[0]
        #expect(outlineGone.outline?.opacity == 0)
        let keep = runs(#"0,0,Default,,0,0,0,,{\1a&H80&\c&H0000FF&}x"#)[0]
        #expect(keep.primary?.rgb == 0xFF0000)
        #expect(abs((keep.primary?.opacity ?? 0) - 0.498) < 0.01)
    }

    @Test("\\b und \\i, auch mitten in der Zeile; \\b700 ist fett")
    func boldItalic() {
        let result = runs(#"0,0,Yellow,,0,0,0,,plain {\b1}bold{\b0} {\i0}upright"#)
        #expect(result.map(\.text) == ["plain ", "bold", " ", "upright"])
        #expect(result[0].bold == false && result[0].italic == true)
        #expect(result[1].bold == true)
        #expect(result[3].italic == false)
        #expect(runs(#"0,0,Yellow,,0,0,0,,{\b700}x"#)[0].bold == true)
    }

    @Test("\\bord und \\shad in Pixeln der Schrift; 0 schaltet ab")
    func outlineShadowOverrides() {
        let result = runs(#"0,0,Default,,0,0,0,,{\bord0\shad0}bare"#)[0]
        #expect(result.outlineEm == 0 && result.shadowEm == 0)
        let big = runs(#"0,0,Default,,0,0,0,,{\bord6}fat"#)[0]
        #expect(big.outlineEm == 0.1)
    }

    @Test("Stil Box: Kasten in der Randfarbe, Stil Yellow ohne Rand")
    func borderStyles() {
        #expect(runs("0,0,Box,,0,0,0,,hi")[0].borderStyle == 3)
        #expect(runs("0,0,Yellow,,0,0,0,,hi")[0].outlineEm == 0)
    }

    @Test("Zeilenumbruch, harte Leerzeichen, Kommas im Text")
    func textEscapes() {
        let text = runs(#"0,0,Default,,0,0,0,,One\Ntwo\hthree, four, five"#).map(\.text).joined()
        #expect(text == "One\ntwo\u{00A0}three, four, five")
    }

    @Test("Zeichnungen (\\p1) werden nicht als Text gezeigt")
    func drawingsDropped() {
        #expect(runs(#"0,0,Default,,0,0,0,,{\p1}m 0 0 l 100 0 100 100{\p0}"#).isEmpty)
        let mixed = runs(#"0,0,Default,,0,0,0,,{\p1}m 0 0 l 5 5{\p0}Text"#)
        #expect(mixed.map(\.text) == ["Text"])
    }

    @Test("Animationen, Positionen und Verläufe stören die Farben nicht")
    func ignoredTags() {
        let result = runs(#"0,0,Default,,0,0,0,,{\an8\pos(960,100)\fad(100,200)\t(0,500,\1c&H0000FF&)\clip(0,0,10,10)\blur2\fscx90}Sign"#)
        #expect(result.count == 1)
        #expect(result[0].text == "Sign")
        #expect(result[0].primary?.rgb == 0xCCCCCC)
    }

    @Test("Mehrere Ereigniszeilen werden untereinander gesetzt")
    func severalEvents() {
        let result = runs("0,0,Default,,0,0,0,,First\n1,0,Yellow,,0,0,0,,Second")
        #expect(result.map(\.text) == ["First", "\n", "Second"])
        #expect(result[0].primary?.rgb == 0xCCCCCC)
        #expect(result[2].primary?.rgb == 0xFFFF00)
    }

    @Test("Ohne Kopfzeile zählen nur die Tags; sonst bleibt die Füllung leer (eigener Stil)")
    func withoutHeader() {
        let result = ASSCue.runs(eventLines: #"0,0,Default,,0,0,0,,{\c&H0000FF&}red{\r} plain"#, sheet: nil)
        #expect(result[0].primary?.rgb == 0xFF0000)
        #expect(result[1].primary == nil && result[1].outlineEm == nil)
    }

    @Test("Eine Zeile, die keine Ereigniszeile ist, geht unverändert durch")
    func plainLine() {
        let result = runs("Just words, with a comma")
        #expect(result.map(\.text) == ["Just words, with a comma"])
        #expect(!result[0].isStyled)
    }
}
