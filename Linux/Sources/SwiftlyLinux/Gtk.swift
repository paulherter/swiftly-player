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
@inline(__always) func alsZeichen(_ w: Widget!) -> UnsafeMutablePointer<GtkDrawingArea>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkDrawingArea>.self)
}
@inline(__always) func alsFest(_ w: Widget!) -> UnsafeMutablePointer<GtkFixed>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkFixed>.self)
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
/// Eine Tafel, die an ihrem Anker hängt — und mit ihm verschwindet.
///
/// **GTK räumt ein Popover nicht mit seinem Anker ab.** Es wird zwar über
/// `gtk_widget_set_parent` dessen Kind, aber niemand löst es wieder: wird der
/// Anker zerstört, meldet GTK
///
///     Finalizing GtkButton …, but it still has children left: GtkPopover …
///
/// und lässt einen Zeiger stehen. Solange man nur zusieht, fällt das nicht
/// auf; sobald derselbe Speicher wieder gebraucht wird, nimmt es die App mit.
/// Genau so ist sie beim Öffnen einer Serie abgestürzt — und die Startseite
/// hängt eine solche Tafel an **jede** Kachel.
///
/// Deshalb hier: anhängen und im selben Atemzug das Lösen bestellen. Wer eine
/// Tafel braucht, nimmt diese Funktion und nicht `gtk_popover_new` von Hand.
func tafelAn(_ anker: Widget!, stil: String = "swiftly-mehr",
             lage: GtkPositionType = GTK_POS_BOTTOM) -> Widget! {
    let tafel: Widget! = gtk_popover_new()
    gtk_widget_add_css_class(tafel, stil)
    gtk_popover_set_position(alsTafel(tafel), lage)
    gtk_widget_set_parent(tafel, anker)
    beiSignal(anker, "destroy") { gtk_widget_unparent(tafel) }
    return tafel
}

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
/// Genau so ist die App am 04.09.2026 abgestürzt, als Paul den Blätterpfeil
/// gedrückt hat: `edge-reached` reicht die erreichte Kante als zweites
/// Argument, also stand dort eine 0 bis 3 statt einer Adresse.
/// „Bad pointer dereference at 0x8". Wer ein Signal mit Argumenten braucht,
/// schreibt einen eigenen Rückruf mit passender Form — siehe ``beiZeiger``
/// für „enter", das x und y mitbringt.
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
/// sofort. Diese Hülle setzt ihn stattdessen bei jedem Bild neu.
///
/// **Am Bildtakt, nicht an einem Zeitgeber.** Hier stand `g_timeout_add` mit
/// 16 ms — das sind 62 Bilder je Sekunde, und zwar auf jedem Schirm. Paul
/// sieht auf 144 Hz sofort, dass sich alles nach 60 anfühlt.
/// `gtk_widget_add_tick_callback` hängt am Bildtakt des Fensters und läuft
/// damit so schnell wie der Schirm.
private final class Bewegung {
    let setzen: (Double) -> Void
    let von: Double
    let nach: Double
    let beginn = Date()
    static let dauer = 0.28
    var takt: guint = 0
    var teiler: Double = 1

    init(von: Double, nach: Double, setzen: @escaping (Double) -> Void) {
        self.von = von
        self.nach = nach
        self.setzen = setzen
    }
}

nonisolated(unsafe) private let bewegungsTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, daten in
    guard let daten else { return 0 }
    let b = Unmanaged<Bewegung>.fromOpaque(daten).takeUnretainedValue()
    let t = min(Date().timeIntervalSince(b.beginn) / Bewegung.dauer, 1)
    // easeInOut, dieselbe Kennlinie wie `Animation.easeInOut` auf dem Mac.
    let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    // Auf ganze Gerätepunkte, aus demselben Grund wie beim Scrollen.
    let roh = b.von + (b.nach - b.von) * e
    b.setzen((roh * b.teiler).rounded() / b.teiler)
    if t >= 1 {
        Unmanaged<Bewegung>.fromOpaque(daten).release()
        return 0   // G_SOURCE_REMOVE
    }
    return 1
}

