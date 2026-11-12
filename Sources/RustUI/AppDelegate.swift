import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // The real app unless launched with --demo (scripted suite, used by the comparison goldens).
        if !CommandLine.arguments.contains("--demo") { HostPlatform.register() }
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = RustController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

final class RustController: UIViewController {
    private let engine = AVEngine()

    override func loadView() {
        let ground = UIView(frame: UIScreen.main.bounds)
        ground.backgroundColor = UIColor(white: 0.0627, alpha: 1)
        engine.view.frame = ground.bounds
        engine.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        ground.addSubview(engine.view)
        let rust = RustView(frame: ground.bounds)
        rust.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        rust.engine = engine
        engine.wake = { [weak rust] in rust?.wake() }
        ground.addSubview(rust)
        view = ground
    }
    #if os(iOS)
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    #endif
}
