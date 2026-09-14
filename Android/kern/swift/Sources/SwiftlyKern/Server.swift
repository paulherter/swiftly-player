import Foundation
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
