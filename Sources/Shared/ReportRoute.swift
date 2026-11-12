import Foundation

/// **Who sends which report while the core plays a title.**
///
/// The core's `PlayerVm` reports start (at the first picture), progress, pause/resume and seeks itself; the app
/// keeps the stop (awaited, the pages reload after it) and the background report. Both go through one queue
/// (`PlayerVm` is created over the app's `PlayReporter`), so there is one stop lock and one order. The rule below is
/// what `AppModel.reportStart/Progress` ask: a report the core already sends is not sent a second time.
enum ReportRoute {
    enum Kind { case start, progress, stop, background }

    static func appSends(_ kind: Kind, coreOwns: Bool) -> Bool {
        switch kind {
        case .start, .progress: !coreOwns
        case .stop, .background: true
        }
    }
}
