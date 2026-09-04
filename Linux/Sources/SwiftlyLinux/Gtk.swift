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

nonisolated(unsafe) private let auftragAlsSignal: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> Void = { _, daten in
    guard let daten else { return }
    Unmanaged<Auftrag>.fromOpaque(daten).takeUnretainedValue().block()
}

nonisolated(unsafe) private let auftragFreigeben: @convention(c) (gpointer?, UnsafeMutablePointer<_GClosure>?) -> Void = { daten, _ in
    guard let daten else { return }
    Unmanaged<Auftrag>.fromOpaque(daten).release()
}

/// Verbindet ein Signal mit einem Swift-Abschluss.
///
/// `g_signal_connect` ist ein Makro und in Swift unsichtbar; darunter liegt
/// `g_signal_connect_data`. Der Abschluss wird festgehalten und wieder
/// freigegeben, wenn GTK das Signal löst — sonst wäre er nach dem nächsten
/// Aufräumen ein Zeiger ins Leere.
func beiSignal(_ ziel: Widget!, _ name: String, _ block: @escaping () -> Void) {
    let auftrag = Unmanaged.passRetained(Auftrag(block)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(ziel), name,
                          unsafeBitCast(auftragAlsSignal, to: GCallback.self),
                          auftrag, auftragFreigeben, GConnectFlags(rawValue: 0))
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
func aufHauptfaden(_ block: @escaping () -> Void) {
    let auftrag = Unmanaged.passRetained(Auftrag(block)).toOpaque()
    g_idle_add_full(200, auftragImLeerlauf, auftrag, nil)   // 200 = G_PRIORITY_DEFAULT_IDLE
}
