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
        case let .zertifikat(grund):    return zertifikatstext(grund)
        case let .transport(text):      return text
        case .notAuthenticated:         return uebersetzt("Nicht angemeldet.")
        case .zweiFaktor:
            return uebersetzt("Dein Server will eine Zwei-Faktor-Bestätigung. Gib dieses Gerät im Browser frei oder melde dich mit einem App-Passwort an.")
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
        if let grund = zertifikatsgrund(code: ns.code, text: fehler.localizedDescription) {
            return zertifikatstext(grund)
        }
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
        // Auf Apple ist der Systemtext übersetzt und nennt die Ursache.
        return (fehler ?? URLError(URLError.Code(rawValue: code))).localizedDescription
        #else
        // **Hier stand „abgebrochen", und das war gelogen.** In diesen Zweig
        // fiel auf Android, Linux und Windows jeder TLS-Fehler (alle kommen
        // dort als Code `-1`, siehe ``zertifikatsgrund(code:text:)``), und der
        // Satz behauptete eine Ursache, die nicht stimmte: die Verbindung war
        // nie da, sie brach nicht ab. Bei einem selbst ausgestellten
        // Zertifikat stand so „The connection to the server dropped."
        // (gemessen 17.09.2026 auf dem Android-Emulator).
        //
        // Die Zertifikatsfälle sind jetzt eigene; was hier noch ankommt, ist
        // wirklich unbekannt, und der Satz behauptet nichts mehr. Der Text von
        // curl steht nicht da: er ist englisch und technisch („Recv failure:
        // Connection reset by peer").
        return uebersetzt("Die Verbindung zum Server hat nicht geklappt.")
        #endif
    }
}

/// **Was am Zertifikat des Servers nicht stimmt** — oder `nil`, wenn es nicht
/// daran liegt.
///
/// Zwei Wege, weil es zwei Foundations gibt:
///
/// - **Apple** hat für jede Ursache einen eigenen Code (`-1200` bis `-1206`).
/// - **Android, Linux, Windows** haben sie nicht. Dort steckt hinter
///   `URLSession` libcurl, und **jeder** TLS-Fehler kommt als
///   `NSURLErrorDomain` **Code `-1`** an (`NSURLErrorUnknown`); die Ursache
///   steht allein im englischen Satz von curl. Deshalb wird der Satz gelesen.
///
/// **Gemessen** am 17.09.2026 auf dem Android-Emulator (arm64, Swift 6.3.3,
/// ein eigenes Testprogramm gegen badssl.com):
///
/// | Adresse | Code | Text |
/// |---|---|---|
/// | `self-signed.badssl.com`     | `-1` | SSL certificate problem: self signed certificate |
/// | `expired.badssl.com`         | `-1` | SSL certificate problem: certificate has expired |
/// | `wrong.host.badssl.com`      | `-1` | SSL: no alternative certificate subject name matches target hostname |
/// | `untrusted-root.badssl.com`  | `-1` | SSL certificate problem: self signed certificate in certificate chain |
///
/// `-1001`, `-1003` und `-1004` kamen in derselben Messung richtig an — die
/// Fälle in ``netztext(code:sonst:)`` greifen dort also, nur die TLS-Fälle
/// nicht.
func zertifikatsgrund(code: Int, text: String) -> Zertifikatsgrund? {
    switch URLError.Code(rawValue: code) {
    case .serverCertificateHasBadDate:  return .abgelaufen
    case .serverCertificateNotYetValid: return .giltNochNicht
    case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
        return .nichtVertraut
    case .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
        return .sonst
    default:
        let k = text.lowercased()
        // **Erst prüfen, ob der Satz überhaupt von TLS redet.** Sonst bliebe
        // ein beliebiger Fehler an einem Wort wie „expired" hängen.
        guard k.contains("ssl") || k.contains("tls") || k.contains("certificate")
        else { return nil }
        // Reihenfolge: das Genauere zuerst. „certificate has expired" enthält
        // auch „certificate".
        if k.contains("not yet valid")   { return .giltNochNicht }
        if k.contains("expired")         { return .abgelaufen }
        if k.contains("subject name") || k.contains("hostname") { return .andereAdresse }
        if k.contains("self signed") || k.contains("self-signed")
            || k.contains("unable to get local issuer") || k.contains("unable to get issuer")
            || k.contains("verify failed") || k.contains("not trusted") { return .nichtVertraut }
        return .sonst
    }
}

/// Der Satz für den Nutzer. Einer je Ursache: „ungültiges Zertifikat" allein
/// sagt nicht, ob die Uhr falsch geht oder ein anderer Server antwortet.
private func zertifikatstext(_ grund: Zertifikatsgrund) -> String {
    switch grund {
    case .nichtVertraut: return uebersetzt("Dem Zertifikat des Servers wird nicht vertraut.")
    case .abgelaufen:    return uebersetzt("Das Zertifikat des Servers ist abgelaufen.")
    case .giltNochNicht: return uebersetzt("Das Zertifikat des Servers gilt noch nicht.")
    case .andereAdresse: return uebersetzt("Das Zertifikat des Servers gehört zu einer anderen Adresse.")
    case .sonst:         return uebersetzt("Die verschlüsselte Verbindung kam nicht zustande.")
    }
}
