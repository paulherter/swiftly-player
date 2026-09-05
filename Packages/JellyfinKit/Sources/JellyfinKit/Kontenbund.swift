import Foundation

/// Mehrere Jellyfin-Konten auf demselben Server, und welches gerade gilt.
///
/// **Warum ein eigener Typ und nicht einfach ein Array im Zustandshalter.**
/// An dieser Sammlung hängen lauter kleine Regeln, die man beim ersten
/// Hinschauen für selbstverständlich hält und die trotzdem jede für sich
/// falsch gehen können: was passiert, wenn sich dasselbe Konto ein zweites
/// Mal anmeldet; welches Konto gilt, nachdem das aktive entfernt wurde;
/// was mit einer alten Einzelsitzung geschieht, die noch aus der Zeit vor
/// dieser Funktion stammt. Solche Regeln gehören dahin, wo sie ohne
/// Simulator geprüft werden können — und nicht in eine Ansicht.
///
/// **Ein Bund gehört zu genau einem Server.** Wer den Server wechselt,
/// fängt neu an; alles andere wäre eine zweite Bedeutung für dieselbe
/// Sammlung, und die erste, die sie nachher liest, versteht sie falsch.
public struct Kontenbund: Codable, Sendable, Equatable {

    /// Die Konten in der Reihenfolge, in der sie hinzugekommen sind. Genau
    /// so stehen sie später im Streifen über der Profilseite.
    public private(set) var konten: [Session]

    /// Die Kennung des Kontos, mit dem die App gerade angemeldet ist.
    public private(set) var aktiveKennung: String

    /// Das aktive Konto.
    ///
    /// **Nie optional nach außen.** Ein Bund ohne aktives Konto ist kein
    /// Zustand, den es geben soll; die Anlässe, bei denen er entstehen
    /// könnte, sind hier drin abgefangen. Zeigt der Zeiger trotzdem ins
    /// Leere — etwa weil von Hand am Schlüsselbund gedreht wurde —, gilt
    /// das erste Konto, statt die App ohne Sitzung dastehen zu lassen.
    public var aktives: Session {
        konten.first { $0.userID == aktiveKennung } ?? konten[0]
    }

    public var serverURL: URL { konten[0].serverURL }

    /// Ein einzelnes Konto, wie es nach der ersten Anmeldung aussieht.
    public init(_ erstes: Session) {
        konten = [erstes]
        aktiveKennung = erstes.userID
    }

    /// Aus gespeicherten Werten. Gibt `nil` zurück, wenn nichts da ist —
    /// ein leerer Bund ist kein Bund.
    public init?(konten: [Session], aktiv: String?) {
        guard let erstes = konten.first else { return nil }
        self.konten = konten
        let gewuenscht = aktiv ?? erstes.userID
        aktiveKennung = konten.contains { $0.userID == gewuenscht } ? gewuenscht
                                                                   : erstes.userID
    }

    /// Nimmt ein Konto auf und macht es zum aktiven.
    ///
    /// **Dasselbe Konto zweimal gibt es nicht.** Meldet sich jemand erneut
    /// an — weil das Merkmal abgelaufen war —, ersetzt die neue Sitzung die
    /// alte **an ihrer Stelle**. Anhängen würde denselben Namen zweimal in
    /// den Streifen setzen, und der Nutzer müsste raten, welcher der beiden
    /// noch trägt.
    public mutating func aufnehmen(_ neu: Session) {
        if let i = konten.firstIndex(where: { $0.userID == neu.userID }) {
            konten[i] = neu
        } else {
            konten.append(neu)
        }
        aktiveKennung = neu.userID
    }

    /// Schaltet auf ein vorhandenes Konto um. Unbekannte Kennungen ändern
    /// nichts — lieber angemeldet bleiben als ins Leere schalten.
    public mutating func wechseln(zu kennung: String) {
        guard konten.contains(where: { $0.userID == kennung }) else { return }
        aktiveKennung = kennung
    }

    /// Entfernt ein Konto und gibt zurück, was übrig bleibt.
    ///
    /// **Abmelden trifft nur das eine Konto.** War es das aktive, gilt
    /// danach das folgende — und ist es das letzte gewesen, kommt `nil`
    /// zurück: dann ist die App abgemeldet und die Anmeldung fängt von vorn
    /// an. Alle Konten auf einmal zu entfernen, wäre eine zweite Bedeutung
    /// für denselben Knopf.
    public func entfernt(_ kennung: String) -> Kontenbund? {
        var rest = konten
        guard let i = rest.firstIndex(where: { $0.userID == kennung }) else { return self }
        rest.remove(at: i)
        guard !rest.isEmpty else { return nil }
        // Das nächste in der Reihe, sonst das letzte davor — so wandert der
        // Streifen nicht an den Anfang zurück, nur weil in der Mitte eines
        // wegfiel.
        let nachfolger = rest[min(i, rest.count - 1)]
        let neuAktiv = kennung == aktiveKennung ? nachfolger.userID : aktiveKennung
        return Kontenbund(konten: rest, aktiv: neuAktiv)
    }

    /// Gehört das Konto auf denselben Server wie der Bund?
    ///
    /// Der Vergleich läuft über die Adresse ohne abschließenden Schrägstrich:
    /// `https://tv.example.de` und `https://tv.example.de/` sind derselbe
    /// Server, und beide Schreibweisen kommen vor — die eine aus der
    /// Eingabe des Nutzers, die andere aus unserer Normalisierung.
    public func passtZumServer(_ s: Session) -> Bool {
        Self.kennung(s.serverURL) == Self.kennung(serverURL)
    }

    static func kennung(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