/// Bewegt einen Wert weich von `von` nach `nach`, im Takt des Schirms.
func sanft(auf widget: Widget!, von: Double, nach: Double,
           setzen: @escaping (Double) -> Void) {
    guard abs(nach - von) > 0.5 else { return }
    let lauf = Bewegung(von: von, nach: nach, setzen: setzen)
    lauf.teiler = Double(max(gtk_widget_get_scale_factor(widget), 1))
    let b = Unmanaged.passRetained(lauf).toOpaque()
    _ = gtk_widget_add_tick_callback(widget, bewegungsTakt, b, nil)
}

// MARK: - Zeiger drüber, Zeiger weg

nonisolated(unsafe) let auftragAlsBewegungOeffentlich: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, _, _, daten in
    guard let daten else { return }
    Unmanaged<Auftrag>.fromOpaque(daten).takeUnretainedValue().block()
}

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
/// das Stockige. Am Zeigerfeld glättet GTK selbst, am Rad nicht.
///
/// Jeder Rastpunkt wird hier zu einem Ziel, und ein Takt läuft diesem Ziel
/// hinterher. Kommen weitere Rastpunkte, wandert nur das Ziel — es entsteht
/// keine zweite Bewegung, die gegen die erste läuft.
///
/// **Zwei Sachen, die es vorher nicht getroffen haben.** Der Takt hing an
/// `g_timeout_add` mit 16 ms, also an 62 Bildern je Sekunde statt am Schirm;
/// auf 144 Hz fühlt sich das an wie 60. Und der Schritt war ein fester Anteil
/// *je Bild* — damit liefe dieselbe Bewegung auf einem schnellen Schirm mehr
/// als doppelt so schnell. Beides hängt jetzt an der **Zeit**: `1 − e^(−k·dt)`
/// mit `k = 13,9`, was bei 16 ms genau den alten Fünftelschritt ergibt.
private final class Weichlauf {
    let lesen: () -> Double
    let setzen: (Double) -> Void
    let obergrenze: () -> Double
    var ziel: Double
    var takt: guint = 0
    var zuletzt: Int = 0
    /// Wie viele Gerätepunkte auf einen Punkt kommen.
    var teiler: Double = 1

    init(lesen: @escaping () -> Double, setzen: @escaping (Double) -> Void,
         obergrenze: @escaping () -> Double) {
        self.lesen = lesen
        self.setzen = setzen
        self.obergrenze = obergrenze
        self.ziel = lesen()
    }

    /// **Auf ganze Gerätepunkte einrasten.**
    ///
    /// Ein gebrochener Scrollstand verschiebt den ganzen Inhalt um einen
    /// halben Bildpunkt. Dann werden **alle** Widget-Kanten mit halber
    /// Deckung gezeichnet — und wo zwei gleichfarbige Kästen aneinander
    /// stossen, scheint der Grund dahinter durch. Genau daher der dunkle
    /// Strich zwischen Kopfzone und Unterbau: beide tragen denselben Ton,
    /// dahinter liegt Schwarz, und zwei halb gedeckte Zeilen ergeben
    /// 66 → 60 → 52 → 64. Am Bildschirmfoto gemessen.
    func rasten(_ wert: Double) -> Double {
        (wert * teiler).rounded() / teiler
    }
}

/// Wie weit ein Rastpunkt trägt. Etwa drei Textzeilen — dieselbe Größenordnung,
/// die ein Zeigerfeld in einer Wischbewegung zurücklegt.
private let rastweite: Double = 110
/// Wie schnell der Rest zusammenschmilzt. Bei 16 ms bleibt ein Fünftel.
private let weichrate: Double = 13.9

nonisolated(unsafe) private let weichTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, uhr, daten in
    guard let daten else { return 0 }
    let w = Unmanaged<Weichlauf>.fromOpaque(daten).takeUnretainedValue()

    // Die Zeit kommt aus dem Bildtakt, in Mikrosekunden.
    let jetztZeit = Int(uhr.map { gdk_frame_clock_get_frame_time($0) } ?? 0)
    let dt = w.zuletzt == 0 ? 1.0 / 60 : Double(jetztZeit - w.zuletzt) / 1_000_000
    w.zuletzt = jetztZeit

    let jetzt = w.lesen()
    let rest = w.ziel - jetzt
    if abs(rest) < 0.5 {
        w.setzen(w.rasten(w.ziel))
        w.takt = 0
        Unmanaged<Weichlauf>.fromOpaque(daten).release()
        return 0
    }
    w.setzen(w.rasten(jetzt + rest * (1 - exp(-weichrate * min(dt, 0.1)))))
    return 1
}

