import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JellyfinKit

/// **Erreicht die App den Server?** — der erste Aufruf von Kotlin ins Paket.
///
/// Fragt `System/Info/Public` ab, das keine Anmeldung braucht, und gibt eine
/// fertige Zeile zurueck. Die Fassade spricht in Antworten, nicht in
/// Einzelteilen: Kotlin setzt hier nichts zusammen.
///
/// `clientVersion` steht ausdruecklich da. Die Vorgabe liest die Fassung aus
/// dem App-Buendel — und das gibt es in einer Android-Bibliothek nicht.
public func serverPruefen(adresse: String) async throws -> String {
    guard let url = URL(string: adresse) else {
        throw Kernfehler.adresse(adresse)
    }
    let client = JellyfinClient(baseURL: url, deviceID: "swiftly-android",
                                deviceName: "Android", clientVersion: "1.0.3")
    let info = try await client.publicSystemInfo()
    return "\(info.serverName ?? "?") · Jellyfin \(info.version ?? "?")"
}

public enum Kernfehler: Error {
    case adresse(String)
    case nichtVerbunden
}

/// **Ein Fehler, dessen Nachricht schon fuer den Nutzer taugt.** swift-java reicht
/// `String(describing:)` als Nachricht der Java-Ausnahme weiter; hier ist das der Text selbst.
public struct Kerntext: Error, CustomStringConvertible {
    public let description: String
    public init(_ text: String) { description = text }
}

/// **Der Satz fuer den Nutzer, aus jedem Fehler der Fassade.** Ueber `lesbarerFehler` aus dem
/// Paket, damit Android dieselben Worte zeigt wie iOS und Linux.
///
/// Vorher reichte swift-java `String(describing:)` weiter, und auf dem Verbindungsschirm stand bei
/// einer falschen Adresse woertlich `transport("Could not resolve host: …")` (gemessen 16.09.2026).
/// Netzfehler kommen seit `1feb8e5` als `JellyfinError.netz(code:)` aus dem Paket; die curl-Saetze
/// muss hier niemand mehr zurueckuebersetzen.
func kernFehlertext(_ fehler: any Error) -> String {
    switch fehler {
    case let k as Kerntext: return k.description
    case Kernfehler.adresse: return lesbarerFehler(JellyfinError.invalidServerURL)
    case Kernfehler.nichtVerbunden: return lesbarerFehler(JellyfinError.notAuthenticated)
    default: return lesbarerFehler(fehler)
    }
}

/// Fuer jede werfende Funktion, deren Fehler Kotlin anzeigt: die Java-Ausnahme traegt dann den Satz.
func lesbarWerfen<T>(_ tun: () async throws -> T) async throws -> T {
    do { return try await tun() }
    catch is CancellationError { throw CancellationError() }
    catch { throw Kerntext(kernFehlertext(error)) }
}
