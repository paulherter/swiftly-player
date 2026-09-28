#if DEBUG && canImport(Darwin)
import Foundation

/// **Nur für Selbsttests: kein Netz, ohne das Netz abzuschalten.**
///
/// Der Offline-Selbsttest (`-offlinelauf`) muss prüfen, was eine App ohne
/// Server tut — im Simulator, ohne Flugmodus und ohne jemanden, der ein Kabel
/// zieht. Dieses Protokoll hängt in ``Foundation/URLSession/ortsnetzfaehig``
/// und lässt, solange ``an`` gilt, jede Anfrage sofort mit
/// `notConnectedToInternet` scheitern — genau der Fehler, den das Gerät im
/// Flugzeug liefert. Alles andere (Bilder über `URLSession.shared`, die
/// Hintergrundsitzung der Downloads) bleibt unberührt.
///
/// Im Release-Bau gibt es die Klasse nicht.
public final class Netzsperre: URLProtocol, @unchecked Sendable {

    private static let schloss = NSLock()
    nonisolated(unsafe) private static var zu = false

    /// Umschalten mitten im Lauf ist gewollt: so misst der Selbsttest auch
    /// das Wiederverbinden.
    public static var an: Bool {
        get { schloss.lock(); defer { schloss.unlock() }; return zu }
        set { schloss.lock(); zu = newValue; schloss.unlock() }
    }

    override public class func canInit(with request: URLRequest) -> Bool { an }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override public func stopLoading() {}
}
#endif
