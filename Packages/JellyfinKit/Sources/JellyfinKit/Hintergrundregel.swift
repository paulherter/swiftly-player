import Foundation

/// Ob die Wiedergabe angehalten wird, wenn die App in den Hintergrund geht.
///
/// **Die App erklaert `UIBackgroundModes: audio`** — sie muss das, sonst gaebe
/// es kein Bild-im-Bild und keinen Sperrbildschirm. Der Preis: ohne eigenes
/// Zutun laeuft ein Video weiter, wenn der Zuschauer die App wegwischt. Er
/// hoert es nicht einmal unbedingt, wenn der Ton leise steht — und findet
/// beim Zurueckkommen eine Folge vor, die weit weiter oder als gesehen
/// markiert ist.
///
/// **Swiftfin hatte genau das zweimal** (jellyfin/Swiftfin#871, spaeter als
/// Rueckfall #2175): erst unbemerktes Weiterlaufen mit falschem Fortschritt,
/// dann dieselbe Sache nach einem Umbau erneut. Bei uns ist die Luecke am
/// 04.09.2026 beim Gegenlesen aufgefallen — `scenePhase` wird in der
/// iOS-Ansicht zwar beobachtet, aber nur fuer eine Geometriemessung.
///
/// **Zwei Faelle duerfen nicht angehalten werden**, und sie sind der ganze
/// Grund, warum diese Regel nicht `if background { pause() }` heisst:
///
/// - **Bild-im-Bild.** Die App ist dann im Hintergrund, das Fenster laeuft
///   aber sichtbar weiter. Anhalten waere der Fehler, den Bild-im-Bild
///   verhindern soll — und PiP ist der Grund, aus dem es diese App gibt.
/// - **Ausgabe auf einem anderen Geraet.** Laeuft das Bild ueber AirPlay auf
///   dem Fernseher, hat der Zuschauer das Telefon absichtlich weggelegt.
///
/// Fortgesetzt wird beim Zurueckkommen **nicht**. Das ist Absicht: wer
/// zurueckkommt, will oft erst sehen, wo er ist. So halten es Apples eigene
/// Videoapp und Netflix auch, und ein Player, der von selbst losspielt,
/// ueberrascht mehr als einer, der wartet.
public enum Hintergrundregel {

    /// - Parameters:
    ///   - imKleinenFenster: Bild-im-Bild laeuft.
    ///   - aufAnderemGeraet: Die Ausgabe geht ueber AirPlay o. ae. woanders hin.
    ///   - laeuft: Es wird ueberhaupt gerade abgespielt.
    /// - Returns: `true`, wenn beim Wechsel in den Hintergrund angehalten
    ///   werden soll.
    public static func anhalten(imKleinenFenster: Bool,
                                aufAnderemGeraet: Bool,
                                laeuft: Bool) -> Bool {
        guard laeuft else { return false }
        return !imKleinenFenster && !aufAnderemGeraet
    }
}
