import Foundation
// Auf Linux liegt URLSession nicht in Foundation, sondern in einem
// eigenen Modul. Auf Apple-Plattformen gibt es das Modul nicht — der
// Import ist deshalb bedingt und dort wirkungslos.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension URLSession {

    /// Die Sitzung, mit der Swiftly Server im Heimnetz erreicht.
    ///
    /// **`waitsForConnectivity` ist der Punkt, und zwar wegen einer Abfrage.**
    /// Seit iOS 14 fragt das System um Erlaubnis, bevor eine App Geräte im
    /// eigenen Netz anspricht — und zwar auch bei einer direkten IP, nicht nur
    /// bei `.local`. Die Abfrage erscheint beim **ersten** Versuch, und der
    /// scheitert, während der Nutzer sie noch liest. Mit `waitsForConnectivity`
    /// wartet die Anfrage stattdessen, bis die Erlaubnis da ist, und läuft dann
    /// weiter.
    ///
    /// Ohne das sah es so aus: Adresse eingeben, „Verbinden", sofort ein
    /// Fehler, dann die Abfrage — und wer sie erlaubt, muss von Hand noch
    /// einmal tippen. Beim zweiten Mal ging es dann „plötzlich".
    ///
    /// **Deshalb die Frist.** `waitsForConnectivity` wartet ohne Grenze, und
    /// ein Server, der schlicht nicht da ist, würde die Anmeldung hängen
    /// lassen statt einen Fehler zu zeigen. `timeoutIntervalForResource`
    /// begrenzt den ganzen Vorgang; 20 Sekunden reichen für eine Abfrage, die
    /// der Nutzer liest, und sind kurz genug, dass ein Tippfehler in der
    /// Adresse als Fehler ankommt.
    static let ortsnetzfaehig: URLSession = {
        let k = URLSessionConfiguration.default
        // **Auf Linux nur lesbar.** swift-corelibs-foundation kennt die
        // Eigenschaft, setzt sie aber nicht um — dort gibt es kein Warten auf
        // eine Verbindung, die noch nicht steht. Die beiden Fristen darunter
        // greifen weiterhin und sind ohnehin das, was einen Tippfehler in der
        // Adresse als Fehler ankommen lässt.
        #if canImport(Darwin)
        k.waitsForConnectivity = true
        #endif
        k.timeoutIntervalForRequest = 15
        k.timeoutIntervalForResource = 20
        return URLSession(configuration: k)
    }()
}
