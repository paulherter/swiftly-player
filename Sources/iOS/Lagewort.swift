import UIKit

/// Der Zustand der App als lesbares Wort, fuer das Protokoll.
///
/// **Nur zur Fehlersuche.** Am 08.09.2026 pausierte die Wiedergabe, sobald
/// die Mitteilungszentrale heruntergezogen wurde, und zweimal wurde auf die
/// falsche Quelle getippt: erst auf eine Tonunterbrechung (im Protokoll steht
/// keine), dann auf `scenePhase`. Die Umstellung auf
/// `didEnterBackgroundNotification` half auch nicht -- die feuert dabei
/// offenbar wirklich. Bevor eine dritte Regel entsteht, soll dastehen, was
/// iOS meldet und in welchem Zustand die App dabei ist.
enum Lagewort {
    @MainActor static var jetzt: String {
        switch UIApplication.shared.applicationState {
        case .active: "aktiv"
        case .inactive: "untaetig"
        case .background: "hintergrund"
        @unknown default: "?"
        }
    }
}
