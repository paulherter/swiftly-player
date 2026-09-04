import CGtk
import Foundation

/// **GTK kennt keine Vererbung, es hat Zeigerkunst.**
///
/// Jede Funktion nimmt den Typ, für den sie gedacht ist — `gtk_box_append`
/// will eine Box, `gtk_button_set_label` einen Knopf —, aber jedes `*_new()`
/// gibt ein `GtkWidget*` zurück. In C erledigen Makros das Umdeuten; in Swift
/// gibt es die nicht, also stehen die Umwandlungen hier einmal beisammen.
///
/// **Welche Typen Swift benennen kann, ist nicht zu erraten:** `GtkBox`,
/// `GtkButton` und `GtkEntry` ja, `GtkLabel` und `GtkEditable` nein — die
/// kommen als undurchsichtige Zeiger herein. Herausgefunden am 04.09.2026,
/// indem der Übersetzer selbst nach den erwarteten Typen gefragt wurde,
/// nachdem drei Anläufe daran gescheitert waren. Wer hier etwas ergänzt,
/// fragt ihn am besten genauso, statt zu raten.
typealias Widget = UnsafeMutablePointer<GtkWidget>

@inline(__always) func alsBox(_ w: Widget!) -> UnsafeMutablePointer<GtkBox>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkBox>.self)
}
@inline(__always) func alsKnopf(_ w: Widget!) -> UnsafeMutablePointer<GtkButton>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkButton>.self)
}
@inline(__always) func alsFeld(_ w: Widget!) -> UnsafeMutablePointer<GtkEntry>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkEntry>.self)
}
@inline(__always) func alsFenster(_ w: Widget!) -> UnsafeMutablePointer<GtkWindow>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkWindow>.self)
}
@inline(__always) func alsTafel(_ w: Widget!) -> UnsafeMutablePointer<GtkPopover>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkPopover>.self)
}
@inline(__always) func alsSkala(_ w: Widget!) -> UnsafeMutablePointer<GtkScale>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkScale>.self)
}
@inline(__always) func alsBereich(_ w: Widget!) -> UnsafeMutablePointer<GtkRange>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkRange>.self)
}
@inline(__always) func alsFeld2(_ w: Widget!) -> UnsafeMutablePointer<GtkFixed>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkFixed>.self)
}

// MARK: - Bausteine

/// Ein senkrechter oder waagerechter Stapel mit Abstand.
func stapel(_ richtung: GtkOrientation, abstand: Int32 = 0) -> Widget! {
    gtk_box_new(richtung, abstand)
}

func anhaengen(_ eltern: Widget!, _ kind: Widget!) {
    gtk_box_append(alsBox(eltern), kind)
}

/// Leert eine Box. GTK bietet dafür nichts Fertiges — man muss sich von vorn
/// durchhangeln, bis kein Kind mehr da ist.
func leeren(_ box: Widget!) {
    while let kind = gtk_widget_get_first_child(box) {
        gtk_box_remove(alsBox(box), kind)
    }
}

func beschriftung(_ text: String, stil: String? = nil, umbruch: Bool = false) -> Widget! {
    let l: Widget! = gtk_label_new(text)
    if let stil { gtk_widget_add_css_class(l, stil) }
    if umbruch {
        gtk_label_set_wrap(OpaquePointer(l), 1)
        gtk_label_set_justify(OpaquePointer(l), GTK_JUSTIFY_CENTER)
    }
    return l
}

func raender(_ w: Widget!, _ alle: Int32) {
    gtk_widget_set_margin_top(w, alle)
    gtk_widget_set_margin_bottom(w, alle)
    gtk_widget_set_margin_start(w, alle)
    gtk_widget_set_margin_end(w, alle)
}

// MARK: - Rückrufe mit Zustand

/// **Ein C-Rückruf kann nichts einfangen.**
///
/// Er ist ein nackter Funktionszeiger. Wer ihm etwas mitgeben will, reicht
/// einen Zeiger auf ein Objekt durch und packt ihn drüben wieder aus. Diese
/// Hülle nimmt einem das ab: sie hält den Swift-Abschluss am Leben, bis GTK
/// ihn nicht mehr braucht.
final class Auftrag {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
}

nonisolated(unsafe) let auftragAlsSignalOeffentlich: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> Void = { _, daten in
    guard let daten else { return }
    Unmanaged<Auftrag>.fromOpaque(daten).takeUnretainedValue().block()
}

