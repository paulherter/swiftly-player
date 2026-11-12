#if os(iOS) || os(macOS)
import JellyfinKit
import SwiftUI
import enum SwiftlyCore.LogShareText
#if os(iOS)
import UIKit
#endif

/// **"Share log": the last hour as a text file.**
///
/// For bugs that only occur on the user's device: they reproduce it, tap here,
/// and send the file via the share sheet. The lines come from ``Protokollring``;
/// credentials are already redacted when entered. The server address stays,
/// because without it a network error cannot be read.
struct LogFile: Identifiable {
    let url: URL
    var id: String { url.path }

    @MainActor
    static func write() -> LogFile? {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let text = LogShareText.text(
            version: Version.withBase, system: system(v), now: Date(),
            excerpt: LogRing.shared.excerpt(seconds: 3600))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(LogShareText.fileName)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            AppLog.writeOut("[Protokoll] Datei ließ sich nicht schreiben: \(error.localizedDescription)")
            return nil
        }
        return LogFile(url: url)
    }

    private static func system(_ v: OperatingSystemVersion) -> String {
        #if os(iOS)
        LogShareText.systemIOS(v, model: UIDevice.current.model)
        #else
        LogShareText.systemMacOS(v)
        #endif
    }
}

#if os(iOS)

/// The system share sheet for a file.
struct ShareSheet: UIViewControllerRepresentable {
    let file: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }

    func updateUIViewController(_ sheet: UIActivityViewController, context: Context) {}
}
#endif
#endif
