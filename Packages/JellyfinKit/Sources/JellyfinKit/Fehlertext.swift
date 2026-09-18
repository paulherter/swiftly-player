import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Was dem Nutzer statt „Error Domain=… Code=-1004" gesagt wird.**
///
/// `localizedDescription` einer `URLError` ist brauchbar, die eines
/// selbstgebauten Fehlers ist es selten — dort steht sonst der Typname.
///
/// Lag in `Sources/Shared/Anmeldemodell.swift` und war damit für die
/// Linux-Fassung unerreichbar; dort stand bei jeder fehlgeschlagenen
/// Anmeldung roh `error.localizedDescription`. Das verstösst gegen D3:
/// **Fehlertexte nennen die Ursache, nicht nur „etwas ging nicht".**
public func lesbarerFehler(_ fehler: any Error) -> String {
    if let j = fehler as? JellyfinError {
        switch j {
        case let .netz(code):           return netztext(code: code, sonst: nil)
        case let .transport(text):      return text
        case .notAuthenticated:         return uebersetzt("Nicht angemeldet.")
        case .invalidServerURL:         return uebersetzt("Die Adresse konnte nicht gelesen werden.")
        case let .http(status, _):
            switch status {
            case 401:  return uebersetzt("Benutzername oder Passwort stimmt nicht.")
            case 403:  return uebersetzt("Dieses Konto darf das nicht.")
            case 404:  return uebersetzt("Das gibt es auf dem Server nicht.")
            case 500...599: return uebersetzt("Der Server hat einen Fehler gemeldet.")
            default:   return uebersetzt("Der Server hat mit \(status) geantwortet.")
            }
        // **Ohne den Decoder-Text.** Dort stand fuer den Nutzer
        // „keyNotFound(CodingKeys(stringValue: "Id" …" — er sagt nichts,
        // was man tun koennte. Fuer die Fehlersuche bleibt er im Fall selbst.
        case .decoding:
            return uebersetzt("Die Antwort des Servers war unverständlich.")
        case .noPlayableSource:
            return uebersetzt("Der Server nennt keine abspielbare Fassung.")
        }
    }
    // **Über `NSError`, nicht `as? URLError`.** FoundationNetworking (Android,
    // Linux, Windows) wirft ein `NSError` der Domäne `NSURLErrorDomain`; ob
    // der Cast dort greift, hängt an der Brücke. Auf Apple landet `URLError`
    // genauso hier. Ohne das stand auf Android roh
    // `Error Domain=NSURLErrorDomain Code=-1001 "(null)"` auf dem Schirm.
    let ns = fehler as NSError
    if ns.domain == NSURLErrorDomain {
        return netztext(code: ns.code, sonst: fehler)
    }
    return fehler.localizedDescription
}

/// Der Satz zu einem `NSURLErrorDomain`-Code — aus einem rohen `URLError`
/// wie aus ``JellyfinError/netz(code:)``.
private func netztext(code: Int, sonst fehler: (any Error)?) -> String {
    switch URLError.Code(rawValue: code) {
    case .notConnectedToInternet: return uebersetzt("Keine Verbindung.")
    case .timedOut:               return uebersetzt("Der Server hat nicht geantwortet.")
    case .cannotFindHost, .cannotConnectToHost:
        return uebersetzt("Unter dieser Adresse ist kein Server erreichbar.")
    case .networkConnectionLost:  return uebersetzt("Die Verbindung zum Server ist abgebrochen.")
    default:
        #if canImport(Darwin)
        // Auf Apple ist der Systemtext übersetzt und nennt die Ursache
        // (etwa ein ungültiges Zertifikat).
        return (fehler ?? URLError(URLError.Code(rawValue: code))).localizedDescription
        #else
        // Dort steht sonst der Text von curl („Recv failure: …").
        return uebersetzt("Die Verbindung zum Server ist abgebrochen.")
        #endif
    }
}
