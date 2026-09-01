import SwiftUI

@main
struct SwiftlyApp: App {
    @UIApplicationDelegateAdaptor(SwiftlyAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { RootView() }
    }
}
