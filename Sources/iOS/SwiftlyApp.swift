import SwiftUI

@main
struct SwiftlyApp: App {
    @UIApplicationDelegateAdaptor(SwiftlyAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { RootView() }
            // **Without this a background download is left hanging.**
            //
            // An 18 GB file does not download in the thirty seconds iOS gives an app in the
            // background; the background session therefore hands the transfer to a system
            // service that keeps running after the app is terminated. When it finishes, **iOS
            // relaunches the app just for this** and expects someone to look. Without this
            // line the launch leads nowhere: the finished file stays in Apple's staging area,
            // and the next opening starts the download from scratch.
            //
            // The identifier must be the same as in `DownloadManager`, hence taken from
            // there, not typed.
            .backgroundTask(.urlSession(DownloadManager.sessionId)) {
                // Merely waking up is enough: the session delivers its callbacks by itself as
                // soon as the model touches it. Nothing to do here, but the line must be there.
            }
    }
}
