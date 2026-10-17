import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **What the user is told instead of "Error Domain=… Code=-1004".**
///
/// `localizedDescription` of a `URLError` is usable; that of a hand-built
/// error rarely is, since it shows the type name.
///
/// Lives in the package so that the Linux version can reach it as well; there,
/// every failed sign-in would otherwise show a raw `error.localizedDescription`.
/// **Error texts name the cause, not just "something went wrong".**
public func readableError(_ error: any Error) -> String {
    if let j = error as? JellyfinError {
        switch j {
        case let .network(code):           return networkText(code: code, otherwise: nil)
        case let .certificate(reason):    return certificateText(reason)
        case let .transport(text):      return text
        case .notAuthenticated:         return translated("Nicht angemeldet.")
        case .twoFactor:
            return translated("Dein Server will eine Zwei-Faktor-Bestätigung. Gib dieses Gerät im Browser frei oder melde dich mit einem App-Passwort an.")
        case .invalidServerURL:         return translated("Die Adresse konnte nicht gelesen werden.")
        case let .http(status, _):
            switch status {
            case 401:  return translated("Benutzername oder Passwort stimmt nicht.")
            case 403:  return translated("Dieses Konto darf das nicht.")
            case 404:  return translated("Das gibt es auf dem Server nicht.")
            case 500...599: return translated("Der Server hat einen Fehler gemeldet.")
            default:   return translated("Der Server hat mit \(status) geantwortet.")
            }
        // **Without the decoder text.** It read
        // "keyNotFound(CodingKeys(stringValue: "Id" …" for the user, which says nothing
        // they could act on. For debugging it stays in the case itself.
        case .decoding:
            return translated("Die Antwort des Servers war unverständlich.")
        case .noPlayableSource:
            return translated("Der Server nennt keine abspielbare Fassung.")
        case let .playbackRejected(reason):
            switch reason {
            case "NotAllowed":
                return translated("Der Server lässt dieses Konto den Titel nicht abspielen.")
            case "RateLimitExceeded":
                return translated("Der Server lässt gerade keine weitere Wiedergabe zu. Die Bandbreite für dieses Konto ist ausgeschöpft.")
            default:
                return translated("Der Server findet keine Fassung, die er an dieses Gerät schicken darf. Meist ist Umwandeln für dieses Konto abgeschaltet.")
            }
        }
    }
    // **Via `NSError`, not `as? URLError`.** FoundationNetworking (Android,
    // Linux, Windows) throws an `NSError` of domain `NSURLErrorDomain`; whether
    // the cast works there depends on the bridge. On Apple, `URLError` ends up
    // here the same way. Without this, Android showed the raw
    // `Error Domain=NSURLErrorDomain Code=-1001 "(null)"` on screen.
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        if let reason = certificateReason(code: ns.code, text: error.localizedDescription) {
            return certificateText(reason)
        }
        return networkText(code: ns.code, otherwise: error)
    }
    return error.localizedDescription
}

/// The sentence for an `NSURLErrorDomain` code, from a raw `URLError` as well
/// as from ``JellyfinError/netz(code:)``.
private func networkText(code: Int, otherwise error: (any Error)?) -> String {
    switch URLError.Code(rawValue: code) {
    case .notConnectedToInternet: return translated("Keine Verbindung.")
    case .timedOut:               return translated("Der Server hat nicht geantwortet.")
    case .cannotFindHost, .cannotConnectToHost:
        return translated("Unter dieser Adresse ist kein Server erreichbar.")
    case .networkConnectionLost:  return translated("Die Verbindung zum Server ist abgebrochen.")
    default:
        #if canImport(Darwin)
        // On Apple the system text is translated and names the cause.
        return (error ?? URLError(URLError.Code(rawValue: code))).localizedDescription
        #else
        // **This used to say "cancelled", which was wrong.** On Android, Linux and
        // Windows every TLS error landed in this branch (they all arrive there as code
        // `-1`, see ``zertifikatsgrund(code:text:)``), and the sentence claimed a cause
        // that was not true: the connection never existed, it did not drop. With a
        // self-signed certificate it said "The connection to the server dropped."
        // (seen on the Android emulator).
        //
        // The certificate cases are separate now; what still arrives here is
        // really unknown, and the sentence claims nothing. The text from curl is
        // not shown: it is English and technical ("Recv failure:
        // Connection reset by peer").
        return translated("Die Verbindung zum Server hat nicht geklappt.")
        #endif
    }
}

/// **What is wrong with the server's certificate**, or `nil` if that is not
/// the cause.
///
/// Two paths, because there are two Foundations:
///
/// - **Apple** has its own code for each cause (`-1200` to `-1206`).
/// - **Android, Linux, Windows** do not. `URLSession` sits on libcurl there,
///   and **every** TLS error arrives as `NSURLErrorDomain` **code `-1`**
///   (`NSURLErrorUnknown`); the cause is only in curl's English sentence.
///   That is why the sentence is read.
///
/// **Measured** on the Android emulator (arm64, Swift 6.3.3, a test program
/// against badssl.com):
///
/// | Adresse | Code | Text |
/// |---|---|---|
/// | `self-signed.badssl.com`     | `-1` | SSL certificate problem: self signed certificate |
/// | `expired.badssl.com`         | `-1` | SSL certificate problem: certificate has expired |
/// | `wrong.host.badssl.com`      | `-1` | SSL: no alternative certificate subject name matches target hostname |
/// | `untrusted-root.badssl.com`  | `-1` | SSL certificate problem: self signed certificate in certificate chain |
///
/// `-1001`, `-1003` and `-1004` arrived correctly in the same measurement,
/// so the cases in ``netztext(code:otherwise:)`` work there; only the TLS cases
/// do not.
func certificateReason(code: Int, text: String) -> CertificateReason? {
    switch URLError.Code(rawValue: code) {
    case .serverCertificateHasBadDate:  return .expired
    case .serverCertificateNotYetValid: return .appliesNotYet
    case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
        return .notTrusted
    case .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
        return .otherwise
    default:
        let k = text.lowercased()
        // **First check that the sentence is about TLS at all.** Otherwise any error
        // would stick to a word like "expired".
        guard k.contains("ssl") || k.contains("tls") || k.contains("certificate")
        else { return nil }
        // Order: the more specific first. "certificate has expired" also contains
        // "certificate".
        if k.contains("not yet valid")   { return .appliesNotYet }
        if k.contains("expired")         { return .expired }
        if k.contains("subject name") || k.contains("hostname") { return .otherAddress }
        if k.contains("self signed") || k.contains("self-signed")
            || k.contains("unable to get local issuer") || k.contains("unable to get issuer")
            || k.contains("verify failed") || k.contains("not trusted") { return .notTrusted }
        return .otherwise
    }
}

/// The sentence for the user, one per cause: "invalid certificate" alone does
/// not say whether the clock is wrong or a different server is answering.
private func certificateText(_ reason: CertificateReason) -> String {
    switch reason {
    case .notTrusted: return translated("Dem Zertifikat des Servers wird nicht vertraut.")
    case .expired:    return translated("Das Zertifikat des Servers ist abgelaufen.")
    case .appliesNotYet: return translated("Das Zertifikat des Servers gilt noch nicht.")
    case .otherAddress: return translated("Das Zertifikat des Servers gehört zu einer anderen Adresse.")
    case .otherwise:         return translated("Die verschlüsselte Verbindung kam nicht zustande.")
    }
}