nonisolated(unsafe) private let radGedreht: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> gboolean = { horcher, _, dy, daten in
    guard let daten else { return 0 }
    let w = Unmanaged<Weichlauf>.fromOpaque(daten).takeUnretainedValue()
    let hoechst = w.obergrenze()
    // **Bei jedem neuen Griff neu ansetzen.** Läuft gerade nichts, ist das
    // gemerkte Ziel womöglich veraltet — die Seite kann inzwischen neu gebaut
    // oder von woanders gescrollt worden sein.
    if w.takt == 0 { w.ziel = w.lesen(); w.zuletzt = 0 }
    w.ziel = min(max(w.ziel + dy * rastweite, 0), max(hoechst, 0))
    if w.takt == 0, let horcher,
       let ziel = gtk_event_controller_get_widget(OpaquePointer(horcher)) {
        w.teiler = Double(max(gtk_widget_get_scale_factor(ziel), 1))
        w.takt = gtk_widget_add_tick_callback(ziel, weichTakt,
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
    // GTKs eigene Trägheit läuft sonst gegen unsere Bewegung an.
    gtk_scrolled_window_set_kinetic_scrolling(OpaquePointer(scroller), 0)
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

// MARK: - Klicken ohne Knopf

nonisolated(unsafe) let auftragAlsKlick: @convention(c) (
    UnsafeMutableRawPointer?, Int32, Double, Double, gpointer?
) -> Void = { _, _, _, _, daten in
    guard let daten else { return }
    Unmanaged<Auftrag>.fromOpaque(daten).takeUnretainedValue().block()
}

/// Macht ein beliebiges Widget anklickbar, ohne es zu einem Knopf zu machen.
///
/// **Warum kein Knopf.** Eine Folgenzeile trägt selbst einen Knopf — den
/// Haken zum Umschalten. Ein Knopf im Knopf ist in GTK kein sicherer Bau; wer
/// beide braucht, nimmt für den äusseren eine Geste. Auf dem Mac steht dort
/// aus demselben Grund `.onTapGesture` statt eines `Button`.
///
/// `released` bringt Zählung und Ort mit — vier Argumente, nicht zwei.
func beiKlick(_ ziel: Widget!, _ block: @escaping () -> Void) {
    let geste = gtk_gesture_click_new()
    let auftrag = Unmanaged.passRetained(Auftrag(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(geste), "released",
                          unsafeBitCast(auftragAlsKlick, to: GCallback.self),
                          auftrag, auftragFreigebenOeffentlich, GConnectFlags(rawValue: 0))
    // `GtkEventController` ist in C ein unvollstaendiger Typ; Swift bekommt
    // ihn als `OpaquePointer` — genau das, was die Geste schon ist.
    gtk_widget_add_controller(ziel, geste)
}

// MARK: - Ein Lauf von null nach eins

/// Ein Lauf über eine Dauer, im Takt des Schirms. ``sanft(auf:von:nach:setzen:)``
/// bewegt **einen** Wert; hier braucht es den Fortschritt selbst, weil an ihm
/// mehrere Ebenen gleichzeitig hängen.
private final class Lauf {
    let schritt: (Double) -> Void
    let fertig: () -> Void
    let dauer: Double
    let beginn = Date()

    init(dauer: Double, schritt: @escaping (Double) -> Void, fertig: @escaping () -> Void) {
        self.dauer = dauer
        self.schritt = schritt
        self.fertig = fertig
    }
}

nonisolated(unsafe) private let laufTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, daten in
    guard let daten else { return 0 }
    let l = Unmanaged<Lauf>.fromOpaque(daten).takeUnretainedValue()
    let t = min(Date().timeIntervalSince(l.beginn) / l.dauer, 1)
    // easeInOut — dieselbe Kennlinie wie `Animation.easeInOut` auf dem Mac.
    l.schritt(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
    if t >= 1 {
        l.fertig()
        Unmanaged<Lauf>.fromOpaque(daten).release()
        return 0   // G_SOURCE_REMOVE
    }
    return 1
}

/// Ruft `schritt` mit dem geglätteten Fortschritt 0…1, dann einmal `fertig`.
func laufen(auf widget: Widget!, dauer: Double,
            schritt: @escaping (Double) -> Void,
            fertig: @escaping () -> Void) {
    let lauf = Lauf(dauer: dauer, schritt: schritt, fertig: fertig)
    _ = gtk_widget_add_tick_callback(widget, laufTakt,
                                     Unmanaged.passRetained(lauf).toOpaque(), nil)
}

// MARK: - Grösse melden

final class Massauftrag {
    let block: (Int32, Int32) -> Void
    init(_ block: @escaping (Int32, Int32) -> Void) { self.block = block }
}

nonisolated(unsafe) private let auftragAlsMass: @convention(c) (
    UnsafeMutableRawPointer?, Int32, Int32, gpointer?
) -> Void = { _, breite, hoehe, daten in
    guard let daten else { return }
    Unmanaged<Massauftrag>.fromOpaque(daten).takeUnretainedValue().block(breite, hoehe)
}

nonisolated(unsafe) private let massFreigeben: @convention(c) (
    gpointer?, UnsafeMutablePointer<_GClosure>?
) -> Void = { daten, _ in
    guard let daten else { return }
    Unmanaged<Massauftrag>.fromOpaque(daten).release()
}

/// Meldet die Grösse einer Zeichenfläche. **`resize` bringt Breite und Höhe
/// mit** — vier Argumente, also wieder ein eigener Rückruf (Falle 2).
func beiGroesse(_ feld: Widget!, _ block: @escaping (Int32, Int32) -> Void) {
    let auftrag = Unmanaged.passRetained(Massauftrag(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(feld), "resize",
                          unsafeBitCast(auftragAlsMass, to: GCallback.self),
                          auftrag, massFreigeben, GConnectFlags(rawValue: 0))
}

// MARK: - Während eine Seite fährt, wird nichts Schweres getan

/// **Das Ruckeln war nie die Kurve.**
///
/// Auf dem Mac stand an derselben Stelle ein `HStack`, der jede Kachel sofort
/// baute — „in demselben Bild, in dem die Seite hereinfährt. Das war das
/// Ruckeln: nicht die Bewegung war hart, sondern sie verlor Bilder, weil
/// daneben die halbe Seite gebaut wurde." Ein `LazyHStack` hat es behoben.
///
/// GTK hat kein faules Auslegen, und die schweren Sachen sind hier andere:
/// ein 1600 Punkt breites Kopfbild entpacken, das Stilblatt für den Farbton
/// neu einlesen (das stellt **jedes** Widget der App neu), die halbe Seite
/// verwerfen und mit dem vollen Satz vom Server neu bauen. Alles das kommt
/// aus dem Netz und trifft die Seite deshalb genau in der Mitte der Fahrt —
/// da, wo es hakt.
///
/// Also wartet es. Die Fahrt dauert 0,45 s; wer danach dran ist, merkt nichts
/// davon, und die Bewegung behält alle Bilder.
///
/// `nonisolated(unsafe)`, weil es GTKs Hauptfaden gehört wie alles hier —
/// angefasst wird es nur aus ``aufHauptfaden`` heraus.
enum Schubsperre {
    nonisolated(unsafe) private static var tiefe = 0
    nonisolated(unsafe) private static var seit = Date.distantPast
    nonisolated(unsafe) private static var warteschlange: [@Sendable () -> Void] = []

    /// **Eine Sperre, die haengenbleibt, ist schlimmer als keine.** Der
    /// Bildtakt gibt keine Zusicherung, dass er einen Lauf zu Ende bringt —
    /// wird das Fenster unterwegs abgebaut, kommt der letzte Rueckruf nie,
    /// und dann laedt die App nie wieder ein Bild. Eine Fahrt dauert 0,45 s;
    /// was laenger als eine Sekunde behauptet zu fahren, faehrt nicht mehr.
    static var faehrt: Bool {
        guard tiefe > 0 else { return false }
        guard Date().timeIntervalSince(seit) < 1 else { tiefe = 0; return false }
        return true
    }

    static func beginnen() {
        tiefe += 1
        seit = Date()
    }

    static func beenden() {
        tiefe = max(tiefe - 1, 0)
        guard !faehrt, !warteschlange.isEmpty else { return }
        let offen = warteschlange
        warteschlange = []
        // **Nicht im letzten Bild der Fahrt.** Der Rückruf läuft noch im
        // Bildtakt; wer hier arbeitet, kostet genau das Bild, das die
        // Bewegung abschliesst.
        aufHauptfaden { for block in offen { block() } }
    }

    /// Sperrt für eine feste Zeit. Gebraucht für Bewegungen, die **GTK**
    /// führt — ein `GtkStack` sagt nicht Bescheid, wenn er fertig ist, und
    /// beim Schliessen des Players baut die Startseite sich gerade neu auf,
    /// mitten in der Fahrt.
    static func fuer(_ sekunden: Double) {
        beginnen()
        let auftrag = Unmanaged.passRetained(Auftrag { beenden() }).toOpaque()
        g_timeout_add_full(200, guint(sekunden * 1000 + 30), auftragEinmal,
                           auftrag, auftragFreigebenRoh)
    }

    static func spaeter(_ block: @escaping @Sendable () -> Void) {
        guard faehrt else { beenden(); block(); return }
        warteschlange.append(block)
    }
}

/// Wie ``aufHauptfaden``, aber **nicht, während eine Seite fährt**.
///
/// **Nur für die vielen, nicht für die wenigen.** Das Kopfbild, der Farbton,
/// der Titelblock, die Staffelauswahl — das ist das, was man während der
/// Fahrt anschaut, und das darf nicht nachpoppen; es ist auch je eine Sache
/// und keine zwanzig. Was hier wartet, sind die Folgenbilder, die Besetzung
/// und „Ähnliches": viele kleine Bilder, die alle im selben Augenblick
/// eintreffen. Nicht für die Navigation selbst — die löst die Fahrt ja
/// erst aus.
func nachDemSchub(_ block: @escaping @Sendable () -> Void) {
    aufHauptfaden { Schubsperre.spaeter(block) }
}


nonisolated(unsafe) private let auftragEinmal: @convention(c) (gpointer?) -> gboolean = { daten in
    guard let daten else { return 0 }
    Unmanaged<Auftrag>.fromOpaque(daten).takeUnretainedValue().block()
    return 0   // G_SOURCE_REMOVE
}

nonisolated(unsafe) private let auftragFreigebenRoh: @convention(c) (gpointer?) -> Void = { daten in
    guard let daten else { return }
    Unmanaged<Auftrag>.fromOpaque(daten).release()
}


/// Meldet, wenn ein Scroller **unten** angekommen ist.
///
/// `edge-reached` reicht die erreichte Kante als zweites Argument mit — genau
/// das Signal, an dem die App am 04.09.2026 abgestuerzt ist, als es noch ueber
/// ``beiSignal`` lief. Deshalb ein eigener Rueckruf mit passender Form, und
/// gemeldet wird nur die untere Kante (`GTK_POS_BOTTOM` = 3).
func randMelden(_ scroller: Widget!, _ block: @escaping () -> Void) {
    let auftrag = Unmanaged.passRetained(Auftrag(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(scroller), "edge-reached",
                          unsafeBitCast(auftragAnKante, to: GCallback.self),
                          auftrag, auftragFreigebenOeffentlich, GConnectFlags(rawValue: 0))
}

nonisolated(unsafe) private let auftragAnKante: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, gpointer?
) -> Void = { _, kante, daten in
    guard let daten, kante == GTK_POS_BOTTOM.rawValue else { return }
    Unmanaged<Auftrag>.fromOpaque(daten).takeUnretainedValue().block()
}

/// Meldet **echte** Bewegungen des Zeigers über einem Widget.
///
/// **Warum eine Schwelle.** Auf dem Mac steht dort ausdrücklich „bei jeder
/// echten Bewegung > 2 px" (`PlayerScreen.swift:180`). Ich hatte das
/// weggelassen — mit sichtbarer Folge: über eine Fernsitzung schickt der
/// Client laufend die Zeigerposition, auch wenn niemand die Maus anfasst.
/// Jede dieser Meldungen holte die Steuerung zurück, und sie blendete nie
/// wieder aus.
///
/// Zwei Punkte sind ausserdem der Zittertoleranz eines ruhenden Fingers oder
/// einer optischen Maus geschuldet; ohne sie zählt schon das Rauschen.
func beiBewegung(_ ziel: Widget!, _ block: @escaping () -> Void) {
    let horcher = gtk_event_controller_motion_new()
    let a = Unmanaged.passRetained(Bewegungswache(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(horcher), "motion",
                          unsafeBitCast(wacheAlsBewegung, to: GCallback.self),
                          a, wacheFreigeben, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(ziel, horcher)
}

/// Merkt sich, wo der Zeiger zuletzt war.
final class Bewegungswache {
    let block: () -> Void
    var x: Double = -1
    var y: Double = -1
    init(_ block: @escaping () -> Void) { self.block = block }
}

nonisolated(unsafe) private let wacheAlsBewegung: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, x, y, daten in
    guard let daten else { return }
    let w = Unmanaged<Bewegungswache>.fromOpaque(daten).takeUnretainedValue()
    // **Die Marke wandert nur beim Auslösen mit.**
    //
    // Vorher stand sie nach *jeder* Meldung neu — damit wurde immer nur der
    // Abstand zur vorigen Meldung geprüft, und langsames Ziehen blieb ewig
    // darunter: die Steuerung blendete weg, obwohl die Maus lief. Bleibt die
    // Marke stehen, summiert sich die Strecke, und irgendwann sind die zwei
    // Punkte erreicht — genau das meint „echte Bewegung".
    guard w.x >= 0 else { w.x = x; w.y = y; return }
    guard abs(x - w.x) > 2 || abs(y - w.y) > 2 else { return }
    w.x = x
    w.y = y
    w.block()
}

nonisolated(unsafe) private let wacheFreigeben: @convention(c) (
    gpointer?, UnsafeMutablePointer<_GClosure>?
) -> Void = { daten, _ in
    guard let daten else { return }
    Unmanaged<Bewegungswache>.fromOpaque(daten).release()
}

/// Meldet einen Rechtsklick — die Zeigerform des langen Drückens (A6).
///
/// Dieselbe Geste wie ``beiKlick``, nur auf die rechte Taste gestellt und auf
/// `pressed`: ein Kontextmenü erscheint beim Drücken, nicht beim Loslassen.
func beiRechtsklick(_ ziel: Widget!, _ block: @escaping () -> Void) {
    let geste = gtk_gesture_click_new()
    gtk_gesture_single_set_button(geste, 3)
    let auftrag = Unmanaged.passRetained(Auftrag(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(geste), "pressed",
                          unsafeBitCast(auftragAlsKlick, to: GCallback.self),
                          auftrag, auftragFreigebenOeffentlich, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(ziel, geste)
}

// MARK: - Was die Bedienhilfe erfährt

/// Gibt einem selbstgebauten Bedienelement einen Namen.
///
/// **E8: wer keine Standardsteuerelemente nimmt, erbt auch deren
/// Barrierefreiheit nicht.** Ein gemalter Knopf ist sonst nur „Taste", ein
/// Zeitregler ein namenloses Rechteck. Auf Apple leistet das
/// `accessibilityLabel`; in GTK4 heisst es `GTK_ACCESSIBLE_PROPERTY_LABEL`.
func beschriften(_ ziel: Widget!, _ name: String) {
    // **Die bequeme Form ist variadisch und damit für Swift gesperrt.**
    // `gtk_accessible_update_property` nimmt Paare beliebiger Länge;
    // `…_value` nimmt zwei Felder und ist aufrufbar. Der Typ des Wertes wird
    // über seinen Namen geholt, statt das Makro `G_TYPE_STRING` nachzubauen.
    var eigenschaft = GTK_ACCESSIBLE_PROPERTY_LABEL
    var wert = GValue()
    g_value_init(&wert, g_type_from_name("gchararray"))
    name.withCString { g_value_set_string(&wert, $0) }
    gtk_accessible_update_property_value(OpaquePointer(ziel), 1, &eigenschaft, &wert)
    g_value_unset(&wert)
}
