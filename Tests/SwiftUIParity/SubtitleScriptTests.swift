import XCTest

/// The table that decides, per text run, how much outline a script gets (`SubtitleScript`).
final class SubtitleScriptTests: XCTestCase {
    private func parts(_ line: String) -> [String] {
        let text = line as NSString
        return SubtitleScript.runs(in: line).map { "\(text.substring(with: $0.range))|\($0.density)" }
    }

    func testLatinAndOtherScriptsStayPlain() {
        for line in ["Chaos must reign...", "Привет, мир", "Γεια σου", "你好,世界", "ひらがな カタカナ", "12:30 - ...", "Ünïcödé"] {
            XCTAssertEqual(SubtitleScript.strongest(in: SubtitleScript.runs(in: line)), .plain, line)
        }
    }

    func testScriptsAreClassified() {
        XCTAssertEqual(parts("مرحبا"), ["مرحبا|connected"])
        XCTAssertEqual(parts("שלום עולם"), ["שלום עולם|dense"])
        XCTAssertEqual(parts("नमस्ते"), ["नमस्ते|dense"])
        XCTAssertEqual(parts("สวัสดี"), ["สวัสดี|dense"])
        XCTAssertEqual(parts("ܫܠܡܐ"), ["ܫܠܡܐ|connected"])
    }

    func testRunsSplitOnlyAtScriptChangesAndNeutralsJoinTheRunBefore() {
        // The space and the colon after "Jack" stay with Jack; the Arabic comma belongs to the Arabic.
        XCTAssertEqual(parts("قال Jack: سأعود، ثم"),
                       ["قال |connected", "Jack: |plain", "سأعود، ثم|connected"])
        // Leading neutrals join the first run; digits and dots do not split a word.
        XCTAssertEqual(parts("- مرحبا 12..."), ["- مرحبا 12...|connected"])
        XCTAssertEqual(parts("..."), ["...|plain"])
        XCTAssertEqual(parts(""), [])
        // Runs cover the line in UTF-16 units (emoji are two).
        let line = "😀 ab مرحبا"
        let runs = SubtitleScript.runs(in: line)
        XCTAssertEqual(runs.reduce(0) { $0 + $1.range.length }, (line as NSString).length)
    }

    func testOutlineScalesWithTheLookButNeverBackToTheLatinValue() {
        XCTAssertEqual(SubtitleScript.strokeWidth(thickness: 3, density: .plain), 6)
        XCTAssertEqual(SubtitleScript.strokeWidth(thickness: 2, density: .plain), 4)
        XCTAssertEqual(SubtitleScript.strokeWidth(thickness: 0, density: .connected), 0)
        for density in [SubtitleScript.Density.dense, .connected] {
            let thin = SubtitleScript.strokeWidth(thickness: 2, density: density)
            let normal = SubtitleScript.strokeWidth(thickness: 3, density: density)
            XCTAssertGreaterThan(thin, 0)                // stroke only, behind the letters
            XCTAssertGreaterThan(normal, thin)           // the thickness choice still counts
            XCTAssertLessThan(normal, 6)                 // and it is thinner than Latin's 6
        }
        XCTAssertLessThan(SubtitleScript.Density.connected.outlineScale, SubtitleScript.Density.dense.outlineScale)
        XCTAssertLessThan(SubtitleScript.Density.connected.shadowScale, 1)
        XCTAssertEqual(SubtitleScript.Density.plain.shadowBlur, 0)
    }
}
