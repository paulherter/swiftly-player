import Foundation

/// The Apple host of the core's `Platform` trait: the device name, a log sink and the directory for
/// disposable files. Create one per app and hand it to `Core(platform:...)`.
public final class CorePlatform: Platform {
    private let name: String
    private let sink: @Sendable (String) -> Void
    private let base: URL?

    /// - Parameters:
    ///   - deviceName: what the server lists this device under; the host name by default.
    ///   - cachesBase: replaces the system Caches directory (tests).
    ///   - log: where the core's log lines go (they never contain secrets); dropped by default.
    public init(
        deviceName: String = ProcessInfo.processInfo.hostName, cachesBase: URL? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.name = deviceName
        self.sink = log
        self.base = cachesBase
    }

    /// The folder the core keeps disposable files in: `Caches/de.paulherter.swiftly/core`, made when asked.
    /// `nil` when it cannot be made (the core then keeps everything in memory).
    public func cacheDir() -> String? {
        let caches =
            base
            ?? (try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        guard let caches else { return nil }
        let folder = caches.appendingPathComponent("de.paulherter.swiftly", isDirectory: true)
            .appendingPathComponent("core", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return folder.path
    }

    public func deviceName() -> String { name }
    public func log(line: String) { sink(line) }
}
