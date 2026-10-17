#if os(iOS) || os(macOS)
import JellyfinKit
import SwiftUI
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
        var rows = [
            "Swiftly \(Version.withBase)",
            system(v),
            "Stand \(ISO8601DateFormatter().string(from: Date()))",
            "",
        ]
        let excerpt = LogRing.shared.excerpt(seconds: 3600)
        rows += excerpt.isEmpty
            ? ["(no lines in the last hour — reproduce the problem first, then share without closing the app)"]
            : excerpt
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Swiftly-Protokoll.txt")
        do {
            try Data(rows.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        } catch {
            AppLog.writeOut("[Protokoll] Datei ließ sich nicht schreiben: \(error.localizedDescription)")
            return nil
        }
        return LogFile(url: url)
    }

    private static func system(_ v: OperatingSystemVersion) -> String {
        #if os(iOS)
        "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) · \(UIDevice.current.model)"
        #else
        "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
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
