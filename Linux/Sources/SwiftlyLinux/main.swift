import Adwaita
import Foundation
import JellyfinKit

/// **Der erste sichtbare Beweis, dass der Weg traegt.**
///
/// Ein Fenster, eine Adresse, ein Knopf — und dahinter derselbe
/// `JellyfinClient`, den iPhone, iPad, Apple TV und Mac benutzen. Kein
/// nachgebauter Client, keine zweite Wahrheit: `publicSystemInfo()` ist
/// dieselbe Zeile Code, die auf allen anderen Plattformen laeuft.
@main
struct SwiftlyLinux: App {
    let id = "de.paulherter.swiftly"
    var app: GTUIApp!

    var scene: Scene {
        Window(id: "haupt") { window in
            Anmeldung(fenster: window)
                .topToolbar {
                    HeaderBar.empty()
                }
        }
        .defaultSize(width: 520, height: 360)
        .title("Swiftly")
    }
}

struct Anmeldung: View {
    var fenster: GTUIWindow

    @State private var adresse = "https://tv.paulherter.de"
    @State private var stand = "Noch nichts versucht."
    @State private var laeuft = false

    var view: Body {
        VStack {
            Text("Swiftly")
                .title1()
                .padding(10)

            Text("Wo steht dein Jellyfin?")
                .padding(4)

            Form {
                EntryRow("Serveradresse", text: $adresse)
                    .onSubmit { verbinden() }
            }
            .padding(10)

            Button(laeuft ? "Verbinde …" : "Verbinden") {
                verbinden()
            }
            .suggested()
            .insensitive(laeuft)
            .padding(10)

            Text(stand)
                .padding(10)
                .wrap()
        }
        .valign(.center)
        .padding(20)
    }

    /// Der Aufruf geht über denselben Client wie auf allen Apple-Plattformen.
    func verbinden() {
        guard !laeuft else { return }
        guard let url = AppModelURLNormalizer.normalize(adresse) else {
            stand = "Diese Adresse ergibt keinen Sinn."
            return
        }
        laeuft = true
        stand = "Frage \(url.host() ?? url.absoluteString) …"

        Task {
            let client = JellyfinClient(baseURL: url,
                                        deviceID: "linux-probe",
                                        deviceName: "Swiftly auf Linux")
            do {
                let info = try await client.publicSystemInfo()
                let name = info.serverName ?? "ohne Namen"
                let fassung = info.version ?? "?"
                Idle {
                    stand = "Verbunden mit \(name), Jellyfin \(fassung)."
                    laeuft = false
                }
            } catch {
                Idle {
                    stand = "Ging nicht: \(error.localizedDescription)"
                    laeuft = false
                }
            }
        }
    }
}