nonisolated(unsafe) let auftragFreigebenOeffentlich: @convention(c) (gpointer?, UnsafeMutablePointer<_GClosure>?) -> Void = { daten, _ in
    guard let daten else { return }
    Unmanaged<Auftrag>.fromOpaque(daten).release()
}

/// Verbindet ein Signal mit einem Swift-Abschluss.
///
/// `g_signal_connect` ist ein Makro und in Swift unsichtbar; darunter liegt
/// `g_signal_connect_data`. Der Abschluss wird festgehalten und wieder
/// freigegeben, wenn GTK das Signal löst — sonst wäre er nach dem nächsten
/// Aufräumen ein Zeiger ins Leere.
///
/// **Nur für Signale ohne eigene Argumente.** Der Rückruf unten nimmt zwei
/// Zeiger: den Sender und die Nutzdaten. Ein Signal, das dazwischen etwas
/// mitgibt, schiebt die Nutzdaten eine Stelle weiter — und dann liest der
/// Rückruf dessen Wert als Zeiger.
///
/// Genau so ist die App am 04.09.2026 abgestürzt, als „Bad pointer dereference
/// at 0x8". Wer ein Signal mit Argumenten braucht, schreibt einen eigenen
/// Rückruf mit passender Form — siehe ``beiZeiger`` für „enter", das x und y
/// mitbringt.
func beiSignal(_ ziel: Widget!, _ name: String, _ block: @escaping () -> Void) {
    let auftrag = Unmanaged.passRetained(Auftrag(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(ziel), name,
                          unsafeBitCast(auftragAlsSignalOeffentlich, to: GCallback.self),
                          auftrag, auftragFreigebenOeffentlich, GConnectFlags(rawValue: 0))
}

/// Dasselbe für etwas, das kein Widget ist — eine `GtkAdjustment` etwa.
/// Es gelten dieselben Formvorschriften wie bei ``beiSignal``.
func beiSignalRoh(_ ziel: UnsafeMutableRawPointer, _ name: String,
                  _ block: @escaping () -> Void) {
    let auftrag = Unmanaged.passRetained(Auftrag(block)).toOpaque()
    g_signal_connect_data(ziel, name,
                          unsafeBitCast(auftragAlsSignalOeffentlich, to: GCallback.self),
                          auftrag, auftragFreigebenOeffentlich, GConnectFlags(rawValue: 0))
}

nonisolated(unsafe) private let auftragAlsEigenschaft: @convention(c) (
    UnsafeMutableRawPointer?, OpaquePointer?, gpointer?
) -> Void = { _, _, daten in
    guard let daten else { return }
    Unmanaged<Auftrag>.fromOpaque(daten).takeUnretainedValue().block()
}

/// Horcht auf eine Eigenschaft — `notify::is-active` und Verwandte.
///
/// **Eigener Rückruf, weil `notify` die Eigenschaft mitgibt.** Es ist genau
/// die Form, an der die App am 04.09.2026 gestorben ist: der GParamSpec steht
/// an der Stelle, an der ``beiSignal`` die Nutzdaten erwartet.
func beiEigenschaft(_ ziel: UnsafeMutableRawPointer, _ name: String,
                    _ block: @escaping () -> Void) {
    let auftrag = Unmanaged.passRetained(Auftrag(block)).toOpaque()
    g_signal_connect_data(ziel, name,
                          unsafeBitCast(auftragAlsEigenschaft, to: GCallback.self),
                          auftrag, auftragFreigebenOeffentlich, GConnectFlags(rawValue: 0))
}

/// **Ein GTK-Zeiger ist nicht „sendbar", und Swift 6 besteht darauf.**
///
/// Zu Recht: ein roher Zeiger sagt nichts darüber, wer ihn gleichzeitig
/// anfassen darf. Bei GTK ist die Antwort trotzdem einfach — alles läuft auf
/// dem Hauptfaden, und genau dorthin schickt ``aufHauptfaden`` die Arbeit
/// zurück. Diese Kiste trägt den Zeiger über die Grenze; die Zusicherung gilt,
/// solange sie **nur** in einem `aufHauptfaden`-Block ausgepackt wird.
struct Zeigerkiste: @unchecked Sendable {
    let widget: Widget!
    init(_ widget: Widget!) { self.widget = widget }
}

// MARK: - Zurück auf den Hauptfaden

nonisolated(unsafe) private let auftragImLeerlauf: @convention(c) (gpointer?) -> gboolean = { daten in
    guard let daten else { return 0 }
    Unmanaged<Auftrag>.fromOpaque(daten).takeRetainedValue().block()
    return 0   // einmal ausführen, dann abmelden
}

/// **GTK ist nicht nebenläufig.** Jede Änderung an der Oberfläche muss auf
/// dem Hauptfaden geschehen; ein Aufruf aus einer Task würde sie irgendwann
/// still zerlegen. `g_idle_add` ist der vorgesehene Rückweg.
func aufHauptfaden(_ block: @escaping @Sendable () -> Void) {
    let auftrag = Unmanaged.passRetained(Auftrag(block)).toOpaque()
    g_idle_add_full(200, auftragImLeerlauf, auftrag, nil)   // 200 = G_PRIORITY_DEFAULT_IDLE
}

// MARK: - Sanftes Blättern

/// **Ein Sprung sieht kaputt aus, auch wenn er richtig ist.**
///
/// Auf dem Mac blättert die Reihe mit `easeInOut` über 280 ms. GTK bewegt
/// eine `GtkAdjustment` nicht von selbst — der Wert wird gesetzt, und zwar
/// sofort. Diese Hülle setzt ihn stattdessen dreißigmal in derselben Zeit,
/// nach derselben Kennlinie.
///
/// Sie hält **keinen** GTK-Zeiger, sondern einen Abschluss, der ihn setzt.
/// Das ist nicht Zierde: welchen Typ `gtk_scrolled_window_get_hadjustment`
/// in Swift zurückgibt, ist nicht zu erraten, und geraten wurde hier schon
/// dreimal falsch. So muss der Typ nirgends benannt werden.
private final class Bewegung {
    let setzen: (Double) -> Void
    let von: Double
    let nach: Double
    let beginn = Date()
    static let dauer = 0.28

    init(von: Double, nach: Double, setzen: @escaping (Double) -> Void) {
        self.von = von
        self.nach = nach
        self.setzen = setzen
    }
}

nonisolated(unsafe) private let bewegungsTakt: @convention(c) (gpointer?) -> gboolean = { daten in
    guard let daten else { return 0 }
    let b = Unmanaged<Bewegung>.fromOpaque(daten).takeUnretainedValue()
    let t = min(Date().timeIntervalSince(b.beginn) / Bewegung.dauer, 1)
    // easeInOut, dieselbe Kennlinie wie `Animation.easeInOut` auf dem Mac.
    let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    b.setzen(b.von + (b.nach - b.von) * e)
    if t >= 1 {
        Unmanaged<Bewegung>.fromOpaque(daten).release()
        return 0
    }
    return 1
}

/// Bewegt einen Wert weich von `von` nach `nach`.
func sanft(von: Double, nach: Double, setzen: @escaping (Double) -> Void) {
    guard abs(nach - von) > 0.5 else { return }
    let b = Unmanaged.passRetained(Bewegung(von: von, nach: nach, setzen: setzen)).toOpaque()
    g_timeout_add_full(200, 16, bewegungsTakt, b, nil)
}

// MARK: - Zeiger drüber, Zeiger weg

nonisolated(unsafe) private let auftragAlsBewegung: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, _, _, daten in
    guard let daten else { return }
    Unmanaged<Auftrag>.fromOpaque(daten).takeUnretainedValue().block()
}

