import AVFoundation
import OSLog
import SwiftUI
import UIKit

/// Steuert, wohin sich die App drehen darf.
///
/// Auf dem **iPhone** bleibt die App im Hochformat — Bibliothek und
/// Detailseiten sind dafür gebaut. Nur der Player erlaubt Querformat, und
/// dort lässt es sich zusätzlich festnageln, damit das Bild beim Hinlegen
/// nicht kippt.
///
/// Auf dem **iPad** tut diese Klasse nichts. Das ist keine Nachlässigkeit,
/// sondern Bedingung: ohne `UIRequiresFullScreen` gilt die App als
/// multitaskingfähig, und eine multitaskingfähige App darf die Drehung nicht
/// erzwingen — sie teilt sich den Bildschirm mit einer zweiten, die ihre
/// eigene Meinung dazu hat. `requestGeometryUpdate` wird dort schlicht
/// abgelehnt. Es gilt also der Rahmen aus der Info.plist, alle vier.
@MainActor
final class Orientierung {
    static let shared = Orientierung()
    private init() {}

    /// Auf dem iPad wird nichts eingeschränkt, deshalb steht hier von
    /// Anfang an die volle Maske.
    private(set) var erlaubt: UIInterfaceOrientationMask = Orientierung.amPad
        ? .all : .portrait

    private static var amPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    func setzen(_ maske: UIInterfaceOrientationMask) {
        // Auf dem iPad bleibt `erlaubt` auf `.all` stehen. Würde hier die
        // Maske trotzdem gesetzt, meldete der App-Delegate sie an iOS
        // zurück — und die App wäre nicht mehr multitaskingfähig.
        guard !Self.amPad else { return }

        erlaubt = maske
        guard let szene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        szene.requestGeometryUpdate(.iOS(interfaceOrientations: maske))
        szene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// Player offen: darf drehen.
    func playerGeoeffnet(querformatFest: Bool) {
        setzen(querformatFest ? .landscape : [.portrait, .landscape])
    }

    /// Zurück zur App: wieder hochkant.
    func playerGeschlossen() { setzen(.portrait) }

    /// Ob sich die Sperre überhaupt anbieten lässt. Auf dem iPad nicht — ein
    /// Schalter ohne Wirkung ist schlechter als keiner.
    static var querformatSperreMoeglich: Bool { !amPad }
}

/// Ohne Delegate hat iOS keine Stelle, an der es nach der erlaubten
/// Ausrichtung fragen kann — SwiftUI allein bietet das nicht.
final class SwiftlyAppDelegate: NSObject, UIApplicationDelegate {

    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "start")

    /// Tonsitzung einmal beim Start einrichten.
    ///
    /// Vorher geschah das erst beim Abspielen — mitten in der Übergangs-
    /// animation des Players. Schlägt `setActive` dort fehl, bekommt VLCs
    /// Tonausgang eine Abtastrate von 0 („too low audio sample frequency"),
    /// liefert keine Uhr, und das Bild wartet auf ihn. Genau das stand im
    /// Protokoll.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil)
        -> Bool {
        bilderspeicherVergroessern()

        let sitzung = AVAudioSession.sharedInstance()
        do {
            // .playback + .moviePlayback: Ton läuft weiter, wenn das Fenster
            // schrumpft — sonst wäre Bild-im-Bild stumm.
            try sitzung.setCategory(.playback, mode: .moviePlayback)
            try sitzung.setActive(true)
            Self.log.info("Tonsitzung aktiv · \(Int(sitzung.sampleRate)) Hz · \(sitzung.outputNumberOfChannels) Kanäle")
        } catch {
            Self.log.error("Tonsitzung: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }
    /// Plakate im Speicher halten, statt sie beim Scrollen neu zu holen.
    ///
    /// `AsyncImage` legt nichts eigenes ab — es verlässt sich vollständig auf
    /// `URLCache.shared`, und deren Vorgabe ist mit einem halben Megabyte
    /// Arbeitsspeicher so knapp, dass schon die zweite Reihe die erste
    /// verdrängt. Beim Zurückscrollen wird dann jedes Plakat erneut vom
    /// Server geholt. 64 MB fassen ein paar hundert Plakate; das Bildmaterial
    /// auf der Platte darf großzügiger sein, es kostet nichts.
    private func bilderspeicherVergroessern() {
        // Muss vor der ersten Anfrage geschehen: `URLSession.shared` liest
        // `URLCache.shared` beim ersten Zugriff und behält, was dann dasteht.
        // `didFinishLaunching` ist der früheste Ort, an dem eigener Code
        // läuft — vor jeder Ansicht und damit vor jedem Bild.
        let speicher = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                diskCapacity: 512 * 1024 * 1024)
        URLCache.shared = speicher
        Self.log.info("Bildspeicher: \(speicher.memoryCapacity / 1024 / 1024) MB im Arbeitsspeicher")
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Orientierung.shared.erlaubt }
    }
}

/// Stellt die Wischgeste zum Zurückgehen wieder her.
///
/// Wer die Navigationsleiste ausblendet, verliert sie: iOS koppelt die Geste
/// an den Zurück-Knopf der Leiste. Ohne das geht es nur über den eigenen
/// Pfeil — und das erwartet niemand, der sonst iOS benutzt.
struct WischZurueck: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Halter()
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    private final class Halter: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            uebernehmen()
        }

        /// Auch beim Zurückkommen von einer Unterseite.
        ///
        /// Die Erkennung hat nur *einen* Bevollmächtigten. Öffnet man von hier
        /// eine weitere Seite, übernimmt deren Halter ihn; verschwindet die
        /// wieder, zeigt er ins Leere und der Wisch tat nichts mehr. Genau das
        /// war zwischen Profil und Einstellungen zu sehen.
        override func viewDidAppear(_ animiert: Bool) {
            super.viewDidAppear(animiert)
            uebernehmen()
        }

        private func uebernehmen() {
            guard let geste = navigationController?.interactivePopGestureRecognizer else { return }
            geste.delegate = self
            geste.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

/// Lässt die waagerechte Scrollfläche einer Zeile der Zurückgeste den Vortritt.
///
/// Eine `ScrollView(.horizontal)` fängt den Zug vom linken Bildschirmrand ab —
/// dann fährt die Zeile auf, statt dass die Seite zurückgeht. In UIKit ist das
/// ein Einzeiler: `require(toFail:)`. Nur muss man an beide Erkenner
/// herankommen, und dafür braucht es diesen Umweg über eine eingehängte
/// Ansicht.
///
/// Wird als Hintergrund in die Zeile gelegt; sie sucht sich von dort die
/// umgebende Scrollfläche und den Zurück-Erkenner der Navigation.
struct RandGesteVorrang: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Halter() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    private final class Halter: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            // Erst nach dem Einhängen steht die Ansichtshierarchie.
            DispatchQueue.main.async { [weak self] in self?.verknuepfen() }
        }

        private func verknuepfen() {
            guard let zurueck = navigationController?.interactivePopGestureRecognizer
            else { return }

            // Die *innerste* Scrollfläche über uns ist die der Zeile — die
            // senkrechte der Liste liegt weiter außen. Nicht über contentSize
            // suchen: die steht direkt nach dem Einhängen noch auf null.
            var ansicht: UIView? = view.superview
            while let a = ansicht {
                if let scroll = a as? UIScrollView {
                    scroll.panGestureRecognizer.require(toFail: zurueck)
                    return
                }
                ansicht = a.superview
            }
        }
    }
}
