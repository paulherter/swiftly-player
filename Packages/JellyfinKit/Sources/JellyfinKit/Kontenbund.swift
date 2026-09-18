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
    public var aktives: Session { konto(aktiveKennung) ?? konten[0] }

    /// Die Server des Bundes, jeder einmal, in der Reihenfolge ihres ersten
    /// Kontos. **Seit dem 11.09.2026 können es mehrere sein** — vorher gehörte
    /// ein Bund zu genau einem Server, und wer sich an einem anderen anmeldete,
    /// fing neu an.
    public var server: [URL] {
        var gesehen = Set<String>()
        return konten.map(\.serverURL).filter { gesehen.insert(Self.kennung($0)).inserted }
    }

    /// Die Konten eines Servers, in ihrer Reihenfolge.
    public func konten(auf server: URL) -> [Session] {
        konten.filter { Self.kennung($0.serverURL) == Self.kennung(server) }
    }

    /// Ein Konto über seinen Schlüssel (`Session.kontoschluessel`) — oder,
    /// für gemerkte Bünde von vor dem zweiten Server, über die bloße
    /// Benutzerkennung.
    public func konto(_ kennung: String) -> Session? {
        konten.first { $0.kontoschluessel == kennung } ?? konten.first { $0.userID == kennung }
    }

    /// Der Server des aktiven Kontos.
    public var serverURL: URL { aktives.serverURL }

    /// Ein einzelnes Konto, wie es nach der ersten Anmeldung aussieht.
    public init(_ erstes: Session) {
        konten = [erstes]
        aktiveKennung = erstes.kontoschluessel
    }

    /// Aus gespeicherten Werten. Gibt `nil` zurück, wenn nichts da ist —
    /// ein leerer Bund ist kein Bund.
    public init?(konten: [Session], aktiv: String?) {
        guard let erstes = konten.first else { return nil }
        self.konten = konten
        let gewuenscht = aktiv.flatMap { a in
            konten.first { $0.kontoschluessel == a } ?? konten.first { $0.userID == a }
        }
        aktiveKennung = (gewuenscht ?? erstes).kontoschluessel
    }

    /// Die alte Ablage der GTK-Fassung — andere Feldnamen, dieselbe Bedeutung.
    ///
    /// **Warum das im Paket steht, obwohl es nach Plattform klingt.** Es
    /// kennt keine Pfade und keine Ablage, nur Feldnamen; das ist eine
    /// Aussage über unsere eigenen Daten von früher, und die ist ohne
    /// Simulator prüfbar. Die GTK-Schicht hat kein Testziel — dort wäre
    /// genau diese Umsetzung ungeprüft geblieben.
    ///
    /// **Und sie war es**: am 05.09.2026 wurde die alte Datei roh an
    /// ``ausAblage(bund:einzelne:)`` gereicht, die sie als ``Session`` lesen
    /// will. Drei von vier Schlüsseln passen nicht, `try?` verschluckt den
    /// Fehlschlag, und **jeder bestehende Nutzer stand nach dem
    /// Aktualisieren vor dem Anmeldeschirm.** Auf einem Rechner, der die
    /// neue Ablage schon hat, ist davon nichts zu sehen; aufgefallen ist es
    /// nur, weil eine Prüfmaschine den alten Stand trug.
    ///
    /// `servername` fällt weg — er steht in der neuen Ablage nicht und wird
    /// beim ersten Verbinden ohnehin frisch geholt.
    public static func ausAlterGtkAblage(_ daten: Data) -> Session? {
        struct Abgelegt: Decodable {
            let serverURL: URL
            let token: String
            let benutzerID: String
            let benutzername: String
        }
        guard let a = try? JSONDecoder().decode(Abgelegt.self, from: daten) else { return nil }
        return Session(accessToken: a.token, userID: a.benutzerID,
                       userName: a.benutzername, serverURL: a.serverURL)
    }

    /// Ein Konto aufnehmen — und dabei sagen, ob es ein **Wechsel** war.
    ///
    /// **Warum das hier steht und nicht bei den Aufrufern.** Beide Fassungen
    /// leiteten es sich selbst her: „war vorher schon ein Bund da, also ist
    /// es ein Wechsel" — einmal in `AppModel.sitzungUebernehmen`, einmal in
    /// der GTK-Fassung. Zwei Herleitungen derselben Regel, und an dieser
    /// Antwort hängt viel: ob die Startseite geräumt wird, ob die
    /// Fernsteuerung neu aufgebaut wird, ob ein zweites Laden angestossen
    /// wird. Wer sie falsch herleitet, bekommt genau die Fehler, die uns den
    /// 05.09.2026 gekostet haben.
    ///
    /// **Ein anderer Server ist kein Wechsel, sondern ein Neuanfang.** Ein
    /// Bund gehört zu genau einem Server; passt die Sitzung nicht dazu,
    /// entsteht ein neuer Bund, und das vorige Konto ist keins mehr.
    public static func aufnehmen(_ neu: Session,
                                 in vorhanden: Kontenbund?) -> (bund: Kontenbund,
                                                                warWechsel: Bool) {
        // Ein anderer Server kommt dazu wie ein weiteres Konto — er ersetzt
        // den Bund nicht mehr.
        guard var bund = vorhanden else {
            return (Kontenbund(neu), false)
        }
        bund.aufnehmen(neu)
        return (bund, true)
    }

    /// Aus dem, was in der Ablage liegt — mit der Übernahme aus der Zeit vor
    /// den Mehrfachkonten.
    ///
    /// **Auch das stand zweimal**, in `AppModel.bundLaden()` und in der
    /// GTK-Fassung: erst den Bund versuchen, sonst die einzelne Sitzung von
    /// früher, sonst gar nichts. Dass die alte Einzelsitzung liegen bleibt
    /// statt gelöscht zu werden, ist Absicht — wer noch einmal eine ältere
    /// Fassung startet, soll nicht plötzlich abgemeldet sein.
    ///
    /// **Wo die Daten herkommen, bleibt Sache der Plattform** (Schlüsselbund,
    /// Datei, Registrierung). Hier steht nur, was sie bedeuten.
    public static func ausAblage(bund: Data?, einzelne: Data?) -> Kontenbund? {
        let leser = JSONDecoder()
        if let bund, let b = try? leser.decode(Kontenbund.self, from: bund) {
            return b
        }
        guard let einzelne,
              let alt = try? leser.decode(Session.self, from: einzelne) else { return nil }
        return Kontenbund(alt)
    }

    /// Nimmt ein Konto auf und macht es zum aktiven.
    ///
    /// **Dasselbe Konto zweimal gibt es nicht.** Meldet sich jemand erneut
    /// an — weil das Merkmal abgelaufen war —, ersetzt die neue Sitzung die
    /// alte **an ihrer Stelle**. Anhängen würde denselben Namen zweimal in
    /// den Streifen setzen, und der Nutzer müsste raten, welcher der beiden
    /// noch trägt.
    public mutating func aufnehmen(_ neu: Session) {
        if let i = konten.firstIndex(where: { $0.kontoschluessel == neu.kontoschluessel }) {
            konten[i] = neu
        } else {
            konten.append(neu)
        }
        aktiveKennung = neu.kontoschluessel
    }

    /// Schaltet auf ein vorhandenes Konto um. Unbekannte Kennungen ändern
    /// nichts — lieber angemeldet bleiben als ins Leere schalten.
    public mutating func wechseln(zu kennung: String) {
        guard let ziel = konto(kennung) else { return }
        aktiveKennung = ziel.kontoschluessel
    }

    /// Entfernt ein Konto und gibt zurück, was übrig bleibt.
    ///
    /// **Abmelden trifft nur das eine Konto.** War es das aktive, gilt
    /// danach das folgende — und ist es das letzte gewesen, kommt `nil`
    /// zurück: dann ist die App abgemeldet und die Anmeldung fängt von vorn
    /// an. Alle Konten auf einmal zu entfernen, wäre eine zweite Bedeutung
    /// für denselben Knopf.
    public func entfernt(_ kennung: String) -> Kontenbund? {
        guard let weg = konto(kennung),
              let i = konten.firstIndex(where: { $0.kontoschluessel == weg.kontoschluessel })
        else { return self }
        var rest = konten
        rest.remove(at: i)
        guard !rest.isEmpty else { return nil }
        // Das nächste in der Reihe, sonst das letzte davor — so wandert der
        // Streifen nicht an den Anfang zurück, nur weil in der Mitte eines
        // wegfiel.
        let nachfolger = rest[min(i, rest.count - 1)]
        let warAktiv = weg.kontoschluessel == aktives.kontoschluessel
        let neuAktiv = warAktiv ? nachfolger.kontoschluessel : aktives.kontoschluessel
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

extension Session {
    /// **Server und Benutzer zusammen.** Ein Konto ist erst durch seinen
    /// Server eindeutig: dieselbe Benutzerkennung auf zwei Servern — etwa ein
    /// umgezogener Server — sind zwei Konten.
    public var kontoschluessel: String { Kontenbund.kennung(serverURL) + "|" + userID }
}