/// Meldet, wenn der Zeiger ein Widget betritt oder verlässt.
///
/// GTK4 hat dafür `GtkEventControllerMotion` mit „enter" und „leave" — zwei
/// Signale mit **verschiedenen** Formen: „enter" bringt die Koordinaten mit,
/// „leave" nicht. Deshalb zwei Rückrufe statt einem.
func beiZeiger(_ ziel: Widget!, herein: @escaping () -> Void, hinaus: @escaping () -> Void) {
    let horcher = gtk_event_controller_motion_new()
    let a = Unmanaged.passRetained(Auftrag(herein)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(horcher), "enter",
                          unsafeBitCast(auftragAlsBewegung, to: GCallback.self),
                          a, auftragFreigebenOeffentlich, GConnectFlags(rawValue: 0))
    let b = Unmanaged.passRetained(Auftrag(hinaus)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(horcher), "leave",
                          unsafeBitCast(auftragAlsSignalOeffentlich, to: GCallback.self),
                          b, auftragFreigebenOeffentlich, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(ziel, horcher)
}

// MARK: - Weiches Scrollen

/// **GTK scrollt am Mausrad in Sprüngen.** Ein Rastpunkt, ein Satz — das ist
/// das Stockige, das Am Zeigerfeld glättet GTK selbst, am Rad nicht.
///
/// Hier wird jeder Rastpunkt in ein Ziel verwandelt, und ein Takt läuft diesem
/// Ziel exponentiell hinterher: pro Bild ein Fünftel des Rests. Kommen weitere
/// Rastpunkte, wandert nur das Ziel — es entsteht keine zweite Bewegung, die
/// gegen die erste läuft.
private final class Weichlauf {
    let lesen: () -> Double
    let setzen: (Double) -> Void
    let obergrenze: () -> Double
    var ziel: Double
    var takt: guint = 0

    init(lesen: @escaping () -> Double, setzen: @escaping (Double) -> Void,
         obergrenze: @escaping () -> Double) {
        self.lesen = lesen
        self.setzen = setzen
        self.obergrenze = obergrenze
        self.ziel = lesen()
    }
}

/// Wie weit ein Rastpunkt trägt. Etwa drei Textzeilen — dieselbe Größenordnung,
/// die ein Zeigerfeld in einer Wischbewegung zurücklegt.
private let rastweite: Double = 110

nonisolated(unsafe) private let weichTakt: @convention(c) (gpointer?) -> gboolean = { daten in
    guard let daten else { return 0 }
    let w = Unmanaged<Weichlauf>.fromOpaque(daten).takeUnretainedValue()
    let jetzt = w.lesen()
    let rest = w.ziel - jetzt
    if abs(rest) < 0.5 {
        w.setzen(w.ziel)
        w.takt = 0
        Unmanaged<Weichlauf>.fromOpaque(daten).release()
        return 0
    }
    w.setzen(jetzt + rest * 0.20)
    return 1
}

nonisolated(unsafe) private let radGedreht: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> gboolean = { _, _, dy, daten in
    guard let daten else { return 0 }
    let w = Unmanaged<Weichlauf>.fromOpaque(daten).takeUnretainedValue()
    let hoechst = w.obergrenze()
    w.ziel = min(max(w.ziel + dy * rastweite, 0), max(hoechst, 0))
    if w.takt == 0 {
        // Der Takt hält sich selbst fest, solange er läuft.
        w.takt = g_timeout_add_full(200, 16, weichTakt,
                                    Unmanaged.passRetained(w).toOpaque(), nil)
    }
    return 1   // verbraucht: GTK soll nicht zusätzlich springen
}

nonisolated(unsafe) private let weichlaufFreigeben: @convention(c) (
    gpointer?, UnsafeMutablePointer<_GClosure>?
) -> Void = { daten, _ in
    guard let daten else { return }
    Unmanaged<Weichlauf>.fromOpaque(daten).release()
}

/// Hängt weiches Scrollen an eine Scrollfläche.
func weichesScrollen(_ scroller: Widget!) {
    guard let anpassung = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
    else { return }
    let w = Weichlauf(
        lesen: { gtk_adjustment_get_value(anpassung) },
        setzen: { gtk_adjustment_set_value(anpassung, $0) },
        obergrenze: {
            gtk_adjustment_get_upper(anpassung) - gtk_adjustment_get_page_size(anpassung)
        })
    let horcher = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)
    // **In der Fangphase, sonst kommt nichts an.** Ein Horcher, der an der
    // Scrollfläche hängt, läuft von Haus aus in der Blasenphase — also
    // *nachdem* die Scrollfläche das Rad schon selbst verarbeitet und den
    // Sprung gemacht hat. Genau deshalb blieb das Scrollen stockig, obwohl
    // der Horcher dran war. `CAPTURE` sieht das Ereignis zuerst.
    gtk_event_controller_set_propagation_phase(horcher, GTK_PHASE_CAPTURE)
    g_signal_connect_data(UnsafeMutableRawPointer(horcher), "scroll",
                          unsafeBitCast(radGedreht, to: GCallback.self),
                          Unmanaged.passRetained(w).toOpaque(),
                          weichlaufFreigeben, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(scroller, horcher)
}
