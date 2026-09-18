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
        case let .decoding(text):
            return uebersetzt("Die Antwort des Servers war unverständlich. (\(String(text.prefix(80))))")
        case .noPlayableSource:
            return uebersetzt("Der Server nennt keine abspielbare Fassung.")
        }
    }
    if let u = fehler as? URLError {
        switch u.code {
        case .notConnectedToInternet: return uebersetzt("Keine Verbindung.")
        case .timedOut:               return uebersetzt("Der Server hat nicht geantwortet.")
        case .cannotFindHost, .cannotConnectToHost:
            return uebersetzt("Unter dieser Adresse ist kein Server erreichbar.")
        default:                      return u.localizedDescription
        }
    }
    return fehler.localizedDescription
}
