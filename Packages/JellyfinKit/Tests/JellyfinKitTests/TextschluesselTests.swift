#if !canImport(Darwin)
import Foundation
import Testing
@testable import JellyfinKit

/// Nur ausserhalb von Apple — dort uebersetzt `String(localized:)`, nicht `Textkatalog`.
/// `%lld` liest 64 Bit — auch dort, wo `Int` nur 32 Bit hat (armeabi-v7a).
@Suite struct TextschluesselTests {
    @Test func zahlenGehenAls64BitInsFormat() {
        #expect(Textschluessel.Argument.zahl(40).alsFormatargument is Int64)
    }

    @Test func laufzeitMitZweiZahlen() {
        let katalog = Textkatalog(leer: "de")
        #expect(katalog.text("\(1) Std. \(40) Min.") == "1 Std. 40 Min.")
        #expect(katalog.text("Noch \(42) Minuten") == "Noch 42 Minuten")
    }
}
#endif
