import Testing
@testable import JellyfinKit

/// The language list from which the settings build their choices.
///
/// **It is checked, not looked at.** A list with 33 entries and
/// several spellings per entry is exactly the kind of file where a
/// duplicate goes unnoticed, until a track name of the wrong
/// language gets assigned.
@Suite("Sprachliste")
struct LanguageListTests {

    // MARK: - The extended list

/// **Two languages must not share a form.** Otherwise the order in
/// the list decides which one wins, and nobody would see why a
/// Portuguese track name suddenly counts as Spanish.
    @Test func noFormDouble() {
    var watched: [String: String] = [:]
    for entryRecord in Language.all {
        for form in entryRecord.shape {
            #expect(watched[form] == nil,
                    "„\(form)“ steht bei \(entryRecord.name) und bei \(watched[form] ?? "")")
            watched[form] = entryRecord.name
        }
    }
}

/// Short forms that occur as ordinary words in track names must not
/// be in the list; "No subtitles" is not Norwegian.
    @Test func noTripShorthands() {
    let forbidden = ["no", "is", "id", "he", "be", "or", "as", "in", "am", "so",
                    "an", "da", "de", "it", "el", "la", "un"]
    for entryRecord in Language.all {
        for form in entryRecord.shape where forbidden.contains(form) {
            Issue.record("\(entryRecord.name) traegt die Stolperform „\(form)“")
        }
    }
}

    @Test func newLanguagesWhoDetected() {
    #expect(Language.detected(in: "Polski (forced)") == "Polski")
    #expect(Language.detected(in: "pol") == "Polski")
    #expect(Language.detected(in: "Portuguese (Brazil)") == "Português")
    #expect(Language.detected(in: "zh-Hans") == "中文")
    #expect(Language.detected(in: "No subtitles") == nil)
    #expect(Language.detected(in: "This is forced") == nil)
}
}
